//! Thin SQLite wrapper for the agent-continuity store.
//!
//! The amalgamation is compiled with `-D` flags that translate-c does not
//! inherit, so the few entry points we use are hand-declared here instead of
//! `@cImport`ing vendor/sqlite/sqlite3.h (see vendor/sqlite/PIN.md).
//!
//! One connection, used only on the calling thread: the library is built with
//! SQLITE_THREADSAFE=0, so never share a `Db` across threads.

const std = @import("std");
const builtin = @import("builtin");

/// Schema version stored in `PRAGMA user_version`. Bump only with a migration;
/// opening a newer or mismatched database fails with `error.DbIncompatible`.
/// Version 2 adds the knowledge tables (see `gate` for the 1 -> 2 upgrade).
pub const schema_version = 2;

pub const sqlite3 = opaque {};
pub const sqlite3_stmt = opaque {};

pub extern fn sqlite3_open_v2(path: [*:0]const u8, db: *?*sqlite3, flags: c_int, vfs: ?[*:0]const u8) c_int;
pub extern fn sqlite3_close(db: *sqlite3) c_int;
pub extern fn sqlite3_busy_timeout(db: *sqlite3, ms: c_int) c_int;
// The callback is always NULL; declared as an opaque pointer on purpose.
pub extern fn sqlite3_exec(db: *sqlite3, sql: [*:0]const u8, callback: ?*anyopaque, arg: ?*anyopaque, errmsg: ?*?[*:0]u8) c_int;
pub extern fn sqlite3_prepare_v2(db: *sqlite3, sql: [*]const u8, n_byte: c_int, stmt: *?*sqlite3_stmt, tail: ?*?[*:0]const u8) c_int;
pub extern fn sqlite3_step(stmt: *sqlite3_stmt) c_int;
pub extern fn sqlite3_finalize(stmt: *sqlite3_stmt) c_int;
pub extern fn sqlite3_bind_text(stmt: *sqlite3_stmt, idx: c_int, text: ?[*]const u8, n: c_int, destructor: usize) c_int;
pub extern fn sqlite3_bind_blob(stmt: *sqlite3_stmt, idx: c_int, data: ?*const anyopaque, n: c_int, destructor: usize) c_int;
pub extern fn sqlite3_bind_int64(stmt: *sqlite3_stmt, idx: c_int, value: i64) c_int;
pub extern fn sqlite3_bind_null(stmt: *sqlite3_stmt, idx: c_int) c_int;
pub extern fn sqlite3_column_text(stmt: *sqlite3_stmt, col: c_int) ?[*:0]const u8;
pub extern fn sqlite3_column_blob(stmt: *sqlite3_stmt, col: c_int) ?*const anyopaque;
pub extern fn sqlite3_column_bytes(stmt: *sqlite3_stmt, col: c_int) c_int;
pub extern fn sqlite3_column_int64(stmt: *sqlite3_stmt, col: c_int) i64;
pub extern fn sqlite3_column_type(stmt: *sqlite3_stmt, col: c_int) c_int;
pub extern fn sqlite3_libversion_number() c_int;
pub extern fn sqlite3_threadsafe() c_int;
pub extern fn sqlite3_errcode(db: *sqlite3) c_int;

const SQLITE_OK = 0;
const SQLITE_ERROR = 1;
const SQLITE_PERM = 3;
const SQLITE_BUSY = 5;
const SQLITE_LOCKED = 6;
const SQLITE_NOMEM = 7;
const SQLITE_READONLY = 8;
const SQLITE_CORRUPT = 11;
const SQLITE_FULL = 13;
const SQLITE_CANTOPEN = 14;
const SQLITE_MISUSE = 21;
const SQLITE_NOTADB = 26;
const SQLITE_ROW = 100;
const SQLITE_DONE = 101;

const SQLITE_OPEN_READWRITE: c_int = 0x00000002;
const SQLITE_OPEN_CREATE: c_int = 0x00000004;

const busy_timeout_ms = 5000;

/// `SQLITE_TRANSIENT`: sqlite3_bind_* copies the value right away.
const SQLITE_TRANSIENT: usize = @bitCast(@as(isize, -1));

pub const Error = error{
    DbBusy,
    DbIncompatible,
    InvalidArgument,
    OutOfMemory,
    FileNotFound,
    AccessDenied,
    InputOutput,
    NoSpaceLeft,
};

