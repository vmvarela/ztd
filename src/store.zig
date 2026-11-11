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

fn existsPath(io: std.Io, path: []const u8) bool {
    if (std.fs.path.isAbsolute(path)) {
        std.Io.Dir.accessAbsolute(io, path, .{}) catch return false;
    } else {
        std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    }
    return true;
}

fn hasWorkspace(io: std.Io, base: []const u8, alloc: std.mem.Allocator) bool {
    for ([_][]const u8{ "contexts.md", "config.json", "inbox.md" }) |name| {
        const p = std.fs.path.join(alloc, &.{ base, "ztd", name }) catch continue;
        defer alloc.free(p);
        if (existsPath(io, p)) return true;
    }
    return false;
}

/// Returns the ztd directory. Accepts a repository root or a ztd directory.
pub fn resolveRoot(io: std.Io, alloc: std.mem.Allocator, explicit: ?[]const u8) ![]const u8 {
    if (explicit) |base| {
        const contexts = try std.fs.path.join(alloc, &.{ base, "contexts.md" });
        defer alloc.free(contexts);
        if (existsPath(io, contexts)) {
            return alloc.dupe(u8, base);
        }
        if (hasWorkspace(io, base, alloc)) {
            return std.fs.path.join(alloc, &.{ base, "ztd" });
        }
        return error.InvalidWorkspace;
    }

    const cwd = try std.process.currentPathAlloc(io, alloc);
    var p: []const u8 = cwd;
    while (true) {
        if (hasWorkspace(io, p, alloc)) {
            return std.fs.path.join(alloc, &.{ p, "ztd" });
        }
        const parent = std.fs.path.dirname(p) orelse break;
        if (std.mem.eql(u8, parent, p)) break;
        p = parent;
    }
    return error.InvalidWorkspace;
}

test "resolve rejects missing workspace" {
    const alloc = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    try std.testing.expectError(error.InvalidWorkspace, resolveRoot(threaded.io(), alloc, "/definitely/not/here"));
}
