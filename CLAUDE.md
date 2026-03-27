# pyr

a systems programming language with scripting ergonomics, built in zig. compiles to native code. no GC, no runtime overhead, arena-scoped memory. high-level code reads like python, low-level code reads like zig - same language, different depths.

you are the sole maintainer. before making technology or architecture decisions, read `~/code/vigil/learnings.md` for cross-cutting insights from past experiments. you may write to this file but never commit or push changes to the vigil repo - only modify the file and leave it for the user.

## concept

the gap in backend languages: general-purpose languages bolt HTTP on as a library (Go, Rust, Java). web-native languages have the right server model but bad performance (PHP, Ruby, Python). pyr closes that gap - a language where the server runtime is a first-class stdlib module with arena-per-request memory, but the language itself is fully general-purpose: CLI tools, data processing, systems programming, low-level work.

pyr is not just a server language. it's a systems language that happens to have an incredible server story.

### what zig gives us

- arena-per-request memory (no GC, no refcounting, no manual free)
- comptime for route table compilation, string interning, static dispatch
- SIMD via @Vector for JSON/HTTP parsing
- io_uring/kqueue for native async I/O
- zero-cost C FFI (database drivers, TLS, compression)
- no hidden allocations - every allocation is explicit and arena-routed
- work-stealing thread pool for green thread scheduling

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
  main.zig         - CLI entry point (pyr run, pyr build, pyr init, pyr install, pyr add, pyr version)
  lexer.zig        - tokenizer
  token.zig        - token types
  parser.zig       - recursive descent parser -> AST
  ast.zig          - AST node definitions
  sema.zig         - semantic analysis (scope, name resolution, type checking)
  value.zig        - VM value representation + object types
  chunk.zig        - bytecode format (opcodes + constant pool)
  compiler.zig     - AST -> bytecode compiler
  vm.zig           - bytecode interpreter (switch dispatch)
  module.zig       - module loading + package-aware resolution
  pkg.zig          - package manager (manifest parser, lock file, git ops, cache)
```

### CLI

- `pyr build <file>` - compile to native binary
- `pyr run <file>` - compile and run
- `pyr test [file]` - run tests
- `pyr fmt <file>...` - format pyr source

### compiler error quality

the compiler must produce genuinely helpful errors. this is critical for dogfooding - we are both the language designers and the primary users. every error message should:

- show the exact source location with line/column
- highlight the relevant span
- explain what went wrong in plain language
- suggest a fix when possible

```
error: type mismatch
  --> server.pyr:12:18
   |
12 |   user = find(42) ?? not_found()
   |                  ^^ expected User, found ?User
   |
   = help: find() returns ?User. use ?? to provide a fallback:
           user = find(42) ?? return not_found()
