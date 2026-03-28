const std = @import("std");
const ast = @import("ast.zig");
const Token = @import("token.zig").Token;
const Lexer = @import("lexer.zig").Lexer;

pub const Parser = struct {
    tokens: []const Token,
    source: []const u8,
    pos: usize,
    arena: std.mem.Allocator,
    errors: std.ArrayListUnmanaged(ast.Error),
    nesting: u32,

    pub fn init(tokens: []const Token, source: []const u8, arena: std.mem.Allocator) Parser {
        return .{
            .tokens = tokens,
            .source = source,
            .pos = 0,
            .arena = arena,
            .errors = .{},
            .nesting = 0,
        };
    }

    pub fn parse(self: *Parser) ast.Ast {
        var items = std.ArrayListUnmanaged(ast.Item){};
        self.skipNewlines();
        while (!self.atEnd()) {
            if (self.parseItem()) |item| {
                items.append(self.arena, item) catch @panic("oom");
            } else {
                self.synchronize();
            }
            self.skipNewlines();
        }
        return .{
            .source = self.source,
            .items = items.toOwnedSlice(self.arena) catch @panic("oom"),
            .errors = self.errors.toOwnedSlice(self.arena) catch @panic("oom"),
        };
    }

    // ---------------------------------------------------------------
    // items
    // ---------------------------------------------------------------

    fn parseItem(self: *Parser) ?ast.Item {
        const start = self.currentSpanStart();
        const is_pub = self.eat(.kw_pub) != null;

        if (is_pub) self.skipNewlines();

        return switch (self.peek()) {
            .kw_fn => self.parseFnDeclItem(is_pub, start),
            .kw_struct => self.parseStructDeclItem(is_pub, start),
            .kw_enum => self.parseEnumDeclItem(is_pub, start),
            .kw_trait => self.parseTraitDeclItem(is_pub, start),
            .kw_imp => blk: {
                if (is_pub) {
                    self.emitError("imports cannot be pub");
                    break :blk null;
                }
                break :blk self.parseImportItem(start);
            },
            .kw_type => blk: {
                if (is_pub) {
                    self.emitError("type aliases cannot be pub");
                    break :blk null;
                }
                break :blk self.parseTypeAlias(start);
            },
            .kw_extern => blk: {
                if (is_pub) {
                    self.emitError("extern blocks cannot be pub");
                    break :blk null;
                }
                break :blk self.parseExternBlock(start);
            },
            else => blk: {
                if (is_pub) {
                    // pub before a binding
                    if (self.isBindingStart()) {
                        break :blk self.parseBindingItem(start);
                    }
                    self.emitError("expected declaration after pub");
                    break :blk null;
                }
                if (self.isBindingStart()) {
                    break :blk self.parseBindingItem(start);
                }
                self.emitError("expected declaration");
                break :blk null;
            },
        };
    }

    fn parseFnDeclItem(self: *Parser, is_pub: bool, start: usize) ?ast.Item {
        const decl = self.parseFnDecl(is_pub) orelse return null;
        return .{ .span = self.spanFrom(start), .kind = .{ .fn_decl = decl } };
    }

    fn parseFnDecl(self: *Parser, is_pub: bool) ?ast.FnDecl {
        _ = self.expect(.kw_fn) orelse return null;
        self.skipNewlines();
        const name = self.expectIdent() orelse return null;
        const params = self.parseParamList() orelse return null;

        var return_type: ?*const ast.TypeExpr = null;
        if (self.eat(.arrow) != null) {
            self.skipNewlines();
            return_type = self.parseTypeExpr() orelse return null;
        }

        self.skipNewlines();

        var body: ast.FnDecl.Body = .none;
        if (self.peek() == .lbrace) {
            body = .{ .block = self.parseBlock() orelse return null };
        } else if (self.eat(.eq) != null) {
            self.skipNewlines();
            body = .{ .expr = self.parseExpr() orelse return null };
        }

        return .{
            .is_pub = is_pub,
            .name = name,
            .params = params,
            .return_type = return_type,
            .body = body,
        };
    }

    fn parseParamList(self: *Parser) ?[]const ast.Param {
        _ = self.expect(.lparen) orelse return null;
        self.nesting += 1;
        var params = std.ArrayListUnmanaged(ast.Param){};

        self.skipNewlines();
        while (self.peek() != .rparen and !self.atEnd()) {
            const is_own = self.eat(.kw_own) != null;
            const pname = self.expectIdent() orelse return null;
            var type_expr: ?*const ast.TypeExpr = null;
            if (self.eat(.colon) != null) {
                self.skipNewlines();
                type_expr = self.parseTypeExpr() orelse return null;
            }
            params.append(self.arena, .{ .name = pname, .type_expr = type_expr, .is_own = is_own }) catch @panic("oom");
            self.skipNewlines();
            if (self.peek() != .rparen) {
                _ = self.expect(.comma) orelse return null;
                self.skipNewlines();
            }
        }

        self.nesting -= 1;
        _ = self.expect(.rparen) orelse return null;
        return params.toOwnedSlice(self.arena) catch @panic("oom");
    }

    fn parseStructDeclItem(self: *Parser, is_pub: bool, start: usize) ?ast.Item {
        _ = self.expect(.kw_struct) orelse return null;
        self.skipNewlines();
        const name = self.expectIdent() orelse return null;

        var is_packed = false;
        if (self.peek() == .identifier) {
            const text = self.tokenSlice(self.current());
            if (std.mem.eql(u8, text, "packed")) {
                _ = self.advance();
                is_packed = true;
            }
        }

        self.skipNewlines();
        _ = self.expect(.lbrace) orelse return null;
        self.nesting += 1;
        var fields = std.ArrayListUnmanaged(ast.Field){};

        self.skipNewlines();
        while (self.peek() != .rbrace and !self.atEnd()) {
            const fname = self.expectIdent() orelse return null;
            _ = self.expect(.colon) orelse return null;
            self.skipNewlines();
            const ftype = self.parseTypeExpr() orelse return null;
            fields.append(self.arena, .{ .name = fname, .type_expr = ftype }) catch @panic("oom");
            self.skipNewlines();
        }

        self.nesting -= 1;
        _ = self.expect(.rbrace) orelse return null;

        return .{
            .span = self.spanFrom(start),
            .kind = .{ .struct_decl = .{
                .is_pub = is_pub,
                .name = name,
                .is_packed = is_packed,
                .fields = fields.toOwnedSlice(self.arena) catch @panic("oom"),
            } },
        };
    }

    fn parseEnumDeclItem(self: *Parser, is_pub: bool, start: usize) ?ast.Item {
        _ = self.expect(.kw_enum) orelse return null;
        self.skipNewlines();
        const name = self.expectIdent() orelse return null;

        var type_params = std.ArrayListUnmanaged([]const u8){};
        if (self.eat(.lparen) != null) {
            self.nesting += 1;
            self.skipNewlines();
            while (self.peek() != .rparen and !self.atEnd()) {
                const tp = self.expectIdent() orelse return null;
                type_params.append(self.arena, tp) catch @panic("oom");
                self.skipNewlines();
                if (self.peek() != .rparen) {
                    _ = self.expect(.comma) orelse return null;
                    self.skipNewlines();
                }
            }
            self.nesting -= 1;
            _ = self.expect(.rparen) orelse return null;
        }

        self.skipNewlines();
        _ = self.expect(.lbrace) orelse return null;
        self.nesting += 1;
        var variants = std.ArrayListUnmanaged(ast.Variant){};

        self.skipNewlines();
        while (self.peek() != .rbrace and !self.atEnd()) {
            const vname = self.expectIdent() orelse return null;
            var payloads = std.ArrayListUnmanaged(*const ast.TypeExpr){};

            if (self.eat(.lparen) != null) {
                self.nesting += 1;
                self.skipNewlines();
                while (self.peek() != .rparen and !self.atEnd()) {
                    const ptype = self.parseTypeExpr() orelse return null;
                    payloads.append(self.arena, ptype) catch @panic("oom");
                    self.skipNewlines();
                    if (self.peek() != .rparen) {
                        _ = self.expect(.comma) orelse return null;
                        self.skipNewlines();
                    }
                }
                self.nesting -= 1;
                _ = self.expect(.rparen) orelse return null;
            }

            variants.append(self.arena, .{
                .name = vname,
                .payloads = payloads.toOwnedSlice(self.arena) catch @panic("oom"),
            }) catch @panic("oom");
            _ = self.eat(.comma);
            self.skipNewlines();
        }

        self.nesting -= 1;
        _ = self.expect(.rbrace) orelse return null;

        return .{
            .span = self.spanFrom(start),
            .kind = .{ .enum_decl = .{
                .is_pub = is_pub,
                .name = name,
                .type_params = type_params.toOwnedSlice(self.arena) catch @panic("oom"),
                .variants = variants.toOwnedSlice(self.arena) catch @panic("oom"),
            } },
        };
    }

    fn parseTraitDeclItem(self: *Parser, is_pub: bool, start: usize) ?ast.Item {
        _ = self.expect(.kw_trait) orelse return null;
        self.skipNewlines();
        const name = self.expectIdent() orelse return null;
        self.skipNewlines();
        _ = self.expect(.lbrace) orelse return null;
        self.nesting += 1;
        var methods = std.ArrayListUnmanaged(ast.FnSig){};

        self.skipNewlines();
        while (self.peek() != .rbrace and !self.atEnd()) {
            _ = self.expect(.kw_fn) orelse return null;
            self.skipNewlines();
            const mname = self.expectIdent() orelse return null;
            const params = self.parseParamList() orelse return null;

            var return_type: ?*const ast.TypeExpr = null;
            if (self.eat(.arrow) != null) {
                self.skipNewlines();
                return_type = self.parseTypeExpr() orelse return null;
            }

            methods.append(self.arena, .{
                .name = mname,
                .params = params,
                .return_type = return_type,
            }) catch @panic("oom");
            self.skipNewlines();
        }

        self.nesting -= 1;
        _ = self.expect(.rbrace) orelse return null;

        return .{
            .span = self.spanFrom(start),
            .kind = .{ .trait_decl = .{
                .is_pub = is_pub,
                .name = name,
                .methods = methods.toOwnedSlice(self.arena) catch @panic("oom"),
            } },
        };
    }

    fn parseTypeAlias(self: *Parser, start: usize) ?ast.Item {
        _ = self.expect(.kw_type) orelse return null;
        const name_tok = self.expect(.identifier) orelse return null;
        _ = self.expect(.eq) orelse return null;
        self.skipNewlines();
        const type_expr = self.parseTypeExpr() orelse return null;
        return .{
            .span = self.spanFrom(start),
            .kind = .{ .type_alias = .{
                .name = name_tok.slice(self.source),
                .type_expr = type_expr,
            } },
        };
    }

    fn parseExternBlock(self: *Parser, start: usize) ?ast.Item {
        _ = self.expect(.kw_extern) orelse return null;

        const lib_tok = self.eat(.string) orelse {
            self.emitError("expected library name string after extern");
            return null;
        };
        const raw = lib_tok.slice(self.source);
        const lib = raw[1 .. raw.len - 1];

        self.skipNewlines();
        _ = self.expect(.lbrace) orelse return null;
        self.nesting += 1;
        self.skipNewlines();

        var funcs = std.ArrayListUnmanaged(ast.FfiFunc){};
        while (self.peek() != .rbrace and !self.atEnd()) {
            _ = self.expect(.kw_fn) orelse return null;
            const name = self.expectIdent() orelse return null;
            _ = self.expect(.lparen) orelse return null;

            var params = std.ArrayListUnmanaged(ast.FfiType){};
            while (self.peek() != .rparen and !self.atEnd()) {
                if (self.eat(.identifier) != null) {
                    if (self.eat(.colon) == null) {
                        self.emitError("expected ':' after parameter name");
                        return null;
                    }
                }
                const ptype = self.parseFfiType() orelse return null;
                params.append(self.arena, ptype) catch @panic("oom");
                if (self.peek() != .rparen) {
                    _ = self.expect(.comma) orelse return null;
                }
            }
            _ = self.expect(.rparen) orelse return null;

            var ret: ast.FfiType = .void_;
            if (self.eat(.arrow) != null) {
                ret = self.parseFfiType() orelse return null;
            }

            funcs.append(self.arena, .{
                .name = name,
                .params = params.toOwnedSlice(self.arena) catch @panic("oom"),
                .ret = ret,
            }) catch @panic("oom");
            self.skipNewlines();
        }

        self.nesting -= 1;
        _ = self.expect(.rbrace) orelse return null;

        return .{
            .span = self.spanFrom(start),
            .kind = .{ .extern_block = .{
                .lib = lib,
                .funcs = funcs.toOwnedSlice(self.arena) catch @panic("oom"),
            } },
        };
    }

    fn parseFfiType(self: *Parser) ?ast.FfiType {
        const tok = self.advance();
        const text = tok.slice(self.source);
        if (std.mem.eql(u8, text, "cint")) return .cint;
        if (std.mem.eql(u8, text, "cstr")) return .cstr;
        if (std.mem.eql(u8, text, "ptr")) return .ptr;
        if (std.mem.eql(u8, text, "f64")) return .f64_;
        if (std.mem.eql(u8, text, "void")) return .void_;
        self.emitError("unknown FFI type");
        return null;
    }

    fn parseImportItem(self: *Parser, start: usize) ?ast.Item {
        _ = self.expect(.kw_imp) orelse return null;

        var path = std.ArrayListUnmanaged([]const u8){};
        const first = self.expectIdent() orelse return null;
        path.append(self.arena, first) catch @panic("oom");
        while (self.eat(.slash) != null) {
            const seg = self.expectIdent() orelse return null;
            path.append(self.arena, seg) catch @panic("oom");
        }

        var items = std.ArrayListUnmanaged([]const u8){};
        if (self.eat(.lbrace) != null) {
            self.nesting += 1;
            self.skipNewlines();
            while (self.peek() != .rbrace and !self.atEnd()) {
                const iname = self.expectIdent() orelse return null;
                items.append(self.arena, iname) catch @panic("oom");
                self.skipNewlines();
                if (self.peek() != .rbrace) {
                    _ = self.expect(.comma) orelse return null;
                    self.skipNewlines();
                }
            }
            self.nesting -= 1;
            _ = self.expect(.rbrace) orelse return null;
        }

        var alias: ?[]const u8 = null;
        if (self.eat(.kw_as) != null) {
            alias = self.expectIdent() orelse return null;
        }

        return .{
            .span = self.spanFrom(start),
            .kind = .{ .import = .{
                .path = path.toOwnedSlice(self.arena) catch @panic("oom"),
                .items = items.toOwnedSlice(self.arena) catch @panic("oom"),
                .alias = alias,
            } },
        };
    }

    fn parseBindingItem(self: *Parser, start: usize) ?ast.Item {
        const binding = self.parseBinding() orelse return null;
        return .{ .span = self.spanFrom(start), .kind = .{ .binding = binding } };
    }

    // ---------------------------------------------------------------
    // statements
    // ---------------------------------------------------------------

    fn parseStmt(self: *Parser) ?ast.Stmt {
        const start = self.currentSpanStart();

        if (self.peek() == .kw_return) {
            return self.parseReturn(start);
        }

        if (self.peek() == .kw_fail) {
            return self.parseFail(start);
        }

        if (self.peek() == .kw_for) {
            return self.parseForStmt(start);
        }

        if (self.peek() == .kw_while) {
            return self.parseWhileStmt(start);
        }

        if (self.peek() == .kw_break) {
            _ = self.expect(.kw_break) orelse return null;
            return .{
                .span = self.spanFrom(start),
                .kind = .break_stmt,
            };
        }

        if (self.peek() == .kw_defer) {
            _ = self.expect(.kw_defer) orelse return null;
            self.skipNewlines();
            if (self.peek() == .lbrace) {
                const block = self.parseBlock() orelse return null;
                return .{
                    .span = self.spanFrom(start),
                    .kind = .{ .defer_stmt = .{ .body = .{ .block = block } } },
                };
            }
            const expr = self.parseExpr() orelse return null;
            return .{
                .span = self.spanFrom(start),
                .kind = .{ .defer_stmt = .{ .body = .{ .expr = expr } } },
            };
        }

        if (self.peek() == .kw_arena) {
            _ = self.expect(.kw_arena) orelse return null;
            self.skipNewlines();
            const body = self.parseBlock() orelse return null;
            return .{
                .span = self.spanFrom(start),
                .kind = .{ .arena_block = body },
            };
        }

        if (self.peek() == .kw_mut) {
            const binding = self.parseMutBinding() orelse return null;
            return .{ .span = self.spanFrom(start), .kind = .{ .binding = binding } };
        }

        if (self.isBindingStart()) {
            const binding = self.parseBinding() orelse return null;
            return .{ .span = self.spanFrom(start), .kind = .{ .binding = binding } };
        }

        const expr = self.parseExpr() orelse return null;

        if (self.eatAny(&.{ .plus_eq, .minus_eq, .star_eq, .slash_eq })) |op_tok| {
            self.skipNewlines();
            const value = self.parseExpr() orelse return null;
            return .{
                .span = self.spanFrom(start),
                .kind = .{ .compound_assign = .{ .op = op_tok.tag, .target = expr, .value = value } },
            };
        }

        if (self.eat(.eq) != null) {
            self.skipNewlines();
            const value = self.parseExpr() orelse return null;
            return .{
                .span = self.spanFrom(start),
                .kind = .{ .assign = .{ .target = expr, .value = value } },
            };
        }

        return .{ .span = self.spanFrom(start), .kind = .{ .expr_stmt = expr } };
    }

    fn parseBinding(self: *Parser) ?ast.Binding {
        const is_mut = self.eat(.kw_mut) != null;
        return self.parseBindingBody(is_mut);
    }

    fn parseMutBinding(self: *Parser) ?ast.Binding {
        _ = self.expect(.kw_mut) orelse return null;
        return self.parseBindingBody(true);
    }

    fn parseBindingBody(self: *Parser, is_mut: bool) ?ast.Binding {
        const name = self.expectIdent() orelse return null;

        var type_expr: ?*const ast.TypeExpr = null;
        if (self.eat(.colon) != null) {
            self.skipNewlines();
            type_expr = self.parseTypeExpr() orelse return null;
        }

        _ = self.expect(.eq) orelse return null;
        self.skipNewlines();
        const value = self.parseExpr() orelse return null;

        return .{
            .is_mut = is_mut,
            .name = name,
            .type_expr = type_expr,
            .value = value,
        };
    }

    fn parseReturn(self: *Parser, start: usize) ?ast.Stmt {
        _ = self.expect(.kw_return) orelse return null;
        var value: ?*const ast.Expr = null;
        if (!self.atTerminator()) {
            value = self.parseExpr() orelse return null;
        }
        return .{ .span = self.spanFrom(start), .kind = .{ .ret = .{ .value = value } } };
    }

    fn parseFail(self: *Parser, start: usize) ?ast.Stmt {
        _ = self.expect(.kw_fail) orelse return null;
        self.skipNewlines();
        const value = self.parseExpr() orelse return null;
        return .{ .span = self.spanFrom(start), .kind = .{ .fail = .{ .value = value } } };
    }

    fn parseForStmt(self: *Parser, start: usize) ?ast.Stmt {
        _ = self.expect(.kw_for) orelse return null;
        self.skipNewlines();
        const binding = self.expectIdent() orelse return null;
        _ = self.expect(.kw_in) orelse return null;
        self.skipNewlines();
        const iterator = self.parseExpr() orelse return null;
        self.skipNewlines();
        const body = self.parseBlock() orelse return null;
        return .{
            .span = self.spanFrom(start),
            .kind = .{ .for_loop = .{ .binding = binding, .iterator = iterator, .body = body } },
        };
    }

    fn parseWhileStmt(self: *Parser, start: usize) ?ast.Stmt {
        _ = self.expect(.kw_while) orelse return null;
        self.skipNewlines();
        const condition = self.parseExpr() orelse return null;
        self.skipNewlines();
        const body = self.parseBlock() orelse return null;
        return .{
            .span = self.spanFrom(start),
            .kind = .{ .while_loop = .{ .condition = condition, .body = body } },
        };
    }

    // ---------------------------------------------------------------
    // blocks
    // ---------------------------------------------------------------

    fn parseBlock(self: *Parser) ?*const ast.Block {
        _ = self.expect(.lbrace) orelse return null;
        self.nesting += 1;
        var stmts = std.ArrayListUnmanaged(ast.Stmt){};
        var trailing: ?*const ast.Expr = null;

        self.skipNewlines();
        while (self.peek() != .rbrace and !self.atEnd()) {
            const stmt = self.parseStmt() orelse return null;

            const at_end = self.peek() == .rbrace;
            if (at_end and stmt.kind == .expr_stmt) {
                trailing = stmt.kind.expr_stmt;
            } else {
                stmts.append(self.arena, stmt) catch @panic("oom");
                if (!at_end) self.skipNewlines();
            }
        }

        self.nesting -= 1;
        _ = self.expect(.rbrace) orelse return null;

        return self.create(ast.Block, .{
            .stmts = stmts.toOwnedSlice(self.arena) catch @panic("oom"),
            .trailing = trailing,
        });
    }

    // ---------------------------------------------------------------
    // expressions - pratt parser
    // ---------------------------------------------------------------

    fn parseExpr(self: *Parser) ?*const ast.Expr {
        return self.parsePrecedence(.pipeline);
    }

    fn parsePrecedence(self: *Parser, min_prec: Precedence) ?*const ast.Expr {
        var lhs = self.parsePrefix() orelse return null;

        while (true) {
            if (self.nesting > 0) self.skipNewlines();

            if (self.peek() == .newline) {
                if (self.peekPastNewlines() == .pipe_right and @intFromEnum(Precedence.pipeline) >= @intFromEnum(min_prec)) {
                    self.skipNewlines();
                } else {
                    break;
                }
            }

            if (self.atEnd()) break;

            if (isPostfixToken(self.peek())) {
                const post_prec = Precedence.postfix;
                if (@intFromEnum(post_prec) < @intFromEnum(min_prec)) break;
                lhs = self.parsePostfix(lhs) orelse return null;
                continue;
            }

            const prec = infixPrecedence(self.peek());
            if (prec == .none or @intFromEnum(prec) < @intFromEnum(min_prec)) break;

            if (self.peek() == .pipe_right) {
                lhs = self.parsePipelineExpr(lhs) orelse return null;
                continue;
            }

            if (self.peek() == .kw_or) {
                lhs = self.parseOrExpr(lhs) orelse return null;
                continue;
            }

            const op_tok = self.advance();
            self.skipNewlines();
            const rhs = self.parsePrecedence(prec.next()) orelse return null;
            const span = ast.Span{ .start = lhs.span.start, .end = rhs.span.end };
            lhs = self.create(ast.Expr, .{
                .span = span,
                .kind = .{ .binary = .{ .op = op_tok.tag, .lhs = lhs, .rhs = rhs } },
            });
        }

        return lhs;
    }

    fn parsePrefix(self: *Parser) ?*const ast.Expr {
        const start = self.currentSpanStart();

        switch (self.peek()) {
            .integer => return self.parseLiteral(.int_literal),
            .float => return self.parseLiteral(.float_literal),
            .string => return self.parseLiteral(.string_literal),
            .string_begin => return self.parseStringInterp(),
            .kw_true => {
                _ = self.advance();
                return self.create(ast.Expr, .{ .span = self.spanFrom(start), .kind = .{ .bool_literal = true } });
            },
            .kw_false => {
                _ = self.advance();
                return self.create(ast.Expr, .{ .span = self.spanFrom(start), .kind = .{ .bool_literal = false } });
            },
            .kw_nil => {
                _ = self.advance();
                return self.create(ast.Expr, .{ .span = self.spanFrom(start), .kind = .none_literal });
            },
            .lbracket => return self.parseArrayLiteral(),
            .identifier, .kw_int, .kw_float, .kw_str, .kw_bool, .kw_byte => {
                const name = self.tokenSlice(self.advance());
                const ident_expr = self.create(ast.Expr, .{
                    .span = self.spanFrom(start),
                    .kind = .{ .identifier = name },
                });

                if (self.peek() == .lbrace and self.looksLikeStructLiteral()) {
                    return self.parseStructLiteralExpr(name, start);
                }

                return ident_expr;
            },
            .bang => {
                _ = self.advance();
                self.skipNewlines();
                const operand = self.parsePrecedence(.unary) orelse return null;
                return self.create(ast.Expr, .{
                    .span = self.spanFrom(start),
                    .kind = .{ .unary = .{ .op = .not, .operand = operand } },
                });
            },
            .minus => {
                _ = self.advance();
                self.skipNewlines();
                const operand = self.parsePrecedence(.unary) orelse return null;
                return self.create(ast.Expr, .{
                    .span = self.spanFrom(start),
                    .kind = .{ .unary = .{ .op = .negate, .operand = operand } },
                });
            },
            .ampersand => {
                _ = self.advance();
                var op: ast.Unary.Op = .addr;
                if (self.eat(.kw_mut) != null) {
                    op = .addr_mut;
                }
                self.skipNewlines();
                const operand = self.parsePrecedence(.unary) orelse return null;
                return self.create(ast.Expr, .{
                    .span = self.spanFrom(start),
                    .kind = .{ .unary = .{ .op = op, .operand = operand } },
                });
            },
            .lparen => {
                _ = self.advance();
                self.nesting += 1;
                self.skipNewlines();
                const inner = self.parseExpr() orelse return null;
                self.skipNewlines();
                self.nesting -= 1;
                _ = self.expect(.rparen) orelse return null;
                return inner;
            },
            .lbrace => {
                const block = self.parseBlock() orelse return null;
                return self.create(ast.Expr, .{
                    .span = self.spanFrom(start),
                    .kind = .{ .block = block },
                });
            },
            .kw_if => return self.parseIfExpr(start),
            .kw_match => return self.parseMatchExpr(start),
            .kw_fn => return self.parseClosureExpr(start),
            .pipe => return self.parsePipeClosureExpr(start),
            .kw_spawn => return self.parseSpawnExpr(start),
            else => {
                self.emitError("expected expression");
                return null;
            },
        }
    }

    const LiteralKind = enum { int_literal, float_literal, string_literal };

    fn parseLiteral(self: *Parser, kind: LiteralKind) *const ast.Expr {
        const start = self.currentSpanStart();
        const text = self.tokenSlice(self.advance());
        const expr_kind: ast.Expr.Kind = switch (kind) {
            .int_literal => .{ .int_literal = text },
            .float_literal => .{ .float_literal = text },
            .string_literal => .{ .string_literal = text },
        };
        return self.create(ast.Expr, .{ .span = self.spanFrom(start), .kind = expr_kind });
    }

    fn parseArrayLiteral(self: *Parser) ?*const ast.Expr {
        const start = self.currentSpanStart();
        _ = self.advance(); // eat [
        self.nesting += 1;
        self.skipNewlines();
        var elems = std.ArrayListUnmanaged(*const ast.Expr){};
        while (self.peek() != .rbracket and !self.atEnd()) {
            const elem = self.parseExpr() orelse return null;
            elems.append(self.arena, elem) catch @panic("oom");
            self.skipNewlines();
            if (self.eat(.comma) == null) break;
            self.skipNewlines();
        }
        self.nesting -= 1;
        _ = self.expect(.rbracket) orelse return null;
        return self.create(ast.Expr, .{
            .span = self.spanFrom(start),
            .kind = .{ .array_literal = elems.toOwnedSlice(self.arena) catch @panic("oom") },
        });
    }

    fn parseStringInterp(self: *Parser) *const ast.Expr {
        const start = self.currentSpanStart();
        var parts = std.ArrayListUnmanaged(ast.StringInterp.InterpPart){};
        const text = self.tokenSlice(self.advance());
        if (text.len > 1) {
            parts.append(self.arena, .{ .literal = text[1..] }) catch @panic("oom");
        }
        while (true) {
            const expr = self.parseExpr() orelse break;
            parts.append(self.arena, .{ .expr = expr }) catch @panic("oom");
            if (self.peek() == .string_part) {
                const part = self.tokenSlice(self.advance());
                if (part.len > 0) {
                    parts.append(self.arena, .{ .literal = part }) catch @panic("oom");
                }
            } else if (self.peek() == .string_end) {
                const end_text = self.tokenSlice(self.advance());
                if (end_text.len > 1) {
                    parts.append(self.arena, .{ .literal = end_text[0 .. end_text.len - 1] }) catch @panic("oom");
                }
                break;
            } else {
                break;
            }
        }
        return self.create(ast.Expr, .{
            .span = self.spanFrom(start),
            .kind = .{ .string_interp = .{ .parts = parts.toOwnedSlice(self.arena) catch @panic("oom") } },
        });
    }

    fn parsePostfix(self: *Parser, lhs: *const ast.Expr) ?*const ast.Expr {
        const start = lhs.span.start;

        switch (self.peek()) {
            .dot => {
                _ = self.advance();
                self.skipNewlines();
                const field = self.expectIdent() orelse return null;
                return self.create(ast.Expr, .{
                    .span = self.spanFrom(start),
                    .kind = .{ .field_access = .{ .target = lhs, .field = field } },
                });
            },
            .lparen => {
                _ = self.advance();
                self.nesting += 1;
                var args = std.ArrayListUnmanaged(*const ast.Expr){};
                self.skipNewlines();
                while (self.peek() != .rparen and !self.atEnd()) {
                    const arg = self.parseExpr() orelse return null;
                    args.append(self.arena, arg) catch @panic("oom");
                    self.skipNewlines();
                    if (self.peek() != .rparen) {
                        _ = self.expect(.comma) orelse return null;
                        self.skipNewlines();
                    }
                }
                self.nesting -= 1;
                _ = self.expect(.rparen) orelse return null;
                return self.create(ast.Expr, .{
                    .span = self.spanFrom(start),
                    .kind = .{ .call = .{
                        .callee = lhs,
                        .args = args.toOwnedSlice(self.arena) catch @panic("oom"),
                    } },
                });
            },
            .lbracket => {
                _ = self.advance();
                self.nesting += 1;
                self.skipNewlines();
                const idx = self.parseExpr() orelse return null;
                self.skipNewlines();
                self.nesting -= 1;
                _ = self.expect(.rbracket) orelse return null;
                return self.create(ast.Expr, .{
                    .span = self.spanFrom(start),
                    .kind = .{ .index = .{ .target = lhs, .idx = idx } },
                });
            },
            .question => {
                _ = self.advance();
                return self.create(ast.Expr, .{
                    .span = self.spanFrom(start),
                    .kind = .{ .try_unwrap = lhs },
                });
            },
            .bang => {
                _ = self.advance();
                return self.create(ast.Expr, .{
                    .span = self.spanFrom(start),
                    .kind = .{ .unwrap_crash = lhs },
                });
            },
            else => return lhs,
        }
    }

    fn parsePipelineExpr(self: *Parser, first: *const ast.Expr) ?*const ast.Expr {
        var stages = std.ArrayListUnmanaged(*const ast.Expr){};
        stages.append(self.arena, first) catch @panic("oom");

        while (self.eat(.pipe_right) != null) {
            self.skipNewlines();
            const stage = self.parsePrecedence(Precedence.pipeline.next()) orelse return null;
            stages.append(self.arena, stage) catch @panic("oom");

            if (self.nesting > 0) self.skipNewlines();
            if (self.peek() == .newline and self.peekPastNewlines() == .pipe_right) {
                self.skipNewlines();
            }
        }

        const start = first.span.start;
        const end = stages.items[stages.items.len - 1].span.end;
        return self.create(ast.Expr, .{
            .span = .{ .start = start, .end = end },
            .kind = .{ .pipeline = .{
                .stages = stages.toOwnedSlice(self.arena) catch @panic("oom"),
            } },
        });
    }

    fn parseOrExpr(self: *Parser, lhs: *const ast.Expr) ?*const ast.Expr {
        _ = self.expect(.kw_or) orelse return null;
        self.skipNewlines();

        var err_binding: ?[]const u8 = null;
        if (self.eat(.pipe) != null) {
            err_binding = self.expectIdent() orelse return null;
            _ = self.expect(.pipe) orelse return null;
            self.skipNewlines();
        }

        const rhs = if (self.peek() == .lbrace)
            self.create(ast.Expr, .{
                .span = self.spanFrom(lhs.span.start),
                .kind = .{ .block = self.parseBlock() orelse return null },
            })
        else
            self.parsePrecedence(Precedence.coalesce.next()) orelse return null;

        return self.create(ast.Expr, .{
            .span = .{ .start = lhs.span.start, .end = rhs.span.end },
            .kind = .{ .or_expr = .{
                .lhs = lhs,
                .err_binding = err_binding,
                .rhs = rhs,
            } },
        });
    }

    fn parseIfExpr(self: *Parser, start: usize) ?*const ast.Expr {
        _ = self.expect(.kw_if) orelse return null;
        self.skipNewlines();
        const condition = self.parseExpr() orelse return null;
        self.skipNewlines();
        const then_block = self.parseBlock() orelse return null;

        var else_branch: ?ast.IfExpr.ElseBranch = null;
        self.skipNewlines();
        if (self.eat(.kw_else) != null) {
            self.skipNewlines();
            if (self.peek() == .kw_if) {
                const else_if = self.parseIfExpr(self.currentSpanStart()) orelse return null;
                else_branch = .{ .else_if = else_if };
            } else {
                const else_block = self.parseBlock() orelse return null;
                else_branch = .{ .block = else_block };
            }
        }

        return self.create(ast.Expr, .{
            .span = self.spanFrom(start),
            .kind = .{ .if_expr = .{
                .condition = condition,
                .then_block = then_block,
                .else_branch = else_branch,
            } },
        });
    }

    fn parseMatchExpr(self: *Parser, start: usize) ?*const ast.Expr {
        _ = self.expect(.kw_match) orelse return null;
        self.skipNewlines();
        const subject = self.parseExpr() orelse return null;
        self.skipNewlines();
        _ = self.expect(.lbrace) orelse return null;
        self.nesting += 1;
        var arms = std.ArrayListUnmanaged(ast.MatchArm){};

        self.skipNewlines();
        while (self.peek() != .rbrace and !self.atEnd()) {
            const arm = self.parseMatchArm() orelse return null;
            arms.append(self.arena, arm) catch @panic("oom");
            self.skipNewlines();
        }

        self.nesting -= 1;
        _ = self.expect(.rbrace) orelse return null;

        return self.create(ast.Expr, .{
            .span = self.spanFrom(start),
            .kind = .{ .match_expr = .{
                .subject = subject,
                .arms = arms.toOwnedSlice(self.arena) catch @panic("oom"),
            } },
        });
    }

    fn parseMatchArm(self: *Parser) ?ast.MatchArm {
        const pattern = self.parsePattern() orelse return null;

        var guard: ?*const ast.Expr = null;
        if (self.eat(.kw_if) != null) {
            self.skipNewlines();
            guard = self.parseExpr() orelse return null;
        }

        _ = self.expect(.arrow) orelse return null;
        self.skipNewlines();
        const body = self.parseExpr() orelse return null;

        return .{ .pattern = pattern, .guard = guard, .body = body };
    }

    fn parsePattern(self: *Parser) ?ast.Pattern {
        switch (self.peek()) {
            .integer, .float, .string => {
                const expr = self.parseLiteral(switch (self.peek()) {
                    .integer => .int_literal,
                    .float => .float_literal,
                    .string => .string_literal,
                    else => unreachable,
                });
                return .{ .kind = .{ .literal = expr } };
            },
            .kw_true => {
                _ = self.advance();
                const start = self.pos - 1;
                const expr = self.create(ast.Expr, .{
                    .span = .{ .start = start, .end = start },
                    .kind = .{ .bool_literal = true },
                });
                return .{ .kind = .{ .literal = expr } };
            },
            .kw_false => {
                _ = self.advance();
                const start = self.pos - 1;
                const expr = self.create(ast.Expr, .{
                    .span = .{ .start = start, .end = start },
                    .kind = .{ .bool_literal = false },
                });
                return .{ .kind = .{ .literal = expr } };
            },
            .kw_nil => {
                _ = self.advance();
                return .{ .kind = .{ .literal = self.create(ast.Expr, .{
                    .span = .{ .start = 0, .end = 0 },
                    .kind = .none_literal,
                }) } };
            },
            .identifier => {
                const name = self.tokenSlice(self.advance());

                if (std.mem.eql(u8, name, "_")) {
                    return .{ .kind = .wildcard };
                }

                if (self.eat(.lparen) != null) {
                    self.nesting += 1;
                    var bindings = std.ArrayListUnmanaged([]const u8){};
                    self.skipNewlines();
                    while (self.peek() != .rparen and !self.atEnd()) {
                        const bname = self.expectIdent() orelse return null;
                        bindings.append(self.arena, bname) catch @panic("oom");
                        self.skipNewlines();
                        if (self.peek() != .rparen) {
                            _ = self.expect(.comma) orelse return null;
                            self.skipNewlines();
                        }
                    }
                    self.nesting -= 1;
                    _ = self.expect(.rparen) orelse return null;
                    return .{ .kind = .{ .variant = .{
                        .name = name,
                        .bindings = bindings.toOwnedSlice(self.arena) catch @panic("oom"),
                    } } };
                }

                return .{ .kind = .{ .identifier = name } };
            },
            else => {
                self.emitError("expected pattern");
                return null;
            },
        }
    }

    fn parseClosureExpr(self: *Parser, start: usize) ?*const ast.Expr {
        _ = self.expect(.kw_fn) orelse return null;
        const params = self.parseParamList() orelse return null;

        if (self.eat(.arrow) != null) {
            self.skipNewlines();
            _ = self.parseTypeExpr() orelse return null;
        }

        self.skipNewlines();
        var body: ast.Closure.Body = undefined;
        if (self.peek() == .lbrace) {
            body = .{ .block = self.parseBlock() orelse return null };
        } else {
            body = .{ .expr = self.parsePrecedence(.pipeline) orelse return null };
        }

        return self.create(ast.Expr, .{
            .span = self.spanFrom(start),
            .kind = .{ .closure = .{ .params = params, .body = body } },
        });
    }

    fn parsePipeClosureExpr(self: *Parser, start: usize) ?*const ast.Expr {
        _ = self.expect(.pipe) orelse return null;
        var params = std.ArrayListUnmanaged(ast.Param){};
        while (self.peek() != .pipe and !self.atEnd()) {
            const pname = self.expectIdent() orelse return null;
            var type_expr: ?*const ast.TypeExpr = null;
            if (self.eat(.colon) != null) {
                self.skipNewlines();
                type_expr = self.parseTypeExpr() orelse return null;
            }
            params.append(self.arena, .{ .name = pname, .type_expr = type_expr }) catch @panic("oom");
            if (self.peek() != .pipe) {
                _ = self.expect(.comma) orelse return null;
            }
        }
        _ = self.expect(.pipe) orelse return null;
        self.skipNewlines();

        var body: ast.Closure.Body = undefined;
        if (self.peek() == .lbrace) {
            body = .{ .block = self.parseBlock() orelse return null };
        } else {
            body = .{ .expr = self.parsePrecedence(.pipeline) orelse return null };
        }

        return self.create(ast.Expr, .{
            .span = self.spanFrom(start),
            .kind = .{ .closure = .{
                .params = params.toOwnedSlice(self.arena) catch @panic("oom"),
                .body = body,
            } },
        });
    }

    fn parseSpawnExpr(self: *Parser, start: usize) ?*const ast.Expr {
        _ = self.expect(.kw_spawn) orelse return null;
        self.skipNewlines();
        const body: *const ast.Expr = if (self.peek() == .lbrace) blk: {
            const block = self.parseBlock() orelse return null;
            break :blk self.create(ast.Expr, .{
                .span = self.spanFrom(start),
                .kind = .{ .block = block },
            });
        } else self.parseExpr() orelse return null;

        return self.create(ast.Expr, .{
            .span = self.spanFrom(start),
            .kind = .{ .spawn = body },
        });
    }

    fn parseStructLiteralExpr(self: *Parser, name: []const u8, start: usize) ?*const ast.Expr {
        _ = self.expect(.lbrace) orelse return null;
        self.nesting += 1;
        var fields = std.ArrayListUnmanaged(ast.FieldInit){};

        self.skipNewlines();
        while (self.peek() != .rbrace and !self.atEnd()) {
            const fname = self.expectIdent() orelse return null;
            _ = self.expect(.colon) orelse return null;
            self.skipNewlines();
            const value = self.parseExpr() orelse return null;
            fields.append(self.arena, .{ .name = fname, .value = value }) catch @panic("oom");
            self.skipNewlines();
            if (self.peek() != .rbrace) {
                _ = self.expect(.comma) orelse return null;
                self.skipNewlines();
            }
        }

        self.nesting -= 1;
        _ = self.expect(.rbrace) orelse return null;

        return self.create(ast.Expr, .{
            .span = self.spanFrom(start),
            .kind = .{ .struct_literal = .{
                .name = name,
                .fields = fields.toOwnedSlice(self.arena) catch @panic("oom"),
            } },
        });
    }

    // ---------------------------------------------------------------
    // types
    // ---------------------------------------------------------------

    fn parseTypeExpr(self: *Parser) ?*const ast.TypeExpr {
        const start = self.currentSpanStart();

        if (self.eat(.star) != null) {
            var is_mut = false;
            if (self.eat(.kw_mut) != null) {
                is_mut = true;
            }
            self.skipNewlines();
            const pointee = self.parseTypeExpr() orelse return null;
            return self.create(ast.TypeExpr, .{
                .span = self.spanFrom(start),
                .kind = .{ .pointer = .{ .is_mut = is_mut, .pointee = pointee } },
            });
        }

        if (self.eat(.kw_fn) != null) {
            _ = self.expect(.lparen) orelse return null;
            self.nesting += 1;
            var params = std.ArrayListUnmanaged(*const ast.TypeExpr){};
            self.skipNewlines();
            while (self.peek() != .rparen and !self.atEnd()) {
                const param = self.parseTypeExpr() orelse return null;
                params.append(self.arena, param) catch @panic("oom");
                self.skipNewlines();
                if (self.peek() != .rparen) {
                    _ = self.expect(.comma) orelse return null;
                    self.skipNewlines();
                }
            }
            self.nesting -= 1;
            _ = self.expect(.rparen) orelse return null;
            var return_type: ?*const ast.TypeExpr = null;
            if (self.eat(.arrow) != null) {
                self.skipNewlines();
                return_type = self.parseTypeExpr() orelse return null;
            }
            return self.create(ast.TypeExpr, .{
                .span = self.spanFrom(start),
                .kind = .{ .fn_type = .{
                    .param_types = params.toOwnedSlice(self.arena) catch @panic("oom"),
                    .return_type = return_type,
                } },
            });
        }

        if (self.eat(.lbracket) != null) {
            _ = self.expect(.rbracket) orelse return null;
            const inner = self.parseTypeExpr() orelse return null;
            return self.create(ast.TypeExpr, .{
                .span = self.spanFrom(start),
                .kind = .{ .slice = inner },
            });
        }

        const name = self.expectTypeIdent() orelse return null;

        var base: *const ast.TypeExpr = undefined;
        if (self.eat(.lparen) != null) {
            self.nesting += 1;
            var args = std.ArrayListUnmanaged(*const ast.TypeExpr){};
            self.skipNewlines();
            while (self.peek() != .rparen and !self.atEnd()) {
                const arg = self.parseTypeExpr() orelse return null;
                args.append(self.arena, arg) catch @panic("oom");
                self.skipNewlines();
                if (self.peek() != .rparen) {
                    _ = self.expect(.comma) orelse return null;
                    self.skipNewlines();
                }
            }
            self.nesting -= 1;
            _ = self.expect(.rparen) orelse return null;
            base = self.create(ast.TypeExpr, .{
                .span = self.spanFrom(start),
                .kind = .{ .generic = .{
                    .name = name,
                    .args = args.toOwnedSlice(self.arena) catch @panic("oom"),
                } },
            });
        } else {
            base = self.create(ast.TypeExpr, .{
                .span = self.spanFrom(start),
                .kind = .{ .named = name },
            });
        }

        if (self.eat(.question) != null) {
            return self.create(ast.TypeExpr, .{
                .span = self.spanFrom(start),
                .kind = .{ .optional = base },
            });
        }

        if (self.eat(.bang) != null) {
            var err_type: ?*const ast.TypeExpr = null;
            if (self.eat(.lparen) != null) {
                self.nesting += 1;
                self.skipNewlines();
                err_type = self.parseTypeExpr() orelse return null;
                self.skipNewlines();
                self.nesting -= 1;
                _ = self.expect(.rparen) orelse return null;
            }
            return self.create(ast.TypeExpr, .{
                .span = self.spanFrom(start),
                .kind = .{ .result = .{ .ok_type = base, .err_type = err_type } },
            });
        }

        return base;
    }

    // ---------------------------------------------------------------
    // precedence
    // ---------------------------------------------------------------

    const Precedence = enum(u8) {
        none,
        pipeline,
        or_,
        and_,
        equality,
        comparison,
        coalesce,
        range,
        addition,
        multiply,
        unary,
        postfix,
        primary,

        fn next(self: Precedence) Precedence {
            return @enumFromInt(@intFromEnum(self) + 1);
        }
    };

    fn infixPrecedence(tag: Token.Tag) Precedence {
        return switch (tag) {
            .pipe_right => .pipeline,
            .or_or => .or_,
            .and_and => .and_,
            .eq_eq, .bang_eq => .equality,
            .lt, .gt, .lt_eq, .gt_eq => .comparison,
            .kw_or => .coalesce,
            .dotdot => .range,
            .plus, .minus => .addition,
            .star, .slash, .percent => .multiply,
            else => .none,
        };
    }

    fn isPostfixToken(tag: Token.Tag) bool {
        return tag == .dot or tag == .lparen or tag == .lbracket or tag == .question or tag == .bang;
    }

    // ---------------------------------------------------------------
    // helpers
    // ---------------------------------------------------------------

    fn current(self: *Parser) Token {
        if (self.pos >= self.tokens.len) return self.tokens[self.tokens.len - 1];
        return self.tokens[self.pos];
    }

    fn peek(self: *Parser) Token.Tag {
        return self.current().tag;
    }

    fn advance(self: *Parser) Token {
        const tok = self.current();
        if (self.pos < self.tokens.len) self.pos += 1;
        return tok;
    }

    fn expect(self: *Parser, tag: Token.Tag) ?Token {
        if (self.peek() == tag) return self.advance();
        self.emitErrorFmt("expected {s}", .{tag.displayName()});
        return null;
    }

    fn eat(self: *Parser, tag: Token.Tag) ?Token {
        if (self.peek() == tag) return self.advance();
        return null;
    }

    fn eatAny(self: *Parser, tags: []const Token.Tag) ?Token {
        for (tags) |tag| {
            if (self.peek() == tag) return self.advance();
        }
        return null;
    }

    fn expectIdent(self: *Parser) ?[]const u8 {
        if (self.peek() == .identifier) return self.tokenSlice(self.advance());

        if (self.peek() == .kw_int or self.peek() == .kw_float or
            self.peek() == .kw_str or self.peek() == .kw_bool or
            self.peek() == .kw_byte)
        {
            return self.tokenSlice(self.advance());
        }

        self.emitError("expected identifier");
        return null;
    }

    fn expectTypeIdent(self: *Parser) ?[]const u8 {
        if (self.peek() == .identifier) return self.tokenSlice(self.advance());

        if (self.peek() == .kw_int or self.peek() == .kw_float or
            self.peek() == .kw_str or self.peek() == .kw_bool or
            self.peek() == .kw_byte)
        {
            return self.tokenSlice(self.advance());
        }

        // sized types are identifiers
        self.emitError("expected type name");
        return null;
    }

    fn atEnd(self: *Parser) bool {
        return self.peek() == .eof;
    }

    fn atTerminator(self: *Parser) bool {
        return self.peek() == .newline or self.peek() == .eof or self.peek() == .rbrace;
    }

    fn skipNewlines(self: *Parser) void {
        while (self.peek() == .newline) {
            self.pos += 1;
        }
    }

    fn peekPastNewlines(self: *Parser) Token.Tag {
        var i = self.pos;
        while (i < self.tokens.len and self.tokens[i].tag == .newline) {
            i += 1;
        }
        if (i >= self.tokens.len) return .eof;
        return self.tokens[i].tag;
    }

    fn tokenSlice(self: *Parser, tok: Token) []const u8 {
        return tok.slice(self.source);
    }

    fn currentSpanStart(self: *Parser) usize {
        return self.current().loc.start;
    }

    fn spanFrom(self: *Parser, start: usize) ast.Span {
        const end = if (self.pos > 0) self.tokens[self.pos - 1].loc.end else start;
        return .{ .start = start, .end = end };
    }

    fn isBindingStart(self: *Parser) bool {
        if (self.peek() == .kw_mut) return true;
        if (self.peek() != .identifier) return false;
        if (self.pos + 1 >= self.tokens.len) return false;
        const next_tag = self.tokens[self.pos + 1].tag;
        return next_tag == .eq or next_tag == .colon;
    }

    fn looksLikeStructLiteral(self: *Parser) bool {
        if (self.peek() != .lbrace) return false;
        var i = self.pos + 1;
        while (i < self.tokens.len and self.tokens[i].tag == .newline) {
            i += 1;
        }
        if (i >= self.tokens.len) return false;
        if (self.tokens[i].tag != .identifier) return false;
        i += 1;
        while (i < self.tokens.len and self.tokens[i].tag == .newline) {
            i += 1;
        }
        if (i >= self.tokens.len) return false;
        return self.tokens[i].tag == .colon;
    }

    fn create(self: *Parser, comptime T: type, value: T) *const T {
        const ptr = self.arena.create(T) catch @panic("oom");
        ptr.* = value;
        return ptr;
    }

    fn emitError(self: *Parser, message: []const u8) void {
        self.errors.append(self.arena, .{
            .span = .{ .start = self.current().loc.start, .end = self.current().loc.end },
            .message = message,
        }) catch @panic("oom");
    }

    fn emitErrorFmt(self: *Parser, comptime fmt: []const u8, args: anytype) void {
        const message = std.fmt.allocPrint(self.arena, fmt, args) catch @panic("oom");
        self.emitError(message);
    }

    fn synchronize(self: *Parser) void {
        while (!self.atEnd()) {
            switch (self.peek()) {
                .kw_fn, .kw_struct, .kw_enum, .kw_trait, .kw_imp, .kw_pub => return,
                else => _ = self.advance(),
            }
        }
    }
};

