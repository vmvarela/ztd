//! Read-only terminal browser for the store: a collapsible tree of lists and
//! documents beside a pager, refreshed when the files change on disk.
//! Explicitly opened items collect in a tab strip above the header.
//!
//! The viewer never mutates the store and holds no lock. It re-reads on a
//! one-second tick: editors and `ztd` write atomically, so a changed file is
//! complete by the time it is read.

const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const engine = @import("engine.zig");
const hoy = @import("hoy.zig");
const model = @import("model.zig");
const platform = @import("platform.zig");
const theme = @import("theme.zig");
const tabs = @import("tabs.zig");

const Allocator = std.mem.Allocator;
const Style = vaxis.Style;
const Color = vaxis.Color;

pub fn run(
    io: std.Io,
    gpa: Allocator,
    env_map: *std.process.Environ.Map,
    root: []const u8,
    today: platform.Date,
) !u8 {
    var eng_arena = std.heap.ArenaAllocator.init(gpa);
    defer eng_arena.deinit();
    var eng = try engine.Engine.init(io, eng_arena.allocator(), root, today, false);
    defer eng.deinit();
    // A viewer must not block writers in another terminal.
    eng.store.unlock();

    var m = try Model.init(io, gpa, &eng, root, env_map.get("HOME") orelse "", env_map.get("NO_COLOR") != null);
    defer m.deinit();

    const buffer = try gpa.alloc(u8, 64 * 1024);
    defer gpa.free(buffer);

    var app = try vxfw.App.init(io, gpa, env_map, buffer);
    defer app.deinit();
    try app.run(m.widget(), .{ .framerate = 30 });
    return 0;
}

const section_count = 13;

const Section = enum(u8) {
    hoy,
    inbox,
    next,
    waiting,
    someday,
    projects,
    plans,
    reviews,
    knowledge,
    journal,
    goals,
    routines,
    archive,
};

const sections = std.enums.values(Section);

fn sectionName(s: Section) []const u8 {
    return switch (s) {
        .hoy => "Today",
        .inbox => "Inbox",
        .next => "Next",
        .waiting => "Waiting",
        .someday => "Someday",
        .projects => "Projects",
        .plans => "Plans",
        .reviews => "Reviews",
        .knowledge => "Knowledge",
        .journal => "Journal",
        .goals => "Goals",
        .routines => "Routines",
        .archive => "Archive",
    };
}

const Item = struct {
    section: Section,
    /// Task ID or store-relative path; stable across reloads.
    key: []const u8,
    title: []const u8,
    detail: []const u8,
    /// File backing the item; the doc for tasks is pre-rendered instead.
    path: []const u8,
    doc: ?[]const u8 = null,
};

const Row = struct {
    kind: enum { group, item, blank },
    section: Section,
    item: usize = 0,
};

const Focus = enum { tree, doc };

const DocKind = enum { body, h1, h2, h3, list, code };

const DocLine = struct {
    text: []const u8,
    kind: DocKind = .body,
    /// Only the first wrapped line of a list entry carries the muted dash.
    dash: bool = false,
};

