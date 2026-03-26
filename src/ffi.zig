const std = @import("std");
const ast = @import("ast.zig");
const Value = @import("value.zig").Value;
const ObjString = @import("value.zig").ObjString;

pub const FfiType = ast.FfiType;

pub const FfiDesc = struct {
    lib: []const u8,
    name: [:0]const u8,
    params: []const FfiType,
    ret: FfiType,
    fn_ptr: ?*anyopaque = null,
};

pub const FfiState = struct {
    descs: []FfiDesc,
    libs: std.StringHashMapUnmanaged(?*anyopaque),
    alloc: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator, descs: []FfiDesc) FfiState {
        return .{ .descs = descs, .libs = .{}, .alloc = alloc };
    }

    pub fn resolve(self: *FfiState) !void {
        for (self.descs) |*desc| {
            if (desc.fn_ptr != null) continue;
            const handle = try self.openLib(desc.lib);
            desc.fn_ptr = dlsym(handle, desc.name.ptr);
            if (desc.fn_ptr == null) {
                std.debug.print("ffi: symbol not found: {s}\n", .{desc.name});
                return error.SymbolNotFound;
            }
        }
    }

    fn openLib(self: *FfiState, name: []const u8) !?*anyopaque {
        if (self.libs.get(name)) |h| return h;

        var handle: ?*anyopaque = null;

        if (std.mem.eql(u8, name, "c") or std.mem.eql(u8, name, "libc")) {
            handle = dlopen(null, RTLD_LAZY);
        } else {
            // try as-is first
            var name_buf: [256]u8 = undefined;
            const name_z = std.fmt.bufPrintZ(&name_buf, "{s}", .{name}) catch return error.NameTooLong;
            handle = dlopen(name_z.ptr, RTLD_LAZY);
            if (handle == null) {
                // try with platform extension
                var buf: [256]u8 = undefined;
                const decorated = std.fmt.bufPrintZ(&buf, "lib{s}" ++ lib_ext, .{name}) catch return error.NameTooLong;
                handle = dlopen(decorated.ptr, RTLD_LAZY);
            }
        }

        if (handle == null) {
            const err = dlerror();
            if (err) |msg| {
                const len = std.mem.len(msg);
                std.debug.print("ffi: dlopen failed: {s}\n", .{msg[0..len]});
            }
            return error.LibNotFound;
        }

        self.libs.put(self.alloc, name, handle) catch @panic("oom");
        return handle;
    }

    pub fn call(self: *FfiState, desc_idx: u16, args: []const Value, alloc: std.mem.Allocator) Value {
        const desc = &self.descs[desc_idx];
        const fn_ptr = desc.fn_ptr orelse return Value.initNil();

        var int_args: [8]usize = undefined;
        var float_args: [8]f64 = undefined;
        var int_count: usize = 0;
        var float_count: usize = 0;
        var str_bufs: [8][:0]u8 = undefined;
        var str_count: usize = 0;

        for (desc.params, 0..) |ptype, i| {
            if (i >= args.len) break;
            switch (ptype) {
                .cint, .ptr => {
                    int_args[int_count] = marshalToInt(args[i]);
                    int_count += 1;
                },
                .cstr => {
                    if (args[i].tag == .string) {
                        const chars = args[i].asString().chars;
                        const z = alloc.allocSentinel(u8, chars.len, 0) catch {
                            int_args[int_count] = 0;
                            int_count += 1;
                            continue;
                        };
                        @memcpy(z, chars);
                        str_bufs[str_count] = z;
                        str_count += 1;
                        int_args[int_count] = @intFromPtr(z.ptr);
                    } else {
                        int_args[int_count] = marshalToInt(args[i]);
                    }
                    int_count += 1;
                },
                .f64_ => {
                    float_args[float_count] = if (args[i].tag == .float) args[i].asFloat() else @floatFromInt(args[i].asInt());
                    float_count += 1;
                },
                .void_ => {},
            }
        }

        if (float_count > 0) {
            return self.callWithFloats(fn_ptr, &int_args, int_count, &float_args, float_count, desc.ret, alloc);
        }

        const raw = switch (int_count) {
            0 => trampoline0(fn_ptr),
            1 => trampoline1(fn_ptr, int_args[0]),
            2 => trampoline2(fn_ptr, int_args[0], int_args[1]),
            3 => trampoline3(fn_ptr, int_args[0], int_args[1], int_args[2]),
            4 => trampoline4(fn_ptr, int_args[0], int_args[1], int_args[2], int_args[3]),
            5 => trampoline5(fn_ptr, int_args[0], int_args[1], int_args[2], int_args[3], int_args[4]),
            6 => trampoline6(fn_ptr, int_args[0], int_args[1], int_args[2], int_args[3], int_args[4], int_args[5]),
            else => 0,
        };

        return marshalResult(raw, desc.ret, alloc);
    }

    fn callWithFloats(_: *FfiState, fn_ptr: *anyopaque, int_args: *const [8]usize, int_count: usize, float_args: *const [8]f64, _: usize, ret: FfiType, alloc: std.mem.Allocator) Value {
        // for functions with mixed int/float args, only support common patterns
        // f64 return with float args
        if (ret == .f64_) {
            if (int_count == 0) {
                const f: *const fn (f64) callconv(.c) f64 = @ptrCast(@alignCast(fn_ptr));
                return Value.initFloat(f(float_args[0]));
            }
        }
        // fallback: pass all as int (works for most cases where float fits in register)
        const raw = switch (int_count) {
            0 => trampoline0(fn_ptr),
            1 => trampoline1(fn_ptr, int_args[0]),
            else => 0,
        };
        return marshalResult(raw, ret, alloc);
    }
};