pub fn tokenize(alloc: std.mem.Allocator, source: []const u8) []const Token {
    var tokens: std.ArrayListUnmanaged(Token) = .{};
    var lex = Lexer.init(source);
    while (true) {
        const tok = lex.next();
        tokens.append(alloc, tok) catch @panic("oom");
        if (tok.tag == .eof) break;
    }
    return tokens.toOwnedSlice(alloc) catch @panic("oom");
}

// ---------------------------------------------------------------
// tests
// ---------------------------------------------------------------

fn testParse(source: []const u8) ast.Ast {
    var arena_impl = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const arena = arena_impl.allocator();
    const tokens = tokenize(arena, source);
    var parser = Parser.init(tokens, source, arena);
    return parser.parse();
}

fn expectNoErrors(result: ast.Ast) !void {
    if (result.errors.len > 0) {
        std.debug.print("parse errors:\n", .{});
        for (result.errors) |err| {
            std.debug.print("  [{d}..{d}] {s}\n", .{ err.span.start, err.span.end, err.message });
        }
        return error.TestUnexpectedResult;
    }
}

test "parse empty file" {
    const result = testParse("");
    try expectNoErrors(result);
    try std.testing.expectEqual(@as(usize, 0), result.items.len);
}

test "parse simple function" {
    const result = testParse("fn main() {\n  println(\"hello\")\n}");
    try expectNoErrors(result);
    try std.testing.expectEqual(@as(usize, 1), result.items.len);
    try std.testing.expectEqual(ast.Item.Kind.fn_decl, std.meta.activeTag(result.items[0].kind));
    const decl = result.items[0].kind.fn_decl;
    try std.testing.expectEqualStrings("main", decl.name);
    try std.testing.expectEqual(@as(usize, 0), decl.params.len);
    try std.testing.expectEqual(ast.FnDecl.Body.block, std.meta.activeTag(decl.body));
}

