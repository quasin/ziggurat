//! Everything outside this process: the mounted releases (rekarma daemon),
//! the desktop opener a release's files go to, and the filesystem facts the TUI
//! asks about. Kept out of `tui.zig` so the screen code stays about the screen.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const linux = std.os.linux;
const magnet = @import("magnet.zig");

pub const Config = struct {
    /// The binary that mounts a release; rekarma, by default.
    rekarma: []const u8 = "rekarma",
    /// The desktop's default application for a release's files, chosen by
    /// xdg-open from the extension: a film plays, a book opens in a reader, a
    /// folder in a file manager. The interface names no player of its own.
    opener: []const u8 = "xdg-open",
    /// Where releases are mounted: <mount_root>/<8-char hash>.
    mount_root: []const u8 = "mnt",
    /// Where pieces and the daemon's log/pid are kept:
    /// <cache>/<8-char hash>/{magnet.log,magnet.pid}.
    cache: []const u8 = ".ziggurat/cache",
    /// Where complete releases are kept — qBittorrent's save path. A directory
    /// of its own, never the mount root: the mounted releases are the reader's,
    /// and a download landing in them would fight the FUSE server.
    torrents: []const u8 = "Torrents",
    /// `--cache-limit <size>` for rekarma: how many bytes one release's cache
    /// may keep on disk (holes are punched for the rest, which is what lets a
    /// 10 GB machine mount a 2 TB release). Empty = rekarma's own default, 60 %
    /// of the free space on the cache's filesystem.
    cache_limit: []const u8 = "",
    /// `--prefetch <size>`: read-ahead per waiting read. Empty = rekarma's
    /// default (128 MiB), which a desktop wants and a slow uplink does not.
    prefetch: []const u8 = "",
    /// `--fuse-threads <n>`: FUSE workers. 0 = rekarma's default (32); a
    /// one-core VPS wants fewer, because each worker is a thread that exists
    /// only to wait for pieces.
    fuse_threads: u32 = 0,
};

/// Where a program name actually lives, or null when it is nowhere.
///
/// `std.process.spawn(.{ .exe = .detect })` would search PATH too, but only to
/// fail inside the spawn with a bare `FileNotFound`; resolving first lets the
/// interface say which program is missing and how to point at it. A name with a
/// slash is a path, not a name, and is only checked.
pub fn resolveExecutable(
    allocator: std.mem.Allocator,
    io: Io,
    name: []const u8,
    path_var: ?[]const u8,
) !?[]u8 {
    if (name.len == 0) return null;

    if (std.mem.indexOfScalar(u8, name, '/') != null) {
        std.Io.Dir.cwd().access(io, name, .{ .execute = true }) catch return null;
        return try allocator.dupe(u8, name);
    }

    const dirs = path_var orelse return null;
    var it = std.mem.splitScalar(u8, dirs, ':');
    while (it.next()) |dir| {
        const candidate = try std.fs.path.join(allocator, &.{ if (dir.len == 0) "." else dir, name });
        if (std.Io.Dir.cwd().access(io, candidate, .{ .execute = true })) |_| {
            return candidate;
        } else |_| {
            allocator.free(candidate);
        }
    }
    return null;
}

/// A release's own directory names, so one release's log and pid file can
/// never be overwritten by another's.
pub fn dirsOf(allocator: std.mem.Allocator, config: Config, source: []const u8) !struct { mount: []u8, cache: []u8 } {
    var name_buf: [16]u8 = undefined;
    const name = magnet.mountName(source, &name_buf);
    return .{
        .mount = try std.fs.path.join(allocator, &.{ config.mount_root, name }),
        .cache = try std.fs.path.join(allocator, &.{ config.cache, name }),
    };
}

