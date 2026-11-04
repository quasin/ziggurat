//! The RuTracker.Org dump (`rutracker-YYYYMMDD.xml`) as a searchable list.
//!
//! The file is tens of gigabytes, so nothing is loaded: a worker thread streams
//! it in megabyte chunks, splits it into `<torrent …>…</torrent>` records and
//! keeps the titles that match the query. The screen polls that worker instead
//! of waiting for it, and a new query cancels the one in flight.
//!
//! The dump is written by the tracked user, not by us: one record per release,
//! with the attributes this module reads
//!
//!     <torrent id="…" registred_at="2024.03.12 20:11:00" size="…">
//!      <title><![CDATA[…]]></title>
//!      <torrent hash="…" tracker_id="4"/>
//!      <forum id="…">…</forum>
//!      <content><![CDATA[…]]></content>
//!     </torrent>
//!
//! A record whose parts do not parse is skipped rather than aborting the scan:
//! a 5-million-record file has room for a few odd ones, and stopping there
//! would hide everything after them.
const std = @import("std");

/// Where a scan stops. A dump with 5.7 million releases answers a common word
/// with thousands of hits; the panel can show a screen full, and scanning the
/// remaining gigabytes to grow that list only delays the answer.
pub const max_results: usize = 300;

/// A release title is clipped here before it is stored: the panel truncates it
/// to its width anyway, and a title longer than this is a release description
/// pasted into the wrong field.
pub const max_title: usize = 160;

/// How much of a single record the buffer keeps before giving up on it. Content
/// blocks are large (a release description can be tens of kilobytes) but not
/// this large; a record that never closes means the file is not a dump.
const max_record: usize = 16 << 20;

/// The read size of the scanner. One megabyte is a few milliseconds from the
/// page cache and keeps the cancel latency small.
const chunk_size: usize = 1 << 20;

/// The section of the dump a release lives in, kept inside the result: the row
/// prints it, and a second heap allocation per match is what makes a 300-hit
/// scan cost 600 frees. Long forum names are clipped anyway.
pub const max_forum: usize = 96;

/// The registration date as `YYYY.MM.DD`. The dump writes it with the time of
/// day (`2024-03-12 20:11:00`), which the row has no columns for: the date
/// alone is what tells a fresh release from an old one at a glance.
pub const max_date: usize = 10;

pub const Result = struct {
    title: []u8,
    hash: [64]u8 = undefined,
    hash_len: u8 = 0,
    forum: [max_forum]u8 = undefined,
    forum_len: u8 = 0,
    date: [max_date]u8 = undefined,
    date_len: u8 = 0,
    /// The `<torrent id="…">` of the record: the topic number its page on the
    /// tracker is addressed by. Zero when the dump recorded none.
    topic_id: u32 = 0,
    tracker_id: u32 = 1,
    size: u64 = 0,

    pub fn hashText(self: *const Result) []const u8 {
        return self.hash[0..self.hash_len];
    }

    pub fn forumText(self: *const Result) []const u8 {
        return self.forum[0..self.forum_len];
    }

    /// Empty for a record the dump wrote without a date; the row then starts
    /// with the section, as it did before.
    pub fn dateText(self: *const Result) []const u8 {
        return self.date[0..self.date_len];
    }

    /// The magnet link the row stands for: the info-hash and the tracker the
    /// dump names, so a release found here can be mounted straight away.
    pub fn magnet(self: *const Result, buf: []u8) ?[]const u8 {
        return std.fmt.bufPrint(buf, "magnet:?xt=urn:btih:{s}&tr=http://bt{d}.t-ru.org/ann?magnet", .{
            self.hashText(), self.tracker_id,
        }) catch null;
    }

    /// The release's page on the tracker, for a row that has an id to build it
    /// from. The scheme is left out: `https://` is eight columns the first line
    /// cannot spare, and a browser puts it back on a pasted address.
    pub fn link(self: *const Result, buf: []u8) ?[]const u8 {
        if (self.topic_id == 0) return null;
        return std.fmt.bufPrint(buf, "rutracker.org/forum/viewtopic.php?t={d}", .{self.topic_id}) catch null;
    }

    /// The link cut down to the topic number, for a panel too narrow to hold
    /// the whole address: `t=6499008` still names the page.
    pub fn linkTag(self: *const Result, buf: []u8) ?[]const u8 {
        if (self.topic_id == 0) return null;
        return std.fmt.bufPrint(buf, "t={d}", .{self.topic_id}) catch null;
    }
};

