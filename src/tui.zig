//! The two panels: a magnet line on the left, the history of what was typed on
//! the right. Every row action (mount, unmount, play through vlc) is a key on
//! the selected row, so the screen never needs a menu.
const std = @import("std");
const Io = std.Io;
const term = @import("term.zig");
const magnet = @import("magnet.zig");
const history = @import("history.zig");
const procs = @import("procs.zig");

/// One frame per 120 ms: fast enough that a mount appears as it comes up, slow
/// enough that redrawing costs nothing while the user reads.
const tick_ms = 120;

/// A mount that never produced metadata is reported rather than spun on: the
/// daemon's log is what explains the swarm, and the row says so.
const mount_timeout_ticks = 180 * 1000 / tick_ms;

const State = enum {
    idle,
    mounting,
    mounted,
    failed,

    fn label(self: State) []const u8 {
        return switch (self) {
            .idle => "не смонтирован",
            .mounting => "монтируется",
            .mounted => "смонтирован",
            .failed => "ошибка",
        };
    }

    fn style(self: State) term.Style {
        return switch (self) {
            .idle => .dim,
            .mounting => .warn,
            .mounted => .ok,
            .failed => .err,
        };
    }
};

/// Session-only facts about a row. The note is a fixed buffer on purpose: it is
/// refreshed while a mount waits, and a per-refresh allocation would grow for
/// as long as the swarm is slow.
const Runtime = struct {
    state: State = .idle,
    started_tick: u64 = 0,
    note_buf: [240]u8 = @splat(0),
    note_len: usize = 0,

    fn note(self: *const Runtime) []const u8 {
        return self.note_buf[0..self.note_len];
    }

    fn setNote(self: *Runtime, text: []const u8) void {
        const n = @min(text.len, self.note_buf.len);
        @memcpy(self.note_buf[0..n], text[0..n]);
        self.note_len = n;
    }
};

const Focus = enum { input, history };
const View = enum { history, files };

pub const Options = struct {
    version: []const u8,
    librats_version: []const u8,
    history_path: []const u8,
    /// Where `--rekarma` / `--vlc` resolved to, or null when the program is not
    /// on PATH. Resolved once at startup so a missing program is a message, not
    /// a failed spawn three keystrokes later.
    rekarma_exe: ?[]const u8,
    player_exe: ?[]const u8,
};

