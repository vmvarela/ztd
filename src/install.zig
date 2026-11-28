//! `ztd install`: publish the embedded OpenCode integration and method
//! templates under a no-clobber preflight. The whole bundle is classified
//! before the first write; any conflict aborts the run and nothing is written.
//!
//! A hidden manifest next to the installed files records the SHA-256 of every
//! managed path, so a later run can tell an upgrade from a file the user
//! edited. Ported from internal/install/install.go.

const std = @import("std");
const Io = std.Io;
const errors = @import("errors.zig");
const jsonw = @import("json.zig");
const timeutil = @import("timeutil.zig");
const embedded = @import("install_assets.zig");

pub const manifest_name = ".ztd-assets.json";
const manifest_format = 1;
/// A file at or above this size cannot match an embedded asset, so it is a
/// conflict instead of being loaded.
const max_asset_bytes = 1 << 20;

pub const Report = struct {
    installed: usize = 0,
    updated: usize = 0,
    unchanged: usize = 0,
    conflicts: []const []const u8 = &.{},

    pub fn write(self: Report, o: *jsonw.Obj) !void {
        try o.int("installed", @intCast(self.installed));
        try o.int("updated", @intCast(self.updated));
        try o.int("unchanged", @intCast(self.unchanged));
        if (self.conflicts.len > 0) {
            var arr = try o.arr("conflicts");
            for (self.conflicts) |msg| try arr.str(msg);
            try arr.end();
        }
    }
};

pub const Config = struct {
    prefix: []const u8,
    root: []const u8,
    require_root: bool = false,
    version: []const u8,
    dry_run: bool = false,
};

const Entry = struct {
    rel: []const u8,
    data: []const u8,
    sha: [64]u8,
};

const Action = enum { install, update, unchanged };

fn shaHex(data: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

const Stat = union(enum) { missing, ok: std.Io.File.Stat };

fn lstat(io: Io, path: []const u8) !Stat {
    const st = std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch |e| switch (e) {
        error.FileNotFound => return .missing,
        else => return e,
    };
    return .{ .ok = st };
}

fn isSymlink(st: std.Io.File.Stat) bool {
    return st.kind == .sym_link;
}

/// Absent is fine: the publish phase creates it. A symlink or a file where a
/// directory belongs is a conflict.
fn checkDir(a: std.mem.Allocator, io: Io, path: []const u8) !?[]const u8 {
    switch (try lstat(io, path)) {
        .missing => return null,
        .ok => |st| {
            if (isSymlink(st)) return try std.fmt.allocPrint(a, "symlink ancestor {s}", .{path});
            if (st.kind != .directory) return try std.fmt.allocPrint(a, "not a directory {s}", .{path});
            return null;
        },
    }
}

fn joinPath(a: std.mem.Allocator, root: []const u8, rel: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, "{s}/{s}", .{ root, rel });
}

fn parentOf(path: []const u8) []const u8 {
    return std.fs.path.dirname(path) orelse path;
}

fn dirOfRel(rel: []const u8) []const u8 {
    return std.fs.path.dirname(rel) orelse "";
}