/// Start the daemon that serves one release. The daemon forks itself and
/// returns at once — the mount appears later, which is why the caller polls
/// `isMounted` instead of trusting this call.
pub fn mount(
    io: Io,
    exe: []const u8,
    source: []const u8,
    mount_dir: []const u8,
    cache_dir: []const u8,
    tuning: Config,
) !void {
    // The metadata comes from the swarm (--magnet) or from the file the user
    // picked (--torrent); everything else about the daemon is the same.
    const flag: []const u8 = if (magnet.isTorrent(source)) "--torrent" else "--magnet";
    const value: []const u8 = if (magnet.isTorrent(source)) magnet.torrentPath(source) else source;

    // Built rather than spelled out because the tuning flags are optional. A
    // daemon's stderr goes to /dev/null here, so a flag rekarma rejects would
    // look like a mount that never appears: the values are validated in
    // main.parse before they ever reach this point.
    var args: [20][]const u8 = undefined;
    var argc: usize = 0;
    const fixed = [_][]const u8{ exe, flag, value, "-m", mount_dir, "--cache", cache_dir, "--daemon" };
    for (fixed) |arg| {
        args[argc] = arg;
        argc += 1;
    }
    if (tuning.cache_limit.len > 0) {
        args[argc] = "--cache-limit";
        args[argc + 1] = tuning.cache_limit;
        argc += 2;
    }
    if (tuning.prefetch.len > 0) {
        args[argc] = "--prefetch";
        args[argc + 1] = tuning.prefetch;
        argc += 2;
    }
    var threads_buf: [8]u8 = undefined;
    if (tuning.fuse_threads > 0) {
        args[argc] = "--fuse-threads";
        args[argc + 1] = std.fmt.bufPrint(&threads_buf, "{d}", .{tuning.fuse_threads}) catch
            return error.MountStartFailed;
        argc += 2;
    }

    var child = try std.process.spawn(io, .{
        .argv = args[0..argc],
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    const term = try child.wait(io);
    if (term != .exited or term.exited != 0) return error.MountStartFailed;
}

/// A release counts as mounted once its directory exists and lists something.
/// Root-level readdir is served from the metadata the daemon already has, so
/// asking once a tick is cheap even while the swarm is slow.
pub fn isMounted(io: Io, mount_dir: []const u8) bool {
    var dir = std.Io.Dir.cwd().openDir(io, mount_dir, .{ .iterate = true }) catch return false;
    defer dir.close(io);
    var it = dir.iterate();
    const first = it.next(io) catch return false;
    return first != null;
}

/// Stops the daemon through the pid file it wrote; the daemon's own SIGTERM
/// path unmounts before exiting.
pub fn unmount(io: Io, cache_dir: []const u8) bool {
    const pid_text = readPid(io, cache_dir) orelse return false;
    std.posix.kill(pid_text, .TERM) catch return false;
    return true;
}

/// Whether a mount daemon for this release is still alive: `<cache>/magnet.pid`
/// names it and `/proc/<pid>` says the number is still a process. The pid file
/// outlives a daemon that exited or was killed, so the file alone proves
/// nothing — this is the check that keeps a second daemon off the same release.
pub fn mountRunning(io: Io, cache_dir: []const u8) bool {
    const pid = readPid(io, cache_dir) orelse return false;
    return pidAlive(io, pid);
}

/// `/proc/<pid>` exists for as long as the pid is a process, whatever it does.
fn pidAlive(io: Io, pid: std.posix.pid_t) bool {
    var buf: [48]u8 = undefined;
    const path = std.fmt.bufPrint(&buf, "/proc/{d}", .{pid}) catch return false;
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

fn readPid(io: Io, cache_dir: []const u8) ?std.posix.pid_t {
    var buf: [64]u8 = undefined;
    const path = std.fmt.bufPrint(&buf, "{s}/magnet.pid", .{cache_dir}) catch return null;
    return readPidFile(io, path);
}

fn readPidFile(io: Io, path: []const u8) ?std.posix.pid_t {
    var file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return null;
    defer file.close(io);

    var text: [32]u8 = undefined;
    const n = file.readStreaming(io, &.{&text}) catch return null;
    const trimmed = std.mem.trim(u8, text[0..n], " \t\r\n");
    return std.fmt.parseInt(std.posix.pid_t, trimmed, 10) catch null;
}

/// The room plain `rekarma` records with no option at all: the default room is
/// called `rekarma`, its file is `all.txt` in the directory the program was
/// started from, and the recorder's pid and log sit beside it. Reading that file
/// is what puts the room's history on screen without linking librats into
/// ziggurat — the same reason `--version` asks the binary instead.
pub const room_file = "all.txt";
pub const room_pid_file = "all.txt.pid";

/// Where the recorder's own output goes, for the status line: rekarma names the
/// daemon's log after the room's file.
pub const room_log_file = "all.txt.log";

/// Whether something is recording the default room right now. A pid file left by
/// a run that ended names a process that is not there any more, and /proc is the
/// cheap way to tell the two apart — this is polled by the screen, so it must not
/// spawn anything.
pub fn recorderRunning(io: Io) bool {
    const pid = readPidFile(io, room_pid_file) orelse return false;
    return pidAlive(io, pid);
}

/// Starts `rekarma --daemon` with no other argument: the recorder of the default
/// room. Like a mount it forks and exits at once, so this returning says nothing
/// about the file growing — `recorderRunning` is what the caller polls.
pub fn startRecorder(io: Io, exe: []const u8) !void {
    var child = try std.process.spawn(io, .{
        .argv = &.{ exe, "--daemon" },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    const term = try child.wait(io);
    if (term != .exited or term.exited != 0) return error.RecorderStartFailed;
}

/// Publishes one message into the default room with `rekarma <text>`: a one-shot
/// send that waits for a peer, hands the bytes to the engine and exits. It runs
/// behind the screen because that wait is seconds long, and it is spawned with
/// argv rather than a shell so the message's quotes and spaces stay literal.
///
/// `port` is the recorder's listening port on this machine: dialing it directly
/// makes the message reach the room even when mDNS and the DHT cannot route
/// between two nodes that share a host but not a network path.
pub fn publishMessage(io: Io, exe: []const u8, text: []const u8, port: ?u16) !std.posix.pid_t {
    var argv_buf: [4][]const u8 = undefined;
    var peer_buf: [24]u8 = undefined;
    var argc: usize = 0;

    argv_buf[argc] = exe;
    argc += 1;
    if (port) |p| {
        const peer = std.fmt.bufPrint(&peer_buf, "127.0.0.1:{d}", .{p}) catch return error.NoPid;
        argv_buf[argc] = "-c";
        argv_buf[argc + 1] = peer;
        argc += 2;
    }
    argv_buf[argc] = text;
    argc += 1;

    const child = try std.process.spawn(io, .{
        .argv = argv_buf[0..argc],
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    return child.id orelse error.NoPid;
}

/// The port the recorder listens on, read from the banner it printed at startup
/// (`node <id> on port <n>`). The log is appended to by every run, so the last
/// banner is the one the running process wrote; a log without one means there is
/// no recorder to dial.
pub fn recorderPort(allocator: std.mem.Allocator, io: Io) ?u16 {
    const data = std.Io.Dir.cwd().readFileAlloc(io, room_log_file, allocator, .limited(1 << 20)) catch return null;
    defer allocator.free(data);
    return portFromLog(data);
}

/// The `on port N` half of `recorderPort`, split out so the parse is testable
/// without a daemon.
fn portFromLog(text: []const u8) ?u16 {
    const marker = " on port ";
    var port: ?u16 = null;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        const at = std.mem.indexOf(u8, line, marker) orelse continue;
        const digits = std.mem.trim(u8, line[at + marker.len ..], " \t\r");
        port = std.fmt.parseInt(u16, digits, 10) catch port;
    }
    return port;
}

/// The exit code of a child that has finished, or null while it still runs.
/// `reapIfDone` answers the same question with a bool, which is enough to drop
/// a pid but says nothing about whether the job worked.
pub fn reapCode(pid: std.posix.pid_t) ?u32 {
    var status: i32 = 0;
    if (linux.waitpid(pid, &status, linux.W.NOHANG) != pid) return null;
    // WIFEXITED / WEXITSTATUS without libc: a signal death leaves the low 7 bits
    // set, and 0xff is a code no clean run produces.
    if ((status & 0x7f) != 0) return 0xff;
    return @intCast((status >> 8) & 0xff);
}

/// Hands a file inside the mount to the desktop opener, which starts whatever
/// is registered for that type. The path itself is passed, never a copy, so the
/// player or reader then reads through the mount and those reads are what pull
/// the pieces.
pub fn launch(io: Io, exe: []const u8, path: []const u8) !std.posix.pid_t {
    const child = try std.process.spawn(io, .{
        .argv = &.{ exe, path },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    return child.id orelse error.NoPid;
}

/// Reaps a finished child without blocking the event loop. One that is still
/// running answers nothing, which is not an error.
pub fn reap(pid: std.posix.pid_t) void {
    var status: i32 = 0;
    _ = linux.waitpid(pid, &status, linux.W.NOHANG);
}

/// Reaps a child only once it has exited; false means it is still running and
/// must be asked again later. Unlike `reap`, this lets a long-lived child keep
/// its pid instead of turning into a zombie the first time it is polled.
pub fn reapIfDone(pid: std.posix.pid_t) bool {
    var status: i32 = 0;
    return linux.waitpid(pid, &status, linux.W.NOHANG) == pid;
}

pub const ant_client_url = "https://raw.githubusercontent.com/WithAutonomi/ant-client/main/install.sh";

/// The static build of qBittorrent's headless client: one file, no package
/// manager, and the version the service runs is exactly the one named here.
/// The release directory is fixed; the file inside it is chosen by the
/// architecture this binary was compiled for, so an aarch64 or riscv64 ziggurat
/// installs the client it can actually run.
pub const qbittorrent_release = "https://github.com/userdocs/qbittorrent-nox-static/releases/download/release-5.3.0_v2.1.2/";
pub const qbittorrent_asset: ?[]const u8 = switch (builtin.cpu.arch) {
    .x86_64 => "x86_64-qbittorrent-nox",
    .aarch64 => "aarch64-qbittorrent-nox",
    .riscv64 => "riscv64-qbittorrent-nox",
    // Not a build target of this project; the shortcut refuses instead of the
    // whole program failing to compile over one optional installer.
    else => null,
};

/// The port the WebUI of ziggurat's qBittorrent answers on.
pub const qbittorrent_webui_port: u16 = 8090;

/// The engine, fetched from its own release when the machine has none. A fresh
/// session otherwise refuses every mount with "rekarma не найден", and there is
/// no package manager that carries it — the binary beside the matching triple
/// is the whole install. The tag is spelled out because the asset URL is built
/// at compile time; it is the version this source was released with.
pub const rekarma_release = "https://github.com/quasin/rekarma/releases/download/v0.1.0/";
pub const rekarma_asset: ?[]const u8 = switch (builtin.cpu.arch) {
    .x86_64 => "rekarma-x86_64-linux-gnu",
    .aarch64 => "rekarma-aarch64-linux-gnu",
    .riscv64 => "rekarma-riscv64-linux-gnu",
    // Any other target still compiles; it just has no asset to fetch and falls
    // back to the existing "not found" warning.
    else => null,
};

/// Where the install lands, and where a later start looks for it even when
/// `~/.local/bin` is not on PATH.
pub fn defaultRekarmaPath(allocator: std.mem.Allocator, home: []const u8) ![]u8 {
    return std.fs.path.join(allocator, &.{ home, ".local/bin/rekarma" });
}

/// `.new` plus `mv` so a running engine is replaced by rename, never rewritten
/// under a mount that is reading it. `--max-time` keeps a black-holed network
/// from stalling the start for ever.
pub fn rekarmaCommand(buf: []u8, home: []const u8, asset: []const u8) ![]const u8 {
    return std.fmt.bufPrint(
        buf,
        "mkdir -p \"{s}/.local/bin\" && curl -fsSL --max-time 120 {s}{s} -o \"{s}/.local/bin/rekarma.new\" && " ++
            "chmod +x \"{s}/.local/bin/rekarma.new\" && " ++
            "mv -f \"{s}/.local/bin/rekarma.new\" \"{s}/.local/bin/rekarma\"",
        .{ home, rekarma_release, asset, home, home, home, home },
    );
}

/// Fetches rekarma into `~/.local/bin` and waits: the first mount needs it, so
/// unlike the optional installers this one cannot be backgrounded. Its output
/// goes to `log_path` instead of the terminal the interface is about to take
/// over; a failure leaves the usual "not found" status line in place.
pub fn installRekarma(io: Io, home: []const u8, log_path: []const u8) !void {
    const asset = rekarma_asset orelse return error.UnsupportedArch;
    var cmd_buf: [2048]u8 = undefined;
    const command = try rekarmaCommand(&cmd_buf, home, asset);

    var wrapped_buf: [4096]u8 = undefined;
    const wrapped = try std.fmt.bufPrint(&wrapped_buf, "( {s} ) >> \"{s}\" 2>&1", .{ command, log_path });
    var child = try std.process.spawn(io, .{
        .argv = &.{ "/bin/sh", "-c", wrapped },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    const term = try child.wait(io);
    if (term != .exited or term.exited != 0) return error.RekarmaInstallFailed;
}

/// The RuTracker database source. The address is fixed, the archive has the
/// upstream name, and `xz -d` turns it into the `.xml` beside it.
pub const rutracker_address = "a74d01ff38a9a737cc009f54ae4bf4f0b03c446aa61e1c1d11fff5c6f6df06fc";
pub const rutracker_archive = "rutracker-20261031.xml.xz";

/// The ant-client installer is a curl|bash pipeline, so it needs a shell.
pub fn antClientCommand(buf: []u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "curl -fsSL {s} | bash", .{ant_client_url});
}

/// `xz -d -f` decompresses the archive in place and removes the `.xz`, which is
/// exactly "unpack it next to the program and drop the original".
pub fn rutrackerCommand(buf: []u8, ant: []const u8, xz: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "\"{s}\" file download {s} -o {s} && \"{s}\" -d -f {s}", .{
        ant, rutracker_address, rutracker_archive, xz, rutracker_archive,
    });
}

/// Runs `command` through a shell with all of its output in `log_path`: a child
/// writing to this terminal would paint over the panels. `dir` is created first
/// because the log usually lives in the interface's own state directory.
pub fn runInBackground(io: Io, command: []const u8, dir: []const u8, log_path: []const u8) !std.posix.pid_t {
    var wrapped_buf: [4096]u8 = undefined;
    const wrapped = try std.fmt.bufPrint(
        &wrapped_buf,
        "mkdir -p \"{s}\" && ( {s} ) >> \"{s}\" 2>&1",
        .{ dir, command, log_path },
    );
    const child = try std.process.spawn(io, .{
        .argv = &.{ "/bin/sh", "-c", wrapped },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    return child.id orelse error.NoPid;
}

/// Starts the installer without waiting for it: a slow download must not
/// freeze the interface. The caller reaps the pid through `reapIfDone`.
pub fn installAutonomi(io: Io, dir: []const u8, log_path: []const u8) !std.posix.pid_t {
    var cmd_buf: [2048]u8 = undefined;
    const command = try antClientCommand(&cmd_buf);
    return runInBackground(io, command, dir, log_path);
}

/// The profile ziggurat gives qBittorrent: a directory of its own, so the
/// service never reads or rewrites a qBittorrent the user may already run.
pub fn qbittorrentProfile(allocator: std.mem.Allocator, home: []const u8) ![]u8 {
    return std.fs.path.join(allocator, &.{ home, ".config/ziggurat/qbittorrent" });
}

/// Where qBittorrent keeps its settings under that profile. A `--profile=<dir>`
/// run stores them in `<dir>/qBittorrent/config/qBittorrent.conf`.
pub fn qbittorrentConfigPath(allocator: std.mem.Allocator, home: []const u8) ![]u8 {
    return std.fs.path.join(allocator, &.{ home, ".config/ziggurat/qbittorrent/qBittorrent/config/qBittorrent.conf" });
}

/// Downloads the static build into `~/.local/bin` and (re)starts the user unit:
/// the unit and the profile config are already written by ziggurat, so the job
/// here is the file and the service manager. `.new` plus `mv` keeps a running
/// binary from being replaced mid-read.
pub fn qbittorrentCommand(buf: []u8, home: []const u8, asset: []const u8) ![]const u8 {
    return std.fmt.bufPrint(
        buf,
        "mkdir -p \"{s}/.local/bin\" && curl -fsSL {s}{s} -o \"{s}/.local/bin/qbittorrent-nox.new\" && " ++
            "chmod +x \"{s}/.local/bin/qbittorrent-nox.new\" && " ++
            "mv -f \"{s}/.local/bin/qbittorrent-nox.new\" \"{s}/.local/bin/qbittorrent-nox\" && " ++
            "systemctl --user daemon-reload && systemctl --user enable --now qbittorrent-nox.service",
        .{ home, qbittorrent_release, asset, home, home, home, home },
    );
}

/// The user service that keeps the client up after the interface exits. The
/// paths are literal because the home is known here; the WebUI port is fixed so
/// the panel can name it.
pub fn qbittorrentUnit(buf: []u8, home: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buf,
        \\[Unit]
        \\Description=qBittorrent-nox (ziggurat)
        \\Wants=network-online.target
        \\After=network-online.target nss-lookup.target
        \\
        \\[Service]
        \\Type=exec
        \\ExecStart="{s}/.local/bin/qbittorrent-nox" --profile="{s}/.config/ziggurat/qbittorrent" --webui-port={d}
        \\Restart=on-failure
        \\SyslogIdentifier=qbittorrent-nox
        \\
        \\[Install]
        \\WantedBy=default.target
        \\
    , .{ home, home, qbittorrent_webui_port });
}

pub const qbittorrent_save_path_key = "Session\\DefaultSavePath=";
pub const qbittorrent_username = "admin";
pub const qbittorrent_password = "ziggurat";

/// The `@ByteArray(salt:key)` value qBittorrent keeps under
/// `WebUI\Password_PBKDF2`: 16 bytes of salt and PBKDF2-HMAC-SHA512, 100000
/// rounds, 64 bytes of key — the constants the client itself verifies with.
/// Both halves are standard base64, salt first, joined by a colon.
pub fn qbittorrentPasswordHash(io: Io, allocator: std.mem.Allocator, password: []const u8) ![]u8 {
    var salt: [16]u8 = undefined;
    io.random(&salt);
    var key: [64]u8 = undefined;
    try std.crypto.pwhash.pbkdf2(&key, password, &salt, 100_000, std.crypto.auth.hmac.sha2.HmacSha512);

    var salt_buf: [24]u8 = undefined; // base64 of 16 bytes
    var key_buf: [88]u8 = undefined; // base64 of 64 bytes
    const salt_text = std.base64.standard.Encoder.encode(&salt_buf, &salt);
    const key_text = std.base64.standard.Encoder.encode(&key_buf, &key);
    return std.fmt.allocPrint(allocator, "@ByteArray({s}:{s})", .{ salt_text, key_text });
}

/// Points qBittorrent's default save path at `save_path`. It is a preference,
/// not a switch — `--save-path` only applies to torrents handed to it at
/// startup — so the profile's config is edited instead.
pub fn setDefaultSavePath(io: Io, allocator: std.mem.Allocator, config_path: []const u8, save_path: []const u8) !void {
    return upsertConfigKey(io, allocator, config_path, "[BitTorrent]", qbittorrent_save_path_key, save_path, false);
}

/// The WebUI account the service starts with. Both keys are written only when
/// the file does not have them: a password the user changed in the WebUI must
/// survive the next press of the shortcut.
pub fn setWebUiAccount(
    io: Io,
    allocator: std.mem.Allocator,
    config_path: []const u8,
    username: []const u8,
    password_hash: []const u8,
) !void {
    var quoted_buf: [256]u8 = undefined;
    const quoted = try std.fmt.bufPrint(&quoted_buf, "\"{s}\"", .{password_hash});
    // Inside `[WebUI]` the keys are bare: qBittorrent reads
    // `WebUI/Password_PBKDF2`, and a `WebUI\` prefix under the same section
    // would resolve to `WebUI/WebUI/...` and be ignored.
    try upsertConfigKey(io, allocator, config_path, "[WebUI]", "Username=", username, true);
    try upsertConfigKey(io, allocator, config_path, "[WebUI]", "Password_PBKDF2=", quoted, true);
}

/// Writes one key into a `qBittorrent.conf`: the file is created when absent,
/// the key is replaced where it already is, and inserted right under its
/// section header otherwise (a missing section is appended). `keep_existing`
/// leaves the current value alone when the key is already there.
pub fn upsertConfigKey(
    io: Io,
    allocator: std.mem.Allocator,
    config_path: []const u8,
    section: []const u8,
    key: []const u8,
    value: []const u8,
    keep_existing: bool,
) !void {
    var existing: []u8 = &.{};
    var owned = false;
    if (std.Io.Dir.cwd().readFileAlloc(io, config_path, allocator, .limited(1 << 20))) |data| {
        existing = data;
        owned = true;
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }
    defer if (owned) allocator.free(existing);

    var has_key = false;
    var key_scan = std.mem.splitScalar(u8, existing, '\n');
    while (key_scan.next()) |line| {
        if (std.mem.startsWith(u8, std.mem.trimEnd(u8, line, "\r"), key)) {
            has_key = true;
            break;
        }
    }
    if (has_key and keep_existing) return;

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    var wrote = false;
    var first = true;
    var lines = std.mem.splitScalar(u8, existing, '\n');
    while (lines.next()) |line| {
        const bare = std.mem.trimEnd(u8, line, "\r");
        if (!first) try out.append(allocator, '\n');
        first = false;

        if (std.mem.eql(u8, bare, section)) {
            try out.appendSlice(allocator, line);
            if (!has_key) {
                try out.append(allocator, '\n');
                try out.appendSlice(allocator, key);
                try out.appendSlice(allocator, value);
                wrote = true;
            }
            continue;
        }
        if (std.mem.startsWith(u8, bare, key)) {
            try out.appendSlice(allocator, key);
            try out.appendSlice(allocator, value);
            wrote = true;
            continue;
        }
        try out.appendSlice(allocator, line);
    }

    if (!wrote) {
        if (out.items.len > 0 and out.items[out.items.len - 1] != '\n') try out.append(allocator, '\n');
        try out.appendSlice(allocator, section);
        try out.append(allocator, '\n');
        try out.appendSlice(allocator, key);
        try out.appendSlice(allocator, value);
        try out.append(allocator, '\n');
    }

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = config_path, .data = out.items });
}

/// The path made absolute against the directory the program runs in: a
/// qBittorrent preference must be absolute, while `--torrents Torrents` reads
/// naturally as "beside mnt/".
pub fn absolutePath(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(path)) return allocator.dupe(u8, path);
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const rc = linux.getcwd(&buf, buf.len);
    if (linux.errno(rc) != .SUCCESS or rc == 0) return error.CwdUnavailable;
    // The syscall answers the length including the terminating NUL.
    return std.fs.path.join(allocator, &.{ buf[0 .. rc - 1], path });
}

pub const ToolVersions = struct {
    rekarma: []const u8 = "",
    librats: []const u8 = "",
};

/// The version lines say `rekarma 0.0.1` / `librats 3.0.4.0 (major=…)`;
/// everything after the first word is trimmed to the bare version token.
pub fn parseToolVersions(output: []const u8, rekarma_buf: []u8, librats_buf: []u8) ToolVersions {
    var versions: ToolVersions = .{};
    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (std.mem.startsWith(u8, trimmed, "rekarma ") and versions.rekarma.len == 0) {
            versions.rekarma = copyVersion(rekarma_buf, trimmed["rekarma ".len..]);
        } else if (std.mem.startsWith(u8, trimmed, "librats ") and versions.librats.len == 0) {
            versions.librats = copyVersion(librats_buf, trimmed["librats ".len..]);
        }
    }
    return versions;
}

fn copyVersion(buf: []u8, tail: []const u8) []const u8 {
    const end = std.mem.indexOfAny(u8, tail, " \t") orelse tail.len;
    const n = @min(buf.len, end);
    @memcpy(buf[0..n], tail[0..n]);
    return buf[0..n];
}

/// ziggurat does not link librats any more: the binary that mounts releases is
/// the one that speaks it, so its own `--version` is the only truthful answer
/// about the engine. A missing or failing rekarma yields empty strings.
pub fn toolVersions(
    allocator: std.mem.Allocator,
    io: Io,
    exe: []const u8,
    rekarma_buf: []u8,
    librats_buf: []u8,
) ToolVersions {
    const result = std.process.run(allocator, io, .{
        .argv = &.{ exe, "--version" },
        .stdout_limit = .limited(16 * 1024),
        .stderr_limit = .limited(4 * 1024),
    }) catch return .{};
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    return parseToolVersions(result.stdout, rekarma_buf, librats_buf);
}

/// One row of a release as the files view lists it: a directory or a file,
/// with the path inside the mount (root included) so the player or the desktop
/// opener can be handed it unchanged.
pub const Entry = struct {
    path: []const u8,
    size: u64 = 0,
    dir: bool = false,
};

/// Every directory and file of a release, sorted so parents come before their
/// children and a directory before the files beside it — the panel indents by
/// depth, which only reads as a tree with that order.
///
/// The walk is bounded: a release with thousands of files must not turn one
/// keypress into a second of readdir.
///
/// Two allocators on purpose: the list's own buffer must outlive a frame (and
/// be freed by whoever owns the list), while the paths it holds are rebuilt
/// from scratch on every open and belong to a scratch arena.
pub fn listEntries(
    list_allocator: std.mem.Allocator,
    path_allocator: std.mem.Allocator,
    io: Io,
    root: []const u8,
    out: *std.ArrayList(Entry),
) !void {
    try scan(list_allocator, path_allocator, io, root, 0, out);
    std.mem.sort(Entry, out.items, {}, struct {
        fn lessThan(_: void, a: Entry, b: Entry) bool {
            const pa = std.fs.path.dirname(a.path) orelse "";
            const pb = std.fs.path.dirname(b.path) orelse "";
            if (!std.mem.eql(u8, pa, pb)) return std.mem.lessThan(u8, pa, pb);
            if (a.dir != b.dir) return a.dir;
            return std.mem.lessThan(u8, a.path, b.path);
        }
    }.lessThan);
}

const max_depth = 8;
/// A release can hold hundreds of tracks plus scans; the cap is what keeps one
/// keypress from walking a pathological tree, not a display limit.
const max_files = 2000;

fn scan(
    list_allocator: std.mem.Allocator,
    path_allocator: std.mem.Allocator,
    io: Io,
    path: []const u8,
    depth: usize,
    out: *std.ArrayList(Entry),
) !void {
    if (depth > max_depth or out.items.len >= max_files) return;
    var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch return;
    defer dir.close(io);

    var it = dir.iterate();
    while (it.next(io) catch return) |entry| {
        if (out.items.len >= max_files) return;
        if (entry.name.len == 0 or entry.name[0] == '.') continue;
        const child = try std.fs.path.join(path_allocator, &.{ path, entry.name });
        switch (entry.kind) {
            // The directory is a row of its own as well as a level to descend
            // into: the panel names the folders the user sees in the mount.
            .directory => {
                try out.append(list_allocator, .{ .path = child, .dir = true });
                try scan(list_allocator, path_allocator, io, child, depth + 1, out);
            },
            .file, .sym_link => {
                const size = fileSize(io, child) orelse 0;
                try out.append(list_allocator, .{ .path = child, .size = size });
            },
            else => {},
        }
    }
}

fn fileSize(io: Io, path: []const u8) ?u64 {
    const st = std.Io.Dir.cwd().statFile(io, path, .{}) catch return null;
    return st.size;
}

/// The last non-empty line of a log, for the status line: rekarma says
/// "waiting for pieces … (N peers)" there, which is the difference between a
/// slow swarm and a hang.
pub fn tailLine(allocator: std.mem.Allocator, io: Io, path: []const u8) ?[]u8 {
    const data = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1 << 20)) catch return null;
    defer allocator.free(data);
    var lines = std.mem.splitBackwardsScalar(u8, std.mem.trimEnd(u8, data, "\r\n"), '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        return allocator.dupe(u8, trimmed) catch null;
    }
    return null;
}

pub fn cacheLogPath(allocator: std.mem.Allocator, cache_dir: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/magnet.log", .{cache_dir});
}

const testing = std.testing;

test "procs: the recorder's port is the last one its log printed" {
    const log =
        \\daemon   pid 100, log all.txt.log
        \\node     082194d4f537 on port 40001
        \\listening in rekarma — Ctrl-C to stop
        \\daemon   pid 200, log all.txt.log
        \\node     082194d4f537 on port 40585
        \\listening in rekarma — Ctrl-C to stop
    ;
    try testing.expectEqual(@as(?u16, 40585), portFromLog(log));
    try testing.expectEqual(@as(?u16, null), portFromLog("listening in rekarma\n"));
    // A torn last line (the daemon died mid-write) keeps the previous answer.
    try testing.expectEqual(@as(?u16, 40001), portFromLog("node id on port 40001\nnode id on port "));
}

test "procs: one release, one mount dir and one cache dir" {
    const a = testing.allocator;
    const config = Config{};
    const link = "magnet:?xt=urn:btih:81DB4118ADC4332D9D1CFFF9D80667C4DFCF5848";

    const dirs = try dirsOf(a, config, link);
    defer a.free(dirs.mount);
    defer a.free(dirs.cache);

    try testing.expectEqualStrings("mnt/81db4118", dirs.mount);
    try testing.expectEqualStrings(".ziggurat/cache/81db4118", dirs.cache);
}

test "procs: a mount is running only while its pid file names a live process" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var buf: [128]u8 = undefined;
    const cache = try std.fmt.bufPrint(&buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    // No daemon ever wrote a pid here.
    try testing.expect(!mountRunning(io, cache));

    // A pid file naming this very process is a daemon that is still around.
    var pid_buf: [32]u8 = undefined;
    const mine = try std.fmt.bufPrint(&pid_buf, "{d}", .{std.os.linux.getpid()});
    try tmp.dir.writeFile(io, .{ .sub_path = "magnet.pid", .data = mine });
    try testing.expect(mountRunning(io, cache));

    // A daemon that exited leaves its pid file behind, so the number is what
    // gets checked, not the file.
    try tmp.dir.writeFile(io, .{ .sub_path = "magnet.pid", .data = "999999999" });
    try testing.expect(!mountRunning(io, cache));
}

test "procs: the qBittorrent config keeps every other setting" {
    const a = testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/qBittorrent.conf", .{tmp.sub_path});

    // A fresh profile gets the section and the key.
    try setDefaultSavePath(io, a, path, "/data/Torrents");
    var buf: [4096]u8 = undefined;
    var text = try std.Io.Dir.cwd().readFile(io, path, &buf);
    try testing.expectEqualStrings("[BitTorrent]\nSession\\DefaultSavePath=/data/Torrents\n", text);

    // A file the client already filled in keeps its keys; only ours changes.
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = path,
        .data = "[BitTorrent]\nSession\\Port=16881\nSession\\DefaultSavePath=/old\n\n[WebUI]\nPort=8080\n",
    });
    try setDefaultSavePath(io, a, path, "/new");
    text = try std.Io.Dir.cwd().readFile(io, path, &buf);
    try testing.expectEqualStrings(
        "[BitTorrent]\nSession\\Port=16881\nSession\\DefaultSavePath=/new\n\n[WebUI]\nPort=8080\n",
        text,
    );

    // A section without the key gets it right under the header.
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = "[BitTorrent]\nSession\\Port=1\n" });
    try setDefaultSavePath(io, a, path, "/x");
    text = try std.Io.Dir.cwd().readFile(io, path, &buf);
    try testing.expectEqualStrings("[BitTorrent]\nSession\\DefaultSavePath=/x\nSession\\Port=1\n", text);
}

