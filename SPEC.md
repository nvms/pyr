# pyr language spec

## file extension

`.pyr`

## types

**structs** - product types, plain data:
```
struct User {
  id: int
  name: str
  email: str
  active: bool
}
```

packed structs for explicit memory layout:
```
struct PacketHeader packed {
  version: u4
  length: u12
  flags: u8
  seq: u32
}
```

**enums** - algebraic sum types (rust-style, not C-style):
```
enum Shape {
  Circle(f64)
  Rect(f64, f64)
  Point
}

enum Result(T, E) {
  Ok(T)
  Err(E)
}

enum Option(T) {
  Some(T)
  Nil
}
```

simple enums (no payloads):
```
enum Color { Red, Green, Blue }
```

**traits** - named structural constraints. no explicit conformance - if a type has the right functions via UFCS, it satisfies the trait automatically:
```
trait Serializable {
  fn serialize(self) -> []u8
  fn deserialize(data: []u8) -> Self
}
```

**no classes. no inheritance. no constructors.** structs are plain data. composition over inheritance.

## numbers

ergonomic defaults with explicit sizes when needed:

| type | meaning |
|------|---------|
| `int` | i64 (default integer) |
| `float` | f64 (default float) |
| `bool` | boolean |
| `byte` | u8 alias |
| `usize` | pointer-sized unsigned |
| `isize` | pointer-sized signed |
| `u8` `u16` `u32` `u64` | explicit unsigned |
| `i8` `i16` `i32` `i64` | explicit signed |
| `f32` `f64` | explicit float |

numeric literals: `1_000_000`, `0xFF`, `0b1010`, `0o755`

## strings

`str` is an immutable UTF-8 slice (pointer + length). not null-terminated.

```
name = "alice"
greeting = "hello {name}"     // interpolation
raw = r"no \escapes"          // raw string
multi = """
  multi-line strings
  auto-dedent
"""

name.len                       // 5 (bytes)
name.chars()                   // iterator over codepoints
name[0..3]                     // "ali" (byte slice)
```

`str.builder()` for mutable string building. `[]u8` for raw bytes. explicit conversion between `str` and `[]u8`.

## variables and immutability

everything immutable by default:
```
x = 5
x = 6              // compile error

mut y = 5
y = 6              // ok

user = User { name: "alice", ... }
user.name = "bob"  // compile error

mut user = User { name: "alice", ... }
user.name = "bob"  // ok
```

function parameters are always immutable. mutable access requires a pointer:
```
fn reset_name(u: *mut User) {
  u.name = "anonymous"
}
```

## functions

```
fn add(a: int, b: int) -> int {
  a + b
}

// one-liner
fn double(x: int) -> int = x * 2

// closures
users.filter(fn(u) u.active)
```

no semicolons. newline-terminated, continuation on operators.

## UFCS (uniform function call syntax)

any function can be called with dot syntax on its first argument. no methods, no impl blocks.

```
fn full_name(u: User) -> str {
  "{u.first} {u.last}"
}

// both identical:
full_name(user)
user.full_name()
```

chaining works naturally:
```
users
  .filter(fn(u) u.active)
  .map(fn(u) u.full_name())
  .sort()
```

## pattern matching

```
fn area(s: Shape) -> f64 = match s {
  Circle(r) -> math.pi * r * r
  Rect(w, h) -> w * h
  Point -> 0.0
}

fn describe(val) = match val {
  0 -> "zero"
  n if n < 0 -> "negative"
  n -> "positive: {n}"
}
```

## pipeline operator

```
data
  |> filter(fn(x) x > 0)
  |> map(fn(x) x * 2)
  |> sort()
  |> take(10)
```

## option and error handling

### option types (might be absent)

postfix `?` on types:
```
fn find(id: int) -> User? { ... }
```

`or` operator for unwrap-or-fallback:
```
user = find(42) or default_user()
user = find(42) or { return }
```

`?` suffix for early return on nil:
```
fn greet(id: int) -> str? {
  name = find(id)?
  "hello " + name
}
```

### result types (might have failed)

postfix `!` on types. bare `!` means string error, `!(E)` for typed errors:
```
fn parse(raw: str) -> Config! {
  if raw.len == 0 { fail "empty input" }
  do_parse(raw)
}

fn connect(addr: str) -> Conn!(IoError) {
  ...
}
```

`fail` produces an error value and returns from the function:
```
fail "something went wrong"
fail IoError.Timeout
```

`or` catches both nil and error:
```
config = parse(data) or default_config()
safe = parse(data) or 0
```

`or |err|` binds the error value:
```
config = parse(data) or |err| {
  log("failed: " + err)
  default_config()
}
```

`?` propagates errors up the call chain:
```
fn load_settings(path: str) -> Settings! {
  raw = fs.read(path)?
  config = parse(raw)?
  validate(config)?
  config
}
```

`!` crashes on nil or error (unwrap-or-die):
```
config = parse(data)!
```

### error type compatibility

| from | into | result |
|------|------|--------|
| `T!` | `U!` | passes through (both string errors) |
| `T!(IoError)` | `U!` | IoError stringified, propagates |
| `T!(IoError)` | `U!(IoError)` | passes through directly |
| `T!(IoError)` | `U!(HttpError)` | compiler error |

### truthiness

`nil` and `false` are falsy. `0`, empty strings, and error values are falsy. everything else is truthy.

`&&` and `||` short-circuit and return actual values:
```
nil && true     // nil
nil || "yes"    // "yes"
```

