#!/bin/bash
set -e

cd "$(dirname "$0")/.."

if ! command -v openssl &>/dev/null; then
  echo "skip: openssl not found"
  exit 0
fi

if [ ! -f test_tls/cert.pem ]; then
  openssl req -x509 -newkey rsa:2048 -keyout test_tls/key.pem -out test_tls/cert.pem \
    -days 365 -nodes -subj "/CN=localhost" 2>/dev/null
fi

./zig-out/bin/pyr run examples/tls_server.pyr &
SERVER_PID=$!
sleep 0.5

RESPONSE=$(printf "hello tls" | openssl s_client -connect 127.0.0.1:19543 -quiet 2>/dev/null || true)

wait $SERVER_PID 2>/dev/null || true

if echo "$RESPONSE" | grep -q "echo: hello tls"; then
  echo "ok   tls_server"
else
  echo "FAIL tls_server"
  echo "response: '$RESPONSE'"
  exit 1
fi
