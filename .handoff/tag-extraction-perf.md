# tag extraction performance regression

## what was done

this session implemented NaN boxing (16->8 byte Values), array superinstructions (index_local, index_local_local), 16 array/string builtins, and map/filter/reduce as pre-compiled helper functions. then fixed CI by expanding payload from 45 to 47 bits for linux x86_64 pointer compatibility.

## current state

all 255 tests pass, all 35 examples pass, CI green on both ubuntu and macos. everything is committed and pushed on main.

## what to do next

the 47-bit payload change regressed tight benchmarks by 10-30%. the tag extraction now does two separate bit extractions (sign bit + mantissa bits) and combines them, versus the old single contiguous extraction.

current tag extraction:
```zig
pub fn tag(self: Value) Tag {
    if ((self.bits & QNAN) != QNAN) return .float;
    const hi: u5 = @truncate((self.bits >> 63) & 1);
    const lo: u5 = @truncate((self.bits >> TAG_SHIFT) & 0x7);
    return @enumFromInt((hi << 3) | lo);
}
```

the hot path (fastLoop) calls tag() on every value comparison. the loop benchmark regressed 30% (0.20s -> 0.26s), array 14%, closure 12%.

### approaches to fix

1. **avoid tag() in the hot path** - the fastLoop switch dispatch compares tag values. instead of calling tag(), compute the full NaN-boxed signature directly. for example, `val.tag() == .int` could become `(val.bits & SIGNATURE_MASK) == INT_SIGNATURE` where INT_SIGNATURE is the pre-computed bit pattern for int (QNAN | (2 << 47)). this avoids the branch, two shifts, and enum conversion entirely. define constants:
   ```
   const SIG_INT = QNAN | (2 << 47)      // tags 0-7, sign bit 0
   const SIG_ARRAY = SIGN | QNAN | (0 << 47)  // tag 8, sign bit 1
   const SIG_MASK = SIGN | QNAN | (0x7 << 47)  // mask for tag bits
   ```
   then `val.bits & SIG_MASK == SIG_INT` is a single AND + compare. this should recover the regression entirely

2. **specialized is* methods** - add `isInt()`, `isArray()`, `isString()` etc. that check the signature directly without going through tag(). the compiler and fastLoop use these instead of tag() == .X

3. **alternative encoding** - use a lookup table or different bit arrangement that makes tag extraction cheaper

approach 1 is the recommended path. it's the simplest, most targeted fix, and should fully recover the regression since it replaces the expensive tag() computation with a single bitwise comparison.

### other work to consider

- **dogfooding** - build something real in pyr
- **pyr fmt** - formatter for pyr source
- **match optimization** - 1.25x python gap
- **struct optimization** - 1.55x python gap

## files to know

- `src/value.zig` - Value encoding, tag(), encode(), all init*/as* methods
- `src/vm.zig` - fastLoop (line ~1073), run() - the two dispatch loops
- `src/compiler.zig` - analyzeLocalsOnly, the three build*Func helpers for map/filter/reduce

## constraints

- LLVM perturbation: benchmark after every VM structural change
- the sign bit trick: tags 0-7 have bit 63=0, tags 8-15 have bit 63=1. float detection ignores the sign bit: `(bits & 0x7FFC000000000000) != 0x7FFC000000000000`
- ext types (listener, dgram, tls_conn, ssl_ctx, ssl_conn) share tag 15 with tagged-pointer secondary dispatch (low 3 bits of pointer). ObjListener and ObjDgram have forced 8-byte alignment via `_align: usize` padding field
- 47-bit signed ints: range +/- 70.4 trillion. sign extension via `(raw << 17) >> 17`

## verification

- `make build` - compiler builds
- `make test` - all 255 tests pass
- `make examples` - all 35 examples pass
- `bash bench/run.sh` - benchmarks (compare against python)

## current benchmarks

fib 0.69s (python 0.88s), loop 0.26s (python 0.23s), closure 0.27s (python 0.32s), struct 0.34s (python 0.20s), string 0.007s (python 0.14s), array 0.73s (python 0.65s), match 2.65s (python 2.12s), arena 0.29s (python 0.21s), channel 0.02s (python 0.10s), tcp_echo 0.19s (python 0.17s)
