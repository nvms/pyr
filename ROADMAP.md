# Roadmap

pyr is a bytecode VM language. Source compiles to bytecode, bytecode runs on a stack-based interpreter written in Zig.

## Compiler Foundation

- [x] **Lexer** - tokenize .pyr source files (8 tests)
- [x] **Parser** - recursive descent + Pratt precedence climbing (42 tests)
- [x] **Semantic analysis** - scope analysis, name resolution, basic type checking (17 tests)
- [x] **Bytecode compiler** - AST to bytecode. Each function compiles to its own chunk. Locals are slot-indexed. Two-pass: register globals, then call main()
- [x] **VM interpreter** - switch-based dispatch. CallFrame stack, value stack, global variable table (8 tests)

**Status:** Hello world runs end-to-end on the VM. 81 tests passing. Supports: integer/float arithmetic, string values, boolean logic, variable bindings, function definitions and calls, if/else control flow, comparison operators, negation, print/println.

## Architecture

```
.pyr source
  -> lexer -> tokens
  -> parser -> AST
  -> sema -> error check
  -> compiler -> bytecode (Chunk per function)
  -> VM interpreter -> output
```

**Value representation:** Tagged struct - 1 byte tag + 8 byte data. Tags: nil, bool, int (i64), float (f64), string (*ObjString), function (*ObjFunction). No NaN-boxing - clean and debuggable, optimize later if profiling shows it matters.

**Bytecode:** Single-byte opcodes with u8/u16 inline operands. Stack-based evaluation. 28 opcodes covering constants, locals, globals, arithmetic, comparison, logic, jumps, calls, return, print.

**Memory:** Arena allocator per compilation. All objects (strings, functions) are arena-allocated. No GC needed - arena freed when done.

## Up Next

- [ ] **While loops** in VM (compiler + opcodes done, needs testing)
- [ ] **Mutable variables** - `set_local`/`set_global` for `mut` bindings
- [ ] **String operations** - concatenation, length, slicing
- [ ] **Struct support** - creation, field access, field mutation
- [ ] **Enum support** - tagged union values, pattern matching
- [ ] **Closures** - upvalue capture mechanism
- [ ] **For loops** - iterator protocol or range-based
- [ ] **Module system** - import resolution

## Long-term

- [ ] **Arena-per-request** - VM-level memory model for the server runtime
- [ ] **Green threads** - cooperative scheduling, channels
- [ ] **std/http** - server module with compiled route tables
- [ ] **std/json** - parsing and serialization
- [ ] **FFI** - zero-cost calls to Zig/C libraries
- [ ] **Type-specialized opcodes** - int-specific arithmetic for known types
- [ ] **Package manager** - module resolution and dependencies
