const std = @import("std");
const Value = @import("value.zig").Value;
const ObjString = @import("value.zig").ObjString;
const ObjArray = @import("value.zig").ObjArray;
const ObjStruct = @import("value.zig").ObjStruct;
const ObjEnum = @import("value.zig").ObjEnum;
const ObjListener = @import("value.zig").ObjListener;
const ObjConn = @import("value.zig").ObjConn;
const ObjDgram = @import("value.zig").ObjDgram;

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
    .{ .name = "io", .functions = &io_fns },
    .{ .name = "fs", .functions = &fs_fns },
    .{ .name = "os", .functions = &os_fns },
    .{ .name = "json", .functions = &json_fns },
    .{ .name = "net", .functions = &net_fns },
    .{ .name = "http", .functions = &http_fns },
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
        .task => writeBytes(fd, "<task>"),
        .channel => writeBytes(fd, "<channel>"),
        .listener => writeBytes(fd, "<listener>"),
        .conn => writeBytes(fd, "<conn>"),
        .dgram => writeBytes(fd, "<dgram>"),
        .ptr => {
            var buf: [32]u8 = undefined;
            const s = std.fmt.bufPrint(&buf, "<ptr 0x{x}>", .{v.data}) catch return;
            writeBytes(fd, s);
        },
        .array => {
            const arr = v.asArray();
            writeBytes(fd, "[");
            for (arr.items, 0..) |item, i| {
                if (i > 0) writeBytes(fd, ", ");
                writeValueTo(alloc, fd, item);
            }
            writeBytes(fd, "]");
        },
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
    if (args[0].tag != .string) return makeIoError(alloc, "read requires string path");
    const path = args[0].asString().chars;
    const content = std.fs.cwd().readFileAlloc(alloc, path, 10 * 1024 * 1024) catch return makeIoError(alloc, "read failed");
    return ObjString.create(alloc, content).toValue();
}

fn fsWrite(alloc: std.mem.Allocator, args: []const Value) Value {
    if (args[0].tag != .string or args[1].tag != .string) return makeIoError(alloc, "write requires string path and content");
    const path = args[0].asString().chars;
    const content = args[1].asString().chars;
    const file = std.fs.cwd().createFile(path, .{}) catch return makeIoError(alloc, "write failed");
    defer file.close();
    file.writeAll(content) catch return makeIoError(alloc, "write failed");
    return Value.initBool(true);
}

fn fsAppend(alloc: std.mem.Allocator, args: []const Value) Value {
    if (args[0].tag != .string or args[1].tag != .string) return makeIoError(alloc, "append requires string path and content");
    const path = args[0].asString().chars;
    const content = args[1].asString().chars;
    const file = std.fs.cwd().openFile(path, .{ .mode = .write_only }) catch
        std.fs.cwd().createFile(path, .{}) catch return makeIoError(alloc, "append failed");
    defer file.close();
    file.seekFromEnd(0) catch return makeIoError(alloc, "append failed");
    file.writeAll(content) catch return makeIoError(alloc, "append failed");
    return Value.initBool(true);
}

fn fsExists(_: std.mem.Allocator, args: []const Value) Value {
    if (args[0].tag != .string) return Value.initBool(false);
    const path = args[0].asString().chars;
    std.fs.cwd().access(path, .{}) catch return Value.initBool(false);
    return Value.initBool(true);
}

