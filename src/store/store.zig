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
        const version = stmt.int(0);
        if (version < 0) return errors.fail(.db_incompatible, "database schema version {d} is negative", .{version});
        return version;
    }

    fn bootstrap(self: *Store) errors.Ztd!void {
        const version = try self.userVersion();
        const highest: i64 = migrations.len;
        if (version < 0) {
            return errors.fail(.db_incompatible, "database schema version {d} is negative", .{version});
        }
        if (version > highest) {
            return errors.fail(.db_incompatible, "database schema version {d} is newer than the highest supported version {d}", .{ version, highest });
        }
        if (version == highest) return;
        while (true) {
            try self.db.begin();
            errdefer self.db.rollback();
            const current = try self.userVersion();
            if (current < 0) {
                return errors.fail(.db_incompatible, "database schema version {d} is negative", .{current});
            }
            if (current > highest) {
                return errors.fail(.db_incompatible, "database schema version {d} is newer than the highest supported version {d}", .{ current, highest });
            }
            if (current == highest) {
                try self.db.commit();
                return;
            }
            if (current == 0) {
                var stmt = try self.db.prepare(
                    "SELECT count(*) FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'",
                );
                defer stmt.finalize();
                if (!try stmt.step()) return errors.fail(.db_incompatible, "cannot inspect schema", .{});
                if (stmt.int(0) > 0) {
                    return errors.fail(.db_incompatible, "existing SQLite file has tables but no ZTD schema version; refusing to initialize it", .{});
                }
            }
            const i: usize = @intCast(current);
            const n = i + 1;
            self.db.exec(migrations[i].sql) catch |e| {
                // Copy the detail: fail() formats over the buffer it came from.
                var tmp: [4096]u8 = undefined;
                const detail = errors.detailCopy(&tmp);
                return errors.fail(.db_incompatible, "migration {d} failed: {s}", .{ n, detail }) catch e;
            };
            if (migrations[i].step) |step| {
                try step(self);
            }
            try assertForeignKeys(self, n);
            var sql_buf: [48]u8 = undefined;
            const sql = std.fmt.bufPrint(&sql_buf, "PRAGMA user_version = {d}", .{n}) catch unreachable;
            self.db.exec(sql) catch |e| {
                return errors.fail(.db_incompatible, "migration {d} failed to record its version", .{n}) catch e;
            };
            try self.db.commit();
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

const BusyMigration = struct {
    writer: *sqlite.Db,
    unversioned: bool = false,
    called: bool = false,
    failed: bool = false,

    fn complete(raw: ?*anyopaque, _: c_int) callconv(.c) c_int {
        const ctx: *BusyMigration = @ptrCast(@alignCast(raw.?));
        ctx.called = true;
        if (ctx.unversioned) {
            ctx.writer.exec("CREATE TABLE unrelated (id INTEGER)") catch {
                ctx.failed = true;
                return 0;
            };
            ctx.writer.commit() catch {
                ctx.failed = true;
                return 0;
            };
            return 1;
        }
        ctx.writer.exec(migrations[0].sql) catch {
            ctx.failed = true;
            return 0;
        };
        ctx.writer.exec("PRAGMA user_version = 1") catch {
            ctx.failed = true;
            return 0;
        };
        ctx.writer.commit() catch {
            ctx.failed = true;
            return 0;
        };
        return 1;
    }
};

test "bootstrap rechecks stale version after waiting for another writer" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(io, "race.db", .{});
    file.close(io);
    const path = try tmp.dir.realPathFileAlloc(io, "race.db", a);
    defer a.free(path);
    const zpath = try a.dupeSentinel(u8, path, 0);
    defer a.free(zpath);
    var writer = try sqlite.Db.open(zpath);
    defer writer.close();
    var s = Store{ .db = try sqlite.Db.open(zpath) };
    defer s.close();
    try writer.begin();
    var ctx = BusyMigration{ .writer = &writer };
    try std.testing.expectEqual(@as(c_int, sqlite.c.SQLITE_OK), sqlite.c.sqlite3_busy_handler(s.db.handle, BusyMigration.complete, &ctx));
    try s.bootstrap();
    try std.testing.expect(ctx.called and !ctx.failed);
    try std.testing.expectEqual(@as(i64, migrations.len), try s.userVersion());
    try assertForeignKeys(&s, migrations.len);
}

test "bootstrap checks unversioned schema after waiting for another writer" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(io, "unversioned.db", .{});
    file.close(io);
    const path = try tmp.dir.realPathFileAlloc(io, "unversioned.db", a);
    defer a.free(path);
    const zpath = try a.dupeSentinel(u8, path, 0);
    defer a.free(zpath);
    var writer = try sqlite.Db.open(zpath);
    defer writer.close();
    var s = Store{ .db = try sqlite.Db.open(zpath) };
    defer s.close();
    try writer.begin();
    var ctx = BusyMigration{ .writer = &writer, .unversioned = true };
    try std.testing.expectEqual(@as(c_int, sqlite.c.SQLITE_OK), sqlite.c.sqlite3_busy_handler(s.db.handle, BusyMigration.complete, &ctx));
    try std.testing.expectError(error.Ztd, s.bootstrap());
    try std.testing.expect(ctx.called and !ctx.failed);
    try std.testing.expectEqual(errors.Family.db_incompatible, errors.getFamily());
    try std.testing.expectEqual(@as(i64, 0), try s.userVersion());
    var stmt = try s.db.prepare("SELECT count(*) FROM sqlite_master WHERE type='table' AND name='unrelated'");
    defer stmt.finalize();
    try std.testing.expect(try stmt.step());
    try std.testing.expectEqual(@as(i64, 1), stmt.int(0));
}

