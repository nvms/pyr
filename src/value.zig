const std = @import("std");

pub const Value = struct {
    tag: Tag,
    data: u64,

    pub const Tag = enum(u8) {
        nil,
        bool_,
        int,
        float,
        string,
        function,
        struct_,
        enum_,
        native_fn,
        closure,
        array,
        task,
        channel,
        listener,
        conn,
        ptr,
    };

    pub fn initNil() Value {
        return .{ .tag = .nil, .data = 0 };
    }

    pub fn initBool(v: bool) Value {
        return .{ .tag = .bool_, .data = @intFromBool(v) };
    }

    pub fn initInt(v: i64) Value {
        return .{ .tag = .int, .data = @bitCast(v) };
    }

    pub fn initFloat(v: f64) Value {
        return .{ .tag = .float, .data = @bitCast(v) };
    }

    pub fn initString(ptr: *ObjString) Value {
        return .{ .tag = .string, .data = @intFromPtr(ptr) };
    }

    pub fn initFunction(ptr: *ObjFunction) Value {
        return .{ .tag = .function, .data = @intFromPtr(ptr) };
    }

    pub fn initStruct(ptr: *ObjStruct) Value {
        return .{ .tag = .struct_, .data = @intFromPtr(ptr) };
    }

    pub fn initEnum(ptr: *ObjEnum) Value {
        return .{ .tag = .enum_, .data = @intFromPtr(ptr) };
    }

    pub fn initNativeFn(ptr: *ObjNativeFn) Value {
        return .{ .tag = .native_fn, .data = @intFromPtr(ptr) };
    }

    pub fn initClosure(ptr: *ObjClosure) Value {
        return .{ .tag = .closure, .data = @intFromPtr(ptr) };
    }

    pub fn initArray(ptr: *ObjArray) Value {
        return .{ .tag = .array, .data = @intFromPtr(ptr) };
    }

    pub fn initTask(ptr: *ObjTask) Value {
        return .{ .tag = .task, .data = @intFromPtr(ptr) };
    }

    pub fn initChannel(ptr: *ObjChannel) Value {
        return .{ .tag = .channel, .data = @intFromPtr(ptr) };
    }

    pub fn initListener(ptr: *ObjListener) Value {
        return .{ .tag = .listener, .data = @intFromPtr(ptr) };
    }

    pub fn initConn(p: *ObjConn) Value {
        return .{ .tag = .conn, .data = @intFromPtr(p) };
    }

    pub fn initPtr(p: usize) Value {
        return .{ .tag = .ptr, .data = p };
    }

    pub fn asPtr(self: Value) usize {
        return self.data;
    }

    pub fn asBool(self: Value) bool {
        return self.data != 0;
    }

    pub fn asInt(self: Value) i64 {
        return @bitCast(self.data);
    }

    pub fn asFloat(self: Value) f64 {
        return @bitCast(self.data);
    }

    pub fn asString(self: Value) *ObjString {
        return @ptrCast(@alignCast(@as(*anyopaque, @ptrFromInt(self.data))));
    }

    pub fn asFunction(self: Value) *ObjFunction {
        return @ptrCast(@alignCast(@as(*anyopaque, @ptrFromInt(self.data))));
    }

    pub fn asStruct(self: Value) *ObjStruct {
        return @ptrCast(@alignCast(@as(*anyopaque, @ptrFromInt(self.data))));
    }

    pub fn asEnum(self: Value) *ObjEnum {
        return @ptrCast(@alignCast(@as(*anyopaque, @ptrFromInt(self.data))));
    }

    pub fn asNativeFn(self: Value) *ObjNativeFn {
        return @ptrCast(@alignCast(@as(*anyopaque, @ptrFromInt(self.data))));
    }

    pub fn asClosure(self: Value) *ObjClosure {
        return @ptrCast(@alignCast(@as(*anyopaque, @ptrFromInt(self.data))));
    }

    pub fn asArray(self: Value) *ObjArray {
        return @ptrCast(@alignCast(@as(*anyopaque, @ptrFromInt(self.data))));
    }

    pub fn asTask(self: Value) *ObjTask {
        return @ptrCast(@alignCast(@as(*anyopaque, @ptrFromInt(self.data))));
    }

    pub fn asChannel(self: Value) *ObjChannel {
        return @ptrCast(@alignCast(@as(*anyopaque, @ptrFromInt(self.data))));
    }

    pub fn asListener(self: Value) *ObjListener {
        return @ptrCast(@alignCast(@as(*anyopaque, @ptrFromInt(self.data))));
    }

    pub fn asConn(self: Value) *ObjConn {
        return @ptrCast(@alignCast(@as(*anyopaque, @ptrFromInt(self.data))));
    }

    pub fn isTruthy(self: Value) bool {
        return switch (self.tag) {
            .nil => false,
            .bool_ => self.asBool(),
            .int => self.asInt() != 0,
            .float => self.asFloat() != 0.0,
            .string, .function, .struct_, .enum_, .native_fn, .closure, .array, .task, .channel, .listener, .conn => true,
            .ptr => self.data != 0,
        };
    }

    pub fn eql(a: Value, b: Value) bool {
        if (a.tag != b.tag) return false;
        return switch (a.tag) {
            .nil => true,
            .bool_ => a.asBool() == b.asBool(),
            .int => a.asInt() == b.asInt(),
            .float => a.asFloat() == b.asFloat(),
            .string => std.mem.eql(u8, a.asString().chars, b.asString().chars),
            .enum_ => {
                const ae = a.asEnum();
                const be = b.asEnum();
                if (ae.variant_index != be.variant_index) return false;
                if (!std.mem.eql(u8, ae.type_name, be.type_name)) return false;
                if (ae.payloads.len != be.payloads.len) return false;
                for (ae.payloads, be.payloads) |ap, bp| {
                    if (!eql(ap, bp)) return false;
                }
                return true;
            },
            .function, .struct_, .native_fn, .closure, .task, .channel, .listener, .conn, .ptr => a.data == b.data,
            .array => {
                const aa = a.asArray();
                const ba = b.asArray();
                if (aa.items.len != ba.items.len) return false;
                for (aa.items, ba.items) |av, bv| {
                    if (!eql(av, bv)) return false;
                }
                return true;
            },
        };
    }

    pub fn dump(self: Value) void {
        switch (self.tag) {
            .nil => std.debug.print("nil", .{}),
            .bool_ => std.debug.print("{}", .{self.asBool()}),
            .int => std.debug.print("{d}", .{self.asInt()}),
            .float => std.debug.print("{d}", .{self.asFloat()}),
            .string => std.debug.print("{s}", .{self.asString().chars}),
            .function => std.debug.print("<fn {s}>", .{self.asFunction().name}),
            .struct_ => {
                const s = self.asStruct();
                std.debug.print("{s} {{ ", .{s.name});
                const fv = s.fieldValues();
                for (s.field_names, 0..) |name, i| {
                    if (i > 0) std.debug.print(", ", .{});
                    std.debug.print("{s}: ", .{name});
                    fv[i].dump();
                }
                std.debug.print(" }}", .{});
            },
            .enum_ => {
                const e = self.asEnum();
                std.debug.print("{s}", .{e.variant});
                if (e.payloads.len > 0) {
                    std.debug.print("(", .{});
                    for (e.payloads, 0..) |val, i| {
                        if (i > 0) std.debug.print(", ", .{});
                        val.dump();
                    }
                    std.debug.print(")", .{});
                }
            },
            .native_fn => std.debug.print("<native fn>", .{}),
            .closure => std.debug.print("<closure>", .{}),
            .task => std.debug.print("<task>", .{}),
            .channel => std.debug.print("<channel>", .{}),
            .listener => std.debug.print("<listener>", .{}),
            .conn => std.debug.print("<conn>", .{}),
            .ptr => std.debug.print("<ptr 0x{x}>", .{self.data}),
            .array => {
                const arr = self.asArray();
                std.debug.print("[", .{});
                for (arr.items, 0..) |item, i| {
                    if (i > 0) std.debug.print(", ", .{});
                    item.dump();
                }
                std.debug.print("]", .{});
            },
        }
    }
};