/// What a scan reports when it is over. `running` is not part of it because the
/// UI asks the atomics for that: the outcome is written once, a frame at a time.
pub const Outcome = enum(u8) { none = 0, done = 1, failed = 2, stopped = 3 };

pub const Engine = struct {
    allocator: std.mem.Allocator,
    /// Guards `results`. The worker appends a result at a time; the screen
    /// holds it only while it copies a row out, never while it draws.
    mutex: std.atomic.Mutex = .unlocked,
    results: std.ArrayList(Result) = .empty,
    /// The folded query, owned here so the worker can outlive the caller's
    /// buffer. Written before the thread starts, read by it afterwards.
    query: std.ArrayList(u8) = .empty,

    scanned: std.atomic.Value(u64) = .init(0),
    total: std.atomic.Value(u64) = .init(0),
    found: std.atomic.Value(u64) = .init(0),
    running: std.atomic.Value(bool) = .init(false),
    cancel: std.atomic.Value(bool) = .init(false),
    outcome: std.atomic.Value(u8) = .init(@backingInt(Outcome.none)),

    thread: ?std.Thread = null,

    pub fn init(allocator: std.mem.Allocator) Engine {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Engine) void {
        self.stop();
        self.clearResults();
        self.results.deinit(self.allocator);
        self.query.deinit(self.allocator);
    }

    /// Stops the scan in flight, if any, and waits for the thread: the engine's
    /// buffers must not be freed under a worker still writing into them.
    pub fn stop(self: *Engine) void {
        self.cancel.store(true, .monotonic);
        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }
        self.running.store(false, .release);
    }

    pub fn clearResults(self: *Engine) void {
        self.lock();
        defer self.mutex.unlock();
        for (self.results.items) |result| self.allocator.free(result.title);
        self.results.clearRetainingCapacity();
    }

    /// Starts a scan of `path` for `text`. `total` is the file size, for the
    /// progress line; `path` must outlive the scan (the app's own copy).
    pub fn start(self: *Engine, path: []const u8, text: []const u8, total: u64) !void {
        self.stop();
        self.cancel.store(false, .monotonic);
        self.clearResults();

        self.query.clearRetainingCapacity();
        var folded: [1024]u8 = undefined;
        try self.query.appendSlice(self.allocator, fold(&folded, text));

        self.found.store(0, .monotonic);
        self.scanned.store(0, .monotonic);
        self.total.store(total, .monotonic);
        self.outcome.store(@backingInt(Outcome.none), .monotonic);
        self.running.store(true, .release);

        self.thread = try std.Thread.spawn(.{}, worker, .{ self, path });
    }

    fn lock(self: *Engine) void {
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
    }

    /// Copies one result out for the screen, or null when the list is shorter
    /// than that. Taken under the lock so the title slice stays valid while the
    /// caller builds the link.
    pub fn resultAt(self: *Engine, index: usize, out: *Result) bool {
        self.lock();
        defer self.mutex.unlock();
        if (index >= self.results.items.len) return false;
        out.* = self.results.items[index];
        return true;
    }

    fn worker(self: *Engine, path: []const u8) void {
        var stopped = false;
        self.scanFile(path) catch {
            self.outcome.store(@backingInt(Outcome.failed), .release);
            self.running.store(false, .release);
            return;
        };
        // A scan that returned without being cancelled finished the file; one
        // that hit the result cap or the cancel flag is a partial answer, and
        // the panel says which.
        if (self.cancel.load(.monotonic)) {
            stopped = true;
        } else if (self.found.load(.monotonic) >= max_results) {
            stopped = true;
        }
        self.outcome.store(@backingInt(if (stopped) Outcome.stopped else Outcome.done), .release);
        self.running.store(false, .release);
    }

    fn scanFile(self: *Engine, path: []const u8) !void {
        const fd = try std.posix.openat(std.posix.AT.FDCWD, path, .{}, 0);
        defer _ = std.os.linux.close(fd);

        // The buffer grows across reads because a record straddles chunk
        // boundaries; it is trimmed after every processed record.
        var pending: std.ArrayList(u8) = .empty;
        defer pending.deinit(self.allocator);
        try pending.ensureTotalCapacity(self.allocator, chunk_size * 2);

        var chunk: [chunk_size]u8 = undefined;
        var scanned: u64 = 0;
        while (true) {
            if (self.cancel.load(.monotonic)) return;
            const n = try std.posix.read(fd, &chunk);
            if (n == 0) break;
            scanned += n;
            self.scanned.store(scanned, .monotonic);
            try consume(self, &pending, chunk[0..n]);
            if (self.found.load(.monotonic) >= max_results) return;
            if (pending.items.len > max_record) return error.RecordTooLong;
        }
        // A file whose last record has no closing tag is still worth the
        // matches already collected; nothing after it can be read anyway.
    }

    /// Appends the matches of every complete record in `pending`. Records are
    /// consumed from the front, and an incomplete tail is kept for the next
    /// read. Split out of `scanFile` so the parser is testable on bytes.
    fn consume(self: *Engine, pending: *std.ArrayList(u8), chunk: []const u8) !void {
        try pending.appendSlice(self.allocator, chunk);
        try consumeRecords(self, pending);
    }

    fn consumeRecords(self: *Engine, pending: *std.ArrayList(u8)) !void {
        var used: usize = 0;
        while (true) {
            if (self.found.load(.monotonic) >= max_results) break;
            const rest = pending.items[used..];
            const open_at = std.mem.indexOf(u8, rest, "<torrent ") orelse break;
            const record_start = used + open_at;
            const end = recordEnd(pending.items, record_start + 1) orelse break;
            try self.consider(pending.items[record_start..end]);
            used = end;
        }

        // Keep only what may still turn into a record: a partial opening tag or
        // a record whose closing tag has not arrived yet.
        if (used > 0) {
            const left = pending.items.len - used;
            std.mem.copyForwards(u8, pending.items[0..left], pending.items[used..]);
            pending.shrinkRetainingCapacity(left);
        }
        if (std.mem.indexOf(u8, pending.items, "<torrent ") == null) {
            // No opening tag in the buffer: keep only the tail that could be
            // the first half of one split by the chunk boundary, and drop the
            // content of records that were already consumed.
            const want = "<torrent ";
            var keep: usize = 0;
            var k: usize = 1;
            while (k < want.len and k <= pending.items.len) : (k += 1) {
                if (std.mem.eql(u8, pending.items[pending.items.len - k ..], want[0..k])) keep = k;
            }
            const drop = pending.items.len - keep;
            if (drop > 0) {
                std.mem.copyForwards(u8, pending.items[0..keep], pending.items[pending.items.len - keep ..]);
                pending.shrinkRetainingCapacity(keep);
            }
        }
    }

    fn consider(self: *Engine, block: []const u8) !void {
        const parsed = parseRecord(block) orelse return;
        var folded: [1024]u8 = undefined;
        if (!self.matches(parsed.title, parsed.hash, &folded)) return;

        const copy = try self.allocator.dupe(u8, clipTitle(parsed.title));
        errdefer self.allocator.free(copy);

        var result = Result{ .title = copy, .tracker_id = parsed.tracker_id, .topic_id = parsed.topic_id, .size = parsed.size };
        const hash_len = @min(parsed.hash.len, result.hash.len);
        @memcpy(result.hash[0..hash_len], parsed.hash[0..hash_len]);
        result.hash_len = @intCast(hash_len);
        const forum = storeClipped(&result.forum, parsed.forum);
        result.forum_len = @intCast(forum.len);
        const date = storeClipped(&result.date, parsed.date);
        result.date_len = @intCast(date.len);

        self.lock();
        defer self.mutex.unlock();
        try self.results.append(self.allocator, result);
        _ = self.found.fetchAdd(1, .monotonic);
    }

    fn matches(self: *const Engine, title: []const u8, hash: []const u8, buf: []u8) bool {
        const query = std.mem.trim(u8, self.query.items, " \t\r\n");
        if (query.len == 0) return false;
        // An info-hash pasted into the search line is a hash lookup, not a
        // substring of a title.
        if (query.len == hash.len and query.len >= 32) {
            return std.ascii.eqlIgnoreCase(query, hash);
        }
        // Words separated by spaces are independent parts of the title: every
        // one must occur, in any order, so `паттерн проект` finds both
        // «Паттерны проектирования» and «Проектирование на паттернах».
        const folded_title = fold(buf, title);
        var terms = std.mem.tokenizeAny(u8, query, " \t\r\n");
        var any = false;
        while (terms.next()) |term| {
            any = true;
            if (std.mem.indexOf(u8, folded_title, term) == null) return false;
        }
        return any;
    }
};