test "bootstrap rejects a negative version before and after acquiring the lock" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(io, "negative.db", .{});
    file.close(io);
    const path = try tmp.dir.realPathFileAlloc(io, "negative.db", a);
    defer a.free(path);
    const zpath = try a.dupeSentinel(u8, path, 0);
    defer a.free(zpath);
    var writer = try sqlite.Db.open(zpath);
    defer writer.close();
    var s = Store{ .db = try sqlite.Db.open(zpath) };
    defer s.close();
    const Callback = struct {
        writer: *sqlite.Db,
        called: bool = false,
        failed: bool = false,
        fn complete(raw: ?*anyopaque, _: c_int) callconv(.c) c_int {
            const ctx: *@This() = @ptrCast(@alignCast(raw.?));
            ctx.called = true;
            ctx.writer.exec("PRAGMA user_version = -1") catch {
                ctx.failed = true;
                return 0;
            };
            ctx.writer.commit() catch {
                ctx.failed = true;
                return 0;
            };
            return 1;
        }
    };
    try writer.begin();
    var ctx = Callback{ .writer = &writer };
    try std.testing.expectEqual(@as(c_int, sqlite.c.SQLITE_OK), sqlite.c.sqlite3_busy_handler(s.db.handle, Callback.complete, &ctx));
    try std.testing.expectError(error.Ztd, s.bootstrap());
    try std.testing.expect(ctx.called and !ctx.failed);
    try std.testing.expectEqual(errors.Family.db_incompatible, errors.getFamily());
    try std.testing.expectEqualStrings("database schema version -1 is negative", errors.detail());
    try s.db.begin();
    s.db.rollback();
    try std.testing.expectError(error.Ztd, s.bootstrap());
    try std.testing.expectEqual(errors.Family.db_incompatible, errors.getFamily());
    try std.testing.expectEqualStrings("database schema version -1 is negative", errors.detail());
    var stmt = try s.db.prepare("PRAGMA user_version");
    defer stmt.finalize();
    try std.testing.expect(try stmt.step());
    try std.testing.expectEqual(@as(i64, -1), stmt.int(0));
}

