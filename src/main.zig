const std = @import("std");
const lexer = @import("lexer.zig");

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

    var lex = lexer.Lexer.init(source);
    var count: usize = 0;
    while (true) {
        const tok = lex.next();
        count += 1;
        if (tok.tag == .eof) break;
    }
    std.debug.print("lexed {s}: {} tokens\n", .{ path, count });
}

fn runFile(allocator: std.mem.Allocator, path: []const u8) !void {
    try buildFile(allocator, path);
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
}
