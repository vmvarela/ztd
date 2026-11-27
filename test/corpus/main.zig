//! Golden record/replay for the CLI conformance corpus: a straight port of
//! corpus_test.go's TestJourney/TestErrors plus the v3 suite. The checked-in
//! goldens under test/corpus/golden are the oracle; ZTD_UPDATE=1 re-records
//! them instead of comparing.

const std = @import("std");
const process = std.process;
const harness = @import("harness.zig");
const dbdump = @import("dbdump.zig");
const v3 = @import("v3.zig");

const golden_dir = "test/corpus/golden";

pub fn main(init: process.Init) !void {
    const io = init.io;
    const a = init.arena.allocator();
    const gpa = init.gpa;
    const args = try init.minimal.args.toSlice(a);
    const env = init.environ_map;

    const update = std.mem.eql(u8, env.get("ZTD_UPDATE") orelse "", "1");
    const sys_tmp = env.get("TMPDIR") orelse "/tmp";
    const bin = resolveBin(io, gpa, a, args, env) orelse std.process.exit(1);

    var failed: usize = 0;
    var steps_done: usize = 0;
    var tables_done: usize = 0;

    if (runSuite(io, gpa, a, bin, env, sys_tmp, update, "journey", journeySteps)) |rep| {
        steps_done += rep.steps;
        tables_done += rep.tables;
    } else |_| {
        failed += 1;
    }
    if (runSuite(io, gpa, a, bin, env, sys_tmp, update, "errors", errorSteps)) |rep| {
        steps_done += rep.steps;
        tables_done += rep.tables;
    } else |_| {
        failed += 1;
    }

    const v3_failed = v3.run(io, gpa, a, bin, env, sys_tmp);
    failed += v3_failed;

    if (failed == 0) {
        std.debug.print(
            "corpus: PASS — {d} steps compared, {d} db tables compared, 10 v3 subtests\n",
            .{ steps_done, tables_done },
        );
        std.process.exit(0);
    } else {
        std.debug.print("corpus: FAIL — {d} suite(s) failed\n", .{failed});
        std.process.exit(1);
    }
}

/// argv[1] from the build, then ZTD_BIN, then the installed Zig build — the
/// same fallbacks as TestMain.
fn resolveBin(io: std.Io, gpa: std.mem.Allocator, a: std.mem.Allocator, args: []const [:0]const u8, env: *const process.Environ.Map) ?[]const u8 {
    const ztd_bin = env.get("ZTD_BIN") orelse "";
    const explicit = args.len > 1 or ztd_bin.len > 0;
    const raw: []const u8 = if (args.len > 1)
        args[1]
    else if (ztd_bin.len > 0)
        ztd_bin
    else
        "./zig-out/bin/ztd";
    const abs = if (raw.len > 0 and raw[0] == '/')
        a.dupe(u8, raw) catch return null
    else blk: {
        const cwd = process.currentPathAlloc(io, gpa) catch return null;
        defer gpa.free(cwd);
        break :blk std.fmt.allocPrint(a, "{s}/{s}", .{ cwd, std.mem.trim(u8, raw, "/") }) catch return null;
    };
    if (fileExists(io, abs)) return abs;
    if (explicit) {
        std.debug.print("ZTD_BIN: product binary not found: {s}\n", .{abs});
    } else {
        std.debug.print("ZTD_BIN: set it or run `zig build --release=fast` first: {s}\n", .{abs});
    }
    return null;
}

fn fileExists(io: std.Io, path: []const u8) bool {
    _ = std.Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return true;
}

const Report = struct { steps: usize, tables: usize };

const StepFn = fn (r: *harness.Runner) anyerror!void;

