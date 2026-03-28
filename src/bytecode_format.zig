const std = @import("std");
const Value = @import("value.zig").Value;
const ObjString = @import("value.zig").ObjString;
const ObjFunction = @import("value.zig").ObjFunction;
const ObjNativeFn = @import("value.zig").ObjNativeFn;
const Chunk = @import("chunk.zig").Chunk;
const ffi = @import("ffi.zig");

const MAGIC = "PYRC".*;
const FORMAT_VERSION: u16 = 1;
const EXE_MAGIC = "PYREXE\x00\x00".*;

const ConstTag = enum(u8) {
    nil = 0,
    bool_false = 1,
    bool_true = 2,
    int = 3,
    float = 4,
    string = 5,
    function = 6,
    native_fn = 7,
};

pub fn serialize(alloc: std.mem.Allocator, root: *ObjFunction, ffi_descs: []const ffi.FfiDesc) ![]u8 {
    var ctx = SerializeCtx.init(alloc);
    defer ctx.deinit();

    ctx.collectFunction(root);
    const root_idx = ctx.funcIndex(root).?;

    var buf = std.ArrayListUnmanaged(u8){};

    buf.appendSlice(alloc, &MAGIC) catch @panic("oom");
    writeU16(&buf, alloc, FORMAT_VERSION);

    writeU32(&buf, alloc, @intCast(ctx.strings.items.len));
    for (ctx.strings.items) |s| {
        writeU32(&buf, alloc, @intCast(s.len));
        buf.appendSlice(alloc, s) catch @panic("oom");
    }

    writeU32(&buf, alloc, @intCast(ctx.functions.items.len));
    for (ctx.functions.items) |func| {
        ctx.serializeFunction(&buf, alloc, func);
    }

    writeU32(&buf, alloc, @intCast(ffi_descs.len));
    for (ffi_descs) |desc| {
        writeU32(&buf, alloc, @intCast(ctx.internString(desc.lib)));
        writeU32(&buf, alloc, @intCast(ctx.internString(desc.name)));
        buf.append(alloc, @intCast(desc.params.len)) catch @panic("oom");
        for (desc.params) |p| {
            buf.append(alloc, @intFromEnum(p)) catch @panic("oom");
        }
        buf.append(alloc, @intFromEnum(desc.ret)) catch @panic("oom");
    }

    writeU32(&buf, alloc, @intCast(root_idx));

    return buf.toOwnedSlice(alloc) catch @panic("oom");
}

pub fn deserialize(alloc: std.mem.Allocator, data: []const u8) !DeserializeResult {
    var r = Reader{ .data = data, .pos = 0 };

    const magic = r.readBytes(4);
    if (!std.mem.eql(u8, magic, &MAGIC)) return error.InvalidMagic;
    const version = r.readU16();
    if (version != FORMAT_VERSION) return error.UnsupportedVersion;

    const str_count = r.readU32();
    const strings = alloc.alloc([]const u8, str_count) catch @panic("oom");
    for (0..str_count) |i| {
        const len = r.readU32();
        strings[i] = alloc.dupe(u8, r.readBytes(len)) catch @panic("oom");
    }

    const func_count = r.readU32();
    const functions = alloc.alloc(*ObjFunction, func_count) catch @panic("oom");
    for (0..func_count) |i| {
        functions[i] = ObjFunction.create(alloc, "", 0);
    }

    for (0..func_count) |i| {
        deserializeFunction(&r, alloc, functions[i], strings, functions);
    }

    const ffi_count = r.readU32();
    const ffi_descs = alloc.alloc(ffi.FfiDesc, ffi_count) catch @panic("oom");
    for (0..ffi_count) |i| {
        const lib = strings[r.readU32()];
        const name_str = strings[r.readU32()];
        const param_count = r.readByte();
        const params = alloc.alloc(ffi.FfiType, param_count) catch @panic("oom");
        for (0..param_count) |j| {
            params[j] = @enumFromInt(r.readByte());
        }
        const ret: ffi.FfiType = @enumFromInt(r.readByte());
        const name_z = alloc.allocSentinel(u8, name_str.len, 0) catch @panic("oom");
        @memcpy(name_z, name_str);
        ffi_descs[i] = .{ .lib = lib, .name = name_z, .params = params, .ret = ret };
    }

    const root_idx = r.readU32();

    return .{
        .func = functions[root_idx],
        .ffi_descs = ffi_descs,
        .strings = strings,
        .functions = functions,
    };
}

