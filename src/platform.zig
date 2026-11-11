const std = @import("std");
const builtin = @import("builtin");

pub const Date = struct {
    year: u16,
    month: u8,
    day: u8,

    pub fn format(self: Date, buf: *[10]u8) []const u8 {
        return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}", .{
            self.year, self.month, self.day,
        }) catch unreachable;
    }

    pub fn eql(a: Date, b: Date) bool {
        return a.year == b.year and a.month == b.month and a.day == b.day;
    }
};

const Tm = extern struct {
    tm_sec: c_int,
    tm_min: c_int,
    tm_hour: c_int,
    tm_mday: c_int,
    tm_mon: c_int,
    tm_year: c_int,
    tm_wday: c_int,
    tm_yday: c_int,
    tm_isdst: c_int,
    tm_gmtoff: c_long,
    tm_zone: ?[*:0]const u8,
};

extern "c" fn localtime_r(timep: *const c_long, result: *Tm) ?*Tm;

const SYSTEMTIME = extern struct {
    wYear: u16,
    wMonth: u16,
    wDayOfWeek: u16,
    wDay: u16,
    wHour: u16,
    wMinute: u16,
    wSecond: u16,
    wMilliseconds: u16,
};

extern "kernel32" fn GetLocalTime(lpSystemTime: *SYSTEMTIME) callconv(.winapi) void;

pub fn today(io: std.Io) Date {
    const ts = std.Io.Clock.real.now(io);
    const secs: i64 = @intCast(@divFloor(ts.nanoseconds, std.time.ns_per_s));

    if (builtin.os.tag == .windows) {
        var st: SYSTEMTIME = undefined;
        GetLocalTime(&st);
        return .{ .year = st.wYear, .month = @intCast(st.wMonth), .day = @intCast(st.wDay) };
    }

    if (builtin.os.tag == .linux or builtin.os.tag == .macos or builtin.os.tag.isDarwin() or
        builtin.os.tag == .freebsd or builtin.os.tag == .openbsd or builtin.os.tag == .netbsd or
        builtin.os.tag == .dragonfly)
    {
        var t: c_long = @intCast(secs);
        var tm: Tm = undefined;
        if (localtime_r(&t, &tm) != null) {
            return .{
                .year = @intCast(tm.tm_year + 1900),
                .month = @intCast(tm.tm_mon + 1),
                .day = @intCast(tm.tm_mday),
            };
        }
    }

    // Fallback: UTC date. Only reachable on targets without a local-time API.
    const es = std.time.epoch.EpochSeconds{ .secs = @intCast(@max(secs, 0)) };
    const yd = es.getEpochDay().calculateYearDay();
    const md = yd.calculateMonthDay();
    return .{ .year = yd.year, .month = @backingInt(md.month), .day = md.day_index + 1 };
}

pub fn parseDate(text: []const u8) !Date {
    if (text.len != 10 or text[4] != '-' or text[7] != '-') return error.InvalidDate;
    const y = std.fmt.parseInt(u16, text[0..4], 10) catch return error.InvalidDate;
    const m = std.fmt.parseInt(u8, text[5..7], 10) catch return error.InvalidDate;
    const d = std.fmt.parseInt(u8, text[8..10], 10) catch return error.InvalidDate;
    if (m < 1 or m > 12 or d < 1 or d > 31) return error.InvalidDate;
    return .{ .year = y, .month = m, .day = d };
}

test "date parse" {
    const d = try parseDate("2026-11-11");
    try std.testing.expectEqual(@as(u16, 2026), d.year);
    try std.testing.expectEqual(@as(u8, 11), d.month);
    try std.testing.expectEqual(@as(u8, 11), d.day);
    try std.testing.expectError(error.InvalidDate, parseDate("2026-13-01"));
}
