const std = @import("std");
const Value = @import("value.zig").Value;
const ObjString = @import("value.zig").ObjString;

pub const NativeDef = struct {
    name: []const u8,
    arity: u8,
    func: *const fn (std.mem.Allocator, []const Value) Value,
};

pub const StdModule = struct {
    name: []const u8,
    functions: []const NativeDef,
};

pub fn findModule(path: []const []const u8) ?*const StdModule {
    if (path.len != 2) return null;
    if (!std.mem.eql(u8, path[0], "std")) return null;
    for (&modules) |*m| {
        if (std.mem.eql(u8, m.name, path[1])) return m;
    }
    return null;
}

const modules = [_]StdModule{
    .{ .name = "io", .functions = &io_fns },
    .{ .name = "fs", .functions = &fs_fns },
    .{ .name = "os", .functions = &os_fns },
};

// --------------- output helpers ---------------

fn writeBytes(fd: std.posix.fd_t, bytes: []const u8) void {
    var written: usize = 0;
    while (written < bytes.len) {
        written += std.posix.write(fd, bytes[written..]) catch return;
    }
}

fn writeValueTo(alloc: std.mem.Allocator, fd: std.posix.fd_t, v: Value) void {
    switch (v.tag) {
        .nil => writeBytes(fd, "nil"),
        .bool_ => writeBytes(fd, if (v.asBool()) "true" else "false"),
        .int => {
            var buf: [32]u8 = undefined;
            const s = std.fmt.bufPrint(&buf, "{d}", .{v.asInt()}) catch return;
            writeBytes(fd, s);
        },
        .float => {
            var buf: [64]u8 = undefined;
            const s = std.fmt.bufPrint(&buf, "{d}", .{v.asFloat()}) catch return;
            writeBytes(fd, s);
        },
        .string => writeBytes(fd, v.asString().chars),
        .struct_ => {
            const st = v.asStruct();
            writeBytes(fd, st.name);
            writeBytes(fd, " { ");
            const fv = st.fieldValues();
            for (st.field_names, 0..) |name, i| {
                if (i > 0) writeBytes(fd, ", ");
                writeBytes(fd, name);
                writeBytes(fd, ": ");
                writeValueTo(alloc, fd, fv[i]);
            }
            writeBytes(fd, " }");
        },
        .enum_ => {
            const e = v.asEnum();
            writeBytes(fd, e.variant);
            if (e.payloads.len > 0) {
                writeBytes(fd, "(");
                for (e.payloads, 0..) |val, i| {
                    if (i > 0) writeBytes(fd, ", ");
                    writeValueTo(alloc, fd, val);
                }
                writeBytes(fd, ")");
            }
        },
        .function => {
            writeBytes(fd, "<fn ");
            writeBytes(fd, v.asFunction().name);
            writeBytes(fd, ">");
        },
        .native_fn => writeBytes(fd, "<native fn>"),
        .closure => writeBytes(fd, "<closure>"),
    }
}

// --------------- std/io ---------------

const io_fns = [_]NativeDef{
    .{ .name = "println", .arity = 1, .func = &ioPrintln },
    .{ .name = "print", .arity = 1, .func = &ioPrint },
    .{ .name = "eprintln", .arity = 1, .func = &ioEprintln },
    .{ .name = "eprint", .arity = 1, .func = &ioEprint },
    .{ .name = "readln", .arity = 0, .func = &ioReadln },
};

fn ioPrintln(alloc: std.mem.Allocator, args: []const Value) Value {
    writeValueTo(alloc, std.posix.STDOUT_FILENO, args[0]);
    writeBytes(std.posix.STDOUT_FILENO, "\n");
    return Value.initNil();
}

fn ioPrint(alloc: std.mem.Allocator, args: []const Value) Value {
    writeValueTo(alloc, std.posix.STDOUT_FILENO, args[0]);
    return Value.initNil();
}

fn ioEprintln(alloc: std.mem.Allocator, args: []const Value) Value {
    writeValueTo(alloc, std.posix.STDERR_FILENO, args[0]);
    writeBytes(std.posix.STDERR_FILENO, "\n");
    return Value.initNil();
}

fn ioEprint(alloc: std.mem.Allocator, args: []const Value) Value {
    writeValueTo(alloc, std.posix.STDERR_FILENO, args[0]);
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

// --------------- std/fs ---------------

const fs_fns = [_]NativeDef{
    .{ .name = "read", .arity = 1, .func = &fsRead },
    .{ .name = "write", .arity = 2, .func = &fsWrite },
    .{ .name = "append", .arity = 2, .func = &fsAppend },
    .{ .name = "exists", .arity = 1, .func = &fsExists },
    .{ .name = "remove", .arity = 1, .func = &fsRemove },
};

fn fsRead(alloc: std.mem.Allocator, args: []const Value) Value {
    if (args[0].tag != .string) return Value.initNil();
    const path = args[0].asString().chars;
    const content = std.fs.cwd().readFileAlloc(alloc, path, 10 * 1024 * 1024) catch return Value.initNil();
    return ObjString.create(alloc, content).toValue();
}

fn fsWrite(_: std.mem.Allocator, args: []const Value) Value {
    if (args[0].tag != .string or args[1].tag != .string) return Value.initBool(false);
    const path = args[0].asString().chars;
    const content = args[1].asString().chars;
    const file = std.fs.cwd().createFile(path, .{}) catch return Value.initBool(false);
    defer file.close();
    file.writeAll(content) catch return Value.initBool(false);
    return Value.initBool(true);
}

fn fsAppend(_: std.mem.Allocator, args: []const Value) Value {
    if (args[0].tag != .string or args[1].tag != .string) return Value.initBool(false);
    const path = args[0].asString().chars;
    const content = args[1].asString().chars;
    const file = std.fs.cwd().openFile(path, .{ .mode = .write_only }) catch
        std.fs.cwd().createFile(path, .{}) catch return Value.initBool(false);
    defer file.close();
    file.seekFromEnd(0) catch return Value.initBool(false);
    file.writeAll(content) catch return Value.initBool(false);
    return Value.initBool(true);
}

fn fsExists(_: std.mem.Allocator, args: []const Value) Value {
    if (args[0].tag != .string) return Value.initBool(false);
    const path = args[0].asString().chars;
    std.fs.cwd().access(path, .{}) catch return Value.initBool(false);
    return Value.initBool(true);
}

fn fsRemove(_: std.mem.Allocator, args: []const Value) Value {
    if (args[0].tag != .string) return Value.initBool(false);
    const path = args[0].asString().chars;
    std.fs.cwd().deleteFile(path) catch return Value.initBool(false);
    return Value.initBool(true);
}

// --------------- std/os ---------------

const os_fns = [_]NativeDef{
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

fn osArgs(_: std.mem.Allocator, _: []const Value) Value {
    // returns arg count until arrays are implemented
    const a = std.process.argsAlloc(std.heap.page_allocator) catch return Value.initInt(0);
    defer std.process.argsFree(std.heap.page_allocator, a);
    return Value.initInt(@intCast(a.len));
}

fn osExit(_: std.mem.Allocator, args: []const Value) Value {
    const code: u8 = if (args[0].tag == .int) @intCast(@as(i64, @max(0, @min(255, args[0].asInt())))) else 1;
    std.process.exit(code);
}
