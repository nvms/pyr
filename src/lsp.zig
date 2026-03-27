const std = @import("std");
const parser = @import("parser.zig");
const sema = @import("sema.zig");
const ast = @import("ast.zig");
const module = @import("module.zig");

const Allocator = std.mem.Allocator;

const Document = struct {
    uri: []const u8,
    content: []const u8,
    version: i64,
};

const SymbolKind = enum { function, struct_, enum_, trait, variable, parameter, import_, type_name };

const SymbolInfo = struct {
    name: []const u8,
    kind: SymbolKind,
    span: ast.Span,
    detail: []const u8,
};

pub const Server = struct {
    allocator: Allocator,
    arena: std.heap.ArenaAllocator,
    documents: std.StringHashMapUnmanaged(Document),
    initialized: bool,
    shutdown: bool,

    pub fn init(allocator: Allocator) Server {
        return .{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .documents = .{},
            .initialized = false,
            .shutdown = false,
        };
    }

    pub fn deinit(self: *Server) void {
        self.arena.deinit();
    }

    pub fn run(self: *Server) !void {
        while (!self.shutdown) {
            const msg = readMessage(self.allocator) catch |err| {
                if (err == error.EndOfStream) return;
                return err;
            };
            defer self.allocator.free(msg);
            self.handleMessage(msg);
        }
    }

    fn handleMessage(self: *Server, raw: []const u8) void {
        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, raw, .{}) catch return;
        defer parsed.deinit();

        const root = parsed.value.object;
        const method_val = root.get("method") orelse return;
        const method = switch (method_val) {
            .string => |s| s,
            else => return,
        };
        const id = root.get("id");

        if (std.mem.eql(u8, method, "initialize")) {
            self.initialized = true;
            self.respondInit(id);
        } else if (std.mem.eql(u8, method, "initialized")) {
            // noop
        } else if (std.mem.eql(u8, method, "shutdown")) {
            self.shutdown = true;
            self.respondNull(id);
        } else if (std.mem.eql(u8, method, "exit")) {
            return;
        } else if (std.mem.eql(u8, method, "textDocument/didOpen")) {
            self.handleDidOpen(root);
        } else if (std.mem.eql(u8, method, "textDocument/didChange")) {
            self.handleDidChange(root);
        } else if (std.mem.eql(u8, method, "textDocument/didClose")) {
            self.handleDidClose(root);
        } else if (std.mem.eql(u8, method, "textDocument/didSave")) {
            self.handleDidSave(root);
        } else if (std.mem.eql(u8, method, "textDocument/hover")) {
            self.handleHover(root, id);
        } else if (std.mem.eql(u8, method, "textDocument/definition")) {
            self.handleDefinition(root, id);
        } else if (std.mem.eql(u8, method, "textDocument/references")) {
            self.handleReferences(root, id);
        } else {
            if (id != null) {
                self.respondNull(id);
            }
        }
    }

    fn handleDidOpen(self: *Server, root: std.json.ObjectMap) void {
        const params = (root.get("params") orelse return).object;
        const td = (params.get("textDocument") orelse return).object;
        const uri = switch (td.get("uri") orelse return) {
            .string => |s| s,
            else => return,
        };
        const text = switch (td.get("text") orelse return) {
            .string => |s| s,
            else => return,
        };
        const version = switch (td.get("version") orelse return) {
            .integer => |n| n,
            else => return,
        };

        const alloc = self.arena.allocator();
        const uri_copy = alloc.dupe(u8, uri) catch return;
        const text_copy = alloc.dupe(u8, text) catch return;

        self.documents.put(self.allocator, uri_copy, .{
            .uri = uri_copy,
            .content = text_copy,
            .version = version,
        }) catch return;

        self.publishDiagnostics(uri_copy, text_copy);
    }

    fn handleDidChange(self: *Server, root: std.json.ObjectMap) void {
        const params = (root.get("params") orelse return).object;
        const td = (params.get("textDocument") orelse return).object;
        const uri = switch (td.get("uri") orelse return) {
            .string => |s| s,
            else => return,
        };

        const changes = switch (params.get("contentChanges") orelse return) {
            .array => |a| a,
            else => return,
        };

        if (changes.items.len == 0) return;

        const last = changes.items[changes.items.len - 1].object;
        const new_text = switch (last.get("text") orelse return) {
            .string => |s| s,
            else => return,
        };

        if (self.documents.get(uri)) |_| {
            const alloc = self.arena.allocator();
            const text_copy = alloc.dupe(u8, new_text) catch return;
            if (self.documents.getPtr(uri)) |entry| {
                entry.content = text_copy;
            }
            self.publishDiagnostics(uri, text_copy);
        }
    }

    fn handleDidClose(self: *Server, root: std.json.ObjectMap) void {
        const params = (root.get("params") orelse return).object;
        const td = (params.get("textDocument") orelse return).object;
        const uri = switch (td.get("uri") orelse return) {
            .string => |s| s,
            else => return,
        };

        _ = self.documents.remove(uri);
        self.clearDiagnostics(uri);
    }

    fn handleDidSave(self: *Server, root: std.json.ObjectMap) void {
        const params = (root.get("params") orelse return).object;
        const td = (params.get("textDocument") orelse return).object;
        const uri = switch (td.get("uri") orelse return) {
            .string => |s| s,
            else => return,
        };

        if (self.documents.get(uri)) |doc| {
            self.publishDiagnostics(uri, doc.content);
        }
    }

    fn handleHover(self: *Server, root: std.json.ObjectMap, id: ?std.json.Value) void {
        const params = (root.get("params") orelse return).object;
        const td = (params.get("textDocument") orelse return).object;
        const uri = switch (td.get("uri") orelse return) {
            .string => |s| s,
            else => return,
        };
        const position = (params.get("position") orelse return).object;
        const line = switch (position.get("line") orelse return) {
            .integer => |n| @as(u32, @intCast(n)),
            else => return,
        };
        const character = switch (position.get("character") orelse return) {
            .integer => |n| @as(u32, @intCast(n)),
            else => return,
        };

        const doc = self.documents.get(uri) orelse {
            self.respondNull(id);
            return;
        };

        var tmp_arena = std.heap.ArenaAllocator.init(self.allocator);
        defer tmp_arena.deinit();
        const alloc = tmp_arena.allocator();

        const offset = positionToOffset(doc.content, line, character);
        const name = identifierAtOffset(doc.content, offset) orelse {
            self.respondNull(id);
            return;
        };

        if (keywordHover(name)) |kw_doc| {
            self.respondHoverMarkdown(id, kw_doc);
            return;
        }

        if (builtinHover(name)) |bi_doc| {
            self.respondHoverMarkdown(id, bi_doc);
            return;
        }

        if (typeKeywordHover(name)) |ty_doc| {
            self.respondHoverMarkdown(id, ty_doc);
            return;
        }

        const tokens = parser.tokenize(alloc, doc.content);
        var p = parser.Parser.init(tokens, doc.content, alloc);
        const result = p.parse();
        if (result.errors.len > 0) {
            self.respondNull(id);
            return;
        }

        const sym = findDefinition(result.items, name, offset, doc.content) orelse {
            self.respondNull(id);
            return;
        };

        var hover_buf: [4096]u8 = undefined;
        const hover_text = buildHoverText(sym, &hover_buf);

        self.respondHoverMarkdown(id, hover_text);
    }

    fn handleReferences(self: *Server, root: std.json.ObjectMap, id: ?std.json.Value) void {
        const params = (root.get("params") orelse return).object;
        const td = (params.get("textDocument") orelse return).object;
        const uri = switch (td.get("uri") orelse return) {
            .string => |s| s,
            else => return,
        };
        const position = (params.get("position") orelse return).object;
        const line = switch (position.get("line") orelse return) {
            .integer => |n| @as(u32, @intCast(n)),
            else => return,
        };
        const character = switch (position.get("character") orelse return) {
            .integer => |n| @as(u32, @intCast(n)),
            else => return,
        };

        const doc = self.documents.get(uri) orelse {
            self.respondNull(id);
            return;
        };

        const offset = positionToOffset(doc.content, line, character);
        const name = identifierAtOffset(doc.content, offset) orelse {
            self.respondNull(id);
            return;
        };

        var escaped_uri: [2048]u8 = undefined;
        const safe_uri = jsonEscape(uri, &escaped_uri);

        var buf: [65536]u8 = undefined;
        var pos: usize = 0;
        buf[pos] = '[';
        pos += 1;

        var count: usize = 0;
        var i: usize = 0;
        while (i < doc.content.len) {
            if (i > 0 and isIdentChar(doc.content[i - 1])) {
                i += 1;
                continue;
            }
            if (std.mem.startsWith(u8, doc.content[i..], name)) {
                const end_idx = i + name.len;
                if (end_idx < doc.content.len and isIdentChar(doc.content[end_idx])) {
                    i += 1;
                    continue;
                }
                const start_pos = offsetToPosition(doc.content, i);
                const end_pos = offsetToPosition(doc.content, end_idx);

                if (count > 0) {
                    buf[pos] = ',';
                    pos += 1;
                }

                const entry = std.fmt.bufPrint(buf[pos..],
                    \\{{"uri":"{s}","range":{{"start":{{"line":{d},"character":{d}}},"end":{{"line":{d},"character":{d}}}}}}}
                , .{ safe_uri, start_pos.line, start_pos.character, end_pos.line, end_pos.character }) catch break;
                pos += entry.len;
                count += 1;
                i = end_idx;
            } else {
                i += 1;
            }
        }

        buf[pos] = ']';
        pos += 1;

        if (count == 0) {
            self.respondResult(id, "[]");
        } else {
            self.respondResult(id, buf[0..pos]);
        }
    }

    fn respondHoverMarkdown(self: *Server, id: ?std.json.Value, markdown: []const u8) void {
        var buf: [16384]u8 = undefined;
        var escaped_buf: [8192]u8 = undefined;
        const escaped = jsonEscape(markdown, &escaped_buf);
        const body = std.fmt.bufPrint(&buf,
            \\{{"contents":{{"kind":"markdown","value":"{s}"}}}}
        , .{escaped}) catch {
            self.respondNull(id);
            return;
        };
        self.respondResult(id, body);
    }

    fn handleDefinition(self: *Server, root: std.json.ObjectMap, id: ?std.json.Value) void {
        const params = (root.get("params") orelse return).object;
        const td = (params.get("textDocument") orelse return).object;
        const uri = switch (td.get("uri") orelse return) {
            .string => |s| s,
            else => return,
        };
        const position = (params.get("position") orelse return).object;
        const line = switch (position.get("line") orelse return) {
            .integer => |n| @as(u32, @intCast(n)),
            else => return,
        };
        const character = switch (position.get("character") orelse return) {
            .integer => |n| @as(u32, @intCast(n)),
            else => return,
        };

        const doc = self.documents.get(uri) orelse {
            self.respondNull(id);
            return;
        };

        var tmp_arena = std.heap.ArenaAllocator.init(self.allocator);
        defer tmp_arena.deinit();
        const alloc = tmp_arena.allocator();

        const offset = positionToOffset(doc.content, line, character);
        const name = identifierAtOffset(doc.content, offset) orelse {
            self.respondNull(id);
            return;
        };

        const tokens = parser.tokenize(alloc, doc.content);
        var p = parser.Parser.init(tokens, doc.content, alloc);
        const result = p.parse();
        if (result.errors.len > 0) {
            self.respondNull(id);
            return;
        }

        const sym = findDefinition(result.items, name, offset, doc.content) orelse {
            self.respondNull(id);
            return;
        };

        const start = offsetToPosition(doc.content, sym.span.start);
        const end = offsetToPosition(doc.content, sym.span.end);

        var escaped_uri: [2048]u8 = undefined;
        const safe_uri = jsonEscape(uri, &escaped_uri);

        var buf: [4096]u8 = undefined;
        const body = std.fmt.bufPrint(&buf,
            \\{{"uri":"{s}","range":{{"start":{{"line":{d},"character":{d}}},"end":{{"line":{d},"character":{d}}}}}}}
        , .{ safe_uri, start.line, start.character, end.line, end.character }) catch {
            self.respondNull(id);
            return;
        };

        self.respondResult(id, body);
    }

    fn publishDiagnostics(self: *Server, uri: []const u8, source: []const u8) void {
        var diag_arena = std.heap.ArenaAllocator.init(self.allocator);
        defer diag_arena.deinit();
        const alloc = diag_arena.allocator();

        const tokens = parser.tokenize(alloc, source);
        var p = parser.Parser.init(tokens, source, alloc);
        const result = p.parse();

        var diags: std.ArrayListUnmanaged(u8) = .{};
        defer diags.deinit(alloc);

        diags.appendSlice(alloc, "[") catch return;

        var count: usize = 0;

        for (result.errors) |err| {
            if (count > 0) diags.appendSlice(alloc, ",") catch return;
            appendDiagnostic(alloc, &diags, source, err.span, err.message, 1);
            count += 1;
        }

        if (result.errors.len == 0) {
            const analysis = sema.Sema.analyze(alloc, result);
            for (analysis.errors) |err| {
                if (count > 0) diags.appendSlice(alloc, ",") catch return;
                appendDiagnostic(alloc, &diags, source, err.span, err.message, 2);
                count += 1;
            }
        }

        diags.appendSlice(alloc, "]") catch return;

        self.sendNotification("textDocument/publishDiagnostics", uri, diags.items);
    }

    fn clearDiagnostics(self: *Server, uri: []const u8) void {
        self.sendNotification("textDocument/publishDiagnostics", uri, "[]");
    }

    fn respondInit(self: *Server, id: ?std.json.Value) void {
        const result =
            \\{"capabilities":{"textDocumentSync":{"openClose":true,"change":1,"save":{"includeText":false}},"hoverProvider":true,"definitionProvider":true,"referencesProvider":true}}
        ;
        self.respondResult(id, result);
    }

    fn respondNull(self: *Server, id: ?std.json.Value) void {
        self.respondResult(id, "null");
    }

    fn respondResult(_: *Server, id: ?std.json.Value, result: []const u8) void {
        var buf: [65536]u8 = undefined;

        var id_buf: [64]u8 = undefined;
        const id_str = formatId(id, &id_buf);

        const body = std.fmt.bufPrint(&buf,
            \\{{"jsonrpc":"2.0","id":{s},"result":{s}}}
        , .{ id_str, result }) catch return;

        writeMessage(body);
    }

    fn sendNotification(_: *Server, method: []const u8, uri: []const u8, diagnostics: []const u8) void {
        var buf: [65536]u8 = undefined;

        var escaped_uri: [2048]u8 = undefined;
        const safe_uri = jsonEscape(uri, &escaped_uri);

        const body = std.fmt.bufPrint(&buf,
            \\{{"jsonrpc":"2.0","method":"{s}","params":{{"uri":"{s}","diagnostics":{s}}}}}
        , .{ method, safe_uri, diagnostics }) catch return;

        writeMessage(body);
    }
};

