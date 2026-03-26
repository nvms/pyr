const std = @import("std");
const Token = @import("token.zig").Token;

pub const Span = struct {
    start: usize,
    end: usize,
};

pub const Ast = struct {
    source: []const u8,
    items: []const Item,
    errors: []const Error,
};

pub const Error = struct {
    span: Span,
    message: []const u8,
};

pub const Item = struct {
    span: Span,
    kind: Kind,

    pub const Kind = union(enum) {
        fn_decl: FnDecl,
        struct_decl: StructDecl,
        enum_decl: EnumDecl,
        trait_decl: TraitDecl,
        import: Import,
        binding: Binding,
    };
};

pub const FnDecl = struct {
    is_pub: bool,
    name: []const u8,
    params: []const Param,
    return_type: ?*const TypeExpr,
    body: Body,

    pub const Body = union(enum) {
        block: *const Block,
        expr: *const Expr,
        none,
    };
};

pub const Param = struct {
    name: []const u8,
    type_expr: ?*const TypeExpr,
};

pub const StructDecl = struct {
    is_pub: bool,
    name: []const u8,
    is_packed: bool,
    fields: []const Field,
};

pub const Field = struct {
    name: []const u8,
    type_expr: *const TypeExpr,
};

pub const EnumDecl = struct {
    is_pub: bool,
    name: []const u8,
    type_params: []const []const u8,
    variants: []const Variant,
};

pub const Variant = struct {
    name: []const u8,
    payloads: []const *const TypeExpr,
};

pub const TraitDecl = struct {
    is_pub: bool,
    name: []const u8,
    methods: []const FnSig,
};

pub const FnSig = struct {
    name: []const u8,
    params: []const Param,
    return_type: ?*const TypeExpr,
};

pub const Import = struct {
    path: []const []const u8,
    items: []const []const u8,
    alias: ?[]const u8,
};

pub const Binding = struct {
    is_mut: bool,
    name: []const u8,
    type_expr: ?*const TypeExpr,
    value: *const Expr,
};

pub const Stmt = struct {
    span: Span,
    kind: Kind,

    pub const Kind = union(enum) {
        binding: Binding,
        assign: Assign,
        compound_assign: CompoundAssign,
        ret: Return,
        for_loop: ForLoop,
        while_loop: WhileLoop,
        expr_stmt: *const Expr,
    };
};

pub const Assign = struct {
    target: *const Expr,
    value: *const Expr,
};

pub const CompoundAssign = struct {
    op: Token.Tag,
    target: *const Expr,
    value: *const Expr,
};

pub const Return = struct {
    value: ?*const Expr,
};

pub const ForLoop = struct {
    binding: []const u8,
    iterator: *const Expr,
    body: *const Block,
};

pub const WhileLoop = struct {
    condition: *const Expr,
    body: *const Block,
};

pub const Expr = struct {
    span: Span,
    kind: Kind,

    pub const Kind = union(enum) {
        int_literal: []const u8,
        float_literal: []const u8,
        string_literal: []const u8,
        string_interp: StringInterp,
        bool_literal: bool,
        none_literal,
        identifier: []const u8,

        binary: Binary,
        unary: Unary,

        field_access: FieldAccess,
        call: Call,
        index: Index,

        if_expr: IfExpr,
        match_expr: MatchExpr,
        block: *const Block,

        closure: Closure,
        spawn: *const Expr,

        struct_literal: StructLiteral,
        pipeline: Pipeline,
        array_literal: []const *const Expr,
    };
};

pub const StringInterp = struct {
    parts: []const InterpPart,

    pub const InterpPart = union(enum) {
        literal: []const u8,
        expr: *const Expr,
    };
};

pub const Binary = struct {
    op: Token.Tag,
    lhs: *const Expr,
    rhs: *const Expr,
};

pub const Unary = struct {
    op: Op,
    operand: *const Expr,

    pub const Op = enum {
        negate,
        not,
        addr,
        addr_mut,
    };
};

pub const FieldAccess = struct {
    target: *const Expr,
    field: []const u8,
};

pub const Call = struct {
    callee: *const Expr,
    args: []const *const Expr,
};

pub const Index = struct {
    target: *const Expr,
    idx: *const Expr,
};

pub const IfExpr = struct {
    condition: *const Expr,
    then_block: *const Block,
    else_branch: ?ElseBranch,

    pub const ElseBranch = union(enum) {
        block: *const Block,
        else_if: *const Expr,
    };
};

pub const MatchExpr = struct {
    subject: *const Expr,
    arms: []const MatchArm,
};

pub const MatchArm = struct {
    pattern: Pattern,
    guard: ?*const Expr,
    body: *const Expr,
};

pub const Pattern = struct {
    kind: Kind,

    pub const Kind = union(enum) {
        identifier: []const u8,
        literal: *const Expr,
        variant: VariantPattern,
        wildcard,
    };
};

pub const VariantPattern = struct {
    name: []const u8,
    bindings: []const []const u8,
};

pub const Closure = struct {
    params: []const Param,
    body: Body,

    pub const Body = union(enum) {
        block: *const Block,
        expr: *const Expr,
    };
};

pub const StructLiteral = struct {
    name: []const u8,
    fields: []const FieldInit,
};

pub const FieldInit = struct {
    name: []const u8,
    value: *const Expr,
};

pub const Pipeline = struct {
    stages: []const *const Expr,
};

pub const Block = struct {
    stmts: []const Stmt,
    trailing: ?*const Expr,
};

pub const TypeExpr = struct {
    span: Span,
    kind: Kind,

    pub const Kind = union(enum) {
        named: []const u8,
        generic: Generic,
        optional: *const TypeExpr,
        pointer: Pointer,
        slice: *const TypeExpr,
    };
};

pub const Generic = struct {
    name: []const u8,
    args: []const *const TypeExpr,
};

pub const Pointer = struct {
    is_mut: bool,
    pointee: *const TypeExpr,
};
