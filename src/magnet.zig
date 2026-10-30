const std = @import("std");

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
pub fn shortId(magnet: []const u8) []const u8 {
    const hash = infoHash(magnet) orelse return "?";
    return hash[0..@min(hash.len, 8)];
}

/// The eight-character label doubles as the mount directory name: it is unique
/// per release, needs no sanitizing, and is what the user sees in the history.
pub fn mountName(magnet: []const u8, buf: []u8) []const u8 {
    const hash = infoHash(magnet) orelse return "release";
    const n = @min(hash.len, 8);
    for (hash[0..n], 0..) |ch, i| buf[i] = std.ascii.toLower(ch);
    return buf[0..n];
}

const media_extensions = [_][]const u8{
    // video
    "mkv", "mp4", "m4v", "avi", "mov",  "webm", "ts",   "m2ts", "mpg",  "mpeg",
    "flv", "wmv", "ogv", "vob", "3gp",
    // audio
     "mp3",  "flac", "ogg",  "opus", "m4a",
    "aac", "wav", "wv",  "ape", "alac",
};

pub fn isMedia(path: []const u8) bool {
    const ext = std.fs.path.extension(path);
    if (ext.len < 2) return false;
    const bare = ext[1..];
    for (media_extensions) |known| {
        if (std.ascii.eqlIgnoreCase(bare, known)) return true;
    }
    return false;
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

test "magnet: only playable files are media" {
    try testing.expect(isMedia("release/CD1/track.MKV"));
    try testing.expect(isMedia("a.flac"));
    try testing.expect(!isMedia("release/cover.jpg"));
    try testing.expect(!isMedia("release/notes.txt"));
    try testing.expect(!isMedia("noext"));
}