fn runSuite(
    io: std.Io,
    gpa: std.mem.Allocator,
    a: std.mem.Allocator,
    bin: []const u8,
    env: *const process.Environ.Map,
    sys_tmp: []const u8,
    update: bool,
    name: []const u8,
    step_fn: StepFn,
) anyerror!Report {
    var r = try harness.Runner.init(io, gpa, a, bin, env, sys_tmp);
    defer r.deinit();
    step_fn(&r) catch |e| {
        // Keep the throwaway tree for inspection when a step blows up.
        std.debug.print("{s}: aborted: {s}\n", .{ name, @errorName(e) });
        return e;
    };
    const rep = finish(&r, io, a, name, update) catch |e| {
        std.debug.print("{s}: aborted: {s}\n", .{ name, @errorName(e) });
        return e;
    };
    r.cleanup();
    return rep;
}

// ------------------------------------------------------------------ journeys

const batch_json =
    \\{
    \\  "batch_id": "b1",
    \\  "idempotency_key": "r1",
    \\  "result_kind": "reported",
    \\  "retrieval": {"window": "2026-11-20", "cursor": "", "requested_limit": 50, "provider_returned_limit": 1, "complete_window": true, "truncated": false, "failures": []},
    \\  "items": [{"external_id": "note-001", "external_revision": "1", "original_text": "renew the parking permit before the trip", "source_uri": "file:///notes/note-001.md"}]
    \\}
;

/// TestJourney: capture, all five process outcomes, planning, focus, review,
/// knowledge and sources — 37 invocations.
fn journeySteps(r: *harness.Runner) anyerror!void {
    const a = r.a;
    _ = try r.run(&.{ "init", "--non-interactive", "--scope", "id=personal,kind=personal" });
    _ = try r.run(&.{"status"});

    const permit = (try r.run(&.{ "capture", "--key", "cap-1", "renew the parking permit" })).id(a);
    const notes = (try r.run(&.{ "capture", "--key", "cap-2", "read the architecture notes" })).id(a);
    const bank = (try r.run(&.{ "capture", "--key", "cap-3", "call the bank" })).id(a);
    const sail = (try r.run(&.{ "capture", "--key", "cap-4", "learn to sail" })).id(a);
    const invoice = (try r.run(&.{ "capture", "--key", "cap-5", "delegate the invoice" })).id(a);
    _ = try r.run(&.{ "list", "--list", "inbox" });

    const item_path = [_][]const u8{ "data", "work_items", "0", "id" };
    const item = (try r.run(&.{ "process", "--outcome", "work_items", "--title", "Renew permit", "--waiting-on", "DMV", permit })).value(a, &item_path);
    _ = try r.run(&.{ "process", "--outcome", "reference", "--reason", "docs/architecture", notes });
    _ = try r.run(&.{ "process", "--outcome", "immediate", "--evidence", "paid online", bank });
    _ = try r.run(&.{ "process", "--outcome", "discard", "--reason", "duplicate", sail });
    _ = try r.run(&.{ "process", "--outcome", "defer", "--review-after", "2026-12-01", invoice });

    _ = try r.run(&.{ "find", "permit" });
    _ = try r.run(&.{ "show", item });
    _ = try r.run(&.{ "move", "--field", "energy:low", item, "next" });
    _ = try r.run(&.{ "goal", "set", "--statement", "Ship ztd v3" });
    _ = try r.run(&.{"prepare"});
    const item_mit = try std.fmt.allocPrint(a, "{s}:mit", .{item});
    _ = try r.run(&.{ "plan", "commit", "--period", "2026-W48", "--item", item_mit });

    const focus_path = [_][]const u8{ "data", "focus", "id" };
    const focus = (try r.run(&.{ "focus", "start", item })).value(a, &focus_path);
    _ = try r.run(&.{ "focus", "checkpoint", "--result", "permit renewed", item });
    _ = try r.run(&.{ "focus", "finish", focus });
    _ = try r.run(&.{ "review", "daily", "--period", "2026-W48", "--outcomes", "1 completed", "--coverage", "0.5" });

    _ = try r.run(&.{ "doc", "put", "--kind", "knowledge", "--slug", "notes/architecture", "--title", "Architecture", "--body", "One binary over SQLite." });
    _ = try r.run(&.{ "doc", "get", "--kind", "knowledge", "--slug", "notes/architecture" });
    _ = try r.run(&.{ "doc", "search", "--query", "SQLite" });
    _ = try r.run(&.{ "doc", "related", "--kind", "knowledge", "--slug", "notes/architecture" });
    _ = try r.run(&.{ "doc", "list", "--kind", "knowledge" });
    _ = try r.run(&.{ "doc", "log" });
    _ = try r.run(&.{ "doc", "lint" });

    const batch = try r.write("batch.json", batch_json);
    _ = try r.run(&.{ "source", "add", "--id", "feed", "--name", "Feed", "--scope", "personal", "--kind", "capture", "--connector", "manual" });
    _ = try r.run(&.{ "source", "list", "--all" });
    _ = try r.run(&.{ "source", "review", "--source", "feed", "--batch", "b1", "--key", "r1", "--file", batch });
    _ = try r.run(&.{ "source", "list", "feed" });
    _ = try r.run(&.{ "routines", "add", "--id", "weekly", "--cadence", "weekly:mon" });
    _ = try r.run(&.{ "routines", "due" });
    _ = try r.run(&.{"check"});
}

