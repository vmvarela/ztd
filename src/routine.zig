const std = @import("std");
const platform = @import("platform.zig");

/// Última ejecución de cada rutina recurrente. Markdown como el resto del
/// workspace: el archivo es legible y diffeable, y `ztd` solo reescribe la fila.
pub const path = "routines/state.md";

pub const Row = struct {
    id: []const u8,
    cadence: []const u8,
    last: platform.Date,
    /// 0 = lunes … 6 = domingo; null para cadencia diaria.
    weekday: ?u3,
};

const names = [_][]const u8{ "lun", "mar", "mie", "jue", "vie", "sab", "dom" };
const weekly_prefix = "semanal:";
const daily = "diaria";

pub fn isDue(entry: Row, today: platform.Date) bool {
    const since = platform.diff(today, entry.last);
    const wd = entry.weekday orelse return since >= 1;
    const current: u8 = today.weekday();
    const wanted: u8 = wd;
    const offset: i64 = @intCast((current + 7 - wanted) % 7);
    return since > offset;
}

pub fn parse(alloc: std.mem.Allocator, text: []const u8) ![]Row {
    var out: std.ArrayList(Row) = .empty;
    errdefer {
        for (out.items) |r| {
            alloc.free(r.id);
            alloc.free(r.cadence);
        }
        out.deinit(alloc);
    }
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const maybe = try row(line);
        const r = maybe orelse continue;
        for (out.items) |seen| {
            if (std.mem.eql(u8, seen.id, r.id)) return error.DuplicateId;
        }
        try out.append(alloc, .{
            .id = try alloc.dupe(u8, r.id),
            .cadence = try alloc.dupe(u8, r.cadence),
            .last = r.last,
            .weekday = r.weekday,
        });
    }
    if (out.items.len == 0) return error.MalformedRoutine;
    return out.toOwnedSlice(alloc);
}

pub fn stamp(alloc: std.mem.Allocator, text: []const u8, id: []const u8, today: platform.Date) ![]const u8 {
    var date_buf: [10]u8 = undefined;
    const date = today.format(&date_buf);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    var found = false;
    var first = true;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (!first) try out.append(alloc, '\n');
        first = false;
        if (try row(line)) |r| {
            if (std.mem.eql(u8, r.id, id)) {
                found = true;
                try out.appendSlice(alloc, "| ");
                try out.appendSlice(alloc, r.id);
                try out.appendSlice(alloc, " | ");
                try out.appendSlice(alloc, r.cadence);
                try out.appendSlice(alloc, " | ");
                try out.appendSlice(alloc, date);
                try out.appendSlice(alloc, " |");
                continue;
            }
        }
        try out.appendSlice(alloc, line);
    }
    if (!found) return error.UnknownId;
    return out.toOwnedSlice(alloc);
}

/// Una fila de la tabla; null para líneas fuera de tabla, cabecera y separador.
fn row(line: []const u8) !?Row {
    const trimmed = std.mem.trim(u8, line, " \t\r");
    if (trimmed.len == 0 or trimmed[0] != '|') return null;
    if (trimmed[trimmed.len - 1] != '|') return error.MalformedRoutine;

    var cells: [3][]const u8 = undefined;
    var count: usize = 0;
    var it = std.mem.splitScalar(u8, trimmed[1 .. trimmed.len - 1], '|');
    while (it.next()) |cell| {
        if (count == cells.len) return error.MalformedRoutine;
        cells[count] = std.mem.trim(u8, cell, " \t");
        count += 1;
    }
    if (count != cells.len) return error.MalformedRoutine;

    const id = cells[0];
    const cadence = cells[1];
    if (std.mem.eql(u8, id, "rutina") or isSeparator(id)) return null;
    if (!validId(id)) return error.MalformedRoutine;

    const weekday: ?u3 = if (std.mem.eql(u8, cadence, daily))
        null
    else blk: {
        if (!std.mem.startsWith(u8, cadence, weekly_prefix)) return error.MalformedRoutine;
        break :blk dayIndex(cadence[weekly_prefix.len..]) orelse return error.MalformedRoutine;
    };
    const last = platform.parseDate(cells[2]) catch return error.MalformedRoutine;
    return .{ .id = id, .cadence = cadence, .last = last, .weekday = weekday };
}

fn dayIndex(text: []const u8) ?u3 {
    for (names, 0..) |name, i| {
        if (std.mem.eql(u8, name, text)) return @intCast(i);
    }
    return null;
}

fn validId(id: []const u8) bool {
    if (id.len == 0 or id[0] < 'a' or id[0] > 'z') return false;
    for (id[1..]) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_') return false;
    }
    return true;
}

fn isSeparator(id: []const u8) bool {
    for (id) |c| {
        if (c != '-') return false;
    }
    return id.len > 0;
}

const sample =
    \\# Estado de rutinas
    \\
    \\| rutina | cadencia | última |
    \\| --- | --- | --- |
    \\| inbox | diaria | 2026-11-14 |
    \\| review | semanal:sab | 2026-11-07 |
    \\
;

test "parse and due" {
    const alloc = std.testing.allocator;
    const rows = try parse(alloc, sample);
    defer {
        for (rows) |r| {
            alloc.free(r.id);
            alloc.free(r.cadence);
        }
        alloc.free(rows);
    }
    try std.testing.expectEqual(@as(usize, 2), rows.len);
    try std.testing.expectEqualStrings("inbox", rows[0].id);
    try std.testing.expectEqualStrings("semanal:sab", rows[1].cadence);
    try std.testing.expectEqual(@as(?u3, 5), rows[1].weekday);

    const sunday = try platform.parseDate("2026-11-15");
    try std.testing.expect(isDue(rows[0], sunday));
    try std.testing.expect(isDue(rows[1], sunday));

    const saturday = try platform.parseDate("2026-11-14");
    try std.testing.expect(!isDue(rows[0], saturday));
    try std.testing.expect(isDue(rows[1], saturday));
    // Hecha el sábado, no vuelve a vencer hasta el sábado siguiente.
    try std.testing.expect(!isDue(rows[1], try platform.parseDate("2026-11-08")));
    try std.testing.expect(!isDue(rows[1], try platform.parseDate("2026-11-13")));
}

test "stamp rewrites one row and rejects unknown ids" {
    const alloc = std.testing.allocator;
    const today = try platform.parseDate("2026-11-15");
    const text = try stamp(alloc, sample, "inbox", today);
    defer alloc.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "| inbox | diaria | 2026-11-15 |") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "| review | semanal:sab | 2026-11-07 |") != null);
    try std.testing.expectEqual(sample.len, text.len);
    try std.testing.expectError(error.UnknownId, stamp(alloc, sample, "nope", today));
}

test "malformed input fails closed" {
    const alloc = std.testing.allocator;
    try std.testing.expectError(error.MalformedRoutine, parse(alloc, "| inbox | horaria | 2026-11-14 |\n"));
    try std.testing.expectError(error.MalformedRoutine, parse(alloc, "| inbox | diaria | 2026-13-14 |\n"));
    try std.testing.expectError(error.MalformedRoutine, parse(alloc, "# sin filas\n"));
    try std.testing.expectError(error.DuplicateId, parse(alloc, sample ++ "| inbox | diaria | 2026-11-14 |\n"));
}
