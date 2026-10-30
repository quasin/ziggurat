# ziggurat — agent notes

A single-executable Zig 0.17.0 project linked against **librats 3.0.3** (C++ p2p
library), vendored as a static archive **per target triple**. The program is a
two-panel TUI: a magnet line on the left, the history of what was typed on the
right; a row mounts a release as a read-only directory (a FUSE 3 mount served by
a `rekarma` daemon) and hands one of its files to `vlc`, whose reads pull the
pieces on demand. `--help` prints the librats version read from the linked
library at runtime. Published targets: x86_64, aarch64, riscv64 (all linux-gnu).

Ziggurat itself does not download anything: librats is linked for the version
report (and is what rekarma mounts through). The torrent, the mount and the
piece scheduling live behind `--rekarma <binary>`, started once per release as
`rekarma --magnet <link> -m <dir> --cache <dir> --daemon`.

## Setup, build, test

    bash scripts/fetch-librats.sh            # ONCE: vendors all three triples (~2.5 min)
    bash scripts/fetch-librats.sh aarch64-linux-gnu   # just one triple
    zig build                                # host binary -> zig-out/bin/ziggurat
    zig build dist                           # all three -> zig-out/<triple>/ziggurat
    zig build -Dtarget=aarch64-linux-gnu -Doptimize=ReleaseSafe
    zig build test                           # unit tests (links the real librats)
    zig build run                            # the interface (needs a terminal)
    zig fmt --check build.zig src            # formatting gate (no output = clean)

Requires Zig **0.17.0**, plus `cmake`, `make`, `curl`, `tar` for the vendor step
(no g++ and no cross toolchain: librats is compiled by `zig c++ -target`).
`zig build` fails loudly, naming the triple and the command to fix it, when that
target has not been vendored. Running the interface needs `rekarma` (itself built
with libfuse3) and `vlc` on `PATH`, or `--rekarma` / `--vlc` pointing at them.

## Layout

    build.zig                    per-triple vendor lookup, translate-c, link flags, dist/run/test
    build.zig.zon                manifest: version, fingerprint, `.paths`
    src/main.zig                 Command union, parse(), usage, libratsVersion(), main(), tests
    src/tui.zig                  App state, the two panels, the event loop, mount/play actions
    src/term.zig                 raw mode, key decoding, frame buffer (clipped, styled text)
    src/procs.zig                spawning rekarma and the player, mount probing, file scan, log tail
    src/history.zig              the history rows and their tab-separated file
    src/magnet.zig               magnet normalization, info-hash, media filter
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
  Long-lived state (the history, the file list) uses `init.gpa`, never the arena:
  the process outlives the screen by a long time.
- External programs are resolved once in `main` (`procs.resolveExecutable`, PATH
  from `init.environ_map`) and passed to the app as `rekarma_exe` / `player_exe`.
  A missing program is a warning on the status line and a refused action with the
  fix in it, never a bare `FileNotFound` from a spawn the user cannot see.
- Parsing lives in `parse()`, which returns a `Command`; `main` only dispatches.
  New options go there with a `usage` line in the same edit. Options are read
  anywhere on the command line (`--name value` and `--name=value` both work) and
  an unknown or incomplete one is a `problem`, not a silent default.
- Screen code never allocates per frame: everything it prints is a fixed buffer,
  a slice of existing state, or a `bufPrint`. The one per-frame allocation is the
  `term.Frame` buffer itself, freed before the frame is over.
- Version reporting goes through `libratsVersion()` (calls `c.rats_version` /
  `c.rats_version_string`); never hard-code librats' version in Zig.
- Comments explain *why* a choice was made, not what the line does; match the
  density in `build.zig` and `scripts/fetch-librats.sh`. UI strings are Russian,
  code and comments English.
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
- **A container allocated by one allocator must be freed by the same one.** The
  media list's buffer belongs to `init.gpa` (it survives a frame), while the
  paths inside it belong to a per-open arena — `listMedia` therefore takes two
  allocators. Passing one allocator for both panics on exit with
  `free after resize of [addr …]`, after the UI has already worked.
- **Rows are cleared before they are drawn.** The screen is patched in place, so
  a row that shrinks between frames (a mount that finished, a file list that
  reloads) keeps the previous text underneath unless every interior row is
  erased with `\x1b[K` first. Borders are drawn *after* the interiors for the same
  reason: an erase-to-end-of-line at the panel edge would otherwise cut them.
- **`std.posix.tcgetattr`/`tcsetattr` in a libc-linked binary corrupt the stack.**
  With `link_libc = true` they call glibc's functions, which write glibc's
  `struct termios` (60 bytes, `NCCS` 32) into Zig's `linux.termios` (44 bytes,
  `NCCS` 19). The overflow is silent in Debug and fatal in ReleaseSafe, where the
  stack protector catches it: `Illegal instruction at address …` / `Cannot print
  stack trace` at startup, pointing at a line that merely returns an error. Use
  the syscall instead — `std.os.linux.tcgetattr(fd, &term)` /
  `tcsetattr(fd, .NOW, &term)` classified with `linux.errno()` — and keep
  `termios` as `linux.termios`. Verify the artifacts the user runs, not just the
  Debug build: `zig build dist` output is what breaks.
- **A full-screen TUI needs `isatty` and `TIOCGWINSZ`, and std has neither.** Probe
  a tty with the syscall-based `tcgetattr` above, and size the window with
  `linux.ioctl(fd, 0x5413, @intFromPtr(&ws))` into a `std.posix.winsize`.
- **`rekarma` is not on PATH by default.** It is a separate project
  (`zig-out/bin/rekarma`), so a fresh session shows "rekarma не найден" until it
  is installed or passed as `--rekarma <path>`; the mount then runs from whatever
  directory ziggurat was started in, creating `mnt/` and `.ziggurat/` there.
- **A mount appears later than the daemon that started it.** `rekarma --daemon`
  forks, prints its pid and exits, so the spawn says nothing about the mount:
  the row counts as mounted only when a readdir of `<mount-root>/<hash>` returns
  an entry, polled once a tick. Probing root-level readdir is metadata-only and
  does not touch the swarm.
- **A daemon per release needs its own cache dir**, `<cache>/<hash>`: rekarma
  writes `magnet.pid`/`magnet.log` into `--cache`, so two releases sharing one
  directory would overwrite each other's pid and stop the wrong mount.
- **Ctrl-C must reach the program as a keypress** (`ISIG` off in raw mode), or
  the terminal is left in raw mode and the alternate screen after a signal.
  Every exit path restores both, and the mounts deliberately survive the exit —
  the last thing printed is which of them still run and how to stop them.
- **A palette of escape codes per character is fine; an allocation per frame is
  not.** `frame.put()` writes style + text + reset each time, which keeps the
  buffer simple, but any `allocPrint` in a draw function leaks once per tick.
