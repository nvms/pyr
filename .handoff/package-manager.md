# handoff: package manager / module resolution

## what was done

this session completed two roadmap items:

1. **error handling** - jump_if_nil opcode, ?? null coalescing (fixed: was using jump_if_false, broke `false ?? x`), ? suffix operator (early return on nil), && || short-circuit. all with examples, tests, benchmarks clean

2. **std/tls server-side** - runtime dlopen of OpenSSL/LibreSSL (no build dependency). tls.context(cert, key) creates ObjSslCtx, tls.upgrade(conn, ctx) does SSL_accept, returns ObjSslConn. VM dispatches read/write on ssl_conn tag. test_tls/run.sh validates with openssl s_client

## current state

- codebase clean, CI green on macOS + Ubuntu, benchmarks at baseline
- 204 tests, 28 validated examples, 10 benchmarks
- all roadmap items through #18 complete
- the module system currently handles: `imp std/io`, `imp math { add }`, `imp math as m`, file-relative resolution, circular import protection via cache, pub enforcement

## what to do next

### package manager - git-based, like Go

the user has expressed a preference for git-based packages like Go, no hosted registry, and dislikes TOML. see the memory file at `~/.claude/projects/-Users-jonathanpyers-code-vigil-hone-pyr/memory/project_package_manager.md` for their stated preferences.

read SPEC.md for the package format spec. key points from the spec:

```
[package]
name = "myapp"
version = "0.1.0"

[require]
github.com/user/repo v1.2.0
github.com/other/lib v0.5.0
```

lock file records resolved commit hashes for reproducibility.

### design decisions to make

1. **package file format** - the spec shows a simple ini-like format (NOT toml). the user dislikes toml. keep it minimal
2. **resolution strategy** - git clone + checkout tag. cache cloned repos locally
3. **import syntax for packages** - how does `imp github.com/user/repo/module` work? does the compiler resolve the package path to a local cache directory?
4. **version resolution** - semver tags. what happens with conflicts?
5. **lock file format** - what fields, what format
6. **CLI commands** - `pyr get`, `pyr install`, `pyr update`?
7. **where packages are cached** - `~/.pyr/cache/`? project-local?

### implementation areas

1. **package file parser** - parse the package manifest (pyr.pkg or similar)
2. **git operations** - clone, fetch, checkout tag. use `git` CLI via zig's std.process
3. **dependency resolver** - resolve version constraints, handle transitive deps
4. **module resolution update** - extend the existing module system to look up packages in the cache
5. **lock file** - generate and read lock files
6. **CLI commands** - add package management subcommands to the pyr CLI

### what already exists

- module system in compiler.zig handles `imp` statements
- file resolution is relative to entry file
- std modules are compiler-intrinsic (no files)
- the CLI entry point is in main.zig

## files to know

- `SPEC.md` - language spec, has the package format section
- `src/main.zig` - CLI entry point (pyr build, pyr run, etc)
- `src/compiler.zig` - module system, imp statement compilation
- `src/parser.zig` - import parsing
- `src/ast.zig` - Import node type
- `~/.claude/projects/-Users-jonathanpyers-code-vigil-hone-pyr/memory/project_package_manager.md` - user's stated preferences

## constraints

- **no TOML** - the user explicitly dislikes TOML
- **git-based** - like Go, no hosted registry
- **keep it simple** - pyr is a young language, don't over-engineer the package manager
- **backwards compatible** - existing `imp std/...` and file-relative imports must continue working
- **LLVM perturbation** - if any VM/compiler changes are needed, benchmark after

## verification

```
make build
make test
make examples
bench/run.sh
```
