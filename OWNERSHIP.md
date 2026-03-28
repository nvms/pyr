# pyr ownership model

compile-time automatic memory management. the compiler tracks ownership of heap-allocated values, determines when they become unreachable, and inserts frees at the optimal points. no garbage collector, no reference counting, no manual free. deterministic, zero-overhead deallocation.

## core concept

every heap-allocated value (struct, array, string) has exactly one owner at any point in time. ownership is determined by how the value was created and how it flows through the program. the compiler tracks this statically and inserts deallocation at the earliest safe point after last use.

stack values (int, float, bool, nil) are unaffected - they live on the VM stack and require no management.

## ownership rules

### 1. creation = ownership

when you create a heap value, you own it:

```pyr
fn process() {
  user = User { name: "alice" }   // you own user
  parts = split(data, ",")        // you own parts
  items = [1, 2, 3]               // you own items
}
```

### 2. return = transfer

returning a heap value transfers ownership to the caller:

```pyr
fn find_user(id: int) -> User {
  user = User { name: "alice", id: id }
  return user   // ownership transfers to caller
}

fn main() {
  user = find_user(1)   // you own user now
}
```

### 3. parameters are borrowed

function parameters are borrowed by default. the callee can read, mutate, and pass them around - but does not own them. the caller retains ownership:

```pyr
fn format(user: User) -> str {
  user.name = to_upper(user.name)   // mutation is fine
  return user.name + " (" + int(user.id) + ")"
}

fn main() {
  user = find_user(1)
  label = format(user)    // user is borrowed by format
  println(user.name)      // still valid - we own user
}
// compiler frees user and label here
```

### 4. own parameters

when a function needs to take ownership (e.g. storing in a long-lived structure), the parameter is marked `own`:

```pyr
fn cache_put(cache: Cache, own item: Item) {
  push(cache.entries, item)   // item is now owned by the array
}

fn main() {
  item = make_item()
  cache_put(cache, item)   // ownership transferred
  println(item.name)       // COMPILE ERROR: item was moved
}
```

at the call site, `own` parameters consume the value. using it after is a compile error.

### 5. move into structures

assigning a value to a struct field or pushing to an array moves ownership into the container:

```pyr
fn main() {
  name = "alice"
  user = User { name: name }   // name moved into user
  println(name)                // COMPILE ERROR: name was moved
  println(user.name)           // fine - access through the owner
}
```

### 6. auto-free after last use

the compiler determines the last use of every owned value and inserts a free after it:

```pyr
fn handle(req: Request) -> Response {
  user = find_user(req.id)
  config = load_config()
  body = json_encode(user)        // last use of user -> freed here
  resp = Response { status: 200, body: body }
                                  // last use of config -> freed here
                                  // body moved into resp
  return resp                     // ownership to caller
}
```

scope exit is the backstop - anything still owned at scope exit is freed.

### 7. deep free

freeing a struct frees its fields recursively. freeing an array frees its elements. the entire object graph reachable from the freed value is deallocated:

```pyr
fn main() {
  users = [
    User { name: "alice" },
    User { name: "bob" }
  ]
}
// freeing users frees: the array, both User structs, both name strings
```

### 8. conditional moves and drop flags

when a move happens inside a branch, the compiler inserts a drop flag - a hidden boolean that tracks whether the value was moved:

```pyr
fn process(items: [Item]) -> Item? {
  mut result = nil
  for item in items {
    if item.score > 100 {
      result = item           // item moved (flag set)
    }
  }                           // item freed IF not moved (flag check)
  return result
}
```

the drop flag is one byte per variable, checked at the free point. the compiler emits: `if !moved { free(item) }`.

## what the compiler catches

### use after move

```
error: use of moved value `user`
  --> server.pyr:5:11
   |
 4 |   cache_put(cache, user)
   |                    ---- moved here (own parameter)
 5 |   println(user.name)
   |           ^^^^ used after move
```

### storing borrowed value in longer-lived structure

```
error: cannot store borrowed value `user` in `cache`
  --> server.pyr:3:3
   |
 2 | fn register(cache: Cache, user: User) {
   |                           ---- borrowed parameter
 3 |   push(cache.entries, user)
   |   ^^^^^^^^^^^^^^^^^^^^^^^^^ would outlive the borrow
   |
   = help: use `own user: User` to take ownership
```

### unnecessary own

```
warning: `own` parameter `data` is never stored or returned
  --> server.pyr:2:18
   |
 2 | fn process(own data: Data) {
   |                ^^^^ takes ownership but only reads
   |
   = help: remove `own` - borrowing is sufficient here
```

## interaction with existing features

### arena blocks

arena blocks remain as an explicit optimization for bulk-free patterns. inside an arena block, all allocations use the arena allocator and are freed in bulk at block exit. ownership rules still apply within the arena - the arena is the owner:

```pyr
for i in range(10000) {
  arena {
    req = Request { path: "/users" }
    handle(req)
  }
  // bulk free - faster than individual frees for many small allocations
}
```

without an arena, the compiler would insert individual frees (correct but potentially slower for many small allocations in a tight loop). arenas are a performance tool, not a correctness tool.

### closures

pyr uses copy-capture. the closure owns its copies. when the closure is freed, its captured values are freed:

```pyr
fn main() {
  user = User { name: "alice" }
  task = fn() { println(user.name) }
  // user was copied into the closure
  // original user still owned by main
  println(user.name)   // fine
}
// main exits: user freed, task freed (which frees its copy)
```

### spawned tasks

same as closures - the task captures copies and owns them. when the task completes, its captures are freed:

```pyr
fn main() {
  data = Data { value: 42 }
  spawn {
    process(data)   // data was copied into the task
  }
}
// main frees its copy, task frees its copy when done
```

### FFI

values passed to C via FFI need special handling. the compiler cannot track what C does with a pointer. use `pin` to prevent auto-free:

```pyr
fn main() {
  buf = make_buffer(4096)
  pin buf                     // compiler will NOT auto-free buf
  c_register_buffer(buf)      // C holds this pointer
  // ...
  unpin buf                   // re-enables auto-free
}
// buf freed here (after unpin)
```

`pin`/`unpin` is a narrow escape hatch for FFI. using `pin` without `unpin` is a compile warning ("pinned value is never unpinned - possible leak").

### global variables

global variables own their values for the program's lifetime. no auto-free:

```pyr
mut registry = []

fn register(own item: Item) {
  push(registry, item)   // item owned by global array
}
// registry lives until program exit
```

## LSP integration

the compiler has full ownership information at compile time. the LSP should surface this as visual hints so developers can see the memory story of their code without running it.

### 1. inline free hints (virtual text after last use)

after the last use of an owned local, show a virtual text hint indicating the value will be freed:

```pyr
fn handle(req: Request) -> Response {
  user = find_user(req.id)
  config = load_config()
  body = json_encode(user)        // <- `user` freed
  resp = Response { status: 200, body: body }
                                  // <- `config` freed
  return resp
}
```

for conditional moves with drop flags, show conditional free:

```pyr
fn process(d: Data, flag: bool) {
  if flag {
    consume(d)                    // <- `d` moved (ownership transferred)
  }
}                                 // <- `d` freed (if not moved)
```

**implementation**: the compiler already computes free points via `emitEarlyFrees()` and `endScope()`. the LSP needs the source locations (line numbers) where `free_local` and `free_local_if` opcodes are emitted. the compiler can produce a side-channel map of `{local_slot, local_name, free_line, is_conditional}` entries alongside the bytecode.

### 2. hover on function calls

when hovering over a function call, show ownership effects:

```
fn handle(req: Request) -> Response
  borrows: req
  creates: user (freed line 6), config (freed line 7), body (moved into resp)
  returns: Response (ownership to caller)
```

**implementation**: for each function, the compiler knows: which params are `own` vs borrowed (from `own_params` bitmask), which locals are created and owned (from `is_owned` on Local), where each is freed (from free point computation), and the return type. collect this into a function-level ownership summary.

### 3. hover on variables

when hovering over a variable, show its ownership status:

```
user: User
  owned by: handle()
  created: line 3 (returned from find_user)
  freed: line 6 (after last use)
```

for conditionally moved values:

```
d: Data
  owned by: process()
  created: line 2
  maybe moved: line 5 (consume, inside if)
  freed: line 7 (if not moved, via drop flag)
```

**implementation**: the compiler's Local struct already has `is_owned`, `drop_flag_slot`, and the AST span (via statement positions). augment with the free point location.

### 4. call site ownership transfer indicators

at call sites where `own` params are used, show which values are being transferred:

```pyr
cache_put(cache, item)   // <- `item` moved (ownership transferred)
```

**implementation**: check `fn_own_params` for the callee, match against argument identifiers, show inline hint for each `own` argument.

### implementation approach

pyr does not have an LSP server yet. when building one:

1. **ownership data**: add a compilation mode (or post-compilation pass) that produces an `OwnershipMap` struct containing: list of owned locals per function (name, slot, source span, free span, is_conditional), list of ownership transfers per call site (callee name, arg index, arg name, source span), function-level summaries (borrowed params, owned params, return ownership)

2. **LSP protocol**: use `textDocument/inlayHint` for free point hints. use `textDocument/hover` for variable and function ownership summaries. use `textDocument/codeLens` for function-level ownership overview

3. **the compiler already does the hard work**. the LSP just needs to read the compiler's analysis results and format them for the protocol. no new analysis needed - just plumbing

## implementation strategy

### compiler (sema + compiler.zig)

1. classify every local as stack or heap based on type
2. track ownership state per local: owned, borrowed, moved
3. for each owned local, compute last-use point via liveness analysis
4. detect moves: assignment to struct fields, array pushes, own parameters, return
5. detect violations: use after move, storing borrowed into longer-lived scope
6. for conditional moves, insert drop flag tracking
7. emit free opcodes at computed free points

### new opcodes

- `free_local <slot>` - free the heap value in local slot, deep free
- `free_local_if <slot> <flag_slot>` - conditional free based on drop flag

### vm changes

- implement `free_local`: read value from slot, recursively free the object graph
- implement `free_local_if`: check drop flag byte, conditionally free
- drop flag storage: reserve local slots for flags (compiler assigns them)

### phases

1. **ownership tracking in sema** - classify owned/borrowed/moved, detect errors
2. **liveness analysis in compiler** - compute free points, emit free opcodes
3. **vm free opcodes** - implement deep free
4. **drop flags** - conditional move handling
5. **LSP integration** - surface ownership info in editor
6. **arena interaction** - ensure arena blocks and ownership coexist correctly