fn appendDiagnostic(alloc: Allocator, buf: *std.ArrayListUnmanaged(u8), source: []const u8, span: ast.Span, message: []const u8, severity: u8) void {
    const start = offsetToPosition(source, span.start);
    const end_off = if (span.end > span.start) span.end else span.start + 1;
    const end = offsetToPosition(source, @min(end_off, source.len));

    var tmp: [4096]u8 = undefined;
    var escaped_buf: [2048]u8 = undefined;
    const escaped = jsonEscape(message, &escaped_buf);

    const len = std.fmt.bufPrint(&tmp,
        \\{{"range":{{"start":{{"line":{d},"character":{d}}},"end":{{"line":{d},"character":{d}}}}},"severity":{d},"source":"pyr","message":"{s}"}}
    , .{ start.line, start.character, end.line, end.character, severity, escaped }) catch return;
    buf.appendSlice(alloc, len) catch return;
}

// AST symbol finder

fn findDefinition(items: []const ast.Item, name: []const u8, cursor_offset: usize, source: []const u8) ?SymbolInfo {
    for (items) |item| {
        switch (item.kind) {
            .fn_decl => |f| {
                if (std.mem.eql(u8, f.name, name)) {
                    return .{
                        .name = f.name,
                        .kind = .function,
                        .span = item.span,
                        .detail = firstLine(source, item.span),
                    };
                }
                if (findInParams(f.params, name)) |sym| return sym;
                if (findInFnBody(f, name, cursor_offset, source)) |sym| return sym;
            },
            .struct_decl => |s| {
                if (std.mem.eql(u8, s.name, name)) {
                    return .{
                        .name = s.name,
                        .kind = .struct_,
                        .span = item.span,
                        .detail = firstLine(source, item.span),
                    };
                }
            },
            .enum_decl => |e| {
                if (std.mem.eql(u8, e.name, name)) {
                    return .{
                        .name = e.name,
                        .kind = .enum_,
                        .span = item.span,
                        .detail = firstLine(source, item.span),
                    };
                }
                for (e.variants) |v| {
                    if (std.mem.eql(u8, v.name, name)) {
                        return .{
                            .name = v.name,
                            .kind = .enum_,
                            .span = item.span,
                            .detail = firstLine(source, item.span),
                        };
                    }
                }
            },
            .trait_decl => |t| {
                if (std.mem.eql(u8, t.name, name)) {
                    return .{
                        .name = t.name,
                        .kind = .trait,
                        .span = item.span,
                        .detail = firstLine(source, item.span),
                    };
                }
            },
            .binding => |b| {
                if (std.mem.eql(u8, b.name, name)) {
                    return .{
                        .name = b.name,
                        .kind = .variable,
                        .span = item.span,
                        .detail = firstLine(source, item.span),
                    };
                }
            },
            .import => {},
            .type_alias => |ta| {
                if (std.mem.eql(u8, ta.name, name)) {
                    return .{
                        .name = ta.name,
                        .kind = .type_name,
                        .span = item.span,
                        .detail = firstLine(source, item.span),
                    };
                }
            },
            .extern_block => |eb| {
                for (eb.funcs) |f| {
                    if (std.mem.eql(u8, f.name, name)) {
                        return .{
                            .name = f.name,
                            .kind = .function,
                            .span = item.span,
                            .detail = externFnSignature(eb.lib, f),
                        };
                    }
                }
            },
        }
    }
    return null;
}

