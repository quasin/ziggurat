const std = @import("std");
const Io = std.Io;
const build_options = @import("build_options");
const c = @import("c");
const procs = @import("procs.zig");
const term = @import("term.zig");
const tui = @import("tui.zig");

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
    \\  Two panels: a magnet line on the left, the history of what you typed on
    \\  the right. Enter mounts a release through rekarma; Enter on a mounted
    \\  release lists its media files; Enter on a file plays it with vlc, and the
    \\  player's reads are what pull the pieces out of the swarm.
    \\
    \\  --help, -h          print this text and exit
    \\  --version, -V       print the version and exit
    \\
    \\Options:
    \\  --rekarma <path>    binary that mounts a release      [rekarma]
    \\  --vlc <path>        binary that plays a file          [vlc]
    \\  --mount-root <dir>  where releases are mounted        [mnt]
    \\  --cache <dir>       where pieces and logs are kept    [.ziggurat/cache]
    \\  --history <path>    history file                      [.ziggurat/history.tsv]
    \\
    \\The magnet line accepts a full link, an xt= or urn: fragment, or a bare
    \\info-hash (40 hex or 32 base32). Quote the link in the shell: ? and & are
    \\special there. A link mounts at <mount-root>/<first 8 of the info-hash>.
    \\
    \\Keys:
    \\  Enter     mount the magnet line / open the selected row / play a file
    \\  Tab       move between the input line and the history
    \\  u, x      unmount / remove the selected row
    \\  Esc       clear the input line (or leave the file list)
    \\  Ctrl-C    quit; releases stay mounted until `u` or their pid is killed
    \\
;

const Field = enum { rekarma, player, mount_root, cache, history };
const Flag = struct { name: []const u8, field: Field };

const flags = [_]Flag{
    .{ .name = "--rekarma", .field = .rekarma },
    .{ .name = "--vlc", .field = .player },
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
                        .player => options.config.player = value,
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

/// The librats version is read out of the linked library at runtime, not from a
/// constant or from build.zig.zon: the archive vendored by
/// `scripts/fetch-librats.sh` is the only thing that knows what it was built
/// from, and a mismatch here means the vendor step was skipped or stale.
pub fn libratsVersion() struct { major: c_int, minor: c_int, patch: c_int, build: c_int, text: [:0]const u8 } {
    var major: c_int = 0;
    var minor: c_int = 0;
    var patch: c_int = 0;
    var build: c_int = 0;
    c.rats_version(&major, &minor, &patch, &build);
    return .{
        .major = major,
        .minor = minor,
        .patch = patch,
        .build = build,
        .text = std.mem.span(c.rats_version_string()),
    };
}

fn printHelp(out: *Io.Writer) !void {
    try out.writeAll(usage);
    try out.print("linked librats: {s}\n", .{libratsVersion().text});
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

    switch (parse(args)) {
        .help => try printHelp(out),
        .version => try out.print("ziggurat {s} (librats {s})\n", .{ build_options.version, libratsVersion().text }),
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
            const path_var = init.environ_map.get("PATH");
            const rekarma_exe = try procs.resolveExecutable(arena, init.io, options.config.rekarma, path_var);
            const player_exe = try procs.resolveExecutable(arena, init.io, options.config.player, path_var);

            var app = try tui.App.init(init.gpa, init.io, options.config, .{
                .version = build_options.version,
                .librats_version = libratsVersion().text,
                .history_path = options.history_path,
                .rekarma_exe = rekarma_exe,
                .player_exe = player_exe,
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

    const b = parse(&.{ "ziggurat", "--history", "h.tsv", "--mount-root", "rel" });
    try std.testing.expectEqualStrings("h.tsv", b.run.history_path);
    try std.testing.expectEqualStrings("rel", b.run.config.mount_root);
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

test "librats: the library reports the version it was built from" {
    const v = libratsVersion();
    try std.testing.expect(v.text.len > 0);
    try std.testing.expect(v.major >= 0 and v.minor >= 0 and v.patch >= 0);
    // The string form and the numeric form must agree, or one of them was
    // generated from a different tag than the rest of the archive.
    const expect = try std.fmt.allocPrint(std.testing.allocator, "{d}.{d}.{d}.{d}", .{ v.major, v.minor, v.patch, v.build });
    defer std.testing.allocator.free(expect);
    try std.testing.expectEqualStrings(expect, v.text);
}