test "parse function with params and return type" {
    const result = testParse("fn add(a: int, b: int) -> int {\n  a + b\n}");
    try expectNoErrors(result);
    const decl = result.items[0].kind.fn_decl;
    try std.testing.expectEqualStrings("add", decl.name);
    try std.testing.expectEqual(@as(usize, 2), decl.params.len);
    try std.testing.expectEqualStrings("a", decl.params[0].name);
    try std.testing.expectEqualStrings("b", decl.params[1].name);
    try std.testing.expect(decl.return_type != null);
    try std.testing.expectEqual(ast.FnDecl.Body.block, std.meta.activeTag(decl.body));
    const block = decl.body.block;
    try std.testing.expect(block.trailing != null);
    try std.testing.expectEqual(ast.Expr.Kind.binary, std.meta.activeTag(block.trailing.?.kind));
}

test "parse one-liner function" {
    const result = testParse("fn double(x: int) -> int = x * 2");
    try expectNoErrors(result);
    const decl = result.items[0].kind.fn_decl;
    try std.testing.expectEqualStrings("double", decl.name);
    try std.testing.expectEqual(ast.FnDecl.Body.expr, std.meta.activeTag(decl.body));
}

test "parse pub function" {
    const result = testParse("pub fn greet() {\n  println(\"hi\")\n}");
    try expectNoErrors(result);
    try std.testing.expect(result.items[0].kind.fn_decl.is_pub);
}