fn fsRemove(alloc: std.mem.Allocator, args: []const Value) Value {
    if (args[0].tag != .string) return makeIoError(alloc, "remove requires string path");
    const path = args[0].asString().chars;
    std.fs.cwd().deleteFile(path) catch return makeIoError(alloc, "remove failed");
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

// --------------- std/json ---------------

const json_fns = [_]NativeDef{
    .{ .name = "encode", .arity = 1, .func = &jsonEncode },
    .{ .name = "decode", .arity = 1, .func = &jsonDecode },
};

fn jsonEncode(alloc: std.mem.Allocator, args: []const Value) Value {
    var buf = std.ArrayListUnmanaged(u8){};
    jsonWriteValue(alloc, &buf, args[0]);
    return ObjString.create(alloc, buf.items).toValue();
}

fn jsonWriteValue(alloc: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), v: Value) void {
    switch (v.tag) {
        .nil => buf.appendSlice(alloc, "null") catch return,
        .bool_ => buf.appendSlice(alloc, if (v.asBool()) "true" else "false") catch return,
        .int => {
            var tmp: [32]u8 = undefined;
            const s = std.fmt.bufPrint(&tmp, "{d}", .{v.asInt()}) catch return;
            buf.appendSlice(alloc, s) catch return;
        },
        .float => {
            var tmp: [64]u8 = undefined;
            const s = std.fmt.bufPrint(&tmp, "{d}", .{v.asFloat()}) catch return;
            buf.appendSlice(alloc, s) catch return;
        },
        .string => jsonWriteString(alloc, buf, v.asString().chars),
        .array => {
            const arr = v.asArray();
            buf.append(alloc, '[') catch return;
            for (arr.items, 0..) |item, i| {
                if (i > 0) buf.append(alloc, ',') catch return;
                jsonWriteValue(alloc, buf, item);
            }
            buf.append(alloc, ']') catch return;
        },
        .struct_ => {
            const st = v.asStruct();
            const fv = st.fieldValues();
            buf.append(alloc, '{') catch return;
            for (st.field_names, 0..) |name, i| {
                if (i > 0) buf.append(alloc, ',') catch return;
                jsonWriteString(alloc, buf, name);
                buf.append(alloc, ':') catch return;
                jsonWriteValue(alloc, buf, fv[i]);
            }
            buf.append(alloc, '}') catch return;
        },
        .enum_ => {
            const e = v.asEnum();
            if (e.payloads.len == 0) {
                jsonWriteString(alloc, buf, e.variant);
            } else {
                buf.appendSlice(alloc, "{\"variant\":") catch return;
                jsonWriteString(alloc, buf, e.variant);
                buf.appendSlice(alloc, ",\"payloads\":[") catch return;
                for (e.payloads, 0..) |val, i| {
                    if (i > 0) buf.append(alloc, ',') catch return;
                    jsonWriteValue(alloc, buf, val);
                }
                buf.appendSlice(alloc, "]}") catch return;
            }
        },
        .function, .native_fn, .closure, .task, .channel, .listener, .conn, .dgram, .ptr => buf.appendSlice(alloc, "null") catch return,
    }
}

fn jsonWriteString(alloc: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), s: []const u8) void {
    buf.append(alloc, '"') catch return;
    for (s) |c| {
        switch (c) {
            '"' => buf.appendSlice(alloc, "\\\"") catch return,
            '\\' => buf.appendSlice(alloc, "\\\\") catch return,
            '\n' => buf.appendSlice(alloc, "\\n") catch return,
            '\t' => buf.appendSlice(alloc, "\\t") catch return,
            '\r' => buf.appendSlice(alloc, "\\r") catch return,
            else => {
                if (c < 0x20) {
                    var tmp: [6]u8 = undefined;
                    const esc = std.fmt.bufPrint(&tmp, "\\u{x:0>4}", .{c}) catch return;
                    buf.appendSlice(alloc, esc) catch return;
                } else {
                    buf.append(alloc, c) catch return;
                }
            },
        }
    }
    buf.append(alloc, '"') catch return;
}

fn jsonDecode(alloc: std.mem.Allocator, args: []const Value) Value {
    if (args[0].tag != .string) return Value.initNil();
    var parser = JsonParser{ .src = args[0].asString().chars, .pos = 0, .alloc = alloc };
    return parser.parseValue();
}

