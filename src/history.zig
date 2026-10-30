const std = @import("std");
const Io = std.Io;

/// One line of the history: what the user typed, where it is mounted and what
/// the release is called. Runtime state (is it mounted, how long it has been
/// mounting) is deliberately not here — it is a fact about this session, while
/// the file only remembers what survives a restart.
pub const Entry = struct {
    magnet: []const u8,
    mount: []const u8,
    title: []const u8,
};

pub const List = struct {
    items: std.ArrayList(Entry),
    arena: std.heap.ArenaAllocator,

    pub fn init(allocator: std.mem.Allocator) List {
        return .{
            .items = .empty,
            .arena = std.heap.ArenaAllocator.init(allocator),
        };
    }

    pub fn deinit(self: *List) void {
        self.arena.deinit();
        self.items.deinit(self.arena.child_allocator);
    }

    /// Where a magnet already is, or null. The caller keeps its own parallel
    /// state in the same order, so this is the only place that decides whether
    /// a typed link is a new row or an old one moved up.
    pub fn findIndex(self: *const List, magnet: []const u8) ?usize {
        for (self.items.items, 0..) |entry, i| {
            if (std.mem.eql(u8, entry.magnet, magnet)) return i;
        }
        return null;
    }

    /// Newest first. A repeat of a magnet is moved, not duplicated: the mount
    /// directory is derived from the info-hash, so two rows would fight over
    /// one mountpoint.
    pub fn insertTop(self: *List, magnet: []const u8, mount: []const u8, title: []const u8) !void {
        const a = self.arena.allocator();
        try self.items.insert(self.arena.child_allocator, 0, .{
            .magnet = try a.dupe(u8, magnet),
            .mount = try a.dupe(u8, mount),
            .title = try a.dupe(u8, title),
        });
    }

    /// Moves an existing row to the front without touching its strings.
    pub fn moveToTop(self: *List, index: usize) void {
        if (index >= self.items.items.len or index == 0) return;
        const moved = self.items.orderedRemove(index);
        self.items.insert(self.arena.child_allocator, 0, moved) catch {
            // Put it back rather than lose the row; out of memory here is not
            // worth a crash in the middle of a keypress.
            self.items.append(self.arena.child_allocator, moved) catch {};
        };
    }

    pub fn removeAt(self: *List, index: usize) void {
        if (index < self.items.items.len) _ = self.items.orderedRemove(index);
    }

    /// Tab-separated, one entry per line. A title with a tab or a newline in it
    /// would break the columns on the next load, so the separators are folded
    /// into spaces on the way out.
    pub fn save(self: *List, io: Io, path: []const u8) !void {
        const a = self.arena.child_allocator;
        var allocating: std.Io.Writer.Allocating = .init(a);
        defer allocating.deinit();
        const w = &allocating.writer;

        for (self.items.items) |entry| {
            try writeField(w, entry.magnet);
            try w.writeByte('\t');
            try writeField(w, entry.mount);
            try w.writeByte('\t');
            try writeField(w, entry.title);
            try w.writeByte('\n');
        }

        if (std.fs.path.dirname(path)) |dir| {
            if (dir.len > 0) std.Io.Dir.cwd().createDirPath(io, dir) catch {};
        }
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = allocating.written() });
    }

    /// A missing or unreadable history is an empty history: the TUI has nothing
    /// worth failing over, and a first run has no file at all.
    pub fn load(self: *List, io: Io, path: []const u8) !void {
        const data = std.Io.Dir.cwd().readFileAlloc(io, path, self.arena.allocator(), .limited(1 << 20)) catch return;
        var lines = std.mem.splitScalar(u8, data, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            var fields = std.mem.splitScalar(u8, line, '\t');
            const magnet = fields.next() orelse continue;
            const mount = fields.next() orelse continue;
            if (magnet.len == 0 or mount.len == 0) continue;
            const title = fields.next() orelse "";
            if (self.findIndex(magnet) == null) try self.insertTop(magnet, mount, title);
        }
    }
};

fn writeField(w: anytype, s: []const u8) !void {
    for (s) |ch| {
        try w.writeByte(switch (ch) {
            '\t', '\n', '\r' => ' ',
            else => ch,
        });
    }
}

const testing = std.testing;

test "history: a repeat moves up instead of duplicating" {
    var list = List.init(testing.allocator);
    defer list.deinit();

    try list.insertTop("magnet:?xt=urn:btih:aaa", "mnt/aaa", "one");
    try list.insertTop("magnet:?xt=urn:btih:bbb", "mnt/bbb", "two");
    const at = list.findIndex("magnet:?xt=urn:btih:aaa").?;
    list.moveToTop(at);

    try testing.expectEqual(@as(usize, 2), list.items.items.len);
    try testing.expectEqualStrings("one", list.items.items[0].title);
    try testing.expectEqualStrings("two", list.items.items[1].title);
}

test "history: removeAt drops exactly one row" {
    var list = List.init(testing.allocator);
    defer list.deinit();
    try list.insertTop("m1", "p1", "t1");
    try list.insertTop("m2", "p2", "t2");
    list.removeAt(0);
    try testing.expectEqual(@as(usize, 1), list.items.items.len);
    try testing.expectEqualStrings("m1", list.items.items[0].magnet);
}
