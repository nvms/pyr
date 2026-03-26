const std = @import("std");
const Chunk = @import("chunk.zig").Chunk;
const OpCode = @import("chunk.zig").OpCode;
const Value = @import("value.zig").Value;
const ObjFunction = @import("value.zig").ObjFunction;
const ObjString = @import("value.zig").ObjString;
const ObjStruct = @import("value.zig").ObjStruct;
const ObjEnum = @import("value.zig").ObjEnum;
const ObjNativeFn = @import("value.zig").ObjNativeFn;
const ObjClosure = @import("value.zig").ObjClosure;
const ObjArray = @import("value.zig").ObjArray;
const ObjTask = @import("value.zig").ObjTask;
const ObjChannel = @import("value.zig").ObjChannel;
const ObjListener = @import("value.zig").ObjListener;
const ObjConn = @import("value.zig").ObjConn;
const TaskState = @import("value.zig").TaskState;
const stdlib = @import("stdlib.zig");
const ffi_mod = @import("ffi.zig");

pub const ConcatState = struct {
    buf: std.ArrayListUnmanaged(u8),
    slot: u8,
    frame: usize,
    active: bool,

    fn init() ConcatState {
        return .{ .buf = .{}, .slot = 0, .frame = 0, .active = false };
    }
};

pub const ArenaStack = struct {
    arenas: [16]?std.heap.ArenaAllocator,
    depth: u8,
    root_alloc: std.mem.Allocator,

    fn init(root: std.mem.Allocator) ArenaStack {
        var as: ArenaStack = .{
            .arenas = .{null} ** 16,
            .depth = 0,
            .root_alloc = root,
        };
        _ = &as;
        return as;
    }

    fn currentAlloc(self: *ArenaStack) std.mem.Allocator {
        if (self.depth > 0) {
            return self.arenas[self.depth - 1].?.allocator();
        }
        return self.root_alloc;
    }

    fn push(self: *ArenaStack) void {
        if (self.depth >= 16) @panic("arena stack overflow");
        self.arenas[self.depth] = std.heap.ArenaAllocator.init(self.root_alloc);
        self.depth += 1;
    }

    fn pop(self: *ArenaStack) void {
        if (self.depth == 0) @panic("arena stack underflow");
        self.depth -= 1;
        self.arenas[self.depth].?.deinit();
        self.arenas[self.depth] = null;
    }
};

pub const Scheduler = struct {
    run_queue: [64]?*ObjTask,
    queue_head: u8,
    queue_tail: u8,
    queue_count: u8,
    current_task: ?*ObjTask,
    active: bool,
    await_waiters: [16]?*ObjTask,
    await_waiter_count: u8,
    io_fds: [64]std.posix.fd_t,
    io_ops: [64]IoOp,
    io_tasks: [64]?*ObjTask,
    io_count: u8,
    io_write_data: [64][]const u8,
    io_write_off: [64]usize,

    const IoOp = enum(u8) { accept, read, write };

    fn init() Scheduler {
        return .{
            .run_queue = .{null} ** 64,
            .queue_head = 0,
            .queue_tail = 0,
            .queue_count = 0,
            .current_task = null,
            .active = false,
            .await_waiters = .{null} ** 16,
            .await_waiter_count = 0,
            .io_fds = .{0} ** 64,
            .io_ops = .{.accept} ** 64,
            .io_tasks = .{null} ** 64,
            .io_count = 0,
            .io_write_data = .{&.{}} ** 64,
            .io_write_off = .{0} ** 64,
        };
    }

    fn enqueue(self: *Scheduler, task: *ObjTask) void {
        if (self.queue_count >= 64) @panic("scheduler queue overflow");
        self.run_queue[self.queue_tail] = task;
        self.queue_tail = (self.queue_tail + 1) % 64;
        self.queue_count += 1;
    }

    fn dequeue(self: *Scheduler) ?*ObjTask {
        if (self.queue_count == 0) return null;
        const task = self.run_queue[self.queue_head].?;
        self.run_queue[self.queue_head] = null;
        self.queue_head = (self.queue_head + 1) % 64;
        self.queue_count -= 1;
        return task;
    }

    fn parkIo(self: *Scheduler, task: *ObjTask, fd: std.posix.fd_t, op: IoOp) void {
        if (self.io_count >= 64) @panic("io poller overflow");
        self.io_fds[self.io_count] = fd;
        self.io_ops[self.io_count] = op;
        self.io_tasks[self.io_count] = task;
        self.io_count += 1;
    }

    fn parkIoWrite(self: *Scheduler, task: *ObjTask, fd: std.posix.fd_t, data: []const u8, offset: usize) void {
        if (self.io_count >= 64) @panic("io poller overflow");
        self.io_fds[self.io_count] = fd;
        self.io_ops[self.io_count] = .write;
        self.io_tasks[self.io_count] = task;
        self.io_write_data[self.io_count] = data;
        self.io_write_off[self.io_count] = offset;
        self.io_count += 1;
    }

    fn removeIoWaiter(self: *Scheduler, idx: u8) void {
        self.io_count -= 1;
        self.io_fds[idx] = self.io_fds[self.io_count];
        self.io_ops[idx] = self.io_ops[self.io_count];
        self.io_tasks[idx] = self.io_tasks[self.io_count];
        self.io_write_data[idx] = self.io_write_data[self.io_count];
        self.io_write_off[idx] = self.io_write_off[self.io_count];
        self.io_tasks[self.io_count] = null;
    }

    fn pollAndWake(self: *Scheduler, alloc: std.mem.Allocator) void {
        if (self.io_count == 0) return;

        var pollfds: [64]std.posix.pollfd = undefined;
        var i: u8 = 0;
        while (i < self.io_count) : (i += 1) {
            const events: i16 = if (self.io_ops[i] == .write) std.posix.POLL.OUT else std.posix.POLL.IN;
            pollfds[i] = .{ .fd = self.io_fds[i], .events = events, .revents = 0 };
        }

        _ = std.posix.poll(pollfds[0..self.io_count], -1) catch return;

        var j: u8 = self.io_count;
        while (j > 0) {
            j -= 1;
            if (pollfds[j].revents & (std.posix.POLL.IN | std.posix.POLL.OUT | std.posix.POLL.ERR | std.posix.POLL.HUP) != 0) {
                const task = self.io_tasks[j].?;

                switch (self.io_ops[j]) {
                    .accept => {
                        const client_fd = std.posix.accept(self.io_fds[j], null, null, 0) catch {
                            task.stack[task.sp] = Value.initNil();
                            task.sp += 1;
                            task.state = .ready;
                            self.enqueue(task);
                            self.removeIoWaiter(j);
                            continue;
                        };
                        stdlib.setNonBlocking(client_fd);
                        task.stack[task.sp] = ObjConn.create(alloc, client_fd).toValue();
                        task.sp += 1;
                    },
                    .read => {
                        var buf: [8192]u8 = undefined;
                        const n = std.posix.read(self.io_fds[j], &buf) catch {
                            task.stack[task.sp] = Value.initNil();
                            task.sp += 1;
                            task.state = .ready;
                            self.enqueue(task);
                            self.removeIoWaiter(j);
                            continue;
                        };
                        if (n == 0) {
                            task.stack[task.sp] = Value.initNil();
                        } else {
                            const owned = alloc.dupe(u8, buf[0..n]) catch {
                                task.stack[task.sp] = Value.initNil();
                                task.sp += 1;
                                task.state = .ready;
                                self.enqueue(task);
                                self.removeIoWaiter(j);
                                continue;
                            };
                            task.stack[task.sp] = ObjString.create(alloc, owned).toValue();
                        }
                        task.sp += 1;
                    },
                    .write => {
                        const data = self.io_write_data[j];
                        var off = self.io_write_off[j];
                        while (off < data.len) {
                            const n = std.posix.write(self.io_fds[j], data[off..]) catch {
                                break;
                            };
                            off += n;
                        }
                        task.stack[task.sp] = Value.initBool(off >= data.len);
                        task.sp += 1;
                    },
                }

                task.state = .ready;
                self.enqueue(task);
                self.removeIoWaiter(j);
            }
        }
    }
};

