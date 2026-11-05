# ziggurat — agent notes

A single-executable Zig 0.17.0 project with no C dependencies. The program is a
two-panel TUI: a source line on the left (magnet link, bare info-hash or a
`.torrent` file), the history of what was typed on the
right; a row mounts a release as a read-only directory (a FUSE 3 mount served by
a `rekarma` daemon) and lists every folder and file inside it. Enter hands a
file to the desktop's default application through `--open` (xdg-open), and that
program's reads are what pull the pieces on demand. Published targets: x86_64, aarch64, riscv64 (all linux-gnu).

Ziggurat itself does not download anything and does not link librats. The
torrent, the mount and the piece scheduling live behind `--rekarma <binary>`,
started once per release as
`rekarma --magnet <link>|--torrent <file> -m <dir> --cache <dir> --daemon`.
`--help`/`--version` print rekarma's and librats' versions by running
`rekarma --version` at startup, so the answer describes the engine the mounts
will actually run.

## Setup, build, test

    zig build                                # host binary -> zig-out/bin/ziggurat
    zig build dist                           # all three -> zig-out/<triple>/ziggurat
    zig build -Dtarget=aarch64-linux-gnu -Doptimize=ReleaseSafe
    zig build test                           # unit tests
    zig build run                            # the interface (needs a terminal)
    zig fmt --check build.zig src            # formatting gate (no output = clean)

Requires Zig **0.17.0** only: there is no vendor step and no cross toolchain.
Running the interface needs `rekarma` (itself built with libfuse3) and
`xdg-open` on `PATH`, or `--rekarma` / `--open` pointing at them.

## Layout

    build.zig                    pure-Zig exe, options module, dist/run/test
    build.zig.zon                manifest: version, fingerprint, `.paths`
    src/main.zig                 Command union, parse(), usage, version lookup, main(), tests
    src/tui.zig                  App state, the two panels, the event loop, mount/play/install actions
    src/term.zig                 raw mode, key decoding, frame buffer (clipped, styled text)
    src/procs.zig                spawning rekarma/player, mount probing, file scan, log tail,
                                 rekarma version lookup, background installers (ant-client,
                                 qBittorrent-nox, the RuTracker database)
    src/rutracker.zig            the RuTracker dump: streaming search, record parsing, the
                                 worker thread behind the viewer
    src/history.zig              the history rows and their tab-separated file
    src/magnet.zig               source normalization (magnet/.torrent), ids, media filter

## Conventions

- The program is pure Zig: it links neither libc nor librats. If a C header is
  ever needed, Zig 0.17 has no inline `@cImport`; translate it in `build.zig`
  with `b.addTranslateC` and import the generated module by name.
- Zig 0.17 I/O: `pub fn main(init: std.process.Init) !void`, arena from
  `init.arena.allocator()`, args from `init.minimal.args.toSlice(arena)`, output
  through `Io.File.Writer` with an explicit buffer — always `try out.flush()`.
  Long-lived state (the history, the file list) uses `init.gpa`, never the arena:
  the process outlives the screen by a long time.
- External programs are resolved once in `main` (`procs.resolveExecutable`, PATH
  from `init.environ_map`) and passed to the app as `rekarma_exe` /
  `player_exe` / `opener_exe`.
  A missing program is a warning on the status line and a refused action with the
  fix in it, never a bare `FileNotFound` from a spawn the user cannot see.
- Parsing lives in `parse()`, which returns a `Command`; `main` only dispatches.
  New options go there with a `usage` line in the same edit. Options are read
  anywhere on the command line (`--name value` and `--name=value` both work) and
  an unknown or incomplete one is a `problem`, not a silent default.
- Screen code never allocates per frame: everything it prints is a fixed buffer,
  a slice of existing state, or a `bufPrint`. The one per-frame allocation is the
  `term.Frame` buffer itself, freed before the frame is over.
- Version reporting goes through `procs.toolVersions` (which runs
  `rekarma --version`); never hard-code librats' version in Zig and never link it
  into ziggurat just to ask.
- Comments explain *why* a choice was made, not what the line does; match the
  density in `build.zig`. UI strings are Russian, code and comments English.
