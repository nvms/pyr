# ownership model - handoff

## what was done

implemented a compile-time ownership model for pyr's memory management. this was a ground-up design - we evaluated GC, arena-only, borrow checkers, escape analysis, ref counting, and several novel approaches before landing on this model.

### features implemented

- **`own` keyword on function parameters**: explicit ownership transfer. callee takes ownership, caller can't use the value after. parsed in lexer/parser, tracked in sema via `own_params` bitmask on FnType, enforced at call sites
- **ownership state tracking**: sema tracks per-symbol states: `none`, `owned`, `borrowed`, `moved`, `maybe_moved`. parameters are `borrowed` by default, `owned` if marked `own`
- **use-after-move detection**: sema reports compile error when a moved value is used. clear diagnostics with source location
- **liveness analysis**: compiler pre-scans AST blocks to find last-use of each owned local. emits `free_local` after last use instead of waiting for scope exit. implemented via `emitEarlyFrees()` which checks remaining statements for name references using `exprUsesName`/`stmtUsesName`/`blockUsesName` helpers
- **drop flags for conditional moves**: when a value is moved inside an if/match block, sema marks it `maybe_moved` (not an error to use after). compiler pre-allocates a hidden `$drop_flag` local (initialized to 0) at binding time if `needsDropFlag()` detects a conditional own-call. flag set to 1 on move via `emitDropFlags()`. `free_local_if` opcode checks the flag - only frees if flag is 0 (not moved)
- **borrow-store detection**: sema catches `push(arr, borrowed_param)` and suggests using `own`
- **shallow free**: `deepFree` on Value only frees the container (struct shell, array buffer, enum payloads buffer), not contents. contents may be constant pool values or shared references that we don't own
- **`free_local` and `free_local_if` opcodes**: in run() switch of vm.zig. `free_local` takes slot index, calls `deepFree`, sets slot to nil. `free_local_if` takes slot + flag_slot, checks flag before freeing

## current state

- all tests pass (269+ unit tests across sema, compiler, parser, vm)
- all 37 examples pass
- no benchmark regressions (verified with bench/run.sh)
- everything committed and pushed to main
- CI should be green

## what to do next

roadmap item 1: **LSP ownership hints**. full spec is in `OWNERSHIP.md` under "LSP integration" section. the compiler already computes all ownership data - the LSP is plumbing work:

1. add a compilation mode that produces an `OwnershipMap` - list of owned locals per function with their free points, ownership transfers per call site, function-level summaries
2. build an LSP server using `textDocument/inlayHint` for free point hints, `textDocument/hover` for ownership summaries, `textDocument/codeLens` for function overview
3. inline hints show: `// <- user freed` after last use, `// <- item moved (ownership transferred)` at own-param call sites, `// <- d freed (if not moved)` for conditional frees

roadmap item 2: dogfooding - build real programs in pyr to stress-test the ownership model

## files to know

- `src/sema.zig` - ownership state tracking (Symbol.Ownership enum, checkOwnParams, checkBorrowedStore, cond_depth for conditional move detection)
- `src/compiler.zig` - free point emission (emitEarlyFrees, emitDropFlags, needsDropFlag, isHeapExpr, endScope with free_local/free_local_if, fn_own_params map, cond_depth, current_block, Local.is_owned/drop_flag_slot)
- `src/value.zig` - Value.deepFree (shallow free implementation)
- `src/vm.zig` - free_local and free_local_if opcode handlers in run() switch
- `src/chunk.zig` - OpCode enum (free_local, free_local_if)
- `src/token.zig` - kw_own token
- `src/ast.zig` - Param.is_own field
- `OWNERSHIP.md` - full spec including LSP integration details

## constraints

- **LLVM perturbation**: adding opcodes to the OpCode enum changes switch dispatch layout and can cause benchmark regressions across ALL benchmarks. always benchmark after structural changes to vm.zig or chunk.zig
- **shallow free only**: deepFree must NOT recurse into struct fields or array elements. they may be constant pool values (string literals from source) that were never heap-allocated. freeing them causes bus errors
- **constant pool strings**: ObjString.chars may point into source code or constant data, not heap memory. never free strings inside deepFree
- **drop flag scope**: drop flags must be allocated at the same scope depth as the owned local they guard, not inside the conditional block. otherwise the flag gets popped at the wrong time in loops

## verification

- `zig build` - compiler builds
- `zig build test` - all unit tests pass
- `make examples` - all 37 examples produce expected output
- `bash bench/run.sh` - benchmarks within expected ranges (fib ~0.67s, loop ~0.20s, struct ~0.33s)
