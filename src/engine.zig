const std = @import("std");
const model = @import("model.zig");
const platform = @import("platform.zig");
const store_mod = @import("store.zig");
const config_mod = @import("config.zig");

pub const Store = store_mod.Store;
pub const Config = config_mod.Config;

pub const List = enum {
    inbox,
    next,
    waiting,
    someday,
    archive,

    pub fn name(self: List) []const u8 {
        return @tagName(self);
    }

    pub fn path(self: List) []const u8 {
        return switch (self) {
            .inbox => "inbox.md",
            .next => "lists/next.md",
            .waiting => "lists/waiting.md",
            .someday => "lists/someday.md",
            .archive => "lists/archive.md",
        };
    }

    pub fn parse(text: []const u8) ?List {
        if (std.mem.eql(u8, text, "inbox")) return .inbox;
        if (std.mem.eql(u8, text, "next")) return .next;
        if (std.mem.eql(u8, text, "waiting")) return .waiting;
        if (std.mem.eql(u8, text, "someday")) return .someday;
        if (std.mem.eql(u8, text, "archive")) return .archive;
        return null;
    }

    pub fn isActive(self: List) bool {
        return self != .archive;
    }
};

pub const lists = [_]List{ .inbox, .next, .waiting, .someday, .archive };

pub const LoadedTask = struct {
    task: model.Task,
    list: List,
    file: []const u8,
    line: usize,
    previous: ?List = null,
};

pub const Change = struct {
    path: []const u8,
    before: []const u8,
    after: []const u8,
};

pub const JournalFile = struct {
    path: []const u8,
    before: []const u8,
    after: []const u8,
};

pub const Journal = struct {
    version: u32 = 1,
    files: []JournalFile,
};

pub const Error = error{
    UnknownId,
    DuplicateId,
    InvalidTransition,
    InvalidWorkspace,
    InvalidText,
    IdExhausted,
    PendingTransaction,
    MalformedTask,
    InvalidList,
    InvalidContext,
    InvalidClient,
    InvalidProject,
    MissingField,
    ExternalEdit,
    CorruptJournal,
    StaleTask,
    InvalidConfig,
};

