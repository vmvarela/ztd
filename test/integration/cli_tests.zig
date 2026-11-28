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
