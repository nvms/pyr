const std = @import("std");
const ast = @import("ast.zig");

pub const Codegen = struct {
    source: []const u8,
    out: std.ArrayListUnmanaged(u8),
    alloc: std.mem.Allocator,
    indent: usize,

    pub fn generate(alloc: std.mem.Allocator, tree: ast.Ast) []const u8 {
        var self = Codegen{
            .source = tree.source,
            .out = .{},
            .alloc = alloc,
            .indent = 0,
        };

        self.write("const std = @import(\"std\");\n\n");

        for (tree.items) |item| {
            self.emitItem(item);
            self.write("\n");
        }

        return self.out.items;
    }

    // ---------------------------------------------------------------
    // items
    // ---------------------------------------------------------------

    fn emitItem(self: *Codegen, item: ast.Item) void {
        switch (item.kind) {
            .fn_decl => |decl| self.emitFnDecl(decl),
            .struct_decl => |decl| self.emitStructDecl(decl),
            .enum_decl => |decl| self.emitEnumDecl(decl),
            .trait_decl => {},
            .import => {},
            .binding => |b| self.emitTopLevelBinding(b),
        }
    }

    fn emitFnDecl(self: *Codegen, decl: ast.FnDecl) void {
        if (std.mem.eql(u8, decl.name, "main")) {
            self.write("pub fn main() void ");
        } else {
            self.write("fn ");
            self.write(decl.name);
            self.write("(");
            for (decl.params, 0..) |param, i| {
                if (i > 0) self.write(", ");
                self.write(param.name);
                self.write(": ");
                if (param.type_expr) |te| {
                    self.emitType(te);
                } else {
                    self.write("anytype");
                }
            }
            self.write(") ");
            if (decl.return_type) |rt| {
                self.emitType(rt);
                self.write(" ");
            } else {
                self.write("void ");
            }
        }

        switch (decl.body) {
            .block => |block| self.emitBlock(block),
            .expr => |expr| {
                self.write("{\n");
                self.indent += 1;
                self.writeIndent();
                self.write("return ");
                self.emitExpr(expr);
                self.write(";\n");
                self.indent -= 1;
                self.writeIndent();
                self.write("}\n");
            },
            .none => self.write("{}\n"),
        }
    }

    fn emitStructDecl(self: *Codegen, decl: ast.StructDecl) void {
        if (decl.is_pub) self.write("pub ");
        self.write("const ");
        self.write(decl.name);
        self.write(" = ");
        if (decl.is_packed) self.write("packed ");
        self.write("struct {\n");
        self.indent += 1;
        for (decl.fields) |field| {
            self.writeIndent();
            self.write(field.name);
            self.write(": ");
            self.emitType(field.type_expr);
            self.write(",\n");
        }
        self.indent -= 1;
        self.writeIndent();
        self.write("};\n");
    }

    fn emitEnumDecl(self: *Codegen, decl: ast.EnumDecl) void {
        if (decl.is_pub) self.write("pub ");
        self.write("const ");
        self.write(decl.name);
        self.write(" = union(enum) {\n");
        self.indent += 1;
        for (decl.variants) |variant| {
            self.writeIndent();
            self.write(variant.name);
            if (variant.payloads.len > 0) {
                self.write(": ");
                if (variant.payloads.len == 1) {
                    self.emitType(variant.payloads[0]);
                } else {
                    self.write("struct { ");
                    for (variant.payloads, 0..) |pl, i| {
                        if (i > 0) self.write(", ");
                        self.writeFmt("_{d}: ", .{i});
                        self.emitType(pl);
                    }
                    self.write(" }");
                }
            }
            self.write(",\n");
        }
        self.indent -= 1;
        self.writeIndent();
        self.write("};\n");
    }

    fn emitTopLevelBinding(self: *Codegen, binding: ast.Binding) void {
        if (binding.is_mut) {
            self.write("var ");
        } else {
            self.write("const ");
        }
        self.write(binding.name);
        if (binding.type_expr) |te| {
            self.write(": ");
            self.emitType(te);
        }
        self.write(" = ");
        self.emitExpr(binding.value);
        self.write(";\n");
    }

    // ---------------------------------------------------------------
    // blocks and statements
    // ---------------------------------------------------------------

    fn emitBlock(self: *Codegen, block: *const ast.Block) void {
        self.write("{\n");
        self.indent += 1;

        for (block.stmts) |stmt| {
            self.writeIndent();
            self.emitStmt(stmt);
        }

        if (block.trailing) |expr| {
            self.writeIndent();
            self.write("return ");
            self.emitExpr(expr);
            self.write(";\n");
        }

        self.indent -= 1;
        self.writeIndent();
        self.write("}\n");
    }

    fn emitStmt(self: *Codegen, stmt: ast.Stmt) void {
        switch (stmt.kind) {
            .binding => |b| {
                if (b.is_mut) {
                    self.write("var ");
                } else {
                    self.write("const ");
                }
                self.write(b.name);
                if (b.type_expr) |te| {
                    self.write(": ");
                    self.emitType(te);
                }
                self.write(" = ");
                self.emitExpr(b.value);
                self.write(";\n");
            },
            .assign => |a| {
                self.emitExpr(a.target);
                self.write(" = ");
                self.emitExpr(a.value);
                self.write(";\n");
            },
            .compound_assign => |ca| {
                self.emitExpr(ca.target);
                self.write(" ");
                self.write(opStr(ca.op));
                self.write(" ");
                self.emitExpr(ca.value);
                self.write(";\n");
            },
            .ret => |r| {
                self.write("return");
                if (r.value) |val| {
                    self.write(" ");
                    self.emitExpr(val);
                }
                self.write(";\n");
            },
            .for_loop => |fl| {
                self.write("for (");
                self.emitExpr(fl.iterator);
                self.write(") |");
                self.write(fl.binding);
                self.write("| ");
                self.emitBlock(fl.body);
            },
            .while_loop => |wl| {
                self.write("while (");
                self.emitExpr(wl.condition);
                self.write(") ");
                self.emitBlock(wl.body);
            },
            .expr_stmt => |expr| {
                self.emitExprStmt(expr);
                self.write(";\n");
            },
        }
    }

    // ---------------------------------------------------------------
    // expressions
    // ---------------------------------------------------------------

    fn emitExpr(self: *Codegen, expr: *const ast.Expr) void {
        switch (expr.kind) {
            .int_literal => |text| self.write(text),
            .float_literal => |text| self.write(text),
            .string_literal => |text| self.write(text),
            .bool_literal => |val| self.write(if (val) "true" else "false"),
            .none_literal => self.write("null"),
            .identifier => |name| self.write(name),
            .binary => |bin| {
                self.write("(");
                self.emitExpr(bin.lhs);
                self.write(" ");
                self.write(opStr(bin.op));
                self.write(" ");
                self.emitExpr(bin.rhs);
                self.write(")");
            },
            .unary => |un| {
                switch (un.op) {
                    .negate => self.write("-"),
                    .not => self.write("!"),
                    .addr => self.write("&"),
                    .addr_mut => self.write("&"),
                }
                self.emitExpr(un.operand);
            },
            .field_access => |fa| {
                self.emitExpr(fa.target);
                self.write(".");
                self.write(fa.field);
            },
            .call => |call| self.emitCall(call),
            .index => |idx| {
                self.emitExpr(idx.target);
                self.write("[");
                self.emitExpr(idx.idx);
                self.write("]");
            },
            .if_expr => |ie| self.emitIfExpr(ie),
            .match_expr => |me| self.emitMatchExpr(me),
            .block => |block| {
                self.write("blk: ");
                self.emitBlockExpr(block);
            },
            .closure => |cl| self.emitClosure(cl),
            .spawn => |inner| {
                self.write("@import(\"std\").Thread.spawn(.{}, struct { fn f() void { ");
                self.emitExpr(inner);
                self.write("; } }.f, .{})");
            },
            .struct_literal => |sl| {
                self.write(sl.name);
                self.write("{ ");
                for (sl.fields, 0..) |field, i| {
                    if (i > 0) self.write(", ");
                    self.write(".");
                    self.write(field.name);
                    self.write(" = ");
                    self.emitExpr(field.value);
                }
                self.write(" }");
            },
            .pipeline => |pl| self.emitPipeline(pl),
        }
    }

    fn emitExprStmt(self: *Codegen, expr: *const ast.Expr) void {
        switch (expr.kind) {
            .call => |call| self.emitCall(call),
            else => {
                self.write("_ = ");
                self.emitExpr(expr);
            },
        }
    }

    fn emitCall(self: *Codegen, call: ast.Call) void {
        if (call.callee.kind == .identifier) {
            const name = call.callee.kind.identifier;
            if (std.mem.eql(u8, name, "println")) {
                self.emitPrintln(call.args);
                return;
            }
            if (std.mem.eql(u8, name, "print")) {
                self.emitPrint(call.args);
                return;
            }
        }

        self.emitExpr(call.callee);
        self.write("(");
        for (call.args, 0..) |arg, i| {
            if (i > 0) self.write(", ");
            self.emitExpr(arg);
        }
        self.write(")");
    }

    fn emitPrintln(self: *Codegen, args: []const *const ast.Expr) void {
        if (args.len == 0) {
            self.write("std.debug.print(\"\\n\", .{})");
            return;
        }
        if (args[0].kind == .string_literal) {
            self.write("std.debug.print(");
            self.emitExpr(args[0]);
            self.write(" ++ \"\\n\", .{})");
        } else {
            self.write("std.debug.print(\"{any}\\n\", .{");
            self.emitExpr(args[0]);
            self.write("})");
        }
    }

    fn emitPrint(self: *Codegen, args: []const *const ast.Expr) void {
        if (args.len == 0) return;
        if (args[0].kind == .string_literal) {
            self.write("std.debug.print(");
            self.emitExpr(args[0]);
            self.write(", .{})");
        } else {
            self.write("std.debug.print(\"{any}\", .{");
            self.emitExpr(args[0]);
            self.write("})");
        }
    }

    fn emitIfExpr(self: *Codegen, ie: ast.IfExpr) void {
        self.write("if (");
        self.emitExpr(ie.condition);
        self.write(") ");
        self.emitBlockExpr(ie.then_block);
        if (ie.else_branch) |eb| {
            self.write(" else ");
            switch (eb) {
                .block => |block| self.emitBlockExpr(block),
                .else_if => |ei| self.emitExpr(ei),
            }
        }
    }

    fn emitMatchExpr(self: *Codegen, me: ast.MatchExpr) void {
        self.write("switch (");
        self.emitExpr(me.subject);
        self.write(") {\n");
        self.indent += 1;
        for (me.arms) |arm| {
            self.writeIndent();
            self.emitPattern(arm.pattern);
            self.write(" => ");
            self.emitCapture(arm.pattern);
            self.emitExpr(arm.body);
            self.write(",\n");
        }
        self.indent -= 1;
        self.writeIndent();
        self.write("}");
    }

    fn emitPattern(self: *Codegen, pattern: ast.Pattern) void {
        switch (pattern.kind) {
            .identifier => |name| {
                if (name.len > 0 and name[0] >= 'A' and name[0] <= 'Z') {
                    self.write(".");
                }
                self.write(name);
            },
            .literal => |expr| self.emitExpr(expr),
            .variant => |v| {
                self.write(".");
                self.write(v.name);
            },
            .wildcard => self.write("_"),
        }
    }

    fn emitCapture(self: *Codegen, pattern: ast.Pattern) void {
        if (pattern.kind == .variant) {
            const v = pattern.kind.variant;
            if (v.bindings.len > 0) {
                self.write("|");
                for (v.bindings, 0..) |b, i| {
                    if (i > 0) self.write(", ");
                    self.write(b);
                }
                self.write("| ");
            }
        }
    }

    fn emitClosure(self: *Codegen, cl: ast.Closure) void {
        self.write("struct { fn f(");
        for (cl.params, 0..) |param, i| {
            if (i > 0) self.write(", ");
            self.write(param.name);
            self.write(": ");
            if (param.type_expr) |te| {
                self.emitType(te);
            } else {
                self.write("anytype");
            }
        }
        self.write(") ");
        switch (cl.body) {
            .block => |block| {
                self.write("void ");
                self.emitBlock(block);
            },
            .expr => |expr| {
                self.write("anytype { return ");
                self.emitExpr(expr);
                self.write("; }");
            },
        }
        self.write(" }.f");
    }

    fn emitPipeline(self: *Codegen, pl: ast.Pipeline) void {
        if (pl.stages.len == 0) return;
        if (pl.stages.len == 1) {
            self.emitExpr(pl.stages[0]);
            return;
        }

        var i: usize = pl.stages.len;
        while (i > 1) {
            i -= 1;
            self.emitExpr(pl.stages[i]);
            self.write("(");
        }
        self.emitExpr(pl.stages[0]);
        i = 1;
        while (i < pl.stages.len) : (i += 1) {
            self.write(")");
        }
    }

    fn emitBlockExpr(self: *Codegen, block: *const ast.Block) void {
        if (block.stmts.len == 0 and block.trailing != null) {
            self.emitExpr(block.trailing.?);
        } else {
            self.emitBlock(block);
        }
    }

    // ---------------------------------------------------------------
    // types
    // ---------------------------------------------------------------

    fn emitType(self: *Codegen, type_expr: *const ast.TypeExpr) void {
        switch (type_expr.kind) {
            .named => |name| {
                if (std.mem.eql(u8, name, "int")) {
                    self.write("i64");
                } else if (std.mem.eql(u8, name, "float")) {
                    self.write("f64");
                } else if (std.mem.eql(u8, name, "str")) {
                    self.write("[]const u8");
                } else if (std.mem.eql(u8, name, "bool")) {
                    self.write("bool");
                } else if (std.mem.eql(u8, name, "byte")) {
                    self.write("u8");
                } else {
                    self.write(name);
                }
            },
            .generic => |g| {
                self.write(g.name);
                self.write("(");
                for (g.args, 0..) |arg, i| {
                    if (i > 0) self.write(", ");
                    self.emitType(arg);
                }
                self.write(")");
            },
            .optional => |inner| {
                self.write("?");
                self.emitType(inner);
            },
            .pointer => |p| {
                self.write("*");
                if (p.is_mut) self.write("allowzero ");
                self.emitType(p.pointee);
            },
            .slice => |inner| {
                self.write("[]");
                self.emitType(inner);
            },
        }
    }

    // ---------------------------------------------------------------
    // output helpers
    // ---------------------------------------------------------------

    fn write(self: *Codegen, s: []const u8) void {
        self.out.appendSlice(self.alloc, s) catch @panic("oom");
    }

    fn writeFmt(self: *Codegen, comptime fmt: []const u8, args: anytype) void {
        var buf: [256]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, fmt, args) catch @panic("fmt overflow");
        self.write(s);
    }

    fn writeIndent(self: *Codegen) void {
        for (0..self.indent) |_| {
            self.write("    ");
        }
    }
};