pub const Engine = struct {
    io: std.Io,
    alloc: std.mem.Allocator,
    store: Store,
    config: Config,
    contexts: []const []const u8,
    today: platform.Date,

    pub fn init(io: std.Io, alloc: std.mem.Allocator, root: []const u8, today: platform.Date, exclusive: bool) !Engine {
        var store = try Store.open(io, alloc, root);
        errdefer store.deinit();
        try store.lock(exclusive);
        const cfg = try config_mod.load(&store, alloc);
        if (cfg.format != 1) return error.InvalidConfig;
        const contexts_list = try config_mod.loadContexts(&store, alloc);
        return .{
            .io = io,
            .alloc = alloc,
            .store = store,
            .config = cfg,
            .contexts = contexts_list.items,
            .today = today,
        };
    }

    pub fn deinit(self: *Engine) void {
        self.store.deinit();
    }

    pub fn lockExclusive(self: *Engine) !void {
        self.store.unlock();
        try self.store.lock(true);
    }

    pub fn loadAll(self: *Engine) ![]LoadedTask {
        var out: std.ArrayList(LoadedTask) = .empty;
        errdefer out.deinit(self.alloc);
        for (lists) |list| {
            const content = (try self.store.readOptional(list.path())) orelse continue;
            var lines = std.mem.splitScalar(u8, content, '\n');
            var line_no: usize = 0;
            while (lines.next()) |line| {
                line_no += 1;
                const parsed = model.parseLine(self.alloc, line) catch |err| switch (err) {
                    error.MalformedTask, error.InvalidId => continue,
                    else => return err,
                };
                if (parsed) |task| {
                    var t = task;
                    t.list = list.name();
                    try out.append(self.alloc, .{ .task = t, .list = list, .file = list.path(), .line = line_no });
                }
            }
        }
        return out.toOwnedSlice(self.alloc);
    }

    pub fn find(self: *Engine, id: []const u8, tasks: []const LoadedTask) !LoadedTask {
        _ = self;
        var found: ?LoadedTask = null;
        for (tasks) |t| {
            if (std.mem.eql(u8, t.task.id, id)) {
                if (found != null) return error.DuplicateId;
                found = t;
            }
        }
        return found orelse error.UnknownId;
    }

    pub fn capture(self: *Engine, texts: []const []const u8, dry_run: bool) ![]LoadedTask {
        if (texts.len == 0) return error.InvalidText;
        for (texts) |text| {
            if (std.mem.trim(u8, text, " \t\r\n").len == 0) return error.InvalidText;
            if (std.mem.indexOfAny(u8, text, "\r\n") != null) return error.InvalidText;
        }
        if (self.store.exists(".state/pending.json")) return error.PendingTransaction;

        const all = try self.loadAll();
        const today8 = try self.date8();
        var max: u32 = 0;
        for (all) |lt| {
            if (!std.mem.startsWith(u8, lt.task.id, "T-")) continue;
            if (!std.mem.eql(u8, lt.task.id[2..10], today8)) continue;
            const n = std.fmt.parseInt(u32, lt.task.id[11..], 10) catch continue;
            if (n > max) max = n;
        }

        const before = (try self.store.readOptional("inbox.md")) orelse "";
        var after: std.ArrayList(u8) = .empty;
        errdefer after.deinit(self.alloc);
        try after.appendSlice(self.alloc, before);
        if (after.items.len > 0 and after.items[after.items.len - 1] != '\n') {
            try after.append(self.alloc, '\n');
        }

        var created: std.ArrayList(LoadedTask) = .empty;
        errdefer created.deinit(self.alloc);
        const base_line = std.mem.count(u8, before, "\n") + 1 + @as(usize, if (before.len > 0 and before[before.len - 1] != '\n') 1 else 0);
        for (texts, 0..) |text, i| {
            const n = max + 1 + @as(u32, @intCast(i));
            if (n > 999) return error.IdExhausted;
            const id = try std.fmt.allocPrint(self.alloc, "T-{s}-{d:0>3}", .{ today8, n });
            var task = model.Task{
                .status = .open,
                .id = id,
                .title = try self.alloc.dupe(u8, std.mem.trim(u8, text, " \t")),
            };
            const date_str = try self.dateString(self.today);
            try task.set(self.alloc, "capturada", date_str);
            const line = try task.render(self.alloc);
            try after.appendSlice(self.alloc, line);
            try after.append(self.alloc, '\n');
            try created.append(self.alloc, .{
                .task = task,
                .list = .inbox,
                .file = "inbox.md",
                .line = base_line + i,
            });
        }

        if (!dry_run) try self.commit(&.{.{ .path = "inbox.md", .before = before, .after = after.items }});
        return created.toOwnedSlice(self.alloc);
    }

    fn date8(self: *Engine) ![]const u8 {
        var buf: [10]u8 = undefined;
        const ds = self.today.format(&buf);
        return std.fmt.allocPrint(self.alloc, "{s}{s}{s}", .{ ds[0..4], ds[5..7], ds[8..10] });
    }

    fn dateString(self: *Engine, date: platform.Date) ![]const u8 {
        var buf: [10]u8 = undefined;
        return self.alloc.dupe(u8, date.format(&buf));
    }

    pub fn commit(self: *Engine, changes: []const Change) !void {
        if (changes.len == 0) return;
        if (self.store.exists(".state/pending.json")) return error.PendingTransaction;
        try self.store.dir.createDirPath(self.io, ".state");

        const files = try self.alloc.alloc(JournalFile, changes.len);
        for (changes, 0..) |c, i| {
            files[i] = .{ .path = c.path, .before = c.before, .after = c.after };
        }
        const journal = Journal{ .files = files };
        const json = try std.json.Stringify.valueAlloc(self.alloc, journal, .{});
        try self.store.writeAtomic(".state/pending.json", json);

        for (changes) |c| {
            try self.store.writeAtomic(c.path, c.after);
        }

        self.store.dir.deleteFile(self.io, ".state/last-transaction.json") catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
        try self.store.dir.rename(".state/pending.json", self.store.dir, ".state/last-transaction.json", self.io);
    }

    pub fn pending(self: *Engine) bool {
        return self.store.exists(".state/pending.json");
    }

    pub fn recover(self: *Engine) !bool {
        const data = (try self.store.readOptional(".state/pending.json")) orelse return false;
        const parsed = std.json.parseFromSlice(Journal, self.alloc, data, .{}) catch return error.CorruptJournal;
        for (parsed.value.files) |f| {
            if (!store_mod.safeRel(f.path)) return error.CorruptJournal;
            const current = (try self.store.readOptional(f.path)) orelse "";
            if (std.mem.eql(u8, current, f.after)) continue;
            if (std.mem.eql(u8, current, f.before)) {
                try self.store.writeAtomic(f.path, f.after);
            } else {
                return error.ExternalEdit;
            }
        }
        self.store.dir.deleteFile(self.io, ".state/last-transaction.json") catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
        try self.store.dir.rename(".state/pending.json", self.store.dir, ".state/last-transaction.json", self.io);
        return true;
    }

    pub fn move(self: *Engine, id: []const u8, dest: List, text: ?[]const u8, set_fields: []const [2][]const u8, unset_fields: []const []const u8, expect_line: ?usize, dry_run: bool) !LoadedTask {
        if (self.store.exists(".state/pending.json")) return error.PendingTransaction;
        const all = try self.loadAll();
        const found = try self.find(id, all);
        if (found.list == .archive and dest != .archive) return error.InvalidTransition;

        var task = found.task;
        if (text) |t| {
            const trimmed = std.mem.trim(u8, t, " \t");
            if (trimmed.len == 0 or std.mem.indexOfAny(u8, trimmed, "\r\n") != null) return error.InvalidText;
            task.title = try self.alloc.dupe(u8, trimmed);
        }
        for (set_fields) |kv| {
            try task.set(self.alloc, kv[0], kv[1]);
        }
        for (unset_fields) |key| {
            _ = task.unset(key);
        }

        try self.validateTask(&task, dest);

        if (dest == .archive) {
            task.status = .done;
            if (!task.has("cerrada")) {
                try task.set(self.alloc, "cerrada", try self.dateString(self.today));
            }
        } else {
            task.status = .open;
            if (task.has("resolución") or task.has("cerrada")) return error.InvalidTransition;
        }

        const src_content = self.store.read(found.list.path()) catch |err| switch (err) {
            error.FileNotFound => return error.InvalidWorkspace,
            else => return err,
        };
        if (expect_line) |want| {
            var n: usize = 1;
            var actual: ?usize = null;
            var lines = std.mem.splitScalar(u8, src_content, '\n');
            while (lines.next()) |line| : (n += 1) {
                const parsed = model.parseLine(self.alloc, line) catch continue;
                if (parsed) |t| {
                    if (std.mem.eql(u8, t.id, id)) actual = n;
                }
            }
            if (actual == null or actual.? != want) return error.StaleTask;
        }
        const src_after = try removeTaskLine(self.alloc, src_content, id);
        const dest_path = dest.path();
        const dest_before = if (dest == found.list) src_after else ((try self.store.readOptional(dest_path)) orelse return error.InvalidWorkspace);
        var dest_after: std.ArrayList(u8) = .empty;
        errdefer dest_after.deinit(self.alloc);
        try dest_after.appendSlice(self.alloc, dest_before);
        if (dest_after.items.len > 0 and dest_after.items[dest_after.items.len - 1] != '\n') {
            try dest_after.append(self.alloc, '\n');
        }
        const line = try task.render(self.alloc);
        try dest_after.appendSlice(self.alloc, line);
        try dest_after.append(self.alloc, '\n');

        task.list = dest.name();
        if (!dry_run) {
            if (dest == found.list) {
                try self.commit(&.{.{ .path = src_path(found.list), .before = src_content, .after = dest_after.items }});
            } else {
                try self.commit(&.{
                    .{ .path = src_path(found.list), .before = src_content, .after = src_after },
                    .{ .path = dest_path, .before = dest_before, .after = dest_after.items },
                });
            }
        }
        return .{ .task = task, .list = dest, .file = dest.path(), .line = 0, .previous = found.list };
    }

    fn validateTask(self: *Engine, task: *model.Task, dest: List) !void {
        const context = task.get("contexto");
        if (dest == .inbox) return;
        if (context == null or context.?.len == 0) return error.MissingField;
        if (!config_mod.contains(self.contexts, context.?)) return error.InvalidContext;

        const client = task.get("cliente");
        if (client != null and client.?.len > 0) {
            if (!config_mod.contains(self.config.policy.clientOnlyIn, context.?)) return error.InvalidClient;
        }
        if (config_mod.contains(self.config.policy.requireClientFor, context.?)) {
            if (client == null or client.?.len == 0) return error.InvalidClient;
        }

        if (task.get("proyecto")) |project| {
            if (!config_mod.projectRegistered(&self.store, self.alloc, project)) {
                if (try self.legacyProject(project) == null) return error.InvalidProject;
            }
        }
        if (dest == .waiting) {
            if (task.get("espera") == null or task.get("espera").?.len == 0) return error.MissingField;
        }
        if (dest == .archive) {
            if (task.get("resolución") == null or task.get("resolución").?.len == 0) return error.MissingField;
        }
    }

    fn legacyProject(self: *Engine, project: []const u8) !?[]const u8 {
        if (!config_mod.projectValid(project)) return null;
        const suffix = try std.fmt.allocPrint(self.alloc, "/{s}", .{project});
        defer self.alloc.free(suffix);
        var walker = self.store.dir.walk(self.alloc) catch return null;
        defer walker.deinit();
        var found: ?[]const u8 = null;
        while (try walker.next(self.io)) |entry| {
            if (entry.kind != .file) continue;
            const path = try normalizeSlashes(self.alloc, entry.path);
            defer self.alloc.free(path);
            if (!std.mem.endsWith(u8, path, ".md")) continue;
            if (!std.mem.startsWith(u8, path, "lists/projects/")) continue;
            const rel = path["lists/projects/".len .. path.len - 3];
            if (std.mem.eql(u8, rel, project) or std.mem.endsWith(u8, rel, suffix)) {
                if (found != null and !std.mem.eql(u8, found.?, rel)) return null;
                found = try self.alloc.dupe(u8, rel);
            }
        }
        return found;
    }

    pub fn listTasks(self: *Engine, context: ?[]const u8, client: ?[]const u8, project: ?[]const u8, only: ?List) ![]LoadedTask {
        const all = try self.loadAll();
        var out: std.ArrayList(LoadedTask) = .empty;
        for (all) |lt| {
            if (only) |l| {
                if (lt.list != l) continue;
            } else if (lt.list == .archive) continue;
            if (context) |c| {
                const v = lt.task.get("contexto") orelse continue;
                if (!std.mem.eql(u8, v, c)) continue;
            }
            if (client) |c| {
                const v = lt.task.get("cliente") orelse continue;
                if (!std.mem.eql(u8, v, c)) continue;
            }
            if (project) |p| {
                const v = lt.task.get("proyecto") orelse continue;
                if (!std.mem.eql(u8, v, p)) continue;
            }
            try out.append(self.alloc, lt);
        }
        return out.toOwnedSlice(self.alloc);
    }

    pub fn planTasks(self: *Engine, date: platform.Date, context: []const u8, client: ?[]const u8) ![]LoadedTask {
        var dbuf: [10]u8 = undefined;
        const ds = date.format(&dbuf);
        const rel = try std.fmt.allocPrint(self.alloc, "plans/daily/{s}.md", .{ds});
        const plan = (try self.store.readOptional(rel)) orelse return &.{};
        const all = try self.loadAll();
        var ids: std.ArrayList([]const u8) = .empty;
        var i: usize = 0;
        while (i + 3 <= plan.len) : (i += 1) {
            if (!std.mem.startsWith(u8, plan[i..], "T-")) continue;
            var j = i + 2;
            while (j < plan.len and std.ascii.isDigit(plan[j])) : (j += 1) {}
            if (j != i + 10 or j >= plan.len or plan[j] != '-') continue;
            var k = j + 1;
            while (k < plan.len and std.ascii.isDigit(plan[k])) : (k += 1) {}
            if (k < j + 4) continue;
            const id = plan[i..k];
            if (!model.validId(id)) continue;
            var seen = false;
            for (ids.items) |x| if (std.mem.eql(u8, x, id)) {
                seen = true;
                break;
            };
            if (!seen) try ids.append(self.alloc, try self.alloc.dupe(u8, id));
            i = k - 1;
        }
        var out: std.ArrayList(LoadedTask) = .empty;
        for (ids.items) |id| {
            const lt = self.find(id, all) catch |err| switch (err) {
                error.UnknownId => continue,
                else => return err,
            };
            const c = lt.task.get("contexto") orelse continue;
            if (!std.mem.eql(u8, c, context)) continue;
            if (client) |cl| {
                const v = lt.task.get("cliente") orelse continue;
                if (!std.mem.eql(u8, v, cl)) continue;
            }
            try out.append(self.alloc, lt);
        }
        return out.toOwnedSlice(self.alloc);
    }

    pub fn check(self: *Engine, strict: bool) !CheckResult {
        if (self.store.exists(".state/pending.json")) return error.PendingTransaction;
        var errors: std.ArrayList([]const u8) = .empty;
        var warnings: std.ArrayList([]const u8) = .empty;
        const all = try self.loadAll();

        var seen: std.ArrayList([]const u8) = .empty;
        for (all) |lt| {
            for (seen.items) |id| {
                if (std.mem.eql(u8, id, lt.task.id)) {
                    try errors.append(self.alloc, try std.fmt.allocPrint(self.alloc, "duplicate id {s}", .{lt.task.id}));
                }
            }
            try seen.append(self.alloc, lt.task.id);

            if (lt.list != .archive and lt.task.status == .done) {
                try errors.append(self.alloc, try std.fmt.allocPrint(self.alloc, "{s}: done task outside archive", .{lt.task.id}));
            }
            if (lt.list == .archive and lt.task.status != .done) {
                try errors.append(self.alloc, try std.fmt.allocPrint(self.alloc, "{s}: archive task is not done", .{lt.task.id}));
            }
            if (lt.list == .archive) {
                if (lt.task.get("resolución") == null) try errors.append(self.alloc, try std.fmt.allocPrint(self.alloc, "{s}: archive task missing resolución", .{lt.task.id}));
                if (lt.task.get("cerrada") == null) try errors.append(self.alloc, try std.fmt.allocPrint(self.alloc, "{s}: archive task missing cerrada", .{lt.task.id}));
            } else if (lt.task.has("resolución") or lt.task.has("cerrada")) {
                try errors.append(self.alloc, try std.fmt.allocPrint(self.alloc, "{s}: closed fields outside archive", .{lt.task.id}));
            }
            if (lt.task.get("contexto")) |ctx| {
                if (!config_mod.contains(self.contexts, ctx)) {
                    try errors.append(self.alloc, try std.fmt.allocPrint(self.alloc, "{s}: unknown context {s}", .{ lt.task.id, ctx }));
                }
                if (lt.task.get("cliente")) |cl| {
                    if (!config_mod.contains(self.config.policy.clientOnlyIn, ctx)) {
                        try errors.append(self.alloc, try std.fmt.allocPrint(self.alloc, "{s}: client not allowed in context {s}", .{ lt.task.id, ctx }));
                    }
                    _ = cl;
                }
                if (config_mod.contains(self.config.policy.requireClientFor, ctx) and lt.task.get("cliente") == null) {
                    try errors.append(self.alloc, try std.fmt.allocPrint(self.alloc, "{s}: missing client for context {s}", .{ lt.task.id, ctx }));
                }
            }
            if (lt.task.get("proyecto")) |p| {
                if (!config_mod.projectRegistered(&self.store, self.alloc, p)) {
                    if (try self.legacyProject(p)) |resolved| {
                        try warnings.append(self.alloc, try std.fmt.allocPrint(self.alloc, "{s}: legacy project {s} resolves to {s}", .{ lt.task.id, p, resolved }));
                    } else {
                        try errors.append(self.alloc, try std.fmt.allocPrint(self.alloc, "{s}: unknown project {s}", .{ lt.task.id, p }));
                    }
                }
            }
        }

        // Malformed task-like lines in the canonical lists.
        for (lists) |list| {
            const content = (try self.store.readOptional(list.path())) orelse continue;
            var lines = std.mem.splitScalar(u8, content, '\n');
            var n: usize = 0;
            while (lines.next()) |line| {
                n += 1;
                if (!std.mem.startsWith(u8, line, "- [")) continue;
                _ = model.parseLine(self.alloc, line) catch {
                    try errors.append(self.alloc, try std.fmt.allocPrint(self.alloc, "{s}:{d}: malformed task", .{ list.path(), n }));
                };
            }
        }

        // References to unknown IDs anywhere under ztd/ (except templates/state).
        var walker = try self.store.dir.walk(self.alloc);
        defer walker.deinit();
        while (try walker.next(self.io)) |entry| {
            if (entry.kind != .file) continue;
            const path = try normalizeSlashes(self.alloc, entry.path);
            defer self.alloc.free(path);
            if (!std.mem.endsWith(u8, path, ".md")) continue;
            if (std.mem.startsWith(u8, path, "templates/") or std.mem.startsWith(u8, path, ".state/")) continue;
            const content = entry.dir.readFileAlloc(self.io, entry.basename, self.alloc, .limited(store_mod.max_file_bytes)) catch continue;
            var i: usize = 0;
            while (i + 3 <= content.len) : (i += 1) {
                if (!std.mem.startsWith(u8, content[i..], "T-")) continue;
                var j = i + 2;
                while (j < content.len and std.ascii.isDigit(content[j])) : (j += 1) {}
                if (j != i + 10 or j >= content.len or content[j] != '-') continue;
                var k = j + 1;
                while (k < content.len and std.ascii.isDigit(content[k])) : (k += 1) {}
                if (k < j + 4) continue;
                const id = content[i..k];
                if (!model.validId(id)) continue;
                var known = false;
                for (all) |lt| if (std.mem.eql(u8, lt.task.id, id)) {
                    known = true;
                    break;
                };
                if (!known) {
                    try errors.append(self.alloc, try std.fmt.allocPrint(self.alloc, "{s}: reference to unknown id {s}", .{ path, id }));
                }
                i = k - 1;
            }
        }

        if (strict and warnings.items.len > 0) {
            for (warnings.items) |w| try errors.append(self.alloc, w);
            warnings.clearRetainingCapacity();
        }
        return .{ .errors = errors.items, .warnings = warnings.items };
    }
};