pub const DeserializeResult = struct {
    func: *ObjFunction,
    ffi_descs: []ffi.FfiDesc,
    strings: [][]const u8,
    functions: []*ObjFunction,
};

pub fn appendToExecutable(alloc: std.mem.Allocator, exe_path: []const u8, bytecode: []const u8, out_path: []const u8) !void {
    const exe_data = try std.fs.cwd().readFileAlloc(alloc, exe_path, 100 * 1024 * 1024);
    defer alloc.free(exe_data);

    const file = try std.fs.cwd().createFile(out_path, .{});
    defer file.close();

    try file.writeAll(exe_data);
    try file.writeAll(bytecode);

    var trailer: [16]u8 = undefined;
    @memcpy(trailer[0..8], &EXE_MAGIC);
    std.mem.writeInt(u32, trailer[8..12], @intCast(exe_data.len), .little);
    std.mem.writeInt(u32, trailer[12..16], @intCast(bytecode.len), .little);
    try file.writeAll(&trailer);

    std.posix.fchmodat(std.posix.AT.FDCWD, out_path, 0o755, 0) catch {};
}

pub fn detectEmbeddedBytecode(alloc: std.mem.Allocator) ?[]u8 {
    const self_path = std.fs.selfExePath(&path_buf) catch return null;
    const file = std.fs.openFileAbsolute(self_path, .{}) catch return null;
    defer file.close();

    const stat = file.stat() catch return null;
    const file_size = stat.size;
    if (file_size < 16) return null;

    file.seekTo(file_size - 16) catch return null;
    var trailer: [16]u8 = undefined;
    const n = file.read(&trailer) catch return null;
    if (n < 16) return null;

    if (!std.mem.eql(u8, trailer[0..8], &EXE_MAGIC)) return null;

    const offset = std.mem.readInt(u32, trailer[8..12], .little);
    const length = std.mem.readInt(u32, trailer[12..16], .little);

    file.seekTo(offset) catch return null;
    const bytecode = alloc.alloc(u8, length) catch return null;
    const read = file.readAll(bytecode) catch {
        alloc.free(bytecode);
        return null;
    };
    if (read < length) {
        alloc.free(bytecode);
        return null;
    }
    return bytecode;
}

var path_buf: [std.fs.max_path_bytes]u8 = undefined;

