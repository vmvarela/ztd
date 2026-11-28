//! Port of v3_test.go: pins the acceptance surface of the v3 features —
//! provenance, prepare packets, measurement, overrides, calendar assertions,
//! decisions, learnings, output caps, the directory connector and export v2.
//! The Go file skips without ZTD_BIN; here the suite always runs.

const std = @import("std");
const harness = @import("harness.zig");

// ------------------------------------------------------------- time helpers

const daysFromCivil = timeutil.daysFromCivil;
const civilFromDays = timeutil.civilFromDays;

const timeutil = struct {
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

    pub fn civilFromDays(days: i64) struct { year: i32, month: u8, day: u8 } {
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
};

/// The runner links libc, and Go's time.Local is libc's `localtime_r`
/// anyway — the same substitute the product itself uses.
const CTm = extern struct {
    sec: i32,
    min: i32,
    hour: i32,
    mday: i32,
    mon: i32,
    year: i32,
    wday: i32,
    yday: i32,
    isdst: i32,
    gmtoff: i64,
    zone: ?[*:0]const u8,
};
extern fn tzset() void;
extern fn localtime_r(time: *const i64, result: *CTm) ?*CTm;

fn localDays(io: std.Io) i64 {
    const now: i64 = std.Io.Timestamp.now(io, .real).toSeconds();
    tzset();
    var secs: i64 = now;
    var tm: CTm = undefined;
    if (localtime_r(&secs, &tm) == null) return @divFloor(now, 86400);
    return daysFromCivil(tm.year + 1900, @intCast(tm.mon + 1), @intCast(tm.mday));
}

/// `time.Now().AddDate(0, 0, offset).Format("2006-01-02")`.
fn today(io: std.Io, buf: *[10]u8, offset: i64) []const u8 {
    const d = timeutil.civilFromDays(localDays(io) + offset);
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}", .{
        @as(u32, @intCast(d.year)), d.month, d.day,
    }) catch unreachable;
}

/// `time.Now().ISOWeek()` formatted as `YYYY-Www`, on the local calendar.
fn week(io: std.Io, buf: *[8]u8) []const u8 {
    const days = localDays(io);
    const weekday: i64 = @mod(days + 4, 7); // 1970-01-01 was a Thursday
    const monday_offset: i64 = if (weekday == 0) 6 else weekday - 1;
    const thursday = days - monday_offset + 3;
    const iso_year = timeutil.civilFromDays(thursday).year;
    const jan1 = daysFromCivil(iso_year, 1, 1);
    const w: u8 = @intCast(@divFloor(thursday - jan1, 7) + 1);
    return std.fmt.bufPrint(buf, "{d:0>4}-W{d:0>2}", .{ @as(u32, @intCast(iso_year)), w }) catch unreachable;
}

fn isRFC3339(s: []const u8) bool {
    var p: usize = 0;
    p = digits(s, p, 4) orelse return false;
    if (p >= s.len or s[p] != '-') return false;
    p = digits(s, p + 1, 2) orelse return false;
    if (p >= s.len or s[p] != '-') return false;
    p = digits(s, p + 1, 2) orelse return false;
    if (p >= s.len or (s[p] != 'T' and s[p] != 't')) return false;
    p = digits(s, p + 1, 2) orelse return false;
    if (p >= s.len or s[p] != ':') return false;
    p = digits(s, p + 1, 2) orelse return false;
    if (p >= s.len or s[p] != ':') return false;
    p = digits(s, p + 1, 2) orelse return false;
    if (p < s.len and s[p] == '.') {
        var q = p + 1;
        while (q < s.len and s[q] >= '0' and s[q] <= '9') q += 1;
        if (q == p + 1) return false;
        p = q;
    }
    if (p < s.len and (s[p] == 'Z' or s[p] == 'z')) return p + 1 == s.len;
    if (p >= s.len or (s[p] != '+' and s[p] != '-')) return false;
    p = digits(s, p + 1, 2) orelse return false;
    if (p >= s.len or s[p] != ':') return false;
    p = digits(s, p + 1, 2) orelse return false;
    return p == s.len;
}

fn digits(s: []const u8, i: usize, n: usize) ?usize {
    if (i + n > s.len) return null;
    for (0..n) |k| {
        if (s[i + k] < '0' or s[i + k] > '9') return null;
    }
    return i + n;
}

/// `^[A-Z]+-\d{8}-\d{3}$`
fn isEntityID(s: []const u8) bool {
    var i: usize = 0;
    const start = i;
    while (i < s.len and s[i] >= 'A' and s[i] <= 'Z') i += 1;
    if (i == start) return false;
    if (i >= s.len or s[i] != '-') return false;
    i = digits(s, i + 1, 8) orelse return false;
    if (i >= s.len or s[i] != '-') return false;
    i = digits(s, i + 1, 3) orelse return false;
    return i == s.len;
}

// --------------------------------------------------------------- mini test

const T = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    a: std.mem.Allocator,
    bin: []const u8,
    parent_env: *const std.process.Environ.Map,
    sys_tmp: []const u8,
    name: []const u8,

    fn fail(self: *T, comptime fmt: []const u8, args: anytype) anyerror {
        std.debug.print("v3 {s}: FAIL: ", .{self.name});
        std.debug.print(fmt, args);
        std.debug.print("\n", .{});
        return error.SubtestFailed;
    }

    fn newRunner(self: *T) !harness.Runner {
        return harness.Runner.init(self.io, self.gpa, self.a, self.bin, self.parent_env, self.sys_tmp);
    }

    /// A runner with an initialized database (v3New).
    fn newInit(self: *T) !harness.Runner {
        var r = try self.newRunner();
        errdefer r.deinit();
        _ = try v3OK(self, try r.run(&.{ "init", "--non-interactive", "--scope", "id=personal,kind=personal" }));
        return r;
    }

    /// Success path: release the env map and remove the throwaway tree.
    fn done(r: *harness.Runner) void {
        r.deinit();
        r.cleanup();
    }
};

const Envelope = struct {
    ok: bool,
    command: []const u8,
    data: ?std.json.Value,
    family: ?[]const u8,
    detail: ?[]const u8,
    raw: []const u8,
};

