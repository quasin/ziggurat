const std = @import("std");
const Io = std.Io;
const build_options = @import("build_options");

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

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const out = &stdout_file_writer.interface;

    switch (parse(args)) {
        .help => try out.writeAll(usage),
        .version => try out.print("ziggurat {s}\n", .{build_options.version}),
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
