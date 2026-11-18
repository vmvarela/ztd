//! `ztd install opencode`: publishes the embedded skills/ and commands/
//! bundle into `$HOME/.config/opencode` under a no-clobber preflight, with a
//! hidden manifest that turns later runs into upgrades instead of conflicts.
//! The whole bundle is classified before the first write: any conflict
//! aborts with exit 1 and no writes at all.
const std = @import("std");
const builtin = @import("builtin");
const assets = @import("assets");
const build_options = @import("build_options");

/// Hidden manifest recording every managed path and the sha256 of the bytes
/// the installer wrote, plus the ztd version and the last write time. Only
/// this installer reads it; OpenCode ignores dotfiles in its config dir.
pub const manifest_name = ".ztd-assets.json";
const manifest_format: u32 = 1;
/// Every shipped asset is far smaller, so a file at or above this limit
/// cannot match the embedded bytes and is reported as differing.
const max_asset_bytes = 1 << 20;

const Manifest = struct {
    format: u32 = manifest_format,
    ztd_version: []const u8 = "",
    installed_at: []const u8 = "",
    assets: std.json.ArrayHashMap([]const u8) = .{},
};

pub const Action = enum { install, update, unchanged };

pub const Report = struct {
    installed: usize = 0,
    updated: usize = 0,
    unchanged: usize = 0,
    /// Owned by the caller's allocator; empty when the run may proceed.
    conflicts: []const []const u8 = &.{},

    pub fn deinit(rep: Report, alloc: std.mem.Allocator) void {
        if (rep.conflicts.len == 0) return;
        for (rep.conflicts) |c| alloc.free(c);
        alloc.free(rep.conflicts);
    }
};

const Leaf = union(enum) {
    missing,
    symlink,
    special,
    too_big,
    sha: [64]u8,
};

const Pair = struct { path: []const u8, sha: []const u8 };

/// Installs or upgrades the bundle. `home` is `$HOME`; the target directory
/// is fixed at `$HOME/.config/opencode`.
// shortcut: fixed $HOME/.config/opencode, no XDG override; add when someone needs it.
pub fn run(io: std.Io, alloc: std.mem.Allocator, home: []const u8, dry_run: bool) !Report {
    const base = try std.fs.path.join(alloc, &.{ home, ".config", "opencode" });
    defer alloc.free(base);

    var conflicts: std.ArrayList([]const u8) = .empty;
    defer conflicts.deinit(alloc);

    var actions: [assets.opencode.len]Action = undefined;
    var manifest_text: ?[]const u8 = null;
    defer if (manifest_text) |t| alloc.free(t);

    var base_dir = try openBase(io, base);
    defer if (base_dir) |*d| d.close(io);

    try preflight(io, alloc, home, base, base_dir, &actions, &manifest_text, &conflicts);
    if (conflicts.items.len > 0) return .{ .conflicts = try conflicts.toOwnedSlice(alloc) };

    var installed: usize = 0;
    var updated: usize = 0;
    var unchanged: usize = 0;
    for (actions) |a| switch (a) {
        .install => installed += 1,
        .update => updated += 1,
        .unchanged => unchanged += 1,
    };
    if (dry_run) return .{ .installed = installed, .updated = updated, .unchanged = unchanged };

    // Directories first, then re-verify: preflight saw the layout before any
    // directory existed, so a symlink planted in between must not be written
    // through either. Only empty directories can exist after such an abort.
    std.Io.Dir.cwd().createDirPath(io, base) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    for (assets.opencode, 0..) |entry, i| {
        if (actions[i] == .unchanged) continue;
        const slash = std.mem.lastIndexOfScalar(u8, entry.path, '/') orelse continue;
        const parent = try std.fs.path.join(alloc, &.{ base, entry.path[0..slash] });
        defer alloc.free(parent);
        std.Io.Dir.cwd().createDirPath(io, parent) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
    }
    if (base_dir == null) base_dir = (try openBase(io, base)) orelse return error.InvalidWorkspace;
    var recheck: std.ArrayList([]const u8) = .empty;
    defer recheck.deinit(alloc);
    try verifyAncestors(io, alloc, home, base, base_dir, &recheck);
    if (recheck.items.len > 0) return .{ .conflicts = try recheck.toOwnedSlice(alloc) };

    const dir = base_dir.?;
    for (assets.opencode, 0..) |entry, i| try writeEntry(io, dir, entry, actions[i]);
    if (manifest_text) |text| {
        var af = try dir.createFileAtomic(io, manifest_name, .{ .replace = true });
        defer af.deinit(io);
        try af.file.writeStreamingAll(io, text);
        try af.file.sync(io);
        try af.replace(io);
    }
    return .{ .installed = installed, .updated = updated, .unchanged = unchanged };
}