fn v3Env(t: *T, o: harness.Obs) !Envelope {
    const raw = o.raw orelse
        return t.fail("no JSON envelope on stdout (exit {d}, stderr {s})", .{ o.code, o.stderr_text });
    const parsed = std.json.parseFromSlice(std.json.Value, t.a, raw, .{}) catch |e|
        return t.fail("envelope is not valid JSON: {s}\n{s}", .{ @errorName(e), raw });
    if (parsed.value != .object) return t.fail("envelope is not an object:\n{s}", .{raw});
    const obj = parsed.value.object;
    var e: Envelope = .{
        .ok = false,
        .command = "",
        .data = null,
        .family = null,
        .detail = null,
        .raw = raw,
    };
    if (obj.get("ok")) |v| e.ok = if (v == .bool) v.bool else false;
    if (obj.get("command")) |v| {
        if (v == .string) e.command = v.string;
    }
    if (obj.get("error")) |v| {
        if (v == .object) {
            if (v.object.get("family")) |f| {
                if (f == .string) e.family = f.string;
            }
            if (v.object.get("detail")) |d| {
                if (d == .string) e.detail = d.string;
            }
        }
    }
    e.data = obj.get("data");
    return e;
}

/// Success envelope: exit 0, ok:true, command and data.
fn v3OK(t: *T, o: harness.Obs) !Envelope {
    const e = try v3Env(t, o);
    if (o.code != 0 or !e.ok)
        return t.fail("want success, got exit {d}: {s}", .{ o.code, o.raw orelse "" });
    if (e.command.len == 0 or e.data == null)
        return t.fail("success envelope lacks command or data: {s}", .{e.raw});
    return e;
}

/// Failure envelope: exit 1, ok:false and the error family.
fn v3Fail(t: *T, o: harness.Obs, family: []const u8) !Envelope {
    const e = try v3Env(t, o);
    if (o.code != 1 or e.ok)
        return t.fail("want failure exit 1 with family \"{s}\", got exit {d}: {s}", .{ family, o.code, o.raw orelse "" });
    if (e.family == null or !std.mem.eql(u8, e.family.?, family)) {
        const got = if (e.family) |f|
            try std.fmt.allocPrint(t.a, "{s}: {s}", .{ f, e.detail orelse "" })
        else
            "no error object";
        return t.fail("want error family \"{s}\", got {s}", .{ family, got });
    }
    return e;
}

fn v3Data(t: *T, e: Envelope) !std.json.ObjectMap {
    const d = e.data orelse return t.fail("envelope has no data: {s}", .{e.raw});
    if (d != .object) return t.fail("data is not an object:\n{s}", .{e.raw});
    return d.object;
}

fn v3DataArr(t: *T, e: Envelope) !std.json.Array {
    const d = e.data orelse return t.fail("envelope has no data: {s}", .{e.raw});
    if (d != .array) return t.fail("data is not an array:\n{s}", .{e.raw});
    return d.array;
}

fn keysOf(a: std.mem.Allocator, m: std.json.ObjectMap) ![]const []const u8 {
    const keys = try a.alloc([]const u8, m.count());
    var i: usize = 0;
    var it = m.iterator();
    while (it.next()) |e| : (i += 1) keys[i] = e.key_ptr.*;
    std.mem.sort([]const u8, keys, {}, harness.lessStr);
    return keys;
}

fn fmtKeys(a: std.mem.Allocator, m: std.json.ObjectMap) ![]const u8 {
    const keys = try keysOf(a, m);
    var out: std.ArrayList(u8) = .empty;
    try out.append(a, '[');
    for (keys, 0..) |k, i| {
        if (i > 0) try out.append(a, ' ');
        try out.appendSlice(a, k);
    }
    try out.append(a, ']');
    return out.toOwnedSlice(a);
}

fn v3Str(t: *T, m: std.json.ObjectMap, key: []const u8) ![]const u8 {
    const v = m.get(key) orelse
        return t.fail("missing field \"{s}\" in {s}", .{ key, try fmtKeys(t.a, m) });
    if (v != .string)
        return t.fail("field \"{s}\" is {s}, want string", .{ key, kindOf(v) });
    return v.string;
}

fn v3Num(t: *T, m: std.json.ObjectMap, key: []const u8) !f64 {
    const v = m.get(key) orelse
        return t.fail("missing field \"{s}\" in {s}", .{ key, try fmtKeys(t.a, m) });
    return switch (v) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        .number_string => |s| std.fmt.parseFloat(f64, s) catch
            return t.fail("field \"{s}\" is not a number: {s}", .{ key, s }),
        else => return t.fail("field \"{s}\" is {s}, want number", .{ key, kindOf(v) }),
    };
}

fn v3Obj(t: *T, m: std.json.ObjectMap, key: []const u8) !std.json.ObjectMap {
    const v = m.get(key) orelse
        return t.fail("missing field \"{s}\" in {s}", .{ key, try fmtKeys(t.a, m) });
    if (v != .object) return t.fail("field \"{s}\" is {s}, want object", .{ key, kindOf(v) });
    return v.object;
}

fn v3Arr(t: *T, m: std.json.ObjectMap, key: []const u8) !std.json.Array {
    const v = m.get(key) orelse
        return t.fail("missing field \"{s}\" in {s}", .{ key, try fmtKeys(t.a, m) });
    if (v != .array) return t.fail("field \"{s}\" is {s}, want array", .{ key, kindOf(v) });
    return v.array;
}

fn kindOf(v: std.json.Value) []const u8 {
    return switch (v) {
        .null => "null",
        .bool => "bool",
        .integer, .float, .number_string => "number",
        .string => "string",
        .array => "array",
        .object => "object",
    };
}

/// Exact key set of an object (v3Keys).
fn v3Keys(t: *T, m: std.json.ObjectMap, want: []const []const u8) !void {
    if (m.count() != want.len) {
        return t.fail("keys {s}, want {s}", .{ try fmtKeys(t.a, m), try fmtWantKeys(t.a, want) });
    }
    for (want) |k| {
        if (m.get(k) == null) {
            return t.fail("missing key \"{s}\" (got {s})", .{ k, try fmtKeys(t.a, m) });
        }
    }
}