test "parse struct" {
    const result = testParse("struct User {\n  id: int\n  name: str\n  active: bool\n}");
    try expectNoErrors(result);
    const decl = result.items[0].kind.struct_decl;
    try std.testing.expectEqualStrings("User", decl.name);
    try std.testing.expectEqual(@as(usize, 3), decl.fields.len);
    try std.testing.expectEqualStrings("id", decl.fields[0].name);
    try std.testing.expect(!decl.is_packed);
}

test "parse packed struct" {
    const result = testParse("struct PacketHeader packed {\n  version: int\n}");
    try expectNoErrors(result);
    try std.testing.expect(result.items[0].kind.struct_decl.is_packed);
}

test "parse enum" {
    const result = testParse("enum Shape {\n  Circle(f64)\n  Rect(f64, f64)\n  Point\n}");
    try expectNoErrors(result);
    const decl = result.items[0].kind.enum_decl;
    try std.testing.expectEqualStrings("Shape", decl.name);
    try std.testing.expectEqual(@as(usize, 3), decl.variants.len);
    try std.testing.expectEqualStrings("Circle", decl.variants[0].name);
    try std.testing.expectEqual(@as(usize, 1), decl.variants[0].payloads.len);
    try std.testing.expectEqualStrings("Point", decl.variants[2].name);
    try std.testing.expectEqual(@as(usize, 0), decl.variants[2].payloads.len);
}