const Model = struct {
    io: std.Io,
    alloc: Allocator,
    eng: *engine.Engine,
    root: []const u8,
    home: []const u8,
    mono: bool,

    idx: std.heap.ArenaAllocator,
    items: [section_count]std.ArrayList(Item),
    rows: std.ArrayList(Row),
    collapsed: [section_count]bool,
    selected: usize = 0,
    tree_top: usize = 0,
    doc_top: usize = 0,
    focus: Focus = .tree,
    filter: std.ArrayList(u8),
    filtering: bool = false,
    help: bool = false,
    zen: bool = false,
    width: u16 = 0,
    height: u16 = 0,
    hover: ?u16 = null,
    tree_w_user: ?u16 = null,
    drag_sep: bool = false,
    doc_arena: std.heap.ArenaAllocator,
    doc_lines: []const DocLine = &.{},
    doc_key: ?[]const u8 = null,
    doc_width: u16 = 0,
    sig: u64 = 0,
    armed: bool = false,
    error_text: ?[]const u8 = null,
    theme: theme.Theme,
    dark: bool = true,
    /// Opened-document tabs; Today is pinned first.
    tabs: tabs.List,
    /// Seconds since the last successful store poll.
    since_poll: u16 = 0,
    /// Ticks since the last key or mouse event; hints fade after 8.
    idle: u16 = 0,
    /// Ticks left to show the theme notice in the status line.
    toast_left: u16 = 0,
    hoy_label: ?[]u8 = null,
    hoy_plan: ?[]u8 = null,

    fn init(io: std.Io, alloc: Allocator, eng: *engine.Engine, root: []const u8, home: []const u8, mono: bool) !Model {
        var m: Model = .{
            .io = io,
            .alloc = alloc,
            .eng = eng,
            .root = root,
            .home = home,
            .mono = mono,
            .idx = .init(alloc),
            .items = undefined,
            .rows = .empty,
            .collapsed = undefined,
            .filter = .empty,
            .doc_arena = .init(alloc),
            .tabs = tabs.List.init(alloc),
            .theme = theme.byKey(eng.config.tui.theme),
        };
        for (&m.items) |*list| list.* = .empty;
        for (sections) |s| m.collapsed[@backingInt(s)] = s == .archive or s == .knowledge;
        try m.reload(null);
        m.sig = m.signature() catch 0;
        return m;
    }

    fn deinit(self: *Model) void {
        self.rows.deinit(self.alloc);
        self.filter.deinit(self.alloc);
        self.tabs.deinit();
        self.doc_arena.deinit();
        self.idx.deinit();
        if (self.hoy_label) |l| self.alloc.free(l);
        if (self.hoy_plan) |p| self.alloc.free(p);
    }

    fn widget(self: *Model) vxfw.Widget {
        return .{ .userdata = self, .drawFn = drawFn, .eventHandler = eventFn };
    }

    fn drawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
        const self: *Model = @ptrCast(@alignCast(ptr));
        return self.draw(ctx);
    }

    fn eventFn(ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        const self: *Model = @ptrCast(@alignCast(ptr));
        return self.handleEvent(ctx, event);
    }

    // ---- index -----------------------------------------------------------

    fn reload(self: *Model, keep_key: ?[]const u8) !void {
        self.doc_key = null;
        self.doc_lines = &.{};
        self.doc_top = 0;
        _ = self.doc_arena.reset(.free_all);

        var saved: ?[]u8 = null;
        defer if (saved) |k| self.alloc.free(k);
        if (keep_key) |k| saved = try self.alloc.dupe(u8, k);

        _ = self.idx.reset(.retain_capacity);
        for (&self.items) |*list| list.* = .empty;
        try self.buildIndex();
        try self.rebuildRows();
        try self.syncTabs();

        if (saved) |k| {
            for (self.rows.items, 0..) |row, i| {
                if (row.kind != .item) continue;
                if (std.mem.eql(u8, self.items[@backingInt(row.section)].items[row.item].key, k)) {
                    self.selected = i;
                    break;
                }
            }
        }
        self.clampSelection();
        self.ensureVisible();
    }

    fn buildIndex(self: *Model) !void {
        const a = self.idx.allocator();

        for (try self.eng.loadAll()) |lt| {
            const sec: Section = switch (lt.list) {
                .inbox => .inbox,
                .next => .next,
                .waiting => .waiting,
                .someday => .someday,
                .archive => .archive,
            };
            try self.items[@backingInt(sec)].append(a, .{
                .section = sec,
                .key = lt.task.id,
                .title = lt.task.title,
                .detail = try taskDetail(a, &lt.task),
                .path = lt.file,
                .doc = try renderTask(a, lt),
            });
        }

        const store = self.eng.store;
        var walker = try store.dir.walk(a);
        defer walker.deinit();
        while (try walker.next(self.io)) |entry| {
            if (entry.kind != .file) continue;
            const path = try a.dupe(u8, entry.path);
            if (!std.mem.endsWith(u8, path, ".md")) continue;
            const sec = docSection(path) orelse continue;
            if (sec == .routines) continue; // rendered from parsed routine rows
            const rest = path[prefixOf(sec).len..];
            const dir = std.fs.path.dirname(rest) orelse "";
            try self.items[@backingInt(sec)].append(a, .{
                .section = sec,
                .key = try a.dupe(u8, path),
                .title = stripMd(std.fs.path.basename(rest)),
                .detail = if (dir.len > 0) dir else "—",
                .path = try a.dupe(u8, path),
            });
        }

        for (try self.eng.routines()) |row| {
            var buf: [10]u8 = undefined;
            const last = row.last.format(&buf);
            try self.items[@backingInt(Section.routines)].append(a, .{
                .section = .routines,
                .key = row.id,
                .title = row.id,
                .detail = try std.fmt.allocPrint(a, "every {s} · last {s}", .{ row.cadence, last }),
                .path = "routines/state.md",
                .doc = try std.fmt.allocPrint(a, "# Routine {s}\n\n- cadence: {s}\n- last: {s}\n", .{ row.id, row.cadence, last }),
            });
        }

        const day = try hoy.load(self.io, a, &self.eng.store, self.eng.today);
        try self.setHoy(day.label, day.plan_path);
        if (day.goal) |g| {
            try self.items[@backingInt(Section.hoy)].append(a, .{
                .section = .hoy,
                .key = "hoy:meta",
                .title = g,
                .detail = "",
                .path = day.goal_path,
            });
        }
        for (day.mits, 0..) |mit, i| {
            const task: ?Item = if (mit.task_id) |id| self.findTask(id) else null;
            try self.items[@backingInt(Section.hoy)].append(a, .{
                .section = .hoy,
                .key = try std.fmt.allocPrint(a, "hoy:mit:{d}", .{i + 1}),
                .title = mit.text,
                .detail = mit.task_id orelse "plan",
                .path = if (task) |t| t.path else (day.plan_path orelse day.goal_path),
                .doc = if (task) |t| t.doc else null,
            });
        }

        for (sections) |s| {
            const list = &self.items[@backingInt(s)];
            if (s == .hoy) continue; // keeps meta first, then MITs in order
            if (s == .projects or s == .knowledge) {
                std.mem.sort(Item, list.items, {}, itemAsc);
            } else {
                std.mem.sort(Item, list.items, {}, itemDesc);
            }
        }
    }

    /// Keeps the day label and plan path alive across reloads in the model
    /// allocator: the index arena is reset on every reload.
    fn setHoy(self: *Model, label: []const u8, plan: ?[]const u8) !void {
        const new_label = try self.alloc.dupe(u8, label);
        errdefer self.alloc.free(new_label);
        var new_plan: ?[]u8 = null;
        errdefer if (new_plan) |p| self.alloc.free(p);
        if (plan) |p| new_plan = try self.alloc.dupe(u8, p);
        if (self.hoy_label) |l| self.alloc.free(l);
        if (self.hoy_plan) |p| self.alloc.free(p);
        self.hoy_label = new_label;
        self.hoy_plan = new_plan;
    }

    fn findTask(self: *Model, id: []const u8) ?Item {
        for ([_]Section{ .inbox, .next, .waiting, .someday, .archive }) |s| {
            for (self.items[@backingInt(s)].items) |it| {
                if (std.mem.eql(u8, it.key, id)) return it;
            }
        }
        return null;
    }

    fn findItem(self: *Model, key: []const u8) ?Item {
        for (sections) |s| {
            for (self.items[@backingInt(s)].items) |it| {
                if (std.mem.eql(u8, it.key, key)) return it;
            }
        }
        return null;
    }

    /// Refreshes tab titles from the rebuilt index, drops tabs whose key
    /// vanished, and guarantees the pinned Today tab exists. Reload never
    /// opens tabs: only an explicit open does.
    fn syncTabs(self: *Model) !void {
        if (self.tabs.indexOf("hoy") == null) {
            _ = try self.tabs.open("hoy", "Today", true);
        }
        for (self.tabs.entries.items) |*e| {
            if (std.mem.eql(u8, e.key, "hoy")) continue;
            const item = self.findItem(e.key) orelse continue;
            const fresh = try self.alloc.dupe(u8, item.title);
            self.alloc.free(e.title);
            e.title = fresh;
        }
        const a = self.idx.allocator();
        var keys: std.ArrayList([]const u8) = .empty;
        try keys.append(a, "hoy");
        for (sections) |s| {
            for (self.items[@backingInt(s)].items) |it| {
                try keys.append(a, it.key);
            }
        }
        self.tabs.retainKeys(keys.items);
    }

    fn itemAsc(_: void, a: Item, b: Item) bool {
        return std.mem.lessThan(u8, a.title, b.title);
    }

    fn itemDesc(_: void, a: Item, b: Item) bool {
        return std.mem.lessThan(u8, b.key, a.key);
    }

    fn docSection(path: []const u8) ?Section {
        if (std.mem.startsWith(u8, path, "lists/projects/")) return .projects;
        if (std.mem.startsWith(u8, path, "plans/")) return .plans;
        if (std.mem.startsWith(u8, path, "reviews/")) return .reviews;
        if (std.mem.startsWith(u8, path, "knowledge/")) return .knowledge;
        if (std.mem.startsWith(u8, path, "journal/")) return .journal;
        if (std.mem.startsWith(u8, path, "goals/")) return .goals;
        if (std.mem.startsWith(u8, path, "routines/")) return .routines;
        return null;
    }

    fn prefixOf(s: Section) []const u8 {
        return switch (s) {
            .projects => "lists/projects/",
            .plans => "plans/",
            .reviews => "reviews/",
            .knowledge => "knowledge/",
            .journal => "journal/",
            .goals => "goals/",
            .routines => "routines/",
            else => "",
        };
    }

    fn stripMd(name: []const u8) []const u8 {
        if (std.mem.endsWith(u8, name, ".md")) return name[0 .. name.len - 3];
        return name;
    }

    fn taskDetail(a: Allocator, task: *const model.Task) ![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        for ([_][]const u8{ "context", "client", "project" }) |key| {
            const value = task.get(key) orelse continue;
            if (out.items.len > 0) try out.appendSlice(a, " · ");
            try out.appendSlice(a, value);
        }
        return out.items;
    }

    fn renderTask(a: Allocator, lt: engine.LoadedTask) ![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        try out.appendSlice(a, try std.fmt.allocPrint(a, "# {s}\n\n{s} · {s} · {s}\n", .{
            lt.task.title,
            lt.task.id,
            lt.list.name(),
            if (lt.task.status == .open) "open" else "done",
        }));
        if (lt.task.fields.items.len > 0) {
            try out.appendSlice(a, "\n");
            for (lt.task.fields.items) |f| {
                try out.appendSlice(a, try std.fmt.allocPrint(a, "- {s}: {s}\n", .{ f.key, f.value }));
            }
        }
        return out.items;
    }

    // ---- rows and selection ----------------------------------------------

    fn rebuildRows(self: *Model) !void {
        self.rows.clearRetainingCapacity();
        const filtering = self.filter.items.len > 0;
        // An empty inbox is information; every other empty group stays hidden.
        var groups_shown: usize = 0;
        for (sections) |s| {
            const list = self.items[@backingInt(s)].items;
            if (list.len == 0 and s != .inbox) continue;
            var matches: usize = 0;
            if (filtering) {
                for (list) |item| {
                    if (matchesFilter(item, self.filter.items)) matches += 1;
                }
                if (matches == 0) continue;
            }
            if (!filtering) {
                if (groups_shown > 0) {
                    try self.rows.append(self.alloc, .{ .kind = .blank, .section = s });
                }
                groups_shown += 1;
            }
            try self.rows.append(self.alloc, .{ .kind = .group, .section = s });
            if (!filtering and self.collapsed[@backingInt(s)]) continue;
            for (list, 0..) |item, i| {
                if (filtering and !matchesFilter(item, self.filter.items)) continue;
                try self.rows.append(self.alloc, .{ .kind = .item, .section = s, .item = i });
            }
        }
        self.clampSelection();
        self.ensureVisible();
    }

    fn nearestItemRow(self: *Model, idx0: usize, forward: bool) usize {
        const rows = self.rows.items;
        if (rows.len == 0) return 0;
        const idx = @min(idx0, rows.len - 1);
        if (rows[idx].kind != .blank) return idx;
        var lo = idx;
        var hi = idx;
        while (lo > 0 or hi + 1 < rows.len) {
            if (forward and hi + 1 < rows.len) {
                hi += 1;
                if (rows[hi].kind != .blank) return hi;
            }
            if (!forward and lo > 0) {
                lo -= 1;
                if (rows[lo].kind != .blank) return lo;
            }
            if (!forward and hi + 1 < rows.len) {
                hi += 1;
                if (rows[hi].kind != .blank) return hi;
            }
            if (forward and lo > 0) {
                lo -= 1;
                if (rows[lo].kind != .blank) return lo;
            }
        }
        return idx;
    }

    fn clampSelection(self: *Model) void {
        if (self.rows.items.len == 0) {
            self.selected = 0;
            return;
        }
        if (self.selected >= self.rows.items.len) self.selected = self.rows.items.len - 1;
        self.selected = self.nearestItemRow(self.selected, false);
    }

    fn currentRow(self: *Model) ?Row {
        if (self.selected >= self.rows.items.len) return null;
        return self.rows.items[self.selected];
    }

    fn currentItem(self: *Model) ?Item {
        const row = self.currentRow() orelse return null;
        if (row.kind != .item) return null;
        return self.items[@backingInt(row.section)].items[row.item];
    }

    fn currentKey(self: *Model) ?[]const u8 {
        const item = self.currentItem() orelse return null;
        return item.key;
    }

    fn move(self: *Model, delta: isize) void {
        if (self.rows.items.len == 0) return;
        const len: isize = @intCast(self.rows.items.len);
        var next = @as(isize, @intCast(self.selected)) + delta;
        next = @max(0, @min(len - 1, next));
        self.selected = self.nearestItemRow(@intCast(next), delta > 0);
        self.ensureVisible();
    }

    fn page(self: *Model, down: bool) void {
        const step: isize = @intCast(self.bodyHeight());
        self.move(if (down) step else -step);
    }

    fn ensureVisible(self: *Model) void {
        const h = self.bodyHeight();
        if (h == 0 or self.rows.items.len == 0) return;
        const sel = self.selected;
        if (sel < self.tree_top) {
            self.tree_top = sel -| 3;
        } else if (sel >= self.tree_top + h) {
            self.tree_top = if (h > 6) sel + 3 - (h - 1) else sel;
        } else if (h > 6) {
            if (sel < self.tree_top + 3) {
                self.tree_top = sel -| 3;
            } else if (sel + 3 >= self.tree_top + h) {
                self.tree_top = sel + 3 - (h - 1);
            }
        }
        self.tree_top = @min(self.tree_top, self.maxTreeTop());
    }

    fn activate(self: *Model) void {
        const row = self.currentRow() orelse return;
        if (row.kind == .group) {
            const i = @backingInt(row.section);
            self.collapsed[i] = !self.collapsed[i];
            self.rebuildRows() catch {};
        } else if (row.kind == .item) {
            if (self.currentItem()) |it| {
                _ = self.tabs.open(it.key, it.title, false) catch {};
            }
            self.focus = .doc;
        }
    }

    /// Focuses the tab at `idx` and moves the tree selection to its item,
    /// expanding its group and clearing any filter first.
    fn jumpToTab(self: *Model, idx: usize) void {
        if (idx >= self.tabs.entries.items.len) return;
        self.tabs.active = idx;
        const key = self.tabs.entries.items[idx].key;
        self.focus = .doc;
        if (self.filter.items.len > 0) {
            self.filter.clearRetainingCapacity();
            self.rebuildRows() catch {};
        }
        var section: ?Section = null;
        if (std.mem.eql(u8, key, "hoy")) {
            section = .hoy;
        } else if (self.findItem(key)) |it| {
            section = it.section;
        }
        if (section) |s| {
            if (self.collapsed[@backingInt(s)]) {
                self.collapsed[@backingInt(s)] = false;
                self.rebuildRows() catch {};
            }
        }
        for (self.rows.items, 0..) |row, i| {
            const row_key: ?[]const u8 = switch (row.kind) {
                .item => self.items[@backingInt(row.section)].items[row.item].key,
                .group => @tagName(row.section),
                .blank => null,
            };
            if (row_key) |rk| {
                if (std.mem.eql(u8, rk, key)) {
                    self.selected = i;
                    self.ensureVisible();
                    return;
                }
            }
        }
    }

    /// Closes the active tab (Today is pinned and never closes). The
    /// selection stays put unless the closed tab was the item on screen;
    /// then it falls back to the new active tab.
    fn closeActiveTab(self: *Model) void {
        const entry = self.tabs.activeEntry() orelse return;
        if (entry.pinned) return;
        // Compare before close: tabs.close frees the entry's strings.
        const was_current = if (self.currentKey()) |k| std.mem.eql(u8, k, entry.key) else false;
        self.tabs.close(self.tabs.active);
        if (was_current) self.jumpToTab(self.tabs.active);
    }

    fn matchCount(self: *Model) usize {
        var n: usize = 0;
        for (sections) |s| {
            for (self.items[@backingInt(s)].items) |it| {
                if (matchesFilter(it, self.filter.items)) n += 1;
            }
        }
        return n;
    }

    // ---- events ----------------------------------------------------------

    fn handleEvent(self: *Model, ctx: *vxfw.EventContext, event: vxfw.Event) !void {
        switch (event) {
            .init => {
                if (!self.armed) {
                    self.armed = true;
                    try ctx.tick(1000, self.widget());
                }
            },
            .tick => {
                self.poll();
                self.idle = @min(self.idle + 1, 9);
                self.since_poll = @min(self.since_poll + 1, 999);
                if (self.toast_left > 0) self.toast_left -= 1;
                try ctx.tick(1000, self.widget());
            },
            .key_press => |key| try self.handleKey(ctx, key),
            .mouse => |mouse| try self.handleMouse(ctx, mouse),
            .mouse_leave => self.hover = null,
            .color_scheme => |scheme| self.dark = scheme == .dark,
            else => {},
        }
        ctx.redraw = true;
    }

    fn poll(self: *Model) void {
        const sig = self.signature() catch return;
        if (sig == self.sig) return;
        self.forcePoll();
    }

    /// Reloads unconditionally (manual `r` or a detected change) and marks
    /// the status line fresh.
    fn forcePoll(self: *Model) void {
        self.sig = self.signature() catch return;
        const key = self.currentKey();
        self.reload(key) catch |err| {
            self.error_text = @errorName(err);
            return;
        };
        self.since_poll = 0;
    }

    fn signature(self: *Model) !u64 {
        var arena = std.heap.ArenaAllocator.init(self.alloc);
        defer arena.deinit();
        var walker = try self.eng.store.dir.walk(arena.allocator());
        defer walker.deinit();
        var h = std.hash.Wyhash.init(0);
        while (try walker.next(self.io)) |entry| {
            if (entry.kind != .file) continue;
            const st = entry.dir.statFile(self.io, entry.basename, .{}) catch continue;
            h.update(entry.path);
            h.update(std.mem.asBytes(&st.mtime.nanoseconds));
            h.update(std.mem.asBytes(&st.size));
        }
        return h.final();
    }

    fn handleKey(self: *Model, ctx: *vxfw.EventContext, key: vaxis.Key) !void {
        self.idle = 0;
        if (self.help) {
            self.help = false;
            return;
        }
        if (self.zen) {
            if (key.matches('z', .{}) or key.matches(vaxis.Key.escape, .{})) {
                self.zen = false;
                return;
            }
            if (key.matches('q', .{}) or key.matches('c', .{ .ctrl = true })) {
                ctx.quit = true;
                return;
            }
            if (key.matches('?', .{}) or key.matches(vaxis.Key.f1, .{})) {
                self.help = true;
                return;
            }
            if (key.matches('j', .{}) or key.matches('J', .{})) {
                self.doc_top +|= 1;
                return;
            }
            if (key.matches('k', .{}) or key.matches('K', .{})) {
                self.doc_top -|= 1;
                return;
            }
            if (key.matches('d', .{ .ctrl = true })) {
                self.doc_top +|= self.docVisible();
                return;
            }
            if (key.matches('u', .{ .ctrl = true })) {
                self.doc_top -|= self.docVisible();
                return;
            }
            if (key.matches('g', .{})) {
                self.doc_top = 0;
                return;
            }
            if (key.matches('G', .{})) {
                self.doc_top = self.maxDocTop();
                return;
            }
            return;
        }
        if (self.filtering) {
            if (key.matches(vaxis.Key.escape, .{})) {
                self.filtering = false;
                self.filter.clearRetainingCapacity();
                try self.rebuildRows();
            } else if (key.matches(vaxis.Key.enter, .{})) {
                self.filtering = false;
            } else if (key.matches(vaxis.Key.backspace, .{})) {
                if (self.filter.items.len > 0) {
                    _ = self.filter.pop();
                    try self.rebuildRows();
                }
            } else if (key.text) |text| {
                for (text) |ch| {
                    if (ch >= 0x20 and ch < 0x7f) try self.filter.append(self.alloc, ch);
                }
                try self.rebuildRows();
            }
            return;
        }

        if (key.matches('q', .{}) or key.matches('c', .{ .ctrl = true })) {
            ctx.quit = true;
            return;
        }
        if (key.matches('?', .{}) or key.matches(vaxis.Key.f1, .{})) {
            self.help = true;
            return;
        }
        if (key.matches('/', .{})) {
            self.filtering = true;
            self.focus = .tree;
            return;
        }
        if (key.matches('t', .{})) {
            self.theme = theme.next(self.theme);
            self.toast_left = 2;
            return;
        }
        if (key.matches('z', .{})) {
            self.zen = true;
            return;
        }
        if (key.matches('j', .{}) or key.matches(vaxis.Key.down, .{})) {
            if (self.focus == .doc) {
                self.doc_top = @min(self.doc_top + 1, self.maxDocTop());
                return;
            }
            return self.move(1);
        }
        if (key.matches('k', .{}) or key.matches(vaxis.Key.up, .{})) {
            if (self.focus == .doc) {
                if (self.doc_top > 0) self.doc_top -= 1;
                return;
            }
            return self.move(-1);
        }
        if (key.matches('d', .{ .ctrl = true }) or key.matches(vaxis.Key.page_down, .{})) {
            if (self.focus == .doc) {
                self.doc_top = @min(self.doc_top + self.docVisible(), self.maxDocTop());
                return;
            }
            return self.page(true);
        }
        if (key.matches('u', .{ .ctrl = true }) or key.matches(vaxis.Key.page_up, .{})) {
            if (self.focus == .doc) {
                self.doc_top -|= self.docVisible();
                return;
            }
            return self.page(false);
        }
        if (key.matches('g', .{})) {
            if (self.focus == .doc) {
                self.doc_top = 0;
                return;
            }
            self.selected = 0;
            self.ensureVisible();
            return;
        }
        if (key.matches('G', .{})) {
            if (self.focus == .doc) {
                self.doc_top = self.maxDocTop();
                return;
            }
            if (self.rows.items.len > 0) self.selected = self.rows.items.len - 1;
            self.ensureVisible();
            return;
        }
        if (key.matches(vaxis.Key.tab, .{})) {
            self.focus = if (self.focus == .tree) .doc else .tree;
            return;
        }
        if (key.matches('h', .{}) or key.matches(vaxis.Key.left, .{})) {
            const row = self.currentRow() orelse return;
            if (row.kind == .group and !self.collapsed[@backingInt(row.section)]) {
                self.collapsed[@backingInt(row.section)] = true;
                try self.rebuildRows();
            } else {
                self.focus = .tree;
            }
            return;
        }
        if (key.matches('l', .{}) or key.matches(vaxis.Key.right, .{})) {
            self.focus = .doc;
            return;
        }
        if (key.matches('[', .{})) {
            self.jumpToTab(self.tabs.cycle(-1));
            return;
        }
        if (key.matches(']', .{})) {
            self.jumpToTab(self.tabs.cycle(1));
            return;
        }
        if (key.matches('x', .{})) {
            self.closeActiveTab();
            return;
        }
        if (key.matches(vaxis.Key.enter, .{}) or key.matches(vaxis.Key.space, .{})) {
            self.activate();
            return;
        }
        if (key.matches('J', .{}) or key.matches('K', .{})) {
            if (self.focus == .doc) {
                self.doc_top = if (key.matches('J', .{}))
                    self.doc_top + 1
                else if (self.doc_top > 0) self.doc_top - 1 else 0;
            } else {
                self.move(if (key.matches('J', .{})) 1 else -1);
            }
            return;
        }
        if (key.matches('r', .{})) self.forcePoll();
    }

    fn handleMouse(self: *Model, ctx: *vxfw.EventContext, mouse: vaxis.Mouse) !void {
        _ = ctx;
        self.idle = 0;
        if (self.zen) {
            switch (mouse.type) {
                .press => switch (mouse.button) {
                    .wheel_up => self.doc_top -|= 3,
                    .wheel_down => self.doc_top = @min(self.doc_top + 3, self.maxDocTop()),
                    else => {},
                },
                else => {},
            }
            return;
        }
        const body_h: i16 = @intCast(self.bodyHeight());
        const body_top: i16 = @intCast(self.bodyTop());
        const tree_w: i16 = @intCast(self.treeWidth());
        const in_body = mouse.row >= body_top and mouse.row < body_top + body_h;

        switch (mouse.type) {
            .motion, .drag => {
                if (self.drag_sep) {
                    if (mouse.col >= 0) {
                        const max: u16 = self.width -| 30;
                        self.tree_w_user = std.math.clamp(@as(u16, @intCast(mouse.col)), 20, max);
                    }
                    return;
                }
                self.hover = if (in_body) @intCast(mouse.row) else null;
            },
            .release => {
                self.drag_sep = false;
                self.hover = null;
            },
            .press => switch (mouse.button) {
                .wheel_up => {
                    if (mouse.col >= 0 and mouse.col < tree_w) {
                        self.tree_top = self.tree_top -| 3;
                    } else {
                        self.doc_top -|= 3;
                    }
                },
                .wheel_down => {
                    if (mouse.col >= 0 and mouse.col < tree_w) {
                        self.tree_top = @min(self.tree_top + 3, self.maxTreeTop());
                    } else {
                        self.doc_top = @min(self.doc_top + 3, self.maxDocTop());
                    }
                },
                .left => {
                    if (self.tabsVisible() and mouse.row == 0 and mouse.col >= 0) {
                        self.clickTab(mouse.col);
                        return;
                    }
                    if (self.width >= 100 and mouse.col >= 0 and @abs(mouse.col - tree_w) <= 1) {
                        self.drag_sep = true;
                        return;
                    }
                    if (!in_body) return;
                    const y: usize = @intCast(mouse.row - body_top);
                    if (mouse.col >= 0 and mouse.col < tree_w) {
                        self.focus = .tree;
                        const idx = self.tree_top + y;
                        if (idx < self.rows.items.len) {
                            self.selected = self.nearestItemRow(idx, false);
                            self.activate();
                        }
                    } else {
                        self.focus = .doc;
                    }
                },
                else => {},
            },
        }
    }

    fn bodyHeight(self: *Model) u16 {
        const chrome = self.bodyTop() + 1; // top chrome plus the status line
        return self.height -| chrome;
    }

    /// Row where the body starts: below the tab strip when it is shown.
    fn bodyTop(self: *Model) u16 {
        return if (self.tabsVisible()) 2 else 1;
    }

    fn tabsVisible(self: *Model) bool {
        return !self.zen and self.width >= 100;
    }

    /// Uniform tab cell width with a leading space.
    fn tabCellWidth(self: *Model) u16 {
        const n: usize = @max(self.tabs.entries.items.len, 1);
        return @intCast(@min(@as(usize, 18), @as(usize, self.width) / n));
    }

    /// How many tabs fit, reserving room for the "+N" overflow marker.
    fn tabsShown(self: *Model) usize {
        const len = self.tabs.entries.items.len;
        if (len == 0) return 0;
        const w: usize = self.tabCellWidth();
        if (w == 0) return 0;
        var shown = @min(len, @as(usize, self.width) / w);
        if (shown < len and @as(usize, self.width) - shown * w < 3) shown -= 1;
        return shown;
    }

    fn clickTab(self: *Model, col: i16) void {
        const w = self.tabCellWidth();
        if (w == 0 or col < 0) return;
        const idx: usize = @intCast(@divTrunc(col, @as(i16, @intCast(w))));
        if (idx >= self.tabsShown()) return;
        self.jumpToTab(idx);
    }

    fn docVisible(self: *Model) u16 {
        if (self.zen) return self.height -| 2;
        return self.bodyHeight() -| 6;
    }

    fn treeWidth(self: *Model) u16 {
        if (self.width < 100) return self.width;
        if (self.tree_w_user) |w| return @min(@max(w, 20), self.width -| 30);
        return @min(44, @max(28, self.width * 35 / 100));
    }

    fn maxTreeTop(self: *Model) usize {
        const h = self.bodyHeight();
        if (self.rows.items.len <= h) return 0;
        return self.rows.items.len - h;
    }

    fn maxDocTop(self: *Model) usize {
        const h = self.docVisible();
        if (self.doc_lines.len <= h) return 0;
        return self.doc_lines.len - h;
    }

    /// Reading width for the document pane: 90 columns centered, or the full
    /// pane minus two margins when narrow.
    fn readWidth(w: u16) u16 {
        var rw: u16 = @min(@as(u16, 90), w -| 4);
        if (w < 60) rw = w -| 2;
        return @max(rw, 1);
    }

    // ---- painting --------------------------------------------------------

    fn draw(self: *Model, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
        const surface = try vxfw.Surface.init(ctx.arena, self.widget(), .{
            .width = ctx.max.width orelse 0,
            .height = ctx.max.height orelse 0,
        });
        self.width = surface.size.width;
        self.height = surface.size.height;
        if (self.width == 0 or self.height == 0) return surface;

        if (self.width < 40 or self.height < 8) {
            self.paint(ctx, surface, 0, 0, self.width, "terminal too small", .{ .bold = true });
            return surface;
        }

        if (self.zen) {
            self.paintZen(ctx, surface);
            if (self.help) self.paintHelp(ctx, surface);
            return surface;
        }

        if (self.tabsVisible()) self.paintTabs(ctx, surface);
        self.paintHeader(ctx, surface);
        self.paintBody(ctx, surface);
        self.paintStatus(ctx, surface);
        if (self.help) self.paintHelp(ctx, surface);
        return surface;
    }

    fn paintHeader(self: *Model, ctx: vxfw.DrawContext, surface: vxfw.Surface) void {
        const row: u16 = self.bodyTop() -| 1;
        if (self.filtering or self.filter.items.len > 0) {
            const f = std.fmt.allocPrint(ctx.arena, "/{s}", .{self.filter.items}) catch "/";
            self.paint(ctx, surface, 0, row, self.width, f, .{ .bold = true });
            const caret_x: u16 = @intCast(@min(ctx.stringWidth(f), self.width - 1));
            surface.writeCell(caret_x, row, .{
                .char = .{ .grapheme = "▌", .width = 1 },
                .style = .{ .fg = self.accent(), .bold = true },
            });
            const t = std.fmt.allocPrint(ctx.arena, "{d} matches", .{self.matchCount()}) catch "";
            const tw: u16 = @intCast(@min(ctx.stringWidth(t), @as(usize, self.width)));
            self.paint(ctx, surface, self.width -| tw, row, self.width, t, self.mutedStyle());
            return;
        }
        self.paint(ctx, surface, 0, row, self.width, "ztd", .{ .fg = self.accent(), .bold = true });
        self.paint(ctx, surface, 3, row, self.width, " · ", self.mutedStyle());
        const date = self.hoy_label orelse "";
        const dw: u16 = if (date.len == 0) 0 else @intCast(@min(ctx.stringWidth(date), @as(usize, self.width)));
        self.paint(ctx, surface, 6, row, self.width -| dw, self.rootShort(ctx), self.mutedStyle());
        if (dw > 0) self.paint(ctx, surface, self.width -| dw, row, self.width, date, self.mutedStyle());
    }

    fn rootShort(self: *Model, ctx: vxfw.DrawContext) []const u8 {
        if (self.home.len > 0 and std.mem.startsWith(u8, self.root, self.home)) {
            return std.fmt.allocPrint(ctx.arena, "~{s}", .{self.root[self.home.len..]}) catch self.root;
        }
        return self.root;
    }

    fn paintTabs(self: *Model, ctx: vxfw.DrawContext, surface: vxfw.Surface) void {
        const entries = self.tabs.entries.items;
        const shown = self.tabsShown();
        const w = self.tabCellWidth();
        var i: usize = 0;
        while (i < shown) : (i += 1) {
            const x: u16 = @intCast(i * @as(usize, w));
            const style: Style = if (i == self.tabs.active)
                .{ .fg = self.accent(), .bold = true }
            else
                self.mutedStyle();
            surface.writeCell(x, 0, .{ .char = .{ .grapheme = " ", .width = 1 }, .style = style });
            self.paint(ctx, surface, x + 1, 0, x + w, entries[i].title, style);
        }
        if (shown < entries.len) {
            const t = std.fmt.allocPrint(ctx.arena, "+{d}", .{entries.len - shown}) catch "";
            const tw: u16 = @intCast(@min(ctx.stringWidth(t), @as(usize, self.width)));
            self.paint(ctx, surface, self.width -| tw, 0, self.width, t, self.mutedStyle());
        }
    }

    fn paintStatus(self: *Model, ctx: vxfw.DrawContext, surface: vxfw.Surface) void {
        const row = self.height - 1;
        if (self.error_text) |err| {
            // Errors never fade.
            self.paint(ctx, surface, 0, row, self.width, err, .{ .fg = .{ .index = 203 }, .bold = true });
            return;
        }
        self.paint(ctx, surface, 0, row, self.width, "ztd", .{ .fg = self.accent(), .bold = true });
        self.paint(ctx, surface, 3, row, self.width, " · ", self.mutedStyle());
        const root = self.rootShort(ctx);
        self.paint(ctx, surface, 6, row, self.width, root, self.mutedStyle());
        const age: []const u8 = if (self.since_poll < 2)
            "just now"
        else
            std.fmt.allocPrint(ctx.arena, "{d}s ago", .{self.since_poll}) catch "";
        const right = std.fmt.allocPrint(ctx.arena, "updated {s} · ? help", .{age}) catch "";
        const rw: u16 = @intCast(@min(ctx.stringWidth(right), @as(usize, self.width)));
        self.paint(ctx, surface, self.width -| rw, row, self.width, right, self.mutedStyle());
        var hint: ?[]const u8 = null;
        if (self.toast_left > 0) {
            hint = std.fmt.allocPrint(ctx.arena, "theme · {s}", .{self.theme.name}) catch "theme";
        } else if (self.filtering) {
            hint = "enter apply · esc clear";
        } else if (self.idle < 8) {
            hint = if (self.focus == .tree)
                "j/k move · ↵ open · / filter · t theme · ? help"
            else
                "j/k read · tab back · z zen · ? help";
        }
        if (hint) |t| {
            const x: u16 = 6 + @as(u16, @intCast(@min(ctx.stringWidth(root), @as(usize, self.width -| 6))));
            self.paint(ctx, surface, x + 2, row, self.width -| rw -| 2, t, self.mutedStyle());
        }
    }

    fn paintBody(self: *Model, ctx: vxfw.DrawContext, surface: vxfw.Surface) void {
        const single = self.width < 100;
        if (single) {
            if (self.focus == .doc) {
                self.paintDoc(ctx, surface, 0, self.width);
            } else {
                self.paintTree(ctx, surface, 0, self.width);
            }
            return;
        }
        const tree_w = self.treeWidth();
        self.paintTree(ctx, surface, 0, tree_w);
        var row = self.bodyTop();
        while (row < self.height - 1) : (row += 1) {
            surface.writeCell(tree_w, row, .{
                .char = .{ .grapheme = "│", .width = 1 },
                .style = .{ .fg = self.rule() },
            });
        }
        self.paintDoc(ctx, surface, tree_w + 1, self.width);
    }

    fn paintTree(self: *Model, ctx: vxfw.DrawContext, surface: vxfw.Surface, x0: u16, x1: u16) void {
        const h = self.bodyHeight();
        const tree_focus = self.focus == .tree;
        var row: u16 = 0;
        while (row < h) : (row += 1) {
            const idx = self.tree_top + row;
            const y = self.bodyTop() + row;
            if (idx >= self.rows.items.len) break;
            const entry = self.rows.items[idx];
            if (entry.kind == .blank) continue;
            const is_selected = idx == self.selected;
            const is_hover = !is_selected and self.hover != null and self.hover.? == y;
            var style: Style = .{};
            if (!tree_focus) style.dim = true;
            if (is_hover) style.ul_style = .single;
            if (is_selected) {
                style.bold = true;
                surface.writeCell(x0, y, .{
                    .char = .{ .grapheme = "▌", .width = 1 },
                    .style = .{ .fg = if (tree_focus) self.accent() else self.muted() },
                });
            }

            switch (entry.kind) {
                .group => {
                    const list = self.items[@backingInt(entry.section)].items;
                    style.bold = true;
                    var cw: u16 = 0;
                    var count: []const u8 = "";
                    if (self.width >= 60 and list.len > 0) {
                        count = std.fmt.allocPrint(ctx.arena, "{d}", .{list.len}) catch "";
                        cw = @intCast(@min(ctx.stringWidth(count), @as(usize, x1 -| x0)));
                    }
                    const label = std.fmt.allocPrint(ctx.arena, "{s} {s}", .{
                        if (self.collapsed[@backingInt(entry.section)]) "▸" else "▾",
                        sectionName(entry.section),
                    }) catch sectionName(entry.section);
                    self.paint(ctx, surface, x0 + 1, y, x1 -| (cw + 1), label, style);
                    if (cw > 0) self.paint(ctx, surface, x1 -| cw, y, x1, count, self.mutedStyle());
                },
                .item => {
                    const item = self.items[@backingInt(entry.section)].items[entry.item];
                    const tw: u16 = @intCast(@min(ctx.stringWidth(item.title), @as(usize, x1 -| (x0 + 3))));
                    self.paint(ctx, surface, x0 + 3, y, x0 + 3 + tw, item.title, style);
                    if (item.detail.len > 0) {
                        const sep = std.fmt.allocPrint(ctx.arena, "  · {s}", .{item.detail}) catch "";
                        self.paint(ctx, surface, x0 + 3 + tw, y, x1 -| 1, sep, self.mutedStyle());
                    }
                },
                .blank => {},
            }
        }
    }

    fn paintDoc(self: *Model, ctx: vxfw.DrawContext, surface: vxfw.Surface, x0: u16, x1: u16) void {
        const h = self.bodyHeight();
        const w = x1 -| x0;
        if (w < 4) return;
        const rw = readWidth(w);
        const dx = x0 + (w - rw) / 2;
        const item = self.currentItem();
        const group_row = self.currentRow();
        self.ensureDoc(ctx, item, group_row, rw);

        const top = self.bodyTop();
        self.paint(ctx, surface, dx, top, dx + rw, self.docCrumb(ctx, item, group_row), self.mutedStyle());
        const title = if (item) |it| it.title else if (group_row) |gr| sectionName(gr.section) else "";
        self.paint(ctx, surface, dx, top + 1, dx + rw, title, .{ .bold = true });
        const meta: []const u8 = if (item) |it| it.detail else if (group_row) |gr|
            std.fmt.allocPrint(ctx.arena, "{d} items", .{self.items[@backingInt(gr.section)].items.len}) catch ""
        else
            "";
        self.paint(ctx, surface, dx, top + 2, dx + rw, meta, self.mutedStyle());
        var col = dx;
        while (col < dx + rw) : (col += 1) {
            surface.writeCell(col, top + 3, .{
                .char = .{ .grapheme = "─", .width = 1 },
                .style = .{ .fg = self.rule() },
            });
        }
        self.paintDocLines(ctx, surface, dx, dx + rw, top + 5, h -| 6);
    }

    fn paintZen(self: *Model, ctx: vxfw.DrawContext, surface: vxfw.Surface) void {
        const w = self.width;
        const h = self.height;
        if (h < 3) return;
        const rw = readWidth(w);
        const dx = (w - rw) / 2;
        const item = self.currentItem();
        const group_row = self.currentRow();
        self.ensureDoc(ctx, item, group_row, rw);
        self.paint(ctx, surface, dx, 0, dx + rw, self.docCrumb(ctx, item, group_row), self.mutedStyle());
        self.paintDocLines(ctx, surface, dx, dx + rw, 2, h -| 2);
    }

    fn paintDocLines(self: *Model, ctx: vxfw.DrawContext, surface: vxfw.Surface, dx: u16, limit: u16, top: u16, visible: u16) void {
        if (self.doc_top > self.maxDocTop()) self.doc_top = self.maxDocTop();
        var row: u16 = 0;
        while (row < visible) : (row += 1) {
            const idx = self.doc_top + row;
            if (idx >= self.doc_lines.len) break;
            const line = self.doc_lines[idx];
            const y = top + row;
            const style: Style = switch (line.kind) {
                .h1, .h2 => .{ .bold = true, .fg = self.accent() },
                .h3 => .{ .bold = true },
                .code => .{ .dim = true },
                else => .{},
            };
            self.paint(ctx, surface, dx, y, limit, line.text, style);
            if (line.dash) {
                surface.writeCell(dx, y, .{
                    .char = .{ .grapheme = "–", .width = 1 },
                    .style = self.mutedStyle(),
                });
            }
        }
    }

    fn ensureDoc(self: *Model, ctx: vxfw.DrawContext, item: ?Item, group_row: ?Row, width: u16) void {
        const key: ?[]const u8 = if (item) |it| it.key else if (group_row) |gr| @tagName(gr.section) else null;
        if (self.doc_key == null or key == null or !std.mem.eql(u8, self.doc_key.?, key.?) or self.doc_width != width) {
            self.loadDoc(ctx, item, group_row, width);
        }
    }

    fn docCrumb(self: *Model, ctx: vxfw.DrawContext, item: ?Item, group_row: ?Row) []const u8 {
        _ = self;
        if (item) |it| {
            const tail = if (std.mem.startsWith(u8, it.key, "T-"))
                it.key
            else if (std.mem.startsWith(u8, it.key, "hoy:mit:"))
                std.fmt.allocPrint(ctx.arena, "MIT {s}", .{it.key["hoy:mit:".len..]}) catch it.title
            else if (std.mem.eql(u8, it.key, "hoy:meta"))
                "goal"
            else
                it.title;
            return std.fmt.allocPrint(ctx.arena, "{s} › {s}", .{ sectionName(it.section), tail }) catch tail;
        }
        if (group_row) |gr| return sectionName(gr.section);
        return "";
    }

    fn loadDoc(self: *Model, ctx: vxfw.DrawContext, item: ?Item, group_row: ?Row, width: u16) void {
        _ = self.doc_arena.reset(.free_all);
        const a = self.doc_arena.allocator();
        self.doc_width = width;
        self.doc_key = null;
        self.doc_top = 0;

        var text: []const u8 = "";
        if (item) |it| {
            self.doc_key = it.key;
            if (it.doc) |rendered| {
                text = rendered;
            } else {
                const raw = self.eng.store.dir.readFileAlloc(self.io, it.path, a, .limited(16 * 1024 * 1024)) catch |err| {
                    text = std.fmt.allocPrint(a, "Could not read {s}: {s}", .{ it.path, @errorName(err) }) catch "read error";
                    self.doc_lines = layoutDoc(ctx, a, text, width) catch &.{};
                    return;
                };
                text = normalizeCrlf(raw);
            }
        } else if (group_row) |gr| {
            self.doc_key = @tagName(gr.section);
            const count = self.items[@backingInt(gr.section)].items.len;
            if (gr.section == .hoy) {
                if (self.hoy_plan) |p| {
                    const raw = self.eng.store.dir.readFileAlloc(self.io, p, a, .limited(16 * 1024 * 1024)) catch |err| {
                        text = std.fmt.allocPrint(a, "Could not read {s}: {s}", .{ p, @errorName(err) }) catch "read error";
                        self.doc_lines = layoutDoc(ctx, a, text, width) catch &.{};
                        return;
                    };
                    text = normalizeCrlf(raw);
                } else {
                    var goal: ?[]const u8 = null;
                    for (self.items[@backingInt(Section.hoy)].items) |it| {
                        if (std.mem.eql(u8, it.key, "hoy:meta")) goal = it.title;
                    }
                    text = std.fmt.allocPrint(a, "# {s}\n\nGoal: {s}\n\nNo plan for today; pick the next thing and start.", .{
                        self.hoy_label orelse "",
                        goal orelse "—",
                    }) catch "";
                }
            } else {
                text = std.fmt.allocPrint(a, "# {s}\n\n{d} items.\n\nEnter or space folds the group; the arrows move through the tree.", .{ sectionName(gr.section), count }) catch "";
            }
        }
        self.doc_lines = layoutDoc(ctx, a, text, width) catch &.{};
    }

    fn normalizeCrlf(raw: []u8) []const u8 {
        if (std.mem.indexOf(u8, raw, "\r\n") == null) return raw;
        var out: usize = 0;
        var i: usize = 0;
        while (i < raw.len) : (i += 1) {
            if (raw[i] == '\r' and i + 1 < raw.len and raw[i + 1] == '\n') continue;
            raw[out] = raw[i];
            out += 1;
        }
        return raw[0..out];
    }

    fn fill(self: *Model, surface: vxfw.Surface, x0: u16, x1: u16, row: u16, style: Style) void {
        _ = self;
        var col = x0;
        while (col < x1) : (col += 1) {
            surface.writeCell(col, row, .{ .char = .{ .grapheme = " ", .width = 1 }, .style = style });
        }
    }

    fn paint(self: *Model, ctx: vxfw.DrawContext, surface: vxfw.Surface, x: u16, row: u16, limit: u16, text: []const u8, style: Style) void {
        _ = self;
        var col = x;
        var it = ctx.graphemeIterator(text);
        while (it.next()) |g| {
            const bytes = g.bytes(text);
            const w: u16 = @intCast(ctx.stringWidth(bytes));
            if (col + w > limit) {
                if (x < limit) surface.writeCell(limit - 1, row, .{
                    .char = .{ .grapheme = "…", .width = 1 },
                    .style = style,
                });
                return;
            }
            surface.writeCell(col, row, .{
                .char = .{ .grapheme = bytes, .width = @intCast(@max(w, 1)) },
                .style = style,
            });
            col += @max(w, 1);
        }
    }

    fn paintHelp(self: *Model, ctx: vxfw.DrawContext, surface: vxfw.Surface) void {
        const lines = [_][]const u8{
            " ztd · help",
            "",
            " j/k · ↑↓         move",
            " ctrl+d · ctrl+u  half page",
            " g · G            top / bottom",
            " enter · space    open or fold",
            " tab              switch pane",
            " /                filter",
            " [ · ]            switch tabs",
            " x                close tab",
            " t                cycle theme",
            " z                zen mode",
            " esc              back · clear filter",
            " r                reload now",
            " ?                close this help",
            " q                quit",
            "",
            " The tree refreshes when files change.",
        };
        const w: u16 = @min(48, self.width -| 4);
        const h: u16 = @min(20, self.height -| 2);
        const x = (self.width - w) / 2;
        const y = (self.height - h) / 2;
        // Clear with the terminal background: no fill color anywhere.
        for (0..h) |row| self.fill(surface, x, x + w, y + @as(u16, @intCast(row)), .{});
        const border: Style = .{ .fg = self.rule() };
        for ([_]struct { row: u16, left: []const u8, right: []const u8 }{
            .{ .row = y, .left = "┌", .right = "┐" },
            .{ .row = y + h - 1, .left = "└", .right = "┘" },
        }) |edge| {
            surface.writeCell(x, edge.row, .{ .char = .{ .grapheme = edge.left, .width = 1 }, .style = border });
            surface.writeCell(x + w - 1, edge.row, .{ .char = .{ .grapheme = edge.right, .width = 1 }, .style = border });
            var col = x + 1;
            while (col + 1 < x + w) : (col += 1) {
                surface.writeCell(col, edge.row, .{ .char = .{ .grapheme = "─", .width = 1 }, .style = border });
            }
        }
        for (1..h - 1) |i| {
            const row = y + @as(u16, @intCast(i));
            surface.writeCell(x, row, .{ .char = .{ .grapheme = "│", .width = 1 }, .style = border });
            surface.writeCell(x + w - 1, row, .{ .char = .{ .grapheme = "│", .width = 1 }, .style = border });
        }
        for (lines, 0..) |line, i| {
            const row = y + 1 + @as(u16, @intCast(i));
            if (row >= y + h - 1) break;
            self.paint(ctx, surface, x + 2, row, x + w -| 2, line, .{
                .fg = if (i == 0) self.accent() else .default,
                .bold = i == 0,
            });
        }
    }

    fn accent(self: *Model) Color {
        if (self.mono) return .default;
        return .{ .index = if (self.dark) self.theme.accent_dark else self.theme.accent_light };
    }

    fn muted(self: *Model) Color {
        if (self.mono) return .default;
        return .{ .index = if (self.dark) self.theme.muted_dark else self.theme.muted_light };
    }

    fn rule(self: *Model) Color {
        if (self.mono) return .default;
        return .{ .index = if (self.dark) self.theme.rule_dark else self.theme.rule_light };
    }

    fn mutedStyle(self: *Model) Style {
        if (self.mono) return .{ .dim = true };
        return .{ .fg = self.muted() };
    }
};

