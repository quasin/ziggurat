//! The two panels: a source line on the left (a magnet link or a .torrent file),
//! the history of what was typed on the right. Every row action (mount, unmount,
//! open through the desktop) is a key on the selected row, so the screen never
//! needs a menu.
const std = @import("std");
const Io = std.Io;
const term = @import("term.zig");
const magnet = @import("magnet.zig");
const history = @import("history.zig");
const procs = @import("procs.zig");
const rutracker = @import("rutracker.zig");

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
/// What the right panel shows: the mount history, a release's files, the
/// reKarma room, or the RuTracker dump. The room is a view rather than a popup
/// because reading it and typing into it are the same act; the dump is one
/// because searching it and mounting what it finds are the same act too.
const View = enum { history, files, room, database };

/// The shortcuts under the source line: fixed one-shot jobs, each with its own
/// log, not history entries. `↓` walks them, Enter runs the selected one. The
/// room shortcut is the one that stays: it opens the default room's history in
/// the left panel instead of running a job and returning.
const Link = struct {
    label: []const u8,
    action: Action,
};
const Action = enum { autonomi_install, rutracker_database, rutracker_view, room_history };
const links = [_]Link{
    .{ .label = "Autonomi Install", .action = .autonomi_install },
    .{ .label = "Install RuTracker.Org DataBase", .action = .rutracker_database },
    .{ .label = "База RuTracker.Org", .action = .rutracker_view },
    .{ .label = "История reKarma", .action = .room_history },
};

/// How many of the room's newest messages are kept in memory. The recorder caps
/// its file at 1000 lines; the panel shows the tail of that, and keeping more
/// than it can ever print only makes a reload more expensive.
const room_max_lines: usize = 200;

/// How long a message waits for the recorder to print its listening port before
/// it is published through discovery instead. The daemon fork is instant but the
/// node's banner comes after librats bootstraps.
const recorder_wait_ticks = 8 * 1000 / tick_ms;

/// The longest message the compose line accepts. rekarma prepends a stamp and a
/// peer id to every line it keeps, so a room message that never fits a terminal
/// row is a mistake rather than a feature.
const compose_max: usize = 400;

