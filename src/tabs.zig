//! Document tab list: entries with their own title, pinned or not, with
//! focus, an unpinned cap, and closing that keeps the focus valid.

const std = @import("std");

pub const Entry = struct {
    key: []const u8, // owned copy
    title: []const u8, // owned copy
    pinned: bool = false,
};

pub const List = struct {
    alloc: std.mem.Allocator,
    entries: std.ArrayList(Entry),
    active: usize = 0,
    max_unpinned: usize = 8,

    pub fn init(alloc: std.mem.Allocator) List {
        return .{ .alloc = alloc, .entries = .empty };
    }

    pub fn deinit(self: *List) void {
        for (self.entries.items) |e| {
            self.alloc.free(e.key);
            self.alloc.free(e.title);
        }
        self.entries.deinit(self.alloc);
    }

    /// If the key already exists: focus it and refresh its title.
    /// Otherwise append it at the end and focus it. Pinned entries do not
    /// count toward `max_unpinned`; exceeding the cap drops the oldest
    /// unpinned entry (never the active one unless it is the only
    /// candidate). Returns the active index.
    pub fn open(self: *List, key: []const u8, title: []const u8, pinned: bool) !usize {
        if (self.indexOf(key)) |idx| {
            const fresh = try self.alloc.dupe(u8, title);
            self.alloc.free(self.entries.items[idx].title);
            self.entries.items[idx].title = fresh;
            self.active = idx;
            return idx;
        }
        const k = try self.alloc.dupe(u8, key);
        errdefer self.alloc.free(k);
        const t = try self.alloc.dupe(u8, title);
        errdefer self.alloc.free(t);
        try self.entries.append(self.alloc, .{ .key = k, .title = t, .pinned = pinned });
        self.active = self.entries.items.len - 1;
        self.enforceUnpinnedCap();
        return self.active;
    }

    /// Close one entry (no-op if pinned or out of range), freeing its
    /// strings. Keeps `active` valid, preferring the entry to the left.
    pub fn close(self: *List, index: usize) void {
        if (index >= self.entries.items.len) return;
        if (self.entries.items[index].pinned) return;
        self.removeAt(index);
    }

    /// Remove every entry whose key is not in `keys`; pinned entries are
    /// kept even when their key is missing. `keys` is []const []const u8.
    pub fn retainKeys(self: *List, keys: []const []const u8) void {
        var i = self.entries.items.len;
        while (i > 0) {
            i -= 1;
            const e = self.entries.items[i];
            if (e.pinned) continue;
            if (!contains(keys, e.key)) self.removeAt(i);
        }
    }

    pub fn indexOf(self: *const List, key: []const u8) ?usize {
        for (self.entries.items, 0..) |e, i| {
            if (std.mem.eql(u8, e.key, key)) return i;
        }
        return null;
    }

    pub fn activeEntry(self: *const List) ?Entry {
        if (self.entries.items.len == 0) return null;
        return self.entries.items[self.active];
    }

    /// Move the focus by `delta` with wraparound; returns the new index.
    pub fn cycle(self: *List, delta: isize) usize {
        const len = self.entries.items.len;
        if (len == 0) {
            self.active = 0;
            return 0;
        }
        const i = @mod(@as(i64, @intCast(self.active)) + @as(i64, @intCast(delta)), @as(i64, @intCast(len)));
        self.active = @intCast(i);
        return self.active;
    }

    /// Free one entry and shift the focus left when needed; `active`
    /// stays in range and 0 when the list becomes empty.
    fn removeAt(self: *List, index: usize) void {
        const gone = self.entries.orderedRemove(index);
        self.alloc.free(gone.key);
        self.alloc.free(gone.title);
        if (index < self.active or (index == self.active and self.active > 0)) {
            self.active -= 1;
        }
    }

    /// Enforce the unpinned cap after an insert: drop the oldest entry
    /// that is not the active one; if the active one is the only
    /// candidate, drop it.
    fn enforceUnpinnedCap(self: *List) void {
        while (self.countUnpinned() > self.max_unpinned) {
            var victim: ?usize = null;
            for (self.entries.items, 0..) |e, i| {
                if (e.pinned or i == self.active) continue;
                victim = i;
                break;
            }
            self.removeAt(victim orelse self.active);
        }
    }

    fn countUnpinned(self: *const List) usize {
        var n: usize = 0;
        for (self.entries.items) |e| {
            if (!e.pinned) n += 1;
        }
        return n;
    }

    fn contains(keys: []const []const u8, key: []const u8) bool {
        for (keys) |k| if (std.mem.eql(u8, k, key)) return true;
        return false;
    }
};

test "open appends and refocuses duplicate" {
    const alloc = std.testing.allocator;
    var l = List.init(alloc);
    defer l.deinit();

    try std.testing.expectEqual(@as(usize, 0), try l.open("a", "A", false));
    try std.testing.expectEqual(@as(usize, 1), try l.open("b", "B", false));
    try std.testing.expectEqual(@as(usize, 2), try l.open("c", "C", false));
    try std.testing.expectEqual(@as(usize, 3), l.entries.items.len);

    // A repeated key adds no entry and moves the focus back to the existing one.
    try std.testing.expectEqual(@as(usize, 0), try l.open("a", "A", false));
    try std.testing.expectEqual(@as(usize, 0), l.active);
    try std.testing.expectEqual(@as(usize, 3), l.entries.items.len);
}