/// A busy or locked database after the busy timeout is retryable, never a
/// generic IO error (spec: storage contract).
fn mapRc(rc: c_int) Error {
    return switch (rc & 0xff) {
        SQLITE_BUSY, SQLITE_LOCKED => error.DbBusy,
        SQLITE_PERM, SQLITE_READONLY => error.AccessDenied,
        SQLITE_NOMEM => error.OutOfMemory,
        SQLITE_FULL => error.NoSpaceLeft,
        SQLITE_CANTOPEN => error.FileNotFound,
        SQLITE_CORRUPT, SQLITE_NOTADB => error.DbIncompatible,
        SQLITE_MISUSE => error.InvalidArgument,
        else => error.InputOutput,
    };
}

pub fn threadsafe() c_int {
    return sqlite3_threadsafe();
}

pub fn libversionNumber() c_int {
    return sqlite3_libversion_number();
}

/// Resolves the database path: explicit value > `ZTD_AGENT_DB` > per-OS
/// default. The defaults live in the user data directory, never under a
/// workspace `ztd/` directory. Always returns an absolute path.
pub fn resolvePath(io: std.Io, alloc: std.mem.Allocator, explicit: ?[]const u8) ![]u8 {
    if (explicit) |p| {
        if (p.len > 0) return absolute(io, alloc, p);
    }
    if (try envAlloc(alloc, "ZTD_AGENT_DB")) |env_path| {
        defer alloc.free(env_path);
        if (env_path.len > 0) return absolute(io, alloc, env_path);
    }
    return defaultPath(alloc);
}

fn absolute(io: std.Io, alloc: std.mem.Allocator, path: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(path)) return alloc.dupe(u8, path);
    const cwd = try std.process.currentPathAlloc(io, alloc);
    defer alloc.free(cwd);
    return std.fs.path.resolveAlloc(alloc, &.{ cwd, path });
}

fn defaultPath(alloc: std.mem.Allocator) ![]u8 {
    switch (builtin.os.tag) {
        .windows => {
            const base = (try envAlloc(alloc, "LOCALAPPDATA")) orelse return error.FileNotFound;
            defer alloc.free(base);
            return std.fs.path.join(alloc, &.{ base, "ztd", "agent.db" });
        },
        .macos => {
            const home = (try envAlloc(alloc, "HOME")) orelse return error.FileNotFound;
            defer alloc.free(home);
            return std.fs.path.join(alloc, &.{ home, "Library", "Application Support", "ztd", "agent.db" });
        },
        else => {
            if (try envAlloc(alloc, "XDG_DATA_HOME")) |xdg| {
                defer alloc.free(xdg);
                if (xdg.len > 0) return std.fs.path.join(alloc, &.{ xdg, "ztd", "agent.db" });
            }
            const home = (try envAlloc(alloc, "HOME")) orelse return error.FileNotFound;
            defer alloc.free(home);
            return std.fs.path.join(alloc, &.{ home, ".local", "share", "ztd", "agent.db" });
        },
    }
}

/// Caller owns the returned value. On Windows the value is read from the PEB
/// (UTF-16); everywhere else `getenv` (the build links libc on every target).
fn envAlloc(alloc: std.mem.Allocator, comptime name: [:0]const u8) !?[]u8 {
    if (builtin.os.tag == .windows) {
        const environ: std.process.Environ = .{ .block = .global };
        const value = std.process.Environ.getWindows(environ, std.unicode.utf8ToUtf16LeStringLiteral(name)) orelse return null;
        const owned = try std.unicode.utf16LeToUtf8Alloc(alloc, value);
        return @as(?[]u8, owned);
    }
    const value = std.c.getenv(name) orelse return null;
    const owned = try alloc.dupe(u8, std.mem.span(value));
    return @as(?[]u8, owned);
}

const schema_v1_sql =
    \\CREATE TABLE scope (id TEXT PRIMARY KEY) WITHOUT ROWID;
    \\CREATE TABLE assignment (
    \\  id TEXT PRIMARY KEY,
    \\  scope_id TEXT NOT NULL REFERENCES scope(id),
    \\  request TEXT NOT NULL,
    \\  objective TEXT,
    \\  constraints TEXT,
    \\  project TEXT,
    \\  status TEXT NOT NULL,          -- 'open' | 'done' | 'cancelled'
    \\  rev INTEGER NOT NULL,
    \\  created_at TEXT NOT NULL,
    \\  updated_at TEXT NOT NULL
    \\);
    \\CREATE INDEX assignment_scope ON assignment(scope_id);
    \\CREATE TABLE checkpoint (
    \\  id TEXT PRIMARY KEY,
    \\  assignment_id TEXT NOT NULL REFERENCES assignment(id),
    \\  kind TEXT NOT NULL,            -- 'progress' | 'done'
    \\  result TEXT NOT NULL,
    \\  evidence TEXT,
    \\  next_action TEXT,
    \\  rev INTEGER NOT NULL,
    \\  created_at TEXT NOT NULL
    \\);
    \\CREATE INDEX checkpoint_assignment ON checkpoint(assignment_id);
    \\CREATE TABLE op_log (
    \\  key TEXT PRIMARY KEY,
    \\  request_sha256 BLOB NOT NULL,
    \\  result_json TEXT NOT NULL,
    \\  created_at TEXT NOT NULL
    \\) WITHOUT ROWID;
