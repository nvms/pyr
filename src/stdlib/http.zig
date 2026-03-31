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
    .{ .name = "get", .arity = 1, .func = &httpGet },
    .{ .name = "post", .arity = 2, .func = &httpPost },
    .{ .name = "fetch", .arity = 1, .func = &httpFetch },
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

const ObjMap = @import("../value.zig").ObjMap;
const net = @import("net.zig");
const tls_mod = @import("tls.zig");

fn getStringField(val: Value, field: []const u8) ?[]const u8 {
    if (val.tag() == .struct_) {
        const s = val.asStruct();
        if (s.getField(field)) |fv| {
            if (fv.tag() == .string) return fv.asString().chars;
        }
    } else if (val.tag() == .map) {
        const m = val.asMap();
        if (m.get(field)) |fv| {
            if (fv.tag() == .string) return fv.asString().chars;
        }
    }
    return null;
}

const ParsedUrl = struct {
    host: []const u8,
    port: u16,
    path: []const u8,
    is_tls: bool,
};

fn parseUrl(url: []const u8) ?ParsedUrl {
    var rest = url;
    var is_tls = false;
    if (std.mem.startsWith(u8, rest, "https://")) {
        is_tls = true;
        rest = rest[8..];
    } else if (std.mem.startsWith(u8, rest, "http://")) {
        rest = rest[7..];
    } else {
        return null;
    }
    const path_start = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
    const host_port = rest[0..path_start];
    const path = if (path_start < rest.len) rest[path_start..] else "/";
    if (std.mem.indexOfScalar(u8, host_port, ':')) |colon| {
        return .{
            .host = host_port[0..colon],
            .port = std.fmt.parseInt(u16, host_port[colon + 1 ..], 10) catch return null,
            .path = path,
            .is_tls = is_tls,
        };
    }
    return .{
        .host = host_port,
        .port = if (is_tls) 443 else 80,
        .path = path,
        .is_tls = is_tls,
    };
}

fn doRequest(alloc: std.mem.Allocator, url_str: []const u8, method: []const u8, extra_headers: ?[]const u8, body: ?[]const u8) Value {
    const parsed = parseUrl(url_str) orelse return root.makeIoError(alloc, "invalid url");

    const host_owned = alloc.dupe(u8, parsed.host) catch return root.makeIoError(alloc, "out of memory");
    const host_val = ObjString.create(alloc, host_owned).toValue();
    const port_val = Value.initInt(@intCast(parsed.port));
    const connect_args = [_]Value{ host_val, port_val };
    const conn_val = net.fns[2].func(alloc, &connect_args);
    if (conn_val.tag() == .enum_) return conn_val;

    var final_conn = conn_val;
    if (parsed.is_tls) {
        const hostname_val = ObjString.create(alloc, host_owned).toValue();
        const tls_args = [_]Value{ conn_val, hostname_val };
        final_conn = tls_mod.fns[0].func(alloc, &tls_args);
        if (final_conn.tag() == .enum_) return final_conn;
    }

    var req = std.ArrayListUnmanaged(u8){};
    req.appendSlice(alloc, method) catch return root.makeIoError(alloc, "out of memory");
    req.appendSlice(alloc, " ") catch {};
    req.appendSlice(alloc, parsed.path) catch {};
    req.appendSlice(alloc, " HTTP/1.1\r\nHost: ") catch {};
    req.appendSlice(alloc, parsed.host) catch {};
    req.appendSlice(alloc, "\r\nConnection: close\r\n") catch {};
    if (extra_headers) |hdrs| {
        if (hdrs.len > 0) {
            req.appendSlice(alloc, hdrs) catch {};
            if (!std.mem.endsWith(u8, hdrs, "\r\n"))
                req.appendSlice(alloc, "\r\n") catch {};
        }
    }
    if (body) |b| {
        var len_buf: [20]u8 = undefined;
        const len_str = std.fmt.bufPrint(&len_buf, "{d}", .{b.len}) catch "0";
        req.appendSlice(alloc, "Content-Length: ") catch {};
        req.appendSlice(alloc, len_str) catch {};
        req.appendSlice(alloc, "\r\n") catch {};
    }
    req.appendSlice(alloc, "\r\n") catch {};
    if (body) |b| req.appendSlice(alloc, b) catch {};

    const req_str = ObjString.create(alloc, req.items).toValue();
    const write_args = [_]Value{ final_conn, req_str };
    _ = net.fns[4].func(alloc, &write_args);

    var resp_buf = std.ArrayListUnmanaged(u8){};
    while (true) {
        const read_args = [_]Value{final_conn};
        const chunk = net.fns[3].func(alloc, &read_args);
        if (chunk.tag() == .enum_) break;
        if (chunk.tag() != .string) break;
        resp_buf.appendSlice(alloc, chunk.asString().chars) catch break;
    }

    const close_args = [_]Value{final_conn};
    _ = net.fns[5].func(alloc, &close_args);

    return parseResponse(alloc, resp_buf.items);
}

