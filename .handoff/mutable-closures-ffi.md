# handoff: mutable closures + FFI

## what was done

this session implemented three features:

1. **std/net** - TCP socket primitives (listen, accept, connect, read, write, close) with ObjListener and ObjConn value types
2. **std/http** - HTTP utility module (parse_request, respond, respond_status, json_response, route, match_route). server loop written in pyr using std/net
3. **non-blocking I/O** - `server.accept()` and `conn.read()` method-call syntax compiles to net_accept/net_read opcodes. when they'd block, the task is parked in the scheduler's I/O waiter arrays, scheduler switches to the next ready task. when all tasks are blocked, `scheduleNextOrPoll` calls `std.posix.poll()` on waiting fds and wakes ready tasks. transparent fallback to blocking poll when no scheduler is active

## current state

- 188 tests, 22 examples, 9 benchmarks, all passing
- concurrent server pattern works: spawn per connection with accept/read yielding to scheduler
- no LLVM perturbation from the changes
- benchmarks stable

## what to do next

### 1. mutable closure capture (medium)

closures currently use copy-capture. `mut x = 0; f = fn() { x += 1 }; f(); println(x)` prints 0, not 1. the captured x is a snapshot, not a reference.

**approach:**
- add `set_upvalue` opcode (counterpart to existing `get_upvalue`)
- compiler: when a closure assigns to a captured variable, emit `set_upvalue` instead of `set_local`
- VM: `set_upvalue` writes back to the ObjClosure's captured values array
- the tricky part: if two closures capture the same variable, they each get independent copies. true shared capture (like lua's upvalues-as-heap-cells) would require ObjUpvalue boxing. decide which semantics are right for pyr
- SPEC.md section on closures should guide the decision

**testing:**
- basic mutation through closure
- closure mutation visible to caller
- nested closure mutation
- closure mutation in spawned tasks (interaction with concurrency)
- multiple closures sharing a variable (if shared semantics chosen)

### 2. FFI - zero-cost zig/C interop (large)

this is what makes pyr a real systems language. without FFI, you can't call database drivers, TLS, compression, or any C library.

**approach options:**
- **comptime FFI**: declare foreign functions in pyr, compiler generates zig extern declarations and call wrappers at comptime. most "pyr-like" but requires deep compiler changes
- **dlopen FFI**: runtime dynamic loading via `std.c.dlopen`/`dlsym`. simpler to implement, more flexible, but has runtime overhead
- **native module FFI**: write zig modules that expose functions to pyr's native function registry. easiest but requires zig compilation per module

**recommended start:**
- native module approach first (extend stdlib.zig pattern to support loadable modules)
- then dlopen for dynamic C libraries
- comptime FFI as the final form

**key considerations:**
- type mapping: pyr int (i64) <-> C int/long, pyr float (f64) <-> C double, pyr string <-> C char*, pyr struct <-> C struct
- memory: who owns what? arena-allocated pyr values vs malloc'd C values
- error handling: C errors (errno, null returns) -> pyr error values
- read `~/code/vigil/learnings.md` for cross-cutting insights before making architecture decisions

## files to know

- `src/vm.zig` - VM interpreter, scheduler, I/O polling (lines 63-170 for scheduler/IoPoller)
- `src/compiler.zig` - bytecode compiler, compileCall for opcode emission (lines 1009-1040 for field_access interception)
- `src/value.zig` - value types, ObjClosure (upvalue capture), ObjTask
- `src/chunk.zig` - opcode enum
- `src/stdlib.zig` - native function registry, std modules
- `INTERNALS.md` - deep architecture notes
- `SPEC.md` - language spec (closure semantics, FFI syntax)

## constraints

- LLVM perturbation: do NOT add fields to VM struct directly. benchmark after any structural changes to VM, CallFrame, OpCode enum, or run() switch
- fastLoop: new specialized opcodes go in run() only unless proven safe in fastLoop
- the `read` and `accept` field names are intercepted by the compiler for ALL field access calls (runtime type check in VM). adding more intercepted names increases collision risk with user struct fields

## verification

```
make build
make test
make examples
bash bench/run.sh
```
