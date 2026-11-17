const std = @import("std");
const builtin = @import("builtin");

pub const max_file_bytes: usize = 16 * 1024 * 1024;

/// A journal path must stay inside the workspace and use `/` separators.
pub fn safeRel(rel: []const u8) bool {
    if (rel.len == 0 or std.fs.path.isAbsolute(rel)) return false;
    if (std.mem.indexOfScalar(u8, rel, '\\') != null) return false;
    var it = std.mem.splitScalar(u8, rel, '/');
    while (it.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return false;
    }
    return true;
}

pub const Store = struct {
    io: std.Io,
    alloc: std.mem.Allocator,
    path: []const u8,
    dir: std.Io.Dir,
    lock_file: ?std.Io.File = null,
    locked: bool = false,

    pub fn open(io: std.Io, alloc: std.mem.Allocator, path: []const u8) !Store {
        const dir = if (std.fs.path.isAbsolute(path))
            try std.Io.Dir.openDirAbsolute(io, path, .{ .iterate = true })
        else
            try std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
        return .{ .io = io, .alloc = alloc, .path = path, .dir = dir };
    }

    pub fn deinit(self: *Store) void {
        self.unlock();
        self.dir.close(self.io);
    }

    pub fn unlock(self: *Store) void {
        if (self.lock_file) |f| {
            f.unlock(self.io);
            f.close(self.io);
            self.lock_file = null;
        }
        self.locked = false;
    }

    /// Shared for reads, exclusive for mutations. A missing lock file is fine
    /// for readers: there is nothing to coordinate with yet.
    pub fn lock(self: *Store, exclusive: bool) !void {
        if (self.locked) return;
        if (exclusive) {
            try self.dir.createDirPath(self.io, ".state");
        } else {
            self.dir.access(self.io, ".state/lock", .{}) catch return;
        }
        var file = try self.dir.createFile(self.io, ".state/lock", .{ .read = true, .truncate = false });
        errdefer file.close(self.io);
        try file.lock(self.io, if (exclusive) .exclusive else .shared);
        self.lock_file = file;
        self.locked = true;
    }

    pub fn exists(self: *Store, rel: []const u8) bool {
        self.dir.access(self.io, rel, .{}) catch return false;
        return true;
    }

    pub fn read(self: *Store, rel: []const u8) ![]u8 {
        const raw = try self.dir.readFileAlloc(self.io, rel, self.alloc, .limited(max_file_bytes));
        if (std.mem.indexOf(u8, raw, "\r\n") == null) return raw;
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(self.alloc);
        var i: usize = 0;
        while (i < raw.len) : (i += 1) {
            if (raw[i] == '\r' and i + 1 < raw.len and raw[i + 1] == '\n') continue;
            try out.append(self.alloc, raw[i]);
        }
        return out.toOwnedSlice(self.alloc);
    }

    pub fn readOptional(self: *Store, rel: []const u8) !?[]u8 {
        return self.read(rel) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
    }

    pub fn writeAtomic(self: *Store, rel: []const u8, data: []const u8) !void {
        var af = try self.dir.createFileAtomic(self.io, rel, .{ .replace = true });
        defer af.deinit(self.io);
        try af.file.writeStreamingAll(self.io, data);
        try af.file.sync(self.io);
        try self.replaceAtomic(&af);
        if (builtin.os.tag != .windows) {
            _ = std.c.fsync(self.dir.handle);
        }
    }

    fn replaceAtomic(self: *Store, af: *std.Io.File.Atomic) !void {
        var attempts: u8 = 0;
        while (true) {
            af.replace(self.io) catch |err| {
                // Windows antivirus/editors can hold the destination briefly.
                if (builtin.os.tag == .windows and err == error.AccessDenied and attempts < 5) {
                    attempts += 1;
                    std.Io.sleep(self.io, .{ .nanoseconds = 10 * std.time.ns_per_ms }, .awake) catch {};
                    continue;
                }
                return err;
            };
            return;
        }
    }

    pub fn createIfMissing(self: *Store, rel: []const u8, data: []const u8) !bool {
        if (self.exists(rel)) return false;
        var file = self.dir.createFile(self.io, rel, .{
            .read = false,
            .truncate = false,
            .exclusive = true,
        }) catch |err| switch (err) {
            error.PathAlreadyExists => return false,
            else => return err,
        };
        defer file.close(self.io);
        try file.writeStreamingAll(self.io, data);
        try file.sync(self.io);
        return true;
    }
};

pub fn pathExists(io: std.Io, path: []const u8) bool {
    if (std.fs.path.isAbsolute(path)) {
        std.Io.Dir.accessAbsolute(io, path, .{}) catch return false;
    } else {
        std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    }
    return true;
}

/// Platform home directory: `$HOME`, then `$USERPROFILE` on Windows. A missing
/// home is a workspace error because the default root cannot be located.
pub fn homeDir(io: std.Io, alloc: std.mem.Allocator) ![]const u8 {
    _ = io;
    const raw = std.c.getenv("HOME") orelse std.c.getenv("USERPROFILE") orelse return error.InvalidWorkspace;
    const home = std.mem.sliceTo(raw, 0);
    if (home.len == 0) return error.InvalidWorkspace;
    return alloc.dupe(u8, home);
}

/// Store directory from root precedence alone: an explicit `--root`/`ZTD_ROOT`
/// path verbatim, otherwise `$HOME/.ztd`. It never inspects the filesystem and
/// never walks the working directory looking for a `ztd/`.
pub fn rootPath(io: std.Io, alloc: std.mem.Allocator, explicit: ?[]const u8) ![]const u8 {
    if (explicit) |path| return alloc.dupe(u8, path);
    const home = try homeDir(io, alloc);
    defer alloc.free(home);
    return std.fs.path.join(alloc, &.{ home, ".ztd" });
}

/// `rootPath` plus existence: everything except `status` and `init` needs a
/// store that is already there.
pub fn resolveRoot(io: std.Io, alloc: std.mem.Allocator, explicit: ?[]const u8) ![]const u8 {
    const path = try rootPath(io, alloc, explicit);
    errdefer alloc.free(path);
    if (!pathExists(io, path)) return error.InvalidWorkspace;
    return path;
}

test "root precedence uses the explicit path verbatim and never walks upward" {
    const alloc = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // An explicit path is the store itself: no `ztd` component is appended,
    // whatever it looks like.
    const explicit_path = try rootPath(io, alloc, "/tmp/store");
    defer alloc.free(explicit_path);
    try std.testing.expectEqualStrings("/tmp/store", explicit_path);
    try std.testing.expectError(error.InvalidWorkspace, resolveRoot(io, alloc, "/definitely/not/here"));

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &path_buf);
    const existing = try resolveRoot(io, alloc, path_buf[0..n]);
    defer alloc.free(existing);
    try std.testing.expectEqualStrings(path_buf[0..n], existing);

    // The default is `$HOME/.ztd`, independent of the working directory: the
    // resolution result is built from the environment alone (the no-cwd-walk
    // behaviour with a store on the way up is covered by the integration test).
    const home = try homeDir(io, alloc);
    defer alloc.free(home);
    const expected = try std.fs.path.join(alloc, &.{ home, ".ztd" });
    defer alloc.free(expected);
    const default_root = try rootPath(io, alloc, null);
    defer alloc.free(default_root);
    try std.testing.expectEqualStrings(expected, default_root);
}
