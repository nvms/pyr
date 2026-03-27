<p align="center">
  <img src=".github/logo.svg" width="120" height="120" style="border-radius: 16px" />
</p>

<h1 align="center">pyr</h1>

<p align="center">A systems programming language with scripting ergonomics, built in Zig.</p>

<p align="center">
  <a href="https://github.com/nvms/pyr/actions/workflows/ci.yml">
    <img src="https://github.com/nvms/pyr/actions/workflows/ci.yml/badge.svg" alt="ci" />
  </a>
</p>

---

Pyr is a compiled language that targets native code via Zig. It combines the performance of systems languages with the expressiveness of scripting languages. No garbage collector, no runtime overhead - arena-scoped memory, lightweight concurrency, and a type system that stays out of your way until you need it.

High-level code reads like Python. Low-level code reads like Zig. Same language, different depths.

## Features

- **No GC** - Arena-scoped memory management. Per-request arenas for servers, explicit allocators for systems work
- **Native performance** - Compiles to native code via Zig. SIMD, io_uring, zero-cost C FFI
- **Lightweight concurrency** - Green threads on a work-stealing thread pool. Typed channels for communication
- **Structural typing** - If it fits, it works. No interface declarations required
- **UFCS** - Any function can be called with dot syntax on its first argument. No methods, no impl blocks
- **Pattern matching** - Algebraic enums with exhaustive matching
- **Pipeline operator** - Left-to-right data flow with `|>`
- **Helpful compiler errors** - Source locations, span highlighting, fix suggestions

## Example

```
import std/http { serve, get, post }
import std/pg

fn main() {
  db = pg.connect(env("DATABASE_URL"))

  serve ":8080" {
    get "/users/:id" |req| {
      user = db.find(User, req.params.id) ?? not_found()
      json(user)
    }

    post "/users" |req| {
      input = req.json(CreateUser) ?? bad_request("invalid body")
      user = db.insert(User, input)
      json(user, status: 201)
    }
  }
}
```

```
// CLI tool
fn main(args: []str) {
  config = parse_args(args) ?? {
    eprintln("usage: compress <input> <output>")
    exit(1)
  }

  data = fs.read_bytes(config.input) ?? die("can't read {config.input}")
  compressed = zlib.compress(data, level: 6)
  fs.write(config.output, compressed)
  println("compressed {data.len} -> {compressed.len} bytes")
}
```

```
// data processing
fn main() {
  fs.read_lines("access.log")
    |> filter(fn(line) line.contains("ERROR"))
    |> map(parse_log_entry)
    |> group_by(fn(e) e.endpoint)
    |> sort_by(fn(k, v) v.len, descending)
    |> take(10)
    |> each(fn(endpoint, errors) {
      println("{endpoint}: {errors.len} errors")
    })
}
```

## Building from source

Requires Zig 0.15.x.

```sh
git clone https://github.com/nvms/pyr
cd pyr
make build
```

## Package management

Pyr uses git-based packages with no hosted registry, similar to Go modules.

```sh
pyr init myapp             # create pyr.pkg manifest
pyr add github.com/user/lib v1.0.0   # add a dependency
pyr install                # fetch all dependencies
```

Packages are imported by name:

```
imp router { serve, get, post }
imp json
imp logger as log
```

The manifest format is minimal and purpose-built:

```
name myapp
version 0.1.0

require (
  github.com/user/router v0.3.1
  github.com/user/json v1.0.0
)
```

Dependencies are cloned and cached locally in `~/.pyr/cache/`. A `pyr.lock` file records resolved commit hashes for reproducible builds.

## Status

Early development. This project is an experiment in AI-maintained open source - autonomously built, tested, and refined by AI with human oversight. Regular audits, thorough test coverage, continuous refinement. The emphasis is on high quality, rigorously tested, production-grade code.

## License

MIT