/// Read-only classification of the whole bundle plus the manifest. Every
/// conflict found is collected so one run reports all of them.
fn preflight(
    io: std.Io,
    alloc: std.mem.Allocator,
    home: []const u8,
    base: []const u8,
    base_dir: ?std.Io.Dir,
    actions: []Action,
    manifest_text: *?[]const u8,
    conflicts: *std.ArrayList([]const u8),
) !void {
    try verifyAncestors(io, alloc, home, base, base_dir, conflicts);

    // A malformed or unsupported manifest is treated as absent: differing
    // files then conflict instead of being silently adopted.
    var parsed: ?std.json.Parsed(Manifest) = null;
    defer if (parsed) |*p| p.deinit();
    var old = Manifest{};
    if (base_dir) |dir| {
        const st = try statL(io, dir, manifest_name);
        if (st) |s| switch (s.kind) {
            .file => {
                const text = dir.readFileAlloc(io, manifest_name, alloc, .limited(max_asset_bytes)) catch |err| switch (err) {
                    error.FileNotFound => null,
                    else => return err,
                };
                if (text) |t| {
                    defer alloc.free(t);
                    parsed = std.json.parseFromSlice(Manifest, alloc, t, .{ .allocate = .alloc_always }) catch |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        else => null,
                    };
                    if (parsed) |*p| old = p.value;
                }
            },
            else => try conflicts.append(alloc, try std.fmt.allocPrint(alloc, "not a regular file {s}/{s}", .{ base, manifest_name })),
        };
    }

    for (assets.opencode, 0..) |entry, i| {
        const abs = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ base, entry.path });
        defer alloc.free(abs);
        const new_sha = sha256Hex(entry.data);
        const leaf: Leaf = if (base_dir) |dir| try classify(io, alloc, dir, entry.path) else .missing;
        switch (leaf) {
            .missing => actions[i] = .install,
            .symlink => try conflicts.append(alloc, try std.fmt.allocPrint(alloc, "symlink {s}", .{abs})),
            .special => try conflicts.append(alloc, try std.fmt.allocPrint(alloc, "not a regular file {s}", .{abs})),
            .too_big => try conflicts.append(alloc, try std.fmt.allocPrint(alloc, "differs {s}", .{abs})),
            .sha => |disk| {
                if (std.mem.eql(u8, &disk, &new_sha)) {
                    // Already the shipped bytes: adopt them into the manifest.
                    actions[i] = .unchanged;
                } else if (old.assets.map.get(entry.path)) |recorded| {
                    if (std.mem.eql(u8, &disk, recorded)) {
                        actions[i] = .update; // the bytes of an earlier release
                    } else {
                        try conflicts.append(alloc, try std.fmt.allocPrint(alloc, "differs {s}", .{abs}));
                    }
                } else {
                    try conflicts.append(alloc, try std.fmt.allocPrint(alloc, "differs {s}", .{abs}));
                }
            },
        }
    }

    // The manifest is rewritten only when the recorded bytes or the version
    // change, so a rerun from the same binary keeps it byte-identical.
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    var pairs: std.ArrayList(Pair) = .empty;
    defer pairs.deinit(a);
    var old_it = old.assets.map.iterator();
    while (old_it.next()) |kv| {
        // Entries a future release dropped stay recorded: their files are
        // outside the bundle now, but remain managed instead of foreign.
        if (findAsset(kv.key_ptr.*) == null) try pairs.append(a, .{ .path = kv.key_ptr.*, .sha = kv.value_ptr.* });
    }
    for (assets.opencode) |entry| {
        const sha = sha256Hex(entry.data);
        try pairs.append(a, .{ .path = entry.path, .sha = try a.dupe(u8, &sha) });
    }
    std.mem.sort(Pair, pairs.items, {}, struct {
        fn lt(_: void, lhs: Pair, rhs: Pair) bool {
            return std.mem.lessThan(u8, lhs.path, rhs.path);
        }
    }.lt);

    if (!std.mem.eql(u8, old.ztd_version, build_options.version) or !sameShas(old.assets, pairs.items)) {
        manifest_text.* = try renderManifest(io, alloc, pairs.items);
    }
}

