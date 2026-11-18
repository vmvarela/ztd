const std = @import("std");
const platform = @import("platform.zig");
const routine = @import("routine.zig");
const config_mod = @import("config.zig");
const assets = @import("assets");
const Store = @import("store.zig").Store;

pub const Result = struct {
    root: []const u8,
    created: []const []const u8,
};

const File = struct {
    path: []const u8,
    content: []const u8,
};

const files = [_]File{
    .{ .path = "contexts.md", .content = "# Active contexts\n\n| Context | Use |\n| --- | --- |\n| personal | Personal matters |\n" },
    .{ .path = "config.json", .content = "{\"format\":2,\"policy\":{\"requireClientFor\":[],\"clientOnlyIn\":[]}}\n" },
    .{ .path = "inbox.md", .content = "# Inbox\n\n" },
    .{ .path = "lists/next.md", .content = "# Next actions\n\n" },
    .{ .path = "lists/waiting.md", .content = "# Waiting\n\n" },
    .{ .path = "lists/someday.md", .content = "# Someday\n\n" },
    .{ .path = "lists/archive.md", .content = "# Archive\n\n" },
    .{ .path = "lists/projects/index.md", .content = "# Projects\n\n" },
    .{ .path = ".gitignore", .content = ".state/\n" },
    .{ .path = ".gitattributes", .content = "* text eol=lf\n" },
    .{ .path = "plans/daily/.gitkeep", .content = "" },
    .{ .path = "plans/weekly/.gitkeep", .content = "" },
    .{ .path = "templates/.gitkeep", .content = "" },
    .{ .path = "README.md", .content = "# ZTD workspace\n\nTasks are Markdown. Use `ztd` to edit them; commit the files with Git.\n\nSee `ztd --help` and the ztd project documentation.\n" },
};

const dirs = [_][]const u8{
    ".state",
    "lists",
    "lists/projects",
    "plans",
    "plans/daily",
    "plans/weekly",
    "routines",
    "templates",
};

/// Files that carry task-store data. Without an explicit supported
/// config.json their presence means the destination already holds store
/// content, which init must not relabel as format 2.
const store_data = [_][]const u8{
    "contexts.md",
    "inbox.md",
    "lists/next.md",
    "lists/waiting.md",
    "lists/someday.md",
    "lists/archive.md",
    "lists/projects/index.md",
    routine.path,
};

/// Canonical directories whose contents are parsed as task references: `plan`
/// scans plan files for task IDs and `check` reads them as reference inputs.
/// Only init's own `.gitkeep` scaffolding does not count as data.
const store_dirs = [_]struct { dir: []const u8, ignore: []const u8 }{
    .{ .dir = "plans/daily", .ignore = ".gitkeep" },
    .{ .dir = "plans/weekly", .ignore = ".gitkeep" },
};

