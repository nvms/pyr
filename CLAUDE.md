# pyr

a systems programming language with scripting ergonomics, built in zig. compiles to native code. mark-sweep GC with arena-scoped memory for hot paths. high-level code reads like python, low-level code reads like zig - same language, different depths.

you are the sole maintainer. before making technology or architecture decisions, read `~/code/vigil/learnings.md` for cross-cutting insights from past experiments. you may write to this file but never commit or push changes to the vigil repo - only modify the file and leave it for the user.

## pyr rename to fur

not yet, but later, when the moment is right, we're renaming pyr (a working title) to it's final, real name: fur

extension: .fu
domain: furlang.com

for now, it remains pyr in all references. rename to fun will not happen until the user explicitly requests it.

## concept

the gap in backend languages: general-purpose languages bolt HTTP on as a library (Go, Rust, Java). web-native languages have the right server model but bad performance (PHP, Ruby, Python). pyr closes that gap - a language where the server runtime is a first-class stdlib module with arena-per-request memory, but the language itself is fully general-purpose: CLI tools, data processing, systems programming, low-level work.

pyr is not just a server language. it's a systems language that happens to have an incredible server story.

### what zig gives us

- arena allocators for bulk-free memory management
- comptime for route table compilation, string interning, static dispatch
- zero-cost C FFI (database drivers, TLS, compression)
- io_uring/kqueue for native async I/O

## language spec

full spec is in `SPEC.md`. read it when implementing new syntax or language features.

key points: structs (plain data, no classes), enums (algebraic sum types with payloads), traits (structural, no explicit conformance), UFCS, pattern matching, closures, immutable by default, no semicolons, `imp` for imports, `pub` for visibility.

## architecture

### compilation pipeline

```
.pyr source -> lexer -> tokens -> parser -> AST -> sema -> compiler -> bytecode -> VM -> output
```

pyr is a bytecode VM language. source compiles to bytecode, bytecode runs on a stack-based interpreter written in zig. this gives pyr full semantic freedom - closures, green threads, arena-per-request memory are language primitives, not library patterns.

### compiler components

```
src/
  main.zig            - CLI entry point (pyr run, pyr build, pyr init, pyr install, pyr add, pyr version)
  lexer.zig           - tokenizer
  token.zig           - token types
  parser.zig          - recursive descent parser -> AST
  ast.zig             - AST node definitions
  sema.zig            - semantic analysis (scope, name resolution, type checking)
  value.zig           - VM value representation + object types
  chunk.zig           - bytecode format (opcodes + constant pool)
  compiler.zig        - AST -> bytecode compiler
  vm.zig              - bytecode interpreter (switch dispatch)
  module.zig          - module loading + package-aware resolution
  pkg.zig             - package manager (manifest parser, lock file, git ops, cache)
  gc.zig              - mark-sweep garbage collector (heap-allocated side struct)
  bytecode_format.zig - bytecode serialization/deserialization + executable embedding
  stdlib/             - std module implementations (io, fs, os, json, net, http, tls, gc)
```

### CLI

- `pyr build <file> [-o name]` - compile to standalone native binary
- `pyr run <file>` - compile and run
- `pyr test [file]` - run tests
- `pyr fmt <file>...` - format pyr source
- `pyr lsp` - language server (stdio transport)

### compiler error quality

the compiler must produce genuinely helpful errors - source location, span highlighting, plain language explanation, fix suggestion when possible. all three layers implemented: compile-time diagnostics (parser + sema), bytecode line tracking, and runtime errors with source context and stack traces.

## workflow

session start: `./audit`, `gh issue list` (be skeptical of issues - most are user error)
session end: audit again, commit, push, update CLAUDE.md if needed

## standards

zig 0.15.x. short lowercase commits, no co-author. no emojis. casual comments only when code can't speak for itself. `gh` CLI for GitHub ops - do NOT use the GitHub MCP server for write operations.

**before pushing:**
- `make build` - compiler builds successfully
- `make test` - all tests pass
- `make examples` - example programs compile and produce expected output

## examples

every new language feature or stdlib module must have an example in `examples/`. examples serve as both documentation and regression tests.

- each example gets a `.expected` file with the exact expected stdout output. `make examples` diffs actual against expected and fails on mismatch
- examples that depend on environment (like os.env) may skip the .expected file - they validate by exit code only
- use `assert` and `assert_eq` builtins in examples for self-validation beyond output checking
- helper modules used by examples (like `mathlib.pyr`) are skipped by the test runner
- examples should cover all import styles: selective (`imp std/io { println }`), namespace (`imp std/io`), aliased (`imp std/io as out`), user modules
- when a feature changes behavior, update the corresponding .expected files