pub const ObjString = struct {
    chars: []const u8,

    pub fn create(alloc: std.mem.Allocator, chars: []const u8) *ObjString {
        const str = alloc.create(ObjString) catch @panic("oom");
        str.* = .{ .chars = chars };
        return str;
    }

    pub fn toValue(self: *ObjString) Value {
        return Value.initString(self);
    }
};

pub const ObjStruct = struct {
    name: []const u8,
    field_names: []const []const u8,
    field_count: u8,

    const header_slots = (@sizeOf(ObjStruct) + @sizeOf(Value) - 1) / @sizeOf(Value);

    pub fn fieldValues(self: *ObjStruct) [*]Value {
        const base: [*]Value = @ptrCast(@alignCast(@as([*]u8, @ptrCast(self))));
        return base + header_slots;
    }

    pub fn create(alloc: std.mem.Allocator, name: []const u8, field_names: []const []const u8, values: []Value) *ObjStruct {
        const buf = alloc.alloc(Value, header_slots + values.len) catch @panic("oom");
        const self: *ObjStruct = @ptrCast(&buf[0]);
        self.* = .{ .name = name, .field_names = field_names, .field_count = @intCast(values.len) };
        const fv = self.fieldValues();
        for (values, 0..) |v, i| {
            fv[i] = v;
        }
        return self;
    }

    pub fn getField(self: *ObjStruct, name: []const u8) ?Value {
        for (self.field_names, 0..) |fname, i| {
            if (std.mem.eql(u8, fname, name)) return self.fieldValues()[i];
        }
        return null;
    }

    pub fn setField(self: *ObjStruct, name: []const u8, val: Value) bool {
        for (self.field_names, 0..) |fname, i| {
            if (std.mem.eql(u8, fname, name)) {
                self.fieldValues()[i] = val;
                return true;
            }
        }
        return false;
    }

    pub fn toValue(self: *ObjStruct) Value {
        return Value.initStruct(self);
    }
};

