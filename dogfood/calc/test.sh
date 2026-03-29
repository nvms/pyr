#!/bin/bash
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
PYR="${DIR}/../../zig-out/bin/pyr"

check() {
  desc="$1"
  expected="$2"
  shift 2
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

check_err() {
  desc="$1"
  expected="$2"
  shift 2
  actual=$("$PYR" run "$DIR/main.pyr" -- "$@" 2>&1) && {
    echo "FAIL: $desc (expected error, got success: $actual)"
    exit 1
  }
  if [ "$actual" = "$expected" ]; then
    echo "pass: $desc"
  else
    echo "FAIL: $desc"
    echo "  expected: $expected"
    echo "  actual:   $actual"
    exit 1
  fi
}

check "addition" "5" "2 + 3"
check "subtraction" "63" "100 - 37"
check "multiplication" "18" "(4 + 5) * 2"
check "division" "3" "10 / 3"
check "modulo" "1" "10 % 3"
check "precedence" "26" "2 * 3 + 4 * 5"
check "parentheses" "21" "(1 + 2) * (3 + 4)"
check "nested parens" "30" "((2 + 3) * (1 + 1)) * 3"
check "float" "6.28" "3.14 * 2"
check "negative" "-2" "-5 + 3"
check "negative paren" "-21" "-(1 + 2) * (3 + 4)"
check "spaces" "10" "  5  +  5  "
check "single number" "42" "42"

check_err "division by zero" "calc: division by zero" "10 / 0"
check_err "unmatched paren" "calc: expected closing parenthesis" "(2 + 3"
check_err "bad input" "calc: expected number at position 4" "2 + + 3"

echo ""
echo "all calc tests passed"