pub const Options = struct {
    version: []const u8,
    /// The engine's own version, read from `rekarma --version` at startup:
    /// ziggurat links no librats of its own to ask.
    rekarma_version: []const u8,
    history_path: []const u8,
    /// Where `--rekarma` / `--open` resolved to, or null when the program is
    /// not on PATH. Resolved once at startup so a missing program is a message,
    /// not a failed spawn three keystrokes later.
    rekarma_exe: ?[]const u8,
    /// The desktop's default application, behind every file of a mounted
    /// release: video plays, a book opens in a reader, a folder in a file
    /// manager. The mount is a plain directory to whatever the desktop
    /// associates with the type.
    opener_exe: ?[]const u8 = null,
    /// The two tools behind the RuTracker database link: `ant` fetches the
    /// archive, `xz -d` unpacks it in place.
    ant_exe: ?[]const u8 = null,
    xz_exe: ?[]const u8 = null,
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
    /// Whether the shortcuts under the prompt are selected instead of the input
    /// line, and which one. Enter runs it, `↓`/`↑` move through the list.
    link_selected: bool = false,
    link_index: usize = 0,
    view: View = .history,
    selected: usize = 0,

    /// Every directory and file of the release the `files` view shows; owned by
    /// `files_arena` and rebuilt on every open, never edited in place.
    files: std.ArrayList(procs.Entry),
    files_arena: std.heap.ArenaAllocator,
    /// The mount the list was taken from, so a row can be printed relative to
    /// it and opened by its full path. A copy in `files_arena`.
    files_root: []const u8 = "",
    files_entry: usize = 0,
    files_scroll: usize = 0,

    /// The room view's messages: rekarma's `all.txt`, read into memory when the
    /// file changes. The lines live in the app's allocator because they outlive a
    /// frame; the panel only ever prints slices of them.
    room_started: bool = false,
    room_lines: std.ArrayList([]u8),
    room_absent: bool = false,
    /// The file state the lines were read at. An unchanged stat costs one syscall
    /// per tick and no allocation, which is how the panel stays live.
    room_read: bool = false,
    room_size: u64 = 0,
    room_mtime: i96 = 0,
    /// Messages above the tail the user scrolled to; 0 follows whatever arrives.
    room_scroll: usize = 0,
    /// How many message rows the last frame had room for, so scroll keys clamp
    /// against the same number the screen used.
    room_rows: usize = 0,
    /// The line being written into the room, kept apart from the source line so a
    /// half-typed magnet link is not lost when the room is opened.
    compose: std.ArrayList(u8),
    compose_cursor: usize = 0,
    /// The one-shot `rekarma <message>` that publishes the compose line; reaped
    /// like the other long-lived children because finding a peer takes seconds.
    publish_pid: ?std.posix.pid_t = null,
    published: [160]u8 = @splat(0),
    published_len: usize = 0,
    /// A message handed over but not yet spawned: the recorder prints the port it
    /// listens on a moment after it forks, and a send without that port falls
    /// back to the DHT and takes a minute to reach anybody.
    pending: [compose_max]u8 = @splat(0),
    pending_len: usize = 0,
    pending_since: u64 = 0,

    /// The RuTracker dump viewer. `db_path` is the `rutracker-*.xml` found in
    /// the startup directory, kept as an owned copy because the scan thread
    /// borrows it; `db_query` is the line typed into the panel.
    db_path: ?[]u8 = null,
    db: rutracker.Engine,
    db_query: std.ArrayList(u8),
    db_cursor: usize = 0,
    /// Whether ↑↓ and Enter act on the results instead of the query line.
    db_results_focus: bool = false,
    db_selected: usize = 0,
    db_scroll: usize = 0,
    /// How many result *releases* the last frame had room for: each one is two
    /// rows, the section and the title.
    db_rows: usize = 0,
    /// Set once the scan's outcome has been put on the status line, so it is
    /// not rewritten every tick.
    db_reported: bool = false,

    status_buf: [240]u8 = @splat(0),
    status_len: usize = 0,
    status_style: term.Style = .dim,
    /// The children the desktop opener started: a player or a reader outlives
    /// the frame that launched it, so its pid waits here to be reaped.
    opened: std.ArrayList(std.posix.pid_t),
    /// The installer runs far longer than a player, so its pid stays here
    /// until `reapIfDone` sees it exit instead of being dropped after one poll.
    install_pid: ?std.posix.pid_t = null,
    /// The RuTracker database download/unpack, reaped the same way.
    download_pid: ?std.posix.pid_t = null,
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
            .room_lines = .empty,
            .compose = .empty,
            .opened = .empty,
            .db = rutracker.Engine.init(allocator),
            .db_query = .empty,
        };
        try app.list.load(io, options.history_path);
        for (app.list.items.items) |entry| {
            // What a previous session left mounted is a fact of the filesystem,
            // not of the history file: ask the mountpoint. A release whose
            // daemon is alive but whose directory is still empty is a mount on
            // its way — a restart of the interface must not read it as idle,
            // because the next Enter would then start a twin on the same cache
            // dir and overwrite the pid of the daemon that is working.
            var state: State = .idle;
            if (procs.isMounted(io, entry.mount)) {
                state = .mounted;
            } else {
                const dirs = try procs.dirsOf(allocator, config, entry.magnet);
                const running = procs.mountRunning(io, dirs.cache);
                allocator.free(dirs.mount);
                allocator.free(dirs.cache);
                if (running) state = .mounting;
            }
            try app.runtime.append(allocator, .{ .state = state });
        }

        if (options.rekarma_exe == null) {
            var buf: [240]u8 = undefined;
            const text = std.fmt.bufPrint(&buf, "rekarma не найден: {s} — укажите --rekarma <путь>", .{
                config.rekarma,
            }) catch "";
            app.setStatus(text, .warn);
        } else if (options.opener_exe == null) {
            var buf: [240]u8 = undefined;
            const text = std.fmt.bufPrint(&buf, "xdg-open не найден: {s} — укажите --open <путь>", .{config.opener}) catch "";
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
        self.clearRoom();
        self.room_lines.deinit(self.allocator);
        self.compose.deinit(self.allocator);
        self.opened.deinit(self.allocator);
        self.db.deinit();
        self.db_query.deinit(self.allocator);
        if (self.db_path) |path| self.allocator.free(path);
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
            .room => try self.handleRoom(key),
            .database => try self.handleDatabase(key),
            .history => switch (self.focus) {
                .input => try self.handleInput(key),
                .history => {
                    if (try self.handleHistory(key)) return true;
                },
            },
        }
        return false;
    }

    /// Keys in the room view: the panel is a chat, so a printable key edits the
    /// message line, Enter publishes it, and the arrows scroll the log instead of
    /// walking a selection. Esc is the way back to the mount history.
    fn handleRoom(self: *App, key: term.Key) !void {
        switch (key) {
            .esc, .tab => {
                self.view = .history;
                self.focus = .input;
                self.room_scroll = 0;
            },
            .up => self.room_scroll +|= 1,
            .down => if (self.room_scroll > 0) {
                self.room_scroll -= 1;
            },
            .enter => try self.sendMessage(),
            .home => self.room_scroll = room_max_lines,
            .end => self.room_scroll = 0,
            .text => |bytes| {
                if (self.compose.items.len + bytes.len > compose_max) {
                    self.setStatus("сообщение длиннее 400 символов — не вставляю", .warn);
                    return;
                }
                try self.compose.insertSlice(self.allocator, self.compose_cursor, bytes);
                self.compose_cursor += bytes.len;
            },
            .backspace => if (self.compose_cursor > 0) {
                const start = prevCodepoint(self.compose.items, self.compose_cursor);
                try self.compose.replaceRange(self.allocator, start, self.compose_cursor - start, "");
                self.compose_cursor = start;
            },
            .delete => if (self.compose_cursor < self.compose.items.len) {
                const end = nextCodepoint(self.compose.items, self.compose_cursor);
                try self.compose.replaceRange(self.allocator, self.compose_cursor, end - self.compose_cursor, "");
            },
            .left => self.compose_cursor = prevCodepoint(self.compose.items, self.compose_cursor),
            .right => self.compose_cursor = nextCodepoint(self.compose.items, self.compose_cursor),
            else => {},
        }
    }

    /// Keys in the dump view: a printable key edits the search line, Enter
    /// scans the file for it, ↓ walks the results, and Enter on one hands its
    /// magnet link to the source line and mounts it.
    fn handleDatabase(self: *App, key: term.Key) !void {
        switch (key) {
            .esc, .tab => {
                // Leaving the view stops a scan still running: a mount the
                // user went back to watch must not compete with the dump for
                // the disk. The matches collected so far stay on screen when
                // the view is opened again.
                self.db.stop();
                self.view = .history;
                self.focus = .input;
                self.db_results_focus = false;
            },
            .enter => if (self.db_results_focus)
                try self.mountDatabaseResult(self.db_selected)
            else
                try self.searchDatabase(),
            .down => {
                if (self.db.found.load(.monotonic) == 0) return;
                self.db_results_focus = true;
                self.db_selected +|= 1;
                self.clampDatabaseSelection();
            },
            .up => {
                if (!self.db_results_focus) return;
                if (self.db_selected == 0) {
                    self.db_results_focus = false;
                    return;
                }
                self.db_selected -= 1;
            },
            .text => |bytes| {
                // Typing always means editing the query, even after a search:
                // the previous results stay on screen until Enter replaces them.
                self.db_results_focus = false;
                try self.db_query.insertSlice(self.allocator, self.db_cursor, bytes);
                self.db_cursor += bytes.len;
            },
            .backspace => if (self.db_cursor > 0) {
                self.db_results_focus = false;
                const start = prevCodepoint(self.db_query.items, self.db_cursor);
                try self.db_query.replaceRange(self.allocator, start, self.db_cursor - start, "");
                self.db_cursor = start;
            },
            .delete => if (self.db_cursor < self.db_query.items.len) {
                self.db_results_focus = false;
                const end = nextCodepoint(self.db_query.items, self.db_cursor);
                try self.db_query.replaceRange(self.allocator, self.db_cursor, end - self.db_cursor, "");
            },
            .left => self.db_cursor = prevCodepoint(self.db_query.items, self.db_cursor),
            .right => self.db_cursor = nextCodepoint(self.db_query.items, self.db_cursor),
            .home => self.db_cursor = 0,
            .end => self.db_cursor = self.db_query.items.len,
            .ctrl_u => {
                self.db_query.clearRetainingCapacity();
                self.db_cursor = 0;
                self.db_results_focus = false;
            },
            else => {},
        }
    }

    fn clampDatabaseSelection(self: *App) void {
        const count: usize = @intCast(self.db.found.load(.monotonic));
        if (count == 0) {
            self.db_selected = 0;
            self.db_results_focus = false;
            return;
        }
        if (self.db_selected >= count) self.db_selected = count - 1;
    }

    /// Publishes the typed line with `rekarma <text>`: a one-shot send into the
    /// same room the recorder is in. The text is parked in `pending` and the tick
    /// spawns it once the recorder's listening port is known — finding a peer
    /// takes seconds, so the child runs behind the screen.
    fn sendMessage(self: *App) !void {
        const text = std.mem.trim(u8, self.compose.items, " \t");
        if (text.len == 0) {
            self.setStatus("пустая строка не отправляется", .warn);
            return;
        }
        if (self.options.rekarma_exe == null) {
            self.setStatus("rekarma не найден в PATH — укажите --rekarma <путь>", .err);
            return;
        }
        if (self.publish_pid != null or self.pending_len > 0) {
            self.setStatus("предыдущее сообщение ещё отправляется", .warn);
            return;
        }

        const n = @min(text.len, self.pending.len);
        @memcpy(self.pending[0..n], text[0..n]);
        self.pending_len = n;
        self.pending_since = self.tick;

        self.compose.clearRetainingCapacity();
        self.compose_cursor = 0;
        self.room_scroll = 0;

        var buf: [240]u8 = undefined;
        const note = std.fmt.bufPrint(&buf, "отправляю в комнату reKarma: {s}", .{text}) catch "";
        self.setStatus(note, .dim);
    }

    /// The spawn half of `sendMessage`, called from the tick: with the recorder's
    /// port the message is dialed straight into the room instead of waiting for
    /// discovery, and after a few seconds without one it goes out anyway.
    fn publishPending(self: *App) void {
        if (self.pending_len == 0 or self.publish_pid != null) return;

        const port = if (procs.recorderRunning(self.io))
            procs.recorderPort(self.allocator, self.io)
        else
            null;
        const waited = self.tick - self.pending_since;
        if (port == null and waited < recorder_wait_ticks) return;

        const text = self.pending[0..self.pending_len];
        const exe = self.options.rekarma_exe orelse {
            self.pending_len = 0;
            self.setStatus("rekarma не найден в PATH — укажите --rekarma <путь>", .err);
            return;
        };
        self.publish_pid = procs.publishMessage(self.io, exe, text, port) catch |err| {
            self.pending_len = 0;
            var buf: [200]u8 = undefined;
            const note = std.fmt.bufPrint(&buf, "отправка в комнату: {s}", .{@errorName(err)}) catch "";
            self.setStatus(note, .err);
            return;
        };

        const n = @min(text.len, self.published.len);
        @memcpy(self.published[0..n], text[0..n]);
        self.published_len = n;
        self.pending_len = 0;
    }

    fn handleInput(self: *App, key: term.Key) !void {
        // The install shortcut owns the keys while it is selected: Enter runs
        // the installer, Up returns to typing and any text key falls through
        // so the first character lands in the input line as usual.
        if (self.link_selected) {
            switch (key) {
                .down => {
                    self.link_index = (self.link_index + 1) % links.len;
                    return;
                },
                .up => {
                    if (self.link_index == 0) {
                        self.link_selected = false;
                    } else {
                        self.link_index -= 1;
                    }
                    return;
                },
                .esc => {
                    self.link_selected = false;
                    self.input.clearRetainingCapacity();
                    self.cursor = 0;
                    return;
                },
                .enter => return self.runLink(),
                .tab => {
                    self.link_selected = false;
                    if (self.list.items.items.len > 0) self.focus = .history;
                    return;
                },
                else => self.link_selected = false,
            }
        }

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
            .down => {
                self.link_selected = true;
                self.link_index = 0;
            },
            .ctrl_u => {
                self.input.clearRetainingCapacity();
                self.cursor = 0;
            },
            .enter => try self.startFromInput(),
            .tab => {
                self.link_selected = false;
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
                    try self.openEntry(self.files_entry);
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
        const link = (try magnet.parse(self.allocator, self.io, self.input.items)) orelse {
            self.setStatus("это не magnet-ссылка и не .torrent: нужен magnet:?xt=…, info-hash или путь к файлу", .err);
            return;
        };
        defer self.allocator.free(link);

        const dirs = try procs.dirsOf(self.allocator, self.config, link);
        defer self.allocator.free(dirs.mount);
        defer self.allocator.free(dirs.cache);

        self.input.clearRetainingCapacity();
        self.cursor = 0;

        // A link already in the history is moved up, not duplicated — and Enter
        // then means exactly what it means on that row: show its files when it
        // is mounted, retry the mount when it is not. Returning early for an
        // idle or failed row left the dump view unable to remount a release
        // that had been unmounted or had once failed.
        if (self.list.findIndex(link)) |existing| {
            self.list.moveToTop(existing);
            const moved = self.runtime.orderedRemove(existing);
            try self.runtime.insert(self.allocator, 0, moved);
            self.selected = 0;
            self.focus = .history;
            try self.saveHistory();
            try self.activate(0);
            return;
        }

        try self.list.insertTop(link, dirs.mount, "");
        try self.runtime.insert(self.allocator, 0, .{ .state = .mounting, .started_tick = self.tick });
        self.selected = 0;
        self.focus = .history;
        try self.saveHistory();

        // A daemon already holding this release keeps it: the row waits for
        // the mountpoint instead of a second daemon overwriting the pid.
        if (self.adoptRunningMount(0, dirs.cache)) return;

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

    /// Enter on the install shortcut. The ant-client installer is a curl|bash
    /// pipeline, so it runs in the background with its output in a log: a child
    /// writing to this terminal would paint over the panels. The pid goes into
    /// the same reap list as a player, so it never stays a zombie.
    fn installAutonomi(self: *App) !void {
        const dir = std.fs.path.dirname(self.config.cache) orelse ".";
        var log_buf: [512]u8 = undefined;
        const log_path = std.fmt.bufPrint(&log_buf, "{s}/autonomi-install.log", .{dir}) catch {
            self.setStatus("не удалось собрать путь к логу установщика", .err);
            return;
        };
        const pid = procs.installAutonomi(self.io, dir, log_path) catch |err| {
            var buf: [200]u8 = undefined;
            const text = std.fmt.bufPrint(&buf, "установщик ant-client: {s}", .{@errorName(err)}) catch "";
            self.setStatus(text, .err);
            return;
        };
        self.install_pid = pid;

        var buf: [240]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, "установщик ant-client запущен · лог: {s}", .{log_path}) catch "установщик ant-client запущен";
        self.setStatus(text, .ok);
        self.link_selected = false;
    }

    fn runLink(self: *App) !void {
        switch (links[self.link_index].action) {
            .autonomi_install => try self.installAutonomi(),
            .rutracker_database => try self.downloadRutrackerDatabase(),
            .rutracker_view => try self.openDatabase(),
            .room_history => try self.openRoom(),
        }
    }

    /// Enter on the dump shortcut: the right panel becomes the searchable
    /// RuTracker dump. The file is looked up in the startup directory — the
    /// same place `Install RuTracker.Org DataBase` unpacks it — and a missing
    /// one is a message with the shortcut that fixes it, not an empty list.
    fn openDatabase(self: *App) !void {
        self.link_selected = false;
        self.view = .database;
        self.focus = .history;
        self.db_results_focus = false;
        self.db_selected = 0;
        self.db_scroll = 0;

        const path = (try self.ensureDatabasePath()) orelse {
            self.setStatus(
                "rutracker-*.xml в каталоге запуска нет — скачайте базу ссылкой Install RuTracker.Org DataBase",
                .warn,
            );
            return;
        };

        var buf: [240]u8 = undefined;
        if (std.Io.Dir.cwd().statFile(self.io, path, .{})) |st| {
            const text = std.fmt.bufPrint(&buf, "база: {s} · {d} ГБ · введите слова через пробел и нажмите Enter", .{
                std.fs.path.basename(path), st.size / (1 << 30),
            }) catch "";
            self.setStatus(text, .dim);
        } else |_| {
            self.setStatus("база найдена, но не читается", .err);
        }
    }

    fn ensureDatabasePath(self: *App) !?[]const u8 {
        if (self.db_path) |path| return path;
        self.db_path = try findDatabase(self.allocator, self.io);
        return self.db_path;
    }

    /// Enter on the query line: one streaming scan of the dump behind the
    /// screen. The previous scan is cancelled first, so a refined query does not
    /// have to wait for the first one to reach the end of 30 GB.
    fn searchDatabase(self: *App) !void {
        const path = (try self.ensureDatabasePath()) orelse {
            self.setStatus(
                "rutracker-*.xml в каталоге запуска нет — скачайте базу ссылкой Install RuTracker.Org DataBase",
                .err,
            );
            return;
        };
        const query = std.mem.trim(u8, self.db_query.items, " \t");
        if (query.len == 0) {
            self.setStatus("пустой запрос — нечего искать", .warn);
            return;
        }
        const st = std.Io.Dir.cwd().statFile(self.io, path, .{}) catch {
            self.setStatus("база не читается: файл пропал из каталога запуска", .err);
            return;
        };

        self.db.start(path, query, st.size) catch |err| {
            var buf: [200]u8 = undefined;
            const text = std.fmt.bufPrint(&buf, "поиск по базе: {s}", .{@errorName(err)}) catch "";
            self.setStatus(text, .err);
            return;
        };
        self.db_results_focus = false;
        self.db_selected = 0;
        self.db_scroll = 0;
        self.db_reported = false;

        var buf: [220]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, "поиск «{s}» по {d} ГБ базы · Esc — назад", .{ query, st.size / (1 << 30) }) catch "";
        self.setStatus(text, .dim);
    }

    /// Enter on a result: its magnet link goes into the source line and the
    /// release is mounted from there, exactly as if it had been pasted.
    fn mountDatabaseResult(self: *App, index: usize) !void {
        var result: rutracker.Result = undefined;
        if (!self.db.resultAt(index, &result)) {
            self.setStatus("выберите строку результата стрелками", .warn);
            return;
        }
        var buf: [256]u8 = undefined;
        const link = result.magnet(&buf) orelse {
            self.setStatus("у результата нет info-hash — монтировать нечего", .err);
            return;
        };

        self.input.clearRetainingCapacity();
        try self.input.appendSlice(self.allocator, link);
        self.cursor = self.input.items.len;

        self.view = .history;
        self.focus = .input;
        self.db_results_focus = false;
        try self.startFromInput();
    }

    /// Reports the scan's outcome once: a finished scan, one that hit the
    /// result cap, or one whose file could not be read.
    fn pollDatabase(self: *App) void {
        if (self.db_reported) return;
        const outcome: rutracker.Outcome = @fromBackingInt(@intCast(self.db.outcome.load(.acquire)));
        if (outcome == .none) return;
        self.db_reported = true;

        const found = self.db.found.load(.monotonic);
        var buf: [240]u8 = undefined;
        switch (outcome) {
            .done => {
                self.resetDatabaseSelection();
                const text = if (found == 0)
                    std.fmt.bufPrint(&buf, "в базе ничего не найдено по этому запросу", .{}) catch ""
                else
                    std.fmt.bufPrint(&buf, "база прочитана: {d} совпадений · ↓ и Enter — смонтировать", .{found}) catch "";
                self.setStatus(text, if (found == 0) .warn else .ok);
            },
            .stopped => {
                self.resetDatabaseSelection();
                const text = std.fmt.bufPrint(&buf, "найдено {d} — поиск остановлен на лимите, уточните запрос", .{found}) catch "";
                self.setStatus(text, if (found == 0) .warn else .dim);
            },
            .failed => self.setStatus("не удалось прочитать базу: файл повреждён или это не дамп", .err),
            .none => {},
        }
    }

    /// The matches are sorted by date once the scan ends, so the row the
    /// selection stood on now holds another release: it goes back to the
    /// newest one instead of mounting something the user did not pick.
    fn resetDatabaseSelection(self: *App) void {
        self.db_selected = 0;
        self.db_scroll = 0;
    }

    /// Enter on the room shortcut: the right panel turns into the room, and a
    /// recorder is started when none is running — without one the file never
    /// grows, sending has nowhere to go and the view would look broken. The
    /// recorder is a daemon of its own and, like a mount, outlives the interface.
    fn openRoom(self: *App) !void {
        self.link_selected = false;

        const started = !procs.recorderRunning(self.io);
        if (started) {
            const exe = self.options.rekarma_exe orelse {
                self.setStatus("rekarma не найден в PATH — укажите --rekarma <путь>", .err);
                return;
            };
            procs.startRecorder(self.io, exe) catch |err| {
                var buf: [200]u8 = undefined;
                const text = std.fmt.bufPrint(&buf, "запись комнаты reKarma: {s}", .{@errorName(err)}) catch "";
                self.setStatus(text, .err);
                return;
            };
            self.room_started = true;
        }

        self.view = .room;
        // The room owns the keys while it is open, so the cursor leaves the
        // source line: everything typed goes into the message line instead.
        self.focus = .history;
        self.room_scroll = 0;
        self.room_read = false;
        self.refreshRoom();

        var buf: [220]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, "{s} · комната reKarma · {d} сообщ. · {s}", .{
            if (started) "запись запущена, лог " ++ procs.room_log_file else "запись уже идёт",
            self.room_lines.items.len,
            procs.room_file,
        }) catch "";
        self.setStatus(text, .ok);
    }

    /// Reads the room's file when it changed: one stat per tick, one read per
    /// message. The lines are copies in the app's allocator and are replaced as a
    /// whole, so the panel can never print half a message.
    fn refreshRoom(self: *App) void {
        const st = std.Io.Dir.cwd().statFile(self.io, procs.room_file, .{}) catch {
            self.room_absent = true;
            self.room_read = true;
            self.clearRoom();
            return;
        };
        self.room_absent = false;
        if (self.room_read and st.size == self.room_size and st.mtime.nanoseconds == self.room_mtime) return;

        self.room_size = st.size;
        self.room_mtime = st.mtime.nanoseconds;
        self.room_read = true;
        self.clearRoom();

        var scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        const data = std.Io.Dir.cwd().readFileAlloc(
            self.io,
            procs.room_file,
            scratch.allocator(),
            .limited(1 << 20),
        ) catch return;

        var it = std.mem.splitScalar(u8, data, '\n');
        while (it.next()) |line| {
            if (line.len == 0) continue;
            const copy = self.allocator.dupe(u8, line) catch return;
            self.room_lines.append(self.allocator, copy) catch {
                self.allocator.free(copy);
                return;
            };
            if (self.room_lines.items.len > room_max_lines) {
                self.allocator.free(self.room_lines.orderedRemove(0));
            }
        }
    }

    fn clearRoom(self: *App) void {
        for (self.room_lines.items) |line| self.allocator.free(line);
        self.room_lines.clearRetainingCapacity();
    }

    /// Enter on the RuTracker shortcut: `ant file download` fetches the archive
    /// and `xz -d -f` unpacks it in the startup directory (the program's own
    /// folder), removing the archive by itself. Backgrounded like the installer,
    /// with the tool output in a log rather than over the panels.
    fn downloadRutrackerDatabase(self: *App) !void {
        const ant = self.options.ant_exe orelse {
            self.setStatus("ant не найден в PATH — установите ant-client", .err);
            return;
        };
        const xz = self.options.xz_exe orelse {
            self.setStatus("xz не найден в PATH — установите xz-utils", .err);
            return;
        };

        var cmd_buf: [2048]u8 = undefined;
        const command = procs.rutrackerCommand(&cmd_buf, ant, xz) catch {
            self.setStatus("не удалось собрать команду загрузки базы", .err);
            return;
        };

        const dir = std.fs.path.dirname(self.config.cache) orelse ".";
        var log_buf: [512]u8 = undefined;
        const log_path = std.fmt.bufPrint(&log_buf, "{s}/rutracker-install.log", .{dir}) catch {
            self.setStatus("не удалось собрать путь к логу загрузки", .err);
            return;
        };
        const pid = procs.runInBackground(self.io, command, dir, log_path) catch |err| {
            var buf: [200]u8 = undefined;
            const text = std.fmt.bufPrint(&buf, "загрузка базы: {s}", .{@errorName(err)}) catch "";
            self.setStatus(text, .err);
            return;
        };
        self.download_pid = pid;

        var buf: [240]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, "загрузка базы RuTracker запущена · лог: {s}", .{log_path}) catch "загрузка базы RuTracker запущена";
        self.setStatus(text, .ok);
        self.link_selected = false;
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
                const dirs = try procs.dirsOf(self.allocator, self.config, entry.magnet);
                defer self.allocator.free(dirs.mount);
                defer self.allocator.free(dirs.cache);

                // A daemon already working this release is the mount, whatever
                // the timeout wrote on the row: starting a second one would
                // share the release's cache dir and overwrite its pid.
                if (self.adoptRunningMount(index, dirs.cache)) return;

                const exe = self.options.rekarma_exe orelse {
                    self.setStatus("rekarma не найден в PATH — укажите --rekarma <путь>", .err);
                    return;
                };
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

    /// Takes over a daemon that is still running a release instead of starting
    /// a second one: ziggurat restarted while the metadata was on its way, or a
    /// failed row is retried while its daemon is alive after all. The row waits
    /// on the mountpoint like any other, and the pid file keeps naming the one
    /// process that holds the mount.
    fn adoptRunningMount(self: *App, index: usize, cache_dir: []const u8) bool {
        if (!procs.mountRunning(self.io, cache_dir)) return false;
        const rt = &self.runtime.items[index];
        rt.state = .mounting;
        rt.started_tick = self.tick;
        rt.note_len = 0;
        self.setStatus("монтирование уже идёт — ждём метаданные", .dim);
        return true;
    }

    /// The status a mount that just came up earns: what the release holds. A
    /// book (PDF/EPUB), an archive or a release whose files are all unknown
    /// extensions mounts correctly and then has nothing to hand to a media
    /// player, so saying "смонтирован" alone reads as a failure — the user sees
    /// no window open and cannot tell the mount from a broken one. One readdir
    /// at the mount transition, never per frame.
    fn reportMountMedia(self: *App, index: usize) void {
        const entry = self.list.items.items[index];
        var scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        var found: std.ArrayList(procs.Entry) = .empty;
        defer found.deinit(self.allocator);
        procs.listEntries(self.allocator, scratch.allocator(), self.io, entry.mount, &found) catch {};

        var files: usize = 0;
        var dirs: usize = 0;
        for (found.items) |item| {
            if (item.dir) dirs += 1 else files += 1;
        }

        var buf: [240]u8 = undefined;
        if (files == 0 and dirs == 0) {
            const text = std.fmt.bufPrint(&buf, "релиз смонтирован, но файлов в нём нет — каталог {s}", .{entry.mount}) catch "релиз смонтирован, но файлов в нём нет";
            self.setStatus(text, .warn);
            return;
        }
        const text = std.fmt.bufPrint(&buf, "релиз смонтирован · файлов: {d}, папок: {d} · Enter — открыть", .{ files, dirs }) catch "релиз смонтирован · Enter — открыть";
        self.setStatus(text, .ok);
    }

    fn openFiles(self: *App, index: usize) !void {
        if (index >= self.list.items.items.len) return;
        const entry = self.list.items.items[index];

        _ = self.files_arena.reset(.retain_capacity);
        self.files.clearRetainingCapacity();
        const arena = self.files_arena.allocator();
        self.files_root = arena.dupe(u8, entry.mount) catch "";
        procs.listEntries(self.allocator, arena, self.io, entry.mount, &self.files) catch {
            self.setStatus("не удалось прочитать каталог релиза", .err);
            return;
        };
        self.files_entry = 0;
        self.files_scroll = 0;

        if (self.files.items.len == 0) {
            self.view = .files;
            self.setStatus("каталог релиза пуст — метаданные без файлов", .warn);
            return;
        }
        self.view = .files;

        var buf: [200]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, "{d} записей в {s} · Enter — открыть", .{
            self.files.items.len, entry.mount,
        }) catch "файлы релиза · Enter — открыть";
        self.setStatus(text, .dim);
    }

    /// Enter on a row of the files view: the file goes to the desktop's default
    /// application, whatever it is — a film to a player, a book to a reader, a
    /// folder to a file manager. That program reads through the mount, so its
    /// reads are what pull the pieces.
    fn openEntry(self: *App, index: usize) !void {
        if (index >= self.files.items.len) return;
        const item = self.files.items[index];

        const exe = self.options.opener_exe orelse {
            self.setStatus("xdg-open не найден в PATH — укажите --open <путь>", .err);
            return;
        };
        const pid = procs.launch(self.io, exe, item.path) catch |err| {
            var buf: [200]u8 = undefined;
            const text = std.fmt.bufPrint(&buf, "открыть файл: {s}", .{@errorName(err)}) catch "";
            self.setStatus(text, .err);
            return;
        };
        try self.opened.append(self.allocator, pid);

        var buf: [200]u8 = undefined;
        const base = std.fs.path.basename(item.path);
        const text = std.fmt.bufPrint(&buf, "открываю: {s}", .{truncateTo(base, 120)}) catch "открываю файл";
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
    /// that came up, one that never will, and finished children that would
    /// otherwise stay zombies.
    fn housekeeping(self: *App) void {
        for (self.list.items.items, 0..) |entry, i| {
            const rt = &self.runtime.items[i];
            if (rt.state != .mounting) continue;

            if (procs.isMounted(self.io, entry.mount)) {
                rt.state = .mounted;
                rt.note_len = 0;
                self.nameEntry(i);
                self.reportMountMedia(i);
                // The row the user is looking at opens its own listing: what a
                // mount holds is the answer to the keypress that started it, and
                // waiting for a second Enter to see any names is what made a
                // mounted release look like a failed one.
                if (self.view == .history and self.focus == .history and self.selected == i) {
                    self.openFiles(i) catch {};
                }
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

        for (self.opened.items) |pid| procs.reap(pid);
        self.opened.clearRetainingCapacity();

        // The room view is a tail: it has to follow the file while it is open,
        // and costs one stat when nothing arrived.
        if (self.view == .room) self.refreshRoom();

        // A finished dump scan reports itself once; the panel reads the
        // progress atomics while the worker is still running.
        if (self.view == .database) self.pollDatabase();

        // A message waiting for the recorder's port is spawned here, out of the
        // key handler: the wait is bounded in ticks, not in blocking calls.
        if (self.pending_len > 0) self.publishPending();

        // The publish is a one-shot `rekarma <message>`, so its exit is the
        // answer: code 0 means the room has it.
        if (self.publish_pid) |pid| {
            if (procs.reapCode(pid)) |code| {
                self.publish_pid = null;
                var buf: [240]u8 = undefined;
                if (code == 0) {
                    const text = std.fmt.bufPrint(&buf, "опубликовано в комнате reKarma: {s}", .{
                        self.published[0..self.published_len],
                    }) catch "";
                    self.setStatus(text, .ok);
                } else {
                    const text = std.fmt.bufPrint(&buf, "rekarma не смогла опубликовать (код {d})", .{code}) catch "";
                    self.setStatus(text, .err);
                }
            }
        }

        // The installer is long-running, so keep its pid until it actually
        // exits: dropping it on the first poll would leave a zombie behind.
        if (self.install_pid) |pid| {
            if (procs.reapIfDone(pid)) {
                self.install_pid = null;
                self.setStatus("установщик ant-client завершён", .ok);
            }
        }
        if (self.download_pid) |pid| {
            if (procs.reapIfDone(pid)) {
                self.download_pid = null;
                self.setStatus("база RuTracker распакована · rutracker-20261031.xml", .ok);
            }
        }
    }

    /// Names a release the moment it mounts: the biggest file inside is the
    /// only name a magnet link does not carry. Directories are skipped — their
    /// size is not known without walking them, and a folder name is a worse
    /// label than the file it holds.
    fn nameEntry(self: *App, index: usize) void {
        const entry = &self.list.items.items[index];
        if (entry.title.len > 0) return;

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        var found: std.ArrayList(procs.Entry) = .empty;
        defer found.deinit(self.allocator);
        procs.listEntries(self.allocator, arena.allocator(), self.io, entry.mount, &found) catch return;

        var best: ?procs.Entry = null;
        for (found.items) |item| {
            if (item.dir) continue;
            if (best == null or item.size > best.?.size) best = item;
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
        // The recorder this session started is a daemon like a mount: it keeps
        // writing the room after the screen is gone, so say how to stop it.
        if (self.room_started) {
            try out.print("ziggurat: комната reKarma пишется в {s} — kill $(cat {s})\n", .{
                procs.room_file, procs.room_pid_file,
            });
        }

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
        var room_cursor: ?[2]u16 = null;
        var db_cursor: ?[2]u16 = null;
        switch (self.view) {
            .history => self.drawHistoryPanel(&frame, top, right_left, height, right_width),
            .files => self.drawFilesPanel(&frame, top, right_left, height, right_width),
            .room => room_cursor = self.drawRoomPanel(&frame, top, right_left, height, right_width),
            .database => db_cursor = self.drawDatabasePanel(&frame, top, right_left, height, right_width),
        }
        frame.at(top, size.cols);
        frame.endRow();
        frame.at(bottom, size.cols);
        frame.endRow();

        drawBox(&frame, top, 1, height, left_width, "Ввод");
        drawBox(&frame, top, right_left, height, right_width, switch (self.view) {
            .history => "История",
            .files => "Содержимое релиза",
            .room => "Комната reKarma",
            .database => "База RuTracker.Org",
        });

        self.drawFooter(&frame, size);

        // The cursor is only shown where typing goes; everywhere else the
        // selection highlight is the pointer. In the room that is the compose
        // line, not the source line; in the dump it is the query.
        const typing_at = switch (self.view) {
            .room => room_cursor,
            .database => db_cursor,
            else => cursor_at,
        };
        if (typing_at) |pos| {
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
        frame.put(.plain, "p2p-релизы: magnet/.torrent → монтирование → приложение по умолчанию");
        frame.endRow();

        var buf: [128]u8 = undefined;
        const right = if (self.options.rekarma_version.len > 0)
            std.fmt.bufPrint(&buf, "rekarma {s} · ziggurat {s} ", .{
                self.options.rekarma_version, self.options.version,
            }) catch return
        else
            std.fmt.bufPrint(&buf, "ziggurat {s} ", .{self.options.version}) catch return;
        const width = term.displayWidth(right);
        const used = 10 + term.displayWidth("p2p-релизы: magnet/.torrent → монтирование → приложение по умолчанию");
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
            frame.put(.dim, "magnet:?xt=… · info-hash · путь к .torrent");
        }
        frame.endRow();

        // The shortcuts under the prompt: `↓` selects them, Enter runs the job
        // instead of mounting the line. Labels are clipped to the panel.
        const link_focused = focused and self.link_selected;
        for (links, 0..) |link, i| {
            const link_row = top + 2 + @as(u16, @intCast(i));
            if (link_row >= top + height - 1) break;
            const selected = link_focused and i == self.link_index;
            frame.at(link_row, left + 1);
            frame.put(if (selected) .selected else .dim, if (selected) "▸ " else "  ");
            frame.put(if (selected) .selected else .accent, truncateTo(link.label, width -| 4));
            frame.endRow();
        }

        // Under the input: what the selected row is doing right now. A mount
        // waiting for the swarm must not look like a hung program.
        var row = top + 2 + @as(u16, @intCast(links.len));
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
            frame.put(.dim, "Enter — выполнить · ↑↓ — ссылки");
            frame.at(row + 2, left + 1);
            frame.put(.dim, "Tab — к истории, Esc — очистить");
        }

        if (!focused or self.link_selected) return null;
        const cursor_col = left + 3 + (cursor_cols - offset);
        return .{ top + 1, @min(cursor_col, left + width - 2) };
    }

    /// The room, right panel: the newest messages filling the height and a compose
    /// line on the last row, so reading what arrived and answering it are one
    /// screen. Returns where the typing cursor belongs.
    fn drawRoomPanel(self: *App, frame: *term.Frame, top: u16, left: u16, height: u16, width: u16) ?[2]u16 {
        const inner_width: u16 = width -| 2;
        const text_width: u16 = inner_width -| 2;

        var head_buf: [128]u8 = undefined;
        const head = if (self.room_absent)
            std.fmt.bufPrint(&head_buf, "комната reKarma · {s} нет", .{procs.room_file}) catch ""
        else
            std.fmt.bufPrint(&head_buf, "комната reKarma · {d} сообщ. · ↑↓ — прокрутка · Home/End", .{
                self.room_lines.items.len,
            }) catch "";
        frame.at(top + 1, left + 2);
        frame.put(.dim, truncateTo(head, inner_width -| 1));
        frame.endRow();

        // The compose line owns the row above the bottom border; the messages get
        // everything between the header and it.
        const compose_row = top + height - 2;
        const rows: usize = if (compose_row > top + 2) compose_row - (top + 2) else 0;
        self.room_rows = rows;

        const total = self.room_lines.items.len;
        if (self.room_scroll > total -| rows) self.room_scroll = total -| rows;
        const end = total - self.room_scroll;
        const start = end -| rows;

        if (total == 0) {
            frame.at(top + 2, left + 2);
            frame.put(.dim, truncateTo(
                if (self.room_absent) "лог появится с первым сообщением" else "пока никто ничего не написал",
                inner_width -| 1,
            ));
            frame.endRow();
        }

        var i: usize = 0;
        while (i < rows and start + i < end) : (i += 1) {
            const row = top + 2 + @as(u16, @intCast(i));
            if (row >= compose_row) break;

            const line = parseRoomLine(self.room_lines.items[start + i]);
            frame.at(row, left + 1);
            frame.put(.dim, " ");
            var used: u16 = 2;
            if (line.stamp.len > 0) {
                frame.put(.dim, line.stamp);
                frame.put(.dim, " ");
                used += 6;
            }
            frame.put(.plain, truncateTo(line.text, text_width -| used));
            frame.endRow();
        }

        // What the user is about to say: the same scrolling the source line does,
        // so a long message keeps the caret visible in a narrow panel.
        const compose_width: u16 = inner_width -| 4;
        const cursor_cols = term.displayWidth(self.compose.items[0..self.compose_cursor]);
        const offset = if (cursor_cols >= compose_width) cursor_cols - compose_width + 1 else 0;
        frame.at(compose_row, left + 1);
        frame.put(.accent, ">");
        frame.put(.plain, " ");
        frame.put(.plain, skipCols(self.compose.items, offset));
        if (self.compose.items.len == 0) frame.put(.dim, "сообщение в комнату · Enter — отправить");
        frame.endRow();

        const cursor_col = left + 3 + (cursor_cols - offset);
        return .{ compose_row, @min(cursor_col, left + width - 2) };
    }

    /// The RuTracker dump, right panel: a search line, how far the scan has
    /// got, and the releases it matched. Enter on a row mounts it, so a search
    /// ends in the same place a pasted magnet does.
    fn drawDatabasePanel(self: *App, frame: *term.Frame, top: u16, left: u16, height: u16, width: u16) ?[2]u16 {
        const inner_width: u16 = width -| 2;

        const query_row = top + 1;
        const prompt_width: u16 = inner_width -| 4;
        const cursor_cols = term.displayWidth(self.db_query.items[0..self.db_cursor]);
        const offset = if (cursor_cols >= prompt_width) cursor_cols - prompt_width + 1 else 0;
        frame.at(query_row, left + 1);
        frame.put(if (self.db_results_focus) .dim else .accent, if (self.db_results_focus) " " else ">");
        frame.put(.plain, " ");
        frame.put(.plain, skipCols(self.db_query.items, offset));
        if (self.db_query.items.len == 0) frame.put(.dim, "запрос по базе RuTracker · слова через пробел · Enter — искать");
        frame.endRow();

        const scanned = self.db.scanned.load(.monotonic);
        const total = self.db.total.load(.monotonic);
        const found = self.db.found.load(.monotonic);
        var head_buf: [160]u8 = undefined;
        const head = if (self.db.running.load(.monotonic))
            std.fmt.bufPrint(&head_buf, "читаю {d} МБ из {d} МБ · найдено {d}", .{
                scanned / (1 << 20), total / (1 << 20), found,
            }) catch ""
        else if (found > 0)
            std.fmt.bufPrint(&head_buf, "найдено {d} · ↓ — выбор · Enter — смонтировать", .{found}) catch ""
        else if (self.db_path) |path|
            std.fmt.bufPrint(&head_buf, "{s}", .{std.fs.path.basename(path)}) catch ""
        else
            "rutracker-*.xml в каталоге запуска не найден";
        frame.at(top + 2, left + 2);
        frame.put(.dim, truncateTo(head, inner_width -| 1));
        frame.endRow();

        // Every release takes three rows — the date and section with its size,
        // the title, then the address of its page on the tracker — so the query
        // and the progress line leave a third as many releases on screen.
        // Scrolling counts releases, not rows.
        const rows: usize = if (height > 4) height - 4 else 0;
        const recs: usize = rows / 3;
        self.db_rows = recs;
        if (self.db_selected < self.db_scroll) self.db_scroll = self.db_selected;
        if (recs > 0 and self.db_selected >= self.db_scroll + recs) {
            self.db_scroll = self.db_selected - recs + 1;
        }

        if (self.db.mutex.tryLock()) {
            defer self.db.mutex.unlock();
            const items = self.db.results.items;
            var i: usize = 0;
            while (i < recs and self.db_scroll + i < items.len) : (i += 1) {
                const index = self.db_scroll + i;
                const result = &items[index];
                const selected = self.db_results_focus and index == self.db_selected;
                const row = top + 3 + @as(u16, @intCast(i * 3));

                var size_buf: [24]u8 = undefined;
                const size = sizeText(&size_buf, result.size);
                const size_width = term.displayWidth(size);
                const date = result.dateText();
                const forum_text = result.forumText();
                const forum = if (forum_text.len > 0) forum_text else "раздел не указан";
                // The date leads the line and takes its ten columns plus a gap,
                // but only when the dump recorded one: an empty date must not
                // shorten the section for the whole list.
                const date_width: u16 = if (date.len > 0) term.displayWidth(date) + 1 else 0;
                // Two columns go to the selection marker, two to the gap the
                // size leaves on the right.
                const room_i: i32 = @as(i32, inner_width) - @as(i32, size_width) - 5 - @as(i32, date_width);
                const room: u16 = @intCast(@max(room_i, 4));
                const shown = truncateTo(forum, room);

                // The date, then the section on the left, the size against the
                // right edge, so sizes line up down the panel whatever the
                // section's length.
                frame.at(row, left + 1);
                frame.put(if (selected) .selected else .dim, if (selected) "▸" else " ");
                frame.put(if (selected) .selected else .accent, " ");
                if (date.len > 0) {
                    frame.put(if (selected) .selected else .dim, date);
                    frame.put(if (selected) .selected else .accent, " ");
                }
                frame.put(if (selected) .selected else .accent, shown);
                const used = term.displayWidth(shown) + size_width + date_width;
                frame.spaces(if (inner_width > used + 4) inner_width - used - 4 else 1);
                frame.put(if (selected) .selected else .dim, size);
                frame.endRow();

                frame.at(row + 1, left + 3);
                frame.put(if (selected) .selected else .plain, truncateTo(result.title, inner_width -| 2));
                frame.endRow();

                // The release's page on a row of its own: the scheme is what a
                // terminal needs to make the address clickable, and its 53
                // columns fit here where they never did beside the section.
                var link_buf: [64]u8 = undefined;
                if (result.link(&link_buf)) |url| {
                    frame.at(row + 2, left + 3);
                    frame.put(if (selected) .selected else .plain, truncateTo(url, inner_width -| 2));
                    frame.endRow();
                }
            }
        } else {
            // The worker holds the lock only while it appends a match; when it
            // does, the frame shows the progress line without the list rather
            // than blocking the screen on it.
            const row = top + 3;
            if (row + 1 < top + height) {
                frame.at(row, left + 2);
                frame.put(.dim, "…");
                frame.endRow();
            }
        }

        if (self.db_results_focus) return null;
        const cursor_col = left + 3 + (cursor_cols - offset);
        return .{ query_row, @min(cursor_col, left + width - 2) };
    }

    fn drawHistoryPanel(self: *App, frame: *term.Frame, top: u16, left: u16, height: u16, width: u16) void {
        const rows = height - 2;
        const inner_width = width - 2;
        const entries = self.list.items.items;

        if (entries.len == 0) {
            frame.at(top + 1, left + 2);
            frame.put(.dim, "пока пусто: вставьте magnet-ссылку или путь к .torrent слева");
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

        var files: usize = 0;
        var dirs: usize = 0;
        for (self.files.items) |item| {
            if (item.dir) dirs += 1 else files += 1;
        }

        frame.at(top + 1, left + 2);
        var head: [110]u8 = undefined;
        const head_text = std.fmt.bufPrint(&head, "файлов: {d} · папок: {d} · Enter — открыть", .{ files, dirs }) catch "";
        frame.put(.dim, head_text);
        frame.endRow();

        const visible_rows = height - 3;
        if (self.files_entry < self.files_scroll) self.files_scroll = self.files_entry;
        if (self.files_entry >= self.files_scroll + visible_rows) self.files_scroll = self.files_entry - visible_rows + 1;

        var i: usize = 0;
        while (i < visible_rows and self.files_scroll + i < self.files.items.len) : (i += 1) {
            const index = self.files_scroll + i;
            const item = self.files.items[index];
            const selected = index == self.files_entry;
            const row = top + 2 + @as(u16, @intCast(i));

            // The tree: depth comes from the path below the mount, so a folder
            // and what is inside it read as one block.
            const rel = relUnder(item.path, self.files_root);
            const depth: u16 = @intCast(@min(depthOf(rel), 8));
            const indent: u16 = depth * 2;

            var size_buf: [24]u8 = undefined;
            const tail = if (item.dir) "папка" else sizeText(&size_buf, item.size);

            frame.at(row, left + 1);
            frame.put(if (selected) .selected else .dim, if (selected) "▸" else " ");
            frame.put(if (selected) .selected else .plain, " ");
            frame.spaces(indent);
            const room_i: i32 = @as(i32, inner_width) - @as(i32, term.displayWidth(tail)) - 6 - @as(i32, indent);
            const room: u16 = @intCast(@max(room_i, 4));
            frame.put(if (selected) .selected else @as(term.Style, if (item.dir) .accent else .plain), truncateTo(std.fs.path.basename(rel), room));
            if (item.dir) frame.put(if (selected) .selected else .accent, "/");
            frame.put(if (selected) .selected else .dim, "  ");
            frame.put(if (selected) .selected else .dim, tail);
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
                .input => "Ctrl-C — выход · Tab — история · Enter — смонтировать · ↓ — ссылки",
                .history => "↑↓ — выбор · Enter — открыть · u — отмонтировать · x — удалить · q — выход",
            },
            .files => "↑↓ — выбор · Enter — открыть · Esc — назад · Ctrl-C — выход",
            .room => "Enter — отправить · ↑↓ — прокрутка · Home/End · Esc — назад · Ctrl-C — выход",
            .database => "Enter — поиск · ↓ — результаты · Enter — смонтировать · Esc — назад",
        };
        frame.put(.dim, hints);
        frame.endRow();
    }
};

/// The dump the viewer reads: the newest `rutracker-*.xml` in the startup
/// directory, which is where the download shortcut unpacks it. A copy of the
/// name is returned because the path outlives the scan thread that reads it.
fn findDatabase(allocator: std.mem.Allocator, io: Io) !?[]u8 {
    var dir = std.Io.Dir.cwd().openDir(io, ".", .{ .iterate = true }) catch return null;
    defer dir.close(io);

    var best: ?[]u8 = null;
    errdefer if (best) |path| allocator.free(path);
    var best_ns: i96 = std.math.minInt(i96);

    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.startsWith(u8, entry.name, "rutracker-")) continue;
        if (!std.mem.endsWith(u8, entry.name, ".xml")) continue;

        const st = std.Io.Dir.cwd().statFile(io, entry.name, .{}) catch continue;
        if (st.mtime.nanoseconds <= best_ns) continue;

        const copy = try allocator.dupe(u8, entry.name);
        if (best) |old| allocator.free(old);
        best = copy;
        best_ns = st.mtime.nanoseconds;
    }
    return best;
}

