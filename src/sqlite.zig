//! Thin SQLite C API wrapper. Stage 1 grows this into the store layer; for now
//! it proves the vendored amalgamation, FTS5 and JSON1 link and run.

const std = @import("std");
pub const c = @import("c");

pub const Db = struct {
    handle: *c.sqlite3,

    pub fn open(path: [:0]const u8) !Db {
        var handle: ?*c.sqlite3 = null;
        if (c.sqlite3_open(path, &handle) != c.SQLITE_OK) return error.SqliteOpen;
        errdefer _ = c.sqlite3_close(handle);
        const db = Db{ .handle = handle.? };
        try db.exec("PRAGMA foreign_keys=ON; PRAGMA busy_timeout=5000; PRAGMA synchronous=FULL;");
        return db;
    }

    pub fn close(self: *Db) void {
        _ = c.sqlite3_close(self.handle);
    }

    pub fn exec(self: Db, sql: [:0]const u8) !void {
        var msg: [*c]u8 = null;
        if (c.sqlite3_exec(self.handle, sql, null, null, &msg) != c.SQLITE_OK) {
            if (msg != null) c.sqlite3_free(msg);
            return error.SqliteExec;
        }
    }

    pub fn prepare(self: Db, sql: [:0]const u8) !Statement {
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.handle, sql, -1, &stmt, null) != c.SQLITE_OK) return error.SqlitePrepare;
        return .{ .stmt = stmt.? };
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

    pub fn step(self: Statement) !bool {
        return switch (c.sqlite3_step(self.stmt)) {
            c.SQLITE_ROW => true,
            c.SQLITE_DONE => false,
            else => error.SqliteStep,
        };
    }

    pub fn text(self: Statement, col: c_int) []const u8 {
        const p = c.sqlite3_column_text(self.stmt, col) orelse return "";
        return std.mem.span(p);
    }

    pub fn int(self: Statement, col: c_int) i64 {
        return c.sqlite3_column_int64(self.stmt, col);
    }
};

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
