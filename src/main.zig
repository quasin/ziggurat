const std = @import("std");
const Io = std.Io;
const build_options = @import("build_options");
const procs = @import("procs.zig");
const term = @import("term.zig");
const tui = @import("tui.zig");
const magnet = @import("magnet.zig");
const history = @import("history.zig");
const rutracker = @import("rutracker.zig");

test {
    // A module reached only from `main()` is never analyzed in a test build, so
    // its own `test` blocks would drop out of the artifact without a word.
    // Naming every import here is what keeps `zig build test` covering the
    // screen, the terminal, the dump and the history: a file imported by an
    // analyzed file is NOT enough on its own, because only the decls the tests
    // reach are analyzed — `rutracker` and `history` are used by drawing code
    // the suite never runs, which is exactly how seven tests were skipped.
    _ = tui;
    _ = term;
    _ = procs;
    _ = rutracker;
    _ = history;
    _ = magnet;
}

/// What the command line asked for. Kept separate from `main` so the parser is
/// testable without a process.
pub const Command = union(enum) {
    help,
    version,
    run: Options,
    /// The command line did not parse; the argument is the one to blame.
    problem: []const u8,
};

/// Everything `run` needs, all of it borrowed from the argument arena.
pub const Options = struct {
    config: procs.Config = .{},
    history_path: []const u8 = ".ziggurat/history.tsv",
};

pub const usage =
    \\usage: ziggurat [options]
    \\
    \\  Two panels: a source line on the left (a magnet link or a .torrent file),
    \\  the history of what you typed on the right. Enter mounts a release through rekarma; once it is
    \\  mounted the right panel lists every folder and file inside it. Enter on a
    \\  file hands it to the desktop's default application — a film plays, a book
    \\  opens in a reader, a folder in a file manager — and that program's reads
    \\  are what pull the pieces out of the swarm.
    \\
    \\  `↓` selects the shortcuts under the source line: the ant-client installer,
    \\  the RuTracker.Org database download and its viewer, and the reKarma room.
    \\  The viewer searches rutracker-*.xml from the startup directory and mounts
    \\  the release of a chosen match.
    \\
    \\  --help, -h          print this text and exit
    \\  --version, -V       print the version and exit
    \\
    \\Options:
    \\  --rekarma <path>    binary that mounts a release          [rekarma]
    \\  --open <path>       opener for a release's files         [xdg-open]
    \\  --mount-root <dir>  where releases are mounted           [mnt]
    \\  --cache <dir>       where pieces and logs are kept       [.ziggurat/cache]
    \\  --history <path>    history file                         [.ziggurat/history.tsv]
    \\
    \\The magnet line accepts a full link, an xt= or urn: fragment, a bare
    \\info-hash (40 hex or 32 base32), or the path of a .torrent file (also as
    \\file:<path>, for a torrent saved without the extension). Quote the link in
    \\the shell: ? and & are special there. A link mounts at <mount-root>/<first
    \\8 of the info-hash>; a .torrent mounts at <mount-root>/<digest of its path>.
    \\
    \\Keys:
    \\  Enter     mount the source line / open the selected row / open a file
    \\  Tab       move between the input line and the history
    \\  u, x      unmount / remove the selected row
    \\  Esc       clear the input line (or leave the file list)
    \\  Ctrl-C    quit; releases stay mounted until `u` or their pid is killed
    \\
;

const Field = enum { rekarma, opener, mount_root, cache, history };
const Flag = struct { name: []const u8, field: Field };

const flags = [_]Flag{
    .{ .name = "--rekarma", .field = .rekarma },
    .{ .name = "--open", .field = .opener },
    .{ .name = "--mount-root", .field = .mount_root },
    .{ .name = "--cache", .field = .cache },
    .{ .name = "--history", .field = .history },
};