/// Splits markdown text into display lines: inline markers stripped, headings
/// classified, list dashes rewritten, and each logical line wrapped to the
/// reading width. Fenced code passes through untouched, dimmed.
fn layoutDoc(ctx: vxfw.DrawContext, a: Allocator, text: []const u8, width: u16) ![]const DocLine {
    var logical: std.ArrayList(DocLine) = .empty;
    var in_code = false;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        var line = raw;
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        const trimmed = std.mem.trim(u8, line, " \t");
        if (std.mem.startsWith(u8, trimmed, "```")) {
            in_code = !in_code;
            try logical.append(a, .{ .text = line, .kind = .code });
            continue;
        }
        if (in_code) {
            try logical.append(a, .{ .text = line, .kind = .code });
            continue;
        }
        var hashes: usize = 0;
        while (hashes < trimmed.len and trimmed[hashes] == '#') hashes += 1;
        if (hashes > 0 and hashes < trimmed.len and trimmed[hashes] == ' ') {
            const body = std.mem.trim(u8, trimmed[hashes + 1 ..], " ");
            try logical.append(a, .{
                .text = try hoy.stripInline(a, body),
                .kind = if (hashes == 1) .h1 else if (hashes == 2) .h2 else .h3,
            });
            continue;
        }
        if (std.mem.startsWith(u8, trimmed, "- ") or std.mem.startsWith(u8, trimmed, "* ")) {
            const body = try hoy.stripInline(a, std.mem.trim(u8, trimmed[2..], " "));
            try logical.append(a, .{
                .text = try std.fmt.allocPrint(a, "– {s}", .{body}),
                .kind = .list,
                .dash = true,
            });
            continue;
        }
        try logical.append(a, .{ .text = try hoy.stripInline(a, line), .kind = .body });
    }
    var out: std.ArrayList(DocLine) = .empty;
    for (logical.items) |dl| {
        const parts = try wrap(ctx, a, dl.text, width);
        for (parts, 0..) |p, i| {
            try out.append(a, .{ .text = p, .kind = dl.kind, .dash = dl.dash and i == 0 });
        }
    }
    return out.items;
}

