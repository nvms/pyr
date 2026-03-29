const std = @import("std");
const Value = @import("../value.zig").Value;
const ObjString = @import("../value.zig").ObjString;
const ObjArray = @import("../value.zig").ObjArray;
const ObjStruct = @import("../value.zig").ObjStruct;
const ObjMap = @import("../value.zig").ObjMap;
const root = @import("../stdlib.zig");

pub const fns = [_]root.NativeDef{
    .{ .name = "encode", .arity = 1, .func = &jsonEncode },
    .{ .name = "decode", .arity = 1, .func = &jsonDecode },
};

fn jsonEncode(alloc: std.mem.Allocator, args: []const Value) Value {
    var buf = std.ArrayListUnmanaged(u8){};
    writeValue(alloc, &buf, args[0]);
    return ObjString.create(alloc, buf.items).toValue();
}

pub fn writeValue(alloc: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), v: Value) void {
    switch (v.tag()) {
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
        .string => writeString(alloc, buf, v.asString().chars),
        .array => {
            const arr = v.asArray();
            buf.append(alloc, '[') catch return;
            for (arr.items, 0..) |item, i| {
                if (i > 0) buf.append(alloc, ',') catch return;
                writeValue(alloc, buf, item);
            }
            buf.append(alloc, ']') catch return;
        },
        .struct_ => {
            const st = v.asStruct();
            const fv = st.fieldValues();
            buf.append(alloc, '{') catch return;
            for (st.field_names, 0..) |name, i| {
                if (i > 0) buf.append(alloc, ',') catch return;
                writeString(alloc, buf, name);
                buf.append(alloc, ':') catch return;
                writeValue(alloc, buf, fv[i]);
            }
            buf.append(alloc, '}') catch return;
        },
        .enum_ => {
            const e = v.asEnum();
            if (e.payloads.len == 0) {
                writeString(alloc, buf, e.variant);
            } else {
                buf.appendSlice(alloc, "{\"variant\":") catch return;
                writeString(alloc, buf, e.variant);
                buf.appendSlice(alloc, ",\"payloads\":[") catch return;
                for (e.payloads, 0..) |val, i| {
                    if (i > 0) buf.append(alloc, ',') catch return;
                    writeValue(alloc, buf, val);
                }
                buf.appendSlice(alloc, "]}") catch return;
            }
        },
        .error_val => {
            buf.appendSlice(alloc, "{\"error\":") catch return;
            writeValue(alloc, buf, v.asError().value);
            buf.append(alloc, '}') catch return;
        },
        .map => {
            const m = v.asMap();
            buf.append(alloc, '{') catch return;
            var it = m.entries.iterator();
            var first = true;
            while (it.next()) |entry| {
                if (!first) buf.append(alloc, ',') catch return;
                writeString(alloc, buf, entry.key_ptr.*);
                buf.append(alloc, ':') catch return;
                writeValue(alloc, buf, entry.value_ptr.*);
                first = false;
            }
            buf.append(alloc, '}') catch return;
        },
        .function, .native_fn, .closure, .task, .channel, .ext, .ptr => buf.appendSlice(alloc, "null") catch return,
    }
}

fn writeString(alloc: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), s: []const u8) void {
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
    if (args[0].tag() != .string) return Value.initNil();
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
        self.pos += 1;
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
                        self.pos += 3;
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
        if (self.pos < self.src.len) self.pos += 1;
        return ObjString.create(self.alloc, buf.items).toValue();
    }

    fn parseArray(self: *JsonParser) Value {
        self.pos += 1;
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
        self.pos += 1;
        self.skipWhitespace();
        const m = ObjMap.create(self.alloc);
        if (self.pos < self.src.len and self.src[self.pos] == '}') {
            self.pos += 1;
            return m.toValue();
        }
        while (self.pos < self.src.len) {
            self.skipWhitespace();
            if (self.pos >= self.src.len or self.src[self.pos] != '"') break;
            const key_val = self.parseString();
            const key = key_val.asString().chars;
            self.skipWhitespace();
            if (self.pos < self.src.len and self.src[self.pos] == ':') self.pos += 1;
            m.set(self.alloc, key, self.parseValue());
            self.skipWhitespace();
            if (self.pos < self.src.len and self.src[self.pos] == ',') {
                self.pos += 1;
                continue;
            }
            break;
        }
        if (self.pos < self.src.len and self.src[self.pos] == '}') self.pos += 1;
        return m.toValue();
    }
};