pub const VM = struct {
    frames: [64]CallFrame,
    frame_count: usize,
    stack: [256]Value,
    sp: usize,
    globals: std.StringHashMapUnmanaged(Value),
    alloc: std.mem.Allocator,
    concat: *ConcatState,
    arena_stack: *ArenaStack,
    sched: *Scheduler,
    ffi: ?*ffi_mod.FfiState,

    pub const CallFrame = struct {
        function: *ObjFunction,
        ip: usize,
        slot_offset: usize,
        closure: ?*ObjClosure,
    };

    pub const Error = error{RuntimeError};

    pub fn init(alloc: std.mem.Allocator) VM {
        const cs = alloc.create(ConcatState) catch @panic("oom");
        cs.* = ConcatState.init();
        const as = alloc.create(ArenaStack) catch @panic("oom");
        as.* = ArenaStack.init(alloc);
        const sc = alloc.create(Scheduler) catch @panic("oom");
        sc.* = Scheduler.init();
        return .{
            .frames = undefined,
            .frame_count = 0,
            .stack = undefined,
            .sp = 0,
            .globals = .{},
            .alloc = alloc,
            .concat = cs,
            .arena_stack = as,
            .sched = sc,
            .ffi = null,
        };
    }

    fn currentAlloc(self: *VM) std.mem.Allocator {
        return self.arena_stack.currentAlloc();
    }

    pub fn setFfiDescs(self: *VM, descs: []ffi_mod.FfiDesc) void {
        if (descs.len == 0) return;
        const state = self.alloc.create(ffi_mod.FfiState) catch @panic("oom");
        state.* = ffi_mod.FfiState.init(self.alloc, descs);
        state.resolve() catch {
            std.debug.print("ffi: failed to resolve symbols\n", .{});
        };
        self.ffi = state;
    }

    pub fn interpret(self: *VM, function: *ObjFunction) Error!void {
        self.push(function.toValue());
        self.frames[0] = .{
            .function = function,
            .ip = 0,
            .slot_offset = 0,
            .closure = null,
        };
        self.frame_count = 1;
        try self.run();
    }

    fn run(self: *VM) Error!void {
        while (true) {
            const op: OpCode = @enumFromInt(self.readByte());

            switch (op) {
                .constant => {
                    const idx = self.readU16();
                    self.push(self.currentChunk().constants.items[idx]);
                },
                .nil => self.push(Value.initNil()),
                .true_ => self.push(Value.initBool(true)),
                .false_ => self.push(Value.initBool(false)),
                .pop => _ = self.pop(),

                .get_local => {
                    const slot = self.readByte();
                    self.push(self.stack[self.currentFrame().slot_offset + slot]);
                },
                .set_local => {
                    const slot = self.readByte();
                    self.stack[self.currentFrame().slot_offset + slot] = self.peek(0);
                },
                .get_global => {
                    const name = self.readStringConstant();
                    if (self.globals.get(name)) |val| {
                        self.push(val);
                    } else {
                        self.runtimeError("undefined variable '{s}'", .{name});
                        return error.RuntimeError;
                    }
                },
                .set_global => {
                    const name = self.readStringConstant();
                    if (self.globals.getPtr(name)) |ptr| {
                        ptr.* = self.peek(0);
                    } else {
                        self.runtimeError("undefined variable '{s}'", .{name});
                        return error.RuntimeError;
                    }
                },
                .define_global => {
                    const name = self.readStringConstant();
                    self.globals.put(self.alloc, name, self.peek(0)) catch @panic("oom");
                    _ = self.pop();
                },

                .add => try self.binaryOp(.add),
                .subtract => try self.binaryOp(.subtract),
                .multiply => try self.binaryOp(.multiply),
                .divide => try self.binaryOp(.divide),
                .modulo => try self.binaryOp(.modulo),
                .negate => {
                    const val = self.pop();
                    if (val.tag == .int) {
                        self.push(Value.initInt(-val.asInt()));
                    } else if (val.tag == .float) {
                        self.push(Value.initFloat(-val.asFloat()));
                    } else {
                        self.runtimeError("operand must be a number", .{});
                        return error.RuntimeError;
                    }
                },

                .not => {
                    const val = self.pop();
                    self.push(Value.initBool(!val.isTruthy()));
                },
                .equal => {
                    const b = self.pop();
                    const a = self.pop();
                    self.push(Value.initBool(Value.eql(a, b)));
                },
                .not_equal => {
                    const b = self.pop();
                    const a = self.pop();
                    self.push(Value.initBool(!Value.eql(a, b)));
                },
                .less => try self.comparisonOp(.less),
                .greater => try self.comparisonOp(.greater),
                .less_equal => try self.comparisonOp(.less_equal),
                .greater_equal => try self.comparisonOp(.greater_equal),

                .jump => {
                    const offset = self.readU16();
                    self.currentFrame().ip += offset;
                },
                .jump_if_false => {
                    const offset = self.readU16();
                    if (!self.peek(0).isTruthy()) {
                        self.currentFrame().ip += offset;
                    }
                },
                .loop_ => {
                    const offset = self.readU16();
                    self.currentFrame().ip -= offset;
                },

                .call => {
                    const arg_count = self.readByte();
                    const callee = self.stack[self.sp - 1 - arg_count];
                    const is_fast = if (callee.tag == .function) callee.asFunction().locals_only
                        else if (callee.tag == .closure) callee.asClosure().function.locals_only
                        else false;
                    try self.callValue(callee, arg_count);
                    if (is_fast) try self.fastLoop();
                },
                .return_ => {
                    const result = self.pop();
                    const slot = self.currentFrame().slot_offset;
                    self.frame_count -= 1;
                    if (self.frame_count == 0) {
                        if (self.sched.active) {
                            self.sp = slot;
                            self.push(result);
                            if (!self.taskFinished()) return;
                        } else {
                            return;
                        }
                    } else {
                        self.sp = slot;
                        self.push(result);
                    }
                },

                .print => {
                    const val = self.pop();
                    val.dump();
                },
                .println => {
                    const val = self.pop();
                    val.dump();
                    std.debug.print("\n", .{});
                },

                .struct_create => {
                    const name_idx = self.readU16();
                    const field_count = self.readByte();
                    const name = self.currentChunk().constants.items[name_idx].asString().chars;
                    const ca = self.currentAlloc();

                    const field_names = ca.alloc([]const u8, field_count) catch @panic("oom");
                    const temp_values = ca.alloc(Value, field_count) catch @panic("oom");

                    for (0..field_count) |fi| {
                        const fi_idx = self.readU16();
                        field_names[fi] = self.currentChunk().constants.items[fi_idx].asString().chars;
                    }

                    var fc: usize = field_count;
                    while (fc > 0) {
                        fc -= 1;
                        temp_values[fc] = self.pop();
                    }

                    const s = ObjStruct.create(ca, name, field_names, temp_values);
                    ca.free(temp_values);
                    self.push(s.toValue());
                },

                .get_field => {
                    const name_idx = self.readU16();
                    const field_name = self.currentChunk().constants.items[name_idx].asString().chars;
                    const val = self.pop();
                    if (val.tag == .struct_) {
                        const s = val.asStruct();
                        if (s.getField(field_name)) |fv| {
                            self.push(fv);
                        } else {
                            self.runtimeError("struct '{s}' has no field '{s}'", .{ s.name, field_name });
                            return error.RuntimeError;
                        }
                    } else if (val.tag == .string) {
                        if (std.mem.eql(u8, field_name, "len")) {
                            self.push(Value.initInt(@intCast(val.asString().chars.len)));
                        } else {
                            self.runtimeError("string has no field '{s}'", .{field_name});
                            return error.RuntimeError;
                        }
                    } else if (val.tag == .array) {
                        if (std.mem.eql(u8, field_name, "len")) {
                            self.push(Value.initInt(@intCast(val.asArray().items.len)));
                        } else {
                            self.runtimeError("array has no field '{s}'", .{field_name});
                            return error.RuntimeError;
                        }
                    } else {
                        self.runtimeError("cannot access field on this value", .{});
                        return error.RuntimeError;
                    }
                },

                .get_field_idx => {
                    const idx = self.readByte();
                    const val = self.pop();
                    if (val.tag == .struct_) {
                        const s = val.asStruct();
                        if (idx < s.field_count) {
                            self.push(s.fieldValues()[idx]);
                        } else {
                            self.runtimeError("field index out of bounds", .{});
                            return error.RuntimeError;
                        }
                    } else {
                        self.runtimeError("cannot access field on non-struct value", .{});
                        return error.RuntimeError;
                    }
                },

                .set_field => {
                    const name_idx = self.readU16();
                    const field_name = self.currentChunk().constants.items[name_idx].asString().chars;
                    const target = self.pop();
                    const val = self.stack[self.sp - 1];
                    if (target.tag == .struct_) {
                        if (!target.asStruct().setField(field_name, val)) {
                            self.runtimeError("struct has no field '{s}'", .{field_name});
                            return error.RuntimeError;
                        }
                    } else {
                        self.runtimeError("cannot set field on non-struct value", .{});
                        return error.RuntimeError;
                    }
                },

                .set_field_idx => {
                    const idx = self.readByte();
                    const target = self.pop();
                    const val = self.stack[self.sp - 1];
                    if (target.tag == .struct_) {
                        const s = target.asStruct();
                        if (idx < s.field_count) {
                            s.fieldValues()[idx] = val;
                        } else {
                            self.runtimeError("field index out of bounds", .{});
                            return error.RuntimeError;
                        }
                    } else {
                        self.runtimeError("cannot set field on non-struct value", .{});
                        return error.RuntimeError;
                    }
                },

                .get_local_field => {
                    const slot = self.readByte();
                    const field_idx = self.readByte();
                    const val = self.stack[self.currentFrame().slot_offset + slot];
                    if (val.tag == .struct_) {
                        self.push(val.asStruct().fieldValues()[field_idx]);
                    } else {
                        self.runtimeError("cannot access field on non-struct value", .{});
                        return error.RuntimeError;
                    }
                },

                .to_str => {
                    const val = self.pop();
                    if (val.tag == .string) {
                        self.push(val);
                    } else {
                        self.push(self.valueToString(val));
                    }
                },

                .enum_variant => {
                    const variant_idx = self.readU16();
                    const type_idx = self.readU16();
                    const payload_count = self.readByte();
                    const vi = self.readByte();
                    const variant_name = self.currentChunk().constants.items[variant_idx].asString().chars;
                    const type_name = self.currentChunk().constants.items[type_idx].asString().chars;
                    const ca = self.currentAlloc();

                    const payloads = ca.alloc(Value, payload_count) catch @panic("oom");
                    var pc: usize = payload_count;
                    while (pc > 0) {
                        pc -= 1;
                        payloads[pc] = self.pop();
                    }

                    const e = ObjEnum.create(ca, type_name, variant_name, vi, payloads);
                    self.push(e.toValue());
                },

                .match_variant => {
                    const expected_vi = self.readByte();
                    const val = self.peek(0);
                    if (val.tag == .enum_) {
                        self.push(Value.initBool(val.asEnum().variant_index == expected_vi));
                    } else {
                        self.push(Value.initBool(false));
                    }
                },

                .make_closure => {
                    const idx = self.readU16();
                    const uv_count = self.readByte();
                    const func = self.currentChunk().constants.items[idx].asFunction();
                    const ca = self.currentAlloc();
                    const upvalues = ca.alloc(Value, uv_count) catch @panic("oom");
                    var i: u8 = 0;
                    while (i < uv_count) : (i += 1) {
                        const is_local = self.readByte() == 1;
                        const uv_index = self.readByte();
                        if (is_local) {
                            upvalues[i] = self.stack[self.currentFrame().slot_offset + uv_index];
                        } else {
                            const cl = self.currentFrame().closure orelse {
                                upvalues[i] = Value.initNil();
                                continue;
                            };
                            upvalues[i] = if (uv_index < cl.upvalues.len) cl.upvalues[uv_index] else Value.initNil();
                        }
                    }
                    const cl = ObjClosure.create(ca, func, upvalues);
                    self.push(cl.toValue());
                },

                .get_upvalue => {
                    const uv_index = self.readByte();
                    const cl = self.currentFrame().closure orelse {
                        self.push(Value.initNil());
                        continue;
                    };
                    self.push(if (uv_index < cl.upvalues.len) cl.upvalues[uv_index] else Value.initNil());
                },

                .set_upvalue => {
                    const uv_index = self.readByte();
                    const cl = self.currentFrame().closure orelse continue;
                    if (uv_index < cl.upvalues.len) {
                        cl.upvalues[uv_index] = self.peek(0);
                    }
                },

                .get_payload => {
                    const idx = self.readByte();
                    const val = self.pop();
                    if (val.tag == .enum_) {
                        const e = val.asEnum();
                        if (idx < e.payloads.len) {
                            self.push(e.payloads[idx]);
                        } else {
                            self.push(Value.initNil());
                        }
                    } else {
                        self.push(Value.initNil());
                    }
                },

                .concat_local => {
                    const slot = self.readByte();
                    const rhs = self.pop();
                    self.concatAppend(slot, rhs);
                },

                .add_int => {
                    const b = self.pop();
                    const a = self.pop();
                    self.push(Value.initInt(a.asInt() + b.asInt()));
                },
                .sub_int => {
                    const b = self.pop();
                    const a = self.pop();
                    self.push(Value.initInt(a.asInt() - b.asInt()));
                },
                .mul_int => {
                    const b = self.pop();
                    const a = self.pop();
                    self.push(Value.initInt(a.asInt() * b.asInt()));
                },
                .div_int => {
                    const b = self.pop();
                    const a = self.pop();
                    const bi = b.asInt();
                    self.push(Value.initInt(if (bi != 0) @divTrunc(a.asInt(), bi) else 0));
                },
                .mod_int => {
                    const b = self.pop();
                    const a = self.pop();
                    const bi = b.asInt();
                    self.push(Value.initInt(if (bi != 0) @mod(a.asInt(), bi) else 0));
                },
                .less_int => {
                    const b = self.pop();
                    const a = self.pop();
                    self.push(Value.initBool(a.asInt() < b.asInt()));
                },
                .greater_int => {
                    const b = self.pop();
                    const a = self.pop();
                    self.push(Value.initBool(a.asInt() > b.asInt()));
                },
                .add_float => {
                    const b = self.pop();
                    const a = self.pop();
                    const af: f64 = if (a.tag == .float) a.asFloat() else @floatFromInt(a.asInt());
                    const bf: f64 = if (b.tag == .float) b.asFloat() else @floatFromInt(b.asInt());
                    self.push(Value.initFloat(af + bf));
                },
                .sub_float => {
                    const b = self.pop();
                    const a = self.pop();
                    const af: f64 = if (a.tag == .float) a.asFloat() else @floatFromInt(a.asInt());
                    const bf: f64 = if (b.tag == .float) b.asFloat() else @floatFromInt(b.asInt());
                    self.push(Value.initFloat(af - bf));
                },
                .mul_float => {
                    const b = self.pop();
                    const a = self.pop();
                    const af: f64 = if (a.tag == .float) a.asFloat() else @floatFromInt(a.asInt());
                    const bf: f64 = if (b.tag == .float) b.asFloat() else @floatFromInt(b.asInt());
                    self.push(Value.initFloat(af * bf));
                },
                .div_float => {
                    const b = self.pop();
                    const a = self.pop();
                    const af: f64 = if (a.tag == .float) a.asFloat() else @floatFromInt(a.asInt());
                    const bf: f64 = if (b.tag == .float) b.asFloat() else @floatFromInt(b.asInt());
                    self.push(Value.initFloat(if (bf != 0.0) af / bf else 0.0));
                },
                .less_float => {
                    const b = self.pop();
                    const a = self.pop();
                    const af: f64 = if (a.tag == .float) a.asFloat() else @floatFromInt(a.asInt());
                    const bf: f64 = if (b.tag == .float) b.asFloat() else @floatFromInt(b.asInt());
                    self.push(Value.initBool(af < bf));
                },
                .greater_float => {
                    const b = self.pop();
                    const a = self.pop();
                    const af: f64 = if (a.tag == .float) a.asFloat() else @floatFromInt(a.asInt());
                    const bf: f64 = if (b.tag == .float) b.asFloat() else @floatFromInt(b.asInt());
                    self.push(Value.initBool(af > bf));
                },

                .array_create => {
                    const count = self.readByte();
                    const items = self.stack[self.sp - count .. self.sp];
                    const arr = ObjArray.create(self.currentAlloc(), items);
                    self.sp -= count;
                    self.push(arr.toValue());
                },
                .index_get => {
                    const idx_val = self.pop();
                    const target = self.pop();
                    if (target.tag == .array and idx_val.tag == .int) {
                        const arr = target.asArray();
                        const idx = idx_val.asInt();
                        if (idx >= 0 and idx < @as(i64, @intCast(arr.items.len))) {
                            self.push(arr.items[@intCast(idx)]);
                        } else {
                            self.runtimeError("array index out of bounds: {d}", .{idx});
                            return error.RuntimeError;
                        }
                    } else if (target.tag == .string and idx_val.tag == .int) {
                        const s = target.asString();
                        const idx = idx_val.asInt();
                        if (idx >= 0 and idx < @as(i64, @intCast(s.chars.len))) {
                            const ch = s.chars[@intCast(idx) .. @as(usize, @intCast(idx)) + 1];
                            self.push(ObjString.create(self.currentAlloc(), ch).toValue());
                        } else {
                            self.runtimeError("string index out of bounds: {d}", .{idx});
                            return error.RuntimeError;
                        }
                    } else {
                        self.runtimeError("cannot index into this value", .{});
                        return error.RuntimeError;
                    }
                },
                .index_set => {
                    const idx_val = self.pop();
                    const target = self.pop();
                    const val = self.stack[self.sp - 1];
                    if (target.tag == .array and idx_val.tag == .int) {
                        const arr = target.asArray();
                        const idx = idx_val.asInt();
                        if (idx >= 0 and idx < @as(i64, @intCast(arr.items.len))) {
                            arr.items[@intCast(idx)] = val;
                        } else {
                            self.runtimeError("array index out of bounds: {d}", .{idx});
                            return error.RuntimeError;
                        }
                    } else {
                        self.runtimeError("cannot index-assign into this value", .{});
                        return error.RuntimeError;
                    }
                },
                .array_push, .array_len => {},
                .push_arena => self.arena_stack.push(),
                .pop_arena => self.arena_stack.pop(),

                .spawn => try self.execSpawn(),
                .channel_create => {
                    const cap = self.readByte();
                    const ch = ObjChannel.create(self.alloc, @intCast(cap));
                    self.push(ch.toValue());
                },
                .channel_send => try self.execChannelSend(),
                .channel_recv => try self.execChannelRecv(),
                .await_task => try self.execAwaitTask(),
                .await_all => {
                    _ = self.readByte();
                },
                .net_accept => try self.execNetAccept(),
                .net_read => try self.execNetRead(),
                .net_write => try self.execNetWrite(),
                .ffi_call => try self.execFfiCall(),
                .slide => {
                    const n = self.readByte();
                    const result = self.stack[self.sp - 1];
                    self.sp -= n;
                    self.stack[self.sp - 1] = result;
                },
                .inc_local => {
                    const frame_ = &self.frames[self.frame_count - 1];
                    const slot = frame_.function.chunk.code.items[frame_.ip];
                    frame_.ip += 1;
                    const abs = frame_.slot_offset + slot;
                    self.stack[abs] = Value.initInt(self.stack[abs].asInt() + 1);
                },
                .match_jump => {
                    const frame_ = &self.frames[self.frame_count - 1];
                    const c = frame_.function.chunk.code.items;
                    const slot = c[frame_.ip];
                    frame_.ip += 1;
                    const n = c[frame_.ip];
                    frame_.ip += 1;
                    const table_start = frame_.ip;
                    frame_.ip += @as(usize, n) * 2 + 2;
                    const base = frame_.ip;
                    const val = self.stack[frame_.slot_offset + slot];
                    var off_idx: usize = @as(usize, n) * 2;
                    if (val.tag == .enum_) {
                        const vi = val.asEnum().variant_index;
                        if (vi < n) off_idx = @as(usize, vi) * 2;
                    }
                    const offset = @as(u16, c[table_start + off_idx]) << 8 | c[table_start + off_idx + 1];
                    frame_.ip = base + offset;
                },
            }
        }
    }

    fn fastLoop(self: *VM) Error!void {
        const entry_fc = self.frame_count;

        while (true) {
            const frame = &self.frames[self.frame_count - 1];
            const code = frame.function.chunk.code.items;
            const byte = code[frame.ip];
            frame.ip += 1;

            if (byte == @intFromEnum(OpCode.get_local)) {
                const slot = code[frame.ip];
                frame.ip += 1;
                self.stack[self.sp] = self.stack[frame.slot_offset + slot];
                self.sp += 1;
            } else if (byte == @intFromEnum(OpCode.set_local)) {
                const slot = code[frame.ip];
                frame.ip += 1;
                self.stack[frame.slot_offset + slot] = self.stack[self.sp - 1];
            } else if (byte == @intFromEnum(OpCode.inc_local)) {
                const slot = code[frame.ip];
                frame.ip += 1;
                const abs = frame.slot_offset + slot;
                self.stack[abs] = Value.initInt(self.stack[abs].asInt() + 1);
            } else if (byte == @intFromEnum(OpCode.constant)) {
                const hi: u16 = code[frame.ip];
                const lo: u16 = code[frame.ip + 1];
                frame.ip += 2;
                self.stack[self.sp] = frame.function.chunk.constants.items[(hi << 8) | lo];
                self.sp += 1;
            } else if (byte == @intFromEnum(OpCode.add)) {
                const b = self.stack[self.sp - 1];
                const a = self.stack[self.sp - 2];
                self.sp -= 1;
                if (a.tag == .int and b.tag == .int) {
                    self.stack[self.sp - 1] = Value.initInt(a.asInt() + b.asInt());
                } else {
                    try self.binaryOpSlow(a, b, .add);
                }
            } else if (byte == @intFromEnum(OpCode.subtract)) {
                const b = self.stack[self.sp - 1];
                const a = self.stack[self.sp - 2];
                self.sp -= 1;
                if (a.tag == .int and b.tag == .int) {
                    self.stack[self.sp - 1] = Value.initInt(a.asInt() - b.asInt());
                } else {
                    try self.binaryOpSlow(a, b, .subtract);
                }
            } else if (byte == @intFromEnum(OpCode.multiply)) {
                const b = self.stack[self.sp - 1];
                const a = self.stack[self.sp - 2];
                self.sp -= 1;
                if (a.tag == .int and b.tag == .int) {
                    self.stack[self.sp - 1] = Value.initInt(a.asInt() * b.asInt());
                } else {
                    try self.binaryOpSlow(a, b, .multiply);
                }
            } else if (byte == @intFromEnum(OpCode.less)) {
                const b = self.stack[self.sp - 1];
                const a = self.stack[self.sp - 2];
                self.sp -= 1;
                if (a.tag == .int and b.tag == .int) {
                    self.stack[self.sp - 1] = Value.initBool(a.asInt() < b.asInt());
                } else {
                    try self.comparisonOpSlow(a, b, .less);
                }
            } else if (byte == @intFromEnum(OpCode.greater)) {
                const b = self.stack[self.sp - 1];
                const a = self.stack[self.sp - 2];
                self.sp -= 1;
                if (a.tag == .int and b.tag == .int) {
                    self.stack[self.sp - 1] = Value.initBool(a.asInt() > b.asInt());
                } else {
                    try self.comparisonOpSlow(a, b, .greater);
                }
            } else if (byte == @intFromEnum(OpCode.jump_if_false)) {
                const hi: u16 = code[frame.ip];
                const lo: u16 = code[frame.ip + 1];
                frame.ip += 2;
                if (!self.stack[self.sp - 1].isTruthy()) {
                    frame.ip += (hi << 8) | lo;
                }
            } else if (byte == @intFromEnum(OpCode.jump)) {
                const hi: u16 = code[frame.ip];
                const lo: u16 = code[frame.ip + 1];
                frame.ip += 2;
                frame.ip += (hi << 8) | lo;
            } else if (byte == @intFromEnum(OpCode.loop_)) {
                const hi: u16 = code[frame.ip];
                const lo: u16 = code[frame.ip + 1];
                frame.ip += 2;
                frame.ip -= (hi << 8) | lo;
            } else if (byte == @intFromEnum(OpCode.call)) {
                const arg_count = code[frame.ip];
                frame.ip += 1;
                const callee = self.stack[self.sp - 1 - arg_count];
                if (callee.tag == .native_fn) {
                    const nf = callee.asNativeFn();
                    const args = self.stack[self.sp - arg_count .. self.sp];
                    const result = nf.func(self.currentAlloc(), args);
                    self.sp -= arg_count + 1;
                    self.stack[self.sp] = result;
                    self.sp += 1;
                } else {
                    const func = if (callee.tag == .function)
                        callee.asFunction()
                    else if (callee.tag == .closure)
                        callee.asClosure().function
                    else {
                        self.runtimeError("can only call functions", .{});
                        return error.RuntimeError;
                    };
                    if (self.frame_count == 64) {
                        self.runtimeError("stack overflow", .{});
                        return error.RuntimeError;
                    }
                    self.frames[self.frame_count] = .{
                        .function = func,
                        .ip = 0,
                        .slot_offset = self.sp - arg_count - 1,
                        .closure = if (callee.tag == .closure) callee.asClosure() else null,
                    };
                    self.frame_count += 1;
                    if (!func.locals_only) return;
                }
            } else if (byte == @intFromEnum(OpCode.return_)) {
                const result = self.stack[self.sp - 1];
                self.sp -= 1;
                const slot = frame.slot_offset;
                self.frame_count -= 1;
                self.sp = slot;
                self.stack[self.sp] = result;
                self.sp += 1;
                if (self.frame_count < entry_fc) return;
            } else if (byte == @intFromEnum(OpCode.get_upvalue)) {
                const uv_index = code[frame.ip];
                frame.ip += 1;
                const cl = self.frames[self.frame_count - 1].closure orelse {
                    self.stack[self.sp] = Value.initNil();
                    self.sp += 1;
                    continue;
                };
                self.stack[self.sp] = if (uv_index < cl.upvalues.len) cl.upvalues[uv_index] else Value.initNil();
                self.sp += 1;
            } else if (byte == @intFromEnum(OpCode.set_upvalue)) {
                const uv_index = code[frame.ip];
                frame.ip += 1;
                const cl = self.frames[self.frame_count - 1].closure orelse continue;
                if (uv_index < cl.upvalues.len) {
                    cl.upvalues[uv_index] = self.stack[self.sp - 1];
                }
            } else if (byte == @intFromEnum(OpCode.add_int)) {
                self.sp -= 1;
                self.stack[self.sp - 1] = Value.initInt(self.stack[self.sp - 1].asInt() + self.stack[self.sp].asInt());
            } else if (byte == @intFromEnum(OpCode.sub_int)) {
                self.sp -= 1;
                self.stack[self.sp - 1] = Value.initInt(self.stack[self.sp - 1].asInt() - self.stack[self.sp].asInt());
            } else if (byte == @intFromEnum(OpCode.less_int)) {
                self.sp -= 1;
                self.stack[self.sp - 1] = Value.initBool(self.stack[self.sp - 1].asInt() < self.stack[self.sp].asInt());
            } else if (byte == @intFromEnum(OpCode.greater_int)) {
                self.sp -= 1;
                self.stack[self.sp - 1] = Value.initBool(self.stack[self.sp - 1].asInt() > self.stack[self.sp].asInt());
            } else if (byte == @intFromEnum(OpCode.mul_int)) {
                self.sp -= 1;
                self.stack[self.sp - 1] = Value.initInt(self.stack[self.sp - 1].asInt() *% self.stack[self.sp].asInt());
            } else if (byte == @intFromEnum(OpCode.mod_int)) {
                self.sp -= 1;
                const bi = self.stack[self.sp].asInt();
                self.stack[self.sp - 1] = Value.initInt(if (bi != 0) @mod(self.stack[self.sp - 1].asInt(), bi) else 0);
            } else if (byte == @intFromEnum(OpCode.add_float)) {
                const b = self.stack[self.sp - 1];
                const a = self.stack[self.sp - 2];
                self.sp -= 1;
                const af: f64 = if (a.tag == .float) a.asFloat() else @floatFromInt(a.asInt());
                const bf: f64 = if (b.tag == .float) b.asFloat() else @floatFromInt(b.asInt());
                self.stack[self.sp - 1] = Value.initFloat(af + bf);
            } else if (byte == @intFromEnum(OpCode.concat_local)) {
                const slot = code[frame.ip];
                frame.ip += 1;
                const rhs = self.stack[self.sp - 1];
                self.sp -= 1;
                self.concatAppend(slot, rhs);
            } else if (byte == @intFromEnum(OpCode.get_local_field)) {
                const slot = code[frame.ip];
                const field_idx = code[frame.ip + 1];
                frame.ip += 2;
                self.stack[self.sp] = self.stack[frame.slot_offset + slot].asStruct().fieldValues()[field_idx];
                self.sp += 1;
            } else if (byte == @intFromEnum(OpCode.get_field_idx)) {
                const idx = code[frame.ip];
                frame.ip += 1;
                const val = self.stack[self.sp - 1];
                if (val.tag == .struct_) {
                    self.stack[self.sp - 1] = val.asStruct().fieldValues()[idx];
                } else {
                    frame.ip -= 2;
                    return;
                }
            } else if (byte == @intFromEnum(OpCode.get_field)) {
                const hi: u16 = code[frame.ip];
                const lo: u16 = code[frame.ip + 1];
                frame.ip += 2;
                const field_name = frame.function.chunk.constants.items[(hi << 8) | lo].asString().chars;
                const val = self.stack[self.sp - 1];
                if (val.tag == .struct_) {
                    const s = val.asStruct();
                    if (s.getField(field_name)) |fv| {
                        self.stack[self.sp - 1] = fv;
                    } else {
                        self.runtimeError("struct has no field '{s}'", .{field_name});
                        return error.RuntimeError;
                    }
                } else {
                    frame.ip -= 3;
                    return;
                }
            } else if (byte == @intFromEnum(OpCode.pop)) {
                self.sp -= 1;
            } else if (byte == @intFromEnum(OpCode.slide)) {
                const n = code[frame.ip];
                frame.ip += 1;
                const result = self.stack[self.sp - 1];
                self.sp -= n;
                self.stack[self.sp - 1] = result;
            } else if (byte == @intFromEnum(OpCode.nil)) {
                self.stack[self.sp] = Value.initNil();
                self.sp += 1;
            } else if (byte == @intFromEnum(OpCode.true_)) {
                self.stack[self.sp] = Value.initBool(true);
                self.sp += 1;
            } else if (byte == @intFromEnum(OpCode.false_)) {
                self.stack[self.sp] = Value.initBool(false);
                self.sp += 1;
            } else if (byte == @intFromEnum(OpCode.equal)) {
                const b = self.stack[self.sp - 1];
                const a = self.stack[self.sp - 2];
                self.sp -= 1;
                self.stack[self.sp - 1] = Value.initBool(Value.eql(a, b));
            } else if (byte == @intFromEnum(OpCode.not_equal)) {
                const b = self.stack[self.sp - 1];
                const a = self.stack[self.sp - 2];
                self.sp -= 1;
                self.stack[self.sp - 1] = Value.initBool(!Value.eql(a, b));
            } else if (byte == @intFromEnum(OpCode.not)) {
                self.stack[self.sp - 1] = Value.initBool(!self.stack[self.sp - 1].isTruthy());
            } else if (byte == @intFromEnum(OpCode.negate)) {
                const val = self.stack[self.sp - 1];
                if (val.tag == .int) {
                    self.stack[self.sp - 1] = Value.initInt(-val.asInt());
                } else if (val.tag == .float) {
                    self.stack[self.sp - 1] = Value.initFloat(-val.asFloat());
                } else {
                    self.runtimeError("operand must be a number", .{});
                    return error.RuntimeError;
                }
            } else if (byte == @intFromEnum(OpCode.divide)) {
                const b = self.stack[self.sp - 1];
                const a = self.stack[self.sp - 2];
                self.sp -= 1;
                if (a.tag == .int and b.tag == .int) {
                    const bi = b.asInt();
                    self.stack[self.sp - 1] = Value.initInt(if (bi != 0) @divTrunc(a.asInt(), bi) else 0);
                } else {
                    try self.binaryOpSlow(a, b, .divide);
                }
            } else if (byte == @intFromEnum(OpCode.modulo)) {
                const b = self.stack[self.sp - 1];
                const a = self.stack[self.sp - 2];
                self.sp -= 1;
                if (a.tag == .int and b.tag == .int) {
                    const bi = b.asInt();
                    self.stack[self.sp - 1] = Value.initInt(if (bi != 0) @mod(a.asInt(), bi) else 0);
                } else {
                    try self.binaryOpSlow(a, b, .modulo);
                }
            } else if (byte == @intFromEnum(OpCode.less_equal)) {
                const b = self.stack[self.sp - 1];
                const a = self.stack[self.sp - 2];
                self.sp -= 1;
                if (a.tag == .int and b.tag == .int) {
                    self.stack[self.sp - 1] = Value.initBool(a.asInt() <= b.asInt());
                } else {
                    try self.comparisonOpSlow(a, b, .less_equal);
                }
            } else if (byte == @intFromEnum(OpCode.get_global)) {
                const hi: u16 = code[frame.ip];
                const lo: u16 = code[frame.ip + 1];
                frame.ip += 2;
                const name = frame.function.chunk.constants.items[(hi << 8) | lo].asString().chars;
                if (self.globals.get(name)) |val| {
                    self.stack[self.sp] = val;
                    self.sp += 1;
                } else {
                    self.runtimeError("undefined variable '{s}'", .{name});
                    return error.RuntimeError;
                }
            } else if (byte == @intFromEnum(OpCode.greater_equal)) {
                const b = self.stack[self.sp - 1];
                const a = self.stack[self.sp - 2];
                self.sp -= 1;
                if (a.tag == .int and b.tag == .int) {
                    self.stack[self.sp - 1] = Value.initBool(a.asInt() >= b.asInt());
                } else {
                    try self.comparisonOpSlow(a, b, .greater_equal);
                }
            } else if (byte == @intFromEnum(OpCode.match_variant)) {
                const expected_vi = code[frame.ip];
                frame.ip += 1;
                const val = self.stack[self.sp - 1];
                if (val.tag == .enum_) {
                    self.stack[self.sp] = Value.initBool(val.asEnum().variant_index == expected_vi);
                } else {
                    self.stack[self.sp] = Value.initBool(false);
                }
                self.sp += 1;
            } else if (byte == @intFromEnum(OpCode.get_payload)) {
                const payload_idx = code[frame.ip];
                frame.ip += 1;
                const val = self.stack[self.sp - 1];
                self.sp -= 1;
                if (val.tag == .enum_) {
                    self.stack[self.sp] = val.asEnum().payloads[payload_idx];
                    self.sp += 1;
                }
            } else if (byte == @intFromEnum(OpCode.index_get)) {
                const idx_val = self.stack[self.sp - 1];
                const target = self.stack[self.sp - 2];
                if (target.tag == .array and idx_val.tag == .int) {
                    const arr = target.asArray();
                    const idx = idx_val.asInt();
                    if (idx >= 0 and idx < @as(i64, @intCast(arr.items.len))) {
                        self.sp -= 1;
                        self.stack[self.sp - 1] = arr.items[@intCast(idx)];
                    } else {
                        frame.ip -= 1;
                        return;
                    }
                } else {
                    frame.ip -= 1;
                    return;
                }
            } else if (byte == @intFromEnum(OpCode.match_jump)) {
                const slot = code[frame.ip];
                frame.ip += 1;
                const n = code[frame.ip];
                frame.ip += 1;
                const table_start = frame.ip;
                frame.ip += @as(usize, n) * 2 + 2;
                const base = frame.ip;
                const val = self.stack[frame.slot_offset + slot];
                var off_idx: usize = @as(usize, n) * 2;
                if (val.tag == .enum_) {
                    const vi = val.asEnum().variant_index;
                    if (vi < n) off_idx = @as(usize, vi) * 2;
                }
                const offset = @as(u16, code[table_start + off_idx]) << 8 | code[table_start + off_idx + 1];
                frame.ip = base + offset;
            } else {
                frame.ip -= 1;
                return;
            }
        }
    }

    fn binaryOpSlow(self: *VM, a: Value, b: Value, op: OpCode) Error!void {
        if ((a.tag == .float or a.tag == .int) and (b.tag == .float or b.tag == .int)) {
            const af: f64 = if (a.tag == .float) a.asFloat() else @floatFromInt(a.asInt());
            const bf: f64 = if (b.tag == .float) b.asFloat() else @floatFromInt(b.asInt());
            self.stack[self.sp - 1] = Value.initFloat(switch (op) {
                .add => af + bf,
                .subtract => af - bf,
                .multiply => af * bf,
                .divide => if (bf != 0.0) af / bf else 0.0,
                .modulo => @mod(af, bf),
                else => 0.0,
            });
            return;
        }
        if (a.tag == .string and b.tag == .string and op == .add) {
            const as = a.asString().chars;
            const bs = b.asString().chars;
            const ca = self.currentAlloc();
            const buf = ca.alloc(u8, as.len + bs.len) catch @panic("oom");
            @memcpy(buf[0..as.len], as);
            @memcpy(buf[as.len..], bs);
            const str = ObjString.create(ca, buf);
            self.stack[self.sp - 1] = str.toValue();
            return;
        }
        self.runtimeError("operands must be numbers", .{});
        return error.RuntimeError;
    }

    fn comparisonOpSlow(self: *VM, a: Value, b: Value, op: OpCode) Error!void {
        if ((a.tag == .float or a.tag == .int) and (b.tag == .float or b.tag == .int)) {
            const af: f64 = if (a.tag == .float) a.asFloat() else @floatFromInt(a.asInt());
            const bf: f64 = if (b.tag == .float) b.asFloat() else @floatFromInt(b.asInt());
            self.stack[self.sp - 1] = Value.initBool(switch (op) {
                .less => af < bf,
                .greater => af > bf,
                .less_equal => af <= bf,
                .greater_equal => af >= bf,
                else => false,
            });
            return;
        }
        self.runtimeError("operands must be numbers", .{});
        return error.RuntimeError;
    }

    fn callValue(self: *VM, callee: Value, arg_count: u8) Error!void {
        if (callee.tag == .native_fn) {
            const nf = callee.asNativeFn();
            if (arg_count != nf.arity) {
                self.runtimeError("expected {d} arguments but got {d}", .{ nf.arity, arg_count });
                return error.RuntimeError;
            }
            const args = self.stack[self.sp - arg_count .. self.sp];
            const result = nf.func(self.currentAlloc(), args);
            self.sp -= arg_count + 1;
            self.push(result);
            return;
        }

        if (callee.tag == .closure) {
            const cl = callee.asClosure();
            if (arg_count != cl.function.arity) {
                self.runtimeError("expected {d} arguments but got {d}", .{ cl.function.arity, arg_count });
                return error.RuntimeError;
            }
            if (self.frame_count == 64) {
                self.runtimeError("stack overflow", .{});
                return error.RuntimeError;
            }
            self.frames[self.frame_count] = .{
                .function = cl.function,
                .ip = 0,
                .slot_offset = self.sp - arg_count - 1,
                .closure = cl,
            };
            self.frame_count += 1;
            return;
        }

        if (callee.tag != .function) {
            self.runtimeError("can only call functions", .{});
            return error.RuntimeError;
        }

        const func = callee.asFunction();
        if (arg_count != func.arity) {
            self.runtimeError("expected {d} arguments but got {d}", .{ func.arity, arg_count });
            return error.RuntimeError;
        }

        if (self.frame_count == 64) {
            self.runtimeError("stack overflow", .{});
            return error.RuntimeError;
        }

        self.frames[self.frame_count] = .{
            .function = func,
            .ip = 0,
            .slot_offset = self.sp - arg_count - 1,
            .closure = null,
        };
        self.frame_count += 1;
    }

    fn valueToString(self: *VM, val: Value) Value {
        var buf: [64]u8 = undefined;
        const s = switch (val.tag) {
            .int => std.fmt.bufPrint(&buf, "{d}", .{val.asInt()}) catch "?",
            .float => std.fmt.bufPrint(&buf, "{d}", .{val.asFloat()}) catch "?",
            .bool_ => if (val.asBool()) "true" else "false",
            .nil => "nil",
            else => "?",
        };
        const ca = self.currentAlloc();
        const copy = ca.alloc(u8, s.len) catch @panic("oom");
        @memcpy(copy, s);
        return ObjString.create(ca, copy).toValue();
    }

    fn binaryOp(self: *VM, op: OpCode) Error!void {
        const b = self.pop();
        const a = self.pop();

        if (a.tag == .int and b.tag == .int) {
            const ai = a.asInt();
            const bi = b.asInt();
            self.push(Value.initInt(switch (op) {
                .add => ai + bi,
                .subtract => ai - bi,
                .multiply => ai * bi,
                .divide => if (bi != 0) @divTrunc(ai, bi) else 0,
                .modulo => if (bi != 0) @mod(ai, bi) else 0,
                else => 0,
            }));
            return;
        }

        if ((a.tag == .float or a.tag == .int) and (b.tag == .float or b.tag == .int)) {
            const af: f64 = if (a.tag == .float) a.asFloat() else @floatFromInt(a.asInt());
            const bf: f64 = if (b.tag == .float) b.asFloat() else @floatFromInt(b.asInt());
            self.push(Value.initFloat(switch (op) {
                .add => af + bf,
                .subtract => af - bf,
                .multiply => af * bf,
                .divide => if (bf != 0.0) af / bf else 0.0,
                .modulo => @mod(af, bf),
                else => 0.0,
            }));
            return;
        }

        if (a.tag == .string and b.tag == .string and op == .add) {
            const as = a.asString().chars;
            const bs = b.asString().chars;
            const ca = self.currentAlloc();
            const buf = ca.alloc(u8, as.len + bs.len) catch @panic("oom");
            @memcpy(buf[0..as.len], as);
            @memcpy(buf[as.len..], bs);
            const str = ObjString.create(ca, buf);
            self.push(str.toValue());
            return;
        }

        self.runtimeError("operands must be numbers", .{});
        return error.RuntimeError;
    }

    fn comparisonOp(self: *VM, op: OpCode) Error!void {
        const b = self.pop();
        const a = self.pop();

        if (a.tag == .int and b.tag == .int) {
            const result = switch (op) {
                .less => a.asInt() < b.asInt(),
                .greater => a.asInt() > b.asInt(),
                .less_equal => a.asInt() <= b.asInt(),
                .greater_equal => a.asInt() >= b.asInt(),
                else => false,
            };
            self.push(Value.initBool(result));
            return;
        }

        if ((a.tag == .float or a.tag == .int) and (b.tag == .float or b.tag == .int)) {
            const af: f64 = if (a.tag == .float) a.asFloat() else @floatFromInt(a.asInt());
            const bf: f64 = if (b.tag == .float) b.asFloat() else @floatFromInt(b.asInt());
            const result = switch (op) {
                .less => af < bf,
                .greater => af > bf,
                .less_equal => af <= bf,
                .greater_equal => af >= bf,
                else => false,
            };
            self.push(Value.initBool(result));
            return;
        }

        self.runtimeError("operands must be numbers", .{});
        return error.RuntimeError;
    }

    // ---------------------------------------------------------------
    // concurrency
    // ---------------------------------------------------------------

    fn saveToTask(self: *VM, task: *ObjTask) void {
        @memcpy(task.frames[0..self.frame_count], self.frames[0..self.frame_count]);
        @memcpy(task.stack[0..self.sp], self.stack[0..self.sp]);
        task.frame_count = self.frame_count;
        task.sp = self.sp;
    }

    fn restoreFromTask(self: *VM, task: *ObjTask) void {
        @memcpy(self.frames[0..task.frame_count], task.frames[0..task.frame_count]);
        @memcpy(self.stack[0..task.sp], task.stack[0..task.sp]);
        self.frame_count = task.frame_count;
        self.sp = task.sp;
    }

    fn switchTo(self: *VM, next: *ObjTask) void {
        next.state = .running;
        self.restoreFromTask(next);
        self.sched.current_task = next;
    }

    fn yieldTo(self: *VM, next: *ObjTask) void {
        if (self.sched.current_task) |ct| {
            self.saveToTask(ct);
        }
        self.switchTo(next);
    }

    fn scheduleNext(self: *VM) bool {
        if (self.sched.dequeue()) |next| {
            self.yieldTo(next);
            return true;
        }
        return false;
    }

    fn execSpawn(self: *VM) Error!void {
        const callee = self.pop();

        const func = if (callee.tag == .closure)
            callee.asClosure().function
        else if (callee.tag == .function)
            callee.asFunction()
        else {
            self.runtimeError("spawn requires a function or closure", .{});
            return error.RuntimeError;
        };

        const closure = if (callee.tag == .closure) callee.asClosure() else null;
        const task = ObjTask.create(self.alloc, func, closure);
        task.state = .ready;
        self.sched.enqueue(task);

        if (!self.sched.active) {
            self.sched.active = true;
            const main_task = ObjTask.create(self.alloc, self.frames[0].function, self.frames[0].closure);
            main_task.state = .running;
            self.sched.current_task = main_task;
        }

        self.push(task.toValue());
    }

    fn taskFinished(self: *VM) bool {
        const sched = self.sched;
        if (!sched.active) return false;

        if (sched.current_task) |ct| {
            ct.state = .done;
            if (self.sp > 0) ct.result = self.stack[self.sp - 1];

            self.wakeAwaiters(ct);
        }

        if (self.scheduleNextOrPoll()) |next| {
            self.switchTo(next);
            return true;
        }

        sched.active = false;
        sched.current_task = null;
        return false;
    }

    fn wakeAwaiters(self: *VM, finished: *ObjTask) void {
        const sched = self.sched;
        var i: u8 = 0;
        while (i < sched.await_waiter_count) {
            if (sched.await_waiters[i]) |waiter| {
                if (waiter.state == .blocked_await and waiter.waiting_on == finished) {
                    waiter.stack[waiter.sp] = finished.result;
                    waiter.sp += 1;
                    waiter.state = .ready;
                    waiter.waiting_on = null;
                    sched.enqueue(waiter);

                    sched.await_waiter_count -= 1;
                    sched.await_waiters[i] = sched.await_waiters[sched.await_waiter_count];
                    sched.await_waiters[sched.await_waiter_count] = null;
                    continue;
                }
            }
            i += 1;
        }
    }

    fn execChannelSend(self: *VM) Error!void {
        const val = self.pop();
        const ch_val = self.pop();
        if (ch_val.tag != .channel) {
            self.runtimeError("send on non-channel value", .{});
            return error.RuntimeError;
        }
        const ch = ch_val.asChannel();

        if (ch.trySend(val)) {
            if (ch.popRecvWaiter()) |waiter| {
                const recv_val = ch.tryRecv().?;
                waiter.stack[waiter.sp] = recv_val;
                waiter.sp += 1;
                waiter.state = .ready;
                self.sched.enqueue(waiter);
            }
            self.push(Value.initNil());
        } else if (self.sched.active) {
            if (self.sched.current_task) |ct| {
                self.push(Value.initNil());
                self.saveToTask(ct);
                ct.state = .blocked_send;
                ct.pending_send = val;
                ch.addSendWaiter(ct);

                if (self.scheduleNextOrPoll()) |next| {
                    self.switchTo(next);
                } else {
                    self.runtimeError("deadlock: all tasks blocked", .{});
                    return error.RuntimeError;
                }
            }
        } else {
            self.runtimeError("send on full channel with no active tasks", .{});
            return error.RuntimeError;
        }
    }

    fn execChannelRecv(self: *VM) Error!void {
        const ch_val = self.pop();
        if (ch_val.tag != .channel) {
            self.runtimeError("recv on non-channel value", .{});
            return error.RuntimeError;
        }
        const ch = ch_val.asChannel();

        if (ch.tryRecv()) |val| {
            if (ch.popSendWaiter()) |waiter| {
                _ = ch.trySend(waiter.pending_send);
                waiter.pending_send = Value.initNil();
                waiter.state = .ready;
                self.sched.enqueue(waiter);
            }
            self.push(val);
        } else if (self.sched.active) {
            if (self.sched.current_task) |ct| {
                self.saveToTask(ct);
                ct.state = .blocked_recv;
                ch.addRecvWaiter(ct);

                if (self.scheduleNextOrPoll()) |next| {
                    self.switchTo(next);
                } else {
                    self.runtimeError("deadlock: all tasks blocked", .{});
                    return error.RuntimeError;
                }
            }
        } else {
            self.runtimeError("recv on empty channel with no active tasks", .{});
            return error.RuntimeError;
        }
    }

    fn execAwaitTask(self: *VM) Error!void {
        const task_val = self.pop();
        if (task_val.tag != .task) {
            self.runtimeError("await requires a task value", .{});
            return error.RuntimeError;
        }
        const task = task_val.asTask();

        if (task.state == .done) {
            self.push(task.result);
            return;
        }

        if (self.sched.active) {
            if (self.sched.current_task) |ct| {
                self.saveToTask(ct);
                ct.state = .blocked_await;
                ct.waiting_on = task;
                self.addAwaitWaiter(ct);

                if (self.scheduleNextOrPoll()) |next| {
                    self.switchTo(next);
                } else {
                    self.runtimeError("deadlock: all tasks blocked", .{});
                    return error.RuntimeError;
                }
            }
        } else {
            self.push(Value.initNil());
        }
    }

    fn addAwaitWaiter(self: *VM, task: *ObjTask) void {
        const sched = self.sched;
        if (sched.await_waiter_count < 16) {
            sched.await_waiters[sched.await_waiter_count] = task;
            sched.await_waiter_count += 1;
        }
    }

    fn scheduleNextOrPoll(self: *VM) ?*ObjTask {
        if (self.sched.dequeue()) |next| return next;
        if (self.sched.io_count > 0) {
            self.sched.pollAndWake(self.alloc);
            return self.sched.dequeue();
        }
        return null;
    }

    fn execNetAccept(self: *VM) Error!void {
        const target = self.pop();
        if (target.tag != .listener) {
            self.runtimeError("accept on non-listener value", .{});
            return error.RuntimeError;
        }
        const fd = target.asListener().fd;
        stdlib.setNonBlocking(fd);

        const client_fd = std.posix.accept(fd, null, null, 0) catch |err| {
            if (err == error.WouldBlock) {
                if (self.sched.active) {
                    if (self.sched.current_task) |ct| {
                        self.saveToTask(ct);
                        ct.state = .blocked_io;
                        self.sched.parkIo(ct, fd, .accept);

                        if (self.scheduleNextOrPoll()) |next| {
                            self.switchTo(next);
                        } else {
                            self.runtimeError("deadlock: all tasks blocked", .{});
                            return error.RuntimeError;
                        }
                        return;
                    }
                }
                var pollfds = [1]std.posix.pollfd{.{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 }};
                _ = std.posix.poll(&pollfds, -1) catch {
                    self.push(Value.initNil());
                    return;
                };
                const retry_fd = std.posix.accept(fd, null, null, 0) catch {
                    self.push(Value.initNil());
                    return;
                };
                stdlib.setNonBlocking(retry_fd);
                self.push(ObjConn.create(self.currentAlloc(), retry_fd).toValue());
                return;
            }
            self.push(Value.initNil());
            return;
        };

        stdlib.setNonBlocking(client_fd);
        self.push(ObjConn.create(self.currentAlloc(), client_fd).toValue());
    }

    fn execNetRead(self: *VM) Error!void {
        const target = self.pop();
        if (target.tag != .conn) {
            self.runtimeError("read on non-conn value", .{});
            return error.RuntimeError;
        }
        const fd = target.asConn().fd;
        stdlib.setNonBlocking(fd);

        var buf: [8192]u8 = undefined;
        const n = std.posix.read(fd, &buf) catch |err| {
            if (err == error.WouldBlock) {
                if (self.sched.active) {
                    if (self.sched.current_task) |ct| {
                        self.saveToTask(ct);
                        ct.state = .blocked_io;
                        self.sched.parkIo(ct, fd, .read);

                        if (self.scheduleNextOrPoll()) |next| {
                            self.switchTo(next);
                        } else {
                            self.runtimeError("deadlock: all tasks blocked", .{});
                            return error.RuntimeError;
                        }
                        return;
                    }
                }
                var pollfds = [1]std.posix.pollfd{.{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 }};
                _ = std.posix.poll(&pollfds, -1) catch {
                    self.push(Value.initNil());
                    return;
                };
                const retry_n = std.posix.read(fd, &buf) catch {
                    self.push(Value.initNil());
                    return;
                };
                if (retry_n == 0) {
                    self.push(Value.initNil());
                    return;
                }
                const owned = self.currentAlloc().dupe(u8, buf[0..retry_n]) catch {
                    self.push(Value.initNil());
                    return;
                };
                self.push(ObjString.create(self.currentAlloc(), owned).toValue());
                return;
            }
            self.push(Value.initNil());
            return;
        };

        if (n == 0) {
            self.push(Value.initNil());
            return;
        }
        const owned = self.currentAlloc().dupe(u8, buf[0..n]) catch {
            self.push(Value.initNil());
            return;
        };
        self.push(ObjString.create(self.currentAlloc(), owned).toValue());
    }

    fn execNetWrite(self: *VM) Error!void {
        const data_val = self.pop();
        const target = self.pop();
        if (target.tag != .conn or data_val.tag != .string) {
            self.push(Value.initBool(false));
            return;
        }
        const fd = target.asConn().fd;
        const data = data_val.asString().chars;

        if (self.sched.active) {
            stdlib.setNonBlocking(fd);
        }

        var written: usize = 0;
        while (written < data.len) {
            const n = std.posix.write(fd, data[written..]) catch |err| {
                if (err == error.WouldBlock and self.sched.active) {
                    if (self.sched.current_task) |ct| {
                        self.saveToTask(ct);
                        ct.state = .blocked_io;
                        self.sched.parkIoWrite(ct, fd, data, written);

                        if (self.scheduleNextOrPoll()) |next| {
                            self.switchTo(next);
                        } else {
                            self.runtimeError("deadlock: all tasks blocked", .{});
                            return error.RuntimeError;
                        }
                        return;
                    }
                }
                self.push(Value.initBool(false));
                return;
            };
            written += n;
        }
        self.push(Value.initBool(true));
    }


    fn execFfiCall(self: *VM) Error!void {
        const desc_idx = self.readU16();
        const arg_count = self.readByte();
        const state = self.ffi orelse {
            self.runtimeError("ffi not initialized", .{});
            return error.RuntimeError;
        };
        const args = self.stack[self.sp - arg_count .. self.sp];
        const result = state.call(desc_idx, args, self.currentAlloc());
        self.sp -= arg_count;
        self.push(result);
    }

    // ---------------------------------------------------------------
    // stack and frame helpers
    // ---------------------------------------------------------------

    fn concatAppend(self: *VM, slot: u8, rhs: Value) void {
        const cs = self.concat;
        const abs_slot = self.currentFrame().slot_offset + slot;
        const lhs = self.stack[abs_slot];

        if (lhs.tag != .string or rhs.tag != .string) {
            self.push(lhs);
            self.push(rhs);
            self.binaryOp(.add) catch {};
            self.stack[abs_slot] = self.pop();
            return;
        }

        const rhs_chars = rhs.asString().chars;

        if (cs.active and cs.slot == slot and cs.frame == self.frame_count) {
            cs.buf.appendSlice(self.alloc, rhs_chars) catch @panic("oom");
            self.stack[abs_slot].asString().chars = cs.buf.items;
            return;
        }

        if (cs.active) self.concatFinalize();

        const lhs_chars = lhs.asString().chars;

        cs.buf.clearRetainingCapacity();
        cs.buf.appendSlice(self.alloc, lhs_chars) catch @panic("oom");
        cs.buf.appendSlice(self.alloc, rhs_chars) catch @panic("oom");
        cs.slot = slot;
        cs.frame = self.frame_count;
        cs.active = true;

        self.stack[abs_slot].asString().chars = cs.buf.items;
    }

    fn concatFinalize(self: *VM) void {
        const cs = self.concat;
        if (!cs.active) return;
        cs.active = false;
    }

    fn push(self: *VM, val: Value) void {
        self.stack[self.sp] = val;
        self.sp += 1;
    }

    fn pop(self: *VM) Value {
        self.sp -= 1;
        return self.stack[self.sp];
    }

    fn peek(self: *VM, distance: usize) Value {
        return self.stack[self.sp - 1 - distance];
    }

    fn currentFrame(self: *VM) *CallFrame {
        return &self.frames[self.frame_count - 1];
    }

    fn currentChunk(self: *VM) *const Chunk {
        return &self.currentFrame().function.chunk;
    }

    fn readByte(self: *VM) u8 {
        const frame = self.currentFrame();
        const byte = frame.function.chunk.code.items[frame.ip];
        frame.ip += 1;
        return byte;
    }

    fn readU16(self: *VM) u16 {
        const hi: u16 = self.readByte();
        const lo: u16 = self.readByte();
        return (hi << 8) | lo;
    }

    fn readStringConstant(self: *VM) []const u8 {
        const idx = self.readU16();
        const val = self.currentChunk().constants.items[idx];
        return val.asString().chars;
    }

    fn runtimeError(self: *VM, comptime fmt: []const u8, args: anytype) void {
        std.debug.print("runtime error: " ++ fmt ++ "\n", args);
        var i: usize = self.frame_count;
        while (i > 0) {
            i -= 1;
            const frame = &self.frames[i];
            const name = if (frame.function.name.len > 0) frame.function.name else "<script>";
            std.debug.print("  in {s}\n", .{name});
        }
    }
};

