//! `ztd install` suite, ported from `test/integration/install_test.go`:
//! fresh-install counts against the repository bundle, unchanged reruns, the
//! conflict envelope of an edited file, --dry-run writing nothing, and the
//! missing-store-root refusal.

const std = @import("std");
const json = std.json;
const harness = @import("harness.zig");

const Ctx = harness.Ctx;

const InstallReport = struct {
    installed: i64 = 0,
    updated: i64 = 0,
    unchanged: i64 = 0,
    conflicts: []const []const u8 = &.{},
};

// TestInstallOpenCodeDryRun points HOME at a throwaway directory and checks
// the classification without letting the command write anything.
pub fn testInstallOpenCodeDryRun(ctx: *Ctx) anyerror!void {
    const home = try ctx.tempDir("-home");
    const db = try ctx.tempDb();

    const r = try ctx.runHome(home, db, &.{ "install", "opencode", "--dry-run" });
    const rep = try ctx.decode(InstallReport, try ctx.wantOK(r, "install"));

    const want = try ctx.countBundle(&.{"integrations/opencode/skills"});
    if (rep.installed != @as(i64, @intCast(want)) or rep.updated != 0 or
        rep.unchanged != 0 or rep.conflicts.len != 0)
        return ctx.fatal("report = installed={d} updated={d} unchanged={d} conflicts={d}, want {d} installed", .{
            rep.installed, rep.updated, rep.unchanged, rep.conflicts.len, want,
        });
    const config = try std.fmt.allocPrint(ctx.arena, "{s}/.config", .{home});
    if (ctx.exists(config))
        return ctx.fatal("dry run created {s}", .{config});
}

// TestInstallTemplates publishes the method templates into the directory of
// --db (a temp store root, never ~/.ztd) and keeps a rerun unchanged.
pub fn testInstallTemplates(ctx: *Ctx) anyerror!void {
    const dir = try ctx.tempDir("-store");
    const db = try std.fmt.allocPrint(ctx.arena, "{s}/ztd.db", .{dir});
    const want = try ctx.countBundle(&.{"method/templates"});

    const r = try ctx.run(db, &.{ "install", "templates" });
    const rep = try ctx.decode(InstallReport, try ctx.wantOK(r, "install"));
    if (rep.installed != @as(i64, @intCast(want)) or rep.updated != 0 or rep.unchanged != 0)
        return ctx.fatal("report = installed={d} updated={d} unchanged={d}, want {d} installed", .{
            rep.installed, rep.updated, rep.unchanged, want,
        });

    const day = try ctx.readFile(try std.fmt.allocPrint(ctx.arena, "{s}/templates/day.md", .{dir}), 1 << 20);
    if (day.len == 0)
        return ctx.fatal("templates/day.md is empty", .{});

    const raw = try ctx.readFile(try std.fmt.allocPrint(ctx.arena, "{s}/.ztd-assets.json", .{dir}), 1 << 20);
    const manifest = try parseManifest(ctx, raw);
    const format = harness.jint(manifest, "format") orelse 0;
    const assets = harness.jget(manifest, "assets") orelse
        return ctx.fatal("manifest has no assets: {s}", .{raw});
    const map = switch (assets) {
        .object => |o| o,
        else => return ctx.fatal("manifest assets = {s}, want an object", .{raw}),
    };
    if (format != 1 or map.count() != want)
        return ctx.fatal("manifest = format {d}, {d} assets, want format 1 and {d} assets", .{ format, map.count(), want });
    const day_entry = map.get("templates/day.md") orelse
        return ctx.fatal("manifest does not record templates/day.md", .{});
    const day_sha = switch (day_entry) {
        .string => |s| s,
        else => "",
    };
    if (day_sha.len == 0)
        return ctx.fatal("manifest templates/day.md entry is empty", .{});

    const r2 = try ctx.run(db, &.{ "install", "templates" });
    const rep2 = try ctx.decode(InstallReport, try ctx.wantOK(r2, "install"));
    if (rep2.installed != 0 or rep2.updated != 0 or rep2.unchanged != @as(i64, @intCast(want)))
        return ctx.fatal("rerun report = installed={d} updated={d} unchanged={d}, want {d} unchanged", .{
            rep2.installed, rep2.updated, rep2.unchanged, want,
        });
}

// TestInstallTemplatesMissingRoot refuses to create a store: the directory
// of --db must already exist, and the command must not make it.
pub fn testInstallTemplatesMissingRoot(ctx: *Ctx) anyerror!void {
    const dir = try std.fmt.allocPrint(ctx.arena, "{s}/missing", .{try ctx.tempDir("-store")});
    const db = try std.fmt.allocPrint(ctx.arena, "{s}/ztd.db", .{dir});

    const r = try ctx.run(db, &.{ "install", "templates" });
    try ctx.wantErr(r, 1, "install", "invalid_input");

    if (ctx.exists(dir))
        return ctx.fatal("missing root was created: {s}", .{dir});
}

