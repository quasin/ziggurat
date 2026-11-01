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
    var file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return null;
    defer file.close(io);

    var text: [32]u8 = undefined;
    const n = file.readStreaming(io, &.{&text}) catch return null;
    const trimmed = std.mem.trim(u8, text[0..n], " \t\r\n");
    return std.fmt.parseInt(std.posix.pid_t, trimmed, 10) catch null;
}

/// Hands a file inside the mount to the player. The path stays inside the
/// FUSE mount, so the player's reads are what pull the pieces: nothing is
/// downloaded until the playhead gets there.
pub fn play(io: Io, exe: []const u8, path: []const u8) !std.posix.pid_t {
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

/// The ant-client install pipeline. It needs a shell (`curl | bash`), and a
/// child writing to this terminal would paint over the panels, so the whole
/// pipeline's output is redirected into `log_path` and the interface stays
/// interactive while the installer runs in the background.
pub fn installCommand(buf: []u8, dir: []const u8, log_path: []const u8) ![]const u8 {
    return std.fmt.bufPrint(
        buf,
        "mkdir -p \"{s}\" && ( curl -fsSL https://raw.githubusercontent.com/WithAutonomi/ant-client/main/install.sh | bash ) >> \"{s}\" 2>&1",
        .{ dir, log_path },
    );
}

/// Starts the installer without waiting for it: a slow download must not
/// freeze the interface. The caller reaps the pid through `reap`.
pub fn installAutonomi(io: Io, dir: []const u8, log_path: []const u8) !std.posix.pid_t {
    var cmd_buf: [1024]u8 = undefined;
    const command = try installCommand(&cmd_buf, dir, log_path);
    const child = try std.process.spawn(io, .{
        .argv = &.{ "/bin/sh", "-c", command },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    return child.id orelse error.NoPid;
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

pub const MediaFile = struct {
    path: []const u8,
    size: u64,
};

/// The playable files of a release, sorted so the list is stable between
/// frames. The walk is bounded: a release with thousands of files must not
/// turn one keypress into a second of readdir.
///
/// Two allocators on purpose: the list's own buffer must outlive a frame (and
/// be freed by whoever owns the list), while the paths it holds are rebuilt
/// from scratch on every open and belong to a scratch arena.
pub fn listMedia(
    list_allocator: std.mem.Allocator,
    path_allocator: std.mem.Allocator,
    io: Io,
    root: []const u8,
    out: *std.ArrayList(MediaFile),
) !void {
    try scan(list_allocator, path_allocator, io, root, 0, out);
    std.mem.sort(MediaFile, out.items, {}, struct {
        fn lessThan(_: void, a: MediaFile, b: MediaFile) bool {
            return std.mem.lessThan(u8, a.path, b.path);
        }
    }.lessThan);
}

const max_depth = 8;
const max_files = 500;

fn scan(
    list_allocator: std.mem.Allocator,
    path_allocator: std.mem.Allocator,
    io: Io,
    path: []const u8,
    depth: usize,
    out: *std.ArrayList(MediaFile),
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
            .directory => try scan(list_allocator, path_allocator, io, child, depth + 1, out),
            .file, .sym_link => {
                if (!magnet.isMedia(entry.name)) continue;
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

test "procs: the installer command carries the upstream script and the log" {
    var buf: [1024]u8 = undefined;
    const cmd = try installCommand(&buf, ".ziggurat", ".ziggurat/autonomi-install.log");
    try testing.expect(std.mem.indexOf(u8, cmd, "https://raw.githubusercontent.com/WithAutonomi/ant-client/main/install.sh") != null);
    try testing.expect(std.mem.indexOf(u8, cmd, "| bash") != null);
    try testing.expect(std.mem.indexOf(u8, cmd, ".ziggurat/autonomi-install.log") != null);
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