fn fmtWantKeys(a: std.mem.Allocator, want: []const []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.append(a, '[');
    for (want, 0..) |k, i| {
        if (i > 0) try out.append(a, ' ');
        try out.appendSlice(a, k);
    }
    try out.append(a, ']');
    return out.toOwnedSlice(a);
}

fn v3RFC3339(t: *T, s: []const u8) !void {
    if (!isRFC3339(s)) return t.fail("timestamp \"{s}\" is not RFC3339", .{s});
}

/// Captures one entry and processes it into a work item (v3WorkItem).
fn v3WorkItem(t: *T, r: *harness.Runner, key: []const u8, title: []const u8) ![]const u8 {
    const text = try std.fmt.allocPrint(t.a, "input for {s}", .{title});
    const got = try v3OK(t, try r.run(&.{ "capture", "--key", key, text }));
    const cid = try v3Str(t, try v3Data(t, got), "id");
    const p = try v3OK(t, try r.run(&.{ "process", "--outcome", "work_items", "--title", title, cid }));
    const items = try v3Arr(t, try v3Data(t, p), "work_items");
    if (items.items.len == 0) return t.fail("process {s} produced no work item", .{cid});
    if (items.items[0] != .object) return t.fail("work item is {s}", .{kindOf(items.items[0])});
    return v3Str(t, items.items[0].object, "id");
}

fn v3HasEdge(edges: std.json.Array, relation: []const u8, from_type: []const u8, from_id: []const u8, to_type: []const u8, to_id: []const u8) bool {
    for (edges.items) |raw| {
        if (raw != .object) continue;
        const e = raw.object;
        const rel = e.get("relation") orelse continue;
        const ft = e.get("from_type") orelse continue;
        const fi = e.get("from_id") orelse continue;
        const tt = e.get("to_type") orelse continue;
        const ti = e.get("to_id") orelse continue;
        if (rel == .string and ft == .string and fi == .string and tt == .string and ti == .string and
            std.mem.eql(u8, rel.string, relation) and
            std.mem.eql(u8, ft.string, from_type) and
            std.mem.eql(u8, fi.string, from_id) and
            std.mem.eql(u8, tt.string, to_type) and
            std.mem.eql(u8, ti.string, to_id))
            return true;
    }
    return false;
}

fn dataLen(raw: []const u8) usize {
    const span = harness.topLevelValueSpan(raw, "data") orelse return 0;
    return span.len;
}

// ---------------------------------------------------------------- subtests

fn provenance(t: *T) !void {
    var r = try t.newInit();
    errdefer r.deinit();

    const c = try v3OK(t, try r.run(&.{ "capture", "--key", "v3-cap", "renew the parking permit" }));
    const cd = try v3Data(t, c);
    const cid = try v3Str(t, cd, "id");
    if (!isEntityID(cid)) return t.fail("capture id \"{s}\" does not match ^[A-Z]+-\\d{{8}}-\\d{{3}}$", .{cid});
    v3RFC3339(t, try v3Str(t, cd, "captured_at")) catch return error.SubtestFailed;

    const p = try v3OK(t, try r.run(&.{ "process", "--outcome", "work_items", "--title", "X", cid }));
    const items = try v3Arr(t, try v3Data(t, p), "work_items");
    if (items.items.len != 1) return t.fail("process produced {d} work items, want 1", .{items.items.len});
    if (items.items[0] != .object) return t.fail("work item is {s}", .{kindOf(items.items[0])});
    const tid = try v3Str(t, items.items[0].object, "id");
    if (!isEntityID(tid)) return t.fail("work item id \"{s}\" does not match ^[A-Z]+-\\d{{8}}-\\d{{3}}$", .{tid});

    const tr = try v3OK(t, try r.run(&.{ "trace", tid }));
    const td = try v3Data(t, tr);
    const kind = try v3Str(t, td, "kind");
    if (!std.mem.eql(u8, kind, "work_item")) return t.fail("trace kind \"{s}\", want work_item", .{kind});
    const edges = try v3Arr(t, td, "edges");
    if (!v3HasEdge(edges, "produced", "capture", cid, "work_item", tid))
        return t.fail("trace edges lack capture->work_item produced edge", .{});

    _ = try v3Fail(t, try r.run(&.{ "trace", "T-19990101-999" }), "not_found");
    T.done(&r);
}

fn preparePacket(t: *T) !void {
    var r = try t.newInit();
    errdefer r.deinit();

    var long_buf: std.ArrayList(u8) = .empty;
    for (0..30) |_| try long_buf.appendSlice(t.a, "long title ");
    const long_title = try long_buf.toOwnedSlice(t.a);
    _ = try v3WorkItem(t, &r, "p1", long_title);
    for (2..5) |i| {
        const title = try std.fmt.allocPrint(t.a, "errand number {d}", .{i});
        _ = try v3WorkItem(t, &r, try std.fmt.allocPrint(t.a, "p{d}", .{i}), title);
    }
    _ = try v3OK(t, try r.run(&.{ "capture", "--key", "p-pending", "still sitting in the inbox" }));

    var dbuf: [10]u8 = undefined;
    const date = today(t.io, &dbuf, 0);
    const pk = try v3OK(t, try r.run(&.{ "prepare", "--packet", "--date", date }));
    const pk_len = dataLen(pk.raw);
    if (pk_len > 1536) return t.fail("packet data is {d} bytes, want <= 1536", .{pk_len});
    const pd = try v3Data(t, pk);
    for ([_][]const u8{ "profile", "date", "candidates", "pending_captures", "waiting" }) |key| {
        if (pd.get(key) == null) return t.fail("packet lacks \"{s}\": {s}", .{ key, try dataText(t, pk) });
    }
    const got_date = try v3Str(t, pd, "date");
    if (!std.mem.eql(u8, got_date, date)) return t.fail("packet date \"{s}\", want \"{s}\"", .{ got_date, date });
    const cands = try v3Arr(t, pd, "candidates");
    if (cands.items.len == 0 or cands.items.len > 3) return t.fail("packet has {d} candidates, want 1..3", .{cands.items.len});
    for (cands.items) |raw| {
        if (raw != .object) continue;
        const title = try v3Str(t, raw.object, "title");
        if (title.len > 120) return t.fail("candidate title is {d} chars, want <= 120: \"{s}\"", .{ title.len, title });
    }
    const pending = try v3Num(t, pd, "pending_captures");
    if (pending < 1) return t.fail("pending_captures {d}, want >= 1", .{pending});
    if (pd.get("waiting") == null) return t.fail("packet lacks waiting: {s}", .{try dataText(t, pk)});

    const full = try v3OK(t, try r.run(&.{ "prepare", "--date", date }));
    const full_len = dataLen(full.raw);
    if (full_len <= pk_len) {
        return t.fail("packet ({d} bytes) is not smaller than the uncapped brief ({d} bytes)", .{ pk_len, full_len });
    }
    T.done(&r);
}

