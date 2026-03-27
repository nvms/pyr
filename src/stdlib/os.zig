const std = @import("std");
const Value = @import("../value.zig").Value;
const ObjString = @import("../value.zig").ObjString;
const ObjArray = @import("../value.zig").ObjArray;
const root = @import("../stdlib.zig");

pub const fns = [_]root.NativeDef{
    .{ .name = "env", .arity = 1, .func = &osEnv },
    .{ .name = "args", .arity = 0, .func = &osArgs },
    .{ .name = "exit", .arity = 1, .func = &osExit },
};

fn osEnv(alloc: std.mem.Allocator, args: []const Value) Value {
    if (args[0].tag != .string) return Value.initNil();
    const key = args[0].asString().chars;
    const keyz = alloc.dupeZ(u8, key) catch return Value.initNil();
    defer alloc.free(keyz);
    const val = std.posix.getenv(keyz) orelse return Value.initNil();
    const owned = alloc.dupe(u8, val) catch return Value.initNil();
    return ObjString.create(alloc, owned).toValue();
}

fn osArgs(alloc: std.mem.Allocator, _: []const Value) Value {
    const a = std.process.argsAlloc(std.heap.page_allocator) catch return ObjArray.create(alloc, &.{}).toValue();
    defer std.process.argsFree(std.heap.page_allocator, a);
    const arr = ObjArray.create(alloc, &.{});
    for (a) |arg| {
        const s = ObjString.create(alloc, alloc.dupe(u8, arg) catch "");
        arr.push(alloc, s.toValue());
    }
    return arr.toValue();
}

fn osExit(_: std.mem.Allocator, args: []const Value) Value {
    const code: u8 = if (args[0].tag == .int) @intCast(@as(i64, @max(0, @min(255, args[0].asInt())))) else 1;
    std.process.exit(code);
}