const JsonParser = struct {
    src: []const u8,
    pos: usize,
    alloc: std.mem.Allocator,

    fn parseValue(self: *JsonParser) Value {
        self.skipWhitespace();
        if (self.pos >= self.src.len) return Value.initNil();
        return switch (self.src[self.pos]) {
            '"' => self.parseString(),
            '{' => self.parseObject(),
            '[' => self.parseArray(),
            't' => self.parseLiteral("true", Value.initBool(true)),
            'f' => self.parseLiteral("false", Value.initBool(false)),
            'n' => self.parseLiteral("null", Value.initNil()),
            '-', '0'...'9' => self.parseNumber(),
            else => Value.initNil(),
        };
    }

    fn skipWhitespace(self: *JsonParser) void {
        while (self.pos < self.src.len and (self.src[self.pos] == ' ' or self.src[self.pos] == '\t' or self.src[self.pos] == '\n' or self.src[self.pos] == '\r')) {
            self.pos += 1;
        }
    }

    fn parseLiteral(self: *JsonParser, lit: []const u8, val: Value) Value {
        if (self.pos + lit.len > self.src.len) return Value.initNil();
        if (std.mem.eql(u8, self.src[self.pos .. self.pos + lit.len], lit)) {
            self.pos += lit.len;
            return val;
        }
        return Value.initNil();
    }

    fn parseNumber(self: *JsonParser) Value {
        const start = self.pos;
        if (self.pos < self.src.len and self.src[self.pos] == '-') self.pos += 1;
        while (self.pos < self.src.len and self.src[self.pos] >= '0' and self.src[self.pos] <= '9') self.pos += 1;
        var is_float = false;
        if (self.pos < self.src.len and self.src[self.pos] == '.') {
            is_float = true;
            self.pos += 1;
            while (self.pos < self.src.len and self.src[self.pos] >= '0' and self.src[self.pos] <= '9') self.pos += 1;
        }
        if (self.pos < self.src.len and (self.src[self.pos] == 'e' or self.src[self.pos] == 'E')) {
            is_float = true;
            self.pos += 1;
            if (self.pos < self.src.len and (self.src[self.pos] == '+' or self.src[self.pos] == '-')) self.pos += 1;
            while (self.pos < self.src.len and self.src[self.pos] >= '0' and self.src[self.pos] <= '9') self.pos += 1;
        }
        const slice = self.src[start..self.pos];
        if (is_float) {
            const f = std.fmt.parseFloat(f64, slice) catch return Value.initNil();
            return Value.initFloat(f);
        }
        const i = std.fmt.parseInt(i64, slice, 10) catch return Value.initNil();
        return Value.initInt(i);
    }

    fn parseString(self: *JsonParser) Value {
        self.pos += 1; // skip opening "
        var buf = std.ArrayListUnmanaged(u8){};
        while (self.pos < self.src.len and self.src[self.pos] != '"') {
            if (self.src[self.pos] == '\\') {
                self.pos += 1;
                if (self.pos >= self.src.len) break;
                switch (self.src[self.pos]) {
                    '"' => buf.append(self.alloc, '"') catch return Value.initNil(),
                    '\\' => buf.append(self.alloc, '\\') catch return Value.initNil(),
                    '/' => buf.append(self.alloc, '/') catch return Value.initNil(),
                    'n' => buf.append(self.alloc, '\n') catch return Value.initNil(),
                    't' => buf.append(self.alloc, '\t') catch return Value.initNil(),
                    'r' => buf.append(self.alloc, '\r') catch return Value.initNil(),
                    'b' => buf.append(self.alloc, 0x08) catch return Value.initNil(),
                    'f' => buf.append(self.alloc, 0x0c) catch return Value.initNil(),
                    'u' => {
                        self.pos += 1;
                        if (self.pos + 4 > self.src.len) return Value.initNil();
                        const hex = self.src[self.pos .. self.pos + 4];
                        const cp = std.fmt.parseInt(u21, hex, 16) catch return Value.initNil();
                        self.pos += 3; // will be incremented by outer loop
                        var enc: [4]u8 = undefined;
                        const n = std.unicode.utf8Encode(cp, &enc) catch return Value.initNil();
                        buf.appendSlice(self.alloc, enc[0..n]) catch return Value.initNil();
                    },
                    else => buf.append(self.alloc, self.src[self.pos]) catch return Value.initNil(),
                }
            } else {
                buf.append(self.alloc, self.src[self.pos]) catch return Value.initNil();
            }
            self.pos += 1;
        }
        if (self.pos < self.src.len) self.pos += 1; // skip closing "
        return ObjString.create(self.alloc, buf.items).toValue();
    }

    fn parseArray(self: *JsonParser) Value {
        self.pos += 1; // skip [
        self.skipWhitespace();
        const arr = ObjArray.create(self.alloc, &.{});
        if (self.pos < self.src.len and self.src[self.pos] == ']') {
            self.pos += 1;
            return arr.toValue();
        }
        while (self.pos < self.src.len) {
            arr.push(self.alloc, self.parseValue());
            self.skipWhitespace();
            if (self.pos < self.src.len and self.src[self.pos] == ',') {
                self.pos += 1;
                continue;
            }
            break;
        }
        if (self.pos < self.src.len and self.src[self.pos] == ']') self.pos += 1;
        return arr.toValue();
    }

    fn parseObject(self: *JsonParser) Value {
        self.pos += 1; // skip {
        self.skipWhitespace();
        var names = std.ArrayListUnmanaged([]const u8){};
        var values = std.ArrayListUnmanaged(Value){};
        if (self.pos < self.src.len and self.src[self.pos] == '}') {
            self.pos += 1;
            const name_slice = names.toOwnedSlice(self.alloc) catch return Value.initNil();
            const val_slice = values.toOwnedSlice(self.alloc) catch return Value.initNil();
            return ObjStruct.create(self.alloc, "object", name_slice, val_slice).toValue();
        }
        while (self.pos < self.src.len) {
            self.skipWhitespace();
            if (self.pos >= self.src.len or self.src[self.pos] != '"') break;
            const key_val = self.parseString();
            const key = key_val.asString().chars;
            self.skipWhitespace();
            if (self.pos < self.src.len and self.src[self.pos] == ':') self.pos += 1;
            names.append(self.alloc, key) catch return Value.initNil();
            values.append(self.alloc, self.parseValue()) catch return Value.initNil();
            self.skipWhitespace();
            if (self.pos < self.src.len and self.src[self.pos] == ',') {
                self.pos += 1;
                continue;
            }
            break;
        }
        if (self.pos < self.src.len and self.src[self.pos] == '}') self.pos += 1;
        const name_slice = names.toOwnedSlice(self.alloc) catch return Value.initNil();
        const val_slice = values.toOwnedSlice(self.alloc) catch return Value.initNil();
        return ObjStruct.create(self.alloc, "object", name_slice, val_slice).toValue();
    }
};

