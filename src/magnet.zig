const std = @import("std");
const Io = std.Io;

/// A `.torrent` file is a source of its own: its metadata is in the file, so no
/// swarm is needed to browse the release. The row keeps it as `file:<path>` —
/// one string, so the history file needs no second column and a row says what
/// kind of source it is without a lookup.
pub const torrent_prefix = "file:";

pub fn isTorrent(source: []const u8) bool {
    return std.mem.startsWith(u8, source, torrent_prefix);
}

/// The path inside a `file:` source, borrowed from it.
pub fn torrentPath(source: []const u8) []const u8 {
    return source[torrent_prefix.len..];
}

/// A magnet link as the user typed it, normalized into the one form rekarma's
/// `--magnet` accepts. The forms users paste are all partial — a bare info
/// hash, an `xt=` fragment, an `urn:` — and refusing them sends the user back
/// to the shell that mangled the link, so every prefix is completed here.
pub fn normalize(allocator: std.mem.Allocator, raw: []const u8) !?[]u8 {
    const s = std.mem.trim(u8, raw, " \t\r\n");
    if (s.len == 0) return null;

    if (startsWithIgnoreCase(s, "magnet:?")) return @as(?[]u8, try allocator.dupe(u8, s));
    if (startsWithIgnoreCase(s, "magnet:")) return @as(?[]u8, try std.fmt.allocPrint(allocator, "magnet:?{s}", .{s["magnet:".len..]}));
    if (startsWithIgnoreCase(s, "xt=")) return @as(?[]u8, try std.fmt.allocPrint(allocator, "magnet:?{s}", .{s}));
    if (startsWithIgnoreCase(s, "urn:btih:")) return @as(?[]u8, try std.fmt.allocPrint(allocator, "magnet:?xt={s}", .{s}));

    // A bare info-hash: 40 hex (v1), 64 hex (v2) or 32 base32. Lowercased,
    // because the same release pasted in caps must land on the same mount dir.
    if (isInfoHash(s)) {
        var buf: [64]u8 = undefined;
        const n = @min(s.len, buf.len);
        for (s[0..n], 0..) |ch, i| buf[i] = std.ascii.toLower(ch);
        return @as(?[]u8, try std.fmt.allocPrint(allocator, "magnet:?xt=urn:btih:{s}", .{buf[0..n]}));
    }

    return null;
}

/// A `.torrent` file the user typed, as a `file:` source, or null when the text
/// is not one. The file is opened rather than guessed from the name alone so a
/// typo is refused here, in the foreground, instead of by rekarma later.
///
/// The path is stored as typed: ziggurat spawns the daemon from its own cwd, so
/// a relative path keeps meaning the same file, and the row stays readable.
pub fn torrentSource(allocator: std.mem.Allocator, io: Io, raw: []const u8) !?[]u8 {
    const s = std.mem.trim(u8, raw, " \t\r\n");
    if (s.len == 0) return null;

    const explicit = startsWithIgnoreCase(s, torrent_prefix);
    const path = if (explicit) s[torrent_prefix.len..] else s;
    if (path.len == 0) return null;
    // By its bare name only a .torrent is taken: any other file the user happens
    // to type would otherwise become a "release". `file:` accepts any name, for
    // a torrent saved without the extension.
    if (!explicit and !std.ascii.endsWithIgnoreCase(path, ".torrent")) return null;

    var file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return null;
    file.close(io);

    return try std.fmt.allocPrint(allocator, "{s}{s}", .{ torrent_prefix, path });
}

/// What the input line means, as the one string a history row stores: a magnet
/// link (in any of the forms `normalize` completes) or a `file:` source.
pub fn parse(allocator: std.mem.Allocator, io: Io, raw: []const u8) !?[]u8 {
    if (try normalize(allocator, raw)) |link| return link;
    return torrentSource(allocator, io, raw);
}

/// The info-hash inside a normalized link, borrowed from it. Used as the
/// directory name and as the row label, so it has to be stable and short.
pub fn infoHash(magnet: []const u8) ?[]const u8 {
    const marker = "urn:btih:";
    const at = indexOfIgnoreCase(magnet, marker) orelse return null;
    const start = at + marker.len;
    const rest = magnet[start..];
    const end = std.mem.indexOfAny(u8, rest, "&?#") orelse rest.len;
    if (end == 0) return null;
    return rest[0..end];
}

/// Eight characters identify a release in a list without eating the width a
/// title needs.
pub fn shortId(source: []const u8) []const u8 {
    // A .torrent has no info-hash in its name, and its file name is what the
    // user recognises it by anyway.
    if (isTorrent(source)) {
        const base = std.fs.path.basename(torrentPath(source));
        const stem = if (std.mem.lastIndexOfScalar(u8, base, '.')) |at| base[0..at] else base;
        return stem[0..@min(stem.len, 8)];
    }
    const hash = infoHash(source) orelse return "?";
    return hash[0..@min(hash.len, 8)];
}

