const std = @import("std");
const Value = @import("../value.zig").Value;
const ObjString = @import("../value.zig").ObjString;
const ObjStruct = @import("../value.zig").ObjStruct;
const json = @import("json.zig");
const root = @import("../stdlib.zig");

pub const fns = [_]root.NativeDef{
    .{ .name = "parse_request", .arity = 1, .func = &httpParseRequest },
    .{ .name = "respond", .arity = 1, .func = &httpRespond },
    .{ .name = "respond_status", .arity = 2, .func = &httpRespondStatus },
    .{ .name = "json_response", .arity = 1, .func = &httpJsonResponse },
    .{ .name = "route", .arity = 3, .func = &httpRoute },
    .{ .name = "match_route", .arity = 3, .func = &httpMatchRoute },
};

fn httpParseRequest(alloc: std.mem.Allocator, args: []const Value) Value {
    if (args[0].tag() != .string) return Value.initNil();
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
    if (args[0].tag() != .string) return Value.initNil();
    return buildResponse(alloc, "200 OK", "text/plain", args[0].asString().chars);
}

fn httpRespondStatus(alloc: std.mem.Allocator, args: []const Value) Value {
    if (args[0].tag() != .int or args[1].tag() != .string) return Value.initNil();
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
    json.writeValue(alloc, &buf, args[0]);
    return buildResponse(alloc, "200 OK", "application/json", buf.items);
}

fn httpRoute(alloc: std.mem.Allocator, args: []const Value) Value {
    if (args[0].tag() != .string or args[1].tag() != .string) return Value.initNil();
    const field_names = alloc.alloc([]const u8, 3) catch return Value.initNil();
    field_names[0] = "method";
    field_names[1] = "path";
    field_names[2] = "handler";
    var values: [3]Value = .{ args[0], args[1], args[2] };
    return ObjStruct.create(alloc, "Route", field_names, &values).toValue();
}

fn httpMatchRoute(_: std.mem.Allocator, args: []const Value) Value {
    if (args[0].tag() != .array or args[1].tag() != .string or args[2].tag() != .string) return Value.initNil();
    const routes = args[0].asArray();
    const method = args[1].asString().chars;
    const path = args[2].asString().chars;

    for (routes.items) |route_val| {
        if (route_val.tag() != .struct_) continue;
        const route = route_val.asStruct();
        const fv = route.fieldValues();
        if (fv[0].tag() != .string or fv[1].tag() != .string) continue;

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
