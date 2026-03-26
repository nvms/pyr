# pyr compiler internals

deep implementation notes for working on the compiler, VM, and runtime. read this when touching `src/` files.

## zig 0.15 api

- `std.ArrayListUnmanaged(T){}` with allocator passed to each method call
- `std.io.getStdOut()` / `std.io.getStdErr()` / `std.io.getStdIn()` no longer exist. use `std.posix.write(std.posix.STDOUT_FILENO, bytes)` for stdout, `std.posix.read(std.posix.STDIN_FILENO, &buf)` for stdin. `std.debug.print` still works for diagnostic output (writes to stderr)
- regular zig structs do NOT guarantee field ordering. do not assume first-field-is-at-offset-0 for casting patterns. use explicit typed pointers instead

## parser

- pre-lexes all tokens for O(1) lookahead
- pratt precedence climbing for expressions
- go-style newline significance with nesting-aware suppression
- `packed` is a contextual keyword (parsed as identifier, checked by text)
- type keywords (int, float, str, bool, byte) are valid in expression position for conversion calls: `int(3.7)`, `float(5)`

## VM architecture

- value representation is a tagged struct: `{ tag: Tag, data: u64 }`. tag indicates the type, data is bitcast/ptrcast depending on type. no NaN-boxing - clean, debuggable, 16 bytes per value
- object types (ObjString, ObjFunction, ObjStruct, ObjEnum, ObjNativeFn) are separate heap-allocated structs. the Value tag distinguishes them (no ObjHeader pattern - zig struct layout makes that unreliable)
- bytecode is single-byte opcodes with u8/u16 inline operands. stack-based evaluation
- each function compiles to its own Chunk (code + constants + line info)
- locals are slot-indexed (u8). slot 0 of each frame is reserved for the callee function. parameters start at slot 1. this matches the CallFrame's slot_offset in the VM
- the compiler creates a "script" function for top-level code. it defines natives, defines all user functions as globals, then calls main()
- the VM uses a fixed-size call stack (64 frames) and value stack (256 slots). CallFrame stores function pointer, instruction pointer, and stack slot offset
- println/print are compiled as dedicated opcodes (not function calls) for simplicity. eventually these become stdlib functions
- source string must outlive the VM execution (string literals in bytecode are slices into the source). the arena allocator owns the source copy

## fastLoop (performance-critical)

- separate function from run(), uses if/else chains instead of switch. LLVM optimizes it more aggressively than the large run() switch
- handles: get_local, set_local, get_global, constant, arithmetic (add/subtract/multiply/divide/modulo), comparisons (less/greater/etc), logic (not/equal/not_equal), jumps, call, return, pop, nil/true/false, negate, get_field_idx, get_field, get_upvalue, match_variant, get_payload, index_get, match_jump, slide, inc_local, mul_int, mod_int
- inlines call/return for locals_only functions so entire recursion tree stays in one zig function
- on unknown opcode: rewinds ip by 1 and returns to run() (ip must be rewound because fastLoop already advanced past the opcode byte)
- native function calls are handled inline (no frame push, direct fn pointer call)
- functions are marked `locals_only` by analyzeLocalsOnly() in compiler.zig: scans bytecode, returns false if set_global/define_global/print/println found
- CallFrame includes optional closure pointer for upvalue access
- CRITICAL: fastLoop return_ must clean up the stack (sp = slot, push result) BEFORE checking if it should exit. if it exits first, the caller sees stale sp
- WARNING: any change to VM struct, CallFrame, OpCode enum, or run() switch can perturb LLVM register allocation for ALL handlers. always benchmark after structural changes

## pattern matching compilation

- match subject compiled and stored as hidden local `$match`
- two dispatch modes:
  - **match_jump** (fast path): when all arms are variant patterns (or wildcard) with no guards, emits a jump table. match_jump reads the variant_index and jumps directly to the right arm in O(1). encoding: `match_jump <slot:u8> <variant_count:u8> [<offset:u16> * variant_count] <default_offset:u16>`. offsets are relative to the byte after the instruction
  - **linear scan** (fallback): each arm tests via match_variant (enum) or equal (literal), bindings extracted via get_payload (pops enum, pushes payload)
- identifier patterns checked against enum_variants table: if match, compiled as variant match; otherwise as binding
- linear scan stack discipline: match_variant peeks + pushes bool, so the enum copy must be popped on both success AND failure paths (two pops: bool + enum copy)
- `slide <n:u8>` opcode: used by endScopeKeepTop to remove N locals from below the top of stack while preserving the result value. critical for match expressions used inline (e.g. `x = match e { ... }`) - without it, scope locals accumulate on the stack. works in functions because return_ ignores stack junk, but breaks when match result is assigned to a variable

## string operations

