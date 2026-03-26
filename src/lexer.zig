const std = @import("std");
const Token = @import("token.zig").Token;
const keywords = @import("token.zig").keywords;

pub const Lexer = struct {
    source: []const u8,
    pos: usize,
    interp_depth: u8,

    pub fn init(source: []const u8) Lexer {
        return .{ .source = source, .pos = 0, .interp_depth = 0 };
    }

    pub fn next(self: *Lexer) Token {
        self.skipWhitespace();

        if (self.interp_depth > 0 and self.pos < self.source.len and self.source[self.pos] == '}') {
            self.pos += 1;
            self.interp_depth -= 1;
            return self.lexStringContinuation(self.pos);
        }

        if (self.pos >= self.source.len) {
            return self.makeToken(.eof, self.pos, self.pos);
        }

        const start = self.pos;
        const c = self.advance();

        return switch (c) {
            '\n' => self.makeToken(.newline, start, self.pos),
            '(' => self.makeToken(.lparen, start, self.pos),
            ')' => self.makeToken(.rparen, start, self.pos),
            '{' => self.makeToken(.lbrace, start, self.pos),
            '}' => self.makeToken(.rbrace, start, self.pos),
            '[' => self.makeToken(.lbracket, start, self.pos),
            ']' => self.makeToken(.rbracket, start, self.pos),
            ',' => self.makeToken(.comma, start, self.pos),
            ':' => self.makeToken(.colon, start, self.pos),
            '?' => if (self.match('?')) self.makeToken(.double_question, start, self.pos) else self.makeToken(.question, start, self.pos),
            '@' => self.makeToken(.at, start, self.pos),
            '&' => if (self.match('&')) self.makeToken(.and_and, start, self.pos) else self.makeToken(.ampersand, start, self.pos),
            '+' => if (self.match('=')) self.makeToken(.plus_eq, start, self.pos) else self.makeToken(.plus, start, self.pos),
            '*' => if (self.match('=')) self.makeToken(.star_eq, start, self.pos) else self.makeToken(.star, start, self.pos),
            '%' => self.makeToken(.percent, start, self.pos),
            '/' => blk: {
                if (self.match('/')) {
                    while (self.pos < self.source.len and self.source[self.pos] != '\n') {
                        self.pos += 1;
                    }
                    break :blk self.next();
                }
                if (self.match('=')) break :blk self.makeToken(.slash_eq, start, self.pos);
                break :blk self.makeToken(.slash, start, self.pos);
            },
            '-' => blk: {
                if (self.match('>')) break :blk self.makeToken(.arrow, start, self.pos);
                if (self.match('=')) break :blk self.makeToken(.minus_eq, start, self.pos);
                break :blk self.makeToken(.minus, start, self.pos);
            },
            '.' => if (self.match('.')) self.makeToken(.dotdot, start, self.pos) else self.makeToken(.dot, start, self.pos),
            '|' => blk: {
                if (self.match('>')) break :blk self.makeToken(.pipe_right, start, self.pos);
                if (self.match('|')) break :blk self.makeToken(.or_or, start, self.pos);
                break :blk self.makeToken(.pipe, start, self.pos);
            },
            '=' => blk: {
                if (self.match('=')) break :blk self.makeToken(.eq_eq, start, self.pos);
                if (self.match('>')) break :blk self.makeToken(.fat_arrow, start, self.pos);
                break :blk self.makeToken(.eq, start, self.pos);
            },
            '!' => if (self.match('=')) self.makeToken(.bang_eq, start, self.pos) else self.makeToken(.bang, start, self.pos),
            '<' => if (self.match('=')) self.makeToken(.lt_eq, start, self.pos) else self.makeToken(.lt, start, self.pos),
            '>' => if (self.match('=')) self.makeToken(.gt_eq, start, self.pos) else self.makeToken(.gt, start, self.pos),
            '"' => self.lexString(start),
            else => {
                if (isDigit(c)) return self.lexNumber(start);
                if (isIdentStart(c)) return self.lexIdentifier(start);
                return self.makeToken(.invalid, start, self.pos);
            },
        };
    }

    fn lexString(self: *Lexer, start: usize) Token {
        while (self.pos < self.source.len and self.source[self.pos] != '"') {
            if (self.source[self.pos] == '\\') {
                self.pos += 1;
                if (self.pos < self.source.len) self.pos += 1;
                continue;
            }
            if (self.source[self.pos] == '{') {
                const end = self.pos;
                self.pos += 1;
                self.interp_depth += 1;
                return self.makeToken(.string_begin, start, end);
            }
            self.pos += 1;
        }
        if (self.pos < self.source.len) self.pos += 1;
        return self.makeToken(.string, start, self.pos);
    }

    fn lexStringContinuation(self: *Lexer, start: usize) Token {
        while (self.pos < self.source.len and self.source[self.pos] != '"') {
            if (self.source[self.pos] == '\\') {
                self.pos += 1;
                if (self.pos < self.source.len) self.pos += 1;
                continue;
            }
            if (self.source[self.pos] == '{') {
                const end = self.pos;
                self.pos += 1;
                self.interp_depth += 1;
                return self.makeToken(.string_part, start, end);
            }
            self.pos += 1;
        }
        if (self.pos < self.source.len) self.pos += 1;
        return self.makeToken(.string_end, start, self.pos);
    }

    fn lexNumber(self: *Lexer, start: usize) Token {
        var is_float = false;

        if (self.pos < self.source.len and start < self.source.len) {
            const prev = self.source[start];
            if (prev == '0' and self.pos < self.source.len) {
                const next_ch = self.peek();
                if (next_ch == 'x' or next_ch == 'X' or next_ch == 'b' or next_ch == 'B' or next_ch == 'o' or next_ch == 'O') {
                    self.pos += 1;
                    while (self.pos < self.source.len and (isHexDigit(self.source[self.pos]) or self.source[self.pos] == '_')) {
                        self.pos += 1;
                    }
                    return self.makeToken(.integer, start, self.pos);
                }
            }
        }

        while (self.pos < self.source.len and (isDigit(self.source[self.pos]) or self.source[self.pos] == '_')) {
            self.pos += 1;
        }

        if (self.pos < self.source.len and self.source[self.pos] == '.' and self.pos + 1 < self.source.len and isDigit(self.source[self.pos + 1])) {
            is_float = true;
            self.pos += 1;
            while (self.pos < self.source.len and (isDigit(self.source[self.pos]) or self.source[self.pos] == '_')) {
                self.pos += 1;
            }
        }

        return self.makeToken(if (is_float) .float else .integer, start, self.pos);
    }

    fn lexIdentifier(self: *Lexer, start: usize) Token {
        while (self.pos < self.source.len and isIdentContinue(self.source[self.pos])) {
            self.pos += 1;
        }
        const text = self.source[start..self.pos];
        const tag = keywords.get(text) orelse .identifier;
        return self.makeToken(tag, start, self.pos);
    }

    fn skipWhitespace(self: *Lexer) void {
        while (self.pos < self.source.len) {
            switch (self.source[self.pos]) {
                ' ', '\t', '\r' => self.pos += 1,
                else => break,
            }
        }
    }

    fn advance(self: *Lexer) u8 {
        const c = self.source[self.pos];
        self.pos += 1;
        return c;
    }

    fn peek(self: *Lexer) u8 {
        if (self.pos >= self.source.len) return 0;
        return self.source[self.pos];
    }

    fn match(self: *Lexer, expected: u8) bool {
        if (self.pos >= self.source.len or self.source[self.pos] != expected) return false;
        self.pos += 1;
        return true;
    }

    fn makeToken(_: *Lexer, tag: Token.Tag, start: usize, end: usize) Token {
        return .{ .tag = tag, .loc = .{ .start = start, .end = end } };
    }

    fn isDigit(c: u8) bool {
        return c >= '0' and c <= '9';
    }

    fn isHexDigit(c: u8) bool {
        return (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
    }

    fn isIdentStart(c: u8) bool {
        return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_';
    }

    fn isIdentContinue(c: u8) bool {
        return isIdentStart(c) or isDigit(c);
    }
};

test "lex simple tokens" {
    var lex = Lexer.init("fn main() { }");
    try std.testing.expectEqual(Token.Tag.kw_fn, lex.next().tag);
    try std.testing.expectEqual(Token.Tag.identifier, lex.next().tag);
    try std.testing.expectEqual(Token.Tag.lparen, lex.next().tag);
    try std.testing.expectEqual(Token.Tag.rparen, lex.next().tag);
    try std.testing.expectEqual(Token.Tag.lbrace, lex.next().tag);
    try std.testing.expectEqual(Token.Tag.rbrace, lex.next().tag);
    try std.testing.expectEqual(Token.Tag.eof, lex.next().tag);
}

test "lex keywords" {
    var lex = Lexer.init("struct enum trait pub mut imp");
    try std.testing.expectEqual(Token.Tag.kw_struct, lex.next().tag);
    try std.testing.expectEqual(Token.Tag.kw_enum, lex.next().tag);
    try std.testing.expectEqual(Token.Tag.kw_trait, lex.next().tag);
    try std.testing.expectEqual(Token.Tag.kw_pub, lex.next().tag);
    try std.testing.expectEqual(Token.Tag.kw_mut, lex.next().tag);
    try std.testing.expectEqual(Token.Tag.kw_imp, lex.next().tag);
    try std.testing.expectEqual(Token.Tag.eof, lex.next().tag);
}

test "lex operators" {
    var lex = Lexer.init("|> ?? -> == != <= >=");
    try std.testing.expectEqual(Token.Tag.pipe_right, lex.next().tag);
    try std.testing.expectEqual(Token.Tag.double_question, lex.next().tag);
    try std.testing.expectEqual(Token.Tag.arrow, lex.next().tag);
    try std.testing.expectEqual(Token.Tag.eq_eq, lex.next().tag);
    try std.testing.expectEqual(Token.Tag.bang_eq, lex.next().tag);
    try std.testing.expectEqual(Token.Tag.lt_eq, lex.next().tag);
    try std.testing.expectEqual(Token.Tag.gt_eq, lex.next().tag);
    try std.testing.expectEqual(Token.Tag.eof, lex.next().tag);
}

test "lex numbers" {
    var lex = Lexer.init("42 3.14 0xFF 0b1010 1_000_000");
    const int1 = lex.next();
    try std.testing.expectEqual(Token.Tag.integer, int1.tag);
    try std.testing.expectEqualStrings("42", int1.slice("42 3.14 0xFF 0b1010 1_000_000"));

    try std.testing.expectEqual(Token.Tag.float, lex.next().tag);
    try std.testing.expectEqual(Token.Tag.integer, lex.next().tag);
    try std.testing.expectEqual(Token.Tag.integer, lex.next().tag);
    try std.testing.expectEqual(Token.Tag.integer, lex.next().tag);
    try std.testing.expectEqual(Token.Tag.eof, lex.next().tag);
}

test "lex string" {
    var lex = Lexer.init("\"hello world\"");
    const tok = lex.next();
    try std.testing.expectEqual(Token.Tag.string, tok.tag);
    try std.testing.expectEqual(Token.Tag.eof, lex.next().tag);
}

test "lex string interpolation" {
    var lex = Lexer.init("\"hello {name}!\"");
    try std.testing.expectEqual(Token.Tag.string_begin, lex.next().tag);
    try std.testing.expectEqual(Token.Tag.identifier, lex.next().tag);
    const end = lex.next();
    try std.testing.expectEqual(Token.Tag.string_end, end.tag);
    try std.testing.expectEqual(Token.Tag.eof, lex.next().tag);
}

test "lex string multiple interpolations" {
    var lex = Lexer.init("\"a {x} b {y} c\"");
    try std.testing.expectEqual(Token.Tag.string_begin, lex.next().tag);
    try std.testing.expectEqual(Token.Tag.identifier, lex.next().tag);
    try std.testing.expectEqual(Token.Tag.string_part, lex.next().tag);
    try std.testing.expectEqual(Token.Tag.identifier, lex.next().tag);
    try std.testing.expectEqual(Token.Tag.string_end, lex.next().tag);
    try std.testing.expectEqual(Token.Tag.eof, lex.next().tag);
}

test "lex comments are skipped" {
    var lex = Lexer.init("foo // this is a comment\nbar");
    try std.testing.expectEqual(Token.Tag.identifier, lex.next().tag);
    try std.testing.expectEqual(Token.Tag.newline, lex.next().tag);
    try std.testing.expectEqual(Token.Tag.identifier, lex.next().tag);
    try std.testing.expectEqual(Token.Tag.eof, lex.next().tag);
}

test "lex pyr snippet" {
    var lex = Lexer.init("pub fn add(a: int, b: int) -> int {\n  a + b\n}");
    try std.testing.expectEqual(Token.Tag.kw_pub, lex.next().tag);
    try std.testing.expectEqual(Token.Tag.kw_fn, lex.next().tag);
    try std.testing.expectEqual(Token.Tag.identifier, lex.next().tag);
    try std.testing.expectEqual(Token.Tag.lparen, lex.next().tag);
    try std.testing.expectEqual(Token.Tag.identifier, lex.next().tag);
    try std.testing.expectEqual(Token.Tag.colon, lex.next().tag);
    try std.testing.expectEqual(Token.Tag.kw_int, lex.next().tag);
    try std.testing.expectEqual(Token.Tag.comma, lex.next().tag);
    try std.testing.expectEqual(Token.Tag.identifier, lex.next().tag);
    try std.testing.expectEqual(Token.Tag.colon, lex.next().tag);
    try std.testing.expectEqual(Token.Tag.kw_int, lex.next().tag);
    try std.testing.expectEqual(Token.Tag.rparen, lex.next().tag);
    try std.testing.expectEqual(Token.Tag.arrow, lex.next().tag);
    try std.testing.expectEqual(Token.Tag.kw_int, lex.next().tag);
    try std.testing.expectEqual(Token.Tag.lbrace, lex.next().tag);
    try std.testing.expectEqual(Token.Tag.newline, lex.next().tag);
    try std.testing.expectEqual(Token.Tag.identifier, lex.next().tag);
    try std.testing.expectEqual(Token.Tag.plus, lex.next().tag);
    try std.testing.expectEqual(Token.Tag.identifier, lex.next().tag);
    try std.testing.expectEqual(Token.Tag.newline, lex.next().tag);
    try std.testing.expectEqual(Token.Tag.rbrace, lex.next().tag);
    try std.testing.expectEqual(Token.Tag.eof, lex.next().tag);
}
