#!/bin/bash
set +e

DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$DIR"

DURATION=10
THREADS=4
CONNECTIONS=100

echo "arena-per-request benchmark"
echo "  each request: create 10 records, serialize to JSON, respond"
echo "  duration: ${DURATION}s, threads: $THREADS, connections: $CONNECTIONS"
echo ""

bench() {
  local name=$1
  local url=$2
  echo "$name:"
  wrk -t$THREADS -c$CONNECTIONS -d${DURATION}s --latency $url 2>&1 | grep -E "Requests/sec|50%|75%|90%|99%"
  echo ""
}

# pyr
pyr run server.pyr 9980 > /dev/null 2>&1 &
PYR_PID=$!
sleep 1
bench "pyr" "http://127.0.0.1:9980/"
kill $PYR_PID 2>/dev/null; wait $PYR_PID 2>/dev/null

# python
python3 server.py 9981 > /dev/null 2>&1 &
PY_PID=$!
sleep 1
bench "python" "http://127.0.0.1:9981/"
kill $PY_PID 2>/dev/null; wait $PY_PID 2>/dev/null

# node
node server.js 9982 > /dev/null 2>&1 &
NODE_PID=$!
sleep 1
bench "node" "http://127.0.0.1:9982/"
kill $NODE_PID 2>/dev/null; wait $NODE_PID 2>/dev/null

# bun
bun server_bun.js 9983 > /dev/null 2>&1 &
BUN_PID=$!
sleep 1
bench "bun" "http://127.0.0.1:9983/"
kill $BUN_PID 2>/dev/null; wait $BUN_PID 2>/dev/null