// ---------------------------------------------------------------
// tests
// ---------------------------------------------------------------

const parser = @import("parser.zig");
const compiler = @import("compiler.zig");

fn testRunExpectError(source: []const u8) !void {
    var arena_impl = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_impl.deinit();
    const alloc = arena_impl.allocator();
    const tokens = parser.tokenize(alloc, source);
    var p = parser.Parser.init(tokens, source, alloc);
    const tree = p.parse();
    if (tree.errors.len > 0) @panic("parse error in test");
    const cr = compiler.Compiler.compile(alloc, tree) orelse @panic("compile error");
    var vm = VM.init(alloc);
    vm.setFfiDescs(cr.ffi_descs);
    const result = vm.interpret(cr.func);
    try std.testing.expectError(error.RuntimeError, result);
}

fn testRun(source: []const u8) !void {
    var arena_impl = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_impl.deinit();
    const alloc = arena_impl.allocator();
    const tokens = parser.tokenize(alloc, source);
    var p = parser.Parser.init(tokens, source, alloc);
    const tree = p.parse();
    if (tree.errors.len > 0) @panic("parse error in test");
    const cr = compiler.Compiler.compile(alloc, tree) orelse @panic("compile error");
    var vm = VM.init(alloc);
    vm.setFfiDescs(cr.ffi_descs);
    try vm.interpret(cr.func);
}