test "parse generic enum" {
    const result = testParse("enum Result(T, E) {\n  Ok(T)\n  Err(E)\n}");
    try expectNoErrors(result);
    const decl = result.items[0].kind.enum_decl;
    try std.testing.expectEqual(@as(usize, 2), decl.type_params.len);
    try std.testing.expectEqualStrings("T", decl.type_params[0]);
    try std.testing.expectEqualStrings("E", decl.type_params[1]);
}

test "parse trait" {
    const result = testParse("trait Serializable {\n  fn serialize(self) -> []u8\n}");
    try expectNoErrors(result);
    const decl = result.items[0].kind.trait_decl;
    try std.testing.expectEqualStrings("Serializable", decl.name);
    try std.testing.expectEqual(@as(usize, 1), decl.methods.len);
}

test "parse import" {
    const result = testParse("imp std/http");
    try expectNoErrors(result);
    const imp = result.items[0].kind.import;
    try std.testing.expectEqual(@as(usize, 2), imp.path.len);
    try std.testing.expectEqualStrings("std", imp.path[0]);
    try std.testing.expectEqualStrings("http", imp.path[1]);
}

test "parse import with items" {
    const result = testParse("imp models { User, Post }");
    try expectNoErrors(result);
    const imp = result.items[0].kind.import;
    try std.testing.expectEqual(@as(usize, 2), imp.items.len);
    try std.testing.expectEqualStrings("User", imp.items[0]);
}

