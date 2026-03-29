const std = @import("std");
const parser = @import("parser.zig");
const sema = @import("sema.zig");
const ast = @import("ast.zig");
const module = @import("module.zig");
const compiler = @import("compiler.zig");

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
    doc: []const u8 = "",
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
        } else if (std.mem.eql(u8, method, "textDocument/inlayHint")) {
            self.handleInlayHint(root, id);
        } else if (std.mem.eql(u8, method, "textDocument/completion")) {
            self.handleCompletion(root, id);
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

        if (lookupBuiltin(name)) |sig| {
            var bi_buf: [4096]u8 = undefined;
            const bi_doc = formatBuiltinHover(name, sig, &bi_buf);
            if (bi_doc.len > 0) {
                self.respondHoverMarkdown(id, bi_doc);
                return;
            }
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

        // check for namespace-qualified stdlib calls (e.g. io.eprintln)
        const ident_start = blk: {
            var s = offset;
            while (s > 0 and isIdentChar(doc.content[s - 1])) s -= 1;
            break :blk s;
        };
        if (namespaceAtOffset(doc.content, ident_start)) |ns| {
            if (resolveNamespace(result.items, ns)) |mod_name| {
                if (lookupStdlib(mod_name, name)) |sig| {
                    var bi_buf: [4096]u8 = undefined;
                    const qualified = std.fmt.bufPrint(&bi_buf, "{s}.{s}", .{ ns, name }) catch {
                        self.respondNull(id);
                        return;
                    };
                    const qlen = qualified.len;
                    var fmt_buf: [4096]u8 = undefined;
                    const bi_doc = formatBuiltinHover(bi_buf[0..qlen], sig, &fmt_buf);
                    if (bi_doc.len > 0) {
                        self.respondHoverMarkdown(id, bi_doc);
                        return;
                    }
                }
            }
        }

        // also check for selective imports (e.g. imp std/io { eprintln })
        for (result.items) |item| {
            switch (item.kind) {
                .import => |imp| {
                    if (imp.path.len == 2 and std.mem.eql(u8, imp.path[0], "std")) {
                        for (imp.items) |imported_name| {
                            if (std.mem.eql(u8, imported_name, name)) {
                                if (lookupStdlib(imp.path[1], name)) |sig| {
                                    var bi_buf: [4096]u8 = undefined;
                                    const bi_doc = formatBuiltinHover(name, sig, &bi_buf);
                                    if (bi_doc.len > 0) {
                                        self.respondHoverMarkdown(id, bi_doc);
                                        return;
                                    }
                                }
                            }
                        }
                    }
                },
                else => {},
            }
        }

        var sym = findDefinition(result.items, name, offset, doc.content) orelse {
            self.respondNull(id);
            return;
        };

        var doc_buf: [2048]u8 = undefined;
        sym.doc = extractDocComment(doc.content, sym.span.start, &doc_buf);

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

    fn handleCompletion(self: *Server, root: std.json.ObjectMap, id: ?std.json.Value) void {
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
            self.respondResult(id, "[]");
            return;
        };

        var tmp_arena = std.heap.ArenaAllocator.init(self.allocator);
        defer tmp_arena.deinit();
        const alloc = tmp_arena.allocator();

        const offset = positionToOffset(doc.content, line, character);
        const line_text = getLineText(doc.content, line);

        // detect context from line text
        const trimmed = std.mem.trimLeft(u8, line_text, " \t");

        // import completion
        if (std.mem.startsWith(u8, trimmed, "imp ")) {
            const path_part = std.mem.trimLeft(u8, trimmed[4..], " ");
            if (std.mem.startsWith(u8, path_part, "std/")) {
                // selective import: "imp std/io { " -> complete functions
                if (std.mem.indexOf(u8, trimmed, "{")) |_| {
                    const slash = std.mem.indexOf(u8, path_part, "/") orelse 0;
                    const space = std.mem.indexOf(u8, path_part[slash + 1 ..], " ") orelse (path_part.len - slash - 1);
                    const mod_name = path_part[slash + 1 .. slash + 1 + space];
                    self.completeStdlibFunctions(id, mod_name);
                    return;
                }
                // module path: "imp std/" -> complete module names
                self.completeStdlibModules(id);
                return;
            }
            // bare "imp " -> suggest "std/" prefix
            self.completeImportRoots(id);
            return;
        }

        // namespace dot completion: "io." or "fs."
        if (offset >= 2 and doc.content[offset - 1] == '.') {
            var ns_start = offset - 1;
            while (ns_start > 0 and isIdentChar(doc.content[ns_start - 1])) ns_start -= 1;
            const ns = doc.content[ns_start .. offset - 1];
            if (ns.len > 0) {
                const tokens = parser.tokenize(alloc, doc.content);
                var p = parser.Parser.init(tokens, doc.content, alloc);
                const result = p.parse();
                if (result.errors.len == 0) {
                    if (resolveNamespace(result.items, ns)) |mod_name| {
                        self.completeStdlibFunctions(id, mod_name);
                        return;
                    }
                }
            }
        }

        // general completion: builtins + keywords + user definitions + imported stdlib
        self.completeGeneral(id, alloc, doc.content, offset);
    }

    fn completeImportRoots(self: *Server, id: ?std.json.Value) void {
        self.respondResult(id,
            \\[{"label":"std/","kind":9}]
        );
    }

    fn completeStdlibModules(self: *Server, id: ?std.json.Value) void {
        var buf: [4096]u8 = undefined;
        var pos: usize = 0;
        buf[pos] = '[';
        pos += 1;
        for (&stdlib_modules, 0..) |*m, i| {
            if (i > 0) {
                buf[pos] = ',';
                pos += 1;
            }
            const entry = std.fmt.bufPrint(buf[pos..], "{s}{s}{s}", .{
                "{\"label\":\"",
                m.name,
                "\",\"kind\":9}",
            }) catch break;
            pos += entry.len;
        }
        buf[pos] = ']';
        pos += 1;
        self.respondResult(id, buf[0..pos]);
    }

    fn completeStdlibFunctions(self: *Server, id: ?std.json.Value, mod_name: []const u8) void {
        const m = findStdlibModule(mod_name) orelse {
            self.respondResult(id, "[]");
            return;
        };
        var buf: [8192]u8 = undefined;
        var pos: usize = 0;
        buf[pos] = '[';
        pos += 1;
        for (m.functions, 0..) |entry, i| {
            if (i > 0) {
                buf[pos] = ',';
                pos += 1;
            }
            const name = entry[0];
            const sig = entry[1];
            var detail_buf: [512]u8 = undefined;
            const detail = formatSignatureLine(name, sig.overloads[0], &detail_buf);
            var escaped_detail: [1024]u8 = undefined;
            const safe_detail = jsonEscape(detail, &escaped_detail);
            var escaped_doc: [1024]u8 = undefined;
            const safe_doc = jsonEscape(sig.description, &escaped_doc);
            const item = std.fmt.bufPrint(buf[pos..],
                \\{{"label":"{s}","kind":3,"detail":"{s}","documentation":"{s}"}}
            , .{ name, safe_detail, safe_doc }) catch break;
            pos += item.len;
        }
        buf[pos] = ']';
        pos += 1;
        self.respondResult(id, buf[0..pos]);
    }

    fn completeGeneral(self: *Server, id: ?std.json.Value, alloc: std.mem.Allocator, source: []const u8, offset: usize) void {
        var buf: [32768]u8 = undefined;
        var pos: usize = 0;
        buf[pos] = '[';
        pos += 1;
        var first = true;

        // builtins
        for (&builtin_signatures) |*entry| {
            if (!first) {
                buf[pos] = ',';
                pos += 1;
            }
            first = false;
            const name = entry[0];
            const sig = entry[1];
            var detail_buf: [512]u8 = undefined;
            const detail = formatSignatureLine(name, sig.overloads[0], &detail_buf);
            var escaped_detail: [1024]u8 = undefined;
            const safe_detail = jsonEscape(detail, &escaped_detail);
            const item = std.fmt.bufPrint(buf[pos..],
                \\{{"label":"{s}","kind":3,"detail":"{s}"}}
            , .{ name, safe_detail }) catch break;
            pos += item.len;
        }

        // keywords
        const keywords = [_][]const u8{
            "fn",     "struct", "enum",   "trait",  "if",     "else",
            "for",    "while",  "return", "match",  "mut",    "imp",
            "pub",    "break",  "continue", "in",   "defer",  "spawn",
            "arena",  "fail",   "extern", "type",   "true",   "false",
            "nil",
        };
        for (&keywords) |kw| {
            if (!first) {
                buf[pos] = ',';
                pos += 1;
            }
            first = false;
            const item = std.fmt.bufPrint(buf[pos..],
                \\{{"label":"{s}","kind":14}}
            , .{kw}) catch break;
            pos += item.len;
        }

        // user-defined symbols from the current file
        const tokens = parser.tokenize(alloc, source);
        var p = parser.Parser.init(tokens, source, alloc);
        const result = p.parse();
        if (result.errors.len == 0) {
            for (result.items) |item| {
                switch (item.kind) {
                    .fn_decl => |f| {
                        if (!first) {
                            buf[pos] = ',';
                            pos += 1;
                        }
                        first = false;
                        const detail = firstLine(source, item.span);
                        var escaped: [1024]u8 = undefined;
                        const safe = jsonEscape(detail, &escaped);
                        const entry = std.fmt.bufPrint(buf[pos..],
                            \\{{"label":"{s}","kind":3,"detail":"{s}"}}
                        , .{ f.name, safe }) catch break;
                        pos += entry.len;
                    },
                    .struct_decl => |s| {
                        if (!first) {
                            buf[pos] = ',';
                            pos += 1;
                        }
                        first = false;
                        const entry = std.fmt.bufPrint(buf[pos..],
                            \\{{"label":"{s}","kind":22}}
                        , .{s.name}) catch break;
                        pos += entry.len;
                    },
                    .enum_decl => |e| {
                        if (!first) {
                            buf[pos] = ',';
                            pos += 1;
                        }
                        first = false;
                        const entry = std.fmt.bufPrint(buf[pos..],
                            \\{{"label":"{s}","kind":13}}
                        , .{e.name}) catch break;
                        pos += entry.len;
                        for (e.variants) |v| {
                            buf[pos] = ',';
                            pos += 1;
                            const ventry = std.fmt.bufPrint(buf[pos..],
                                \\{{"label":"{s}","kind":20}}
                            , .{v.name}) catch break;
                            pos += ventry.len;
                        }
                    },
                    .import => |imp| {
                        // namespace imports get a module completion entry
                        if (imp.items.len == 0 and imp.alias == null and imp.path.len == 2) {
                            if (!first) {
                                buf[pos] = ',';
                                pos += 1;
                            }
                            first = false;
                            const entry = std.fmt.bufPrint(buf[pos..],
                                \\{{"label":"{s}","kind":9}}
                            , .{imp.path[1]}) catch break;
                            pos += entry.len;
                        } else if (imp.alias) |alias| {
                            if (!first) {
                                buf[pos] = ',';
                                pos += 1;
                            }
                            first = false;
                            const entry = std.fmt.bufPrint(buf[pos..],
                                \\{{"label":"{s}","kind":9}}
                            , .{alias}) catch break;
                            pos += entry.len;
                        }
                        // selective imports: add each imported name
                        if (imp.path.len == 2 and std.mem.eql(u8, imp.path[0], "std")) {
                            for (imp.items) |imported_fn| {
                                if (lookupStdlib(imp.path[1], imported_fn)) |sig| {
                                    if (!first) {
                                        buf[pos] = ',';
                                        pos += 1;
                                    }
                                    first = false;
                                    var detail_buf: [512]u8 = undefined;
                                    const detail = formatSignatureLine(imported_fn, sig.overloads[0], &detail_buf);
                                    var escaped: [1024]u8 = undefined;
                                    const safe = jsonEscape(detail, &escaped);
                                    const entry = std.fmt.bufPrint(buf[pos..],
                                        \\{{"label":"{s}","kind":3,"detail":"{s}"}}
                                    , .{ imported_fn, safe }) catch break;
                                    pos += entry.len;
                                }
                            }
                        }
                    },
                    else => {},
                }
            }

            // also complete bindings visible at the cursor offset
            for (result.items) |item| {
                switch (item.kind) {
                    .fn_decl => |f| {
                        if (offset >= item.span.start and offset <= item.span.end) {
                            if (findBindingsInFn(f, source, alloc)) |bindings| {
                                for (bindings) |b| {
                                    if (!first) {
                                        buf[pos] = ',';
                                        pos += 1;
                                    }
                                    first = false;
                                    const entry = std.fmt.bufPrint(buf[pos..],
                                        \\{{"label":"{s}","kind":6}}
                                    , .{b}) catch break;
                                    pos += entry.len;
                                }
                            }
                        }
                    },
                    else => {},
                }
            }
        }

        buf[pos] = ']';
        pos += 1;
        self.respondResult(id, buf[0..pos]);
    }

    fn handleInlayHint(self: *Server, _: std.json.ObjectMap, id: ?std.json.Value) void {
        self.respondResult(id, "[]");
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
            \\{"capabilities":{"textDocumentSync":{"openClose":true,"change":1,"save":{"includeText":false}},"hoverProvider":true,"definitionProvider":true,"referencesProvider":true,"inlayHintProvider":true,"completionProvider":{"triggerCharacters":[".","/"," "]}}}
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
    var line = source[start..end];
    // strip trailing " {" or " =" from signatures
    if (line.len >= 2 and std.mem.endsWith(u8, line, " {")) {
        line = line[0 .. line.len - 2];
    } else if (line.len >= 2 and std.mem.endsWith(u8, line, " =")) {
        line = line[0 .. line.len - 2];
    }
    return line;
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

    if (sym.doc.len > 0 and pos + sym.doc.len + 2 < buf.len) {
        @memcpy(buf[pos..][0..2], "\n\n");
        pos += 2;
        @memcpy(buf[pos..][0..sym.doc.len], sym.doc);
        pos += sym.doc.len;
    }

    return buf[0..pos];
}

fn extractDocComment(source: []const u8, span_start: usize, buf: []u8) []const u8 {
    if (span_start == 0) return "";

    var line_starts: [64]usize = undefined;
    var line_ends: [64]usize = undefined;
    var count: usize = 0;

    var pos = span_start;

    // walk back past whitespace/newline to end of previous line's content
    while (pos > 0 and (source[pos - 1] == ' ' or source[pos - 1] == '\t' or source[pos - 1] == '\n' or source[pos - 1] == '\r')) {
        pos -= 1;
    }

    // collect comment lines going upward
    while (pos > 0 and count < 64) {
        const line_end = pos;

        // find start of this line
        var line_start = pos;
        while (line_start > 0 and source[line_start - 1] != '\n') {
            line_start -= 1;
        }

        const line = std.mem.trimLeft(u8, source[line_start..line_end], " \t");
        if (line.len >= 2 and line[0] == '/' and line[1] == '/') {
            line_starts[count] = line_start;
            line_ends[count] = line_end;
            count += 1;
            if (line_start == 0) break;
            // go to the newline before this line
            pos = line_start - 1;
            // check for blank line: if the char before the newline is also a newline, stop
            if (pos > 0 and source[pos - 1] == '\n') break;
            if (pos == 0 and source[0] == '\n') break;
            // skip trailing whitespace on the line above
            while (pos > 0 and (source[pos - 1] == ' ' or source[pos - 1] == '\t')) {
                pos -= 1;
            }
        } else {
            break;
        }
    }

    if (count == 0) return "";

    // lines are in reverse order, write them forward
    var out_pos: usize = 0;
    var i = count;
    while (i > 0) {
        i -= 1;
        const raw = source[line_starts[i]..line_ends[i]];
        const trimmed = std.mem.trimLeft(u8, raw, " \t");
        // strip the // prefix and optional leading space
        var text = trimmed[2..];
        if (text.len > 0 and text[0] == ' ') text = text[1..];

        if (out_pos + text.len + 1 >= buf.len) break;
        @memcpy(buf[out_pos..][0..text.len], text);
        out_pos += text.len;
        if (i > 0) {
            buf[out_pos] = '\n';
            out_pos += 1;
        }
    }

    return buf[0..out_pos];
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

const ParamSig = struct { name: []const u8, type_name: []const u8 };
const Overload = struct { params: []const ParamSig, return_type: ?[]const u8 };
const BuiltinSig = struct { overloads: []const Overload, description: []const u8 };

const builtin_signatures = [_]struct { []const u8, BuiltinSig }{
    .{ "println", .{
        .overloads = &.{.{ .params = &.{.{ .name = "value", .type_name = "any" }}, .return_type = null }},
        .description = "Print a value to stdout followed by a newline.",
    } },
    .{ "print", .{
        .overloads = &.{.{ .params = &.{.{ .name = "value", .type_name = "any" }}, .return_type = null }},
        .description = "Print a value to stdout without a trailing newline.",
    } },
    .{ "len", .{
        .overloads = &.{
            .{ .params = &.{.{ .name = "arr", .type_name = "[]T" }}, .return_type = "int" },
            .{ .params = &.{.{ .name = "s", .type_name = "str" }}, .return_type = "int" },
            .{ .params = &.{.{ .name = "m", .type_name = "map" }}, .return_type = "int" },
        },
        .description = "Return the length of a collection (element count for arrays/maps, byte count for strings).",
    } },
    .{ "push", .{
        .overloads = &.{.{ .params = &.{
            .{ .name = "arr", .type_name = "[]T" },
            .{ .name = "value", .type_name = "T" },
        }, .return_type = null }},
        .description = "Append a value to the end of a mutable array.",
    } },
    .{ "pop", .{
        .overloads = &.{.{ .params = &.{.{ .name = "arr", .type_name = "[]T" }}, .return_type = "T" }},
        .description = "Remove and return the last element of a mutable array.",
    } },
    .{ "assert", .{
        .overloads = &.{.{ .params = &.{.{ .name = "condition", .type_name = "bool" }}, .return_type = null }},
        .description = "Exit with an error if the condition is false.",
    } },
    .{ "assert_eq", .{
        .overloads = &.{.{ .params = &.{
            .{ .name = "actual", .type_name = "T" },
            .{ .name = "expected", .type_name = "T" },
        }, .return_type = null }},
        .description = "Exit with an error if the two values are not equal. Shows both values on failure.",
    } },
    .{ "range", .{
        .overloads = &.{
            .{ .params = &.{.{ .name = "n", .type_name = "int" }}, .return_type = "iter" },
            .{ .params = &.{
                .{ .name = "start", .type_name = "int" },
                .{ .name = "end", .type_name = "int" },
            }, .return_type = "iter" },
            .{ .params = &.{
                .{ .name = "start", .type_name = "int" },
                .{ .name = "end", .type_name = "int" },
                .{ .name = "step", .type_name = "int" },
            }, .return_type = "iter" },
        },
        .description = "Generate a sequence of integers. Used with `for` loops. Compiled to a while loop - no iterator overhead.",
    } },
    .{ "channel", .{
        .overloads = &.{.{ .params = &.{.{ .name = "capacity", .type_name = "int" }}, .return_type = "channel" }},
        .description = "Create a bounded channel for communication between tasks. `ch.send(val)` and `ch.recv()` block when full/empty.",
    } },
    .{ "sqrt", .{
        .overloads = &.{.{ .params = &.{.{ .name = "n", .type_name = "number" }}, .return_type = "float" }},
        .description = "Return the square root of a number.",
    } },
    .{ "abs", .{
        .overloads = &.{.{ .params = &.{.{ .name = "n", .type_name = "number" }}, .return_type = "number" }},
        .description = "Return the absolute value of a number.",
    } },
    .{ "int", .{
        .overloads = &.{.{ .params = &.{.{ .name = "value", .type_name = "any" }}, .return_type = "int" }},
        .description = "Convert a value to an integer. Truncates floats, parses strings.",
    } },
    .{ "float", .{
        .overloads = &.{.{ .params = &.{.{ .name = "value", .type_name = "any" }}, .return_type = "float" }},
        .description = "Convert a value to a float. Parses strings, promotes integers.",
    } },
    .{ "contains", .{
        .overloads = &.{
            .{ .params = &.{
                .{ .name = "arr", .type_name = "[]T" },
                .{ .name = "value", .type_name = "T" },
            }, .return_type = "bool" },
            .{ .params = &.{
                .{ .name = "s", .type_name = "str" },
                .{ .name = "substr", .type_name = "str" },
            }, .return_type = "bool" },
            .{ .params = &.{
                .{ .name = "m", .type_name = "map" },
                .{ .name = "key", .type_name = "str" },
            }, .return_type = "bool" },
        },
        .description = "Check if a collection contains a value, substring, or key.",
    } },
    .{ "index_of", .{
        .overloads = &.{
            .{ .params = &.{
                .{ .name = "arr", .type_name = "[]T" },
                .{ .name = "value", .type_name = "T" },
            }, .return_type = "int" },
            .{ .params = &.{
                .{ .name = "s", .type_name = "str" },
                .{ .name = "substr", .type_name = "str" },
            }, .return_type = "int" },
        },
        .description = "Return the index of the first occurrence, or -1 if not found.",
    } },
    .{ "slice", .{
        .overloads = &.{
            .{ .params = &.{
                .{ .name = "arr", .type_name = "[]T" },
                .{ .name = "start", .type_name = "int" },
                .{ .name = "end", .type_name = "int" },
            }, .return_type = "[]T" },
            .{ .params = &.{
                .{ .name = "s", .type_name = "str" },
                .{ .name = "start", .type_name = "int" },
                .{ .name = "end", .type_name = "int" },
            }, .return_type = "str" },
        },
        .description = "Return a sub-array or substring from start (inclusive) to end (exclusive).",
    } },
    .{ "join", .{
        .overloads = &.{.{ .params = &.{
            .{ .name = "arr", .type_name = "[]str" },
            .{ .name = "sep", .type_name = "str" },
        }, .return_type = "str" }},
        .description = "Join an array of strings with a separator.",
    } },
    .{ "split", .{
        .overloads = &.{.{ .params = &.{
            .{ .name = "s", .type_name = "str" },
            .{ .name = "sep", .type_name = "str" },
        }, .return_type = "[]str" }},
        .description = "Split a string by a separator into an array of strings.",
    } },
    .{ "trim", .{
        .overloads = &.{.{ .params = &.{.{ .name = "s", .type_name = "str" }}, .return_type = "str" }},
        .description = "Remove leading and trailing whitespace.",
    } },
    .{ "reverse", .{
        .overloads = &.{.{ .params = &.{.{ .name = "arr", .type_name = "[]T" }}, .return_type = "[]T" }},
        .description = "Return a reversed copy of the array.",
    } },
    .{ "starts_with", .{
        .overloads = &.{.{ .params = &.{
            .{ .name = "s", .type_name = "str" },
            .{ .name = "prefix", .type_name = "str" },
        }, .return_type = "bool" }},
        .description = "Check if a string starts with the given prefix.",
    } },
    .{ "ends_with", .{
        .overloads = &.{.{ .params = &.{
            .{ .name = "s", .type_name = "str" },
            .{ .name = "suffix", .type_name = "str" },
        }, .return_type = "bool" }},
        .description = "Check if a string ends with the given suffix.",
    } },
    .{ "replace", .{
        .overloads = &.{.{ .params = &.{
            .{ .name = "s", .type_name = "str" },
            .{ .name = "old", .type_name = "str" },
            .{ .name = "new", .type_name = "str" },
        }, .return_type = "str" }},
        .description = "Replace all occurrences of `old` with `new`.",
    } },
    .{ "to_upper", .{
        .overloads = &.{.{ .params = &.{.{ .name = "s", .type_name = "str" }}, .return_type = "str" }},
        .description = "Convert a string to uppercase.",
    } },
    .{ "to_lower", .{
        .overloads = &.{.{ .params = &.{.{ .name = "s", .type_name = "str" }}, .return_type = "str" }},
        .description = "Convert a string to lowercase.",
    } },
    .{ "clone", .{
        .overloads = &.{.{ .params = &.{.{ .name = "value", .type_name = "T" }}, .return_type = "T" }},
        .description = "Deep copy a heap-allocated value (struct, array, enum, string). The clone is independently owned. Works with UFCS: `val.clone()`.",
    } },
    .{ "getattr", .{
        .overloads = &.{.{ .params = &.{
            .{ .name = "obj", .type_name = "struct" },
            .{ .name = "name", .type_name = "str" },
        }, .return_type = "any?" }},
        .description = "Get a struct field by name at runtime. Returns nil if the field does not exist.",
    } },
    .{ "keys", .{
        .overloads = &.{
            .{ .params = &.{.{ .name = "obj", .type_name = "struct" }}, .return_type = "[]str" },
            .{ .params = &.{.{ .name = "m", .type_name = "map" }}, .return_type = "[]str" },
        },
        .description = "Return the field names of a struct or keys of a map as an array of strings.",
    } },
    .{ "type_of", .{
        .overloads = &.{.{ .params = &.{.{ .name = "value", .type_name = "any" }}, .return_type = "str" }},
        .description = "Return the type name: \"null\", \"boolean\", \"number\", \"string\", \"array\", \"object\", \"map\".",
    } },
    .{ "map", .{
        .overloads = &.{.{ .params = &.{
            .{ .name = "arr", .type_name = "[]T" },
            .{ .name = "f", .type_name = "fn(T) -> U" },
        }, .return_type = "[]U" }},
        .description = "Apply a function to each element and return a new array.",
    } },
    .{ "filter", .{
        .overloads = &.{.{ .params = &.{
            .{ .name = "arr", .type_name = "[]T" },
            .{ .name = "f", .type_name = "fn(T) -> bool" },
        }, .return_type = "[]T" }},
        .description = "Return elements where the predicate returns true.",
    } },
    .{ "reduce", .{
        .overloads = &.{.{ .params = &.{
            .{ .name = "arr", .type_name = "[]T" },
            .{ .name = "initial", .type_name = "U" },
            .{ .name = "f", .type_name = "fn(U, T) -> U" },
        }, .return_type = "U" }},
        .description = "Reduce an array to a single value by applying a function to each element.",
    } },
    .{ "sort", .{
        .overloads = &.{.{ .params = &.{.{ .name = "arr", .type_name = "[]T" }}, .return_type = "[]T" }},
        .description = "Return a sorted copy of the array. Elements must be comparable.",
    } },
    .{ "sort_by", .{
        .overloads = &.{.{ .params = &.{
            .{ .name = "arr", .type_name = "[]T" },
            .{ .name = "f", .type_name = "fn(T, T) -> bool" },
        }, .return_type = "[]T" }},
        .description = "Return a sorted copy using a comparator. `fn(a, b)` returns true if a should come before b.",
    } },
    .{ "delete", .{
        .overloads = &.{.{ .params = &.{
            .{ .name = "m", .type_name = "map" },
            .{ .name = "key", .type_name = "str" },
        }, .return_type = "bool" }},
        .description = "Remove a key from a map. Returns true if the key existed.",
    } },
    .{ "await_all", .{
        .overloads = &.{.{ .params = &.{.{ .name = "tasks", .type_name = "...task" }}, .return_type = "[]any" }},
        .description = "Wait for multiple spawned tasks to complete and collect their results into an array.",
    } },
};

fn lookupBuiltin(name: []const u8) ?BuiltinSig {
    for (&builtin_signatures) |*entry| {
        if (std.mem.eql(u8, entry[0], name)) return entry[1];
    }
    return null;
}

const StdlibModule = struct {
    name: []const u8,
    functions: []const struct { []const u8, BuiltinSig },
};

const stdlib_modules = [_]StdlibModule{
    .{ .name = "io", .functions = &.{
        .{ "println", .{ .overloads = &.{.{ .params = &.{.{ .name = "value", .type_name = "any" }}, .return_type = null }}, .description = "Print a value to stdout followed by a newline." } },
        .{ "print", .{ .overloads = &.{.{ .params = &.{.{ .name = "value", .type_name = "any" }}, .return_type = null }}, .description = "Print a value to stdout without a trailing newline." } },
        .{ "eprintln", .{ .overloads = &.{.{ .params = &.{.{ .name = "value", .type_name = "any" }}, .return_type = null }}, .description = "Print a value to stderr followed by a newline." } },
        .{ "eprint", .{ .overloads = &.{.{ .params = &.{.{ .name = "value", .type_name = "any" }}, .return_type = null }}, .description = "Print a value to stderr without a trailing newline." } },
        .{ "readln", .{ .overloads = &.{.{ .params = &.{}, .return_type = "str" }}, .description = "Read a line from stdin." } },
    } },
    .{ .name = "fs", .functions = &.{
        .{ "read", .{ .overloads = &.{.{ .params = &.{.{ .name = "path", .type_name = "str" }}, .return_type = "str" }}, .description = "Read the entire contents of a file as a string." } },
        .{ "write", .{ .overloads = &.{.{ .params = &.{.{ .name = "path", .type_name = "str" }, .{ .name = "content", .type_name = "str" }}, .return_type = null }}, .description = "Write a string to a file, replacing any existing content." } },
        .{ "append", .{ .overloads = &.{.{ .params = &.{.{ .name = "path", .type_name = "str" }, .{ .name = "content", .type_name = "str" }}, .return_type = null }}, .description = "Append a string to a file." } },
        .{ "exists", .{ .overloads = &.{.{ .params = &.{.{ .name = "path", .type_name = "str" }}, .return_type = "bool" }}, .description = "Check if a file exists at the given path." } },
        .{ "remove", .{ .overloads = &.{.{ .params = &.{.{ .name = "path", .type_name = "str" }}, .return_type = null }}, .description = "Delete a file." } },
    } },
    .{ .name = "os", .functions = &.{
        .{ "env", .{ .overloads = &.{.{ .params = &.{.{ .name = "key", .type_name = "str" }}, .return_type = "str?" }}, .description = "Get an environment variable. Returns nil if not set." } },
        .{ "args", .{ .overloads = &.{.{ .params = &.{}, .return_type = "[]str" }}, .description = "Get command-line arguments as an array of strings." } },
        .{ "exit", .{ .overloads = &.{.{ .params = &.{.{ .name = "code", .type_name = "int" }}, .return_type = null }}, .description = "Exit the process with the given status code." } },
    } },
    .{ .name = "json", .functions = &.{
        .{ "encode", .{ .overloads = &.{.{ .params = &.{.{ .name = "value", .type_name = "any" }}, .return_type = "str" }}, .description = "Serialize a value to a JSON string." } },
        .{ "decode", .{ .overloads = &.{.{ .params = &.{.{ .name = "s", .type_name = "str" }}, .return_type = "any?" }}, .description = "Parse a JSON string into a value. Returns nil on parse failure." } },
    } },
    .{ .name = "net", .functions = &.{
        .{ "listen", .{ .overloads = &.{.{ .params = &.{.{ .name = "host", .type_name = "str" }, .{ .name = "port", .type_name = "int" }}, .return_type = "socket!" }}, .description = "Bind and listen on a TCP address." } },
        .{ "accept", .{ .overloads = &.{.{ .params = &.{.{ .name = "server", .type_name = "socket" }}, .return_type = "socket!" }}, .description = "Accept an incoming TCP connection." } },
        .{ "connect", .{ .overloads = &.{.{ .params = &.{.{ .name = "host", .type_name = "str" }, .{ .name = "port", .type_name = "int" }}, .return_type = "socket!" }}, .description = "Open a TCP connection to a remote address." } },
        .{ "read", .{ .overloads = &.{.{ .params = &.{.{ .name = "conn", .type_name = "socket" }}, .return_type = "str!" }}, .description = "Read data from a socket. Returns IoError on failure." } },
        .{ "write", .{ .overloads = &.{.{ .params = &.{.{ .name = "conn", .type_name = "socket" }, .{ .name = "data", .type_name = "str" }}, .return_type = "bool!" }}, .description = "Write data to a socket." } },
        .{ "close", .{ .overloads = &.{.{ .params = &.{.{ .name = "conn", .type_name = "socket" }}, .return_type = null }}, .description = "Close a socket." } },
        .{ "timeout", .{ .overloads = &.{.{ .params = &.{.{ .name = "conn", .type_name = "socket" }, .{ .name = "ms", .type_name = "int" }}, .return_type = null }}, .description = "Set a read/write timeout on a socket in milliseconds." } },
        .{ "udp_bind", .{ .overloads = &.{.{ .params = &.{.{ .name = "host", .type_name = "str" }, .{ .name = "port", .type_name = "int" }}, .return_type = "socket!" }}, .description = "Bind a UDP socket to an address." } },
        .{ "udp_open", .{ .overloads = &.{.{ .params = &.{}, .return_type = "socket!" }}, .description = "Open an unbound UDP socket." } },
        .{ "sendto", .{ .overloads = &.{.{ .params = &.{.{ .name = "sock", .type_name = "socket" }, .{ .name = "data", .type_name = "str" }, .{ .name = "host", .type_name = "str" }, .{ .name = "port", .type_name = "int" }}, .return_type = "bool!" }}, .description = "Send a UDP datagram to a specific address." } },
        .{ "recvfrom", .{ .overloads = &.{.{ .params = &.{.{ .name = "sock", .type_name = "socket" }}, .return_type = "str!" }}, .description = "Receive a UDP datagram." } },
    } },
    .{ .name = "http", .functions = &.{
        .{ "parse_request", .{ .overloads = &.{.{ .params = &.{.{ .name = "raw", .type_name = "str" }}, .return_type = "request?" }}, .description = "Parse a raw HTTP request string into a request object with method, path, headers, and body." } },
        .{ "respond", .{ .overloads = &.{.{ .params = &.{.{ .name = "conn", .type_name = "socket" }}, .return_type = null }}, .description = "Send a 200 OK response." } },
        .{ "respond_status", .{ .overloads = &.{.{ .params = &.{.{ .name = "conn", .type_name = "socket" }, .{ .name = "status", .type_name = "int" }}, .return_type = null }}, .description = "Send an HTTP response with the given status code." } },
        .{ "json_response", .{ .overloads = &.{.{ .params = &.{.{ .name = "conn", .type_name = "socket" }}, .return_type = null }}, .description = "Send a JSON response with Content-Type: application/json." } },
        .{ "route", .{ .overloads = &.{.{ .params = &.{.{ .name = "method", .type_name = "str" }, .{ .name = "path", .type_name = "str" }, .{ .name = "request", .type_name = "request" }}, .return_type = "bool" }}, .description = "Check if a request matches a method and path." } },
        .{ "match_route", .{ .overloads = &.{.{ .params = &.{.{ .name = "method", .type_name = "str" }, .{ .name = "pattern", .type_name = "str" }, .{ .name = "request", .type_name = "request" }}, .return_type = "[]str?" }}, .description = "Match a request against a route pattern with `:param` segments. Returns captured values or nil." } },
    } },
    .{ .name = "tls", .functions = &.{
        .{ "upgrade", .{ .overloads = &.{.{ .params = &.{.{ .name = "conn", .type_name = "socket" }, .{ .name = "hostname", .type_name = "str" }}, .return_type = "tls_conn!" }}, .description = "Upgrade a TCP connection to TLS (client mode)." } },
        .{ "context", .{ .overloads = &.{.{ .params = &.{.{ .name = "cert_path", .type_name = "str" }, .{ .name = "key_path", .type_name = "str" }}, .return_type = "tls_ctx!" }}, .description = "Create a TLS server context from certificate and key files." } },
    } },
    .{ .name = "gc", .functions = &.{
        .{ "pause", .{ .overloads = &.{.{ .params = &.{}, .return_type = null }}, .description = "Pause automatic garbage collection." } },
        .{ "resume", .{ .overloads = &.{.{ .params = &.{}, .return_type = null }}, .description = "Resume automatic garbage collection." } },
        .{ "collect", .{ .overloads = &.{.{ .params = &.{}, .return_type = "int" }}, .description = "Run a garbage collection cycle. Returns the number of objects freed." } },
        .{ "stats", .{ .overloads = &.{.{ .params = &.{}, .return_type = "str" }}, .description = "Return GC statistics as a formatted string." } },
    } },
};

fn lookupStdlib(mod_name: []const u8, fn_name: []const u8) ?BuiltinSig {
    for (&stdlib_modules) |*m| {
        if (std.mem.eql(u8, m.name, mod_name)) {
            for (m.functions) |*entry| {
                if (std.mem.eql(u8, entry[0], fn_name)) return entry[1];
            }
            return null;
        }
    }
    return null;
}

fn findStdlibModule(name: []const u8) ?*const StdlibModule {
    for (&stdlib_modules) |*m| {
        if (std.mem.eql(u8, m.name, name)) return m;
    }
    return null;
}

fn formatBuiltinHover(name: []const u8, sig: BuiltinSig, buf: []u8) []const u8 {
    var pos: usize = 0;

    const prefix = "```pyr\n";
    @memcpy(buf[pos..][0..prefix.len], prefix);
    pos += prefix.len;

    for (sig.overloads, 0..) |overload, i| {
        if (i > 0) {
            buf[pos] = '\n';
            pos += 1;
        }

        @memcpy(buf[pos..][0..name.len], name);
        pos += name.len;
        buf[pos] = '(';
        pos += 1;

        for (overload.params, 0..) |param, j| {
            if (j > 0) {
                @memcpy(buf[pos..][0..2], ", ");
                pos += 2;
            }
            @memcpy(buf[pos..][0..param.name.len], param.name);
            pos += param.name.len;
            @memcpy(buf[pos..][0..2], ": ");
            pos += 2;
            @memcpy(buf[pos..][0..param.type_name.len], param.type_name);
            pos += param.type_name.len;
        }
        buf[pos] = ')';
        pos += 1;

        if (overload.return_type) |rt| {
            @memcpy(buf[pos..][0..4], " -> ");
            pos += 4;
            @memcpy(buf[pos..][0..rt.len], rt);
            pos += rt.len;
        }
    }

    const suffix = "\n```\n\n";
    @memcpy(buf[pos..][0..suffix.len], suffix);
    pos += suffix.len;

    @memcpy(buf[pos..][0..sig.description.len], sig.description);
    pos += sig.description.len;

    return buf[0..pos];
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

fn getLineText(source: []const u8, line_num: u32) []const u8 {
    var cur_line: u32 = 0;
    var start: usize = 0;
    for (source, 0..) |c, i| {
        if (cur_line == line_num) {
            if (c == '\n') return source[start..i];
        } else if (c == '\n') {
            cur_line += 1;
            start = i + 1;
        }
    }
    if (cur_line == line_num) return source[start..];
    return "";
}

fn formatSignatureLine(name: []const u8, overload: Overload, buf: []u8) []const u8 {
    var pos: usize = 0;
    @memcpy(buf[pos..][0..name.len], name);
    pos += name.len;
    buf[pos] = '(';
    pos += 1;
    for (overload.params, 0..) |param, j| {
        if (j > 0) {
            @memcpy(buf[pos..][0..2], ", ");
            pos += 2;
        }
        @memcpy(buf[pos..][0..param.name.len], param.name);
        pos += param.name.len;
        @memcpy(buf[pos..][0..2], ": ");
        pos += 2;
        @memcpy(buf[pos..][0..param.type_name.len], param.type_name);
        pos += param.type_name.len;
    }
    buf[pos] = ')';
    pos += 1;
    if (overload.return_type) |rt| {
        @memcpy(buf[pos..][0..4], " -> ");
        pos += 4;
        @memcpy(buf[pos..][0..rt.len], rt);
        pos += rt.len;
    }
    return buf[0..pos];
}

fn findBindingsInFn(f: ast.FnDecl, source: []const u8, alloc: std.mem.Allocator) ?[]const []const u8 {
    _ = source;
    const body_block = switch (f.body) {
        .block => |b| b,
        else => return null,
    };
    var names: std.ArrayListUnmanaged([]const u8) = .{};
    for (f.params) |param| {
        names.append(alloc, param.name) catch {};
    }
    collectBindings(body_block, &names, alloc);
    if (names.items.len == 0) return null;
    return names.toOwnedSlice(alloc) catch null;
}

fn collectBindings(block: *const ast.Block, names: *std.ArrayListUnmanaged([]const u8), alloc: std.mem.Allocator) void {
    for (block.stmts) |stmt| {
        switch (stmt.kind) {
            .binding => |b| names.append(alloc, b.name) catch {},
            .for_loop => |fl| {
                names.append(alloc, fl.binding) catch {};
                collectBindings(fl.body, names, alloc);
            },
            .while_loop => |wl| collectBindings(wl.body, names, alloc),
            .arena_block => |ab| collectBindings(ab, names, alloc),
            else => {},
        }
    }
}

fn namespaceAtOffset(source: []const u8, ident_start: usize) ?[]const u8 {
    if (ident_start < 2) return null;
    if (source[ident_start - 1] != '.') return null;
    const end = ident_start - 1;
    var start = end;
    while (start > 0 and isIdentChar(source[start - 1])) start -= 1;
    if (start == end) return null;
    return source[start..end];
}

fn resolveNamespace(items: []const ast.Item, ns: []const u8) ?[]const u8 {
    for (items) |item| {
        switch (item.kind) {
            .import => |imp| {
                if (imp.path.len == 2 and std.mem.eql(u8, imp.path[0], "std")) {
                    if (imp.alias) |alias| {
                        if (std.mem.eql(u8, alias, ns)) return imp.path[1];
                    } else if (imp.items.len == 0) {
                        if (std.mem.eql(u8, imp.path[1], ns)) return imp.path[1];
                    }
                }
            },
            else => {},
        }
    }
    return null;
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

test "builtin hover: single overload" {
    const sig = lookupBuiltin("trim") orelse return error.NotFound;
    var buf: [4096]u8 = undefined;
    const text = formatBuiltinHover("trim", sig, &buf);
    try std.testing.expectEqualStrings(
        "```pyr\ntrim(s: str) -> str\n```\n\nRemove leading and trailing whitespace.",
        text,
    );
}

test "builtin hover: multiple overloads" {
    const sig = lookupBuiltin("len") orelse return error.NotFound;
    var buf: [4096]u8 = undefined;
    const text = formatBuiltinHover("len", sig, &buf);
    try std.testing.expectEqualStrings(
        "```pyr\nlen(arr: []T) -> int\nlen(s: str) -> int\nlen(m: map) -> int\n```\n\n" ++
            "Return the length of a collection (element count for arrays/maps, byte count for strings).",
        text,
    );
}

test "builtin hover: no return type" {
    const sig = lookupBuiltin("println") orelse return error.NotFound;
    var buf: [4096]u8 = undefined;
    const text = formatBuiltinHover("println", sig, &buf);
    try std.testing.expectEqualStrings(
        "```pyr\nprintln(value: any)\n```\n\nPrint a value to stdout followed by a newline.",
        text,
    );
}

test "doc comment: single line" {
    const source = "// adds two numbers\nfn add(a, b) = a + b";
    var buf: [2048]u8 = undefined;
    const doc = extractDocComment(source, 20, &buf);
    try std.testing.expectEqualStrings("adds two numbers", doc);
}

test "doc comment: multi-line" {
    const source = "// first line\n// second line\nfn foo() = 1";
    var buf: [2048]u8 = undefined;
    const doc = extractDocComment(source, 29, &buf);
    try std.testing.expectEqualStrings("first line\nsecond line", doc);
}

test "doc comment: no comment" {
    const source = "x = 5\nfn foo() = 1";
    var buf: [2048]u8 = undefined;
    const doc = extractDocComment(source, 6, &buf);
    try std.testing.expectEqualStrings("", doc);
}

test "doc comment: gap breaks collection" {
    const source = "// orphan\n\n// real doc\nfn foo() = 1";
    var buf: [2048]u8 = undefined;
    const doc = extractDocComment(source, 23, &buf);
    try std.testing.expectEqualStrings("real doc", doc);
}

test "builtin hover: all builtins resolve" {
    const names = [_][]const u8{
        "println",    "print",      "len",       "push",       "pop",
        "assert",     "assert_eq",  "range",     "channel",    "sqrt",
        "abs",        "int",        "float",     "contains",   "index_of",
        "slice",      "join",       "split",     "trim",       "reverse",
        "starts_with", "ends_with", "replace",   "to_upper",   "to_lower",
        "clone",      "getattr",    "keys",      "type_of",    "map",
        "filter",     "reduce",     "sort",      "sort_by",    "delete",
        "await_all",
    };
    for (&names) |name| {
        const sig = lookupBuiltin(name) orelse {
            std.debug.print("missing builtin: {s}\n", .{name});
            return error.MissingBuiltin;
        };
        var buf: [4096]u8 = undefined;
        const text = formatBuiltinHover(name, sig, &buf);
        try std.testing.expect(text.len > 0);
    }
}
