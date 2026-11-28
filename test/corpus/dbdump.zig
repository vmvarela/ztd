//! Read-only SQLite dumper for the corpus: walks `sqlite_master` and every
//! user table b-tree in rowid order, without linking SQLite. Main-file pages
//! are overlaid with committed `-wal` frames first so the dump sees what a
//! real reader (the Go harness's driver) sees.

const std = @import("std");
const harness = @import("harness.zig");

pub const Cell = struct { name: []const u8, value: []const u8 };
pub const Row = std.ArrayList(Cell);
pub const Table = struct { name: []const u8, rows: std.ArrayList(Row) };

const Value = union(enum) {
    null,
    int: i64,
    real: f64,
    text: []const u8,
    blob: []const u8,
};

const image = struct {
    bytes: []u8,
    page_size: usize,
    usable: usize,

    fn page(self: image, no: u32) error{Corrupt}![]const u8 {
        if (no == 0) return error.Corrupt;
        const off = (@as(usize, no) - 1) * self.page_size;
        if (off + self.page_size > self.bytes.len) return error.Corrupt;
        return self.bytes[off .. off + self.page_size];
    }

    fn readU32(b: []const u8) u32 {
        return (@as(u32, b[0]) << 24) | (@as(u32, b[1]) << 16) | (@as(u32, b[2]) << 8) | @as(u32, b[3]);
    }

    fn readU16(b: []const u8) u16 {
        return (@as(u16, b[0]) << 8) | @as(u16, b[1]);
    }

    /// SQLite varint: 1..9 bytes, 7 bits each, high bit = continuation.
    fn readVarint(b: []const u8) error{Corrupt}!struct { v: u64, len: usize } {
        var v: u64 = 0;
        var i: usize = 0;
        while (i < 8 and i < b.len) : (i += 1) {
            v = (v << 7) | @as(u64, b[i] & 0x7f);
            if (b[i] & 0x80 == 0) return .{ .v = v, .len = i + 1 };
        }
        if (b.len < 9) return error.Corrupt;
        v = (v << 8) | @as(u64, b[8]);
        return .{ .v = v, .len = 9 };
    }

    /// Reassembles a cell payload, following overflow chains when the payload
    /// exceeds the page's local budget (formulas from sqlite3.c btree.c).
    fn payload(self: image, a: std.mem.Allocator, psize: usize, cell: []const u8) (error{Corrupt} || std.mem.Allocator.Error)![]const u8 {
        const max_local = self.usable - 35;
        const min_local = ((self.usable - 12) * 32) / 255 - 23;
        if (psize <= max_local) {
            if (cell.len < psize) return error.Corrupt;
            return try a.dupe(u8, cell[0..psize]);
        }
        const surplus = min_local + (psize - min_local) % (self.usable - 4);
        const local: usize = if (surplus <= max_local) surplus else min_local;
        if (cell.len < local + 4) return error.Corrupt;
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(a);
        try out.appendSlice(a, cell[0..local]);
        var next: u32 = readU32(cell[local .. local + 4]);
        while (next != 0 and out.items.len < psize) {
            const pg = try self.page(next);
            try out.appendSlice(a, pg[4 .. 4 + (self.usable - 4)]);
            next = readU32(pg[0..4]);
        }
        if (out.items.len < psize) return error.Corrupt;
        return out.items[0..psize];
    }
};

const RawRow = struct { rowid: i64, values: std.ArrayList(Value) };

