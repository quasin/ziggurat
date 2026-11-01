//! Everything outside this process: the mounted releases (rekarma daemon),
//! the player (vlc) and the filesystem facts the TUI asks about. Kept out of
//! `tui.zig` so the screen code stays about the screen.
const std = @import("std");
const Io = std.Io;
const linux = std.os.linux;
const magnet = @import("magnet.zig");

pub const Config = struct {
    /// The binary that mounts a release; rekarma, by default.
    rekarma: []const u8 = "rekarma",
    /// The binary that plays one; vlc, by default.
    player: []const u8 = "vlc",
    /// The desktop opener behind every non-media file of a release: a book, an
    /// archive or a folder goes here instead of to the player.
    opener: []const u8 = "xdg-open",
    /// Where releases are mounted: <mount_root>/<8-char hash>.
    mount_root: []const u8 = "mnt",
    /// Where pieces and the daemon's log/pid are kept:
    /// <cache>/<8-char hash>/{magnet.log,magnet.pid}.
    cache: []const u8 = ".ziggurat/cache",
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
) !void {
    // The metadata comes from the swarm (--magnet) or from the file the user
    // picked (--torrent); everything else about the daemon is the same.
    const flag: []const u8 = if (magnet.isTorrent(source)) "--torrent" else "--magnet";
    const value: []const u8 = if (magnet.isTorrent(source)) magnet.torrentPath(source) else source;
    var child = try std.process.spawn(io, .{
        .argv = &.{
            exe,       flag,       value,
            "-m",      mount_dir,  "--cache",
            cache_dir, "--daemon",
        },
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
    var buf: [48]u8 = undefined;
    const path = std.fmt.bufPrint(&buf, "/proc/{d}", .{pid}) catch return false;
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
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

/// Hands a file inside the mount to a program: the player for media, the
/// desktop opener for everything else. The path stays inside the FUSE mount, so
/// whatever reads it is what pulls the pieces — nothing is copied out.
pub fn launch(io: Io, exe: []const u8, path: []const u8) !std.posix.pid_t {
    const child = try std.process.spawn(io, .{
        .argv = &.{ exe, path },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    return child.id orelse error.NoPid;
}

/// Reaps a finished player without blocking the event loop. A player that is
/// still running answers 0, which is not an error.
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