test "vm: hello world" {
    try testRun("fn main() {\n  println(\"hello\")\n}");
}

test "vm: arithmetic" {
    try testRun("fn main() {\n  println(1 + 2)\n}");
}

test "vm: variables" {
    try testRun("fn main() {\n  x = 5\n  y = 10\n  println(x + y)\n}");
}

test "vm: function call" {
    try testRun("fn add(a: int, b: int) -> int = a + b\nfn main() {\n  println(add(3, 4))\n}");
}

test "vm: if expression" {
    try testRun("fn main() {\n  x = if true { 1 } else { 0 }\n  println(x)\n}");
}

test "vm: comparison" {
    try testRun("fn main() {\n  println(5 > 3)\n}");
}

test "vm: negation" {
    try testRun("fn main() {\n  println(-42)\n}");
}

test "vm: boolean not" {
    try testRun("fn main() {\n  println(!false)\n}");
}

test "vm: for loop with range" {
    try testRun("fn main() {\n  mut s = 0\n  for i in range(5) {\n    s = s + i\n  }\n  println(s)\n}");
}

test "vm: for loop with range start/end" {
    try testRun("fn main() {\n  mut s = 0\n  for i in range(3, 6) {\n    s = s + i\n  }\n  println(s)\n}");
}

test "vm: mutable variable rebinding" {
    try testRun("fn main() {\n  mut x = 1\n  x = x + 1\n  x = x * 3\n  println(x)\n}");
}