/// The end of the record that starts at `from`, as an index just past its
/// `</torrent>`. The search is a vectorized scan for `<`, which is the only
/// fast byte scan Zig's std offers in a Debug build: a multi-byte needle costs
/// a byte-at-a-time Boyer-Moore there, and that is the whole 30 GB scan.
fn recordEnd(buf: []const u8, from: usize) ?usize {
    var at = from;
    while (std.mem.indexOfScalarPos(u8, buf, at, '<')) |lt| {
        if (std.mem.startsWith(u8, buf[lt..], "</torrent>")) return lt + "</torrent>".len;
        at = lt + 1;
    }
    return null;
}

pub const Parsed = struct {
    title: []const u8,
    hash: []const u8,
    forum: []const u8 = "",
    /// `YYYY.MM.DD` from the record's `registred_at`, empty when the dump has
    /// none — an old or hand-made dump does not, and that is not a failure.
    date: []const u8 = "",
    /// The `<torrent id="…">` topic number, zero when the record has none.
    topic_id: u32 = 0,
    tracker_id: u32 = 1,
    size: u64 = 0,
};

/// The parts of one `<torrent …>…</torrent>` block this module needs. Null when
/// the block does not have them, which is how a malformed record is skipped.
pub fn parseRecord(block: []const u8) ?Parsed {
    const open_end = std.mem.indexOfScalar(u8, block, '>') orelse return null;
    const size_text = attrValue(block[0..open_end], "size") orelse return null;
    const size = std.fmt.parseInt(u64, size_text, 10) catch return null;

    const title_start = std.mem.indexOf(u8, block, "<title>") orelse return null;
    const title_end = std.mem.indexOfPos(u8, block, title_start, "</title>") orelse return null;
    var title = std.mem.trim(u8, block[title_start + "<title>".len .. title_end], " \t\r\n");
    if (std.mem.startsWith(u8, title, "<![CDATA[")) title = title["<![CDATA[".len..];
    if (std.mem.endsWith(u8, title, "]]>")) title = title[0 .. title.len - "]]>".len];
    if (title.len == 0) return null;

    // The hash is the inner `<torrent hash="…"/>`, never the outer element:
    // only the part after the opening tag is searched.
    const hash_at = std.mem.indexOfPos(u8, block, open_end, "<torrent hash=\"") orelse return null;
    const hash_start = hash_at + "<torrent hash=\"".len;
    const hash_end = std.mem.indexOfScalarPos(u8, block, hash_start, '"') orelse return null;
    const hash = block[hash_start..hash_end];
    if (hash.len == 0 or hash.len > 64) return null;

    const tracker_id = if (attrValue(block[open_end..], "tracker_id")) |text|
        std.fmt.parseInt(u32, text, 10) catch 1
    else
        1;

    // The topic number the release's page is addressed by. A record without
    // one is still a result: it just cannot offer the link.
    const topic_id = if (attrValue(block[0..open_end], "id")) |text|
        std.fmt.parseInt(u32, text, 10) catch 0
    else
        0;

    // The section is printed above the title, so a record without one is still
    // a result: it just shows an empty first line. The date is printed in front
    // of the section and is just as optional.
    const forum = forumText(block) orelse "";
    const date = dateText(block[0..open_end]);

    return .{ .title = title, .hash = hash, .forum = forum, .date = date, .topic_id = topic_id, .tracker_id = tracker_id, .size = size };
}