test "foreign key failure rolls back the whole migration" {
    var s = Store{ .db = try sqlite.Db.open(":memory:") };
    defer s.close();
    try s.db.exec(migrations[0].sql);
    try s.db.exec(
        "PRAGMA user_version = 1; PRAGMA foreign_keys = OFF;" ++
            "INSERT INTO contexts (id, scope_id, name, revision) VALUES ('orphan','missing','test',1);" ++
            "PRAGMA foreign_keys = ON;",
    );
    try std.testing.expectError(error.Ztd, s.bootstrap());
    try std.testing.expectEqual(errors.Family.db_incompatible, errors.getFamily());
    try std.testing.expectEqual(@as(i64, 1), try s.userVersion());
    var stmt = try s.db.prepare("SELECT count(*) FROM sqlite_master WHERE type='table' AND name='focus_sessions'");
    defer stmt.finalize();
    try std.testing.expect(try stmt.step());
    try std.testing.expectEqual(@as(i64, 0), stmt.int(0));
    try s.db.begin();
    s.db.rollback();
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
        const cut = errors.utf8Prefix(chosen, 80);
        @memcpy(buf[0..cut.len], cut);
        return buf[0..cut.len];
    }
    const cut = errors.utf8Prefix(id, 80);
    @memcpy(buf[0..cut.len], cut);
    return buf[0..cut.len];
}

pub const LegacyKnowledgeRow = struct {
    id: []const u8,
    scope_id: []const u8,
    kind: []const u8,
    text: []const u8,
    state: []const u8,
    review_state: []const u8,
    source_refs: []const u8,
    valid_from: ?[]const u8,
    reviewed_at: ?[]const u8,
    supersedes_id: ?[]const u8,
    revision: i64,
    created_at: []const u8,
};