- Tests are `test "..."` blocks beside the code, `std.testing.allocator` for leaks.
- `build.zig.zon` `.paths` lists tracked paths only; commit subjects are
  `area: lowercase imperative summary`; LF everywhere (`.gitattributes`).

## Pitfalls

- **The room view tails `all.txt` in the startup directory, not a file of its
  own.** Plain `rekarma` records the room `rekarma` into `all.txt` (pid
  `all.txt.pid`, log `all.txt.log`) beside where it runs, and ziggurat only reads
  that file — putting the history in a ziggurat-owned path would show an empty
  panel next to a recorder writing elsewhere. The link starts `rekarma --daemon`
  itself when `all.txt.pid` names no live process, and the file is re-read only
  when its size or mtime changes: one stat per tick, never a read per frame.
- **Two rekarma nodes on one host do not meet over discovery, so a sent message
  needs the recorder's port.** A one-shot `rekarma <text>` that waits for mDNS or
  the DHT never finds the recorder beside it (the log fills with
  `no route to …`/`Network is unreachable`), so the panel's Enter dials
  `-c 127.0.0.1:<port>` instead. That port is only printed in the daemon's banner
  (`node <id> on port <n>`) a moment *after* it forks, which is why the send is
  parked in a fixed buffer and spawned from the tick once the port is readable —
  a send with no port silently costs the engine's 90 s peer wait. Parse the log's
  **last** banner: it is appended across runs and the previous run's port is
  stale.
- **A module whose `test` blocks matter must be named from a `test` block.** A
  file reached only through `main()` is not analyzed in a test build, and its
  tests drop out of the artifact silently (`tui.zig`, `term.zig` did until
  `main.zig` gained a `test { _ = tui; _ = term; }`); `zig build test --summary
  all` showing fewer tests than `grep -c '^test ' src/*.zig` is that bug. Being
  imported by an already-named file is **not** enough: only the decls the tests
  actually reach are analyzed, so `rutracker.zig` and `history.zig` stayed out
  (seven tests) even though `tui.zig` imports both — name every file in that
  `test` block. Skipped tests also hide failing ones: `rutracker`'s suite had
  one broken test (a raw uppercase query fed to `matches`, which expects the
  folded form `start` produces) that only appeared once the file was wired in.
  The sum of `grep -c '^test '` is the number the run must report.
- **Do not add a librats dependency back to ziggurat.** The library belongs to
  rekarma, the binary that mounts and downloads; ziggurat only spawns it and asks
  for `--version`. Linking it again reintroduces the per-triple C++ vendoring,
  the `link_libcpp` requirement and the system-libstdc++ trap.
- **`@import("build.zig.zon")` works only in `build.zig`**, not from `src/`
  (it resolves relative to the source file and fails with `FileNotFound`); code
  reads it through the generated `build_options` module.
- **A 30 GB dump is searched by streaming, never by loading.** `rutracker-*.xml`
  is ~31 GB and 5.7 million `<torrent>` records; the viewer's scan runs in a
  worker thread (`rutracker.Engine`) that reads 1 MB chunks, splits complete
  records and appends matches under a spinlock. The screen only reads atomics
  for progress and `tryLock`s the list, so a scan never stalls a frame. Cancel
  is checked per chunk, which is why leaving the view (`db.stop()`) returns in
  milliseconds. Do not "optimise" this into a full read: a per-query allocation
  of tens of gigabytes is the failure mode the design exists to avoid. A Debug
  build scans at ~280 MB/s and a ReleaseSafe one at ~1.1 GB/s (disk-bound), so
  the dump view is what `zig build dist` is for.
- **The scan's record boundary is found with a single-byte scan for `<`.**
  `std.mem.indexOf` with a multi-byte needle is byte-at-a-time Boyer-Moore in a
  Debug build; `indexOfScalarPos('<')` plus a `startsWith` is several times
  faster there and identical in ReleaseSafe. `recordEnd` is that path; keep it.
- The dump's structure is one `<torrent id=… size=…>` per release with
  `<title>`, `<torrent hash=… tracker_id=…/>` and `<forum>` inside. `parseRecord`
  skips a malformed record instead of aborting the scan — 5.7 million records
  are not all clean.