/// Runs one bundle publish. Conflicts come back in the report and nothing is
/// written when they do; anything else is an error.
pub fn run(a: std.mem.Allocator, io: Io, cfg: Config) !Report {
    var entries: std.ArrayList(Entry) = .empty;
    for (embedded.assets) |asset| {
        if (!std.mem.eql(u8, asset.prefix, cfg.prefix)) continue;
        try entries.append(a, .{ .rel = asset.rel, .data = asset.data, .sha = shaHex(asset.data) });
    }
    if (entries.items.len == 0) return errors.invalid("no assets embedded under \"{s}\"", .{cfg.prefix});

    if (cfg.require_root) {
        const missing = "store root missing or not a directory; run `ztd init` first";
        switch (try lstat(io, cfg.root)) {
            .missing => return errors.invalid("{s}: {s}", .{ cfg.root, missing }),
            .ok => |st| {
                if (isSymlink(st) or st.kind != .directory) {
                    return errors.invalid("{s}: {s}", .{ cfg.root, missing });
                }
            },
        }
    }

    var conflicts: std.ArrayList([]const u8) = .empty;
    var dirs: std.ArrayList([]const u8) = .empty;
    try dirs.append(a, try a.dupe(u8, cfg.root));
    switch (try lstat(io, cfg.root)) {
        .missing => {
            const parent = parentOf(cfg.root);
            if (!std.mem.eql(u8, parent, cfg.root)) try dirs.append(a, try a.dupe(u8, parent));
        },
        .ok => {},
    }
    for (entries.items) |entry| {
        const dir = dirOfRel(entry.rel);
        if (dir.len == 0) continue;
        var acc: std.ArrayList(u8) = .empty;
        var it = std.mem.splitScalar(u8, dir, '/');
        while (it.next()) |comp| {
            if (acc.items.len > 0) try acc.append(a, '/');
            try acc.appendSlice(a, comp);
            try dirs.append(a, try joinPath(a, cfg.root, acc.items));
        }
    }
    for (dirs.items) |dir| {
        if (try checkDir(a, io, dir)) |msg| try conflicts.append(a, msg);
    }

    const manifest_path = try joinPath(a, cfg.root, manifest_name);
    var old_assets = std.StringHashMap([]const u8).init(a);
    var old_version: []const u8 = "";
    try readManifest(a, io, manifest_path, &old_assets, &old_version, &conflicts);

    var actions: std.ArrayList(Action) = .empty;
    for (entries.items) |entry| {
        const target = try joinPath(a, cfg.root, entry.rel);
        const st = try lstat(io, target);
        switch (st) {
            .missing => {
                try actions.append(a, .install);
                continue;
            },
            .ok => |info| {
                if (isSymlink(info)) {
                    try conflicts.append(a, try std.fmt.allocPrint(a, "symlink {s}", .{target}));
                    try actions.append(a, .unchanged);
                    continue;
                }
                if (info.kind != .file) {
                    try conflicts.append(a, try std.fmt.allocPrint(a, "not a regular file {s}", .{target}));
                    try actions.append(a, .unchanged);
                    continue;
                }
                if (info.size > max_asset_bytes) {
                    try conflicts.append(a, try std.fmt.allocPrint(a, "differs {s}", .{target}));
                    try actions.append(a, .unchanged);
                    continue;
                }
                const disk = std.Io.Dir.cwd().readFileAlloc(io, target, a, .limited(max_asset_bytes)) catch |e| {
                    try conflicts.append(a, try std.fmt.allocPrint(a, "cannot inspect {s}: {s}", .{ target, @errorName(e) }));
                    try actions.append(a, .unchanged);
                    continue;
                };
                const got = shaHex(disk);
                if (std.mem.eql(u8, &got, &entry.sha)) {
                    try actions.append(a, .unchanged);
                } else if (old_assets.get(entry.rel)) |recorded| {
                    if (std.mem.eql(u8, recorded, &got)) {
                        try actions.append(a, .update);
                    } else {
                        try conflicts.append(a, try std.fmt.allocPrint(a, "differs {s}", .{target}));
                        try actions.append(a, .unchanged);
                    }
                } else {
                    try conflicts.append(a, try std.fmt.allocPrint(a, "differs {s}", .{target}));
                    try actions.append(a, .unchanged);
                }
            },
        }
    }
    if (conflicts.items.len > 0) return .{ .conflicts = conflicts.items };

    var report = Report{};
    for (actions.items) |action| switch (action) {
        .install => report.installed += 1,
        .update => report.updated += 1,
        .unchanged => report.unchanged += 1,
    };
    if (cfg.dry_run) return report;

    // The manifest is rewritten only when the recorded bytes or the version
    // change, so a rerun from the same binary keeps it byte-identical.
    var next = std.StringHashMap([]const u8).init(a);
    var old_it = old_assets.iterator();
    while (old_it.next()) |kv| {
        var managed = false;
        for (entries.items) |entry| {
            if (std.mem.eql(u8, entry.rel, kv.key_ptr.*)) {
                managed = true;
                break;
            }
        }
        if (!managed) try next.put(kv.key_ptr.*, kv.value_ptr.*);
    }
    for (entries.items) |entry| try next.put(entry.rel, &entry.sha);

    var manifest_text: ?[]const u8 = null;
    if (!std.mem.eql(u8, old_version, cfg.version) or !sameShas(a, &old_assets, &next)) {
        manifest_text = try renderManifest(a, io, cfg.version, &next);
    }

    for (dirs.items) |dir| {
        std.Io.Dir.cwd().createDirPath(io, dir) catch |e| switch (e) {
            error.PathAlreadyExists => {},
            else => return errors.fail(.io_error, "create {s}: {s}", .{ dir, @errorName(e) }),
        };
    }
    var recheck: std.ArrayList([]const u8) = .empty;
    for (dirs.items) |dir| {
        if (try checkDir(a, io, dir)) |msg| try recheck.append(a, msg);
    }
    if (recheck.items.len > 0) return .{ .conflicts = recheck.items };

    for (entries.items, actions.items) |entry, action| {
        if (action == .unchanged) continue;
        const target = try joinPath(a, cfg.root, entry.rel);
        if (action == .install) {
            try createExclusive(io, target, entry.data);
        } else {
            try replaceFile(a, io, target, entry.data);
        }
    }
    if (manifest_text) |text| try replaceFile(a, io, manifest_path, text);
    return report;
}

