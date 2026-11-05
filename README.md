# Ziggurat

A two-panel terminal UI for watching releases without downloading them first.

The left panel is a source line — a magnet link, a bare info-hash, or a
`.torrent` file; the right one is the history of what you typed.
Enter mounts the release as a read-only directory (a FUSE 3 mount served by
`rekarma`, which owns the librats bittorrent stack),
Enter on a mounted row lists every folder and file of the release, and Enter on a
file hands it to the desktop's default application — a film plays, a book opens
in a reader. That program's reads are what pull the pieces, so playback starts
long before the release is complete: browsing a 100 GB release costs its
metadata only.

```
┌─ Ввод ───────────────────────┐┌─ История ───────────────────────────┐
│> magnet:?xt=urn:btih:81db…   ││▸ 81db4118 episode-two   смонтирован│
│                              ││  9f2c0a11 show-s01e01   монтируется│
│Enter — смонтировать          ││  44da0e77   ошибка                 │
└──────────────────────────────┘└────────────────────────────────────┘
```

## Build and run

    zig build                       # -> zig-out/bin/ziggurat (host)
    zig build dist                  # -> zig-out/<triple>/ziggurat (ReleaseSafe, stripped)
    zig build run                   # the interface
    zig build test                  # unit tests

Requires Zig 0.17.0 (`build.zig.zon` `.minimum_zig_version`). Ziggurat is pure
Zig and links neither librats nor the C library; nothing has to be vendored
before the first build.

Watching a release needs two more programs on `PATH` (both overridable):

- `rekarma` — mounts a magnet or a `.torrent` as a read-only directory. Ziggurat
  starts it as a daemon per release:
  `rekarma --magnet <link>|--torrent <file> -m <dir> --cache <dir> --daemon`.
  That binary needs libfuse3 at build and run time.
- `xdg-open` — hands a file of the mount to the desktop's default application,
  started as `xdg-open <path-inside-the-mount>`. Ziggurat names no player of its
  own: a film opens in whatever plays video, a book in whatever reads it.

`--help` and `--version` ask rekarma for its own and librats' versions
(`rekarma --version`); ziggurat has no librats of its own to report, and the
answer therefore describes the engine the mounts will actually run.

## Keys

    Enter    mount the source line / open the selected row / play a file
    ↓        select a shortcut under the source line
    Tab      move between the input line and the history
    u        unmount the selected release
    x        forget the selected row
    Esc      clear the input line, or leave the file list
    Ctrl-C   quit — mounts keep running until `u` or their pid is killed

The source line accepts a full magnet link, an `xt=` or `urn:` fragment, a bare
info-hash (40 hex or 32 base32) — every one of those is completed into
`magnet:?xt=urn:btih:…` — or the path of a `.torrent` file, typed as
`release.torrent` or explicitly as `file:<path>` (for a torrent saved without the
extension). A `.torrent` is mounted with the release's metadata read from the
file, so it can be browsed with no peer at all. Quote a link in a shell: `?` and
`&` are special there.

## Where things live

    mnt/<first 8 of the info-hash>/      the release, read-only, while mounted
    mnt/<digest of the path>/            the same, for a .torrent source
    Torrents/                            complete releases (qBittorrent's save path)
    .ziggurat/cache/<hash>/magnet.log    the mount daemon's own log
    .ziggurat/cache/<hash>/magnet.pid    its pid: kill $(cat …) stops it
    .ziggurat/history.tsv                the history (magnet, mount, title)

`--mount-root`, `--torrents`, `--cache`, `--history`, `--rekarma` and `--open`
move all of it.
A mount that never produces metadata is reported as `ошибка` after three
minutes, with the last line of the daemon's log as the reason.

## The room shortcut

The third shortcut under the source line, `История reKarma`, turns the right
panel into the default rekarma room: the messages rekarma recorded, newest at
the bottom and refreshed as they arrive, with a message line on the last row.
Typing there and pressing Enter publishes the text into the room; ↑↓ scroll the
log, Home/End jump, Esc goes back to the mount history.

Nothing in ziggurat links librats, so the panel tails the file plain `rekarma`
writes itself — `all.txt` in the directory ziggurat was started from — and starts
`rekarma --daemon` when no recorder is running (`all.txt.pid` is how it tells).
Sending is a one-shot `rekarma <text>`; it is dialed at the recorder's own port,
read from the banner in `all.txt.log` (`node … on port N`), so a message from the
same machine reaches the room even when mDNS and the DHT cannot route between
two nodes on one host. The recorder outlives the interface like a mount;
`kill $(cat all.txt.pid)` stops the recording.

## The RuTracker dump viewer

The `База RuTracker.Org` shortcut under the source line turns the right panel
into a search over the RuTracker.Org dump (`rutracker-*.xml`, the file
`Install RuTracker.Org DataBase` unpacks into the startup directory). Type a
query, press Enter, and the file is streamed — nothing is loaded, searched or
indexed up front; a match list fills as records come in.

    Enter    scan the dump for the typed query (or mount the selected match)
    ↓        move into the matches; ↑ leaves them
    Esc      back to the history, and stop a scan still running

A match's magnet link (info-hash plus the tracker the dump names) goes into the
source line and the release is mounted from there, exactly as if it had been
pasted. The panel keeps at most 300 matches and stops scanning once it has
them, so a common word answers in seconds and a rare one after one full pass
(about 30 s for 30 GB from a warm page cache in a ReleaseSafe build; a Debug
build scans several times slower). Matches are listed newest first: the scan
sorts them by the release date once it ends, so a row that appears mid-scan can
still move. `rutracker-*.xml` is listed in `.gitignore`
either way — it is tens of gigabytes.

## The qBittorrent shortcut

The `Install qBittorrent-nox` shortcut under the source line puts the static
headless client into `~/.local/bin` — the build matching the architecture
ziggurat itself was compiled for (`x86_64`, `aarch64` or `riscv64`), creates the Torrents directory (`--torrents`,
`Torrents` beside `mnt/` by default), points the client's default save path at
it, and installs a systemd user service that keeps it running:

    systemctl --user status qbittorrent-nox
    journalctl --user -u qbittorrent-nox      # the service's own log

The WebUI answers on http://localhost:8090 with the account `admin` / `ziggurat`
on a fresh profile; a password changed in the WebUI is kept when the shortcut is
pressed again. The service runs its own qBittorrent
profile in `~/.config/ziggurat/qbittorrent`, so it never reads or rewrites a
qBittorrent the user already runs. Complete releases land in the Torrents
directory; the mounts stay read-only and are never touched — a download in them
would fight the FUSE server.

## License

MIT — see [LICENSE](LICENSE).