- concatenation via `+`: both binaryOp (run()) and binaryOpSlow (fastLoop) check for string+string and allocate new ObjString with combined chars
- `.len` field access: get_field handler checks if value is a string and field is "len", returns byte count
- value equality: Value.eql compares string chars with std.mem.eql, not pointer identity
- len() native function: returns byte length of string argument
- concat_local opcode with growable buffer: compiler detects `s = s + expr` and `s += expr` patterns at compile time, emits single concat_local opcode. VM maintains ConcatState with ArrayList(u8) that persists across iterations. ObjString.chars points directly into the buffer (updated on each append). 45x faster than naive concat for 100K iterations
- ConcatState is heap-allocated (following zphp's LLVM perturbation lesson - new state goes on side struct, not VM/CallFrame)
- non-string fallback: if concat_local sees non-string operands, falls back to regular binaryOp(.add)

## string interpolation

- syntax: `"hello {name}"` - curly braces delimit expressions inside string literals
- lexer uses `interp_depth` counter to track nesting. when `{` is found inside a string, emits `string_begin` token and increments depth. when `}` is found while depth > 0, calls `lexStringContinuation` which reads until the next `{` (emitting `string_part`) or `"` (emitting `string_end`)
- token text for `string_begin` excludes the leading `"` and trailing `{`. `string_part` text is the literal between `}` and `{`. `string_end` text includes the trailing `"`
- parser builds `string_interp` AST node with array of `InterpPart` (either `.literal` string segment or `.expr` parsed expression)
- compiler emits each part: literals as string constants, expressions followed by `to_str` opcode. parts are concatenated with generic `add` opcode
- `to_str` opcode converts stack top to ObjString: strings pass through, ints/floats use `bufPrint`, bools become "true"/"false", nil becomes "nil"
- plain strings without `{` still lex as `string` token (no overhead for non-interpolated strings)

## module system

- `imp math { add }` brings specific pub items into direct scope. `imp math` registers "math" as a module namespace, accessible via `math.add()`. `imp math as m` aliases
- file resolution: paths are relative to the importing file's directory. `imp foo/bar` resolves to `foo/bar.pyr`. `imp std/io` also resolves relative to entry file's directory (std library lives alongside user code for now)
- ModuleLoader (module.zig) caches parsed modules by path. circular imports are safe - the loader checks the cache before parsing, so a module is only parsed once
- sema registers imported pub names (selective import) or the namespace name (bare import) in the current scope
- compiler's registerDecl walks imported module's items, registers pub functions/structs/enums in fn_table/struct_defs/enum_variants. compileItem compiles imported pub function bodies
- module-qualified access (`math.add()`) is resolved at compile time: field_access handler checks if the target identifier matches a module_namespace, then resolves the field via fn_table
- pub enforcement: only items with `is_pub = true` are visible to importers. non-pub items are correctly rejected by both sema and compiler
- no runtime module objects. all linking happens at compile time. imports are resolved to direct function references in bytecode

## stdlib (compiler-intrinsic)

- stdlib.zig defines a NativeDef registry: each std module maps to an array of {name, arity, func} entries
- stdlib.findModule() checks import path against the registry. if found, sema/compiler skip .pyr file loading
- native fn signature: `fn(std.mem.Allocator, []const Value) Value` - allocator passed from VM for functions that allocate (readln, fs.read, os.env)
- compiler has two new maps: `std_modules` (namespace name -> StdModule*) and `native_fns` (name -> ObjNativeFn*)
- registerStdImport creates ObjNativeFn for each function, stores in native_fns. for namespace imports, also registers in std_modules
- compileStdImport emits define_global for each native fn (same pattern as defineNativeFn)
- resolveModuleValue checks both module_namespaces (user modules) and std_modules (std modules), returns Value (either ObjFunction or ObjNativeFn)
- compileGetVar checks native_fns table before falling back to get_global, enabling direct constant embedding for selective std imports
- io functions use std.posix.write/read directly (zig 0.15 removed std.io.getStdOut/getStdErr/getStdIn)

## direct function calls

- compiler pre-allocates all ObjFunctions in registerDecl (pass 1), stores in fn_table
- at call sites, compileGetVar checks fn_table before falling back to get_global
- if found, emits `constant + call` instead of `get_global + call` - direct array index vs hash lookup
- works for recursive calls (pointer stable from pass 1, chunk filled in pass 2)
- fn_table walks enclosing compiler chain so nested functions can reference top-level functions

## type inference and specialized opcodes

- TypeHint enum: unknown, int_, float_, string_, bool_, struct_
- type sources: parameter annotations (parsed from TypeExpr.named via resolveTypeHint which checks struct_defs), literal types, return type annotations (stored in fn_returns map)
- exprType() infers types recursively: literals -> direct, identifiers -> local type_hint, binaries -> propagated, calls -> fn_returns lookup
- Local struct has type_hint field, set from parameter annotations or inferred from binding expressions
- compileBinary emits int-specialized ops (add_int/sub_int/mul_int/div_int/mod_int/less_int/greater_int) when both operands are int_, float-specialized ops (add_float/sub_float/mul_float/div_float/less_float/greater_float) when either operand is float
- int-specialized opcodes are in fastLoop (tag-check-free). float-specialized opcodes are in run() ONLY - adding them to fastLoop caused 7x LLVM perturbation regression across all benchmarks
- for-range counter comparison and increment emit less_int/add_int directly (not generic less/add)
- `inc_local <slot:u8>` replaces the 5-opcode counter increment pattern (get_local + constant(1) + add_int + set_local + pop). ~20-30% improvement on all for-range benchmarks
- for-range binding aliases the counter local directly instead of pushing a copy. the compiler temporarily renames `$counter` to the binding name during body compilation, then restores it. saves 2 opcodes per iteration (the copy push and scope pop). safe because for-range bindings are immutable
- for-range body must have beginScope/endScope around it (added after discovering stack leak). without inner scope, bindings declared inside the loop body are never popped, causing stack overflow after ~250 iterations with struct creation
- mul_int and mod_int are now in fastLoop alongside add_int/sub_int/less_int/greater_int

## get_field_idx and get_local_field optimization

- compiler's resolveFieldIndex scans all struct_defs for the field name. if every struct with that field has it at the same index, emits get_field_idx with u8 index instead of get_field with string name
- get_local_field combines get_local + get_field_idx into a single opcode when the local has struct_ type hint. skips tag check entirely in fastLoop since the compiler proves the type
- for non-struct-typed locals, falls back to separate get_local + get_field_idx (with tag check)

## inline struct field storage

- ObjStruct allocates header + field values as a single contiguous block of Value-aligned memory
- `header_slots = ceil(sizeof(ObjStruct) / sizeof(Value))` Values for the header, then field_count Values for fields
- `fieldValues()` computes the field pointer via arithmetic (base + header_slots), eliminating one pointer deref vs the old separate field_values allocation
- struct_create in VM allocates temp_values, passes to ObjStruct.create (which copies into the inline block), then frees temp_values

## struct/enum compilation

- compiler does two passes: registerDecl (collects struct field names and enum variant info), then compileItem (generates bytecode)
- struct_create opcode encodes field names as u16 constant indices after the field count byte (variable-length encoding)
- enum variants with payloads are compiled at call sites (compileCall detects variant names), bare variants compiled in compileIdentifier
- metadata walks the enclosing compiler chain so nested functions can reference type definitions

## arrays

- ObjArray stores `items: []Value` and `capacity: usize`. growable via push() with capacity doubling (initial capacity 8)
- `[1, 2, 3]` compiles to: push each element, then `array_create` with u8 count. VM pops N values from stack and creates ObjArray
- `arr[i]` compiles to: push target, push index, `index_get`. works for both arrays and strings (single-char string for string indexing)
- `index_set`: array element assignment (`arr[i] = val`, `arr[i] += 5`). bounds-checked at runtime
- `push(arr, val)` is a builtin native function (not an opcode) - takes array and value, calls ObjArray.push
- `len(arr)` handled by native len() function. `arr.len` handled by get_field in VM (string comparison for "len")
- `for x in arr` compiles to: hidden `$iter` local (the array), hidden `$idx` local (counter), index-based loop using get_field("len") for bounds check and index_get per iteration
- deep equality: Value.eql recursively compares array elements (not pointer identity)
- array benchmark (1M push + iterate) shows room for optimization: get_field("len") per iteration is expensive (string comparison). future optimization: cache array length or emit specialized array_len opcode

## arena memory model

- `arena { ... }` blocks create a child arena allocator. all allocations inside use the child arena. when the block exits, the arena is freed in bulk
- ArenaStack is a heap-allocated side struct (like ConcatState) to avoid LLVM perturbation of the VM layout. holds up to 16 nested arenas
- `push_arena` opcode creates a new `std.heap.ArenaAllocator` backed by the root allocator, pushes it. `pop_arena` calls `deinit()` and pops
- `currentAlloc()` method on VM returns the top arena's allocator (or root allocator if no arena is active). replaces direct `self.alloc` usage in all allocation sites
- allocations that use currentAlloc: ObjString, ObjStruct, ObjEnum, ObjArray, ObjClosure creation, temp buffers, string concat, valueToString, native function allocator arg
- allocations that stay on root allocator: globals hashmap (program lifetime), ConcatState buffer (persists across arena boundaries)
- string literals are slices into the source buffer, not arena-allocated. they remain valid across arena boundaries
- values that escape an arena scope (e.g. assigned to a variable in the parent scope) will have dangling pointers after the arena is freed. currently the programmer's responsibility to avoid this. future: explicit `escape()` function or implicit escape analysis
- push_arena/pop_arena are in run() only, not fastLoop - they're not hot-path opcodes
- the arena approach maps directly to arena-per-request in HTTP servers: handler wrapped in implicit arena block, all request allocations freed in one shot when response is sent
