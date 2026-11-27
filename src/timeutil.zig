//! Time as the Go binary sees it: Unix seconds, UTC RFC3339, UTC id dates,
//! and the local calendar date through libc. Go never loads an IANA zone
//! (only `time.Local`), so `localtime_r` is a faithful substitute.

const std = @import("std");
const builtin = @import("builtin");
const c = @import("c");

pub const Timestamp = i64;

pub const CivilDate = struct {
    year: i32,
    month: u8,
    day: u8,
};

pub const CivilTime = struct {
    date: CivilDate,
    hour: u8,
    minute: u8,
    second: u8,
    /// 0 = Sunday, like libc's tm_wday.
    weekday: u8,
};

pub fn now(io: std.Io) Timestamp {
    return std.Io.Timestamp.now(io, .real).toSeconds();
}

/// Days since 1970-01-01 for a proleptic Gregorian date (Howard Hinnant).
pub fn daysFromCivil(y_in: i32, m: u8, d: u8) i64 {
    var y: i64 = y_in;
    const m_i: i64 = m;
    y -= if (m <= 2) 1 else 0;
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const mp = if (m_i > 2) m_i - 3 else m_i + 9;
    const doy = @divFloor(153 * mp + 2, 5) + d - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

pub fn civilFromDays(days: i64) CivilDate {
    const z = days + 719468;
    const era = @divFloor(z, 146097);
    const doe = z - era * 146097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    const y = yoe + era * 400;
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const d = doy - @divFloor(153 * mp + 2, 5) + 1;
    const m = if (mp < 10) mp + 3 else mp - 9;
    return .{
        .year = @intCast(if (m <= 2) y + 1 else y),
        .month = @intCast(m),
        .day = @intCast(d),
    };
}

pub fn civilFromTimestamp(t: Timestamp) CivilTime {
    const days = @divFloor(t, 86400);
    const secs = t - days * 86400;
    // 1970-01-01 was a Thursday (4).
    const weekday: u8 = @intCast(@mod(days + 4, 7));
    return .{
        .date = civilFromDays(days),
        .hour = @intCast(@divFloor(secs, 3600)),
        .minute = @intCast(@divFloor(@mod(secs, 3600), 60)),
        .second = @intCast(@mod(secs, 60)),
        .weekday = weekday,
    };
}

/// RFC3339 in UTC, second precision: the storage format for every timestamp.
pub fn fmtTime(t: Timestamp, buf: *[20]u8) []const u8 {
    const ct = civilFromTimestamp(t);
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        @as(u32, @intCast(ct.date.year)), ct.date.month, ct.date.day, ct.hour, ct.minute, ct.second,
    }) catch unreachable;
}

/// Compact UTC date used inside generated ids: C-20261119-001.
pub fn idDate(t: Timestamp, buf: *[8]u8) []const u8 {
    const ct = civilFromTimestamp(t);
    return std.fmt.bufPrint(buf, "{d:0>4}{d:0>2}{d:0>2}", .{
        @as(u32, @intCast(ct.date.year)), ct.date.month, ct.date.day,
    }) catch unreachable;
}

/// Calendar date in UTC: YYYY-MM-DD.
pub fn date(t: Timestamp, buf: *[10]u8) []const u8 {
    const ct = civilFromTimestamp(t);
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}", .{
        @as(u32, @intCast(ct.date.year)), ct.date.month, ct.date.day,
    }) catch unreachable;
}

/// Calendar date in the process timezone: Go uses time.Local for local_date.
pub fn localDate(t: Timestamp, buf: *[10]u8) []const u8 {
    var secs: c.time_t = @intCast(t);
    var tm: c.struct_tm = undefined;
    if (c.localtime_r(&secs, &tm) == null) return date(t, buf);
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}", .{
        @as(u32, @intCast(tm.tm_year + 1900)), @as(u8, @intCast(tm.tm_mon + 1)), @as(u8, @intCast(tm.tm_mday)),
    }) catch unreachable;
}