;

// Version 2: `knowledge` plus its standalone (not external-content) FTS5
// index. Every write to `knowledge_fts` happens in the same transaction as the
// `knowledge` row it mirrors, keyed by `knowledge.rowid`, so the index cannot
// drift from the table.
const schema_v2_sql =
    \\CREATE VIRTUAL TABLE knowledge_fts USING fts5(text, source, id UNINDEXED, tokenize='unicode61 remove_diacritics 2');
    \\CREATE TABLE knowledge (
    \\  id TEXT PRIMARY KEY,
    \\  scope_id TEXT NOT NULL REFERENCES scope(id),
    \\  kind TEXT NOT NULL,            -- 'fact' | 'decision' | 'constraint' | 'procedure'
    \\  text TEXT NOT NULL,
    \\  source TEXT,
    \\  rev INTEGER NOT NULL,
    \\  created_at TEXT NOT NULL
    \\);
    \\CREATE INDEX knowledge_scope ON knowledge(scope_id);
;

/// Fresh databases are created at the current version in one shot.
const schema_sql = schema_v1_sql ++ "\n" ++ schema_v2_sql;

/// Tables plus indexes a version-1 database must have.
const expected_objects_v1_sql =
    \\SELECT count(*) FROM sqlite_master
    \\WHERE (type = 'table' AND name IN ('scope', 'assignment', 'checkpoint', 'op_log'))
    \\   OR (type = 'index' AND name IN ('assignment_scope', 'checkpoint_assignment'))
;
const expected_objects_v1 = 6;

/// Tables plus indexes a version-2 database must have. FTS5's own shadow
/// tables (`knowledge_fts_*`) are its implementation detail, not ours to pin.
const expected_objects_sql =
    \\SELECT count(*) FROM sqlite_master
    \\WHERE (type = 'table' AND name IN ('scope', 'assignment', 'checkpoint', 'op_log', 'knowledge', 'knowledge_fts'))
    \\   OR (type = 'index' AND name IN ('assignment_scope', 'checkpoint_assignment', 'knowledge_scope'))
;
const expected_objects = 9;

