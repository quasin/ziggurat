const std = @import("std");
const Io = std.Io;
const build_options = @import("build_options");
const c = @import("c");

/// What the command line asked for. Kept separate from `main` so the parser is
/// testable without a process.
pub const Command = union(enum) {
    help,
    version,
    /// Everything after the program name, verbatim.
    run: []const []const u8,
};

pub const usage =
    \\usage: ziggurat [--help|--version] [args...]
    \\
    \\  --help, -h      print this text and exit
    \\  --version, -V   print the version and exit
    \\
;

pub fn parse(args: []const []const u8) Command {
    // args[0] is the program name; skip it.
    const rest = if (args.len > 0) args[1..] else args;
    if (rest.len == 0) return .{ .run = rest };
    if (std.mem.eql(u8, rest[0], "--help") or std.mem.eql(u8, rest[0], "-h")) return .help;
    if (std.mem.eql(u8, rest[0], "--version") or std.mem.eql(u8, rest[0], "-V")) return .version;
    return .{ .run = rest };
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
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const out = &stdout_file_writer.interface;

    switch (parse(args)) {
        .help => try printHelp(out),
        .version => try out.print("ziggurat {s} (librats {s})\n", .{ build_options.version, libratsVersion().text }),
        // The placeholder: replace with the real work. Arguments arrive here
        // untouched so this switch never has to grow per-flag.
        .run => |rest| try out.print("ziggurat: {d} argument(s)\n", .{rest.len}),
    }
    try out.flush();
}

test "parse: no arguments is a run with none" {
    const cmd = parse(&.{"ziggurat"});
    try std.testing.expectEqual(@as(usize, 0), cmd.run.len);
}

test "parse: flags only count in the first position" {
    try std.testing.expect(parse(&.{ "ziggurat", "--help" }) == .help);
    try std.testing.expect(parse(&.{ "ziggurat", "-V" }) == .version);
    // A later `--help` is an argument to the program, not a request for help.
    try std.testing.expectEqualStrings("--help", parse(&.{ "ziggurat", "x", "--help" }).run[1]);
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
