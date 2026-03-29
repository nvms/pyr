const std = @import("std");
const ast = @import("ast.zig");
const ModuleLoader = @import("module.zig").ModuleLoader;
const stdlib = @import("stdlib.zig");

pub const Type = union(enum) {
    void,
    bool_,
    int,
    float,
    str,
    byte,
    u8_,
    u16_,
    u32_,
    u64_,
    i8_,
    i16_,
    i32_,
    i64_,
    f32_,
    f64_,
    usize_,
    isize_,
    named: []const u8,
    fn_: FnType,
    optional: *const Type,
    pointer: Ptr,
    slice: *const Type,
    err,

    pub const Ptr = struct {
        pointee: *const Type,
        is_mut: bool,
    };
};

pub const FnType = struct {
    param_count: usize,
    return_type: *const Type,
    mut_params: u64 = 0,
};

pub const Symbol = struct {
    ty: *const Type,
    is_mut: bool,
    kind: Kind,

    pub const Kind = enum { variable, function, parameter, type_name, builtin };
};

const t_void: Type = .void;
const t_bool: Type = .bool_;
const t_int: Type = .int;
const t_float: Type = .float;
const t_str: Type = .str;
const t_byte: Type = .byte;
const t_err: Type = .err;
const t_u8: Type = .u8_;
const t_u16: Type = .u16_;
const t_u32: Type = .u32_;
const t_u64: Type = .u64_;
const t_i8: Type = .i8_;
const t_i16: Type = .i16_;
const t_i32: Type = .i32_;
const t_i64: Type = .i64_;
const t_f32: Type = .f32_;
const t_f64: Type = .f64_;
const t_usize: Type = .usize_;
const t_isize: Type = .isize_;

const builtin_println_ty: Type = .{ .fn_ = .{ .param_count = 255, .return_type = &t_void } };
const builtin_print_ty: Type = .{ .fn_ = .{ .param_count = 255, .return_type = &t_void } };

pub const Scope = struct {
    parent: ?*Scope,
    symbols: std.StringHashMapUnmanaged(Symbol),

    fn init() Scope {
        return .{ .parent = null, .symbols = .{} };
    }

    fn define(self: *Scope, alloc: std.mem.Allocator, name: []const u8, sym: Symbol) void {
        self.symbols.put(alloc, name, sym) catch @panic("oom");
    }

    fn lookup(self: *const Scope, name: []const u8) ?Symbol {
        if (self.symbols.get(name)) |sym| return sym;
        if (self.parent) |p| return p.lookup(name);
        return null;
    }

    fn lookupLocal(self: *const Scope, name: []const u8) ?Symbol {
        return self.symbols.get(name);
    }

    fn lookupPtr(self: *Scope, name: []const u8) ?*Symbol {
        if (self.symbols.getPtr(name)) |ptr| return ptr;
        if (self.parent) |p| return p.lookupPtr(name);
        return null;
    }
};

pub const Error = struct {
    span: ast.Span,
    message: []const u8,
};

pub const Analysis = struct {
    errors: []const Error,
};