/// The eight-character label doubles as the mount directory name: it is unique
/// per release, needs no sanitizing, and is what the user sees in the history.
pub fn mountName(source: []const u8, buf: []u8) []const u8 {
    // The info-hash of a .torrent is inside the file, which is rekarma's to
    // parse; a digest of the path is stable across restarts and distinct per
    // file, which is all the mount and cache directory names need to be.
    if (isTorrent(source)) {
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(source, &digest, .{});
        const digits = "0123456789abcdef";
        for (digest[0..4], 0..) |byte, i| {
            buf[i * 2] = digits[byte >> 4];
            buf[i * 2 + 1] = digits[byte & 0x0f];
        }
        return buf[0..8];
    }
    const hash = infoHash(source) orelse return "release";
    const n = @min(hash.len, 8);
    for (hash[0..n], 0..) |ch, i| buf[i] = std.ascii.toLower(ch);
    return buf[0..n];
}

fn isInfoHash(s: []const u8) bool {
    if (s.len == 40 or s.len == 64) {
        for (s) |ch| if (!std.ascii.isHex(ch)) return false;
        return true;
    }
    if (s.len == 32) {
        for (s) |ch| if (!std.ascii.isAlphanumeric(ch)) return false;
        return true;
    }
    return false;
}

fn startsWithIgnoreCase(s: []const u8, prefix: []const u8) bool {
    return s.len >= prefix.len and std.ascii.eqlIgnoreCase(s[0..prefix.len], prefix);
}

fn indexOfIgnoreCase(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len > haystack.len) return null;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return i;
    }
    return null;
}

const testing = std.testing;

test "magnet: every prefix users paste is completed" {
    const a = testing.allocator;
    const full = "magnet:?xt=urn:btih:81db4118adc4332d9d1cfff9d80667c4dfcf5848";
    const hash = "81db4118adc4332d9d1cfff9d80667c4dfcf5848";

    const cases = [_]struct { input: []const u8, want: []const u8 }{
        .{ .input = full, .want = full },
        .{ .input = hash, .want = full },
        .{ .input = "xt=urn:btih:81db4118adc4332d9d1cfff9d80667c4dfcf5848", .want = full },
        .{ .input = "urn:btih:81db4118adc4332d9d1cfff9d80667c4dfcf5848", .want = full },
        .{ .input = "  magnet:?xt=urn:btih:" ++ hash ++ "  ", .want = full },
        .{ .input = "81DB4118ADC4332D9D1CFFF9D80667C4DFCF5848", .want = full },
    };
    for (cases) |case| {
        const got = (try normalize(a, case.input)).?;
        defer a.free(got);
        try testing.expectEqualStrings(case.want, got);
    }
}

test "magnet: what is not a magnet is refused" {
    const a = testing.allocator;
    try testing.expect((try normalize(a, "")) == null);
    try testing.expect((try normalize(a, "hello")) == null);
    try testing.expect((try normalize(a, "https://example.com/x")) == null);
    try testing.expect((try normalize(a, "81db4118")) == null);
}

test "magnet: the info-hash is readable for the label and the mount dir" {
    const link = "magnet:?xt=urn:btih:81DB4118ADC4332D9D1CFFF9D80667C4DFCF5848&dn=release";
    try testing.expectEqualStrings("81DB4118ADC4332D9D1CFFF9D80667C4DFCF5848", infoHash(link).?);
    try testing.expectEqualStrings("81DB4118", shortId(link));
    var buf: [16]u8 = undefined;
    try testing.expectEqualStrings("81db4118", mountName(link, &buf));
}

test "magnet: a .torrent file becomes a file: source, and only a real one" {
    const a = testing.allocator;
    const io = std.testing.io;

    // Missing files and ordinary files are refused by their bare name, so a
    // stray path never turns into a "release"; `file:` is the explicit form.
    try testing.expect((try torrentSource(a, io, "no-such-release.torrent")) == null);
    try testing.expect((try torrentSource(a, io, "src/magnet.zig")) == null);

    const source = (try torrentSource(a, io, "file:src/magnet.zig")).?;
    defer a.free(source);
    try testing.expectEqualStrings("file:src/magnet.zig", source);
    try testing.expect(isTorrent(source));
    try testing.expectEqualStrings("src/magnet.zig", torrentPath(source));

    // The row label is the file name; the mount directory is a digest of the
    // path, stable across restarts and distinct per file.
    try testing.expectEqualStrings("magnet", shortId(source));
    var buf: [16]u8 = undefined;
    const dir = mountName(source, &buf);
    try testing.expectEqual(@as(usize, 8), dir.len);
    try testing.expectEqualStrings(dir, mountName(source, &buf));
}

test "magnet: the input line takes a link or a .torrent, nothing else" {
    const a = testing.allocator;
    const io = std.testing.io;

    const link = (try parse(a, io, "81db4118adc4332d9d1cfff9d80667c4dfcf5848")).?;
    defer a.free(link);
    try testing.expectEqualStrings("magnet:?xt=urn:btih:81db4118adc4332d9d1cfff9d80667c4dfcf5848", link);

    const torrent = (try parse(a, io, "file:src/magnet.zig")).?;
    defer a.free(torrent);
    try testing.expectEqualStrings("file:src/magnet.zig", torrent);

    try testing.expect((try parse(a, io, "hello")) == null);
}
