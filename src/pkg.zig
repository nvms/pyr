const std = @import("std");

pub const Dependency = struct {
    url: []const u8,
    version: []const u8,
};

pub const Manifest = struct {
    name: []const u8,
    version: []const u8,
    deps: []const Dependency,
};

pub const LockEntry = struct {
    url: []const u8,
    version: []const u8,
    hash: []const u8,
};

pub const LockFile = struct {
    entries: []const LockEntry,
};

pub fn parseManifest(alloc: std.mem.Allocator, source: []const u8) ?Manifest {
    var name: ?[]const u8 = null;
    var version: ?[]const u8 = null;
    var deps = std.ArrayListUnmanaged(Dependency){};
    var in_require = false;

    var iter = std.mem.splitScalar(u8, source, '\n');
    while (iter.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;
        if (line[0] == '#') continue;

        if (in_require) {
            if (std.mem.eql(u8, line, ")")) {
                in_require = false;
                continue;
            }
            if (parseDependencyLine(line)) |dep| {
                deps.append(alloc, dep) catch @panic("oom");
            }
            continue;
        }

        if (std.mem.startsWith(u8, line, "name ")) {
            name = std.mem.trim(u8, line["name ".len..], " \t");
        } else if (std.mem.startsWith(u8, line, "version ")) {
            version = std.mem.trim(u8, line["version ".len..], " \t");
        } else if (std.mem.startsWith(u8, line, "require")) {
            const rest = std.mem.trim(u8, line["require".len..], " \t");
            if (std.mem.eql(u8, rest, "(")) {
                in_require = true;
            }
        }
    }

    const n = name orelse return null;
    const v = version orelse return null;

    return .{
        .name = n,
        .version = v,
        .deps = deps.toOwnedSlice(alloc) catch @panic("oom"),
    };
}

fn parseDependencyLine(line: []const u8) ?Dependency {
    const trimmed = std.mem.trim(u8, line, " \t");
    if (trimmed.len == 0) return null;

    if (std.mem.lastIndexOfScalar(u8, trimmed, ' ')) |sep| {
        return .{
            .url = std.mem.trim(u8, trimmed[0..sep], " \t"),
            .version = std.mem.trim(u8, trimmed[sep + 1 ..], " \t"),
        };
    }
    return .{ .url = trimmed, .version = "latest" };
}

pub fn parseLockFile(alloc: std.mem.Allocator, source: []const u8) LockFile {
    var entries = std.ArrayListUnmanaged(LockEntry){};
    var iter = std.mem.splitScalar(u8, source, '\n');
    while (iter.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;

        var parts = std.mem.splitScalar(u8, line, ' ');
        const url = parts.next() orelse continue;
        const ver = parts.next() orelse continue;
        const hash = parts.next() orelse continue;
        entries.append(alloc, .{ .url = url, .version = ver, .hash = hash }) catch @panic("oom");
    }
    return .{ .entries = entries.toOwnedSlice(alloc) catch @panic("oom") };
}

pub fn writeLockFile(alloc: std.mem.Allocator, entries: []const LockEntry) []const u8 {
    var buf = std.ArrayListUnmanaged(u8){};
    buf.appendSlice(alloc, "# pyr.lock - auto-generated, do not edit\n") catch @panic("oom");
    for (entries) |e| {
        buf.appendSlice(alloc, e.url) catch @panic("oom");
        buf.append(alloc, ' ') catch @panic("oom");
        buf.appendSlice(alloc, e.version) catch @panic("oom");
        buf.append(alloc, ' ') catch @panic("oom");
        buf.appendSlice(alloc, e.hash) catch @panic("oom");
        buf.append(alloc, '\n') catch @panic("oom");
    }
    return buf.toOwnedSlice(alloc) catch @panic("oom");
}

