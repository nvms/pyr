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
  None
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

no null. option types with `?` suffix:
```
fn find(id: int) -> ?User { ... }

// ?? operator - unwrap or fallback
user = find(42) ?? default_user
user = find(42) ?? return not_found()
```

result types for errors:
```
fn parse(s: str) -> Result(Config, str) {
  content = fs.read(s) ?? return err("file not found")
  ok(json.decode(Config, content))
}
```

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

pub fn validate(u: User) -> Result(User, []str) { ... }

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

## pointers (systems work)

high-level code never sees pointers. for systems/FFI work:
```
ptr: *User = &user
mut_ptr: *mut User = &mut user
raw: *u8 = buf.ptr
next = ptr.offset(1)
value = ptr.*
```

## server stdlib

the killer app - arena-per-request, compiled route tables, native async I/O:
```
imp std/http { serve, get, post, ws }

fn main() {
  db = pg.connect(env("DATABASE_URL"))

  serve ":8080" {
    get "/users/:id" |req| {
      user = db.find(User, req.params.id) ?? not_found()
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