// --------------- std/net ---------------

const net_fns = [_]NativeDef{
    .{ .name = "listen", .arity = 2, .func = &netListen },
    .{ .name = "accept", .arity = 1, .func = &netAccept },
    .{ .name = "connect", .arity = 2, .func = &netConnect },
    .{ .name = "read", .arity = 1, .func = &netRead },
    .{ .name = "write", .arity = 2, .func = &netWrite },
    .{ .name = "close", .arity = 1, .func = &netClose },
    .{ .name = "timeout", .arity = 2, .func = &netTimeout },
    .{ .name = "udp_bind", .arity = 2, .func = &netUdpBind },
    .{ .name = "udp_open", .arity = 0, .func = &netUdpOpen },
    .{ .name = "sendto", .arity = 4, .func = &netSendto },
    .{ .name = "recvfrom", .arity = 1, .func = &netRecvfrom },
};

pub fn parseAddr(s: []const u8) [4]u8 {
    if (s.len == 0 or std.mem.eql(u8, s, "0.0.0.0")) return .{ 0, 0, 0, 0 };
    if (std.mem.eql(u8, s, "localhost") or std.mem.eql(u8, s, "127.0.0.1")) return .{ 127, 0, 0, 1 };
    var octets: [4]u8 = .{ 0, 0, 0, 0 };
    var parts = std.mem.splitScalar(u8, s, '.');
    var i: usize = 0;
    while (parts.next()) |part| {
        if (i >= 4) return .{ 0, 0, 0, 0 };
        octets[i] = std.fmt.parseInt(u8, part, 10) catch return .{ 0, 0, 0, 0 };
        i += 1;
    }
    return octets;
}