pub const ObjEnum = struct {
    type_name: []const u8,
    variant: []const u8,
    variant_index: u8,
    payloads: []Value,

    pub fn create(alloc: std.mem.Allocator, type_name: []const u8, variant: []const u8, variant_index: u8, payloads: []Value) *ObjEnum {
        const e = alloc.create(ObjEnum) catch @panic("oom");
        e.* = .{ .type_name = type_name, .variant = variant, .variant_index = variant_index, .payloads = payloads };
        return e;
    }

    pub fn toValue(self: *ObjEnum) Value {
        return Value.initEnum(self);
    }
};

pub const ObjNativeFn = struct {
    name: []const u8,
    arity: u8,
    func: *const fn (std.mem.Allocator, []const Value) Value,

    pub fn create(alloc: std.mem.Allocator, name: []const u8, arity: u8, func: *const fn (std.mem.Allocator, []const Value) Value) *ObjNativeFn {
        const nf = alloc.create(ObjNativeFn) catch @panic("oom");
        nf.* = .{ .name = name, .arity = arity, .func = func };
        return nf;
    }

    pub fn toValue(self: *ObjNativeFn) Value {
        return Value.initNativeFn(self);
    }
};

pub const ObjClosure = struct {
    function: *ObjFunction,
    upvalues: []Value,

    pub fn create(alloc: std.mem.Allocator, function: *ObjFunction, upvalues: []Value) *ObjClosure {
        const c = alloc.create(ObjClosure) catch @panic("oom");
        c.* = .{ .function = function, .upvalues = upvalues };
        return c;
    }

    pub fn toValue(self: *ObjClosure) Value {
        return Value.initClosure(self);
    }
};