pub const Db = struct {
    handle: *sqlite3,

    pub fn open(io: std.Io, alloc: std.mem.Allocator, path: []const u8) !Db {
        var db = try connect(io, alloc, path);
        errdefer db.close();
        try db.exec("PRAGMA trusted_schema=OFF");
        try db.gate();
        // Persistent and only set once the database is accepted.
        try db.exec("PRAGMA journal_mode=WAL");
        return db;
    }

    fn connect(io: std.Io, alloc: std.mem.Allocator, path: []const u8) !Db {
        const abs = try resolvePath(io, alloc, path);
        defer alloc.free(abs);
        if (std.fs.path.dirname(abs)) |dir| {
            if (dir.len > 0) {
                std.Io.Dir.cwd().createDirPath(io, dir) catch |err| switch (err) {
                    error.PathAlreadyExists => {},
                    else => return err,
                };
            }
        }
        const zpath = try allocSentinel(alloc, abs);
        defer alloc.free(zpath);

        var handle: ?*sqlite3 = null;
        const rc = sqlite3_open_v2(zpath.ptr, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, null);
        if (rc != SQLITE_OK) {
            if (handle) |h| _ = sqlite3_close(h);
            return mapRc(rc);
        }
        var db = Db{ .handle = handle.? };
        errdefer db.close();
        const btc = sqlite3_busy_timeout(db.handle, busy_timeout_ms);
        if (btc != SQLITE_OK) return mapRc(btc);
        return db;
    }

    pub fn close(self: *Db) void {
        _ = sqlite3_close(self.handle);
    }

    /// Runs a statement with no parameters and no result columns.
    pub fn exec(self: *Db, sql: [*:0]const u8) !void {
        const rc = sqlite3_exec(self.handle, sql, null, null, null);
        if (rc != SQLITE_OK) return mapRc(rc);
    }

    pub fn beginImmediate(self: *Db) !void {
        try self.exec("BEGIN IMMEDIATE");
    }

    pub fn commit(self: *Db) !void {
        try self.exec("COMMIT");
    }

    /// Best-effort: used on error paths where no transaction may be open.
    pub fn rollback(self: *Db) void {
        self.exec("ROLLBACK") catch {};
    }

    pub fn prepare(self: *Db, sql: []const u8) !Stmt {
        if (sql.len == 0) return error.InvalidArgument;
        const n = std.math.cast(c_int, sql.len) orelse return error.InvalidArgument;
        var stmt: ?*sqlite3_stmt = null;
        const rc = sqlite3_prepare_v2(self.handle, sql.ptr, n, &stmt, null);
        if (rc != SQLITE_OK) return mapRc(rc);
        return .{ .stmt = stmt orelse return error.InvalidArgument };
    }

    /// True when the most recent API failure was SQLite's generic
    /// `SQLITE_ERROR` (result-code class 1) — the way FTS5 reports a malformed
    /// MATCH query — rather than an I/O, busy or corruption error, which keep
    /// their own result codes.
    pub fn lastWasGenericError(self: *Db) bool {
        return (sqlite3_errcode(self.handle) & 0xff) == SQLITE_ERROR;
    }

    /// Version gate: create schema 2 on a database with no user objects of its
    /// own, upgrade a version-1 database inside this same transaction, accept
    /// version 2 with every object present, reject anything else. Never
    /// downgrades, adopts or silently recreates another database.
    fn gate(self: *Db) !void {
        // Take the write lock first so two first opens cannot both initialise.
        try self.beginImmediate();
        var committed = false;
        defer if (!committed) self.rollback();

        const version = try self.userVersion();
        if (version == 0) {
            if (try self.userObjectCount() != 0) return error.DbIncompatible;
            try self.exec(schema_sql);
        } else if (version == 1) {
            // A v1 store is upgraded in place: only the knowledge objects are
            // created here, then user_version moves to 2.
            if (try self.objectCount(expected_objects_v1_sql) != expected_objects_v1) return error.DbIncompatible;
            try self.exec(schema_v2_sql);
        } else if (version != schema_version) return error.DbIncompatible;
        if (try self.objectCount(expected_objects_sql) != expected_objects) return error.DbIncompatible;
        if (version != schema_version) try self.exec("PRAGMA user_version = 2");
        try self.commit();
        committed = true;
    }

    /// Any table, index, view or trigger the user created; SQLite internals excluded.
    fn userObjectCount(self: *Db) !i64 {
        var stmt = try self.prepare(
            \\SELECT count(*) FROM sqlite_master
            \\WHERE name NOT LIKE 'sqlite_%' AND type IN ('table', 'index', 'view', 'trigger')
        );
        defer stmt.deinit();
        if (!try stmt.step()) return 0;
        return stmt.columnInt64(0);
    }

    fn userVersion(self: *Db) !i64 {
        var stmt = try self.prepare("PRAGMA user_version");
        defer stmt.deinit();
        if (!try stmt.step()) return 0;
        return stmt.columnInt64(0);
    }

    fn objectCount(self: *Db, sql: []const u8) !i64 {
        var stmt = try self.prepare(sql);
        defer stmt.deinit();
        if (!try stmt.step()) return 0;
        return stmt.columnInt64(0);
    }
};