fn sizeText(buf: []u8, bytes: u64) []const u8 {
    const units = [_][]const u8{ "Б", "КБ", "МБ", "ГБ", "ТБ" };
    var value: f64 = @floatFromInt(bytes);
    var unit: usize = 0;
    while (value >= 1024.0 and unit + 1 < units.len) : (unit += 1) value /= 1024.0;
    if (unit == 0) return std.fmt.bufPrint(buf, "{d} {s}", .{ bytes, units[0] }) catch "";
    return std.fmt.bufPrint(buf, "{d:.1} {s}", .{ value, units[unit] }) catch "";
}

const RoomLine = struct { stamp: []const u8, text: []const u8 };

/// One recorder line, "<ISO stamp> <peer id> <message>", split for the panel: the
/// date and the peer id are bookkeeping a 26-column panel cannot afford, and the
/// time of day is the only part of the stamp it can use. A line the recorder did
/// not write is shown as it is rather than mangled.
fn parseRoomLine(line: []const u8) RoomLine {
    if (line.len > 22 and line[4] == '-' and line[10] == 'T' and line[19] == 'Z' and line[20] == ' ') {
        var rest = line[21..];
        while (rest.len > 0 and rest[0] == ' ') rest = rest[1..];
        if (std.mem.indexOfScalar(u8, rest, ' ')) |at| {
            return .{ .stamp = line[11..16], .text = rest[at + 1 ..] };
        }
    }
    return .{ .stamp = "", .text = line };
}