fn matchesFilter(item: Item, needle: []const u8) bool {
    return containsIgnoreCase(item.title, needle) or
        containsIgnoreCase(item.key, needle) or
        containsIgnoreCase(item.detail, needle) or
        containsIgnoreCase(item.path, needle);
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var same = true;
        for (needle, 0..) |ch, j| {
            if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(ch)) {
                same = false;
                break;
            }
        }
        if (same) return true;
    }
    return false;
}

fn wrap(ctx: vxfw.DrawContext, a: Allocator, text: []const u8, width: u16) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    const limit: usize = @max(width, 1);
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        var line = raw;
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        if (line.len == 0) {
            try out.append(a, "");
            continue;
        }
        if (ctx.stringWidth(line) <= limit) {
            try out.append(a, try a.dupe(u8, line));
            continue;
        }
        var rest = line;
        while (rest.len > 0) {
            var it = ctx.graphemeIterator(rest);
            var col: usize = 0;
            var cut: usize = 0;
            var last_space: ?usize = null;
            while (it.next()) |g| {
                const bytes = g.bytes(rest);
                const w = ctx.stringWidth(bytes);
                if (col + w > limit and col > 0) break;
                cut = g.start + g.len;
                if (std.mem.eql(u8, bytes, " ")) last_space = g.start;
                col += w;
            }
            if (cut == 0) cut = 1;
            var take = cut;
            var skip = cut;
            if (cut < rest.len) {
                if (last_space) |sp| {
                    if (sp > 0) {
                        take = sp;
                        skip = sp + 1;
                    }
                }
            }
            try out.append(a, try a.dupe(u8, rest[0..take]));
            rest = rest[skip..];
            while (rest.len > 0 and rest[0] == ' ') rest = rest[1..];
        }
    }
    return out.items;
}