/// The day `<torrent registred_at="2024.03.12 20:11:00">` was registered, with
/// the time of day dropped: the row can afford ten columns for a date and not
/// nineteen, and a dump without the attribute yields an empty slice.
fn dateText(tag: []const u8) []const u8 {
    const text = attrValue(tag, "registred_at") orelse return "";
    const end = std.mem.indexOfScalar(u8, text, ' ') orelse text.len;
    return text[0..@min(end, max_date)];
}

/// The text of `<forum id="…">…</forum>`: the section of the dump the release
/// sits in. Null when the record has none, which is not a parse failure.
fn forumText(block: []const u8) ?[]const u8 {
    const open_at = std.mem.indexOf(u8, block, "<forum ") orelse return null;
    const open_end = std.mem.indexOfScalarPos(u8, block, open_at, '>') orelse return null;
    const close_at = std.mem.indexOfPos(u8, block, open_end, "</forum>") orelse return null;
    var text = std.mem.trim(u8, block[open_end + 1 .. close_at], " \t\r\n");
    if (std.mem.startsWith(u8, text, "<![CDATA[")) text = text["<![CDATA[".len..];
    if (std.mem.endsWith(u8, text, "]]>")) text = text[0 .. text.len - "]]>".len];
    return text;
}

/// Copies `text` into `dest`, clipping it at a UTF-8 boundary: the panel prints
/// these bytes, so a half character would corrupt the whole row.
fn storeClipped(dest: []u8, text: []const u8) []const u8 {
    const len = @min(text.len, dest.len);
    var end = len;
    if (len < text.len) {
        while (end > 0 and (text[end] & 0xc0) == 0x80) end -= 1;
    }
    @memcpy(dest[0..end], text[0..end]);
    return dest[0..end];
}