pub const CheckResult = struct {
    errors: []const []const u8,
    warnings: []const []const u8,
};

fn normalizeSlashes(alloc: std.mem.Allocator, path: []const u8) ![]u8 {
    const out = try alloc.dupe(u8, path);
    for (out) |*c| {
        if (c.* == '\\') c.* = '/';
    }
    return out;
}

fn src_path(list: List) []const u8 {
    return list.path();
}

fn removeTaskLine(alloc: std.mem.Allocator, content: []const u8, id: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var lines = std.mem.splitScalar(u8, content, '\n');
    var first = true;
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "- [")) {
            const parsed = model.parseLine(alloc, line) catch null;
            if (parsed) |t| {
                if (std.mem.eql(u8, t.id, id)) continue;
            }
        }
        if (!first) try out.append(alloc, '\n');
        first = false;
        try out.appendSlice(alloc, line);
    }
    return out.toOwnedSlice(alloc);
}

pub fn errorName(err: anyerror) []const u8 {
    return switch (err) {
        error.UnknownId => "unknown_id",
        error.DuplicateId => "duplicate_id",
        error.InvalidTransition => "invalid_transition",
        error.InvalidWorkspace => "invalid_workspace",
        error.InvalidText => "invalid_text",
        error.IdExhausted => "id_exhausted",
        error.PendingTransaction => "pending_transaction",
        error.MalformedTask => "invalid_field",
        error.InvalidList => "unknown_list",
        error.InvalidContext => "unknown_context",
        error.InvalidClient => "invalid_client",
        error.InvalidProject => "unknown_project",
        error.MissingField => "invalid_field",
        error.ExternalEdit => "recover_conflict",
        error.CorruptJournal => "corrupt_journal",
        error.StaleTask => "stale_task",
        error.InvalidConfig => "unsupported_format",
        error.OutOfMemory => "out_of_memory",
        else => "io_error",
    };
}

