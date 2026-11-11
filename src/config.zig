const std = @import("std");
const Store = @import("store.zig").Store;

pub const Policy = struct {
    requireClientFor: []const []const u8 = &.{},
    clientOnlyIn: []const []const u8 = &.{},
};

pub const Config = struct {
    format: u32 = 1,
    policy: Policy = .{},
};

pub fn load(store: *Store, alloc: std.mem.Allocator) !Config {
    const text = try store.readOptional("config.json") orelse return .{};
    const parsed = std.json.parseFromSlice(Config, alloc, text, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch |err| {
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.InvalidConfig,
        };
    };
    return parsed.value;
}

pub fn contains(list: []const []const u8, needle: []const u8) bool {
    for (list) |item| {
        if (std.mem.eql(u8, item, needle)) return true;
    }
    return false;
}

pub fn loadContexts(store: *Store, alloc: std.mem.Allocator) !std.ArrayList([]const u8) {
    const text = store.read("contexts.md") catch |err| switch (err) {
        error.FileNotFound => return error.InvalidWorkspace,
        else => return err,
    };
    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(alloc);
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (!std.mem.startsWith(u8, trimmed, "|")) continue;
        const end = std.mem.indexOfScalarPos(u8, trimmed, 1, '|') orelse continue;
        const cell = std.mem.trim(u8, trimmed[1..end], " \t");
        if (cell.len == 0) continue;
        if (std.mem.eql(u8, cell, "Contexto")) continue;
        if (std.mem.allEqual(u8, cell, '-')) continue;
        try out.append(alloc, try alloc.dupe(u8, cell));
    }
    return out;
}

pub fn projectValid(project: []const u8) bool {
    if (project.len == 0) return false;
    if (std.fs.path.isAbsolute(project)) return false;
    if (std.mem.indexOfScalar(u8, project, '\\') != null) return false;
    var it = std.mem.splitScalar(u8, project, '/');
    var parts: usize = 0;
    while (it.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return false;
        parts += 1;
    }
    return parts >= 1;
}

pub fn projectRegistered(store: *Store, alloc: std.mem.Allocator, project: []const u8) bool {
    if (!projectValid(project)) return false;
    const rel = std.fs.path.join(alloc, &.{ "lists", "projects", project }) catch return false;
    defer alloc.free(rel);
    const with_ext = std.fmt.allocPrint(alloc, "{s}.md", .{rel}) catch return false;
    defer alloc.free(with_ext);
    return store.exists(with_ext);
}
