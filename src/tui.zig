//! Read-only terminal browser for the store: a collapsible tree of lists and
//! documents beside a pager, refreshed when the files change on disk.
//!
//! The viewer never mutates the store and holds no lock. It re-reads on a
//! one-second tick: editors and `ztd` write atomically, so a changed file is
//! complete by the time it is read.

const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const engine = @import("engine.zig");
const model = @import("model.zig");
const platform = @import("platform.zig");

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

    var m = try Model.init(io, gpa, &eng, root, env_map.get("NO_COLOR") != null);
    defer m.deinit();

    const buffer = try gpa.alloc(u8, 64 * 1024);
    defer gpa.free(buffer);

    var app = try vxfw.App.init(io, gpa, env_map, buffer);
    defer app.deinit();
    try app.run(m.widget(), .{ .framerate = 30 });
    return 0;
}

const section_count = 12;

const Section = enum(u8) {
    inbox,
    next,
    waiting,
    someday,
    archive,
    projects,
    plans,
    reviews,
    knowledge,
    journal,
    goals,
    routines,
};

const sections = std.enums.values(Section);

fn sectionName(s: Section) []const u8 {
    return switch (s) {
        .inbox => "Bandeja",
        .next => "Next",
        .waiting => "Waiting",
        .someday => "Someday",
        .archive => "Archivo",
        .projects => "Proyectos",
        .plans => "Planes",
        .reviews => "Revisiones",
        .knowledge => "Conocimiento",
        .journal => "Diario",
        .goals => "Metas",
        .routines => "Rutinas",
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
    kind: enum { group, item },
    section: Section,
    item: usize = 0,
};

const Focus = enum { tree, doc };

const Model = struct {
    io: std.Io,
    alloc: Allocator,
    eng: *engine.Engine,
    root: []const u8,
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
    width: u16 = 0,
    height: u16 = 0,
    hover: ?u16 = null,
    doc_arena: std.heap.ArenaAllocator,
    doc_lines: []const []const u8 = &.{},
    doc_key: ?[]const u8 = null,
    doc_width: u16 = 0,
    sig: u64 = 0,
    armed: bool = false,
    error_text: ?[]const u8 = null,

    fn init(io: std.Io, alloc: Allocator, eng: *engine.Engine, root: []const u8, mono: bool) !Model {
        var m: Model = .{
            .io = io,
            .alloc = alloc,
            .eng = eng,
            .root = root,
            .mono = mono,
            .idx = .init(alloc),
            .items = undefined,
            .rows = .empty,
            .collapsed = undefined,
            .filter = .empty,
            .doc_arena = .init(alloc),
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
        self.doc_arena.deinit();
        self.idx.deinit();
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
            const path = entry.path;
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
                .detail = try std.fmt.allocPrint(a, "cada {s} · última {s}", .{ row.cadence, last }),
                .path = "routines/state.md",
                .doc = try std.fmt.allocPrint(a, "# Rutina {s}\n\n- cadencia: {s}\n- última: {s}\n", .{ row.id, row.cadence, last }),
            });
        }

        for (sections) |s| {
            const list = &self.items[@backingInt(s)];
            if (s == .projects or s == .knowledge) {
                std.mem.sort(Item, list.items, {}, itemAsc);
            } else {
                std.mem.sort(Item, list.items, {}, itemDesc);
            }
        }
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
            if (lt.task.status == .open) "abierta" else "hecha",
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
        for (sections) |s| {
            const list = self.items[@backingInt(s)].items;
            var matches: usize = 0;
            if (filtering) {
                for (list) |item| {
                    if (matchesFilter(item, self.filter.items)) matches += 1;
                }
                if (matches == 0) continue;
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

    fn clampSelection(self: *Model) void {
        if (self.rows.items.len == 0) {
            self.selected = 0;
            return;
        }
        if (self.selected >= self.rows.items.len) self.selected = self.rows.items.len - 1;
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
        self.selected = @intCast(next);
        self.ensureVisible();
    }

    fn page(self: *Model, down: bool) void {
        const step: isize = @intCast(self.bodyHeight());
        self.move(if (down) step else -step);
    }

    fn ensureVisible(self: *Model) void {
        const h = self.bodyHeight();
        if (h == 0) return;
        if (self.selected < self.tree_top) self.tree_top = self.selected;
        if (self.selected >= self.tree_top + h) self.tree_top = self.selected - h + 1;
    }

    fn activate(self: *Model) void {
        const row = self.currentRow() orelse return;
        if (row.kind == .group) {
            const i = @backingInt(row.section);
            self.collapsed[i] = !self.collapsed[i];
            self.rebuildRows() catch {};
        } else {
            self.focus = .doc;
        }
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
                try ctx.tick(1000, self.widget());
            },
            .key_press => |key| try self.handleKey(ctx, key),
            .mouse => |mouse| try self.handleMouse(ctx, mouse),
            else => {},
        }
        ctx.redraw = true;
    }

    fn poll(self: *Model) void {
        const sig = self.signature() catch return;
        if (sig == self.sig) return;
        self.sig = sig;
        const key = self.currentKey();
        self.reload(key) catch |err| {
            self.error_text = @errorName(err);
        };
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
        if (self.help) {
            self.help = false;
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
        if (key.matches('j', .{}) or key.matches(vaxis.Key.down, .{})) return self.move(1);
        if (key.matches('k', .{}) or key.matches(vaxis.Key.up, .{})) return self.move(-1);
        if (key.matches('d', .{ .ctrl = true }) or key.matches(vaxis.Key.page_down, .{})) return self.page(true);
        if (key.matches('u', .{ .ctrl = true }) or key.matches(vaxis.Key.page_up, .{})) return self.page(false);
        if (key.matches('g', .{})) {
            self.selected = 0;
            self.ensureVisible();
            return;
        }
        if (key.matches('G', .{})) {
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
        if (key.matches('r', .{})) self.poll();
    }

    fn handleMouse(self: *Model, ctx: *vxfw.EventContext, mouse: vaxis.Mouse) !void {
        _ = ctx;
        const body_h: i16 = @intCast(self.bodyHeight());
        const body_top: i16 = 1;
        const tree_w: i16 = @intCast(self.treeWidth());
        const in_body = mouse.row >= body_top and mouse.row < body_top + body_h;

        switch (mouse.type) {
            .motion => {
                self.hover = if (in_body) @intCast(mouse.row) else null;
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
                    if (!in_body) return;
                    const y: usize = @intCast(mouse.row - body_top);
                    if (mouse.col >= 0 and mouse.col < tree_w) {
                        self.focus = .tree;
                        const idx = self.tree_top + y;
                        if (idx < self.rows.items.len) {
                            self.selected = idx;
                            self.activate();
                        }
                    } else {
                        self.focus = .doc;
                    }
                },
                else => {},
            },
            else => {},
        }
    }

    fn bodyHeight(self: *Model) u16 {
        return if (self.height > 2) self.height - 2 else 0;
    }

    fn treeWidth(self: *Model) u16 {
        if (self.width < 100) return self.width;
        return @min(44, @max(28, self.width * 35 / 100));
    }

    fn maxTreeTop(self: *Model) usize {
        const h = self.bodyHeight();
        if (self.rows.items.len <= h) return 0;
        return self.rows.items.len - h;
    }

    fn maxDocTop(self: *Model) usize {
        const h = self.bodyHeight();
        if (self.doc_lines.len <= h) return 0;
        return self.doc_lines.len - h;
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
            self.paint(ctx, surface, 0, 0, self.width, "terminal demasiado pequeña", .{ .bold = true });
            return surface;
        }

        self.paintHeader(ctx, surface);
        self.paintBody(ctx, surface);
        self.paintFooter(ctx, surface);
        if (self.help) self.paintHelp(ctx, surface);
        return surface;
    }

    fn paintHeader(self: *Model, ctx: vxfw.DrawContext, surface: vxfw.Surface) void {
        self.fill(surface, 0, self.width, 0, .{ .bg = self.chromeBg(), .fg = self.chromeFg() });
        const text = std.fmt.allocPrint(ctx.arena, " ztd · {s}", .{self.root}) catch self.root;
        self.paint(ctx, surface, 0, 0, self.width - 12, text, .{ .bg = self.chromeBg(), .fg = self.accent(), .bold = true });
        if (self.filtering or self.filter.items.len > 0) {
            const f = std.fmt.allocPrint(ctx.arena, "/{s} ", .{self.filter.items}) catch "/";
            const start = self.width -| @as(u16, @intCast(ctx.stringWidth(f)));
            self.paint(ctx, surface, start, 0, self.width, f, .{ .bg = self.chromeBg(), .fg = self.chromeFg(), .bold = true });
        }
    }

    fn paintFooter(self: *Model, ctx: vxfw.DrawContext, surface: vxfw.Surface) void {
        const row = self.height - 1;
        self.fill(surface, 0, self.width, row, .{ .bg = self.chromeBg(), .fg = self.chromeFg() });
        if (self.error_text) |err| {
            self.paint(ctx, surface, 0, row, self.width, err, .{ .bg = self.chromeBg(), .fg = .{ .index = 203 } });
            return;
        }
        const text = if (self.filtering)
            " escribiendo filtro · enter aplicar · esc limpiar"
        else
            " ↑↓ mover · enter abrir · espacio plegar · / filtrar · tab panel · ? ayuda · q salir";
        self.paint(ctx, surface, 0, row, self.width, text, .{ .bg = self.chromeBg(), .fg = self.chromeFg(), .dim = !self.mono });
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
        for (1..self.height - 1) |row| {
            surface.writeCell(tree_w, @intCast(row), .{
                .char = .{ .grapheme = "│", .width = 1 },
                .style = .{ .fg = .{ .index = 238 } },
            });
        }
        self.paintDoc(ctx, surface, tree_w + 1, self.width);
    }

    fn paintTree(self: *Model, ctx: vxfw.DrawContext, surface: vxfw.Surface, x0: u16, x1: u16) void {
        const h = self.bodyHeight();
        const selected = self.selected;
        const dirty = self.tree_top;
        var row: u16 = 0;
        while (row < h) : (row += 1) {
            const idx = dirty + row;
            const y = 1 + row;
            if (idx >= self.rows.items.len) break;
            const entry = self.rows.items[idx];
            const is_selected = idx == selected;
            const is_hover = !is_selected and self.hover != null and self.hover.? == y;
            const base: Style = if (is_selected and self.focus == .tree)
                .{ .reverse = true }
            else if (is_hover)
                .{ .bg = .{ .index = 236 } }
            else
                .{};
            if (is_selected and self.focus == .tree) self.fill(surface, x0, x1, y, base);

            switch (entry.kind) {
                .group => {
                    const list = self.items[@backingInt(entry.section)].items;
                    const label = std.fmt.allocPrint(ctx.arena, "{s} {s} ({d})", .{
                        if (self.collapsed[@backingInt(entry.section)]) "▸" else "▾",
                        sectionName(entry.section),
                        list.len,
                    }) catch sectionName(entry.section);
                    self.paint(ctx, surface, x0 + 1, y, x1, label, .{
                        .bold = true,
                        .reverse = base.reverse,
                        .bg = base.bg,
                        .fg = if (is_selected and self.focus == .tree) .default else self.accent(),
                    });
                },
                .item => {
                    const item = self.items[@backingInt(entry.section)].items[entry.item];
                    const indent: u16 = if (self.width < 100) 2 else 3;
                    const line = if (item.detail.len > 0)
                        std.fmt.allocPrint(ctx.arena, "{s}  · {s}", .{ item.title, item.detail }) catch item.title
                    else
                        item.title;
                    self.paint(ctx, surface, x0 + indent, y, x1 -| 1, line, base);
                },
            }
        }
    }

    fn paintDoc(self: *Model, ctx: vxfw.DrawContext, surface: vxfw.Surface, x0: u16, x1: u16) void {
        const h = self.bodyHeight();
        const width = x1 -| x0;
        if (width < 4) return;

        const item = self.currentItem();
        const group_row = self.currentRow();
        const key: ?[]const u8 = if (item) |it| it.key else if (group_row) |gr| @tagName(gr.section) else null;
        if (self.doc_key == null or key == null or !std.mem.eql(u8, self.doc_key.?, key.?) or self.doc_width != width) {
            self.loadDoc(ctx, item, group_row, width);
        }

        if (item) |it| {
            self.paint(ctx, surface, x0 + 2, 1, x1 -| 2, it.title, if (it.doc != null)
                .{ .bold = true, .fg = self.accent() }
            else
                .{ .bold = true });
            self.paint(ctx, surface, x0 + 2, 2, x1 -| 2, it.key, .{ .fg = .{ .index = 244 } });
        } else if (group_row) |gr| {
            self.paint(ctx, surface, x0 + 2, 1, x1 -| 2, sectionName(gr.section), .{ .bold = true, .fg = self.accent() });
        }

        const top: u16 = 4;
        const visible = if (h > top) h - top else 0;
        if (self.doc_top > self.maxDocTop()) self.doc_top = self.maxDocTop();
        var row: u16 = 0;
        while (row < visible) : (row += 1) {
            const idx = self.doc_top + row;
            if (idx >= self.doc_lines.len) break;
            const line = self.doc_lines[idx];
            const style: Style = if (std.mem.startsWith(u8, line, "#"))
                .{ .bold = true, .fg = self.accent() }
            else if (std.mem.startsWith(u8, line, "```"))
                .{ .dim = true }
            else
                .{};
            self.paint(ctx, surface, x0 + 2, top + row, x1 -| 2, line, style);
        }
    }

    fn loadDoc(self: *Model, ctx: vxfw.DrawContext, item: ?Item, group_row: ?Row, width: u16) void {
        _ = self.doc_arena.reset(.free_all);
        const a = self.doc_arena.allocator();
        self.doc_width = width;
        self.doc_key = null;

        var text: []const u8 = "";
        if (item) |it| {
            self.doc_key = it.key;
            if (it.doc) |rendered| {
                text = rendered;
            } else {
                const raw = self.eng.store.dir.readFileAlloc(self.io, it.path, a, .limited(16 * 1024 * 1024)) catch |err| {
                    text = std.fmt.allocPrint(a, "No se pudo leer {s}: {s}", .{ it.path, @errorName(err) }) catch "error de lectura";
                    self.doc_lines = wrap(ctx, a, text, width) catch &.{};
                    return;
                };
                text = normalizeCrlf(raw);
            }
        } else if (group_row) |gr| {
            const count = self.items[@backingInt(gr.section)].items.len;
            self.doc_key = @tagName(gr.section);
            text = std.fmt.allocPrint(a, "# {s}\n\n{d} elementos.\n\nEnter o espacio pliega el grupo; las flechas recorren el árbol.", .{ sectionName(gr.section), count }) catch "";
        }
        self.doc_lines = wrap(ctx, a, text, width) catch &.{};
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
            " ztd · ayuda",
            "",
            " ↑ ↓ / j k       moverse",
            " ctrl+d / ctrl+u  media página",
            " g / G            inicio / final",
            " enter / espacio  abrir o plegar",
            " tab              cambiar de panel",
            " /                filtrar",
            " r                recargar ahora",
            " ?                cerrar esta ayuda",
            " q                salir",
            "",
            " El árbol se refresca solo al cambiar los archivos.",
        };
        const w: u16 = @min(64, self.width -| 4);
        const h: u16 = @min(16, self.height -| 2);
        const x = (self.width - w) / 2;
        const y = (self.height - h) / 2;
        const bg: Style = .{ .bg = self.chromeBg(), .fg = self.chromeFg() };
        for (0..h) |row| self.fill(surface, x, x + w, y + @as(u16, @intCast(row)), bg);
        const border: Style = .{ .bg = self.chromeBg(), .fg = .{ .index = 238 } };
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
                .bg = self.chromeBg(),
                .fg = if (i == 0) self.accent() else self.chromeFg(),
                .bold = i == 0,
            });
        }
    }

    fn accent(self: *Model) Color {
        return if (self.mono) .default else .{ .index = 39 };
    }

    fn chromeBg(self: *Model) Color {
        return if (self.mono) .default else .{ .index = 235 };
    }

    fn chromeFg(self: *Model) Color {
        return if (self.mono) .default else .{ .index = 252 };
    }
};

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