test "procs: the qBittorrent password hash is PBKDF2 the client can verify" {
    const a = testing.allocator;
    const hash = try qbittorrentPasswordHash(std.testing.io, a, "ziggurat");
    defer a.free(hash);

    try testing.expect(std.mem.startsWith(u8, hash, "@ByteArray("));
    try testing.expect(std.mem.endsWith(u8, hash, ")"));

    const body = hash["@ByteArray(".len .. hash.len - 1];
    const colon = std.mem.indexOfScalar(u8, body, ':').?;
    const salt_text = body[0..colon];
    const key_text = body[colon + 1 ..];
    // 16 bytes of salt and 64 bytes of key, base64 with padding.
    try testing.expectEqual(@as(usize, 24), salt_text.len);
    try testing.expectEqual(@as(usize, 88), key_text.len);

    var salt: [16]u8 = undefined;
    var key: [64]u8 = undefined;
    try std.base64.standard.Decoder.decode(&salt, salt_text);
    try std.base64.standard.Decoder.decode(&key, key_text);

    var derived: [64]u8 = undefined;
    try std.crypto.pwhash.pbkdf2(&derived, "ziggurat", &salt, 100_000, std.crypto.auth.hmac.sha2.HmacSha512);
    try testing.expectEqualSlices(u8, &key, &derived);
}

