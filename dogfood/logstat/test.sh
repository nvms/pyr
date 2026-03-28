#!/bin/bash
set -e
cd "$(dirname "$0")"
PYR="../../zig-out/bin/pyr"

echo "logstat dogfood tests"
echo "====================="

echo -n "run ... "
output=$($PYR run main.pyr -- test.jsonl 2>&1)
echo "$output" | grep -q "total entries: 20" && echo "ok" || { echo "FAIL"; echo "$output"; exit 1; }

echo -n "build ... "
$PYR build main.pyr -o /tmp/logstat_test 2>/dev/null
built_output=$(/tmp/logstat_test -- test.jsonl 2>&1)
if [ "$output" = "$built_output" ]; then
  echo "ok (binary matches interpreter)"
else
  echo "FAIL (output mismatch)"
  diff <(echo "$output") <(echo "$built_output")
  exit 1
fi

echo -n "counts ... "
echo "$output" | grep -q "debug: 4" || { echo "FAIL debug"; exit 1; }
echo "$output" | grep -q "info:  10" || { echo "FAIL info"; exit 1; }
echo "$output" | grep -q "warn:  3" || { echo "FAIL warn"; exit 1; }
echo "$output" | grep -q "error: 3" || { echo "FAIL error"; exit 1; }
echo "$output" | grep -q "error rate: 15%" || { echo "FAIL rate"; exit 1; }
echo "ok"

echo -n "slowest ... "
echo "$output" | grep -q "/api/external 10000ms" || { echo "FAIL"; exit 1; }
echo "$output" | grep -q "/api/batch 2200ms" || { echo "FAIL"; exit 1; }
echo "ok"

echo -n "endpoints ... "
echo "$output" | grep -q "/api/external: 2 reqs, avg 7500ms" || { echo "FAIL"; exit 1; }
echo "$output" | grep -q "/health: 4 reqs, avg 1ms" || { echo "FAIL"; exit 1; }
echo "ok"

echo -n "empty file ... "
echo "" > /tmp/logstat_empty.jsonl
empty_out=$($PYR run main.pyr -- /tmp/logstat_empty.jsonl 2>&1)
echo "$empty_out" | grep -q "total entries: 0" && echo "ok" || { echo "FAIL"; echo "$empty_out"; exit 1; }

echo -n "malformed lines ... "
printf '{"level":"info","message":"good","endpoint":"/ok","duration_ms":10}\nnot json\n{"level":"error","message":"bad","endpoint":"/err","duration_ms":99}\n' > /tmp/logstat_bad.jsonl
bad_out=$($PYR run main.pyr -- /tmp/logstat_bad.jsonl 2>&1)
echo "$bad_out" | grep -q "total entries: 2" && echo "ok" || { echo "FAIL"; echo "$bad_out"; exit 1; }

rm -f /tmp/logstat_test /tmp/logstat_empty.jsonl /tmp/logstat_bad.jsonl
echo ""
echo "all tests passed"