```

**current state:** all three layers implemented. layer 1: `printDiagnostic()` in main.zig renders parser and sema errors with source excerpts, line number gutters, and `^^^` underlines. layer 2: compiler propagates real line numbers from AST spans to bytecode (via `current_line` field + `setSpan()` calls on item/stmt/expr). layer 3: `runtimeError()` in vm.zig reads line numbers from bytecode, prints source context with gutter formatting, and a full stack trace with function names and line numbers. `ObjFunction.source` field stores the source text pointer for runtime diagnostics

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

older handoff documents should be cleaned up. if the work described in a handoff has been completed, delete the file. the `.handoff/` directory should only contain active handoffs.

## user commands

- "hone" or starting a conversation - run audit, check issues, assess and refine
- "hone <area>" - focus on a specific area (e.g. "hone parser", "hone tests", "hone errors")
- "handoff" - immediately find a stopping point, commit clean work, write a `.handoff/` document, and give the user a prompt for the next session
- "retire" - archive the project

## current status

pyr is a bytecode VM language. examples run end-to-end: struct creation, field access, enum variants, pattern matching, native functions, string operations.

**implemented:**
- lexer: full tokenization of all pyr syntax (8 tests)
- parser: recursive descent + pratt precedence climbing (42 tests)
  - all declaration types, expression types, statement types, type expressions
  - go-style newline significance
- sema: scope analysis, name resolution, type checking, mutability, arity (17 tests)
  - mutable variable rebinding (mut x = 0; x = x + 1)
- bytecode compiler: AST -> bytecode. each function gets own chunk. locals are slot-indexed. script function registers natives + globals then calls main()
  - two-pass compilation: first pass pre-allocates all ObjFunctions + registers struct/enum metadata, second pass compiles
  - direct function calls: compiler embeds pre-allocated ObjFunction pointers as constants instead of get_global hash lookup. ~29M hash lookups eliminated for fib(35)
  - type inference: compiler infers types from annotations, literals, and expression propagation. emits specialized opcodes (add_int, sub_int, less_int, greater_int, add_float) that skip tag checks
  - locals_only analysis marks functions for fast-path dispatch
- VM interpreter: dual-loop dispatch (16 tests)
  - `run()`: switch-based, handles all opcodes
  - `fastLoop()`: switch dispatch for hot-path opcodes (6.6x speedup on fib(35), switch replaced if/else for ~5% uniform gain)
  - int/float arithmetic, string values, booleans, variable bindings
  - function definitions and calls, if/else, while loops, comparisons, negation, print/println
  - struct creation and field access (ObjStruct with named fields)
  - get_field_idx: compile-time field index optimization - compiler resolves field positions across struct defs, emits direct index when unambiguous. eliminates string comparison in hot loops
  - enum variants with payloads (ObjEnum)
  - pattern matching: variant patterns with destructuring, literal patterns, identifier patterns, wildcard. match_jump opcode for O(1) variant dispatch via jump table (replaces linear match_variant scan). inline match expressions work as RHS of assignments
  - native functions: sqrt, abs, int, float, len, push, assert, assert_eq
  - mutable variable reassignment (set_local/set_global)
  - string concatenation via `+` operator (allocates new ObjString)
  - string `.len` field access (returns byte count as int)
  - string value equality (compares chars, not pointer identity)
- closures with copy-capture (ObjClosure wraps ObjFunction + captured values)
  - make_closure opcode with upvalue descriptors (is_local flag + index)
  - get_upvalue/set_upvalue opcodes for reading/writing captured values
  - mutable closure capture: set_upvalue writes to the closure's own copy (counter pattern works). outer scope unaffected (copy semantics)
  - compiler walks enclosing scope chain to resolve upvalues. binding handler checks resolveUpvalue before creating new locals
  - closures callable from both run() and fastLoop
- for loops with range: `for i in range(n)`, `for i in range(start, end)`, `for i in range(start, end, step)`
  - compiled to while loops at compile time - no iterator protocol overhead
  - range() detected and lowered by compiler, not a runtime function
- mutable variable rebinding: `mut x = 0; x = x + 1` works via sema allowing rebinding of mutable locals
- arrays: `[1, 2, 3]` literals, `arr[i]` indexing (also works on strings), `push(arr, val)`, `len(arr)`, deep equality via `==`, `for x in arr` iteration
  - ObjArray with growable backing store (capacity doubling). array_create, index_get, index_set opcodes in run()
  - for-in compiles to hidden `$iter` + `$idx` locals, index-based loop with len check and index_get per iteration
- NaN-boxed values: Value is a single u64 (8 bytes, down from 16). doubles stored as raw IEEE 754 bits. non-double types encoded in the quiet NaN space: QNAN base (0x7FFC000000000000) + 5-bit type tag (bits 49-45) + 45-bit payload. tag() method returns Tag enum, isFloat detected by (bits & QNAN) != QNAN. integers sign-extended from 45 bits (range +/- 17.6 trillion). pointers stored in 45-bit payload (32TB address space). floats canonicalized to 0x7FF8... if they collide with QNAN pattern. halved memory for stack, arrays, channels, struct fields - major performance win for data-heavy workloads
- value types: nil, bool, int (i45 signed), float (f64), string (*ObjString), function (*ObjFunction), struct_ (*ObjStruct), enum_ (*ObjEnum), native_fn (*ObjNativeFn), closure (*ObjClosure), array (*ObjArray), task (*ObjTask), channel (*ObjChannel), listener (*ObjListener), conn (*ObjConn), dgram (*ObjDgram), tls_conn (*ObjTlsConn), ssl_ctx (*ObjSslCtx), ssl_conn (*ObjSslConn), ptr (raw C pointer for FFI), error_val (*ObjError - wraps any Value as error payload)
- arena memory model: `arena { ... }` blocks create child arena allocators. all allocations inside use the child arena. freed in bulk on block exit. ArenaStack side struct (heap-allocated, avoids LLVM perturbation) holds up to 16 nested arenas. push_arena/pop_arena opcodes. VM.currentAlloc() routes allocations to active arena
- concat_local opcode: compile-time detection of `s = s + expr` pattern. compiler emits concat_local instead of get_local+add+set_local. VM maintains a growable ConcatState buffer (heap-allocated, avoids LLVM perturbation). amortized O(1) append instead of O(n) realloc per iteration. also handles `s += expr` compound assignment
- type-specialized opcodes: add_int, sub_int, mul_int, div_int, mod_int, less_int, greater_int, add_float, sub_float, mul_float, div_float, less_float, greater_float - skip tag checks entirely when compiler can prove operand types. int ops in fastLoop, float ops in run() only (fastLoop size limit)
- inline struct field storage: ObjStruct and field values allocated as single contiguous block, eliminating one pointer deref per field access
- get_local_field opcode: combines get_local + get_field_idx for struct-typed locals (compiler proves struct type via parameter annotations)
- struct_ type hint: compiler resolves struct type names via struct_defs, enables tag-check-free field access
- for-range optimizations: less_int/add_int for counter ops, inc_local compound opcode (replaces 5-opcode increment pattern), binding aliases counter local directly (eliminates copy+pop per iteration)
- closures get locals_only analysis so they execute in fastLoop (was missing, caused 8x closure call penalty)
- string escape sequences: compiler processEscapes handles `\n`, `\t`, `\r`, `\\`, `\"`, `\{`, `\}`, `\0`, `\xNN`. applied to both plain string literals and interpolation literal parts. lexer skips escaped chars for delimiter purposes, compiler resolves them to actual bytes
- string interpolation: `"hello {name}"` - lexer splits into string_begin/string_part/string_end tokens, compiler emits to_str + add for each part
- module system: `imp math { add }` for selective import, `imp math` for namespace access (`math.add()`), `imp math as m` for alias. file resolution relative to entry file. circular imports handled via module cache. pub enforcement on all declarations
- stdlib: compiler-intrinsic std modules (no .pyr files needed). native function registry in stdlib.zig. native fn signature includes allocator for std modules that allocate (readln, fs.read, os.env)
  - std/io: println, print, eprintln, eprint, readln. writes to real stdout/stderr via std.posix.write (not std.debug.print)
  - std/fs: read, write, append, exists, remove. file operations via std.fs.cwd()
  - std/os: env (environment variables), args (returns string array), exit
  - std/json: encode (any pyr value -> JSON string), decode (JSON string -> pyr value). encode handles int, float, str, bool, nil, array, struct, enum. decode returns int/float/str/bool/nil for primitives, ObjArray for arrays, ObjStruct (name "object") for objects. round-trip: decode(encode(v)) preserves structure for structs/arrays
  - std/net: listen, accept, connect, read, write, close, timeout, udp_bind, udp_open, sendto, recvfrom. TCP sockets via std.posix.* syscalls. ObjListener (fd + port) and ObjConn (fd + nonblock flag) value types. method-call syntax (`server.accept()`, `conn.read()`, `conn.write(data)`) and `net.connect(addr, port)` compile to net_accept/net_read/net_write/net_connect opcodes with non-blocking I/O + scheduler integration. namespace syntax (`net.accept(server)`, `net.read(conn)`, `net.write(conn, data)`) uses blocking native functions. ObjConn.ensureNonBlock() caches fcntl state - only sets O_NONBLOCK once per fd, eliminating redundant syscalls in hot loops. UDP: ObjDgram (fd + timeout_ms + bound flag) value type. `udp_bind(addr, port)` creates bound socket for receiving, `udp_open()` creates unbound socket for sending. `sendto(sock, data, addr, port)` sends datagrams, `recvfrom(sock)` returns UdpMessage struct {data, addr, port}. method-call syntax (`sock.sendto(data, addr, port)`, `sock.recvfrom()`) compiles to net_sendto/net_recvfrom opcodes. recvfrom integrates with scheduler for non-blocking I/O in async contexts. timeout support via net.timeout(sock, ms)
  - std/http: parse_request, respond, respond_status, json_response, route, match_route. HTTP utility module - server loop written in pyr using std/net primitives. handlers are regular pyr functions. route/match_route pattern for declarative routing
  - std/tls: TLS 1.2/1.3 client via zig's std.crypto.tls.Client. `tls.upgrade(conn, hostname)` wraps a TCP connection with TLS. hostname enables SNI + certificate verification via system CA bundle (cached across connections). `tls.upgrade(conn, nil)` skips verification. ObjTlsConn value type holds heap-allocated TLS client state with stable addresses for zig's @fieldParentPtr vtable pattern. transparent read/write via .read()/.write() method-call syntax - same net_read/net_write opcodes, VM dispatches on tag. reads use peekGreedy(1) + tossBuffered() on the Io.Reader (NOT readSliceShort, which loops trying to fill the entire buffer and causes hangs). poll-based read with 5s default timeout prevents indefinite blocking when servers are slow to close. allow_truncation_attacks=true for real-world servers that don't send close_notify. `net.connect` supports DNS resolution via std.net.getAddressList for hostnames (falls back from parseAddr when address doesn't look like an IP). server-side TLS via runtime dlopen of OpenSSL/LibreSSL (no build-time dependency). `tls.context(cert_path, key_path)` creates ObjSslCtx (wraps SSL_CTX*). `tls.upgrade(conn, ctx)` when second arg is ssl_ctx does SSL_accept server handshake, returns ObjSslConn (wraps SSL*). VM dispatches net_read/net_write on .ssl_conn tag via SSL_read/SSL_write. ssl.zig binding layer: runtime dlopen with platform-specific search paths (homebrew on macOS, system paths on Linux), lazy init, ~12 function pointers resolved via dlsym. OPENSSL_init_ssl called on first load. net.close handles SSL_shutdown + SSL_free for ssl_conn. net.timeout sets timeout_ms on ssl_conn. test_tls/run.sh validates server with openssl s_client