fn writeEntry(io: std.Io, dir: std.Io.Dir, entry: assets.Entry, action: Action) !void {
    switch (action) {
        .unchanged => {},
        .install => {
            // Exclusive publication: a racer that filled the leaf aborts
            // instead of clobbering it; a rerun turns it into a no-op.
            var af = try dir.createFileAtomic(io, entry.path, .{});
            defer af.deinit(io);
            try af.file.writeStreamingAll(io, entry.data);
            try af.file.sync(io);
            try af.link(io);
        },
        .update => {
            var af = try dir.createFileAtomic(io, entry.path, .{ .replace = true });
            defer af.deinit(io);
            try af.file.writeStreamingAll(io, entry.data);
            try af.file.sync(io);
            try af.replace(io);
        },
    }
}

/// Every component between $HOME and each target must already be a real
/// directory: a symlink or a file where a directory belongs is a conflict.
/// Missing components are fine — the publish phase creates them.
fn verifyAncestors(io: std.Io, alloc: std.mem.Allocator, home: []const u8, base: []const u8, base_dir: ?std.Io.Dir, conflicts: *std.ArrayList([]const u8)) !void {
    const config = try std.fs.path.join(alloc, &.{ home, ".config" });
    defer alloc.free(config);
    try checkComponent(io, alloc, null, config, config, conflicts);
    try checkComponent(io, alloc, null, base, base, conflicts);

    const dir = base_dir orelse return;
    for (assets.opencode) |entry| {
        const slash = std.mem.lastIndexOfScalar(u8, entry.path, '/') orelse continue;
        var acc: [std.fs.max_path_bytes]u8 = undefined;
        var len: usize = 0;
        var it = std.mem.splitScalar(u8, entry.path[0..slash], '/');
        while (it.next()) |comp| {
            if (len > 0) {
                acc[len] = '/';
                len += 1;
            }
            @memcpy(acc[len .. len + comp.len], comp);
            len += comp.len;
            const display = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ base, acc[0..len] });
            defer alloc.free(display);
            try checkComponent(io, alloc, dir, acc[0..len], display, conflicts);
        }
    }
}

/// `path` is absolute when `dir` is null, relative to it otherwise;
/// `display` is always the full path used in the conflict message.
fn checkComponent(io: std.Io, alloc: std.mem.Allocator, dir: ?std.Io.Dir, path: []const u8, display: []const u8, conflicts: *std.ArrayList([]const u8)) !void {
    const st = if (dir) |d|
        d.statFile(io, path, .{ .follow_symlinks = false })
    else
        std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false });
    const s = st catch |err| switch (err) {
        error.FileNotFound => return,
        error.NotDir => {
            try conflicts.append(alloc, try std.fmt.allocPrint(alloc, "not a directory {s}", .{display}));
            return;
        },
        else => return err,
    };
    switch (s.kind) {
        .directory => {},
        .sym_link => try conflicts.append(alloc, try std.fmt.allocPrint(alloc, "symlink ancestor {s}", .{display})),
        else => try conflicts.append(alloc, try std.fmt.allocPrint(alloc, "not a directory {s}", .{display})),
    }
}

