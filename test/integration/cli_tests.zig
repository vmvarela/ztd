//! CLI aliases that no golden covers: `routine`/`due` forward to the routines
//! command unchanged. The Go suite exercised these through cli_test.go, which
//! is not ported, so the aliases are pinned here.

const std = @import("std");
const json = std.json;
const harness = @import("harness.zig");

const Ctx = harness.Ctx;

/// `routine add|done` and `due` must behave exactly like `routines ...`.
pub fn testRoutineAliases(ctx: *Ctx) anyerror!void {
    const db = try ctx.tempDb();
    _ = try ctx.wantOK(try ctx.run(db, &.{ "init", "--non-interactive", "--scope", "id=personal,kind=personal" }), "init");

    const added = try ctx.wantOK(try ctx.run(db, &.{ "routine", "add", "--id", "alias-daily", "--cadence", "daily" }), "routines add");
    if (!std.mem.eql(u8, harness.jstr(added, "id") orelse "", "alias-daily"))
        return ctx.fatal("routine add returned {s}, want alias-daily", .{try compact(ctx, added)});

    const due = try ctx.wantOK(try ctx.run(db, &.{"due"}), "routines due");
    if (due != .array or due.array.items.len != 1)
        return ctx.fatal("due = {s}, want one routine", .{try compact(ctx, due)});

    const done = try ctx.wantOK(try ctx.run(db, &.{ "routine", "done", "alias-daily" }), "routines done");
    if (harness.jstr(done, "last_completed_at") == null)
        return ctx.fatal("routine done did not record a completion: {s}", .{try compact(ctx, done)});

    _ = try ctx.wantErr(try ctx.run(db, &.{ "routine", "bogus" }), 1, "routine", "invalid_input");
}

/// `--flag=false` must read as absent: it used to enable the flag anyway.
pub fn testBooleanFlagValue(ctx: *Ctx) anyerror!void {
    const db = try ctx.tempDb();
    _ = try ctx.wantOK(try ctx.run(db, &.{ "init", "--non-interactive", "--scope", "id=personal,kind=personal" }), "init");

    // The packet carries `candidates`; the full brief carries `mits`.
    const off = try ctx.wantOK(try ctx.run(db, &.{ "prepare", "--packet=false" }), "prepare");
    if (harness.jget(off, "candidates") != null)
        return ctx.fatal("prepare --packet=false returned the packet: {s}", .{try compact(ctx, off)});

    const on = try ctx.wantOK(try ctx.run(db, &.{ "prepare", "--packet" }), "prepare");
    if (harness.jget(on, "candidates") == null)
        return ctx.fatal("prepare --packet did not return the packet: {s}", .{try compact(ctx, on)});
}

/// A replayed `process` must return the same work item, fields included.
pub fn testProcessReplayKeepsFields(ctx: *Ctx) anyerror!void {
    const db = try ctx.tempDb();
    _ = try ctx.wantOK(try ctx.run(db, &.{ "init", "--non-interactive", "--scope", "id=personal,kind=personal" }), "init");

    const cap = try ctx.wantOK(try ctx.run(db, &.{ "capture", "--key", "c1", "renew permit" }), "capture");
    const cap_id = harness.jstr(cap, "id") orelse return ctx.fatal("capture has no id", .{});

    const argv = [_][]const u8{ "process", "--key", "p1", "--outcome", "work_items", "--title", "Renew permit", cap_id };
    const first = try ctx.wantOK(try ctx.run(db, &argv), "process");
    const again = try ctx.wantOK(try ctx.run(db, &argv), "process");

    const want = firstItemField(first, "origin_capture_id") orelse
        return ctx.fatal("first process response has no origin_capture_id: {s}", .{try compact(ctx, first)});
    const got = firstItemField(again, "origin_capture_id") orelse
        return ctx.fatal("replayed process response lost origin_capture_id: {s}", .{try compact(ctx, again)});
    if (!std.mem.eql(u8, want, got))
        return ctx.fatal("origin_capture_id {s} != {s}", .{ want, got });
}

