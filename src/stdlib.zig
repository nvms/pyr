const std = @import("std");
const Value = @import("value.zig").Value;
const ObjString = @import("value.zig").ObjString;
const ObjArray = @import("value.zig").ObjArray;
const ObjStruct = @import("value.zig").ObjStruct;
const ObjEnum = @import("value.zig").ObjEnum;

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
        .function, .native_fn, .closure => buf.appendSlice(alloc, "null") catch return,
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