fn dataText(_: *T, e: Envelope) ![]const u8 {
    return e.raw;
}

const metric_keys = [_][]const u8{
    "captures_processed", "captures_received", "completed_items",
    "focus_minutes",      "focus_sessions",    "mit_completed",
    "mit_planned",        "overdue_routines",  "plan_items",
};

fn measurement(t: *T) !void {
    var r = try t.newInit();
    errdefer r.deinit();

    var dbuf: [10]u8 = undefined;
    const date = today(t.io, &dbuf, 0);

    // The writer must refuse exactly what `check` refuses, or a stored review
    // turns the database permanently red and blocks every later restore.
    _ = try v3Fail(t, try r.run(&.{ "review", "monthly", "--period", "2026-+1", "--outcomes", "x", "--coverage", "1" }), "invalid_input");
    _ = try v3Fail(t, try r.run(&.{ "review", "yearly", "--period", " 2026", "--outcomes", "x", "--coverage", "1" }), "invalid_input");
    const rev = try v3OK(t, try r.run(&.{ "review", "daily", "--period", date, "--outcomes", "shipped the release", "--coverage", "1", "--derive" }));
    const rd = try v3Data(t, rev);
    v3RFC3339(t, try v3Str(t, rd, "created_at")) catch return error.SubtestFailed;
    try v3Keys(t, try v3Obj(t, rd, "metrics"), &metric_keys);

    const show = try v3OK(t, try r.run(&.{ "review", "show", "--period", date }));
    const sd = try v3Data(t, show);
    try v3Keys(t, sd, &.{ "id", "kind", "period", "metrics" });
    const id = try v3Str(t, sd, "id");
    if (!isEntityID(id)) return t.fail("review id \"{s}\" does not match ^[A-Z]+-\\d{{8}}-\\d{{3}}$", .{id});
    const kind = try v3Str(t, sd, "kind");
    if (!std.mem.eql(u8, kind, "daily")) return t.fail("review kind \"{s}\", want daily", .{kind});
    const period = try v3Str(t, sd, "period");
    if (!std.mem.eql(u8, period, date)) return t.fail("review period \"{s}\", want \"{s}\"", .{ period, date });
    try v3Keys(t, try v3Obj(t, sd, "metrics"), &metric_keys);

    _ = try v3Fail(t, try r.run(&.{ "review", "show", "--period", "1999-01-01" }), "not_found");
    T.done(&r);
}

fn overrides(t: *T) !void {
    var r = try t.newInit();
    errdefer r.deinit();

    var dbuf: [10]u8 = undefined;
    const date = today(t.io, &dbuf, 0);

    const ov = try v3OK(t, try r.run(&.{ "override", "add", "--rule", "mit", "--date", date, "--reason", "travel day" }));
    const od = try v3Data(t, ov);
    const want = try std.fmt.allocPrint(t.a, "override:{s}:mit:{s}", .{ try v3Str(t, od, "actor"), date });
    const id = try v3Str(t, od, "id");
    if (!std.mem.eql(u8, id, want)) return t.fail("override id \"{s}\", want \"{s}\"", .{ id, want });
    const local_date = try v3Str(t, od, "local_date");
    if (!std.mem.eql(u8, local_date, date)) return t.fail("override local_date \"{s}\", want \"{s}\"", .{ local_date, date });
    v3RFC3339(t, try v3Str(t, od, "created_at")) catch return error.SubtestFailed;

    _ = try v3Fail(t, try r.run(&.{ "override", "add", "--rule", "bogus", "--date", date, "--reason", "r" }), "invalid_input");

    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(t.a);
    try args.appendSlice(t.a, &.{ "plan", "commit", "--period", date });
    var first: []const u8 = "";
    for (1..5) |i| {
        const title = try std.fmt.allocPrint(t.a, "errand number {d}", .{i});
        const item = try v3WorkItem(t, &r, try std.fmt.allocPrint(t.a, "o{d}", .{i}), title);
        if (i == 1) first = item;
        const item_mit = try std.fmt.allocPrint(t.a, "{s}:mit", .{item});
        try args.appendSlice(t.a, &.{ "--item", item_mit });
    }
    _ = try v3OK(t, try r.run(args.items));

    var wbuf: [8]u8 = undefined;
    const w = week(t.io, &wbuf);
    _ = try v3Fail(t, try r.run(&.{ "plan", "commit", "--kind", "weekly", "--period", w, "--override", want, "--item", (try std.fmt.allocPrint(t.a, "{s}:mit", .{first})) }), "invalid_input");
    T.done(&r);
}