/// Canonical file presence for the probe: only `FileNotFound` means the path
/// is absent. Any other access error fails the probe instead of hiding behind
/// `Store.exists`, which maps every error to false.
fn pathPresent(store: *Store, io: std.Io, rel: []const u8) !bool {
    store.dir.access(io, rel, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    return true;
}

fn dirHasData(store: *Store, io: std.Io, dir: []const u8, ignore: []const u8) !bool {
    var d = store.dir.openDir(io, dir, .{ .iterate = true }) catch |err| switch (err) {
        // No such plan storage means absent; anything else — a file where the
        // directory belongs (NotDir), denied access, ... — fails the probe
        // closed instead of reading as empty.
        error.FileNotFound => return false,
        else => return err,
    };
    defer d.close(io);
    var it = d.iterate();
    while (try it.next(io)) |entry| {
        if (std.mem.eql(u8, entry.name, ignore)) continue;
        return true;
    }
    return false;
}

fn hasStoreData(store: *Store, io: std.Io) !bool {
    for (store_data) |rel| {
        if (try pathPresent(store, io, rel)) return true;
    }
    for (store_dirs) |d| {
        if (try dirHasData(store, io, d.dir, d.ignore)) return true;
    }
    return false;
}

/// `target` is the store directory itself: a `ztd` component is never appended.
pub fn initWorkspace(io: std.Io, alloc: std.mem.Allocator, target: []const u8, dry_run: bool) !Result {
    const ztd_path = target;

    // Refuse an unsupported existing format — or store data with no explicit
    // format at all — before any directory, file or lock is created, so a
    // legacy store is never partially initialized or relabeled. The probe
    // reads with its own arena: the caller's allocator only owns the result.
    if (pathExists(io, ztd_path)) {
        var probe_arena = std.heap.ArenaAllocator.init(alloc);
        defer probe_arena.deinit();
        const probe_alloc = probe_arena.allocator();
        var probe: ?Store = Store.open(io, probe_alloc, ztd_path) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        defer if (probe) |*p| p.deinit();
        if (probe) |*p| {
            if (try pathPresent(p, io, "config.json")) {
                _ = config_mod.load(p, probe_alloc) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.InvalidWorkspace => {}, // vanished between exists and read
                    else => return error.InvalidConfig,
                };
            } else if (try hasStoreData(p, io)) {
                // Legacy or partial store content without a format declaration:
                // seeding format 2 over it would mislabel the data.
                return error.InvalidWorkspace;
            }
        }
    }

    if (!dry_run) {
        std.Io.Dir.cwd().createDirPath(io, ztd_path) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
    } else if (!pathExists(io, ztd_path)) {
        var created: std.ArrayList([]const u8) = .empty;
        for (dirs) |dir| try created.append(alloc, try alloc.dupe(u8, dir));
        for (files) |f| try created.append(alloc, try alloc.dupe(u8, f.path));
        for (assets.templates) |t| try created.append(alloc, try alloc.dupe(u8, t.path));
        try created.append(alloc, try alloc.dupe(u8, routine.path));
        return .{ .root = try alloc.dupe(u8, ztd_path), .created = try created.toOwnedSlice(alloc) };
    }

    var store = Store.open(io, alloc, ztd_path) catch |err| switch (err) {
        error.FileNotFound => return error.InvalidWorkspace,
        else => return err,
    };
    defer store.deinit();
    if (!dry_run) try store.lock(true);

    var created: std.ArrayList([]const u8) = .empty;
    errdefer created.deinit(alloc);

    for (dirs) |dir| {
        if (dry_run) {
            if (!store.exists(dir)) try created.append(alloc, try alloc.dupe(u8, dir));
            continue;
        }
        store.dir.createDirPath(io, dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
    }

    for (files) |f| {
        if (store.exists(f.path)) continue;
        if (!dry_run) _ = try store.createIfMissing(f.path, f.content);
        try created.append(alloc, try alloc.dupe(u8, f.path));
    }

    // Method templates are seeded only when absent: an edited template is
    // user data and is never overwritten, only reported when already missing.
    for (assets.templates) |t| {
        if (store.exists(t.path)) continue;
        if (!dry_run and !try store.createIfMissing(t.path, t.data)) continue;
        try created.append(alloc, try alloc.dupe(u8, t.path));
    }

    if (!store.exists(routine.path)) {
        if (!dry_run) {
            const text = try seedRoutines(io, alloc);
            defer alloc.free(text);
            _ = try store.createIfMissing(routine.path, text);
        }
        try created.append(alloc, try alloc.dupe(u8, routine.path));
    }

    return .{ .root = try alloc.dupe(u8, ztd_path), .created = try created.toOwnedSlice(alloc) };
}

/// A routine seeded with the creation date is not due on the spot; a new
/// workspace starts without debt.
fn seedRoutines(io: std.Io, alloc: std.mem.Allocator) ![]u8 {
    var buf: [10]u8 = undefined;
    const date = platform.today(io).format(&buf);
    return std.fmt.allocPrint(alloc,
        \\# Routine state
        \\
        \\| routine | cadence | last |
        \\| --- | --- | --- |
        \\| inbox | daily | {s} |
        \\| plan | daily | {s} |
        \\| review | weekly:sat | {s} |
        \\
    , .{ date, date, date });
}

fn pathExists(io: std.Io, path: []const u8) bool {
    if (std.fs.path.isAbsolute(path)) {
        std.Io.Dir.accessAbsolute(io, path, .{}) catch return false;
    } else {
        std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    }
    return true;
}

test "init is idempotent" {
    const alloc = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &path_buf);
    const base = try alloc.dupe(u8, path_buf[0..n]);
    defer alloc.free(base);

    const first = try initWorkspace(io, alloc, base, false);
    defer alloc.free(first.root);
    defer {
        for (first.created) |p| alloc.free(p);
        alloc.free(first.created);
    }
    try std.testing.expect(first.created.len > 0);

    const second = try initWorkspace(io, alloc, base, false);
    defer alloc.free(second.root);
    defer alloc.free(second.created);
    try std.testing.expectEqual(@as(usize, 0), second.created.len);
}