pub fn testExportNoReplace(ctx: *Ctx) anyerror!void {
    const db = try ctx.tempDb();
    _ = try ctx.wantOK(try ctx.run(db, &.{ "init", "--non-interactive", "--scope", "id=personal,kind=personal" }), "init");
    const out = try std.fmt.allocPrint(ctx.arena, "{s}.json", .{db});
    try ctx.writeFile(out, "keep");
    try ctx.wantErr(try ctx.run(db, &.{ "export", "--out", out }), 1, "export", "destination_not_empty");
    if (!std.mem.eql(u8, try ctx.readFile(out, 100), "keep")) return ctx.fatal("export replaced existing file", .{});
    for ([_][]const u8{ "", "-wal", "-shm", "-journal", "-JOURNAL" }) |suffix| {
        const reserved = try std.fmt.allocPrint(ctx.arena, "{s}{s}", .{ db, suffix });
        try ctx.wantErr(try ctx.run(db, &.{ "export", "--out", reserved }), 1, "export", "destination_not_empty");
    }
    const alias = try std.fmt.allocPrint(ctx.arena, "{s}/./{s}", .{ std.fs.path.dirname(db).?, std.fs.path.basename(db) });
    try ctx.wantErr(try ctx.run(db, &.{ "export", "--out", alias }), 1, "export", "destination_not_empty");
    const fresh = try std.fmt.allocPrint(ctx.arena, "{s}.fresh", .{db});
    _ = try ctx.wantOK(try ctx.run(db, &.{ "export", "--out", fresh }), "export");
    const content = try ctx.readFile(fresh, 1024 * 1024);
    if (std.mem.indexOf(u8, content, "\"ztd-export\"") == null) return ctx.fatal("invalid export", .{});
    _ = try ctx.wantOK(try ctx.run(db, &.{"check"}), "check");
}

fn makeItem(ctx: *Ctx, db: []const u8, scope: []const u8, key: []const u8) ![]const u8 {
    const cap = try ctx.wantOK(try ctx.run(db, &.{ "capture", "--scope", scope, "--key", key, key }), "capture");
    const cap_id = harness.jstr(cap, "id") orelse return ctx.fatal("capture has no id", .{});
    const result = try ctx.wantOK(try ctx.run(db, &.{ "process", "--scope", scope, "--key", key, "--outcome", "work_items", "--title", key, cap_id }), "process");
    return firstItemField(result, "id") orelse ctx.fatal("process has no item id", .{});
}

fn traceInScope(ctx: *Ctx, db: []const u8, scope: []const u8, id: []const u8) !Ctx.Res {
    const home = try ctx.tempDir("-home");
    const tmp = try ctx.tempDir("-tmp");
    var env = try ctx.childEnv(home, tmp);
    try env.put("ZTD_SCOPES", scope);
    const result = try std.process.run(ctx.arena, ctx.io, .{
        .argv = &.{ ctx.bin, "--json", "--db", db, "trace", id },
        .environ_map = &env,
    });
    const code: i32 = switch (result.term) {
        .exited => |c| @intCast(c),
        else => return ctx.fatal("trace terminated abnormally", .{}),
    };
    return .{
        .code = code,
        .stdout = result.stdout,
        .stderr = result.stderr,
        .env = try json.parseFromSliceLeaky(json.Value, ctx.arena, std.mem.trim(u8, result.stdout, " \t\r\n"), .{}),
    };
}

