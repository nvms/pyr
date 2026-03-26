#!/usr/bin/env bash
set -e
cd "$(dirname "$0")"

PYR=../zig-out/bin/pyr

bench() {
    local name="$1"
    shift
    local elapsed
    elapsed=$(python3 -c "
import subprocess, time, sys
start = time.perf_counter()
subprocess.run(sys.argv[1:], capture_output=True)
print(f'{time.perf_counter() - start:.3f}')
" "$@")
    printf "  %-12s %ss\n" "$name" "$elapsed"
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
