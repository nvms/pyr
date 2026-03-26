const std = @import("std");
const lexer = @import("lexer.zig");
const parser = @import("parser.zig");
const sema = @import("sema.zig");
const codegen = @import("codegen.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        printUsage();
        return;
    }

    const command = args[1];

    if (std.mem.eql(u8, command, "build")) {
        if (args.len < 3) {
            std.debug.print("error: pyr build requires a file argument\n", .{});
            std.process.exit(1);
        }
        try buildFile(allocator, args[2]);
    } else if (std.mem.eql(u8, command, "run")) {
        if (args.len < 3) {
            std.debug.print("error: pyr run requires a file argument\n", .{});
            std.process.exit(1);
        }
        try runFile(allocator, args[2]);
    } else if (std.mem.eql(u8, command, "version")) {
        std.debug.print("pyr 0.1.0\n", .{});
    } else {
        std.debug.print("error: unknown command '{s}'\n", .{command});
        printUsage();
        std.process.exit(1);
    }
}

fn buildFile(allocator: std.mem.Allocator, path: []const u8) !void {
    const source = std.fs.cwd().readFileAlloc(allocator, path, 10 * 1024 * 1024) catch |err| {
        std.debug.print("error: could not read '{s}': {}\n", .{ path, err });
        std.process.exit(1);
    };
    defer allocator.free(source);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const tokens = parser.tokenize(arena.allocator(), source);
    var p = parser.Parser.init(tokens, source, arena.allocator());
    const result = p.parse();

    if (result.errors.len > 0) {
        for (result.errors) |err| {
            const loc = lineCol(source, err.span.start);
            std.debug.print("{s}:{d}:{d}: error: {s}\n", .{ path, loc.line, loc.col, err.message });
        }
        std.process.exit(1);
    }

    const analysis = sema.Sema.analyze(arena.allocator(), result);

    if (analysis.errors.len > 0) {
        for (analysis.errors) |err| {
            const loc = lineCol(source, err.span.start);
            std.debug.print("{s}:{d}:{d}: error: {s}\n", .{ path, loc.line, loc.col, err.message });
        }
        std.process.exit(1);
    }

    const zig_source = codegen.Codegen.generate(arena.allocator(), result);

    const out_path = blk: {
        if (std.mem.endsWith(u8, path, ".pyr")) {
            break :blk std.fmt.allocPrint(arena.allocator(), "{s}.zig", .{path[0 .. path.len - 4]}) catch @panic("oom");
        }
        break :blk std.fmt.allocPrint(arena.allocator(), "{s}.zig", .{path}) catch @panic("oom");
    };

    std.fs.cwd().writeFile(.{ .sub_path = out_path, .data = zig_source }) catch |write_err| {
        std.debug.print("error: could not write '{s}': {}\n", .{ out_path, write_err });
        std.process.exit(1);
    };

    std.debug.print("compiled {s} -> {s}\n", .{ path, out_path });
}

fn runFile(allocator: std.mem.Allocator, path: []const u8) !void {
    try buildFile(allocator, path);
}

const LineLoc = struct { line: usize, col: usize };

fn lineCol(source: []const u8, offset: usize) LineLoc {
    var line: usize = 1;
    var col: usize = 1;
    for (source[0..@min(offset, source.len)]) |c| {
        if (c == '\n') {
            line += 1;
            col = 1;
        } else {
            col += 1;
        }
    }
    return .{ .line = line, .col = col };
}

fn printUsage() void {
    std.debug.print(
        \\usage: pyr <command> [args]
        \\
        \\commands:
        \\  build <file>    compile a .pyr file
        \\  run <file>      compile and run a .pyr file
        \\  version         print version
        \\
    , .{});
}

test {
    _ = lexer;
    _ = @import("parser.zig");
    _ = @import("sema.zig");
    _ = @import("codegen.zig");
}
