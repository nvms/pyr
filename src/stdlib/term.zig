const std = @import("std");
const Value = @import("../value.zig").Value;
const ObjString = @import("../value.zig").ObjString;
const ObjStruct = @import("../value.zig").ObjStruct;
const root = @import("../stdlib.zig");

pub const fns = [_]root.NativeDef{
    .{ .name = "cols", .arity = 0, .func = &termCols },
    .{ .name = "rows", .arity = 0, .func = &termRows },
    .{ .name = "size", .arity = 0, .func = &termSize },
    .{ .name = "is_tty", .arity = 0, .func = &termIsTty },
    .{ .name = "move", .arity = 2, .func = &termMove },
    .{ .name = "move_to_col", .arity = 1, .func = &termMoveToCol },
    .{ .name = "up", .arity = 1, .func = &termUp },
    .{ .name = "down", .arity = 1, .func = &termDown },
    .{ .name = "save", .arity = 0, .func = &termSave },
    .{ .name = "restore", .arity = 0, .func = &termRestore },
    .{ .name = "clear_line", .arity = 0, .func = &termClearLine },
    .{ .name = "clear_down", .arity = 0, .func = &termClearDown },
    .{ .name = "clear_screen", .arity = 0, .func = &termClearScreen },
    .{ .name = "hide_cursor", .arity = 0, .func = &termHideCursor },
    .{ .name = "show_cursor", .arity = 0, .func = &termShowCursor },
    .{ .name = "scroll_region", .arity = 2, .func = &termScrollRegion },
    .{ .name = "reset_scroll", .arity = 0, .func = &termResetScroll },
    .{ .name = "raw", .arity = 0, .func = &termRaw },
    .{ .name = "cooked", .arity = 0, .func = &termCooked },
    .{ .name = "read_key", .arity = 0, .func = &termReadKey },
    .{ .name = "cursor_row", .arity = 0, .func = &termCursorRow },
    .{ .name = "flush", .arity = 0, .func = &termFlush },
    .{ .name = "style", .arity = 2, .func = &termStyle },
};

var original_termios: ?std.posix.termios = null;

fn getWinsize() ?std.posix.winsize {
    var ws: std.posix.winsize = undefined;
    const rc = std.posix.system.ioctl(std.posix.STDOUT_FILENO, std.posix.T.IOCGWINSZ, @intFromPtr(&ws));
    if (rc == 0) return ws;
    return null;
}

fn emit(seq: []const u8) void {
    _ = std.posix.write(std.posix.STDOUT_FILENO, seq) catch {};
}

fn termCols(_: std.mem.Allocator, _: []const Value) Value {
    if (getWinsize()) |ws| return Value.initInt(@intCast(ws.col));
    return Value.initInt(80);
}

fn termRows(_: std.mem.Allocator, _: []const Value) Value {
    if (getWinsize()) |ws| return Value.initInt(@intCast(ws.row));
    return Value.initInt(24);
}

fn termSize(alloc: std.mem.Allocator, _: []const Value) Value {
    const ws = getWinsize() orelse {
        const names = alloc.alloc([]const u8, 2) catch return Value.initNil();
        names[0] = "cols";
        names[1] = "rows";
        var vals: [2]Value = .{ Value.initInt(80), Value.initInt(24) };
        return ObjStruct.create(alloc, "Size", names, &vals).toValue();
    };
    const names = alloc.alloc([]const u8, 2) catch return Value.initNil();
    names[0] = "cols";
    names[1] = "rows";
    var vals: [2]Value = .{ Value.initInt(@intCast(ws.col)), Value.initInt(@intCast(ws.row)) };
    return ObjStruct.create(alloc, "Size", names, &vals).toValue();
}

fn termIsTty(_: std.mem.Allocator, _: []const Value) Value {
    return Value.initBool(std.posix.isatty(std.posix.STDOUT_FILENO));
}