`or` checks for nil specifically (not falsiness), so `false or x` returns `false`.

## concurrency

lightweight green threads (tasks) on a work-stealing thread pool:
```
profile, orders = await_all(
  spawn { get_profile(id) },
  spawn { get_orders(id) },
)
```

typed channels:
```
ch = channel(str, capacity: 100)
spawn { ch.send("hello") }
msg = ch.recv()
```

## modules and visibility

a file is a module. `pub` for public visibility. everything private by default.

```
// models.pyr
pub struct User {
  id: int
  name: str
}

pub fn validate(u: User) -> User!([]str) { ... }

fn internal_helper() { ... }  // not visible outside
```

imports:
```
imp std/http
imp std/fs
imp models { User }
imp db/postgres as pg
```

`pub struct` makes all fields visible. encapsulation via module boundaries, not field-level access control.

## arena memory

arena blocks scope all allocations to a region freed in bulk on exit:
```
fn process(data: str) {
  arena {
    parsed = parse(data)
    result = transform(parsed)
    save(result)
  }
  // all memory from arena block freed here
}
```

arenas nest. inner arenas are freed before outer ones:
```
arena {
  arena {
    // allocations freed here
  }
  // outer arena still alive
}
```

the server stdlib wraps each request handler in an implicit arena block.

## defer

scoped cleanup, like zig. runs when its enclosing scope exits - whether by reaching the end, `return`, `fail`, or `?` propagation. multiple defers in the same scope run in reverse order (LIFO):
```
fn process() {
  conn = net.connect("localhost", 5432)
  defer net.close(conn)

  arena {
    defer flush_logs()
    // arena freed AND logs flushed on exit
  }

  // conn closed when process() returns
}
```

two forms - single expression or block:
```
defer net.close(conn)
defer {
  flush()
  log("done")
}
```

scoped, not function-level (unlike go). defer in a loop runs at each iteration end:
```
for file in files {
  f = fs.open(file)
  defer fs.close(f)
  // f closed at end of each iteration
}
```

## pointers (systems work)

high-level code never sees pointers. for systems/FFI work:
```
ptr: *User = &user
mut_ptr: *mut User = &mut user
raw: *u8 = buf.ptr
next = ptr.offset(1)
value = ptr.*
```

## FFI (foreign function interface)

call C functions from shared libraries via `extern` blocks:
```
extern "c" {
  fn getpid() -> cint
  fn strlen(s: cstr) -> cint
  fn getenv(name: cstr) -> cstr
}

extern "sqlite3" {
  fn sqlite3_open(path: cstr, db: ptr) -> cint
  fn sqlite3_close(db: ptr) -> cint
}
```

FFI types: `cint` (32-bit int), `cstr` (null-terminated string), `ptr` (raw pointer), `f64` (double), `void` (no return).

library `"c"` resolves to libc. other names are resolved via dlopen with platform-appropriate extensions (.dylib, .so, .dll).

strings are automatically null-terminated when passed as `cstr`. C strings returned as `cstr` are copied into pyr-managed memory. null pointers return `nil`.

## packages (draft)

this section is a loose spec - directional, not final.

### manifest: `pyr.pkg`

go.mod-style, purpose-built minimal format. not toml, not json - just a flat declarative file:

```
name httpserver
version 0.2.0

require (
  github.com/nvms/pyr-router v0.3.1
  github.com/nvms/pyr-json v1.0.0
)
```

that's it. no nested tables, no arrays of objects. `name`, `version`, and a `require` block with git-based package references and version tags.

versions are git tags. a commit hash works too for pinning:

```
require (
  github.com/nvms/pyr-router v0.3.1
  github.com/nvms/pyr-json abc1234
)
```

### lockfile: `pyr.lock`

auto-generated, records resolved commit hashes for every dependency (including transitive). ensures reproducible builds. never hand-edited.

### import syntax

packages are imported by their registered name (the `name` field from their pyr.pkg):

```
imp router { serve, get, post }
imp json { encode, decode }
```

if two packages export the same name, alias:

```
imp router as r
imp json as j
```

this extends the existing `imp` syntax naturally - std modules are `std/io`, local modules are `math`, packages are `router`.

### resolution

- `imp std/io` - stdlib (compiled-in)
- `imp math` - local file first (math.pyr relative to entry)
- `imp router` - if not local, check pyr.pkg dependencies

### local cache

```
~/.pyr/cache/
  github.com/
    nvms/
      pyr-router/
        v0.3.1/     <- git checkout at tag
          pyr.pkg
          src/
```

mirroring the git path like Go does. versions are directories. `pyr install` fetches, `pyr update` bumps within semver constraints.

### CLI

- `pyr init` - create pyr.pkg
- `pyr install` - fetch all dependencies into cache
- `pyr update [pkg]` - update to latest compatible version
- `pyr add <url> [version]` - add dependency

### open questions

- semver ranges vs exact pinning? (go uses minimum version selection - worth considering)
- how to handle packages with native/FFI dependencies?
- should packages declare their pyr version compatibility?
- private repos - ssh vs https auth?

## server stdlib

the killer app - arena-per-request, compiled route tables, native async I/O:
```
imp std/http { serve, get, post, ws }

fn main() {
  db = pg.connect(env("DATABASE_URL"))

  serve ":8080" {
    get "/users/:id" |req| {
      user = db.find(User, req.params.id) or not_found()
      json(user)
    }

    ws "/feed" |conn| {
      for msg in conn {
        broadcast(msg.text)
      }
    }
  }
}
```