fn findInParams(params: []const ast.Param, name: []const u8) ?SymbolInfo {
    for (params) |p| {
        if (std.mem.eql(u8, p.name, name)) {
            return .{
                .name = p.name,
                .kind = .parameter,
                .span = .{ .start = 0, .end = 0 },
                .detail = if (p.type_expr != null) "parameter (typed)" else "parameter",
            };
        }
    }
    return null;
}

fn findInFnBody(f: ast.FnDecl, name: []const u8, cursor_offset: usize, source: []const u8) ?SymbolInfo {
    switch (f.body) {
        .block => |blk| return findInBlock(blk, name, cursor_offset, source),
        .expr => return null,
        .none => return null,
    }
}

fn findInBlock(blk: *const ast.Block, name: []const u8, cursor_offset: usize, source: []const u8) ?SymbolInfo {
    for (blk.stmts) |stmt| {
        switch (stmt.kind) {
            .binding => |b| {
                if (std.mem.eql(u8, b.name, name) and stmt.span.start <= cursor_offset) {
                    return .{
                        .name = b.name,
                        .kind = .variable,
                        .span = stmt.span,
                        .detail = firstLine(source, stmt.span),
                    };
                }
            },
            .for_loop => |fl| {
                if (std.mem.eql(u8, fl.binding, name)) {
                    return .{
                        .name = fl.binding,
                        .kind = .variable,
                        .span = stmt.span,
                        .detail = "for loop binding",
                    };
                }
                if (findInBlock(fl.body, name, cursor_offset, source)) |sym| return sym;
            },
            .while_loop => |wl| {
                if (findInBlock(wl.body, name, cursor_offset, source)) |sym| return sym;
            },
            .arena_block => |blk2| {
                if (findInBlock(blk2, name, cursor_offset, source)) |sym| return sym;
            },
            else => {},
        }
    }
    return null;
}