pub const App = struct {
    allocator: std.mem.Allocator,
    io: Io,
    config: procs.Config,
    options: Options,

    list: history.List,
    runtime: std.ArrayList(Runtime),

    input: std.ArrayList(u8),
    cursor: usize = 0,
    focus: Focus = .input,
    view: View = .history,
    selected: usize = 0,

    /// Files of the release the `files` view shows; owned by `files_arena` and
    /// rebuilt on every open, never edited in place.
    files: std.ArrayList(procs.MediaFile),
    files_arena: std.heap.ArenaAllocator,
    files_entry: usize = 0,
    files_scroll: usize = 0,

    status_buf: [240]u8 = @splat(0),
    status_len: usize = 0,
    status_style: term.Style = .dim,
    players: std.ArrayList(std.posix.pid_t),
    tick: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, io: Io, config: procs.Config, options: Options) !App {
        var app = App{
            .allocator = allocator,
            .io = io,
            .config = config,
            .options = options,
            .list = history.List.init(allocator),
            .runtime = .empty,
            .input = .empty,
            .files = .empty,
            .files_arena = std.heap.ArenaAllocator.init(allocator),
            .players = .empty,
        };
        try app.list.load(io, options.history_path);
        for (app.list.items.items) |entry| {
            // What a previous session left mounted is a fact of the filesystem,
            // not of the history file: ask the mountpoint.
            try app.runtime.append(allocator, .{
                .state = if (procs.isMounted(io, entry.mount)) .mounted else .idle,
            });
        }

        if (options.rekarma_exe == null) {
            var buf: [240]u8 = undefined;
            const text = std.fmt.bufPrint(&buf, "rekarma не найден: {s} — укажите --rekarma <путь>", .{
                config.rekarma,
            }) catch "";
            app.setStatus(text, .warn);
        } else if (options.player_exe == null) {
            var buf: [240]u8 = undefined;
            const text = std.fmt.bufPrint(&buf, "vlc не найден: {s} — укажите --vlc <путь>", .{config.player}) catch "";
            app.setStatus(text, .warn);
        }
        return app;
    }

    pub fn deinit(self: *App) void {
        self.list.deinit();
        self.runtime.deinit(self.allocator);
        self.input.deinit(self.allocator);
        self.files.deinit(self.allocator);
        self.files_arena.deinit();
        self.players.deinit(self.allocator);
    }

    pub fn run(self: *App) !void {
        var raw = try term.Raw.enter();
        defer raw.leave();

        var out_buffer: [8192]u8 = undefined;
        var stdout_writer: Io.File.Writer = .init(.stdout(), self.io, &out_buffer);
        const out = &stdout_writer.interface;

        try out.writeAll("\x1b[?1049h\x1b[?25l\x1b[2J");
        try out.flush();
        defer {
            out.writeAll("\x1b[?25h\x1b[?1049l") catch {};
            out.flush() catch {};
        }

        var input = term.Input{};
        while (true) {
            self.tick += 1;
            self.housekeeping();

            try self.draw(term.size(), out);
            try out.flush();

            const key = try input.next(tick_ms);
            if (key) |k| {
                if (try self.handle(k)) break;
            }
        }
    }

    fn handle(self: *App, key: term.Key) !bool {
        // Ctrl-C is the only key that quits from the input line: every other
        // character there is text the user is typing.
        switch (key) {
            .ctrl_c => return true,
            .ctrl_d => if (self.focus == .input and self.input.items.len == 0) return true,
            .ctrl_l => return false,
            else => {},
        }

        switch (self.view) {
            .files => try self.handleFiles(key),
            .history => switch (self.focus) {
                .input => try self.handleInput(key),
                .history => {
                    if (try self.handleHistory(key)) return true;
                },
            },
        }
        return false;
    }

    fn handleInput(self: *App, key: term.Key) !void {
        switch (key) {
            .text => |bytes| {
                try self.input.insertSlice(self.allocator, self.cursor, bytes);
                self.cursor += bytes.len;
            },
            .backspace => if (self.cursor > 0) {
                const start = prevCodepoint(self.input.items, self.cursor);
                try self.input.replaceRange(self.allocator, start, self.cursor - start, "");
                self.cursor = start;
            },
            .delete => if (self.cursor < self.input.items.len) {
                const end = nextCodepoint(self.input.items, self.cursor);
                try self.input.replaceRange(self.allocator, self.cursor, end - self.cursor, "");
            },
            .left => self.cursor = prevCodepoint(self.input.items, self.cursor),
            .right => self.cursor = nextCodepoint(self.input.items, self.cursor),
            .home => self.cursor = 0,
            .end => self.cursor = self.input.items.len,
            .ctrl_u => {
                self.input.clearRetainingCapacity();
                self.cursor = 0;
            },
            .enter => try self.startFromInput(),
            .tab => {
                if (self.list.items.items.len > 0) self.focus = .history;
            },
            .esc => {
                self.input.clearRetainingCapacity();
                self.cursor = 0;
            },
            else => {},
        }
    }

    fn handleHistory(self: *App, key: term.Key) !bool {
        const count = self.list.items.items.len;
        if (count == 0) {
            if (key == .tab or key == .esc) self.focus = .input;
            return false;
        }
        if (self.selected >= count) self.selected = count - 1;

        switch (key) {
            .up, .left => self.selected = if (self.selected == 0) count - 1 else self.selected - 1,
            .down, .right => self.selected = (self.selected + 1) % count,
            .tab, .esc => self.focus = .input,
            .enter => try self.activate(self.selected),
            .text => |bytes| {
                if (std.mem.eql(u8, bytes, "q")) return true;
                if (std.mem.eql(u8, bytes, "u")) try self.unmountSelected();
                if (std.mem.eql(u8, bytes, "x")) try self.deleteSelected();
                if (std.mem.eql(u8, bytes, "r")) try self.activate(self.selected);
            },
            else => {},
        }
        return false;
    }

    fn handleFiles(self: *App, key: term.Key) !void {
        switch (key) {
            .esc, .tab => self.view = .history,
            .up, .left => if (self.files.items.len > 0) {
                self.files_entry = if (self.files_entry == 0) self.files.items.len - 1 else self.files_entry - 1;
            },
            .down, .right => if (self.files.items.len > 0) {
                self.files_entry = (self.files_entry + 1) % self.files.items.len;
            },
            .enter => {
                if (self.files_entry < self.files.items.len) {
                    try self.playPath(self.files.items[self.files_entry].path);
                }
            },
            else => {},
        }
    }

    /// Enter in the input line: normalize what was typed, remember it and hand
    /// it to the mount daemon. The row appears in `mounting` at once, so a
    /// wrong link is visible as a row that never becomes read-only.
    fn startFromInput(self: *App) !void {
        const exe = self.options.rekarma_exe orelse {
            self.setStatus("rekarma не найден в PATH — укажите --rekarma <путь>", .err);
            return;
        };
        const link = (try magnet.normalize(self.allocator, self.input.items)) orelse {
            self.setStatus("это не magnet-ссылка: нужен magnet:?xt=… или info-hash", .err);
            return;
        };
        defer self.allocator.free(link);

        const dirs = try procs.dirsOf(self.allocator, self.config, link);
        defer self.allocator.free(dirs.mount);
        defer self.allocator.free(dirs.cache);

        self.input.clearRetainingCapacity();
        self.cursor = 0;

        // A link already in the history is moved up, not duplicated — and if it
        // is still mounted, Enter means "show me its files" rather than a
        // second daemon on the same mountpoint.
        if (self.list.findIndex(link)) |existing| {
            self.list.moveToTop(existing);
            const moved = self.runtime.orderedRemove(existing);
            try self.runtime.insert(self.allocator, 0, moved);
            self.selected = 0;
            self.focus = .history;
            try self.saveHistory();
            if (self.runtime.items[0].state == .mounted) try self.openFiles(0);
            return;
        }

        try self.list.insertTop(link, dirs.mount, "");
        try self.runtime.insert(self.allocator, 0, .{ .state = .mounting, .started_tick = self.tick });
        self.selected = 0;
        self.focus = .history;
        try self.saveHistory();

        procs.mount(self.io, exe, link, dirs.mount, dirs.cache) catch |err| {
            var buf: [200]u8 = undefined;
            const note = std.fmt.bufPrint(&buf, "rekarma: {s}", .{@errorName(err)}) catch "";
            self.runtime.items[0].state = .failed;
            self.runtime.items[0].setNote(note);
            self.setStatus("монтирование не запустилось", .err);
            return;
        };
        self.setStatus("монтирование запущено", .dim);
    }

    /// Enter on a history row: show its files if it is mounted, mount it if it
    /// is not. A failed row retries from the same key.
    fn activate(self: *App, index: usize) !void {
        if (index >= self.list.items.items.len) return;
        const entry = self.list.items.items[index];
        const rt = &self.runtime.items[index];

        switch (rt.state) {
            .mounted => try self.openFiles(index),
            .mounting => self.setStatus("ещё монтируется — метаданные не пришли", .warn),
            .idle, .failed => {
                const exe = self.options.rekarma_exe orelse {
                    self.setStatus("rekarma не найден в PATH — укажите --rekarma <путь>", .err);
                    return;
                };
                const dirs = try procs.dirsOf(self.allocator, self.config, entry.magnet);
                defer self.allocator.free(dirs.mount);
                defer self.allocator.free(dirs.cache);
                procs.mount(self.io, exe, entry.magnet, dirs.mount, dirs.cache) catch |err| {
                    var buf: [200]u8 = undefined;
                    const note = std.fmt.bufPrint(&buf, "rekarma: {s}", .{@errorName(err)}) catch "";
                    rt.state = .failed;
                    rt.setNote(note);
                    self.setStatus("монтирование не запустилось", .err);
                    return;
                };
                rt.state = .mounting;
                rt.started_tick = self.tick;
                rt.note_len = 0;
                self.setStatus("монтирование запущено", .dim);
            },
        }
    }

    fn openFiles(self: *App, index: usize) !void {
        if (index >= self.list.items.items.len) return;
        const entry = self.list.items.items[index];

        _ = self.files_arena.reset(.retain_capacity);
        self.files.clearRetainingCapacity();
        procs.listMedia(self.allocator, self.files_arena.allocator(), self.io, entry.mount, &self.files) catch {
            self.setStatus("не удалось прочитать каталог релиза", .err);
            return;
        };
        self.files_entry = 0;
        self.files_scroll = 0;

        if (self.files.items.len == 0) {
            self.setStatus("в релизе нет медиафайлов", .warn);
            return;
        }
        // A single playable file is what most releases are: opening a list of
        // one to press Enter on it again is a step with nothing to choose.
        if (self.files.items.len == 1) {
            try self.playPath(self.files.items[0].path);
            return;
        }
        self.view = .files;
        self.setStatus("выберите файл и нажмите Enter", .dim);
    }

    /// Starts the player on one file inside a mount and remembers its pid, so
    /// the tick can reap it when it exits.
    fn playPath(self: *App, path: []const u8) !void {
        const exe = self.options.player_exe orelse {
            self.setStatus("vlc не найден в PATH — укажите --vlc <путь>", .err);
            return;
        };
        const pid = procs.play(self.io, exe, path) catch |err| {
            var buf: [200]u8 = undefined;
            const text = std.fmt.bufPrint(&buf, "vlc: {s}", .{@errorName(err)}) catch "";
            self.setStatus(text, .err);
            return;
        };
        try self.players.append(self.allocator, pid);

        var buf: [160]u8 = undefined;
        const name = std.fs.path.stem(std.fs.path.basename(path));
        const text = std.fmt.bufPrint(&buf, "vlc: {s}", .{name}) catch "запущен vlc";
        self.setStatus(text, .ok);
    }

    fn unmountSelected(self: *App) !void {
        if (self.selected >= self.list.items.items.len) return;
        const entry = self.list.items.items[self.selected];
        const dirs = try procs.dirsOf(self.allocator, self.config, entry.magnet);
        defer self.allocator.free(dirs.mount);
        defer self.allocator.free(dirs.cache);

        if (procs.unmount(self.io, dirs.cache)) {
            self.setStatus("отмонтировано", .ok);
        } else {
            self.setStatus("daemon не найден — релиз и так не смонтирован", .warn);
        }
        self.runtime.items[self.selected] = .{ .state = .idle };
    }

    fn deleteSelected(self: *App) !void {
        if (self.selected >= self.list.items.items.len) return;
        if (self.runtime.items[self.selected].state == .mounted) try self.unmountSelected();
        self.list.removeAt(self.selected);
        if (self.selected < self.runtime.items.len) _ = self.runtime.orderedRemove(self.selected);
        if (self.list.items.items.len > 0 and self.selected >= self.list.items.items.len) {
            self.selected = self.list.items.items.len - 1;
        }
        try self.saveHistory();
        self.setStatus("запись удалена из истории", .dim);
    }

    /// Per-tick work that is cheap and must stay out of the draw path: a mount
    /// that came up, one that never will, and finished players that would
    /// otherwise stay zombies.
    fn housekeeping(self: *App) void {
        for (self.list.items.items, 0..) |entry, i| {
            const rt = &self.runtime.items[i];
            if (rt.state != .mounting) continue;

            if (procs.isMounted(self.io, entry.mount)) {
                rt.state = .mounted;
                rt.note_len = 0;
                self.nameEntry(i);
                var buf: [96]u8 = undefined;
                const text = std.fmt.bufPrint(&buf, "релиз смонтирован · Enter — файлы", .{}) catch "";
                self.setStatus(text, .ok);
                continue;
            }
            if (self.tick - rt.started_tick > mount_timeout_ticks) {
                rt.state = .failed;
                if (self.logTail(i)) |line| {
                    rt.setNote(line);
                } else {
                    rt.setNote("метаданные не пришли");
                }
                continue;
            }
            // Once a second, not every tick: the log is a file read and the
            // line only changes when the swarm does.
            if ((self.tick - rt.started_tick) % (1000 / tick_ms) == 0) {
                if (self.logTail(i)) |line| rt.setNote(line);
            }
        }

        for (self.players.items) |pid| procs.reap(pid);
        self.players.clearRetainingCapacity();
    }

    /// Names a release the moment it mounts: the biggest media file inside is
    /// the only name a magnet link does not carry.
    fn nameEntry(self: *App, index: usize) void {
        const entry = &self.list.items.items[index];
        if (entry.title.len > 0) return;

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        var found: std.ArrayList(procs.MediaFile) = .empty;
        defer found.deinit(self.allocator);
        procs.listMedia(self.allocator, arena.allocator(), self.io, entry.mount, &found) catch return;

        var best: ?procs.MediaFile = null;
        for (found.items) |file| {
            if (best == null or file.size > best.?.size) best = file;
        }
        const chosen = best orelse return;
        const name = std.fs.path.stem(std.fs.path.basename(chosen.path));
        if (name.len == 0) return;

        const owned = self.list.arena.allocator().dupe(u8, name) catch return;
        entry.title = owned;
        self.list.save(self.io, self.options.history_path) catch {};
    }

    fn logTail(self: *App, index: usize) ?[]const u8 {
        const entry = self.list.items.items[index];
        const dirs = procs.dirsOf(self.allocator, self.config, entry.magnet) catch return null;
        defer self.allocator.free(dirs.mount);
        defer self.allocator.free(dirs.cache);

        const log_path = procs.cacheLogPath(self.allocator, dirs.cache) catch return null;
        defer self.allocator.free(log_path);

        var scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        return procs.tailLine(scratch.allocator(), self.io, log_path);
    }

    /// What is still running after the interface closes: the mounts are
    /// daemons of their own and outlive the TUI on purpose, so the last thing
    /// printed is how to stop them rather than a silent surprise.
    pub fn printRemaining(self: *App, out: *Io.Writer) !void {
        var count: usize = 0;
        for (self.runtime.items) |rt| {
            if (rt.state == .mounted) count += 1;
        }
        if (count == 0) return;

        try out.print("ziggurat: смонтированных релизов осталось: {d}\n", .{count});
        for (self.list.items.items, 0..) |entry, i| {
            if (self.runtime.items[i].state != .mounted) continue;
            const dirs = procs.dirsOf(self.allocator, self.config, entry.magnet) catch continue;
            defer self.allocator.free(dirs.mount);
            defer self.allocator.free(dirs.cache);
            try out.print("  {s}  →  kill $(cat {s}/magnet.pid)\n", .{ dirs.mount, dirs.cache });
        }
    }

    fn saveHistory(self: *App) !void {
        self.list.save(self.io, self.options.history_path) catch |err| {
            self.setStatus(@errorName(err), .err);
        };
    }

    fn setStatus(self: *App, text: []const u8, style: term.Style) void {
        const n = @min(text.len, self.status_buf.len);
        @memcpy(self.status_buf[0..n], text[0..n]);
        self.status_len = n;
        self.status_style = style;
    }

    fn status(self: *const App) []const u8 {
        return self.status_buf[0..self.status_len];
    }

    fn draw(self: *App, size: term.Size, out: *Io.Writer) !void {
        var frame = term.Frame.init(self.allocator, size.rows, size.cols);
        defer frame.deinit();

        if (size.rows < 10 or size.cols < 46) {
            frame.at(1, 1);
            frame.put(.err, "окно слишком мало для двух панелей");
            frame.endRow();
            frame.showCursor();
            try out.writeAll(frame.bytes());
            return;
        }

        self.drawTitle(&frame, size);

        const top: u16 = 2;
        const bottom: u16 = size.rows - 3;
        const height = bottom - top + 1;
        var left_width = size.cols * 2 / 5;
        left_width = std.math.clamp(left_width, 26, 48);
        if (size.cols - left_width < 24) left_width = size.cols - 24;
        const right_left = left_width + 1;
        const right_width = size.cols - left_width;

        // Every interior row is cleared before it is drawn: a row that shrinks
        // or disappears (a mount that finished, a release that lost a file)
        // would otherwise keep the previous frame's text under the new one.
        var clear_row = top + 1;
        while (clear_row < top + height - 1) : (clear_row += 1) {
            frame.at(clear_row, 1);
            frame.endRow();
        }

        // Interiors first, boxes last: a panel's content erases to the end of
        // its line, and drawing the borders afterwards keeps them intact.
        const cursor_at = self.drawInputPanel(&frame, top, 1, height, left_width);
        switch (self.view) {
            .history => self.drawHistoryPanel(&frame, top, right_left, height, right_width),
            .files => self.drawFilesPanel(&frame, top, right_left, height, right_width),
        }
        frame.at(top, size.cols);
        frame.endRow();
        frame.at(bottom, size.cols);
        frame.endRow();

        drawBox(&frame, top, 1, height, left_width, "Ввод");
        drawBox(&frame, top, right_left, height, right_width, switch (self.view) {
            .history => "История",
            .files => "Файлы релиза",
        });

        self.drawFooter(&frame, size);

        // The cursor is only shown where typing goes; everywhere else the
        // selection highlight is the pointer.
        if (cursor_at) |pos| {
            frame.at(pos[0], pos[1]);
            frame.showCursor();
        } else {
            frame.hideCursor();
        }

        try out.writeAll(frame.bytes());
    }

    fn drawTitle(self: *App, frame: *term.Frame, size: term.Size) void {
        frame.at(1, 1);
        frame.put(.title, " ziggurat ");
        frame.put(.plain, "p2p-релизы: magnet → монтирование → vlc");
        frame.endRow();

        var buf: [128]u8 = undefined;
        const right = std.fmt.bufPrint(&buf, "librats {s} · ziggurat {s} ", .{
            self.options.librats_version, self.options.version,
        }) catch return;
        const width = term.displayWidth(right);
        const used = 10 + term.displayWidth("p2p-релизы: magnet → монтирование → vlc");
        if (size.cols > used + width) {
            frame.at(1, size.cols - width + 1);
            frame.put(.dim, right);
        }
    }

    fn drawBox(frame: *term.Frame, top: u16, left: u16, height: u16, width: u16, title: []const u8) void {
        if (width < 6 or height < 3) return;

        frame.at(top, left);
        frame.put(.border, "┌─ ");
        frame.put(.bold, title);
        frame.put(.border, " ");
        var filled: u16 = term.displayWidth(title) + 4;
        while (filled + 1 < width) : (filled += 1) frame.put(.border, "─");
        frame.put(.border, "┐");

        var row = top + 1;
        while (row < top + height - 1) : (row += 1) {
            frame.at(row, left);
            frame.put(.border, "│");
            frame.at(row, left + width - 1);
            frame.put(.border, "│");
        }

        frame.at(top + height - 1, left);
        frame.put(.border, "└");
        var i: u16 = 1;
        while (i + 1 < width) : (i += 1) frame.put(.border, "─");
        frame.put(.border, "┘");
    }

    /// Returns where the typing cursor belongs, when the input panel has focus.
    fn drawInputPanel(self: *App, frame: *term.Frame, top: u16, left: u16, height: u16, width: u16) ?[2]u16 {
        const focused = self.focus == .input;
        const text_width: u16 = width - 4;

        frame.at(top + 1, left + 1);
        frame.put(if (focused) .accent else .dim, if (focused) ">" else " ");
        frame.put(.plain, " ");

        const cursor_cols = term.displayWidth(self.input.items[0..self.cursor]);
        const offset = if (cursor_cols >= text_width) cursor_cols - text_width + 1 else 0;
        frame.put(.plain, skipCols(self.input.items, offset));
        if (self.input.items.len == 0 and focused) {
            frame.put(.dim, "magnet:?xt=urn:btih:…  (или info-hash)");
        }
        frame.endRow();

        // Under the input: what the selected row is doing right now. A mount
        // waiting for the swarm must not look like a hung program.
        var row = top + 3;
        if (self.selected < self.list.items.items.len and row + 2 < top + height - 1) {
            const rt = &self.runtime.items[self.selected];
            const entry = self.list.items.items[self.selected];

            if (rt.state == .mounting) {
                var buf: [96]u8 = undefined;
                const secs = (self.tick - rt.started_tick) * tick_ms / 1000;
                const text = std.fmt.bufPrint(&buf, "монтируется {d} с · {s}", .{
                    secs, magnet.shortId(entry.magnet),
                }) catch "";
                frame.at(row, left + 1);
                frame.put(.warn, text);
                frame.endRow();
                row += 1;
            }

            const note = rt.note();
            if (note.len > 0) {
                frame.at(row, left + 1);
                frame.put(.dim, note);
                frame.endRow();
                row += 1;
            }
        }

        if (row + 2 < top + height - 1) {
            frame.at(row + 1, left + 1);
            frame.put(.dim, "Enter — смонтировать");
            frame.at(row + 2, left + 1);
            frame.put(.dim, "Tab — к истории, Esc — очистить");
        }

        if (!focused) return null;
        const cursor_col = left + 3 + (cursor_cols - offset);
        return .{ top + 1, @min(cursor_col, left + width - 2) };
    }

    fn drawHistoryPanel(self: *App, frame: *term.Frame, top: u16, left: u16, height: u16, width: u16) void {
        const rows = height - 2;
        const inner_width = width - 2;
        const entries = self.list.items.items;

        if (entries.len == 0) {
            frame.at(top + 1, left + 2);
            frame.put(.dim, "пока пусто: вставьте magnet-ссылку слева");
            return;
        }

        // Keep the selection visible without storing an offset: the list is
        // short and the selected index is the only state worth keeping.
        const start = if (self.selected < rows) 0 else self.selected - rows + 1;

        var i: usize = 0;
        while (i < rows and start + i < entries.len) : (i += 1) {
            const index = start + i;
            const entry = entries[index];
            const rt = self.runtime.items[index];
            const is_selected = index == self.selected and self.focus == .history;
            const row = top + 1 + @as(u16, @intCast(i));

            const state_text = rt.state.label();
            const state_width = term.displayWidth(state_text);
            const room_i: i32 = @as(i32, inner_width) - @as(i32, state_width) - 10;
            const room: u16 = @intCast(@max(room_i, 4));

            frame.at(row, left + 1);
            frame.put(if (is_selected) .selected else .dim, if (is_selected) "▸" else " ");
            frame.put(if (is_selected) .selected else .dim, " ");
            frame.put(if (is_selected) .selected else .accent, magnet.shortId(entry.magnet));
            frame.put(if (is_selected) .selected else .plain, " ");
            frame.put(if (is_selected) .selected else .plain, truncateTo(
                if (entry.title.len > 0) entry.title else "—",
                room,
            ));
            frame.endRow();

            if (left + width > state_width + 1) {
                frame.at(row, left + width - 1 - state_width);
                frame.put(if (is_selected) .selected else rt.state.style(), state_text);
            }
        }
    }

    fn drawFilesPanel(self: *App, frame: *term.Frame, top: u16, left: u16, height: u16, width: u16) void {
        const inner_width = width - 2;

        frame.at(top + 1, left + 2);
        var head: [96]u8 = undefined;
        const head_text = std.fmt.bufPrint(&head, "{d} файл(ов) · Enter — vlc", .{self.files.items.len}) catch "";
        frame.put(.dim, head_text);
        frame.endRow();

        const visible_rows = height - 3;
        if (self.files_entry < self.files_scroll) self.files_scroll = self.files_entry;
        if (self.files_entry >= self.files_scroll + visible_rows) self.files_scroll = self.files_entry - visible_rows + 1;

        var i: usize = 0;
        while (i < visible_rows and self.files_scroll + i < self.files.items.len) : (i += 1) {
            const index = self.files_scroll + i;
            const file = self.files.items[index];
            const selected = index == self.files_entry;
            const row = top + 2 + @as(u16, @intCast(i));

            var size_buf: [24]u8 = undefined;
            const size = sizeText(&size_buf, file.size);

            frame.at(row, left + 1);
            frame.put(if (selected) .selected else .dim, if (selected) "▸" else " ");
            frame.put(if (selected) .selected else .plain, " ");
            const room_i: i32 = @as(i32, inner_width) - @as(i32, term.displayWidth(size)) - 6;
            const room: u16 = @intCast(@max(room_i, 4));
            const name = std.fs.path.stem(std.fs.path.basename(file.path));
            frame.put(if (selected) .selected else .plain, truncateTo(name, room));
            frame.put(if (selected) .selected else .dim, "  ");
            frame.put(if (selected) .selected else .dim, size);
            frame.endRow();
        }
    }

    fn drawFooter(self: *App, frame: *term.Frame, size: term.Size) void {
        frame.at(size.rows - 2, 1);
        frame.put(self.status_style, self.status());
        frame.endRow();

        frame.at(size.rows - 1, 1);
        const hints = switch (self.view) {
            .history => switch (self.focus) {
                .input => "Ctrl-C — выход · Tab — история · Enter — смонтировать",
                .history => "↑↓ — выбор · Enter — открыть · u — отмонтировать · x — удалить · q — выход",
            },
            .files => "↑↓ — файл · Enter — vlc · Esc — назад · Ctrl-C — выход",
        };
        frame.put(.dim, hints);
        frame.endRow();
    }
};