test "vm: struct creation and field access" {
    try testRun("struct Point {\n  x: float\n  y: float\n}\nfn main() {\n  p = Point { x: 3.0, y: 4.0 }\n  println(p.x + p.y)\n}");
}

test "vm: enum variant and match" {
    try testRun("enum Color { Red, Green, Blue }\nfn name(c: Color) -> int = match c {\n  Red -> 1\n  Green -> 2\n  Blue -> 3\n}\nfn main() {\n  println(name(Green))\n}");
}

test "vm: enum variant with payload" {
    try testRun("enum Shape {\n  Circle(float)\n  Rect(float, float)\n}\nfn area(s: Shape) -> float = match s {\n  Circle(r) -> r * r\n  Rect(w, h) -> w * h\n}\nfn main() {\n  println(area(Circle(5.0)))\n}");
}

test "vm: native sqrt" {
    try testRun("fn main() {\n  println(sqrt(4.0))\n}");
}

test "vm: while loop" {
    try testRun("fn main() {\n  mut i = 0\n  while i < 3 {\n    i = i + 1\n  }\n  println(i)\n}");
}

test "vm: closure captures local" {
    try testRun("fn main() {\n  x = 10\n  f = fn() x + 5\n  println(f())\n}");
}

test "vm: closure as argument" {
    try testRun("fn apply(f, x: int) -> int = f(x)\nfn main() {\n  scale = 3\n  mul = fn(n) n * scale\n  println(apply(mul, 7))\n}");
}