const SerializeCtx = struct {
    strings: std.ArrayListUnmanaged([]const u8),
    string_map: std.StringHashMapUnmanaged(u32),
    functions: std.ArrayListUnmanaged(*ObjFunction),
    func_set: std.AutoHashMapUnmanaged(*ObjFunction, u32),
    alloc: std.mem.Allocator,

    fn init(alloc: std.mem.Allocator) SerializeCtx {
        return .{
            .strings = .{},
            .string_map = .{},
            .functions = .{},
            .func_set = .{},
            .alloc = alloc,
        };
    }

    fn deinit(self: *SerializeCtx) void {
        self.strings.deinit(self.alloc);
        self.string_map.deinit(self.alloc);
        self.functions.deinit(self.alloc);
        self.func_set.deinit(self.alloc);
    }

    fn internString(self: *SerializeCtx, s: []const u8) u32 {
        if (self.string_map.get(s)) |idx| return idx;
        const idx: u32 = @intCast(self.strings.items.len);
        self.strings.append(self.alloc, s) catch @panic("oom");
        self.string_map.put(self.alloc, s, idx) catch @panic("oom");
        return idx;
    }

    fn collectFunction(self: *SerializeCtx, func: *ObjFunction) void {
        if (self.func_set.get(func) != null) return;
        const idx: u32 = @intCast(self.functions.items.len);
        self.functions.append(self.alloc, func) catch @panic("oom");
        self.func_set.put(self.alloc, func, idx) catch @panic("oom");

        _ = self.internString(func.name);
        _ = self.internString(func.source);

        for (func.chunk.constants.items) |val| {
            switch (val.tag()) {
                .string => _ = self.internString(val.asString().chars),
                .function => self.collectFunction(val.asFunction()),
                .native_fn => _ = self.internString(self.nativeKey(val.asNativeFn())),
                else => {},
            }
        }
    }

    fn nativeKey(self: *SerializeCtx, nf: *ObjNativeFn) []const u8 {
        var buf: [128]u8 = undefined;
        if (stdlib.qualifyNative(&buf, nf.func)) |qualified| {
            const duped = self.alloc.dupe(u8, qualified) catch @panic("oom");
            return duped;
        }
        return nf.name;
    }

    fn funcIndex(self: *SerializeCtx, func: *ObjFunction) ?u32 {
        return self.func_set.get(func);
    }

    fn serializeFunction(self: *SerializeCtx, buf: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator, func: *ObjFunction) void {
        writeU32(buf, alloc, self.internString(func.name));
        buf.append(alloc, func.arity) catch @panic("oom");
        buf.append(alloc, @intFromBool(func.locals_only)) catch @panic("oom");
        writeU32(buf, alloc, self.internString(func.source));

        const chunk = &func.chunk;
        writeU32(buf, alloc, @intCast(chunk.code.items.len));
        buf.appendSlice(alloc, chunk.code.items) catch @panic("oom");

        writeU32(buf, alloc, @intCast(chunk.constants.items.len));
        for (chunk.constants.items) |val| {
            self.serializeConstant(buf, alloc, val);
        }

        writeU32(buf, alloc, @intCast(chunk.lines.items.len));
        for (chunk.lines.items) |line| {
            writeU32(buf, alloc, line);
        }
    }

    fn serializeConstant(self: *SerializeCtx, buf: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator, val: Value) void {
        switch (val.tag()) {
            .nil => buf.append(alloc, @intFromEnum(ConstTag.nil)) catch @panic("oom"),
            .bool_ => buf.append(alloc, @intFromEnum(if (val.asBool()) ConstTag.bool_true else ConstTag.bool_false)) catch @panic("oom"),
            .int => {
                buf.append(alloc, @intFromEnum(ConstTag.int)) catch @panic("oom");
                writeU64(buf, alloc, @bitCast(val.asInt()));
            },
            .float => {
                buf.append(alloc, @intFromEnum(ConstTag.float)) catch @panic("oom");
                writeU64(buf, alloc, @bitCast(val.asFloat()));
            },
            .string => {
                buf.append(alloc, @intFromEnum(ConstTag.string)) catch @panic("oom");
                writeU32(buf, alloc, self.internString(val.asString().chars));
            },
            .function => {
                buf.append(alloc, @intFromEnum(ConstTag.function)) catch @panic("oom");
                writeU32(buf, alloc, self.funcIndex(val.asFunction()).?);
            },
            .native_fn => {
                buf.append(alloc, @intFromEnum(ConstTag.native_fn)) catch @panic("oom");
                writeU32(buf, alloc, self.internString(self.nativeKey(val.asNativeFn())));
                buf.append(alloc, val.asNativeFn().arity) catch @panic("oom");
            },
            else => {
                buf.append(alloc, @intFromEnum(ConstTag.nil)) catch @panic("oom");
            },
        }
    }
};

fn deserializeFunction(r: *Reader, alloc: std.mem.Allocator, func: *ObjFunction, strings: [][]const u8, functions: []*ObjFunction) void {
    func.name = strings[r.readU32()];
    func.arity = r.readByte();
    func.locals_only = r.readByte() != 0;
    func.source = strings[r.readU32()];

    const code_len = r.readU32();
    func.chunk.code.ensureTotalCapacity(alloc, code_len) catch @panic("oom");
    func.chunk.code.appendSliceAssumeCapacity(r.readBytes(code_len));

    const const_count = r.readU32();
    func.chunk.constants.ensureTotalCapacity(alloc, const_count) catch @panic("oom");
    for (0..const_count) |_| {
        const tag: ConstTag = @enumFromInt(r.readByte());
        const val: Value = switch (tag) {
            .nil => Value.initNil(),
            .bool_false => Value.initBool(false),
            .bool_true => Value.initBool(true),
            .int => Value.initInt(@bitCast(r.readU64())),
            .float => Value.initFloat(@bitCast(r.readU64())),
            .string => ObjString.create(alloc, strings[r.readU32()]).toValue(),
            .function => functions[r.readU32()].toValue(),
            .native_fn => blk: {
                const name = strings[r.readU32()];
                const arity = r.readByte();
                break :blk ObjNativeFn.create(alloc, name, arity, &nativePlaceholder).toValue();
            },
        };
        func.chunk.constants.appendAssumeCapacity(val);
    }

    const lines_count = r.readU32();
    func.chunk.lines.ensureTotalCapacity(alloc, lines_count) catch @panic("oom");
    for (0..lines_count) |_| {
        func.chunk.lines.appendAssumeCapacity(r.readU32());
    }
}