fn firstLine(source: []const u8, span: ast.Span) []const u8 {
    if (span.start >= source.len) return "";
    const start = span.start;
    var end = start;
    while (end < source.len and end < span.end and source[end] != '\n') end += 1;
    return source[start..end];
}

fn externFnSignature(lib: []const u8, f: ast.FfiFunc) []const u8 {
    _ = lib;
    _ = f;
    return "extern fn";
}

fn buildHoverText(sym: SymbolInfo, buf: []u8) []const u8 {
    var pos: usize = 0;
    const code_prefix = "```pyr\n";
    const code_suffix = "\n```";

    switch (sym.kind) {
        .function => {
            @memcpy(buf[pos..][0..code_prefix.len], code_prefix);
            pos += code_prefix.len;
            const detail_len = @min(sym.detail.len, buf.len - pos - code_suffix.len - 1);
            @memcpy(buf[pos..][0..detail_len], sym.detail[0..detail_len]);
            pos += detail_len;
            @memcpy(buf[pos..][0..code_suffix.len], code_suffix);
            pos += code_suffix.len;
        },
        .struct_ => {
            @memcpy(buf[pos..][0..code_prefix.len], code_prefix);
            pos += code_prefix.len;
            const detail_len = @min(sym.detail.len, buf.len - pos - code_suffix.len - 1);
            @memcpy(buf[pos..][0..detail_len], sym.detail[0..detail_len]);
            pos += detail_len;
            @memcpy(buf[pos..][0..code_suffix.len], code_suffix);
            pos += code_suffix.len;
        },
        .enum_ => {
            @memcpy(buf[pos..][0..code_prefix.len], code_prefix);
            pos += code_prefix.len;
            const detail_len = @min(sym.detail.len, buf.len - pos - code_suffix.len - 1);
            @memcpy(buf[pos..][0..detail_len], sym.detail[0..detail_len]);
            pos += detail_len;
            @memcpy(buf[pos..][0..code_suffix.len], code_suffix);
            pos += code_suffix.len;
        },
        .variable => {
            const inferred = inferBindingType(sym.detail);
            @memcpy(buf[pos..][0..code_prefix.len], code_prefix);
            pos += code_prefix.len;
            const detail_len = @min(sym.detail.len, buf.len - pos - code_suffix.len - inferred.len - 20);
            @memcpy(buf[pos..][0..detail_len], sym.detail[0..detail_len]);
            pos += detail_len;
            @memcpy(buf[pos..][0..code_suffix.len], code_suffix);
            pos += code_suffix.len;
            if (inferred.len > 0) {
                const sep = "\n\n**type:** `";
                const end_bt = "`";
                @memcpy(buf[pos..][0..sep.len], sep);
                pos += sep.len;
                @memcpy(buf[pos..][0..inferred.len], inferred);
                pos += inferred.len;
                @memcpy(buf[pos..][0..end_bt.len], end_bt);
                pos += end_bt.len;
            }
        },
        .parameter => {
            @memcpy(buf[pos..][0..code_prefix.len], code_prefix);
            pos += code_prefix.len;
            const detail_len = @min(sym.detail.len, buf.len - pos - code_suffix.len - 1);
            @memcpy(buf[pos..][0..detail_len], sym.detail[0..detail_len]);
            pos += detail_len;
            @memcpy(buf[pos..][0..code_suffix.len], code_suffix);
            pos += code_suffix.len;
        },
        else => {
            @memcpy(buf[pos..][0..code_prefix.len], code_prefix);
            pos += code_prefix.len;
            const detail_len = @min(sym.detail.len, buf.len - pos - code_suffix.len - 1);
            @memcpy(buf[pos..][0..detail_len], sym.detail[0..detail_len]);
            pos += detail_len;
            @memcpy(buf[pos..][0..code_suffix.len], code_suffix);
            pos += code_suffix.len;
        },
    }
    return buf[0..pos];
}

