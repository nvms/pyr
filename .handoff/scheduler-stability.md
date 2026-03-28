# scheduler stability under load - handoff

## what was done

this session implemented LSP ownership hints, clone builtin, break keyword, dogfood tools (grep, wc, cat, head, jq, httpd), fixed a use-after-free aliasing bug in the ownership model, and added preemptive yielding at loop boundaries.

the preemptive yield exposed a crash: the arena HTTP server segfaults under high concurrency (100 simultaneous connections via wrk). individual requests work fine.

## current state

- all 300 tests pass, 40 examples pass
- static file httpd works at 30-34K req/sec with spawn-per-connection
- arena server crashes under load (SIGABRT, exit code 134) when wrk hammers it with 100 concurrent connections
- preemptive yield is implemented in run()'s loop_ handler (vm.zig ~line 551)
- fib benchmark shows ~28% regression from LLVM perturbation (known issue, switch layout change)

## what to do next

### 1. fix the arena-under-load crash

the arena server at `dogfood/httpd/arena-bench/server.pyr` crashes under concurrent load. reproduce:

```
cd dogfood/httpd/arena-bench
pyr run server.pyr 9970 &
wrk -t4 -c100 -d5s http://127.0.0.1:9970/
```

individual requests work: `curl http://localhost:9970/` returns correct JSON.

likely causes:
- **scheduler run queue overflow**: the queue starts at 64 slots and doubles, but rapid spawn/complete cycles under 100 concurrent connections may overflow before growth
- **arena stack corruption**: ArenaStack holds max 16 nested arenas. under concurrent spawns, arena push/pop may conflict if the arena_stack is shared (it's a heap-allocated side struct on the VM)
- **task allocation pressure**: ObjTask.create allocates 256-value stack + 64-frame array per task. 100 simultaneous tasks = significant allocation pressure

debugging approach:
1. run the server under load and capture the full crash trace (not just the first few frames)
2. check if the crash is in arena code (push_arena/pop_arena), scheduler code (enqueue/dequeue), or task creation
3. add bounds checking to scheduler.enqueue() - currently returns silently if queue is full, which drops tasks
4. check if arena_stack is shared across tasks (it shouldn't be - each task needs its own)

### 2. investigate fib benchmark regression

the fib(35) benchmark regressed from 0.67s to 0.86s (~28%). fib is recursive (no loops), so the loop_ yield check never fires. this is pure LLVM perturbation from adding code to the loop_ case in run()'s switch.

options:
- accept the regression (it's only for recursive-heavy code)
- try `@branchHint(.cold)` on the yield check path
- restructure the yield to be a separate function call to minimize switch case code size
- move the yield check to a new opcode `yield_check` emitted by the compiler only when `sched.active` could be true (functions that contain spawn)

### 3. continue dogfooding

once the crash is fixed, rerun the arena benchmark and compare p99 latency against python/node/bun. this is pyr's thesis: consistent latency without GC pauses.

## files to know

- `src/vm.zig` - scheduler (line 69), preemptive yield in loop_ handler (line 551), context switching (saveToTask/switchTo/yieldTo around line 1834)
- `src/compiler.zig` - mayAliasCallResult (ownership aliasing fix), break compilation, emitLoop
- `dogfood/httpd/arena-bench/` - the failing benchmark (server.pyr + bench.sh + comparison servers)
- `dogfood/httpd/` - working static file server + benchmark (34K req/sec)

## constraints

- **LLVM perturbation**: any change to VM struct, OpCode enum, or run() switch can cause benchmark regressions across ALL benchmarks. always benchmark after structural changes
- **arena_stack**: heap-allocated side struct, max 16 levels. must be per-task if used in concurrent code
- **shallow free only**: deepFree must not recurse into struct fields or array elements
- **preemptive yield**: only in run(), not fastLoop(). fastLoop functions that loop won't yield, but spawn bodies go through run() because they call non-locals_only functions

## verification

- `zig build` - compiler builds
- `zig build test` - all tests pass
- `make examples` - all 40 examples pass
- `bash bench/run.sh` - benchmarks (fib ~0.86s with current regression)
- `cd dogfood/httpd && pyr run main.pyr www 8080` - static file server works
- `cd dogfood/httpd/arena-bench && pyr run server.pyr 9970` then `curl localhost:9970` - single request works
