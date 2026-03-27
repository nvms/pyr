# NaN boxing - pack Value from 16 bytes to 8 bytes

## what was done

- UFCS implemented (compile-time rewrite of `x.f(args)` to `f(x, args)`)
- fastLoop dispatch converted from if/else chain to switch statement (~5% uniform benchmark improvement)
- profiled all slow benchmarks (array_sum 2.6x python, match 2.1x python)
- confirmed the remaining perf gap is not dispatch overhead but data representation: Value is 16 bytes (tag enum + padding + u64), every stack slot and array element pays this cost

## current state

all tests pass, all 32 examples pass, benchmarks stable. the codebase is clean and committed on main.

current benchmark numbers (pyr vs python):
- fib: 0.80 vs 0.85 (faster)
- loop: 0.20 vs 0.21 (faster)
- closure: 0.25 vs 0.31 (faster)
- struct: 0.32 vs 0.19 (1.7x slower)
- string: 0.008 vs 0.14 (way faster)
- array_sum: 1.57 vs 0.60 (2.6x slower)
- match: 4.35 vs 2.03 (2.1x slower)
- arena: 0.51 vs 0.20 (2.5x slower)
- channel: 0.03 vs 0.10 (faster)

## what to do next

implement NaN boxing to pack Value into 8 bytes. this is the single highest-impact optimization available.

### the scheme

current Value (16 bytes):
```zig
pub const Value = struct {
    tag: Tag,    // enum(u8)
    data: u64,   // payload
};
```

NaN boxed Value (8 bytes):
```
- doubles stored directly as 64-bit IEEE 754
- non-double values encoded in the NaN space:
  - bits 63-51: quiet NaN signal (0x7FF8 or similar)
  - bits 50-48: type tag (3 bits = 8 types)
  - bits 47-0: 48-bit payload (enough for pointers and most ints)
```

key design decisions:
- **doubles pass through unchanged** - most common numeric type, zero encoding cost
- **integers**: 48 bits gives +/- 140 trillion range. for full i64 range, either box large ints or accept the limitation (48 bits is enough for most use cases)
- **pointers**: 48 bits is enough for user-space virtual addresses on all current architectures
- **booleans/nil**: encoded in the tag bits, payload is 0 or 1
- **tag values needed**: nil, bool, int, string, function, struct, enum, array, plus ~10 more (closure, native_fn, task, channel, listener, conn, dgram, tls_conn, ssl_ctx, ssl_conn, ptr, error_val). that's 19 tags total. 3 bits only gives 8. options:
  - use more NaN space bits for the tag (bits 50-48 for 3 bits, or bits 50-47 for 4 bits = 16 types, or 5 bits = 32 types)
  - group rare types under a single "object" tag and use a secondary tag in the heap object
  - the cleanest approach: use the full exponent + some mantissa bits. a quiet NaN has bits 62-52 = 0x7FF and bit 51 = 1. that leaves bits 50-0 = 51 bits. use 5 bits for tag (32 types, plenty) and 46 bits for payload. 46-bit pointers work on all current systems

recommended encoding:
```
if top 13 bits == 0x7FF8..0x7FFF (quiet NaN range):
    bits 50-48: not used for tag (these overlap with NaN signaling)

simpler approach - use the sign bit + exponent to signal non-double:
    QNAN = 0x7FFC000000000000 (quiet NaN base)
    tag = (value >> 47) & 0x1F   // 5-bit tag in bits 51-47
    payload = value & 0x00007FFFFFFFFFFF  // 47-bit payload
```

actually, the simplest proven scheme (used by LuaJIT, wren, many others):
```
all non-double values have bits 50-0 as payload and bits 63-51 as type signature:
    NANISH = 0x7FFC000000000000
    TAG_NIL     = NANISH | (0 << 47)
    TAG_BOOL    = NANISH | (1 << 47)
    TAG_INT     = NANISH | (2 << 47)
    TAG_STRING  = NANISH | (3 << 47)
    TAG_FUNC    = NANISH | (4 << 47)
    ...etc for all 19 types...

    isDouble(v): (v & NANISH) != NANISH
    getTag(v):   (v >> 47) & 0x1F
    getPayload(v): v & 0x00007FFFFFFFFFFF
```

