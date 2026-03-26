#!/usr/bin/env bash
set -e
cd "$(dirname "$0")"

PYR=../zig-out/bin/pyr

bench() {
    local name="$1"
    shift
    local result
    result=$(python3 -c "
import subprocess, time, sys
start = time.perf_counter()
r = subprocess.run(sys.argv[1:], capture_output=True)
elapsed = time.perf_counter() - start
if r.returncode != 0:
    print(f'FAIL:{r.stderr.decode().strip()[:80]}')
else:
    print(f'{elapsed:.3f}')
" "$@")
    if [[ "$result" == FAIL:* ]]; then
        printf "  %-12s %s\n" "$name" "${result#FAIL:}"
    else
        printf "  %-12s %ss\n" "$name" "$result"
    fi
}

verify() {
    local name="$1"
    shift
    local result
    result=$("$@" 2>&1 | head -1)
    if [ "$result" != "$2" ]; then
        echo "  $name: WRONG (got '$result', expected '$2')"
    fi
}

echo "pyr benchmarks"
echo ""

echo "building pyr (release)..."
(cd .. && zig build -Doptimize=ReleaseFast > /dev/null 2>&1)

echo "fib(35) - recursive fibonacci"
bench "pyr" $PYR run fib.pyr
bench "python" python3 fib.py
if command -v lua > /dev/null 2>&1; then
    bench "lua" lua fib.lua
else
    printf "  %-12s (not installed)\n" "lua"
fi
echo ""

echo "loop - 10M iteration sum"
bench "pyr" $PYR run loop.pyr
bench "python" python3 loop.py
if command -v lua > /dev/null 2>&1; then
    bench "lua" lua loop.lua
else
    printf "  %-12s (not installed)\n" "lua"
fi
echo ""

echo "closure - 10M closure calls with capture"
bench "pyr" $PYR run closure.pyr
bench "python" python3 closure.py
if command -v lua > /dev/null 2>&1; then
    bench "lua" lua closure.lua
else
    printf "  %-12s (not installed)\n" "lua"
fi
echo ""

echo "struct_access - 10M field reads on single struct"
bench "pyr" $PYR run struct_access.pyr
bench "python" python3 struct_access.py
if command -v lua > /dev/null 2>&1; then
    bench "lua" lua struct_access.lua
else
    printf "  %-12s (not installed)\n" "lua"
fi
echo ""

echo "string_ops - 100K concatenations"
bench "pyr" $PYR run string_ops.pyr
bench "python" python3 string_ops.py
if command -v lua > /dev/null 2>&1; then
    bench "lua" lua string_ops.lua
else
    printf "  %-12s (not installed)\n" "lua"
fi
echo ""

echo "array_sum - 10M index reads"
bench "pyr" $PYR run array_sum.pyr
bench "python" python3 array_sum.py
if command -v lua > /dev/null 2>&1; then
    bench "lua" lua array_sum.lua
else
    printf "  %-12s (not installed)\n" "lua"
fi
echo ""

echo "match - 30M enum dispatch"
bench "pyr" $PYR run match.pyr
bench "python" python3 match.py
if command -v lua > /dev/null 2>&1; then
    bench "lua" lua match.lua
else
    printf "  %-12s (not installed)\n" "lua"
fi
echo ""

echo "channel - 100K message passing"
bench "pyr" $PYR run channel.pyr
bench "python" python3 channel.py
if command -v lua > /dev/null 2>&1; then
    bench "lua" lua channel.lua
else
    printf "  %-12s (not installed)\n" "lua"
fi
echo ""

echo "arena_alloc - 1M struct create (no arena vs scoped arena)"
bench "pyr" $PYR run arena_alloc.pyr
bench "pyr+arena" $PYR run arena_alloc_scoped.pyr
bench "python" python3 arena_alloc.py
if command -v lua > /dev/null 2>&1; then
    bench "lua" lua arena_alloc.lua
else
    printf "  %-12s (not installed)\n" "lua"
fi
echo ""