fn calendarAssertion(t: *T) !void {
    var r = try t.newInit();
    errdefer r.deinit();

    var b1: [10]u8 = undefined;
    var b2: [10]u8 = undefined;
    const d1 = today(t.io, &b1, 0);
    const d2 = today(t.io, &b2, -1);

    const first = try v3OK(t, try r.run(&.{ "review", "daily", "--period", d1, "--outcomes", "shipped it", "--coverage", "1", "--calendar-assert", "the release went out" }));
    const id1 = try v3Str(t, try v3Data(t, first), "id");
    if (!isEntityID(id1)) return t.fail("review id \"{s}\" does not match ^[A-Z]+-\\d{{8}}-\\d{{3}}$", .{id1});

    const clean = try v3OK(t, try r.run(&.{ "check", "--scope", "personal" }));
    const clean_data = try v3Data(t, clean);
    if (!truthy(clean_data.get("ok"))) return t.fail("check data.ok = {s}, want true (raw {s})", .{ kindOfOpt(clean_data.get("ok")), clean.raw });

    const second = try v3OK(t, try r.run(&.{ "review", "daily", "--period", d2, "--outcomes", "kept the lights on", "--coverage", "1" }));
    const id2 = try v3Str(t, try v3Data(t, second), "id");

    const bad = try r.run(&.{ "check", "--scope", "personal" });
    if (bad.code != 0) return t.fail("check exit {d}, want 0: {s}", .{ bad.code, bad.raw orelse "" });
    const be = try v3Env(t, bad);
    const bd = try v3Data(t, be);
    if (truthy(bd.get("ok"))) return t.fail("check data.ok = {s}, want false (raw {s})", .{ kindOfOpt(bd.get("ok")), be.raw });
    const want = try std.fmt.allocPrint(t.a, "daily review {s} has no calendar assertion", .{id2});
    const errs = try v3Arr(t, bd, "errors");
    var found = false;
    for (errs.items) |raw| {
        if (raw == .string and std.mem.eql(u8, raw.string, want)) found = true;
    }
    if (!found) return t.fail("check errors lack \"{s}\": {s}", .{ want, try fmtKeys(t.a, bd) });
    T.done(&r);
}

fn truthy(v: ?std.json.Value) bool {
    const x = v orelse return false;
    return switch (x) {
        .bool => |b| b,
        else => false,
    };
}

fn kindOfOpt(v: ?std.json.Value) []const u8 {
    const x = v orelse return "missing";
    return kindOf(x);
}

fn decisions(t: *T) !void {
    var r = try t.newInit();
    errdefer r.deinit();

    const tid = try v3WorkItem(t, &r, "d1", "decide the migration path");
    const body = "Body of one covers the migration decision";

    const put = try v3OK(t, try r.run(&.{ "doc", "put", "--kind", "knowledge", "--slug", "d/one", "--body", body, "--record-kind", "decision", "--rationale", "the evidence points here", "--evidence", tid }));
    const pd = try v3Data(t, put);
    const rk = try v3Str(t, pd, "record_kind");
    if (!std.mem.eql(u8, rk, "decision")) return t.fail("record_kind \"{s}\", want decision", .{rk});
    if ((try v3Num(t, pd, "revision")) != 1) return t.fail("revision {d}, want 1", .{try v3Num(t, pd, "revision")});
    v3RFC3339(t, try v3Str(t, pd, "created_at")) catch return error.SubtestFailed;
    const docID = try v3Str(t, pd, "id");

    var verifying: std.ArrayList([]const u8) = .empty;
    defer verifying.deinit(t.a);
    try verifying.appendSlice(t.a, &.{ "doc", "put", "--kind", "knowledge", "--slug", "d/one", "--body", body, "--record-kind", "decision", "--rationale", "r", "--status", "verified", "--expected", "1" });
    _ = try v3Fail(t, try r.run(verifying.items), "invalid_input");
    try verifying.appendSlice(t.a, &.{ "--approved-by", "alice" });
    const verified = try v3OK(t, try r.run(verifying.items));
    const status = try v3Str(t, try v3Data(t, verified), "status");
    if (!std.mem.eql(u8, status, "verified")) return t.fail("status \"{s}\", want verified", .{status});

    const hits = try v3DataArr(t, try v3OK(t, try r.run(&.{ "doc", "search", "--query", body, "--record-kind", "decision" })));
    var found = false;
    for (hits.items) |raw| {
        if (raw != .object) continue;
        const doc = raw.object.get("document") orelse continue;
        if (doc != .object) continue;
        const id = doc.object.get("id") orelse continue;
        if (id == .string and std.mem.eql(u8, id.string, docID)) found = true;
    }
    if (!found) return t.fail("doc search does not contain {s}", .{docID});

    _ = try v3Fail(t, try r.run(&.{ "doc", "search", "--query", body, "--record-kind", "bogus" }), "invalid_input");

    _ = try v3OK(t, try r.run(&.{ "doc", "put", "--kind", "knowledge", "--slug", "d/two", "--body", "Body of two", "--record-kind", "decision", "--rationale", "second opinion" }));
    const sup = try v3OK(t, try r.run(&.{ "doc", "supersede", "d/one", "d/two" }));
    const supersedes_id = try v3Str(t, try v3Data(t, sup), "supersedes_id");
    if (!std.mem.eql(u8, supersedes_id, docID)) return t.fail("supersedes_id \"{s}\", want \"{s}\"", .{ supersedes_id, docID });

    const old = try v3Data(t, try v3OK(t, try r.run(&.{ "doc", "get", "--kind", "knowledge", "--slug", "d/one" })));
    const old_status = try v3Str(t, old, "status");
    if (!std.mem.eql(u8, old_status, "superseded")) return t.fail("old doc status \"{s}\", want superseded", .{old_status});

    _ = try v3Fail(t, try r.run(&.{ "doc", "supersede", "d/two", "d/two" }), "invalid_input");
    T.done(&r);
}