fn parseResponse(alloc: std.mem.Allocator, raw: []const u8) Value {
    const status_end = std.mem.indexOf(u8, raw, "\r\n") orelse return root.makeIoError(alloc, "invalid response");
    const status_line = raw[0..status_end];

    var status_code: i64 = 0;
    const sp1 = std.mem.indexOfScalar(u8, status_line, ' ') orelse 0;
    if (sp1 > 0 and sp1 + 1 < status_line.len) {
        const after_ver = status_line[sp1 + 1 ..];
        const sp2 = std.mem.indexOfScalar(u8, after_ver, ' ') orelse after_ver.len;
        status_code = std.fmt.parseInt(i64, after_ver[0..sp2], 10) catch 0;
    }

    const header_end = std.mem.indexOf(u8, raw, "\r\n\r\n") orelse raw.len;
    const headers = raw[status_end + 2 .. header_end];
    const body_start = if (header_end + 4 <= raw.len) header_end + 4 else raw.len;

    var body_data: []const u8 = raw[body_start..];

    const is_chunked = blk: {
        var lo_buf: [4096]u8 = undefined;
        const lo_len = @min(headers.len, lo_buf.len);
        for (headers[0..lo_len], 0..) |c, i| {
            lo_buf[i] = if (c >= 'A' and c <= 'Z') c + 32 else c;
        }
        break :blk std.mem.indexOf(u8, lo_buf[0..lo_len], "transfer-encoding: chunked") != null;
    };
    if (is_chunked) {
        body_data = decodeChunked(alloc, body_data);
    }

    const field_names = alloc.alloc([]const u8, 3) catch return root.makeIoError(alloc, "out of memory");
    field_names[0] = "status";
    field_names[1] = "headers";
    field_names[2] = "body";
    var values: [3]Value = .{
        Value.initInt(status_code),
        ObjString.create(alloc, alloc.dupe(u8, headers) catch "").toValue(),
        ObjString.create(alloc, alloc.dupe(u8, body_data) catch "").toValue(),
    };
    return ObjStruct.create(alloc, "Response", field_names, &values).toValue();
}

fn decodeChunked(alloc: std.mem.Allocator, data: []const u8) []const u8 {
    var result = std.ArrayListUnmanaged(u8){};
    var pos: usize = 0;
    while (pos < data.len) {
        const line_end = std.mem.indexOf(u8, data[pos..], "\r\n") orelse break;
        const size_str = data[pos .. pos + line_end];
        const chunk_size = std.fmt.parseInt(usize, size_str, 16) catch break;
        if (chunk_size == 0) break;
        pos += line_end + 2;
        if (pos + chunk_size > data.len) break;
        result.appendSlice(alloc, data[pos .. pos + chunk_size]) catch break;
        pos += chunk_size + 2;
    }
    return result.items;
}

fn httpGet(alloc: std.mem.Allocator, args: []const Value) Value {
    if (args[0].tag() != .string) return root.makeIoError(alloc, "get requires url string");
    return doRequest(alloc, args[0].asString().chars, "GET", null, null);
}

fn httpPost(alloc: std.mem.Allocator, args: []const Value) Value {
    if (args[0].tag() != .string) return root.makeIoError(alloc, "post requires url string");
    const body_str = getStringField(args[1], "body");
    const headers_str = getStringField(args[1], "headers");
    return doRequest(alloc, args[0].asString().chars, "POST", headers_str, body_str);
}

fn httpFetch(alloc: std.mem.Allocator, args: []const Value) Value {
    const opts = args[0];
    const url = getStringField(opts, "url") orelse return root.makeIoError(alloc, "fetch requires url field");
    const method = getStringField(opts, "method") orelse "GET";
    const headers_str = getStringField(opts, "headers");
    const body_str = getStringField(opts, "body");
    return doRequest(alloc, url, method, headers_str, body_str);
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