pub fn writeManifest(alloc: std.mem.Allocator, manifest: Manifest) []const u8 {
    var buf = std.ArrayListUnmanaged(u8){};
    buf.appendSlice(alloc, "name ") catch @panic("oom");
    buf.appendSlice(alloc, manifest.name) catch @panic("oom");
    buf.append(alloc, '\n') catch @panic("oom");
    buf.appendSlice(alloc, "version ") catch @panic("oom");
    buf.appendSlice(alloc, manifest.version) catch @panic("oom");
    buf.append(alloc, '\n') catch @panic("oom");
    if (manifest.deps.len > 0) {
        buf.append(alloc, '\n') catch @panic("oom");
        buf.appendSlice(alloc, "require (\n") catch @panic("oom");
        for (manifest.deps) |dep| {
            buf.appendSlice(alloc, "  ") catch @panic("oom");
            buf.appendSlice(alloc, dep.url) catch @panic("oom");
            buf.append(alloc, ' ') catch @panic("oom");
            buf.appendSlice(alloc, dep.version) catch @panic("oom");
            buf.append(alloc, '\n') catch @panic("oom");
        }
        buf.appendSlice(alloc, ")\n") catch @panic("oom");
    }
    return buf.toOwnedSlice(alloc) catch @panic("oom");
}

pub fn cacheDir(alloc: std.mem.Allocator) ?[]const u8 {
    const home = std.process.getEnvVarOwned(alloc, "HOME") catch return null;
    defer alloc.free(home);
    var buf = std.ArrayListUnmanaged(u8){};
    buf.appendSlice(alloc, home) catch @panic("oom");
    buf.appendSlice(alloc, "/.pyr/cache") catch @panic("oom");
    return buf.toOwnedSlice(alloc) catch @panic("oom");
}

pub fn packageCachePath(alloc: std.mem.Allocator, cache_root: []const u8, url: []const u8, version: []const u8) []const u8 {
    var buf = std.ArrayListUnmanaged(u8){};
    buf.appendSlice(alloc, cache_root) catch @panic("oom");
    buf.append(alloc, '/') catch @panic("oom");
    buf.appendSlice(alloc, url) catch @panic("oom");
    buf.append(alloc, '/') catch @panic("oom");
    buf.appendSlice(alloc, version) catch @panic("oom");
    return buf.toOwnedSlice(alloc) catch @panic("oom");
}

fn gitExec(alloc: std.mem.Allocator, argv: []const []const u8) !struct { code: u8, stdout: []const u8 } {
    const result = std.process.Child.run(.{
        .allocator = alloc,
        .argv = argv,
        .max_output_bytes = 1024 * 1024,
    }) catch return .{ .code = 1, .stdout = "" };

    const code: u8 = switch (result.term) {
        .Exited => |c| c,
        else => 1,
    };
    return .{ .code = code, .stdout = result.stdout };
}

pub fn fetchPackage(alloc: std.mem.Allocator, cache_root: []const u8, dep: Dependency) !LockEntry {
    const pkg_dir = packageCachePath(alloc, cache_root, dep.url, dep.version);

    if (std.fs.cwd().access(pkg_dir, .{})) |_| {
        const hash = resolveHash(alloc, pkg_dir) catch "unknown";
        return .{ .url = dep.url, .version = dep.version, .hash = hash };
    } else |_| {}

    const git_url = gitUrl(alloc, dep.url);
    const bare_dir = bareCachePath(alloc, cache_root, dep.url);

    if (std.fs.cwd().access(bare_dir, .{})) |_| {
        _ = try gitExec(alloc, &.{ "git", "-C", bare_dir, "fetch", "--tags" });
    } else |_| {
        makeDirRecursive(bare_dir);
        _ = try gitExec(alloc, &.{ "git", "clone", "--bare", git_url, bare_dir });
    }

    const ref = resolveRef(alloc, bare_dir, dep.version) catch return error.VersionNotFound;

    makeDirRecursive(pkg_dir);
    _ = try gitExec(alloc, &.{ "git", "clone", bare_dir, pkg_dir });
    _ = try gitExec(alloc, &.{ "git", "-C", pkg_dir, "checkout", ref });

    const hash = resolveHash(alloc, pkg_dir) catch "unknown";
    return .{ .url = dep.url, .version = dep.version, .hash = hash };
}

