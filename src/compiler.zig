const std = @import("std");
const ast = @import("ast.zig");
const Chunk = @import("chunk.zig").Chunk;
const OpCode = @import("chunk.zig").OpCode;
const Value = @import("value.zig").Value;
const ObjString = @import("value.zig").ObjString;
const ObjFunction = @import("value.zig").ObjFunction;

pub const Compiler = struct {
    alloc: std.mem.Allocator,
    enclosing: ?*Compiler,
    function: *ObjFunction,
    locals: [256]Local,
    local_count: u8,
    scope_depth: u32,

    pub const Local = struct {
        name: []const u8,
        depth: u32,
    };

    pub fn compile(alloc: std.mem.Allocator, tree: ast.Ast) ?*ObjFunction {
        const script = ObjFunction.create(alloc, "", 0);
        var compiler = Compiler{
            .alloc = alloc,
            .enclosing = null,
            .function = script,
            .locals = undefined,
            .local_count = 0,
            .scope_depth = 0,
        };

        for (tree.items) |item| {
            compiler.compileItem(item);
        }

        compiler.emitCall("main", 0);
        compiler.emitOp(.nil);
        compiler.emitOp(.return_);

        return script;
    }

    // ---------------------------------------------------------------
    // items
    // ---------------------------------------------------------------

    fn compileItem(self: *Compiler, item: ast.Item) void {
        switch (item.kind) {
            .fn_decl => |decl| self.compileFnDecl(decl),
            .binding => |b| self.compileTopBinding(b),
            .struct_decl, .enum_decl, .trait_decl, .import => {},
        }
    }

    fn compileFnDecl(self: *Compiler, decl: ast.FnDecl) void {
        var func = ObjFunction.create(self.alloc, decl.name, @intCast(decl.params.len));

        var sub = Compiler{
            .alloc = self.alloc,
            .enclosing = self,
            .function = func,
            .locals = undefined,
            .local_count = 0,
            .scope_depth = 1,
        };
        sub.addLocal("");

        for (decl.params) |param| {
            sub.addLocal(param.name);
        }

        switch (decl.body) {
            .block => |block| sub.compileBlock(block),
            .expr => |expr| {
                sub.compileExpr(expr);
                sub.emitOp(.return_);
            },
            .none => {},
        }

        if (!sub.lastOpIs(.return_)) {
            sub.emitOp(.nil);
            sub.emitOp(.return_);
        }

        const idx = self.chunk().addConstant(self.alloc, func.toValue());
        self.emitOp(.constant);
        self.emitU16(idx);

        const name_idx = self.addStringConstant(decl.name);
        self.emitOp(.define_global);
        self.emitU16(name_idx);
    }

    fn compileTopBinding(self: *Compiler, binding: ast.Binding) void {
        self.compileExpr(binding.value);
        const name_idx = self.addStringConstant(binding.name);
        self.emitOp(.define_global);
        self.emitU16(name_idx);
    }

    // ---------------------------------------------------------------
    // blocks and statements
    // ---------------------------------------------------------------

    fn compileBlock(self: *Compiler, block: *const ast.Block) void {
        self.beginScope();

        for (block.stmts) |stmt| {
            self.compileStmt(stmt);
        }

        if (block.trailing) |expr| {
            self.compileExpr(expr);
            self.emitOp(.return_);
        }

        self.endScope();
    }

    fn compileStmt(self: *Compiler, stmt: ast.Stmt) void {
        switch (stmt.kind) {
            .binding => |b| {
                self.compileExpr(b.value);
                if (self.scope_depth > 0) {
                    self.addLocal(b.name);
                } else {
                    const name_idx = self.addStringConstant(b.name);
                    self.emitOp(.define_global);
                    self.emitU16(name_idx);
                }
            },
            .assign => |a| {
                self.compileExpr(a.value);
                self.compileSetTarget(a.target);
            },
            .compound_assign => |ca| {
                self.compileGetTarget(ca.target);
                self.compileExpr(ca.value);
                self.emitOp(switch (ca.op) {
                    .plus_eq => .add,
                    .minus_eq => .subtract,
                    .star_eq => .multiply,
                    .slash_eq => .divide,
                    else => .add,
                });
                self.compileSetTarget(ca.target);
            },
            .ret => |r| {
                if (r.value) |val| {
                    self.compileExpr(val);
                } else {
                    self.emitOp(.nil);
                }
                self.emitOp(.return_);
            },
            .for_loop => |fl| {
                self.compileExpr(fl.iterator);
                _ = fl.binding;
                // TODO: iterator protocol
            },
            .while_loop => |wl| {
                const loop_start = self.chunk().count();
                self.compileExpr(wl.condition);
                const exit_jump = self.emitJump(.jump_if_false);
                self.emitOp(.pop);
                self.compileBlock(wl.body);
                self.emitLoop(loop_start);
                self.patchJump(exit_jump);
                self.emitOp(.pop);
            },
            .expr_stmt => |expr| {
                self.compileExpr(expr);
                self.emitOp(.pop);
            },
        }
    }

    // ---------------------------------------------------------------
    // expressions
    // ---------------------------------------------------------------

    fn compileExpr(self: *Compiler, expr: *const ast.Expr) void {
        switch (expr.kind) {
            .int_literal => |text| {
                const val = std.fmt.parseInt(i64, text, 10) catch 0;
                self.emitConstant(Value.initInt(val));
            },
            .float_literal => |text| {
                const val = std.fmt.parseFloat(f64, text) catch 0.0;
                self.emitConstant(Value.initFloat(val));
            },
            .string_literal => |text| {
                const inner = if (text.len >= 2) text[1 .. text.len - 1] else text;
                const str = ObjString.create(self.alloc, inner);
                self.emitConstant(str.toValue());
            },
            .bool_literal => |val| self.emitOp(if (val) .true_ else .false_),
            .none_literal => self.emitOp(.nil),
            .identifier => |name| self.compileGetVar(name),
            .binary => |bin| self.compileBinary(bin),
            .unary => |un| {
                self.compileExpr(un.operand);
                switch (un.op) {
                    .negate => self.emitOp(.negate),
                    .not => self.emitOp(.not),
                    .addr, .addr_mut => {},
                }
            },
            .call => |call| self.compileCall(call),
            .field_access => |fa| {
                self.compileExpr(fa.target);
                // TODO: field access opcode
                _ = fa.field;
            },
            .index => |idx| {
                self.compileExpr(idx.target);
                self.compileExpr(idx.idx);
                // TODO: index opcode
            },
            .if_expr => |ie| self.compileIf(ie),
            .match_expr => |me| self.compileMatch(me),
            .block => |block| self.compileBlock(block),
            .closure => |cl| self.compileClosure(cl),
            .spawn => {},
            .struct_literal => |sl| {
                // TODO: struct creation
                _ = sl;
                self.emitOp(.nil);
            },
            .pipeline => |pl| self.compilePipeline(pl),
        }
    }

    fn compileBinary(self: *Compiler, bin: ast.Binary) void {
        if (bin.op == .double_question) {
            self.compileExpr(bin.lhs);
            const jump = self.emitJump(.jump_if_false);
            self.emitOp(.pop);
            self.compileExpr(bin.rhs);
            self.patchJump(jump);
            return;
        }

        self.compileExpr(bin.lhs);
        self.compileExpr(bin.rhs);

        const op: OpCode = switch (bin.op) {
            .plus => .add,
            .minus => .subtract,
            .star => .multiply,
            .slash => .divide,
            .percent => .modulo,
            .eq_eq => .equal,
            .bang_eq => .not_equal,
            .lt => .less,
            .gt => .greater,
            .lt_eq => .less_equal,
            .gt_eq => .greater_equal,
            else => return,
        };
        self.emitOp(op);
    }

    fn compileCall(self: *Compiler, call: ast.Call) void {
        if (call.callee.kind == .identifier) {
            const name = call.callee.kind.identifier;

            if (std.mem.eql(u8, name, "println")) {
                if (call.args.len > 0) self.compileExpr(call.args[0]) else self.emitOp(.nil);
                self.emitOp(.println);
                self.emitOp(.nil);
                return;
            }
            if (std.mem.eql(u8, name, "print")) {
                if (call.args.len > 0) self.compileExpr(call.args[0]) else self.emitOp(.nil);
                self.emitOp(.print);
                self.emitOp(.nil);
                return;
            }
        }

        self.compileGetExpr(call.callee);
        for (call.args) |arg| {
            self.compileExpr(arg);
        }
        self.emitOp(.call);
        self.emitByte(@intCast(call.args.len));
    }

    fn compileGetExpr(self: *Compiler, expr: *const ast.Expr) void {
        switch (expr.kind) {
            .identifier => |name| self.compileGetVar(name),
            else => self.compileExpr(expr),
        }
    }

    fn compileIf(self: *Compiler, ie: ast.IfExpr) void {
        self.compileExpr(ie.condition);
        const then_jump = self.emitJump(.jump_if_false);
        self.emitOp(.pop);

        self.compileBlockValue(ie.then_block);

        const else_jump = self.emitJump(.jump);
        self.patchJump(then_jump);
        self.emitOp(.pop);

        if (ie.else_branch) |eb| switch (eb) {
            .block => |block| self.compileBlockValue(block),
            .else_if => |ei| self.compileExpr(ei),
        } else {
            self.emitOp(.nil);
        }

        self.patchJump(else_jump);
    }

    fn compileBlockValue(self: *Compiler, block: *const ast.Block) void {
        self.beginScope();
        for (block.stmts) |stmt| {
            self.compileStmt(stmt);
        }
        if (block.trailing) |expr| {
            self.compileExpr(expr);
        } else {
            self.emitOp(.nil);
        }
        self.endScopeKeepTop();
    }

    fn compileMatch(self: *Compiler, me: ast.MatchExpr) void {
        self.compileExpr(me.subject);
        // simplified: compile as if/else chain
        for (me.arms, 0..) |arm, i| {
            _ = i;
            // TODO: proper pattern matching
            // for now, just compile the body of the first arm
            self.emitOp(.pop);
            self.compileExpr(arm.body);
            return;
        }
        self.emitOp(.pop);
        self.emitOp(.nil);
    }

    fn compileClosure(self: *Compiler, cl: ast.Closure) void {
        var func = ObjFunction.create(self.alloc, "<closure>", @intCast(cl.params.len));
        var sub = Compiler{
            .alloc = self.alloc,
            .enclosing = self,
            .function = func,
            .locals = undefined,
            .local_count = 0,
            .scope_depth = 1,
        };
        sub.addLocal("");

        for (cl.params) |param| {
            sub.addLocal(param.name);
        }

        switch (cl.body) {
            .block => |block| sub.compileBlock(block),
            .expr => |expr| {
                sub.compileExpr(expr);
                sub.emitOp(.return_);
            },
        }

        if (!sub.lastOpIs(.return_)) {
            sub.emitOp(.nil);
            sub.emitOp(.return_);
        }

        self.emitConstant(func.toValue());
    }

    fn compilePipeline(self: *Compiler, pl: ast.Pipeline) void {
        if (pl.stages.len == 0) return;
        self.compileExpr(pl.stages[0]);
        for (pl.stages[1..]) |stage| {
            if (stage.kind == .call) {
                const call = stage.kind.call;
                self.compileGetExpr(call.callee);
                // first arg is the piped value (already on stack)
                // swap: value is below callee, need callee below value
                // actually, just push remaining args and call with +1 arity
                // this is a simplification - proper pipeline needs stack manipulation
                for (call.args) |arg| {
                    self.compileExpr(arg);
                }
                self.emitOp(.call);
                self.emitByte(@intCast(call.args.len + 1));
            } else {
                self.compileGetExpr(stage);
                self.emitOp(.call);
                self.emitByte(1);
            }
        }
    }

    // ---------------------------------------------------------------
    // variables
    // ---------------------------------------------------------------

    fn compileGetVar(self: *Compiler, name: []const u8) void {
        if (self.resolveLocal(name)) |slot| {
            self.emitOp(.get_local);
            self.emitByte(slot);
        } else {
            const idx = self.addStringConstant(name);
            self.emitOp(.get_global);
            self.emitU16(idx);
        }
    }

    fn compileSetTarget(self: *Compiler, expr: *const ast.Expr) void {
        if (expr.kind == .identifier) {
            const name = expr.kind.identifier;
            if (self.resolveLocal(name)) |slot| {
                self.emitOp(.set_local);
                self.emitByte(slot);
            } else {
                const idx = self.addStringConstant(name);
                self.emitOp(.set_global);
                self.emitU16(idx);
            }
        }
    }

    fn compileGetTarget(self: *Compiler, expr: *const ast.Expr) void {
        self.compileGetVar(if (expr.kind == .identifier) expr.kind.identifier else "");
    }

    fn resolveLocal(self: *Compiler, name: []const u8) ?u8 {
        if (self.local_count == 0) return null;
        var i: u8 = self.local_count;
        while (i > 0) {
            i -= 1;
            if (std.mem.eql(u8, self.locals[i].name, name)) return i;
        }
        return null;
    }

    fn addLocal(self: *Compiler, name: []const u8) void {
        if (self.local_count == 255) return;
        self.locals[self.local_count] = .{ .name = name, .depth = self.scope_depth };
        self.local_count += 1;
    }

    fn beginScope(self: *Compiler) void {
        self.scope_depth += 1;
    }

    fn endScope(self: *Compiler) void {
        self.scope_depth -= 1;
        while (self.local_count > 0 and self.locals[self.local_count - 1].depth > self.scope_depth) {
            self.emitOp(.pop);
            self.local_count -= 1;
        }
    }

    fn endScopeKeepTop(self: *Compiler) void {
        self.scope_depth -= 1;
        while (self.local_count > 0 and self.locals[self.local_count - 1].depth > self.scope_depth) {
            self.local_count -= 1;
        }
    }

    // ---------------------------------------------------------------
    // emit helpers
    // ---------------------------------------------------------------

    fn chunk(self: *Compiler) *Chunk {
        return &self.function.chunk;
    }

    fn emitByte(self: *Compiler, byte: u8) void {
        self.chunk().write(self.alloc, byte, 0);
    }

    fn emitOp(self: *Compiler, op: OpCode) void {
        self.chunk().writeOp(self.alloc, op, 0);
    }

    fn emitU16(self: *Compiler, val: u16) void {
        self.chunk().writeU16(self.alloc, val, 0);
    }

    fn emitConstant(self: *Compiler, val: Value) void {
        const idx = self.chunk().addConstant(self.alloc, val);
        self.emitOp(.constant);
        self.emitU16(idx);
    }

    fn emitJump(self: *Compiler, op: OpCode) usize {
        self.emitOp(op);
        self.emitByte(0xff);
        self.emitByte(0xff);
        return self.chunk().count() - 2;
    }

    fn patchJump(self: *Compiler, offset: usize) void {
        self.chunk().patchJump(offset);
    }

    fn emitLoop(self: *Compiler, loop_start: usize) void {
        self.emitOp(.loop_);
        const offset = self.chunk().count() - loop_start + 2;
        self.emitU16(@intCast(offset));
    }

    fn emitCall(self: *Compiler, name: []const u8, arity: u8) void {
        const idx = self.addStringConstant(name);
        self.emitOp(.get_global);
        self.emitU16(idx);
        self.emitOp(.call);
        self.emitByte(arity);
    }

    fn addStringConstant(self: *Compiler, text: []const u8) u16 {
        const str = ObjString.create(self.alloc, text);
        return self.chunk().addConstant(self.alloc, str.toValue());
    }

    fn lastOpIs(self: *Compiler, op: OpCode) bool {
        if (self.chunk().code.items.len == 0) return false;
        return self.chunk().code.items[self.chunk().code.items.len - 1] == @intFromEnum(op);
    }
};
