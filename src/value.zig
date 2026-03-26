const std = @import("std");

pub const Value = struct {
    tag: Tag,
    data: u64,

    pub const Tag = enum(u8) {
        nil,
        bool_,
        int,
        float,
        string,
        function,
        struct_,
        enum_,
        native_fn,
        closure,
    };

    pub fn initNil() Value {
        return .{ .tag = .nil, .data = 0 };
    }

    pub fn initBool(v: bool) Value {
        return .{ .tag = .bool_, .data = @intFromBool(v) };
    }

    pub fn initInt(v: i64) Value {
        return .{ .tag = .int, .data = @bitCast(v) };
    }

    pub fn initFloat(v: f64) Value {
        return .{ .tag = .float, .data = @bitCast(v) };
    }

    pub fn initString(ptr: *ObjString) Value {
        return .{ .tag = .string, .data = @intFromPtr(ptr) };
    }

    pub fn initFunction(ptr: *ObjFunction) Value {
        return .{ .tag = .function, .data = @intFromPtr(ptr) };
    }

    pub fn initStruct(ptr: *ObjStruct) Value {
        return .{ .tag = .struct_, .data = @intFromPtr(ptr) };
    }

    pub fn initEnum(ptr: *ObjEnum) Value {
        return .{ .tag = .enum_, .data = @intFromPtr(ptr) };
    }

    pub fn initNativeFn(ptr: *ObjNativeFn) Value {
        return .{ .tag = .native_fn, .data = @intFromPtr(ptr) };
    }

    pub fn initClosure(ptr: *ObjClosure) Value {
        return .{ .tag = .closure, .data = @intFromPtr(ptr) };
    }

    pub fn asBool(self: Value) bool {
        return self.data != 0;
    }

    pub fn asInt(self: Value) i64 {
        return @bitCast(self.data);
    }

    pub fn asFloat(self: Value) f64 {
        return @bitCast(self.data);
    }

    pub fn asString(self: Value) *ObjString {
        return @ptrCast(@alignCast(@as(*anyopaque, @ptrFromInt(self.data))));
    }

    pub fn asFunction(self: Value) *ObjFunction {
        return @ptrCast(@alignCast(@as(*anyopaque, @ptrFromInt(self.data))));
    }

    pub fn asStruct(self: Value) *ObjStruct {
        return @ptrCast(@alignCast(@as(*anyopaque, @ptrFromInt(self.data))));
    }

    pub fn asEnum(self: Value) *ObjEnum {
        return @ptrCast(@alignCast(@as(*anyopaque, @ptrFromInt(self.data))));
    }

    pub fn asNativeFn(self: Value) *ObjNativeFn {
        return @ptrCast(@alignCast(@as(*anyopaque, @ptrFromInt(self.data))));
    }

    pub fn asClosure(self: Value) *ObjClosure {
        return @ptrCast(@alignCast(@as(*anyopaque, @ptrFromInt(self.data))));
    }

    pub fn isTruthy(self: Value) bool {
        return switch (self.tag) {
            .nil => false,
            .bool_ => self.asBool(),
            .int => self.asInt() != 0,
            .float => self.asFloat() != 0.0,
            .string, .function, .struct_, .enum_, .native_fn, .closure => true,
        };
    }

    pub fn eql(a: Value, b: Value) bool {
        if (a.tag != b.tag) return false;
        return switch (a.tag) {
            .nil => true,
            .bool_ => a.asBool() == b.asBool(),
            .int => a.asInt() == b.asInt(),
            .float => a.asFloat() == b.asFloat(),
            .string => std.mem.eql(u8, a.asString().chars, b.asString().chars),
            .function, .struct_, .enum_, .native_fn, .closure => a.data == b.data,
        };
    }

    pub fn dump(self: Value) void {
        switch (self.tag) {
            .nil => std.debug.print("nil", .{}),
            .bool_ => std.debug.print("{}", .{self.asBool()}),
            .int => std.debug.print("{d}", .{self.asInt()}),
            .float => std.debug.print("{d}", .{self.asFloat()}),
            .string => std.debug.print("{s}", .{self.asString().chars}),
            .function => std.debug.print("<fn {s}>", .{self.asFunction().name}),
            .struct_ => {
                const s = self.asStruct();
                std.debug.print("{s} {{ ", .{s.name});
                const fv = s.fieldValues();
                for (s.field_names, 0..) |name, i| {
                    if (i > 0) std.debug.print(", ", .{});
                    std.debug.print("{s}: ", .{name});
                    fv[i].dump();
                }
                std.debug.print(" }}", .{});
            },
            .enum_ => {
                const e = self.asEnum();
                std.debug.print("{s}", .{e.variant});
                if (e.payloads.len > 0) {
                    std.debug.print("(", .{});
                    for (e.payloads, 0..) |val, i| {
                        if (i > 0) std.debug.print(", ", .{});
                        val.dump();
                    }
                    std.debug.print(")", .{});
                }
            },
            .native_fn => std.debug.print("<native fn>", .{}),
            .closure => std.debug.print("<closure>", .{}),
        }
    }
};

