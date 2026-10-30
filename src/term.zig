//! Terminal plumbing: raw mode, key decoding and a frame buffer that turns
//! cursor moves and styled text into one write. Nothing here knows what the
//! screens look like — that is `tui.zig`.
const std = @import("std");
const Io = std.Io;
const posix = std.posix;
const linux = std.os.linux;

/// asm-generic/ioctls.h: Zig's std has no name for it, and the query is a
/// single ioctl away from a hardcoded 80x24.
const TIOCGWINSZ: u32 = 0x5413;

/// VMIN/VTIME live at these indexes in the Linux termios control-character
/// array; there are no named constants for them in std either.
const VTIME = 5;
const VMIN = 6;

pub const Size = struct { rows: u16 = 24, cols: u16 = 80 };

pub fn size() Size {
    var ws: posix.winsize = .{ .row = 0, .col = 0, .xpixel = 0, .ypixel = 0 };
    const rc = linux.ioctl(posix.STDOUT_FILENO, TIOCGWINSZ, @intFromPtr(&ws));
    if (linux.errno(rc) != .SUCCESS or ws.row == 0 or ws.col == 0) return .{};
    return .{ .rows = ws.row, .cols = ws.col };
}

/// Termios through the syscall, never through `std.posix`.
///
/// This binary links libc, and `std.posix.tcgetattr` then calls glibc's
/// `tcgetattr`, which writes glibc's `struct termios` — 60 bytes, `NCCS` 32 —
/// into Zig's 44-byte `linux.termios` (`NCCS` 19). The extra 16 bytes land on
/// the caller's stack frame: in Debug that is silent corruption, in ReleaseSafe
/// it is `__chk_fail` → `@trap()` → SIGILL at startup, with no stack trace.
/// The kernel ABI is the 44-byte one, so the raw call is the correct one.
fn tcgetattr(fd: posix.fd_t) !linux.termios {
    while (true) {
        var term: linux.termios = undefined;
        switch (linux.errno(linux.tcgetattr(fd, &term))) {
            .SUCCESS => return term,
            .INTR => continue,
            .BADF, .NOTTY, .INVAL => return error.NotATerminal,
            else => return error.Unexpected,
        }
    }
}

fn tcsetattr(fd: posix.fd_t, action: linux.TCSA, term: linux.termios) !void {
    while (true) {
        switch (linux.errno(linux.tcsetattr(fd, action, &term))) {
            .SUCCESS => return,
            .INTR => continue,
            .BADF, .NOTTY, .INVAL => return error.NotATerminal,
            else => return error.Unexpected,
        }
    }
}

/// Whether a file descriptor is a terminal. Same reason as above for not
/// asking `std.posix`.
pub fn isTerminal(fd: posix.fd_t) bool {
    _ = tcgetattr(fd) catch return false;
    return true;
}

/// Raw mode for the lifetime of the guard. Signals are left off so Ctrl-C
/// arrives as a keypress the TUI can answer with an orderly shutdown, which is
/// what restores the terminal.
pub const Raw = struct {
    saved: linux.termios,

    pub fn enter() !Raw {
        const saved = try tcgetattr(posix.STDIN_FILENO);
        var raw = saved;
        raw.lflag.ICANON = false;
        raw.lflag.ECHO = false;
        raw.lflag.ISIG = false;
        raw.iflag.IXON = false;
        raw.iflag.ICRNL = false;
        raw.cc[VMIN] = 1;
        raw.cc[VTIME] = 0;
        try tcsetattr(posix.STDIN_FILENO, .NOW, raw);
        return .{ .saved = saved };
    }

    pub fn leave(self: *const Raw) void {
        tcsetattr(posix.STDIN_FILENO, .NOW, self.saved) catch {};
    }
};

pub const Key = union(enum) {
    /// Bytes to insert into the input line (one UTF-8 codepoint).
    text: []const u8,
    enter,
    backspace,
    delete,
    up,
    down,
    left,
    right,
    home,
    end,
    tab,
    esc,
    ctrl_c,
    ctrl_d,
    ctrl_l,
    ctrl_u,
};