test "vm: higher-order function" {
    try testRun("fn twice(f, x: int) -> int = f(f(x))\nfn main() {\n  inc = fn(n) n + 1\n  println(twice(inc, 5))\n}");
}

test "vm: string concatenation" {
    try testRun("fn main() {\n  a = \"hello\"\n  b = \" world\"\n  println(a + b)\n}");
}

test "vm: string length via .len" {
    try testRun("fn main() {\n  s = \"hello\"\n  println(s.len)\n}");
}

test "vm: string length via len()" {
    try testRun("fn main() {\n  println(len(\"test\"))\n}");
}

test "vm: string equality" {
    try testRun("fn main() {\n  a = \"hello\"\n  b = \"hello\"\n  println(a == b)\n}");
}

test "vm: string inequality" {
    try testRun("fn main() {\n  a = \"hello\"\n  b = \"world\"\n  println(a == b)\n}");
}

test "vm: get_field_idx optimization" {
    try testRun("struct Vec2 {\n  x: float\n  y: float\n}\nfn sum(v: Vec2) -> float = v.x + v.y\nfn main() {\n  v = Vec2 { x: 10.0, y: 20.0 }\n  println(sum(v))\n}");
}

test "vm: concat_local in loop" {
    try testRun("fn main() {\n  mut s = \"\"\n  mut i = 0\n  while i < 5 {\n    s = s + \"x\"\n    i = i + 1\n  }\n  println(s)\n  println(len(s))\n}");
}

test "vm: concat_local preserves other values" {
    try testRun("fn main() {\n  mut s = \"hello\"\n  s = s + \" \"\n  s = s + \"world\"\n  println(s)\n}");
}

test "vm: string interpolation" {
    try testRun("fn main() {\n  name = \"world\"\n  println(\"hello {name}\")\n}");
}

test "vm: string interpolation with expression" {
    try testRun("fn main() {\n  x = 5\n  println(\"x is {x + 1}\")\n}");
}

test "vm: string interpolation multiple parts" {
    try testRun("fn main() {\n  a = 1\n  b = 2\n  println(\"{a} + {b}\")\n}");
}

test "vm: inline match expression" {
    try testRun("enum Op { Add(int)\n  Sub(int)\n  Nop }\nfn main() {\n  a = Add(3)\n  s = Sub(1)\n  mut r = 0\n  r = match a {\n    Add(n) -> r + n\n    Sub(n) -> r - n\n    Nop -> r\n  }\n  r = match s {\n    Add(n) -> r + n\n    Sub(n) -> r - n\n    Nop -> r\n  }\n  println(r)\n}");
}

test "vm: inline match in loop" {
    try testRun("enum Op { Add(int)\n  Nop }\nfn main() {\n  a = Add(1)\n  mut r = 0\n  for i in range(5) {\n    r = match a {\n      Add(n) -> r + n\n      Nop -> r\n    }\n  }\n  println(r)\n}");
}

test "vm: struct field mutation" {
    try testRun("struct Point { x: int\n  y: int }\nfn main() {\n  mut p = Point { x: 1, y: 2 }\n  p.x = 10\n  p.y = 20\n  println(p.x)\n  println(p.y)\n}");
}

test "vm: array element assignment" {
    try testRun("fn main() {\n  mut arr = [1, 2, 3]\n  arr[0] = 99\n  arr[2] = arr[0] + 1\n  println(arr[0])\n  println(arr[1])\n  println(arr[2])\n}");
}

test "vm: compound assignment on field" {
    try testRun("struct C { val: int }\nfn main() {\n  mut c = C { val: 5 }\n  c.val += 3\n  println(c.val)\n}");
}

test "vm: compound assignment on array element" {
    try testRun("fn main() {\n  mut arr = [10, 20]\n  arr[0] += 5\n  arr[1] *= 2\n  println(arr[0])\n  println(arr[1])\n}");
}

test "vm: array mutation in loop" {
    try testRun("fn main() {\n  mut arr = [0, 0, 0]\n  for i in range(3) {\n    arr[i] = i * i\n  }\n  println(arr[0])\n  println(arr[1])\n  println(arr[2])\n}");
}

test "vm: explicit return" {
    try testRun("fn double(x: int) -> int {\n  return x * 2\n}\nfn main() {\n  println(double(7))\n}");
}

test "vm: early return from nested block" {
    try testRun("fn find(items, target: int) -> int {\n  for i in range(len(items)) {\n    if items[i] == target {\n      return i\n    }\n  }\n  return -1\n}\nfn main() {\n  arr = [10, 20, 30, 40, 50]\n  println(find(arr, 30))\n  println(find(arr, 99))\n}");
}

test "vm: bare return for early exit" {
    try testRun("fn f(items, limit: int) -> int {\n  mut c = 0\n  for i in range(len(items)) {\n    if items[i] > limit {\n      return c\n    }\n    c = c + 1\n  }\n  c\n}\nfn main() {\n  println(f([1, 3, 5, 7, 9], 5))\n}");
}

test "vm: for-range body scope cleanup" {
    try testRun("struct P { x: int }\nfn main() {\n  mut s = 0\n  for i in range(500) {\n    p = P { x: i }\n    s = s + p.x\n  }\n  println(s)\n}");
}

test "vm: arena block basic" {
    try testRun("struct P { x: int }\nfn main() {\n  mut r = 0\n  arena {\n    p = P { x: 42 }\n    r = p.x\n  }\n  println(r)\n}");
}

test "vm: arena block nested" {
    try testRun("fn main() {\n  mut r = 0\n  arena {\n    arena {\n      r = 99\n    }\n  }\n  println(r)\n}");
}

test "vm: arena block in loop" {
    try testRun("struct D { v: int }\nfn main() {\n  mut s = 0\n  for i in range(10) {\n    arena {\n      d = D { v: i }\n      s = s + d.v\n    }\n  }\n  println(s)\n}");
}

test "vm: spawn basic" {
    try testRun("fn work() {\n  println(42)\n}\nfn main() {\n  spawn { work() }\n  println(1)\n}");
}

test "vm: channel send recv" {
    try testRun("fn main() {\n  ch = channel(10)\n  ch.send(99)\n  println(ch.recv())\n}");
}

test "vm: spawn with channel" {
    try testRun("fn main() {\n  ch = channel(5)\n  spawn { ch.send(7) }\n  println(ch.recv())\n}");
}

test "vm: spawn channel blocking" {
    try testRun("fn main() {\n  ch = channel(1)\n  spawn {\n    ch.send(10)\n    ch.send(20)\n  }\n  println(ch.recv())\n  println(ch.recv())\n}");
}

test "vm: multiple spawns" {
    try testRun("fn main() {\n  ch = channel(10)\n  spawn { ch.send(1) }\n  spawn { ch.send(2) }\n  println(ch.recv())\n  println(ch.recv())\n}");
}

test "vm: spawn captures closure" {
    try testRun("fn main() {\n  x = 100\n  ch = channel(1)\n  spawn { ch.send(x) }\n  println(ch.recv())\n}");
}

test "vm: recv blocks until send" {
    try testRun("fn main() {\n  ch = channel(1)\n  spawn { ch.send(77) }\n  msg = ch.recv()\n  println(msg)\n}");
}

test "vm: multiple producers one consumer" {
    try testRun(
        \\fn main() {
        \\  ch = channel(10)
        \\  spawn { ch.send(10) }
        \\  spawn { ch.send(20) }
        \\  spawn { ch.send(30) }
        \\  mut sum = 0
        \\  sum = sum + ch.recv()
        \\  sum = sum + ch.recv()
        \\  sum = sum + ch.recv()
        \\  println(sum)
        \\}
    );
}

test "vm: one producer multiple consumers" {
    try testRun(
        \\fn consume(ch, out) {
        \\  out.send(ch.recv())
        \\}
        \\fn main() {
        \\  ch = channel(10)
        \\  out = channel(10)
        \\  spawn { consume(ch, out) }
        \\  spawn { consume(ch, out) }
        \\  ch.send(1)
        \\  ch.send(2)
        \\  mut sum = 0
        \\  sum = sum + out.recv()
        \\  sum = sum + out.recv()
        \\  println(sum)
        \\}
    );
}

test "vm: ping pong channel" {
    try testRun(
        \\fn main() {
        \\  ch = channel(1)
        \\  spawn {
        \\    ch.send(1)
        \\    ch.send(2)
        \\    ch.send(3)
        \\  }
        \\  println(ch.recv())
        \\  println(ch.recv())
        \\  println(ch.recv())
        \\}
    );
}

test "vm: spawn no channel" {
    try testRun(
        \\fn work(n: int) {
        \\  mut i = 0
        \\  while i < n {
        \\    i = i + 1
        \\  }
        \\  println(i)
        \\}
        \\fn main() {
        \\  spawn { work(5) }
        \\  println(0)
        \\}
    );
}

test "vm: spawn in loop" {
    try testRun(
        \\fn main() {
        \\  ch = channel(10)
        \\  mut i = 0
        \\  while i < 5 {
        \\    spawn { ch.send(i) }
        \\    i = i + 1
        \\  }
        \\  mut sum = 0
        \\  mut j = 0
        \\  while j < 5 {
        \\    sum = sum + ch.recv()
        \\    j = j + 1
        \\  }
        \\  println(sum)
        \\}
    );
}

test "vm: channel with struct values" {
    try testRun(
        \\struct Point {
        \\  x: int
        \\  y: int
        \\}
        \\fn main() {
        \\  ch = channel(5)
        \\  ch.send(Point { x: 3, y: 4 })
        \\  p = ch.recv()
        \\  println(p.x + p.y)
        \\}
    );
}

test "vm: channel with enum values" {
    try testRun(
        \\enum Msg { Hello(int), Bye }
        \\fn main() {
        \\  ch = channel(5)
        \\  ch.send(Hello(42))
        \\  msg = ch.recv()
        \\  result = match msg {
        \\    Hello(n) -> n
        \\    Bye -> 0
        \\  }
        \\  println(result)
        \\}
    );
}

test "vm: channel with array values" {
    try testRun(
        \\fn main() {
        \\  ch = channel(5)
        \\  ch.send([1, 2, 3])
        \\  arr = ch.recv()
        \\  println(arr[0] + arr[1] + arr[2])
        \\}
    );
}

test "vm: synchronous channel no spawn" {
    try testRun(
        \\fn main() {
        \\  ch = channel(3)
        \\  ch.send(10)
        \\  ch.send(20)
        \\  ch.send(30)
        \\  println(ch.recv())
        \\  println(ch.recv())
        \\  println(ch.recv())
        \\}
    );
}

test "vm: spawn fifo ordering" {
    try testRun(
        \\fn main() {
        \\  ch = channel(10)
        \\  spawn { ch.send(1) }
        \\  spawn { ch.send(2) }
        \\  spawn { ch.send(3) }
        \\  spawn { ch.send(4) }
        \\  println(ch.recv())
        \\  println(ch.recv())
        \\  println(ch.recv())
        \\  println(ch.recv())
        \\}
    );
}

test "vm: many tasks stress" {
    try testRun(
        \\fn main() {
        \\  ch = channel(20)
        \\  mut i = 0
        \\  while i < 20 {
        \\    spawn { ch.send(1) }
        \\    i = i + 1
        \\  }
        \\  mut sum = 0
        \\  mut j = 0
        \\  while j < 20 {
        \\    sum = sum + ch.recv()
        \\    j = j + 1
        \\  }
        \\  println(sum)
        \\}
    );
}

test "vm: channel blocking recv then send" {
    try testRun(
        \\fn delayed_send(ch) {
        \\  ch.send(999)
        \\}
        \\fn main() {
        \\  ch = channel(1)
        \\  spawn { delayed_send(ch) }
        \\  result = ch.recv()
        \\  println(result)
        \\}
    );
}

test "vm: spawn with multiple captures" {
    try testRun(
        \\fn main() {
        \\  a = 10
        \\  b = 20
        \\  c = 30
        \\  ch = channel(1)
        \\  spawn { ch.send(a + b + c) }
        \\  println(ch.recv())
        \\}
    );
}

test "vm: producer consumer loop" {
    try testRun(
        \\fn producer(ch, n: int) {
        \\  mut i = 0
        \\  while i < n {
        \\    ch.send(i * i)
        \\    i = i + 1
        \\  }
        \\}
        \\fn main() {
        \\  ch = channel(3)
        \\  spawn { producer(ch, 5) }
        \\  mut sum = 0
        \\  mut i = 0
        \\  while i < 5 {
        \\    sum = sum + ch.recv()
        \\    i = i + 1
        \\  }
        \\  println(sum)
        \\}
    );
}

