const std = @import("std");
const ast = @import("ast.zig");
const parser = @import("parser.zig");
const Token = @import("token.zig").Token;

pub const Module = struct {
    path: []const u8,
    dir: []const u8,
    source: []const u8,
    tree: ast.Ast,
};

pub const ModuleLoader = struct {
    alloc: std.mem.Allocator,
    modules: std.StringHashMapUnmanaged(*Module),
    entry_dir: []const u8,
    package_map: ?*const std.StringHashMapUnmanaged([]const u8) = null,

    pub fn init(alloc: std.mem.Allocator, entry_dir: []const u8) ModuleLoader {
        return .{
            .alloc = alloc,
            .modules = .{},
            .entry_dir = entry_dir,
        };
    }

    pub fn load(self: *ModuleLoader, import_path: []const []const u8, from_dir: []const u8) ?*Module {
        const resolved = self.resolve(import_path, from_dir) orelse return null;
        if (self.modules.get(resolved)) |mod| return mod;
        return self.parseModule(resolved);
    }

    fn resolve(self: *ModuleLoader, segments: []const []const u8, from_dir: []const u8) ?[]const u8 {
        if (segments.len == 0) return null;

        if (std.mem.eql(u8, segments[0], "std")) {
            return self.buildPath(self.entry_dir, segments);
        }

        const local_path = self.buildPath(from_dir, segments);
        if (local_path) |lp| {
            if (fileExists(lp)) return lp;
        }

        if (self.package_map) |pkg_map| {
            if (segments.len >= 1) {
                if (pkg_map.get(segments[0])) |pkg_dir| {
                    if (segments.len == 1) {
                        return self.buildPath(pkg_dir, &.{"src/main"});
                    }
                    return self.buildPath(pkg_dir, segments[1..]);
                }
            }
        }

        return local_path;
    }

    fn buildPath(self: *ModuleLoader, base_dir: []const u8, segments: []const []const u8) ?[]const u8 {
        if (segments.len == 0) return null;
        var path_buf = std.ArrayListUnmanaged(u8){};
        path_buf.appendSlice(self.alloc, base_dir) catch @panic("oom");

        for (segments) |seg| {
            if (path_buf.items.len > 0 and path_buf.items[path_buf.items.len - 1] != '/') {
                path_buf.append(self.alloc, '/') catch @panic("oom");
            }
            path_buf.appendSlice(self.alloc, seg) catch @panic("oom");
        }

        path_buf.appendSlice(self.alloc, ".pyr") catch @panic("oom");
        return path_buf.toOwnedSlice(self.alloc) catch @panic("oom");
    }

    fn parseModule(self: *ModuleLoader, path: []const u8) ?*Module {
        const source = std.fs.cwd().readFileAlloc(self.alloc, path, 10 * 1024 * 1024) catch return null;
        const tokens = parser.tokenize(self.alloc, source);
        var p = parser.Parser.init(tokens, source, self.alloc);
        const tree = p.parse();
        if (tree.errors.len > 0) return null;

        const dir = dirOf(path, self.alloc);

        const mod = self.alloc.create(Module) catch @panic("oom");
        mod.* = .{ .path = path, .dir = dir, .source = source, .tree = tree };
        self.modules.put(self.alloc, path, mod) catch @panic("oom");

        for (tree.items) |item| {
            if (item.kind == .import) {
                _ = self.load(item.kind.import.path, dir);
            }
        }

        return mod;
    }
};

fn fileExists(path: []const u8) bool {
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}

pub fn dirOf(path: []const u8, alloc: std.mem.Allocator) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |idx| {
        const d = alloc.alloc(u8, idx) catch @panic("oom");
        @memcpy(d, path[0..idx]);
        return d;
    }
    const d = alloc.alloc(u8, 1) catch @panic("oom");
    d[0] = '.';
    return d;
}