pub const Sema = struct {
    arena: std.mem.Allocator,
    source: []const u8,
    scope: *Scope,
    scope_stack: std.ArrayListUnmanaged(*Scope),
    errors: std.ArrayListUnmanaged(Error),
    fn_return_type: ?*const Type,
    module_loader: ?*ModuleLoader,
    module_dir: []const u8,
    cond_depth: u32 = 0,

    pub fn analyze(arena: std.mem.Allocator, tree: ast.Ast) Analysis {
        return analyzeModule(arena, tree, null, ".");
    }

    pub fn analyzeModule(arena: std.mem.Allocator, tree: ast.Ast, loader: ?*ModuleLoader, dir: []const u8) Analysis {
        var self = Sema{
            .arena = arena,
            .source = tree.source,
            .scope = undefined,
            .scope_stack = .{},
            .errors = .{},
            .fn_return_type = null,
            .module_loader = loader,
            .module_dir = dir,
        };

        self.pushScope();
        self.defineBuiltins();

        for (tree.items) |item| {
            self.registerItem(item);
        }

        for (tree.items) |item| {
            self.analyzeItem(item);
        }

        self.popScope();

        return .{
            .errors = self.errors.toOwnedSlice(arena) catch @panic("oom"),
        };
    }

    fn defineBuiltins(self: *Sema) void {
        self.define("println", .{ .ty = &builtin_println_ty, .is_mut = false, .kind = .builtin });
        self.define("print", .{ .ty = &builtin_print_ty, .is_mut = false, .kind = .builtin });
        self.define("sqrt", .{ .ty = &builtin_println_ty, .is_mut = false, .kind = .builtin });
        self.define("len", .{ .ty = &builtin_println_ty, .is_mut = false, .kind = .builtin });
        self.define("range", .{ .ty = &builtin_println_ty, .is_mut = false, .kind = .builtin });
        self.define("abs", .{ .ty = &builtin_println_ty, .is_mut = false, .kind = .builtin });
        self.define("int", .{ .ty = &builtin_println_ty, .is_mut = false, .kind = .builtin });
        self.define("float", .{ .ty = &builtin_println_ty, .is_mut = false, .kind = .builtin });
        self.define("push", .{ .ty = &builtin_println_ty, .is_mut = false, .kind = .builtin });
        self.define("assert", .{ .ty = &builtin_println_ty, .is_mut = false, .kind = .builtin });
        self.define("assert_eq", .{ .ty = &builtin_println_ty, .is_mut = false, .kind = .builtin });
        self.define("contains", .{ .ty = &builtin_println_ty, .is_mut = false, .kind = .builtin });
        self.define("index_of", .{ .ty = &builtin_println_ty, .is_mut = false, .kind = .builtin });
        self.define("slice", .{ .ty = &builtin_println_ty, .is_mut = false, .kind = .builtin });
        self.define("join", .{ .ty = &builtin_println_ty, .is_mut = false, .kind = .builtin });
        self.define("reverse", .{ .ty = &builtin_println_ty, .is_mut = false, .kind = .builtin });
        self.define("pop", .{ .ty = &builtin_println_ty, .is_mut = false, .kind = .builtin });
        self.define("split", .{ .ty = &builtin_println_ty, .is_mut = false, .kind = .builtin });
        self.define("trim", .{ .ty = &builtin_println_ty, .is_mut = false, .kind = .builtin });
        self.define("starts_with", .{ .ty = &builtin_println_ty, .is_mut = false, .kind = .builtin });
        self.define("ends_with", .{ .ty = &builtin_println_ty, .is_mut = false, .kind = .builtin });
        self.define("replace", .{ .ty = &builtin_println_ty, .is_mut = false, .kind = .builtin });
        self.define("to_upper", .{ .ty = &builtin_println_ty, .is_mut = false, .kind = .builtin });
        self.define("to_lower", .{ .ty = &builtin_println_ty, .is_mut = false, .kind = .builtin });
        self.define("clone", .{ .ty = &builtin_println_ty, .is_mut = false, .kind = .builtin });
        self.define("getattr", .{ .ty = &builtin_println_ty, .is_mut = false, .kind = .builtin });
        self.define("keys", .{ .ty = &builtin_println_ty, .is_mut = false, .kind = .builtin });
        self.define("type_of", .{ .ty = &builtin_println_ty, .is_mut = false, .kind = .builtin });
        self.define("map", .{ .ty = &builtin_println_ty, .is_mut = false, .kind = .builtin });
        self.define("filter", .{ .ty = &builtin_println_ty, .is_mut = false, .kind = .builtin });
        self.define("reduce", .{ .ty = &builtin_println_ty, .is_mut = false, .kind = .builtin });
        self.define("sort", .{ .ty = &builtin_println_ty, .is_mut = false, .kind = .builtin });
        self.define("sort_by", .{ .ty = &builtin_println_ty, .is_mut = false, .kind = .builtin });
        self.define("delete", .{ .ty = &builtin_println_ty, .is_mut = false, .kind = .builtin });
        self.define("channel", .{ .ty = &builtin_println_ty, .is_mut = false, .kind = .builtin });
        self.define("await_all", .{ .ty = &builtin_println_ty, .is_mut = false, .kind = .builtin });

        const io_err_ty = self.create(Type, .{ .named = "IoError" });
        self.define("Eof", .{ .ty = io_err_ty, .is_mut = false, .kind = .variable });
        self.define("Closed", .{ .ty = io_err_ty, .is_mut = false, .kind = .variable });
        self.define("Error", .{ .ty = &builtin_println_ty, .is_mut = false, .kind = .function });
        self.define("Timeout", .{ .ty = io_err_ty, .is_mut = false, .kind = .variable });
    }

    // ---------------------------------------------------------------
    // registration (phase 1: forward declarations)
    // ---------------------------------------------------------------

    fn registerItem(self: *Sema, item: ast.Item) void {
        switch (item.kind) {
            .fn_decl => |decl| {
                const return_ty = if (decl.return_type) |rt| self.resolveType(rt) else &t_void;
                var mut_params: u64 = 0;
                for (decl.params, 0..) |param, i| {
                    if (param.type_expr) |te| {
                        if (te.kind == .pointer and te.kind.pointer.is_mut) {
                            mut_params |= @as(u64, 1) << @intCast(i);
                        }
                    }
                }
                const fn_ty = self.create(Type, .{ .fn_ = .{
                    .param_count = decl.params.len,
                    .return_type = return_ty,
                    .mut_params = mut_params,
                } });
                self.define(decl.name, .{
                    .ty = fn_ty,
                    .is_mut = false,
                    .kind = .function,
                });
            },
            .struct_decl => |decl| {
                self.define(decl.name, .{
                    .ty = self.create(Type, .{ .named = decl.name }),
                    .is_mut = false,
                    .kind = .type_name,
                });
            },
            .enum_decl => |decl| {
                self.define(decl.name, .{
                    .ty = self.create(Type, .{ .named = decl.name }),
                    .is_mut = false,
                    .kind = .type_name,
                });
                for (decl.variants) |v| {
                    if (v.payloads.len > 0) {
                        const variant_fn = self.create(Type, .{ .fn_ = .{
                            .param_count = v.payloads.len,
                            .return_type = self.create(Type, .{ .named = decl.name }),
                        } });
                        self.define(v.name, .{
                            .ty = variant_fn,
                            .is_mut = false,
                            .kind = .function,
                        });
                    } else {
                        self.define(v.name, .{
                            .ty = self.create(Type, .{ .named = decl.name }),
                            .is_mut = false,
                            .kind = .variable,
                        });
                    }
                }
            },
            .trait_decl => |decl| {
                self.define(decl.name, .{
                    .ty = self.create(Type, .{ .named = decl.name }),
                    .is_mut = false,
                    .kind = .type_name,
                });
            },
            .import => |imp| self.registerImport(imp),
            .binding => |b| {
                const ty = if (b.type_expr) |te| self.resolveType(te) else &t_err;
                self.define(b.name, .{
                    .ty = ty,
                    .is_mut = b.is_mut,
                    .kind = .variable,
                });
            },
            .extern_block => |eb| {
                for (eb.funcs) |func| {
                    self.define(func.name, .{
                        .ty = &t_err,
                        .is_mut = false,
                        .kind = .function,
                    });
                }
            },
            .type_alias => |ta| {
                const ty = self.resolveType(ta.type_expr);
                self.define(ta.name, .{
                    .ty = ty,
                    .is_mut = false,
                    .kind = .type_name,
                });
            },
        }
    }

    fn registerImport(self: *Sema, imp: ast.Import) void {
        if (stdlib.findModule(imp.path)) |std_mod| {
            self.registerStdImport(imp, std_mod);
            return;
        }

        const loader = self.module_loader orelse return;
        const mod = loader.load(imp.path, self.module_dir) orelse return;

        if (imp.items.len > 0) {
            for (mod.tree.items) |item| {
                switch (item.kind) {
                    .fn_decl => |decl| {
                        if (!decl.is_pub) continue;
                        for (imp.items) |wanted| {
                            if (std.mem.eql(u8, decl.name, wanted)) {
                                self.registerItem(item);
                                break;
                            }
                        }
                    },
                    .struct_decl => |decl| {
                        if (!decl.is_pub) continue;
                        for (imp.items) |wanted| {
                            if (std.mem.eql(u8, decl.name, wanted)) {
                                self.registerItem(item);
                                break;
                            }
                        }
                    },
                    .enum_decl => |decl| {
                        if (!decl.is_pub) continue;
                        for (imp.items) |wanted| {
                            if (std.mem.eql(u8, decl.name, wanted)) {
                                self.registerItem(item);
                                break;
                            }
                        }
                    },
                    else => {},
                }
            }
        } else {
            const ns_name = imp.alias orelse imp.path[imp.path.len - 1];
            self.define(ns_name, .{
                .ty = &t_err,
                .is_mut = false,
                .kind = .variable,
            });
        }
    }

    fn registerStdImport(self: *Sema, imp: ast.Import, std_mod: *const stdlib.StdModule) void {
        if (imp.items.len > 0) {
            for (std_mod.functions) |def| {
                for (imp.items) |wanted| {
                    if (std.mem.eql(u8, def.name, wanted)) {
                        self.define(def.name, .{
                            .ty = &t_err,
                            .is_mut = false,
                            .kind = .function,
                        });
                        break;
                    }
                }
            }
        } else {
            const ns_name = imp.alias orelse imp.path[imp.path.len - 1];
            self.define(ns_name, .{
                .ty = &t_err,
                .is_mut = false,
                .kind = .variable,
            });
        }
    }

    // ---------------------------------------------------------------
    // analysis (phase 2: type checking)
    // ---------------------------------------------------------------

    fn analyzeItem(self: *Sema, item: ast.Item) void {
        switch (item.kind) {
            .fn_decl => |decl| self.analyzeFnDecl(decl, item.span),
            .struct_decl => |decl| self.analyzeStructDecl(decl),
            .enum_decl => {},
            .trait_decl => {},
            .import => {},
            .binding => |b| self.analyzeBinding(b, item.span),
            .extern_block => {},
            .type_alias => {},
        }
    }

    fn analyzeFnDecl(self: *Sema, decl: ast.FnDecl, span: ast.Span) void {
        const return_ty = if (decl.return_type) |rt| self.resolveType(rt) else &t_void;
        const prev_return = self.fn_return_type;
        self.fn_return_type = return_ty;
        defer self.fn_return_type = prev_return;

        self.pushScope();
        defer self.popScope();

        for (decl.params) |param| {
            if (self.scope.lookup(param.name)) |existing| {
                if (existing.kind == .builtin) {
                    self.emitError(span, "'{s}' shadows a builtin function", .{param.name});
                }
            }
            const ty = if (param.type_expr) |te| self.resolveType(te) else &t_err;
            const is_mut_ptr = ty.* == .pointer and ty.pointer.is_mut;
            self.define(param.name, .{
                .ty = ty,
                .is_mut = is_mut_ptr,
                .kind = .parameter,
            });
        }

        switch (decl.body) {
            .block => |block| self.analyzeBlock(block),
            .expr => |expr| self.analyzeExpr(expr),
            .none => {},
        }
    }

    fn analyzeStructDecl(self: *Sema, decl: ast.StructDecl) void {
        for (decl.fields) |field| {
            _ = self.resolveType(field.type_expr);
        }
    }

    fn analyzeBlock(self: *Sema, block: *const ast.Block) void {
        self.pushScope();
        defer self.popScope();

        for (block.stmts) |stmt| {
            self.analyzeStmt(stmt);
        }
        if (block.trailing) |expr| {
            self.analyzeExpr(expr);
        }
    }

    fn analyzeStmt(self: *Sema, stmt: ast.Stmt) void {
        switch (stmt.kind) {
            .binding => |b| self.analyzeBinding(b, stmt.span),
            .assign => |a| {
                self.checkLvalue(a.target);
                self.analyzeExpr(a.target);
                self.analyzeExpr(a.value);
            },
            .compound_assign => |ca| {
                self.checkMutableTarget(ca.target, stmt.span);
                self.analyzeExpr(ca.target);
                self.analyzeExpr(ca.value);
            },
            .ret => |r| {
                if (r.value) |val| self.analyzeExpr(val);
            },
            .fail => |f| {
                self.analyzeExpr(f.value);
            },
            .for_loop => |fl| {
                self.analyzeExpr(fl.iterator);
                if (self.scope.lookup(fl.binding)) |existing| {
                    if (existing.kind == .builtin) {
                        self.emitError(stmt.span, "'{s}' shadows a builtin function", .{fl.binding});
                    }
                }
                self.pushScope();
                self.define(fl.binding, .{
                    .ty = &t_err,
                    .is_mut = false,
                    .kind = .variable,
                });
                self.analyzeBlock(fl.body);
                self.popScope();
            },
            .while_loop => |wl| {
                self.analyzeExpr(wl.condition);
                self.analyzeBlock(wl.body);
            },
            .arena_block => |blk| {
                self.analyzeBlock(blk);
            },
            .defer_stmt => |d| {
                switch (d.body) {
                    .expr => |expr| self.analyzeExpr(expr),
                    .block => |blk| self.analyzeBlock(blk),
                }
            },
            .break_stmt, .continue_stmt => {},
            .expr_stmt => |expr| self.analyzeExpr(expr),
        }
    }

    fn analyzeBinding(self: *Sema, binding: ast.Binding, span: ast.Span) void {
        self.analyzeExpr(binding.value);

        if (self.scope.lookup(binding.name)) |existing| {
            if (existing.kind == .builtin) {
                self.emitError(span, "'{s}' shadows a builtin function", .{binding.name});
                return;
            }
            if (existing.is_mut) return;
        }

        if (self.scope.lookupLocal(binding.name)) |_| {
            self.emitError(span, "redefinition of '{s}'", .{binding.name});
            return;
        }

        const ty = if (binding.type_expr) |te| self.resolveType(te) else &t_err;
        self.define(binding.name, .{
            .ty = ty,
            .is_mut = binding.is_mut,
            .kind = .variable,
        });
    }

    fn analyzeExpr(self: *Sema, expr: *const ast.Expr) void {
        switch (expr.kind) {
            .int_literal, .float_literal, .string_literal, .bool_literal, .none_literal => {},
            .string_interp => |si| {
                for (si.parts) |part| {
                    switch (part) {
                        .literal => {},
                        .expr => |e| self.analyzeExpr(e),
                    }
                }
            },
            .identifier => |name| {
                if (self.resolve(name) == null) {
                    self.emitError(expr.span, "undefined name '{s}'", .{name});
                }
            },
            .binary => |bin| {
                self.analyzeExpr(bin.lhs);
                self.analyzeExpr(bin.rhs);
            },
            .unary => |un| {
                self.analyzeExpr(un.operand);
                if (un.op == .addr_mut) {
                    if (un.operand.kind == .identifier) {
                        const name = un.operand.kind.identifier;
                        if (self.resolve(name)) |sym| {
                            if (!sym.is_mut) {
                                self.emitError(expr.span, "cannot take mutable reference of immutable variable '{s}'", .{name});
                            }
                        }
                    }
                }
            },
            .field_access => |fa| self.analyzeExpr(fa.target),
            .call => |call| {
                self.analyzeExpr(call.callee);
                for (call.args) |arg| self.analyzeExpr(arg);
                self.checkCallArity(call, expr.span);
                self.checkMutParams(call, expr.span);
            },
            .index => |idx| {
                self.analyzeExpr(idx.target);
                self.analyzeExpr(idx.idx);
            },
            .if_expr => |ie| {
                self.analyzeExpr(ie.condition);
                self.cond_depth += 1;
                self.analyzeBlock(ie.then_block);
                if (ie.else_branch) |eb| switch (eb) {
                    .block => |block| self.analyzeBlock(block),
                    .else_if => |ei| self.analyzeExpr(ei),
                };
                self.cond_depth -= 1;
            },
            .match_expr => |me| {
                self.analyzeExpr(me.subject);
                self.cond_depth += 1;
                for (me.arms) |arm| {
                    self.pushScope();
                    self.bindPattern(arm.pattern);
                    if (arm.guard) |g| self.analyzeExpr(g);
                    self.analyzeExpr(arm.body);
                    self.popScope();
                }
                self.cond_depth -= 1;
            },
            .block => |block| self.analyzeBlock(block),
            .closure => |cl| {
                self.pushScope();
                for (cl.params) |param| {
                    if (self.scope.lookup(param.name)) |existing| {
                        if (existing.kind == .builtin) {
                            self.emitError(expr.span, "'{s}' shadows a builtin function", .{param.name});
                        }
                    }
                    self.define(param.name, .{
                        .ty = if (param.type_expr) |te| self.resolveType(te) else &t_err,
                        .is_mut = false,
                        .kind = .parameter,
                    });
                }
                switch (cl.body) {
                    .block => |block| self.analyzeBlock(block),
                    .expr => |e| self.analyzeExpr(e),
                }
                self.popScope();
            },
            .spawn => |inner| self.analyzeExpr(inner),
            .struct_literal => |sl| {
                if (self.resolve(sl.name) == null) {
                    self.emitError(expr.span, "undefined type '{s}'", .{sl.name});
                }
                for (sl.fields) |field| self.analyzeExpr(field.value);
            },
            .pipeline => |pl| {
                for (pl.stages) |stage| self.analyzeExpr(stage);
            },
            .array_literal => |elems| {
                for (elems) |elem| self.analyzeExpr(elem);
            },
            .map_literal => |entries| {
                for (entries) |entry| {
                    self.analyzeExpr(entry.key);
                    self.analyzeExpr(entry.value);
                }
            },
            .try_unwrap => |inner| self.analyzeExpr(inner),
            .or_expr => |oe| {
                self.analyzeExpr(oe.lhs);
                if (oe.err_binding) |binding_name| {
                    self.pushScope();
                    self.define(binding_name, .{
                        .ty = &t_err,
                        .is_mut = false,
                        .kind = .variable,
                    });
                    self.analyzeExpr(oe.rhs);
                    self.popScope();
                } else {
                    self.analyzeExpr(oe.rhs);
                }
            },
            .unwrap_crash => |inner| self.analyzeExpr(inner),
        }
    }

    fn bindPattern(self: *Sema, pattern: ast.Pattern) void {
        switch (pattern.kind) {
            .identifier => |name| {
                self.define(name, .{
                    .ty = &t_err,
                    .is_mut = false,
                    .kind = .variable,
                });
            },
            .variant => |v| {
                for (v.bindings) |binding| {
                    self.define(binding, .{
                        .ty = &t_err,
                        .is_mut = false,
                        .kind = .variable,
                    });
                }
            },
            .literal, .wildcard => {},
        }
    }

    // ---------------------------------------------------------------
    // type resolution
    // ---------------------------------------------------------------

    fn resolveType(self: *Sema, type_expr: *const ast.TypeExpr) *const Type {
        return switch (type_expr.kind) {
            .named => |name| blk: {
                const builtin = resolveNamedType(name);
                if (builtin.* != .err) break :blk builtin;
                if (self.resolve(name)) |sym| {
                    if (sym.kind == .type_name) break :blk sym.ty;
                }
                break :blk self.create(Type, .{ .named = name });
            },
            .generic => |g| self.create(Type, .{ .named = g.name }),
            .optional => |inner| self.create(Type, .{ .optional = self.resolveType(inner) }),
            .result => |r| self.create(Type, .{ .optional = self.resolveType(r.ok_type) }),
            .pointer => |p| self.create(Type, .{ .pointer = .{
                .pointee = self.resolveType(p.pointee),
                .is_mut = p.is_mut,
            } }),
            .slice => |inner| self.create(Type, .{ .slice = self.resolveType(inner) }),
            .fn_type => |ft| self.create(Type, .{ .fn_ = .{
                .param_count = ft.param_types.len,
                .return_type = if (ft.return_type) |rt| self.resolveType(rt) else &t_void,
            } }),
        };
    }

    fn resolveNamedType(name: []const u8) *const Type {
        if (std.mem.eql(u8, name, "int")) return &t_int;
        if (std.mem.eql(u8, name, "float")) return &t_float;
        if (std.mem.eql(u8, name, "str")) return &t_str;
        if (std.mem.eql(u8, name, "bool")) return &t_bool;
        if (std.mem.eql(u8, name, "byte")) return &t_byte;
        if (std.mem.eql(u8, name, "u8")) return &t_u8;
        if (std.mem.eql(u8, name, "u16")) return &t_u16;
        if (std.mem.eql(u8, name, "u32")) return &t_u32;
        if (std.mem.eql(u8, name, "u64")) return &t_u64;
        if (std.mem.eql(u8, name, "i8")) return &t_i8;
        if (std.mem.eql(u8, name, "i16")) return &t_i16;
        if (std.mem.eql(u8, name, "i32")) return &t_i32;
        if (std.mem.eql(u8, name, "i64")) return &t_i64;
        if (std.mem.eql(u8, name, "f32")) return &t_f32;
        if (std.mem.eql(u8, name, "f64")) return &t_f64;
        if (std.mem.eql(u8, name, "usize")) return &t_usize;
        if (std.mem.eql(u8, name, "isize")) return &t_isize;
        if (std.mem.eql(u8, name, "void")) return &t_void;
        return &t_err;
    }

    // ---------------------------------------------------------------
    // checks
    // ---------------------------------------------------------------

    fn checkCallArity(self: *Sema, call: ast.Call, span: ast.Span) void {
        if (call.callee.kind != .identifier) return;
        const name = call.callee.kind.identifier;
        const sym = self.resolve(name) orelse return;
        if (sym.ty.* != .fn_) return;
        const fn_ty = sym.ty.fn_;
        if (fn_ty.param_count == 255) return;
        if (call.args.len != fn_ty.param_count) {
            self.emitError(span, "'{s}' expects {d} argument(s), got {d}", .{
                name, fn_ty.param_count, call.args.len,
            });
        }
    }

    fn checkMutParams(self: *Sema, call: ast.Call, span: ast.Span) void {
        if (call.callee.kind != .identifier) return;
        const name = call.callee.kind.identifier;
        const sym = self.resolve(name) orelse return;
        if (sym.ty.* != .fn_) return;
        const fn_ty = sym.ty.fn_;

        for (call.args, 0..) |arg, i| {
            if (i >= 64) break;
            const needs_mut = (fn_ty.mut_params & (@as(u64, 1) << @intCast(i))) != 0;
            if (needs_mut) {
                const is_addr_mut = arg.kind == .unary and arg.kind.unary.op == .addr_mut;
                if (!is_addr_mut) {
                    self.emitError(span, "argument {d} to '{s}' requires &mut (parameter is *mut)", .{ i + 1, name });
                }
            } else {
                if (arg.kind == .unary and arg.kind.unary.op == .addr_mut) {
                    self.emitError(span, "argument {d} to '{s}' passed as &mut but parameter is not *mut", .{ i + 1, name });
                }
            }
        }
    }

    fn checkLvalue(self: *Sema, expr: *const ast.Expr) void {
        switch (expr.kind) {
            .field_access => |fa| {
                const root = self.findRoot(fa.target);
                if (root) |name| {
                    if (self.resolve(name)) |sym| {
                        if (!sym.is_mut) {
                            if (sym.kind == .parameter) {
                                self.emitError(expr.span, "cannot mutate field on immutable parameter '{s}'. use *mut in the type annotation", .{name});
                            } else {
                                self.emitError(expr.span, "cannot mutate field on immutable variable '{s}'", .{name});
                            }
                        }
                    }
                }
            },
            .index => {},
            .identifier => |name| {
                if (self.resolve(name)) |sym| {
                    if (!sym.is_mut) {
                        self.emitError(expr.span, "cannot assign to immutable variable '{s}'", .{name});
                    }
                }
            },
            else => self.emitError(expr.span, "invalid assignment target", .{}),
        }
    }

    fn findRoot(self: *Sema, expr: *const ast.Expr) ?[]const u8 {
        _ = self;
        var current = expr;
        while (true) {
            switch (current.kind) {
                .identifier => |name| return name,
                .field_access => |fa| current = fa.target,
                .index => |idx| current = idx.target,
                else => return null,
            }
        }
    }

    fn checkMutableTarget(self: *Sema, expr: *const ast.Expr, span: ast.Span) void {
        if (expr.kind == .identifier) {
            const name = expr.kind.identifier;
            if (self.resolve(name)) |sym| {
                if (!sym.is_mut) {
                    self.emitError(span, "cannot use compound assignment on immutable variable '{s}'", .{name});
                }
            }
        } else if (expr.kind == .field_access) {
            const root = self.findRoot(expr);
            if (root) |name| {
                if (self.resolve(name)) |sym| {
                    if (!sym.is_mut) {
                        if (sym.kind == .parameter) {
                            self.emitError(span, "cannot mutate field on immutable parameter '{s}'. use *mut in the type annotation", .{name});
                        } else {
                            self.emitError(span, "cannot mutate field on immutable variable '{s}'", .{name});
                        }
                    }
                }
            }
        }
    }

    // ---------------------------------------------------------------
    // scope management
    // ---------------------------------------------------------------

    fn pushScope(self: *Sema) void {
        const new_scope = self.arena.create(Scope) catch @panic("oom");
        new_scope.* = Scope.init();
        new_scope.parent = if (self.scope_stack.items.len > 0) self.scope else null;
        self.scope_stack.append(self.arena, new_scope) catch @panic("oom");
        self.scope = new_scope;
    }

    fn popScope(self: *Sema) void {
        _ = self.scope_stack.pop();
        if (self.scope_stack.items.len > 0) {
            self.scope = self.scope_stack.items[self.scope_stack.items.len - 1];
        }
    }

    fn define(self: *Sema, name: []const u8, sym: Symbol) void {
        self.scope.define(self.arena, name, sym);
    }

    fn resolve(self: *Sema, name: []const u8) ?Symbol {
        return self.scope.lookup(name);
    }

    fn resolvePtr(self: *Sema, name: []const u8) ?*Symbol {
        return self.scope.lookupPtr(name);
    }

    // ---------------------------------------------------------------
    // helpers
    // ---------------------------------------------------------------

    fn create(self: *Sema, comptime T: type, value: T) *const T {
        const ptr = self.arena.create(T) catch @panic("oom");
        ptr.* = value;
        return ptr;
    }

    fn emitError(self: *Sema, span: ast.Span, comptime fmt: []const u8, args: anytype) void {
        const message = std.fmt.allocPrint(self.arena, fmt, args) catch @panic("oom");
        self.errors.append(self.arena, .{ .span = span, .message = message }) catch @panic("oom");
    }
};