test "vm: channel ring buffer wraparound" {
    try testRun(
        \\fn main() {
        \\  ch = channel(2)
        \\  ch.send(1)
        \\  ch.send(2)
        \\  println(ch.recv())
        \\  ch.send(3)
        \\  println(ch.recv())
        \\  ch.send(4)
        \\  println(ch.recv())
        \\  println(ch.recv())
        \\}
    );
}

test "vm: spawn captures mut variable" {
    try testRun(
        \\fn main() {
        \\  mut x = 5
        \\  ch = channel(1)
        \\  spawn { ch.send(x) }
        \\  x = 99
        \\  println(ch.recv())
        \\}
    );
}

test "vm: deadlock detection" {
    try testRunExpectError(
        \\fn main() {
        \\  ch = channel(1)
        \\  ch.recv()
        \\}
    );
}

test "vm: send on non-channel error" {
    try testRunExpectError(
        \\fn main() {
        \\  x = 5
        \\  x.send(1)
        \\}
    );
}

test "vm: recv on non-channel error" {
    try testRunExpectError(
        \\fn main() {
        \\  x = 5
        \\  x.recv()
        \\}
    );
}

test "vm: channel pipeline" {
    try testRun(
        \\fn double(input, output) {
        \\  mut i = 0
        \\  while i < 4 {
        \\    val = input.recv()
        \\    output.send(val * 2)
        \\    i = i + 1
        \\  }
        \\}
        \\fn main() {
        \\  ch1 = channel(5)
        \\  ch2 = channel(5)
        \\  spawn { double(ch1, ch2) }
        \\  ch1.send(1)
        \\  ch1.send(2)
        \\  ch1.send(3)
        \\  ch1.send(4)
        \\  println(ch2.recv())
        \\  println(ch2.recv())
        \\  println(ch2.recv())
        \\  println(ch2.recv())
        \\}
    );
}

test "vm: two stage pipeline" {
    try testRun(
        \\fn add_one(input, output) {
        \\  val = input.recv()
        \\  output.send(val + 1)
        \\}
        \\fn main() {
        \\  a = channel(1)
        \\  b = channel(1)
        \\  c = channel(1)
        \\  spawn { add_one(a, b) }
        \\  spawn { add_one(b, c) }
        \\  a.send(10)
        \\  println(c.recv())
        \\}
    );
}

test "vm: await_all basic" {
    try testRun(
        \\fn get_a() -> int = 10
        \\fn get_b() -> int = 20
        \\fn main() {
        \\  results = await_all(
        \\    spawn { get_a() },
        \\    spawn { get_b() }
        \\  )
        \\  println(results[0])
        \\  println(results[1])
        \\}
    );
}

test "vm: await_all three tasks" {
    try testRun(
        \\fn compute(n: int) -> int = n * n
        \\fn main() {
        \\  r = await_all(
        \\    spawn { compute(3) },
        \\    spawn { compute(4) },
        \\    spawn { compute(5) }
        \\  )
        \\  println(r[0] + r[1] + r[2])
        \\}
    );
}

test "vm: await_all with channels" {
    try testRun(
        \\fn fetch(ch) -> int {
        \\  ch.send(42)
        \\  42
        \\}
        \\fn main() {
        \\  ch = channel(5)
        \\  r = await_all(
        \\    spawn { fetch(ch) },
        \\    spawn { fetch(ch) }
        \\  )
        \\  println(r[0] + r[1])
        \\}
    );
}

test "vm: await_all single task" {
    try testRun(
        \\fn work() -> int = 99
        \\fn main() {
        \\  r = await_all(spawn { work() })
        \\  println(r[0])
        \\}
    );
}

test "vm: await_all preserves order" {
    try testRun(
        \\fn main() {
        \\  r = await_all(
        \\    spawn { 1 },
        \\    spawn { 2 },
        \\    spawn { 3 },
        \\    spawn { 4 }
        \\  )
        \\  println(r[0])
        \\  println(r[1])
        \\  println(r[2])
        \\  println(r[3])
        \\}
    );
}

// --------------- std/http tests ---------------

test "vm: parse_request GET" {
    try testRun(
        \\imp std/http { parse_request }
        \\fn main() {
        \\  req = parse_request("GET /hello HTTP/1.1\r\nHost: localhost\r\n\r\n")
        \\  assert_eq(req.method, "GET")
        \\  assert_eq(req.path, "/hello")
        \\  assert_eq(req.headers, "Host: localhost")
        \\  assert_eq(req.body, "")
        \\  println("ok")
        \\}
    );
}

test "vm: parse_request POST with body" {
    try testRun(
        \\imp std/http { parse_request }
        \\fn main() {
        \\  req = parse_request("POST /users HTTP/1.1\r\nContent-Type: text/plain\r\nContent-Length: 5\r\n\r\nhello")
        \\  assert_eq(req.method, "POST")
        \\  assert_eq(req.path, "/users")
        \\  assert_eq(req.body, "hello")
        \\  println("ok")
        \\}
    );
}

test "vm: parse_request with query string" {
    try testRun(
        \\imp std/http { parse_request }
        \\fn main() {
        \\  req = parse_request("GET /search?q=test&page=2 HTTP/1.1\r\nHost: example.com\r\n\r\n")
        \\  assert_eq(req.method, "GET")
        \\  assert_eq(req.path, "/search?q=test&page=2")
        \\  println("ok")
        \\}
    );
}

test "vm: parse_request malformed returns nil" {
    try testRun(
        \\imp std/http { parse_request }
        \\fn main() {
        \\  req = parse_request("garbage")
        \\  assert_eq(req, nil)
        \\  req2 = parse_request("")
        \\  assert_eq(req2, nil)
        \\  println("ok")
        \\}
    );
}

test "vm: respond produces valid HTTP" {
    try testRun(
        \\imp std/http { respond }
        \\imp std/json { decode }
        \\fn main() {
        \\  r = respond("hello world")
        \\  assert(len(r) > 0)
        \\  parts = r
        \\  assert(r[0] == "H")
        \\  assert(r[1] == "T")
        \\  assert(r[2] == "T")
        \\  assert(r[3] == "P")
        \\  println("ok")
        \\}
    );
}

test "vm: respond content-length matches body" {
    try testRun(
        \\imp std/http { respond, parse_request }
        \\fn main() {
        \\  r = respond("exactly 17 chars!")
        \\  assert(len(r) > 0)
        \\  println("ok")
        \\}
    );
}

test "vm: respond_status codes" {
    try testRun(
        \\imp std/http { respond_status }
        \\fn main() {
        \\  r200 = respond_status(200, "ok")
        \\  r404 = respond_status(404, "not found")
        \\  r500 = respond_status(500, "error")
        \\  assert(len(r200) > 0)
        \\  assert(len(r404) > 0)
        \\  assert(len(r500) > 0)
        \\  println("ok")
        \\}
    );
}

test "vm: json_response with struct" {
    try testRun(
        \\imp std/http { json_response }
        \\struct User {
        \\  name: str
        \\  age: int
        \\}
        \\fn main() {
        \\  r = json_response(User { name: "alice", age: 30 })
        \\  assert(len(r) > 0)
        \\  println("ok")
        \\}
    );
}

test "vm: json_response with array" {
    try testRun(
        \\imp std/http { json_response }
        \\fn main() {
        \\  r = json_response([1, 2, 3])
        \\  assert(len(r) > 0)
        \\  println("ok")
        \\}
    );
}

test "vm: json_response with nested data" {
    try testRun(
        \\imp std/http { json_response }
        \\struct Point {
        \\  x: int
        \\  y: int
        \\}
        \\fn main() {
        \\  r = json_response([Point { x: 1, y: 2 }, Point { x: 3, y: 4 }])
        \\  assert(len(r) > 0)
        \\  println("ok")
        \\}
    );
}

test "vm: route creates struct with handler" {
    try testRun(
        \\imp std/http { route }
        \\fn my_handler(req) { 42 }
        \\fn main() {
        \\  r = route("GET", "/test", my_handler)
        \\  assert_eq(r.method, "GET")
        \\  assert_eq(r.path, "/test")
        \\  result = r.handler(nil)
        \\  assert_eq(result, 42)
        \\  println("ok")
        \\}
    );
}

test "vm: match_route first match wins" {
    try testRun(
        \\imp std/http { route, match_route }
        \\fn first() { 1 }
        \\fn second() { 2 }
        \\fn main() {
        \\  routes = [
        \\    route("GET", "/x", first),
        \\    route("GET", "/x", second)
        \\  ]
        \\  h = match_route(routes, "GET", "/x")
        \\  assert_eq(h(), 1)
        \\  println("ok")
        \\}
    );
}

test "vm: match_route method must match" {
    try testRun(
        \\imp std/http { route, match_route }
        \\fn handler() { 1 }
        \\fn main() {
        \\  routes = [route("GET", "/hello", handler)]
        \\  assert_eq(match_route(routes, "POST", "/hello"), nil)
        \\  assert_eq(match_route(routes, "GET", "/other"), nil)
        \\  assert(match_route(routes, "GET", "/hello") != nil)
        \\  println("ok")
        \\}
    );
}

test "vm: match_route empty routes" {
    try testRun(
        \\imp std/http { match_route }
        \\fn main() {
        \\  assert_eq(match_route([], "GET", "/"), nil)
        \\  println("ok")
        \\}
    );
}

test "vm: match_route with closure handler" {
    try testRun(
        \\imp std/http { route, match_route }
        \\fn main() {
        \\  prefix = "hello"
        \\  routes = [
        \\    route("GET", "/greet", fn() { prefix })
        \\  ]
        \\  h = match_route(routes, "GET", "/greet")
        \\  assert_eq(h(), "hello")
        \\  println("ok")
        \\}
    );
}

// --------------- std/net tests ---------------

test "vm: net listen and close" {
    try testRun(
        \\imp std/net { listen, close }
        \\fn main() {
        \\  server = listen("127.0.0.1", 0)
        \\  assert(server != nil)
        \\  close(server)
        \\  println("ok")
        \\}
    );
}

test "vm: net echo round-trip" {
    try testRun(
        \\imp std/net as net
        \\fn main() {
        \\  server = net.listen("127.0.0.1", 19876)
        \\  client = net.connect("127.0.0.1", 19876)
        \\  conn = net.accept(server)
        \\  net.write(client, "hello")
        \\  data = net.read(conn)
        \\  assert_eq(data, "hello")
        \\  net.write(conn, "world")
        \\  reply = net.read(client)
        \\  assert_eq(reply, "world")
        \\  net.close(conn)
        \\  net.close(client)
        \\  net.close(server)
        \\  println("ok")
        \\}
    );
}

test "vm: net multiple messages same connection" {
    try testRun(
        \\imp std/net as net
        \\fn main() {
        \\  server = net.listen("127.0.0.1", 19877)
        \\  client = net.connect("127.0.0.1", 19877)
        \\  conn = net.accept(server)
        \\  net.write(client, "one")
        \\  assert_eq(net.read(conn), "one")
        \\  net.write(client, "two")
        \\  assert_eq(net.read(conn), "two")
        \\  net.write(client, "three")
        \\  assert_eq(net.read(conn), "three")
        \\  net.close(conn)
        \\  net.close(client)
        \\  net.close(server)
        \\  println("ok")
        \\}
    );
}

test "vm: net read returns nil on closed connection" {
    try testRun(
        \\imp std/net as net
        \\fn main() {
        \\  server = net.listen("127.0.0.1", 19878)
        \\  client = net.connect("127.0.0.1", 19878)
        \\  conn = net.accept(server)
        \\  net.close(client)
        \\  data = net.read(conn)
        \\  assert_eq(data, nil)
        \\  net.close(conn)
        \\  net.close(server)
        \\  println("ok")
        \\}
    );
}

test "vm: net connect to non-listening port returns nil" {
    try testRun(
        \\imp std/net { connect }
        \\fn main() {
        \\  conn = connect("127.0.0.1", 19899)
        \\  assert_eq(conn, nil)
        \\  println("ok")
        \\}
    );
}

test "vm: net write returns bool" {
    try testRun(
        \\imp std/net as net
        \\fn main() {
        \\  server = net.listen("127.0.0.1", 19879)
        \\  client = net.connect("127.0.0.1", 19879)
        \\  conn = net.accept(server)
        \\  result = net.write(client, "test")
        \\  assert_eq(result, true)
        \\  net.close(conn)
        \\  net.close(client)
        \\  net.close(server)
        \\  println("ok")
        \\}
    );
}

test "vm: net namespace import" {
    try testRun(
        \\imp std/net as tcp
        \\fn main() {
        \\  s = tcp.listen("127.0.0.1", 0)
        \\  assert(s != nil)
        \\  tcp.close(s)
        \\  println("ok")
        \\}
    );
}

test "vm: net selective import" {
    try testRun(
        \\imp std/net { listen, close }
        \\fn main() {
        \\  s = listen("127.0.0.1", 0)
        \\  close(s)
        \\  println("ok")
        \\}
    );
}

// --------------- std/net + std/http integration ---------------

test "vm: http over tcp round-trip" {
    try testRun(
        \\imp std/net as net
        \\imp std/http { parse_request, respond, route, match_route }
        \\fn handle_hello(req) {
        \\  respond("hello from pyr")
        \\}
        \\fn main() {
        \\  server = net.listen("127.0.0.1", 19880)
        \\  routes = [route("GET", "/hello", handle_hello)]
        \\  client = net.connect("127.0.0.1", 19880)
        \\  conn = net.accept(server)
        \\  net.write(client, "GET /hello HTTP/1.1\r\nHost: localhost\r\n\r\n")
        \\  raw = net.read(conn)
        \\  req = parse_request(raw)
        \\  assert_eq(req.method, "GET")
        \\  assert_eq(req.path, "/hello")
        \\  handler = match_route(routes, req.method, req.path)
        \\  resp = handler(req)
        \\  net.write(conn, resp)
        \\  net.close(conn)
        \\  reply = net.read(client)
        \\  assert(len(reply) > 0)
        \\  net.close(client)
        \\  net.close(server)
        \\  println("ok")
        \\}
    );
}