test "capture, move, archive and list" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &path_buf);
    const base = try a.dupe(u8, path_buf[0..n]);

    const init_mod = @import("init.zig");
    _ = try init_mod.initWorkspace(io, a, base, false);
    const root = try std.fs.path.join(a, &.{ base, "ztd" });
    const today = try platform.parseDate("2026-11-11");

    var eng = try Engine.init(io, a, root, today, true);
    defer eng.deinit();

    const created = try eng.capture(&.{ "Uno", "Dos" }, false);
    try std.testing.expectEqual(@as(usize, 2), created.len);
    try std.testing.expectEqualStrings("T-20261111-001", created[0].task.id);

    const fields = [_][2][]const u8{.{ "contexto", "personal" }};
    const moved = try eng.move(created[0].task.id, .next, null, &fields, &.{}, null, false);
    try std.testing.expectEqual(List.next, moved.list);
    try std.testing.expectEqual(List.inbox, moved.previous.?);

    const active = try eng.listTasks(null, null, null, null);
    try std.testing.expectEqual(@as(usize, 2), active.len);

    const archive_fields = [_][2][]const u8{
        .{ "contexto", "personal" },
        .{ "resolución", "hecha" },
    };
    _ = try eng.move(created[1].task.id, .archive, null, &archive_fields, &.{}, null, false);
    const after = try eng.listTasks(null, null, null, null);
    try std.testing.expectEqual(@as(usize, 1), after.len);
    try std.testing.expectError(error.InvalidTransition, eng.move(created[1].task.id, .next, null, &fields, &.{}, null, false));

    const result = try eng.check(false);
    try std.testing.expectEqual(@as(usize, 0), result.errors.len);
}