/// TestErrors: pins failures, exit codes and idempotent replays — 14
/// invocations.
fn errorSteps(r: *harness.Runner) anyerror!void {
    const a = r.a;
    _ = try r.run(&.{ "init", "--non-interactive", "--scope", "id=personal,kind=personal" });
    const first = (try r.run(&.{ "capture", "--key", "cap-1", "renew the parking permit" })).id(a);
    _ = try r.run(&.{ "capture", "--key", "cap-1", "renew the parking permit" });
    _ = try r.run(&.{ "capture", "--key", "cap-1", "something else entirely" });
    _ = try r.run(&.{"capture"});
    _ = try r.run(&.{ "show", "T-19990101-999" });
    _ = try r.run(&.{ "process", "--outcome", "nonsense", first });
    _ = try r.run(&.{ "process", "--outcome", "work_items", "C-19990101-999" });
    _ = try r.run(&.{ "move", "--text", "Renew permit", "--expected", "99", first, "next" });
    _ = try r.run(&.{ "doc", "put", "--kind", "nonsense", "--slug", "x" });
    _ = try r.run(&.{ "doc", "get", "--kind", "knowledge", "--slug", "missing" });
    _ = try r.run(&.{ "source", "add", "--id", "feed", "--name", "Feed", "--scope", "personal", "--kind", "capture", "--connector", "manual" });
    _ = try r.run(&.{ "source", "delete", "--id", "feed" });
    _ = try r.run(&.{"nonsense"});
}

// --------------------------------------------------------- golden record/rep

fn finish(r: *harness.Runner, io: std.Io, a: std.mem.Allocator, name: []const u8, update: bool) anyerror!Report {
    const tables = dbdump.dump(io, a, r.db, r.sys_tmp) catch |e| {
        std.debug.print("{s}: db dump failed: {s}\n", .{ name, @errorName(e) });
        return e;
    };
    const path = try std.fmt.allocPrint(a, "{s}/{s}.json", .{ golden_dir, name });

    if (update) {
        const body = try sessionJson(a, r.steps.items, tables.items);
        const bytes = try a.alloc(u8, body.len + 1);
        @memcpy(bytes[0..body.len], body);
        bytes[body.len] = '\n';
        try std.Io.Dir.cwd().createDirPath(io, golden_dir);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bytes });
        std.debug.print("{s}: recorded {s} ({d} steps, {d} db tables)\n", .{ name, path, r.steps.items.len, tables.items.len });
        return .{ .steps = r.steps.items.len, .tables = tables.items.len };
    }

    const want_raw = std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(1 << 24)) catch |e| {
        std.debug.print("{s}: read golden (run ZTD_UPDATE=1 once): {s}\n", .{ name, @errorName(e) });
        return e;
    };
    const want = std.json.parseFromSlice(std.json.Value, a, want_raw, .{}) catch |e| {
        std.debug.print("{s}: golden is not valid JSON: {s}\n", .{ name, @errorName(e) });
        return e;
    };
    const got_text = try sessionJson(a, r.steps.items, tables.items);
    const got = std.json.parseFromSlice(std.json.Value, a, got_text, .{}) catch |e| {
        std.debug.print("{s}: produced session is not valid JSON: {s}\n", .{ name, @errorName(e) });
        return e;
    };

    if (compareSession(a, want.value, got.value, r.steps.items)) |diff| {
        std.debug.print("golden {s} differs: {s}\n", .{ path, diff });
        return error.GoldenDiff;
    }
    std.debug.print("{s}: {d} steps compared, {d} db tables compared — ok\n", .{
        name,
        countArray(want.value, "steps"),
        countTables(want.value),
    });
    return .{ .steps = countArray(want.value, "steps"), .tables = countTables(want.value) };
}