// TestInstallOpenCodeForReal publishes the bundle into a temp HOME (never
// the real one), verifies a file against the repository bytes, the manifest
// and an unchanged rerun.
pub fn testInstallOpenCodeForReal(ctx: *Ctx) anyerror!void {
    const home = try ctx.tempDir("-home");
    const db = try ctx.tempDb();
    const want = try ctx.countBundle(&.{"integrations/opencode/skills"});

    const r = try ctx.runHome(home, db, &.{ "install", "opencode" });
    const rep = try ctx.decode(InstallReport, try ctx.wantOK(r, "install"));
    if (rep.installed != @as(i64, @intCast(want)) or rep.updated != 0 or
        rep.unchanged != 0 or rep.conflicts.len != 0)
        return ctx.fatal("report = installed={d} updated={d} unchanged={d} conflicts={d}, want {d} installed", .{
            rep.installed, rep.updated, rep.unchanged, rep.conflicts.len, want,
        });

    const base = try std.fmt.allocPrint(ctx.arena, "{s}/.config/opencode", .{home});
    const installed = try ctx.readFile(try std.fmt.allocPrint(ctx.arena, "{s}/skills/ztd/SKILL.md", .{base}), 1 << 20);
    const repo = try ctx.readFile("integrations/opencode/skills/ztd/SKILL.md", 1 << 20);
    if (!std.mem.eql(u8, installed, repo))
        return ctx.fatal("installed skill differs from the repository file", .{});

    const raw = try ctx.readFile(try std.fmt.allocPrint(ctx.arena, "{s}/.ztd-assets.json", .{base}), 1 << 20);
    const manifest = try parseManifest(ctx, raw);
    const format = harness.jint(manifest, "format") orelse 0;
    const assets = harness.jget(manifest, "assets") orelse
        return ctx.fatal("manifest has no assets: {s}", .{raw});
    const count = switch (assets) {
        .object => |o| o.count(),
        else => return ctx.fatal("manifest assets = {s}, want an object", .{raw}),
    };
    if (format != 1 or count != want)
        return ctx.fatal("manifest = format {d} with {d} assets, want format 1 with {d}", .{ format, count, want });

    const r2 = try ctx.runHome(home, db, &.{ "install", "opencode" });
    const rep2 = try ctx.decode(InstallReport, try ctx.wantOK(r2, "install"));
    if (rep2.installed != 0 or rep2.updated != 0 or rep2.unchanged != @as(i64, @intCast(want)))
        return ctx.fatal("rerun report = installed={d} updated={d} unchanged={d}, want {d} unchanged", .{
            rep2.installed, rep2.updated, rep2.unchanged, want,
        });
}

// TestInstallConflictEnvelope pins the failure path: an edited installed
// file exits 1 with family conflict and the report (conflicts included) in
// the JSON envelope, and the edit stands.
pub fn testInstallConflictEnvelope(ctx: *Ctx) anyerror!void {
    const home = try ctx.tempDir("-home");
    const db = try ctx.tempDb();
    _ = try ctx.wantOK(try ctx.runHome(home, db, &.{ "install", "opencode" }), "install");

    const target = try std.fmt.allocPrint(ctx.arena, "{s}/.config/opencode/skills/ztd/SKILL.md", .{home});
    const body = try ctx.readFile(target, 1 << 20);
    const edited = try std.fmt.allocPrint(ctx.arena, "{s}user edit\n", .{body});
    try ctx.writeFile(target, edited);

    const r = try ctx.runHome(home, db, &.{ "install", "opencode" });
    try ctx.wantErr(r, 1, "install", "conflict");
    const rep = try ctx.decode(InstallReport, harness.jget(r.env, "data") orelse json.Value.null);
    if (rep.conflicts.len == 0)
        return ctx.fatal("envelope data has no conflicts: {s}", .{r.stdout});
    var found = false;
    for (rep.conflicts) |c| {
        if (contains(c, target)) found = true;
    }
    if (!found)
        return ctx.fatal("conflicts {s} do not name {s}", .{ harness.dump(ctx.arena, harness.jget(r.env, "data") orelse json.Value.null), target });
    const got = try ctx.readFile(target, 1 << 20);
    if (!std.mem.eql(u8, got, edited))
        return ctx.fatal("edited file changed despite the conflict", .{});
}

fn contains(hay: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, hay, needle) != null;
}

fn parseManifest(ctx: *Ctx, raw: []const u8) !json.Value {
    return json.parseFromSliceLeaky(json.Value, ctx.arena, raw, .{}) catch |err|
        return ctx.fatal("parse manifest: {s}\nraw: {s}", .{ @errorName(err), raw });
}
