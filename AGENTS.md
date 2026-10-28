# ziggurat — agent notes

A single-executable Zig 0.17.0 project. `src/main.zig` parses the command line
(`--help` / `--version` / passthrough args) and is the only source file; the
`run` branch is the placeholder where the real work goes. No dependencies, no
generated code beyond the Zig cache.

## Commands

    zig build                      # compile -> zig-out/bin/ziggurat
    zig build test                 # run every `test` block (cached; --summary all shows steps)
    zig build run -- --version     # build + run; args go after `--`
    zig build -Dcpu=native         # machine-local build (default is x86_64 baseline)
    zig build -Doptimize=ReleaseFast
    zig fmt --check build.zig src  # formatting gate; `zig fmt build.zig src` fixes
    ./zig-out/bin/ziggurat --help  # run the installed binary directly

Requires Zig **0.17.0** (`build.zig.zon` `.minimum_zig_version`).

## Layout

    build.zig        target/optimize options, `build_options` (version), run + test steps
    build.zig.zon    package manifest: version, fingerprint, `.paths`
    src/main.zig     Command union, parse(), usage text, main(), tests

## Conventions

- Zig 0.17 I/O: `pub fn main(init: std.process.Init) !void`, allocator from
  `init.arena.allocator()`, args from `init.minimal.args.toSlice(arena)`, output
  through `Io.File.Writer` with an explicit buffer — **always `try out.flush()`**
  before returning or the output is lost.
- `main` dispatches on `parse()`; parsing is kept in a pure function returning
  `Command` so it is testable without a process. Add new flags there, not inline
  in `main`, and extend `usage` in the same edit.
- Flags are recognised only in the first position; anything after it is a plain
  argument (there is a test asserting this). Don't switch to a flag-scanning
  parser without rewriting that test and `usage`.
- Tests are `test "..."` blocks in the same file as the code (`src/main.zig`),
  using `std.testing.expect*`; `std.testing.allocator` catches leaks.
- Comments explain *why* a choice was made, not what the line does — every
  non-obvious line in `build.zig`/`main.zig` carries such a note. Match that.
- `build.zig.zon` `.paths` lists tracked paths only (`zig-out`, `.zig-cache` are
  gitignored and must never be listed).
- LF everywhere (`.gitattributes`: `text=auto eol=lf`); files are `zig fmt`
  clean. Commit subjects are `area: lowercase imperative summary`.

## Pitfalls

- **`@import("build.zig.zon")` does not work from `src/`** — it resolves relative
  to the source file and fails with `FileNotFound`. The version reaches code via
  the generated `build_options` module (`opts.addOption` in `build.zig`,
  `@import("build_options")` in source). Any new manifest value follows that path.
- The default target is **`x86_64` baseline, not native**: a native build can
  SIGILL elsewhere. Pass `-Dcpu=native` if you actually want host instructions.
- The package `fingerprint` in `build.zig.zon` must never be edited; regenerating
  it makes this a hostile fork of the original package identity.
- `zig build` and `zig build test` print nothing on success — an empty run is a
  pass, not a silent skip. Use `--summary all` when you need proof the test step
  executed rather than hit cache.
- There is no separate library module or `src/root.zig`: everything compiles as
  the one executable's root module, so tests are wired to `exe.root_module`.
  Splitting out a library means adding its own `addTest` step or its tests
  silently stop running.
