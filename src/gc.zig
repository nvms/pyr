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

pub const GC = struct {
    objects: std.ArrayListUnmanaged(GcObj),
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
        self.mark_stack.deinit(self.alloc);
    }

    pub fn track(self: *GC, val: Value) void {
        const tag = val.tag();
        switch (tag) {
            .string, .function, .struct_, .enum_, .array, .closure, .native_fn, .error_val => {},
            else => return,
        }
        self.objects.append(self.alloc, .{
            .ptr = val.payload(),
            .tag = tag,
            .marked = false,
        }) catch {};
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
            self.markValue(Value.initFunction(frame.function));
            if (frame.closure) |cl| self.markValue(cl.toValue());
        }

        while (self.mark_stack.items.len > 0) {
            self.mark_stack.items.len -= 1;
            const val = self.mark_stack.items[self.mark_stack.items.len];
            self.traceValue(val);
        }

        self.sweep();
        self.next_threshold = @max(INITIAL_THRESHOLD, self.bytes_allocated * GROWTH_FACTOR);
        self.collections += 1;
    }

    fn markValue(self: *GC, val: Value) void {
        const tag = val.tag();
        switch (tag) {
            .string, .function, .struct_, .enum_, .array, .closure, .native_fn, .error_val => {},
            else => return,
        }
        const ptr = val.payload();
        for (self.objects.items) |*obj| {
            if (obj.ptr == ptr and obj.tag == tag) {
                if (!obj.marked) {
                    obj.marked = true;
                    self.mark_stack.append(self.alloc, val) catch {};
                }
                return;
            }
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
                self.freeObj(self.objects.items[i]);
                self.objects.items[i] = self.objects.items[self.objects.items.len - 1];
                self.objects.items.len -= 1;
            }
        }
    }

    fn freeObj(self: *GC, obj: GcObj) void {
        const a = self.alloc;
        switch (obj.tag) {
            .string => {
                const s: *ObjString = @ptrCast(@alignCast(@as(*anyopaque, @ptrFromInt(obj.ptr))));
                if (s.chars.len > 0) a.free(@constCast(s.chars));
                a.destroy(s);
            },
            .array => {
                const arr: *ObjArray = @ptrCast(@alignCast(@as(*anyopaque, @ptrFromInt(obj.ptr))));
                if (arr.capacity > 0) a.free(arr.items.ptr[0..arr.capacity]);
                a.destroy(arr);
            },
            .struct_ => {
                const s: *ObjStruct = @ptrCast(@alignCast(@as(*anyopaque, @ptrFromInt(obj.ptr))));
                const total = ObjStruct.header_slots + s.field_count;
                const buf: [*]Value = @ptrCast(@alignCast(@as([*]u8, @ptrCast(s))));
                a.free(buf[0..total]);
            },
            .enum_ => {
                const e: *ObjEnum = @ptrCast(@alignCast(@as(*anyopaque, @ptrFromInt(obj.ptr))));
                if (e.payloads.len > 0) a.free(e.payloads);
                a.destroy(e);
            },
            .closure => {
                const cl: *ObjClosure = @ptrCast(@alignCast(@as(*anyopaque, @ptrFromInt(obj.ptr))));
                if (cl.upvalues.len > 0) a.free(cl.upvalues);
                a.destroy(cl);
            },
            .error_val => {
                const e: *ObjError = @ptrCast(@alignCast(@as(*anyopaque, @ptrFromInt(obj.ptr))));
                a.destroy(e);
            },
            else => {},
        }
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
