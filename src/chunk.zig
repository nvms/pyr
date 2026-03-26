const std = @import("std");
const Value = @import("value.zig").Value;

pub const OpCode = enum(u8) {
    constant,
    nil,
    true_,
    false_,
    pop,

    get_local,
    set_local,
    get_global,
    set_global,
    define_global,

    add,
    subtract,
    multiply,
    divide,
    modulo,
    negate,

    not,
    equal,
    not_equal,
    less,
    greater,
    less_equal,
    greater_equal,

    jump,
    jump_if_false,
    loop_,

    call,
    return_,

    print,
    println,

    struct_create,
    get_field,
    enum_variant,
    match_variant,
    get_payload,

    make_closure,
    get_upvalue,

    get_field_idx,
    concat_local,

    get_local_field,
    to_str,

    add_int,
    sub_int,
    mul_int,
    div_int,
    mod_int,
    less_int,
    greater_int,
    add_float,
    sub_float,
    mul_float,
    div_float,
    less_float,
    greater_float,
};

pub const Chunk = struct {
    code: std.ArrayListUnmanaged(u8),
    constants: std.ArrayListUnmanaged(Value),
    lines: std.ArrayListUnmanaged(u32),

    pub fn init() Chunk {
        return .{
            .code = .{},
            .constants = .{},
            .lines = .{},
        };
    }

    pub fn write(self: *Chunk, alloc: std.mem.Allocator, byte: u8, line: u32) void {
        self.code.append(alloc, byte) catch @panic("oom");
        self.lines.append(alloc, line) catch @panic("oom");
    }

    pub fn writeOp(self: *Chunk, alloc: std.mem.Allocator, op: OpCode, line: u32) void {
        self.write(alloc, @intFromEnum(op), line);
    }

    pub fn writeU16(self: *Chunk, alloc: std.mem.Allocator, value: u16, line: u32) void {
        self.write(alloc, @intCast((value >> 8) & 0xff), line);
        self.write(alloc, @intCast(value & 0xff), line);
    }

    pub fn addConstant(self: *Chunk, alloc: std.mem.Allocator, value: Value) u16 {
        const idx = self.constants.items.len;
        self.constants.append(alloc, value) catch @panic("oom");
        return @intCast(idx);
    }

    pub fn patchJump(self: *Chunk, offset: usize) void {
        const jump_dist = self.code.items.len - offset - 2;
        self.code.items[offset] = @intCast((jump_dist >> 8) & 0xff);
        self.code.items[offset + 1] = @intCast(jump_dist & 0xff);
    }

    pub fn count(self: *const Chunk) usize {
        return self.code.items.len;
    }
};