test "parse import with alias" {
    const result = testParse("imp db/postgres as pg");
    try expectNoErrors(result);
    const imp = result.items[0].kind.import;
    try std.testing.expectEqualStrings("pg", imp.alias.?);
}

test "parse operator precedence" {
    const result = testParse("fn f() -> int = 1 + 2 * 3");
    try expectNoErrors(result);
    const expr = result.items[0].kind.fn_decl.body.expr;
    try std.testing.expectEqual(ast.Expr.Kind.binary, std.meta.activeTag(expr.kind));
    try std.testing.expectEqual(Token.Tag.plus, expr.kind.binary.op);
    try std.testing.expectEqual(Token.Tag.star, expr.kind.binary.rhs.kind.binary.op);
}

test "parse comparison and logical" {
    const result = testParse("fn f() -> bool = a > 0 && b < 10");
    try expectNoErrors(result);
    const expr = result.items[0].kind.fn_decl.body.expr;
    try std.testing.expectEqual(Token.Tag.and_and, expr.kind.binary.op);
}

test "parse unary" {
    const result = testParse("fn f() -> int = -x");
    try expectNoErrors(result);
    const expr = result.items[0].kind.fn_decl.body.expr;
    try std.testing.expectEqual(ast.Expr.Kind.unary, std.meta.activeTag(expr.kind));
    try std.testing.expectEqual(ast.Unary.Op.negate, expr.kind.unary.op);
}