test "procs: the WebUI account is written once and then left alone" {
    const a = testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/qBittorrent.conf", .{tmp.sub_path});

    try setWebUiAccount(io, a, path, "admin", "@ByteArray(AAAA:BBBB)");
    var buf: [4096]u8 = undefined;
    var text = try std.Io.Dir.cwd().readFile(io, path, &buf);
    try testing.expectEqualStrings(
        "[WebUI]\nPassword_PBKDF2=\"@ByteArray(AAAA:BBBB)\"\nUsername=admin\n",
        text,
    );

    // The password the user changed in the WebUI stays; the missing username
    // is still filled in.
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = path,
        .data = "[WebUI]\nPassword_PBKDF2=\"@ByteArray(CCCC:DDDD)\"\n",
    });
    try setWebUiAccount(io, a, path, "admin", "@ByteArray(AAAA:BBBB)");
    text = try std.Io.Dir.cwd().readFile(io, path, &buf);
    try testing.expectEqualStrings(
        "[WebUI]\nUsername=admin\nPassword_PBKDF2=\"@ByteArray(CCCC:DDDD)\"\n",
        text,
    );
}

test "procs: the qBittorrent asset is the build of this architecture" {
    const asset = qbittorrent_asset.?;
    try testing.expect(std.mem.startsWith(u8, asset, @tagName(builtin.cpu.arch)));
    try testing.expect(std.mem.endsWith(u8, asset, "-qbittorrent-nox"));
}