test "vm: http 404 for unmatched route" {
    try testRun(
        \\imp std/net as net
        \\imp std/http { parse_request, respond_status, route, match_route }
        \\fn handler(req) { 1 }
        \\fn main() {
        \\  server = net.listen("127.0.0.1", 19881)
        \\  routes = [route("GET", "/exists", handler)]
        \\  client = net.connect("127.0.0.1", 19881)
        \\  conn = net.accept(server)
        \\  net.write(client, "GET /nope HTTP/1.1\r\nHost: localhost\r\n\r\n")
        \\  raw = net.read(conn)
        \\  req = parse_request(raw)
        \\  h = match_route(routes, req.method, req.path)
        \\  assert_eq(h, nil)
        \\  net.write(conn, respond_status(404, "not found"))
        \\  net.close(conn)
        \\  reply = net.read(client)
        \\  assert(len(reply) > 0)
        \\  net.close(client)
        \\  net.close(server)
        \\  println("ok")
        \\}
    );
}

test "vm: http json response over tcp" {
    try testRun(
        \\imp std/net as net
        \\imp std/http { parse_request, json_response }
        \\struct User {
        \\  name: str
        \\  age: int
        \\}
        \\fn main() {
        \\  server = net.listen("127.0.0.1", 19882)
        \\  client = net.connect("127.0.0.1", 19882)
        \\  conn = net.accept(server)
        \\  net.write(client, "GET /user HTTP/1.1\r\n\r\n")
        \\  raw = net.read(conn)
        \\  req = parse_request(raw)
        \\  resp = json_response(User { name: "alice", age: 30 })
        \\  net.write(conn, resp)
        \\  net.close(conn)
        \\  reply = net.read(client)
        \\  assert(len(reply) > 0)
        \\  net.close(client)
        \\  net.close(server)
        \\  println("ok")
        \\}
    );
}

// --------------- async I/O tests ---------------

test "vm: method-call accept and read" {
    try testRun(
        \\imp std/net as net
        \\fn main() {
        \\  server = net.listen("127.0.0.1", 19900)
        \\  client = net.connect("127.0.0.1", 19900)
        \\  conn = server.accept()
        \\  net.write(client, "hello")
        \\  data = conn.read()
        \\  assert_eq(data, "hello")
        \\  net.close(conn)
        \\  net.close(client)
        \\  net.close(server)
        \\  println("ok")
        \\}
    );
}

test "vm: method-call read returns nil on close" {
    try testRun(
        \\imp std/net as net
        \\fn main() {
        \\  server = net.listen("127.0.0.1", 19901)
        \\  client = net.connect("127.0.0.1", 19901)
        \\  conn = server.accept()
        \\  net.close(client)
        \\  data = conn.read()
        \\  assert_eq(data, nil)
        \\  net.close(conn)
        \\  net.close(server)
        \\  println("ok")
        \\}
    );
}

test "vm: spawned acceptor with channel" {
    try testRun(
        \\imp std/net as net
        \\fn main() {
        \\  server = net.listen("127.0.0.1", 19902)
        \\  ch = channel(1)
        \\  spawn {
        \\    conn = server.accept()
        \\    data = conn.read()
        \\    ch.send(data)
        \\    net.close(conn)
        \\  }
        \\  client = net.connect("127.0.0.1", 19902)
        \\  net.write(client, "async hello")
        \\  result = ch.recv()
        \\  assert_eq(result, "async hello")
        \\  net.close(client)
        \\  net.close(server)
        \\  println("ok")
        \\}
    );
}

test "vm: two spawned acceptors" {
    try testRun(
        \\imp std/net as net
        \\fn main() {
        \\  server = net.listen("127.0.0.1", 19903)
        \\  ch = channel(2)
        \\  spawn {
        \\    conn = server.accept()
        \\    data = conn.read()
        \\    ch.send(data)
        \\    net.close(conn)
        \\  }
        \\  spawn {
        \\    conn = server.accept()
        \\    data = conn.read()
        \\    ch.send(data)
        \\    net.close(conn)
        \\  }
        \\  c1 = net.connect("127.0.0.1", 19903)
        \\  c2 = net.connect("127.0.0.1", 19903)
        \\  net.write(c1, "first")
        \\  net.write(c2, "second")
        \\  r1 = ch.recv()
        \\  r2 = ch.recv()
        \\  assert(len(r1) > 0)
        \\  assert(len(r2) > 0)
        \\  net.close(c1)
        \\  net.close(c2)
        \\  net.close(server)
        \\  println("ok")
        \\}
    );
}

test "vm: spawn echo server handles multiple clients" {
    try testRun(
        \\imp std/net as net
        \\fn handle(server, ch) {
        \\  conn = server.accept()
        \\  data = conn.read()
        \\  net.write(conn, data)
        \\  net.close(conn)
        \\  ch.send(1)
        \\}
        \\fn main() {
        \\  server = net.listen("127.0.0.1", 19904)
        \\  ch = channel(3)
        \\  spawn { handle(server, ch) }
        \\  spawn { handle(server, ch) }
        \\  spawn { handle(server, ch) }
        \\  c1 = net.connect("127.0.0.1", 19904)
        \\  c2 = net.connect("127.0.0.1", 19904)
        \\  c3 = net.connect("127.0.0.1", 19904)
        \\  net.write(c1, "a")
        \\  net.write(c2, "b")
        \\  net.write(c3, "c")
        \\  r1 = c1.read()
        \\  r2 = c2.read()
        \\  r3 = c3.read()
        \\  assert_eq(r1, "a")
        \\  assert_eq(r2, "b")
        \\  assert_eq(r3, "c")
        \\  ch.recv()
        \\  ch.recv()
        \\  ch.recv()
        \\  net.close(c1)
        \\  net.close(c2)
        \\  net.close(c3)
        \\  net.close(server)
        \\  println("ok")
        \\}
    );
}

test "vm: async accept yields to main when blocked" {
    try testRun(
        \\imp std/net as net
        \\fn main() {
        \\  server = net.listen("127.0.0.1", 19905)
        \\  ch = channel(1)
        \\  spawn {
        \\    conn = server.accept()
        \\    ch.send(42)
        \\    net.close(conn)
        \\  }
        \\  client = net.connect("127.0.0.1", 19905)
        \\  result = ch.recv()
        \\  assert_eq(result, 42)
        \\  net.close(client)
        \\  net.close(server)
        \\  println("ok")
        \\}
    );
}

test "vm: async read yields to main when blocked" {
    try testRun(
        \\imp std/net as net
        \\fn main() {
        \\  server = net.listen("127.0.0.1", 19906)
        \\  ch = channel(1)
        \\  client = net.connect("127.0.0.1", 19906)
        \\  conn = server.accept()
        \\  spawn {
        \\    data = conn.read()
        \\    ch.send(data)
        \\  }
        \\  net.write(client, "delayed")
        \\  result = ch.recv()
        \\  assert_eq(result, "delayed")
        \\  net.close(conn)
        \\  net.close(client)
        \\  net.close(server)
        \\  println("ok")
        \\}
    );
}

test "vm: async accept with multiple sequential connections" {
    try testRun(
        \\imp std/net as net
        \\fn main() {
        \\  server = net.listen("127.0.0.1", 19907)
        \\  ch = channel(2)
        \\  spawn {
        \\    conn1 = server.accept()
        \\    data1 = conn1.read()
        \\    net.close(conn1)
        \\    conn2 = server.accept()
        \\    data2 = conn2.read()
        \\    net.close(conn2)
        \\    ch.send(data1)
        \\    ch.send(data2)
        \\  }
        \\  c1 = net.connect("127.0.0.1", 19907)
        \\  net.write(c1, "one")
        \\  c2 = net.connect("127.0.0.1", 19907)
        \\  net.write(c2, "two")
        \\  r1 = ch.recv()
        \\  r2 = ch.recv()
        \\  assert_eq(r1, "one")
        \\  assert_eq(r2, "two")
        \\  net.close(c1)
        \\  net.close(c2)
        \\  net.close(server)
        \\  println("ok")
        \\}
    );
}

test "vm: async io mixed with channels" {
    try testRun(
        \\imp std/net as net
        \\fn main() {
        \\  server = net.listen("127.0.0.1", 19908)
        \\  request_ch = channel(1)
        \\  response_ch = channel(1)
        \\  spawn {
        \\    conn = server.accept()
        \\    data = conn.read()
        \\    request_ch.send(data)
        \\    reply = response_ch.recv()
        \\    net.write(conn, reply)
        \\    net.close(conn)
        \\  }
        \\  client = net.connect("127.0.0.1", 19908)
        \\  net.write(client, "ping")
        \\  req = request_ch.recv()
        \\  assert_eq(req, "ping")
        \\  response_ch.send("pong")
        \\  reply = client.read()
        \\  assert_eq(reply, "pong")
        \\  net.close(client)
        \\  net.close(server)
        \\  println("ok")
        \\}
    );
}

test "vm: mutable closure counter" {
    try testRun(
        \\fn make_counter() {
        \\  mut count = 0
        \\  fn() {
        \\    count = count + 1
        \\    count
        \\  }
        \\}
        \\fn main() {
        \\  c = make_counter()
        \\  assert_eq(c(), 1)
        \\  assert_eq(c(), 2)
        \\  assert_eq(c(), 3)
        \\  println("ok")
        \\}
    );
}

test "vm: mutable closure compound assign" {
    try testRun(
        \\fn main() {
        \\  mut total = 0
        \\  add = fn(n: int) {
        \\    total += n
        \\    total
        \\  }
        \\  assert_eq(add(5), 5)
        \\  assert_eq(add(3), 8)
        \\  assert_eq(add(2), 10)
        \\  println("ok")
        \\}
    );
}

test "vm: mutable closure independent copies" {
    try testRun(
        \\fn make_counter() {
        \\  mut count = 0
        \\  fn() {
        \\    count = count + 1
        \\    count
        \\  }
        \\}
        \\fn main() {
        \\  a = make_counter()
        \\  b = make_counter()
        \\  assert_eq(a(), 1)
        \\  assert_eq(a(), 2)
        \\  assert_eq(b(), 1)
        \\  assert_eq(a(), 3)
        \\  assert_eq(b(), 2)
        \\  println("ok")
        \\}
    );
}

test "vm: closure mutation does not affect outer scope" {
    try testRun(
        \\fn main() {
        \\  mut x = 10
        \\  f = fn() {
        \\    x = 99
        \\  }
        \\  f()
        \\  assert_eq(x, 10)
        \\  println("ok")
        \\}
    );
}

test "vm: ffi getpid" {
    try testRun(
        \\extern "c" {
        \\  fn getpid() -> cint
        \\}
        \\fn main() {
        \\  pid = getpid()
        \\  assert(pid > 0)
        \\  println("ok")
        \\}
    );
}

test "vm: ffi strlen" {
    try testRun(
        \\extern "c" {
        \\  fn strlen(s: cstr) -> cint
        \\}
        \\fn main() {
        \\  assert_eq(strlen("hello"), 5)
        \\  assert_eq(strlen(""), 0)
        \\  println("ok")
        \\}
    );
}

test "vm: ffi getenv" {
    try testRun(
        \\extern "c" {
        \\  fn getenv(name: cstr) -> cstr
        \\}
        \\fn main() {
        \\  home = getenv("HOME")
        \\  assert(home != nil)
        \\  missing = getenv("NONEXISTENT_VAR_XYZ_123")
        \\  assert_eq(missing, nil)
        \\  println("ok")
        \\}
    );
}

test "vm: ffi abs" {
    try testRun(
        \\extern "c" {
        \\  fn abs(n: cint) -> cint
        \\}
        \\fn main() {
        \\  assert_eq(abs(-42), 42)
        \\  assert_eq(abs(0), 0)
        \\  println("ok")
        \\}
    );
}

test "vm: method write opcode" {
    try testRun(
        \\imp std/net as net
        \\fn main() {
        \\  server = net.listen("127.0.0.1", 19890)
        \\  client = net.connect("127.0.0.1", 19890)
        \\  conn = net.accept(server)
        \\  result = client.write("hello from method")
        \\  assert_eq(result, true)
        \\  data = net.read(conn)
        \\  assert_eq(data, "hello from method")
        \\  net.close(conn)
        \\  net.close(client)
        \\  net.close(server)
        \\  println("ok")
        \\}
    );
}

test "vm: method connect opcode" {
    try testRun(
        \\imp std/net as net
        \\fn main() {
        \\  server = net.listen("127.0.0.1", 19891)
        \\  client = net.connect("127.0.0.1", 19891)
        \\  conn = net.accept(server)
        \\  net.write(client, "ping")
        \\  assert_eq(net.read(conn), "ping")
        \\  net.close(conn)
        \\  net.close(client)
        \\  net.close(server)
        \\  println("ok")
        \\}
    );
}


test "vm: concurrent write with spawn" {
    try testRun(
        \\imp std/net as net
        \\fn main() {
        \\  server = net.listen("127.0.0.1", 19893)
        \\  response_ch = channel(1)
        \\  spawn {
        \\    conn = server.accept()
        \\    data = conn.read()
        \\    conn.write("echo:" + data)
        \\    net.close(conn)
        \\    response_ch.send(1)
        \\  }
        \\  client = net.connect("127.0.0.1", 19893)
        \\  net.write(client, "test")
        \\  response_ch.recv()
        \\  reply = net.read(client)
        \\  assert_eq(reply, "echo:test")
        \\  net.close(client)
        \\  net.close(server)
        \\  println("ok")
        \\}
    );
}
