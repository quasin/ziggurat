# ziggurat — agent notes

A single-executable Zig 0.17.0 project linked against **librats 3.0.3** (C++
p2p library), vendored as a static archive built from source. `src/main.zig`
parses the command line (`--help` / `--version` / passthrough args) and is the
only source file; `--help` prints the librats version read from the linked
library at runtime. The `run` branch is the placeholder for the real work.

## Setup, build, test

    bash scripts/fetch-librats.sh   # ONCE after a clone: builds vendor/librats/{include,librats.a}
    zig build                       # -> zig-out/bin/ziggurat
    zig build test                  # unit tests (links the real librats)
    zig build run -- --version      # args go after `--`
    ./zig-out/bin/ziggurat --help   # installed binary, no rebuild
    zig fmt --check build.zig src   # formatting gate (no output = clean)
    zig build -Dcpu=native          # host-optimised (default is x86_64 baseline)
    zig build -Dlibstdcpp=/path -Dlibgcc_s=/path   # non-/usr/lib C++ runtime

Requires Zig **0.17.0**, plus `cmake`, `g++`, `make`, `curl`, `tar` for the
vendor step. `zig build` fails loudly if librats is missing.

## Layout

    build.zig                    librats guard + translate-c, link flags, run/test steps
    build.zig.zon                manifest: version, fingerprint, `.paths`
    src/main.zig                 Command union, parse(), usage, libratsVersion(), main(), tests
    src/c.h                      the only C include (`librats/bindings/rats.h`), translated to `c`
    scripts/fetch-librats.sh     3.0.3 pin: URL, sha256, cmake flags, install into vendor/
    vendor/librats/              GENERATED, gitignored, replaced wholesale on each fetch

## Conventions

- Zig 0.17 I/O: `pub fn main(init: std.process.Init) !void`, arena from
  `init.arena.allocator()`, args from `init.minimal.args.toSlice(arena)`, output
  through `Io.File.Writer` with an explicit buffer — always `try out.flush()`.
- Parsing lives in `parse()`, which returns a `Command`; `main` only dispatches.
  New flags go there with a `usage` line in the same edit (flags are recognised
  in the first position only — a test asserts it).
- Version reporting goes through `libratsVersion()` (calls `c.rats_version` /
  `c.rats_version_string`); never hard-code librats' version in Zig.
- Comments explain *why* a choice was made, not what the line does; match the
  density in `build.zig` and `scripts/fetch-librats.sh`.
- Tests are `test "..."` blocks beside the code, `std.testing.allocator` for leaks.
- `build.zig.zon` `.paths` lists tracked paths only; commit subjects are
  `area: lowercase imperative summary`; LF everywhere (`.gitattributes`).

## Pitfalls

- **`vendor/librats/` is generated and replaced wholesale** — do not edit or
  commit it, and do not `!`-negate a path inside it (a negation cannot re-include
  into an ignored directory). Changing the pin means editing `LIBRATS_VERSION`
  **and** `SHA256` in `scripts/fetch-librats.sh`, then rerunning it; the comment
  in `build.zig` names the version too.
- **librats from a source tarball reports `1.0.0.0` without
  `-DRATS_VERSION_OVERRIDE`** — its CMake falls back to that constant when
  `git describe` is unavailable. The fetch script passes the override, which is
  why the linked library prints `3.0.3.0`; drop that flag and the version (and
  the `librats: the library reports the version it was built from` test) go wrong.
- **`librats.a` is GCC-built C++ (`__cxx11` ABI).** It links the system
  `/usr/lib/libstdc++.so` and `/usr/lib/libgcc_s.so.1` via `addObjectFile`, not
  Zig's bundled libc++ and not `linkSystemLibrary("stdc++")`.
- **No inline `@cImport` in Zig 0.17.** C headers are translated by
  `b.addTranslateC` from `src/c.h` and imported as `@import("c")`; add new C
  includes to `src/c.h`, never to Zig files.
- **`@import("build.zig.zon")` works only in `build.zig`**, not from `src/`
  (it resolves relative to the source file and fails with `FileNotFound`); code
  reads it through the generated `build_options` module.
- Default target is **`x86_64` baseline**, not native: a native build SIGILLs on
  older machines. Pass `-Dcpu=native` deliberately.
- The package `fingerprint` must never be edited (regenerating it makes a hostile
  fork). `zig build`/`zig build test` print nothing on success; use
  `--summary all` to prove the test step ran rather than hit cache.
- One root module only (no `src/root.zig`); tests are wired to `exe.root_module`,
  so a future library module needs its own `addTest` step or its tests stop
  running silently.
