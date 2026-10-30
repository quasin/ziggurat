# Ziggurat

A two-panel terminal UI for watching releases without downloading them first.

The left panel is a magnet line; the right one is the history of what you typed.
Enter mounts the release as a read-only directory (through a FUSE 3 mount served
by [rekarma](https://github.com/librats/librats) and librats' bittorrent stack),
Enter on a mounted row lists its media files, and Enter on a file starts `vlc` on
it. The player's reads are what pull the pieces, so playback starts long before
the release is complete: browsing a 100 GB release costs its metadata only.

```
┌─ Ввод ───────────────────────┐┌─ История ───────────────────────────┐
│> magnet:?xt=urn:btih:81db…   ││▸ 81db4118 episode-two   смонтирован│
│                              ││  9f2c0a11 show-s01e01   монтируется│
│Enter — смонтировать          ││  44da0e77   ошибка                 │
└──────────────────────────────┘└────────────────────────────────────┘
```

## Build and run

    bash scripts/fetch-librats.sh   # once: vendors librats for three targets
    zig build                       # -> zig-out/bin/ziggurat (host)
    zig build dist                  # -> zig-out/<triple>/ziggurat (ReleaseSafe, stripped)
    zig build run                   # the interface
    zig build test                  # unit tests

Requires Zig 0.17.0 (`build.zig.zon` `.minimum_zig_version`), and `cmake`,
`make`, `curl`, `tar` for the librats build. No cross toolchain is needed:
librats is compiled by `zig c++ -target <triple>`.

Watching a release needs two more programs on `PATH` (both overridable):

- `rekarma` — mounts a magnet as a read-only directory. Ziggurat starts it as a
  daemon per release: `rekarma --magnet <link> -m <dir> --cache <dir> --daemon`.
  That binary needs libfuse3 at build and run time.
- `vlc` — the player, started as `vlc <path-inside-the-mount>`.

`--help` prints the librats version the linked archive reports, which is how the
build proves it is linked against the pin in `scripts/fetch-librats.sh`.

## Keys

    Enter    mount the magnet line / open the selected row / play a file
    Tab      move between the input line and the history
    u        unmount the selected release
    x        forget the selected row
    Esc      clear the input line, or leave the file list
    Ctrl-C   quit — mounts keep running until `u` or their pid is killed

The magnet line accepts a full link, an `xt=` or `urn:` fragment, or a bare
info-hash (40 hex or 32 base32); every form is completed into
`magnet:?xt=urn:btih:…`. Quote the link in a shell: `?` and `&` are special
there.

## Where things live

    mnt/<first 8 of the info-hash>/      the release, read-only, while mounted
    .ziggurat/cache/<hash>/magnet.log    the mount daemon's own log
    .ziggurat/cache/<hash>/magnet.pid    its pid: kill $(cat …) stops it
    .ziggurat/history.tsv                the history (magnet, mount, title)

`--mount-root`, `--cache`, `--history`, `--rekarma` and `--vlc` move all of it.
A mount that never produces metadata is reported as `ошибка` after three
minutes, with the last line of the daemon's log as the reason.

## License

MIT — see [LICENSE](LICENSE).