fn inferBindingType(detail: []const u8) []const u8 {
    const trimmed = std.mem.trimLeft(u8, detail, " ");
    const after_eq = blk: {
        if (std.mem.indexOf(u8, trimmed, " = ")) |idx| {
            break :blk std.mem.trimLeft(u8, trimmed[idx + 3 ..], " ");
        }
        break :blk trimmed;
    };

    if (after_eq.len == 0) return "";

    if (after_eq[0] == '"') return "str";
    if (std.mem.eql(u8, after_eq, "true") or std.mem.eql(u8, after_eq, "false")) return "bool";
    if (std.mem.eql(u8, after_eq, "nil")) return "nil";
    if (after_eq[0] == '[') return "array";

    if (after_eq[0] >= '0' and after_eq[0] <= '9') {
        for (after_eq) |c| {
            if (c == '.') return "float";
        }
        return "int";
    }

    if (std.mem.startsWith(u8, after_eq, "0x") or std.mem.startsWith(u8, after_eq, "0b") or std.mem.startsWith(u8, after_eq, "0o")) return "int";

    return "";
}

fn keywordHover(name: []const u8) ?[]const u8 {
    const keywords = std.StaticStringMap([]const u8).initComptime(.{
        .{ "fn", "```pyr\nfn name(params) -> return_type { body }\n```\n\nDeclare a function. Parameters are immutable. The last expression in the body is the return value." },
        .{ "struct", "```pyr\nstruct Name {\n  field: type\n}\n```\n\nDefine a product type. Plain data, no methods, no constructors. Fields accessed with dot syntax." },
        .{ "enum", "```pyr\nenum Name {\n  Variant(payload)\n  Other\n}\n```\n\nDefine an algebraic sum type. Variants can carry payloads. Use `match` to destructure." },
        .{ "trait", "```pyr\ntrait Name {\n  fn method(self) -> type\n}\n```\n\nDefine a structural interface. Types satisfy traits automatically via UFCS - no explicit conformance needed." },
        .{ "match", "```pyr\nmatch value {\n  Pattern(x) -> result\n  _ -> default\n}\n```\n\nPattern matching expression. Supports variant destructuring, literal patterns, guards, and wildcards." },
        .{ "if", "```pyr\nif condition {\n  body\n} else {\n  body\n}\n```\n\nConditional expression. Both branches can return values." },
        .{ "for", "```pyr\nfor item in collection { body }\nfor i in range(n) { body }\n```\n\nIterate over arrays or ranges. `range(n)`, `range(start, end)`, `range(start, end, step)` are supported." },
        .{ "while", "```pyr\nwhile condition {\n  body\n}\n```\n\nLoop while the condition is true." },
        .{ "mut", "**mut** - mutable binding\n\nVariables are immutable by default. `mut` allows reassignment.\n\n```pyr\nmut x = 0\nx = x + 1\n```" },
        .{ "pub", "**pub** - public visibility\n\nDeclarations are private by default. `pub` exports them from the module.\n\n```pyr\npub fn serve() { ... }\npub struct Config { ... }\n```" },
        .{ "imp", "```pyr\nimp std/io { println }    // selective\nimp std/net as net       // namespace\nimp mymodule             // local file\n```\n\nImport a module. Supports selective imports, namespace access, and aliasing." },
        .{ "as", "**as** - alias\n\nRename an import for use in the current module.\n\n```pyr\nimp std/net as net\n```" },
        .{ "return", "**return** - early return from a function\n\nExplicit return. Without `return`, the last expression in the body is the return value." },
        .{ "arena", "```pyr\narena {\n  // all allocations here use the arena\n}\n// freed in bulk on block exit\n```\n\nScoped memory region. All allocations inside use the arena allocator. Memory is freed in bulk when the block exits. Arenas can nest." },
        .{ "spawn", "```pyr\nspawn { work() }\n```\n\nLaunch a green thread (task). The body is compiled as a closure with upvalue capture. Tasks are cooperatively scheduled." },
        .{ "await_all", "```pyr\nresults = await_all(\n  spawn { a() },\n  spawn { b() }\n)\n```\n\nWait for multiple tasks to complete and collect their results into an array." },
        .{ "extern", "```pyr\nextern \"c\" {\n  fn getpid() -> cint\n}\n```\n\nFFI block. Declare foreign functions from shared libraries. `\"c\"` resolves to libc. Strings auto null-terminate as `cstr`." },
        .{ "in", "**in** - iteration keyword\n\nUsed with `for` loops to iterate over collections or ranges.\n\n```pyr\nfor x in arr { ... }\n```" },
        .{ "nil", "**nil** - null value\n\nThe absence of a value. Use `??` (null coalescing) to provide fallbacks, or `?` suffix for early return on nil." },
        .{ "true", "**true** - boolean literal" },
        .{ "false", "**false** - boolean literal" },
        .{ "else", "**else** - alternative branch in `if` expressions" },
    });

    return keywords.get(name);
}

