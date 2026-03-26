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

fn compile(allocator: std.mem.Allocator, path: []const u8) !struct { func: *@import("value.zig").ObjFunction, ffi_descs: []@import("ffi.zig").FfiDesc, arena: std.heap.ArenaAllocator } {
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
            printDiagnostic(path, source, err.span, err.message);
        }
        std.process.exit(1);
    }

    const dir = module.dirOf(path, arena.allocator());
    var loader = module.ModuleLoader.init(arena.allocator(), dir);

    const analysis = sema.Sema.analyzeModule(arena.allocator(), result, &loader, dir);
    if (analysis.errors.len > 0) {
        for (analysis.errors) |err| {
            printDiagnostic(path, source, err.span, err.message);
        }
        std.process.exit(1);
    }
    const cr = compiler.Compiler.compileModule(arena.allocator(), result, &loader, dir) orelse {
        std.debug.print("error: compilation failed\n", .{});
        std.process.exit(1);
    };

    return .{ .func = cr.func, .ffi_descs = cr.ffi_descs, .arena = arena };
}

fn runFile(allocator: std.mem.Allocator, path: []const u8) !void {
    var result = try compile(allocator, path);
    defer result.arena.deinit();

    var vm = vm_mod.VM.init(result.arena.allocator());
    vm.setFfiDescs(result.ffi_descs);
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

fn getSourceLine(source: []const u8, offset: usize) struct { text: []const u8, line_start: usize } {
    const clamped = @min(offset, source.len);
    var start: usize = clamped;
    while (start > 0 and source[start - 1] != '\n') start -= 1;
    var end: usize = clamped;
    while (end < source.len and source[end] != '\n') end += 1;
    return .{ .text = source[start..end], .line_start = start };
}

fn printDiagnostic(path: []const u8, source: []const u8, span: @import("ast.zig").Span, message: []const u8) void {
    const loc = lineCol(source, span.start);
    const line_info = getSourceLine(source, span.start);
    const line_text = line_info.text;
    const col = loc.col;

    const span_len = if (span.end > span.start) @min(span.end - span.start, line_text.len - @min(col - 1, line_text.len)) else 1;

    var line_buf: [8]u8 = undefined;
    const line_str = std.fmt.bufPrint(&line_buf, "{d}", .{loc.line}) catch "?";
    const gutter = line_str.len + 1;

    var buf: [4096]u8 = undefined;
    var pos: usize = 0;

    pos += (std.fmt.bufPrint(buf[pos..], "\nerror: {s}\n", .{message}) catch return).len;
    pos += (std.fmt.bufPrint(buf[pos..], "{s}--> {s}:{d}:{d}\n", .{ pad(gutter), path, loc.line, col }) catch return).len;
    pos += (std.fmt.bufPrint(buf[pos..], "{s} |\n", .{pad(gutter)}) catch return).len;
    pos += (std.fmt.bufPrint(buf[pos..], " {s} | {s}\n", .{ line_str, line_text }) catch return).len;
    pos += (std.fmt.bufPrint(buf[pos..], "{s} | ", .{pad(gutter)}) catch return).len;

    var i: usize = 0;
    while (i < col - 1) : (i += 1) {
        if (pos < buf.len) {
            buf[pos] = ' ';
            pos += 1;
        }
    }
    var j: usize = 0;
    while (j < span_len) : (j += 1) {
        if (pos < buf.len) {
            buf[pos] = '^';
            pos += 1;
        }
    }
    if (pos < buf.len) {
        buf[pos] = '\n';
        pos += 1;
    }

    _ = std.posix.write(2, buf[0..pos]) catch {};
}

fn pad(n: usize) []const u8 {
    const spaces = "                ";
    return spaces[0..@min(n, spaces.len)];
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
    _ = @import("stdlib.zig");
}