test "init uses the exact store directory and never appends ztd" {
    const alloc = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &path_buf);
    const base = try alloc.dupe(u8, path_buf[0..n]);
    defer alloc.free(base);

    const store_path = try std.fs.path.join(alloc, &.{ base, "exact" });
    defer alloc.free(store_path);
    const res = try initWorkspace(io, alloc, store_path, false);
    defer {
        alloc.free(res.root);
        for (res.created) |p| alloc.free(p);
        alloc.free(res.created);
    }
    try std.testing.expectEqualStrings(store_path, res.root);
    try std.testing.expect(pathExists(io, store_path));
    const joined = try std.fs.path.join(alloc, &.{ store_path, "ztd" });
    defer alloc.free(joined);
    try std.testing.expect(!pathExists(io, joined));
}

test "init refuses an unsupported format before creating anything" {
    const alloc = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &path_buf);
    const base = try alloc.dupe(u8, path_buf[0..n]);
    defer alloc.free(base);

    try tmp.dir.createDirPath(io, "foreign");
    const store_path = try std.fs.path.join(alloc, &.{ base, "foreign" });
    defer alloc.free(store_path);

    const cases = [_][]const u8{ "{\"format\":1}\n", "{\"format\":3}\n", "not json\n" };
    for (cases) |data| {
        try tmp.dir.writeFile(io, .{ .sub_path = "foreign/config.json", .data = data });
        try std.testing.expectError(error.InvalidConfig, initWorkspace(io, alloc, store_path, false));
        try std.testing.expectError(error.InvalidConfig, initWorkspace(io, alloc, store_path, true));
        // No partial initialization: no state, no workspace files.
        const state = try std.fs.path.join(alloc, &.{ store_path, ".state" });
        defer alloc.free(state);
        try std.testing.expect(!pathExists(io, state));
        const contexts = try std.fs.path.join(alloc, &.{ store_path, "contexts.md" });
        defer alloc.free(contexts);
        try std.testing.expect(!pathExists(io, contexts));
        const inbox = try std.fs.path.join(alloc, &.{ store_path, "inbox.md" });
        defer alloc.free(inbox);
        try std.testing.expect(!pathExists(io, inbox));
    }
}