fn sameShas(a: std.mem.Allocator, old: *std.StringHashMap([]const u8), next: *std.StringHashMap([]const u8)) bool {
    _ = a;
    if (old.count() != next.count()) return false;
    var it = next.iterator();
    while (it.next()) |kv| {
        const before = old.get(kv.key_ptr.*) orelse return false;
        if (!std.mem.eql(u8, before, kv.value_ptr.*)) return false;
    }
    return true;
}

fn readManifest(
    a: std.mem.Allocator,
    io: Io,
    path: []const u8,
    assets: *std.StringHashMap([]const u8),
    version: *[]const u8,
    conflicts: *std.ArrayList([]const u8),
) !void {
    const st = try lstat(io, path);
    switch (st) {
        .missing => return,
        .ok => |info| {
            if (info.kind != .file or isSymlink(info)) {
                try conflicts.append(a, try std.fmt.allocPrint(a, "not a regular file {s}", .{path}));
                return;
            }
            if (info.size > max_asset_bytes) return;
        },
    }
    const data = std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(max_asset_bytes)) catch return;
    const parsed = std.json.parseFromSlice(std.json.Value, a, data, .{}) catch return;
    if (parsed.value != .object) return;
    const format = jsonw.intField(parsed.value, "format") orelse return;
    if (format != manifest_format) return;
    if (jsonw.strField(parsed.value, "ztd_version")) |v| version.* = try a.dupe(u8, v);
    const list = jsonw.field(parsed.value, "assets") orelse return;
    if (list != .object) return;
    var it = list.object.iterator();
    while (it.next()) |kv| {
        if (kv.value_ptr.* != .string) continue;
        try assets.put(try a.dupe(u8, kv.key_ptr.*), try a.dupe(u8, kv.value_ptr.string));
    }
}

fn renderManifest(a: std.mem.Allocator, io: Io, version: []const u8, assets: *std.StringHashMap([]const u8)) ![]const u8 {
    var keys: std.ArrayList([]const u8) = .empty;
    var it = assets.iterator();
    while (it.next()) |kv| try keys.append(a, kv.key_ptr.*);
    std.mem.sort([]const u8, keys.items, {}, struct {
        fn less(_: void, lhs: []const u8, rhs: []const u8) bool {
            return std.mem.lessThan(u8, lhs, rhs);
        }
    }.less);

    var aw = Io.Writer.Allocating.init(a);
    var o = try jsonw.Obj.init(&aw.writer);
    try o.int("format", manifest_format);
    try o.str("ztd_version", version);
    var tbuf: [20]u8 = undefined;
    try o.str("installed_at", timeutil.fmtTime(timeutil.now(io), &tbuf));
    var map = try o.obj("assets");
    for (keys.items) |key| try map.str(key, assets.get(key).?);
    try map.end();
    try o.end();
    try aw.writer.writeByte('\n');
    return aw.written();
}

