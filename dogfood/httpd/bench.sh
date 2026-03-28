#!/bin/bash
set +e

DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$DIR"

DURATION=10
THREADS=4
CONNECTIONS=50
FILE="/test.txt"

echo "httpd benchmark"
echo "  duration: ${DURATION}s, threads: $THREADS, connections: $CONNECTIONS"
echo "  file: $FILE"
echo ""

# pyr
pyr run main.pyr www 9990 > /dev/null 2>&1 &
PYR_PID=$!
sleep 1
echo "pyr:"
wrk -t$THREADS -c$CONNECTIONS -d${DURATION}s http://127.0.0.1:9990$FILE 2>&1 | grep -E "Requests/sec|Latency"
kill $PYR_PID 2>/dev/null; wait $PYR_PID 2>/dev/null
echo ""

# python
python3 bench_python.py 9991 www > /dev/null 2>&1 &
PY_PID=$!
sleep 1
echo "python:"
wrk -t$THREADS -c$CONNECTIONS -d${DURATION}s http://127.0.0.1:9991$FILE 2>&1 | grep -E "Requests/sec|Latency"
kill $PY_PID 2>/dev/null; wait $PY_PID 2>/dev/null
echo ""

# node
node bench_node.js 9992 www > /dev/null 2>&1 &
NODE_PID=$!
sleep 1
echo "node:"
wrk -t$THREADS -c$CONNECTIONS -d${DURATION}s http://127.0.0.1:9992$FILE 2>&1 | grep -E "Requests/sec|Latency"
kill $NODE_PID 2>/dev/null; wait $NODE_PID 2>/dev/null
echo ""

# bun
bun bench_bun.js 9993 www > /dev/null 2>&1 &
BUN_PID=$!
sleep 1
echo "bun:"
wrk -t$THREADS -c$CONNECTIONS -d${DURATION}s http://127.0.0.1:9993$FILE 2>&1 | grep -E "Requests/sec|Latency"
kill $BUN_PID 2>/dev/null; wait $BUN_PID 2>/dev/null
