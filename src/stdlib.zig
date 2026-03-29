const std = @import("std");
const Value = @import("value.zig").Value;
const ObjString = @import("value.zig").ObjString;
const ObjEnum = @import("value.zig").ObjEnum;

const io = @import("stdlib/io.zig");
const fs = @import("stdlib/fs.zig");
const os = @import("stdlib/os.zig");
const json = @import("stdlib/json.zig");
pub const net = @import("stdlib/net.zig");
const http = @import("stdlib/http.zig");
const tls = @import("stdlib/tls.zig");
pub const gc_mod = @import("stdlib/gc_mod.zig");

pub fn makeIoEof(alloc: std.mem.Allocator) Value {
    return ObjEnum.create(alloc, "IoError", "Eof", 0, &.{}).toValue();
}

pub fn makeIoClosed(alloc: std.mem.Allocator) Value {
    return ObjEnum.create(alloc, "IoError", "Closed", 1, &.{}).toValue();
}

pub fn makeIoError(alloc: std.mem.Allocator, msg: []const u8) Value {
    const owned = alloc.dupe(u8, msg) catch msg;
    const str = ObjString.create(alloc, owned);
    const payloads = alloc.alloc(Value, 1) catch @panic("oom");
    payloads[0] = str.toValue();
    return ObjEnum.create(alloc, "IoError", "Error", 2, payloads).toValue();
}

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
    .{ .name = "io", .functions = &io.fns },
    .{ .name = "fs", .functions = &fs.fns },
    .{ .name = "os", .functions = &os.fns },
    .{ .name = "json", .functions = &json.fns },
    .{ .name = "net", .functions = &net.fns },
    .{ .name = "http", .functions = &http.fns },
    .{ .name = "tls", .functions = &tls.fns },
    .{ .name = "gc", .functions = &gc_mod.fns },
};

pub fn qualifyNative(buf: []u8, func_ptr: *const fn (std.mem.Allocator, []const Value) Value) ?[]const u8 {
    for (&modules) |*m| {
        for (m.functions) |def| {
            if (def.func == func_ptr) {
                return std.fmt.bufPrint(buf, "{s}.{s}", .{ m.name, def.name }) catch null;
            }
        }
    }
    return null;
}

pub fn findNativeByQualified(qualified: []const u8) ?*const fn (std.mem.Allocator, []const Value) Value {
    if (std.mem.indexOfScalar(u8, qualified, '.')) |dot| {
        const mod_name = qualified[0..dot];
        const fn_name = qualified[dot + 1 ..];
        for (&modules) |*m| {
            if (std.mem.eql(u8, m.name, mod_name)) {
                for (m.functions) |def| {
                    if (std.mem.eql(u8, def.name, fn_name)) return def.func;
                }
                return null;
            }
        }
    }
    return null;
}

pub fn writeBytes(fd: std.posix.fd_t, bytes: []const u8) void {
    var written: usize = 0;
    while (written < bytes.len) {
        written += std.posix.write(fd, bytes[written..]) catch return;
    }
}

pub fn writeValueTo(alloc: std.mem.Allocator, fd: std.posix.fd_t, v: Value) void {
    switch (v.tag()) {
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
            for (st.field_names, 0..) |name, idx| {
                if (idx > 0) writeBytes(fd, ", ");
                writeBytes(fd, name);
                writeBytes(fd, ": ");
                if (fv[idx].tag() == .string) {
                    writeBytes(fd, "\"");
                    writeBytes(fd, fv[idx].asString().chars);
                    writeBytes(fd, "\"");
                } else {
                    writeValueTo(alloc, fd, fv[idx]);
                }
            }
            writeBytes(fd, " }");
        },
        .enum_ => {
            const e = v.asEnum();
            writeBytes(fd, e.variant);
            if (e.payloads.len > 0) {
                writeBytes(fd, "(");
                for (e.payloads, 0..) |val, idx| {
                    if (idx > 0) writeBytes(fd, ", ");
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
        .task => writeBytes(fd, "<task>"),
        .channel => writeBytes(fd, "<channel>"),
        .conn => writeBytes(fd, "<conn>"),
        .ext => writeBytes(fd, @tagName(v.extKind())),
        .ptr => {
            var buf: [32]u8 = undefined;
            const s = std.fmt.bufPrint(&buf, "<ptr 0x{x}>", .{v.asPtr()}) catch return;
            writeBytes(fd, s);
        },
        .array => {
            const arr = v.asArray();
            writeBytes(fd, "[");
            for (arr.items, 0..) |item, idx| {
                if (idx > 0) writeBytes(fd, ", ");
                if (item.tag() == .string) {
                    writeBytes(fd, "\"");
                    writeBytes(fd, item.asString().chars);
                    writeBytes(fd, "\"");
                } else {
                    writeValueTo(alloc, fd, item);
                }
            }
            writeBytes(fd, "]");
        },
        .error_val => {
            writeBytes(fd, "error(");
            writeValueTo(alloc, fd, v.asError().value);
            writeBytes(fd, ")");
        },
    }
}

// re-exports for vm.zig
pub const parseAddr = net.parseAddr;
pub const setNonBlocking = net.setNonBlocking;
pub const buildRecvfromResult = net.buildRecvfromResult;