/// Walks a table b-tree in ascending rowid order and decodes each record.
fn walkTable(a: std.mem.Allocator, img: image, root: u32, out: *std.ArrayList(RawRow)) !void {
    const page = try img.page(root);
    if (page.len < 8) return error.Corrupt;
    const hdr: usize = if (root == 1) 100 else 0;
    if (hdr + 8 > page.len) return error.Corrupt;
    const kind = page[hdr];
    const ncells = image.readU16(page[hdr + 3 .. hdr + 5]);
    const ptr_base = hdr + 8;
    const ptr_region = if (kind == 0x05) ptr_base + 4 else ptr_base;
    if (ptr_region + ncells * 2 > page.len) return error.Corrupt;
    switch (kind) {
        0x05 => {
            for (0..ncells) |i| {
                const off = image.readU16(page[ptr_region + i * 2 .. ptr_region + i * 2 + 2]);
                if (off + 4 > page.len) return error.Corrupt;
                try walkTable(a, img, image.readU32(page[off .. off + 4]), out);
            }
            const right = image.readU32(page[ptr_base .. ptr_base + 4]);
            if (right == 0) return error.Corrupt;
            try walkTable(a, img, right, out);
        },
        // sqlite3.c: PTF_LEAFDATA|PTF_INTKEY|PTF_LEAF = 0x0d is a table
        // leaf; 0x0a (ZERODATA|LEAF) is an index leaf.
        0x0D => {
            for (0..ncells) |i| {
                const off = image.readU16(page[ptr_region + i * 2 .. ptr_region + i * 2 + 2]);
                if (off >= page.len) return error.Corrupt;
                var p: usize = off;
                const psize_v = try image.readVarint(page[p..]);
                p += psize_v.len;
                const rowid_v = try image.readVarint(page[p..]);
                p += rowid_v.len;
                const psize = std.math.cast(usize, psize_v.v) orelse return error.Corrupt;
                const pl = try img.payload(a, psize, page[p..]);
                const values = try decodeRecord(a, pl);
                try out.append(a, .{ .rowid = @bitCast(rowid_v.v), .values = values });
            }
        },
        else => return error.Corrupt,
    }
}

fn decodeRecord(a: std.mem.Allocator, pl: []const u8) (error{Corrupt} || std.mem.Allocator.Error)!std.ArrayList(Value) {
    const hdr = try image.readVarint(pl);
    const serials_start = hdr.len;
    const serials_end: usize = @intCast(hdr.v);
    if (serials_end > pl.len or serials_end < serials_start) return error.Corrupt;
    var types: std.ArrayList(u64) = .empty;
    defer types.deinit(a);
    var p = serials_start;
    while (p < serials_end) {
        const sv = try image.readVarint(pl[p..]);
        p += sv.len;
        try types.append(a, sv.v);
    }
    var data = pl[serials_end..];
    var row: std.ArrayList(Value) = .empty;
    errdefer row.deinit(a);
    for (types.items) |st| {
        const v = try decodeValue(st, &data);
        try row.append(a, v);
    }
    if (data.len != 0) return error.Corrupt;
    return row;
}

fn take(data: *[]const u8, n: usize) error{Corrupt}![]const u8 {
    if (data.len < n) return error.Corrupt;
    const out = data.*[0..n];
    data.* = data.*[n..];
    return out;
}

fn decodeValue(st: u64, data: *[]const u8) error{Corrupt}!Value {
    if (st == 0) return .null;
    if (st == 8) return .{ .int = 0 };
    if (st == 9) return .{ .int = 1 };
    if (st == 10 or st == 11) return error.Corrupt;
    if (st >= 12) {
        const len: usize = @intCast(if (st % 2 == 0) (st - 12) / 2 else (st - 13) / 2);
        const bytes = try take(data, len);
        return if (st % 2 == 0) .{ .blob = bytes } else .{ .text = bytes };
    }
    const n: usize = switch (st) {
        1 => 1,
        2 => 2,
        3 => 3,
        4 => 4,
        5 => 6,
        6 => 8,
        7 => 8,
        else => return error.Corrupt,
    };
    const bytes = try take(data, n);
    if (st == 7) {
        var bits: u64 = 0;
        for (bytes) |b| bits = (bits << 8) | @as(u64, b);
        return .{ .real = @bitCast(bits) };
    }
    var u: u64 = 0;
    for (bytes) |b| u = (u << 8) | @as(u64, b);
    const signed: i64 = if (n == 8)
        @bitCast(u)
    else if (bytes[0] & 0x80 != 0)
        @bitCast(u | (~@as(u64, 0) << @intCast(8 * n)))
    else
        @as(i64, @intCast(u));
    return .{ .int = signed };
}

