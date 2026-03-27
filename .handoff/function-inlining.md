# function inlining for small pure functions

## what was done

- map/filter/reduce confirmed working (already implemented via defineHelperFn). removed from roadmap
- added site page for map/filter/reduce with UFCS chaining examples
- added page description system to pyr-by-example site (frontmatter `description` field, rendered between heading and code)
- fixed json site example (unescaped `{` triggering string interpolation)
- set up github pages deployment workflow (`.github/workflows/pages.yml`)
- added escape analysis to roadmap (item 2): compiler warning for heap allocations outside arena blocks
- all tests passing (259 tests, 36 examples), CI green, pages deploying

## current state

roadmap item 1 is function inlining for small pure functions. this has not been started.

## what to do next

implement function inlining in the compiler. the goal: when the compiler encounters a call to a small, pure function, emit the function's bytecode inline instead of a call opcode + frame push. this eliminates call overhead for trivial helpers like `fn double(x: int) -> int = x * 2`.

### design considerations

1. **what qualifies as "small"**: expression-body functions (`= expr`) are the obvious candidates. functions with a single return expression and no control flow are safe. set a bytecode size threshold (e.g. <= 8 opcodes after compilation)

2. **what qualifies as "pure"**: no side effects. no print/println, no mutation of globals, no I/O, no channel ops. only reads its arguments and returns a value. the compiler can check this during the first pass (function bodies are already compiled in pass 2)

3. **where inlining happens**: in compiler.zig's call compilation path. when the compiler resolves a direct call to a known function (already done for direct function calls via fn_table), check if the target is inlineable. if so, emit the body's opcodes directly with argument slots remapped to the caller's stack positions

4. **remapping**: the inlined function's locals (which are its parameters) need to map to the values already on the caller's stack. for expression-body functions with N params, the args are already pushed by the caller - just emit the body opcodes with adjusted slot offsets

5. **LLVM perturbation risk**: this changes bytecode output but NOT the VM struct, OpCode enum, or dispatch loop. the risk is lower than typical VM changes, but benchmark after implementation. fib(35) is the key benchmark since it's all function call overhead

6. **two-pass interaction**: pass 1 pre-allocates ObjFunctions. inlining analysis can happen between pass 1 and pass 2, or as a flag set during pass 2 compilation of each function body. mark functions as `inlineable` on the ObjFunction or in a side table

### suggested approach

- add an `inlineable: bool` field to ObjFunction (or a compiler-side set)
- after compiling a function body in pass 2, check: is it expression-body? is bytecode count <= threshold? are all opcodes pure (no print, no side effects)?
- at call sites: if target is inlineable and arg count matches, emit the body opcodes with slot remapping instead of the call opcode
- start with expression-body functions only. block-body functions can be added later

### what NOT to do

- don't inline recursive functions
- don't inline closures (upvalue handling complicates remapping)
- don't inline functions called via UFCS rewrite until the basic path works
- don't change the VM at all - this is purely a compiler optimization

## files to know

- `src/compiler.zig` - call compilation, fn_table, defineHelperFn pattern, two-pass structure
- `src/chunk.zig` - bytecode format, opcode definitions
- `src/vm.zig` - understand call/return to know what's being eliminated (but don't modify)
- `src/ast.zig` - expression-body functions (FnDecl node)
- `INTERNALS.md` - deep architecture notes
- `bench/` - fib.pyr is the primary benchmark for call overhead

## constraints

- LLVM perturbation: do NOT modify VM struct, CallFrame, OpCode enum, or run()/fastLoop() dispatch. this is a compiler-only change
- benchmark fib(35) before and after. any regression means the inlining heuristic is wrong or bytecode layout shifted
- keep the inlining conservative. it's better to inline too few functions than to break correctness

## verification

- `make build` - compiler builds
- `make test` - all 259 tests pass
- `make examples` - all 36 examples produce expected output
- `zig build bench` or `bench/run.sh` - fib(35) should improve (fewer call frames), other benchmarks should not regress
- write a targeted benchmark: a tight loop calling a small pure function, measure with and without inlining
