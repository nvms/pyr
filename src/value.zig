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

    pub fn isTruthy(self: Value) bool {
        return switch (self.tag) {
            .nil => false,
            .bool_ => self.asBool(),
            .int => self.asInt() != 0,
            .float => self.asFloat() != 0.0,
            .string, .function => true,
        };
    }

    pub fn eql(a: Value, b: Value) bool {
        if (a.tag != b.tag) return false;
        return switch (a.tag) {
            .nil => true,
            .bool_ => a.asBool() == b.asBool(),
            .int => a.asInt() == b.asInt(),
            .float => a.asFloat() == b.asFloat(),
            .string, .function => a.data == b.data,
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

pub const ObjFunction = struct {
    name: []const u8,
    arity: u8,
    chunk: @import("chunk.zig").Chunk,

    pub fn create(alloc: std.mem.Allocator, name: []const u8, arity: u8) *ObjFunction {
        const func = alloc.create(ObjFunction) catch @panic("oom");
        func.* = .{
            .name = name,
            .arity = arity,
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
