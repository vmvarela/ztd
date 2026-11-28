//! Thin SQLite C API wrapper: open with the same durability pragmas as the Go
//! store, prepare/bind/step/column, and transactions.

const std = @import("std");
const builtin = @import("builtin");
pub const c = @import("c");
const errors = @import("errors.zig");

pub const sqliteMagic = "SQLite format 3\x00";

pub const Db = struct {
    handle: *c.sqlite3,

    /// Opens path (creating it), rejects non-SQLite nonempty files, and
    /// asserts the v2 pragmas. The Go driver runs these per connection; a
    /// single-process CLI has one.
    pub fn open(path: [:0]const u8) errors.Ztd!Db {
        if (std.mem.eql(u8, path, ":memory:")) {
            return openRaw(path);
        }
        try checkHeader(path);
        return openRaw(path);
    }

    fn openRaw(path: [:0]const u8) errors.Ztd!Db {
        var handle: ?*c.sqlite3 = null;
        if (c.sqlite3_open(path, &handle) != c.SQLITE_OK) {
            if (handle) |h| {
                defer _ = c.sqlite3_close(h);
                const msg = std.mem.span(c.sqlite3_errmsg(h));
                return errors.fromSqlite(msg, true);
            }
            return errors.fail(.db_incompatible, "cannot open SQLite database", .{});
        }
        var db = Db{ .handle = handle.? };
        errdefer db.close();
        try db.exec("PRAGMA busy_timeout = 5000");
        try db.exec("PRAGMA foreign_keys = ON");
        try db.exec("PRAGMA journal_mode = WAL");
        try db.exec("PRAGMA synchronous = FULL");
        return db;
    }

    pub fn close(self: *Db) void {
        _ = c.sqlite3_close(self.handle);
    }

    /// Runs one or more statements. The tail pointer from prepare_v2 is the
    /// only reliable splitter for trigger bodies, so no string scanning here.
    pub fn exec(self: Db, sql: []const u8) errors.Ztd!void {
        var tail = sql.ptr;
        var remaining = sql.len;
        while (remaining > 0) {
            var stmt: ?*c.sqlite3_stmt = null;
            var next: [*c]const u8 = null;
            if (c.sqlite3_prepare_v2(self.handle, tail, @intCast(remaining), &stmt, &next) != c.SQLITE_OK) {
                return errors.fail(.io_error, "{s}", .{self.errmsg()});
            }
            if (stmt) |st| {
                const rc = c.sqlite3_step(st);
                _ = c.sqlite3_finalize(st);
                if (rc != c.SQLITE_DONE and rc != c.SQLITE_ROW) {
                    return errors.fail(.io_error, "{s}", .{self.errmsg()});
                }
            }
            const consumed = @intFromPtr(next) - @intFromPtr(tail);
            if (consumed == 0) break;
            tail = next;
            remaining -= consumed;
        }
    }

    /// Runs SQL and classifies failures as io_error, except contention.
    pub fn execClassified(self: Db, sql: []const u8) errors.Ztd!void {
        self.exec(sql) catch |e| {
            const msg = self.errmsg();
            if (std.mem.indexOf(u8, msg, "busy") != null or std.mem.indexOf(u8, msg, "locked") != null) {
                return errors.fail(.db_busy, "{s}", .{msg});
            }
            return e;
        };
    }

    pub fn prepare(self: Db, sql: []const u8) errors.Ztd!Statement {
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.handle, sql.ptr, @intCast(sql.len), &stmt, null) != c.SQLITE_OK) {
            return errors.fail(.io_error, "{s}", .{self.errmsg()});
        }
        return .{ .stmt = stmt.? };
    }

    /// BEGIN IMMEDIATE matches the Go pool's _txlock=immediate.
    pub fn begin(self: Db) errors.Ztd!void {
        try self.execClassified("BEGIN IMMEDIATE");
    }

    pub fn commit(self: Db) errors.Ztd!void {
        try self.execClassified("COMMIT");
    }

    /// Never reports: a rollback happens while an error is already being
    /// propagated, and it must not overwrite that error's family and detail.
    pub fn rollback(self: Db) void {
        _ = c.sqlite3_exec(self.handle, "ROLLBACK", null, null, null);
    }

    /// Number of rows changed by the most recent INSERT/UPDATE/DELETE, used to
    /// detect a concurrent writer that invalidated a revision guard.
    pub fn changes(self: Db) i64 {
        return c.sqlite3_changes(self.handle);
    }

    pub fn errmsg(self: Db) []const u8 {
        return std.mem.span(c.sqlite3_errmsg(self.handle));
    }
};