test "title refresh on duplicate" {
    const alloc = std.testing.allocator;
    var l = List.init(alloc);
    defer l.deinit();

    _ = try l.open("a", "viejo", false);
    _ = try l.open("b", "B", false);
    _ = try l.open("a", "nuevo", false);
    try std.testing.expectEqualStrings("nuevo", l.entries.items[0].title);
    try std.testing.expectEqual(@as(usize, 2), l.entries.items.len);
}

test "pinned excluded from cap" {
    const alloc = std.testing.allocator;
    var l = List.init(alloc);
    defer l.deinit();
    l.max_unpinned = 1;

    _ = try l.open("p1", "P1", true);
    _ = try l.open("p2", "P2", true);
    _ = try l.open("u1", "U1", false);
    // Pinned entries do not count toward the cap.
    try std.testing.expectEqual(@as(usize, 3), l.entries.items.len);

    _ = try l.open("u2", "U2", false);
    // The oldest unpinned entry drops; the pinned ones stay intact.
    try std.testing.expectEqual(@as(usize, 3), l.entries.items.len);
    try std.testing.expect(l.indexOf("u1") == null);
    try std.testing.expect(l.indexOf("p1") != null);
    try std.testing.expect(l.indexOf("p2") != null);
}

test "oldest unpinned dropped at cap" {
    const alloc = std.testing.allocator;
    var l = List.init(alloc);
    defer l.deinit();
    l.max_unpinned = 2;

    _ = try l.open("u1", "U1", false);
    _ = try l.open("u2", "U2", false);
    try std.testing.expectEqual(@as(usize, 2), l.entries.items.len);

    _ = try l.open("u3", "U3", false);
    try std.testing.expectEqual(@as(usize, 2), l.entries.items.len);
    try std.testing.expect(l.indexOf("u1") == null);
    try std.testing.expectEqual(@as(usize, 0), l.indexOf("u2").?);
    try std.testing.expectEqual(@as(usize, 1), l.indexOf("u3").?);
    try std.testing.expectEqual(@as(usize, 1), l.active);
}

test "close active moves left" {
    const alloc = std.testing.allocator;
    var l = List.init(alloc);
    defer l.deinit();

    _ = try l.open("a", "A", false);
    _ = try l.open("b", "B", false);
    _ = try l.open("c", "C", false);

    // Closing the active entry leaves the focus on the entry to its left.
    l.close(2);
    try std.testing.expectEqual(@as(usize, 2), l.entries.items.len);
    try std.testing.expectEqual(@as(usize, 1), l.active);
    try std.testing.expectEqualStrings("B", l.activeEntry().?.title);

    // Closing to the left of the active entry shifts the focus left.
    l.close(0);
    try std.testing.expectEqual(@as(usize, 0), l.active);
    try std.testing.expectEqualStrings("B", l.activeEntry().?.title);

    // Closing everything leaves the list empty with focus 0.
    l.close(1);
    l.close(0);
    try std.testing.expectEqual(@as(usize, 0), l.entries.items.len);
    try std.testing.expectEqual(@as(usize, 0), l.active);
    try std.testing.expect(l.activeEntry() == null);
}

test "close pinned is a no-op" {
    const alloc = std.testing.allocator;
    var l = List.init(alloc);
    defer l.deinit();

    _ = try l.open("a", "A", false);
    _ = try l.open("p", "P", true);
    l.close(1);
    try std.testing.expectEqual(@as(usize, 2), l.entries.items.len);
    try std.testing.expect(l.indexOf("p") != null);

    // Out of range is a no-op too.
    l.close(99);
    try std.testing.expectEqual(@as(usize, 2), l.entries.items.len);
    try std.testing.expectEqual(@as(usize, 1), l.active);
}

test "retainKeys drops missing but keeps pinned" {
    const alloc = std.testing.allocator;
    var l = List.init(alloc);
    defer l.deinit();

    _ = try l.open("a", "A", false);
    _ = try l.open("b", "B", false);
    _ = try l.open("p", "P", true);
    _ = try l.open("c", "C", false); // active

    l.retainKeys(&[_][]const u8{ "a", "c" });
    // "b" is not in keys and is not pinned; "p" stays even when missing from keys.
    try std.testing.expectEqual(@as(usize, 3), l.entries.items.len);
    try std.testing.expect(l.indexOf("b") == null);
    try std.testing.expect(l.indexOf("p") != null);
    try std.testing.expectEqual(@as(usize, 2), l.active);
    try std.testing.expectEqualStrings("C", l.activeEntry().?.title);
}

test "cycle wraps" {
    const alloc = std.testing.allocator;
    var l = List.init(alloc);
    defer l.deinit();

    _ = try l.open("a", "A", false);
    _ = try l.open("b", "B", false);
    try std.testing.expectEqual(@as(usize, 1), l.active);

    try std.testing.expectEqual(@as(usize, 0), l.cycle(1)); // 1 → 0
    try std.testing.expectEqual(@as(usize, 1), l.cycle(-1)); // 0 → 1
    try std.testing.expectEqual(@as(usize, 0), l.cycle(-1)); // 1 → 0
    try std.testing.expectEqual(@as(usize, 1), l.cycle(1)); // 0 → 1
}

test "deinit frees" {
    const alloc = std.testing.allocator;
    var l = List.init(alloc);
    _ = try l.open("a", "A", false);
    _ = try l.open("b", "B", true);
    _ = try l.open("c", "C", false);
    l.close(0);
    l.retainKeys(&[_][]const u8{"c"});
    l.deinit();
    // std.testing.allocator fails the test if any copy is left unfreed.
}