pub const ObjArray = struct {
    items: []Value,
    capacity: usize,

    pub fn create(alloc: std.mem.Allocator, initial: []const Value) *ObjArray {
        const arr = alloc.create(ObjArray) catch @panic("oom");
        if (initial.len > 0) {
            const items = alloc.alloc(Value, initial.len) catch @panic("oom");
            @memcpy(items, initial);
            arr.* = .{ .items = items, .capacity = initial.len };
        } else {
            arr.* = .{ .items = &.{}, .capacity = 0 };
        }
        return arr;
    }

    pub fn push(self: *ObjArray, alloc: std.mem.Allocator, val: Value) void {
        if (self.items.len == self.capacity) {
            const new_cap = if (self.capacity == 0) 8 else self.capacity * 2;
            const new_buf = alloc.alloc(Value, new_cap) catch @panic("oom");
            if (self.items.len > 0) @memcpy(new_buf[0..self.items.len], self.items);
            if (self.capacity > 0) alloc.free(self.items.ptr[0..self.capacity]);
            self.items = new_buf[0..self.items.len];
            self.capacity = new_cap;
        }
        self.items = self.items.ptr[0 .. self.items.len + 1];
        self.items[self.items.len - 1] = val;
    }

    pub fn toValue(self: *ObjArray) Value {
        return Value.initArray(self);
    }
};

pub const TaskState = enum(u8) {
    ready,
    running,
    blocked_send,
    blocked_recv,
    blocked_await,
    blocked_io,
    done,
};

pub const ObjTask = struct {
    stack: []Value,
    frames: []CallFrame,
    frame_count: usize,
    sp: usize,
    state: TaskState,
    result: Value,
    waiting_on: ?*ObjTask,
    pending_send: Value,

    const CallFrame = @import("vm.zig").VM.CallFrame;

    pub fn create(alloc: std.mem.Allocator, func: *ObjFunction, closure: ?*ObjClosure) *ObjTask {
        const stack_size: usize = 256;
        const max_frames: usize = 64;
        const stack = alloc.alloc(Value, stack_size) catch @panic("oom");
        const frames = alloc.alloc(CallFrame, max_frames) catch @panic("oom");
        const t = alloc.create(ObjTask) catch @panic("oom");

        stack[0] = if (closure) |cl| cl.toValue() else func.toValue();

        frames[0] = .{
            .function = func,
            .ip = 0,
            .slot_offset = 0,
            .closure = closure,
        };

        t.* = .{
            .stack = stack,
            .frames = frames,
            .frame_count = 1,
            .sp = 1,
            .state = .ready,
            .result = Value.initNil(),
            .waiting_on = null,
            .pending_send = Value.initNil(),
        };
        return t;
    }

    pub fn toValue(self: *ObjTask) Value {
        return Value.initTask(self);
    }
};

pub const ObjChannel = struct {
    buffer: []Value,
    capacity: usize,
    head: usize,
    tail: usize,
    count: usize,
    send_waiters: [16]?*ObjTask,
    send_waiter_count: u8,
    recv_waiters: [16]?*ObjTask,
    recv_waiter_count: u8,

    pub fn create(alloc: std.mem.Allocator, capacity: usize) *ObjChannel {
        const cap = if (capacity == 0) 1 else capacity;
        const buf = alloc.alloc(Value, cap) catch @panic("oom");
        const ch = alloc.create(ObjChannel) catch @panic("oom");
        ch.* = .{
            .buffer = buf,
            .capacity = cap,
            .head = 0,
            .tail = 0,
            .count = 0,
            .send_waiters = .{null} ** 16,
            .send_waiter_count = 0,
            .recv_waiters = .{null} ** 16,
            .recv_waiter_count = 0,
        };
        return ch;
    }

    pub fn trySend(self: *ObjChannel, val: Value) bool {
        if (self.count >= self.capacity) return false;
        self.buffer[self.tail] = val;
        self.tail = (self.tail + 1) % self.capacity;
        self.count += 1;
        return true;
    }

    pub fn tryRecv(self: *ObjChannel) ?Value {
        if (self.count == 0) return null;
        const val = self.buffer[self.head];
        self.head = (self.head + 1) % self.capacity;
        self.count -= 1;
        return val;
    }

    pub fn addSendWaiter(self: *ObjChannel, task: *ObjTask) void {
        if (self.send_waiter_count < 16) {
            self.send_waiters[self.send_waiter_count] = task;
            self.send_waiter_count += 1;
        }
    }

    pub fn addRecvWaiter(self: *ObjChannel, task: *ObjTask) void {
        if (self.recv_waiter_count < 16) {
            self.recv_waiters[self.recv_waiter_count] = task;
            self.recv_waiter_count += 1;
        }
    }

    pub fn popSendWaiter(self: *ObjChannel) ?*ObjTask {
        if (self.send_waiter_count == 0) return null;
        const t = self.send_waiters[0].?;
        self.send_waiter_count -= 1;
        var i: u8 = 0;
        while (i < self.send_waiter_count) : (i += 1) {
            self.send_waiters[i] = self.send_waiters[i + 1];
        }
        self.send_waiters[self.send_waiter_count] = null;
        return t;
    }

    pub fn popRecvWaiter(self: *ObjChannel) ?*ObjTask {
        if (self.recv_waiter_count == 0) return null;
        const t = self.recv_waiters[0].?;
        self.recv_waiter_count -= 1;
        var i: u8 = 0;
        while (i < self.recv_waiter_count) : (i += 1) {
            self.recv_waiters[i] = self.recv_waiters[i + 1];
        }
        self.recv_waiters[self.recv_waiter_count] = null;
        return t;
    }

    pub fn toValue(self: *ObjChannel) Value {
        return Value.initChannel(self);
    }
};