/// Key reader with a small pending buffer, so a pasted burst arrives as many
/// keys instead of the first one and a dropped tail.
pub const Input = struct {
    pending: [1024]u8 = undefined,
    len: usize = 0,
    scratch: [4]u8 = undefined,

    pub fn next(self: *Input, timeout_ms: i32) !?Key {
        if (self.decode()) |key| return key;

        var fds = [_]posix.pollfd{.{ .fd = posix.STDIN_FILENO, .events = posix.POLL.IN, .revents = 0 }};
        const ready = try posix.poll(&fds, timeout_ms);
        if (ready == 0) return null;
        if (fds[0].revents & (posix.POLL.HUP | posix.POLL.ERR) != 0) return .ctrl_d;

        const got = try posix.read(posix.STDIN_FILENO, self.pending[self.len..]);
        if (got == 0) return .ctrl_d;
        self.len += got;
        return self.decode();
    }

    fn decode(self: *Input) ?Key {
        if (self.len == 0) return null;
        const b = self.pending[0];

        // A lone ESC is the Esc key; with more bytes it opens an escape
        // sequence, which is consumed whole or dropped rather than stalling.
        if (b == 0x1b) {
            if (self.len == 1) {
                self.consume(1);
                return .esc;
            }
            if (self.pending[1] != '[') {
                self.consume(2);
                return .esc;
            }
            var i: usize = 2;
            while (i < self.len) : (i += 1) {
                if (self.pending[i] >= 0x40 and self.pending[i] <= 0x7e) {
                    const final = self.pending[i];
                    const params = self.pending[2..i];
                    const key: Key = switch (final) {
                        'A' => .up,
                        'B' => .down,
                        'C' => .right,
                        'D' => .left,
                        'H' => .home,
                        'F' => .end,
                        '~' => self.tildeKey(params) orelse .esc,
                        else => .esc,
                    };
                    self.consume(i + 1);
                    return key;
                }
            }
            // An incomplete sequence: wait for the rest.
            return null;
        }

        switch (b) {
            '\r', '\n' => {
                self.consume(1);
                return .enter;
            },
            0x7f, 0x08 => {
                self.consume(1);
                return .backspace;
            },
            0x09 => {
                self.consume(1);
                return .tab;
            },
            0x03 => {
                self.consume(1);
                return .ctrl_c;
            },
            0x04 => {
                self.consume(1);
                return .ctrl_d;
            },
            0x0c => {
                self.consume(1);
                return .ctrl_l;
            },
            0x15 => {
                self.consume(1);
                return .ctrl_u;
            },
            else => {},
        }

        if (b < 0x80) {
            self.scratch[0] = b;
            self.consume(1);
            return .{ .text = self.scratch[0..1] };
        }

        const need = std.unicode.utf8ByteSequenceLength(b) catch {
            self.consume(1);
            return null;
        };
        if (self.len < need) return null;
        @memcpy(self.scratch[0..need], self.pending[0..need]);
        self.consume(need);
        return .{ .text = self.scratch[0..need] };
    }

    fn tildeKey(self: *Input, params: []const u8) ?Key {
        _ = self;
        if (params.len == 0) return null;
        return switch (params[0]) {
            '1', '7' => .home,
            '4', '8' => .end,
            '3' => .delete,
            else => null,
        };
    }

    fn consume(self: *Input, n: usize) void {
        const tail = self.len - n;
        std.mem.copyForwards(u8, self.pending[0..tail], self.pending[n..self.len]);
        self.len = tail;
    }
};

pub const Style = enum {
    plain,
    dim,
    bold,
    accent,
    title,
    border,
    ok,
    warn,
    err,
    selected,
    selected_dim,

    pub fn code(self: Style) []const u8 {
        return switch (self) {
            .plain => "",
            .dim => "\x1b[90m",
            .bold => "\x1b[1m",
            .accent => "\x1b[36m",
            .title => "\x1b[1;36m",
            .border => "\x1b[90m",
            .ok => "\x1b[32m",
            .warn => "\x1b[33m",
            .err => "\x1b[31m",
            .selected => "\x1b[7m",
            .selected_dim => "\x1b[7;90m",
        };
    }
};

const reset = "\x1b[0m";