test "init permits a fresh destination and refuses store data without a format" {
    const alloc = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &path_buf);
    const base = try alloc.dupe(u8, path_buf[0..n]);
    defer alloc.free(base);

    // An existing but empty destination is fresh: init seeds format 2.
    try tmp.dir.createDirPath(io, "fresh");
    const fresh_path = try std.fs.path.join(alloc, &.{ base, "fresh" });
    defer alloc.free(fresh_path);
    const res = try initWorkspace(io, alloc, fresh_path, false);
    defer {
        alloc.free(res.root);
        for (res.created) |p| alloc.free(p);
        alloc.free(res.created);
    }
    var fresh_store = try Store.open(io, alloc, fresh_path);
    defer fresh_store.deinit();
    const cfg_text = try fresh_store.read("config.json");
    defer alloc.free(cfg_text);
    try std.testing.expect(std.mem.indexOf(u8, cfg_text, "\"format\":2") != null);

    // Store data without an explicit supported format: refused in both modes,
    // before any file or state is created, and the source stays untouched.
    const legacy_line = "- [ ] T-20260101-001 | Old task | captured_at: 2026-01-01\n";
    try tmp.dir.createDirPath(io, "legacy");
    try tmp.dir.writeFile(io, .{ .sub_path = "legacy/inbox.md", .data = legacy_line });
    const legacy_path = try std.fs.path.join(alloc, &.{ base, "legacy" });
    defer alloc.free(legacy_path);
    try std.testing.expectError(error.InvalidWorkspace, initWorkspace(io, alloc, legacy_path, false));
    try std.testing.expectError(error.InvalidWorkspace, initWorkspace(io, alloc, legacy_path, true));
    for ([_][]const u8{ ".state", "config.json", "contexts.md", "routines/state.md" }) |rel| {
        const p = try std.fs.path.join(alloc, &.{ legacy_path, rel });
        defer alloc.free(p);
        try std.testing.expect(!pathExists(io, p));
    }
    var legacy_store = try Store.open(io, alloc, legacy_path);
    defer legacy_store.deinit();
    const kept = try legacy_store.read("inbox.md");
    defer alloc.free(kept);
    try std.testing.expectEqualStrings(legacy_line, kept);

    // The same refusal for other canonical store data without config.json.
    try tmp.dir.createDirPath(io, "partial");
    try tmp.dir.createDirPath(io, "partial/lists");
    try tmp.dir.writeFile(io, .{ .sub_path = "partial/lists/next.md", .data = "- [ ] T-20260101-002 | Old next | captured_at: 2026-01-01\n" });
    const partial_path = try std.fs.path.join(alloc, &.{ base, "partial" });
    defer alloc.free(partial_path);
    try std.testing.expectError(error.InvalidWorkspace, initWorkspace(io, alloc, partial_path, false));
    const partial_state = try std.fs.path.join(alloc, &.{ partial_path, ".state" });
    defer alloc.free(partial_state);
    try std.testing.expect(!pathExists(io, partial_state));
    const partial_cfg = try std.fs.path.join(alloc, &.{ partial_path, "config.json" });
    defer alloc.free(partial_cfg);
    try std.testing.expect(!pathExists(io, partial_cfg));
}

test "init treats plan files as store data but not empty plan scaffolding" {
    const alloc = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &path_buf);
    const base = try alloc.dupe(u8, path_buf[0..n]);
    defer alloc.free(base);

    // Plan files are parsed task references: without config they block init
    // in both modes, before any file or state is created.
    for ([_]struct { store: []const u8, file: []const u8 }{
        .{ .store = "plansdata", .file = "plansdata/plans/daily/2026-01-01.md" },
        .{ .store = "weeklydata", .file = "weeklydata/plans/weekly/2026-W01.md" },
    }) |case| {
        try tmp.dir.createDirPath(io, std.fs.path.dirname(case.file).?);
        try tmp.dir.writeFile(io, .{ .sub_path = case.file, .data = "T-20260101-001\n" });
        const store_path = try std.fs.path.join(alloc, &.{ base, case.store });
        defer alloc.free(store_path);
        try std.testing.expectError(error.InvalidWorkspace, initWorkspace(io, alloc, store_path, false));
        try std.testing.expectError(error.InvalidWorkspace, initWorkspace(io, alloc, store_path, true));
        for ([_][]const u8{ ".state", "config.json" }) |rel| {
            const p = try std.fs.path.join(alloc, &.{ store_path, rel });
            defer alloc.free(p);
            try std.testing.expect(!pathExists(io, p));
        }
    }

    // Empty plan scaffolding — what init itself writes — stays a fresh
    // destination.
    try tmp.dir.createDirPath(io, "scaffold/plans/daily");
    try tmp.dir.writeFile(io, .{ .sub_path = "scaffold/plans/daily/.gitkeep", .data = "" });
    const scaffold_path = try std.fs.path.join(alloc, &.{ base, "scaffold" });
    defer alloc.free(scaffold_path);
    const res = try initWorkspace(io, alloc, scaffold_path, false);
    defer {
        alloc.free(res.root);
        for (res.created) |c| alloc.free(c);
        alloc.free(res.created);
    }
    const cfg = try std.fs.path.join(alloc, &.{ scaffold_path, "config.json" });
    defer alloc.free(cfg);
    try std.testing.expect(pathExists(io, cfg));
}

