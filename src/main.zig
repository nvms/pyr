const std = @import("std");
const lexer = @import("lexer.zig");
const parser = @import("parser.zig");
const sema = @import("sema.zig");
const compiler = @import("compiler.zig");
const vm_mod = @import("vm.zig");
const module = @import("module.zig");

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

    if (std.mem.eql(u8, command, "run")) {
        if (args.len < 3) {
            std.debug.print("error: pyr run requires a file argument\n", .{});
            std.process.exit(1);
        }
        try runFile(allocator, args[2]);
    } else if (std.mem.eql(u8, command, "build")) {
        if (args.len < 3) {
            std.debug.print("error: pyr build requires a file argument\n", .{});
            std.process.exit(1);
        }
        try buildFile(allocator, args[2]);
    } else if (std.mem.eql(u8, command, "version")) {
        std.debug.print("pyr 0.1.0\n", .{});
    } else {
        std.debug.print("error: unknown command '{s}'\n", .{command});
        printUsage();
        std.process.exit(1);
    }
}

fn compile(allocator: std.mem.Allocator, path: []const u8) !struct { func: *@import("value.zig").ObjFunction, arena: std.heap.ArenaAllocator } {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();

    const source = std.fs.cwd().readFileAlloc(arena.allocator(), path, 10 * 1024 * 1024) catch |err| {
        std.debug.print("error: could not read '{s}': {}\n", .{ path, err });
        std.process.exit(1);
    };

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

    const dir = module.dirOf(path, arena.allocator());
    var loader = module.ModuleLoader.init(arena.allocator(), dir);

    const analysis = sema.Sema.analyzeModule(arena.allocator(), result, &loader, dir);
    if (analysis.errors.len > 0) {
        for (analysis.errors) |err| {
            const loc = lineCol(source, err.span.start);
            std.debug.print("{s}:{d}:{d}: error: {s}\n", .{ path, loc.line, loc.col, err.message });
        }
        std.process.exit(1);
    }
    const func = compiler.Compiler.compileModule(arena.allocator(), result, &loader, dir) orelse {
        std.debug.print("error: compilation failed\n", .{});
        std.process.exit(1);
    };

    return .{ .func = func, .arena = arena };
}

fn runFile(allocator: std.mem.Allocator, path: []const u8) !void {
    var result = try compile(allocator, path);
    defer result.arena.deinit();

    var vm = vm_mod.VM.init(result.arena.allocator());
    vm.interpret(result.func) catch {
        std.process.exit(1);
    };
}

fn buildFile(allocator: std.mem.Allocator, path: []const u8) !void {
    var result = try compile(allocator, path);
    defer result.arena.deinit();
    std.debug.print("compiled {s}\n", .{path});
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
        \\  run <file>      run a .pyr file
        \\  build <file>    check a .pyr file
        \\  version         print version
        \\
    , .{});
}

test {
    _ = lexer;
    _ = @import("parser.zig");
    _ = @import("sema.zig");
    _ = @import("value.zig");
    _ = @import("vm.zig");
    _ = @import("module.zig");
}
