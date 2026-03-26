const std = @import("std");
const Chunk = @import("chunk.zig").Chunk;
const OpCode = @import("chunk.zig").OpCode;
const Value = @import("value.zig").Value;
const ObjFunction = @import("value.zig").ObjFunction;
const ObjString = @import("value.zig").ObjString;

pub const VM = struct {
    frames: [64]CallFrame,
    frame_count: usize,
    stack: [256]Value,
    sp: usize,
    globals: std.StringHashMapUnmanaged(Value),
    alloc: std.mem.Allocator,

    pub const CallFrame = struct {
        function: *ObjFunction,
        ip: usize,
        slot_offset: usize,
    };

    pub const Error = error{RuntimeError};

    pub fn init(alloc: std.mem.Allocator) VM {
        return .{
            .frames = undefined,
            .frame_count = 0,
            .stack = undefined,
            .sp = 0,
            .globals = .{},
            .alloc = alloc,
        };
    }

    pub fn interpret(self: *VM, function: *ObjFunction) Error!void {
        self.push(function.toValue());
        self.frames[0] = .{
            .function = function,
            .ip = 0,
            .slot_offset = 0,
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
                    try self.callValue(self.stack[self.sp - 1 - arg_count], arg_count);
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
            }
        }
    }

    fn callValue(self: *VM, callee: Value, arg_count: u8) Error!void {
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