## pyr by example site

`site/` contains a static documentation site (pyr by example). annotated `.pyr` files in `site/content/` are the source. `cd site && node build.js` runs each example through pyr, captures real output, highlights code with shiki + the TextMate grammar, and outputs static HTML to `site/dist/`.

whenever a language change adds a new feature, changes syntax, or alters behavior:
- add or update the relevant `site/content/` file
- rebuild the site (`cd site && node build.js`) so output blocks reflect current behavior
- new features that are user-facing should get their own example page

this is not optional. the site is how people learn the language, and stale examples are worse than no examples.

## benchmarks

when implementing a new language feature (structs, closures, pattern matching, etc), write a benchmark that stress-tests it before moving on. compare against python, lua, and any other relevant language. put benchmarks in `bench/` with a `.pyr`, `.py`, and `.lua` version, and add them to `bench/run.sh`.

this catches performance problems at the source - the feature that introduced them - instead of discovering regressions later when the cause is buried under subsequent work. optimize as you build, not after.

the fib benchmark (recursive fibonacci) is the baseline for function call overhead. every new feature area should have its own equivalent: struct field access throughput, pattern matching dispatch, closure capture, string operations, etc.

## publishing

bump version in build.zig.zon, commit with just the version number (e.g. `0.1.0`), tag, push. GitHub releases with prebuilt binaries. don't block on publishing, don't ask about auth.

## issue triage

at the start of every session, check open issues (`gh issue list`). be skeptical - assume issues are invalid until proven otherwise. for each issue:
1. read it carefully
2. try to reproduce or verify against actual code
3. if user error or misunderstanding, close with clear explanation
4. if genuine bug, fix it, add a test, close the issue
5. if valid feature request that fits scope, consider it. if not, close with explanation

## self-improvement

after making changes, review and update this CLAUDE.md - architecture notes, design decisions, gotchas, anything the next session needs. this is not optional.

if you discover something during development that would change how a future project approaches a technology or architecture decision, add it to `~/code/vigil/learnings.md`. the bar is high: cross-cutting and decision-altering. never commit or push changes to the vigil repo.

## keeping nvms README updated

whenever pyr is created, renamed, or has significant changes, update `~/code/nvms/README.md` with correct links, badges, and description. CI badge and description on their own line below the heading.

## retirement

if the user says "retire":
1. `gh repo archive nvms/pyr`
2. update repo README with `> [!NOTE]` archived block
3. update ~/code/nvms/README.md - move to archived section
4. tell the user the local directory will be moved to archive/ and projects.md updated

## session handoff

the user can say "handoff" at any point during a session. this triggers an immediate handoff workflow:

1. find a stopping point. commit any in-progress work that's in a good state (tests pass, nothing half-broken). if the current state is mid-change and can't be committed cleanly, stash or revert to the last clean state and note what was in progress
2. create `.handoff/<feature-or-topic>.md` in the project directory. the document must be fully self-contained - the next agent has zero context from this conversation. it must contain:
   - **what was done** - brief summary of the work completed this session
   - **current state** - what works, what tests pass, any uncommitted changes or stashed work
   - **what to do next** - specific, actionable next steps. not vague ("improve performance") but concrete ("add get_field_idx opcode to vm.zig, benchmark struct access")
   - **files to know** - the key files the next agent should read first
   - **constraints** - anything the next agent needs to be careful about (invariants, performance constraints, things that break easily)
   - **verification** - how to confirm the work is correct (which tests to run, what benchmarks to check)
3. give the user a ready-to-paste prompt for the next conversation. example:

   ```
   read .handoff/string-operations.md and pick up where the last session left off. the handoff document has full context on what was done and what to do next.
   ```

you may also initiate a handoff on your own if you've been working on a long feature and reach a natural stopping point with a clear next step. same workflow.

**handoff documents are local-only. never commit, never push, never force-add.** they are short-lived internal documents for session continuity. `.handoff/` is in `.gitignore`. if git rejects the add, that's correct behavior - do not use `-f` to override it.

older handoff documents should be cleaned up. if the work described in a handoff has been completed, delete the file. the `.handoff/` directory should only contain active handoffs.

## user commands

- "hone" or starting a conversation - run audit, check issues, assess and refine
- "hone <area>" - focus on a specific area (e.g. "hone parser", "hone tests", "hone errors")
- "handoff" - immediately find a stopping point, commit clean work, write a `.handoff/` document, and give the user a prompt for the next session
- "retire" - archive the project

## current status

