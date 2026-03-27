const std = @import("std");
const Value = @import("../value.zig").Value;
const ObjString = @import("../value.zig").ObjString;
const root = @import("../stdlib.zig");

pub const fns = [_]root.NativeDef{
    .{ .name = "println", .arity = 1, .func = &ioPrintln },
    .{ .name = "print", .arity = 1, .func = &ioPrint },
    .{ .name = "eprintln", .arity = 1, .func = &ioEprintln },
    .{ .name = "eprint", .arity = 1, .func = &ioEprint },
    .{ .name = "readln", .arity = 0, .func = &ioReadln },
};

fn ioPrintln(alloc: std.mem.Allocator, args: []const Value) Value {
    root.writeValueTo(alloc, std.posix.STDOUT_FILENO, args[0]);
    root.writeBytes(std.posix.STDOUT_FILENO, "\n");
    return Value.initNil();
}

fn ioPrint(alloc: std.mem.Allocator, args: []const Value) Value {
    root.writeValueTo(alloc, std.posix.STDOUT_FILENO, args[0]);
    return Value.initNil();
}

fn ioEprintln(alloc: std.mem.Allocator, args: []const Value) Value {
    root.writeValueTo(alloc, std.posix.STDERR_FILENO, args[0]);
    root.writeBytes(std.posix.STDERR_FILENO, "\n");
    return Value.initNil();
}

fn ioEprint(alloc: std.mem.Allocator, args: []const Value) Value {
    root.writeValueTo(alloc, std.posix.STDERR_FILENO, args[0]);
    return Value.initNil();
}

fn ioReadln(alloc: std.mem.Allocator, _: []const Value) Value {
    var buf = std.ArrayListUnmanaged(u8){};
    const fd = std.posix.STDIN_FILENO;
    while (true) {
        var byte: [1]u8 = undefined;
        const n = std.posix.read(fd, &byte) catch return Value.initNil();
        if (n == 0) {
            if (buf.items.len == 0) return Value.initNil();
            break;
        }
        if (byte[0] == '\n') break;
        buf.append(alloc, byte[0]) catch return Value.initNil();
    }
    return ObjString.create(alloc, buf.items).toValue();
}