- Default target is **`x86_64` baseline**, not native: a native build SIGILLs on
  older machines. Pass `-Dcpu=native` deliberately. `zig build dist` is
  ReleaseSafe + stripped (~2 MB per binary).
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
- **Keep the termios syscalls, not `std.posix`.** `term.zig` uses
  `std.os.linux.tcgetattr`/`tcsetattr` classified with `linux.errno()` and keeps
  `linux.termios` (44 bytes, `NCCS` 19). glibc's `struct termios` is 60 bytes;
  if a libc is ever linked, the `std.posix` wrappers overflow that struct and
  abort in ReleaseSafe with `Illegal instruction at address …`.
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
- **A mount is not necessarily a playable release, so the files view lists
  everything.** The dump holds books and archives as often as video: `files`
  now holds every directory and file of the mount (`procs.listEntries`, capped
  at 2000 rows), printed as a tree indented by path depth, and Enter sends every
  one of them — a film, a PDF, an archive, a folder — to `--open` (xdg-open),
  which starts the desktop's default application for the type. Filtering the
  list to media is what made a mounted book look like a failed mount. The
  listing opens by itself when the row that finished mounting is the selected
  one, and `reportMountMedia` still states "файлов: N, папок: M" so the status
  is never a bare "смонтирован".
- **A daemon per release needs its own cache dir**, `<cache>/<hash>`: rekarma
  writes `magnet.pid`/`magnet.log` into `--cache`, so two releases sharing one
  directory would overwrite each other's pid and stop the wrong mount. The same
  pid file is what keeps a *second* daemon off one release: a restart while the
  metadata was still coming reads the empty mountpoint as idle, so both the
  startup state and Enter check `procs.mountRunning` (`/proc/<pid>` for the pid
  in the file) and adopt the daemon that is already working instead of spawning
  a twin over its pid.
- **The qBittorrent service has its own profile, and never the mount root.** The
  shortcut writes `~/.config/systemd/user/qbittorrent-nox.service` and a profile
  under `~/.config/ziggurat/qbittorrent`, and a reinstall rewrites only that one
  unit and one config key — a WebUI password or a port must survive it. The save
  path is a preference (`Session\DefaultSavePath=` in
  `<profile>/qBittorrent/config/qBittorrent.conf`), not `--save-path`, which only
  applies to torrents passed to qBittorrent at startup. Complete releases go to
  the `--torrents` directory (`Torrents` beside `mnt/`), which is created when
  the shortcut runs; the mounts stay read-only and are never touched. The
  download is the release asset of the compiled-in architecture
  (`builtin.cpu.arch` → `x86_64-…`, `aarch64-…`, `riscv64-…`; any other target
  compiles but the shortcut refuses, so one optional installer never breaks a
  build).
- **Inside `[WebUI]` the config keys are bare.** qBittorrent reads
  `WebUI/Password_PBKDF2`, so the line under the `[WebUI]` heading is
  `Password_PBKDF2="@ByteArray(salt:key)"` and `Username=admin`; writing
  `WebUI\Password_PBKDF2` under that heading resolves to
  `WebUI/WebUI/Password_PBKDF2` and is silently ignored — the client then logs
  in with a one-time password instead. The value is PBKDF2-HMAC-SHA512,
  100000 rounds, 16 bytes of salt and 64 of key, both base64 in one
  `@ByteArray(salt:key)`; `--save-path` plays no part in it either.
- **Ctrl-C must reach the program as a keypress** (`ISIG` off in raw mode), or
  the terminal is left in raw mode and the alternate screen after a signal.
  Every exit path restores both, and the mounts deliberately survive the exit —
  the last thing printed is which of them still run and how to stop them.
- **A palette of escape codes per character is fine; an allocation per frame is
  not.** `frame.put()` writes style + text + reset each time, which keeps the
  buffer simple, but any `allocPrint` in a draw function leaks once per tick.
- **A long-running child keeps its pid until it exits.** The ant-client
  installer (`App.install_pid`) and the RuTracker download (`App.download_pid`)
  are reaped with `procs.reapIfDone`, not the per-tick `players` list: that list
  is cleared after one non-blocking `waitpid`, which would drop a still-running
  pid and leave a zombie. Both jobs write their output to `.ziggurat/*.log`; the
  RuTracker one downloads `rutracker-20261031.xml.xz` into the startup directory
  and lets `xz -d` replace it with the `.xml`.