fn marshalToInt(v: Value) usize {
    return switch (v.tag) {
        .int => @bitCast(v.asInt()),
        .ptr => v.asPtr(),
        .nil => 0,
        .bool_ => @intFromBool(v.asBool()),
        .string => @intFromPtr(v.asString().chars.ptr),
        else => 0,
    };
}

fn marshalToStr(v: Value) usize {
    if (v.tag == .string) {
        const chars = v.asString().chars;
        // check for null terminator
        if (chars.len > 0 and chars.ptr[chars.len] == 0) {
            return @intFromPtr(chars.ptr);
        }
        // not null terminated - need to return the pointer anyway
        // pyr strings from source are null-terminated in practice
        return @intFromPtr(chars.ptr);
    }
    if (v.tag == .nil) return 0;
    if (v.tag == .ptr) return v.asPtr();
    return 0;
}

fn marshalResult(raw: usize, ret: FfiType, alloc: std.mem.Allocator) Value {
    return switch (ret) {
        .void_ => Value.initNil(),
        .cint => Value.initInt(@as(i64, @as(i32, @truncate(@as(i64, @bitCast(raw)))))),
        .ptr => Value.initPtr(raw),
        .f64_ => Value.initFloat(@bitCast(raw)),
        .cstr => blk: {
            if (raw == 0) break :blk Value.initNil();
            const cptr: [*:0]const u8 = @ptrFromInt(raw);
            const len = std.mem.len(cptr);
            const copy = alloc.alloc(u8, len) catch break :blk Value.initNil();
            @memcpy(copy, cptr[0..len]);
            break :blk ObjString.create(alloc, copy).toValue();
        },
    };
}

fn trampoline0(fn_ptr: *anyopaque) usize {
    const f: *const fn () callconv(.c) usize = @ptrCast(@alignCast(fn_ptr));
    return f();
}

fn trampoline1(fn_ptr: *anyopaque, a0: usize) usize {
    const f: *const fn (usize) callconv(.c) usize = @ptrCast(@alignCast(fn_ptr));
    return f(a0);
}

fn trampoline2(fn_ptr: *anyopaque, a0: usize, a1: usize) usize {
    const f: *const fn (usize, usize) callconv(.c) usize = @ptrCast(@alignCast(fn_ptr));
    return f(a0, a1);
}

fn trampoline3(fn_ptr: *anyopaque, a0: usize, a1: usize, a2: usize) usize {
    const f: *const fn (usize, usize, usize) callconv(.c) usize = @ptrCast(@alignCast(fn_ptr));
    return f(a0, a1, a2);
}

fn trampoline4(fn_ptr: *anyopaque, a0: usize, a1: usize, a2: usize, a3: usize) usize {
    const f: *const fn (usize, usize, usize, usize) callconv(.c) usize = @ptrCast(@alignCast(fn_ptr));
    return f(a0, a1, a2, a3);
}

fn trampoline5(fn_ptr: *anyopaque, a0: usize, a1: usize, a2: usize, a3: usize, a4: usize) usize {
    const f: *const fn (usize, usize, usize, usize, usize) callconv(.c) usize = @ptrCast(@alignCast(fn_ptr));
    return f(a0, a1, a2, a3, a4);
}

fn trampoline6(fn_ptr: *anyopaque, a0: usize, a1: usize, a2: usize, a3: usize, a4: usize, a5: usize) usize {
    const f: *const fn (usize, usize, usize, usize, usize, usize) callconv(.c) usize = @ptrCast(@alignCast(fn_ptr));
    return f(a0, a1, a2, a3, a4, a5);
}

const lib_ext = switch (@import("builtin").os.tag) {
    .macos => ".dylib",
    .windows => ".dll",
    else => ".so",
};

const RTLD_LAZY = 0x1;

extern "c" fn dlopen(path: ?[*:0]const u8, mode: c_int) ?*anyopaque;
extern "c" fn dlsym(handle: ?*anyopaque, symbol: [*:0]const u8) ?*anyopaque;
extern "c" fn dlerror() ?[*:0]const u8;