// ---------------------------------------------------------------
// tests
// ---------------------------------------------------------------

const parser = @import("parser.zig");

fn testAnalyze(source: []const u8) Analysis {
    var arena_impl = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const arena = arena_impl.allocator();
    const tokens = parser.tokenize(arena, source);
    var p = parser.Parser.init(tokens, source, arena);
    const tree = p.parse();
    if (tree.errors.len > 0) @panic("parse error in test");
    return Sema.analyze(arena, tree);
}

fn expectNoErrors(result: Analysis) !void {
    if (result.errors.len > 0) {
        std.debug.print("sema errors:\n", .{});
        for (result.errors) |err| {
            std.debug.print("  [{d}..{d}] {s}\n", .{ err.span.start, err.span.end, err.message });
        }
        return error.TestUnexpectedResult;
    }
}

fn expectError(result: Analysis, needle: []const u8) !void {
    for (result.errors) |err| {
        if (std.mem.indexOf(u8, err.message, needle) != null) return;
    }
    std.debug.print("expected error containing '{s}', got {d} error(s):\n", .{ needle, result.errors.len });
    for (result.errors) |err| {
        std.debug.print("  {s}\n", .{err.message});
    }
    return error.TestUnexpectedResult;
}

test "sema: clean hello world" {
    const result = testAnalyze("fn main() {\n  println(\"hello\")\n}");
    try expectNoErrors(result);
}