pub const ObjString = struct {
    chars: []const u8,

    pub fn create(alloc: std.mem.Allocator, chars: []const u8) *ObjString {
        const str = alloc.create(ObjString) catch @panic("oom");
        str.* = .{ .chars = chars };
        return str;
    }

    pub fn toValue(self: *ObjString) Value {
        return Value.initString(self);
    }
};

pub const ObjStruct = struct {
    name: []const u8,
    field_names: []const []const u8,
    field_count: u8,

    const header_slots = (@sizeOf(ObjStruct) + @sizeOf(Value) - 1) / @sizeOf(Value);

    pub fn fieldValues(self: *ObjStruct) [*]Value {
        const base: [*]Value = @ptrCast(@alignCast(@as([*]u8, @ptrCast(self))));
        return base + header_slots;
    }

    pub fn create(alloc: std.mem.Allocator, name: []const u8, field_names: []const []const u8, values: []Value) *ObjStruct {
        const buf = alloc.alloc(Value, header_slots + values.len) catch @panic("oom");
        const self: *ObjStruct = @ptrCast(&buf[0]);
        self.* = .{ .name = name, .field_names = field_names, .field_count = @intCast(values.len) };
        const fv = self.fieldValues();
        for (values, 0..) |v, i| {
            fv[i] = v;
        }
        return self;
    }

    pub fn getField(self: *ObjStruct, name: []const u8) ?Value {
        for (self.field_names, 0..) |fname, i| {
            if (std.mem.eql(u8, fname, name)) return self.fieldValues()[i];
        }
        return null;
    }

    pub fn toValue(self: *ObjStruct) Value {
        return Value.initStruct(self);
    }
};

pub const ObjEnum = struct {
    type_name: []const u8,
    variant: []const u8,
    payloads: []Value,

    pub fn create(alloc: std.mem.Allocator, type_name: []const u8, variant: []const u8, payloads: []Value) *ObjEnum {
        const e = alloc.create(ObjEnum) catch @panic("oom");
        e.* = .{ .type_name = type_name, .variant = variant, .payloads = payloads };
        return e;
    }

    pub fn toValue(self: *ObjEnum) Value {
        return Value.initEnum(self);
    }
};

pub const ObjNativeFn = struct {
    name: []const u8,
    arity: u8,
    func: *const fn ([]const Value) Value,

    pub fn create(alloc: std.mem.Allocator, name: []const u8, arity: u8, func: *const fn ([]const Value) Value) *ObjNativeFn {
        const nf = alloc.create(ObjNativeFn) catch @panic("oom");
        nf.* = .{ .name = name, .arity = arity, .func = func };
        return nf;
    }

    pub fn toValue(self: *ObjNativeFn) Value {
        return Value.initNativeFn(self);
    }
};

pub const ObjClosure = struct {
    function: *ObjFunction,
    upvalues: []Value,

    pub fn create(alloc: std.mem.Allocator, function: *ObjFunction, upvalues: []Value) *ObjClosure {
        const c = alloc.create(ObjClosure) catch @panic("oom");
        c.* = .{ .function = function, .upvalues = upvalues };
        return c;
    }

    pub fn toValue(self: *ObjClosure) Value {
        return Value.initClosure(self);
    }
};

pub const ObjFunction = struct {
    name: []const u8,
    arity: u8,
    locals_only: bool,
    chunk: @import("chunk.zig").Chunk,

    pub fn create(alloc: std.mem.Allocator, name: []const u8, arity: u8) *ObjFunction {
        const func = alloc.create(ObjFunction) catch @panic("oom");
        func.* = .{
            .name = name,
            .arity = arity,
            .locals_only = false,
            .chunk = @import("chunk.zig").Chunk.init(),
        };
        return func;
    }

    pub fn toValue(self: *ObjFunction) Value {
        return Value.initFunction(self);
    }
};

test "value: int round-trip" {
    const v = Value.initInt(42);
    try std.testing.expectEqual(@as(i64, 42), v.asInt());
}

test "value: float round-trip" {
    const v = Value.initFloat(3.14);
    try std.testing.expectEqual(@as(f64, 3.14), v.asFloat());
}

test "value: bool round-trip" {
    const t = Value.initBool(true);
    const f = Value.initBool(false);
    try std.testing.expect(t.asBool());
    try std.testing.expect(!f.asBool());
}

test "value: nil is falsy" {
    try std.testing.expect(!Value.initNil().isTruthy());
}

test "value: equality" {
    try std.testing.expect(Value.eql(Value.initInt(5), Value.initInt(5)));
    try std.testing.expect(!Value.eql(Value.initInt(5), Value.initInt(6)));
    try std.testing.expect(!Value.eql(Value.initInt(5), Value.initFloat(5.0)));
}