test "procs: the qBittorrent command fetches the build of this architecture" {
    var buf: [4096]u8 = undefined;
    const asset = qbittorrent_asset.?;
    const command = try qbittorrentCommand(&buf, "/home/u", asset);

    var url_buf: [256]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "{s}{s}", .{ qbittorrent_release, asset });
    try testing.expect(std.mem.indexOf(u8, command, url) != null);
}

test "procs: the qBittorrent unit names the profile and the WebUI port" {
    var buf: [2048]u8 = undefined;
    const unit = try qbittorrentUnit(&buf, "/home/u");
    try testing.expect(std.mem.indexOf(
        u8,
        unit,
        "ExecStart=\"/home/u/.local/bin/qbittorrent-nox\" --profile=\"/home/u/.config/ziggurat/qbittorrent\" --webui-port=8090",
    ) != null);
    try testing.expect(std.mem.indexOf(u8, unit, "WantedBy=default.target") != null);
}

test "procs: a relative Torrents path is made absolute" {
    const a = testing.allocator;

    const absolute = try absolutePath(a, "/data/Torrents");
    defer a.free(absolute);
    try testing.expectEqualStrings("/data/Torrents", absolute);

    const relative = try absolutePath(a, "Torrents");
    defer a.free(relative);
    try testing.expect(std.fs.path.isAbsolute(relative));
    try testing.expect(std.mem.endsWith(u8, relative, "/Torrents"));
}