const Col = struct { name: []const u8, rowid_alias: bool };

/// Splits a CREATE TABLE body into top-level items and keeps the column names,
/// skipping table constraints the way a reader of `SELECT *` would see them.
fn parseColumns(a: std.mem.Allocator, sql: []const u8) !std.ArrayList(Col) {
    const open = std.mem.indexOfScalar(u8, sql, '(') orelse return error.Corrupt;
    var i = open + 1;
    var depth: usize = 1;
    var item_start = i;
    var cols: std.ArrayList(Col) = .empty;
    errdefer cols.deinit(a);
    while (i < sql.len) : (i += 1) {
        const c = sql[i];
        if (c == '\'') {
            i = try skipQuoted(sql, i, '\'');
            continue;
        }
        if (c == '"') {
            i = try skipQuoted(sql, i, '"');
            continue;
        }
        if (c == '[') {
            while (i < sql.len and sql[i] != ']') i += 1;
            continue;
        }
        if (c == '(') {
            depth += 1;
            continue;
        }
        if (c == ')') {
            depth -= 1;
            if (depth == 0) {
                try maybeColumn(a, &cols, sql[item_start..i]);
                return cols;
            }
            continue;
        }
        if (c == ',' and depth == 1) {
            try maybeColumn(a, &cols, sql[item_start..i]);
            item_start = i + 1;
        }
    }
    return error.Corrupt;
}

fn skipQuoted(s: []const u8, i: usize, quote: u8) !usize {
    var j = i + 1;
    while (j < s.len) {
        if (s[j] == quote) {
            if (j + 1 < s.len and s[j + 1] == quote) {
                j += 2;
                continue;
            }
            return j;
        }
        j += 1;
    }
    return error.Corrupt;
}

fn maybeColumn(a: std.mem.Allocator, cols: *std.ArrayList(Col), item: []const u8) !void {
    const t = std.mem.trim(u8, item, " \t\r\n");
    if (t.len == 0) return;
    const keywords = [_][]const u8{ "CONSTRAINT", "PRIMARY", "UNIQUE", "CHECK", "FOREIGN" };
    for (keywords) |kw| {
        if (t.len >= kw.len and std.ascii.eqlIgnoreCase(t[0..kw.len], kw) and
            (t.len == kw.len or !isIdentChar(t[kw.len])))
            return;
    }
    const name, const rest = if (t[0] == '"')
        .{ t[1..try skipQuoted(t, 0, '"')], t[try skipQuoted(t, 0, '"') + 1 ..] }
    else if (t[0] == '[') blk: {
        const end = std.mem.indexOfScalarPos(u8, t, 1, ']') orelse return error.Corrupt;
        break :blk .{ t[1..end], t[end + 1 ..] };
    } else blk: {
        var end: usize = 0;
        while (end < t.len and isIdentChar(t[end])) end += 1;
        if (end == 0) return;
        break :blk .{ t[0..end], t[end..] };
    };
    try cols.append(a, .{ .name = name, .rowid_alias = isRowidAlias(rest) });
}

/// An `INTEGER PRIMARY KEY` column is the rowid alias: its payload cell holds
/// NULL and a reader must return the rowid instead.
fn isRowidAlias(rest: []const u8) bool {
    const t = std.mem.trim(u8, rest, " \t\r\n");
    var end: usize = 0;
    while (end < t.len and isIdentChar(t[end])) end += 1;
    if (end != 7 or !std.ascii.eqlIgnoreCase(t[0..7], "INTEGER")) return false;
    return containsIgnoreCase(t, "PRIMARY KEY");
}

