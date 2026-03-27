# handoff: std/tls - client-side TLS

## what was done

this session implemented UDP support (sendto/recvfrom, ObjDgram value type, scheduler integration) and decomposed stdlib.zig into per-module files under src/stdlib/. the codebase is clean: 204 tests, 26 examples, 10 benchmarks, all passing. CI green.

## current state

- networking stack: TCP (listen/accept/connect/read/write/close), UDP (udp_bind/udp_open/sendto/recvfrom), non-blocking I/O with scheduler integration, IoError returns, configurable timeouts
- stdlib decomposed: src/stdlib/{io,fs,os,json,net,http}.zig with src/stdlib.zig as facade
- value types for networking: ObjListener, ObjConn, ObjDgram

## what to do next

### std/tls - client-side TLS via zig's std.crypto.tls

add TLS client support to pyr. this lets pyr programs make HTTPS requests, connect to TLS databases, etc. server-side TLS (which requires OpenSSL/system libs) is out of scope for this session - client-side is the high-value feature.

**zig 0.15 TLS capabilities:**

zig has a full TLS 1.3 + 1.2 client at `std.crypto.tls.Client`. no server support in std. key details:

- `Client.init(reader, writer, options)` performs the handshake synchronously
- reader/writer are `std.Io.Reader`/`std.Io.Writer` interfaces (not raw fds)
- requires read + write buffers of at least `std.crypto.tls.Client.min_buffer_len` (~16KB each)
- `std.net.Stream` wraps an fd into reader/writer via `.reader(buf)` / `.writer(buf)`
- after init, `client.reader` reads decrypted data, `client.writer` writes plaintext (TLS encrypts transparently)
- `client.end()` sends close_notify before fd close
- certificate verification via `std.crypto.Certificate.Bundle` with platform-native CA loading (`.rescan()`)

**API design:**

```pyr
imp std/tls as tls
imp std/net as net

conn = net.connect("example.com", 443)
secure = tls.upgrade(conn, "example.com")
secure.write("GET / HTTP/1.1\r\nHost: example.com\r\n\r\n")
response = secure.read()
net.close(secure)
```

- `tls.upgrade(conn, hostname)` - upgrade an ObjConn to TLS. hostname is for SNI and certificate verification. returns ObjTlsConn
- `tls.upgrade(conn)` - upgrade without hostname verification (for testing/internal services)
- read/write/close work transparently via the same `.read()`, `.write()` method-call syntax and net_read/net_write opcodes. the VM dispatches based on value tag

**new value type: ObjTlsConn**

add to src/value.zig. this is more complex than ObjConn because it holds TLS state + buffers:

```
ObjTlsConn {
    fd: std.posix.fd_t,
    client: std.crypto.tls.Client,
    read_buf: []u8,      // >= min_buffer_len, heap allocated
    write_buf: []u8,     // >= min_buffer_len, heap allocated
    stream_read_buf: []u8,  // for the std.net.Stream reader
    stream_write_buf: []u8, // for the std.net.Stream writer
}
```

add `.tls_conn` to the Value tag enum, with initTlsConn/asTlsConn methods.

**critical:** the zig TLS Client stores internal pointers to the Reader/Writer interfaces. the ObjTlsConn struct and its buffers must have stable addresses (heap allocated, not moved). read the zig source at `/opt/homebrew/Cellar/zig/0.15.1/lib/zig/std/crypto/tls/Client.zig` carefully before implementing - the init sequence and Reader/Writer interface wiring is nuanced. also look at how `std.http.Client` uses it (search for `tls.Client.init` in the zig stdlib) for the canonical usage pattern.

**implementation steps:**

1. **value.zig** - add ObjTlsConn struct, `.tls_conn` tag, init/as methods. update isTruthy, eql, dump for the new tag