fn learn(t: *T) !void {
    var r = try t.newInit();
    errdefer r.deinit();

    var dbuf: [10]u8 = undefined;
    const date = today(t.io, &dbuf, 0);
    const rev = try v3OK(t, try r.run(&.{ "review", "daily", "--period", date, "--outcomes", "ran the retrospective", "--coverage", "1" }));
    const rid = try v3Str(t, try v3Data(t, rev), "id");
    const lesson = "Always pin the toolchain before the build";

    const propose_args = [_][]const u8{ "learn", "propose", "--review", rid, "--slug", "lessons/x", "--body", lesson };
    const p1 = try v3Data(t, try v3OK(t, try r.run(&propose_args)));
    const status = try v3Str(t, p1, "status");
    if (!std.mem.eql(u8, status, "draft")) return t.fail("learned document status \"{s}\", want draft", .{status});
    const kind = try v3Str(t, p1, "kind");
    if (!std.mem.eql(u8, kind, "knowledge")) return t.fail("learned document kind \"{s}\", want knowledge", .{kind});
    if ((try v3Num(t, p1, "revision")) != 1) return t.fail("revision {d}, want 1", .{try v3Num(t, p1, "revision")});
    const docID = try v3Str(t, p1, "id");

    const td = try v3Data(t, try v3OK(t, try r.run(&.{ "trace", rid })));
    const edges = try v3Arr(t, td, "edges");
    if (!v3HasEdge(edges, "learned", "review", rid, "document", docID))
        return t.fail("trace {s} edges lack review->document learned edge", .{rid});

    const p2 = try v3Data(t, try v3OK(t, try r.run(&propose_args)));
    if ((try v3Num(t, p2, "revision")) != 1) return t.fail("re-running learn propose raised the revision to {d}, want 1", .{try v3Num(t, p2, "revision")});

    _ = try v3OK(t, try r.run(&.{ "doc", "put", "--kind", "knowledge", "--slug", "lessons/x", "--body", lesson, "--status", "verified", "--expected", "1", "--approved-by", "alice" }));
    _ = try v3Fail(t, try r.run(&propose_args), "invalid_transition");
    T.done(&r);
}

fn tokenCaps(t: *T) !void {
    var r = try t.newInit();
    errdefer r.deinit();

    const long_text = try t.a.alloc(u8, 5000);
    @memset(long_text, 'z');
    _ = try v3OK(t, try r.run(&.{ "capture", "--key", "v3-long", long_text }));

    const inbox = try v3OK(t, try r.run(&.{ "inbox", "next" }));
    const inbox_len = dataLen(inbox.raw);
    if (inbox_len > 1024) return t.fail("inbox next data is {d} bytes, want <= 1024", .{inbox_len});
    const ind = try v3Data(t, inbox);
    const text = try v3Str(t, ind, "original_text");
    if (text.len > 280) return t.fail("inbox next original_text is {d} chars, want <= 280", .{text.len});
    if (!truthy(ind.get("truncated"))) return t.fail("inbox next truncated = {s}, want true (raw {s})", .{ kindOfOpt(ind.get("truncated")), inbox.raw });

    for (1..11) |i| {
        const body = try std.fmt.allocPrint(t.a, "matchable haystack body number {d} with filler words so that ten results comfortably exceed the two kilobyte cap", .{i});
        _ = try v3OK(t, try r.run(&.{
            "doc",                                        "put",     "--kind",                                     "knowledge", "--slug",
            try std.fmt.allocPrint(t.a, "cap/{d}", .{i}), "--title", try std.fmt.allocPrint(t.a, "Doc {d}", .{i}), "--body",    body,
        }));
    }
    const ds = try v3OK(t, try r.run(&.{ "doc", "search", "--query", "matchable" }));
    const ds_len = dataLen(ds.raw);
    if (ds_len > 2048) return t.fail("doc search data is {d} bytes, want <= 2048", .{ds_len});
    const hits = try v3DataArr(t, ds);
    if (hits.items.len == 0) return t.fail("doc search returned no hits for \"matchable\"", .{});

    _ = try v3OK(t, try r.run(&.{ "source", "add", "--id", "feed", "--name", "Feed", "--scope", "personal", "--kind", "capture", "--connector", "manual" }));
    var items: std.ArrayList([]const u8) = .empty;
    defer items.deinit(t.a);
    for (1..21) |i| {
        const item = try std.fmt.allocPrint(
            t.a,
            "{{\"external_id\":\"note-{d:0>3}\",\"external_revision\":\"1\",\"original_text\":\"incoming note {d} long enough to push the review output over the cap\",\"source_uri\":\"file:///notes/note-{d:0>3}.md\"}}",
            .{ i, i, i },
        );
        try items.append(t.a, item);
    }
    var joined: std.ArrayList(u8) = .empty;
    for (items.items, 0..) |item, i| {
        if (i > 0) try joined.append(t.a, ',');
        try joined.appendSlice(t.a, item);
    }
    var dbuf: [10]u8 = undefined;
    const date = today(t.io, &dbuf, 0);
    const batch = try std.fmt.allocPrint(
        t.a,
        "{{\"batch_id\":\"b1\",\"idempotency_key\":\"r1\",\"result_kind\":\"reported\",\"retrieval\":{{\"window\":\"{s}\",\"cursor\":\"\",\"requested_limit\":50,\"provider_returned_limit\":20,\"complete_window\":true,\"truncated\":false,\"failures\":[]}},\"items\":[{s}]}}",
        .{ date, joined.items },
    );
    const file = try r.write("batch20.json", batch);

    const sr = try v3OK(t, try r.run(&.{ "source", "review", "--source", "feed", "--batch", "b1", "--key", "r1", "--file", file }));
    const sr_len = dataLen(sr.raw);
    if (sr_len > 1024) return t.fail("source review data is {d} bytes, want <= 1024", .{sr_len});
    const review = try v3Obj(t, try v3Data(t, sr), "review");
    if (!truthy(review.get("truncated"))) return t.fail("source review truncated = {s}, want true (raw {s})", .{ kindOfOpt(review.get("truncated")), sr.raw });
    const omitted = try v3Num(t, review, "omitted");
    if (omitted <= 0) return t.fail("source review omitted {d}, want > 0", .{omitted});

    const full = try v3OK(t, try r.run(&.{ "source", "review", "--source", "feed", "--batch", "b1", "--key", "r1", "--file", file, "--full" }));
    const caps = try v3Arr(t, try v3Data(t, full), "captures");
    if (caps.items.len != 20) return t.fail("--full returned {d} captures, want all 20", .{caps.items.len});
    T.done(&r);
}