test "capture continues after the maximum suffix and dry-run writes nothing" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &path_buf);
    const base = try a.dupe(u8, path_buf[0..n]);

    const init_mod = @import("init.zig");
    _ = try init_mod.initWorkspace(io, a, base, false);
    const root = try std.fs.path.join(a, &.{ base, "ztd" });
    const today = try platform.parseDate("2026-11-11");

    var eng = try Engine.init(io, a, root, today, true);
    defer eng.deinit();

    // A gap does not get reused: the next ID is max + 1.
    try eng.store.writeAtomic("inbox.md", "- [ ] T-20261111-004 | Gap | capturada: 2026-11-11\n");
    const created = try eng.capture(&.{"Next"}, false);
    try std.testing.expectEqualStrings("T-20261111-005", created[0].task.id);

    const before = try eng.store.read("inbox.md");
    const dry = try eng.capture(&.{"Dry"}, true);
    try std.testing.expectEqualStrings("T-20261111-006", dry[0].task.id);
    try std.testing.expectEqualStrings(before, try eng.store.read("inbox.md"));
}

test "recover applies the journal and refuses an external edit" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &path_buf);
    const base = try a.dupe(u8, path_buf[0..n]);

    const init_mod = @import("init.zig");
    _ = try init_mod.initWorkspace(io, a, base, false);
    const root = try std.fs.path.join(a, &.{ base, "ztd" });
    const today = try platform.parseDate("2026-11-11");

    var eng = try Engine.init(io, a, root, today, true);
    defer eng.deinit();

    const before = try eng.store.read("inbox.md");
    const after = try std.fmt.allocPrint(a, "{s}- [ ] T-20261111-001 | Recovered | capturada: 2026-11-11\n", .{before});
    var files = [_]JournalFile{.{ .path = "inbox.md", .before = before, .after = after }};
    const journal = try std.json.Stringify.valueAlloc(a, Journal{ .files = &files }, .{});
    try eng.store.writeAtomic(".state/pending.json", journal);

    try std.testing.expect(try eng.recover());
    try std.testing.expectEqualStrings(after, try eng.store.read("inbox.md"));
    try std.testing.expect(!eng.pending());

    // A later edit outside ztd must not be overwritten.
    const current = try eng.store.read("inbox.md");
    const intended = try std.fmt.allocPrint(a, "{s}- [ ] T-20261111-002 | Intended | capturada: 2026-11-11\n", .{current});
    const outside = try std.fmt.allocPrint(a, "{s}external edit\n", .{current});
    files = [_]JournalFile{.{ .path = "inbox.md", .before = current, .after = intended }};
    const journal2 = try std.json.Stringify.valueAlloc(a, Journal{ .files = &files }, .{});
    try eng.store.writeAtomic(".state/pending.json", journal2);
    try eng.store.writeAtomic("inbox.md", outside);

    try std.testing.expectError(error.ExternalEdit, eng.recover());
    try std.testing.expect(eng.pending());

    // Journal paths cannot escape the workspace.
    var unsafe_files = [_]JournalFile{.{ .path = "../escape", .before = "", .after = "x" }};
    const unsafe = try std.json.Stringify.valueAlloc(a, Journal{
        .files = &unsafe_files,
    }, .{});
    try eng.store.writeAtomic(".state/pending.json", unsafe);
    try std.testing.expectError(error.CorruptJournal, eng.recover());
}