test "sema: function with params" {
    const result = testAnalyze("fn add(a: int, b: int) -> int {\n  a + b\n}");
    try expectNoErrors(result);
}

test "sema: undefined variable" {
    const result = testAnalyze("fn f() {\n  println(x)\n}");
    try expectError(result, "undefined name 'x'");
}

test "sema: forward reference to function" {
    const result = testAnalyze("fn foo() {\n  bar()\n}\nfn bar() {}");
    try expectNoErrors(result);
}

test "sema: struct and field access" {
    const result = testAnalyze(
        \\struct User {
        \\  name: str
        \\}
        \\fn f(u: User) = u.name
    );
    try expectNoErrors(result);
}

test "sema: enum variants in scope" {
    const result = testAnalyze(
        \\enum Color { Red, Green, Blue }
        \\fn f() = Red
    );
    try expectNoErrors(result);
}

test "sema: enum variant constructor" {
    const result = testAnalyze(
        \\enum Shape {
        \\  Circle(float)
        \\  Point
        \\}
        \\fn f() = Circle(5.0)
    );
    try expectNoErrors(result);
}

test "sema: wrong arity" {
    const result = testAnalyze(
        \\fn add(a: int, b: int) -> int = a + b
        \\fn f() = add(1, 2, 3)
    );
    try expectError(result, "expects 2 argument(s), got 3");
}

