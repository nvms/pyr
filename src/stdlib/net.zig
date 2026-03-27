const std = @import("std");
const Value = @import("../value.zig").Value;
const ObjString = @import("../value.zig").ObjString;
const ObjStruct = @import("../value.zig").ObjStruct;
const ObjEnum = @import("../value.zig").ObjEnum;
const ObjListener = @import("../value.zig").ObjListener;
const ObjConn = @import("../value.zig").ObjConn;
const ObjDgram = @import("../value.zig").ObjDgram;
const ObjTlsConn = @import("../value.zig").ObjTlsConn;
const root = @import("../stdlib.zig");

pub const fns = [_]root.NativeDef{
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

pub fn setNonBlocking(fd: std.posix.fd_t) void {
    const flags = std.posix.fcntl(fd, std.posix.F.GETFL, 0) catch return;
    const o_flags: std.posix.O = @bitCast(@as(u32, @truncate(flags)));
    var new_flags = o_flags;
    new_flags.NONBLOCK = true;
    _ = std.posix.fcntl(fd, std.posix.F.SETFL, @as(usize, @as(u32, @bitCast(new_flags)))) catch return;
}

pub fn buildRecvfromResult(alloc: std.mem.Allocator, data: []const u8, src_addr: *const std.posix.sockaddr.in) Value {
    const data_owned = alloc.dupe(u8, data) catch return root.makeIoError(alloc, "out of memory");
    const data_str = ObjString.create(alloc, data_owned);

    const ip_bytes = @as(*const [4]u8, @ptrCast(&src_addr.addr));
    var ip_buf: [15]u8 = undefined;
    const ip_len = std.fmt.bufPrint(&ip_buf, "{d}.{d}.{d}.{d}", .{ ip_bytes[0], ip_bytes[1], ip_bytes[2], ip_bytes[3] }) catch return root.makeIoError(alloc, "format failed");
    const ip_owned = alloc.dupe(u8, ip_len) catch return root.makeIoError(alloc, "out of memory");
    const addr_val = ObjString.create(alloc, ip_owned);

    const src_port: i64 = std.mem.bigToNative(u16, src_addr.port);

    const field_names = alloc.alloc([]const u8, 3) catch return root.makeIoError(alloc, "out of memory");
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

fn netListen(alloc: std.mem.Allocator, args: []const Value) Value {
    if (args[0].tag() != .string or args[1].tag() != .int) return root.makeIoError(alloc, "listen requires string and int");
    const addr_str = args[0].asString().chars;
    const port: u16 = @intCast(@as(i64, @max(0, @min(65535, args[1].asInt()))));

    const fd = std.posix.socket(std.posix.AF.INET, std.posix.SOCK.STREAM, 0) catch return root.makeIoError(alloc, "socket failed");

    const yes: c_int = 1;
    std.posix.setsockopt(fd, std.posix.SOL.SOCKET, std.posix.SO.REUSEADDR, &std.mem.toBytes(yes)) catch {
        std.posix.close(fd);
        return root.makeIoError(alloc, "setsockopt failed");
    };

    const octets = parseAddr(addr_str);
    const addr = std.net.Address.initIp4(octets, port);
    std.posix.bind(fd, &addr.any, addr.getOsSockLen()) catch {
        std.posix.close(fd);
        return root.makeIoError(alloc, "bind failed");
    };

    std.posix.listen(fd, 128) catch {
        std.posix.close(fd);
        return root.makeIoError(alloc, "listen failed");
    };

    return ObjListener.create(alloc, fd, port).toValue();
}

fn netAccept(alloc: std.mem.Allocator, args: []const Value) Value {
    if (args[0].tag() != .ext or args[0].extKind() != .listener) return root.makeIoError(alloc, "accept requires listener");
    const listener = args[0].asListener();
    const client_fd = std.posix.accept(listener.fd, null, null, 0) catch return root.makeIoError(alloc, "accept failed");
    return ObjConn.create(alloc, client_fd).toValue();
}

pub fn resolveAddress(alloc: std.mem.Allocator, addr_str: []const u8, port: u16) ?std.net.Address {
    const octets = parseAddr(addr_str);
    const is_default = octets[0] == 0 and octets[1] == 0 and octets[2] == 0 and octets[3] == 0;
    if (!is_default or addr_str.len == 0 or std.mem.eql(u8, addr_str, "0.0.0.0")) {
        return std.net.Address.initIp4(octets, port);
    }
    const list = std.net.getAddressList(alloc, addr_str, port) catch return null;
    defer list.deinit();
    if (list.addrs.len == 0) return null;
    return list.addrs[0];
}

fn netConnect(alloc: std.mem.Allocator, args: []const Value) Value {
    if (args[0].tag() != .string or args[1].tag() != .int) return root.makeIoError(alloc, "connect requires string and int");
    const addr_str = args[0].asString().chars;
    const port: u16 = @intCast(@as(i64, @max(0, @min(65535, args[1].asInt()))));

    const addr = resolveAddress(alloc, addr_str, port) orelse return root.makeIoError(alloc, "dns resolution failed");

    const fd = std.posix.socket(addr.any.family, std.posix.SOCK.STREAM, 0) catch return root.makeIoError(alloc, "socket failed");
    std.posix.connect(fd, &addr.any, addr.getOsSockLen()) catch {
        std.posix.close(fd);
        return root.makeIoError(alloc, "connect failed");
    };

    return ObjConn.create(alloc, fd).toValue();
}

fn netRead(alloc: std.mem.Allocator, args: []const Value) Value {
    if (args[0].tag() == .ext and args[0].extKind() == .tls_conn) return tlsRead(alloc, args[0].asTlsConn());
    if (args[0].tag() != .conn) return root.makeIoError(alloc, "read requires conn");
    const conn = args[0].asConn();
    var buf: [8192]u8 = undefined;
    const n = std.posix.read(conn.fd, &buf) catch return root.makeIoError(alloc, "read failed");
    if (n == 0) return root.makeIoEof(alloc);
    const owned = alloc.dupe(u8, buf[0..n]) catch return root.makeIoError(alloc, "out of memory");
    return ObjString.create(alloc, owned).toValue();
}

pub fn setRecvTimeout(fd: std.posix.fd_t, ms: i32) void {
    if (ms < 0) return;
    const ms_long: i64 = ms;
    const tv = std.posix.timeval{ .sec = @intCast(@divTrunc(ms_long, 1000)), .usec = @intCast(@rem(ms_long, 1000) * 1000) };
    std.posix.setsockopt(fd, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, &std.mem.toBytes(tv)) catch {};
}

pub fn clearRecvTimeout(fd: std.posix.fd_t) void {
    const tv = std.posix.timeval{ .sec = 0, .usec = 0 };
    std.posix.setsockopt(fd, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, &std.mem.toBytes(tv)) catch {};
}

fn tlsRead(alloc: std.mem.Allocator, obj: *ObjTlsConn) Value {
    const reader = &obj.client.reader;
    if (reader.end > reader.seek) {
        const buffered = reader.buffer[reader.seek..reader.end];
        const owned = alloc.dupe(u8, buffered) catch return root.makeIoError(alloc, "out of memory");
        reader.tossBuffered();
        return ObjString.create(alloc, owned).toValue();
    }
    const tmo: i32 = if (obj.timeout_ms >= 0) obj.timeout_ms else 5000;
    var pollfds = [1]std.posix.pollfd{.{ .fd = obj.fd, .events = std.posix.POLL.IN, .revents = 0 }};
    const poll_n = std.posix.poll(&pollfds, tmo) catch return root.makeIoError(alloc, "poll failed");
    if (poll_n == 0) {
        if (obj.timeout_ms >= 0) return ObjEnum.create(alloc, "IoError", "Timeout", 3, &.{}).toValue();
        return root.makeIoEof(alloc);
    }
    const data = reader.peekGreedy(1) catch return root.makeIoEof(alloc);
    if (data.len == 0) return root.makeIoEof(alloc);
    const owned = alloc.dupe(u8, data) catch return root.makeIoError(alloc, "out of memory");
    reader.tossBuffered();
    return ObjString.create(alloc, owned).toValue();
}

fn netWrite(alloc: std.mem.Allocator, args: []const Value) Value {
    if (args[0].tag() == .ext and args[0].extKind() == .tls_conn) return tlsWrite(alloc, args[0].asTlsConn(), args);
    if (args[0].tag() != .conn or args[1].tag() != .string) return root.makeIoError(alloc, "write requires conn and string");
    const conn = args[0].asConn();
    const data = args[1].asString().chars;
    var written: usize = 0;
    while (written < data.len) {
        written += std.posix.write(conn.fd, data[written..]) catch return root.makeIoError(alloc, "write failed");
    }
    return Value.initBool(true);
}

fn tlsWrite(alloc: std.mem.Allocator, obj: *ObjTlsConn, args: []const Value) Value {
    if (args.len < 2 or args[1].tag() != .string) return root.makeIoError(alloc, "write requires string");
    const data = args[1].asString().chars;
    obj.client.writer.writeAll(data) catch return root.makeIoError(alloc, "tls write failed");
    obj.client.writer.flush() catch return root.makeIoError(alloc, "tls flush failed");
    obj.client.output.flush() catch return root.makeIoError(alloc, "tls flush failed");
    return Value.initBool(true);
}

fn netClose(_: std.mem.Allocator, args: []const Value) Value {
    if (args[0].tag() == .ext) {
        switch (args[0].extKind()) {
            .listener => std.posix.close(args[0].asListener().fd),
            .dgram => std.posix.close(args[0].asDgram().fd),
            .tls_conn => {
                const obj = args[0].asTlsConn();
                obj.client.end() catch {};
                obj.client.writer.flush() catch {};
                std.posix.close(obj.fd);
            },
            .ssl_conn => {
                const ssl_mod = @import("ssl.zig");
                if (ssl_mod.get()) |ssl| {
                    ssl.shutdown(args[0].asSslConn().ssl);
                    ssl.freeSsl(args[0].asSslConn().ssl);
                }
                std.posix.close(args[0].asSslConn().fd);
            },
            .ssl_ctx => {},
        }
    } else if (args[0].tag() == .conn) {
        std.posix.close(args[0].asConn().fd);
    }
    return Value.initNil();
}

fn netTimeout(_: std.mem.Allocator, args: []const Value) Value {
    const ms: i32 = if (args[1].tag() == .int) @intCast(@as(i64, @max(-1, args[1].asInt()))) else -1;
    if (args[0].tag() == .ext) {
        switch (args[0].extKind()) {
            .listener => args[0].asListener().timeout_ms = ms,
            .dgram => args[0].asDgram().timeout_ms = ms,
            .tls_conn => args[0].asTlsConn().timeout_ms = ms,
            .ssl_conn => args[0].asSslConn().timeout_ms = ms,
            .ssl_ctx => {},
        }
    } else if (args[0].tag() == .conn) {
        args[0].asConn().timeout_ms = ms;
    }
    return Value.initNil();
}

fn netUdpBind(alloc: std.mem.Allocator, args: []const Value) Value {
    if (args[0].tag() != .string or args[1].tag() != .int) return root.makeIoError(alloc, "udp_bind requires string and int");
    const addr_str = args[0].asString().chars;
    const port: u16 = @intCast(@as(i64, @max(0, @min(65535, args[1].asInt()))));

    const fd = std.posix.socket(std.posix.AF.INET, std.posix.SOCK.DGRAM, 0) catch return root.makeIoError(alloc, "socket failed");

    const yes: c_int = 1;
    std.posix.setsockopt(fd, std.posix.SOL.SOCKET, std.posix.SO.REUSEADDR, &std.mem.toBytes(yes)) catch {
        std.posix.close(fd);
        return root.makeIoError(alloc, "setsockopt failed");
    };

    const octets = parseAddr(addr_str);
    const addr = std.net.Address.initIp4(octets, port);
    std.posix.bind(fd, &addr.any, addr.getOsSockLen()) catch {
        std.posix.close(fd);
        return root.makeIoError(alloc, "bind failed");
    };

    return ObjDgram.create(alloc, fd, true).toValue();
}

fn netUdpOpen(alloc: std.mem.Allocator, _: []const Value) Value {
    const fd = std.posix.socket(std.posix.AF.INET, std.posix.SOCK.DGRAM, 0) catch return root.makeIoError(alloc, "socket failed");
    return ObjDgram.create(alloc, fd, false).toValue();
}

fn netSendto(alloc: std.mem.Allocator, args: []const Value) Value {
    if ((args[0].tag() != .ext or args[0].extKind() != .dgram) or args[1].tag() != .string or args[2].tag() != .string or args[3].tag() != .int)
        return root.makeIoError(alloc, "sendto requires dgram, string, string, int");
    const dgram = args[0].asDgram();
    const data = args[1].asString().chars;
    const addr_str = args[2].asString().chars;
    const port: u16 = @intCast(@as(i64, @max(0, @min(65535, args[3].asInt()))));

    const octets = parseAddr(addr_str);
    const dest = std.net.Address.initIp4(octets, port);
    _ = std.posix.sendto(dgram.fd, data, 0, &dest.any, dest.getOsSockLen()) catch return root.makeIoError(alloc, "sendto failed");
    return Value.initBool(true);
}

fn netRecvfrom(alloc: std.mem.Allocator, args: []const Value) Value {
    if (args[0].tag() != .ext or args[0].extKind() != .dgram) return root.makeIoError(alloc, "recvfrom requires dgram");
    const dgram = args[0].asDgram();

    if (dgram.timeout_ms >= 0) {
        var pollfds = [1]std.posix.pollfd{.{ .fd = dgram.fd, .events = std.posix.POLL.IN, .revents = 0 }};
        const poll_n = std.posix.poll(&pollfds, dgram.timeout_ms) catch return root.makeIoError(alloc, "poll failed");
        if (poll_n == 0) {
            return ObjEnum.create(alloc, "IoError", "Timeout", 3, &.{}).toValue();
        }
    }

    var buf: [65535]u8 = undefined;
    var src_addr: std.posix.sockaddr.in = undefined;
    var addr_len: std.posix.socklen_t = @sizeOf(std.posix.sockaddr.in);
    const n = std.posix.recvfrom(dgram.fd, &buf, 0, @ptrCast(&src_addr), &addr_len) catch return root.makeIoError(alloc, "recvfrom failed");
    if (n == 0) return root.makeIoEof(alloc);

    return buildRecvfromResult(alloc, buf[0..n], &src_addr);
}