fn directoryConnector(t: *T) !void {
    var r = try t.newInit();
    errdefer r.deinit();

    const tree = try r.path("tree");
    harness.mkdirs(t.io, tree) catch |e| return t.fail("mkdir {s}: {s}", .{ tree, @errorName(e) });
    try std.Io.Dir.cwd().writeFile(t.io, .{ .sub_path = try std.fmt.allocPrint(t.a, "{s}/a.md", .{tree}), .data = "alpha note\n" });
    try std.Io.Dir.cwd().writeFile(t.io, .{ .sub_path = try std.fmt.allocPrint(t.a, "{s}/b.md", .{tree}), .data = "beta note\n" });
    // A text file whose 64 KiB cut lands inside a character must still be a
    // capture: the tail is trimmed before the UTF-8 check, not after.
    var straddle: std.ArrayList(u8) = .empty;
    try straddle.appendNTimes(t.a, 'a', 65535);
    try straddle.appendSlice(t.a, "é tail\n");
    try std.Io.Dir.cwd().writeFile(t.io, .{ .sub_path = try std.fmt.allocPrint(t.a, "{s}/c.md", .{tree}), .data = straddle.items });
    // A binary whose header is valid ASCII must be skipped, never captured as
    // truncated text: only the incomplete tail of the cut may be trimmed.
    var blob: std.ArrayList(u8) = .empty;
    try blob.appendSlice(t.a, "%PDF-1.4\n");
    try blob.appendNTimes(t.a, 'a', 65000);
    try blob.appendSlice(t.a, &.{ 0x80, 0x81, 0xff });
    try blob.appendNTimes(t.a, 'b', 2000);
    try std.Io.Dir.cwd().writeFile(t.io, .{ .sub_path = try std.fmt.allocPrint(t.a, "{s}/bin.pdf", .{tree}), .data = blob.items });
    const outside = try r.path("outside.md");
    try std.Io.Dir.cwd().writeFile(t.io, .{ .sub_path = outside, .data = "outside note\n" });

    var ref_buf: std.ArrayList(u8) = .empty;
    try ref_buf.append(t.a, '[');
    try harness.writeJsonString(&ref_buf, t.a, tree);
    try ref_buf.append(t.a, ']');
    const conn_ref = ref_buf.items;

    const add = try v3OK(t, try r.run(&.{ "source", "add", "--id", "dir1", "--name", "D", "--scope", "personal", "--kind", "capture", "--connector", "directory", "--connection-ref", conn_ref }));
    const connector = try v3Str(t, try v3Data(t, add), "connector");
    if (!std.mem.eql(u8, connector, "directory")) return t.fail("connector \"{s}\", want directory", .{connector});

    // The first scan must ask for the full view: the default rendering caps
    // at 1024 bytes and would only show the first capture of the two.
    const scan1 = try v3Data(t, try v3OK(t, try r.run(&.{ "source", "scan", "--id", "dir1", "--full" })));
    const caps1 = try v3Arr(t, scan1, "captures");
    if (caps1.items.len != 3) return t.fail("first scan observed {d} captures, want 3", .{caps1.items.len});
    const rev1 = try v3Obj(t, scan1, "review");
    const kind1 = try v3Str(t, rev1, "result_kind");
    if (!std.mem.eql(u8, kind1, "observed")) return t.fail("result_kind \"{s}\", want observed", .{kind1});
    const cov1 = try v3Str(t, rev1, "coverage");
    if (!std.mem.eql(u8, cov1, "complete")) return t.fail("coverage \"{s}\", want complete", .{cov1});
    const cursor1 = try v3Str(t, try v3Obj(t, rev1, "retrieval"), "cursor");
    if (cursor1.len == 0) return t.fail("scan cursor is empty", .{});
    v3RFC3339(t, cursor1) catch return error.SubtestFailed;
    const skipped1 = try v3Num(t, try v3Obj(t, rev1, "retrieval"), "skipped");
    if (skipped1 != 1) return t.fail("skipped {d}, want 1 (the binary file)", .{skipped1});

    const scan2 = try v3Data(t, try v3OK(t, try r.run(&.{ "source", "scan", "--id", "dir1" })));
    const caps2 = try v3Arr(t, scan2, "captures");
    if (caps2.items.len != 0) return t.fail("rescan reported {d} new captures, want 0", .{caps2.items.len});
    const rev2 = try v3Obj(t, scan2, "review");
    const cov2 = try v3Str(t, rev2, "coverage");
    if (!std.mem.eql(u8, cov2, "complete")) return t.fail("rescan coverage \"{s}\", want complete", .{cov2});

    const link_path = try std.fmt.allocPrint(t.a, "{s}/link.md", .{tree});
    std.Io.Dir.cwd().symLink(t.io, outside, link_path, .{}) catch |e|
        return t.fail("symlink: {s}", .{@errorName(e)});

    const scan3 = try v3Data(t, try v3OK(t, try r.run(&.{ "source", "scan", "--id", "dir1" })));
    const rev3 = try v3Obj(t, scan3, "review");
    const cov3 = try v3Str(t, rev3, "coverage");
    if (!std.mem.eql(u8, cov3, "partial")) return t.fail("escaping symlink coverage \"{s}\", want partial", .{cov3});
    const retr3 = try v3Obj(t, rev3, "retrieval");
    const failures = try v3Arr(t, retr3, "failures");
    if (failures.items.len == 0) return t.fail("escaping symlink produced no failure", .{});
    const msg = if (failures.items[0] == .string) failures.items[0].string else "";
    if (std.mem.indexOf(u8, msg, "resolves outside root") == null)
        return t.fail("failure \"{s}\" does not mention the escaped root", .{msg});
    const cursor3 = try v3Str(t, retr3, "cursor");
    if (!std.mem.eql(u8, cursor3, cursor1))
        return t.fail("cursor advanced from {s} to {s} after a partial scan", .{ cursor1, cursor3 });

    _ = try v3Fail(t, try r.run(&.{ "source", "add", "--id", "dir2", "--name", "D2", "--scope", "personal", "--kind", "capture", "--connector", "directory", "--connection-ref", "[\"relative/dir\"]" }), "invalid_input");
    T.done(&r);
}