test "sema: variable binding" {
    const result = testAnalyze("fn f() {\n  x = 5\n  println(x)\n}");
    try expectNoErrors(result);
}

test "sema: mutable binding" {
    const result = testAnalyze("fn f() {\n  mut x = 5\n  x += 1\n}");
    try expectNoErrors(result);
}

test "sema: immutable compound assign" {
    const result = testAnalyze("fn f() {\n  x = 5\n  x += 1\n}");
    try expectError(result, "cannot use compound assignment on immutable");
}

test "sema: redefinition" {
    const result = testAnalyze("fn f() {\n  x = 5\n  x = 10\n}");
    try expectError(result, "redefinition");
}

test "sema: closure params in scope" {
    const result = testAnalyze("fn f() = fn(x) x + 1");
    try expectNoErrors(result);
}

test "sema: for loop binding" {
    const result = testAnalyze("fn f() {\n  for item in items {\n    println(item)\n  }\n}");
    try expectError(result, "undefined name 'items'");
}

test "sema: nested scopes" {
    const result = testAnalyze(
        \\fn f() {
        \\  x = 1
        \\  if true {
        \\    y = 2
        \\    println(x)
        \\    println(y)
        \\  }
        \\}
    );
    try expectNoErrors(result);
}

test "sema: match expression" {
    const result = testAnalyze(
        \\enum Shape {
        \\  Circle(float)
        \\  Point
        \\}
        \\fn f(s: Shape) = match s {
        \\  Circle(r) -> r
        \\  Point -> 0.0
        \\}
    );
    try expectNoErrors(result);
}