pub fn parse(args: []const []const u8) Command {
    // args[0] is the program name; skip it.
    const rest = if (args.len > 0) args[1..] else args;
    var options: Options = .{};
    var i: usize = 0;

    while (i < rest.len) : (i += 1) {
        const arg = rest[i];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) return .help;
        if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-V")) return .version;

        var matched = false;
        for (flags) |flag| {
            switch (valueOf(rest, &i, arg, flag.name)) {
                .no_match => continue,
                .missing => return .{ .problem = arg },
                .value => |value| {
                    matched = true;
                    switch (flag.field) {
                        .rekarma => options.config.rekarma = value,
                        .opener => options.config.opener = value,
                        .mount_root => options.config.mount_root = value,
                        .cache => options.config.cache = value,
                        .history => options.history_path = value,
                    }
                    break;
                },
            }
        }
        if (!matched) return .{ .problem = arg };
    }

    return .{ .run = options };
}

const Value = union(enum) { no_match, missing, value: []const u8 };

/// `--name value` and `--name=value` both work; a value that looks like another
/// option is still taken as the value, because a path may legitimately start
/// with a dash.
fn valueOf(rest: []const []const u8, index: *usize, arg: []const u8, name: []const u8) Value {
    if (!std.mem.startsWith(u8, arg, name)) return .no_match;
    if (arg.len == name.len) {
        if (index.* + 1 >= rest.len) return .missing;
        index.* += 1;
        return .{ .value = rest[index.*] };
    }
    if (arg[name.len] == '=') return .{ .value = arg[name.len + 1 ..] };
    return .no_match;
}

/// ziggurat links neither librats nor the C library: the mount engine is the
/// only thing that speaks librats, so `rekarma --version` is where the engine's
/// version comes from. A missing rekarma answers with empty strings instead of
/// making `--help`/`--version` fail.
fn versionsOf(
    allocator: std.mem.Allocator,
    io: Io,
    exe: []const u8,
    rekarma_buf: []u8,
    librats_buf: []u8,
) procs.ToolVersions {
    return procs.toolVersions(allocator, io, exe, rekarma_buf, librats_buf);
}

/// The help and version flags run before a command line is applied, so they ask
/// the default engine name on PATH, exactly what `run` would use with no flags.
fn defaultVersions(
    allocator: std.mem.Allocator,
    io: Io,
    path_var: ?[]const u8,
    rekarma_buf: []u8,
    librats_buf: []u8,
) procs.ToolVersions {
    const defaults: procs.Config = .{};
    const found = procs.resolveExecutable(allocator, io, defaults.rekarma, path_var) catch return .{};
    const exe = found orelse return .{};
    return versionsOf(allocator, io, exe, rekarma_buf, librats_buf);
}

fn printHelp(out: *Io.Writer, versions: procs.ToolVersions) !void {
    try out.writeAll(usage);
    if (versions.rekarma.len == 0) {
        try out.writeAll("rekarma: не найден — поставьте его на PATH или укажите --rekarma <путь>\n");
        return;
    }
    try out.print("rekarma {s} · librats {s}\n", .{ versions.rekarma, versions.librats });
}

fn printVersion(out: *Io.Writer, versions: procs.ToolVersions) !void {
    if (versions.rekarma.len == 0) {
        try out.print("ziggurat {s} (rekarma не найден)\n", .{build_options.version});
        return;
    }
    try out.print("ziggurat {s} (rekarma {s}, librats {s})\n", .{
        build_options.version, versions.rekarma, versions.librats,
    });
}

pub fn main(init: std.process.Init) !void {
    run(init) catch |err| switch (err) {
        // A closed stdout is the reader going away (`ziggurat | head`), not an
        // error worth a stack trace.
        error.WriteFailed => std.process.exit(0),
        else => return err,
    };
}