- type keywords (int, float, str, bool, byte) usable in expression position as conversion functions: `int(3.7)`, `float(5)`
- assert and assert_eq builtins: assert(condition) exits on failure, assert_eq(a, b) exits with diff on mismatch
- slide opcode: endScopeKeepTop emits slide to clean up scope locals while preserving expression result. fixes inline match expressions (e.g. `x = match e { ... }`) which previously left scope locals on the stack
- set_field/set_field_idx opcodes: struct field mutation (`p.x = 10`, `p.x += 3`). set_field_idx uses compile-time field index for unambiguous fields. mutation works through function calls (struct values are pointers)
- index_set opcode: array element assignment (`arr[i] = val`, `arr[i] += val`). bounds-checked at runtime
- concurrency runtime: cooperative green threads (tasks), bounded channels, cooperative scheduler
  - `spawn { body }` creates a green thread. body compiled as closure with upvalue capture
  - `channel(N)` creates a bounded channel with capacity N
  - `ch.send(val)` and `ch.recv()` compiled to dedicated opcodes with blocking/waking
  - Scheduler side struct (heap-allocated, avoids LLVM perturbation) with growable circular run queue, io poller, and await waiters (starts at 64 slots, doubles on demand)
  - ObjTask holds full VM state snapshot (stack, frames, sp, frame_count)
  - context switching at channel boundaries: save current task state, restore next ready task
  - task state machine: ready -> running -> done, with blocked_send/blocked_recv/blocked_await
  - deadlock detection when all tasks blocked
  - `await_all(spawn { a() }, spawn { b() })` collects results from parallel tasks into an array
