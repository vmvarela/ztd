//! Read a consistent committed snapshot through SQLite, including WAL frames.
const std = @import("std");
const c = @import("c");
const harness = @import("harness.zig");

pub const Cell = struct { name: []const u8, value: []const u8 };
pub const Row = std.ArrayList(Cell);
pub const Table = struct { name: []const u8, rows: std.ArrayList(Row) };

fn prepare(db: *c.sqlite3, sql: [*:0]const u8) !*c.sqlite3_stmt {
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(db, sql, -1, &stmt, null) != c.SQLITE_OK) {
        std.debug.print("db: {s}\n", .{std.mem.span(c.sqlite3_errmsg(db))});
        return error.Sqlite;
    }
    return stmt orelse error.Sqlite;
}

fn step(stmt: *c.sqlite3_stmt) !bool {
    return switch (c.sqlite3_step(stmt)) {
        c.SQLITE_ROW => true,
        c.SQLITE_DONE => false,
        else => {
            std.debug.print("db: {s}\n", .{std.mem.span(c.sqlite3_errmsg(c.sqlite3_db_handle(stmt)))});
            return error.Sqlite;
        },
    };
}

fn cellText(a: std.mem.Allocator, stmt: *c.sqlite3_stmt, col: c_int) ![]const u8 {
    return switch (c.sqlite3_column_type(stmt, col)) {
        c.SQLITE_NULL => "<null>",
        c.SQLITE_INTEGER => try std.fmt.allocPrint(a, "{d}", .{c.sqlite3_column_int64(stmt, col)}),
        c.SQLITE_FLOAT => try std.fmt.allocPrint(a, "{d}", .{c.sqlite3_column_double(stmt, col)}),
        else => blk: {
            const p = c.sqlite3_column_blob(stmt, col);
            const len: usize = @intCast(c.sqlite3_column_bytes(stmt, col));
            if (len == 0) break :blk "";
            break :blk try a.dupe(u8, @as([*]const u8, @ptrCast(p orelse return error.Sqlite))[0..len]);
        },
    };
}

fn exec(db: *c.sqlite3, sql: [*:0]const u8) !void {
    if (c.sqlite3_exec(db, sql, null, null, null) != c.SQLITE_OK) {
        std.debug.print("db: {s}\n", .{std.mem.span(c.sqlite3_errmsg(db))});
        return error.Sqlite;
    }
}

/// Check fixed corpus values before legacy normalization masks them.
pub fn checkJourney(a: std.mem.Allocator, db_path: []const u8) !void {
    const path = try a.dupeSentinel(u8, db_path, 0);
    defer a.free(path);
    var db: ?*c.sqlite3 = null;
    const rc = c.sqlite3_open_v2(path, &db, c.SQLITE_OPEN_READONLY, null);
    defer if (db) |handle| {
        _ = c.sqlite3_close(handle);
    };
    if (rc != c.SQLITE_OK) return error.Sqlite;
    const stmt = try prepare(db.?,
        \\SELECT (SELECT review_after FROM captures WHERE original_text='delegate the invoice'),
        \\       (SELECT period FROM reviews WHERE kind='weekly'),
        \\       (SELECT content_hash FROM captures WHERE original_text='renew the parking permit')
    );
    defer _ = c.sqlite3_finalize(stmt);
    if (!try step(stmt)) return error.FixedFixtureMismatch;
    const expected = [_][]const u8{
        "2026-12-01T00:00:00Z",
        "2026-W48",
        "1768ff22e477c069123d83fbf49e7a0da16da63097881765d8eac85d8d5fc67d",
    };
    for (expected, 0..) |value, i| {
        const actual = try cellText(a, stmt, @intCast(i));
        if (!std.mem.eql(u8, actual, value)) {
            std.debug.print("journey: raw fixture {d} got {s}, want {s}\n", .{ i, actual, value });
            return error.FixedFixtureMismatch;
        }
    }
}