test "tui: a room line is shown as its time and its message" {
    const recorded = parseRoomLine("2026-10-16T06:44:42Z ffead4bba412 msg_1");
    try testing.expectEqualStrings("06:44", recorded.stamp);
    try testing.expectEqualStrings("msg_1", recorded.text);

    // Anything else stays whole: the recorder is the only writer of that file,
    // but a hand-edited line must not lose its text to a failed split.
    const plain = parseRoomLine("не строка записи");
    try testing.expectEqualStrings("", plain.stamp);
    try testing.expectEqualStrings("не строка записи", plain.text);
}

/// Keeps a title inside its column, on a codepoint boundary.
fn truncateTo(text: []const u8, cols: u16) []const u8 {
    if (term.displayWidth(text) <= cols or cols == 0) return text;
    return term.clip(text, cols);
}

/// The part of `path` below `root`: the mount prefix is the same on every row
/// of the files view and only eats the width a name needs.
fn relUnder(path: []const u8, root: []const u8) []const u8 {
    if (root.len == 0 or path.len <= root.len) return path;
    if (std.mem.startsWith(u8, path, root) and path[root.len] == '/') return path[root.len + 1 ..];
    return path;
}

/// How deep a path sits below the mount root, for the tree indent.
fn depthOf(rel: []const u8) usize {
    return std.mem.count(u8, rel, "/");
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
    // 'щ' is two bytes: stepping forward from its start lands after both.
    try testing.expectEqual(@as(usize, 4), nextCodepoint(text, 2));
    try testing.expectEqual(@as(usize, 2), prevCodepoint(text, 3));
    try testing.expectEqual(@as(usize, 0), prevCodepoint(text, 0));
    try testing.expectEqual(text.len, nextCodepoint(text, text.len));
}

