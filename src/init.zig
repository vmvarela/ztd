const std = @import("std");
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
    .{ .path = "contexts.md", .content = "# Contextos activos\n\n| Contexto | Uso |\n| --- | --- |\n| personal | Asuntos personales |\n" },
    .{ .path = "config.json", .content = "{\"format\":1,\"policy\":{\"requireClientFor\":[],\"clientOnlyIn\":[]}}\n" },
    .{ .path = "inbox.md", .content = "# Inbox\n\n" },
    .{ .path = "lists/next.md", .content = "# Próximas acciones\n\n" },
    .{ .path = "lists/waiting.md", .content = "# En espera\n\n" },
    .{ .path = "lists/someday.md", .content = "# Algún día\n\n" },
    .{ .path = "lists/archive.md", .content = "# Archivo\n\n" },
    .{ .path = "lists/projects/index.md", .content = "# Proyectos\n\n" },
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
    "templates",
};

pub fn initWorkspace(io: std.Io, alloc: std.mem.Allocator, target: []const u8, dry_run: bool) !Result {
    const needs_join = !(std.mem.endsWith(u8, target, "ztd") or std.mem.endsWith(u8, target, "ztd/"));
    const ztd_path = if (needs_join)
        try std.fs.path.join(alloc, &.{ target, "ztd" })
    else
        target;
    defer if (needs_join) alloc.free(ztd_path);

    if (!dry_run) {
        std.Io.Dir.cwd().createDirPath(io, ztd_path) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
    } else if (!pathExists(io, ztd_path)) {
        var created: std.ArrayList([]const u8) = .empty;
        for (dirs) |dir| try created.append(alloc, try alloc.dupe(u8, dir));
        for (files) |f| try created.append(alloc, try alloc.dupe(u8, f.path));
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

    return .{ .root = try alloc.dupe(u8, ztd_path), .created = try created.toOwnedSlice(alloc) };
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