/// Exercise a live WAL with an even database size and an open writer.
pub fn checkWal(io: std.Io, a: std.mem.Allocator, path: []const u8, sys_tmp: []const u8) !void {
    const zpath = try a.dupeSentinel(u8, path, 0);
    defer a.free(zpath);
    var writer: ?*c.sqlite3 = null;
    const rc = c.sqlite3_open_v2(zpath, &writer, c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE, null);
    defer if (writer) |db| {
        _ = c.sqlite3_close(db);
    };
    if (rc != c.SQLITE_OK) return error.Sqlite;
    const db = writer.?;
    try exec(db, "PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0; CREATE TABLE fixture (id INTEGER PRIMARY KEY, value TEXT); INSERT INTO fixture VALUES (1, 'committed');");
    const count = try prepare(db, "PRAGMA page_count");
    if (!try step(count)) return error.Sqlite;
    const pages = c.sqlite3_column_int(count, 0);
    _ = c.sqlite3_finalize(count);
    if (pages == 0 or @mod(pages, 2) != 0) return error.ExpectedEvenPages;
    try exec(db, "BEGIN; INSERT INTO fixture VALUES (2, 'uncommitted');");
    defer _ = c.sqlite3_exec(db, "ROLLBACK", null, null, null);
    var reader: ?*c.sqlite3 = null;
    const reader_rc = c.sqlite3_open_v2(zpath, &reader, c.SQLITE_OPEN_READONLY, null);
    defer if (reader) |handle| {
        _ = c.sqlite3_close(handle);
    };
    if (reader_rc != c.SQLITE_OK) return error.Sqlite;
    const raw = try prepare(reader.?, "SELECT count(*), min(value), max(id) FROM fixture");
    defer _ = c.sqlite3_finalize(raw);
    if (!try step(raw) or c.sqlite3_column_int(raw, 0) != 1 or
        !std.mem.eql(u8, try cellText(a, raw, 1), "committed") or
        c.sqlite3_column_int(raw, 2) != 1) return error.WalFixtureMismatch;
    const tables = try dump(io, a, path, sys_tmp);
    if (tables.items.len != 1 or tables.items[0].rows.items.len != 1) return error.WalFixtureMismatch;
    const row = tables.items[0].rows.items[0].items;
    if (row.len != 2 or !std.mem.eql(u8, row[0].value, "1") or !std.mem.eql(u8, row[1].value, "committed")) return error.WalFixtureMismatch;
    std.debug.print("corpus: live WAL fixture ({d} pages, 1 committed row, no uncommitted rows) — ok\n", .{pages});
}

pub fn dump(_: std.Io, a: std.mem.Allocator, db_path: []const u8, sys_tmp: []const u8) !std.ArrayList(Table) {
    const path = try a.dupeSentinel(u8, db_path, 0);
    defer a.free(path);
    var handle: ?*c.sqlite3 = null;
    const rc = c.sqlite3_open_v2(path, &handle, c.SQLITE_OPEN_READONLY, null);
    defer if (handle) |db| {
        _ = c.sqlite3_close(db);
    };
    if (rc != c.SQLITE_OK) return error.Sqlite;
    const db = handle orelse return error.Sqlite;
    if (c.sqlite3_exec(db, "BEGIN", null, null, null) != c.SQLITE_OK) return error.Sqlite;
    defer _ = c.sqlite3_exec(db, "ROLLBACK", null, null, null);

    const master = try prepare(db, "SELECT name FROM sqlite_master WHERE type='table' ORDER BY rowid");
    defer _ = c.sqlite3_finalize(master);
    var tables: std.ArrayList(Table) = .empty;
    while (try step(master)) {
        const name_ptr = c.sqlite3_column_text(master, 0) orelse return error.Sqlite;
        const name = try a.dupeSentinel(u8, std.mem.span(name_ptr), 0);
        if (std.mem.startsWith(u8, name, "sqlite_") or
            std.mem.indexOf(u8, name, "_fts") != null or
            std.mem.eql(u8, name, "knowledge_records")) continue;
        const sql = c.sqlite3_mprintf("SELECT * FROM \"%w\" ORDER BY rowid", name.ptr) orelse return error.OutOfMemory;
        defer c.sqlite3_free(sql);
        const stmt = try prepare(db, sql);
        defer _ = c.sqlite3_finalize(stmt);
        var rows: std.ArrayList(Row) = .empty;
        while (try step(stmt)) {
            var row: Row = .empty;
            var col: c_int = 0;
            while (col < c.sqlite3_column_count(stmt)) : (col += 1) {
                const col_name = try a.dupe(u8, std.mem.span(c.sqlite3_column_name(stmt, col)));
                var value: []const u8 = try harness.normalize(a, try cellText(a, stmt, col), &.{}, sys_tmp);
                if (std.mem.eql(u8, col_name, "timezone")) value = "<tz>";
                try row.append(a, .{ .name = col_name, .value = value });
            }
            try rows.append(a, row);
        }
        try tables.append(a, .{ .name = name, .rows = rows });
    }
    return tables;
}