fn builtinHover(name: []const u8) ?[]const u8 {
    const builtins = std.StaticStringMap([]const u8).initComptime(.{
        .{ "println", "```pyr\nprintln(value)\n```\n\nPrint a value to stdout followed by a newline." },
        .{ "print", "```pyr\nprint(value)\n```\n\nPrint a value to stdout without a trailing newline." },
        .{ "len", "```pyr\nlen(collection) -> int\n```\n\nReturn the length of an array or string (byte count for strings)." },
        .{ "push", "```pyr\npush(array, value)\n```\n\nAppend a value to the end of a mutable array." },
        .{ "pop", "```pyr\npop(array) -> value\n```\n\nRemove and return the last element of a mutable array." },
        .{ "assert", "```pyr\nassert(condition)\n```\n\nExit with an error if the condition is false." },
        .{ "assert_eq", "```pyr\nassert_eq(actual, expected)\n```\n\nExit with an error if the two values are not equal. Shows both values on failure." },
        .{ "range", "```pyr\nrange(n)              // 0 to n-1\nrange(start, end)     // start to end-1\nrange(start, end, step)\n```\n\nGenerate a sequence of integers. Used with `for` loops. Compiled to a while loop at compile time - no iterator overhead." },
        .{ "channel", "```pyr\nch = channel(capacity)\n```\n\nCreate a bounded channel for communication between tasks. `ch.send(val)` and `ch.recv()` block when full/empty." },
        .{ "sqrt", "```pyr\nsqrt(number) -> float\n```\n\nReturn the square root of a number." },
        .{ "abs", "```pyr\nabs(number) -> number\n```\n\nReturn the absolute value of a number." },
        .{ "contains", "```pyr\ncontains(haystack, needle) -> bool\n```\n\nCheck if a string contains a substring, or an array contains a value." },
        .{ "index_of", "```pyr\nindex_of(haystack, needle) -> int\n```\n\nReturn the index of the first occurrence, or -1 if not found." },
        .{ "slice", "```pyr\nslice(collection, start, end) -> collection\n```\n\nReturn a sub-array or substring from start (inclusive) to end (exclusive)." },
        .{ "join", "```pyr\njoin(array, separator) -> str\n```\n\nJoin an array of strings with a separator." },
        .{ "split", "```pyr\nsplit(string, separator) -> array\n```\n\nSplit a string by a separator into an array of strings." },
        .{ "trim", "```pyr\ntrim(string) -> str\n```\n\nRemove leading and trailing whitespace." },
        .{ "reverse", "```pyr\nreverse(array) -> array\n```\n\nReturn a reversed copy of the array." },
        .{ "starts_with", "```pyr\nstarts_with(string, prefix) -> bool\n```\n\nCheck if a string starts with the given prefix." },
        .{ "ends_with", "```pyr\nends_with(string, suffix) -> bool\n```\n\nCheck if a string ends with the given suffix." },
        .{ "replace", "```pyr\nreplace(string, old, new) -> str\n```\n\nReplace all occurrences of `old` with `new`." },
        .{ "to_upper", "```pyr\nto_upper(string) -> str\n```\n\nConvert a string to uppercase." },
        .{ "to_lower", "```pyr\nto_lower(string) -> str\n```\n\nConvert a string to lowercase." },
        .{ "map", "```pyr\nmap(array, fn(x) expr) -> array\n```\n\nApply a function to each element and return a new array." },
        .{ "filter", "```pyr\nfilter(array, fn(x) condition) -> array\n```\n\nReturn elements where the predicate returns true." },
        .{ "reduce", "```pyr\nreduce(array, initial, fn(acc, x) expr) -> value\n```\n\nReduce an array to a single value by applying a function to each element." },
    });

    return builtins.get(name);
}