with 5 tag bits, we have 32 slots - enough for all 19 current types plus room for growth.

for integers: 47 bits in the payload gives a range of 0 to 140 trillion unsigned, or -70T to +70T if we use the top bit as sign. alternatively, store i64 directly and check for overflow (if the int fits in 47 bits, NaN box it; otherwise heap-allocate). but for simplicity, just truncate to 47-bit signed (range: -70,368,744,177,664 to +70,368,744,177,663). this covers virtually all practical use cases. the fib(35) benchmark result is 9227465, well within range.

actually, the even simpler approach many VMs use: integers above the 47-bit range get stored as doubles (which can represent integers up to 2^53 exactly). so the full path for an integer:
1. if it fits in 47 signed bits, NaN box it
2. otherwise store as f64 (exact up to 2^53)
3. beyond 2^53, precision loss (acceptable for a scripting-ergonomics language)

### files to modify

1. **src/value.zig** - the core change. replace the struct with a u64. rewrite all init*/as* functions. rewrite Tag enum to be computed from bit patterns rather than a stored field. rewrite eql, isTruthy, toValue, tostring helpers. ObjString, ObjStruct, ObjEnum, ObjArray etc stay unchanged (they're heap objects pointed to by the NaN-boxed value)

2. **src/vm.zig** - update all tag checks (`val.tag == .int` becomes `val.isInt()`). update stack operations. the switch dispatch in fastLoop references `.tag` extensively. also update binaryOpSlow, comparisonOpSlow, runtimeError value formatting

3. **src/compiler.zig** - update Value.initInt, Value.initFloat, etc calls. update constant pool handling. most compiler code creates values through the init* functions so it should be mostly transparent

4. **src/stdlib.zig** - native function signatures take `[]const Value` and return `Value`. update tag checks in native functions

5. **src/ffi.zig** - marshaling between pyr Values and C types

6. **src/chunk.zig** - constant pool stores Values, should work transparently

7. **tests** - all existing tests should pass with no source changes (the Value API is the same, just the internal representation changes)

### implementation strategy

1. start with value.zig - define the NaN boxing constants, rewrite Value as a packed u64, rewrite all init*/as* methods, add isInt()/isFloat()/isString() etc. helper methods. keep the `.tag` field as a computed property that returns the same Tag enum so existing code works with minimal changes

2. update vm.zig - find all `val.tag == .X` patterns and update. the fastLoop switch cases reference tag extensively

3. update remaining files (compiler, stdlib, ffi)

4. build, test, benchmark

the key insight: if you make `Value.tag` a computed property (pub fn tag(self: Value) -> Tag) instead of a stored field, most of the codebase only needs to change from `val.tag` to `val.tag()`. but zig doesn't allow a field and a method with the same name, so you'd need to rename. the cleanest approach: keep `val.tag` as a field access somehow, or do a global rename to `val.getTag()` or just change all call sites.

actually the simplest: make tag a method, do a global find-replace of `.tag ==` to `.tag() ==` and `.tag` to `.tag()` where it's used as a value.

### constraints

- LLVM perturbation: changing Value size from 16 to 8 bytes will change struct layouts throughout the VM. benchmark after every intermediate step
- the stack array `[256 * 64]Value` will halve in size, which changes the VM struct layout
- ObjArray.items is `[]Value` - the element size halves, affecting memory layout
- integer range: decide on 47-bit signed vs heap-boxing for large ints. 47-bit signed is simpler and covers all practical cases
- keep all existing tests and examples passing throughout

### verification

- `make build` - compiler builds
- `make test` - all tests pass (246 tests)
- `make examples` - all 32 examples pass with correct output
- `bash bench/run.sh` - benchmarks should show improvement, especially array_sum and match
- expected improvement: 20-40% across the board from halved Value size

### what success looks like

array_sum drops from 1.57s to under 1.0s (closer to python's 0.60s). match drops from 4.35s to under 3.0s. fib, loop, closure all get faster. no regressions on any benchmark. all tests and examples pass.
