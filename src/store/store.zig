//! Store bootstrap: open, migrate, transactions and the shared persistence
//! helpers (idempotency, generated ids, scope filters).

const std = @import("std");
const sqlite = @import("../sqlite.zig");
const errors = @import("../errors.zig");
const timeutil = @import("../timeutil.zig");

pub const migration_files = [_][]const u8{
    @embedFile("migrations/0001_core.sql"),
    @embedFile("migrations/0002_journey.sql"),
    @embedFile("migrations/0003_goals.sql"),
    @embedFile("migrations/0004_sources.sql"),
    @embedFile("migrations/0005_work_item_fields.sql"),
    @embedFile("migrations/0006_documents.sql"),
    @embedFile("migrations/0007_documents_fts.sql"),
};

pub const Store = struct {
    db: sqlite.Db,

    /// Opens the database and applies every migration not yet in user_version.
    pub fn open(path: [:0]const u8) errors.Ztd!Store {
        var db = try sqlite.Db.open(path);
        errdefer db.close();
        var s = Store{ .db = db };
        try s.bootstrap();
        return s;
    }

    pub fn close(self: *Store) void {
        self.db.close();
    }

    fn userVersion(self: *Store) errors.Ztd!i64 {
        var stmt = try self.db.prepare("PRAGMA user_version");
        defer stmt.finalize();
        if (!try stmt.step()) return errors.fail(.db_incompatible, "cannot read PRAGMA user_version", .{});
        return stmt.int(0);
    }

    fn bootstrap(self: *Store) errors.Ztd!void {
        const version = try self.userVersion();
        const highest: i64 = migration_files.len;
        if (version > highest) {
            return errors.fail(.db_incompatible,
                "database schema version {d} is newer than the highest supported version {d}",
                .{ version, highest });
        }
        if (version == 0) {
            var stmt = try self.db.prepare(
                "SELECT count(*) FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'",
            );
            defer stmt.finalize();
            if (!try stmt.step()) return errors.fail(.db_incompatible, "cannot inspect schema", .{});
            if (stmt.int(0) > 0) {
                return errors.fail(.db_incompatible,
                    "existing SQLite file has tables but no ZTD schema version; refusing to initialize it", .{});
            }
        }
        var i: usize = @intCast(version);
        while (i < migration_files.len) : (i += 1) {
            const n = i + 1;
            try self.db.begin();
            errdefer self.db.rollback();
            self.db.exec(migration_files[i]) catch |e| {
                self.db.rollback();
                return errors.fail(.db_incompatible, "migration {d} failed: {s}", .{ n, errors.detail() }) catch e;
            };
            var sql_buf: [48]u8 = undefined;
            const sql = std.fmt.bufPrint(&sql_buf, "PRAGMA user_version = {d}", .{n}) catch unreachable;
            self.db.exec(sql) catch |e| {
                self.db.rollback();
                return errors.fail(.db_incompatible, "migration {d} failed to record its version", .{n}) catch e;
            };
            self.db.commit() catch |e| {
                self.db.rollback();
                return e;
            };
        }
    }

    /// One short BEGIN IMMEDIATE transaction; any error rolls back all writes.
    pub fn begin(self: *Store) errors.Ztd!void {
        try self.db.begin();
    }

    pub fn commit(self: *Store) errors.Ztd!void {
        self.db.commit() catch |e| {
            self.db.rollback();
            return e;
        };
    }

    pub fn rollback(self: *Store) void {
        self.db.rollback();
    }
};

pub fn sha256hex(s: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(s, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

/// The idempotency contract: same key and same payload replays the stored
/// JSON; same key with another payload is idempotency_conflict.
pub fn lookupIdem(
    stmt: *sqlite.Statement,
    key: []const u8,
    hash: []const u8,
) errors.Ztd!?[]const u8 {
    try stmt.bindText(1, key);
    if (!try stmt.step()) {
        stmt.reset();
        return null;
    }
    const stored_hash = stmt.text(0);
    const result = stmt.text(1);
    // The stored JSON lives in SQLite's buffer until the statement is reset,
    // so copy it before that happens.
    if (!std.mem.eql(u8, stored_hash, hash)) {
        return errors.fail(.idempotency_conflict,
            "idempotency key \"{s}\" was already used with a different payload", .{key});
    }
    return result;
}

/// Returns the first unused numeric suffix after prefix, e.g. "T-20261119-".
pub fn nextDailySeq(db: sqlite.Db, table: []const u8, prefix: []const u8) errors.Ztd!i64 {
    var sql_buf: [160]u8 = undefined;
    const sql = std.fmt.bufPrint(&sql_buf, "SELECT id FROM {s} WHERE id LIKE ?", .{table}) catch unreachable;
    var stmt = try db.prepare(sql);
    defer stmt.finalize();
    var like_buf: [64]u8 = undefined;
    const like = std.fmt.bufPrint(&like_buf, "{s}%", .{prefix}) catch unreachable;
    try stmt.bindText(1, like);
    var max: i64 = 0;
    while (try stmt.step()) {
        const id = stmt.text(0);
        const suffix = id[prefix.len..];
        const n = std.fmt.parseInt(i64, suffix, 10) catch continue;
        if (n > max) max = n;
    }
    return max + 1;
}

/// Renders `?,?,?` for the binding's scopes; an empty binding is rejected.
pub fn scopeFilter(buf: []u8, count: usize) []const u8 {
    var i: usize = 0;
    while (i < count) : (i += 1) {
        if (i > 0) buf[i * 2 - 1] = ',';
        buf[i * 2] = '?';
    }
    return buf[0 .. if (count == 0) 0 else count * 2 - 1];
}

test "migrations apply on a fresh database" {
    var s = try Store.open(":memory:");
    defer s.close();
    var stmt = try s.db.prepare("SELECT count(*) FROM sqlite_master WHERE type='table' AND name='documents'");
    defer stmt.finalize();
    try std.testing.expect(try stmt.step());
    try std.testing.expectEqual(@as(i64, 1), stmt.int(0));
}

test "generated ids start at one per day" {
    var s = try Store.open(":memory:");
    defer s.close();
    try std.testing.expectEqual(@as(i64, 1), try nextDailySeq(s.db, "captures", "C-20261126-"));
}

test "sha256hex matches the Go encoding" {
    const h = sha256hex("abc");
    try std.testing.expectEqualStrings(
        "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
        &h,
    );
}
