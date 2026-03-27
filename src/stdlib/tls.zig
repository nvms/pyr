const std = @import("std");
const Value = @import("../value.zig").Value;
const ObjString = @import("../value.zig").ObjString;
const ObjConn = @import("../value.zig").ObjConn;
const ObjTlsConn = @import("../value.zig").ObjTlsConn;
const root = @import("../stdlib.zig");

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
};

fn tlsUpgrade(alloc: std.mem.Allocator, args: []const Value) Value {
    if (args[0].tag != .conn) return root.makeIoError(alloc, "upgrade requires conn");

    const conn = args[0].asConn();
    const hostname: ?[]const u8 = if (args[1].tag == .string) args[1].asString().chars else null;

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