test "containing filter ignores case" {
    try std.testing.expect(containsIgnoreCase("ZTD TUI", "tui"));
    try std.testing.expect(!containsIgnoreCase("ztd", "tui"));
    try std.testing.expect(containsIgnoreCase("abc", ""));
}

test "wrap keeps words and hard-breaks long ones" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const ctx: vxfw.DrawContext = .{ .arena = arena.allocator(), .min = .{}, .max = .{}, .cell_size = .{} };
    const lines = try wrap(ctx, arena.allocator(), "hola mundo\n\nunapalabralarguisima", 10);
    try std.testing.expectEqual(@as(usize, 4), lines.len);
    try std.testing.expectEqualStrings("hola mundo", lines[0]);
    try std.testing.expectEqualStrings("", lines[1]);
    try std.testing.expectEqualStrings("unapalabra", lines[2]);
    try std.testing.expectEqualStrings("larguisima", lines[3]);
}

test "layoutDoc classifies headings, lists and code" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const ctx: vxfw.DrawContext = .{ .arena = arena.allocator(), .min = .{}, .max = .{}, .cell_size = .{} };
    const a = arena.allocator();
    const lines = try layoutDoc(ctx, a, "# Título\n\n- **punto**\n```\n**sin tocar**\n```\n[hola](y)", 40);
    try std.testing.expectEqual(@as(usize, 7), lines.len);
    try std.testing.expectEqual(DocKind.h1, lines[0].kind);
    try std.testing.expectEqualStrings("Título", lines[0].text);
    try std.testing.expectEqual(DocKind.body, lines[1].kind);
    try std.testing.expectEqual(DocKind.list, lines[2].kind);
    try std.testing.expect(lines[2].dash);
    try std.testing.expectEqualStrings("– punto", lines[2].text);
    for (lines[3..6]) |l| try std.testing.expectEqual(DocKind.code, l.kind);
    try std.testing.expectEqualStrings("**sin tocar**", lines[4].text);
    try std.testing.expectEqualStrings("hola", lines[6].text);
}