fn containsIgnoreCase(hay: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (hay.len < needle.len) return false;
    var i: usize = 0;
    while (i + needle.len <= hay.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(hay[i .. i + needle.len], needle)) return true;
    }
    return false;
}

fn isIdentChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_';
}

/// Go's `cell()` formatting: nil → "<null>", integers decimal, text/blob the
/// raw bytes (the schema stores no REAL columns; floats fall through to the
/// shortest decimal like fmt.Sprint).
fn cellText(a: std.mem.Allocator, v: Value) ![]const u8 {
    return switch (v) {
        .null => "<null>",
        .int => |i| try std.fmt.allocPrint(a, "{d}", .{i}),
        .real => |f| try std.fmt.allocPrint(a, "{d}", .{f}),
        .text, .blob => |s| s,
    };
}

/// Reads every user table in rowid order, applying the harness skip rules
/// (sqlite_%, %_fts%, links, knowledge_records) and normalizing each cell.
pub fn dump(io: std.Io, a: std.mem.Allocator, db_path: []const u8, sys_tmp: []const u8) !std.ArrayList(Table) {
    const raw = std.Io.Dir.cwd().readFileAlloc(io, db_path, a, .limited(1 << 31)) catch |e| switch (e) {
        error.FileNotFound => {
            std.debug.print("db: cannot read {s}: file not found\n", .{db_path});
            return error.FileNotFound;
        },
        else => return e,
    };
    var bytes = try a.dupe(u8, raw);
    try overlayWal(io, a, &bytes, db_path);

    if (bytes.len < 100 or !std.mem.eql(u8, bytes[0..16], "SQLite format 3\x00")) {
        std.debug.print("db: {s} is not a SQLite database\n", .{db_path});
        return error.NotADatabase;
    }
    const page_size_field = image.readU16(bytes[16..18]);
    const page_size: usize = if (page_size_field == 1) 65536 else page_size_field;
    const reserve: usize = bytes[20];
    if (page_size < 512 or page_size < 480 + reserve or bytes.len < page_size) {
        return error.Corrupt;
    }
    const img = image{ .bytes = bytes, .page_size = page_size, .usable = page_size - reserve };

    // sqlite_master is the b-tree rooted at page 1.
    var master: std.ArrayList(RawRow) = .empty;
    defer {
        for (master.items) |*r| r.values.deinit(a);
        master.deinit(a);
    }
    try walkTable(a, img, 1, &master);

    var tables: std.ArrayList(Table) = .empty;
    errdefer {
        for (tables.items) |*t| {
            for (t.rows.items) |*r| r.deinit(a);
            t.rows.deinit(a);
        }
        tables.deinit(a);
    }

    for (master.items) |mrowr| {
        const mrow = mrowr.values;
        if (mrow.items.len < 5) return error.Corrupt;
        const kind = switch (mrow.items[0]) {
            .text => |s| s,
            else => continue,
        };
        if (!std.mem.eql(u8, kind, "table")) continue;
        const name = switch (mrow.items[1]) {
            .text => |s| s,
            else => return error.Corrupt,
        };
        if (std.mem.startsWith(u8, name, "sqlite_") or
            std.mem.indexOf(u8, name, "_fts") != null or
            std.mem.eql(u8, name, "knowledge_records"))
            continue;
        const rootpage: u32 = switch (mrow.items[3]) {
            .int => |i| std.math.cast(u32, i) orelse return error.Corrupt,
            else => return error.Corrupt,
        };
        const sql = switch (mrow.items[4]) {
            .text => |s| s,
            else => return error.Corrupt,
        };
        var cols = try parseColumns(a, sql);
        defer cols.deinit(a);

        var raw_rows: std.ArrayList(RawRow) = .empty;
        defer {
            for (raw_rows.items) |*r| r.values.deinit(a);
            raw_rows.deinit(a);
        }
        try walkTable(a, img, rootpage, &raw_rows);

        var rows: std.ArrayList(Row) = .empty;
        for (raw_rows.items) |rrow| {
            if (rrow.values.items.len != cols.items.len) return error.Corrupt;
            var row: Row = .empty;
            for (cols.items, 0..) |col, i| {
                var stored = rrow.values.items[i];
                if (col.rowid_alias and stored == .null) stored = .{ .int = rrow.rowid };
                var value: []const u8 = try harness.normalize(a, try cellText(a, stored), &.{}, sys_tmp);
                // The profile timezone is the machine's local zone, so it
                // differs between hosts; the shape is what matters.
                if (std.mem.eql(u8, col.name, "timezone")) value = "<tz>";
                try row.append(a, .{ .name = col.name, .value = value });
            }
            try rows.append(a, row);
        }
        try tables.append(a, .{ .name = name, .rows = rows });
    }
    return tables;
}