fn netListen(alloc: std.mem.Allocator, args: []const Value) Value {
    if (args[0].tag != .string or args[1].tag != .int) return makeIoError(alloc, "listen requires string and int");
    const addr_str = args[0].asString().chars;
    const port: u16 = @intCast(@as(i64, @max(0, @min(65535, args[1].asInt()))));

    const fd = std.posix.socket(std.posix.AF.INET, std.posix.SOCK.STREAM, 0) catch return makeIoError(alloc, "socket failed");

    const yes: c_int = 1;
    std.posix.setsockopt(fd, std.posix.SOL.SOCKET, std.posix.SO.REUSEADDR, &std.mem.toBytes(yes)) catch {
        std.posix.close(fd);
        return makeIoError(alloc, "setsockopt failed");
    };

    const octets = parseAddr(addr_str);
    const addr = std.net.Address.initIp4(octets, port);
    std.posix.bind(fd, &addr.any, addr.getOsSockLen()) catch {
        std.posix.close(fd);
        return makeIoError(alloc, "bind failed");
    };

    std.posix.listen(fd, 128) catch {
        std.posix.close(fd);
        return makeIoError(alloc, "listen failed");
    };

    return ObjListener.create(alloc, fd, port).toValue();
}

fn netAccept(alloc: std.mem.Allocator, args: []const Value) Value {
    if (args[0].tag != .listener) return makeIoError(alloc, "accept requires listener");
    const listener = args[0].asListener();
    const client_fd = std.posix.accept(listener.fd, null, null, 0) catch return makeIoError(alloc, "accept failed");
    return ObjConn.create(alloc, client_fd).toValue();
}

fn netConnect(alloc: std.mem.Allocator, args: []const Value) Value {
    if (args[0].tag != .string or args[1].tag != .int) return makeIoError(alloc, "connect requires string and int");
    const addr_str = args[0].asString().chars;
    const port: u16 = @intCast(@as(i64, @max(0, @min(65535, args[1].asInt()))));

    const fd = std.posix.socket(std.posix.AF.INET, std.posix.SOCK.STREAM, 0) catch return makeIoError(alloc, "socket failed");
    const octets = parseAddr(addr_str);
    const addr = std.net.Address.initIp4(octets, port);
    std.posix.connect(fd, &addr.any, addr.getOsSockLen()) catch {
        std.posix.close(fd);
        return makeIoError(alloc, "connect failed");
    };

    return ObjConn.create(alloc, fd).toValue();
}

fn netRead(alloc: std.mem.Allocator, args: []const Value) Value {
    if (args[0].tag != .conn) return makeIoError(alloc, "read requires conn");
    const conn = args[0].asConn();
    var buf: [8192]u8 = undefined;
    const n = std.posix.read(conn.fd, &buf) catch return makeIoError(alloc, "read failed");
    if (n == 0) return makeIoEof(alloc);
    const owned = alloc.dupe(u8, buf[0..n]) catch return makeIoError(alloc, "out of memory");
    return ObjString.create(alloc, owned).toValue();
}

fn netWrite(alloc: std.mem.Allocator, args: []const Value) Value {
    if (args[0].tag != .conn or args[1].tag != .string) return makeIoError(alloc, "write requires conn and string");
    const conn = args[0].asConn();
    const data = args[1].asString().chars;
    var written: usize = 0;
    while (written < data.len) {
        written += std.posix.write(conn.fd, data[written..]) catch return makeIoError(alloc, "write failed");
    }
    return Value.initBool(true);
}

