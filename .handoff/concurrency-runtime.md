## what was done

this session implemented std/json (encode/decode) and string escape sequence processing in the compiler. all tests pass, all examples validate, benchmarks stable.

current state: 65 opcodes, 119 tests, 15 examples, 8 benchmarks, CI green.

## what to do next

implement the concurrency runtime: green threads (tasks), channels, and a cooperative scheduler. this is step 8 on the roadmap and the prerequisite for std/net and std/http.

### spec (from SPEC.md)

```pyr
profile, orders = await_all(
  spawn { get_profile(id) },
  spawn { get_orders(id) },
)

ch = channel(str, capacity: 100)
spawn { ch.send("hello") }
msg = ch.recv()
```

### what already exists

- `spawn` keyword is already lexed (token.zig:42, kw_spawn), parsed (parser.zig:1004), analyzed in sema (sema.zig:491), but is a no-op in the compiler (compiler.zig:765)
- `spawn { expr }` and `spawn expr` both parse into an AST spawn node wrapping the body expression

### design approach

start with cooperative green threads on a single OS thread. work-stealing across multiple OS threads is a later optimization. the goal is to get the concurrency model working correctly first.

**new value types (value.zig):**
- `ObjTask` - a green thread. needs its own stack (heap-allocated Value array), call frames, IP, and state (ready/running/blocked/done). essentially a mini-VM state snapshot
- `ObjChannel` - typed channel with a bounded buffer. needs a ring buffer of Values, capacity, and wait queues (lists of blocked tasks waiting to send/recv)

**new tag variants (value.zig Value.Tag):**
- `task` for ObjTask
- `channel` for ObjChannel

**scheduler (new file or inside vm.zig):**
- the VM holds a run queue (list of ready tasks) and a reference to the current task
- `spawn { body }` creates a new ObjTask, compiles the body as a closure, and adds the task to the run queue. returns the ObjTask (so await_all can collect results)
- yield points: channel send/recv (when buffer is full/empty), explicit `yield` keyword (maybe later), and function calls could optionally yield (cooperative timeslicing)
- the scheduler runs in the VM's main loop: when the current task blocks or yields, save its state, pick the next ready task from the queue, restore its state, continue executing
- a task's return value is stored in the ObjTask when it completes

**new opcodes (chunk.zig):**
- `spawn` - pop a closure/function from the stack, create an ObjTask, add to run queue, push the ObjTask onto the stack
- `channel_create` - create a new ObjChannel with given capacity
- `channel_send` - pop value and channel from stack, send value. if buffer full, block current task
- `channel_recv` - pop channel from stack, receive value. if buffer empty, block current task
- `await_task` - pop ObjTask, block current task until target completes, push result
- `await_all` - pop array of ObjTasks, block until all complete, push array of results

**compiler changes (compiler.zig):**
- `spawn` node: compile the body as a closure (or inline function), emit `spawn` opcode
- `channel(type, capacity: N)` - recognize as builtin, emit `channel_create` with capacity operand
- `.send()` and `.recv()` on channels - could be method-call syntax compiled to opcodes, or builtin functions

**critical constraint - LLVM perturbation:**
- adding fields to the VM struct WILL cause LLVM relayout and potential benchmark regressions across ALL benchmarks
- the recommended approach: put all scheduler state in a heap-allocated side struct (like ConcatState and ArenaStack), accessed via pointer from VM
- do NOT add fields directly to VM struct, CallFrame, or change the OpCode enum ordering of existing opcodes (append new ones at the end)
- benchmark after every structural change

### implementation order

1. add ObjTask and ObjChannel to value.zig, add tag variants
2. add scheduler state as a heap-allocated side struct, wire into VM.init
3. add spawn opcode to chunk.zig (append after push_arena/pop_arena)
4. implement spawn in compiler.zig - compile body, emit spawn opcode
5. implement spawn in vm.zig - create task, context switch logic
6. add channel_create, channel_send, channel_recv opcodes
7. implement channel operations with blocking/waking
8. add await_task for collecting spawn results
9. write tests and examples
10. benchmark to check for LLVM perturbation

### simpler starting point

if full green threads feel too ambitious for one session, a viable incremental step is:

1. just get `spawn { expr }` working where it runs the body synchronously (coroutine-style, no preemption)
2. add channels as the synchronization primitive
3. context switching happens only at channel send/recv boundaries

this is basically goroutines without the multi-threaded scheduler - still very useful and much simpler to get right.

### task state machine

```
  spawn -> READY -> RUNNING -> DONE
                      |   ^
                      v   |
                   BLOCKED (waiting on channel/await)
```

when a task blocks:
1. save current task's IP, SP, frames to ObjTask
2. move task to appropriate wait queue (channel's send_waiters or recv_waiters)
3. dequeue next READY task from run queue
4. restore its IP, SP, frames to VM
5. continue execution

when a task unblocks (e.g. channel has space/data):
1. move task from wait queue to run queue (READY)
2. it will be picked up next time the scheduler runs

### example to target

```pyr
imp std/io { println }

fn producer(ch) {
  for i in range(5) {
    ch.send(i)
  }
}

fn consumer(ch) {
  for i in range(5) {
    msg = ch.recv()
    println(msg)
  }
}

fn main() {
  ch = channel(10)
  spawn { producer(ch) }
  consumer(ch)
}
```

## files to know

- `src/vm.zig` - VM struct, run() and fastLoop() dispatch, context for scheduler integration. ConcatState and ArenaStack show the pattern for heap-allocated side structs
- `src/value.zig` - all Obj types. add ObjTask and ObjChannel here
- `src/chunk.zig` - OpCode enum. append new opcodes at the end only
- `src/compiler.zig` - spawn node is at line 765 (currently no-op). compile spawn body here
- `src/parser.zig` - spawn parsing already done (line 1004). may need to add channel syntax
- `src/sema.zig` - spawn analysis already done (line 491). extend for channels
- `SPEC.md` - concurrency section (line 208) defines the target syntax
- `INTERNALS.md` - architecture docs, update when done

## constraints

- LLVM perturbation: do NOT add fields to VM struct directly. use heap-allocated side structs (see ConcatState/ArenaStack pattern). benchmark after structural changes
- new opcodes MUST be appended after pop_arena in the OpCode enum. do not reorder existing opcodes
- fastLoop contains if/else chains for hot-path opcodes. new concurrency opcodes should go in run() only unless proven safe
- the VM's stack is currently a fixed [256]Value array. tasks need their own stacks - heap-allocate them
- CallFrame array is [64]CallFrame. tasks need their own frame arrays too

## verification

```
make build     # compiler builds
make test      # all tests pass (currently 119)
make examples  # all examples validate (currently 15)
bash bench/run.sh  # no benchmark regressions
```
