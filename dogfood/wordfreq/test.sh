#!/bin/bash
set -e
cd "$(dirname "$0")"
PYR="../../zig-out/bin/pyr"

echo "wordfreq dogfood tests"
echo "======================"

echo -n "run ... "
output=$($PYR run main.pyr -- test.txt 2>&1)
echo "$output" | grep -q "54 words, 30 unique" && echo "ok" || { echo "FAIL"; echo "$output"; exit 1; }

echo -n "top word ... "
echo "$output" | grep -q "10 the" && echo "ok" || { echo "FAIL"; exit 1; }

echo -n "build ... "
$PYR build main.pyr -o /tmp/wordfreq_test 2>/dev/null
built_output=$(/tmp/wordfreq_test -- test.txt 2>&1)
if [ "$output" = "$built_output" ]; then
  echo "ok (binary matches interpreter)"
else
  echo "FAIL (output mismatch)"
  exit 1
fi

rm -f /tmp/wordfreq_test
echo ""
echo "all tests passed"