pub const ObjListener = struct {
    fd: std.posix.fd_t,
    port: u16,

    pub fn create(alloc: std.mem.Allocator, fd: std.posix.fd_t, port: u16) *ObjListener {
        const l = alloc.create(ObjListener) catch @panic("oom");
        l.* = .{ .fd = fd, .port = port };
        return l;
    }

    pub fn toValue(self: *ObjListener) Value {
        return Value.initListener(self);
    }
};

pub const ObjConn = struct {
    fd: std.posix.fd_t,
    nonblock: bool,

    pub fn create(alloc: std.mem.Allocator, fd: std.posix.fd_t) *ObjConn {
        const c = alloc.create(ObjConn) catch @panic("oom");
        c.* = .{ .fd = fd, .nonblock = false };
        return c;
    }

    pub fn ensureNonBlock(self: *ObjConn) void {
        if (!self.nonblock) {
            const flags = std.posix.fcntl(self.fd, std.posix.F.GETFL, 0) catch return;
            const o_flags: std.posix.O = @bitCast(@as(u32, @truncate(flags)));
            var new_flags = o_flags;
            new_flags.NONBLOCK = true;
            _ = std.posix.fcntl(self.fd, std.posix.F.SETFL, @as(usize, @as(u32, @bitCast(new_flags)))) catch return;
            self.nonblock = true;
        }
    }

    pub fn toValue(self: *ObjConn) Value {
        return Value.initConn(self);
    }
};

pub const ObjFunction = struct {
    name: []const u8,
    arity: u8,
    locals_only: bool,
    chunk: @import("chunk.zig").Chunk,
    source: []const u8,

    pub fn create(alloc: std.mem.Allocator, name: []const u8, arity: u8) *ObjFunction {
        const func = alloc.create(ObjFunction) catch @panic("oom");
        func.* = .{
            .name = name,
            .arity = arity,
            .locals_only = false,
            .chunk = @import("chunk.zig").Chunk.init(),
            .source = "",
        };
        return func;
    }

    pub fn toValue(self: *ObjFunction) Value {
        return Value.initFunction(self);
    }
};

test "value: int round-trip" {
    const v = Value.initInt(42);
    try std.testing.expectEqual(@as(i64, 42), v.asInt());
}

test "value: float round-trip" {
    const v = Value.initFloat(3.14);
    try std.testing.expectEqual(@as(f64, 3.14), v.asFloat());
}

test "value: bool round-trip" {
    const t = Value.initBool(true);
    const f = Value.initBool(false);
    try std.testing.expect(t.asBool());
    try std.testing.expect(!f.asBool());
}

test "value: nil is falsy" {
    try std.testing.expect(!Value.initNil().isTruthy());
}

test "value: equality" {
    try std.testing.expect(Value.eql(Value.initInt(5), Value.initInt(5)));
    try std.testing.expect(!Value.eql(Value.initInt(5), Value.initInt(6)));
    try std.testing.expect(!Value.eql(Value.initInt(5), Value.initFloat(5.0)));
}
