# ziggurat — agent notes

A single-executable Zig 0.17.0 project linked against **librats 3.0.3** (C++
p2p library), vendored as a static archive **per target triple**. `src/main.zig`
parses the command line (`--help` / `--version` / passthrough args) and is the
only source file; `--help` prints the librats version read from the linked
library at runtime. The `run` branch is the placeholder for the real work.
Published targets: x86_64, aarch64, riscv64 (all linux-gnu).

## Setup, build, test

    bash scripts/fetch-librats.sh            # ONCE: vendors all three triples (~2.5 min)
    bash scripts/fetch-librats.sh aarch64-linux-gnu   # just one triple
    zig build                                # host binary -> zig-out/bin/ziggurat
    zig build dist                           # all three -> zig-out/<triple>/ziggurat
    zig build -Dtarget=aarch64-linux-gnu -Doptimize=ReleaseSafe
    zig build test                           # unit tests (links the real librats)
    zig build run -- --version               # args go after `--`
    zig fmt --check build.zig src            # formatting gate (no output = clean)

Requires Zig **0.17.0**, plus `cmake`, `make`, `curl`, `tar` for the vendor step
(no g++ and no cross toolchain: librats is compiled by `zig c++ -target`).
`zig build` fails loudly, naming the triple and the command to fix it, when that
target has not been vendored.

## Layout

    build.zig                    per-triple vendor lookup, translate-c, link flags, dist/run/test
    build.zig.zon                manifest: version, fingerprint, `.paths`
    src/main.zig                 Command union, parse(), usage, libratsVersion(), main(), tests
    src/c.h                      the only C include (`librats/bindings/rats.h`), translated to `c`
    scripts/fetch-librats.sh     3.0.3 pin, targets list, cmake flags, install into vendor/
    vendor/librats/<triple>/     GENERATED, gitignored, replaced wholesale on each fetch

## Conventions

- The vendor path is derived from the resolved target
  (`{arch}-{os}-{abi}`), never a hardcoded "native" dir — that is what lets one
  `build.zig` build all three targets.
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

- **`vendor/librats/` is generated, per-triple, and replaced wholesale** — never
  edit or commit it, and do not `!`-negate a path inside it (a negation cannot
  re-include into an ignored directory). Bumping the pin means editing
  `LIBRATS_VERSION` **and** `SHA256` in `scripts/fetch-librats.sh`, rerunning it,
  and updating `README.md`/this file.
- **librats from a source tarball reports `1.0.0.0` without
  `-DRATS_VERSION_OVERRIDE`** — its CMake falls back to that constant when
  `git describe` is unavailable. The fetch script passes the override, which is
  why the linked library prints `3.0.3.0`; drop it and the `librats: the library
  reports the version it was built from` test fails.
- **librats.a is compiled with `zig c++` against Zig's bundled libc++**, so the
  link calls `link_libcpp = true`. Do not rebuild it with a system GCC/g++: the
  resulting `__cxx11` libstdc++ objects cannot be linked into a cross-target
  binary, which is the whole reason for the Zig C++ driver.
- **Build librats with `-g0`** (`CMAKE_C_FLAGS`/`CMAKE_CXX_FLAGS` in the fetch
  script): `zig c++` emits debug info by default and the archive goes from ~6 MB
  to 66-80 MB, which lands in the binary.
- **No inline `@cImport` in Zig 0.17.** C headers are translated by
  `b.addTranslateC` from `src/c.h` and imported as `@import("c")`; add new C
  includes to `src/c.h`, never to Zig files.
- **`@import("build.zig.zon")` works only in `build.zig`**, not from `src/`
  (it resolves relative to the source file and fails with `FileNotFound`); code
  reads it through the generated `build_options` module.
- Default target is **`x86_64` baseline**, not native: a native build SIGILLs on
  older machines. Pass `-Dcpu=native` deliberately. `zig build dist` is
  ReleaseSafe + stripped (~2.3 MB per binary).
- The package `fingerprint` must never be edited (regenerating it makes a hostile
  fork). `zig build`/`zig build test` print nothing on success; use
  `--summary all` to prove the test step ran rather than hit cache.
- One root module only (no `src/root.zig`); tests are wired to `exe.root_module`,
  so a future library module needs its own `addTest` step or its tests stop
  running silently.
