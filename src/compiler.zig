const std = @import("std");
const ast = @import("ast.zig");
const Chunk = @import("chunk.zig").Chunk;
const OpCode = @import("chunk.zig").OpCode;
const Value = @import("value.zig").Value;
const ObjString = @import("value.zig").ObjString;
const ObjFunction = @import("value.zig").ObjFunction;
const ObjNativeFn = @import("value.zig").ObjNativeFn;
const ModuleLoader = @import("module.zig").ModuleLoader;
const Module = @import("module.zig").Module;
const stdlib = @import("stdlib.zig");
const ffi = @import("ffi.zig");

pub const CompileResult = struct {
    func: *ObjFunction,
    ffi_descs: []ffi.FfiDesc,
};

const VariantInfo = struct {
    type_name: []const u8,
    payload_count: u8,
    variant_index: u8,
};

const TypeHint = enum {
    unknown,
    int_,
    float_,
    string_,
    bool_,
    struct_,
};

pub const Compiler = struct {
    alloc: std.mem.Allocator,
    enclosing: ?*Compiler,
    function: *ObjFunction,
    locals: [256]Local,
    local_count: u8,
    scope_depth: u32,
    struct_defs: std.StringHashMapUnmanaged([]const []const u8),
    enum_variants: std.StringHashMapUnmanaged(VariantInfo),
    fn_table: std.StringHashMapUnmanaged(*ObjFunction),
    fn_returns: std.StringHashMapUnmanaged(TypeHint),
    upvalues: [256]Upvalue,
    upvalue_count: u8,
    module_loader: ?*ModuleLoader,
    module_dir: []const u8,
    module_namespaces: std.StringHashMapUnmanaged(*Module),
    std_modules: std.StringHashMapUnmanaged(*const stdlib.StdModule),
    native_fns: std.StringHashMapUnmanaged(*ObjNativeFn),
    ffi_descs: std.ArrayListUnmanaged(ffi.FfiDesc),
    ffi_funcs: std.StringHashMapUnmanaged(u16),
    source: []const u8,
    current_line: u32,

    pub const Local = struct {
        name: []const u8,
        depth: u32,
        type_hint: TypeHint = .unknown,
    };

    pub const Upvalue = struct {
        index: u8,
        is_local: bool,
    };

    pub fn compile(alloc: std.mem.Allocator, tree: ast.Ast) ?CompileResult {
        return compileModule(alloc, tree, null, ".");
    }

    pub fn compileModule(alloc: std.mem.Allocator, tree: ast.Ast, loader: ?*ModuleLoader, dir: []const u8) ?CompileResult {
        const script = ObjFunction.create(alloc, "", 0);
        script.source = tree.source;
        var compiler = Compiler{
            .alloc = alloc,
            .enclosing = null,
            .function = script,
            .locals = undefined,
            .local_count = 0,
            .scope_depth = 0,
            .struct_defs = .{},
            .enum_variants = .{},
            .fn_table = .{},
            .fn_returns = .{},
            .upvalues = undefined,
            .upvalue_count = 0,
            .module_loader = loader,
            .module_dir = dir,
            .module_namespaces = .{},
            .std_modules = .{},
            .native_fns = .{},
            .ffi_descs = .{},
            .ffi_funcs = .{},
            .source = tree.source,
            .current_line = 1,
        };

        compiler.defineNatives();

        for (tree.items) |item| {
            compiler.registerDecl(item);
        }

        for (tree.items) |item| {
            compiler.compileItem(item);
        }

        compiler.emitCall("main", 0);
        compiler.emitOp(.nil);
        compiler.emitOp(.return_);

        return .{
            .func = script,
            .ffi_descs = compiler.ffi_descs.toOwnedSlice(alloc) catch &.{},
        };
    }

    fn defineNatives(self: *Compiler) void {
        self.defineNativeFn("sqrt", 1, &nativeSqrt);
        self.defineNativeFn("abs", 1, &nativeAbs);
        self.defineNativeFn("int", 1, &nativeInt);
        self.defineNativeFn("float", 1, &nativeFloat);
        self.defineNativeFn("len", 1, &nativeLen);
        self.defineNativeFn("push", 2, &nativePush);
        self.defineNativeFn("assert", 1, &nativeAssert);
        self.defineNativeFn("assert_eq", 2, &nativeAssertEq);

        self.registerBuiltinEnum("IoError", &.{
            .{ .name = "Eof", .payloads = 0 },
            .{ .name = "Closed", .payloads = 0 },
            .{ .name = "Error", .payloads = 1 },
            .{ .name = "Timeout", .payloads = 0 },
        });
    }

    const BuiltinVariant = struct { name: []const u8, payloads: u8 };

    fn registerBuiltinEnum(self: *Compiler, type_name: []const u8, variants: []const BuiltinVariant) void {
        for (variants, 0..) |v, i| {
            self.enum_variants.put(self.alloc, v.name, .{
                .type_name = type_name,
                .payload_count = v.payloads,
                .variant_index = @intCast(i),
            }) catch @panic("oom");
        }
    }

    fn defineNativeFn(self: *Compiler, name: []const u8, arity: u8, func: *const fn (std.mem.Allocator, []const Value) Value) void {
        const nf = ObjNativeFn.create(self.alloc, name, arity, func);
        self.emitConstant(nf.toValue());
        const name_idx = self.addStringConstant(name);
        self.emitOp(.define_global);
        self.emitU16(name_idx);
    }

    fn nativeSqrt(_: std.mem.Allocator, args: []const Value) Value {
        const v = args[0];
        const f: f64 = if (v.tag == .float) v.asFloat() else if (v.tag == .int) @floatFromInt(v.asInt()) else 0.0;
        return Value.initFloat(@sqrt(f));
    }

    fn nativeAbs(_: std.mem.Allocator, args: []const Value) Value {
        const v = args[0];
        if (v.tag == .int) {
            const i = v.asInt();
            return Value.initInt(if (i < 0) -i else i);
        }
        if (v.tag == .float) return Value.initFloat(@abs(v.asFloat()));
        return Value.initInt(0);
    }

    fn nativeInt(_: std.mem.Allocator, args: []const Value) Value {
        const v = args[0];
        if (v.tag == .int) return v;
        if (v.tag == .float) return Value.initInt(@intFromFloat(v.asFloat()));
        if (v.tag == .bool_) return Value.initInt(@intFromBool(v.asBool()));
        return Value.initInt(0);
    }

    fn nativeFloat(_: std.mem.Allocator, args: []const Value) Value {
        const v = args[0];
        if (v.tag == .float) return v;
        if (v.tag == .int) return Value.initFloat(@floatFromInt(v.asInt()));
        return Value.initFloat(0.0);
    }

    fn nativeLen(_: std.mem.Allocator, args: []const Value) Value {
        const v = args[0];
        if (v.tag == .string) return Value.initInt(@intCast(v.asString().chars.len));
        if (v.tag == .array) return Value.initInt(@intCast(v.asArray().items.len));
        return Value.initInt(0);
    }

    fn nativePush(alloc: std.mem.Allocator, args: []const Value) Value {
        if (args[0].tag == .array) {
            args[0].asArray().push(alloc, args[1]);
        }
        return Value.initNil();
    }

    fn nativeAssert(_: std.mem.Allocator, args: []const Value) Value {
        if (!args[0].isTruthy()) {
            std.debug.print("assertion failed\n", .{});
            std.process.exit(1);
        }
        return Value.initNil();
    }

    fn nativeAssertEq(_: std.mem.Allocator, args: []const Value) Value {
        if (!Value.eql(args[0], args[1])) {
            std.debug.print("assertion failed: ", .{});
            args[0].dump();
            std.debug.print(" != ", .{});
            args[1].dump();
            std.debug.print("\n", .{});
            std.process.exit(1);
        }
        return Value.initNil();
    }

    // ---------------------------------------------------------------
    // declaration registration (first pass)
    // ---------------------------------------------------------------

    fn registerDecl(self: *Compiler, item: ast.Item) void {
        switch (item.kind) {
            .fn_decl => |decl| {
                const func = ObjFunction.create(self.alloc, decl.name, @intCast(decl.params.len));
                self.fn_table.put(self.alloc, decl.name, func) catch @panic("oom");
                const ret = typeHintFromExpr(decl.return_type);
                if (ret != .unknown) {
                    self.fn_returns.put(self.alloc, decl.name, ret) catch @panic("oom");
                }
            },
            .struct_decl => |decl| {
                const names = self.alloc.alloc([]const u8, decl.fields.len) catch @panic("oom");
                for (decl.fields, 0..) |field, i| {
                    names[i] = field.name;
                }
                self.struct_defs.put(self.alloc, decl.name, names) catch @panic("oom");
            },
            .enum_decl => |decl| {
                for (decl.variants, 0..) |variant, vi| {
                    self.enum_variants.put(self.alloc, variant.name, .{
                        .type_name = decl.name,
                        .payload_count = @intCast(variant.payloads.len),
                        .variant_index = @intCast(vi),
                    }) catch @panic("oom");
                }
            },
            .import => |imp| self.registerImport(imp),
            .extern_block => |eb| self.registerExternBlock(eb),
            else => {},
        }
    }

    fn registerExternBlock(self: *Compiler, eb: ast.ExternBlock) void {
        for (eb.funcs) |func| {
            const idx: u16 = @intCast(self.ffi_descs.items.len);

            // ensure null-terminated symbol name
            const name_z = self.alloc.allocSentinel(u8, func.name.len, 0) catch @panic("oom");
            @memcpy(name_z, func.name);

            self.ffi_descs.append(self.alloc, .{
                .lib = eb.lib,
                .name = name_z,
                .params = func.params,
                .ret = func.ret,
            }) catch @panic("oom");
            self.ffi_funcs.put(self.alloc, func.name, idx) catch @panic("oom");
        }
    }

    fn registerImport(self: *Compiler, imp: ast.Import) void {
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
                                self.registerDecl(item);
                                break;
                            }
                        }
                    },
                    .struct_decl => |decl| {
                        if (!decl.is_pub) continue;
                        for (imp.items) |wanted| {
                            if (std.mem.eql(u8, decl.name, wanted)) {
                                self.registerDecl(item);
                                break;
                            }
                        }
                    },
                    .enum_decl => |decl| {
                        if (!decl.is_pub) continue;
                        for (imp.items) |wanted| {
                            if (std.mem.eql(u8, decl.name, wanted)) {
                                self.registerDecl(item);
                                break;
                            }
                        }
                    },
                    else => {},
                }
            }
        } else {
            const ns_name = imp.alias orelse imp.path[imp.path.len - 1];
            self.module_namespaces.put(self.alloc, ns_name, mod) catch @panic("oom");

            for (mod.tree.items) |item| {
                switch (item.kind) {
                    .fn_decl => |decl| {
                        if (decl.is_pub) self.registerDecl(item);
                    },
                    .struct_decl => |decl| {
                        if (decl.is_pub) self.registerDecl(item);
                    },
                    .enum_decl => |decl| {
                        if (decl.is_pub) self.registerDecl(item);
                    },
                    else => {},
                }
            }
        }
    }

    fn registerStdImport(self: *Compiler, imp: ast.Import, std_mod: *const stdlib.StdModule) void {
        if (imp.items.len > 0) {
            for (std_mod.functions) |def| {
                var wanted = false;
                for (imp.items) |name| {
                    if (std.mem.eql(u8, def.name, name)) {
                        wanted = true;
                        break;
                    }
                }
                if (!wanted) continue;
                const nf = ObjNativeFn.create(self.alloc, def.name, def.arity, def.func);
                self.native_fns.put(self.alloc, def.name, nf) catch @panic("oom");
            }
        } else {
            const ns_name = imp.alias orelse imp.path[imp.path.len - 1];
            self.std_modules.put(self.alloc, ns_name, std_mod) catch @panic("oom");
        }
    }

    // ---------------------------------------------------------------
    // items
    // ---------------------------------------------------------------

    fn compileItem(self: *Compiler, item: ast.Item) void {
        self.setSpan(item.span);
        switch (item.kind) {
            .fn_decl => |decl| self.compileFnDecl(decl),
            .binding => |b| self.compileTopBinding(b),
            .struct_decl, .enum_decl, .trait_decl => {},
            .import => |imp| self.compileImport(imp),
            .extern_block => {},
        }
    }

    fn compileImport(self: *Compiler, imp: ast.Import) void {
        if (stdlib.findModule(imp.path) != null) {
            self.compileStdImport(imp);
            return;
        }

        const loader = self.module_loader orelse return;
        const mod = loader.load(imp.path, self.module_dir) orelse return;
        for (mod.tree.items) |item| {
            switch (item.kind) {
                .fn_decl => |decl| {
                    if (!decl.is_pub) continue;
                    if (imp.items.len > 0) {
                        var wanted = false;
                        for (imp.items) |name| {
                            if (std.mem.eql(u8, decl.name, name)) {
                                wanted = true;
                                break;
                            }
                        }
                        if (!wanted) continue;
                    }
                    self.compileFnDecl(decl);
                },
                else => {},
            }
        }
    }

    fn compileStdImport(self: *Compiler, imp: ast.Import) void {
        if (imp.items.len == 0) return;
        const std_mod = stdlib.findModule(imp.path) orelse return;
        _ = std_mod;
        for (imp.items) |name| {
            const nf = self.native_fns.get(name) orelse continue;
            self.emitConstant(nf.toValue());
            const name_idx = self.addStringConstant(name);
            self.emitOp(.define_global);
            self.emitU16(name_idx);
        }
    }

    fn compileFnDecl(self: *Compiler, decl: ast.FnDecl) void {
        const func = self.findFunction(decl.name) orelse ObjFunction.create(self.alloc, decl.name, @intCast(decl.params.len));
        func.source = self.source;

        var sub = Compiler{
            .alloc = self.alloc,
            .enclosing = self,
            .function = func,
            .locals = undefined,
            .local_count = 0,
            .scope_depth = 1,
            .struct_defs = .{},
            .enum_variants = .{},
            .fn_table = .{},
            .fn_returns = .{},
            .upvalues = undefined,
            .upvalue_count = 0,
            .module_loader = self.module_loader,
            .module_dir = self.module_dir,
            .module_namespaces = .{},
            .std_modules = .{},
            .native_fns = .{},
            .ffi_descs = .{},
            .ffi_funcs = .{},
            .source = self.source,
            .current_line = self.current_line,
        };
        sub.addLocal("");

        for (decl.params) |param| {
            sub.addLocalTyped(param.name, sub.resolveTypeHint(param.type_expr));
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

        func.locals_only = analyzeLocalsOnly(&func.chunk);

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
        self.setSpan(stmt.span);
        switch (stmt.kind) {
            .binding => |b| {
                if (self.scope_depth > 0) {
                    if (self.resolveLocal(b.name)) |slot| {
                        if (self.isConcatPattern(b.name, b.value)) {
                            self.compileConcatRhs(b.value);
                            self.emitOp(.concat_local);
                            self.emitByte(slot);
                        } else {
                            self.compileExpr(b.value);
                            self.emitOp(.set_local);
                            self.emitByte(slot);
                            self.emitOp(.pop);
                        }
                    } else if (self.resolveUpvalue(b.name)) |uv| {
                        self.compileExpr(b.value);
                        self.emitOp(.set_upvalue);
                        self.emitByte(uv);
                        self.emitOp(.pop);
                    } else {
                        const hint = self.exprType(b.value);
                        self.compileExpr(b.value);
                        self.addLocalTyped(b.name, hint);
                    }
                } else {
                    self.compileExpr(b.value);
                    const name_idx = self.addStringConstant(b.name);
                    self.emitOp(.define_global);
                    self.emitU16(name_idx);
                }
            },
            .assign => |a| {
                self.compileExpr(a.value);
                self.compileSetTarget(a.target);
                self.emitOp(.pop);
            },
            .compound_assign => |ca| self.compileCompoundAssign(ca),
            .ret => |r| {
                if (r.value) |val| {
                    self.compileExpr(val);
                } else {
                    self.emitOp(.nil);
                }
                self.emitOp(.return_);
            },
            .for_loop => |fl| self.compileForLoop(fl),
            .while_loop => |wl| {
                const loop_start = self.chunk().count();
                self.compileExpr(wl.condition);
                const exit_jump = self.emitJump(.jump_if_false);
                self.emitOp(.pop);
                self.beginScope();
                for (wl.body.stmts) |s| self.compileStmt(s);
                if (wl.body.trailing) |te| {
                    self.compileExpr(te);
                    self.emitOp(.pop);
                }
                self.endScope();
                self.emitLoop(loop_start);
                self.patchJump(exit_jump);
                self.emitOp(.pop);
            },
            .arena_block => |blk| {
                self.emitOp(.push_arena);
                self.compileBlock(blk);
                self.emitOp(.pop_arena);
            },
            .expr_stmt => |expr| {
                self.compileExpr(expr);
                self.emitOp(.pop);
            },
        }
    }

    fn compileCompoundAssign(self: *Compiler, ca: ast.CompoundAssign) void {
        if (ca.op == .plus_eq and ca.target.kind == .identifier) {
            if (self.resolveLocal(ca.target.kind.identifier)) |slot| {
                self.compileExpr(ca.value);
                self.emitOp(.concat_local);
                self.emitByte(slot);
                return;
            }
        }
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
        self.emitOp(.pop);
    }

    fn isConcatPattern(self: *Compiler, name: []const u8, value: *const ast.Expr) bool {
        if (value.kind != .binary) return false;
        const bin = value.kind.binary;
        if (bin.op != .plus) return false;
        if (bin.lhs.kind != .identifier) return false;
        return std.mem.eql(u8, bin.lhs.kind.identifier, name) and self.resolveLocal(name) != null;
    }

    fn compileConcatRhs(self: *Compiler, value: *const ast.Expr) void {
        self.compileExpr(value.kind.binary.rhs);
    }

    fn compileForLoop(self: *Compiler, fl: ast.ForLoop) void {
        const range_args = detectRange(fl.iterator);
        if (range_args) |args| {
            self.compileForRange(fl.binding, args, fl.body);
        } else {
            self.compileForIn(fl.binding, fl.iterator, fl.body);
        }
    }

    fn compileForIn(self: *Compiler, binding: []const u8, iterator: *const ast.Expr, body: *const ast.Block) void {
        self.beginScope();

        self.compileExpr(iterator);
        self.addLocal("$iter");

        // cache length once to avoid get_field("len") string comparison per iteration
        self.emitOp(.get_local);
        self.emitByte(self.resolveLocal("$iter").?);
        self.emitOp(.get_field);
        self.emitU16(self.addStringConstant("len"));
        self.addLocalTyped("$len", .int_);

        self.emitConstant(Value.initInt(0));
        self.addLocalTyped("$idx", .int_);

        const loop_start = self.chunk().count();

        const idx_slot = self.resolveLocal("$idx").?;
        const iter_slot = self.resolveLocal("$iter").?;
        const len_slot = self.resolveLocal("$len").?;

        self.emitOp(.get_local);
        self.emitByte(idx_slot);
        self.emitOp(.get_local);
        self.emitByte(len_slot);
        self.emitOp(.less_int);
        const exit_jump = self.emitJump(.jump_if_false);
        self.emitOp(.pop);

        self.beginScope();
        self.emitOp(.get_local);
        self.emitByte(iter_slot);
        self.emitOp(.get_local);
        self.emitByte(idx_slot);
        self.emitOp(.index_get);
        self.addLocal(binding);

        for (body.stmts) |s| self.compileStmt(s);
        if (body.trailing) |expr| {
            self.compileExpr(expr);
            self.emitOp(.pop);
        }
        self.endScope();

        self.emitOp(.get_local);
        self.emitByte(idx_slot);
        self.emitConstant(Value.initInt(1));
        self.emitOp(.add_int);
        self.emitOp(.set_local);
        self.emitByte(idx_slot);
        self.emitOp(.pop);

        self.emitLoop(loop_start);
        self.patchJump(exit_jump);
        self.emitOp(.pop);

        self.endScope();
    }

    fn compileForRange(self: *Compiler, binding: []const u8, args: RangeArgs, body: *const ast.Block) void {
        self.beginScope();

        if (args.start) |start| {
            self.compileExpr(start);
        } else {
            self.emitConstant(Value.initInt(0));
        }
        self.addLocalTyped("$counter", .int_);

        const counter_idx = self.local_count - 1;
        const counter_slot = self.resolveLocal("$counter").?;

        const loop_start = self.chunk().count();

        self.emitOp(.get_local);
        self.emitByte(counter_slot);
        self.compileExpr(args.end);
        self.emitOp(.less_int);
        const exit_jump = self.emitJump(.jump_if_false);
        self.emitOp(.pop);

        self.locals[counter_idx].name = binding;

        self.beginScope();
        for (body.stmts) |s| {
            self.compileStmt(s);
        }
        if (body.trailing) |expr| {
            self.compileExpr(expr);
            self.emitOp(.pop);
        }
        self.endScope();

        self.locals[counter_idx].name = "$counter";
        if (args.step == null) {
            self.emitOp(.inc_local);
            self.emitByte(counter_slot);
        } else {
            self.emitOp(.get_local);
            self.emitByte(counter_slot);
            self.compileExpr(args.step.?);
            self.emitOp(.add_int);
            self.emitOp(.set_local);
            self.emitByte(counter_slot);
            self.emitOp(.pop);
        }

        self.emitLoop(loop_start);
        self.patchJump(exit_jump);
        self.emitOp(.pop);

        self.endScope();
    }

    const RangeArgs = struct {
        start: ?*const ast.Expr,
        end: *const ast.Expr,
        step: ?*const ast.Expr,
    };

    fn detectRange(expr: *const ast.Expr) ?RangeArgs {
        if (expr.kind != .call) return null;
        const call = expr.kind.call;
        if (call.callee.kind != .identifier) return null;
        if (!std.mem.eql(u8, call.callee.kind.identifier, "range")) return null;
        if (call.args.len == 1) return .{ .start = null, .end = call.args[0], .step = null };
        if (call.args.len == 2) return .{ .start = call.args[0], .end = call.args[1], .step = null };
        if (call.args.len == 3) return .{ .start = call.args[0], .end = call.args[1], .step = call.args[2] };
        return null;
    }

    // ---------------------------------------------------------------
    // expressions
    // ---------------------------------------------------------------

    fn compileExpr(self: *Compiler, expr: *const ast.Expr) void {
        self.setSpan(expr.span);
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
                const str = ObjString.create(self.alloc, self.processEscapes(inner));
                self.emitConstant(str.toValue());
            },
            .string_interp => |si| self.compileStringInterp(si),
            .bool_literal => |val| self.emitOp(if (val) .true_ else .false_),
            .none_literal => self.emitOp(.nil),
            .identifier => |name| self.compileIdentifier(name),
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
                if (fa.target.kind == .identifier) {
                    if (self.resolveModuleValue(fa.target.kind.identifier, fa.field)) |val| {
                        self.emitConstant(val);
                        return;
                    }
                }
                if (self.resolveFieldIndex(fa.field)) |field_idx| {
                    if (fa.target.kind == .identifier) {
                        if (self.resolveLocal(fa.target.kind.identifier)) |slot| {
                            if (self.localTypeHint(fa.target.kind.identifier) == .struct_) {
                                self.emitOp(.get_local_field);
                                self.emitByte(slot);
                                self.emitByte(field_idx);
                            } else {
                                self.emitOp(.get_local);
                                self.emitByte(slot);
                                self.emitOp(.get_field_idx);
                                self.emitByte(field_idx);
                            }
                        } else {
                            self.compileExpr(fa.target);
                            self.emitOp(.get_field_idx);
                            self.emitByte(field_idx);
                        }
                    } else {
                        self.compileExpr(fa.target);
                        self.emitOp(.get_field_idx);
                        self.emitByte(field_idx);
                    }
                } else {
                    self.compileExpr(fa.target);
                    const name_idx = self.addStringConstant(fa.field);
                    self.emitOp(.get_field);
                    self.emitU16(name_idx);
                }
            },
            .index => |idx| {
                self.compileExpr(idx.target);
                self.compileExpr(idx.idx);
                self.emitOp(.index_get);
            },
            .if_expr => |ie| self.compileIf(ie),
            .match_expr => |me| self.compileMatch(me),
            .block => |block| self.compileBlock(block),
            .closure => |cl| self.compileClosure(cl),
            .spawn => |inner| self.compileSpawn(inner),
            .struct_literal => |sl| self.compileStructLiteral(sl),
            .pipeline => |pl| self.compilePipeline(pl),
            .array_literal => |elems| {
                for (elems) |elem| self.compileExpr(elem);
                self.emitOp(.array_create);
                self.emitByte(@intCast(elems.len));
            },
            .try_unwrap => |inner| {
                self.compileExpr(inner);
                const not_nil = self.emitJump(.jump_if_nil);
                const skip = self.emitJump(.jump);
                self.patchJump(not_nil);
                self.emitOp(.return_);
                self.patchJump(skip);
            },
        }
    }

    fn compileStringInterp(self: *Compiler, si: ast.StringInterp) void {
        var first = true;
        for (si.parts) |part| {
            switch (part) {
                .literal => |text| {
                    const str = ObjString.create(self.alloc, self.processEscapes(text));
                    self.emitConstant(str.toValue());
                },
                .expr => |expr| {
                    self.compileExpr(expr);
                    self.emitOp(.to_str);
                },
            }
            if (!first) {
                self.emitOp(.add);
            }
            first = false;
        }
        if (si.parts.len == 0) {
            const str = ObjString.create(self.alloc, "");
            self.emitConstant(str.toValue());
        }
    }

    fn isModuleNamespace(self: *Compiler, name: []const u8) bool {
        var c: ?*Compiler = self;
        while (c) |cur| {
            if (cur.module_namespaces.get(name) != null) return true;
            if (cur.std_modules.get(name) != null) return true;
            c = cur.enclosing;
        }
        return false;
    }

    fn resolveModuleValue(self: *Compiler, ns: []const u8, name: []const u8) ?Value {
        var c: ?*Compiler = self;
        while (c) |cur| {
            if (cur.module_namespaces.get(ns)) |_| {
                if (cur.fn_table.get(name)) |func| return func.toValue();
                return null;
            }
            if (cur.std_modules.get(ns)) |std_mod| {
                for (std_mod.functions) |def| {
                    if (std.mem.eql(u8, def.name, name)) {
                        const nf = ObjNativeFn.create(self.alloc, def.name, def.arity, def.func);
                        return nf.toValue();
                    }
                }
                return null;
            }
            c = cur.enclosing;
        }
        return null;
    }

    fn compileIdentifier(self: *Compiler, name: []const u8) void {
        if (self.resolveLocal(name)) |slot| {
            self.emitOp(.get_local);
            self.emitByte(slot);
            return;
        }

        if (self.findEnumVariant(name)) |info| {
            if (info.payload_count == 0) {
                const variant_idx = self.addStringConstant(name);
                const type_idx = self.addStringConstant(info.type_name);
                self.emitOp(.enum_variant);
                self.emitU16(variant_idx);
                self.emitU16(type_idx);
                self.emitByte(0);
                self.emitByte(info.variant_index);
                return;
            }
        }

        self.compileGetVar(name);
    }

    fn compileStructLiteral(self: *Compiler, sl: ast.StructLiteral) void {
        const field_defs = self.findStructDef(sl.name);
        if (field_defs) |defs| {
            for (defs) |def_name| {
                var found = false;
                for (sl.fields) |field| {
                    if (std.mem.eql(u8, field.name, def_name)) {
                        self.compileExpr(field.value);
                        found = true;
                        break;
                    }
                }
                if (!found) self.emitOp(.nil);
            }
            const name_idx = self.addStringConstant(sl.name);
            self.emitOp(.struct_create);
            self.emitU16(name_idx);
            self.emitByte(@intCast(defs.len));
            for (defs) |def_name| {
                self.emitU16(self.addStringConstant(def_name));
            }
        } else {
            for (sl.fields) |field| {
                self.compileExpr(field.value);
            }
            const name_idx = self.addStringConstant(sl.name);
            self.emitOp(.struct_create);
            self.emitU16(name_idx);
            self.emitByte(@intCast(sl.fields.len));
            for (sl.fields) |field| {
                self.emitU16(self.addStringConstant(field.name));
            }
        }
    }

    fn compileBinary(self: *Compiler, bin: ast.Binary) void {
        if (bin.op == .double_question) {
            self.compileExpr(bin.lhs);
            const nil_jump = self.emitJump(.jump_if_nil);
            const skip_jump = self.emitJump(.jump);
            self.patchJump(nil_jump);
            self.emitOp(.pop);
            self.compileExpr(bin.rhs);
            self.patchJump(skip_jump);
            return;
        }

        if (bin.op == .and_and) {
            self.compileExpr(bin.lhs);
            const jump = self.emitJump(.jump_if_false);
            self.emitOp(.pop);
            self.compileExpr(bin.rhs);
            self.patchJump(jump);
            return;
        }

        if (bin.op == .or_or) {
            self.compileExpr(bin.lhs);
            const false_jump = self.emitJump(.jump_if_false);
            const true_jump = self.emitJump(.jump);
            self.patchJump(false_jump);
            self.emitOp(.pop);
            self.compileExpr(bin.rhs);
            self.patchJump(true_jump);
            return;
        }

        self.compileExpr(bin.lhs);
        self.compileExpr(bin.rhs);

        const lt = self.exprType(bin.lhs);
        const rt = self.exprType(bin.rhs);

        if (lt == .int_ and rt == .int_) {
            const specialized: ?OpCode = switch (bin.op) {
                .plus => .add_int,
                .minus => .sub_int,
                .lt => .less_int,
                .gt => .greater_int,
                .star => .mul_int,
                .slash => .div_int,
                .percent => .mod_int,
                else => null,
            };
            if (specialized) |op| {
                self.emitOp(op);
                return;
            }
        }

        const either_float = (lt == .float_ or rt == .float_) and (lt == .float_ or lt == .int_) and (rt == .float_ or rt == .int_);
        if (either_float) {
            const specialized: ?OpCode = switch (bin.op) {
                .plus => .add_float,
                .minus => .sub_float,
                .star => .mul_float,
                .slash => .div_float,
                .lt => .less_float,
                .gt => .greater_float,
                else => null,
            };
            if (specialized) |op| {
                self.emitOp(op);
                return;
            }
        }

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

            if (std.mem.eql(u8, name, "channel")) {
                const cap: u8 = if (call.args.len > 0) blk: {
                    if (call.args[0].kind == .int_literal) {
                        break :blk @intCast(std.fmt.parseInt(u8, call.args[0].kind.int_literal, 10) catch 16);
                    }
                    break :blk 16;
                } else 16;
                self.emitOp(.channel_create);
                self.emitByte(cap);
                return;
            }

            if (std.mem.eql(u8, name, "await_all")) {
                const count = call.args.len;
                const base_slot = self.local_count;

                for (call.args) |arg| {
                    self.compileExpr(arg);
                    const slot_name = std.fmt.allocPrint(self.alloc, "$await_{d}", .{self.local_count}) catch "$await";
                    self.addLocal(slot_name);
                }

                var i: usize = 0;
                while (i < count) : (i += 1) {
                    self.emitOp(.get_local);
                    self.emitByte(base_slot + @as(u8, @intCast(i)));
                    self.emitOp(.await_task);
                }

                self.emitOp(.array_create);
                self.emitByte(@intCast(count));
                return;
            }

            if (self.findFfiFunc(name)) |desc_idx| {
                for (call.args) |arg| {
                    self.compileExpr(arg);
                }
                self.emitOp(.ffi_call);
                self.emitU16(desc_idx);
                self.emitByte(@intCast(call.args.len));
                return;
            }

            if (self.findEnumVariant(name)) |info| {
                if (info.payload_count > 0 and call.args.len == info.payload_count) {
                    for (call.args) |arg| {
                        self.compileExpr(arg);
                    }
                    const variant_idx = self.addStringConstant(name);
                    const type_idx = self.addStringConstant(info.type_name);
                    self.emitOp(.enum_variant);
                    self.emitU16(variant_idx);
                    self.emitU16(type_idx);
                    self.emitByte(@intCast(call.args.len));
                    self.emitByte(info.variant_index);
                    return;
                }
            }
        }

        if (call.callee.kind == .field_access) {
            const fa = call.callee.kind.field_access;
            if (std.mem.eql(u8, fa.field, "send") and call.args.len == 1) {
                self.compileExpr(fa.target);
                self.compileExpr(call.args[0]);
                self.emitOp(.channel_send);
                return;
            }
            if (std.mem.eql(u8, fa.field, "recv") and call.args.len == 0) {
                self.compileExpr(fa.target);
                self.emitOp(.channel_recv);
                return;
            }
            if (std.mem.eql(u8, fa.field, "accept") and call.args.len == 0) {
                self.compileExpr(fa.target);
                self.emitOp(.net_accept);
                return;
            }
            if (std.mem.eql(u8, fa.field, "read") and call.args.len == 0) {
                self.compileExpr(fa.target);
                self.emitOp(.net_read);
                return;
            }
            if (std.mem.eql(u8, fa.field, "write") and call.args.len == 1) {
                self.compileExpr(fa.target);
                self.compileExpr(call.args[0]);
                self.emitOp(.net_write);
                return;
            }
            if (std.mem.eql(u8, fa.field, "sendto") and call.args.len == 3) {
                self.compileExpr(fa.target);
                self.compileExpr(call.args[0]);
                self.compileExpr(call.args[1]);
                self.compileExpr(call.args[2]);
                self.emitOp(.net_sendto);
                return;
            }
            if (std.mem.eql(u8, fa.field, "recvfrom") and call.args.len == 0) {
                self.compileExpr(fa.target);
                self.emitOp(.net_recvfrom);
                return;
            }
            if (std.mem.eql(u8, fa.field, "connect") and call.args.len == 2) {
                const is_ns = if (fa.target.kind == .identifier) self.isModuleNamespace(fa.target.kind.identifier) else false;
                if (!is_ns) {
                    self.compileExpr(call.args[0]);
                    self.compileExpr(call.args[1]);
                    self.emitOp(.net_connect);
                    return;
                }
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

    fn variantCountForType(self: *Compiler, type_name: []const u8) u8 {
        var max_idx: u8 = 0;
        var found = false;
        var c: ?*Compiler = self;
        while (c) |cur| {
            var it = cur.enum_variants.iterator();
            while (it.next()) |entry| {
                if (std.mem.eql(u8, entry.value_ptr.type_name, type_name)) {
                    found = true;
                    if (entry.value_ptr.variant_index >= max_idx) {
                        max_idx = entry.value_ptr.variant_index + 1;
                    }
                }
            }
            c = cur.enclosing;
        }
        return if (found) max_idx else 0;
    }

    fn canUseMatchJump(self: *Compiler, arms: []const ast.MatchArm) ?[]const u8 {
        if (arms.len == 0) return null;
        var type_name: ?[]const u8 = null;
        for (arms) |arm| {
            if (arm.guard != null) return null;
            switch (arm.pattern.kind) {
                .variant => |vp| {
                    const info = self.findEnumVariant(vp.name) orelse return null;
                    if (type_name) |tn| {
                        if (!std.mem.eql(u8, tn, info.type_name)) return null;
                    } else {
                        type_name = info.type_name;
                    }
                },
                .identifier => |name| {
                    if (self.findEnumVariant(name)) |info| {
                        if (type_name) |tn| {
                            if (!std.mem.eql(u8, tn, info.type_name)) return null;
                        } else {
                            type_name = info.type_name;
                        }
                    } else {
                        return null;
                    }
                },
                .wildcard => {},
                else => return null,
            }
        }
        return type_name;
    }

    fn compileMatchJump(self: *Compiler, me: ast.MatchExpr, variant_count: u8) void {
        self.compileExpr(me.subject);
        self.beginScope();
        self.addLocal("$match");

        const match_slot = self.resolveLocal("$match").?;
        self.emitOp(.match_jump);
        self.emitByte(match_slot);
        self.emitByte(variant_count);

        const table_start = self.chunk().count();
        for (0..variant_count) |_| {
            self.emitByte(0);
            self.emitByte(0);
        }
        self.emitByte(0);
        self.emitByte(0);
        const base_ip = self.chunk().count();

        var arm_starts: [256]usize = undefined;
        var has_arm: [256]bool = .{false} ** 256;
        var wildcard_arm: ?usize = null;

        var end_jumps: [64]usize = undefined;
        var end_count: usize = 0;

        for (me.arms) |arm| {
            switch (arm.pattern.kind) {
                .variant => |vp| {
                    const info = self.findEnumVariant(vp.name).?;
                    const vi = info.variant_index;
                    arm_starts[vi] = self.chunk().count();
                    has_arm[vi] = true;

                    self.beginScope();
                    for (vp.bindings, 0..) |binding, i| {
                        self.emitOp(.get_local);
                        self.emitByte(match_slot);
                        self.emitOp(.get_payload);
                        self.emitByte(@intCast(i));
                        self.addLocal(binding);
                    }
                    self.compileExpr(arm.body);
                    self.endScopeKeepTop();
                    end_jumps[end_count] = self.emitJump(.jump);
                    end_count += 1;
                },
                .identifier => |name| {
                    const info = self.findEnumVariant(name).?;
                    const vi = info.variant_index;
                    arm_starts[vi] = self.chunk().count();
                    has_arm[vi] = true;

                    self.compileExpr(arm.body);
                    end_jumps[end_count] = self.emitJump(.jump);
                    end_count += 1;
                },
                .wildcard => {
                    wildcard_arm = self.chunk().count();
                    self.compileExpr(arm.body);
                    end_jumps[end_count] = self.emitJump(.jump);
                    end_count += 1;
                },
                else => unreachable,
            }
        }

        const nil_pos = self.chunk().count();
        self.emitOp(.nil);

        for (end_jumps[0..end_count]) |j| {
            self.patchJump(j);
        }

        const code = self.chunk().code.items;
        for (0..variant_count) |vi| {
            const target = if (has_arm[vi])
                arm_starts[vi]
            else if (wildcard_arm) |w|
                w
            else
                nil_pos;
            const offset: u16 = @intCast(target - base_ip);
            code[table_start + vi * 2] = @intCast(offset >> 8);
            code[table_start + vi * 2 + 1] = @intCast(offset & 0xff);
        }
        const default_target = if (wildcard_arm) |w| w else nil_pos;
        const default_offset: u16 = @intCast(default_target - base_ip);
        code[table_start + variant_count * 2] = @intCast(default_offset >> 8);
        code[table_start + variant_count * 2 + 1] = @intCast(default_offset & 0xff);

        self.endScopeKeepTop();
    }

    fn compileMatch(self: *Compiler, me: ast.MatchExpr) void {
        if (self.canUseMatchJump(me.arms)) |type_name| {
            const vc = self.variantCountForType(type_name);
            if (vc > 0 and vc <= 64) {
                self.compileMatchJump(me, vc);
                return;
            }
        }

        self.compileExpr(me.subject);

        self.beginScope();
        self.addLocal("$match");

        var end_jumps: [64]usize = undefined;
        var end_count: usize = 0;

        for (me.arms) |arm| {
            switch (arm.pattern.kind) {
                .variant => |vp| {
                    self.emitOp(.get_local);
                    self.emitByte(self.resolveLocal("$match").?);
                    const vi = if (self.findEnumVariant(vp.name)) |info| info.variant_index else 255;
                    self.emitOp(.match_variant);
                    self.emitByte(vi);
                    const skip = self.emitJump(.jump_if_false);
                    self.emitOp(.pop);
                    self.emitOp(.pop);

                    self.beginScope();
                    for (vp.bindings, 0..) |binding, i| {
                        self.emitOp(.get_local);
                        self.emitByte(self.resolveLocal("$match").?);
                        self.emitOp(.get_payload);
                        self.emitByte(@intCast(i));
                        self.addLocal(binding);
                    }

                    if (arm.guard) |guard| {
                        self.compileExpr(guard);
                        const guard_skip = self.emitJump(.jump_if_false);
                        self.emitOp(.pop);
                        self.compileExpr(arm.body);
                        self.endScopeKeepTop();
                        end_jumps[end_count] = self.emitJump(.jump);
                        end_count += 1;
                        self.patchJump(guard_skip);
                        self.emitOp(.pop);
                    } else {
                        self.compileExpr(arm.body);
                        self.endScopeKeepTop();
                        end_jumps[end_count] = self.emitJump(.jump);
                        end_count += 1;
                    }

                    self.patchJump(skip);
                    self.emitOp(.pop);
                    self.emitOp(.pop);
                },
                .literal => |lit| {
                    self.emitOp(.get_local);
                    self.emitByte(self.resolveLocal("$match").?);
                    self.compileExpr(lit);
                    self.emitOp(.equal);
                    const skip = self.emitJump(.jump_if_false);
                    self.emitOp(.pop);

                    self.compileExpr(arm.body);
                    end_jumps[end_count] = self.emitJump(.jump);
                    end_count += 1;

                    self.patchJump(skip);
                    self.emitOp(.pop);
                },
                .identifier => |binding_name| {
                    if (self.findEnumVariant(binding_name)) |info| {
                        self.emitOp(.get_local);
                        self.emitByte(self.resolveLocal("$match").?);
                        self.emitOp(.match_variant);
                        self.emitByte(info.variant_index);
                        const skip = self.emitJump(.jump_if_false);
                        self.emitOp(.pop);
                        self.emitOp(.pop);

                        self.compileExpr(arm.body);
                        end_jumps[end_count] = self.emitJump(.jump);
                        end_count += 1;

                        self.patchJump(skip);
                        self.emitOp(.pop);
                        self.emitOp(.pop);
                    } else {
                        self.beginScope();
                        self.emitOp(.get_local);
                        self.emitByte(self.resolveLocal("$match").?);
                        self.addLocal(binding_name);

                        if (arm.guard) |guard| {
                            self.compileExpr(guard);
                            const guard_skip = self.emitJump(.jump_if_false);
                            self.emitOp(.pop);
                            self.compileExpr(arm.body);
                            self.endScopeKeepTop();
                            end_jumps[end_count] = self.emitJump(.jump);
                            end_count += 1;
                            self.patchJump(guard_skip);
                            self.emitOp(.pop);
                        } else {
                            self.compileExpr(arm.body);
                            self.endScopeKeepTop();
                            end_jumps[end_count] = self.emitJump(.jump);
                            end_count += 1;
                        }
                    }
                },
                .wildcard => {
                    self.compileExpr(arm.body);
                    end_jumps[end_count] = self.emitJump(.jump);
                    end_count += 1;
                },
            }
        }

        self.emitOp(.nil);

        for (end_jumps[0..end_count]) |j| {
            self.patchJump(j);
        }

        self.endScopeKeepTop();
    }

    fn compileClosure(self: *Compiler, cl: ast.Closure) void {
        var func = ObjFunction.create(self.alloc, "<closure>", @intCast(cl.params.len));
        func.source = self.source;
        var sub = Compiler{
            .alloc = self.alloc,
            .enclosing = self,
            .function = func,
            .locals = undefined,
            .local_count = 0,
            .scope_depth = 1,
            .struct_defs = .{},
            .enum_variants = .{},
            .fn_table = .{},
            .fn_returns = .{},
            .upvalues = undefined,
            .upvalue_count = 0,
            .module_loader = self.module_loader,
            .module_dir = self.module_dir,
            .module_namespaces = .{},
            .std_modules = .{},
            .native_fns = .{},
            .ffi_descs = .{},
            .ffi_funcs = .{},
            .source = self.source,
            .current_line = self.current_line,
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

        func.locals_only = analyzeLocalsOnly(&func.chunk);

        if (sub.upvalue_count > 0) {
            const idx = self.chunk().addConstant(self.alloc, func.toValue());
            self.emitOp(.make_closure);
            self.emitU16(idx);
            self.emitByte(sub.upvalue_count);
            var i: u8 = 0;
            while (i < sub.upvalue_count) : (i += 1) {
                self.emitByte(if (sub.upvalues[i].is_local) 1 else 0);
                self.emitByte(sub.upvalues[i].index);
            }
        } else {
            self.emitConstant(func.toValue());
        }
    }

    fn compileSpawn(self: *Compiler, body: *const ast.Expr) void {
        var func = ObjFunction.create(self.alloc, "<spawn>", 0);
        func.source = self.source;
        var sub = Compiler{
            .alloc = self.alloc,
            .enclosing = self,
            .function = func,
            .locals = undefined,
            .local_count = 0,
            .scope_depth = 1,
            .struct_defs = .{},
            .enum_variants = .{},
            .fn_table = .{},
            .fn_returns = .{},
            .upvalues = undefined,
            .upvalue_count = 0,
            .module_loader = self.module_loader,
            .module_dir = self.module_dir,
            .module_namespaces = .{},
            .std_modules = .{},
            .native_fns = .{},
            .ffi_descs = .{},
            .ffi_funcs = .{},
            .source = self.source,
            .current_line = self.current_line,
        };
        sub.addLocal("");

        sub.copyInheritedState(self);

        if (body.kind == .block) {
            sub.compileBlock(body.kind.block);
        } else {
            sub.compileExpr(body);
            sub.emitOp(.return_);
        }

        if (!sub.lastOpIs(.return_)) {
            sub.emitOp(.nil);
            sub.emitOp(.return_);
        }

        func.locals_only = false;

        if (sub.upvalue_count > 0) {
            const idx = self.chunk().addConstant(self.alloc, func.toValue());
            self.emitOp(.make_closure);
            self.emitU16(idx);
            self.emitByte(sub.upvalue_count);
            var i: u8 = 0;
            while (i < sub.upvalue_count) : (i += 1) {
                self.emitByte(if (sub.upvalues[i].is_local) 1 else 0);
                self.emitByte(sub.upvalues[i].index);
            }
        } else {
            self.emitConstant(func.toValue());
        }
        self.emitOp(.spawn);
    }

    fn copyInheritedState(self: *Compiler, from: *Compiler) void {
        var it = from.struct_defs.iterator();
        while (it.next()) |entry| {
            self.struct_defs.put(self.alloc, entry.key_ptr.*, entry.value_ptr.*) catch {};
        }
        var eit = from.enum_variants.iterator();
        while (eit.next()) |entry| {
            self.enum_variants.put(self.alloc, entry.key_ptr.*, entry.value_ptr.*) catch {};
        }
        var fit = from.fn_table.iterator();
        while (fit.next()) |entry| {
            self.fn_table.put(self.alloc, entry.key_ptr.*, entry.value_ptr.*) catch {};
        }
        var frit = from.fn_returns.iterator();
        while (frit.next()) |entry| {
            self.fn_returns.put(self.alloc, entry.key_ptr.*, entry.value_ptr.*) catch {};
        }
        var nit = from.native_fns.iterator();
        while (nit.next()) |entry| {
            self.native_fns.put(self.alloc, entry.key_ptr.*, entry.value_ptr.*) catch {};
        }
        var sit = from.std_modules.iterator();
        while (sit.next()) |entry| {
            self.std_modules.put(self.alloc, entry.key_ptr.*, entry.value_ptr.*) catch {};
        }
    }

    fn compilePipeline(self: *Compiler, pl: ast.Pipeline) void {
        if (pl.stages.len == 0) return;
        self.compileExpr(pl.stages[0]);
        for (pl.stages[1..]) |stage| {
            if (stage.kind == .call) {
                const call = stage.kind.call;
                self.compileGetExpr(call.callee);
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
        } else if (self.resolveUpvalue(name)) |uv| {
            self.emitOp(.get_upvalue);
            self.emitByte(uv);
        } else if (self.findFunction(name)) |func| {
            self.emitConstant(func.toValue());
        } else if (self.findNative(name)) |nf| {
            self.emitConstant(nf.toValue());
        } else {
            const idx = self.addStringConstant(name);
            self.emitOp(.get_global);
            self.emitU16(idx);
        }
    }

    fn findNative(self: *Compiler, name: []const u8) ?*ObjNativeFn {
        var c: ?*Compiler = self;
        while (c) |cur| {
            if (cur.native_fns.get(name)) |nf| return nf;
            c = cur.enclosing;
        }
        return null;
    }

    fn compileSetTarget(self: *Compiler, expr: *const ast.Expr) void {
        switch (expr.kind) {
            .identifier => |name| {
                if (self.resolveLocal(name)) |slot| {
                    self.emitOp(.set_local);
                    self.emitByte(slot);
                } else if (self.resolveUpvalue(name)) |uv| {
                    self.emitOp(.set_upvalue);
                    self.emitByte(uv);
                } else {
                    const idx = self.addStringConstant(name);
                    self.emitOp(.set_global);
                    self.emitU16(idx);
                }
            },
            .field_access => |fa| {
                self.compileExpr(fa.target);
                if (self.resolveFieldIndex(fa.field)) |fi| {
                    self.emitOp(.set_field_idx);
                    self.emitByte(fi);
                } else {
                    const idx = self.addStringConstant(fa.field);
                    self.emitOp(.set_field);
                    self.emitU16(idx);
                }
            },
            .index => |ix| {
                self.compileExpr(ix.target);
                self.compileExpr(ix.idx);
                self.emitOp(.index_set);
            },
            else => {},
        }
    }

    fn compileGetTarget(self: *Compiler, expr: *const ast.Expr) void {
        switch (expr.kind) {
            .identifier => |name| self.compileGetVar(name),
            .field_access => |fa| {
                self.compileExpr(fa.target);
                if (self.resolveFieldIndex(fa.field)) |fi| {
                    self.emitOp(.get_field_idx);
                    self.emitByte(fi);
                } else {
                    const idx = self.addStringConstant(fa.field);
                    self.emitOp(.get_field);
                    self.emitU16(idx);
                }
            },
            .index => |ix| {
                self.compileExpr(ix.target);
                self.compileExpr(ix.idx);
                self.emitOp(.index_get);
            },
            else => self.compileGetVar(""),
        }
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

    fn resolveUpvalue(self: *Compiler, name: []const u8) ?u8 {
        const enclosing = self.enclosing orelse return null;

        if (enclosing.resolveLocal(name)) |local_slot| {
            return self.addUpvalue(local_slot, true);
        }

        if (enclosing.resolveUpvalue(name)) |upvalue_idx| {
            return self.addUpvalue(upvalue_idx, false);
        }

        return null;
    }

    fn addUpvalue(self: *Compiler, index: u8, is_local: bool) u8 {
        var i: u8 = 0;
        while (i < self.upvalue_count) : (i += 1) {
            if (self.upvalues[i].index == index and self.upvalues[i].is_local == is_local) {
                return i;
            }
        }
        if (self.upvalue_count == 255) return 0;
        self.upvalues[self.upvalue_count] = .{ .index = index, .is_local = is_local };
        self.upvalue_count += 1;
        return self.upvalue_count - 1;
    }

    fn addLocal(self: *Compiler, name: []const u8) void {
        self.addLocalTyped(name, .unknown);
    }

    fn addLocalTyped(self: *Compiler, name: []const u8, hint: TypeHint) void {
        if (self.local_count == 255) return;
        self.locals[self.local_count] = .{ .name = name, .depth = self.scope_depth, .type_hint = hint };
        self.local_count += 1;
    }

    fn resolveTypeHint(self: *Compiler, type_expr: ?*const ast.TypeExpr) TypeHint {
        const hint = typeHintFromExpr(type_expr);
        if (hint != .unknown) return hint;
        const te = type_expr orelse return .unknown;
        if (te.kind != .named) return .unknown;
        if (self.findStructDef(te.kind.named) != null) return .struct_;
        return .unknown;
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
        var count: u8 = 0;
        while (self.local_count > 0 and self.locals[self.local_count - 1].depth > self.scope_depth) {
            self.local_count -= 1;
            count += 1;
        }
        if (count > 0) {
            self.emitOp(.slide);
            self.emitByte(count);
        }
    }

    // ---------------------------------------------------------------
    // metadata lookup (walks enclosing chain)
    // ---------------------------------------------------------------

    fn findStructDef(self: *Compiler, name: []const u8) ?[]const []const u8 {
        var c: ?*Compiler = self;
        while (c) |cur| {
            if (cur.struct_defs.get(name)) |defs| return defs;
            c = cur.enclosing;
        }
        return null;
    }

    fn resolveFieldIndex(self: *Compiler, field: []const u8) ?u8 {
        var result: ?u8 = null;
        var c: ?*Compiler = self;
        while (c) |cur| {
            var it = cur.struct_defs.iterator();
            while (it.next()) |entry| {
                for (entry.value_ptr.*, 0..) |fname, i| {
                    if (std.mem.eql(u8, fname, field)) {
                        const idx: u8 = @intCast(i);
                        if (result) |prev| {
                            if (prev != idx) return null;
                        } else {
                            result = idx;
                        }
                    }
                }
            }
            c = cur.enclosing;
        }
        return result;
    }

    fn findEnumVariant(self: *Compiler, name: []const u8) ?VariantInfo {
        var c: ?*Compiler = self;
        while (c) |cur| {
            if (cur.enum_variants.get(name)) |info| return info;
            c = cur.enclosing;
        }
        return null;
    }

    fn findFfiFunc(self: *Compiler, name: []const u8) ?u16 {
        var c: ?*Compiler = self;
        while (c) |cur| {
            if (cur.ffi_funcs.get(name)) |idx| return idx;
            c = cur.enclosing;
        }
        return null;
    }

    fn findReturnType(self: *Compiler, name: []const u8) TypeHint {
        var c: ?*Compiler = self;
        while (c) |cur| {
            if (cur.fn_returns.get(name)) |hint| return hint;
            c = cur.enclosing;
        }
        return .unknown;
    }

    fn localTypeHint(self: *Compiler, name: []const u8) TypeHint {
        if (self.local_count == 0) return .unknown;
        var i: u8 = self.local_count;
        while (i > 0) {
            i -= 1;
            if (std.mem.eql(u8, self.locals[i].name, name)) return self.locals[i].type_hint;
        }
        return .unknown;
    }

    fn exprType(self: *Compiler, expr: *const ast.Expr) TypeHint {
        return switch (expr.kind) {
            .int_literal => .int_,
            .float_literal => .float_,
            .string_literal => .string_,
            .bool_literal => .bool_,
            .identifier => |name| self.localTypeHint(name),
            .binary => |bin| self.binaryType(bin),
            .unary => |un| switch (un.op) {
                .negate => self.exprType(un.operand),
                .not => .bool_,
                else => .unknown,
            },
            .call => |call| if (call.callee.kind == .identifier)
                self.findReturnType(call.callee.kind.identifier)
            else
                .unknown,
            .if_expr => |ie| self.exprType(ie.then_block.trailing orelse return .unknown),
            else => .unknown,
        };
    }

    fn binaryType(self: *Compiler, bin: ast.Binary) TypeHint {
        const lt = self.exprType(bin.lhs);
        const rt = self.exprType(bin.rhs);
        return switch (bin.op) {
            .plus, .minus, .star, .slash, .percent => blk: {
                if (lt == .int_ and rt == .int_) break :blk .int_;
                if (lt == .string_ and rt == .string_ and bin.op == .plus) break :blk .string_;
                const l_numeric = lt == .float_ or lt == .int_ or lt == .unknown;
                const r_numeric = rt == .float_ or rt == .int_ or rt == .unknown;
                if ((lt == .float_ or rt == .float_) and l_numeric and r_numeric) break :blk .float_;
                break :blk .unknown;
            },
            .lt, .gt, .lt_eq, .gt_eq, .eq_eq, .bang_eq => .bool_,
            else => .unknown,
        };
    }

    fn findFunction(self: *Compiler, name: []const u8) ?*ObjFunction {
        var c: ?*Compiler = self;
        while (c) |cur| {
            if (cur.fn_table.get(name)) |func| return func;
            c = cur.enclosing;
        }
        return null;
    }

    // ---------------------------------------------------------------
    // emit helpers
    // ---------------------------------------------------------------

    fn chunk(self: *Compiler) *Chunk {
        return &self.function.chunk;
    }

    fn lineFromOffset(self: *const Compiler, offset: usize) u32 {
        var line: u32 = 1;
        const end = @min(offset, self.source.len);
        for (self.source[0..end]) |c| {
            if (c == '\n') line += 1;
        }
        return line;
    }

    fn setSpan(self: *Compiler, span: ast.Span) void {
        self.current_line = self.lineFromOffset(span.start);
    }

    fn emitByte(self: *Compiler, byte: u8) void {
        self.chunk().write(self.alloc, byte, self.current_line);
    }

    fn emitOp(self: *Compiler, op: OpCode) void {
        self.chunk().writeOp(self.alloc, op, self.current_line);
    }

    fn emitU16(self: *Compiler, val: u16) void {
        self.chunk().writeU16(self.alloc, val, self.current_line);
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
        if (self.findFunction(name)) |func| {
            self.emitConstant(func.toValue());
        } else {
            const idx = self.addStringConstant(name);
            self.emitOp(.get_global);
            self.emitU16(idx);
        }
        self.emitOp(.call);
        self.emitByte(arity);
    }

    fn processEscapes(self: *Compiler, raw: []const u8) []const u8 {
        var has_escape = false;
        for (raw) |c| {
            if (c == '\\') {
                has_escape = true;
                break;
            }
        }
        if (!has_escape) return raw;

        var buf = std.ArrayListUnmanaged(u8){};
        var i: usize = 0;
        while (i < raw.len) {
            if (raw[i] == '\\' and i + 1 < raw.len) {
                switch (raw[i + 1]) {
                    'n' => buf.append(self.alloc, '\n') catch @panic("oom"),
                    't' => buf.append(self.alloc, '\t') catch @panic("oom"),
                    'r' => buf.append(self.alloc, '\r') catch @panic("oom"),
                    '\\' => buf.append(self.alloc, '\\') catch @panic("oom"),
                    '"' => buf.append(self.alloc, '"') catch @panic("oom"),
                    '{' => buf.append(self.alloc, '{') catch @panic("oom"),
                    '}' => buf.append(self.alloc, '}') catch @panic("oom"),
                    '0' => buf.append(self.alloc, 0) catch @panic("oom"),
                    'x' => {
                        if (i + 3 < raw.len) {
                            const byte = std.fmt.parseInt(u8, raw[i + 2 .. i + 4], 16) catch {
                                buf.append(self.alloc, '\\') catch @panic("oom");
                                buf.append(self.alloc, 'x') catch @panic("oom");
                                i += 2;
                                continue;
                            };
                            buf.append(self.alloc, byte) catch @panic("oom");
                            i += 4;
                            continue;
                        } else {
                            buf.append(self.alloc, '\\') catch @panic("oom");
                            buf.append(self.alloc, 'x') catch @panic("oom");
                            i += 2;
                            continue;
                        }
                    },
                    else => {
                        buf.append(self.alloc, raw[i + 1]) catch @panic("oom");
                    },
                }
                i += 2;
            } else {
                buf.append(self.alloc, raw[i]) catch @panic("oom");
                i += 1;
            }
        }
        return buf.items;
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

fn typeHintFromExpr(type_expr: ?*const ast.TypeExpr) TypeHint {
    return typeHintFromExprWith(type_expr, null);
}

fn typeHintFromExprWith(type_expr: ?*const ast.TypeExpr, struct_defs: ?*const std.StringHashMapUnmanaged([]const []const u8)) TypeHint {
    const te = type_expr orelse return .unknown;
    if (te.kind != .named) return .unknown;
    const name = te.kind.named;
    if (std.mem.eql(u8, name, "int")) return .int_;
    if (std.mem.eql(u8, name, "float")) return .float_;
    if (std.mem.eql(u8, name, "str")) return .string_;
    if (std.mem.eql(u8, name, "bool")) return .bool_;
    if (struct_defs) |sd| {
        if (sd.contains(name)) return .struct_;
    }
    return .unknown;
}

fn analyzeLocalsOnly(c: *const @import("chunk.zig").Chunk) bool {
    const code = c.code.items;
    var i: usize = 0;
    while (i < code.len) {
        const op: OpCode = @enumFromInt(code[i]);
        i += 1;
        switch (op) {
            .constant => i += 2,
            .nil, .true_, .false_, .pop, .to_str => {},
            .get_local, .set_local => i += 1,
            .add, .subtract, .multiply, .divide, .modulo, .negate, .add_int, .sub_int, .mul_int, .div_int, .mod_int, .less_int, .greater_int, .add_float, .sub_float, .mul_float, .div_float, .less_float, .greater_float => {},
            .not, .equal, .not_equal, .less, .greater, .less_equal, .greater_equal => {},
            .jump, .jump_if_false, .jump_if_nil, .loop_ => i += 2,
            .call => i += 1,
            .return_ => {},
            .get_global => i += 2,
            .struct_create => {
                i += 2;
                const fc = code[i];
                i += 1;
                i += @as(usize, fc) * 2;
            },
            .get_field, .set_field => i += 2,
            .get_field_idx, .set_field_idx, .concat_local => i += 1,
            .get_local_field => i += 2,
            .enum_variant => i += 6,
            .match_variant => i += 1,
            .get_payload => i += 1,
            .get_upvalue, .set_upvalue => i += 1,
            .array_create => i += 1,
            .index_get, .index_set, .array_push, .array_len => {},
            .slide => i += 1,
            .inc_local => i += 1,
            .match_jump => {
                i += 1;
                const vc = code[i];
                i += 1;
                i += @as(usize, vc) * 2 + 2;
            },
            .make_closure => {
                i += 2;
                const uv_count = code[i];
                i += 1;
                i += @as(usize, uv_count) * 2;
            },
            .push_arena, .pop_arena => {},
            .set_global, .define_global, .print, .println => return false,
            .spawn, .channel_create, .channel_send, .channel_recv, .await_task, .await_all, .net_accept, .net_read, .net_write, .net_connect, .net_sendto, .net_recvfrom, .ffi_call => return false,
        }
    }
    return true;
}