test "parse function call" {
    const result = testParse("fn f() {\n  println(\"hello\", 42)\n}");
    try expectNoErrors(result);
    const block = result.items[0].kind.fn_decl.body.block;
    try std.testing.expect(block.trailing != null);
    const call = block.trailing.?.kind.call;
    try std.testing.expectEqual(@as(usize, 2), call.args.len);
}

test "parse field access" {
    const result = testParse("fn f() -> str = user.name");
    try expectNoErrors(result);
    const expr = result.items[0].kind.fn_decl.body.expr;
    try std.testing.expectEqual(ast.Expr.Kind.field_access, std.meta.activeTag(expr.kind));
    try std.testing.expectEqualStrings("name", expr.kind.field_access.field);
}

test "parse chained field access and call" {
    const result = testParse("fn f() = user.full_name().len");
    try expectNoErrors(result);
    const expr = result.items[0].kind.fn_decl.body.expr;
    try std.testing.expectEqual(ast.Expr.Kind.field_access, std.meta.activeTag(expr.kind));
    try std.testing.expectEqualStrings("len", expr.kind.field_access.field);
}

test "parse index" {
    const result = testParse("fn f() = items[0]");
    try expectNoErrors(result);
    const expr = result.items[0].kind.fn_decl.body.expr;
    try std.testing.expectEqual(ast.Expr.Kind.index, std.meta.activeTag(expr.kind));
}

test "parse if expression" {
    const result = testParse("fn f() = if x > 0 { \"pos\" } else { \"neg\" }");
    try expectNoErrors(result);
    const expr = result.items[0].kind.fn_decl.body.expr;
    try std.testing.expectEqual(ast.Expr.Kind.if_expr, std.meta.activeTag(expr.kind));
    try std.testing.expect(expr.kind.if_expr.else_branch != null);
}

test "parse match" {
    const result = testParse(
        \\fn f() = match s {
        \\  Circle(r) -> r
        \\  Point -> 0.0
        \\}
    );
    try expectNoErrors(result);
    const expr = result.items[0].kind.fn_decl.body.expr;
    try std.testing.expectEqual(ast.Expr.Kind.match_expr, std.meta.activeTag(expr.kind));
    try std.testing.expectEqual(@as(usize, 2), expr.kind.match_expr.arms.len);
}

test "parse match with guard" {
    const result = testParse(
        \\fn f() = match n {
        \\  0 -> "zero"
        \\  n if n < 0 -> "neg"
        \\  n -> "pos"
        \\}
    );
    try expectNoErrors(result);
    const arms = result.items[0].kind.fn_decl.body.expr.kind.match_expr.arms;
    try std.testing.expectEqual(@as(usize, 3), arms.len);
    try std.testing.expect(arms[1].guard != null);
}

test "parse variable binding" {
    const result = testParse("fn f() {\n  x = 5\n}");
    try expectNoErrors(result);
    const block = result.items[0].kind.fn_decl.body.block;
    try std.testing.expectEqual(@as(usize, 1), block.stmts.len);
    const binding = block.stmts[0].kind.binding;
    try std.testing.expectEqualStrings("x", binding.name);
    try std.testing.expect(!binding.is_mut);
}

test "parse mutable binding" {
    const result = testParse("fn f() {\n  mut y = 10\n}");
    try expectNoErrors(result);
    const binding = result.items[0].kind.fn_decl.body.block.stmts[0].kind.binding;
    try std.testing.expect(binding.is_mut);
}

test "parse typed binding" {
    const result = testParse("fn f() {\n  x: int = 5\n}");
    try expectNoErrors(result);
    const binding = result.items[0].kind.fn_decl.body.block.stmts[0].kind.binding;
    try std.testing.expect(binding.type_expr != null);
}

test "parse return" {
    const result = testParse("fn f() {\n  return 42\n}");
    try expectNoErrors(result);
    const stmt = result.items[0].kind.fn_decl.body.block.stmts[0];
    try std.testing.expectEqual(ast.Stmt.Kind.ret, std.meta.activeTag(stmt.kind));
    try std.testing.expect(stmt.kind.ret.value != null);
}

test "parse for loop" {
    const result = testParse("fn f() {\n  for item in items {\n    process(item)\n  }\n}");
    try expectNoErrors(result);
    const stmt = result.items[0].kind.fn_decl.body.block.stmts[0];
    try std.testing.expectEqual(ast.Stmt.Kind.for_loop, std.meta.activeTag(stmt.kind));
    try std.testing.expectEqualStrings("item", stmt.kind.for_loop.binding);
}

test "parse while loop" {
    const result = testParse("fn f() {\n  while running {\n    tick()\n  }\n}");
    try expectNoErrors(result);
    const stmt = result.items[0].kind.fn_decl.body.block.stmts[0];
    try std.testing.expectEqual(ast.Stmt.Kind.while_loop, std.meta.activeTag(stmt.kind));
}

test "parse arena block" {
    const result = testParse("fn f() {\n  arena {\n    x = 1\n  }\n}");
    try expectNoErrors(result);
    const stmt = result.items[0].kind.fn_decl.body.block.stmts[0];
    try std.testing.expectEqual(ast.Stmt.Kind.arena_block, std.meta.activeTag(stmt.kind));
}

test "parse pipeline" {
    const result = testParse("fn f() = data |> filter(fn(x) x > 0) |> sort()");
    try expectNoErrors(result);
    const expr = result.items[0].kind.fn_decl.body.expr;
    try std.testing.expectEqual(ast.Expr.Kind.pipeline, std.meta.activeTag(expr.kind));
    try std.testing.expectEqual(@as(usize, 3), expr.kind.pipeline.stages.len);
}