fn nativePlaceholder(_: std.mem.Allocator, _: []const Value) Value {
    return Value.initNil();
}

const compiler_mod = @import("compiler.zig");
const stdlib = @import("stdlib.zig");

pub fn patchNatives(functions: []*ObjFunction) void {
    for (functions) |func| {
        for (func.chunk.constants.items) |*val| {
            if (val.tag() == .native_fn) {
                const nf = val.asNativeFn();
                if (findNativeFunc(nf.name)) |real_func| {
                    nf.func = real_func;
                }
            }
        }
    }
}

fn findNativeFunc(name: []const u8) ?*const fn (std.mem.Allocator, []const Value) Value {
    if (stdlib.findNativeByQualified(name)) |func| return func;
    for (&compiler_mod.Compiler.builtin_natives) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return entry.func;
    }
    return null;
}

const Reader = struct {
    data: []const u8,
    pos: usize,

    fn readByte(self: *Reader) u8 {
        const b = self.data[self.pos];
        self.pos += 1;
        return b;
    }

    fn readBytes(self: *Reader, n: usize) []const u8 {
        const slice = self.data[self.pos .. self.pos + n];
        self.pos += n;
        return slice;
    }

    fn readU16(self: *Reader) u16 {
        const b = self.readBytes(2);
        return std.mem.readInt(u16, b[0..2], .little);
    }

    fn readU32(self: *Reader) u32 {
        const b = self.readBytes(4);
        return std.mem.readInt(u32, b[0..4], .little);
    }

    fn readU64(self: *Reader) u64 {
        const b = self.readBytes(8);
        return std.mem.readInt(u64, b[0..8], .little);
    }
};

fn writeU16(buf: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator, val: u16) void {
    var bytes: [2]u8 = undefined;
    std.mem.writeInt(u16, &bytes, val, .little);
    buf.appendSlice(alloc, &bytes) catch @panic("oom");
}

fn writeU32(buf: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator, val: u32) void {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, val, .little);
    buf.appendSlice(alloc, &bytes) catch @panic("oom");
}

fn writeU64(buf: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator, val: u64) void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, val, .little);
    buf.appendSlice(alloc, &bytes) catch @panic("oom");
}

fn freeDeserializedFunc(alloc: std.mem.Allocator, f: *ObjFunction) void {
    for (f.chunk.constants.items) |val| {
        if (val.tag() == .string) alloc.destroy(val.asString());
        if (val.tag() == .native_fn) alloc.destroy(val.asNativeFn());
    }
    f.chunk.code.deinit(alloc);
    f.chunk.constants.deinit(alloc);
    f.chunk.lines.deinit(alloc);
    alloc.destroy(f);
}

