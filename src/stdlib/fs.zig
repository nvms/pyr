const std = @import("std");
const Value = @import("../value.zig").Value;
const ObjString = @import("../value.zig").ObjString;
const root = @import("../stdlib.zig");

pub const fns = [_]root.NativeDef{
    .{ .name = "read", .arity = 1, .func = &fsRead },
    .{ .name = "write", .arity = 2, .func = &fsWrite },
    .{ .name = "append", .arity = 2, .func = &fsAppend },
    .{ .name = "exists", .arity = 1, .func = &fsExists },
    .{ .name = "remove", .arity = 1, .func = &fsRemove },
};

fn fsRead(alloc: std.mem.Allocator, args: []const Value) Value {
    if (args[0].tag() != .string) return root.makeIoError(alloc, "read requires string path");
    const path = args[0].asString().chars;
    const content = std.fs.cwd().readFileAlloc(alloc, path, 10 * 1024 * 1024) catch return root.makeIoError(alloc, "read failed");
    return ObjString.create(alloc, content).toValue();
}

fn fsWrite(alloc: std.mem.Allocator, args: []const Value) Value {
    if (args[0].tag() != .string or args[1].tag() != .string) return root.makeIoError(alloc, "write requires string path and content");
    const path = args[0].asString().chars;
    const content = args[1].asString().chars;
    const file = std.fs.cwd().createFile(path, .{}) catch return root.makeIoError(alloc, "write failed");
    defer file.close();
    file.writeAll(content) catch return root.makeIoError(alloc, "write failed");
    return Value.initBool(true);
}

fn fsAppend(alloc: std.mem.Allocator, args: []const Value) Value {
    if (args[0].tag() != .string or args[1].tag() != .string) return root.makeIoError(alloc, "append requires string path and content");
    const path = args[0].asString().chars;
    const content = args[1].asString().chars;
    const file = std.fs.cwd().openFile(path, .{ .mode = .write_only }) catch
        std.fs.cwd().createFile(path, .{}) catch return root.makeIoError(alloc, "append failed");
    defer file.close();
    file.seekFromEnd(0) catch return root.makeIoError(alloc, "append failed");
    file.writeAll(content) catch return root.makeIoError(alloc, "append failed");
    return Value.initBool(true);
}

fn fsExists(_: std.mem.Allocator, args: []const Value) Value {
    if (args[0].tag() != .string) return Value.initBool(false);
    const path = args[0].asString().chars;
    std.fs.cwd().access(path, .{}) catch return Value.initBool(false);
    return Value.initBool(true);
}

fn fsRemove(alloc: std.mem.Allocator, args: []const Value) Value {
    if (args[0].tag() != .string) return root.makeIoError(alloc, "remove requires string path");
    const path = args[0].asString().chars;
    std.fs.cwd().deleteFile(path) catch return root.makeIoError(alloc, "remove failed");
    return Value.initBool(true);
}