fn gitUrl(alloc: std.mem.Allocator, url: []const u8) []const u8 {
    var buf = std.ArrayListUnmanaged(u8){};
    buf.appendSlice(alloc, "https://") catch @panic("oom");
    buf.appendSlice(alloc, url) catch @panic("oom");
    buf.appendSlice(alloc, ".git") catch @panic("oom");
    return buf.toOwnedSlice(alloc) catch @panic("oom");
}

fn bareCachePath(alloc: std.mem.Allocator, cache_root: []const u8, url: []const u8) []const u8 {
    var buf = std.ArrayListUnmanaged(u8){};
    buf.appendSlice(alloc, cache_root) catch @panic("oom");
    buf.appendSlice(alloc, "/.bare/") catch @panic("oom");
    buf.appendSlice(alloc, url) catch @panic("oom");
    return buf.toOwnedSlice(alloc) catch @panic("oom");
}

fn resolveRef(alloc: std.mem.Allocator, bare_dir: []const u8, version: []const u8) ![]const u8 {
    if (version.len >= 7 and isHex(version)) return version;

    const tag = if (version[0] == 'v') version else blk: {
        var buf = std.ArrayListUnmanaged(u8){};
        buf.append(alloc, 'v') catch @panic("oom");
        buf.appendSlice(alloc, version) catch @panic("oom");
        break :blk buf.toOwnedSlice(alloc) catch @panic("oom");
    };

    const result = try gitExec(alloc, &.{ "git", "-C", bare_dir, "rev-parse", tag });
    if (result.code == 0) {
        return std.mem.trim(u8, result.stdout, " \t\n\r");
    }

    const result2 = try gitExec(alloc, &.{ "git", "-C", bare_dir, "rev-parse", version });
    if (result2.code == 0) {
        return std.mem.trim(u8, result2.stdout, " \t\n\r");
    }

    return error.VersionNotFound;
}

fn resolveHash(alloc: std.mem.Allocator, dir: []const u8) ![]const u8 {
    const result = try gitExec(alloc, &.{ "git", "-C", dir, "rev-parse", "HEAD" });
    if (result.code == 0) {
        return std.mem.trim(u8, result.stdout, " \t\n\r");
    }
    return error.NoHash;
}

fn isHex(s: []const u8) bool {
    for (s) |c| {
        if (!std.ascii.isHex(c)) return false;
    }
    return true;
}

fn makeDirRecursive(path: []const u8) void {
    std.fs.cwd().makePath(path) catch {};
}

pub fn findManifest(alloc: std.mem.Allocator, start_dir: []const u8) ?struct { manifest: Manifest, dir: []const u8 } {
    var dir = start_dir;
    while (true) {
        var pkg_path = std.ArrayListUnmanaged(u8){};
        pkg_path.appendSlice(alloc, dir) catch @panic("oom");
        pkg_path.appendSlice(alloc, "/pyr.pkg") catch @panic("oom");
        const path = pkg_path.toOwnedSlice(alloc) catch @panic("oom");

        if (std.fs.cwd().readFileAlloc(alloc, path, 1024 * 1024)) |source| {
            if (parseManifest(alloc, source)) |m| {
                return .{ .manifest = m, .dir = dir };
            }
        } else |_| {}

        if (std.mem.lastIndexOfScalar(u8, dir, '/')) |idx| {
            if (idx == 0) break;
            const parent = alloc.alloc(u8, idx) catch @panic("oom");
            @memcpy(parent, dir[0..idx]);
            dir = parent;
        } else break;
    }
    return null;
}

pub fn buildPackageMap(alloc: std.mem.Allocator, manifest: Manifest, cache_root: []const u8) std.StringHashMapUnmanaged([]const u8) {
    var map = std.StringHashMapUnmanaged([]const u8){};
    for (manifest.deps) |dep| {
        const pkg_dir = packageCachePath(alloc, cache_root, dep.url, dep.version);
        const pkg_source = readPkgFile(alloc, pkg_dir);
        if (pkg_source) |source| {
            if (parseManifest(alloc, source)) |dep_manifest| {
                map.put(alloc, dep_manifest.name, pkg_dir) catch @panic("oom");
            }
        }

        const last_seg = lastPathSegment(dep.url);
        map.put(alloc, last_seg, pkg_dir) catch @panic("oom");
    }
    return map;
}