2. **src/stdlib/tls.zig** - new module file:
   - `tls_fns` array with: `upgrade` (1 or 2 args)
   - `tlsUpgrade(alloc, args)`: takes ObjConn + optional hostname string
     - create std.net.Stream from conn.fd
     - allocate read/write/stream buffers (~16KB each)
     - load system CA bundle via `std.crypto.Certificate.Bundle.rescan()` (or use `.no_verification` when no hostname)
     - call `std.crypto.tls.Client.init()` with the stream's reader/writer
     - wrap everything in ObjTlsConn, return it
     - on failure, return IoError
   - the CA bundle should be loaded once and cached (it's expensive to rescan per connection). consider a module-level `var ca_bundle` or pass it through the alloc context

3. **src/stdlib.zig** - import tls module, add to modules array, re-export if needed

4. **src/vm.zig** - extend existing opcode handlers:
   - `execNetRead`: add `.tls_conn` branch. call `obj.client.reader.readAll()` or similar instead of `std.posix.read()`. return the decrypted bytes as ObjString. handle TLS-specific errors (TlsAlert, etc.) as IoError
   - `execNetWrite`: add `.tls_conn` branch. call `obj.client.writer.writeAll()` then `flush()`. handle errors as IoError
   - `execNetAccept`/`execNetConnect`: no changes needed (TLS upgrade is separate)
   - the Scheduler's pollAndWake `.read`/`.write` resume paths also need `.tls_conn` handling if we support async TLS reads later. for v1, TLS connections should not enter the scheduler's async path - they block on the calling thread

5. **extend net.close** for `.tls_conn`: call `client.end()` (close_notify) then `std.posix.close(fd)`. add to both stdlib/net.zig's netClose and vm.zig's close handling

6. **extend net.timeout** for `.tls_conn` in stdlib/net.zig

**scheduler integration (v1: blocking only):**

the TLS handshake (`Client.init`) is synchronous - it makes multiple round-trip reads/writes during the handshake and cannot be paused/resumed. for v1, `tls.upgrade()` blocks the calling thread. this means:

- in the main thread: works fine, just blocks briefly during handshake
- in a spawned task: the entire scheduler blocks during handshake. this is acceptable for v1 - document it as a known limitation
- TLS read/write after handshake could theoretically be non-blocking, but the zig TLS Reader/Writer don't support WouldBlock returns. defer async TLS to a future session

**do not add the `.tls_conn` tag to the Scheduler's IoOp handling.** if a TLS read would block, just let it block. async TLS is a separate feature.

**compiler.zig:** no changes needed. method-call syntax (`.read()`, `.write()`) already emits net_read/net_write opcodes based on field name, not receiver type. the VM handles type dispatch at runtime

**testing:**

- VM test: upgrade a connection and do a TLS handshake against a real server (e.g. example.com:443) - send a minimal HTTP/1.1 request, verify we get a response back. this requires network access during tests
- VM test: upgrade with bad hostname, verify IoError
- VM test: read/write through TLS connection
- if network-dependent tests are problematic, create a localhost test using openssl s_server or similar. but a real-server test is more valuable for verifying CA bundle loading
- example: examples/tls.pyr - connect to a public HTTPS server, send GET request, print response status line
- the example may not have a .expected file since the response varies. validate by exit code only

**example (examples/tls.pyr):**

```pyr
imp std/net as net
imp std/tls as tls

fn main() {
  conn = net.connect("example.com", 443)
  secure = tls.upgrade(conn, "example.com")

  secure.write("GET / HTTP/1.1\r\nHost: example.com\r\nConnection: close\r\n\r\n")

  mut response = ""
  mut reading = true
  while reading {
    chunk = secure.read()
    if chunk == Eof {
      reading = false
    } else {
      response = response + chunk
    }
  }

  assert(len(response) > 0)
  println("received " + str(len(response)) + " bytes")
  println("ok")

  net.close(secure)
}
```

## files to know

- `src/value.zig` - ObjConn/ObjDgram as patterns for ObjTlsConn. Value tag enum
- `src/stdlib.zig` - facade with module registry, IO error helpers, re-exports
- `src/stdlib/net.zig` - netClose, netTimeout as patterns to extend for tls_conn
- `src/vm.zig` - execNetRead, execNetWrite for adding .tls_conn dispatch. Scheduler (avoid adding TLS to async paths for v1)
- `src/compiler.zig` - should NOT need changes. method-call syntax is field-name based
- `/opt/homebrew/Cellar/zig/0.15.1/lib/zig/std/crypto/tls/Client.zig` - read this to understand the init sequence, Reader/Writer interface requirements, buffer sizing, and error types
- `/opt/homebrew/Cellar/zig/0.15.1/lib/zig/std/net.zig` - Stream struct, how reader/writer wrap an fd
- `/opt/homebrew/Cellar/zig/0.15.1/lib/zig/std/http/Client.zig` - canonical example of how zig uses TLS. search for `tls.Client.init`

## constraints

- **LLVM perturbation:** adding `.tls_conn` to the Value tag enum can cause benchmark regressions. add it at the end (after `.dgram`, before `.ptr`). benchmark after
- **buffer lifetime:** the TLS Client holds internal pointers to Reader/Writer state. ObjTlsConn and all its buffers must be heap-allocated and never moved. do not put large buffers on the zig stack
- **zig 0.15 API:** the std.Io.Reader/Writer API in zig 0.15 may differ from older versions. read the actual source, don't assume C-like interfaces. the VTable pattern is zig-specific
- **CA bundle caching:** `Certificate.Bundle.rescan()` reads from disk. cache the bundle across connections. a module-level var or lazy init is fine
- **close ordering:** always call `client.end()` before `std.posix.close(fd)` for clean TLS shutdown. handle errors from end() gracefully (peer may have already closed)
- **the handshake blocks:** in spawned tasks, the entire scheduler stalls during tls.upgrade(). this is a known v1 limitation. do not try to make it async - that's a separate, complex feature

## verification

```
make build
make test
make examples
bash bench/run.sh
```

manually test TLS example against a real HTTPS server. verify the CA bundle loads correctly on the development platform (macOS).
