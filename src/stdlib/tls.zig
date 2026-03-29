const std = @import("std");
const Value = @import("../value.zig").Value;
const ObjString = @import("../value.zig").ObjString;
const ObjConn = @import("../value.zig").ObjConn;
const ObjTlsConn = @import("../value.zig").ObjTlsConn;
const ObjSslCtx = @import("../value.zig").ObjSslCtx;
const ObjSslConn = @import("../value.zig").ObjSslConn;
const root = @import("../stdlib.zig");
const ssl_mod = @import("ssl.zig");

const tls = std.crypto.tls;
const Certificate = std.crypto.Certificate;
const Stream = std.net.Stream;

const buf_len = tls.max_ciphertext_record_len;

var ca_bundle: ?Certificate.Bundle = null;

fn getCaBundle(alloc: std.mem.Allocator) ?Certificate.Bundle {
    if (ca_bundle) |bundle| return bundle;
    var bundle: Certificate.Bundle = .{};
    bundle.rescan(alloc) catch return null;
    ca_bundle = bundle;
    return ca_bundle;
}

pub const fns = [_]root.NativeDef{
    .{ .name = "upgrade", .arity = 2, .func = &tlsUpgrade },
    .{ .name = "context", .arity = 2, .func = &tlsContext },
};

fn tlsContext(alloc: std.mem.Allocator, args: []const Value) Value {
    if (args[0].tag() != .string or args[1].tag() != .string) {
        return root.makeIoError(alloc, "context requires cert and key paths");
    }

    const ssl = ssl_mod.get() orelse return root.makeIoError(alloc, "OpenSSL not available");

    const cert = args[0].asString().chars;
    const key = args[1].asString().chars;

    const cert_z = alloc.dupeZ(u8, cert) catch return root.makeIoError(alloc, "out of memory");
    const key_z = alloc.dupeZ(u8, key) catch return root.makeIoError(alloc, "out of memory");

    const ctx = ssl.createContext(cert_z, key_z) orelse return root.makeIoError(alloc, "failed to load certificate or key");

    const obj = alloc.create(ObjSslCtx) catch return root.makeIoError(alloc, "out of memory");
    obj.* = .{ .ctx = ctx };
    return obj.toValue();
}

fn tlsUpgrade(alloc: std.mem.Allocator, args: []const Value) Value {
    if (!args[0].isConn()) return root.makeIoError(alloc, "upgrade requires conn");

    if (args[1].tag() == .ext and args[1].extKind() == .ssl_ctx) return sslServerUpgrade(alloc, args);

    return tlsClientUpgrade(alloc, args);
}

fn sslServerUpgrade(alloc: std.mem.Allocator, args: []const Value) Value {
    const ssl = ssl_mod.get() orelse return root.makeIoError(alloc, "OpenSSL not available");
    const conn = args[0].asConn();
    const ctx = args[1].asSslCtx();

    const ssl_ptr = ssl.accept(ctx.ctx, conn.fd) orelse return root.makeIoError(alloc, "ssl handshake failed");

    const obj = alloc.create(ObjSslConn) catch return root.makeIoError(alloc, "out of memory");
    obj.* = .{
        .fd = conn.fd,
        .ssl = ssl_ptr,
        .timeout_ms = conn.timeout_ms,
    };
    return obj.toValue();
}

fn tlsClientUpgrade(alloc: std.mem.Allocator, args: []const Value) Value {
    const conn = args[0].asConn();
    const hostname: ?[]const u8 = if (args[1].tag() == .string) args[1].asString().chars else null;

    const stream_read_buf = alloc.alloc(u8, buf_len) catch return root.makeIoError(alloc, "out of memory");
    const stream_write_buf = alloc.alloc(u8, buf_len) catch return root.makeIoError(alloc, "out of memory");
    const read_buf = alloc.alloc(u8, buf_len) catch return root.makeIoError(alloc, "out of memory");
    const write_buf = alloc.alloc(u8, buf_len) catch return root.makeIoError(alloc, "out of memory");

    const obj = alloc.create(ObjTlsConn) catch return root.makeIoError(alloc, "out of memory");

    const stream: Stream = .{ .handle = conn.fd };
    obj.stream_reader = stream.reader(stream_read_buf);
    obj.stream_writer = stream.writer(stream_write_buf);

    if (hostname) |h| {
        const bundle = getCaBundle(alloc);
        obj.client = tls.Client.init(
            obj.stream_reader.interface(),
            &obj.stream_writer.interface,
            .{
                .host = .{ .explicit = h },
                .ca = if (bundle) |b| .{ .bundle = b } else .no_verification,
                .read_buffer = read_buf,
                .write_buffer = write_buf,
                .allow_truncation_attacks = true,
            },
        ) catch return root.makeIoError(alloc, "tls handshake failed");
    } else {
        obj.client = tls.Client.init(
            obj.stream_reader.interface(),
            &obj.stream_writer.interface,
            .{
                .host = .no_verification,
                .ca = .no_verification,
                .read_buffer = read_buf,
                .write_buffer = write_buf,
                .allow_truncation_attacks = true,
            },
        ) catch return root.makeIoError(alloc, "tls handshake failed");
    }

    obj.fd = conn.fd;
    obj.timeout_ms = conn.timeout_ms;
    obj.read_buf = read_buf;
    obj.write_buf = write_buf;
    obj.stream_read_buf = stream_read_buf;
    obj.stream_write_buf = stream_write_buf;

    return obj.toValue();
}