fn readPkgFile(alloc: std.mem.Allocator, dir: []const u8) ?[]const u8 {
    var path_buf = std.ArrayListUnmanaged(u8){};
    path_buf.appendSlice(alloc, dir) catch @panic("oom");
    path_buf.appendSlice(alloc, "/pyr.pkg") catch @panic("oom");
    const path = path_buf.toOwnedSlice(alloc) catch @panic("oom");
    return std.fs.cwd().readFileAlloc(alloc, path, 1024 * 1024) catch null;
}

fn lastPathSegment(url: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, url, '/')) |idx| {
        return url[idx + 1 ..];
    }
    return url;
}

pub fn install(alloc: std.mem.Allocator, manifest: Manifest) !void {
    const cache_root = cacheDir(alloc) orelse {
        std.debug.print("error: could not determine cache directory\n", .{});
        return error.NoCacheDir;
    };
    defer alloc.free(cache_root);

    var lock_entries = std.ArrayListUnmanaged(LockEntry){};

    for (manifest.deps) |dep| {
        std.debug.print("fetching {s} {s}...\n", .{ dep.url, dep.version });
        const entry = fetchPackage(alloc, cache_root, dep) catch |err| {
            std.debug.print("error: failed to fetch {s}: {}\n", .{ dep.url, err });
            continue;
        };
        lock_entries.append(alloc, entry) catch @panic("oom");
        const cached_path = packageCachePath(alloc, cache_root, dep.url, dep.version);
        defer alloc.free(cached_path);
        std.debug.print("  cached at {s}\n", .{cached_path});
    }

    const entries = lock_entries.toOwnedSlice(alloc) catch @panic("oom");
    defer alloc.free(entries);
    const lock_content = writeLockFile(alloc, entries);
    defer alloc.free(lock_content);
    std.fs.cwd().writeFile(.{ .sub_path = "pyr.lock", .data = lock_content }) catch |err| {
        std.debug.print("error: could not write pyr.lock: {}\n", .{err});
    };
}

pub fn addDependency(alloc: std.mem.Allocator, url: []const u8, version: []const u8) !void {
    const source = std.fs.cwd().readFileAlloc(alloc, "pyr.pkg", 1024 * 1024) catch {
        std.debug.print("error: no pyr.pkg found in current directory\n", .{});
        return error.NoManifest;
    };
    defer alloc.free(source);
    var manifest = parseManifest(alloc, source) orelse {
        std.debug.print("error: could not parse pyr.pkg\n", .{});
        return error.BadManifest;
    };

    for (manifest.deps) |dep| {
        if (std.mem.eql(u8, dep.url, url)) {
            std.debug.print("{s} already in dependencies\n", .{url});
            alloc.free(manifest.deps);
            return;
        }
    }

    var deps = std.ArrayListUnmanaged(Dependency){};
    deps.appendSlice(alloc, manifest.deps) catch @panic("oom");
    alloc.free(manifest.deps);
    deps.append(alloc, .{ .url = url, .version = version }) catch @panic("oom");
    manifest.deps = deps.toOwnedSlice(alloc) catch @panic("oom");
    defer alloc.free(manifest.deps);

    const content = writeManifest(alloc, manifest);
    defer alloc.free(content);
    std.fs.cwd().writeFile(.{ .sub_path = "pyr.pkg", .data = content }) catch |err| {
        std.debug.print("error: could not write pyr.pkg: {}\n", .{err});
        return error.WriteError;
    };

    std.debug.print("added {s} {s}\n", .{ url, version });
    try install(alloc, manifest);
}

pub fn initManifest(alloc: std.mem.Allocator, name: []const u8) !void {
    std.fs.cwd().access("pyr.pkg", .{}) catch {
        const manifest = Manifest{
            .name = name,
            .version = "0.1.0",
            .deps = &.{},
        };
        const content = writeManifest(alloc, manifest);
        defer alloc.free(content);
        std.fs.cwd().writeFile(.{ .sub_path = "pyr.pkg", .data = content }) catch |err| {
            std.debug.print("error: could not write pyr.pkg: {}\n", .{err});
            return error.WriteError;
        };
        std.debug.print("created pyr.pkg\n", .{});
        return;
    };
    std.debug.print("pyr.pkg already exists\n", .{});
}