pub fn setNonBlocking(fd: std.posix.fd_t) void {
    const flags = std.posix.fcntl(fd, std.posix.F.GETFL, 0) catch return;
    const o_flags: std.posix.O = @bitCast(@as(u32, @truncate(flags)));
    var new_flags = o_flags;
    new_flags.NONBLOCK = true;
    _ = std.posix.fcntl(fd, std.posix.F.SETFL, @as(usize, @as(u32, @bitCast(new_flags)))) catch return;
}

fn netClose(_: std.mem.Allocator, args: []const Value) Value {
    if (args[0].tag == .listener) {
        std.posix.close(args[0].asListener().fd);
    } else if (args[0].tag == .conn) {
        std.posix.close(args[0].asConn().fd);
    } else if (args[0].tag == .dgram) {
        std.posix.close(args[0].asDgram().fd);
    }
    return Value.initNil();
}

fn netTimeout(_: std.mem.Allocator, args: []const Value) Value {
    const ms: i32 = if (args[1].tag == .int) @intCast(@as(i64, @max(-1, args[1].asInt()))) else -1;
    if (args[0].tag == .listener) {
        args[0].asListener().timeout_ms = ms;
    } else if (args[0].tag == .conn) {
        args[0].asConn().timeout_ms = ms;
    } else if (args[0].tag == .dgram) {
        args[0].asDgram().timeout_ms = ms;
    }
    return Value.initNil();
}

fn netUdpBind(alloc: std.mem.Allocator, args: []const Value) Value {
    if (args[0].tag != .string or args[1].tag != .int) return makeIoError(alloc, "udp_bind requires string and int");
    const addr_str = args[0].asString().chars;
    const port: u16 = @intCast(@as(i64, @max(0, @min(65535, args[1].asInt()))));

    const fd = std.posix.socket(std.posix.AF.INET, std.posix.SOCK.DGRAM, 0) catch return makeIoError(alloc, "socket failed");

    const yes: c_int = 1;
    std.posix.setsockopt(fd, std.posix.SOL.SOCKET, std.posix.SO.REUSEADDR, &std.mem.toBytes(yes)) catch {
        std.posix.close(fd);
        return makeIoError(alloc, "setsockopt failed");
    };

    const octets = parseAddr(addr_str);
    const addr = std.net.Address.initIp4(octets, port);
    std.posix.bind(fd, &addr.any, addr.getOsSockLen()) catch {
        std.posix.close(fd);
        return makeIoError(alloc, "bind failed");
    };

    return ObjDgram.create(alloc, fd, true).toValue();
}

fn netUdpOpen(alloc: std.mem.Allocator, _: []const Value) Value {
    const fd = std.posix.socket(std.posix.AF.INET, std.posix.SOCK.DGRAM, 0) catch return makeIoError(alloc, "socket failed");
    return ObjDgram.create(alloc, fd, false).toValue();
}

fn netSendto(alloc: std.mem.Allocator, args: []const Value) Value {
    if (args[0].tag != .dgram or args[1].tag != .string or args[2].tag != .string or args[3].tag != .int)
        return makeIoError(alloc, "sendto requires dgram, string, string, int");
    const dgram = args[0].asDgram();
    const data = args[1].asString().chars;
    const addr_str = args[2].asString().chars;
    const port: u16 = @intCast(@as(i64, @max(0, @min(65535, args[3].asInt()))));

    const octets = parseAddr(addr_str);
    const dest = std.net.Address.initIp4(octets, port);
    _ = std.posix.sendto(dgram.fd, data, 0, &dest.any, dest.getOsSockLen()) catch return makeIoError(alloc, "sendto failed");
    return Value.initBool(true);
}