pub fn testScopedPlanAndTrace(ctx: *Ctx) anyerror!void {
    const db = try ctx.tempDb();
    _ = try ctx.wantOK(try ctx.run(db, &.{ "init", "--non-interactive", "--scope", "id=personal,kind=personal", "--scope", "id=opensource,kind=opensource", "--scope", "id=work,kind=work" }), "init");
    const local = try makeItem(ctx, db, "personal", "local");
    const other = try makeItem(ctx, db, "opensource", "other");
    const hidden = try makeItem(ctx, db, "work", "hidden");
    const trace = try ctx.wantOK(try ctx.run(db, &.{ "trace", local }), "trace");
    const edges = harness.jarr(trace, "edges") orelse return ctx.fatal("trace has no edges", .{});
    if (edges.len == 0) return ctx.fatal("visible trace edge missing", .{});
    try ctx.wantErr(try ctx.run(db, &.{ "trace", hidden }), 1, "trace", "not_found");
    const local_mit = try std.fmt.allocPrint(ctx.arena, "{s}:mit", .{local});
    const other_batch = try std.fmt.allocPrint(ctx.arena, "{s}:batch", .{other});
    const args = [_][]const u8{ "plan", "commit", "--key", "plan-1", "--period", "2026-11-28", "--item", local_mit, "--item", other_batch };
    const first = try ctx.wantOK(try ctx.run(db, &args), "plan commit");
    const replay = try ctx.wantOK(try ctx.run(db, &args), "plan commit");
    if (harness.jint(first, "revision") != 1 or harness.jint(replay, "revision") != 1) return ctx.fatal("create/replay revision mismatch", .{});
    const plan_id = harness.jstr(first, "id") orelse return ctx.fatal("plan has no id", .{});
    const full_trace = try ctx.wantOK(try ctx.run(db, &.{ "trace", plan_id }), "trace");
    const scoped_trace = try ctx.wantOK(try traceInScope(ctx, db, "personal", plan_id), "trace");
    if (!harness.containsString(full_trace, other) or !harness.containsString(scoped_trace, local) or harness.containsString(scoped_trace, other))
        return ctx.fatal("trace did not filter plan endpoints", .{});
    const brief = try ctx.wantOK(try ctx.run(db, &.{ "prepare", "--scope", "personal", "--date", "2026-11-28" }), "prepare");
    if (!harness.containsString(brief, local) or harness.containsString(brief, other)) return ctx.fatal("prepare leaked a plan item", .{});
    const packet = try ctx.wantOK(try ctx.run(db, &.{ "prepare", "--packet", "--scope", "personal", "--date", "2026-11-28" }), "prepare");
    if (!harness.containsString(packet, local) or harness.containsString(packet, other)) return ctx.fatal("packet leaked a plan item", .{});
    try ctx.wantErr(try ctx.run(db, &.{ "plan", "commit", "--key", "plan-2", "--period", "2026-11-28", "--item", local_mit }), 1, "plan", "stale_revision");
    try ctx.wantErr(try ctx.run(db, &.{ "plan", "commit", "--scope", "personal", "--key", "plan-3", "--expected", "1", "--period", "2026-11-28", "--item", local_mit }), 1, "plan", "scope_denied");
    try ctx.wantErr(try ctx.run(db, &.{ "plan", "commit", "--scope", "personal", "--key", "plan-5", "--period", "2026-11-29", "--item", local_mit, "--item", other_batch }), 1, "plan", "scope_denied");
    const updated = try ctx.wantOK(try ctx.run(db, &.{ "plan", "commit", "--key", "plan-4", "--expected", "1", "--period", "2026-11-28", "--item", local_mit, "--item", other_batch }), "plan commit");
    if (harness.jint(updated, "revision") != 2) return ctx.fatal("update revision mismatch", .{});
}

fn firstItemField(v: json.Value, name: []const u8) ?[]const u8 {
    const items = switch (v) {
        .object => |o| o.get("work_items") orelse return null,
        else => return null,
    };
    if (items != .array or items.array.items.len == 0) return null;
    return harness.jstr(items.array.items[0], name);
}

fn compact(ctx: *Ctx, v: json.Value) ![]const u8 {
    var aw = std.Io.Writer.Allocating.init(ctx.arena);
    try std.json.Stringify.value(v, .{}, &aw.writer);
    return aw.written();
}
