## what was done

this session implemented the arena memory model (phase 1) and fixed two bugs:

- `arena { ... }` blocks with push_arena/pop_arena opcodes, ArenaStack side struct
- fixed stack leak in for-range loops (missing beginScope/endScope around body)
- added explicit return tests (early return from nested blocks works correctly)

current state: 65 opcodes, 119 tests, 14 examples, 8 benchmarks, CI green

## what to do next

implement `std/json` as a compiler-intrinsic stdlib module, following the same pattern as std/io, std/fs, std/os.

### API design

```pyr
imp std/json { encode, decode }

// encode: Value -> str (any pyr value to JSON string)
data = [1, "hello", true, nil]
s = encode(data)
println(s)  // [1,"hello",true,null]

p = Point { x: 10, y: 20 }
println(encode(p))  // {"x":10,"y":20}

// decode: str -> Value (JSON string to pyr value)
obj = decode("{\"name\":\"alice\",\"age\":30}")
// returns a struct-like value or nested arrays/primitives

// namespace import
imp std/json
s = json.encode(data)
```

### type mapping

JSON -> pyr:
- `number` (integer) -> int
- `number` (float) -> float
- `string` -> str
- `true`/`false` -> bool
- `null` -> nil
- `array` -> array (ObjArray)
- `object` -> struct (ObjStruct with dynamic field names)

pyr -> JSON:
- int -> number
- float -> number
- str -> string (with proper escaping: \n, \t, \\, \", unicode)
- bool -> true/false
- nil -> null
- array -> array (recursive)
- struct -> object (field names as keys, recursive)
- enum -> object like `{"variant":"Name","payloads":[...]}` or just `"Name"` for no-payload variants
- function/closure/native_fn -> skip or error

### implementation approach

**encode (easier, do first):**

add `jsonEncode` to stdlib.zig as a native function. it takes one Value arg, returns an ObjString containing the JSON. the serialization is recursive - walk the Value tag, emit the appropriate JSON. similar to `writeValueTo` in stdlib.zig but writing to a buffer instead of an fd.

key details:
- use a growable `std.ArrayListUnmanaged(u8)` as the output buffer
- string escaping: `"` -> `\"`, `\` -> `\\`, newline -> `\n`, tab -> `\t`, control chars -> `\uXXXX`
- float formatting: use zig's `std.fmt.bufPrint` with `{d}` format
- struct fields become JSON object keys in declaration order
- arrays recurse into elements
- the allocator arg to the native function is the current arena allocator (already wired up via currentAlloc)

**decode (harder):**

add `jsonDecode` to stdlib.zig. takes one string arg, returns a pyr Value. needs a simple recursive descent JSON parser.

key details:
- parse `{...}` -> ObjStruct with dynamically discovered field names
- parse `[...]` -> ObjArray
- parse `"..."` -> ObjString (handle escape sequences)
- parse numbers -> int if no decimal/exponent, float otherwise
- parse `true`/`false` -> bool
- parse `null` -> nil
- skip whitespace between tokens
- error handling: return nil on malformed JSON (or consider an error value if the language supports it later)
- the decoded values are allocated via the allocator arg, so they participate in arena scoping

### stdlib.zig changes

add to the modules array:
```zig
.{ .name = "json", .functions = &json_fns },
```

add the function table:
```zig
const json_fns = [_]NativeDef{
    .{ .name = "encode", .arity = 1, .func = &jsonEncode },
    .{ .name = "decode", .arity = 1, .func = &jsonDecode },
};
```

### testing

- encode: int, float, string, bool, nil, array, nested array, struct, nested struct, enum with/without payload, string escaping (quotes, backslashes, newlines, unicode)
- decode: all JSON types, nested objects/arrays, string escapes, whitespace handling, number types (int vs float), malformed input returns nil
- round-trip: encode(decode(s)) == s for well-formed JSON
- add an `examples/json.pyr` with .expected file

### example

```pyr
imp std/json { encode, decode }

struct User {
  name: str
  age: int
}

fn main() {
  u = User { name: "alice", age: 30 }
  s = encode(u)
  println(s)

  data = decode("[1, 2, 3]")
  println(len(data))
  println(data[0])

  nested = decode("{\"users\":[{\"name\":\"bob\",\"age\":25}]}")
  println(encode(nested))
}
```

## files to know

- `src/stdlib.zig` - where std modules are defined. look at existing modules (io, fs, os) for the pattern. `writeValueTo` is useful reference for recursive value traversal
- `src/value.zig` - all Obj types, their create() methods. ObjStruct.create needs field_names + values. ObjArray.create takes a slice
- `src/compiler.zig` - how std imports are resolved (line 221, `stdlib.findModule`). no changes needed here
- `src/vm.zig` - native functions receive `currentAlloc()` as their allocator arg. no changes needed
- `INTERNALS.md` - stdlib section explains the intrinsic module pattern

## constraints

- native functions have signature `fn(std.mem.Allocator, []const Value) Value` - single return value, allocator for creating objects
- string escaping must be correct for JSON spec compliance. test with embedded quotes, backslashes, newlines, tabs, null bytes
- ObjStruct.create needs a `[]const []const u8` for field names and `[]Value` for values. the field names must be allocated (not stack references) since they persist
- the allocator passed to native functions is already the current arena allocator. decoded values automatically participate in arena scoping
- don't add JSON opcodes to the VM. this is a stdlib module, not a language primitive. native function calls handle it

## verification

```
make build     # compiler builds
make test      # all tests pass (currently 119)
make examples  # all examples validate (currently 14)
```