pub const Statement = struct {
    stmt: *c.sqlite3_stmt,

    pub fn finalize(self: Statement) void {
        _ = c.sqlite3_finalize(self.stmt);
    }

    pub fn reset(self: Statement) void {
        _ = c.sqlite3_reset(self.stmt);
    }

    pub fn bindText(self: Statement, idx: c_int, value: []const u8) errors.Ztd!void {
        // SQLITE_STATIC: callers keep the bytes alive until the statement is
        // finalized, which is always within the same scope.
        if (c.sqlite3_bind_text(self.stmt, idx, value.ptr, @intCast(value.len), null) != c.SQLITE_OK) {
            return errors.fail(.io_error, "sqlite bind text failed", .{});
        }
    }

    pub fn bindOptText(self: Statement, idx: c_int, value: ?[]const u8) errors.Ztd!void {
        if (value) |v| return self.bindText(idx, v);
        return self.bindNull(idx);
    }

    pub fn bindInt(self: Statement, idx: c_int, value: i64) errors.Ztd!void {
        if (c.sqlite3_bind_int64(self.stmt, idx, value) != c.SQLITE_OK) {
            return errors.fail(.io_error, "sqlite bind int failed", .{});
        }
    }

    pub fn bindDouble(self: Statement, idx: c_int, value: f64) errors.Ztd!void {
        if (c.sqlite3_bind_double(self.stmt, idx, value) != c.SQLITE_OK) {
            return errors.fail(.io_error, "sqlite bind double failed", .{});
        }
    }

    pub fn bindNull(self: Statement, idx: c_int) errors.Ztd!void {
        if (c.sqlite3_bind_null(self.stmt, idx) != c.SQLITE_OK) {
            return errors.fail(.io_error, "sqlite bind null failed", .{});
        }
    }

    pub fn step(self: Statement) errors.Ztd!bool {
        return switch (c.sqlite3_step(self.stmt)) {
            c.SQLITE_ROW => true,
            c.SQLITE_DONE => false,
            c.SQLITE_BUSY, c.SQLITE_LOCKED => errors.fail(.db_busy, "database is locked", .{}),
            else => errors.fromSqlite(std.mem.span(c.sqlite3_errmsg(c.sqlite3_db_handle(self.stmt))), false),
        };
    }

    pub fn columnCount(self: Statement) c_int {
        return c.sqlite3_column_count(self.stmt);
    }

    pub fn isNull(self: Statement, col: c_int) bool {
        return c.sqlite3_column_type(self.stmt, col) == c.SQLITE_NULL;
    }

    pub fn text(self: Statement, col: c_int) []const u8 {
        const p = c.sqlite3_column_text(self.stmt, col) orelse return "";
        const n: usize = @intCast(c.sqlite3_column_bytes(self.stmt, col));
        return p[0..n];
    }

    pub fn optText(self: Statement, col: c_int) ?[]const u8 {
        if (self.isNull(col)) return null;
        return self.text(col);
    }

    pub fn int(self: Statement, col: c_int) i64 {
        return c.sqlite3_column_int64(self.stmt, col);
    }

    /// Reads a REAL column (bm25 ranks, ratios) as Go's database/sql does.
    pub fn columnName(self: Statement, col: c_int) []const u8 {
        const p = c.sqlite3_column_name(self.stmt, col) orelse return "";
        return std.mem.span(p);
    }

    pub const ColumnType = enum { integer, float, text, blob, null_value };

    pub fn columnType(self: Statement, col: c_int) ColumnType {
        return switch (c.sqlite3_column_type(self.stmt, col)) {
            c.SQLITE_INTEGER => .integer,
            c.SQLITE_FLOAT => .float,
            c.SQLITE_TEXT => .text,
            c.SQLITE_BLOB => .blob,
            else => .null_value,
        };
    }

    pub fn bytes(self: Statement, col: c_int) []const u8 {
        const p = c.sqlite3_column_blob(self.stmt, col);
        const n = c.sqlite3_column_bytes(self.stmt, col);
        if (p == null or n <= 0) return "";
        return @as([*]const u8, @ptrCast(p))[0..@intCast(n)];
    }

    pub fn real(self: Statement, col: c_int) f64 {
        return c.sqlite3_column_double(self.stmt, col);
    }
};