pub const Stmt = struct {
    stmt: *sqlite3_stmt,

    pub fn deinit(self: *Stmt) void {
        _ = sqlite3_finalize(self.stmt);
    }

    /// True when a row is ready, false when the statement is done.
    pub fn step(self: *Stmt) !bool {
        const rc = sqlite3_step(self.stmt);
        return switch (rc) {
            SQLITE_ROW => true,
            SQLITE_DONE => false,
            else => mapRc(rc),
        };
    }

    pub fn bindText(self: *Stmt, idx: c_int, value: []const u8) !void {
        const n = std.math.cast(c_int, value.len) orelse return error.InvalidArgument;
        const rc = sqlite3_bind_text(self.stmt, idx, value.ptr, n, SQLITE_TRANSIENT);
        if (rc != SQLITE_OK) return mapRc(rc);
    }

    pub fn bindTextOpt(self: *Stmt, idx: c_int, value: ?[]const u8) !void {
        if (value) |v| return self.bindText(idx, v);
        const rc = sqlite3_bind_null(self.stmt, idx);
        if (rc != SQLITE_OK) return mapRc(rc);
    }

    pub fn bindInt64(self: *Stmt, idx: c_int, value: i64) !void {
        const rc = sqlite3_bind_int64(self.stmt, idx, value);
        if (rc != SQLITE_OK) return mapRc(rc);
    }

    pub fn bindBlob(self: *Stmt, idx: c_int, value: []const u8) !void {
        const n = std.math.cast(c_int, value.len) orelse return error.InvalidArgument;
        const rc = sqlite3_bind_blob(self.stmt, idx, value.ptr, n, SQLITE_TRANSIENT);
        if (rc != SQLITE_OK) return mapRc(rc);
    }

    pub fn columnIsNull(self: *Stmt, col: c_int) bool {
        return sqlite3_column_type(self.stmt, col) == 5; // SQLITE_NULL
    }

    pub fn columnInt64(self: *Stmt, col: c_int) i64 {
        return sqlite3_column_int64(self.stmt, col);
    }

    /// Owned by the caller; null for SQL NULL.
    pub fn columnText(self: *Stmt, alloc: std.mem.Allocator, col: c_int) !?[]u8 {
        if (self.columnIsNull(col)) return null;
        const n: usize = @intCast(sqlite3_column_bytes(self.stmt, col));
        const p = sqlite3_column_text(self.stmt, col) orelse return null;
        return @as(?[]u8, try alloc.dupe(u8, p[0..n]));
    }

    /// Owned by the caller; null for SQL NULL.
    pub fn columnBlob(self: *Stmt, alloc: std.mem.Allocator, col: c_int) !?[]u8 {
        if (self.columnIsNull(col)) return null;
        const n: usize = @intCast(sqlite3_column_bytes(self.stmt, col));
        const p = sqlite3_column_blob(self.stmt, col) orelse return null;
        return @as(?[]u8, try alloc.dupe(u8, @as([*]const u8, @ptrCast(p))[0..n]));
    }
};

fn allocSentinel(alloc: std.mem.Allocator, bytes: []const u8) ![:0]u8 {
    const out = try alloc.allocSentinel(u8, bytes.len, 0);
    @memcpy(out, bytes);
    return out;
}

test "sqlite is compiled single-threaded at 3.54.1" {
    try std.testing.expectEqual(@as(c_int, 0), threadsafe());
    try std.testing.expectEqual(@as(c_int, 3054001), libversionNumber());
}

test "future user_version is rejected" {
    const alloc = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &path_buf);
    const path = try std.fs.path.join(alloc, &.{ path_buf[0..n], "future.db" });
    defer alloc.free(path);

    var created = try Db.open(io, alloc, path);
    created.close();

    var raw = try Db.connect(io, alloc, path);
    try raw.exec("PRAGMA user_version = 3");
    raw.close();

    try std.testing.expectError(error.DbIncompatible, Db.open(io, alloc, path));
}

test "a version-1 database upgrades to version 2 keeping its rows" {
    const alloc = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &path_buf);
    const path = try std.fs.path.join(alloc, &.{ path_buf[0..n], "v1.db" });
    defer alloc.free(path);

    // Built by hand: the binary only creates version 2 now.
    var raw = try Db.connect(io, alloc, path);
    try raw.exec(schema_v1_sql);
    try raw.exec(
        \\INSERT INTO scope (id) VALUES ('demo');
        \\INSERT INTO assignment (id, scope_id, request, status, rev, created_at, updated_at)
        \\VALUES ('A-20260101-001', 'demo', 'tarea antigua', 'open', 1, '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z');
        \\PRAGMA user_version = 1;
    );
    raw.close();

    var upgraded = try Db.open(io, alloc, path);
    defer upgraded.close();
    try std.testing.expectEqual(@as(i64, schema_version), try upgraded.userVersion());

    var kept = try upgraded.prepare("SELECT request, rev FROM assignment WHERE id = 'A-20260101-001'");
    defer kept.deinit();
    try std.testing.expect(try kept.step());
    const request = (try kept.columnText(alloc, 0)).?;
    defer alloc.free(request);
    try std.testing.expectEqualStrings("tarea antigua", request);
    try std.testing.expectEqual(@as(i64, 1), kept.columnInt64(1));

    var objects = try upgraded.prepare(
        "SELECT count(*) FROM sqlite_master WHERE name IN ('knowledge', 'knowledge_fts', 'knowledge_scope')",
    );
    defer objects.deinit();
    try std.testing.expect(try objects.step());
    try std.testing.expectEqual(@as(i64, 3), objects.columnInt64(0));
}

test "an unrelated database is not adopted" {
    const alloc = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &path_buf);
    const path = try std.fs.path.join(alloc, &.{ path_buf[0..n], "other.db" });
    defer alloc.free(path);

    var raw = try Db.connect(io, alloc, path);
    try raw.exec("CREATE TABLE other (x TEXT)");
    raw.close();

    try std.testing.expectError(error.DbIncompatible, Db.open(io, alloc, path));
}