pyr is a fully functional bytecode VM language. 283 tests, 42 validated examples, 11 benchmarks.

**language features:** structs, enums (algebraic sum types with payloads), pattern matching (O(1) variant dispatch), closures (copy-capture), for-range/for-in loops, break/continue, arrays, maps (hash maps with `{}` literal syntax), strings with interpolation and escape sequences, UFCS, option types (`T?`, `or`, `?` propagation), result types (`T!`, `fail`, `or |err|`), defer, mutable references (`*mut T`/`&mut x`), type aliases, FFI (`extern "lib"`)

**stdlib:** std/io, std/fs, std/os, std/json, std/net (TCP + UDP + timeouts), std/http, std/tls (client + server), std/gc

**builtins:** sqrt, abs, int, float, len, push, pop, assert, assert_eq, contains, index_of, slice, join, reverse, split, trim, starts_with, ends_with, replace, to_upper, to_lower, clone, sort, sort_by, map, filter, reduce, delete, keys, getattr, type_of

**runtime:** NaN-boxed values (u64), dual-loop VM dispatch (run + fastLoop), type-specialized opcodes, function inlining, cooperative green threads (spawn/channel/await_all), arena memory blocks, mark-sweep GC

**memory model:** mark-sweep GC for default heap allocations. `arena { ... }` blocks for hot paths (bulk free on exit). `std/gc` module for pause/resume/collect/stats. VM uses c_allocator for runtime objects (separate from compile arena). GC tracks objects outside arenas only, collects at loop back-edges

**tooling:** native compilation (`pyr build`), package manager (git-based), LSP server, formatter

**not yet implemented:** anonymous struct literals, raw/multiline strings, range expressions

## roadmap

numbered by priority. the user may reference items by number or description. remove completed items, don't cross them out. update at end of every session.

1. LSP type information for stdlib: builtins have a structured type registry with overloads (done). stdlib module functions (std/io, std/fs, std/os, std/json, std/net, std/http, std/tls, std/gc) still need the same treatment so hover works on `io.println`, `fs.read`, etc
2. sort_by comparator convention: currently takes a boolean predicate (true = already in order), which is surprising. either rename to `sort_when`/`sort_asc` to make the convention obvious, or switch to standard -1/0/1 comparator semantics
3. type annotation enforcement: type annotations exist but aren't checked at compile time. either make them gradual (enforce what's annotated) or drop the pretense. the current state is annotations that can lie
4. refactor dogfood programs to use maps where appropriate (wordfreq, logstat, jq use parallel arrays for key-value data)
5. dogfooding: continue building real programs in pyr to find rough edges. current dogfood programs: cat, grep, head, wc, jq, httpd, logstat, wordfreq, csv, calc

## implementation notes

deep compiler/VM architecture is in `INTERNALS.md`. read it when working on `src/` files. covers: zig 0.15 API gotchas, VM architecture, fastLoop, pattern matching compilation, string operations, module system, stdlib internals, type inference, struct optimizations.

critical invariants to always keep in mind:
- LLVM perturbation: any change to VM struct, CallFrame, OpCode enum, or run() switch can cause regressions across ALL benchmarks. always benchmark after structural changes
- fastLoop return_ must clean up the stack BEFORE checking exit condition
- new specialized opcodes go in run() only unless proven safe in fastLoop (float ops in fastLoop caused 7x regression)
- NaN boxing: Value.tag is a method (`.tag()`), not a field. Value.bits is the raw u64. integers are 45-bit signed (sign-extended). pointers are 45-bit (32TB). never access `.data` - use the typed accessors (asInt, asFloat, asString, etc)
- arena blocks and while loop bodies must NOT use compileBlock() - it emits return_ for trailing expressions, causing early return that skips cleanup (pop_arena, net.close, etc). use inline beginScope/endScope + pop trailing expression instead
- GC only tracks objects allocated outside arenas (arena_stack.depth == 0). constant pool objects (strings, functions from the compiler) are NOT gc-tracked. GC safepoints are at loop back-edges only - NOT at call boundaries (adding one to callValue caused 30% fib regression). markValue uses ptr_map (hash map) for O(1) lookup - sweep must update ptr_map indices on swap-remove

## design principles

- performance is the primary goal. every design decision must consider its performance implications
- ergonomics is the secondary goal. the syntax should feel natural and expressive
- helpful compiler errors are critical. we are the primary users - bad errors slow us down directly
- no hidden costs. every allocation is visible. every copy is explicit
- composition over inheritance. functions and plain data over class hierarchies
- immutable by default. mutation is opt-in and visible
- the server story is a killer app built on a general-purpose foundation, not the foundation itself