test "init refuses invalid plan storage before creating config or state" {
    const alloc = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &path_buf);
    const base = try alloc.dupe(u8, path_buf[0..n]);
    defer alloc.free(base);

    // `plans/daily` is a file, not a directory: Zig 0.17 opens directories
    // with O_DIRECTORY, so openDir reports NotDir. That error must fail the
    // probe instead of reading the plan storage as empty.
    try tmp.dir.createDirPath(io, "broken/plans");
    try tmp.dir.writeFile(io, .{ .sub_path = "broken/plans/daily", .data = "not a directory\n" });
    const store_path = try std.fs.path.join(alloc, &.{ base, "broken" });
    defer alloc.free(store_path);

    try std.testing.expectError(error.NotDir, initWorkspace(io, alloc, store_path, false));
    try std.testing.expectError(error.NotDir, initWorkspace(io, alloc, store_path, true));

    // Refused before config, state or any other workspace file is created,
    // and the existing plan storage is untouched.
    for ([_][]const u8{ ".state", "config.json", "contexts.md", "inbox.md" }) |rel| {
        const p = try std.fs.path.join(alloc, &.{ store_path, rel });
        defer alloc.free(p);
        try std.testing.expect(!pathExists(io, p));
    }
    const daily = try std.fs.path.join(alloc, &.{ store_path, "plans/daily" });
    defer alloc.free(daily);
    try std.testing.expect(pathExists(io, daily));
}

test "init seeds the method templates and never overwrites an edited one" {
    const alloc = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &path_buf);
    const base = try alloc.dupe(u8, path_buf[0..n]);
    defer alloc.free(base);

    const store_path = try std.fs.path.join(alloc, &.{ base, "tpl" });
    defer alloc.free(store_path);

    const first = try initWorkspace(io, alloc, store_path, false);
    defer alloc.free(first.root);
    defer {
        for (first.created) |p| alloc.free(p);
        alloc.free(first.created);
    }
    for (assets.templates) |t| {
        const p = try std.fs.path.join(alloc, &.{ store_path, t.path });
        defer alloc.free(p);
        const got = try std.Io.Dir.cwd().readFileAlloc(io, p, alloc, .limited(1 << 20));
        defer alloc.free(got);
        try std.testing.expectEqualStrings(t.data, got);
    }

    // An edited template is user data: a later init keeps it and does not
    // report it as created.
    const day = try std.fs.path.join(alloc, &.{ store_path, "templates/day.md" });
    defer alloc.free(day);
    {
        var f = try std.Io.Dir.cwd().createFile(io, day, .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "my own plan\n");
    }
    const second = try initWorkspace(io, alloc, store_path, false);
    defer alloc.free(second.root);
    defer {
        for (second.created) |p| alloc.free(p);
        alloc.free(second.created);
    }
    for (second.created) |p| try std.testing.expect(!std.mem.eql(u8, p, "templates/day.md"));
    const kept = try std.Io.Dir.cwd().readFileAlloc(io, day, alloc, .limited(1 << 20));
    defer alloc.free(kept);
    try std.testing.expectEqualStrings("my own plan\n", kept);

    // A missing template is reported by --dry-run without being written, and
    // written by the real run.
    const week = try std.fs.path.join(alloc, &.{ store_path, "templates/week.md" });
    defer alloc.free(week);
    std.Io.Dir.cwd().deleteFile(io, week) catch {};
    const dry = try initWorkspace(io, alloc, store_path, true);
    defer alloc.free(dry.root);
    defer {
        for (dry.created) |p| alloc.free(p);
        alloc.free(dry.created);
    }
    var reported = false;
    for (dry.created) |p| {
        if (std.mem.eql(u8, p, "templates/week.md")) reported = true;
    }
    try std.testing.expect(reported);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.accessAbsolute(io, week, .{}));

    const third = try initWorkspace(io, alloc, store_path, false);
    defer alloc.free(third.root);
    defer {
        for (third.created) |p| alloc.free(p);
        alloc.free(third.created);
    }
    const restored = try std.Io.Dir.cwd().readFileAlloc(io, week, alloc, .limited(1 << 20));
    defer alloc.free(restored);
    var week_data: []const u8 = "";
    for (assets.templates) |t| {
        if (std.mem.eql(u8, t.path, "templates/week.md")) week_data = t.data;
    }
    try std.testing.expect(week_data.len > 0);
    try std.testing.expectEqualStrings(week_data, restored);
}
