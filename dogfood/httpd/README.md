# httpd

static file HTTP server with spawn-per-connection concurrency.

## usage

```
pyr run main.pyr [directory] [port]
```

defaults to current directory on port 8080.

```
pyr run main.pyr www 3000
```

## benchmark

```
bash bench.sh
```

runs `wrk` (10s, 4 threads, 50 connections) against pyr, python, node, and bun serving a small text file.

| server | req/sec | vs pyr |
|--------|---------|--------|
| bun    | ~47,000 | 1.4x   |
| pyr    | ~34,000 | -      |
| node   | ~7,800  | 0.23x  |
| python | ~5,000  | 0.15x  |