fn typeKeywordHover(name: []const u8) ?[]const u8 {
    const types = std.StaticStringMap([]const u8).initComptime(.{
        .{ "int", "**int** - 64-bit signed integer (i64)\n\nThe default integer type. Literal `0`, `42`, `1_000_000`." },
        .{ "float", "**float** - 64-bit floating point (f64)\n\nThe default float type. Literal `3.14`, `0.5`." },
        .{ "str", "**str** - immutable UTF-8 string\n\nPointer + length, not null-terminated. Supports interpolation `\"hello {name}\"` and escape sequences." },
        .{ "bool", "**bool** - boolean\n\n`true` or `false`." },
        .{ "byte", "**byte** - unsigned 8-bit integer (u8)" },
        .{ "usize", "**usize** - pointer-sized unsigned integer" },
        .{ "isize", "**isize** - pointer-sized signed integer" },
        .{ "u8", "**u8** - unsigned 8-bit integer" },
        .{ "u16", "**u16** - unsigned 16-bit integer" },
        .{ "u32", "**u32** - unsigned 32-bit integer" },
        .{ "u64", "**u64** - unsigned 64-bit integer" },
        .{ "i8", "**i8** - signed 8-bit integer" },
        .{ "i16", "**i16** - signed 16-bit integer" },
        .{ "i32", "**i32** - signed 32-bit integer" },
        .{ "i64", "**i64** - signed 64-bit integer" },
        .{ "f32", "**f32** - 32-bit floating point" },
        .{ "f64", "**f64** - 64-bit floating point" },
        .{ "cint", "**cint** - C int (32-bit signed)\n\nFFI type for interop with C functions." },
        .{ "cstr", "**cstr** - C string (null-terminated)\n\nFFI type. pyr strings are automatically null-terminated when passed as `cstr`." },
        .{ "ptr", "**ptr** - raw pointer\n\nFFI type for C interop. Used in extern blocks." },
        .{ "void", "**void** - no return value\n\nFFI type for C functions that return nothing." },
    });

    return types.get(name);
}