fn termMove(alloc: std.mem.Allocator, args: []const Value) Value {
    if (args[0].tag() != .int or args[1].tag() != .int) return Value.initNil();
    const row: u32 = @intCast(@max(0, args[0].asInt()));
    const col: u32 = @intCast(@max(0, args[1].asInt()));
    var buf: [20]u8 = undefined;
    const seq = std.fmt.bufPrint(&buf, "\x1b[{d};{d}H", .{ row + 1, col + 1 }) catch return Value.initNil();
    _ = alloc;
    emit(seq);
    return Value.initNil();
}

fn termMoveToCol(alloc: std.mem.Allocator, args: []const Value) Value {
    if (args[0].tag() != .int) return Value.initNil();
    const col: u32 = @intCast(@max(0, args[0].asInt()));
    var buf: [12]u8 = undefined;
    const seq = std.fmt.bufPrint(&buf, "\x1b[{d}G", .{col + 1}) catch return Value.initNil();
    _ = alloc;
    emit(seq);
    return Value.initNil();
}

fn termUp(alloc: std.mem.Allocator, args: []const Value) Value {
    if (args[0].tag() != .int) return Value.initNil();
    const n: u32 = @intCast(@max(1, args[0].asInt()));
    var buf: [12]u8 = undefined;
    const seq = std.fmt.bufPrint(&buf, "\x1b[{d}A", .{n}) catch return Value.initNil();
    _ = alloc;
    emit(seq);
    return Value.initNil();
}

fn termDown(alloc: std.mem.Allocator, args: []const Value) Value {
    if (args[0].tag() != .int) return Value.initNil();
    const n: u32 = @intCast(@max(1, args[0].asInt()));
    var buf: [12]u8 = undefined;
    const seq = std.fmt.bufPrint(&buf, "\x1b[{d}B", .{n}) catch return Value.initNil();
    _ = alloc;
    emit(seq);
    return Value.initNil();
}

fn termSave(_: std.mem.Allocator, _: []const Value) Value {
    emit("\x1b[s");
    return Value.initNil();
}

fn termRestore(_: std.mem.Allocator, _: []const Value) Value {
    emit("\x1b[u");
    return Value.initNil();
}

fn termClearLine(_: std.mem.Allocator, _: []const Value) Value {
    emit("\x1b[2K\r");
    return Value.initNil();
}

fn termClearDown(_: std.mem.Allocator, _: []const Value) Value {
    emit("\x1b[J");
    return Value.initNil();
}

fn termClearScreen(_: std.mem.Allocator, _: []const Value) Value {
    emit("\x1b[2J\x1b[H");
    return Value.initNil();
}

fn termHideCursor(_: std.mem.Allocator, _: []const Value) Value {
    emit("\x1b[?25l");
    return Value.initNil();
}

fn termShowCursor(_: std.mem.Allocator, _: []const Value) Value {
    emit("\x1b[?25h");
    return Value.initNil();
}

fn termScrollRegion(_: std.mem.Allocator, args: []const Value) Value {
    if (args[0].tag() != .int or args[1].tag() != .int) return Value.initNil();
    const top: u32 = @intCast(@max(0, args[0].asInt()));
    const bot: u32 = @intCast(@max(0, args[1].asInt()));
    var buf: [20]u8 = undefined;
    const seq = std.fmt.bufPrint(&buf, "\x1b[{d};{d}r", .{ top + 1, bot + 1 }) catch return Value.initNil();
    emit(seq);
    return Value.initNil();
}

fn termResetScroll(_: std.mem.Allocator, _: []const Value) Value {
    emit("\x1b[r");
    return Value.initNil();
}

fn termRaw(_: std.mem.Allocator, _: []const Value) Value {
    if (original_termios != null) return Value.initNil();
    original_termios = std.posix.tcgetattr(std.posix.STDIN_FILENO) catch return Value.initNil();
    var raw = original_termios.?;
    raw.lflag.ECHO = false;
    raw.lflag.ICANON = false;
    raw.lflag.ISIG = false;
    raw.lflag.IEXTEN = false;
    raw.iflag.IXON = false;
    raw.iflag.ICRNL = false;
    raw.cc[@intFromEnum(std.posix.V.MIN)] = 0;
    raw.cc[@intFromEnum(std.posix.V.TIME)] = 1;
    std.posix.tcsetattr(std.posix.STDIN_FILENO, .FLUSH, raw) catch return Value.initNil();
    return Value.initNil();
}

