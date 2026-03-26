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

pub const ConcatState = struct {
    buf: std.ArrayListUnmanaged(u8),
    slot: u8,
    frame: usize,
    active: bool,

    fn init() ConcatState {
        return .{ .buf = .{}, .slot = 0, .frame = 0, .active = false };
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
        return .{
            .frames = undefined,
            .frame_count = 0,
            .stack = undefined,
            .sp = 0,
            .globals = .{},
            .alloc = alloc,
            .concat = cs,
        };
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
                    if (self.frame_count == 0) return;
                    self.sp = slot;
                    self.push(result);
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

                    const field_names = self.alloc.alloc([]const u8, field_count) catch @panic("oom");
                    const temp_values = self.alloc.alloc(Value, field_count) catch @panic("oom");

                    for (0..field_count) |fi| {
                        const fi_idx = self.readU16();
                        field_names[fi] = self.currentChunk().constants.items[fi_idx].asString().chars;
                    }

                    var fc: usize = field_count;
                    while (fc > 0) {
                        fc -= 1;
                        temp_values[fc] = self.pop();
                    }

                    const s = ObjStruct.create(self.alloc, name, field_names, temp_values);
                    self.alloc.free(temp_values);
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

                .enum_variant => {
                    const variant_idx = self.readU16();
                    const type_idx = self.readU16();
                    const payload_count = self.readByte();
                    const variant_name = self.currentChunk().constants.items[variant_idx].asString().chars;
                    const type_name = self.currentChunk().constants.items[type_idx].asString().chars;

                    const payloads = self.alloc.alloc(Value, payload_count) catch @panic("oom");
                    var pc: usize = payload_count;
                    while (pc > 0) {
                        pc -= 1;
                        payloads[pc] = self.pop();
                    }

                    const e = ObjEnum.create(self.alloc, type_name, variant_name, payloads);
                    self.push(e.toValue());
                },

                .match_variant => {
                    const name_idx = self.readU16();
                    const variant_name = self.currentChunk().constants.items[name_idx].asString().chars;
                    const val = self.peek(0);
                    if (val.tag == .enum_) {
                        const e = val.asEnum();
                        self.push(Value.initBool(std.mem.eql(u8, e.variant, variant_name)));
                    } else {
                        self.push(Value.initBool(false));
                    }
                },

                .make_closure => {
                    const idx = self.readU16();
                    const uv_count = self.readByte();
                    const func = self.currentChunk().constants.items[idx].asFunction();
                    const upvalues = self.alloc.alloc(Value, uv_count) catch @panic("oom");
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
                    const cl = ObjClosure.create(self.alloc, func, upvalues);
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
                    const result = nf.func(args);
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
            const buf = self.alloc.alloc(u8, as.len + bs.len) catch @panic("oom");
            @memcpy(buf[0..as.len], as);
            @memcpy(buf[as.len..], bs);
            const str = ObjString.create(self.alloc, buf);
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
            const result = nf.func(args);
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
            const buf = self.alloc.alloc(u8, as.len + bs.len) catch @panic("oom");
            @memcpy(buf[0..as.len], as);
            @memcpy(buf[as.len..], bs);
            const str = ObjString.create(self.alloc, buf);
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

fn testRun(source: []const u8) !void {
    var arena_impl = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_impl.deinit();
    const alloc = arena_impl.allocator();
    const tokens = parser.tokenize(alloc, source);
    var p = parser.Parser.init(tokens, source, alloc);
    const tree = p.parse();
    if (tree.errors.len > 0) @panic("parse error in test");
    const func = compiler.Compiler.compile(alloc, tree) orelse @panic("compile error");
    var vm = VM.init(alloc);
    try vm.interpret(func);
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