test "bytecode_format: round-trip primitives" {
    const alloc = std.testing.allocator;

    const func = ObjFunction.create(alloc, "test", 0);
    defer {
        func.chunk.code.deinit(alloc);
        func.chunk.constants.deinit(alloc);
        func.chunk.lines.deinit(alloc);
        alloc.destroy(func);
    }
    func.source = "test source";

    _ = func.chunk.addConstant(alloc, Value.initNil());
    _ = func.chunk.addConstant(alloc, Value.initBool(true));
    _ = func.chunk.addConstant(alloc, Value.initBool(false));
    _ = func.chunk.addConstant(alloc, Value.initInt(42));
    _ = func.chunk.addConstant(alloc, Value.initInt(-7));
    _ = func.chunk.addConstant(alloc, Value.initFloat(3.14));

    func.chunk.write(alloc, 0, 1);
    func.chunk.write(alloc, 1, 1);

    const bc = try serialize(alloc, func, &.{});
    defer alloc.free(bc);

    const result = try deserialize(alloc, bc);
    defer {
        for (result.strings) |s| alloc.free(s);
        alloc.free(result.strings);
        for (result.functions) |f| freeDeserializedFunc(alloc, f);
        alloc.free(result.functions);
    }

    const rf = result.func;
    try std.testing.expectEqualStrings("test", rf.name);
    try std.testing.expectEqual(@as(usize, 2), rf.chunk.code.items.len);
    try std.testing.expectEqual(@as(usize, 6), rf.chunk.constants.items.len);

    const c = rf.chunk.constants.items;
    try std.testing.expectEqual(Value.Tag.nil, c[0].tag());
    try std.testing.expect(c[1].asBool());
    try std.testing.expect(!c[2].asBool());
    try std.testing.expectEqual(@as(i64, 42), c[3].asInt());
    try std.testing.expectEqual(@as(i64, -7), c[4].asInt());
    try std.testing.expectEqual(@as(f64, 3.14), c[5].asFloat());
}

test "bytecode_format: round-trip strings" {
    const alloc = std.testing.allocator;

    const func = ObjFunction.create(alloc, "main", 0);
    defer {
        func.chunk.constants.deinit(alloc);
        func.chunk.code.deinit(alloc);
        func.chunk.lines.deinit(alloc);
        alloc.destroy(func);
    }
    func.source = "";

    const s1 = ObjString.create(alloc, "hello");
    defer alloc.destroy(s1);
    const s2 = ObjString.create(alloc, "world");
    defer alloc.destroy(s2);

    _ = func.chunk.addConstant(alloc, s1.toValue());
    _ = func.chunk.addConstant(alloc, s2.toValue());

    const bc = try serialize(alloc, func, &.{});
    defer alloc.free(bc);

    const result = try deserialize(alloc, bc);
    defer {
        for (result.strings) |s| alloc.free(s);
        alloc.free(result.strings);
        for (result.functions) |f| freeDeserializedFunc(alloc, f);
        alloc.free(result.functions);
    }

    const c = result.func.chunk.constants.items;
    try std.testing.expectEqualStrings("hello", c[0].asString().chars);
    try std.testing.expectEqualStrings("world", c[1].asString().chars);
}

test "bytecode_format: round-trip nested functions" {
    const alloc = std.testing.allocator;

    const inner = ObjFunction.create(alloc, "add", 2);
    defer {
        inner.chunk.code.deinit(alloc);
        inner.chunk.constants.deinit(alloc);
        inner.chunk.lines.deinit(alloc);
        alloc.destroy(inner);
    }
    inner.source = "src";
    inner.chunk.write(alloc, 0, 1);

    const outer = ObjFunction.create(alloc, "script", 0);
    defer {
        outer.chunk.code.deinit(alloc);
        outer.chunk.constants.deinit(alloc);
        outer.chunk.lines.deinit(alloc);
        alloc.destroy(outer);
    }
    outer.source = "src";
    _ = outer.chunk.addConstant(alloc, inner.toValue());
    _ = outer.chunk.addConstant(alloc, Value.initInt(99));
    outer.chunk.write(alloc, 0, 1);

    const bc = try serialize(alloc, outer, &.{});
    defer alloc.free(bc);

    const result = try deserialize(alloc, bc);
    defer {
        for (result.strings) |s| alloc.free(s);
        alloc.free(result.strings);
        for (result.functions) |f| freeDeserializedFunc(alloc, f);
        alloc.free(result.functions);
    }

    try std.testing.expectEqualStrings("script", result.func.name);
    const c = result.func.chunk.constants.items;
    try std.testing.expectEqual(Value.Tag.function, c[0].tag());
    try std.testing.expectEqualStrings("add", c[0].asFunction().name);
    try std.testing.expectEqual(@as(u8, 2), c[0].asFunction().arity);
    try std.testing.expectEqual(@as(i64, 99), c[1].asInt());
}