test "procs: a program is found on PATH or not at all" {
    const a = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();

    // sh is on PATH in any sane environment; the split also has to survive
    // empty and trailing entries.
    const found = try resolveExecutable(arena.allocator(), std.testing.io, "sh", "/nonexistent::/bin:/usr/bin");
    try testing.expect(found != null);
    try testing.expect(std.mem.endsWith(u8, found.?, "/sh"));

    try testing.expect((try resolveExecutable(arena.allocator(), std.testing.io, "no-such-program-xyz", "/bin:/usr/bin")) == null);
    try testing.expect((try resolveExecutable(arena.allocator(), std.testing.io, "/bin/sh", null)) != null);
    try testing.expect((try resolveExecutable(arena.allocator(), std.testing.io, "/nope/sh", null)) == null);
}

test "procs: the installer command carries the upstream script" {
    var buf: [1024]u8 = undefined;
    const cmd = try antClientCommand(&buf);
    try testing.expect(std.mem.indexOf(u8, cmd, "https://raw.githubusercontent.com/WithAutonomi/ant-client/main/install.sh") != null);
    try testing.expect(std.mem.indexOf(u8, cmd, "| bash") != null);
}

test "procs: the rekarma install names the release asset and the home" {
    const a = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();

    const path = try defaultRekarmaPath(arena.allocator(), "/home/u");
    try testing.expectEqualStrings("/home/u/.local/bin/rekarma", path);

    var buf: [1024]u8 = undefined;
    const cmd = try rekarmaCommand(&buf, "/home/u", "rekarma-x86_64-linux-gnu");
    try testing.expect(std.mem.indexOf(u8, cmd, rekarma_release) != null);
    try testing.expect(std.mem.indexOf(u8, cmd, "rekarma-x86_64-linux-gnu") != null);
    try testing.expect(std.mem.indexOf(u8, cmd, "\"/home/u/.local/bin/rekarma\"") != null);
    // Replaced by rename, never rewritten: a mount may be reading the old one.
    try testing.expect(std.mem.indexOf(u8, cmd, "mv -f") != null);
}