/// Parses the stored RFC3339 form. Fractional seconds are accepted and
/// dropped; anything else is an io_error, as in Go.
pub fn parseTime(s: []const u8) !Timestamp {
    const fmt = std.fmt;
    if (s.len < 20) return error.BadTimestamp;
    const year = fmt.parseInt(i32, s[0..4], 10) catch return error.BadTimestamp;
    const month = fmt.parseInt(u8, s[5..7], 10) catch return error.BadTimestamp;
    const day = fmt.parseInt(u8, s[8..10], 10) catch return error.BadTimestamp;
    const hour = fmt.parseInt(u8, s[11..13], 10) catch return error.BadTimestamp;
    const minute = fmt.parseInt(u8, s[14..16], 10) catch return error.BadTimestamp;
    const second = fmt.parseInt(u8, s[17..19], 10) catch return error.BadTimestamp;
    if (s[19] != 'Z' and s[19] != 'z') return error.BadTimestamp;
    return daysFromCivil(year, month, day) * 86400 +
        @as(i64, hour) * 3600 + @as(i64, minute) * 60 + second;
}

pub fn parseDate(s: []const u8) !Timestamp {
    if (s.len != 10) return error.BadTimestamp;
    const year = std.fmt.parseInt(i32, s[0..4], 10) catch return error.BadTimestamp;
    const month = std.fmt.parseInt(u8, s[5..7], 10) catch return error.BadTimestamp;
    const day = std.fmt.parseInt(u8, s[8..10], 10) catch return error.BadTimestamp;
    return daysFromCivil(year, month, day) * 86400;
}

/// ISO-8601 week and week-year: 2026-W48.
pub fn isoWeek(t: Timestamp) struct { year: i32, week: u8 } {
    const ct = civilFromTimestamp(t);
    // Thursday of the current ISO week decides both the week and the year.
    const monday_offset: i64 = if (ct.weekday == 0) 6 else @as(i64, ct.weekday) - 1;
    const thursday: i64 = daysFromCivil(ct.date.year, ct.date.month, ct.date.day) - monday_offset + 3;
    const iso_year = civilFromDays(thursday).year;
    const jan1 = daysFromCivil(iso_year, 1, 1);
    const week: u8 = @intCast(@divFloor(thursday - jan1, 7) + 1);
    return .{ .year = iso_year, .week = week };
}

pub fn fmtIsoWeek(t: Timestamp, buf: *[8]u8) []const u8 {
    const w = isoWeek(t);
    return std.fmt.bufPrint(buf, "{d:0>4}-W{d:0>2}", .{ @as(u32, @intCast(w.year)), w.week }) catch unreachable;
}

/// Zone name from /etc/localtime's symlink target, falling back to "Local".
pub fn localTimezone(buf: []u8) []const u8 {
    if (builtin.os.tag == .windows) return "Local";
    const n = c.readlink("/etc/localtime", buf.ptr, buf.len);
    if (n > 0) {
        const target = buf[0..@intCast(n)];
        const marker = "zoneinfo/";
        if (std.mem.lastIndexOf(u8, target, marker)) |i| {
            return target[i + marker.len ..];
        }
    }
    return "Local";
}

test "civil date round trip" {
    const t = daysFromCivil(2026, 11, 26);
    const d = civilFromDays(t);
    try std.testing.expectEqual(@as(i32, 2026), d.year);
    try std.testing.expectEqual(@as(u8, 11), d.month);
    try std.testing.expectEqual(@as(u8, 26), d.day);
    // 2026-11-26 is a Thursday.
    try std.testing.expectEqual(@as(u8, 4), civilFromTimestamp(t * 86400 + 3600).weekday);
}

test "fmt and parse are inverse" {
    var buf: [20]u8 = undefined;
    const t: Timestamp = daysFromCivil(2026, 1, 2) * 86400 + 3 * 3600 + 4 * 60 + 5;
    const s = fmtTime(t, &buf);
    try std.testing.expectEqualStrings("2026-01-02T03:04:05Z", s);
    try std.testing.expectEqual(t, try parseTime(s));
}

test "iso week at year boundaries" {
    // 2021-01-01 belongs to 2020-W53; 2024-12-30 to 2025-W01.
    try std.testing.expectEqual(@as(i32, 2020), isoWeek(daysFromCivil(2021, 1, 1) * 86400).year);
    try std.testing.expectEqual(@as(u8, 53), isoWeek(daysFromCivil(2021, 1, 1) * 86400).week);
    try std.testing.expectEqual(@as(i32, 2025), isoWeek(daysFromCivil(2024, 12, 30) * 86400).year);
    try std.testing.expectEqual(@as(u8, 1), isoWeek(daysFromCivil(2024, 12, 30) * 86400).week);
}