fn countArray(v: std.json.Value, key: []const u8) usize {
    if (v != .object) return 0;
    const arr = v.object.get(key) orelse return 0;
    if (arr != .array) return 0;
    return arr.array.items.len;
}

fn countTables(v: std.json.Value) usize {
    if (v != .object) return 0;
    const db = v.object.get("db") orelse return 0;
    if (db != .object) return 0;
    return db.object.count();
}

/// Builds the session document in the goldens' exact shape: steps in order
/// with `exit`/`envelope`/`stderr`, then tables sorted by name with rows
/// sorted by column and empty tables as `null`.
fn sessionJson(a: std.mem.Allocator, steps: []const harness.Obs, tables: []const dbdump.Table) ![]u8 {
    var root = std.json.ObjectMap.empty;
    var steps_arr = std.json.Array.init(a);
    for (steps) |s| {
        var obj = std.json.ObjectMap.empty;
        try obj.put(a, "exit", .{ .integer = s.code });
        if (s.envelope) |env_text| {
            const parsed = std.json.parseFromSlice(std.json.Value, a, env_text, .{}) catch return error.BadEnvelope;
            try obj.put(a, "envelope", parsed.value);
        }
        if (s.stderr_text.len > 0) try obj.put(a, "stderr", .{ .string = s.stderr_text });
        try steps_arr.append(.{ .object = obj });
    }
    try root.put(a, "steps", .{ .array = steps_arr });

    var db_obj = std.json.ObjectMap.empty;
    const names = try a.alloc([]const u8, tables.len);
    for (tables, 0..) |t, i| names[i] = t.name;
    std.mem.sort([]const u8, names, {}, harness.lessStr);
    for (names) |n| {
        const t = for (tables) |t_| {
            if (std.mem.eql(u8, t_.name, n)) break t_;
        } else unreachable;
        if (t.rows.items.len == 0) {
            try db_obj.put(a, n, .null);
            continue;
        }
        var arr = std.json.Array.init(a);
        for (t.rows.items) |row| {
            var robj = std.json.ObjectMap.empty;
            const keys = try a.alloc([]const u8, row.items.len);
            for (row.items, 0..) |c, i| keys[i] = c.name;
            std.mem.sort([]const u8, keys, {}, harness.lessStr);
            for (keys) |k| {
                const cell = for (row.items) |c_| {
                    if (std.mem.eql(u8, c_.name, k)) break c_;
                } else unreachable;
                try robj.put(a, k, .{ .string = cell.value });
            }
            try arr.append(.{ .object = robj });
        }
        try db_obj.put(a, n, .{ .array = arr });
    }
    try root.put(a, "db", .{ .object = db_obj });

    var out: std.ArrayList(u8) = .empty;
    try harness.writeJsonValue(&out, a, .{ .object = root }, 0);
    return out.toOwnedSlice(a);
}

// ---------------------------------------------------------------- comparison

fn kindName(v: std.json.Value) []const u8 {
    return switch (v) {
        .null => "nil",
        .bool => "bool",
        .integer, .float, .number_string => "float64",
        .string => "string",
        .array => "[]interface {}",
        .object => "map[string]interface {}",
    };
}

