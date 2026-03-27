const std = @import("std");
const builtin = @import("builtin");

const SSL_FILETYPE_PEM = 1;
const SSL_ERROR_WANT_READ = 2;
const SSL_ERROR_WANT_WRITE = 3;

pub const Ssl = struct {
    lib_ssl: std.DynLib,
    lib_crypto: std.DynLib,

    SSL_CTX_new: *const fn (*anyopaque) callconv(.c) ?*anyopaque,
    SSL_CTX_free: *const fn (*anyopaque) callconv(.c) void,
    SSL_CTX_use_certificate_file: *const fn (*anyopaque, [*:0]const u8, c_int) callconv(.c) c_int,
    SSL_CTX_use_PrivateKey_file: *const fn (*anyopaque, [*:0]const u8, c_int) callconv(.c) c_int,
    TLS_server_method: *const fn () callconv(.c) *anyopaque,
    SSL_new: *const fn (*anyopaque) callconv(.c) ?*anyopaque,
    SSL_free: *const fn (*anyopaque) callconv(.c) void,
    SSL_set_fd: *const fn (*anyopaque, c_int) callconv(.c) c_int,
    SSL_accept: *const fn (*anyopaque) callconv(.c) c_int,
    SSL_read: *const fn (*anyopaque, [*]u8, c_int) callconv(.c) c_int,
    SSL_write: *const fn (*anyopaque, [*]const u8, c_int) callconv(.c) c_int,
    SSL_shutdown: *const fn (*anyopaque) callconv(.c) c_int,
    SSL_get_error: *const fn (*anyopaque, c_int) callconv(.c) c_int,

    pub fn load() ?Ssl {
        const ssl_names = comptime switch (builtin.os.tag) {
            .macos => [_][]const u8{
                "/opt/homebrew/opt/openssl/lib/libssl.dylib",
                "/usr/local/opt/openssl/lib/libssl.dylib",
                "libssl.3.dylib",
                "libssl.dylib",
            },
            else => [_][]const u8{
                "libssl.so.3",
                "libssl.so",
            },
        };
        const crypto_names = comptime switch (builtin.os.tag) {
            .macos => [_][]const u8{
                "/opt/homebrew/opt/openssl/lib/libcrypto.dylib",
                "/usr/local/opt/openssl/lib/libcrypto.dylib",
                "libcrypto.3.dylib",
                "libcrypto.dylib",
            },
            else => [_][]const u8{
                "libcrypto.so.3",
                "libcrypto.so",
            },
        };

        var lib_crypto: ?std.DynLib = null;
        for (crypto_names) |name| {
            lib_crypto = std.DynLib.open(name) catch continue;
            break;
        }
        if (lib_crypto == null) return null;

        var lib_ssl: ?std.DynLib = null;
        for (ssl_names) |name| {
            lib_ssl = std.DynLib.open(name) catch continue;
            break;
        }
        if (lib_ssl == null) {
            lib_crypto.?.close();
            return null;
        }

        var s = lib_ssl.?;

        const init_fn = s.lookup(*const fn (u64, ?*anyopaque) callconv(.c) c_int, "OPENSSL_init_ssl");
        if (init_fn) |f| {
            _ = f(0, null);
        }

        return .{
            .lib_ssl = s,
            .lib_crypto = lib_crypto.?,
            .SSL_CTX_new = s.lookup(*const fn (*anyopaque) callconv(.c) ?*anyopaque, "SSL_CTX_new") orelse return null,
            .SSL_CTX_free = s.lookup(*const fn (*anyopaque) callconv(.c) void, "SSL_CTX_free") orelse return null,
            .SSL_CTX_use_certificate_file = s.lookup(*const fn (*anyopaque, [*:0]const u8, c_int) callconv(.c) c_int, "SSL_CTX_use_certificate_file") orelse return null,
            .SSL_CTX_use_PrivateKey_file = s.lookup(*const fn (*anyopaque, [*:0]const u8, c_int) callconv(.c) c_int, "SSL_CTX_use_PrivateKey_file") orelse return null,
            .TLS_server_method = s.lookup(*const fn () callconv(.c) *anyopaque, "TLS_server_method") orelse return null,
            .SSL_new = s.lookup(*const fn (*anyopaque) callconv(.c) ?*anyopaque, "SSL_new") orelse return null,
            .SSL_free = s.lookup(*const fn (*anyopaque) callconv(.c) void, "SSL_free") orelse return null,
            .SSL_set_fd = s.lookup(*const fn (*anyopaque, c_int) callconv(.c) c_int, "SSL_set_fd") orelse return null,
            .SSL_accept = s.lookup(*const fn (*anyopaque) callconv(.c) c_int, "SSL_accept") orelse return null,
            .SSL_read = s.lookup(*const fn (*anyopaque, [*]u8, c_int) callconv(.c) c_int, "SSL_read") orelse return null,
            .SSL_write = s.lookup(*const fn (*anyopaque, [*]const u8, c_int) callconv(.c) c_int, "SSL_write") orelse return null,
            .SSL_shutdown = s.lookup(*const fn (*anyopaque) callconv(.c) c_int, "SSL_shutdown") orelse return null,
            .SSL_get_error = s.lookup(*const fn (*anyopaque, c_int) callconv(.c) c_int, "SSL_get_error") orelse return null,
        };
    }

    pub fn createContext(self: *Ssl, cert_path: [*:0]const u8, key_path: [*:0]const u8) ?*anyopaque {
        const method = self.TLS_server_method();
        const ctx = self.SSL_CTX_new(method) orelse return null;
        if (self.SSL_CTX_use_certificate_file(ctx, cert_path, SSL_FILETYPE_PEM) != 1) {
            self.SSL_CTX_free(ctx);
            return null;
        }
        if (self.SSL_CTX_use_PrivateKey_file(ctx, key_path, SSL_FILETYPE_PEM) != 1) {
            self.SSL_CTX_free(ctx);
            return null;
        }
        return ctx;
    }

    pub fn accept(self: *Ssl, ctx: *anyopaque, fd: c_int) ?*anyopaque {
        const ssl = self.SSL_new(ctx) orelse return null;
        _ = self.SSL_set_fd(ssl, fd);
        const ret = self.SSL_accept(ssl);
        if (ret != 1) {
            self.SSL_free(ssl);
            return null;
        }
        return ssl;
    }

    pub fn read(self: *Ssl, ssl: *anyopaque, buf: []u8) c_int {
        return self.SSL_read(ssl, buf.ptr, @intCast(buf.len));
    }

    pub fn write(self: *Ssl, ssl: *anyopaque, data: []const u8) c_int {
        return self.SSL_write(ssl, data.ptr, @intCast(data.len));
    }

    pub fn shutdown(self: *Ssl, ssl: *anyopaque) void {
        _ = self.SSL_shutdown(ssl);
    }

    pub fn freeSsl(self: *Ssl, ssl: *anyopaque) void {
        self.SSL_free(ssl);
    }

    pub fn freeCtx(self: *Ssl, ctx: *anyopaque) void {
        self.SSL_CTX_free(ctx);
    }

    pub fn getError(self: *Ssl, ssl: *anyopaque, ret: c_int) c_int {
        return self.SSL_get_error(ssl, ret);
    }
};

var instance: ?Ssl = null;
var init_done = false;

pub fn get() ?*Ssl {
    if (init_done) return if (instance != null) &instance.? else null;
    init_done = true;
    instance = Ssl.load();
    return if (instance != null) &instance.? else null;
}
