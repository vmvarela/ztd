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

fn compact(ctx: *Ctx, v: json.Value) ![]const u8 {
    var aw = std.Io.Writer.Allocating.init(ctx.arena);
    try std.json.Stringify.value(v, .{}, &aw.writer);
    return aw.written();
}