- FFI: `extern "lib" { fn name(type, ...) -> type }` syntax. dlopen/dlsym resolution at VM init. trampoline dispatch for up to 6 int/ptr args. cstr auto null-termination. "c" library resolves to libc. FfiState is a heap-allocated side struct (avoids LLVM perturbation). ffi_call opcode with u16 descriptor index + u8 arg count. src/ffi.zig contains FfiState, trampolines, marshaling. build.zig links libc
- `nil` keyword (not `none`) for null values. Value tag is `.nil`
- option types: postfix `T?` syntax (was prefix `?T`). `or` keyword replaces `??` for nil coalescing (jump_if_nil opcode - checks nil specifically, not truthiness, so `false or x` correctly returns false). `expr?` suffix operator for early return on nil or error (try_unwrap AST node, compiles to jump_if_nil + jump_if_error + return_ pattern). `&&` and `||` short-circuit logical operators
- result types and error handling: `T!` for string errors, `T!(E)` for typed errors. `fail expr` creates error_val and returns. `or` catches both nil and error_val. `or |err| { body }` binds the error payload. `expr!` crash-unwraps (exits on nil or error). error_val is a new Value tag wrapping ObjError (heap-allocated, holds payload Value). `jump_if_error` opcode mirrors `jump_if_nil`. `make_error` wraps top-of-stack in error_val. `extract_error` replaces error_val with its payload (for `or |err|`). `unwrap_error` crashes with error info (for `!`). error propagation: `?` checks both nil and error_val, returns whichever on failure. typed errors auto-stringify when propagated into `T!` context via valueToString
- 87 opcodes: constants, locals, globals, arithmetic, specialized int/float arithmetic, comparison, logic, jumps, jump_if_nil, jump_if_error, calls, return, print, struct_create, get_field, set_field, set_field_idx, get_field_idx, get_local_field, enum_variant, match_variant, get_payload, make_closure, get_upvalue, set_upvalue, concat_local, to_str, array_create, index_get, index_set, array_push, array_len, slide, match_jump, inc_local, push_arena, pop_arena, spawn, channel_create, channel_send, channel_recv, await_task, await_all, net_accept, net_read, net_write, net_connect, net_sendto, net_recvfrom, ffi_call, make_error, unwrap_error, extract_error
- package manager: git-based, go-style. `pyr.pkg` manifest (name, version, require block). `pyr.lock` lockfile with commit hashes. `~/.pyr/cache/` local cache mirroring git paths. `pyr init [name]` creates manifest, `pyr install` fetches all deps, `pyr add <url> [version]` adds dependency. resolution order: stdlib -> local file -> pyr.pkg dependencies. packages imported by their name field: `imp router { serve }`, `imp router`, `imp router as r`. package entry point is `src/main.pyr`. bare repo cache for efficient fetches, version tags resolved via git rev-parse. src/pkg.zig contains manifest parser, lock file, git ops, cache management. module.zig extended with package_map for fallback resolution
- CLI: `pyr run <file>` executes on VM, `pyr build <file>` checks, `pyr init [name]`, `pyr install`, `pyr add <url> [version]`, `pyr version`
- IoError: built-in enum type (Eof, Closed, Error(str), Timeout) registered in both compiler and sema. I/O operations return IoError variants instead of nil/false on failure. net_read returns Eof on clean close, Closed on reset, Error(msg) on other failures. net_write returns true on success, IoError on failure. fs.read returns IoError on failure. enum equality compares by type_name + variant_index + payloads (structural, not pointer identity). zero-payload variants (Eof, Closed, Timeout) usable as expressions for direct comparison: `if data == Eof`
- read/accept timeouts: `net.timeout(target, ms)` sets per-connection or per-listener timeout in milliseconds. -1 to disable. stored as timeout_ms on ObjListener/ObjConn. blocking path: poll() with timeout, returns IoError.Timeout on expiry. scheduler path: io_deadlines parallel array stores epoch-ms deadlines, pollAndWake computes min deadline as poll timeout, expires waiters past deadline. connections with timeout set are forced nonblocking so poll path is always reachable
- while loop body compilation: uses inline beginScope/endScope instead of compileBlock to avoid emitting return_ for trailing expressions. compileBlock emits return_ for trailing expressions (correct for function bodies) but wrong for loop bodies where trailing expressions should be discarded
- defer: scoped cleanup (like zig). `defer expr` and `defer { block }`. LIFO order. runs at scope exit - normal end, return, fail, or ? propagation. compile-time construct: compiler stores deferred AST nodes per scope depth, emits them at every exit point. no new opcodes. emitScopeDefers for normal scope exit, emitAllDefers for early returns. compileBlock's trailing expression path emits defers before return_
- mutable references: `*mut T` parameter types declare mutation intent. `&mut x` required at call sites. sema enforces: field assignment on non-`*mut` params is compile error, `&mut` on immutable vars is error, unnecessary `&mut` to non-`*mut` params is error. pure compile-time - no new VM opcodes or value types. `&mut x` compiles to just `x` (already a pointer for heap types). FnType.mut_params bitmask (u64) tracks which params are `*mut`
- type aliases: `type Name = TypeExpr` for named type aliases. `fn(T, T) -> T` syntax in type expressions for function types. `type` keyword parsed as top-level item. sema resolves aliases via symbol lookup, fn_type resolves to FnType. compiler and VM unchanged - pure type system feature
- 259 tests, 36 validated examples, 10 benchmarks
- UFCS: `x.f(args)` rewrites to `f(x, args)` at compile time when `f` is a known function (fn_table, native_fns, locals, upvalues) and target is not a module namespace. enables `5.double()`, `p.distance(q)`, `4.0.sqrt()`, chaining `5.double().negate()`, `"a-b-c".split("-").join("/")`
- index_local/index_local_local opcodes: fused array indexing. index_local reads array from local slot, pops index from stack. index_local_local reads both array and index from local slots (used in for-in loops). eliminates stack pushes/pops for the common arr[idx] pattern. compiler detects identifier targets in index expressions
- builtins: sqrt, abs, int, float, len, push, pop, assert, assert_eq, contains, index_of, slice, join, reverse, split, trim, starts_with, ends_with, replace, to_upper, to_lower. all work with UFCS: `arr.contains(x)`, `str.split(",")`, `"hello".to_upper()`
- higher-order array operations: map(arr, fn), filter(arr, fn), reduce(arr, fn, init). implemented as helper functions with hand-built bytecode (defineHelperFn in compiler.zig) - not native functions, because natives can't call back into pyr. each emits bytecode that uses the `call` opcode to invoke the callback through normal VM dispatch. marked locals_only for fastLoop execution. work with closures, named functions, and UFCS chaining: `arr.filter(fn(x) x > 0).map(fn(x) x * 2)`
- benchmarks: fib(35) 0.67s (python 0.86s), loop 10M 0.20s (python 0.22s), closure 10M 0.24s (python 0.32s), struct 10M 0.31s (python 0.20s), string 100K 0.007s (python 0.14s), array 10M 0.64s (python 0.62s), match 30M 2.62s (python 2.07s), arena 1M 0.27s (python 0.22s), channel 100K 0.02s (python 0.10s), tcp_echo 10K 0.19s (python 0.17s)

