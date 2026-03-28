# grep

search files for a pattern, print matching lines.

## usage

```
pyr run dogfood/grep/main.pyr -- [flags] <pattern> <file> [file...]
```

## flags

- `-i` - case insensitive matching
- `-n` - show line numbers
- `-c` - count matches only
- `-v` - invert match (show non-matching lines)

## examples

```
pyr run dogfood/grep/main.pyr -- "fn main" src/*.zig
pyr run dogfood/grep/main.pyr -- -n -i "error" src/compiler.zig
pyr run dogfood/grep/main.pyr -- -c "test" src/vm.zig
```