test "parse closure" {
    const result = testParse("fn f() = fn(x) x * 2");
    try expectNoErrors(result);
    const expr = result.items[0].kind.fn_decl.body.expr;
    try std.testing.expectEqual(ast.Expr.Kind.closure, std.meta.activeTag(expr.kind));
    try std.testing.expectEqual(@as(usize, 1), expr.kind.closure.params.len);
}

test "parse pipe closure" {
    const result = testParse("fn f() = |x| x + 1");
    try expectNoErrors(result);
    const expr = result.items[0].kind.fn_decl.body.expr;
    try std.testing.expectEqual(ast.Expr.Kind.closure, std.meta.activeTag(expr.kind));
}

test "parse spawn" {
    const result = testParse("fn f() = spawn { compute() }");
    try expectNoErrors(result);
    const expr = result.items[0].kind.fn_decl.body.expr;
    try std.testing.expectEqual(ast.Expr.Kind.spawn, std.meta.activeTag(expr.kind));
}

test "parse optional type postfix" {
    const result = testParse("fn find(id: int) -> User? {}");
    try expectNoErrors(result);
    const rt = result.items[0].kind.fn_decl.return_type.?;
    try std.testing.expectEqual(ast.TypeExpr.Kind.optional, std.meta.activeTag(rt.kind));
}

test "parse pointer type" {
    const result = testParse("fn f(p: *User) {}");
    try expectNoErrors(result);
    const pt = result.items[0].kind.fn_decl.params[0].type_expr.?;
    try std.testing.expectEqual(ast.TypeExpr.Kind.pointer, std.meta.activeTag(pt.kind));
    try std.testing.expect(!pt.kind.pointer.is_mut);
}

test "parse mut pointer type" {
    const result = testParse("fn f(p: *mut User) {}");
    try expectNoErrors(result);
    const pt = result.items[0].kind.fn_decl.params[0].type_expr.?;
    try std.testing.expect(pt.kind.pointer.is_mut);
}

test "parse slice type" {
    const result = testParse("fn f(data: []u8) {}");
    try expectNoErrors(result);
    const st = result.items[0].kind.fn_decl.params[0].type_expr.?;
    try std.testing.expectEqual(ast.TypeExpr.Kind.slice, std.meta.activeTag(st.kind));
}

test "parse generic type" {
    const result = testParse("fn f() -> Result(User, str) {}");
    try expectNoErrors(result);
    const rt = result.items[0].kind.fn_decl.return_type.?;
    try std.testing.expectEqual(ast.TypeExpr.Kind.generic, std.meta.activeTag(rt.kind));
    try std.testing.expectEqual(@as(usize, 2), rt.kind.generic.args.len);
}

test "parse or operator" {
    const result = testParse("fn f() = find(42) or default");
    try expectNoErrors(result);
    const expr = result.items[0].kind.fn_decl.body.expr;
    try std.testing.expectEqual(ast.Expr.Kind.or_expr, std.meta.activeTag(expr.kind));
    try std.testing.expect(expr.kind.or_expr.err_binding == null);
}

test "parse struct literal" {
    const result = testParse("fn f() = User { id: 1, name: \"alice\" }");
    try expectNoErrors(result);
    const expr = result.items[0].kind.fn_decl.body.expr;
    try std.testing.expectEqual(ast.Expr.Kind.struct_literal, std.meta.activeTag(expr.kind));
    try std.testing.expectEqual(@as(usize, 2), expr.kind.struct_literal.fields.len);
}

test "parse multiple items" {
    const source =
        \\imp std/io
        \\
        \\struct Point {
        \\  x: int
        \\  y: int
        \\}
        \\
        \\fn distance(a: Point, b: Point) -> float {
        \\  dx = a.x - b.x
        \\  dy = a.y - b.y
        \\  sqrt(dx * dx + dy * dy)
        \\}
    ;
    const result = testParse(source);
    try expectNoErrors(result);
    try std.testing.expectEqual(@as(usize, 3), result.items.len);
}

test "parse newlines inside parens" {
    const result = testParse("fn f() = add(\n  1,\n  2\n)");
    try expectNoErrors(result);
    const expr = result.items[0].kind.fn_decl.body.expr;
    try std.testing.expectEqual(ast.Expr.Kind.call, std.meta.activeTag(expr.kind));
    try std.testing.expectEqual(@as(usize, 2), expr.kind.call.args.len);
}

test "parse hello.pyr" {
    const source = "fn main() {\n  println(\"hello from pyr\")\n}";
    const result = testParse(source);
    try expectNoErrors(result);
    try std.testing.expectEqual(@as(usize, 1), result.items.len);
    const decl = result.items[0].kind.fn_decl;
    try std.testing.expectEqualStrings("main", decl.name);
    const block = decl.body.block;
    try std.testing.expect(block.trailing != null);
    try std.testing.expectEqual(ast.Expr.Kind.call, std.meta.activeTag(block.trailing.?.kind));
}

test "parse result type" {
    const result = testParse("fn parse(s: str) -> Config! {}");
    try expectNoErrors(result);
    const rt = result.items[0].kind.fn_decl.return_type.?;
    try std.testing.expectEqual(ast.TypeExpr.Kind.result, std.meta.activeTag(rt.kind));
    try std.testing.expect(rt.kind.result.err_type == null);
}

test "parse result type with error type" {
    const result = testParse("fn connect(addr: str) -> Conn!(IoError) {}");
    try expectNoErrors(result);
    const rt = result.items[0].kind.fn_decl.return_type.?;
    try std.testing.expectEqual(ast.TypeExpr.Kind.result, std.meta.activeTag(rt.kind));
    try std.testing.expect(rt.kind.result.err_type != null);
}

test "parse or with error binding" {
    const result = testParse("fn f() = x or |err| { err }");
    try expectNoErrors(result);
    const expr = result.items[0].kind.fn_decl.body.expr;
    try std.testing.expectEqual(ast.Expr.Kind.or_expr, std.meta.activeTag(expr.kind));
    try std.testing.expect(expr.kind.or_expr.err_binding != null);
    try std.testing.expectEqualStrings("err", expr.kind.or_expr.err_binding.?);
}

test "parse fail statement" {
    const result = testParse("fn f() {\n  fail \"error\"\n}");
    try expectNoErrors(result);
    const block = result.items[0].kind.fn_decl.body.block;
    try std.testing.expectEqual(@as(usize, 1), block.stmts.len);
    try std.testing.expectEqual(ast.Stmt.Kind.fail, std.meta.activeTag(block.stmts[0].kind));
}

test "parse defer expression" {
    const result = testParse("fn f() {\n  defer close(x)\n}");
    try expectNoErrors(result);
    const block = result.items[0].kind.fn_decl.body.block;
    try std.testing.expectEqual(@as(usize, 1), block.stmts.len);
    try std.testing.expectEqual(ast.Stmt.Kind.defer_stmt, std.meta.activeTag(block.stmts[0].kind));
}

test "parse defer block" {
    const result = testParse("fn f() {\n  defer {\n    a()\n    b()\n  }\n}");
    try expectNoErrors(result);
    const block = result.items[0].kind.fn_decl.body.block;
    try std.testing.expectEqual(@as(usize, 1), block.stmts.len);
    const d = block.stmts[0].kind.defer_stmt;
    try std.testing.expectEqual(ast.Defer.Body.block, std.meta.activeTag(d.body));
}

test "parse unwrap crash postfix" {
    const result = testParse("fn f() = x!");
    try expectNoErrors(result);
    const expr = result.items[0].kind.fn_decl.body.expr;
    try std.testing.expectEqual(ast.Expr.Kind.unwrap_crash, std.meta.activeTag(expr.kind));
}

test "parse try_unwrap still works" {
    const result = testParse("fn f() = x?");
    try expectNoErrors(result);
    const expr = result.items[0].kind.fn_decl.body.expr;
    try std.testing.expectEqual(ast.Expr.Kind.try_unwrap, std.meta.activeTag(expr.kind));
}

test "parse type alias" {
    const result = testParse("type ID = int");
    try expectNoErrors(result);
    try std.testing.expectEqual(ast.Item.Kind.type_alias, std.meta.activeTag(result.items[0].kind));
    try std.testing.expectEqualStrings("ID", result.items[0].kind.type_alias.name);
}

test "parse fn type expression" {
    const result = testParse("type F = fn(int, str) -> bool");
    try expectNoErrors(result);
    const ta = result.items[0].kind.type_alias;
    try std.testing.expectEqual(ast.TypeExpr.Kind.fn_type, std.meta.activeTag(ta.type_expr.kind));
    try std.testing.expectEqual(@as(usize, 2), ta.type_expr.kind.fn_type.param_types.len);
}

test "parse fn type in param" {
    const result = testParse("fn apply(x: int, f: fn(int) -> int) -> int = f(x)");
    try expectNoErrors(result);
    const params = result.items[0].kind.fn_decl.params;
    try std.testing.expectEqual(@as(usize, 2), params.len);
    try std.testing.expectEqual(ast.TypeExpr.Kind.fn_type, std.meta.activeTag(params[1].type_expr.?.kind));
}