/// Rejects nonempty files that are not SQLite before the library touches them.
fn checkHeader(path: [:0]const u8) errors.Ztd!void {
    const fd = c.open(path, c.O_RDONLY);
    if (fd < 0) {
        if (std.c._errno().* == @backingInt(std.c.E.NOENT)) return;
        return errors.fail(.io_error, "open database file: {s}", .{path});
    }
    defer _ = c.close(fd);
    var hdr: [sqliteMagic.len]u8 = undefined;
    var n: usize = 0;
    while (n < hdr.len) {
        const got = c.read(fd, hdr[n..].ptr, @intCast(hdr.len - n));
        if (got < 0) return errors.fail(.io_error, "read database header: {s}", .{path});
        if (got == 0) break;
        n += @intCast(got);
    }
    if (n == 0) return;
    if (!std.mem.eql(u8, hdr[0..n], sqliteMagic[0..n])) {
        return errors.fail(.db_incompatible, "{s} is a nonempty file that is not a SQLite database", .{path});
    }
}

/// Creates an in-memory DB, exercises FTS5 and JSON1, and prints what it found.
pub fn selfTest(w: *std.Io.Writer) !void {
    var db = try Db.open(":memory:");
    defer db.close();
    try db.exec(
        "CREATE TABLE t(id INTEGER PRIMARY KEY, body TEXT);" ++
            "INSERT INTO t(body) VALUES ('alpha beta'),('gamma');" ++
            "CREATE VIRTUAL TABLE fts USING fts5(body);" ++
            "INSERT INTO fts(body) SELECT body FROM t;",
    );

    var stmt = try db.prepare("SELECT body FROM fts WHERE fts MATCH 'beta'");
    defer stmt.finalize();
    if (!try stmt.step()) return error.NoRow;
    try w.print("fts:{s}\n", .{stmt.text(0)});

    var json = try db.prepare("SELECT json_extract('{\"a\":[1,2]}','$.a[1]')");
    defer json.finalize();
    if (!try json.step()) return error.NoRow;
    try w.print("json:{d}\n", .{json.int(0)});
}

test "sqlite links with FTS5 and JSON1" {
    var db = try Db.open(":memory:");
    defer db.close();
    try db.exec("CREATE VIRTUAL TABLE fts USING fts5(body); INSERT INTO fts(body) VALUES ('alpha beta');");

    var stmt = try db.prepare("SELECT json_extract('{\"a\":[1,2]}','$.a[1]')");
    defer stmt.finalize();
    try std.testing.expect(try stmt.step());
    try std.testing.expectEqual(@as(i64, 2), stmt.int(0));
}

test "transactions roll back" {
    var db = try Db.open(":memory:");
    defer db.close();
    try db.exec("CREATE TABLE t(v TEXT)");
    try db.begin();
    var ins = try db.prepare("INSERT INTO t(v) VALUES (?)");
    try ins.bindText(1, "x");
    _ = try ins.step();
    ins.finalize();
    db.rollback();
    var count = try db.prepare("SELECT count(*) FROM t");
    defer count.finalize();
    try std.testing.expect(try count.step());
    try std.testing.expectEqual(@as(i64, 0), count.int(0));
}
