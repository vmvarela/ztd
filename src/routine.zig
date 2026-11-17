const std = @import("std");
const platform = @import("platform.zig");

/// Last run of each recurring routine. Markdown like the rest of the
/// workspace: the file stays readable and diffable, and `ztd` only rewrites
/// the row.
pub const path = "routines/state.md";

pub const Row = struct {
    id: []const u8,
    cadence: []const u8,
    last: platform.Date,
    /// 0 = Monday … 6 = Sunday; null for the daily cadence.
    weekday: ?u3,
};

const names = [_][]const u8{ "mon", "tue", "wed", "thu", "fri", "sat", "sun" };
const weekly_prefix = "weekly:";
const daily = "daily";

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

/// One row of the table; null for lines outside the table, the header and the
/// separator.
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
    if (std.mem.eql(u8, id, "routine") or isSeparator(id)) return null;
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
    \\# Routine state
    \\
    \\| routine | cadence | last |
    \\| --- | --- | --- |
    \\| inbox | daily | 2026-11-14 |
    \\| review | weekly:sat | 2026-11-07 |
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
    try std.testing.expectEqualStrings("weekly:sat", rows[1].cadence);
    try std.testing.expectEqual(@as(?u3, 5), rows[1].weekday);

    const sunday = try platform.parseDate("2026-11-15");
    try std.testing.expect(isDue(rows[0], sunday));
    try std.testing.expect(isDue(rows[1], sunday));

    const saturday = try platform.parseDate("2026-11-14");
    try std.testing.expect(!isDue(rows[0], saturday));
    try std.testing.expect(isDue(rows[1], saturday));
    // Run on Saturday: not due again until the next Saturday.
    try std.testing.expect(!isDue(rows[1], try platform.parseDate("2026-11-08")));
    try std.testing.expect(!isDue(rows[1], try platform.parseDate("2026-11-13")));
}

// Every `weekly:<day>` cadence behaves the same, shifted by the weekday:
// Monday-first tokens map to 0…6 and the due rule is identical for each day.
test "every weekday cadence is equivalent and Monday-first" {
    const alloc = std.testing.allocator;
    const cases = [_]struct { today: []const u8, week_ago: []const u8, token: []const u8, wd: u3 }{
        .{ .today = "2026-11-16", .week_ago = "2026-11-09", .token = "mon", .wd = 0 },
        .{ .today = "2026-11-17", .week_ago = "2026-11-10", .token = "tue", .wd = 1 },
        .{ .today = "2026-11-18", .week_ago = "2026-11-11", .token = "wed", .wd = 2 },
        .{ .today = "2026-11-19", .week_ago = "2026-11-12", .token = "thu", .wd = 3 },
        .{ .today = "2026-11-20", .week_ago = "2026-11-13", .token = "fri", .wd = 4 },
        .{ .today = "2026-11-21", .week_ago = "2026-11-14", .token = "sat", .wd = 5 },
        .{ .today = "2026-11-22", .week_ago = "2026-11-15", .token = "sun", .wd = 6 },
    };
    for (cases) |c| {
        const today = try platform.parseDate(c.today);
        try std.testing.expectEqual(c.wd, today.weekday());
        try std.testing.expectEqual(@as(i64, 7), platform.diff(today, try platform.parseDate(c.week_ago)));

        // Last run exactly one week ago: due today.
        const due_text = try std.fmt.allocPrint(alloc, "| r | weekly:{s} | {s} |\n", .{ c.token, c.week_ago });
        defer alloc.free(due_text);
        const due_rows = try parse(alloc, due_text);
        defer freeRows(alloc, due_rows);
        try std.testing.expectEqual(@as(?u3, c.wd), due_rows[0].weekday);
        try std.testing.expect(isDue(due_rows[0], today));

        // Last run today: not due again until the next occurrence.
        const today_text = try std.fmt.allocPrint(alloc, "| r | weekly:{s} | {s} |\n", .{ c.token, c.today });
        defer alloc.free(today_text);
        const today_rows = try parse(alloc, today_text);
        defer freeRows(alloc, today_rows);
        try std.testing.expect(!isDue(today_rows[0], today));
    }
}

fn freeRows(alloc: std.mem.Allocator, rows: []const Row) void {
    for (rows) |r| {
        alloc.free(r.id);
        alloc.free(r.cadence);
    }
    alloc.free(rows);
}

test "stamp rewrites one row and rejects unknown ids" {
    const alloc = std.testing.allocator;
    const today = try platform.parseDate("2026-11-15");
    const text = try stamp(alloc, sample, "inbox", today);
    defer alloc.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "| inbox | daily | 2026-11-15 |") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "| review | weekly:sat | 2026-11-07 |") != null);
    try std.testing.expectEqual(sample.len, text.len);
    try std.testing.expectError(error.UnknownId, stamp(alloc, sample, "nope", today));
}

test "malformed input fails closed" {
    const alloc = std.testing.allocator;
    try std.testing.expectError(error.MalformedRoutine, parse(alloc, "| inbox | hourly | 2026-11-14 |\n"));
    try std.testing.expectError(error.MalformedRoutine, parse(alloc, "| inbox | daily | 2026-13-14 |\n"));
    try std.testing.expectError(error.MalformedRoutine, parse(alloc, "# no rows\n"));
    try std.testing.expectError(error.DuplicateId, parse(alloc, sample ++ "| inbox | daily | 2026-11-14 |\n"));
}