test "parse manifest" {
    const alloc = std.testing.allocator;
    const source =
        \\name myapp
        \\version 0.1.0
        \\
        \\require (
        \\  github.com/nvms/pyr-router v0.3.1
        \\  github.com/nvms/pyr-json v1.0.0
        \\)
    ;
    const m = parseManifest(alloc, source) orelse return error.ParseFailed;
    defer alloc.free(m.deps);
    try std.testing.expectEqualStrings("myapp", m.name);
    try std.testing.expectEqualStrings("0.1.0", m.version);
    try std.testing.expectEqual(@as(usize, 2), m.deps.len);
    try std.testing.expectEqualStrings("github.com/nvms/pyr-router", m.deps[0].url);
    try std.testing.expectEqualStrings("v0.3.1", m.deps[0].version);
    try std.testing.expectEqualStrings("github.com/nvms/pyr-json", m.deps[1].url);
    try std.testing.expectEqualStrings("v1.0.0", m.deps[1].version);
}

test "parse manifest with comments" {
    const alloc = std.testing.allocator;
    const source =
        \\# my project
        \\name example
        \\version 1.0.0
    ;
    const m = parseManifest(alloc, source) orelse return error.ParseFailed;
    defer alloc.free(m.deps);
    try std.testing.expectEqualStrings("example", m.name);
    try std.testing.expectEqualStrings("1.0.0", m.version);
    try std.testing.expectEqual(@as(usize, 0), m.deps.len);
}

test "parse manifest with commit hash" {
    const alloc = std.testing.allocator;
    const source =
        \\name pinned
        \\version 0.1.0
        \\
        \\require (
        \\  github.com/user/lib abc1234
        \\)
    ;
    const m = parseManifest(alloc, source) orelse return error.ParseFailed;
    defer alloc.free(m.deps);
    try std.testing.expectEqualStrings("abc1234", m.deps[0].version);
}

test "parse lock file" {
    const alloc = std.testing.allocator;
    const source =
        \\# pyr.lock - auto-generated, do not edit
        \\github.com/nvms/pyr-router v0.3.1 abc123def456
        \\github.com/nvms/pyr-json v1.0.0 789abc012def
    ;
    const lock = parseLockFile(alloc, source);
    defer alloc.free(lock.entries);
    try std.testing.expectEqual(@as(usize, 2), lock.entries.len);
    try std.testing.expectEqualStrings("github.com/nvms/pyr-router", lock.entries[0].url);
    try std.testing.expectEqualStrings("abc123def456", lock.entries[0].hash);
}

test "write and re-parse manifest" {
    const alloc = std.testing.allocator;
    const deps = try alloc.alloc(Dependency, 1);
    defer alloc.free(deps);
    deps[0] = .{ .url = "github.com/user/lib", .version = "v1.0.0" };
    const manifest = Manifest{ .name = "roundtrip", .version = "0.2.0", .deps = deps };
    const content = writeManifest(alloc, manifest);
    defer alloc.free(content);
    const parsed = parseManifest(alloc, content) orelse return error.ParseFailed;
    defer alloc.free(parsed.deps);
    try std.testing.expectEqualStrings("roundtrip", parsed.name);
    try std.testing.expectEqualStrings("0.2.0", parsed.version);
    try std.testing.expectEqual(@as(usize, 1), parsed.deps.len);
    try std.testing.expectEqualStrings("github.com/user/lib", parsed.deps[0].url);
}

test "write and re-parse lock file" {
    const alloc = std.testing.allocator;
    const entries = try alloc.alloc(LockEntry, 1);
    defer alloc.free(entries);
    entries[0] = .{ .url = "github.com/a/b", .version = "v1.0.0", .hash = "deadbeef" };
    const content = writeLockFile(alloc, entries);
    defer alloc.free(content);
    const parsed = parseLockFile(alloc, content);
    defer alloc.free(parsed.entries);
    try std.testing.expectEqual(@as(usize, 1), parsed.entries.len);
    try std.testing.expectEqualStrings("deadbeef", parsed.entries[0].hash);
}