fn createExclusive(io: Io, path: []const u8, data: []const u8) !void {
    var file = std.Io.Dir.cwd().createFile(io, path, .{ .exclusive = true }) catch |e|
        return errors.fail(.io_error, "create {s}: {s}", .{ path, @errorName(e) });
    defer file.close(io);
    file.writeStreamingAll(io, data) catch |e|
        return errors.fail(.io_error, "write {s}: {s}", .{ path, @errorName(e) });
}

/// Writes through a temporary file in the same directory and renames it, so a
/// crash never leaves a truncated asset behind.
fn replaceFile(a: std.mem.Allocator, io: Io, path: []const u8, data: []const u8) !void {
    const stamp = Io.Timestamp.now(io, .real).nanoseconds;
    const tmp = try std.fmt.allocPrint(a, "{s}.ztd-tmp-{d}", .{ path, stamp });
    var file = std.Io.Dir.cwd().createFile(io, tmp, .{ .exclusive = true }) catch |e|
        return errors.fail(.io_error, "create {s}: {s}", .{ tmp, @errorName(e) });
    var closed = false;
    defer if (!closed) {
        file.close(io);
        std.Io.Dir.cwd().deleteFile(io, tmp) catch {};
    };
    file.writeStreamingAll(io, data) catch |e|
        return errors.fail(.io_error, "write {s}: {s}", .{ tmp, @errorName(e) });
    file.sync(io) catch |e|
        return errors.fail(.io_error, "sync {s}: {s}", .{ tmp, @errorName(e) });
    file.close(io);
    closed = true;
    std.Io.Dir.renameAbsolute(tmp, path, io) catch |e|
        return errors.fail(.io_error, "rename {s}: {s}", .{ path, @errorName(e) });
}

test "embedded bundle matches the repository trees" {
    // Guards against a stale src/install_bundle: the copy, the generated list
    // and the published bundles must agree byte for byte.
    const a = std.testing.allocator;
    const io = std.testing.io;
    const cases = [_]struct { prefix: []const u8, dir: []const u8, sub: []const u8 }{
        .{ .prefix = "integrations/opencode", .dir = "integrations/opencode", .sub = "skills" },
        .{ .prefix = "method", .dir = "method", .sub = "templates" },
    };
    for (cases) |case| {
        var listed: std.ArrayList([]const u8) = .empty;
        defer listed.deinit(a);
        for (embedded.assets) |asset| {
            if (!std.mem.eql(u8, asset.prefix, case.prefix)) continue;
            try listed.append(a, asset.rel);
            const path = try std.fmt.allocPrint(a, "{s}/{s}/{s}", .{ case.dir, case.sub, asset.rel[case.sub.len + 1 ..] });
            defer a.free(path);
            const disk = try std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(max_asset_bytes));
            defer a.free(disk);
            try std.testing.expectEqualStrings(disk, asset.data);
        }
        const walk_root = try std.fmt.allocPrint(a, "{s}/{s}", .{ case.dir, case.sub });
        defer a.free(walk_root);
        var dir = try std.Io.Dir.cwd().openDir(io, walk_root, .{ .iterate = true });
        defer dir.close(io);
        var walker = try dir.walk(a);
        defer walker.deinit();
        var count: usize = 0;
        while (try walker.next(io)) |entry| {
            if (entry.kind != .file) continue;
            if (std.mem.endsWith(u8, entry.basename, ".DS_Store")) continue;
            count += 1;
        }
        try std.testing.expectEqual(listed.items.len, count);
    }
}
