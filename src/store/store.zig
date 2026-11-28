//! Store bootstrap: open, migrate, transactions and the shared persistence
//! helpers (idempotency, generated ids, scope filters).

const std = @import("std");
const sqlite = @import("../sqlite.zig");
const errors = @import("../errors.zig");
const timeutil = @import("../timeutil.zig");

const StepFn = *const fn (*Store) errors.Ztd!void;

const Migration = struct {
    sql: []const u8,
    /// Bounded procedural steps (row mapping, guards) that plain SQL cannot
    /// express; they run inside the migration transaction.
    step: ?StepFn = null,
};

pub const migrations = [_]Migration{
    .{ .sql = @embedFile("migrations/0001_core.sql") },
    .{ .sql = @embedFile("migrations/0002_journey.sql") },
    .{ .sql = @embedFile("migrations/0003_goals.sql") },
    .{ .sql = @embedFile("migrations/0004_sources.sql") },
    .{ .sql = @embedFile("migrations/0005_work_item_fields.sql") },
    .{ .sql = @embedFile("migrations/0006_documents.sql") },
    .{ .sql = @embedFile("migrations/0007_documents_fts.sql") },
    .{ .sql = @embedFile("migrations/0008_provenance.sql") },
    .{ .sql = @embedFile("migrations/0009_sources_connector.sql") },
    .{ .sql = @embedFile("migrations/0010_knowledge_links.sql"), .step = migrateKnowledge },
    .{ .sql = @embedFile("migrations/0011_review_metrics.sql") },
    .{ .sql = @embedFile("migrations/0012_capture_body_ref.sql") },
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
        const highest: i64 = migrations.len;
        if (version > highest) {
            return errors.fail(.db_incompatible, "database schema version {d} is newer than the highest supported version {d}", .{ version, highest });
        }
        if (version == 0) {
            var stmt = try self.db.prepare(
                "SELECT count(*) FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'",
            );
            defer stmt.finalize();
            if (!try stmt.step()) return errors.fail(.db_incompatible, "cannot inspect schema", .{});
            if (stmt.int(0) > 0) {
                return errors.fail(.db_incompatible, "existing SQLite file has tables but no ZTD schema version; refusing to initialize it", .{});
            }
        }
        var i: usize = @intCast(version);
        while (i < migrations.len) : (i += 1) {
            const n = i + 1;
            try self.db.begin();
            self.db.exec(migrations[i].sql) catch |e| {
                self.db.rollback();
                // Copy the detail: fail() formats over the buffer it came from.
                var tmp: [4096]u8 = undefined;
                const detail = errors.detailCopy(&tmp);
                return errors.fail(.db_incompatible, "migration {d} failed: {s}", .{ n, detail }) catch e;
            };
            if (migrations[i].step) |step| {
                step(self) catch |e| {
                    self.db.rollback();
                    return e;
                };
            }
            try assertForeignKeys(self, n);
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
        return errors.fail(.idempotency_conflict, "idempotency key \"{s}\" was already used with a different payload", .{key});
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
    return buf[0..if (count == 0) 0 else count * 2 - 1];
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

/// A migration may never leave the schema with dangling references.
fn assertForeignKeys(s: *Store, version: usize) errors.Ztd!void {
    var stmt = try s.db.prepare("PRAGMA foreign_key_check");
    defer stmt.finalize();
    if (try stmt.step()) {
        return errors.fail(.db_incompatible, "migration {d} left a foreign key violation", .{version});
    }
}

fn firstLineTitle(id: []const u8, text: []const u8, buf: []u8) []const u8 {
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        const stripped = std.mem.trim(u8, std.mem.trimStart(u8, trimmed, "#"), " \t");
        const chosen = if (stripped.len > 0) stripped else trimmed;
        const n = @min(chosen.len, 80);
        @memcpy(buf[0..n], chosen[0..n]);
        return buf[0..n];
    }
    const n = @min(id.len, 80);
    @memcpy(buf[0..n], id[0..n]);
    return buf[0..n];
}

fn insertKnowledgeDocument(s: *Store, row: *sqlite.Statement) errors.Ztd!void {
    const id = row.text(0);
    var slug_buf: [128]u8 = undefined;
    const slug = std.fmt.bufPrint(&slug_buf, "kr/{s}", .{id}) catch
        return errors.fail(.db_incompatible, "knowledge id is too long to migrate: {s}", .{id});
    var title_buf: [80]u8 = undefined;
    const title = firstLineTitle(id, row.text(3), &title_buf);
    const status = if (std.mem.eql(u8, row.text(4), "superseded"))
        "superseded"
    else if (std.mem.eql(u8, row.text(5), "verified"))
        "verified"
    else
        "draft";
    const reviewed = row.optText(8);
    const updated_at = reviewed orelse row.text(11);

    var ins = try s.db.prepare(
        "INSERT INTO documents (id, scope_id, kind, slug, title, body, status, revision, " ++
            "created_at, updated_at, record_kind, approved_at, valid_from, source_refs, supersedes_id) " ++
            "VALUES (?, ?, 'knowledge', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
    );
    defer ins.finalize();
    try ins.bindText(1, id);
    try ins.bindText(2, row.text(1));
    try ins.bindText(3, slug);
    try ins.bindText(4, title);
    try ins.bindText(5, row.text(3));
    try ins.bindText(6, status);
    try ins.bindInt(7, row.int(10));
    try ins.bindText(8, row.text(11));
    try ins.bindText(9, updated_at);
    try ins.bindText(10, row.text(2));
    try ins.bindOptText(11, reviewed);
    try ins.bindOptText(12, row.optText(7));
    try ins.bindText(13, row.optText(6) orelse "[]");
    try ins.bindOptText(14, row.optText(9));
    _ = try ins.step();
}

/// 0010 step: consolidate knowledge_records into documents without losing a
/// row, then drop the old table. Guards abort before any mutation.
fn migrateKnowledge(s: *Store) errors.Ztd!void {
    // knowledge rows may point at each other through supersedes_id, and the
    // SELECT below has no order, so the FK has to be checked at commit.
    try s.db.exec("PRAGMA defer_foreign_keys = ON");
    {
        var guard = try s.db.prepare(
            "SELECT k.id FROM knowledge_records k WHERE EXISTS (SELECT 1 FROM documents d WHERE d.id = k.id) " ++
                "OR EXISTS (SELECT 1 FROM documents d WHERE d.scope_id = k.scope_id AND d.kind = 'knowledge' " ++
                "AND d.slug = 'kr/' || k.id) LIMIT 11",
        );
        defer guard.finalize();
        var buf: [512]u8 = undefined;
        var used: usize = 0;
        var n: usize = 0;
        while (try guard.step()) {
            if (n == 10) {
                const more = std.fmt.bufPrint(buf[used..], ", ...", .{}) catch "";
                used += more.len;
                break;
            }
            const piece = std.fmt.bufPrint(buf[used..], "{s}{s}", .{
                if (n > 0) ", " else "",
                guard.text(0),
            }) catch break;
            used += piece.len;
            n += 1;
        }
        if (n > 0) {
            return errors.fail(.db_incompatible, "knowledge migration conflicts with existing documents: {s}", .{buf[0..used]});
        }
    }

    var total: i64 = 0;
    {
        var count = try s.db.prepare("SELECT count(*) FROM knowledge_records");
        defer count.finalize();
        if (try count.step()) total = count.int(0);
    }
    var migrated: i64 = 0;
    {
        var rows = try s.db.prepare(
            "SELECT id, scope_id, kind, text, state, review_state, source_refs, valid_from, " ++
                "reviewed_at, supersedes_id, revision, created_at FROM knowledge_records",
        );
        defer rows.finalize();
        while (try rows.step()) {
            try insertKnowledgeDocument(s, &rows);
            migrated += 1;
        }
    }
    if (migrated != total) {
        return errors.fail(.db_incompatible, "knowledge migration copied {d} of {d} rows", .{ migrated, total });
    }
    {
        var nulls = try s.db.prepare(
            "SELECT count(*) FROM documents d JOIN knowledge_records k ON k.id = d.id " ++
                "WHERE d.title IS NULL OR d.body IS NULL OR d.updated_at IS NULL",
        );
        defer nulls.finalize();
        if (try nulls.step() and nulls.int(0) != 0) {
            return errors.fail(.db_incompatible, "knowledge migration produced incomplete documents", .{});
        }
    }
    {
        var fts = try s.db.prepare(
            "SELECT count(*) FROM documents_fts WHERE doc_id IN (SELECT id FROM knowledge_records)",
        );
        defer fts.finalize();
        if (try fts.step() and fts.int(0) != migrated) {
            return errors.fail(.db_incompatible, "knowledge migration left the search index inconsistent", .{});
        }
    }
    try s.db.exec("DROP TABLE knowledge_records");
}
