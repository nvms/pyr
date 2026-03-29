const std = @import("std");
const Value = @import("../value.zig").Value;
const ObjStruct = @import("../value.zig").ObjStruct;
const GC = @import("../gc.zig").GC;
const root = @import("../stdlib.zig");

var gc_ptr: ?*GC = null;

pub fn setGc(gc: *GC) void {
    gc_ptr = gc;
}

pub const fns = [_]root.NativeDef{
    .{ .name = "pause", .arity = 0, .func = &gcPause },
    .{ .name = "resume", .arity = 0, .func = &gcResume },
    .{ .name = "collect", .arity = 0, .func = &gcCollect },
    .{ .name = "stats", .arity = 0, .func = &gcStats },
};

fn gcPause(_: std.mem.Allocator, _: []const Value) Value {
    if (gc_ptr) |gc| gc.paused = true;
    return Value.initNil();
}

fn gcResume(_: std.mem.Allocator, _: []const Value) Value {
    if (gc_ptr) |gc| gc.paused = false;
    return Value.initNil();
}

fn gcCollect(_: std.mem.Allocator, _: []const Value) Value {
    // collect requires roots which we don't have from a native fn
    // just reset the threshold to trigger collection at the next safepoint
    if (gc_ptr) |gc| gc.next_threshold = 0;
    return Value.initNil();
}

fn gcStats(alloc: std.mem.Allocator, _: []const Value) Value {
    const gc = gc_ptr orelse return Value.initNil();
    const field_names = alloc.alloc([]const u8, 3) catch return Value.initNil();
    field_names[0] = "bytes_allocated";
    field_names[1] = "collections";
    field_names[2] = "objects";
    const vals = alloc.alloc(Value, 3) catch return Value.initNil();
    vals[0] = Value.initInt(@intCast(gc.bytes_allocated));
    vals[1] = Value.initInt(@intCast(gc.collections));
    vals[2] = Value.initInt(@intCast(gc.objects.items.len));
    return ObjStruct.create(alloc, "GcStats", field_names, vals).toValue();
}