fn sizeText(buf: []u8, bytes: u64) []const u8 {
    const units = [_][]const u8{ "Б", "КБ", "МБ", "ГБ", "ТБ" };
    var value: f64 = @floatFromInt(bytes);
    var unit: usize = 0;
    while (value >= 1024.0 and unit + 1 < units.len) : (unit += 1) value /= 1024.0;
    if (unit == 0) return std.fmt.bufPrint(buf, "{d} {s}", .{ bytes, units[0] }) catch "";
    return std.fmt.bufPrint(buf, "{d:.1} {s}", .{ value, units[unit] }) catch "";
}

/// Keeps a title inside its column, on a codepoint boundary.
fn truncateTo(text: []const u8, cols: u16) []const u8 {
    if (term.displayWidth(text) <= cols or cols == 0) return text;
    return term.clip(text, cols);
}

fn skipCols(text: []const u8, cols: u16) []const u8 {
    if (cols == 0) return text;
    var seen: u16 = 0;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if ((text[i] & 0xc0) == 0x80) continue;
        if (seen == cols) return text[i..];
        seen += 1;
    }
    return text[text.len..];
}

fn prevCodepoint(text: []const u8, from: usize) usize {
    if (from == 0) return 0;
    var i = from - 1;
    while (i > 0 and (text[i] & 0xc0) == 0x80) i -= 1;
    return i;
}

