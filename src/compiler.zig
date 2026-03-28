const std = @import("std");
const ast = @import("ast.zig");
const Chunk = @import("chunk.zig").Chunk;
const OpCode = @import("chunk.zig").OpCode;
const Value = @import("value.zig").Value;
const ObjString = @import("value.zig").ObjString;
const ObjFunction = @import("value.zig").ObjFunction;
const ObjNativeFn = @import("value.zig").ObjNativeFn;
const ObjArray = @import("value.zig").ObjArray;
const ModuleLoader = @import("module.zig").ModuleLoader;
const Module = @import("module.zig").Module;
const stdlib = @import("stdlib.zig");
const ffi = @import("ffi.zig");

pub const OwnershipHint = struct {
    kind: Kind,
    name: []const u8,
    offset: usize,
    target: []const u8,

    pub const Kind = enum { freed, moved, conditional_free };
};

pub const CompileResult = struct {
    func: *ObjFunction,
    ffi_descs: []ffi.FfiDesc,
    hints: []const OwnershipHint = &.{},
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
    fn_own_params: std.StringHashMapUnmanaged(u64) = .{},
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
    deferred: [64]DeferEntry = undefined,
    defer_count: u8 = 0,
    cond_depth: u32 = 0,
    current_block: ?*const ast.Block = null,
    inline_fns: std.StringHashMapUnmanaged(ast.FnDecl) = .{},
    inline_subs: ?*[16]InlineSub = null,
    inline_sub_count: u8 = 0,
    hints: ?*std.ArrayListUnmanaged(OwnershipHint) = null,
    current_span: ast.Span = .{ .start = 0, .end = 0 },

    const InlineSub = struct {
        name: []const u8,
        expr: *const ast.Expr,
    };

    pub const DeferEntry = struct {
        body: ast.Defer.Body,
        scope_depth: u32,
    };

    pub const Local = struct {
        name: []const u8,
        depth: u32,
        type_hint: TypeHint = .unknown,
        is_owned: bool = false,
        drop_flag_slot: ?u8 = null,
    };

    pub const Upvalue = struct {
        index: u8,
        is_local: bool,
    };

    pub fn compile(alloc: std.mem.Allocator, tree: ast.Ast) ?CompileResult {
        return compileModule(alloc, tree, null, ".");
    }

    pub fn compileForHints(alloc: std.mem.Allocator, tree: ast.Ast) ?[]const OwnershipHint {
        var hints: std.ArrayListUnmanaged(OwnershipHint) = .{};
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
            .module_loader = null,
            .module_dir = ".",
            .module_namespaces = .{},
            .std_modules = .{},
            .native_fns = .{},
            .ffi_descs = .{},
            .ffi_funcs = .{},
            .source = tree.source,
            .current_line = 1,
            .hints = &hints,
        };

        compiler.defineNatives();
        for (tree.items) |item| compiler.registerDecl(item);
        for (tree.items) |item| compiler.compileItem(item);

        return hints.toOwnedSlice(alloc) catch &.{};
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
        self.defineNativeFn("contains", 2, &nativeContains);
        self.defineNativeFn("index_of", 2, &nativeIndexOf);
        self.defineNativeFn("slice", 3, &nativeSlice);
        self.defineNativeFn("join", 2, &nativeJoin);
        self.defineNativeFn("reverse", 1, &nativeReverse);
        self.defineNativeFn("pop", 1, &nativePop);
        self.defineNativeFn("split", 2, &nativeSplit);
        self.defineNativeFn("trim", 1, &nativeTrim);
        self.defineNativeFn("starts_with", 2, &nativeStartsWith);
        self.defineNativeFn("ends_with", 2, &nativeEndsWith);
        self.defineNativeFn("replace", 3, &nativeReplace);
        self.defineNativeFn("to_upper", 1, &nativeToUpper);
        self.defineNativeFn("to_lower", 1, &nativeToLower);
        self.defineNativeFn("clone", 1, &nativeClone);

        self.defineHelperFn("map", 2, buildMapFunc);
        self.defineHelperFn("filter", 2, buildFilterFunc);
        self.defineHelperFn("reduce", 3, buildReduceFunc);

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

    fn defineHelperFn(self: *Compiler, name: []const u8, arity: u8, builder: *const fn (std.mem.Allocator) *ObjFunction) void {
        const func = builder(self.alloc);
        func.name = name;
        func.arity = arity;
        self.fn_table.put(self.alloc, name, func) catch @panic("oom");
        self.emitConstant(func.toValue());
        const name_idx = self.addStringConstant(name);
        self.emitOp(.define_global);
        self.emitU16(name_idx);
    }

    fn defineNativeFn(self: *Compiler, name: []const u8, arity: u8, func: *const fn (std.mem.Allocator, []const Value) Value) void {
        const nf = ObjNativeFn.create(self.alloc, name, arity, func);
        self.native_fns.put(self.alloc, name, nf) catch @panic("oom");
        self.emitConstant(nf.toValue());
        const name_idx = self.addStringConstant(name);
        self.emitOp(.define_global);
        self.emitU16(name_idx);
    }

    fn nativeSqrt(_: std.mem.Allocator, args: []const Value) Value {
        const v = args[0];
        const f: f64 = if (v.tag() == .float) v.asFloat() else if (v.tag() == .int) @floatFromInt(v.asInt()) else 0.0;
        return Value.initFloat(@sqrt(f));
    }

    fn nativeAbs(_: std.mem.Allocator, args: []const Value) Value {
        const v = args[0];
        if (v.tag() == .int) {
            const i = v.asInt();
            return Value.initInt(if (i < 0) -i else i);
        }
        if (v.tag() == .float) return Value.initFloat(@abs(v.asFloat()));
        return Value.initInt(0);
    }

    fn nativeInt(_: std.mem.Allocator, args: []const Value) Value {
        const v = args[0];
        if (v.tag() == .int) return v;
        if (v.tag() == .float) return Value.initInt(@intFromFloat(v.asFloat()));
        if (v.tag() == .bool_) return Value.initInt(@intFromBool(v.asBool()));
        return Value.initInt(0);
    }

    fn nativeFloat(_: std.mem.Allocator, args: []const Value) Value {
        const v = args[0];
        if (v.tag() == .float) return v;
        if (v.tag() == .int) return Value.initFloat(@floatFromInt(v.asInt()));
        return Value.initFloat(0.0);
    }

    fn nativeLen(_: std.mem.Allocator, args: []const Value) Value {
        const v = args[0];
        if (v.tag() == .string) return Value.initInt(@intCast(v.asString().chars.len));
        if (v.tag() == .array) return Value.initInt(@intCast(v.asArray().items.len));
        return Value.initInt(0);
    }

    fn nativePush(alloc: std.mem.Allocator, args: []const Value) Value {
        if (args[0].tag() == .array) {
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

    fn nativeContains(_: std.mem.Allocator, args: []const Value) Value {
        if (args[0].tag() == .array) {
            for (args[0].asArray().items) |item| {
                if (Value.eql(item, args[1])) return Value.initBool(true);
            }
            return Value.initBool(false);
        }
        if (args[0].tag() == .string and args[1].tag() == .string) {
            const haystack = args[0].asString().chars;
            const needle = args[1].asString().chars;
            if (std.mem.indexOf(u8, haystack, needle) != null) return Value.initBool(true);
            return Value.initBool(false);
        }
        return Value.initBool(false);
    }

    fn nativeIndexOf(_: std.mem.Allocator, args: []const Value) Value {
        if (args[0].tag() == .array) {
            for (args[0].asArray().items, 0..) |item, i| {
                if (Value.eql(item, args[1])) return Value.initInt(@intCast(i));
            }
            return Value.initInt(-1);
        }
        if (args[0].tag() == .string and args[1].tag() == .string) {
            const haystack = args[0].asString().chars;
            const needle = args[1].asString().chars;
            if (std.mem.indexOf(u8, haystack, needle)) |pos| return Value.initInt(@intCast(pos));
            return Value.initInt(-1);
        }
        return Value.initInt(-1);
    }

    fn nativeSlice(alloc: std.mem.Allocator, args: []const Value) Value {
        const start_raw = if (args[1].tag() == .int) args[1].asInt() else return Value.initNil();
        const end_raw = if (args[2].tag() == .int) args[2].asInt() else return Value.initNil();
        if (args[0].tag() == .array) {
            const items = args[0].asArray().items;
            const start: usize = @intCast(@max(0, start_raw));
            const end: usize = @intCast(@min(@as(i64, @intCast(items.len)), end_raw));
            if (start >= end) return ObjArray.create(alloc, &.{}).toValue();
            return ObjArray.create(alloc, items[start..end]).toValue();
        }
        if (args[0].tag() == .string) {
            const chars = args[0].asString().chars;
            const start: usize = @intCast(@max(0, start_raw));
            const end: usize = @intCast(@min(@as(i64, @intCast(chars.len)), end_raw));
            if (start >= end) return ObjString.create(alloc, "").toValue();
            const sub = alloc.dupe(u8, chars[start..end]) catch return Value.initNil();
            return ObjString.create(alloc, sub).toValue();
        }
        return Value.initNil();
    }

    fn nativeJoin(alloc: std.mem.Allocator, args: []const Value) Value {
        if (args[0].tag() != .array or args[1].tag() != .string) return Value.initNil();
        const items = args[0].asArray().items;
        const sep = args[1].asString().chars;
        var buf = std.ArrayListUnmanaged(u8){};
        for (items, 0..) |item, i| {
            if (i > 0) buf.appendSlice(alloc, sep) catch return Value.initNil();
            if (item.tag() == .string) {
                buf.appendSlice(alloc, item.asString().chars) catch return Value.initNil();
            } else {
                var tmp: [64]u8 = undefined;
                const s = valueToStr(alloc, item, &tmp);
                buf.appendSlice(alloc, s) catch return Value.initNil();
            }
        }
        const result = alloc.dupe(u8, buf.items) catch return Value.initNil();
        return ObjString.create(alloc, result).toValue();
    }

    fn valueToStr(alloc: std.mem.Allocator, v: Value, buf: *[64]u8) []const u8 {
        return switch (v.tag()) {
            .int => std.fmt.bufPrint(buf, "{d}", .{v.asInt()}) catch "",
            .float => std.fmt.bufPrint(buf, "{d}", .{v.asFloat()}) catch "",
            .bool_ => if (v.asBool()) "true" else "false",
            .nil => "nil",
            .string => v.asString().chars,
            else => {
                const s = alloc.dupe(u8, "<value>") catch return "";
                return s;
            },
        };
    }

    fn nativeReverse(alloc: std.mem.Allocator, args: []const Value) Value {
        if (args[0].tag() == .array) {
            const items = args[0].asArray().items;
            const new = alloc.alloc(Value, items.len) catch return Value.initNil();
            for (items, 0..) |item, i| new[items.len - 1 - i] = item;
            return ObjArray.create(alloc, new).toValue();
        }
        if (args[0].tag() == .string) {
            const chars = args[0].asString().chars;
            const new = alloc.alloc(u8, chars.len) catch return Value.initNil();
            for (chars, 0..) |c, i| new[chars.len - 1 - i] = c;
            return ObjString.create(alloc, new).toValue();
        }
        return Value.initNil();
    }

    fn nativePop(_: std.mem.Allocator, args: []const Value) Value {
        if (args[0].tag() != .array) return Value.initNil();
        const arr = args[0].asArray();
        if (arr.items.len == 0) return Value.initNil();
        const val = arr.items[arr.items.len - 1];
        arr.items = arr.items[0 .. arr.items.len - 1];
        return val;
    }

    fn nativeSplit(alloc: std.mem.Allocator, args: []const Value) Value {
        if (args[0].tag() != .string or args[1].tag() != .string) return Value.initNil();
        const str = args[0].asString().chars;
        const sep = args[1].asString().chars;
        const arr = ObjArray.create(alloc, &.{});
        if (sep.len == 0) {
            for (str) |c| {
                const s = alloc.alloc(u8, 1) catch return Value.initNil();
                s[0] = c;
                arr.push(alloc, ObjString.create(alloc, s).toValue());
            }
            return arr.toValue();
        }
        var rest = str;
        while (rest.len > 0) {
            if (std.mem.indexOf(u8, rest, sep)) |pos| {
                const part = alloc.dupe(u8, rest[0..pos]) catch return Value.initNil();
                arr.push(alloc, ObjString.create(alloc, part).toValue());
                rest = rest[pos + sep.len ..];
            } else {
                const part = alloc.dupe(u8, rest) catch return Value.initNil();
                arr.push(alloc, ObjString.create(alloc, part).toValue());
                break;
            }
        }
        return arr.toValue();
    }

    fn nativeTrim(alloc: std.mem.Allocator, args: []const Value) Value {
        if (args[0].tag() != .string) return Value.initNil();
        const chars = args[0].asString().chars;
        const trimmed = std.mem.trim(u8, chars, " \t\n\r");
        const result = alloc.dupe(u8, trimmed) catch return Value.initNil();
        return ObjString.create(alloc, result).toValue();
    }

    fn nativeStartsWith(_: std.mem.Allocator, args: []const Value) Value {
        if (args[0].tag() != .string or args[1].tag() != .string) return Value.initBool(false);
        return Value.initBool(std.mem.startsWith(u8, args[0].asString().chars, args[1].asString().chars));
    }

    fn nativeEndsWith(_: std.mem.Allocator, args: []const Value) Value {
        if (args[0].tag() != .string or args[1].tag() != .string) return Value.initBool(false);
        return Value.initBool(std.mem.endsWith(u8, args[0].asString().chars, args[1].asString().chars));
    }

    fn nativeReplace(alloc: std.mem.Allocator, args: []const Value) Value {
        if (args[0].tag() != .string or args[1].tag() != .string or args[2].tag() != .string) return Value.initNil();
        const str = args[0].asString().chars;
        const old = args[1].asString().chars;
        const new = args[2].asString().chars;
        if (old.len == 0) return args[0];
        var buf = std.ArrayListUnmanaged(u8){};
        var rest = str;
        while (rest.len > 0) {
            if (std.mem.indexOf(u8, rest, old)) |pos| {
                buf.appendSlice(alloc, rest[0..pos]) catch return Value.initNil();
                buf.appendSlice(alloc, new) catch return Value.initNil();
                rest = rest[pos + old.len ..];
            } else {
                buf.appendSlice(alloc, rest) catch return Value.initNil();
                break;
            }
        }
        const result = alloc.dupe(u8, buf.items) catch return Value.initNil();
        return ObjString.create(alloc, result).toValue();
    }

    fn nativeToUpper(alloc: std.mem.Allocator, args: []const Value) Value {
        if (args[0].tag() != .string) return Value.initNil();
        const chars = args[0].asString().chars;
        const result = alloc.alloc(u8, chars.len) catch return Value.initNil();
        for (chars, 0..) |c, i| result[i] = std.ascii.toUpper(c);
        return ObjString.create(alloc, result).toValue();
    }

    fn nativeToLower(alloc: std.mem.Allocator, args: []const Value) Value {
        if (args[0].tag() != .string) return Value.initNil();
        const chars = args[0].asString().chars;
        const result = alloc.alloc(u8, chars.len) catch return Value.initNil();
        for (chars, 0..) |c, i| result[i] = std.ascii.toLower(c);
        return ObjString.create(alloc, result).toValue();
    }

    fn nativeClone(alloc: std.mem.Allocator, args: []const Value) Value {
        return args[0].deepClone(alloc);
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
                if (decl.body == .expr and isInlineable(decl.body.expr)) {
                    self.inline_fns.put(self.alloc, decl.name, decl) catch @panic("oom");
                }
                var own_mask: u64 = 0;
                for (decl.params, 0..) |param, pi| {
                    if (param.is_own) own_mask |= @as(u64, 1) << @intCast(pi);
                }
                if (own_mask != 0) {
                    self.fn_own_params.put(self.alloc, decl.name, own_mask) catch @panic("oom");
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
            .struct_decl, .enum_decl, .trait_decl, .type_alias => {},
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
            .hints = self.hints,
        };
        sub.addLocal("");

        for (decl.params) |param| {
            sub.addLocalTyped(param.name, sub.resolveTypeHint(param.type_expr));
            if (param.is_own) {
                sub.locals[sub.local_count - 1].is_owned = true;
            }
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
        const scope_base = self.local_count;
        const prev_block = self.current_block;
        self.current_block = block;
        defer self.current_block = prev_block;

        for (block.stmts, 0..) |stmt, stmt_idx| {
            self.compileStmt(stmt);
            self.emitEarlyFrees(block, scope_base, stmt_idx);
        }

        if (block.trailing) |expr| {
            self.compileExpr(expr);
            self.emitAllDefers();
            self.emitOp(.return_);
        }

        self.endScope();
    }

    fn emitEarlyFrees(self: *Compiler, block: *const ast.Block, scope_base: u8, stmt_idx: usize) void {
        var slot: u8 = scope_base;
        while (slot < self.local_count) : (slot += 1) {
            const local = &self.locals[slot];
            if (!local.is_owned or local.depth != self.scope_depth) {
                continue;
            }
            var used_later = false;
            for (block.stmts[stmt_idx + 1 ..]) |future_stmt| {
                if (stmtUsesName(future_stmt, local.name)) {
                    used_later = true;
                    break;
                }
            }
            if (!used_later) {
                if (block.trailing) |expr| {
                    if (exprUsesName(expr, local.name)) continue;
                }
                if (local.drop_flag_slot) |flag_slot| {
                    self.emitOp(.free_local_if);
                    self.emitByte(slot);
                    self.emitByte(flag_slot);
                    self.recordHint(.conditional_free, local.name, self.current_span.end, "");
                } else {
                    self.emitOp(.free_local);
                    self.emitByte(slot);
                    self.recordHint(.freed, local.name, self.current_span.end, "");
                }
                local.is_owned = false;
            }
        }
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
                        if (isHeapExpr(b.value)) {
                            self.locals[self.local_count - 1].is_owned = true;
                        }
                        if (self.needsDropFlag(b.name)) {
                            const owned_slot = self.local_count - 1;
                            self.emitConstant(Value.initInt(0));
                            self.addLocal("$drop_flag");
                            self.locals[owned_slot].drop_flag_slot = self.local_count - 1;
                        }
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
                self.emitAllDefers();
                self.emitOp(.return_);
            },
            .fail => |f| {
                self.compileExpr(f.value);
                self.emitOp(.make_error);
                self.emitAllDefers();
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
            .defer_stmt => |d| {
                if (self.defer_count >= 64) return;
                self.deferred[self.defer_count] = .{
                    .body = d.body,
                    .scope_depth = self.scope_depth,
                };
                self.defer_count += 1;
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
        self.emitOp(.index_local_local);
        self.emitByte(iter_slot);
        self.emitByte(idx_slot);
        self.addLocal(binding);

        for (body.stmts) |s| self.compileStmt(s);
        if (body.trailing) |expr| {
            self.compileExpr(expr);
            self.emitOp(.pop);
        }
        self.endScope();

        self.emitOp(.inc_local);
        self.emitByte(idx_slot);

        self.emitLoop(loop_start);
        self.patchJump(exit_jump);
        self.emitOp(.pop);

        self.endScope();
    }

    fn emitToChunk(alloc: std.mem.Allocator, ch: *@import("chunk.zig").Chunk, op: OpCode) void {
        ch.write(alloc, @intFromEnum(op), 0);
    }

    fn emitByteToChunk(alloc: std.mem.Allocator, ch: *@import("chunk.zig").Chunk, byte: u8) void {
        ch.write(alloc, byte, 0);
    }

    fn emitConstToChunk(alloc: std.mem.Allocator, ch: *@import("chunk.zig").Chunk, val: Value) void {
        const idx = ch.addConstant(alloc, val);
        ch.write(alloc, @intFromEnum(OpCode.constant), 0);
        ch.write(alloc, @intCast(idx >> 8), 0);
        ch.write(alloc, @intCast(idx & 0xFF), 0);
    }

    fn patchJumpInChunk(ch: *@import("chunk.zig").Chunk, hi_pos: usize) void {
        const target = ch.count();
        const offset = target - hi_pos - 2;
        ch.code.items[hi_pos] = @intCast(offset >> 8);
        ch.code.items[hi_pos + 1] = @intCast(offset & 0xFF);
    }

    fn emitLoopToChunk(alloc: std.mem.Allocator, ch: *@import("chunk.zig").Chunk, loop_start: usize) void {
        emitToChunk(alloc, ch, .loop_);
        const offset = ch.count() - loop_start + 2;
        emitByteToChunk(alloc, ch, @intCast(offset >> 8));
        emitByteToChunk(alloc, ch, @intCast(offset & 0xFF));
    }

    fn buildMapFunc(alloc: std.mem.Allocator) *ObjFunction {
        const func = ObjFunction.create(alloc, "map", 2);
        func.locals_only = true;
        const ch = &func.chunk;
        const len_const = ch.addConstant(alloc, ObjString.create(alloc, "len").toValue());

        emitToChunk(alloc, ch, .array_create);
        emitByteToChunk(alloc, ch, 0);
        emitToChunk(alloc, ch, .get_local);
        emitByteToChunk(alloc, ch, 1);
        emitToChunk(alloc, ch, .get_field);
        emitByteToChunk(alloc, ch, @intCast(len_const >> 8));
        emitByteToChunk(alloc, ch, @intCast(len_const & 0xFF));
        emitConstToChunk(alloc, ch, Value.initInt(0));

        const loop_start = ch.count();
        emitToChunk(alloc, ch, .get_local);
        emitByteToChunk(alloc, ch, 5);
        emitToChunk(alloc, ch, .get_local);
        emitByteToChunk(alloc, ch, 4);
        emitToChunk(alloc, ch, .less_int);
        emitToChunk(alloc, ch, .jump_if_false);
        const exit_hi = ch.count();
        emitByteToChunk(alloc, ch, 0);
        emitByteToChunk(alloc, ch, 0);
        emitToChunk(alloc, ch, .pop);
        emitToChunk(alloc, ch, .get_local);
        emitByteToChunk(alloc, ch, 2);
        emitToChunk(alloc, ch, .index_local_local);
        emitByteToChunk(alloc, ch, 1);
        emitByteToChunk(alloc, ch, 5);
        emitToChunk(alloc, ch, .call);
        emitByteToChunk(alloc, ch, 1);
        emitToChunk(alloc, ch, .get_local);
        emitByteToChunk(alloc, ch, 3);
        emitToChunk(alloc, ch, .array_push);
        emitToChunk(alloc, ch, .inc_local);
        emitByteToChunk(alloc, ch, 5);
        emitLoopToChunk(alloc, ch, loop_start);
        patchJumpInChunk(ch, exit_hi);
        emitToChunk(alloc, ch, .pop);
        emitToChunk(alloc, ch, .get_local);
        emitByteToChunk(alloc, ch, 3);
        emitToChunk(alloc, ch, .return_);
        return func;
    }

    fn buildFilterFunc(alloc: std.mem.Allocator) *ObjFunction {
        const func = ObjFunction.create(alloc, "filter", 2);
        func.locals_only = true;
        const ch = &func.chunk;
        const len_const = ch.addConstant(alloc, ObjString.create(alloc, "len").toValue());

        emitToChunk(alloc, ch, .array_create);
        emitByteToChunk(alloc, ch, 0);
        emitToChunk(alloc, ch, .get_local);
        emitByteToChunk(alloc, ch, 1);
        emitToChunk(alloc, ch, .get_field);
        emitByteToChunk(alloc, ch, @intCast(len_const >> 8));
        emitByteToChunk(alloc, ch, @intCast(len_const & 0xFF));
        emitConstToChunk(alloc, ch, Value.initInt(0));

        const loop_start = ch.count();
        emitToChunk(alloc, ch, .get_local);
        emitByteToChunk(alloc, ch, 5);
        emitToChunk(alloc, ch, .get_local);
        emitByteToChunk(alloc, ch, 4);
        emitToChunk(alloc, ch, .less_int);
        emitToChunk(alloc, ch, .jump_if_false);
        const exit_hi = ch.count();
        emitByteToChunk(alloc, ch, 0);
        emitByteToChunk(alloc, ch, 0);
        emitToChunk(alloc, ch, .pop);
        emitToChunk(alloc, ch, .index_local_local);
        emitByteToChunk(alloc, ch, 1);
        emitByteToChunk(alloc, ch, 5);
        emitToChunk(alloc, ch, .get_local);
        emitByteToChunk(alloc, ch, 2);
        emitToChunk(alloc, ch, .get_local);
        emitByteToChunk(alloc, ch, 6);
        emitToChunk(alloc, ch, .call);
        emitByteToChunk(alloc, ch, 1);
        emitToChunk(alloc, ch, .jump_if_false);
        const skip_hi = ch.count();
        emitByteToChunk(alloc, ch, 0);
        emitByteToChunk(alloc, ch, 0);
        emitToChunk(alloc, ch, .pop);
        emitToChunk(alloc, ch, .get_local);
        emitByteToChunk(alloc, ch, 6);
        emitToChunk(alloc, ch, .get_local);
        emitByteToChunk(alloc, ch, 3);
        emitToChunk(alloc, ch, .array_push);
        emitToChunk(alloc, ch, .jump);
        const end_hi = ch.count();
        emitByteToChunk(alloc, ch, 0);
        emitByteToChunk(alloc, ch, 0);
        patchJumpInChunk(ch, skip_hi);
        emitToChunk(alloc, ch, .pop);
        patchJumpInChunk(ch, end_hi);
        emitToChunk(alloc, ch, .pop);
        emitToChunk(alloc, ch, .inc_local);
        emitByteToChunk(alloc, ch, 5);
        emitLoopToChunk(alloc, ch, loop_start);
        patchJumpInChunk(ch, exit_hi);
        emitToChunk(alloc, ch, .pop);
        emitToChunk(alloc, ch, .get_local);
        emitByteToChunk(alloc, ch, 3);
        emitToChunk(alloc, ch, .return_);
        return func;
    }

    fn buildReduceFunc(alloc: std.mem.Allocator) *ObjFunction {
        const func = ObjFunction.create(alloc, "reduce", 3);
        func.locals_only = true;
        const ch = &func.chunk;
        const len_const = ch.addConstant(alloc, ObjString.create(alloc, "len").toValue());

        emitToChunk(alloc, ch, .get_local);
        emitByteToChunk(alloc, ch, 1);
        emitToChunk(alloc, ch, .get_field);
        emitByteToChunk(alloc, ch, @intCast(len_const >> 8));
        emitByteToChunk(alloc, ch, @intCast(len_const & 0xFF));
        emitConstToChunk(alloc, ch, Value.initInt(0));

        const loop_start = ch.count();
        emitToChunk(alloc, ch, .get_local);
        emitByteToChunk(alloc, ch, 5);
        emitToChunk(alloc, ch, .get_local);
        emitByteToChunk(alloc, ch, 4);
        emitToChunk(alloc, ch, .less_int);
        emitToChunk(alloc, ch, .jump_if_false);
        const exit_hi = ch.count();
        emitByteToChunk(alloc, ch, 0);
        emitByteToChunk(alloc, ch, 0);
        emitToChunk(alloc, ch, .pop);
        emitToChunk(alloc, ch, .get_local);
        emitByteToChunk(alloc, ch, 2);
        emitToChunk(alloc, ch, .get_local);
        emitByteToChunk(alloc, ch, 3);
        emitToChunk(alloc, ch, .index_local_local);
        emitByteToChunk(alloc, ch, 1);
        emitByteToChunk(alloc, ch, 5);
        emitToChunk(alloc, ch, .call);
        emitByteToChunk(alloc, ch, 2);
        emitToChunk(alloc, ch, .set_local);
        emitByteToChunk(alloc, ch, 3);
        emitToChunk(alloc, ch, .pop);
        emitToChunk(alloc, ch, .inc_local);
        emitByteToChunk(alloc, ch, 5);
        emitLoopToChunk(alloc, ch, loop_start);
        patchJumpInChunk(ch, exit_hi);
        emitToChunk(alloc, ch, .pop);
        emitToChunk(alloc, ch, .get_local);
        emitByteToChunk(alloc, ch, 3);
        emitToChunk(alloc, ch, .return_);
        return func;
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
                if (idx.target.kind == .identifier) {
                    if (self.resolveLocal(idx.target.kind.identifier)) |slot| {
                        self.compileExpr(idx.idx);
                        self.emitOp(.index_local);
                        self.emitByte(slot);
                        return;
                    }
                }
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
                const nil_jump = self.emitJump(.jump_if_nil);
                const err_jump = self.emitJump(.jump_if_error);
                const skip = self.emitJump(.jump);
                self.patchJump(nil_jump);
                self.patchJump(err_jump);
                self.emitAllDefers();
                self.emitOp(.return_);
                self.patchJump(skip);
            },
            .or_expr => |oe| self.compileOrExpr(oe),
            .unwrap_crash => |inner| {
                self.compileExpr(inner);
                const nil_jump = self.emitJump(.jump_if_nil);
                const err_jump = self.emitJump(.jump_if_error);
                const skip = self.emitJump(.jump);
                self.patchJump(nil_jump);
                self.patchJump(err_jump);
                // unwrap_error: crash with error info (prints + exits)
                self.emitOp(.unwrap_error);
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

    fn compileOrExpr(self: *Compiler, oe: ast.OrExpr) void {
        self.compileExpr(oe.lhs);
        const nil_jump = self.emitJump(.jump_if_nil);
        const err_jump = self.emitJump(.jump_if_error);
        const skip_jump = self.emitJump(.jump);

        self.patchJump(nil_jump);
        self.patchJump(err_jump);

        if (oe.err_binding) |binding_name| {
            // or |err| { body }
            // stack has nil or error_val
            // extract_error: if error_val, replace with payload; otherwise leave unchanged
            self.emitOp(.extract_error);
            self.beginScope();
            self.addLocal(binding_name);
            if (oe.rhs.kind == .block) {
                // compile block without emitting return_ for trailing expr
                const block = oe.rhs.kind.block;
                for (block.stmts) |stmt| self.compileStmt(stmt);
                if (block.trailing) |trail| {
                    self.compileExpr(trail);
                } else {
                    self.emitOp(.nil);
                }
            } else {
                self.compileExpr(oe.rhs);
            }
            self.endScopeKeepTop();
        } else {
            // simple or: pop failed value, evaluate rhs
            self.emitOp(.pop);
            self.compileExpr(oe.rhs);
        }

        self.patchJump(skip_jump);
    }

    fn compileBinary(self: *Compiler, bin: ast.Binary) void {
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

            if (self.tryInlineCall(name, call.args)) return;
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

        if (call.callee.kind == .field_access) {
            const fa = call.callee.kind.field_access;
            const is_ns = if (fa.target.kind == .identifier) self.isModuleNamespace(fa.target.kind.identifier) else false;
            if (!is_ns and self.canResolveCallable(fa.field)) {
                if (self.tryInlineUfcs(fa.field, fa.target, call.args)) return;
                self.compileGetVar(fa.field);
                self.compileExpr(fa.target);
                for (call.args) |arg| {
                    self.compileExpr(arg);
                }
                self.emitOp(.call);
                self.emitByte(@intCast(call.args.len + 1));
                return;
            }
        }

        self.compileGetExpr(call.callee);
        for (call.args) |arg| {
            self.compileExpr(arg);
        }
        self.emitOp(.call);
        self.emitByte(@intCast(call.args.len));
        self.emitDropFlags(call);
        self.recordTransferHints(call);
    }

    fn needsDropFlag(self: *Compiler, name: []const u8) bool {
        var fn_own = self.fn_own_params;
        var c: ?*Compiler = self.enclosing;
        while (c) |cur| {
            var it = cur.fn_own_params.iterator();
            while (it.next()) |entry| {
                fn_own.put(self.alloc, entry.key_ptr.*, entry.value_ptr.*) catch {};
            }
            c = cur.enclosing;
        }
        if (fn_own.count() == 0) return false;

        if (self.current_block) |block| {
            for (block.stmts) |stmt| {
                if (stmtHasOwnCallInCond(stmt, name, fn_own)) return true;
            }
        }
        return false;
    }

    fn emitDropFlags(self: *Compiler, call: ast.Call) void {
        if (self.cond_depth == 0) return;
        if (call.callee.kind != .identifier) return;
        const callee_name = call.callee.kind.identifier;

        var own_mask: u64 = 0;
        var c: ?*Compiler = self;
        while (c) |cur| {
            if (cur.fn_own_params.get(callee_name)) |mask| {
                own_mask = mask;
                break;
            }
            c = cur.enclosing;
        }
        if (own_mask == 0) return;

        for (call.args, 0..) |arg, i| {
            if (i >= 64) break;
            if ((own_mask & (@as(u64, 1) << @intCast(i))) == 0) continue;
            if (arg.kind != .identifier) continue;
            const arg_name = arg.kind.identifier;
            const slot = self.resolveLocal(arg_name) orelse continue;
            const local = &self.locals[slot];
            if (local.drop_flag_slot) |flag_slot| {
                self.emitConstant(Value.initInt(1));
                self.emitOp(.set_local);
                self.emitByte(flag_slot);
                self.emitOp(.pop);
            }
        }
    }

    fn tryInlineCall(self: *Compiler, name: []const u8, args: []const *const ast.Expr) bool {
        const decl = self.findInlineFn(name) orelse return false;
        if (args.len != decl.params.len) return false;
        if (!allSimpleArgs(args)) return false;
        self.inlineSubstitute(decl, args, null);
        return true;
    }

    fn tryInlineUfcs(self: *Compiler, name: []const u8, target: *const ast.Expr, args: []const *const ast.Expr) bool {
        const decl = self.findInlineFn(name) orelse return false;
        if (args.len + 1 != decl.params.len) return false;
        if (!isSimpleArg(target)) return false;
        if (!allSimpleArgs(args)) return false;
        self.inlineSubstitute(decl, args, target);
        return true;
    }

    fn inlineSubstitute(self: *Compiler, decl: ast.FnDecl, args: []const *const ast.Expr, ufcs_target: ?*const ast.Expr) void {
        const prev_subs = self.inline_subs;
        const prev_sub_count = self.inline_sub_count;
        defer {
            self.inline_subs = prev_subs;
            self.inline_sub_count = prev_sub_count;
        }

        var subs: [16]InlineSub = undefined;
        var count: u8 = 0;

        if (ufcs_target) |target| {
            subs[count] = .{ .name = decl.params[0].name, .expr = target };
            count += 1;
        }

        const start: usize = if (ufcs_target != null) 1 else 0;
        for (start..decl.params.len) |i| {
            subs[count] = .{ .name = decl.params[i].name, .expr = args[i - start] };
            count += 1;
        }

        self.inline_subs = &subs;
        self.inline_sub_count = count;
        self.compileExpr(decl.body.expr);
    }

    fn findInlineFn(self: *Compiler, name: []const u8) ?ast.FnDecl {
        var c: ?*Compiler = self;
        while (c) |cur| {
            if (cur.inline_fns.get(name)) |decl| return decl;
            c = cur.enclosing;
        }
        return null;
    }

    fn resolveInlineSub(self: *Compiler, name: []const u8) ?*const ast.Expr {
        const subs = self.inline_subs orelse return null;
        for (subs[0..self.inline_sub_count]) |sub| {
            if (std.mem.eql(u8, sub.name, name)) return sub.expr;
        }
        return null;
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

        self.cond_depth += 1;
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
        self.cond_depth -= 1;

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
            .hints = self.hints,
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
            .hints = self.hints,
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
        if (self.resolveInlineSub(name)) |sub_expr| {
            const prev_subs = self.inline_subs;
            const prev_count = self.inline_sub_count;
            self.inline_subs = null;
            self.inline_sub_count = 0;
            self.compileExpr(sub_expr);
            self.inline_subs = prev_subs;
            self.inline_sub_count = prev_count;
            return;
        }
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

    fn isHeapExpr(expr: *const ast.Expr) bool {
        return switch (expr.kind) {
            .struct_literal => true,
            .array_literal => true,
            .call => true,
            .string_interp => true,
            .binary => |b| {
                if (b.op == .plus) {
                    return b.lhs.kind == .string_literal or
                        b.lhs.kind == .string_interp or
                        b.rhs.kind == .string_literal or
                        b.rhs.kind == .string_interp;
                }
                return false;
            },
            else => false,
        };
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

    fn emitDeferBody(self: *Compiler, body: ast.Defer.Body) void {
        switch (body) {
            .expr => |expr| {
                self.compileExpr(expr);
                self.emitOp(.pop);
            },
            .block => |blk| {
                for (blk.stmts) |s| self.compileStmt(s);
                if (blk.trailing) |expr| {
                    self.compileExpr(expr);
                    self.emitOp(.pop);
                }
            },
        }
    }

    fn emitScopeDefers(self: *Compiler) void {
        var i: u8 = self.defer_count;
        while (i > 0) {
            i -= 1;
            if (self.deferred[i].scope_depth == self.scope_depth) {
                self.emitDeferBody(self.deferred[i].body);
            } else break;
        }
    }

    fn emitAllDefers(self: *Compiler) void {
        var i: u8 = self.defer_count;
        while (i > 0) {
            i -= 1;
            self.emitDeferBody(self.deferred[i].body);
        }
    }

    fn popScopeDefers(self: *Compiler) void {
        while (self.defer_count > 0 and self.deferred[self.defer_count - 1].scope_depth == self.scope_depth) {
            self.defer_count -= 1;
        }
    }

    fn endScope(self: *Compiler) void {
        self.emitScopeDefers();
        self.popScopeDefers();
        self.scope_depth -= 1;
        while (self.local_count > 0 and self.locals[self.local_count - 1].depth > self.scope_depth) {
            const local = self.locals[self.local_count - 1];
            if (local.is_owned) {
                if (local.drop_flag_slot) |flag_slot| {
                    self.emitOp(.free_local_if);
                    self.emitByte(self.local_count - 1);
                    self.emitByte(flag_slot);
                    self.recordHint(.conditional_free, local.name, self.current_span.end, "");
                } else {
                    self.emitOp(.free_local);
                    self.emitByte(self.local_count - 1);
                    self.recordHint(.freed, local.name, self.current_span.end, "");
                }
            }
            self.emitOp(.pop);
            self.local_count -= 1;
        }
    }

    fn endScopeKeepTop(self: *Compiler) void {
        self.emitScopeDefers();
        self.popScopeDefers();
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

    fn canResolveCallable(self: *Compiler, name: []const u8) bool {
        if (self.resolveLocal(name) != null) return true;
        if (self.resolveUpvalue(name) != null) return true;
        if (self.findFunction(name) != null) return true;
        if (self.findNative(name) != null) return true;
        return false;
    }

    // ---------------------------------------------------------------
    // emit helpers
    // ---------------------------------------------------------------

    fn chunk(self: *Compiler) *Chunk {
        return &self.function.chunk;
    }

    fn recordHint(self: *Compiler, kind: OwnershipHint.Kind, name: []const u8, offset: usize, target: []const u8) void {
        const h = self.hints orelse return;
        h.append(self.alloc, .{ .kind = kind, .name = name, .offset = offset, .target = target }) catch {};
    }

    fn recordTransferHints(self: *Compiler, call: ast.Call) void {
        if (self.hints == null) return;
        if (call.callee.kind != .identifier) return;
        const callee_name = call.callee.kind.identifier;

        var own_mask: u64 = 0;
        var c: ?*Compiler = self;
        while (c) |cur| {
            if (cur.fn_own_params.get(callee_name)) |mask| {
                own_mask = mask;
                break;
            }
            c = cur.enclosing;
        }
        if (own_mask == 0) return;

        for (call.args, 0..) |arg, i| {
            if (i >= 64) break;
            if ((own_mask & (@as(u64, 1) << @intCast(i))) == 0) continue;
            if (arg.kind != .identifier) continue;
            self.recordHint(.moved, arg.kind.identifier, self.current_span.end, callee_name);
        }
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
        self.current_span = span;
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

fn exprHasOwnCallOf(expr: *const ast.Expr, name: []const u8, fn_own: std.StringHashMapUnmanaged(u64)) bool {
    switch (expr.kind) {
        .call => |c| {
            if (c.callee.kind == .identifier) {
                const callee_name = c.callee.kind.identifier;
                if (fn_own.get(callee_name)) |mask| {
                    for (c.args, 0..) |arg, i| {
                        if (i >= 64) break;
                        if ((mask & (@as(u64, 1) << @intCast(i))) == 0) continue;
                        if (arg.kind == .identifier and std.mem.eql(u8, arg.kind.identifier, name)) return true;
                    }
                }
            }
            for (c.args) |arg| {
                if (exprHasOwnCallOf(arg, name, fn_own)) return true;
            }
            return exprHasOwnCallOf(c.callee, name, fn_own);
        },
        .binary => |b| return exprHasOwnCallOf(b.lhs, name, fn_own) or exprHasOwnCallOf(b.rhs, name, fn_own),
        .if_expr => |ie| {
            if (blockHasOwnCallOf(ie.then_block, name, fn_own)) return true;
            if (ie.else_branch) |eb| switch (eb) {
                .block => |blk| if (blockHasOwnCallOf(blk, name, fn_own)) return true,
                .else_if => |ei| if (exprHasOwnCallOf(ei, name, fn_own)) return true,
            };
            return false;
        },
        .match_expr => |me| {
            for (me.arms) |arm| {
                if (exprHasOwnCallOf(arm.body, name, fn_own)) return true;
            }
            return false;
        },
        else => return false,
    }
}

fn stmtHasOwnCallInCond(stmt: ast.Stmt, name: []const u8, fn_own: std.StringHashMapUnmanaged(u64)) bool {
    return switch (stmt.kind) {
        .expr_stmt => |e| switch (e.kind) {
            .if_expr => |ie| {
                if (blockHasOwnCallOf(ie.then_block, name, fn_own)) return true;
                if (ie.else_branch) |eb| switch (eb) {
                    .block => |blk| if (blockHasOwnCallOf(blk, name, fn_own)) return true,
                    .else_if => |ei| if (exprHasOwnCallOf(ei, name, fn_own)) return true,
                };
                return false;
            },
            .match_expr => |me| {
                for (me.arms) |arm| {
                    if (exprHasOwnCallOf(arm.body, name, fn_own)) return true;
                }
                return false;
            },
            else => false,
        },
        .for_loop => |fl| blockHasOwnCallOf(fl.body, name, fn_own),
        .while_loop => |wl| blockHasOwnCallOf(wl.body, name, fn_own),
        else => false,
    };
}

fn blockHasOwnCallOf(block: *const ast.Block, name: []const u8, fn_own: std.StringHashMapUnmanaged(u64)) bool {
    for (block.stmts) |stmt| {
        if (stmtHasOwnCallInCond(stmt, name, fn_own)) return true;
        switch (stmt.kind) {
            .expr_stmt => |e| if (exprHasOwnCallOf(e, name, fn_own)) return true,
            .binding => |b| if (exprHasOwnCallOf(b.value, name, fn_own)) return true,
            .assign => |a| if (exprHasOwnCallOf(a.value, name, fn_own)) return true,
            .compound_assign => |ca| if (exprHasOwnCallOf(ca.value, name, fn_own)) return true,
            .ret => |r| if (r.value) |v| {
                if (exprHasOwnCallOf(v, name, fn_own)) return true;
            },
            else => {},
        }
    }
    if (block.trailing) |trailing| {
        if (exprHasOwnCallOf(trailing, name, fn_own)) return true;
    }
    return false;
}

fn exprUsesName(expr: *const ast.Expr, name: []const u8) bool {
    return switch (expr.kind) {
        .identifier => |id| std.mem.eql(u8, id, name),
        .binary => |b| exprUsesName(b.lhs, name) or exprUsesName(b.rhs, name),
        .unary => |u| exprUsesName(u.operand, name),
        .field_access => |fa| exprUsesName(fa.target, name),
        .call => |c| {
            if (exprUsesName(c.callee, name)) return true;
            for (c.args) |arg| {
                if (exprUsesName(arg, name)) return true;
            }
            return false;
        },
        .index => |idx| exprUsesName(idx.target, name) or exprUsesName(idx.idx, name),
        .struct_literal => |sl| {
            for (sl.fields) |f| {
                if (exprUsesName(f.value, name)) return true;
            }
            return false;
        },
        .array_literal => |elems| {
            for (elems) |e| {
                if (exprUsesName(e, name)) return true;
            }
            return false;
        },
        .string_interp => |si| {
            for (si.parts) |part| {
                switch (part) {
                    .literal => {},
                    .expr => |e| if (exprUsesName(e, name)) return true,
                }
            }
            return false;
        },
        .if_expr => |ie| {
            if (exprUsesName(ie.condition, name)) return true;
            if (blockUsesName(ie.then_block, name)) return true;
            if (ie.else_branch) |eb| switch (eb) {
                .block => |blk| if (blockUsesName(blk, name)) return true,
                .else_if => |ei| if (exprUsesName(ei, name)) return true,
            };
            return false;
        },
        .match_expr => |me| {
            if (exprUsesName(me.subject, name)) return true;
            for (me.arms) |arm| {
                if (exprUsesName(arm.body, name)) return true;
            }
            return false;
        },
        .or_expr => |oe| exprUsesName(oe.lhs, name) or exprUsesName(oe.rhs, name),
        .try_unwrap => |inner| exprUsesName(inner, name),
        .unwrap_crash => |inner| exprUsesName(inner, name),
        .closure => |cl| {
            switch (cl.body) {
                .block => |blk| return blockUsesName(blk, name),
                .expr => |e| return exprUsesName(e, name),
            }
        },
        .spawn => |inner| exprUsesName(inner, name),
        .block => |blk| blockUsesName(blk, name),
        .pipeline => |pl| {
            for (pl.stages) |stage| {
                if (exprUsesName(stage, name)) return true;
            }
            return false;
        },
        else => false,
    };
}

fn stmtUsesName(stmt: ast.Stmt, name: []const u8) bool {
    return switch (stmt.kind) {
        .binding => |b| exprUsesName(b.value, name),
        .assign => |a| exprUsesName(a.target, name) or exprUsesName(a.value, name),
        .compound_assign => |ca| exprUsesName(ca.target, name) or exprUsesName(ca.value, name),
        .ret => |r| if (r.value) |v| exprUsesName(v, name) else false,
        .fail => |f| exprUsesName(f.value, name),
        .expr_stmt => |e| exprUsesName(e, name),
        .for_loop => |fl| exprUsesName(fl.iterator, name) or blockUsesName(fl.body, name),
        .while_loop => |wl| exprUsesName(wl.condition, name) or blockUsesName(wl.body, name),
        .arena_block => |blk| blockUsesName(blk, name),
        .defer_stmt => |d| switch (d.body) {
            .expr => |e| exprUsesName(e, name),
            .block => |blk| blockUsesName(blk, name),
        },
    };
}

fn blockUsesName(block: *const ast.Block, name: []const u8) bool {
    for (block.stmts) |stmt| {
        if (stmtUsesName(stmt, name)) return true;
    }
    if (block.trailing) |expr| {
        if (exprUsesName(expr, name)) return true;
    }
    return false;
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
            .jump, .jump_if_false, .jump_if_nil, .jump_if_error, .loop_ => i += 2,
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
            .index_local => i += 1,
            .index_local_local => i += 2,
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
            .make_error, .unwrap_error, .extract_error => {},
            .free_local => i += 1,
            .free_local_if => i += 2,
            .set_global, .define_global, .print, .println => return false,
            .spawn, .channel_create, .channel_send, .channel_recv, .await_task, .await_all, .net_accept, .net_read, .net_write, .net_connect, .net_sendto, .net_recvfrom, .ffi_call => return false,
        }
    }
    return true;
}

fn isInlineable(expr: *const ast.Expr) bool {
    return switch (expr.kind) {
        .int_literal, .float_literal, .string_literal, .bool_literal, .none_literal, .identifier => true,
        .binary => |b| isInlineable(b.lhs) and isInlineable(b.rhs),
        .unary => |u| isInlineable(u.operand),
        else => false,
    };
}

fn isSimpleArg(expr: *const ast.Expr) bool {
    return switch (expr.kind) {
        .identifier, .int_literal, .float_literal, .string_literal, .bool_literal, .none_literal => true,
        else => false,
    };
}

fn allSimpleArgs(args: []const *const ast.Expr) bool {
    for (args) |arg| {
        if (!isSimpleArg(arg)) return false;
    }
    return true;
}

test "compileForHints: owned local freed after last use" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const source =
        \\struct User {
        \\  name: str
        \\}
        \\fn main() {
        \\  u = User { name: "alice" }
        \\  println(u.name)
        \\}
    ;
    const tokens = @import("parser.zig").tokenize(alloc, source);
    var p = @import("parser.zig").Parser.init(tokens, source, alloc);
    const tree = p.parse();
    const hints = Compiler.compileForHints(alloc, tree) orelse {
        try std.testing.expect(false);
        return;
    };

    try std.testing.expect(hints.len > 0);
    try std.testing.expectEqual(OwnershipHint.Kind.freed, hints[0].kind);
    try std.testing.expectEqualStrings("u", hints[0].name);
}

test "compileForHints: ownership transfer recorded" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const source =
        \\struct Data {
        \\  val: int
        \\}
        \\fn consume(own d: Data) {
        \\  println(d.val)
        \\}
        \\fn main() {
        \\  d = Data { val: 42 }
        \\  consume(d)
        \\}
    ;
    const tokens = @import("parser.zig").tokenize(alloc, source);
    var p = @import("parser.zig").Parser.init(tokens, source, alloc);
    const tree = p.parse();
    const hints = Compiler.compileForHints(alloc, tree) orelse {
        try std.testing.expect(false);
        return;
    };

    var has_moved = false;
    for (hints) |h| {
        if (h.kind == .moved) {
            has_moved = true;
            try std.testing.expectEqualStrings("d", h.name);
            try std.testing.expectEqualStrings("consume", h.target);
        }
    }
    try std.testing.expect(has_moved);
}

test "compileForHints: conditional move has conditional_free" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const source =
        \\struct Data {
        \\  val: int
        \\}
        \\fn consume(own d: Data) {
        \\  println(d.val)
        \\}
        \\fn main() {
        \\  d = Data { val: 42 }
        \\  if d.val > 10 {
        \\    consume(d)
        \\  }
        \\  println(0)
        \\}
    ;
    const tokens = @import("parser.zig").tokenize(alloc, source);
    var p = @import("parser.zig").Parser.init(tokens, source, alloc);
    const tree = p.parse();
    const hints = Compiler.compileForHints(alloc, tree) orelse {
        try std.testing.expect(false);
        return;
    };

    var has_moved = false;
    var has_cond_free = false;
    for (hints) |h| {
        if (std.mem.eql(u8, h.name, "d")) {
            if (h.kind == .moved) has_moved = true;
            if (h.kind == .conditional_free) has_cond_free = true;
        }
    }
    try std.testing.expect(has_moved);
    try std.testing.expect(has_cond_free);
}