test "sema: multiple items" {
    const result = testAnalyze(
        \\struct Point {
        \\  x: float
        \\  y: float
        \\}
        \\fn distance(a: Point, b: Point) -> float {
        \\  dx = a.x - b.x
        \\  dy = a.y - b.y
        \\  sqrt(dx * dx + dy * dy)
        \\}
        \\fn main() {
        \\  p = Point { x: 0.0, y: 0.0 }
        \\  println(distance(p, p))
        \\}
    );
    try expectNoErrors(result);
}

test "sema: immutable param field mutation error" {
    const result = testAnalyze("struct P { x: int }\nfn f(p: P) {\n  p.x = 1\n}");
    try expectError(result, "cannot mutate field on immutable parameter");
}

test "sema: *mut param allows field mutation" {
    const result = testAnalyze("struct P { x: int }\nfn f(p: *mut P) {\n  p.x = 1\n}");
    try expectNoErrors(result);
}

test "sema: &mut requires mut variable" {
    const result = testAnalyze("struct P { x: int }\nfn f(p: *mut P) {\n  p.x = 1\n}\nfn main() {\n  p = P { x: 0 }\n  f(&mut p)\n}");
    try expectError(result, "cannot take mutable reference of immutable variable");
}

test "sema: missing &mut at call site" {
    const result = testAnalyze("struct P { x: int }\nfn f(p: *mut P) {\n  p.x = 1\n}\nfn main() {\n  mut p = P { x: 0 }\n  f(p)\n}");
    try expectError(result, "requires &mut");
}