/// One frame: cursor moves and clipped, styled text, flushed with a single
/// write. Rows and columns are 1-based and clipped to the terminal.
pub const Frame = struct {
    allocating: std.Io.Writer.Allocating,
    rows: u16,
    cols: u16,
    row: u16 = 1,
    col: u16 = 1,

    pub fn init(allocator: std.mem.Allocator, rows: u16, cols: u16) Frame {
        return .{ .allocating = .init(allocator), .rows = rows, .cols = cols };
    }

    pub fn deinit(self: *Frame) void {
        self.allocating.deinit();
    }

    pub fn bytes(self: *Frame) []const u8 {
        return self.allocating.written();
    }

    pub fn at(self: *Frame, row: u16, col: u16) void {
        self.row = std.math.clamp(row, 1, @max(self.rows, 1));
        self.col = std.math.clamp(col, 1, @max(self.cols, 1));
        self.allocating.writer.print("\x1b[{d};{d}H", .{ self.row, self.col }) catch {};
    }

    /// Where the cursor currently sits, for a caller that draws left to right
    /// and needs to know when the panel is full.
    pub fn cursor(self: *const Frame) u16 {
        return self.col;
    }

    pub fn put(self: *Frame, style: Style, text: []const u8) void {
        if (self.col > self.cols) return;
        const room = self.cols - self.col + 1;
        const cut = clip(text, room);
        const w = &self.allocating.writer;
        tryWrite(w, style.code());
        tryWrite(w, cut);
        tryWrite(w, reset);
        self.col += displayWidth(cut);
    }

    pub fn spaces(self: *Frame, count: u16) void {
        var left = count;
        while (left > 0) : (left -= 1) {
            if (self.col > self.cols) return;
            tryWrite(&self.allocating.writer, " ");
            self.col += 1;
        }
    }

    /// Erases the rest of the current row, so a shorter line never leaves a
    /// tail of the previous frame behind it.
    pub fn endRow(self: *Frame) void {
        tryWrite(&self.allocating.writer, "\x1b[K");
    }

    pub fn hideCursor(self: *Frame) void {
        tryWrite(&self.allocating.writer, "\x1b[?25l");
    }

    pub fn showCursor(self: *Frame) void {
        tryWrite(&self.allocating.writer, "\x1b[?25h");
    }
};

fn tryWrite(w: *Io.Writer, text: []const u8) void {
    w.writeAll(text) catch {};
}

/// Display columns of a UTF-8 slice, counting codepoints: everything this UI
/// draws (Cyrillic, box drawing, ASCII) is one column wide.
pub fn displayWidth(text: []const u8) u16 {
    var count: u16 = 0;
    for (text) |ch| {
        if ((ch & 0xc0) != 0x80) count += 1;
    }
    return count;
}

/// Cuts to `max_cols` display columns without splitting a codepoint.
pub fn clip(text: []const u8, max_cols: u16) []const u8 {
    if (displayWidth(text) <= max_cols) return text;
    var cols: u16 = 0;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if ((text[i] & 0xc0) == 0x80) continue;
        if (cols == max_cols) return text[0..i];
        cols += 1;
    }
    return text;
}

const testing = std.testing;

test "term: display width counts codepoints, not bytes" {
    try testing.expectEqual(@as(u16, 6), displayWidth("привет"[0..]));
    try testing.expectEqual(@as(u16, 3), displayWidth("abc"));
    try testing.expectEqual(@as(u16, 0), displayWidth(""));
}

test "term: clipping stops on a codepoint boundary" {
    try testing.expectEqualStrings("при", clip("привет", 3));
    try testing.expectEqualStrings("abc", clip("abc", 10));
}

test "term: an escape sequence decodes into its key" {
    var input = Input{};
    @memcpy(input.pending[0..3], "\x1b[A");
    input.len = 3;
    try testing.expectEqual(Key.up, (try input.next(0)).?);

    @memcpy(input.pending[0..4], "\x1b[3~");
    input.len = 4;
    try testing.expectEqual(Key.delete, (try input.next(0)).?);
}

test "term: text decodes one codepoint at a time" {
    var input = Input{};
    const text = "щx";
    @memcpy(input.pending[0..text.len], text);
    input.len = text.len;

    const first = (try input.next(0)).?;
    try testing.expectEqualStrings("щ", first.text);
    const second = (try input.next(0)).?;
    try testing.expectEqualStrings("x", second.text);
    try testing.expectEqual(@as(usize, 0), input.len);
}
