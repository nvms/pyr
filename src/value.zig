const std = @import("std");

pub const Value = struct {
    bits: u64,

    const QNAN: u64 = 0x7FFC_0000_0000_0000;
    const SIGN: u64 = 0x8000_0000_0000_0000;
    const TAG_SHIFT: u6 = 47;
    const PAYLOAD_MASK: u64 = (@as(u64, 1) << 47) - 1;

    pub const Tag = enum(u5) {
        nil = 0,
        bool_ = 1,
        int = 2,
        string = 3,
        function = 4,
        struct_ = 5,
        enum_ = 6,
        array = 7,
        closure = 8,
        native_fn = 9,
        task = 10,
        channel = 11,
        error_val = 12,
        conn = 13,
        ptr = 14,
        ext = 15,
        float = 16,
    };

    pub const ExtKind = enum(u3) { listener, dgram, tls_conn, ssl_ctx, ssl_conn };

    fn encode(t: Tag, val: u64) Value {
        const tv: u64 = @intFromEnum(t);
        const hi: u64 = (tv >> 3) & 1;
        const lo: u64 = tv & 0x7;
        return .{ .bits = (hi * SIGN) | QNAN | (lo << TAG_SHIFT) | (val & PAYLOAD_MASK) };
    }

    fn encodeExt(kind: ExtKind, ptr_val: usize) Value {
        const tagged_ptr = (ptr_val & ~@as(u64, 0x7)) | @intFromEnum(kind);
        return encode(.ext, tagged_ptr);
    }

    pub fn tag(self: Value) Tag {
        if ((self.bits & QNAN) != QNAN) return .float;
        const hi: u5 = @truncate((self.bits >> 63) & 1);
        const lo: u5 = @truncate((self.bits >> TAG_SHIFT) & 0x7);
        return @enumFromInt((hi << 3) | lo);
    }

    pub fn isExt(self: Value) bool {
        return self.tag() == .ext;
    }

    pub fn extKind(self: Value) ExtKind {
        return @enumFromInt(@as(u3, @truncate(self.payload())));
    }

    fn extPtr(self: Value) *anyopaque {
        return @ptrFromInt(self.payload() & ~@as(u64, 0x7));
    }

    pub fn initNil() Value {
        return encode(.nil, 0);
    }

    pub fn initBool(v: bool) Value {
        return encode(.bool_, @intFromBool(v));
    }

    pub fn initInt(v: i64) Value {
        return encode(.int, @bitCast(v));
    }

    pub fn initFloat(v: f64) Value {
        const b: u64 = @bitCast(v);
        if ((b & QNAN) == QNAN) return .{ .bits = 0x7FF8_0000_0000_0000 };
        return .{ .bits = b };
    }

    pub fn initString(p: *ObjString) Value {
        return encode(.string, @intFromPtr(p));
    }

    pub fn initFunction(p: *ObjFunction) Value {
        return encode(.function, @intFromPtr(p));
    }

    pub fn initStruct(p: *ObjStruct) Value {
        return encode(.struct_, @intFromPtr(p));
    }

    pub fn initEnum(p: *ObjEnum) Value {
        return encode(.enum_, @intFromPtr(p));
    }

    pub fn initNativeFn(p: *ObjNativeFn) Value {
        return encode(.native_fn, @intFromPtr(p));
    }

    pub fn initClosure(p: *ObjClosure) Value {
        return encode(.closure, @intFromPtr(p));
    }

    pub fn initArray(p: *ObjArray) Value {
        return encode(.array, @intFromPtr(p));
    }

    pub fn initTask(p: *ObjTask) Value {
        return encode(.task, @intFromPtr(p));
    }

    pub fn initChannel(p: *ObjChannel) Value {
        return encode(.channel, @intFromPtr(p));
    }

    pub fn initListener(p: *ObjListener) Value {
        return encodeExt(.listener, @intFromPtr(p));
    }

    pub fn initConn(p: *ObjConn) Value {
        return encode(.conn, @intFromPtr(p));
    }

    pub fn initDgram(p: *ObjDgram) Value {
        return encodeExt(.dgram, @intFromPtr(p));
    }

    pub fn initTlsConn(p: *ObjTlsConn) Value {
        return encodeExt(.tls_conn, @intFromPtr(p));
    }

    pub fn initSslCtx(p: *ObjSslCtx) Value {
        return encodeExt(.ssl_ctx, @intFromPtr(p));
    }

    pub fn initSslConn(p: *ObjSslConn) Value {
        return encodeExt(.ssl_conn, @intFromPtr(p));
    }

    pub fn initPtr(p: usize) Value {
        return encode(.ptr, p);
    }

    pub fn initError(p: *ObjError) Value {
        return encode(.error_val, @intFromPtr(p));
    }

    fn payload(self: Value) u64 {
        return self.bits & PAYLOAD_MASK;
    }

    fn ptrFromPayload(self: Value) *anyopaque {
        return @ptrFromInt(self.payload());
    }

    pub fn asError(self: Value) *ObjError {
        return @ptrCast(@alignCast(self.ptrFromPayload()));
    }

    pub fn asPtr(self: Value) usize {
        return self.payload();
    }

    pub fn asBool(self: Value) bool {
        return self.payload() != 0;
    }

    pub fn asInt(self: Value) i64 {
        const raw = self.payload();
        const shift: u6 = 64 - 47;
        return @as(i64, @bitCast(raw << shift)) >> shift;
    }

    pub fn asFloat(self: Value) f64 {
        return @bitCast(self.bits);
    }

    pub fn asString(self: Value) *ObjString {
        return @ptrCast(@alignCast(self.ptrFromPayload()));
    }

    pub fn asFunction(self: Value) *ObjFunction {
        return @ptrCast(@alignCast(self.ptrFromPayload()));
    }

    pub fn asStruct(self: Value) *ObjStruct {
        return @ptrCast(@alignCast(self.ptrFromPayload()));
    }

    pub fn asEnum(self: Value) *ObjEnum {
        return @ptrCast(@alignCast(self.ptrFromPayload()));
    }

    pub fn asNativeFn(self: Value) *ObjNativeFn {
        return @ptrCast(@alignCast(self.ptrFromPayload()));
    }

    pub fn asClosure(self: Value) *ObjClosure {
        return @ptrCast(@alignCast(self.ptrFromPayload()));
    }

    pub fn asArray(self: Value) *ObjArray {
        return @ptrCast(@alignCast(self.ptrFromPayload()));
    }

    pub fn asTask(self: Value) *ObjTask {
        return @ptrCast(@alignCast(self.ptrFromPayload()));
    }

    pub fn asChannel(self: Value) *ObjChannel {
        return @ptrCast(@alignCast(self.ptrFromPayload()));
    }

    pub fn asListener(self: Value) *ObjListener {
        return @ptrCast(@alignCast(self.extPtr()));
    }

    pub fn asConn(self: Value) *ObjConn {
        return @ptrCast(@alignCast(self.ptrFromPayload()));
    }

    pub fn asDgram(self: Value) *ObjDgram {
        return @ptrCast(@alignCast(self.extPtr()));
    }

    pub fn asTlsConn(self: Value) *ObjTlsConn {
        return @ptrCast(@alignCast(self.extPtr()));
    }

    pub fn asSslCtx(self: Value) *ObjSslCtx {
        return @ptrCast(@alignCast(self.extPtr()));
    }

    pub fn asSslConn(self: Value) *ObjSslConn {
        return @ptrCast(@alignCast(self.extPtr()));
    }

    pub fn isTruthy(self: Value) bool {
        return switch (self.tag()) {
            .nil => false,
            .bool_ => self.asBool(),
            .int => self.asInt() != 0,
            .float => self.asFloat() != 0.0,
            .string, .function, .struct_, .enum_, .native_fn, .closure, .array, .task, .channel, .conn, .ext => true,
            .ptr => self.payload() != 0,
            .error_val => false,
        };
    }

    pub fn eql(a: Value, b: Value) bool {
        if (a.tag() != b.tag()) return false;
        return switch (a.tag()) {
            .nil => true,
            .bool_, .int => a.bits == b.bits,
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
            .array => {
                const aa = a.asArray();
                const ba = b.asArray();
                if (aa.items.len != ba.items.len) return false;
                for (aa.items, ba.items) |av, bv| {
                    if (!eql(av, bv)) return false;
                }
                return true;
            },
            .error_val => eql(a.asError().value, b.asError().value),
            else => a.bits == b.bits,
        };
    }

    pub fn deepClone(self: Value, alloc: std.mem.Allocator) Value {
        switch (self.tag()) {
            .struct_ => {
                const s = self.asStruct();
                const fv = s.fieldValues();
                const cloned_fields = alloc.alloc(Value, s.field_count) catch @panic("oom");
                for (0..s.field_count) |i| {
                    cloned_fields[i] = fv[i].deepClone(alloc);
                }
                return ObjStruct.create(alloc, s.name, s.field_names, cloned_fields).toValue();
            },
            .array => {
                const a = self.asArray();
                const cloned_items = alloc.alloc(Value, a.items.len) catch @panic("oom");
                for (a.items, 0..) |item, i| {
                    cloned_items[i] = item.deepClone(alloc);
                }
                return ObjArray.create(alloc, cloned_items).toValue();
            },
            .enum_ => {
                const e = self.asEnum();
                const cloned_payloads = alloc.alloc(Value, e.payloads.len) catch @panic("oom");
                for (e.payloads, 0..) |p, i| {
                    cloned_payloads[i] = p.deepClone(alloc);
                }
                return ObjEnum.create(alloc, e.type_name, e.variant, e.variant_index, cloned_payloads).toValue();
            },
            .string => {
                const s = self.asString();
                const chars_copy = alloc.dupe(u8, s.chars) catch @panic("oom");
                return ObjString.create(alloc, chars_copy).toValue();
            },
            else => return self,
        }
    }

    pub fn deepFree(self: Value, alloc: std.mem.Allocator) void {
        // shallow free: only frees the container, not its contents.
        // struct fields, array elements, and enum payloads may contain
        // constant pool values or shared references that we don't own
        switch (self.tag()) {
            .struct_ => {
                const s = self.asStruct();
                const total = ObjStruct.header_slots + s.field_count;
                const buf: [*]Value = @ptrCast(@alignCast(@as([*]u8, @ptrCast(s))));
                alloc.free(buf[0..total]);
            },
            .array => {
                const a = self.asArray();
                if (a.capacity > 0) alloc.free(a.items.ptr[0..a.capacity]);
                alloc.destroy(a);
            },
            .enum_ => {
                const e = self.asEnum();
                if (e.payloads.len > 0) alloc.free(e.payloads);
                alloc.destroy(e);
            },
            .closure => {
                const c = self.asClosure();
                if (c.upvalues.len > 0) alloc.free(c.upvalues);
                alloc.destroy(c);
            },
            .error_val => {
                const e = self.asError();
                alloc.destroy(e);
            },
            else => {},
        }
    }

    pub fn dump(self: Value) void {
        switch (self.tag()) {
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
            .conn => std.debug.print("<conn>", .{}),
            .ptr => std.debug.print("<ptr 0x{x}>", .{self.payload()}),
            .ext => std.debug.print("<{s}>", .{@tagName(self.extKind())}),
            .error_val => {
                std.debug.print("error(", .{});
                self.asError().value.dump();
                std.debug.print(")", .{});
            },
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

pub const ObjError = struct {
    value: Value,

    pub fn create(alloc: std.mem.Allocator, value: Value) *ObjError {
        const e = alloc.create(ObjError) catch @panic("oom");
        e.* = .{ .value = value };
        return e;
    }

    pub fn toValue(self: *ObjError) Value {
        return Value.initError(self);
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
    arena_stack: *ArenaStack,
    concat: *ConcatState,

    const CallFrame = @import("vm.zig").VM.CallFrame;
    const ArenaStack = @import("vm.zig").ArenaStack;
    const ConcatState = @import("vm.zig").ConcatState;

    pub fn create(alloc: std.mem.Allocator, func: *ObjFunction, closure: ?*ObjClosure) *ObjTask {
        const stack_size: usize = 256;
        const max_frames: usize = 64;
        const stack = alloc.alloc(Value, stack_size) catch @panic("oom");
        const frames = alloc.alloc(CallFrame, max_frames) catch @panic("oom");
        const as = alloc.create(ArenaStack) catch @panic("oom");
        as.* = ArenaStack.init(alloc);
        const cs = alloc.create(ConcatState) catch @panic("oom");
        cs.* = ConcatState.init();
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
            .arena_stack = as,
            .concat = cs,
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
    timeout_ms: i32,
    _align: usize = 0,

    pub fn create(alloc: std.mem.Allocator, fd: std.posix.fd_t, port: u16) *ObjListener {
        const l = alloc.create(ObjListener) catch @panic("oom");
        l.* = .{ .fd = fd, .port = port, .timeout_ms = -1 };
        return l;
    }

    pub fn toValue(self: *ObjListener) Value {
        return Value.initListener(self);
    }
};

pub const ObjConn = struct {
    fd: std.posix.fd_t,
    nonblock: bool,
    timeout_ms: i32,

    pub fn create(alloc: std.mem.Allocator, fd: std.posix.fd_t) *ObjConn {
        const c = alloc.create(ObjConn) catch @panic("oom");
        c.* = .{ .fd = fd, .nonblock = false, .timeout_ms = -1 };
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

pub const ObjDgram = struct {
    fd: std.posix.fd_t,
    timeout_ms: i32,
    bound: bool,
    _align: usize = 0,

    pub fn create(alloc: std.mem.Allocator, fd: std.posix.fd_t, bound: bool) *ObjDgram {
        const d = alloc.create(ObjDgram) catch @panic("oom");
        d.* = .{ .fd = fd, .timeout_ms = -1, .bound = bound };
        return d;
    }

    pub fn ensureNonBlock(self: *ObjDgram) void {
        const flags = std.posix.fcntl(self.fd, std.posix.F.GETFL, 0) catch return;
        const o_flags: std.posix.O = @bitCast(@as(u32, @truncate(flags)));
        var new_flags = o_flags;
        new_flags.NONBLOCK = true;
        _ = std.posix.fcntl(self.fd, std.posix.F.SETFL, @as(usize, @as(u32, @bitCast(new_flags)))) catch return;
    }

    pub fn toValue(self: *ObjDgram) Value {
        return Value.initDgram(self);
    }
};

pub const ObjTlsConn = struct {
    fd: std.posix.fd_t,
    client: std.crypto.tls.Client,
    stream_reader: std.net.Stream.Reader,
    stream_writer: std.net.Stream.Writer,
    timeout_ms: i32,
    read_buf: []u8,
    write_buf: []u8,
    stream_read_buf: []u8,
    stream_write_buf: []u8,

    pub fn toValue(self: *ObjTlsConn) Value {
        return Value.initTlsConn(self);
    }
};

pub const ObjSslCtx = struct {
    ctx: *anyopaque,

    pub fn toValue(self: *ObjSslCtx) Value {
        return Value.initSslCtx(self);
    }
};

pub const ObjSslConn = struct {
    fd: std.posix.fd_t,
    ssl: *anyopaque,
    timeout_ms: i32,

    pub fn toValue(self: *ObjSslConn) Value {
        return Value.initSslConn(self);
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

test "value: negative int round-trip" {
    const v = Value.initInt(-1);
    try std.testing.expectEqual(@as(i64, -1), v.asInt());
}

test "value: large int round-trip" {
    const v = Value.initInt(1_000_000_000_000);
    try std.testing.expectEqual(@as(i64, 1_000_000_000_000), v.asInt());
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

test "value: tag detection" {
    try std.testing.expectEqual(Value.Tag.nil, Value.initNil().tag());
    try std.testing.expectEqual(Value.Tag.bool_, Value.initBool(true).tag());
    try std.testing.expectEqual(Value.Tag.int, Value.initInt(42).tag());
    try std.testing.expectEqual(Value.Tag.float, Value.initFloat(3.14).tag());
}

test "value: size is 8 bytes" {
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(Value));
}

test "value: ext round-trip" {
    const alloc = std.testing.allocator;
    const listener = ObjListener.create(alloc, 42, 8080);
    defer alloc.destroy(listener);
    const v = Value.initListener(listener);
    try std.testing.expectEqual(Value.Tag.ext, v.tag());
    try std.testing.expectEqual(Value.ExtKind.listener, v.extKind());
    try std.testing.expectEqual(@as(std.posix.fd_t, 42), v.asListener().fd);
}