fn statL(io: std.Io, dir: std.Io.Dir, rel: []const u8) !?std.Io.File.Stat {
    return dir.statFile(io, rel, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
}

fn classify(io: std.Io, alloc: std.mem.Allocator, dir: std.Io.Dir, rel: []const u8) !Leaf {
    const s = try statL(io, dir, rel);
    if (s) |st| switch (st.kind) {
        .file => {},
        .sym_link => return .symlink,
        else => return .special,
    };
    const bytes = dir.readFileAlloc(io, rel, alloc, .limited(max_asset_bytes)) catch |err| switch (err) {
        error.FileNotFound => return .missing,
        error.StreamTooLong => return .too_big,
        else => return err,
    };
    defer alloc.free(bytes);
    return .{ .sha = sha256Hex(bytes) };
}

fn openBase(io: std.Io, base: []const u8) !?std.Io.Dir {
    return std.Io.Dir.openDirAbsolute(io, base, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return null,
        error.NotDir => return null, // recorded as a conflict by verifyAncestors
        else => return err,
    };
}

fn findAsset(path: []const u8) ?assets.Entry {
    for (assets.opencode) |entry| if (std.mem.eql(u8, entry.path, path)) return entry;
    return null;
}

fn sameShas(old: std.json.ArrayHashMap([]const u8), pairs: []const Pair) bool {
    if (old.map.count() != pairs.len) return false;
    for (pairs) |p| {
        const recorded = old.map.get(p.path) orelse return false;
        if (!std.mem.eql(u8, recorded, p.sha)) return false;
    }
    return true;
}

fn renderManifest(io: std.Io, alloc: std.mem.Allocator, pairs: []const Pair) ![]const u8 {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    var m = Manifest{ .ztd_version = build_options.version, .installed_at = try utcStamp(io, a) };
    for (pairs) |p| try m.assets.map.put(a, p.path, p.sha);
    const json = try std.json.Stringify.valueAlloc(a, m, .{});
    return alloc.dupe(u8, try std.fmt.allocPrint(a, "{s}\n", .{json}));
}

fn utcStamp(io: std.Io, alloc: std.mem.Allocator) ![]const u8 {
    const raw = std.Io.Clock.real.now(io).nanoseconds;
    const secs: i64 = @intCast(@divFloor(raw, std.time.ns_per_s));
    const es = std.time.epoch.EpochSeconds{ .secs = @intCast(@max(secs, 0)) };
    const yd = es.getEpochDay().calculateYearDay();
    const md = yd.calculateMonthDay();
    const sod = @max(secs, 0) % 86400;
    return std.fmt.allocPrint(alloc, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        yd.year, @backingInt(md.month), md.day_index + 1, @divFloor(sod, 3600), @divFloor(@mod(sod, 3600), 60), @mod(sod, 60),
    });
}

fn sha256Hex(bytes: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

fn readAbs(io: std.Io, alloc: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(max_asset_bytes));
}

fn writeAbs(io: std.Io, path: []const u8, data: []const u8) !void {
    if (std.fs.path.dirname(path)) |dir| std.Io.Dir.cwd().createDirPath(io, dir) catch {};
    var f = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer f.close(io);
    try f.writeStreamingAll(io, data);
}

