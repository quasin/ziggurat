const std = @import("std");
const rats = @cImport({
    @cInclude("librats_c.h");
});

pub fn main() !void {
    const version = rats.rats_get_version_string();
    std.debug.print("Ziggurat program started.\n", .{});
    std.debug.print("Librats version: {s}\n", .{std.mem.span(version)});
}