/// `name="value"` inside an attribute list. The quote is part of the marker so
/// a title containing `size=` in its CDATA cannot be mistaken for an attribute,
/// and the name must start a word: `id="` inside `tracker_id="` is a different
/// attribute, and the dump has both.
fn attrValue(tag: []const u8, name: []const u8) ?[]const u8 {
    var marker_buf: [24]u8 = undefined;
    const marker = std.fmt.bufPrint(&marker_buf, "{s}=\"", .{name}) catch return null;
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, tag, from, marker)) |at| {
        if (at == 0 or tag[at - 1] == '<' or std.ascii.isWhitespace(tag[at - 1])) {
            const rest = tag[at + marker.len ..];
            const end = std.mem.indexOfScalar(u8, rest, '"') orelse return null;
            return rest[0..end];
        }
        from = at + 1;
    }
    return null;
}

fn clipTitle(title: []const u8) []const u8 {
    if (title.len <= max_title) return title;
    var end = max_title;
    // Do not cut a UTF-8 sequence in half: the panel prints these bytes.
    while (end > 0 and (title[end] & 0xc0) == 0x80) end -= 1;
    return title[0..end];
}

/// Lowercases what the dump and the keyboard contain: ASCII and the Russian
/// block of Cyrillic. Everything else is copied unchanged, which only makes the
/// search stricter, never wrong.
pub fn fold(buf: []u8, text: []const u8) []const u8 {
    var n: usize = 0;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        const byte = text[i];
        if (n + 2 > buf.len) break;
        if (byte < 0x80) {
            buf[n] = std.ascii.toLower(byte);
            n += 1;
            continue;
        }
        if (i + 1 >= text.len) break;
        const next = text[i + 1];
        // А-Я (U+0410..U+042F, D0 90..D0 AF) → а-я (U+0430..U+044F).
        if (byte == 0xd0 and next >= 0x90 and next <= 0xaf) {
            const offset = next - 0x90;
            if (offset < 16) {
                buf[n] = 0xd0;
                buf[n + 1] = 0xb0 + offset;
            } else {
                buf[n] = 0xd1;
                buf[n + 1] = 0x80 + (offset - 16);
            }
            n += 2;
            i += 1;
            continue;
        }
        // Ё (U+0401, D0 81) → ё (U+0451, D1 91).
        if (byte == 0xd0 and next == 0x81) {
            buf[n] = 0xd1;
            buf[n + 1] = 0x91;
            n += 2;
            i += 1;
            continue;
        }
        buf[n] = byte;
        buf[n + 1] = next;
        n += 2;
        i += 1;
    }
    return buf[0..n];
}

