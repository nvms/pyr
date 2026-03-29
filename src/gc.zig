const std = @import("std");
const Value = @import("value.zig").Value;
const ObjString = @import("value.zig").ObjString;
const ObjFunction = @import("value.zig").ObjFunction;
const ObjStruct = @import("value.zig").ObjStruct;
const ObjEnum = @import("value.zig").ObjEnum;
const ObjArray = @import("value.zig").ObjArray;
const ObjClosure = @import("value.zig").ObjClosure;
const ObjNativeFn = @import("value.zig").ObjNativeFn;
const ObjError = @import("value.zig").ObjError;
const ObjMap = @import("value.zig").ObjMap;

pub const GC = struct {
    objects: std.ArrayListUnmanaged(GcObj),
    ptr_map: std.AutoHashMapUnmanaged(usize, u32),
    mark_stack: std.ArrayListUnmanaged(Value),
    alloc: std.mem.Allocator,
    bytes_allocated: usize,
    next_threshold: usize,
    enabled: bool,
    collections: usize,
    paused: bool,

    const INITIAL_THRESHOLD: usize = 256 * 1024;
    const GROWTH_FACTOR: usize = 2;

    pub const GcObj = struct {
        ptr: usize,
        tag: Value.Tag,
        marked: bool,
    };

    pub fn init(alloc: std.mem.Allocator) GC {
        return .{
            .objects = .{},
            .ptr_map = .{},
            .mark_stack = .{},
            .alloc = alloc,
            .bytes_allocated = 0,
            .next_threshold = INITIAL_THRESHOLD,
            .enabled = true,
            .collections = 0,
            .paused = false,
        };
    }

    pub fn deinit(self: *GC) void {
        self.objects.deinit(self.alloc);
        self.ptr_map.deinit(self.alloc);
        self.mark_stack.deinit(self.alloc);
    }

    pub fn track(self: *GC, val: Value) void {
        const tag = val.tag();
        const size = objSize(val, tag);
        if (size == 0) return;
        const ptr = val.payload();
        const idx: u32 = @intCast(self.objects.items.len);
        self.objects.append(self.alloc, .{
            .ptr = ptr,
            .tag = tag,
            .marked = false,
        }) catch {};
        self.ptr_map.put(self.alloc, ptr, idx) catch {};
        self.bytes_allocated += size;
    }

    fn objSize(val: Value, tag: Value.Tag) usize {
        return switch (tag) {
            .string => @sizeOf(ObjString) + val.asString().chars.len,
            .struct_ => blk: {
                const s = val.asStruct();
                break :blk (ObjStruct.header_slots + s.field_count) * @sizeOf(Value);
            },
            .array => @sizeOf(ObjArray) + val.asArray().capacity * @sizeOf(Value),
            .enum_ => @sizeOf(ObjEnum) + val.asEnum().payloads.len * @sizeOf(Value),
            .closure => @sizeOf(ObjClosure) + val.asClosure().upvalues.len * @sizeOf(Value),
            .error_val => @sizeOf(ObjError),
            .map => @sizeOf(ObjMap) + val.asMap().count() * (@sizeOf(Value) + 32),
            else => 0,
        };
    }

    pub fn maybeCollect(self: *GC, stack: []const Value, globals: anytype, frames: anytype, frame_count: usize) void {
        if (!self.enabled or self.paused) return;
        if (self.bytes_allocated < self.next_threshold) return;
        self.collect(stack, globals, frames, frame_count);
    }

    pub fn collect(self: *GC, stack: []const Value, globals: anytype, frames: anytype, frame_count: usize) void {
        for (self.objects.items) |*obj| {
            obj.marked = false;
        }

        self.mark_stack.clearRetainingCapacity();

        for (stack) |val| self.markValue(val);

        var git = globals.iterator();
        while (git.next()) |entry| {
            self.markValue(entry.value_ptr.*);
        }

        for (frames[0..frame_count]) |frame| {
            if (frame.closure) |cl| self.markValue(cl.toValue());
        }

        while (self.mark_stack.items.len > 0) {
            const val = self.mark_stack.items[self.mark_stack.items.len - 1];
            self.mark_stack.items.len -= 1;
            self.traceValue(val);
        }

        self.sweep();
        self.next_threshold = @max(INITIAL_THRESHOLD, self.bytes_allocated * GROWTH_FACTOR);
        self.collections += 1;
    }

    fn markValue(self: *GC, val: Value) void {
        const tag = val.tag();
        switch (tag) {
            .string, .struct_, .enum_, .array, .closure, .error_val, .map => {},
            else => return,
        }
        const ptr = val.payload();
        const idx = self.ptr_map.get(ptr) orelse return;
        const obj = &self.objects.items[idx];
        if (!obj.marked) {
            obj.marked = true;
            self.mark_stack.append(self.alloc, val) catch {};
        }
    }

    fn traceValue(self: *GC, val: Value) void {
        switch (val.tag()) {
            .struct_ => {
                const s = val.asStruct();
                const fv = s.fieldValues();
                for (0..s.field_count) |i| self.markValue(fv[i]);
            },
            .array => {
                const arr = val.asArray();
                for (arr.items) |item| self.markValue(item);
            },
            .closure => {
                const cl = val.asClosure();
                self.markValue(Value.initFunction(cl.function));
                for (cl.upvalues) |uv| self.markValue(uv);
            },
            .enum_ => {
                const e = val.asEnum();
                for (e.payloads) |p| self.markValue(p);
            },
            .map => {
                const m = val.asMap();
                var it = m.entries.iterator();
                while (it.next()) |entry| {
                    self.markValue(entry.value_ptr.*);
                }
            },
            .error_val => {
                self.markValue(val.asError().value);
            },
            else => {},
        }
    }

    fn sweep(self: *GC) void {
        var i: usize = 0;
        while (i < self.objects.items.len) {
            if (self.objects.items[i].marked) {
                i += 1;
            } else {
                const obj = self.objects.items[i];
                _ = self.ptr_map.remove(obj.ptr);
                self.freeObj(obj);
                const last = self.objects.items.len - 1;
                if (i < last) {
                    self.objects.items[i] = self.objects.items[last];
                    self.ptr_map.put(self.alloc, self.objects.items[i].ptr, @intCast(i)) catch {};
                }
                self.objects.items.len -= 1;
            }
        }
    }

    fn freeObj(self: *GC, obj: GcObj) void {
        const a = self.alloc;
        var freed: usize = 0;
        switch (obj.tag) {
            .string => {
                const s: *ObjString = @ptrCast(@alignCast(@as(*anyopaque, @ptrFromInt(obj.ptr))));
                freed = @sizeOf(ObjString) + s.chars.len;
                if (s.chars.len > 0) a.free(@constCast(s.chars));
                a.destroy(s);
            },
            .array => {
                const arr: *ObjArray = @ptrCast(@alignCast(@as(*anyopaque, @ptrFromInt(obj.ptr))));
                freed = @sizeOf(ObjArray) + arr.capacity * @sizeOf(Value);
                if (arr.capacity > 0) a.free(arr.items.ptr[0..arr.capacity]);
                a.destroy(arr);
            },
            .struct_ => {
                const s: *ObjStruct = @ptrCast(@alignCast(@as(*anyopaque, @ptrFromInt(obj.ptr))));
                const total = ObjStruct.header_slots + s.field_count;
                freed = total * @sizeOf(Value);
                const buf: [*]Value = @ptrCast(@alignCast(@as([*]u8, @ptrCast(s))));
                a.free(buf[0..total]);
            },
            .enum_ => {
                const e: *ObjEnum = @ptrCast(@alignCast(@as(*anyopaque, @ptrFromInt(obj.ptr))));
                freed = @sizeOf(ObjEnum) + e.payloads.len * @sizeOf(Value);
                if (e.payloads.len > 0) a.free(e.payloads);
                a.destroy(e);
            },
            .closure => {
                const cl: *ObjClosure = @ptrCast(@alignCast(@as(*anyopaque, @ptrFromInt(obj.ptr))));
                freed = @sizeOf(ObjClosure) + cl.upvalues.len * @sizeOf(Value);
                if (cl.upvalues.len > 0) a.free(cl.upvalues);
                a.destroy(cl);
            },
            .map => {
                const m: *ObjMap = @ptrCast(@alignCast(@as(*anyopaque, @ptrFromInt(obj.ptr))));
                freed = @sizeOf(ObjMap) + m.count() * (@sizeOf(Value) + 32);
                m.deinit(a);
                a.destroy(m);
            },
            .error_val => {
                const e: *ObjError = @ptrCast(@alignCast(@as(*anyopaque, @ptrFromInt(obj.ptr))));
                freed = @sizeOf(ObjError);
                a.destroy(e);
            },
            else => {},
        }
        self.bytes_allocated -|= freed;
    }
};

test "gc: track and count objects" {
    const alloc = std.testing.allocator;
    var gc_state = GC.init(alloc);
    defer gc_state.deinit();

    const s = ObjString.create(alloc, "hello");
    defer alloc.destroy(s);
    gc_state.track(s.toValue());
    try std.testing.expectEqual(@as(usize, 1), gc_state.objects.items.len);

    gc_state.track(Value.initInt(42));
    try std.testing.expectEqual(@as(usize, 1), gc_state.objects.items.len);
}