fn termCooked(_: std.mem.Allocator, _: []const Value) Value {
    if (original_termios) |orig| {
        std.posix.tcsetattr(std.posix.STDIN_FILENO, .FLUSH, orig) catch {};
        original_termios = null;
    }
    return Value.initNil();
}

fn termReadKey(alloc: std.mem.Allocator, _: []const Value) Value {
    var buf: [8]u8 = undefined;
    const n = std.posix.read(std.posix.STDIN_FILENO, &buf) catch return Value.initNil();
    if (n == 0) return Value.initNil();

    if (n >= 3 and buf[0] == 0x1b and buf[1] == '[') {
        const name: []const u8 = switch (buf[2]) {
            'A' => "up",
            'B' => "down",
            'C' => "right",
            'D' => "left",
            'H' => "home",
            'F' => "end",
            '3' => if (n >= 4 and buf[3] == '~') "delete" else "escape",
            '5' => if (n >= 4 and buf[3] == '~') "pageup" else "escape",
            '6' => if (n >= 4 and buf[3] == '~') "pagedown" else "escape",
            else => "escape",
        };
        return ObjString.create(alloc, alloc.dupe(u8, name) catch name).toValue();
    }

    if (n == 1) {
        const name: []const u8 = switch (buf[0]) {
            0x1b => "escape",
            '\r' => "enter",
            '\t' => "tab",
            127 => "backspace",
            else => blk: {
                const owned = alloc.alloc(u8, 1) catch return Value.initNil();
                owned[0] = buf[0];
                break :blk owned;
            },
        };
        return ObjString.create(alloc, alloc.dupe(u8, name) catch name).toValue();
    }

    return ObjString.create(alloc, alloc.dupe(u8, buf[0..n]) catch "").toValue();
}

fn termCursorRow(_: std.mem.Allocator, _: []const Value) Value {
    if (!std.posix.isatty(std.posix.STDOUT_FILENO)) return Value.initInt(0);

    const orig = std.posix.tcgetattr(std.posix.STDIN_FILENO) catch return Value.initInt(0);
    var raw_attrs = orig;
    raw_attrs.lflag.ECHO = false;
    raw_attrs.lflag.ICANON = false;
    raw_attrs.cc[@intFromEnum(std.posix.V.MIN)] = 0;
    raw_attrs.cc[@intFromEnum(std.posix.V.TIME)] = 1;
    std.posix.tcsetattr(std.posix.STDIN_FILENO, .FLUSH, raw_attrs) catch return Value.initInt(0);
    defer std.posix.tcsetattr(std.posix.STDIN_FILENO, .FLUSH, orig) catch {};

    _ = std.posix.write(std.posix.STDOUT_FILENO, "\x1b[6n") catch return Value.initInt(0);

    var buf: [32]u8 = undefined;
    var pos: usize = 0;
    while (pos < buf.len) {
        const n = std.posix.read(std.posix.STDIN_FILENO, buf[pos .. pos + 1]) catch break;
        if (n == 0) break;
        if (buf[pos] == 'R') break;
        pos += 1;
    }

    // response is \x1b[row;colR
    const resp = buf[0..pos];
    const bracket = std.mem.indexOfScalar(u8, resp, '[') orelse return Value.initInt(0);
    const semi = std.mem.indexOfScalar(u8, resp, ';') orelse return Value.initInt(0);
    const row = std.fmt.parseInt(i64, resp[bracket + 1 .. semi], 10) catch return Value.initInt(0);
    return Value.initInt(row - 1);
}

fn termFlush(_: std.mem.Allocator, _: []const Value) Value {
    return Value.initNil();
}