const testing = std.testing;

test "rutracker: a record yields its title, hash, tracker and size" {
    const block =
        \\<torrent id="6499008" registred_at="2024.03.12 20:11:00" unixts="1710263460" size="498667923">
        \\ <title><![CDATA[[TR24][OF] Sferro & Tommy ‘86 - Remote Communications]]></title>
        \\ <torrent hash="3D9E3C0F6D25349D055D82CFA6401BEE3C9509B2" tracker_id="4"/>
        \\ <forum id="1893">Hi-Res форматы</forum>
        \\ <content><![CDATA[[size=24]Sferro[/size] size="not an attribute"]]></content>
        \\</torrent>
    ;
    const parsed = parseRecord(block).?;
    try testing.expectEqualStrings("[TR24][OF] Sferro & Tommy ‘86 - Remote Communications", parsed.title);
    try testing.expectEqualStrings("3D9E3C0F6D25349D055D82CFA6401BEE3C9509B2", parsed.hash);
    try testing.expectEqual(@as(u32, 4), parsed.tracker_id);
    try testing.expectEqual(@as(u32, 6499008), parsed.topic_id);
    try testing.expectEqual(@as(u64, 498667923), parsed.size);
    try testing.expectEqualStrings("Hi-Res форматы", parsed.forum);
    // The clock time is dropped: the row shows the date only.
    try testing.expectEqualStrings("2024.03.12", parsed.date);

    // A record missing the hash cannot be mounted, so it is not a result.
    const no_hash = "<torrent id=\"1\" size=\"2\">\n<title>x</title>\n</torrent>";
    try testing.expect(parseRecord(no_hash) == null);
}

test "rutracker: a record without a date still parses, with an empty date" {
    const block = "<torrent id=\"1\" size=\"2\">\n<title>x</title>\n" ++
        "<torrent hash=\"AABB\" tracker_id=\"1\"/>\n</torrent>";
    const parsed = parseRecord(block).?;
    try testing.expectEqualStrings("", parsed.date);

    // A date attr in the right shape but without its time of day is taken whole
    // rather than cut at a space that is not there.
    const bare = parseRecord("<torrent id=\"1\" registred_at=\"2024.03.12\" size=\"2\">\n<title>x</title>\n" ++
        "<torrent hash=\"AABB\" tracker_id=\"1\"/>\n</torrent>").?;
    try testing.expectEqualStrings("2024.03.12", bare.date);
}

test "rutracker: the topic id builds the release's page link" {
    var result = Result{ .title = @constCast("x"), .topic_id = 6499008 };
    var buf: [96]u8 = undefined;
    try testing.expectEqualStrings(
        "rutracker.org/forum/viewtopic.php?t=6499008",
        result.link(&buf).?,
    );
    var tag_buf: [24]u8 = undefined;
    try testing.expectEqualStrings("t=6499008", result.linkTag(&tag_buf).?);

    // A record without an id offers neither form.
    result.topic_id = 0;
    try testing.expect(result.link(&buf) == null);
    try testing.expect(result.linkTag(&tag_buf) == null);
}

test "rutracker: an attribute name must start a word" {
    // `id="` occurs inside `tracker_id="`; the topic number is the other one.
    try testing.expectEqualStrings("42", attrValue("<torrent tracker_id=\"9\" id=\"42\"", "id").?);
    try testing.expectEqualStrings("9", attrValue("<torrent tracker_id=\"9\" id=\"42\"", "tracker_id").?);
}