pub fn insertKnowledgeDocument(s: *Store, row: LegacyKnowledgeRow) errors.Ztd!void {
    const id = row.id;
    var slug_buf: [128]u8 = undefined;
    const slug = std.fmt.bufPrint(&slug_buf, "kr/{s}", .{id}) catch
        return errors.fail(.db_incompatible, "knowledge id is too long to migrate: {s}", .{id});
    var title_buf: [80]u8 = undefined;
    const title = firstLineTitle(id, row.text, &title_buf);
    const status = if (std.mem.eql(u8, row.state, "superseded"))
        "superseded"
    else if (std.mem.eql(u8, row.review_state, "verified"))
        "verified"
    else
        "draft";
    const reviewed = row.reviewed_at;
    const updated_at = reviewed orelse row.created_at;

    var ins = try s.db.prepare(
        "INSERT INTO documents (id, scope_id, kind, slug, title, body, status, revision, " ++
            "created_at, updated_at, record_kind, approved_at, valid_from, source_refs, supersedes_id) " ++
            "VALUES (?, ?, 'knowledge', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
    );
    defer ins.finalize();
    try ins.bindText(1, id);
    try ins.bindText(2, row.scope_id);
    try ins.bindText(3, slug);
    try ins.bindText(4, title);
    try ins.bindText(5, row.text);
    try ins.bindText(6, status);
    try ins.bindInt(7, row.revision);
    try ins.bindText(8, row.created_at);
    try ins.bindText(9, updated_at);
    try ins.bindText(10, row.kind);
    try ins.bindOptText(11, reviewed);
    try ins.bindOptText(12, row.valid_from);
    try ins.bindText(13, row.source_refs);
    try ins.bindOptText(14, row.supersedes_id);
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
            try insertKnowledgeDocument(s, .{
                .id = rows.text(0),
                .scope_id = rows.text(1),
                .kind = rows.text(2),
                .text = rows.text(3),
                .state = rows.text(4),
                .review_state = rows.text(5),
                .source_refs = rows.text(6),
                .valid_from = rows.optText(7),
                .reviewed_at = rows.optText(8),
                .supersedes_id = rows.optText(9),
                .revision = rows.int(10),
                .created_at = rows.text(11),
            });
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

test "an existing v7 database upgrades in place with its rows" {
    // The upgrade path (0009 rebuilds `sources`, 0010 copies knowledge) is the
    // only code that can destroy user data, so it runs here on real rows.
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    {
        var f = try tmp.dir.createFile(io, "ztd.db", .{});
        f.close(io);
    }
    const path = try tmp.dir.realPathFileAlloc(io, "ztd.db", a);
    defer a.free(path);

    {
        const zpath = try a.dupeSentinel(u8, path, 0);
        defer a.free(zpath);
        var db = try sqlite.Db.open(zpath);
        defer db.close();
        for (migrations[0..7]) |m| try db.exec(m.sql);
        try db.exec(
            \\INSERT INTO scopes (id, name, kind, created_at) VALUES ('personal','Personal','personal','2026-01-01T00:00:00Z');
            \\INSERT INTO profiles (id, name, kind, owner_actor_id, timezone, status) VALUES ('personal','Personal','personal','me','UTC','active');
            \\INSERT INTO sources (id,name,scope_id,kind,connector,provider,connection_ref,non_secret_query,cadence,auth_state,coverage_state,cursor,created_at,updated_at)
            \\  VALUES ('feed','Feed','personal','capture','manual','','','','','unknown','unknown','','2026-01-01T00:00:00Z','2026-01-01T00:00:00Z');
            \\INSERT INTO source_reviews (id,source_id,batch_id,idempotency_key,request_hash,result_kind,coverage_state,retrieval_json,created_at)
            \\  VALUES ('SR-20260101-001','feed','b1','k1','h','reported','unverified','{}','2026-01-01T00:00:00Z');
            \\INSERT INTO captures (id,scope_id,source_id,external_id,external_revision,original_text,content_hash,captured_at,processing_state,revision)
            \\  VALUES ('C-20260101-001','personal','feed','e1','1','old capture','hash','2026-01-01T00:00:00Z','pending',1);
            \\INSERT INTO knowledge_records (id,scope_id,kind,text,state,review_state,revision,created_at)
            \\  VALUES ('K1','personal','fact','Revisar café','current','draft',1,'2026-01-01T00:00:00Z');
            \\INSERT INTO knowledge_records (id,scope_id,kind,text,state,review_state,supersedes_id,revision,created_at)
            \\  VALUES ('K2','personal','fact','Revisar café otra vez','current','draft','K1',1,'2026-01-02T00:00:00Z');
            \\PRAGMA user_version = 7;
        );
    }

    var s = try Store.open(path);
    defer s.close();
    try std.testing.expectEqual(@as(i64, 12), try s.userVersion());
    try assertForeignKeys(&s, 12);

    var q = try s.db.prepare("SELECT count(*) FROM captures WHERE id = 'C-20260101-001'");
    try std.testing.expect(try q.step());
    try std.testing.expectEqual(@as(i64, 1), q.int(0));
    q.finalize();

    q = try s.db.prepare("SELECT title, supersedes_id FROM documents WHERE id = 'K2'");
    try std.testing.expect(try q.step());
    try std.testing.expectEqualStrings("Revisar café otra vez", q.text(0));
    try std.testing.expectEqualStrings("K1", q.text(1));
    q.finalize();

    q = try s.db.prepare("SELECT reported_cursor FROM sources WHERE id = 'feed'");
    try std.testing.expect(try q.step());
    try std.testing.expectEqualStrings("", q.text(0));
    q.finalize();

    // 0009 rebuilds `sources`; the review that hangs off it must survive, or a
    // DROP with a cascade would silently erase every batch of every source.
    q = try s.db.prepare("SELECT count(*) FROM source_reviews WHERE source_id = 'feed'");
    try std.testing.expect(try q.step());
    try std.testing.expectEqual(@as(i64, 1), q.int(0));
    q.finalize();

    // 0010 copies both knowledge rows; losing the superseded one would leave
    // K2 pointing at a document that no longer exists.
    q = try s.db.prepare("SELECT title FROM documents WHERE id = 'K1'");
    try std.testing.expect(try q.step());
    try std.testing.expectEqualStrings("Revisar café", q.text(0));
    q.finalize();
}