fn exportV2(t: *T) !void {
    var r = try t.newInit();
    errdefer r.deinit();

    _ = try v3OK(t, try r.run(&.{ "capture", "--key", "x1", "exported capture" }));
    _ = try v3OK(t, try r.run(&.{ "doc", "put", "--kind", "knowledge", "--slug", "e/one", "--body", "portable body" }));

    const out = try r.path("export.json");
    const ex = try v3OK(t, try r.run(&.{ "export", "--out", out }));
    const p = try v3Str(t, try v3Data(t, ex), "path");
    if (!std.mem.eql(u8, p, out)) return t.fail("export path \"{s}\", want \"{s}\"", .{ p, out });
    const raw = std.Io.Dir.cwd().readFileAlloc(t.io, out, t.a, .limited(1 << 28)) catch |e|
        return t.fail("read export: {s}", .{@errorName(e)});
    const parsed = std.json.parseFromSlice(std.json.Value, t.a, raw, .{}) catch |e|
        return t.fail("export is not valid JSON: {s}", .{@errorName(e)});
    if (parsed.value != .object) return t.fail("export is not an object", .{});
    const exp = parsed.value.object;
    const format = exp.get("format") orelse return t.fail("export lacks format", .{});
    if (format != .string) return t.fail("export format is not a string", .{});
    if (!std.mem.eql(u8, format.string, "ztd-export"))
        return t.fail("export format \"{s}\", want ztd-export", .{format.string});
    const version = exp.get("version") orelse return t.fail("export lacks version", .{});
    const version_n = switch (version) {
        .integer => |i| i,
        else => return t.fail("export version is not a number", .{}),
    };
    if (version_n != 2) return t.fail("export version {d}, want 2", .{version_n});
    const tables = try v3Obj(t, exp, "tables");
    if (tables.get("links") == null) return t.fail("export lacks a links table", .{});
    if (tables.get("knowledge_records") != null) return t.fail("v2 export still carries knowledge_records", .{});
    const captures = tables.get("captures") orelse return t.fail("export lacks captures", .{});
    if (captures != .array) return t.fail("captures table is not an array", .{});
    const want_captures: f64 = @floatFromInt(captures.array.items.len);

    var restore = try t.newRunner();
    errdefer restore.deinit();
    const rd = try v3Data(t, try v3OK(t, try restore.run(&.{ "restore", "--from", out })));
    const rt = try v3Obj(t, rd, "tables");
    const got = try v3Num(t, rt, "captures");
    if (got != want_captures) return t.fail("restore counted {d} captures, want {d}", .{ got, want_captures });
    if (rt.get("links") == null) return t.fail("restore report lacks links", .{});

    // A version 1 export: same tables minus links, plus knowledge_records.
    var v1_tables = std.json.ObjectMap.empty;
    var it = tables.iterator();
    while (it.next()) |entry| {
        if (std.mem.eql(u8, entry.key_ptr.*, "links")) continue;
        try v1_tables.put(t.a, entry.key_ptr.*, entry.value_ptr.*);
    }
    try v1_tables.put(t.a, "knowledge_records", .{ .array = std.json.Array.init(t.a) });
    var v1_body = std.json.ObjectMap.empty;
    try v1_body.put(t.a, "format", .{ .string = "ztd-export" });
    try v1_body.put(t.a, "version", .{ .integer = 1 });
    try v1_body.put(t.a, "tables", .{ .object = v1_tables });
    var v1_text: std.ArrayList(u8) = .empty;
    try harness.writeJsonValue(&v1_text, t.a, .{ .object = v1_body }, 0);
    const v1_path = try r.write("export_v1.json", v1_text.items);

    var v1_restore = try t.newRunner();
    errdefer v1_restore.deinit();
    const v1_data = try v3Data(t, try v3OK(t, try v1_restore.run(&.{ "restore", "--from", v1_path })));
    const v1_tables_out = try v3Obj(t, v1_data, "tables");
    const v1_got = try v3Num(t, v1_tables_out, "captures");
    if (v1_got != want_captures) return t.fail("v1 restore counted {d} captures, want {d}", .{ v1_got, want_captures });

    T.done(&v1_restore);
    T.done(&restore);
    T.done(&r);
}

// ------------------------------------------------------------------ driver

const Sub = struct {
    name: []const u8,
    f: *const fn (*T) anyerror!void,
};

const subtests = [_]Sub{
    .{ .name = "provenance", .f = provenance },
    .{ .name = "prepare_packet", .f = preparePacket },
    .{ .name = "measurement", .f = measurement },
    .{ .name = "overrides", .f = overrides },
    .{ .name = "calendar_assertion", .f = calendarAssertion },
    .{ .name = "decisions", .f = decisions },
    .{ .name = "learn", .f = learn },
    .{ .name = "token_caps", .f = tokenCaps },
    .{ .name = "directory_connector", .f = directoryConnector },
    .{ .name = "export_v2", .f = exportV2 },
};

/// Runs every v3 subtest; returns how many failed (0 on success).
pub fn run(
    io: std.Io,
    gpa: std.mem.Allocator,
    a: std.mem.Allocator,
    bin: []const u8,
    parent_env: *const std.process.Environ.Map,
    sys_tmp: []const u8,
) usize {
    var failed: usize = 0;
    for (subtests) |sub| {
        var t = T{
            .io = io,
            .gpa = gpa,
            .a = a,
            .bin = bin,
            .parent_env = parent_env,
            .sys_tmp = sys_tmp,
            .name = sub.name,
        };
        sub.f(&t) catch |e| {
            if (e != error.SubtestFailed) {
                std.debug.print("v3 {s}: FAIL: {s}\n", .{ sub.name, @errorName(e) });
            }
            failed += 1;
            continue;
        };
        std.debug.print("v3 {s}: ok\n", .{sub.name});
    }
    if (failed == 0) {
        std.debug.print("v3: {d}/{d} subtests ok ({s})\n", .{ subtests.len, subtests.len, subtestNames() });
    } else {
        std.debug.print("v3: {d} of {d} subtests failed\n", .{ failed, subtests.len });
    }
    return failed;
}

fn subtestNames() []const u8 {
    return "provenance, prepare_packet, measurement, overrides, calendar_assertion, decisions, learn, token_caps, directory_connector, export_v2";
}