fn nextCodepoint(text: []const u8, from: usize) usize {
    if (from >= text.len) return text.len;
    var i = from + 1;
    while (i < text.len and (text[i] & 0xc0) == 0x80) i += 1;
    return i;
}

const testing = std.testing;

test "tui: cursor movement stops on codepoint boundaries" {
    const text = "abщв";
    try testing.expectEqual(@as(usize, 3), nextCodepoint(text, 2));
    try testing.expectEqual(@as(usize, 2), prevCodepoint(text, 3));
    try testing.expectEqual(@as(usize, 0), prevCodepoint(text, 0));
    try testing.expectEqual(text.len, nextCodepoint(text, text.len));
}

test "tui: skipping columns keeps the utf-8 text valid" {
    try testing.expectEqualStrings("вет", skipCols("привет", 3));
    try testing.expectEqualStrings("привет", skipCols("привет", 0));
}

test "tui: sizes are reported in the largest unit that fits" {
    var buf: [24]u8 = undefined;
    try testing.expectEqualStrings("512 Б", sizeText(&buf, 512));
    try testing.expectEqualStrings("1.5 КБ", sizeText(&buf, 1536));
    try testing.expectEqualStrings("2.0 ГБ", sizeText(&buf, 2 * 1024 * 1024 * 1024));
}