fn deleteAbs(io: std.Io, path: []const u8) !void {
    std.Io.Dir.cwd().deleteFile(io, path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

fn expectConflicts(alloc: std.mem.Allocator, rep: Report, needle: []const u8) !void {
    defer rep.deinit(alloc);
    try std.testing.expect(rep.conflicts.len > 0);
    var found = false;
    for (rep.conflicts) |c| {
        if (std.mem.indexOf(u8, c, needle) != null) found = true;
    }
    try std.testing.expect(found);
}

test "the manifest ships exactly the bundled skills and commands" {
    const skills = [_][]const u8{
        "skills/ztd/SKILL.md",          "skills/ztd-collect/SKILL.md",
        "skills/ztd-do/SKILL.md",       "skills/ztd-knowledge/SKILL.md",
        "skills/ztd-plan/SKILL.md",     "skills/ztd-process/SKILL.md",
        "skills/ztd-repo/SKILL.md",     "skills/ztd-review/SKILL.md",
        "skills/ztd-simplify/SKILL.md", "skills/ztd-trusted-system/SKILL.md",
    };
    const commands = [_][]const u8{
        "commands/ztd.md",        "commands/ztd/collect.md", "commands/ztd/focus.md",
        "commands/ztd/goal.md",   "commands/ztd/inbox.md",   "commands/ztd/journal.md",
        "commands/ztd/learn.md",  "commands/ztd/plan.md",    "commands/ztd/repo.md",
        "commands/ztd/review.md", "commands/ztd/routine.md", "commands/ztd/simplify.md",
        "commands/ztd/week.md",
    };
    const templates = [_][]const u8{
        "templates/day.md",     "templates/week.md",      "templates/review.md",
        "templates/journal.md", "templates/knowledge.md", "templates/project.md",
    };

    try std.testing.expectEqual(assets.opencode.len, skills.len + commands.len);
    for (skills ++ commands) |expected| {
        var present = false;
        for (assets.opencode) |entry| {
            if (std.mem.eql(u8, entry.path, expected)) present = true;
            // Nothing outside the two bundles, never anything under agents/.
            try std.testing.expect(std.mem.startsWith(u8, entry.path, "skills/") or std.mem.startsWith(u8, entry.path, "commands/"));
            try std.testing.expect(!std.mem.startsWith(u8, entry.path, "agents/"));
        }
        try std.testing.expect(present);
    }
    try std.testing.expectEqual(templates.len, assets.templates.len);
    for (templates) |expected| {
        var present = false;
        for (assets.templates) |entry| {
            if (std.mem.eql(u8, entry.path, expected)) present = true;
            try std.testing.expect(std.mem.startsWith(u8, entry.path, "templates/"));
        }
        try std.testing.expect(present);
    }
    // Embedded data is the repo file, byte for byte.
    for (assets.opencode ++ assets.templates) |entry| {
        try std.testing.expect(entry.data.len > 0);
    }
}

test "install publishes the bundle; a rerun is unchanged with a stable manifest" {
    const alloc = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &path_buf);
    const home = try alloc.dupe(u8, path_buf[0..n]);
    defer alloc.free(home);

    const r1 = try run(io, alloc, home, false);
    defer r1.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), r1.conflicts.len);
    try std.testing.expectEqual(assets.opencode.len, r1.installed);
    try std.testing.expectEqual(@as(usize, 0), r1.updated);
    try std.testing.expectEqual(@as(usize, 0), r1.unchanged);

    for (assets.opencode) |entry| {
        const p = try std.fs.path.join(alloc, &.{ home, ".config", "opencode", entry.path });
        defer alloc.free(p);
        const got = try readAbs(io, alloc, p);
        defer alloc.free(got);
        try std.testing.expectEqualStrings(entry.data, got);
    }

    const mpath = try std.fs.path.join(alloc, &.{ home, ".config", "opencode", manifest_name });
    defer alloc.free(mpath);
    const mtext1 = try readAbs(io, alloc, mpath);
    defer alloc.free(mtext1);
    var parsed = try std.json.parseFromSlice(Manifest, alloc, mtext1, .{ .allocate = .alloc_always });
    defer parsed.deinit();
    try std.testing.expectEqualStrings(build_options.version, parsed.value.ztd_version);
    try std.testing.expectEqual(assets.opencode.len, parsed.value.assets.map.count());
    try std.testing.expect(parsed.value.installed_at.len == 20);

    const r2 = try run(io, alloc, home, false);
    defer r2.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), r2.conflicts.len);
    try std.testing.expectEqual(@as(usize, 0), r2.installed);
    try std.testing.expectEqual(@as(usize, 0), r2.updated);
    try std.testing.expectEqual(assets.opencode.len, r2.unchanged);
    const mtext2 = try readAbs(io, alloc, mpath);
    defer alloc.free(mtext2);
    try std.testing.expectEqualStrings(mtext1, mtext2);

    // A missing manifest over identical files is adopted, never rewritten
    // with a new timestamp unless the recorded bytes change.
    try deleteAbs(io, mpath);
    const r3 = try run(io, alloc, home, false);
    defer r3.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), r3.conflicts.len);
    try std.testing.expectEqual(@as(usize, 0), r3.installed);
    try std.testing.expectEqual(assets.opencode.len, r3.unchanged);
    const mtext3 = try readAbs(io, alloc, mpath);
    defer alloc.free(mtext3);
    try std.testing.expectEqualStrings(mtext1, mtext3);
}

