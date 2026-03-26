pub const Token = struct {
    tag: Tag,
    loc: Loc,

    pub const Loc = struct {
        start: usize,
        end: usize,
    };

    pub fn slice(self: Token, source: []const u8) []const u8 {
        return source[self.loc.start..self.loc.end];
    }

    pub const Tag = enum {
        // literals
        integer,
        float,
        string,
        string_begin,
        string_part,
        string_end,
        identifier,

        // keywords
        kw_fn,
        kw_struct,
        kw_enum,
        kw_trait,
        kw_pub,
        kw_imp,
        kw_from,
        kw_as,
        kw_mut,
        kw_if,
        kw_else,
        kw_match,
        kw_for,
        kw_in,
        kw_while,
        kw_return,
        kw_arena,
        kw_spawn,
        kw_true,
        kw_false,
        kw_none,

        // types
        kw_int,
        kw_float,
        kw_str,
        kw_bool,
        kw_byte,

        // symbols
        lparen,
        rparen,
        lbrace,
        rbrace,
        lbracket,
        rbracket,
        comma,
        dot,
        colon,
        arrow,       // ->
        fat_arrow,   // =>
        pipe,        // |
        pipe_right,  // |>
        question,    // ?
        double_question, // ??
        ampersand,
        at,

        // operators
        plus,
        minus,
        star,
        slash,
        percent,
        bang,
        eq,
        eq_eq,
        bang_eq,
        lt,
        gt,
        lt_eq,
        gt_eq,
        and_and,
        or_or,
        plus_eq,
        minus_eq,
        star_eq,
        slash_eq,
        dotdot,      // ..

        // special
        newline,
        eof,
        invalid,
    };
};

pub const keywords = std.StaticStringMap(Token.Tag).initComptime(.{
    .{ "fn", .kw_fn },
    .{ "struct", .kw_struct },
    .{ "enum", .kw_enum },
    .{ "trait", .kw_trait },
    .{ "pub", .kw_pub },
    .{ "imp", .kw_imp },
    .{ "from", .kw_from },
    .{ "as", .kw_as },
    .{ "mut", .kw_mut },
    .{ "if", .kw_if },
    .{ "else", .kw_else },
    .{ "match", .kw_match },
    .{ "for", .kw_for },
    .{ "in", .kw_in },
    .{ "while", .kw_while },
    .{ "return", .kw_return },
    .{ "arena", .kw_arena },
    .{ "spawn", .kw_spawn },
    .{ "true", .kw_true },
    .{ "false", .kw_false },
    .{ "none", .kw_none },
    .{ "int", .kw_int },
    .{ "float", .kw_float },
    .{ "str", .kw_str },
    .{ "bool", .kw_bool },
    .{ "byte", .kw_byte },
});

const std = @import("std");