test "procs: the rutracker command downloads, unpacks and drops the archive" {
    var buf: [1024]u8 = undefined;
    const cmd = try rutrackerCommand(&buf, "/usr/bin/ant", "/usr/bin/xz");
    try testing.expect(std.mem.indexOf(u8, cmd, rutracker_address) != null);
    try testing.expect(std.mem.indexOf(u8, cmd, "-o rutracker-20261031.xml.xz") != null);
    try testing.expect(std.mem.indexOf(u8, cmd, "-d -f rutracker-20261031.xml.xz") != null);
    // xz -d removes the input unless -k is passed; the archive must be gone.
    try testing.expect(std.mem.indexOf(u8, cmd, " -k ") == null);
}

test "procs: rekarma's version output is split into the two engines" {
    var rekarma_buf: [64]u8 = undefined;
    var librats_buf: [64]u8 = undefined;
    const versions = parseToolVersions(
        \\rekarma 0.0.1
        \\librats 3.0.4.0 (major=3 minor=0 patch=4 build=0)
        \\librats abi 0x030004, git 3.0.4
        \\
    , &rekarma_buf, &librats_buf);
    try testing.expectEqualStrings("0.0.1", versions.rekarma);
    try testing.expectEqualStrings("3.0.4.0", versions.librats);

    // No rekarma on the machine is an empty answer, not a crash.
    const none = parseToolVersions("command not found\n", &rekarma_buf, &librats_buf);
    try testing.expectEqualStrings("", none.rekarma);
    try testing.expectEqualStrings("", none.librats);
}