fn termStyle(alloc: std.mem.Allocator, args: []const Value) Value {
    if (args[0].tag() != .string) return args[0];
    const text = args[0].asString().chars;

    if (!std.posix.isatty(std.posix.STDOUT_FILENO)) {
        return args[0];
    }

    var fg_code: ?[]const u8 = null;
    var bg_code: ?[]const u8 = null;
    var bold = false;
    var dim = false;
    var italic = false;
    var underline = false;

    if (args[1].tag() == .map) {
        const m = args[1].asMap();
        if (m.get("fg")) |v| {
            if (v.tag() == .string) fg_code = colorCode(v.asString().chars, false);
        }
        if (m.get("bg")) |v| {
            if (v.tag() == .string) bg_code = colorCode(v.asString().chars, true);
        }
        if (m.get("bold")) |v| {
            if (v.tag() == .bool_) bold = v.asBool();
        }
        if (m.get("dim")) |v| {
            if (v.tag() == .bool_) dim = v.asBool();
        }
        if (m.get("italic")) |v| {
            if (v.tag() == .bool_) italic = v.asBool();
        }
        if (m.get("underline")) |v| {
            if (v.tag() == .bool_) underline = v.asBool();
        }
    } else if (args[1].tag() == .struct_) {
        const s = args[1].asStruct();
        if (s.getField("fg")) |v| {
            if (v.tag() == .string) fg_code = colorCode(v.asString().chars, false);
        }
        if (s.getField("bg")) |v| {
            if (v.tag() == .string) bg_code = colorCode(v.asString().chars, true);
        }
        if (s.getField("bold")) |v| {
            if (v.tag() == .bool_) bold = v.asBool();
        }
        if (s.getField("dim")) |v| {
            if (v.tag() == .bool_) dim = v.asBool();
        }
        if (s.getField("italic")) |v| {
            if (v.tag() == .bool_) italic = v.asBool();
        }
        if (s.getField("underline")) |v| {
            if (v.tag() == .bool_) underline = v.asBool();
        }
    }

    var result = std.ArrayListUnmanaged(u8){};
    if (bold) result.appendSlice(alloc, "\x1b[1m") catch {};
    if (dim) result.appendSlice(alloc, "\x1b[2m") catch {};
    if (italic) result.appendSlice(alloc, "\x1b[3m") catch {};
    if (underline) result.appendSlice(alloc, "\x1b[4m") catch {};
    if (fg_code) |c| result.appendSlice(alloc, c) catch {};
    if (bg_code) |c| result.appendSlice(alloc, c) catch {};
    result.appendSlice(alloc, text) catch {};
    if (bold or dim or italic or underline or fg_code != null or bg_code != null)
        result.appendSlice(alloc, "\x1b[0m") catch {};
    return ObjString.create(alloc, result.items).toValue();
}

fn colorCode(name: []const u8, bg: bool) ?[]const u8 {
    const offset: u8 = if (bg) 10 else 0;
    if (std.mem.eql(u8, name, "black")) return csi(30 + offset);
    if (std.mem.eql(u8, name, "red")) return csi(31 + offset);
    if (std.mem.eql(u8, name, "green")) return csi(32 + offset);
    if (std.mem.eql(u8, name, "yellow")) return csi(33 + offset);
    if (std.mem.eql(u8, name, "blue")) return csi(34 + offset);
    if (std.mem.eql(u8, name, "magenta")) return csi(35 + offset);
    if (std.mem.eql(u8, name, "cyan")) return csi(36 + offset);
    if (std.mem.eql(u8, name, "white")) return csi(37 + offset);
    return null;
}

fn csi(code: u8) []const u8 {
    return switch (code) {
        30 => "\x1b[30m",
        31 => "\x1b[31m",
        32 => "\x1b[32m",
        33 => "\x1b[33m",
        34 => "\x1b[34m",
        35 => "\x1b[35m",
        36 => "\x1b[36m",
        37 => "\x1b[37m",
        40 => "\x1b[40m",
        41 => "\x1b[41m",
        42 => "\x1b[42m",
        43 => "\x1b[43m",
        44 => "\x1b[44m",
        45 => "\x1b[45m",
        46 => "\x1b[46m",
        47 => "\x1b[47m",
        else => "",
    };
}