// position utilities

const Position = struct { line: u32, character: u32 };

fn offsetToPosition(source: []const u8, offset: usize) Position {
    var line: u32 = 0;
    var character: u32 = 0;
    const clamped = @min(offset, source.len);
    for (source[0..clamped]) |c| {
        if (c == '\n') {
            line += 1;
            character = 0;
        } else {
            character += 1;
        }
    }
    return .{ .line = line, .character = character };
}

fn positionToOffset(source: []const u8, line: u32, character: u32) usize {
    var cur_line: u32 = 0;
    var cur_char: u32 = 0;
    for (source, 0..) |c, i| {
        if (cur_line == line and cur_char == character) return i;
        if (c == '\n') {
            if (cur_line == line) return i;
            cur_line += 1;
            cur_char = 0;
        } else {
            cur_char += 1;
        }
    }
    return source.len;
}

fn identifierAtOffset(source: []const u8, offset: usize) ?[]const u8 {
    if (offset >= source.len) return null;

    var start = offset;
    while (start > 0 and isIdentChar(source[start - 1])) start -= 1;
    if (!isIdentChar(source[start])) {
        if (offset + 1 < source.len and isIdentChar(source[offset + 1])) {
            start = offset + 1;
        } else {
            return null;
        }
    }

    var end = start;
    while (end < source.len and isIdentChar(source[end])) end += 1;
    if (end == start) return null;

    return source[start..end];
}

fn isIdentChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_';
}

// json/transport utilities

fn formatId(id: ?std.json.Value, buf: []u8) []const u8 {
    const val = id orelse return "null";
    return switch (val) {
        .integer => |n| std.fmt.bufPrint(buf, "{d}", .{n}) catch "null",
        .string => |s| std.fmt.bufPrint(buf, "\"{s}\"", .{s}) catch "null",
        else => "null",
    };
}

fn jsonEscape(input: []const u8, buf: []u8) []const u8 {
    var pos: usize = 0;
    for (input) |c| {
        if (pos + 2 > buf.len) break;
        switch (c) {
            '"' => {
                buf[pos] = '\\';
                buf[pos + 1] = '"';
                pos += 2;
            },
            '\\' => {
                buf[pos] = '\\';
                buf[pos + 1] = '\\';
                pos += 2;
            },
            '\n' => {
                buf[pos] = '\\';
                buf[pos + 1] = 'n';
                pos += 2;
            },
            '\r' => {
                buf[pos] = '\\';
                buf[pos + 1] = 'r';
                pos += 2;
            },
            '\t' => {
                buf[pos] = '\\';
                buf[pos + 1] = 't';
                pos += 2;
            },
            else => {
                buf[pos] = c;
                pos += 1;
            },
        }
    }
    return buf[0..pos];
}

fn readByte() !u8 {
    var buf: [1]u8 = undefined;
    const n = std.posix.read(std.posix.STDIN_FILENO, &buf) catch return error.EndOfStream;
    if (n == 0) return error.EndOfStream;
    return buf[0];
}

fn readExact(allocator: Allocator, len: usize) ![]const u8 {
    const buf = try allocator.alloc(u8, len);
    errdefer allocator.free(buf);
    var pos: usize = 0;
    while (pos < len) {
        const n = std.posix.read(std.posix.STDIN_FILENO, buf[pos..]) catch return error.EndOfStream;
        if (n == 0) return error.EndOfStream;
        pos += n;
    }
    return buf;
}

fn readMessage(allocator: Allocator) ![]const u8 {
    var content_length: usize = 0;

    while (true) {
        var line_buf: [1024]u8 = undefined;
        var line_len: usize = 0;

        while (line_len < line_buf.len) {
            const c = readByte() catch return error.EndOfStream;
            if (c == '\n') break;
            line_buf[line_len] = c;
            line_len += 1;
        }

        const trimmed = std.mem.trimRight(u8, line_buf[0..line_len], "\r");

        if (trimmed.len == 0) break;

        const prefix = "Content-Length: ";
        if (std.mem.startsWith(u8, trimmed, prefix)) {
            content_length = std.fmt.parseInt(usize, trimmed[prefix.len..], 10) catch continue;
        }
    }

    if (content_length == 0) return error.EndOfStream;

    return readExact(allocator, content_length);
}

fn writeAll(data: []const u8) void {
    var written: usize = 0;
    while (written < data.len) {
        written += std.posix.write(std.posix.STDOUT_FILENO, data[written..]) catch return;
    }
}

fn writeMessage(body: []const u8) void {
    var header_buf: [64]u8 = undefined;
    const header = std.fmt.bufPrint(&header_buf, "Content-Length: {d}\r\n\r\n", .{body.len}) catch return;
    writeAll(header);
    writeAll(body);
}