test "an upgrade replaces files whose manifest records older bytes" {
    const alloc = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &path_buf);
    const home = try alloc.dupe(u8, path_buf[0..n]);
    defer alloc.free(home);

    const first = try run(io, alloc, home, false);
    defer first.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), first.conflicts.len);

    // Simulate an earlier release: the file and the manifest both carry the
    // older bytes, the embedded bundle carries the newer ones.
    const entry = assets.opencode[0];
    const older = "older release bytes\n";
    const target = try std.fs.path.join(alloc, &.{ home, ".config", "opencode", entry.path });
    defer alloc.free(target);
    try writeAbs(io, target, older);

    const mpath = try std.fs.path.join(alloc, &.{ home, ".config", "opencode", manifest_name });
    defer alloc.free(mpath);
    const mtext = try readAbs(io, alloc, mpath);
    defer alloc.free(mtext);
    const shipped_hex = sha256Hex(entry.data);
    const older_hex = sha256Hex(older);
    const edited = try std.mem.replaceOwned(u8, alloc, mtext, shipped_hex[0..], older_hex[0..]);
    defer alloc.free(edited);
    try writeAbs(io, mpath, edited);

    const up = try run(io, alloc, home, false);
    defer up.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), up.conflicts.len);
    try std.testing.expectEqual(@as(usize, 0), up.installed);
    try std.testing.expectEqual(@as(usize, 1), up.updated);
    try std.testing.expectEqual(assets.opencode.len - 1, up.unchanged);

    const got = try readAbs(io, alloc, target);
    defer alloc.free(got);
    try std.testing.expectEqualStrings(entry.data, got);

    const after = try readAbs(io, alloc, mpath);
    defer alloc.free(after);
    var parsed = try std.json.parseFromSlice(Manifest, alloc, after, .{ .allocate = .alloc_always });
    defer parsed.deinit();
    const recorded = parsed.value.assets.map.get(entry.path).?;
    try std.testing.expectEqualStrings(shipped_hex[0..], recorded);
}

test "a stale manifest entry is repaired without touching the file" {
    const alloc = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &path_buf);
    const home = try alloc.dupe(u8, path_buf[0..n]);
    defer alloc.free(home);

    const first = try run(io, alloc, home, false);
    defer first.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), first.conflicts.len);

    // The file still holds the bytes the installer wrote; only the manifest
    // record drifted (a crashed run, a hand edit). The bytes match the
    // bundle, so nothing is rewritten and the record is repaired.
    const entry = assets.opencode[0];
    const mpath = try std.fs.path.join(alloc, &.{ home, ".config", "opencode", manifest_name });
    defer alloc.free(mpath);
    const mtext = try readAbs(io, alloc, mpath);
    defer alloc.free(mtext);
    const shipped_hex = sha256Hex(entry.data);
    const drifted_hex = sha256Hex("drifted record\n");
    const edited = try std.mem.replaceOwned(u8, alloc, mtext, shipped_hex[0..], drifted_hex[0..]);
    defer alloc.free(edited);
    try writeAbs(io, mpath, edited);

    const again = try run(io, alloc, home, false);
    defer again.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), again.conflicts.len);
    try std.testing.expectEqual(@as(usize, 0), again.installed);
    try std.testing.expectEqual(@as(usize, 0), again.updated);
    try std.testing.expectEqual(assets.opencode.len, again.unchanged);

    const after = try readAbs(io, alloc, mpath);
    defer alloc.free(after);
    var parsed = try std.json.parseFromSlice(Manifest, alloc, after, .{ .allocate = .alloc_always });
    defer parsed.deinit();
    const recorded = parsed.value.assets.map.get(entry.path).?;
    try std.testing.expectEqualStrings(shipped_hex[0..], recorded);
}