fn scalarText(a: std.mem.Allocator, v: std.json.Value) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    switch (v) {
        .null => try out.appendSlice(a, "<nil>"),
        .bool => |b| try out.appendSlice(a, if (b) "true" else "false"),
        .integer => |i| try out.print(a, "{d}", .{i}),
        .float => |f| try harness.writeFloat(&out, a, f),
        .number_string => |s| try out.appendSlice(a, s),
        .string => |s| try out.appendSlice(a, s),
        else => try out.appendSlice(a, kindName(v)),
    }
    return out.toOwnedSlice(a);
}

fn scalarEqual(w: std.json.Value, g: std.json.Value) bool {
    if (w == .null or g == .null) return w == .null and g == .null;
    return switch (w) {
        .bool => |b| if (g == .bool) g.bool == b else false,
        .string => |s| if (g == .string) std.mem.eql(u8, g.string, s) else false,
        .integer, .float, .number_string => blk: {
            const wn = asNumber(w) orelse break :blk false;
            const gn = asNumber(g) orelse break :blk false;
            break :blk wn == gn;
        },
        else => false,
    };
}

fn asNumber(v: std.json.Value) ?f64 {
    return switch (v) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        .number_string => |s| std.fmt.parseFloat(f64, s) catch null,
        else => null,
    };
}

/// diffValue compares a golden JSON document against a produced one. Every
/// key, array element and scalar in want must be present and equal in got;
/// object keys only present in got are ignored so v3 can add fields.
fn diffParsed(a: std.mem.Allocator, path: []const u8, w: std.json.Value, g: std.json.Value) ?[]const u8 {
    switch (w) {
        .object => |wobj| {
            if (g != .object) {
                return std.fmt.allocPrint(a, "{s}: want object, got {s}", .{ path, kindName(g) }) catch null;
            }
            const keys = a.alloc([]const u8, wobj.count()) catch return null;
            {
                var i: usize = 0;
                var it = wobj.iterator();
                while (it.next()) |e| : (i += 1) keys[i] = e.key_ptr.*;
            }
            std.mem.sort([]const u8, keys, {}, harness.lessStr);
            for (keys) |k| {
                const gv = g.object.get(k) orelse
                    return std.fmt.allocPrint(a, "{s}.{s}: missing", .{ path, k }) catch null;
                if (diffParsed(a, pathJoin(a, path, k) orelse return null, wobj.get(k).?, gv)) |d| return d;
            }
            return null;
        },
        .array => |warr| {
            if (g != .array) {
                return std.fmt.allocPrint(a, "{s}: want array, got {s}", .{ path, kindName(g) }) catch null;
            }
            if (g.array.items.len != warr.items.len) {
                return std.fmt.allocPrint(a, "{s}: array has {d} elements, want {d}", .{ path, g.array.items.len, warr.items.len }) catch null;
            }
            for (warr.items, 0..) |wv, i| {
                const p = std.fmt.allocPrint(a, "{s}[{d}]", .{ path, i }) catch return null;
                if (diffParsed(a, p, wv, g.array.items[i])) |d| return d;
            }
            return null;
        },
        else => {
            if (scalarEqual(w, g)) return null;
            const gt = scalarText(a, g) catch return null;
            const wt = scalarText(a, w) catch return null;
            return std.fmt.allocPrint(a, "{s}: got {s}, want {s}", .{ path, gt, wt }) catch null;
        },
    }
}

fn pathJoin(a: std.mem.Allocator, path: []const u8, key: []const u8) ?[]const u8 {
    return std.fmt.allocPrint(a, "{s}.{s}", .{ path, key }) catch null;
}