/// Overlays committed WAL frames onto the main image so a dump taken between
/// checkpoints sees the same bytes a SQLite reader does. Shortcut: frames are
/// validated by salt and commit order only (the checksum chain is skipped);
/// the corpus DBs checkpoint on last close, so a WAL is rare.
fn overlayWal(io: std.Io, a: std.mem.Allocator, bytes: *[]u8, db_path: []const u8) !void {
    const wal_path = try std.fmt.allocPrint(a, "{s}-wal", .{db_path});
    const wal = std.Io.Dir.cwd().readFileAlloc(io, wal_path, a, .limited(1 << 31)) catch |e| switch (e) {
        error.FileNotFound => return,
        else => return e,
    };
    defer a.free(wal);
    if (wal.len < 32) return;
    const magic = image.readU32(wal[0..4]);
    if (magic != 0x377f0682 and magic != 0x377f0683) return error.WalCorrupt;
    const wal_page = image.readU32(wal[8..12]);
    if (wal_page == 0) return error.WalCorrupt;
    const salt1 = image.readU32(wal[16..20]);
    const salt2 = image.readU32(wal[20..24]);
    const frame_size = 24 + wal_page;
    const db_field: usize = blk: {
        if (bytes.len < 18) break :blk 0;
        const f = image.readU16(bytes.*[16..18]);
        break :blk if (f == 1) 65536 else f;
    };
    if (db_field != 0 and db_field != wal_page) return error.WalCorrupt;

    const Frame = struct { off: usize, pgno: u32, commit: bool };
    var frames: std.ArrayList(Frame) = .empty;
    defer frames.deinit(a);
    var off: usize = 32;
    while (off + frame_size <= wal.len) : (off += frame_size) {
        const pgno = image.readU32(wal[off .. off + 4]);
        const flags = image.readU32(wal[off + 4 .. off + 8]);
        if (image.readU32(wal[off + 8 .. off + 12]) != salt1 or
            image.readU32(wal[off + 12 .. off + 16]) != salt2)
            break; // torn tail
        if (pgno == 0) return error.WalCorrupt;
        try frames.append(a, .{ .off = off, .pgno = pgno, .commit = flags & 1 != 0 });
    }
    // Only frames up to the last commit are part of the visible state.
    var last: usize = 0;
    for (frames.items, 0..) |f, i| {
        if (f.commit) last = i;
    }
    for (frames.items[0 .. last + 1]) |f| {
        const target = (@as(usize, f.pgno) - 1) * wal_page;
        const src = wal[f.off + 24 .. f.off + 24 + wal_page];
        if (target + wal_page > bytes.len) {
            const grown = try a.alloc(u8, target + wal_page);
            @memcpy(grown[0..bytes.len], bytes.*);
            @memset(grown[bytes.len..], 0);
            a.free(bytes.*);
            bytes.* = grown;
        }
        @memcpy(bytes.*[target .. target + wal_page], src);
    }
}