test "sema: unnecessary &mut at call site" {
    const result = testAnalyze("struct P { x: int }\nfn f(p: P) -> int {\n  p.x\n}\nfn main() {\n  mut p = P { x: 0 }\n  f(&mut p)\n}");
    try expectError(result, "passed as &mut but parameter is not *mut");
}

test "sema: local variable push is ok" {
    const result = testAnalyze(
        \\struct Item { v: int }
        \\fn main() {
        \\  list = []
        \\  item = Item { v: 1 }
        \\  push(list, item)
        \\}
    );
    try expectNoErrors(result);
}

test "sema: builtin shadow in binding" {
    const result = testAnalyze("fn f() {\n  filter = 5\n}");
    try expectError(result, "'filter' shadows a builtin function");
}

test "sema: builtin shadow in fn param" {
    const result = testAnalyze("fn f(map: int) -> int = map + 1");
    try expectError(result, "'map' shadows a builtin function");
}

test "sema: builtin shadow in for loop" {
    const result = testAnalyze("fn f() {\n  for len in [1, 2, 3] {\n    println(len)\n  }\n}");
    try expectError(result, "'len' shadows a builtin function");
}

test "sema: builtin shadow in closure" {
    const result = testAnalyze("fn f() = fn(sort) sort + 1");
    try expectError(result, "'sort' shadows a builtin function");
}

test "sema: non-builtin names are fine" {
    const result = testAnalyze("fn f() {\n  x = 5\n  name = \"hello\"\n  count = 0\n}");
    try expectNoErrors(result);
}