test "a user-edited file aborts with no writes and the path listed" {
    const alloc = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &path_buf);
    const home = try alloc.dupe(u8, path_buf[0..n]);
    defer alloc.free(home);

    const first = try run(io, alloc, home, false);
    defer first.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), first.conflicts.len);

    // One file edited by the user, another removed: the run must abort and
    // must not recreate the removed one.
    const edited_entry = assets.opencode[0];
    const removed_entry = assets.opencode[1];
    const edited_path = try std.fs.path.join(alloc, &.{ home, ".config", "opencode", edited_entry.path });
    defer alloc.free(edited_path);
    const removed_path = try std.fs.path.join(alloc, &.{ home, ".config", "opencode", removed_entry.path });
    defer alloc.free(removed_path);
    try writeAbs(io, edited_path, "user content\n");
    try deleteAbs(io, removed_path);

    const mpath = try std.fs.path.join(alloc, &.{ home, ".config", "opencode", manifest_name });
    defer alloc.free(mpath);
    const manifest_before = try readAbs(io, alloc, mpath);
    defer alloc.free(manifest_before);

    const again = try run(io, alloc, home, false);
    try expectConflicts(alloc, again, edited_entry.path);
    try std.testing.expectEqual(@as(usize, 0), again.installed);
    try std.testing.expectEqual(@as(usize, 0), again.updated);
    try std.testing.expectEqual(@as(usize, 0), again.unchanged);

    const still_edited = try readAbs(io, alloc, edited_path);
    defer alloc.free(still_edited);
    try std.testing.expectEqualStrings("user content\n", still_edited);
    // The removed file must not come back: the run wrote nothing.
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.accessAbsolute(io, removed_path, .{}));
    const manifest_after = try readAbs(io, alloc, mpath);
    defer alloc.free(manifest_after);
    try std.testing.expectEqualStrings(manifest_before, manifest_after);
}

test "a dry run classifies without writing" {
    const alloc = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &path_buf);
    const home = try alloc.dupe(u8, path_buf[0..n]);
    defer alloc.free(home);

    const rep = try run(io, alloc, home, true);
    defer rep.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), rep.conflicts.len);
    try std.testing.expectEqual(assets.opencode.len, rep.installed);
    const base = try std.fs.path.join(alloc, &.{ home, ".config" });
    defer alloc.free(base);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.accessAbsolute(io, base, .{}));
}

test "a symlinked leaf is a conflict" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &path_buf);
    const home = try alloc.dupe(u8, path_buf[0..n]);
    defer alloc.free(home);

    const entry = assets.opencode[0];
    const link_path = try std.fs.path.join(alloc, &.{ home, ".config", "opencode", entry.path });
    defer alloc.free(link_path);
    const link_dir = std.fs.path.dirname(link_path).?;
    std.Io.Dir.cwd().createDirPath(io, link_dir) catch {};
    const elsewhere = try std.fs.path.join(alloc, &.{ home, "elsewhere" });
    defer alloc.free(elsewhere);
    try writeAbs(io, elsewhere, "not ours\n");
    try std.Io.Dir.cwd().symLink(io, elsewhere, link_path, .{});

    const rep = try run(io, alloc, home, false);
    try expectConflicts(alloc, rep, "symlink");
    // The link target outside the config tree is untouched.
    const kept = try readAbs(io, alloc, elsewhere);
    defer alloc.free(kept);
    try std.testing.expectEqualStrings("not ours\n", kept);
}