/// compareSession keeps the behavioural contract strict (steps) while letting
/// the v3 schema add trailing columns to existing tables: a dump row matches
/// when every column the baseline recorded is identical, and only tables the
/// golden knows may exist. Returns null when equal.
fn compareSession(a: std.mem.Allocator, want: std.json.Value, got: std.json.Value, steps: []const harness.Obs) ?[]const u8 {
    if (want != .object) return "golden is not an object";
    const w_steps = want.object.get("steps") orelse return "golden lacks steps";
    const g_steps = got.object.get("steps") orelse return "session lacks steps";
    if (w_steps != .array or g_steps != .array) return "steps is not an array";
    if (g_steps.array.items.len != w_steps.array.items.len) {
        return std.fmt.allocPrint(a, "steps: got {d} steps, want {d}", .{ g_steps.array.items.len, w_steps.array.items.len }) catch "steps: count differs";
    }
    for (w_steps.array.items, 0..) |ws, i| {
        const gs = g_steps.array.items[i];
        if (diffParsed(a, (std.fmt.allocPrint(a, "step {d}", .{i}) catch return "oom"), ws, gs)) |d| {
            const cmd = joinArgv(a, if (i < steps.len) steps[i].argv else &.{});
            return std.fmt.allocPrint(a, "steps: {s} (command: {s})", .{ d, cmd orelse "?" }) catch "steps differ";
        }
    }

    const w_db = if (want.object.get("db")) |d| d else .null;
    const g_db = if (got.object.get("db")) |d| d else .null;
    if (w_db != .object) return "golden db is not an object";
    if (g_db != .object) return "session db is not an object";

    var it = w_db.object.iterator();
    while (it.next()) |entry| {
        const table = entry.key_ptr.*;
        const gv = g_db.object.get(table) orelse
            return std.fmt.allocPrint(a, "db: table {s} is missing", .{table}) catch "db: table missing";
        const w_rows = rowCount(entry.value_ptr.*);
        const g_rows = rowCount(gv);
        if (w_rows != g_rows) {
            return std.fmt.allocPrint(a, "db: table {s} has {d} rows, want {d}", .{ table, g_rows, w_rows }) catch "db: row count differs";
        }
        if (w_rows == 0) continue;
        const w_arr = entry.value_ptr.*.array.items;
        const g_arr = gv.array.items;
        for (w_arr, 0..) |wrow, i| {
            if (wrow != .object or g_arr[i] != .object) return "db: row is not an object";
            var rit = wrow.object.iterator();
            while (rit.next()) |col| {
                const cv = g_arr[i].object.get(col.key_ptr.*) orelse
                    return std.fmt.allocPrint(a, "db: {s} row {d} has no column {s}", .{ table, i, col.key_ptr.* }) catch "db: column missing";
                if (scalarEqual(col.value_ptr.*, cv)) continue;
                const got_text = scalarText(a, cv) catch return "db: cell differs";
                const want_text = scalarText(a, col.value_ptr.*) catch return "db: cell differs";
                return std.fmt.allocPrint(a, "db: {s} row {d} column {s} is \"{s}\", want \"{s}\"", .{ table, i, col.key_ptr.*, got_text, want_text }) catch "db: cell differs";
            }
        }
    }
    var git = g_db.object.iterator();
    while (git.next()) |entry| {
        if (w_db.object.get(entry.key_ptr.*) == null) {
            return std.fmt.allocPrint(a, "db: unexpected table {s}", .{entry.key_ptr.*}) catch "db: unexpected table";
        }
    }
    return null;
}

fn rowCount(v: std.json.Value) usize {
    return switch (v) {
        .array => |arr| arr.items.len,
        .null => 0,
        else => std.math.maxInt(usize), // type mismatch surfaces as a count error
    };
}

fn joinArgv(a: std.mem.Allocator, argv: []const []const u8) ?[]const u8 {
    if (argv.len == 0) return "?";
    var out: std.ArrayList(u8) = .empty;
    for (argv, 0..) |arg, i| {
        if (i > 0) out.append(a, ' ') catch return null;
        out.appendSlice(a, arg) catch return null;
    }
    return out.toOwnedSlice(a) catch null;
}