**not yet implemented (parser level):**
- anonymous struct literals: `.{ field: val }` inferred from context (zig-style). when the compiler knows the expected type from a function param, return type, or annotated binding, allow omitting the struct name. pure syntax sugar - desugars to `TypeName { field: val }` during compilation
- raw/multiline strings
- range expressions, tuple destructuring, deref postfix

**next:** performance (function inlining for small pure functions, match dispatch optimization), dogfooding

## roadmap

numbered by priority. the user may reference items by number or description. remove completed items, don't cross them out. update at end of every session.

1. function inlining for small pure functions
2. escape analysis: compiler warning when heap allocations (structs, arrays, strings) don't escape their scope and aren't inside an arena block. sema already tracks scopes and names - detect locals that are created, used locally, and never returned/passed/assigned to an outer field. conservative on function args (assume escape). primary target: loop bodies that allocate without an arena
3. dogfooding: build real programs in pyr to find rough edges

## implementation notes

deep compiler/VM architecture is in `INTERNALS.md`. read it when working on `src/` files. covers: zig 0.15 API gotchas, VM architecture, fastLoop, pattern matching compilation, string operations, module system, stdlib internals, type inference, struct optimizations.

critical invariants to always keep in mind:
- LLVM perturbation: any change to VM struct, CallFrame, OpCode enum, or run() switch can cause regressions across ALL benchmarks. always benchmark after structural changes
- fastLoop return_ must clean up the stack BEFORE checking exit condition
- new specialized opcodes go in run() only unless proven safe in fastLoop (float ops in fastLoop caused 7x regression)
- NaN boxing: Value.tag is a method (`.tag()`), not a field. Value.bits is the raw u64. integers are 45-bit signed (sign-extended). pointers are 45-bit (32TB). never access `.data` - use the typed accessors (asInt, asFloat, asString, etc)

## design principles

- performance is the primary goal. every design decision must consider its performance implications
- ergonomics is the secondary goal. the syntax should feel natural and expressive
- helpful compiler errors are critical. we are the primary users - bad errors slow us down directly
- no hidden costs. every allocation is visible. every copy is explicit
- composition over inheritance. functions and plain data over class hierarchies
- immutable by default. mutation is opt-in and visible
- the server story is a killer app built on a general-purpose foundation, not the foundation itself