test "rutracker: the folded query matches Russian titles in either case" {
    var buf: [1024]u8 = undefined;
    const title = fold(&buf, "[Музыка] ПАТТЕРНЫ проектирования");
    try testing.expectEqualStrings("[музыка] паттерны проектирования", title);

    var query: [64]u8 = undefined;
    try testing.expectEqualStrings("паттерны", fold(&query, "ПАТТЕРНЫ"));
    try testing.expect(std.mem.indexOf(u8, title, fold(&query, "ПАТТЕРНЫ")) != null);

    // Latin text keeps its spaces and punctuation.
    var ascii: [32]u8 = undefined;
    try testing.expectEqualStrings("sferro & tommy", fold(&ascii, "Sferro & Tommy"));
}

test "rutracker: space-separated words match anywhere in the title" {
    const a = testing.allocator;
    var engine = Engine.init(a);
    defer engine.deinit();

    try engine.query.appendSlice(a, " паттерн   проект ");
    var buf: [1024]u8 = undefined;

    // Both words are parts of longer words, in either order.
    try testing.expect(engine.matches("ПАТТЕРНЫ проектирования", "AABB", &buf));
    try testing.expect(engine.matches("Проектирование на паттернах", "AABB", &buf));
    // One missing word is enough to reject the record.
    try testing.expect(!engine.matches("Паттерны без второго слова", "AABB", &buf));
    // A single word stays a plain substring search. The query is folded by
    // `start` before `matches` ever sees it, so this line stores it folded.
    engine.query.clearRetainingCapacity();
    try engine.query.appendSlice(a, "паттерны");
    try testing.expect(engine.matches("Паттерны проектирования", "AABB", &buf));
}

test "rutracker: the result builds the magnet the view mounts" {
    var result = Result{ .title = @constCast("x") };
    const hash = "3D9E3C0F6D25349D055D82CFA6401BEE3C9509B2";
    @memcpy(result.hash[0..hash.len], hash);
    result.hash_len = hash.len;
    result.tracker_id = 4;

    var buf: [160]u8 = undefined;
    try testing.expectEqualStrings(
        "magnet:?xt=urn:btih:3D9E3C0F6D25349D055D82CFA6401BEE3C9509B2&tr=http://bt4.t-ru.org/ann?magnet",
        result.magnet(&buf).?,
    );
}

test "rutracker: the scanner keeps every complete record across chunk edges" {
    const a = testing.allocator;
    var engine = Engine.init(a);
    defer engine.deinit();

    engine.query.clearRetainingCapacity();
    try engine.query.appendSlice(a, "needle");

    var pending: std.ArrayList(u8) = .empty;
    defer pending.deinit(a);
    try pending.ensureTotalCapacity(a, 512);

    const first = "<torrent id=\"1\" registred_at=\"2024.03.12 20:11:00\" size=\"10\">\n<title>needle one</title>\n<torrent hash=\"" ++
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" ++ "\" tracker_id=\"1\"/>\n</torrent>";
    const second = "<torrent id=\"2\" size=\"20\">\n<title>other</title>\n<torrent hash=\"" ++
        "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB" ++ "\" tracker_id=\"1\"/>\n</torrent>";

    // Split the first record in the middle, exactly like a read boundary.
    const cut = first.len / 2;
    try engine.consume(&pending, first[0..cut]);
    try testing.expectEqual(@as(u64, 0), engine.found.load(.monotonic));
    try engine.consume(&pending, first[cut..]);
    try engine.consume(&pending, second);
    try testing.expectEqual(@as(u64, 1), engine.found.load(.monotonic));

    var result: Result = undefined;
    try testing.expect(engine.resultAt(0, &result));
    try testing.expectEqualStrings("needle one", result.title);
    try testing.expectEqual(@as(u64, 10), result.size);
    try testing.expectEqualStrings("2024.03.12", result.dateText());
    try testing.expect(!engine.resultAt(1, &result));
}
