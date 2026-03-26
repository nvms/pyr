# Roadmap

## Compiler Foundation

- [x] **Lexer** - tokenize .pyr source files
  - All token types: keywords, operators, literals, symbols
  - Number formats: hex, binary, octal, underscores, floats
  - String literals with escape handling
  - Comment skipping
  - 8 tests

- [x] **Parser** - recursive descent with Pratt precedence climbing
  - Declarations: fn, struct (packed), enum (generic, payloads), trait, import
  - Expressions: arithmetic, comparison, logical, calls, field access, indexing, if/else, match (patterns, guards), blocks, closures, spawn, pipeline, struct literals, coalesce (??)
  - Statements: bindings (mut/immutable/typed), assignments, compound assignments, return, for/while
  - Type expressions: named, generic, optional, pointer, slice
  - Newline handling: Go-style significance with nesting-aware suppression
  - 42 tests

- [x] **Semantic analysis** - scope analysis, name resolution, basic type checking
  - Two-phase: register declarations, then analyze bodies (forward references)
  - Scope chain with lexical scoping
  - Mutability checking, arity checking
  - Pattern binding in match arms
  - Built-in functions: println, print, sqrt, len
  - 17 tests

- [x] **Zig codegen** - transpile AST to valid Zig source
  - Functions, structs, enums (tagged unions), bindings
  - Type mapping: int->i64, float->f64, str->[]const u8, bool->bool, byte->u8
  - Control flow: if/else, match->switch, for, while
  - Pipeline desugaring to nested calls
  - Operator mapping: ??->orelse, &&->and, ||->or
  - Built-in function mapping: println/print -> std.debug.print
  - 9 tests

**Status:** Hello world compiles and runs end-to-end (.pyr -> .zig -> native binary). 77 tests passing.

## In Progress

- [ ] **CLI completion** - `pyr build` invokes zig compiler to produce native binary, `pyr run` compiles and executes

## Up Next

- [ ] **Language gaps** - array literals, string interpolation, raw/multiline strings, range expressions, enum variant constructor codegen, import/module resolution
- [ ] **Stdlib foundation** - std/io, std/fs, std/os, std/net
- [ ] **Concurrency runtime** - green threads, channels, work-stealing scheduler
- [ ] **std/http** - server module with arena-per-request memory
- [ ] **std/json** - JSON parsing and serialization
- [ ] **Package manager** - module resolution and dependency management