fn opStr(tag: @import("token.zig").Token.Tag) []const u8 {
    return switch (tag) {
        .plus, .plus_eq => "+",
        .minus, .minus_eq => "-",
        .star, .star_eq => "*",
        .slash, .slash_eq => "/",
        .percent => "%",
        .eq_eq => "==",
        .bang_eq => "!=",
        .lt => "<",
        .gt => ">",
        .lt_eq => "<=",
        .gt_eq => ">=",
        .and_and => "and",
        .or_or => "or",
        .double_question => "orelse",
        .dotdot => "...",
        else => "???",
    };
}

// ---------------------------------------------------------------
// tests
// ---------------------------------------------------------------

const parser = @import("parser.zig");

fn testGenerate(source: []const u8) []const u8 {
    const alloc = std.heap.page_allocator;
    var arena_impl = std.heap.ArenaAllocator.init(alloc);
    const arena = arena_impl.allocator();
    const tokens = parser.tokenize(arena, source);
    var p = parser.Parser.init(tokens, source, arena);
    const tree = p.parse();
    if (tree.errors.len > 0) @panic("parse error in test");
    return Codegen.generate(alloc, tree);
}

fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

test "codegen: hello world" {
    const out = testGenerate("fn main() {\n  println(\"hello\")\n}");
    try std.testing.expect(contains(out, "pub fn main()"));
    try std.testing.expect(contains(out, "std.debug.print"));
}