pub fn buildRecvfromResult(alloc: std.mem.Allocator, data: []const u8, src_addr: *const std.posix.sockaddr.in) Value {
    const data_owned = alloc.dupe(u8, data) catch return makeIoError(alloc, "out of memory");
    const data_str = ObjString.create(alloc, data_owned);

    const ip_bytes = @as(*const [4]u8, @ptrCast(&src_addr.addr));
    var ip_buf: [15]u8 = undefined;
    const ip_len = std.fmt.bufPrint(&ip_buf, "{d}.{d}.{d}.{d}", .{ ip_bytes[0], ip_bytes[1], ip_bytes[2], ip_bytes[3] }) catch return makeIoError(alloc, "format failed");
    const ip_owned = alloc.dupe(u8, ip_len) catch return makeIoError(alloc, "out of memory");
    const addr_val = ObjString.create(alloc, ip_owned);

    const src_port: i64 = std.mem.bigToNative(u16, src_addr.port);

    const field_names = alloc.alloc([]const u8, 3) catch return makeIoError(alloc, "out of memory");
    field_names[0] = "data";
    field_names[1] = "addr";
    field_names[2] = "port";
    var values: [3]Value = .{
        data_str.toValue(),
        addr_val.toValue(),
        Value.initInt(src_port),
    };
    return ObjStruct.create(alloc, "UdpMessage", field_names, &values).toValue();
}

fn netRecvfrom(alloc: std.mem.Allocator, args: []const Value) Value {
    if (args[0].tag != .dgram) return makeIoError(alloc, "recvfrom requires dgram");
    const dgram = args[0].asDgram();

    if (dgram.timeout_ms >= 0) {
        var pollfds = [1]std.posix.pollfd{.{ .fd = dgram.fd, .events = std.posix.POLL.IN, .revents = 0 }};
        const poll_n = std.posix.poll(&pollfds, dgram.timeout_ms) catch return makeIoError(alloc, "poll failed");
        if (poll_n == 0) {
            return ObjEnum.create(alloc, "IoError", "Timeout", 3, &.{}).toValue();
        }
    }

    var buf: [65535]u8 = undefined;
    var src_addr: std.posix.sockaddr.in = undefined;
    var addr_len: std.posix.socklen_t = @sizeOf(std.posix.sockaddr.in);
    const n = std.posix.recvfrom(dgram.fd, &buf, 0, @ptrCast(&src_addr), &addr_len) catch return makeIoError(alloc, "recvfrom failed");
    if (n == 0) return makeIoEof(alloc);

    return buildRecvfromResult(alloc, buf[0..n], &src_addr);
}

// --------------- std/http ---------------

const http_fns = [_]NativeDef{
    .{ .name = "parse_request", .arity = 1, .func = &httpParseRequest },
    .{ .name = "respond", .arity = 1, .func = &httpRespond },
    .{ .name = "respond_status", .arity = 2, .func = &httpRespondStatus },
    .{ .name = "json_response", .arity = 1, .func = &httpJsonResponse },
    .{ .name = "route", .arity = 3, .func = &httpRoute },
    .{ .name = "match_route", .arity = 3, .func = &httpMatchRoute },
};

fn httpParseRequest(alloc: std.mem.Allocator, args: []const Value) Value {
    if (args[0].tag != .string) return Value.initNil();
    const raw = args[0].asString().chars;

    const line_end = std.mem.indexOf(u8, raw, "\r\n") orelse return Value.initNil();
    const request_line = raw[0..line_end];

    var parts = std.mem.splitScalar(u8, request_line, ' ');
    const method = parts.next() orelse return Value.initNil();
    const path = parts.next() orelse return Value.initNil();

    const header_end = std.mem.indexOf(u8, raw, "\r\n\r\n") orelse raw.len;
    const header_start = line_end + 2;
    const headers = if (header_start <= header_end) raw[header_start..header_end] else "";
    const body_start = if (header_end + 4 <= raw.len) header_end + 4 else raw.len;
    const body = raw[body_start..];

    const field_names = alloc.alloc([]const u8, 4) catch return Value.initNil();
    field_names[0] = "method";
    field_names[1] = "path";
    field_names[2] = "headers";
    field_names[3] = "body";
    var values: [4]Value = .{
        ObjString.create(alloc, alloc.dupe(u8, method) catch "").toValue(),
        ObjString.create(alloc, alloc.dupe(u8, path) catch "").toValue(),
        ObjString.create(alloc, alloc.dupe(u8, headers) catch "").toValue(),
        ObjString.create(alloc, alloc.dupe(u8, body) catch "").toValue(),
    };
    return ObjStruct.create(alloc, "Request", field_names, &values).toValue();
}

