#!/bin/bash
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
PYR="${DIR}/../../zig-out/bin/pyr"

run() {
  echo "test: $1"
  shift
  "$PYR" run "$DIR/main.pyr" -- "$@"
  echo "---"
}

check() {
  desc="$1"
  shift
  expected="$1"
  shift
  actual=$("$PYR" run "$DIR/main.pyr" -- "$@" 2>&1)
  if [ "$actual" = "$expected" ]; then
    echo "pass: $desc"
  else
    echo "FAIL: $desc"
    echo "  expected: $expected"
    echo "  actual:   $actual"
    exit 1
  fi
}

check "full output" "name,age,city,role
alice,30,new york,engineer
bob,25,san francisco,designer
charlie,35,new york,engineer
diana,28,chicago,manager
eve,32,san francisco,engineer" "$DIR/test.csv"

check "select columns" "name,city
alice,new york
bob,san francisco
charlie,new york
diana,chicago
eve,san francisco" -c name,city "$DIR/test.csv"

check "filter rows" "name,age,city,role
alice,30,new york,engineer
charlie,35,new york,engineer" -f city=new\ york "$DIR/test.csv"

check "filter + select" "name,role
alice,engineer
charlie,engineer
eve,engineer" -f role=engineer -c name,role "$DIR/test.csv"

check "count rows" "5" --count "$DIR/test.csv"

check "count filtered" "3" --count -f role=engineer "$DIR/test.csv"

check "sort by age" "name,age,city,role
bob,25,san francisco,designer
diana,28,chicago,manager
alice,30,new york,engineer
eve,32,san francisco,engineer
charlie,35,new york,engineer" -s age "$DIR/test.csv"

check "quoted fields" "name,description,value
widget,\"a small, useful thing\",10
gadget,\"has \"\"special\"\" features\",25
doohickey,plain item,5" "$DIR/quoted.csv"

echo ""
echo "all csv tests passed"