test "tui: skipping columns keeps the utf-8 text valid" {
    try testing.expectEqualStrings("вет", skipCols("привет", 3));
    try testing.expectEqualStrings("привет", skipCols("привет", 0));
}

test "tui: a release row is printed below its mount and indented by its depth" {
    try testing.expectEqualStrings("CD1/01.flac", relUnder("mnt/97bcd8ad/CD1/01.flac", "mnt/97bcd8ad"));
    try testing.expectEqualStrings("book.pdf", relUnder("mnt/97bcd8ad/book.pdf", "mnt/97bcd8ad"));
    // A path that does not start with the root is left alone rather than cut.
    try testing.expectEqualStrings("other/x", relUnder("other/x", "mnt/97bcd8ad"));
    try testing.expectEqual(@as(usize, 0), depthOf("book.pdf"));
    try testing.expectEqual(@as(usize, 2), depthOf("CD1/Art/cover.jpg"));
}

test "tui: sizes are reported in the largest unit that fits" {
    var buf: [24]u8 = undefined;
    try testing.expectEqualStrings("512 Б", sizeText(&buf, 512));
    try testing.expectEqualStrings("1.5 КБ", sizeText(&buf, 1536));
    try testing.expectEqualStrings("2.0 ГБ", sizeText(&buf, 2 * 1024 * 1024 * 1024));
}