fn httpRespond(alloc: std.mem.Allocator, args: []const Value) Value {
    if (args[0].tag != .string) return Value.initNil();
    return buildResponse(alloc, "200 OK", "text/plain", args[0].asString().chars);
}

fn httpRespondStatus(alloc: std.mem.Allocator, args: []const Value) Value {
    if (args[0].tag != .int or args[1].tag != .string) return Value.initNil();
    const code = args[0].asInt();
    const body = args[1].asString().chars;
    var status_buf: [32]u8 = undefined;
    const reason = switch (code) {
        200 => "OK",
        201 => "Created",
        204 => "No Content",
        400 => "Bad Request",
        401 => "Unauthorized",
        403 => "Forbidden",
        404 => "Not Found",
        405 => "Method Not Allowed",
        500 => "Internal Server Error",
        else => "Unknown",
    };
    const status = std.fmt.bufPrint(&status_buf, "{d} {s}", .{ code, reason }) catch return Value.initNil();
    return buildResponse(alloc, status, "text/plain", body);
}

fn httpJsonResponse(alloc: std.mem.Allocator, args: []const Value) Value {
    var buf = std.ArrayListUnmanaged(u8){};
    jsonWriteValue(alloc, &buf, args[0]);
    return buildResponse(alloc, "200 OK", "application/json", buf.items);
}

fn httpRoute(alloc: std.mem.Allocator, args: []const Value) Value {
    if (args[0].tag != .string or args[1].tag != .string) return Value.initNil();
    const field_names = alloc.alloc([]const u8, 3) catch return Value.initNil();
    field_names[0] = "method";
    field_names[1] = "path";
    field_names[2] = "handler";
    var values: [3]Value = .{ args[0], args[1], args[2] };
    return ObjStruct.create(alloc, "Route", field_names, &values).toValue();
}

fn httpMatchRoute(_: std.mem.Allocator, args: []const Value) Value {
    if (args[0].tag != .array or args[1].tag != .string or args[2].tag != .string) return Value.initNil();
    const routes = args[0].asArray();
    const method = args[1].asString().chars;
    const path = args[2].asString().chars;

    for (routes.items) |route_val| {
        if (route_val.tag != .struct_) continue;
        const route = route_val.asStruct();
        const fv = route.fieldValues();
        if (fv[0].tag != .string or fv[1].tag != .string) continue;

        if (std.mem.eql(u8, fv[0].asString().chars, method) and
            std.mem.eql(u8, fv[1].asString().chars, path))
        {
            return fv[2];
        }
    }
    return Value.initNil();
}

fn buildResponse(alloc: std.mem.Allocator, status: []const u8, content_type: []const u8, body: []const u8) Value {
    var resp = std.ArrayListUnmanaged(u8){};
    resp.appendSlice(alloc, "HTTP/1.1 ") catch return Value.initNil();
    resp.appendSlice(alloc, status) catch return Value.initNil();
    resp.appendSlice(alloc, "\r\nContent-Type: ") catch return Value.initNil();
    resp.appendSlice(alloc, content_type) catch return Value.initNil();
    resp.appendSlice(alloc, "\r\nContent-Length: ") catch return Value.initNil();
    var len_buf: [20]u8 = undefined;
    const len_str = std.fmt.bufPrint(&len_buf, "{d}", .{body.len}) catch return Value.initNil();
    resp.appendSlice(alloc, len_str) catch return Value.initNil();
    resp.appendSlice(alloc, "\r\nConnection: close\r\n\r\n") catch return Value.initNil();
    resp.appendSlice(alloc, body) catch return Value.initNil();
    return ObjString.create(alloc, resp.items).toValue();
}