test "codegen: function with return" {
    const out = testGenerate("fn add(a: int, b: int) -> int {\n  a + b\n}");
    try std.testing.expect(contains(out, "fn add(a: i64, b: i64) i64"));
    try std.testing.expect(contains(out, "return"));
}

test "codegen: one-liner" {
    const out = testGenerate("fn double(x: int) -> int = x * 2");
    try std.testing.expect(contains(out, "fn double(x: i64) i64"));
    try std.testing.expect(contains(out, "return (x * 2)"));
}

test "codegen: struct" {
    const out = testGenerate("struct Point {\n  x: float\n  y: float\n}");
    try std.testing.expect(contains(out, "const Point = struct"));
    try std.testing.expect(contains(out, "x: f64"));
    try std.testing.expect(contains(out, "y: f64"));
}

test "codegen: enum" {
    const out = testGenerate("enum Shape {\n  Circle(float)\n  Point\n}");
    try std.testing.expect(contains(out, "const Shape = union(enum)"));
    try std.testing.expect(contains(out, "Circle: f64"));
    try std.testing.expect(contains(out, "Point"));
}

test "codegen: variable binding" {
    const out = testGenerate("fn f() {\n  x = 5\n  mut y = 10\n}");
    try std.testing.expect(contains(out, "const x = 5"));
    try std.testing.expect(contains(out, "var y = 10"));
}

test "codegen: if expression" {
    const out = testGenerate("fn f() = if true { 1 } else { 0 }");
    try std.testing.expect(contains(out, "if (true)"));
    try std.testing.expect(contains(out, "else"));
}

test "codegen: struct literal" {
    const out = testGenerate("fn f() = Point { x: 1.0, y: 2.0 }");
    try std.testing.expect(contains(out, "Point{ .x = 1.0, .y = 2.0 }"));
}

test "codegen: coalesce to orelse" {
    const out = testGenerate("fn f() = x ?? 0");
    try std.testing.expect(contains(out, "orelse"));
}