fn run(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const out = &stdout_file_writer.interface;

    const path_var = init.environ_map.get("PATH");
    var rekarma_ver_buf: [64]u8 = undefined;
    var librats_ver_buf: [64]u8 = undefined;

    switch (parse(args)) {
        .help => {
            const versions = defaultVersions(arena, init.io, path_var, &rekarma_ver_buf, &librats_ver_buf);
            try printHelp(out, versions);
        },
        .version => {
            const versions = defaultVersions(arena, init.io, path_var, &rekarma_ver_buf, &librats_ver_buf);
            try printVersion(out, versions);
        },
        .problem => |arg| {
            try out.print("ziggurat: unknown option or missing value: {s}\n\n", .{arg});
            try out.writeAll(usage);
            try out.flush();
            // A mistyped command line is a failure for whatever ran it, even
            // though the program did print the help it was asked for.
            std.process.exit(2);
        },
        .run => |options| {
            // The TUI writes to the terminal directly, so nothing may still sit
            // in the buffered writer when it takes over.
            try out.flush();
            if (!term.isTerminal(std.posix.STDOUT_FILENO)) {
                try out.writeAll("ziggurat: the interface needs a terminal (try `ziggurat --help`)\n");
                try out.flush();
                return;
            }

            // Resolved once, here, where the environment is in reach: a
            // missing rekarma is a warning on the status line rather than a
            // spawn failure after the user has already pasted a magnet.
            const rekarma_exe = try procs.resolveExecutable(arena, init.io, options.config.rekarma, path_var);
            const opener_exe = try procs.resolveExecutable(arena, init.io, options.config.opener, path_var);
            const ant_exe = try procs.resolveExecutable(arena, init.io, "ant", path_var);
            const xz_exe = try procs.resolveExecutable(arena, init.io, "xz", path_var);

            // The engine answers for its own librats: ziggurat has no copy of
            // the library to ask, and the version shown must be the one the
            // mounts will actually run.
            const versions = if (rekarma_exe) |exe|
                versionsOf(arena, init.io, exe, &rekarma_ver_buf, &librats_ver_buf)
            else
                procs.ToolVersions{};

            var app = try tui.App.init(init.gpa, init.io, options.config, .{
                .version = build_options.version,
                .rekarma_version = versions.rekarma,
                .history_path = options.history_path,
                .rekarma_exe = rekarma_exe,
                .opener_exe = opener_exe,
                .ant_exe = ant_exe,
                .xz_exe = xz_exe,
            });
            defer app.deinit();
            try app.run();

            // The alt screen is gone by now, so this lands on a normal
            // terminal: what still runs in the background and how to stop it.
            try app.printRemaining(out);
            try out.flush();
        },
    }
    try out.flush();
}

test "parse: no arguments is a run with the defaults" {
    const cmd = parse(&.{"ziggurat"});
    try std.testing.expect(cmd == .run);
    try std.testing.expectEqualStrings("rekarma", cmd.run.config.rekarma);
    try std.testing.expectEqualStrings("mnt", cmd.run.config.mount_root);
    try std.testing.expectEqualStrings(".ziggurat/history.tsv", cmd.run.history_path);
}

test "parse: help and version win wherever they are" {
    try std.testing.expect(parse(&.{ "ziggurat", "--help" }) == .help);
    try std.testing.expect(parse(&.{ "ziggurat", "-V" }) == .version);
    try std.testing.expect(parse(&.{ "ziggurat", "--cache", "/tmp/c", "-h" }) == .help);
}

test "parse: options take a separate value or an =value" {
    const a = parse(&.{ "ziggurat", "--rekarma", "/usr/bin/rekarma", "--cache=/tmp/cache" });
    try std.testing.expect(a == .run);
    try std.testing.expectEqualStrings("/usr/bin/rekarma", a.run.config.rekarma);
    try std.testing.expectEqualStrings("/tmp/cache", a.run.config.cache);

    const b = parse(&.{ "ziggurat", "--history", "h.tsv", "--mount-root", "rel", "--open", "/usr/bin/xdg-open" });
    try std.testing.expectEqualStrings("h.tsv", b.run.history_path);
    try std.testing.expectEqualStrings("rel", b.run.config.mount_root);
    try std.testing.expectEqualStrings("/usr/bin/xdg-open", b.run.config.opener);
}

test "parse: what does not parse names the argument" {
    const cmd = parse(&.{ "ziggurat", "--nope" });
    try std.testing.expect(cmd == .problem);
    try std.testing.expectEqualStrings("--nope", cmd.problem);

    // A flag at the end with no value is a problem, not a silent default.
    const missing = parse(&.{ "ziggurat", "--cache" });
    try std.testing.expect(missing == .problem);
    try std.testing.expectEqualStrings("--cache", missing.problem);
}
