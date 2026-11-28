//! Core persistence: scopes/profiles, captures, work items and the shared
//! idempotency, history and id-sequence helpers.

const std = @import("std");
const builtin = @import("builtin");
const sqlite = @import("../sqlite.zig");
const errors = @import("../errors.zig");
const timeutil = @import("../timeutil.zig");
const domain = @import("../domain.zig");
const jsonw = @import("../json.zig");
const store = @import("store.zig");

const Store = store.Store;
const c = sqlite.c;
const Timestamp = timeutil.Timestamp;

pub const capture_columns = "id, scope_id, source_id, external_id, external_revision, " ++
    "original_text, content_hash, source_uri, occurred_at, captured_at, " ++
    "processing_state, processing_outcome, review_after, revision";

pub const work_item_columns = "id, scope_id, area_id, project_id, context_id, title, " ++
    "origin_capture_id, lifecycle, waiting_on, due_at, closure_kind, closed_at, " ++
    "resolution, revision, created_at, updated_at, custom_fields";

const lifecycle_order = "ORDER BY CASE lifecycle " ++
    "WHEN 'next' THEN 0 WHEN 'waiting' THEN 1 WHEN 'someday' THEN 2 ELSE 3 END, ";

// ---------------------------------------------------------------- helpers

pub fn dup(a: std.mem.Allocator, s: []const u8) ![]const u8 {
    return a.dupe(u8, s) catch errors.fail(.io_error, "out of memory", .{});
}

pub fn dupOpt(a: std.mem.Allocator, s: ?[]const u8) !?[]const u8 {
    const v = s orelse return null;
    return try dup(a, v);
}

pub fn fmtTs(a: std.mem.Allocator, ts: Timestamp) ![]const u8 {
    const buf = a.alloc(u8, 20) catch return errors.fail(.io_error, "out of memory", .{});
    return timeutil.fmtTime(ts, buf[0..20]);
}

fn idDate(a: std.mem.Allocator, ts: Timestamp) ![]const u8 {
    const buf = a.alloc(u8, 8) catch return errors.fail(.io_error, "out of memory", .{});
    return timeutil.idDate(ts, buf[0..8]);
}

pub fn trimmed(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t\n\r");
}

pub fn validateBinding(b: domain.Binding) !void {
    if (trimmed(b.profile).len == 0) return errors.invalid("profile is required", .{});
    if (trimmed(b.actor).len == 0) return errors.invalid("actor is required", .{});
    if (b.scopes.len == 0) return errors.invalid("at least one scope is required", .{});
}

fn requireKey(key: []const u8) !void {
    if (trimmed(key).len == 0) return errors.invalid("idempotency key is required", .{});
}

pub fn scopeFilter(a: std.mem.Allocator, n: usize) ![]const u8 {
    const buf = a.alloc(u8, n * 2) catch return errors.fail(.io_error, "out of memory", .{});
    return store.scopeFilter(buf, n);
}

pub fn scopeArgs(stmt: sqlite.Statement, start: c_int, b: domain.Binding) !c_int {
    var idx = start;
    for (b.scopes) |s| {
        try stmt.bindText(idx, s);
        idx += 1;
    }
    return idx;
}

fn isBusyMessage(msg: []const u8) bool {
    return std.mem.indexOf(u8, msg, "busy") != null or std.mem.indexOf(u8, msg, "locked") != null;
}

fn execClassified(s: *Store, sql: []const u8) !void {
    s.db.exec(sql) catch |e| {
        if (isBusyMessage(s.db.errmsg())) return errors.fail(.db_busy, "database is locked", .{});
        return e;
    };
}

pub fn configIdValid(s: []const u8) bool {
    if (s.len == 0 or s.len > 64) return false;
    if (s[0] < 'a' or s[0] > 'z') return false;
    for (s[1..]) |ch| {
        const ok = (ch >= 'a' and ch <= 'z') or (ch >= '0' and ch <= '9') or
            ch == '_' or ch == ':' or ch == '.' or ch == '-';
        if (!ok) return false;
    }
    return true;
}

const config_id_msg = "must start with a lowercase letter and use only a-z 0-9 _ : . - (max 64 chars, no , | or =)";

pub fn validateScopeCmd(id: []const u8, kind: []const u8) !void {
    if (!configIdValid(id)) {
        return errors.invalid("scope id " ++ config_id_msg, .{});
    }
    const ok = std.mem.eql(u8, kind, "personal") or std.mem.eql(u8, kind, "work") or
        std.mem.eql(u8, kind, "client") or std.mem.eql(u8, kind, "opensource");
    if (!ok) return errors.invalid("unknown scope kind \"{s}\" (personal, work, client or opensource)", .{kind});
}

fn validateProfileCmd(id: []const u8, kind: []const u8, actor: []const u8, scopes: []const []const u8) !void {
    if (!configIdValid(id)) return errors.invalid("profile id " ++ config_id_msg, .{});
    const ok = std.mem.eql(u8, kind, "personal") or std.mem.eql(u8, kind, "work_client");
    if (!ok) return errors.invalid("unknown profile kind \"{s}\" (personal or work_client)", .{kind});
    if (trimmed(actor).len == 0) return errors.invalid("profile {s} needs an owner actor", .{id});
    if (scopes.len == 0) return errors.invalid("profile {s} needs at least one scope", .{id});
    for (scopes, 0..) |sc, i| {
        if (!configIdValid(sc)) {
            return errors.invalid("profile {s} references an invalid scope id \"{s}\"", .{ id, sc });
        }
        for (scopes[0..i]) |prev| {
            if (std.mem.eql(u8, prev, sc)) {
                return errors.invalid("profile {s} lists scope {s} twice", .{ id, sc });
            }
        }
    }
    if (std.mem.eql(u8, kind, "work_client") and scopes.len != 1) {
        return errors.invalid("work_client profile {s} needs exactly one scope, got {d}", .{ id, scopes.len });
    }
}

/// sha256 hex of the canonical JSON payloads hashed by the Go store.
///
/// shortcut: the canonical encoders below reproduce Go's json.Marshal for the
/// three command shapes ZTD hashes; a new hashed command must add its encoder
/// and a cross-version replay fixture.
pub fn sha256hex(s: []const u8) [64]u8 {
    return store.sha256hex(s);
}

// ------------------------------------------------------------- config

pub const ScopeCmd = struct { id: []const u8, name: []const u8 = "", kind: []const u8 };
pub const ProfileCmd = struct { id: []const u8, name: []const u8 = "", kind: []const u8, actor: []const u8, scopes: []const []const u8 };
pub const ConfigResult = struct { scopes: []domain.ConfigEntry, profiles: []domain.ConfigEntry };

pub fn applyConfig(
    s: *Store,
    a: std.mem.Allocator,
    scopes: []const ScopeCmd,
    profiles: []const ProfileCmd,
    now: Timestamp,
) !ConfigResult {
    for (scopes) |sc| try validateScopeCmd(sc.id, sc.kind);
    for (profiles) |p| try validateProfileCmd(p.id, p.kind, p.actor, p.scopes);

    var scope_entries = try a.alloc(domain.ConfigEntry, scopes.len);
    var profile_entries = try a.alloc(domain.ConfigEntry, profiles.len);

    try s.begin();
    errdefer s.rollback();

    const now_s = try fmtTs(a, now);
    for (scopes, 0..) |sc, i| {
        const name = if (sc.name.len == 0) sc.id else sc.name;
        var sel = try s.db.prepare("SELECT kind, name FROM scopes WHERE id = ?");
        defer sel.finalize();
        try sel.bindText(1, sc.id);
        if (try sel.step()) {
            const existing_kind = sel.text(0);
            const existing_name = sel.text(1);
            if (!std.mem.eql(u8, existing_kind, sc.kind) or !std.mem.eql(u8, existing_name, name)) {
                return errors.fail(.conflict, "scope {s} already exists with a different kind or name", .{sc.id});
            }
            scope_entries[i] = .{ .id = sc.id, .existed = true };
        } else {
            var ins = try s.db.prepare("INSERT INTO scopes (id, name, kind, created_at) VALUES (?, ?, ?, ?)");
            defer ins.finalize();
            try ins.bindText(1, sc.id);
            try ins.bindText(2, name);
            try ins.bindText(3, sc.kind);
            try ins.bindText(4, now_s);
            _ = try ins.step();
            scope_entries[i] = .{ .id = sc.id, .existed = false };
        }
    }

    for (profiles, 0..) |p, i| {
        const name = if (p.name.len == 0) p.id else p.name;
        var found = false;
        var existing_kind: []const u8 = "";
        var existing_owner: []const u8 = "";
        {
            var sel = try s.db.prepare("SELECT kind, owner_actor_id FROM profiles WHERE id = ?");
            defer sel.finalize();
            try sel.bindText(1, p.id);
            if (try sel.step()) {
                found = true;
                existing_kind = try dup(a, sel.text(0));
                existing_owner = try dup(a, sel.text(1));
            }
        }
        if (found) {
            if (!std.mem.eql(u8, existing_kind, p.kind)) {
                return errors.fail(.conflict, "profile {s} already exists as kind {s}", .{ p.id, existing_kind });
            }
            if (!std.mem.eql(u8, existing_owner, p.actor)) {
                return errors.fail(.conflict, "profile {s} is owned by actor {s}, not {s}", .{ p.id, existing_owner, p.actor });
            }
        }
        // Every referenced scope must exist; kind rules need the declared kinds.
        var kinds = std.StringHashMap([]const u8).init(a);
        for (p.scopes) |sc| {
            if (kinds.contains(sc)) continue;
            var sel = try s.db.prepare("SELECT kind FROM scopes WHERE id = ?");
            defer sel.finalize();
            try sel.bindText(1, sc);
            if (!try sel.step()) return errors.invalid("unknown scope reference {s}", .{sc});
            try kinds.put(sc, try dup(a, sel.text(0)));
        }
        if (std.mem.eql(u8, p.kind, "work_client")) {
            const k = kinds.get(p.scopes[0]).?;
            if (!std.mem.eql(u8, k, "client")) {
                return errors.invalid("work_client profile {s} needs a client scope, {s} is {s}", .{ p.id, p.scopes[0], k });
            }
        }
        if (found) {
            var missing: usize = 0;
            for (p.scopes) |sc| {
                var has = try s.db.prepare("SELECT 1 FROM profile_scopes WHERE profile_id = ? AND scope_id = ?");
                defer has.finalize();
                try has.bindText(1, p.id);
                try has.bindText(2, sc);
                if (try has.step()) continue;
                var ins = try s.db.prepare("INSERT INTO profile_scopes (profile_id, scope_id) VALUES (?, ?)");
                defer ins.finalize();
                try ins.bindText(1, p.id);
                try ins.bindText(2, sc);
                _ = try ins.step();
                missing += 1;
            }
            profile_entries[i] = .{ .id = p.id, .existed = missing == 0 };
        } else {
            var tz_buf: [256]u8 = undefined;
            const tz = try dup(a, timeutil.localTimezone(&tz_buf));
            var ins = try s.db.prepare(
                "INSERT INTO profiles (id, name, kind, owner_actor_id, timezone, status) VALUES (?, ?, ?, ?, ?, 'active')",
            );
            defer ins.finalize();
            try ins.bindText(1, p.id);
            try ins.bindText(2, name);
            try ins.bindText(3, p.kind);
            try ins.bindText(4, p.actor);
            try ins.bindText(5, tz);
            _ = try ins.step();
            for (p.scopes) |sc| {
                var link = try s.db.prepare("INSERT INTO profile_scopes (profile_id, scope_id) VALUES (?, ?)");
                defer link.finalize();
                try link.bindText(1, p.id);
                try link.bindText(2, sc);
                _ = try link.step();
            }
            profile_entries[i] = .{ .id = p.id, .existed = false };
        }
    }

    try s.commit();
    return .{ .scopes = scope_entries, .profiles = profile_entries };
}

pub fn profileScopes(s: *Store, a: std.mem.Allocator, profile: []const u8) ![]const []const u8 {
    {
        var check = try s.db.prepare("SELECT 1 FROM profiles WHERE id = ?");
        defer check.finalize();
        try check.bindText(1, profile);
        if (!try check.step()) return errors.fail(.not_found, "profile {s} not found", .{profile});
    }
    var list = std.ArrayList([]const u8).empty;
    var stmt = try s.db.prepare("SELECT scope_id FROM profile_scopes WHERE profile_id = ? ORDER BY rowid");
    defer stmt.finalize();
    try stmt.bindText(1, profile);
    while (try stmt.step()) try list.append(a, try dup(a, stmt.text(0)));
    return list.items;
}

pub fn listScopes(s: *Store, a: std.mem.Allocator) ![]domain.Scope {
    var list = std.ArrayList(domain.Scope).empty;
    var stmt = try s.db.prepare("SELECT id, name, kind, created_at FROM scopes ORDER BY id ASC");
    defer stmt.finalize();
    while (try stmt.step()) {
        try list.append(a, .{
            .id = try dup(a, stmt.text(0)),
            .name = try dup(a, stmt.text(1)),
            .kind = try dup(a, stmt.text(2)),
            .created_at = try reformat(a, stmt.text(3), "scopes.created_at"),
        });
    }
    return list.items;
}

pub fn reformat(a: std.mem.Allocator, stored: []const u8, column: []const u8) ![]const u8 {
    const t = timeutil.parseTime(stored) catch
        return errors.fail(.io_error, "invalid timestamp in {s}: \"{s}\"", .{ column, stored });
    return try fmtTs(a, t);
}

// ------------------------------------------------------------ captures

pub const CaptureCmd = struct {
    binding: domain.Binding,
    key: []const u8,
    text: []const u8,
    source_id: []const u8 = "",
    external_id: ?[]const u8 = null,
    external_rev: ?[]const u8 = null,
    source_uri: ?[]const u8 = null,
    occurred_at: ?Timestamp = null,
};

fn outcomeFromValue(a: std.mem.Allocator, stored: []const u8) !domain.Outcome {
    const parsed = std.json.parseFromSlice(std.json.Value, a, stored, .{}) catch
        return .{ .kind = try dup(a, stored) };
    const v = parsed.value;
    if (v != .object) return .{ .kind = try dup(a, stored) };
    var out = domain.Outcome{ .kind = try dup(a, jsonw.strField(v, "kind") orelse "") };
    out.project_id = try dupOpt(a, jsonw.strField(v, "project_id"));
    out.area_id = try dupOpt(a, jsonw.strField(v, "area_id"));
    out.context_id = try dupOpt(a, jsonw.strField(v, "context_id"));
    out.waiting_on = try dup(a, jsonw.strField(v, "waiting_on") orelse "");
    out.review_after = try dupOpt(a, jsonw.strField(v, "review_after"));
    out.reason = try dup(a, jsonw.strField(v, "reason") orelse "");
    out.result_evidence = try dup(a, jsonw.strField(v, "result_evidence") orelse "");
    if (jsonw.arrField(v, "titles")) |titles| {
        var list: std.ArrayList([]const u8) = .empty;
        for (titles) |t| if (t == .string) try list.append(a, try dup(a, t.string));
        out.titles = list.items;
    }
    return out;
}

fn scanCapture(a: std.mem.Allocator, stmt: sqlite.Statement) !domain.Capture {
    const occurred: ?[]const u8 = if (stmt.optText(8)) |occ| try reformat(a, occ, "captures.occurred_at") else null;
    const review_after = try dupOpt(a, stmt.optText(12));
    var outcome: ?*const domain.Outcome = null;
    if (stmt.optText(11)) |stored| {
        const out = try a.create(domain.Outcome);
        if (stored.len > 0 and stored[0] == '{') {
            out.* = try outcomeFromValue(a, stored);
        } else {
            // Rows written before the outcome was stored whole hold its kind.
            out.* = .{ .kind = try dup(a, stored) };
            if (std.mem.eql(u8, stored, "defer")) out.review_after = review_after;
        }
        outcome = out;
    }
    return .{
        .id = try dup(a, stmt.text(0)),
        .scope = try dup(a, stmt.text(1)),
        .source_id = try dup(a, stmt.text(2)),
        .external_id = try dupOpt(a, stmt.optText(3)),
        .external_revision = try dupOpt(a, stmt.optText(4)),
        .original_text = try dup(a, stmt.text(5)),
        .content_hash = try dup(a, stmt.text(6)),
        .source_uri = try dupOpt(a, stmt.optText(7)),
        .occurred_at = occurred,
        .captured_at = try reformat(a, stmt.text(9), "captures.captured_at"),
        .state = try dup(a, stmt.text(10)),
        .outcome = outcome,
        .review_after = review_after,
        .revision = stmt.int(13),
    };
}

pub fn capture(s: *Store, a: std.mem.Allocator, cmd: CaptureCmd, now: Timestamp) !domain.Capture {
    try validateBinding(cmd.binding);
    try requireKey(cmd.key);
    if (trimmed(cmd.text).len == 0) return errors.invalid("capture text is required", .{});
    if (!std.unicode.utf8ValidateSlice(cmd.text)) return errors.invalid("capture text must be valid UTF-8", .{});
    if (cmd.text.len > 64 * 1024) return errors.invalid("capture text exceeds 64 KiB", .{});
    if ((cmd.external_id == null) != (cmd.external_rev == null)) {
        return errors.invalid("external id and external revision must be provided together", .{});
    }
    if (cmd.external_id) |v| if (v.len == 0) return errors.invalid("external id cannot be empty", .{});
    if (cmd.external_rev) |v| if (v.len == 0) return errors.invalid("external revision cannot be empty", .{});
    const source = if (cmd.source_id.len == 0) "MANUAL" else cmd.source_id;
    const now_s = try fmtTs(a, now);
    const scope = cmd.binding.scopes[0];

    var hash_req = std.Io.Writer.Allocating.init(a);
    try writeCaptureRequest(&hash_req.writer, 2, cmd, cmd.source_id);
    const hash = sha256hex(hash_req.written());

    try s.begin();
    errdefer s.rollback();

    const replay = try lookupIdemStmt(s, a, "capture", cmd.key, &hash);
    if (replay) |result| {
        try s.commit();
        return parseCaptureResult(a, result);
    }

    if (cmd.source_id.len != 0) {
        var ref = try s.db.prepare("SELECT scope_id FROM sources WHERE id = ?");
        defer ref.finalize();
        try ref.bindText(1, source);
        if (!try ref.step()) return errors.fail(.not_found, "source {s} not found", .{source});
        if (!std.mem.eql(u8, ref.text(0), scope)) {
            return errors.fail(.scope_denied, "source {s} belongs to scope {s}, not {s}", .{ source, ref.text(0), scope });
        }
    }

    if (cmd.external_id) |ext_id| {
        var dupq = try s.db.prepare(
            "SELECT 1 FROM captures WHERE scope_id = ? AND source_id = ? AND external_id = ? AND external_revision = ?",
        );
        defer dupq.finalize();
        try dupq.bindText(1, scope);
        try dupq.bindText(2, source);
        try dupq.bindText(3, ext_id);
        try dupq.bindText(4, cmd.external_rev.?);
        if (try dupq.step()) {
            return errors.fail(.conflict, "capture with external identity {s}/{s}/{s} already exists in scope {s}", .{
                source, ext_id, cmd.external_rev.?, scope,
            });
        }
    }

    const date = try idDate(a, now);
    var prefix_buf: [16]u8 = undefined;
    const prefix = std.fmt.bufPrint(&prefix_buf, "C-{s}-", .{date}) catch unreachable;
    const seq = try store.nextDailySeq(s.db, "captures", prefix);
    const id = try std.fmt.allocPrint(a, "{s}{d:0>3}", .{ prefix, @as(u32, @intCast(seq)) });
    const content_hash = try a.dupe(u8, &sha256hex(cmd.text));

    const occurred = if (cmd.occurred_at) |t| try fmtTs(a, t) else null;
    {
        var ins = try s.db.prepare(
            "INSERT INTO captures (id, scope_id, source_id, external_id, external_revision, original_text, " ++
                "content_hash, source_uri, occurred_at, captured_at, processing_state, processing_outcome, review_after, revision) " ++
                "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'pending', NULL, NULL, 1)",
        );
        defer ins.finalize();
        try ins.bindText(1, id);
        try ins.bindText(2, scope);
        try ins.bindText(3, source);
        try ins.bindOptText(4, cmd.external_id);
        try ins.bindOptText(5, cmd.external_rev);
        try ins.bindText(6, cmd.text);
        try ins.bindText(7, content_hash);
        try ins.bindOptText(8, cmd.source_uri);
        try ins.bindOptText(9, occurred);
        try ins.bindText(10, now_s);
        _ = try ins.step();
    }

    const cap = domain.Capture{
        .id = id,
        .scope = scope,
        .source_id = source,
        .external_id = cmd.external_id,
        .external_revision = cmd.external_rev,
        .original_text = cmd.text,
        .content_hash = content_hash,
        .source_uri = cmd.source_uri,
        .occurred_at = occurred,
        .captured_at = now_s,
        .state = "pending",
        .revision = 1,
    };
    try insertHistory(s, a, "capture", id, "captured", scope, "", 1, .{ .capture = cap }, now);
    try writeIdem(s, a, "capture", cmd.key, &hash, .{ .capture = cap }, now);
    try s.commit();
    return cap;
}

pub const HistoryPayload = union(enum) {
    capture: domain.Capture,
    outcome: domain.Capture,
    work_item: domain.WorkItem,
    move: struct { target: []const u8, fields: []const u8 },
    goal: domain.Goal,
    plan: domain.Plan,
    focus: domain.FocusSession,
    focus_start: FocusStartResult,
    checkpoint: domain.Checkpoint,
    review: domain.Review,
    document: domain.Document,
    source: domain.Source,
    source_review: domain.SourceReview,
    process_result: ProcessResult,
    source_review_result: SourceReviewResult,
    context: domain.Context,
    project: domain.Project,
};

fn writeHistoryPayload(w: *std.Io.Writer, payload: HistoryPayload) !void {
    var o = try jsonw.Obj.init(w);
    switch (payload) {
        .capture => |cap| try cap.write(&o),
        .outcome => |cap| try cap.write(&o),
        .work_item => |item| try item.write(&o),
        // The history payload is stored JSON, not a CLI envelope: field order
        // here matches Go's map marshaling (sorted keys).
        .move => |m| {
            try o.raw("fields", m.fields);
            try o.str("target", m.target);
        },
        .goal => |g| try g.write(&o),
        .plan => |p| try p.write(&o),
        .focus => |f| try f.write(&o),
        // focus start stores the CLI result as a Go map: sorted keys.
        .focus_start => |r| {
            if (r.checkpoints.len > 0) {
                var arr = try o.arr("checkpoints");
                for (r.checkpoints) |cp| {
                    var inner = try arr.obj();
                    try cp.write(&inner);
                    try inner.end();
                }
                try arr.end();
            }
            var inner = try o.obj("focus");
            try r.focus.write(&inner);
            try inner.end();
        },
        .checkpoint => |cp| try cp.write(&o),
        .review => |r| try r.write(&o),
        .document => |d| try d.write(&o),
        .context => |ctx| try ctx.write(&o),
        .project => |p| try p.write(&o),
        .source => |src| try src.write(&o),
        .source_review => |rev| try rev.write(&o),
        // Stored result: Go struct order (review, then captures).
        .source_review_result => |r| {
            var rev = try o.obj("review");
            try r.review.write(&rev);
            try rev.end();
            if (r.captures.len == 0) {
                try o.raw("captures", "null");
            } else {
                var arr = try o.arr("captures");
                for (r.captures) |cap| {
                    var item = try arr.obj();
                    try cap.write(&item);
                    try item.end();
                }
                try arr.end();
            }
        },
        .process_result => |r| {
            var capo = try o.obj("capture");
            try r.capture.write(&capo);
            try capo.end();
            if (r.work_items.len > 0) {
                var arr = try o.arr("work_items");
                for (r.work_items) |item| {
                    var inner = try arr.obj();
                    try item.write(&inner);
                    try inner.end();
                }
                try arr.end();
            }
        },
    }
    try o.end();
}

pub fn insertHistory(
    s: *Store,
    a: std.mem.Allocator,
    entity: []const u8,
    id: []const u8,
    event: []const u8,
    scope: []const u8,
    profile: []const u8,
    rev: i64,
    payload: HistoryPayload,
    now: Timestamp,
) !void {
    var aw = std.Io.Writer.Allocating.init(a);
    writeHistoryPayload(&aw.writer, payload) catch return errors.invalid("history payload is not serializable", .{});
    const now_s = try fmtTs(a, now);
    var stmt = try s.db.prepare(
        "INSERT INTO history_events (entity_type, entity_id, scope_id, profile_id, event, revision, payload_json, created_at) " ++
            "VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
    );
    defer stmt.finalize();
    try stmt.bindText(1, entity);
    try stmt.bindText(2, id);
    try stmt.bindOptText(3, if (scope.len == 0) null else scope);
    try stmt.bindOptText(4, if (profile.len == 0) null else profile);
    try stmt.bindText(5, event);
    try stmt.bindInt(6, rev);
    try stmt.bindText(7, aw.written());
    try stmt.bindText(8, now_s);
    _ = try stmt.step();
}

/// Records one provenance edge. Links are a set: a repeated edge is ignored.
pub fn insertLink(
    s: *Store,
    a: std.mem.Allocator,
    from_type: []const u8,
    from_id: []const u8,
    to_type: []const u8,
    to_id: []const u8,
    relation: []const u8,
    scope: []const u8,
    now: Timestamp,
) !void {
    var stmt = try s.db.prepare(
        "INSERT OR IGNORE INTO links (from_type, from_id, to_type, to_id, relation, scope_id, created_at) VALUES (?, ?, ?, ?, ?, ?, ?)",
    );
    defer stmt.finalize();
    try stmt.bindText(1, from_type);
    try stmt.bindText(2, from_id);
    try stmt.bindText(3, to_type);
    try stmt.bindText(4, to_id);
    try stmt.bindText(5, relation);
    try stmt.bindText(6, scope);
    try stmt.bindText(7, try fmtTs(a, now));
    _ = try stmt.step();
}

/// Returns the stored result JSON when the key replays, null when the key is
/// new, and a conflict when the payload hash differs.
pub fn lookupIdemStmt(
    s: *Store,
    a: std.mem.Allocator,
    command: []const u8,
    key: []const u8,
    hash: *const [64]u8,
) !?[]const u8 {
    var stmt = try s.db.prepare(
        "SELECT request_hash, result_json FROM idempotency_records WHERE command = ? AND idempotency_key = ?",
    );
    defer stmt.finalize();
    try stmt.bindText(1, command);
    try stmt.bindText(2, key);
    if (!try stmt.step()) return null;
    if (!std.mem.eql(u8, stmt.text(0), hash)) {
        return errors.fail(.idempotency_conflict, "idempotency key \"{s}\" was already used with a different payload", .{key});
    }
    return try dup(a, stmt.text(1));
}

pub fn writeIdem(
    s: *Store,
    a: std.mem.Allocator,
    command: []const u8,
    key: []const u8,
    hash: *const [64]u8,
    result: HistoryPayload,
    now: Timestamp,
) !void {
    var aw = std.Io.Writer.Allocating.init(a);
    writeHistoryPayload(&aw.writer, result) catch return errors.invalid("result is not serializable", .{});
    const now_s = try fmtTs(a, now);
    var stmt = try s.db.prepare(
        "INSERT INTO idempotency_records (command, idempotency_key, request_hash, result_json, created_at) VALUES (?, ?, ?, ?, ?)",
    );
    defer stmt.finalize();
    try stmt.bindText(1, command);
    try stmt.bindText(2, key);
    try stmt.bindText(3, hash);
    try stmt.bindText(4, aw.written());
    try stmt.bindText(5, now_s);
    _ = try stmt.step();
}

fn writeCaptureRequest(w: *std.Io.Writer, version: i64, cmd: CaptureCmd, source: []const u8) !void {
    var o = try jsonw.Obj.init(w);
    try o.int("Version", version);
    var inner = try o.obj("Cmd");
    try writeBinding(&inner, cmd.binding);
    try inner.str("Key", cmd.key);
    try inner.str("Text", cmd.text);
    try inner.str("SourceID", source);
    try writeOptString(&inner, "ExternalID", cmd.external_id);
    try writeOptString(&inner, "ExternalRev", cmd.external_rev);
    try writeOptString(&inner, "SourceURI", cmd.source_uri);
    if (cmd.occurred_at) |t| {
        var tb: [20]u8 = undefined;
        try inner.str("OccurredAt", timeutil.fmtTime(t, &tb));
    } else {
        try inner.raw("OccurredAt", "null");
    }
    try inner.end();
    try o.end();
}

pub fn writeBinding(o: *jsonw.Obj, b: domain.Binding) !void {
    var inner = try o.obj("Binding");
    try inner.str("profile", b.profile);
    try inner.str("actor", b.actor);
    if (b.scopes.len == 0) {
        // Go marshals a nil slice as null; hashed payloads depend on it.
        try inner.raw("scopes", "null");
    } else {
        var a = try inner.arr("scopes");
        for (b.scopes) |s| try a.str(s);
        try a.end();
    }
    try inner.end();
}

fn writeOptString(o: *jsonw.Obj, name: []const u8, value: ?[]const u8) !void {
    if (value) |v| try o.str(name, v) else try o.raw(name, "null");
}

fn parseCaptureResult(a: std.mem.Allocator, result: []const u8) !domain.Capture {
    const parsed = std.json.parseFromSlice(std.json.Value, a, result, .{}) catch
        return errors.fail(.io_error, "stored result is unreadable", .{});
    return captureFromValue(a, parsed.value);
}

fn captureFromValue(a: std.mem.Allocator, v: std.json.Value) !domain.Capture {
    const cap = domain.Capture{
        .id = try dup(a, jsonw.strField(v, "id") orelse ""),
        .scope = try dup(a, jsonw.strField(v, "scope") orelse ""),
        .source_id = try dup(a, jsonw.strField(v, "source_id") orelse ""),
        .external_id = try dupOpt(a, jsonw.strField(v, "external_id")),
        .external_revision = try dupOpt(a, jsonw.strField(v, "external_revision")),
        .original_text = try dup(a, jsonw.strField(v, "original_text") orelse ""),
        .content_hash = try dup(a, jsonw.strField(v, "content_hash") orelse ""),
        .source_uri = try dupOpt(a, jsonw.strField(v, "source_uri")),
        .occurred_at = try dupOpt(a, jsonw.strField(v, "occurred_at")),
        .captured_at = try dup(a, jsonw.strField(v, "captured_at") orelse ""),
        .state = try dup(a, jsonw.strField(v, "processing_state") orelse "pending"),
        .review_after = try dupOpt(a, jsonw.strField(v, "review_after")),
        .revision = jsonw.intField(v, "revision") orelse 0,
    };
    return cap;
}

// ------------------------------------------------------------- inbox

pub fn inboxNext(s: *Store, a: std.mem.Allocator, b: domain.Binding, now: Timestamp) !domain.Capture {
    try validateBinding(b);
    const clause = try scopeFilter(a, b.scopes.len);
    const sql = try std.fmt.allocPrint(a, "SELECT " ++ capture_columns ++ " FROM captures WHERE scope_id IN ({s}) " ++
        "AND (processing_state = 'pending' OR (processing_state = 'deferred' AND review_after <= ?)) " ++
        "ORDER BY captured_at ASC, id ASC LIMIT 1", .{clause});
    var stmt = try s.db.prepare(sql);
    defer stmt.finalize();
    _ = try scopeArgs(stmt, 1, b);
    try stmt.bindText(@intCast(1 + b.scopes.len), try fmtTs(a, now));
    if (!try stmt.step()) {
        return errors.fail(.not_found, "no capture is awaiting processing in the active scopes", .{});
    }
    return scanCapture(a, stmt);
}

pub fn listInbox(s: *Store, a: std.mem.Allocator, b: domain.Binding, now: Timestamp) ![]domain.Capture {
    try validateBinding(b);
    const clause = try scopeFilter(a, b.scopes.len);
    const sql = try std.fmt.allocPrint(a, "SELECT " ++ capture_columns ++ " FROM captures WHERE scope_id IN ({s}) " ++
        "AND (processing_state = 'pending' OR (processing_state = 'deferred' AND review_after <= ?)) " ++
        "ORDER BY captured_at ASC, id ASC LIMIT 200", .{clause});
    var stmt = try s.db.prepare(sql);
    defer stmt.finalize();
    _ = try scopeArgs(stmt, 1, b);
    try stmt.bindText(@intCast(1 + b.scopes.len), try fmtTs(a, now));
    var list = std.ArrayList(domain.Capture).empty;
    while (try stmt.step()) try list.append(a, try scanCapture(a, stmt));
    return list.items;
}

pub fn getCapture(s: *Store, a: std.mem.Allocator, b: domain.Binding, id: []const u8) !domain.Capture {
    try validateBinding(b);
    const clause = try scopeFilter(a, b.scopes.len);
    const sql = try std.fmt.allocPrint(a, "SELECT " ++ capture_columns ++ " FROM captures WHERE id = ? AND scope_id IN ({s})", .{clause});
    var stmt = try s.db.prepare(sql);
    defer stmt.finalize();
    try stmt.bindText(1, id);
    _ = try scopeArgs(stmt, 2, b);
    if (!try stmt.step()) return rowAccessError(s, "captures", "capture", id);
    return scanCapture(a, stmt);
}

fn rowAccessError(s: *Store, table: []const u8, noun: []const u8, id: []const u8) errors.Ztd {
    var sql_buf: [96]u8 = undefined;
    const sql = std.fmt.bufPrint(&sql_buf, "SELECT 1 FROM {s} WHERE id = ?", .{table}) catch unreachable;
    var stmt = s.db.prepare(sql) catch return errors.fail(.io_error, "sqlite prepare failed", .{});
    defer stmt.finalize();
    stmt.bindText(1, id) catch return errors.fail(.io_error, "sqlite bind failed", .{});
    const found = stmt.step() catch return errors.fail(.io_error, "sqlite step failed", .{});
    if (found) return errors.fail(.scope_denied, "{s} {s} is outside the active scopes", .{ noun, id });
    return errors.fail(.not_found, "{s} {s} not found", .{ noun, id });
}

// ----------------------------------------------------------- process

pub const ProcessCmd = struct {
    binding: domain.Binding,
    key: []const u8,
    id: []const u8,
    expected: i64 = 0,
    outcome: domain.Outcome,
};

pub const ProcessResult = struct { capture: domain.Capture, work_items: []domain.WorkItem };

pub fn validateOutcome(o: domain.Outcome) !void {
    if (std.mem.eql(u8, o.kind, "work_items")) {
        if (o.titles.len == 0) return errors.invalid("work_items outcome requires at least one title", .{});
        for (o.titles) |t| {
            if (trimmed(t).len == 0) return errors.invalid("work item titles cannot be blank", .{});
        }
    } else if (std.mem.eql(u8, o.kind, "reference")) {
        // A reference points at content the host already holds; no extra field.
    } else if (std.mem.eql(u8, o.kind, "immediate")) {
        if (trimmed(o.result_evidence).len == 0) return errors.invalid("immediate outcome requires result evidence", .{});
    } else if (std.mem.eql(u8, o.kind, "discard")) {
        if (trimmed(o.reason).len == 0) return errors.invalid("discard outcome requires a reason", .{});
    } else if (std.mem.eql(u8, o.kind, "defer")) {
        if (o.review_after == null) return errors.invalid("defer outcome requires review_after", .{});
    } else {
        return errors.invalid("unknown outcome kind \"{s}\"", .{o.kind});
    }
}

fn dueAfter(cap: domain.Capture, now: Timestamp) bool {
    if (!std.mem.eql(u8, cap.state, "deferred")) return false;
    const r = cap.review_after orelse return false;
    const t = timeutil.parseTime(r) catch return false;
    return t <= now;
}

pub fn process(s: *Store, a: std.mem.Allocator, cmd: ProcessCmd, decision: []const u8, now: Timestamp) !ProcessResult {
    try validateBinding(cmd.binding);
    try requireKey(cmd.key);
    if (cmd.id.len == 0) return errors.invalid("capture id is required", .{});
    try validateOutcome(cmd.outcome);

    var aw = std.Io.Writer.Allocating.init(a);
    try writeProcessRequest(&aw.writer, cmd, decision);
    const hash = sha256hex(aw.written());
    const now_s = try fmtTs(a, now);

    try s.begin();
    errdefer s.rollback();

    if (decision.len > 0) try requireDecision(s, decision, cmd.binding.scopes[0]);

    if (try lookupIdemStmt(s, a, "process", cmd.key, &hash)) |stored| {
        try s.commit();
        return parseProcessResult(a, stored);
    }

    const cap = getCaptureInTx(s, a, cmd.binding, cmd.id) catch |e| {
        return e;
    };
    if (cmd.expected != 0 and cmd.expected != cap.revision) {
        return errors.fail(.stale_revision, "capture {s} is at revision {d}, expected {d}", .{ cmd.id, cap.revision, cmd.expected });
    }
    if (std.mem.eql(u8, cap.state, "pending")) {
        // ready
    } else if (std.mem.eql(u8, cap.state, "deferred") and dueAfter(cap, now)) {
        // ready
    } else if (std.mem.eql(u8, cap.state, "deferred")) {
        return errors.fail(.invalid_transition, "capture {s} is deferred until {s}", .{ cmd.id, cap.review_after.? });
    } else {
        return errors.fail(.invalid_transition, "capture {s} is already {s}", .{ cmd.id, cap.state });
    }
    try checkOutcomeRefs(s, cap.scope, cmd.outcome);

    const state = if (std.mem.eql(u8, cmd.outcome.kind, "discard"))
        "discarded"
    else if (std.mem.eql(u8, cmd.outcome.kind, "defer"))
        "deferred"
    else
        "processed";
    const review_after = if (std.mem.eql(u8, state, "deferred")) cmd.outcome.review_after else null;

    var items = std.ArrayList(domain.WorkItem).empty;
    if (std.mem.eql(u8, cmd.outcome.kind, "work_items")) {
        const date = try idDate(a, now);
        var prefix_buf: [16]u8 = undefined;
        const prefix = std.fmt.bufPrint(&prefix_buf, "T-{s}-", .{date}) catch unreachable;
        const seq = try store.nextDailySeq(s.db, "work_items", prefix);
        for (cmd.outcome.titles, 0..) |title, i| {
            const id = try std.fmt.allocPrint(a, "{s}{d:0>3}", .{ prefix, @as(u32, @intCast(seq + @as(i64, @intCast(i)))) });
            {
                var ins = try s.db.prepare(
                    "INSERT INTO work_items (id, scope_id, area_id, project_id, context_id, title, origin_capture_id, " ++
                        "lifecycle, waiting_on, due_at, closure_kind, closed_at, resolution, revision, created_at, updated_at, custom_fields) " ++
                        "VALUES (?, ?, ?, ?, ?, ?, ?, 'next', NULL, NULL, NULL, NULL, NULL, 1, ?, ?, '{}')",
                );
                defer ins.finalize();
                try ins.bindText(1, id);
                try ins.bindText(2, cap.scope);
                try ins.bindOptText(3, cmd.outcome.area_id);
                try ins.bindOptText(4, cmd.outcome.project_id);
                try ins.bindOptText(5, cmd.outcome.context_id);
                try ins.bindText(6, title);
                try ins.bindText(7, cap.id);
                try ins.bindText(8, now_s);
                try ins.bindText(9, now_s);
                _ = try ins.step();
            }
            const item = domain.WorkItem{
                .id = id,
                .scope = cap.scope,
                .area_id = cmd.outcome.area_id,
                .project_id = cmd.outcome.project_id,
                .context_id = cmd.outcome.context_id,
                .title = title,
                .origin_capture_id = cap.id,
                .lifecycle = "next",
                .revision = 1,
                .created_at = now_s,
                .updated_at = now_s,
            };
            try insertHistory(s, a, "work_item", id, "created", cap.scope, "", 1, .{ .work_item = item }, now);
            try insertLink(s, a, "capture", cap.id, "work_item", id, "produced", cap.scope, now);
            if (decision.len > 0) {
                try insertLink(s, a, "document", decision, "work_item", id, "produced", cap.scope, now);
            }
            try items.append(a, item);
        }
    }

    {
        var upd = try s.db.prepare(
            "UPDATE captures SET processing_state = ?, processing_outcome = ?, review_after = ?, revision = ? " ++
                "WHERE id = ? AND scope_id = ? AND revision = ?",
        );
        defer upd.finalize();
        try upd.bindText(1, state);
        // The whole outcome, not just its kind: the reason and evidence the
        // command demanded must survive somewhere a reader can see them.
        var oj = std.Io.Writer.Allocating.init(a);
        var oo = try jsonw.Obj.init(&oj.writer);
        try cmd.outcome.write(&oo);
        try oo.end();
        try upd.bindText(2, oj.written());
        try upd.bindOptText(3, review_after);
        try upd.bindInt(4, cap.revision + 1);
        try upd.bindText(5, cap.id);
        try upd.bindText(6, cap.scope);
        try upd.bindInt(7, cap.revision);
        _ = try upd.step();
        if (c.sqlite3_changes(s.db.handle) != 1) {
            return errors.fail(.stale_revision, "capture {s} changed concurrently", .{cmd.id});
        }
    }

    var updated = cap;
    updated.state = state;
    updated.review_after = review_after;
    updated.revision = cap.revision + 1;
    const out_copy = try a.create(domain.Outcome);
    out_copy.* = cmd.outcome;
    updated.outcome = out_copy;
    try insertHistory(s, a, "capture", cap.id, "processed", cap.scope, "", updated.revision, .{ .capture = updated }, now);
    const result = ProcessResult{ .capture = updated, .work_items = items.items };
    try writeIdem(s, a, "process", cmd.key, &hash, .{ .process_result = result }, now);
    try s.commit();
    return result;
}

fn getCaptureInTx(s: *Store, a: std.mem.Allocator, b: domain.Binding, id: []const u8) !domain.Capture {
    const clause = try scopeFilter(a, b.scopes.len);
    const sql = try std.fmt.allocPrint(a, "SELECT " ++ capture_columns ++ " FROM captures WHERE id = ? AND scope_id IN ({s})", .{clause});
    var stmt = try s.db.prepare(sql);
    defer stmt.finalize();
    try stmt.bindText(1, id);
    _ = try scopeArgs(stmt, 2, b);
    if (!try stmt.step()) return rowAccessError(s, "captures", "capture", id);
    return scanCapture(a, stmt);
}

fn checkOutcomeRefs(s: *Store, scope: []const u8, o: domain.Outcome) !void {
    if (o.project_id) |id| try checkSameScope(s, "projects", "project", id, scope);
    if (o.area_id) |id| try checkSameScope(s, "areas", "area", id, scope);
    if (o.context_id) |id| try checkSameScope(s, "contexts", "context", id, scope);
}

fn checkSameScope(s: *Store, table: []const u8, noun: []const u8, id: []const u8, scope: []const u8) !void {
    var sql_buf: [96]u8 = undefined;
    const sql = std.fmt.bufPrint(&sql_buf, "SELECT scope_id FROM {s} WHERE id = ?", .{table}) catch unreachable;
    var stmt = try s.db.prepare(sql);
    defer stmt.finalize();
    try stmt.bindText(1, id);
    if (!try stmt.step()) return errors.invalid("unknown {s} reference {s}", .{ noun, id });
    if (!std.mem.eql(u8, stmt.text(0), scope)) {
        return errors.fail(.scope_denied, "{s} {s} belongs to scope {s}, not {s}", .{ noun, id, stmt.text(0), scope });
    }
}

fn writeProcessRequest(w: *std.Io.Writer, cmd: ProcessCmd, decision: []const u8) !void {
    var o = try jsonw.Obj.init(w);
    try writeBinding(&o, cmd.binding);
    try o.str("Key", cmd.key);
    // Emitted only when set so a request of the pre-v3 shape hashes as it did.
    if (decision.len > 0) try o.str("Decision", decision);
    try o.str("ID", cmd.id);
    try o.int("Expected", cmd.expected);
    var inner = try o.obj("Outcome");
    try cmd.outcome.write(&inner);
    try inner.end();
    try o.end();
}

fn parseProcessResult(a: std.mem.Allocator, stored: []const u8) !ProcessResult {
    const parsed = std.json.parseFromSlice(std.json.Value, a, stored, .{}) catch
        return errors.fail(.io_error, "stored result is unreadable", .{});
    const cap_val = jsonw.field(parsed.value, "capture") orelse return errors.fail(.io_error, "stored result is unreadable", .{});
    var items = std.ArrayList(domain.WorkItem).empty;
    if (jsonw.arrField(parsed.value, "work_items")) |list| {
        for (list) |v| try items.append(a, try workItemFromValueFull(a, v));
    }
    return .{ .capture = try captureFromValue(a, cap_val), .work_items = items.items };
}

// --------------------------------------------------------- work items

fn scanWorkItem(a: std.mem.Allocator, stmt: sqlite.Statement) !domain.WorkItem {
    const fields = stmt.text(16);
    return .{
        .id = try dup(a, stmt.text(0)),
        .scope = try dup(a, stmt.text(1)),
        .area_id = try dupOpt(a, stmt.optText(2)),
        .project_id = try dupOpt(a, stmt.optText(3)),
        .context_id = try dupOpt(a, stmt.optText(4)),
        .title = try dup(a, stmt.text(5)),
        .origin_capture_id = try dupOpt(a, stmt.optText(6)),
        .lifecycle = try dup(a, stmt.text(7)),
        .waiting_on = try dup(a, stmt.text(8)),
        .due_at = try dupOpt(a, stmt.optText(9)),
        .closure_kind = try dup(a, stmt.text(10)),
        .closed_at = try dupOpt(a, stmt.optText(11)),
        .resolution = try dup(a, stmt.text(12)),
        .custom_fields_json = if (fields.len == 0 or std.mem.eql(u8, fields, "{}")) null else try dup(a, fields),
        .revision = stmt.int(13),
        .created_at = try reformat(a, stmt.text(14), "work_items.created_at"),
        .updated_at = try reformat(a, stmt.text(15), "work_items.updated_at"),
    };
}

pub fn getWorkItem(s: *Store, a: std.mem.Allocator, b: domain.Binding, id: []const u8) !domain.WorkItem {
    try validateBinding(b);
    const clause = try scopeFilter(a, b.scopes.len);
    const sql = try std.fmt.allocPrint(a, "SELECT " ++ work_item_columns ++ " FROM work_items WHERE id = ? AND scope_id IN ({s})", .{clause});
    var stmt = try s.db.prepare(sql);
    defer stmt.finalize();
    try stmt.bindText(1, id);
    _ = try scopeArgs(stmt, 2, b);
    if (!try stmt.step()) return rowAccessError(s, "work_items", "work item", id);
    return scanWorkItem(a, stmt);
}

pub fn getWorkItemWithCheckpoint(
    s: *Store,
    a: std.mem.Allocator,
    b: domain.Binding,
    id: []const u8,
) !struct { item: domain.WorkItem, checkpoint: ?domain.Checkpoint } {
    const item = try getWorkItem(s, a, b, id);
    var stmt = try s.db.prepare(
        "SELECT id, scope_id, work_item_id, result, evidence_json, uncertainties, next_action, revision, created_at " ++
            "FROM checkpoints WHERE work_item_id = ? AND scope_id = ? ORDER BY revision DESC LIMIT 1",
    );
    defer stmt.finalize();
    try stmt.bindText(1, item.id);
    try stmt.bindText(2, item.scope);
    if (!try stmt.step()) return .{ .item = item, .checkpoint = null };
    return .{ .item = item, .checkpoint = .{
        .id = try dup(a, stmt.text(0)),
        .scope = try dup(a, stmt.text(1)),
        .work_item_id = try dup(a, stmt.text(2)),
        .result = try dup(a, stmt.text(3)),
        .evidence_refs_json = try dupOpt(a, stmt.optText(4)),
        .uncertainties = try dup(a, stmt.text(5)),
        .next_action = try dup(a, stmt.text(6)),
        .created_at = try reformat(a, stmt.text(8), "checkpoints.created_at"),
        .revision = stmt.int(7),
    } };
}

pub const ListFilter = struct {
    lifecycle: []const u8 = "",
    context: []const u8 = "",
    project: []const u8 = "",
    scope: []const u8 = "",
};

pub fn listWorkItems(
    s: *Store,
    a: std.mem.Allocator,
    b: domain.Binding,
    filter: ListFilter,
) ![]domain.WorkItem {
    try validateBinding(b);
    const clause = try scopeFilter(a, b.scopes.len);
    var sql = std.Io.Writer.Allocating.init(a);
    const w = &sql.writer;
    try w.writeAll("SELECT " ++ work_item_columns ++ " FROM work_items WHERE scope_id IN (");
    try w.writeAll(clause);
    try w.writeAll(")");

    if (filter.lifecycle.len > 0) {
        const ok = std.mem.eql(u8, filter.lifecycle, "next") or std.mem.eql(u8, filter.lifecycle, "waiting") or
            std.mem.eql(u8, filter.lifecycle, "someday") or std.mem.eql(u8, filter.lifecycle, "archived");
        if (!ok) return errors.invalid("unknown lifecycle \"{s}\"", .{filter.lifecycle});
        try w.writeAll(" AND lifecycle = ?");
    }
    if (filter.context.len > 0) {
        try w.writeAll(" AND context_id IN (SELECT id FROM contexts WHERE name = ? AND scope_id IN (");
        try w.writeAll(clause);
        try w.writeAll("))");
    }
    if (filter.project.len > 0) try w.writeAll(" AND project_id = ?");
    if (filter.scope.len > 0) {
        if (!b.allows(filter.scope)) {
            return errors.fail(.scope_denied, "scope {s} is outside the active scopes", .{filter.scope});
        }
        try w.writeAll(" AND scope_id = ?");
    }
    try w.writeAll(" " ++ lifecycle_order ++ "updated_at DESC, id ASC");

    var stmt = try s.db.prepare(sql.written());
    defer stmt.finalize();
    var idx = try scopeArgs(stmt, 1, b);
    if (filter.lifecycle.len > 0) {
        try stmt.bindText(idx, filter.lifecycle);
        idx += 1;
    }
    if (filter.context.len > 0) {
        try stmt.bindText(idx, filter.context);
        idx += 1;
        idx = try scopeArgs(stmt, idx, b);
    }
    if (filter.project.len > 0) {
        try stmt.bindText(idx, filter.project);
        idx += 1;
    }
    if (filter.scope.len > 0) {
        try stmt.bindText(idx, filter.scope);
        idx += 1;
    }
    var list = std.ArrayList(domain.WorkItem).empty;
    while (try stmt.step()) try list.append(a, try scanWorkItem(a, stmt));
    return list.items;
}

pub fn find(s: *Store, a: std.mem.Allocator, b: domain.Binding, query: []const u8, limit_in: i64) ![]domain.WorkItem {
    try validateBinding(b);
    if (trimmed(query).len == 0) return errors.invalid("search query is required", .{});
    const limit: i64 = if (limit_in <= 0) 10 else if (limit_in > 50) 50 else limit_in;
    const clause = try scopeFilter(a, b.scopes.len);
    const sql = try std.fmt.allocPrint(a, "SELECT " ++ work_item_columns ++ " FROM work_items WHERE scope_id IN ({s})" ++
        " AND instr(lower(title), lower(?)) > 0 " ++ lifecycle_order ++ "updated_at DESC, id ASC LIMIT ?", .{clause});
    var stmt = try s.db.prepare(sql);
    defer stmt.finalize();
    const idx = try scopeArgs(stmt, 1, b);
    try stmt.bindText(idx, query);
    try stmt.bindInt(idx + 1, limit);
    var list = std.ArrayList(domain.WorkItem).empty;
    while (try stmt.step()) try list.append(a, try scanWorkItem(a, stmt));
    return list.items;
}

// --------------------------------------------------------------- move

pub const MoveCmd = struct {
    binding: domain.Binding,
    key: []const u8,
    id: []const u8,
    target: []const u8,
    text: ?[]const u8 = null,
    waiting_on: ?[]const u8 = null,
    resolution: ?[]const u8 = null,
    closure_kind: []const u8 = "",
    fields: []const [2][]const u8 = &.{},
    expected: i64 = 0,
};

fn validateMove(cmd: MoveCmd) !void {
    try validateBinding(cmd.binding);
    try requireKey(cmd.key);
    if (trimmed(cmd.id).len == 0) return errors.invalid("work item id is required", .{});
    const target_ok = std.mem.eql(u8, cmd.target, "next") or std.mem.eql(u8, cmd.target, "waiting") or
        std.mem.eql(u8, cmd.target, "someday") or std.mem.eql(u8, cmd.target, "archived");
    if (!target_ok) return errors.invalid("move target must be next, waiting, someday or archived, got \"{s}\"", .{cmd.target});
    if (cmd.text) |t| if (trimmed(t).len == 0) return errors.invalid("text cannot be empty", .{});
    if (std.mem.eql(u8, cmd.target, "waiting")) {
        if (cmd.waiting_on == null or trimmed(cmd.waiting_on.?).len == 0) return errors.invalid("waiting requires waiting_on", .{});
    }
    if (std.mem.eql(u8, cmd.target, "archived")) {
        if (cmd.resolution == null or trimmed(cmd.resolution.?).len == 0) return errors.invalid("archive requires resolution", .{});
    }
    const closure_ok = cmd.closure_kind.len == 0 or std.mem.eql(u8, cmd.closure_kind, "completed") or
        std.mem.eql(u8, cmd.closure_kind, "cancelled") or std.mem.eql(u8, cmd.closure_kind, "unspecified");
    if (!closure_ok) return errors.invalid("closure kind must be completed, cancelled or unspecified, got \"{s}\"", .{cmd.closure_kind});
    for (cmd.fields) |kv| {
        if (trimmed(kv[0]).len == 0) return errors.invalid("field keys cannot be empty", .{});
        if (isReservedField(kv[0])) {
            return errors.invalid("field \"{s}\" is reserved: waiting_on, resolution, context, client, project, captured_at and closed_at have their own columns", .{kv[0]});
        }
        if (std.mem.indexOfAny(u8, kv[0], ":=") != null) {
            return errors.invalid("field {s} must be key:value", .{kv[0]});
        }
    }
}

fn isReservedField(key: []const u8) bool {
    const reserved = [_][]const u8{ "context", "client", "project", "captured_at", "closed_at", "waiting_on", "resolution" };
    for (reserved) |r| if (std.mem.eql(u8, key, r)) return true;
    return false;
}

pub fn moveWorkItem(s: *Store, a: std.mem.Allocator, cmd: MoveCmd, now: Timestamp) !domain.WorkItem {
    try validateMove(cmd);
    var aw = std.Io.Writer.Allocating.init(a);
    try writeMoveRequest(&aw.writer, cmd);
    const hash = sha256hex(aw.written());
    const now_s = try fmtTs(a, now);

    try s.begin();
    errdefer s.rollback();

    if (try lookupIdemStmt(s, a, "move", cmd.key, &hash)) |stored| {
        try s.commit();
        const parsed = std.json.parseFromSlice(std.json.Value, a, stored, .{}) catch
            return errors.fail(.io_error, "stored result is unreadable", .{});
        return workItemFromValueFull(a, parsed.value);
    }

    var item = blk: {
        const clause = try scopeFilter(a, cmd.binding.scopes.len);
        const sql = try std.fmt.allocPrint(a, "SELECT " ++ work_item_columns ++ " FROM work_items WHERE id = ? AND scope_id IN ({s})", .{clause});
        var stmt = try s.db.prepare(sql);
        defer stmt.finalize();
        try stmt.bindText(1, cmd.id);
        _ = try scopeArgs(stmt, 2, cmd.binding);
        if (!try stmt.step()) return errors.fail(.not_found, "work item {s} not found", .{cmd.id});
        break :blk try scanWorkItem(a, stmt);
    };
    if (cmd.expected != 0 and cmd.expected != item.revision) {
        return errors.fail(.stale_revision, "work item {s} is at revision {d}, expected {d}", .{ item.id, item.revision, cmd.expected });
    }
    if (cmd.text) |t| item.title = t;

    var merged = std.ArrayList([2][]const u8).empty;
    if (item.custom_fields_json) |existing| {
        const parsed = std.json.parseFromSlice(std.json.Value, a, existing, .{}) catch
            return errors.invalid("work item {s} has invalid custom_fields", .{item.id});
        if (parsed.value == .object) {
            var it = parsed.value.object.iterator();
            while (it.next()) |entry| {
                var replaced = false;
                for (cmd.fields) |kv| if (std.mem.eql(u8, kv[0], entry.key_ptr.*)) {
                    replaced = true;
                };
                if (!replaced) try merged.append(a, .{ entry.key_ptr.*, entry.value_ptr.string });
            }
        }
    }
    for (cmd.fields) |kv| try merged.append(a, kv);

    item.waiting_on = "";
    item.closure_kind = "";
    item.closed_at = null;
    item.resolution = "";
    if (std.mem.eql(u8, cmd.target, "waiting")) {
        item.waiting_on = cmd.waiting_on.?;
    } else if (std.mem.eql(u8, cmd.target, "archived")) {
        const kind = if (cmd.closure_kind.len == 0) "completed" else cmd.closure_kind;
        item.closure_kind = kind;
        item.resolution = cmd.resolution.?;
        item.closed_at = now_s;
    }
    item.lifecycle = cmd.target;
    item.revision += 1;
    item.updated_at = now_s;

    const fields_json = try renderFields(a, merged.items);
    item.custom_fields_json = if (merged.items.len == 0) null else fields_json;

    {
        var upd = try s.db.prepare(
            "UPDATE work_items SET title = ?, lifecycle = ?, waiting_on = ?, closure_kind = ?, closed_at = ?, " ++
                "resolution = ?, custom_fields = ?, revision = ?, updated_at = ? WHERE id = ? AND scope_id = ? AND revision = ?",
        );
        defer upd.finalize();
        try upd.bindText(1, item.title);
        try upd.bindText(2, item.lifecycle);
        try upd.bindOptText(3, if (item.waiting_on.len == 0) null else item.waiting_on);
        try upd.bindOptText(4, if (item.closure_kind.len == 0) null else item.closure_kind);
        try upd.bindOptText(5, item.closed_at);
        try upd.bindOptText(6, if (item.resolution.len == 0) null else item.resolution);
        try upd.bindText(7, fields_json);
        try upd.bindInt(8, item.revision);
        try upd.bindText(9, item.updated_at);
        try upd.bindText(10, item.id);
        try upd.bindText(11, item.scope);
        try upd.bindInt(12, item.revision - 1);
        _ = try upd.step();
        if (c.sqlite3_changes(s.db.handle) != 1) {
            return errors.fail(.stale_revision, "work item {s} changed concurrently", .{item.id});
        }
    }

    var changed = std.Io.Writer.Allocating.init(a);
    {
        var o = try jsonw.Obj.init(&changed.writer);
        if (cmd.text) |t| try o.str("title", t);
        if (std.mem.eql(u8, cmd.target, "waiting")) try o.str("waiting_on", cmd.waiting_on.?);
        if (std.mem.eql(u8, cmd.target, "archived")) {
            try o.str("closure_kind", item.closure_kind);
            try o.str("resolution", item.resolution);
        }
        if (merged.items.len > 0) try o.raw("custom_fields", fields_json);
        try o.end();
    }
    try insertHistory(s, a, "work_item", item.id, "moved", item.scope, "", item.revision, .{ .move = .{
        .target = cmd.target,
        .fields = changed.written(),
    } }, now);
    try writeIdem(s, a, "move", cmd.key, &hash, .{ .work_item = item }, now);
    try s.commit();
    return item;
}

fn renderFields(a: std.mem.Allocator, fields: []const [2][]const u8) ![]const u8 {
    // Go sorts map keys when marshaling; match it so stored JSON is stable.
    const sorted = try a.dupe([2][]const u8, fields);
    std.mem.sort([2][]const u8, sorted, {}, struct {
        fn less(_: void, x: [2][]const u8, y: [2][]const u8) bool {
            return std.mem.lessThan(u8, x[0], y[0]);
        }
    }.less);
    var aw = std.Io.Writer.Allocating.init(a);
    var o = try jsonw.Obj.init(&aw.writer);
    for (sorted) |kv| try o.str(kv[0], kv[1]);
    try o.end();
    return aw.written();
}

fn writeMoveRequest(w: *std.Io.Writer, cmd: MoveCmd) !void {
    var o = try jsonw.Obj.init(w);
    try writeBinding(&o, cmd.binding);
    try o.str("Key", cmd.key);
    try o.str("ID", cmd.id);
    try o.str("Target", cmd.target);
    try writeOptString(&o, "Text", cmd.text);
    try writeOptString(&o, "WaitingOn", cmd.waiting_on);
    try writeOptString(&o, "Resolution", cmd.resolution);
    try o.str("ClosureKind", cmd.closure_kind);
    if (cmd.fields.len == 0) {
        try o.raw("Fields", "null");
    } else {
        var f = try o.obj("Fields");
        const sorted = try std.heap.page_allocator.dupe([2][]const u8, cmd.fields);
        defer std.heap.page_allocator.free(sorted);
        std.mem.sort([2][]const u8, sorted, {}, struct {
            fn less(_: void, x: [2][]const u8, y: [2][]const u8) bool {
                return std.mem.lessThan(u8, x[0], y[0]);
            }
        }.less);
        for (sorted) |kv| try f.str(kv[0], kv[1]);
        try f.end();
    }
    try o.int("Expected", cmd.expected);
    try o.end();
}

fn workItemFromValueFull(a: std.mem.Allocator, v: std.json.Value) !domain.WorkItem {
    const fields_json = jsonw.field(v, "custom_fields");
    return .{
        .id = try dup(a, jsonw.strField(v, "id") orelse ""),
        .scope = try dup(a, jsonw.strField(v, "scope") orelse ""),
        .area_id = try dupOpt(a, jsonw.strField(v, "area_id")),
        .project_id = try dupOpt(a, jsonw.strField(v, "project_id")),
        .context_id = try dupOpt(a, jsonw.strField(v, "context_id")),
        .title = try dup(a, jsonw.strField(v, "title") orelse ""),
        .origin_capture_id = try dupOpt(a, jsonw.strField(v, "origin_capture_id")),
        .lifecycle = try dup(a, jsonw.strField(v, "lifecycle") orelse "next"),
        .waiting_on = try dup(a, jsonw.strField(v, "waiting_on") orelse ""),
        .due_at = try dupOpt(a, jsonw.strField(v, "due_at")),
        .closure_kind = try dup(a, jsonw.strField(v, "closure_kind") orelse ""),
        .closed_at = try dupOpt(a, jsonw.strField(v, "closed_at")),
        .resolution = try dup(a, jsonw.strField(v, "resolution") orelse ""),
        .custom_fields_json = if (fields_json) |f| blk: {
            var aw = std.Io.Writer.Allocating.init(a);
            try std.json.Stringify.value(f, .{}, &aw.writer);
            break :blk aw.written();
        } else null,
        .revision = jsonw.intField(v, "revision") orelse 0,
        .created_at = try dup(a, jsonw.strField(v, "created_at") orelse ""),
        .updated_at = try dup(a, jsonw.strField(v, "updated_at") orelse ""),
    };
}

test "capture writes one pending row and replays idempotently" {
    var s = try Store.open(":memory:");
    defer s.close();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    _ = try applyConfig(&s, a, &.{.{ .id = "personal", .kind = "personal" }}, &.{
        .{ .id = "personal", .kind = "personal", .actor = "tester", .scopes = &.{"personal"} },
    }, 1_700_000_000);
    const b = domain.Binding{ .profile = "personal", .actor = "tester", .scopes = &.{"personal"} };
    const cap = try capture(&s, a, .{ .binding = b, .key = "k1", .text = "hello" }, 1_700_000_000);
    try std.testing.expectEqualStrings("C-20231114-001", cap.id);
    try std.testing.expectEqualStrings("pending", cap.state);
    const again = try capture(&s, a, .{ .binding = b, .key = "k1", .text = "hello" }, 1_700_000_000);
    try std.testing.expectEqualStrings(cap.id, again.id);
    try std.testing.expectError(error.Ztd, capture(&s, a, .{ .binding = b, .key = "k1", .text = "other" }, 1_700_000_000));
    try std.testing.expectEqual(errors.Family.idempotency_conflict, errors.getFamily());
}

// ---------------------------------------------------------------- goals

const goal_columns = "id, profile_id, kind, start_on, end_on, statement, status";

pub const GoalCmd = struct {
    binding: domain.Binding,
    key: []const u8,
    kind: []const u8,
    start_on: []const u8 = "",
    end_on: []const u8 = "",
    statement: []const u8,
};

fn writeGoalRequest(w: *std.Io.Writer, cmd: GoalCmd) !void {
    var o = try jsonw.Obj.init(w);
    try writeBinding(&o, cmd.binding);
    try o.str("Key", cmd.key);
    try o.str("Kind", cmd.kind);
    try o.str("StartOn", cmd.start_on);
    try o.str("EndOn", cmd.end_on);
    try o.str("Statement", cmd.statement);
    try o.end();
}

fn scanGoal(a: std.mem.Allocator, stmt: sqlite.Statement) !domain.Goal {
    return .{
        .id = try dup(a, stmt.text(0)),
        .profile_id = try dup(a, stmt.text(1)),
        .kind = try dup(a, stmt.text(2)),
        .start_on = try dup(a, stmt.text(3)),
        .end_on = try dupOpt(a, stmt.optText(4)),
        .statement = try dup(a, stmt.text(5)),
        .status = try dup(a, stmt.text(6)),
    };
}

fn goalFromValue(a: std.mem.Allocator, v: std.json.Value) !domain.Goal {
    return .{
        .id = try dup(a, jsonw.strField(v, "id") orelse ""),
        .profile_id = try dup(a, jsonw.strField(v, "profile_id") orelse ""),
        .kind = try dup(a, jsonw.strField(v, "kind") orelse ""),
        .start_on = try dup(a, jsonw.strField(v, "start_on") orelse ""),
        .end_on = try dupOpt(a, jsonw.strField(v, "end_on")),
        .statement = try dup(a, jsonw.strField(v, "statement") orelse ""),
        .status = try dup(a, jsonw.strField(v, "status") orelse ""),
    };
}

pub fn setGoal(s: *Store, a: std.mem.Allocator, cmd_in: GoalCmd, now: Timestamp) !domain.Goal {
    try validateBinding(cmd_in.binding);
    try requireKey(cmd_in.key);
    if (!std.mem.eql(u8, cmd_in.kind, "primary") and !std.mem.eql(u8, cmd_in.kind, "subgoal")) {
        return errors.invalid("goal kind must be primary or subgoal", .{});
    }
    if (trimmed(cmd_in.statement).len == 0) return errors.invalid("goal statement is required", .{});
    var cmd = cmd_in;
    if (cmd.start_on.len == 0) {
        var dbuf: [10]u8 = undefined;
        cmd.start_on = try dup(a, timeutil.localDate(now, &dbuf));
    }
    _ = timeutil.parseDate(cmd.start_on) catch return errors.invalid("start_on must be YYYY-MM-DD", .{});
    if (cmd.end_on.len > 0) {
        _ = timeutil.parseDate(cmd.end_on) catch return errors.invalid("end_on must be YYYY-MM-DD", .{});
    }
    var aw = std.Io.Writer.Allocating.init(a);
    try writeGoalRequest(&aw.writer, cmd);
    const hash = sha256hex(aw.written());
    const now_s = try fmtTs(a, now);

    try s.begin();
    errdefer s.rollback();
    if (try lookupIdemStmt(s, a, "goal", cmd.key, &hash)) |stored| {
        try s.commit();
        const parsed = std.json.parseFromSlice(std.json.Value, a, stored, .{}) catch
            return errors.fail(.io_error, "stored result is unreadable", .{});
        return goalFromValue(a, parsed.value);
    }
    {
        var stmt = try s.db.prepare("SELECT 1 FROM profiles WHERE id = ?");
        defer stmt.finalize();
        try stmt.bindText(1, cmd.binding.profile);
        if (!try stmt.step()) return errors.fail(.not_found, "profile {s} does not exist", .{cmd.binding.profile});
    }
    if (std.mem.eql(u8, cmd.kind, "primary")) {
        var stmt = try s.db.prepare(
            "SELECT id FROM goals WHERE profile_id = ? AND kind = 'primary' AND status = 'active' LIMIT 1",
        );
        defer stmt.finalize();
        try stmt.bindText(1, cmd.binding.profile);
        if (try stmt.step()) {
            return errors.fail(.conflict, "profile {s} already has active primary goal {s}", .{ cmd.binding.profile, stmt.text(0) });
        }
    }
    const date = try idDate(a, now);
    const seq = try store.nextDailySeq(s.db, "goals", try std.fmt.allocPrint(a, "G-{s}-", .{date}));
    const id = try std.fmt.allocPrint(a, "G-{s}-{d:0>3}", .{ date, @as(u32, @intCast(seq)) });
    {
        var ins = try s.db.prepare(
            "INSERT INTO goals (id, profile_id, kind, start_on, end_on, statement, status, created_at, updated_at) " ++
                "VALUES (?, ?, ?, ?, ?, ?, 'active', ?, ?)",
        );
        defer ins.finalize();
        try ins.bindText(1, id);
        try ins.bindText(2, cmd.binding.profile);
        try ins.bindText(3, cmd.kind);
        try ins.bindText(4, cmd.start_on);
        try ins.bindOptText(5, if (cmd.end_on.len == 0) null else cmd.end_on);
        try ins.bindText(6, cmd.statement);
        try ins.bindText(7, now_s);
        try ins.bindText(8, now_s);
        _ = try ins.step();
    }
    const goal = domain.Goal{
        .id = id,
        .profile_id = cmd.binding.profile,
        .kind = cmd.kind,
        .start_on = cmd.start_on,
        .end_on = if (cmd.end_on.len == 0) null else cmd.end_on,
        .statement = cmd.statement,
        .status = "active",
    };
    try insertHistory(s, a, "goal", id, "created", "", cmd.binding.profile, 1, .{ .goal = goal }, now);
    try writeIdem(s, a, "goal", cmd.key, &hash, .{ .goal = goal }, now);
    try s.commit();
    return goal;
}

pub fn activeGoal(s: *Store, a: std.mem.Allocator, b: domain.Binding) !?domain.Goal {
    try validateBinding(b);
    var stmt = try s.db.prepare(
        "SELECT " ++ goal_columns ++ " FROM goals WHERE profile_id = ? AND kind = 'primary' AND status = 'active' LIMIT 1",
    );
    defer stmt.finalize();
    try stmt.bindText(1, b.profile);
    if (!try stmt.step()) return null;
    return try scanGoal(a, stmt);
}

fn primaryGoal(s: *Store, a: std.mem.Allocator, profile: []const u8) !?domain.Goal {
    var stmt = try s.db.prepare(
        "SELECT " ++ goal_columns ++ " FROM goals WHERE profile_id = ? AND kind = 'primary' AND status = 'active' " ++
            "ORDER BY created_at DESC, id DESC LIMIT 1",
    );
    defer stmt.finalize();
    try stmt.bindText(1, profile);
    if (!try stmt.step()) return null;
    return try scanGoal(a, stmt);
}

pub fn setGoalStatus(s: *Store, a: std.mem.Allocator, b: domain.Binding, status: []const u8, now: Timestamp) !domain.Goal {
    try validateBinding(b);
    if (!std.mem.eql(u8, status, "completed") and !std.mem.eql(u8, status, "cancelled")) {
        return errors.invalid("goal status must be completed or cancelled, got \"{s}\"", .{status});
    }
    const verb: []const u8 = if (std.mem.eql(u8, status, "completed")) "complete" else "cancel";
    const goal = (try primaryGoal(s, a, b.profile)) orelse
        return errors.fail(.not_found, "profile {s} has no primary goal to {s}", .{ b.profile, verb });
    if (std.mem.eql(u8, goal.status, status)) return goal;
    if (!std.mem.eql(u8, goal.status, "active")) {
        return errors.fail(.invalid_transition, "goal {s} is {s}; cannot mark it {s}", .{ goal.id, goal.status, status });
    }
    const now_s = try fmtTs(a, now);
    try s.begin();
    errdefer s.rollback();
    {
        var upd = try s.db.prepare("UPDATE goals SET status = ?, updated_at = ? WHERE id = ? AND status = 'active'");
        defer upd.finalize();
        try upd.bindText(1, status);
        try upd.bindText(2, now_s);
        try upd.bindText(3, goal.id);
        _ = try upd.step();
        if (s.db.changes() != 1) return errors.fail(.conflict, "goal {s} changed concurrently", .{goal.id});
    }
    var out = goal;
    out.status = status;
    try insertHistory(s, a, "goal", goal.id, status, "", b.profile, 2, .{ .goal = out }, now);
    try s.commit();
    return out;
}

// ------------------------------------------------------------ planning

const plan_columns = "id, profile_id, kind, period, status, revision, created_at, updated_at";
const source_columns = "id, name, scope_id, kind, connector, provider, connection_ref, non_secret_query, cadence, " ++
    "auth_state, coverage_state, cursor, last_attempt_at, last_success_at, created_at, updated_at, reported_cursor, last_reported_at";

pub const PlanItemCmd = struct {
    work_item_id: []const u8,
    role: []const u8,
    position: i64,
};

pub const CommitPlanCmd = struct {
    binding: domain.Binding,
    key: []const u8,
    kind: []const u8,
    period: []const u8,
    expected: i64 = 0,
    items: []const PlanItemCmd = &.{},
    override_id: []const u8 = "",
};

fn writeCommitPlanRequest(w: *std.Io.Writer, cmd: CommitPlanCmd, decision: []const u8) !void {
    var o = try jsonw.Obj.init(w);
    try writeBinding(&o, cmd.binding);
    try o.str("Key", cmd.key);
    if (decision.len > 0) try o.str("Decision", decision);
    try o.str("Kind", cmd.kind);
    try o.str("Period", cmd.period);
    try o.int("Expected", cmd.expected);
    var arr = try o.arr("Items");
    for (cmd.items) |it| {
        var inner = try arr.obj();
        try inner.str("work_item_id", it.work_item_id);
        try inner.str("role", it.role);
        try inner.int("position", it.position);
        try inner.end();
    }
    try arr.end();
    try o.str("OverrideID", cmd.override_id);
    try o.end();
}

fn scanPlan(a: std.mem.Allocator, stmt: sqlite.Statement) !domain.Plan {
    return .{
        .id = try dup(a, stmt.text(0)),
        .profile = try dup(a, stmt.text(1)),
        .kind = try dup(a, stmt.text(2)),
        .period = try dup(a, stmt.text(3)),
        .status = try dup(a, stmt.text(4)),
        .revision = stmt.int(5),
        .created_at = try reformat(a, stmt.text(6), "plans.created_at"),
        .updated_at = try reformat(a, stmt.text(7), "plans.updated_at"),
    };
}

fn planFromValue(a: std.mem.Allocator, v: std.json.Value) !domain.Plan {
    var items = std.ArrayList(domain.PlanItem).empty;
    if (jsonw.arrField(v, "items")) |list| {
        for (list) |it| {
            try items.append(a, .{
                .work_item_id = try dup(a, jsonw.strField(it, "work_item_id") orelse ""),
                .role = try dup(a, jsonw.strField(it, "role") orelse ""),
                .position = jsonw.intField(it, "position") orelse 0,
            });
        }
    }
    return .{
        .id = try dup(a, jsonw.strField(v, "id") orelse ""),
        .profile = try dup(a, jsonw.strField(v, "profile") orelse ""),
        .kind = try dup(a, jsonw.strField(v, "kind") orelse ""),
        .period = try dup(a, jsonw.strField(v, "period") orelse ""),
        .status = try dup(a, jsonw.strField(v, "status") orelse ""),
        .revision = jsonw.intField(v, "revision") orelse 0,
        .items = items.items,
        .created_at = try dup(a, jsonw.strField(v, "created_at") orelse ""),
        .updated_at = try dup(a, jsonw.strField(v, "updated_at") orelse ""),
    };
}

fn scanSource(a: std.mem.Allocator, stmt: sqlite.Statement) !domain.Source {
    return .{
        .id = try dup(a, stmt.text(0)),
        .name = try dup(a, stmt.text(1)),
        .scope = try dup(a, stmt.text(2)),
        .kind = try dup(a, stmt.text(3)),
        .connector = try dup(a, stmt.text(4)),
        .provider = try dup(a, stmt.text(5)),
        .connection_ref = try dup(a, stmt.text(6)),
        .non_secret_query = try dup(a, stmt.text(7)),
        .cadence = try dup(a, stmt.text(8)),
        .auth_state = try dup(a, stmt.text(9)),
        .coverage = try dup(a, stmt.text(10)),
        .cursor = try dup(a, stmt.text(11)),
        .last_attempt_at = try dupOpt(a, stmt.optText(12)),
        .last_success_at = try dupOpt(a, stmt.optText(13)),
        .created_at = try reformat(a, stmt.text(14), "sources.created_at"),
        .updated_at = try reformat(a, stmt.text(15), "sources.updated_at"),
        .reported_cursor = try dup(a, stmt.text(16)),
        .last_reported_at = try dupOpt(a, stmt.optText(17)),
    };
}

pub fn listSources(s: *Store, a: std.mem.Allocator, b: domain.Binding) ![]domain.Source {
    try validateBinding(b);
    const clause = try scopeFilter(a, b.scopes.len);
    const sql = try std.fmt.allocPrint(a, "SELECT " ++ source_columns ++ " FROM sources WHERE scope_id IN ({s}) ORDER BY id ASC", .{clause});
    var stmt = try s.db.prepare(sql);
    defer stmt.finalize();
    _ = try scopeArgs(stmt, 1, b);
    var list = std.ArrayList(domain.Source).empty;
    while (try stmt.step()) try list.append(a, try scanSource(a, stmt));
    return list.items;
}

fn loadPlan(s: *Store, a: std.mem.Allocator, profile: []const u8, kind: []const u8, period: []const u8) !?domain.Plan {
    var stmt = try s.db.prepare(
        "SELECT " ++ plan_columns ++ " FROM plans WHERE profile_id = ? AND kind = ? AND period = ?",
    );
    defer stmt.finalize();
    try stmt.bindText(1, profile);
    try stmt.bindText(2, kind);
    try stmt.bindText(3, period);
    if (!try stmt.step()) return null;
    var plan = try scanPlan(a, stmt);
    var items = std.ArrayList(domain.PlanItem).empty;
    var q = try s.db.prepare(
        "SELECT work_item_id, role, position FROM plan_items WHERE plan_id = ? ORDER BY position ASC",
    );
    defer q.finalize();
    try q.bindText(1, plan.id);
    while (try q.step()) {
        try items.append(a, .{
            .work_item_id = try dup(a, q.text(0)),
            .role = try dup(a, q.text(1)),
            .position = q.int(2),
        });
    }
    plan.items = items.items;
    return plan;
}

pub fn prepare(s: *Store, a: std.mem.Allocator, b: domain.Binding, date_in: []const u8, now: Timestamp) !domain.PlanBrief {
    try validateBinding(b);
    var date = date_in;
    if (date.len == 0) {
        var dbuf: [10]u8 = undefined;
        date = try dup(a, timeutil.localDate(now, &dbuf));
    }
    _ = timeutil.parseDate(date) catch return errors.invalid("date must be YYYY-MM-DD", .{});
    {
        var stmt = try s.db.prepare("SELECT 1 FROM profiles WHERE id = ?");
        defer stmt.finalize();
        try stmt.bindText(1, b.profile);
        if (!try stmt.step()) return errors.fail(.not_found, "profile {s} not found", .{b.profile});
    }
    var brief = domain.PlanBrief{
        .profile = b.profile,
        .date = date,
        .mits = &.{},
        .next = &.{},
        .waiting = &.{},
    };
    brief.goal = try activeGoal(s, a, b);
    const sources = try listSources(s, a, b);
    if (sources.len > 0) brief.sources = sources;
    if (try loadPlan(s, a, b.profile, "daily", date)) |p| {
        brief.plan = p;
        var mits = std.ArrayList(domain.WorkItem).empty;
        var cps = std.ArrayList(domain.Checkpoint).empty;
        for (p.items) |it| {
            if (!std.mem.eql(u8, it.role, "mit")) continue;
            const item = getWorkItem(s, a, b, it.work_item_id) catch |e| {
                if (errors.getFamily() == .not_found) continue;
                return e;
            };
            try mits.append(a, item);
            var q = try s.db.prepare(
                "SELECT id, scope_id, work_item_id, result, evidence_json, uncertainties, next_action, revision, created_at " ++
                    "FROM checkpoints WHERE work_item_id = ? ORDER BY revision DESC LIMIT 1",
            );
            defer q.finalize();
            try q.bindText(1, item.id);
            if (try q.step()) try cps.append(a, try scanCheckpoint(a, q));
        }
        brief.mits = mits.items;
        if (cps.items.len > 0) brief.checkpoints = cps.items;
    }
    var next = std.ArrayList(domain.WorkItem).empty;
    var waiting = std.ArrayList(domain.WorkItem).empty;
    for ([_][]const u8{ "next", "waiting" }) |lc| {
        const clause = try scopeFilter(a, b.scopes.len);
        const sql = try std.fmt.allocPrint(a, "SELECT " ++ work_item_columns ++ " FROM work_items WHERE lifecycle = ? AND scope_id IN ({s}) " ++
            "ORDER BY updated_at DESC, id ASC LIMIT 10", .{clause});
        var stmt = try s.db.prepare(sql);
        defer stmt.finalize();
        try stmt.bindText(1, lc);
        _ = try scopeArgs(stmt, 2, b);
        while (try stmt.step()) {
            const item = try scanWorkItem(a, stmt);
            if (std.mem.eql(u8, lc, "next")) try next.append(a, item) else try waiting.append(a, item);
        }
    }
    brief.next = next.items;
    brief.waiting = waiting.items;
    return brief;
}

/// Byte cap for the `prepare --packet` decision packet (spec §3).
pub const packet_cap = 1536;
/// Byte caps for the token-economical reads (spec §3).
pub const inbox_cap = 1024;
pub const doc_search_cap = 2048;
pub const source_review_cap = 1024;
pub const inbox_excerpt = 280;
pub const compact_capture_ids = 10;

/// A copy of `cap` whose text is cut to `max` bytes on a character boundary.
pub fn clipCapture(a: std.mem.Allocator, cap: domain.Capture, max: usize) !domain.Capture {
    var out = cap;
    out.original_text = try clip(a, cap.original_text, max);
    return out;
}

fn countInScopes(s: *Store, a: std.mem.Allocator, b: domain.Binding, table: []const u8, predicate: []const u8) !i64 {
    const clause = try scopeFilter(a, b.scopes.len);
    const sql = try std.fmt.allocPrint(a, "SELECT count(*) FROM {s} WHERE {s} AND scope_id IN ({s})", .{ table, predicate, clause });
    var stmt = try s.db.prepare(sql);
    defer stmt.finalize();
    _ = try scopeArgs(stmt, 1, b);
    if (!try stmt.step()) return 0;
    return stmt.int(0);
}

/// The compact decision packet: what to do now, with IDs only. Same candidates
/// as `prepare` (MITs first, then next), but at most three, titles clipped, no
/// bodies, and trimmed again if the bytes exceed the cap.
pub fn preparePacket(s: *Store, a: std.mem.Allocator, b: domain.Binding, date_in: []const u8, now: Timestamp) ![]const u8 {
    const brief = try prepare(s, a, b, date_in, now);
    const Candidate = struct { item: domain.WorkItem, role: []const u8 };
    var all: std.ArrayList(Candidate) = .empty;
    for (brief.mits) |it| try all.append(a, .{ .item = it, .role = "mit" });
    for (brief.next) |it| try all.append(a, .{ .item = it, .role = "next" });
    const pending = try countInScopes(s, a, b, "captures", "processing_state = 'pending'");
    const waiting = try countInScopes(s, a, b, "work_items", "lifecycle = 'waiting'");

    var shown: usize = @min(all.items.len, 3);
    while (true) {
        var aw = std.Io.Writer.Allocating.init(a);
        var o = try jsonw.Obj.init(&aw.writer);
        try o.str("profile", brief.profile);
        try o.str("date", brief.date);
        if (brief.goal) |g| {
            var go = try o.obj("goal");
            try go.str("id", g.id);
            try go.str("statement", try clip(a, g.statement, 120));
            try go.optStr("end_on", g.end_on);
            try go.end();
        }
        var arr = try o.arr("candidates");
        for (all.items[0..shown]) |cand| {
            var co = try arr.obj();
            try co.str("id", cand.item.id);
            try co.str("role", cand.role);
            try co.str("title", try clip(a, cand.item.title, 120));
            try co.end();
        }
        try arr.end();
        try o.int("pending_captures", pending);
        try o.int("waiting", waiting);
        if (shown < all.items.len) {
            try o.boolean("truncated", true);
            try o.int("omitted", @intCast(all.items.len - shown));
        }
        try o.end();
        if (aw.written().len <= packet_cap or shown == 0) return aw.written();
        shown -= 1;
    }
}

fn overrideApplies(s: *Store, actor: []const u8, period: []const u8, override_id: []const u8) !bool {
    const sql = if (override_id.len > 0)
        "SELECT 1 FROM daily_limit_overrides WHERE rule = 'mit' AND actor_id = ? AND local_date = ? AND id = ?"
    else
        "SELECT 1 FROM daily_limit_overrides WHERE rule = 'mit' AND actor_id = ? AND local_date = ?";
    var stmt = try s.db.prepare(sql);
    defer stmt.finalize();
    try stmt.bindText(1, actor);
    try stmt.bindText(2, period);
    if (override_id.len > 0) try stmt.bindText(3, override_id);
    return try stmt.step();
}

pub fn commitPlan(s: *Store, a: std.mem.Allocator, cmd: CommitPlanCmd, decision: []const u8, now: Timestamp) !domain.Plan {
    try validateBinding(cmd.binding);
    try requireKey(cmd.key);
    if (!std.mem.eql(u8, cmd.kind, "daily") and !std.mem.eql(u8, cmd.kind, "weekly")) {
        return errors.invalid("plan kind must be daily or weekly", .{});
    }
    if (cmd.period.len == 0) return errors.invalid("period is required", .{});
    // A plan nothing can look up is worse than a rejection.
    if (std.mem.eql(u8, cmd.kind, "daily")) {
        _ = timeutil.parseDate(cmd.period) catch
            return errors.invalid("period must be a real YYYY-MM-DD date, got \"{s}\"", .{cmd.period});
    } else {
        if (!validWeekPeriod(cmd.period)) {
            return errors.invalid("period must be a real YYYY-Www week, got \"{s}\"", .{cmd.period});
        }
    }
    var aw = std.Io.Writer.Allocating.init(a);
    try writeCommitPlanRequest(&aw.writer, cmd, decision);
    const hash = sha256hex(aw.written());
    const now_s = try fmtTs(a, now);

    try s.begin();
    errdefer s.rollback();
    if (decision.len > 0) try requireDecision(s, decision, cmd.binding.scopes[0]);

    if (try lookupIdemStmt(s, a, "commit_plan", cmd.key, &hash)) |stored| {
        try s.commit();
        const parsed = std.json.parseFromSlice(std.json.Value, a, stored, .{}) catch
            return errors.fail(.io_error, "stored result is unreadable", .{});
        return planFromValue(a, parsed.value);
    }
    const owned = profileScopes(s, a, cmd.binding.profile) catch |e| {
        if (errors.getFamily() == .not_found) return errors.fail(.not_found, "profile {s} not found", .{cmd.binding.profile});
        return e;
    };
    for (cmd.binding.scopes) |sc| {
        var found = false;
        for (owned) |o| if (std.mem.eql(u8, o, sc)) {
            found = true;
        };
        if (!found) return errors.fail(.scope_denied, "scope {s} is not part of profile {s}", .{ sc, cmd.binding.profile });
    }
    const existing = try loadPlan(s, a, cmd.binding.profile, cmd.kind, cmd.period);
    if (existing) |p| {
        if (cmd.expected != 0 and cmd.expected != p.revision) {
            return errors.fail(.stale_revision, "plan {s} is at revision {d}, expected {d}", .{ p.id, p.revision, cmd.expected });
        }
    } else if (cmd.expected != 0) {
        return errors.fail(.stale_revision, "no plan exists for profile {s} {s} {s}, so expected must be 0", .{ cmd.binding.profile, cmd.kind, cmd.period });
    }
    const plan_id = if (existing) |p| p.id else try std.fmt.allocPrint(a, "P-{s}-{s}-{s}", .{ cmd.binding.profile, cmd.kind, cmd.period });
    const next_rev: i64 = if (existing) |p| p.revision + 1 else 1;

    var seen = std.StringHashMap(void).init(a);
    var mit_count: i64 = 0;
    for (cmd.items) |it| {
        if (seen.contains(it.work_item_id)) return errors.invalid("duplicate plan item {s}", .{it.work_item_id});
        try seen.put(it.work_item_id, {});
        const role_ok = std.mem.eql(u8, it.role, "mit") or std.mem.eql(u8, it.role, "big_rock") or std.mem.eql(u8, it.role, "batch");
        if (!role_ok) return errors.invalid("invalid plan role \"{s}\"", .{it.role});
        if (std.mem.eql(u8, cmd.kind, "weekly") and std.mem.eql(u8, it.role, "mit")) {
            return errors.invalid("weekly plans accept big_rock and batch roles, not mit", .{});
        }
        const item = getWorkItem(s, a, .{ .profile = cmd.binding.profile, .actor = cmd.binding.actor, .scopes = owned }, it.work_item_id) catch |e| {
            if (errors.getFamily() == .not_found) return errors.fail(.not_found, "work item {s} not found", .{it.work_item_id});
            return e;
        };
        _ = item;
        if (std.mem.eql(u8, it.role, "mit")) mit_count += 1;
    }
    if (std.mem.eql(u8, cmd.kind, "daily")) {
        const needs_override = mit_count < 1 or mit_count > 3 or cmd.override_id.len > 0;
        if (needs_override) {
            const ok = try overrideApplies(s, cmd.binding.actor, cmd.period, cmd.override_id);
            if (!ok) {
                if (cmd.override_id.len > 0) {
                    return errors.invalid("daily limit override \"{s}\" does not apply to {s} for actor {s}", .{ cmd.override_id, cmd.period, cmd.binding.actor });
                }
                return errors.fail(.rules_acknowledgement_required, "daily plan has {d} MITs; 1..3 need no override, otherwise record a daily limit override", .{mit_count});
            }
        }
    }

    var plan = domain.Plan{
        .id = plan_id,
        .profile = cmd.binding.profile,
        .kind = cmd.kind,
        .period = cmd.period,
        .status = "committed",
        .revision = next_rev,
        .items = &.{},
        .created_at = now_s,
        .updated_at = now_s,
    };
    if (existing) |p| {
        plan.created_at = p.created_at;
        var upd = try s.db.prepare("UPDATE plans SET status = 'committed', revision = ?, updated_at = ? WHERE id = ?");
        defer upd.finalize();
        try upd.bindInt(1, next_rev);
        try upd.bindText(2, now_s);
        try upd.bindText(3, plan_id);
        _ = try upd.step();
    } else {
        var ins = try s.db.prepare(
            "INSERT INTO plans (id, profile_id, kind, period, status, revision, created_at, updated_at) " ++
                "VALUES (?, ?, ?, ?, 'committed', ?, ?, ?)",
        );
        defer ins.finalize();
        try ins.bindText(1, plan_id);
        try ins.bindText(2, cmd.binding.profile);
        try ins.bindText(3, cmd.kind);
        try ins.bindText(4, cmd.period);
        try ins.bindInt(5, next_rev);
        try ins.bindText(6, now_s);
        try ins.bindText(7, now_s);
        _ = try ins.step();
    }
    {
        var del = try s.db.prepare("DELETE FROM plan_items WHERE plan_id = ?");
        defer del.finalize();
        try del.bindText(1, plan_id);
        _ = try del.step();
    }
    var items = std.ArrayList(domain.PlanItem).empty;
    for (cmd.items) |it| {
        var ins = try s.db.prepare(
            "INSERT INTO plan_items (plan_id, work_item_id, role, position) VALUES (?, ?, ?, ?)",
        );
        defer ins.finalize();
        try ins.bindText(1, plan_id);
        try ins.bindText(2, it.work_item_id);
        try ins.bindText(3, it.role);
        try ins.bindInt(4, it.position);
        _ = try ins.step();
        try insertLink(s, a, "plan", plan_id, "work_item", it.work_item_id, "produced", cmd.binding.scopes[0], now);
        try items.append(a, .{ .work_item_id = it.work_item_id, .role = it.role, .position = it.position });
    }
    plan.items = items.items;
    if (decision.len > 0) {
        try insertLink(s, a, "document", decision, "plan", plan_id, "produced", cmd.binding.scopes[0], now);
    }
    try insertHistory(s, a, "plan", plan_id, "committed", "", cmd.binding.profile, next_rev, .{ .plan = plan }, now);
    try writeIdem(s, a, "commit_plan", cmd.key, &hash, .{ .plan = plan }, now);
    try s.commit();
    return plan;
}

// ---------------------------------------------------------------- focus

fn scanCheckpoint(a: std.mem.Allocator, stmt: sqlite.Statement) !domain.Checkpoint {
    const evidence = stmt.optText(4);
    return .{
        .id = try dup(a, stmt.text(0)),
        .scope = try dup(a, stmt.text(1)),
        .work_item_id = try dup(a, stmt.text(2)),
        .result = try dup(a, stmt.text(3)),
        .evidence_refs_json = if (evidence) |e| (if (std.mem.eql(u8, e, "[]") or std.mem.eql(u8, e, "null")) null else try dup(a, e)) else null,
        .uncertainties = try dup(a, stmt.text(5)),
        .next_action = try dup(a, stmt.text(6)),
        .revision = stmt.int(7),
        .created_at = try reformat(a, stmt.text(8), "checkpoints.created_at"),
    };
}

fn checkpointFromValue(a: std.mem.Allocator, v: std.json.Value) !domain.Checkpoint {
    var evidence_json: ?[]const u8 = null;
    if (jsonw.field(v, "evidence_refs")) |ev| {
        var aw = std.Io.Writer.Allocating.init(a);
        try std.json.Stringify.value(ev, .{}, &aw.writer);
        evidence_json = aw.written();
    }
    return .{
        .id = try dup(a, jsonw.strField(v, "id") orelse ""),
        .scope = try dup(a, jsonw.strField(v, "scope") orelse ""),
        .work_item_id = try dup(a, jsonw.strField(v, "work_item_id") orelse ""),
        .result = try dup(a, jsonw.strField(v, "result") orelse ""),
        .evidence_refs_json = evidence_json,
        .uncertainties = try dup(a, jsonw.strField(v, "uncertainties") orelse ""),
        .next_action = try dup(a, jsonw.strField(v, "next_action") orelse ""),
        .created_at = try dup(a, jsonw.strField(v, "created_at") orelse ""),
        .revision = jsonw.intField(v, "revision") orelse 0,
    };
}

fn focusFromValue(a: std.mem.Allocator, v: std.json.Value) !domain.FocusSession {
    return .{
        .id = try dup(a, jsonw.strField(v, "id") orelse ""),
        .profile = try dup(a, jsonw.strField(v, "profile") orelse ""),
        .actor = try dup(a, jsonw.strField(v, "actor") orelse ""),
        .work_item_id = try dup(a, jsonw.strField(v, "work_item_id") orelse ""),
        .started_at = try dup(a, jsonw.strField(v, "started_at") orelse ""),
        .ended_at = try dupOpt(a, jsonw.strField(v, "ended_at")),
        .outcome = try dupOpt(a, jsonw.strField(v, "outcome")),
    };
}

pub const FocusStartCmd = struct { binding: domain.Binding, key: []const u8, item: []const u8 };
pub const CheckpointCmd = struct {
    binding: domain.Binding,
    key: []const u8,
    item: []const u8,
    result: []const u8,
    evidence: []const []const u8 = &.{},
    uncertain: []const u8 = "",
    next_action: []const u8 = "",
};
pub const FocusFinishCmd = struct { binding: domain.Binding, key: []const u8, focus: []const u8, outcome: []const u8 = "" };
pub const FocusStartResult = struct { focus: domain.FocusSession, checkpoints: []const domain.Checkpoint };

fn writeStringArrayField(o: *jsonw.Obj, name: []const u8, items: []const []const u8) !void {
    var arr = try o.arr(name);
    for (items) |s| try arr.str(s);
    try arr.end();
}

fn writeFocusStartRequest(w: *std.Io.Writer, cmd: FocusStartCmd) !void {
    var o = try jsonw.Obj.init(w);
    try writeBinding(&o, cmd.binding);
    try o.str("Key", cmd.key);
    try o.str("Item", cmd.item);
    try o.end();
}

fn writeCheckpointRequest(w: *std.Io.Writer, cmd: CheckpointCmd) !void {
    var o = try jsonw.Obj.init(w);
    try writeBinding(&o, cmd.binding);
    try o.str("Key", cmd.key);
    try o.str("Item", cmd.item);
    try o.str("Result", cmd.result);
    try writeStringArrayField(&o, "Evidence", cmd.evidence);
    try o.str("Uncertain", cmd.uncertain);
    try o.str("NextAction", cmd.next_action);
    try o.end();
}

fn writeFocusFinishRequest(w: *std.Io.Writer, cmd: FocusFinishCmd) !void {
    var o = try jsonw.Obj.init(w);
    try writeBinding(&o, cmd.binding);
    try o.str("Key", cmd.key);
    try o.str("Focus", cmd.focus);
    try o.str("Outcome", cmd.outcome);
    try o.end();
}

fn lastCheckpoint(s: *Store, a: std.mem.Allocator, work_item_id: []const u8) !?domain.Checkpoint {
    var stmt = try s.db.prepare(
        "SELECT id, scope_id, work_item_id, result, evidence_json, uncertainties, next_action, revision, created_at " ++
            "FROM checkpoints WHERE work_item_id = ? ORDER BY revision DESC LIMIT 1",
    );
    defer stmt.finalize();
    try stmt.bindText(1, work_item_id);
    if (!try stmt.step()) return null;
    return try scanCheckpoint(a, stmt);
}

pub fn startFocus(s: *Store, a: std.mem.Allocator, cmd: FocusStartCmd, now: Timestamp) !FocusStartResult {
    try validateBinding(cmd.binding);
    try requireKey(cmd.key);
    if (trimmed(cmd.item).len == 0) return errors.invalid("work item is required", .{});
    var aw = std.Io.Writer.Allocating.init(a);
    try writeFocusStartRequest(&aw.writer, cmd);
    const hash = sha256hex(aw.written());
    const now_s = try fmtTs(a, now);

    try s.begin();
    errdefer s.rollback();
    if (try lookupIdemStmt(s, a, "focus_start", cmd.key, &hash)) |stored| {
        try s.commit();
        const parsed = std.json.parseFromSlice(std.json.Value, a, stored, .{}) catch
            return errors.fail(.io_error, "stored result is unreadable", .{});
        const fv = jsonw.field(parsed.value, "focus") orelse return errors.fail(.io_error, "stored result is unreadable", .{});
        var cps = std.ArrayList(domain.Checkpoint).empty;
        if (jsonw.arrField(parsed.value, "checkpoints")) |list| {
            for (list) |v| try cps.append(a, try checkpointFromValue(a, v));
        }
        return .{ .focus = try focusFromValue(a, fv), .checkpoints = cps.items };
    }
    const item = try getWorkItem(s, a, cmd.binding, cmd.item);
    if (!std.mem.eql(u8, item.lifecycle, "next")) {
        return errors.fail(.invalid_transition, "work item {s} is {s}, not actionable", .{ item.id, item.lifecycle });
    }
    {
        var stmt = try s.db.prepare("SELECT id FROM focus_sessions WHERE actor_id = ? AND ended_at IS NULL");
        defer stmt.finalize();
        try stmt.bindText(1, cmd.binding.actor);
        if (try stmt.step()) {
            return errors.fail(.focus_conflict, "actor {s} already has open focus {s}", .{ cmd.binding.actor, stmt.text(0) });
        }
    }
    const date = try idDate(a, now);
    const seq = try store.nextDailySeq(s.db, "focus_sessions", try std.fmt.allocPrint(a, "F-{s}-", .{date}));
    const id = try std.fmt.allocPrint(a, "F-{s}-{d:0>3}", .{ date, @as(u32, @intCast(seq)) });
    {
        var ins = try s.db.prepare(
            "INSERT INTO focus_sessions (id, profile_id, actor_id, work_item_id, started_at, ended_at, outcome, revision) " ++
                "VALUES (?, ?, ?, ?, ?, NULL, NULL, 1)",
        );
        defer ins.finalize();
        try ins.bindText(1, id);
        try ins.bindText(2, cmd.binding.profile);
        try ins.bindText(3, cmd.binding.actor);
        try ins.bindText(4, item.id);
        try ins.bindText(5, now_s);
        _ = try ins.step();
    }
    try insertLink(s, a, "work_item", item.id, "focus_session", id, "produced", item.scope, now);
    const focus = domain.FocusSession{
        .id = id,
        .profile = cmd.binding.profile,
        .actor = cmd.binding.actor,
        .work_item_id = item.id,
        .started_at = now_s,
    };
    var cps = std.ArrayList(domain.Checkpoint).empty;
    if (try lastCheckpoint(s, a, item.id)) |cp| try cps.append(a, cp);
    const result = FocusStartResult{ .focus = focus, .checkpoints = cps.items };
    try insertHistory(s, a, "focus_session", id, "started", item.scope, cmd.binding.profile, 1, .{ .focus = focus }, now);
    try writeIdem(s, a, "focus_start", cmd.key, &hash, .{ .focus_start = result }, now);
    try s.commit();
    return result;
}

pub fn recordCheckpoint(s: *Store, a: std.mem.Allocator, cmd: CheckpointCmd, now: Timestamp) !domain.Checkpoint {
    try validateBinding(cmd.binding);
    try requireKey(cmd.key);
    if (trimmed(cmd.item).len == 0) return errors.invalid("work item is required", .{});
    if (trimmed(cmd.result).len == 0) return errors.invalid("checkpoint result is required", .{});
    var aw = std.Io.Writer.Allocating.init(a);
    try writeCheckpointRequest(&aw.writer, cmd);
    const hash = sha256hex(aw.written());
    const now_s = try fmtTs(a, now);

    try s.begin();
    errdefer s.rollback();
    if (try lookupIdemStmt(s, a, "checkpoint", cmd.key, &hash)) |stored| {
        try s.commit();
        const parsed = std.json.parseFromSlice(std.json.Value, a, stored, .{}) catch
            return errors.fail(.io_error, "stored result is unreadable", .{});
        return checkpointFromValue(a, parsed.value);
    }
    const item = try getWorkItem(s, a, cmd.binding, cmd.item);
    if (std.mem.eql(u8, item.lifecycle, "archived")) {
        return errors.fail(.invalid_transition, "work item {s} is archived", .{item.id});
    }
    var focus_id: []const u8 = undefined;
    {
        var stmt = try s.db.prepare("SELECT id FROM focus_sessions WHERE actor_id = ? AND work_item_id = ? AND ended_at IS NULL");
        defer stmt.finalize();
        try stmt.bindText(1, cmd.binding.actor);
        try stmt.bindText(2, item.id);
        if (!try stmt.step()) {
            return errors.fail(.focus_conflict, "actor {s} has no open focus on work item {s}", .{ cmd.binding.actor, item.id });
        }
        focus_id = try dup(a, stmt.text(0));
    }
    var rev: i64 = 1;
    {
        var stmt = try s.db.prepare("SELECT COALESCE(MAX(revision), 0) + 1 FROM checkpoints WHERE work_item_id = ?");
        defer stmt.finalize();
        try stmt.bindText(1, item.id);
        if (try stmt.step()) rev = stmt.int(0);
    }
    var evidence_json = std.Io.Writer.Allocating.init(a);
    try writeStringArrayRaw(&evidence_json.writer, cmd.evidence);
    const date = try idDate(a, now);
    const seq = try store.nextDailySeq(s.db, "checkpoints", try std.fmt.allocPrint(a, "CP-{s}-", .{date}));
    const id = try std.fmt.allocPrint(a, "CP-{s}-{d:0>3}", .{ date, @as(u32, @intCast(seq)) });
    {
        var ins = try s.db.prepare(
            "INSERT INTO checkpoints (id, scope_id, work_item_id, focus_id, result, evidence_json, uncertainties, next_action, revision, created_at) " ++
                "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
        );
        defer ins.finalize();
        try ins.bindText(1, id);
        try ins.bindText(2, item.scope);
        try ins.bindText(3, item.id);
        try ins.bindText(4, focus_id);
        try ins.bindText(5, cmd.result);
        try ins.bindText(6, evidence_json.written());
        try ins.bindOptText(7, if (cmd.uncertain.len == 0) null else cmd.uncertain);
        try ins.bindOptText(8, if (cmd.next_action.len == 0) null else cmd.next_action);
        try ins.bindInt(9, rev);
        try ins.bindText(10, now_s);
        _ = try ins.step();
    }
    try insertLink(s, a, "focus_session", focus_id, "checkpoint", id, "produced", item.scope, now);
    const cp = domain.Checkpoint{
        .id = id,
        .scope = item.scope,
        .work_item_id = item.id,
        .result = cmd.result,
        .evidence_refs_json = if (cmd.evidence.len > 0) evidence_json.written() else null,
        .uncertainties = cmd.uncertain,
        .next_action = cmd.next_action,
        .created_at = now_s,
        .revision = rev,
    };
    try insertHistory(s, a, "checkpoint", id, "recorded", item.scope, cmd.binding.profile, rev, .{ .checkpoint = cp }, now);
    try writeIdem(s, a, "checkpoint", cmd.key, &hash, .{ .checkpoint = cp }, now);
    try s.commit();
    return cp;
}

fn writeStringArrayRaw(w: *std.Io.Writer, items: []const []const u8) !void {
    var arr = try jsonw.Arr.init(w);
    for (items) |s| try arr.str(s);
    try arr.end();
}

pub fn finishFocus(s: *Store, a: std.mem.Allocator, cmd: FocusFinishCmd, now: Timestamp) !domain.FocusSession {
    try validateBinding(cmd.binding);
    try requireKey(cmd.key);
    if (trimmed(cmd.focus).len == 0) return errors.invalid("focus id is required", .{});
    var aw = std.Io.Writer.Allocating.init(a);
    try writeFocusFinishRequest(&aw.writer, cmd);
    const hash = sha256hex(aw.written());
    const now_s = try fmtTs(a, now);

    try s.begin();
    errdefer s.rollback();
    if (try lookupIdemStmt(s, a, "focus_finish", cmd.key, &hash)) |stored| {
        try s.commit();
        const parsed = std.json.parseFromSlice(std.json.Value, a, stored, .{}) catch
            return errors.fail(.io_error, "stored result is unreadable", .{});
        return focusFromValue(a, parsed.value);
    }
    var focus = domain.FocusSession{ .id = "", .profile = "", .actor = "", .work_item_id = "", .started_at = "" };
    var revision: i64 = 0;
    var ended = false;
    {
        var stmt = try s.db.prepare(
            "SELECT profile_id, actor_id, work_item_id, started_at, ended_at, outcome, revision FROM focus_sessions WHERE id = ?",
        );
        defer stmt.finalize();
        try stmt.bindText(1, cmd.focus);
        if (!try stmt.step()) return errors.fail(.not_found, "focus {s} does not exist", .{cmd.focus});
        focus.profile = try dup(a, stmt.text(0));
        focus.actor = try dup(a, stmt.text(1));
        focus.work_item_id = try dup(a, stmt.text(2));
        focus.started_at = try reformat(a, stmt.text(3), "focus_sessions.started_at");
        focus.ended_at = try dupOpt(a, stmt.optText(4));
        focus.outcome = try dupOpt(a, stmt.optText(5));
        revision = stmt.int(6);
        ended = !stmt.isNull(4);
    }
    focus.id = cmd.focus;
    if (!std.mem.eql(u8, focus.actor, cmd.binding.actor)) {
        return errors.fail(.scope_denied, "focus {s} belongs to another actor", .{cmd.focus});
    }
    const item = try getWorkItem(s, a, cmd.binding, focus.work_item_id);
    if (ended) return errors.fail(.invalid_transition, "focus {s} is already finished", .{cmd.focus});
    {
        var upd = try s.db.prepare("UPDATE focus_sessions SET ended_at = ?, outcome = ?, revision = ? WHERE id = ? AND ended_at IS NULL");
        defer upd.finalize();
        try upd.bindText(1, now_s);
        try upd.bindOptText(2, if (cmd.outcome.len == 0) null else cmd.outcome);
        try upd.bindInt(3, revision + 1);
        try upd.bindText(4, cmd.focus);
        _ = try upd.step();
        if (s.db.changes() != 1) return errors.fail(.invalid_transition, "focus {s} is already finished", .{cmd.focus});
    }
    focus.ended_at = now_s;
    focus.outcome = if (cmd.outcome.len == 0) null else cmd.outcome;
    try insertHistory(s, a, "focus_session", cmd.focus, "finished", item.scope, cmd.binding.profile, revision + 1, .{ .focus = focus }, now);
    try writeIdem(s, a, "focus_finish", cmd.key, &hash, .{ .focus = focus }, now);
    try s.commit();
    return focus;
}

// --------------------------------------------------------------- reviews

pub const ReviewCmd = struct {
    binding: domain.Binding,
    key: []const u8,
    kind: []const u8,
    period: []const u8,
    outcomes: []const u8,
    coverage: []const u8,
    complete: bool = true,
};

fn writeReviewRequest(w: *std.Io.Writer, cmd: ReviewCmd, derive: bool, calendar_assert: []const u8) !void {
    var o = try jsonw.Obj.init(w);
    try writeBinding(&o, cmd.binding);
    try o.str("Key", cmd.key);
    if (derive) try o.boolean("Derive", true);
    if (calendar_assert.len > 0) try o.str("CalendarAssert", calendar_assert);
    try o.str("Kind", cmd.kind);
    try o.str("Period", cmd.period);
    try o.str("Outcomes", cmd.outcomes);
    try o.str("Coverage", cmd.coverage);
    try o.boolean("Complete", cmd.complete);
    try o.end();
}

fn reviewFromValue(a: std.mem.Allocator, v: std.json.Value) !domain.Review {
    return .{
        .id = try dup(a, jsonw.strField(v, "id") orelse ""),
        .profile = try dup(a, jsonw.strField(v, "profile") orelse ""),
        .kind = try dup(a, jsonw.strField(v, "kind") orelse ""),
        .period = try dup(a, jsonw.strField(v, "period") orelse ""),
        .outcomes = try dup(a, jsonw.strField(v, "outcomes") orelse ""),
        .coverage = try dup(a, jsonw.strField(v, "coverage") orelse ""),
        .completion_state = try dup(a, jsonw.strField(v, "completion_state") orelse ""),
        .created_at = try dup(a, jsonw.strField(v, "created_at") orelse ""),
    };
}

pub fn recordReview(s: *Store, a: std.mem.Allocator, cmd: ReviewCmd, derive: bool, calendar_assert: []const u8, now: Timestamp) !domain.Review {
    try validateBinding(cmd.binding);
    try requireKey(cmd.key);
    const kind_ok = std.mem.eql(u8, cmd.kind, "daily") or std.mem.eql(u8, cmd.kind, "weekly") or
        std.mem.eql(u8, cmd.kind, "monthly") or std.mem.eql(u8, cmd.kind, "yearly");
    if (!kind_ok) return errors.invalid("unknown review kind \"{s}\"", .{cmd.kind});
    if (cmd.period.len == 0) return errors.invalid("period is required", .{});
    // Validate the label once, so --derive cannot be the only thing that cares.
    _ = try periodRange(a, cmd.kind, cmd.period);
    if (cmd.outcomes.len == 0) return errors.invalid("outcomes are required", .{});
    if (cmd.coverage.len == 0) return errors.invalid("coverage is required", .{});
    var aw = std.Io.Writer.Allocating.init(a);
    try writeReviewRequest(&aw.writer, cmd, derive, calendar_assert);
    const hash = sha256hex(aw.written());
    const now_s = try fmtTs(a, now);

    try s.begin();
    errdefer s.rollback();
    if (try lookupIdemStmt(s, a, "review", cmd.key, &hash)) |stored| {
        try s.commit();
        const parsed = std.json.parseFromSlice(std.json.Value, a, stored, .{}) catch
            return errors.fail(.io_error, "stored result is unreadable", .{});
        return reviewFromValue(a, parsed.value);
    }
    const owned = profileScopes(s, a, cmd.binding.profile) catch |e| {
        if (errors.getFamily() == .not_found) return errors.fail(.not_found, "profile {s} does not exist", .{cmd.binding.profile});
        return e;
    };
    for (cmd.binding.scopes) |sc| {
        var found = false;
        for (owned) |o| if (std.mem.eql(u8, o, sc)) {
            found = true;
        };
        if (!found) return errors.fail(.scope_denied, "scope {s} is not part of profile {s}", .{ sc, cmd.binding.profile });
    }
    const state: []const u8 = if (cmd.complete) "complete" else "partial";
    // Derived metrics are computed, never claimed: SQL over the period's plans,
    // work items, captures, focus sessions and routines.
    const metrics_json: []const u8 = if (derive) try computeMetrics(s, a, cmd.binding, cmd.kind, cmd.period) else "{}";
    var existing_id: ?[]const u8 = null;
    var rev: i64 = 1;
    var created_at: []const u8 = now_s;
    {
        var stmt = try s.db.prepare(
            "SELECT id, revision, created_at FROM reviews WHERE profile_id = ? AND kind = ? AND period = ?",
        );
        defer stmt.finalize();
        try stmt.bindText(1, cmd.binding.profile);
        try stmt.bindText(2, cmd.kind);
        try stmt.bindText(3, cmd.period);
        if (try stmt.step()) {
            existing_id = try dup(a, stmt.text(0));
            rev = stmt.int(1) + 1;
            created_at = try reformat(a, stmt.text(2), "reviews.created_at");
        }
    }
    const id = existing_id orelse blk: {
        const date = try idDate(a, now);
        const seq = try store.nextDailySeq(s.db, "reviews", try std.fmt.allocPrint(a, "R-{s}-", .{date}));
        break :blk try std.fmt.allocPrint(a, "R-{s}-{d:0>3}", .{ date, @as(u32, @intCast(seq)) });
    };
    if (existing_id != null) {
        var upd = try s.db.prepare(
            "UPDATE reviews SET outcomes = ?, coverage = ?, completion_state = ?, revision = ?, metrics_json = ? WHERE id = ?",
        );
        defer upd.finalize();
        try upd.bindText(1, cmd.outcomes);
        try upd.bindText(2, cmd.coverage);
        try upd.bindText(3, state);
        try upd.bindInt(4, rev);
        try upd.bindText(5, metrics_json);
        try upd.bindText(6, id);
        _ = try upd.step();
    } else {
        var ins = try s.db.prepare(
            "INSERT INTO reviews (id, profile_id, kind, period, outcomes, coverage, completion_state, created_at, revision, metrics_json) " ++
                "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
        );
        defer ins.finalize();
        try ins.bindText(1, id);
        try ins.bindText(2, cmd.binding.profile);
        try ins.bindText(3, cmd.kind);
        try ins.bindText(4, cmd.period);
        try ins.bindText(5, cmd.outcomes);
        try ins.bindText(6, cmd.coverage);
        try ins.bindText(7, state);
        try ins.bindText(8, now_s);
        try ins.bindInt(9, rev);
        try ins.bindText(10, metrics_json);
        _ = try ins.step();
    }
    const review = domain.Review{
        .id = id,
        .profile = cmd.binding.profile,
        .kind = cmd.kind,
        .period = cmd.period,
        .outcomes = cmd.outcomes,
        .coverage = cmd.coverage,
        .completion_state = state,
        .created_at = created_at,
        .metrics_json = metrics_json,
    };
    if (derive) try linkMeasured(s, a, cmd.binding, cmd.kind, cmd.period, id, now);
    if (calendar_assert.len > 0 and std.mem.eql(u8, cmd.kind, "daily")) {
        try recordCalendarAssertion(s, a, cmd.binding, cmd.period, calendar_assert, now);
    }
    try insertHistory(s, a, "review", id, "recorded", "", cmd.binding.profile, rev, .{ .review = review }, now);
    try writeIdem(s, a, "review", cmd.key, &hash, .{ .review = review }, now);
    try s.commit();
    return review;
}

// ---- routines ----

pub const RoutineCmd = struct {
    binding: domain.Binding,
    id: []const u8,
    cadence: []const u8,
    last: []const u8 = "",
};

const routine_columns = "id, scope_id, kind, cadence, last_completed_at, active, revision";

fn scanRoutine(a: std.mem.Allocator, stmt: anytype) !domain.Routine {
    return .{
        .id = try dup(a, stmt.text(0)),
        .scope = try dup(a, stmt.text(1)),
        .kind = try dup(a, stmt.text(2)),
        .cadence = try dup(a, stmt.text(3)),
        .last_completed_at = if (stmt.optText(4)) |v| try reformat(a, v, "routines.last_completed_at") else null,
        .active = stmt.int(5) != 0,
        .revision = stmt.int(6),
    };
}

fn weekdayName(name: []const u8) ?u8 {
    const names = [_][]const u8{ "sun", "mon", "tue", "wed", "thu", "fri", "sat" };
    for (names, 0..) |n, i| {
        if (std.mem.eql(u8, name, n)) return @intCast(i);
    }
    return null;
}

/// routineDue mirrors the Go cadence rules: daily fires on a later day, weekly
/// on the first matching weekday after the last completion.
pub fn routineDue(cadence_in: []const u8, last: ?timeutil.Timestamp, date: timeutil.Timestamp) !bool {
    const cadence = trimmed(cadence_in);
    if (std.mem.eql(u8, cadence, "daily")) {
        const l = last orelse return true;
        return date > l;
    }
    if (!std.mem.startsWith(u8, cadence, "weekly:")) {
        return errors.invalid("unknown routine cadence \"{s}\"", .{cadence});
    }
    const want = weekdayName(trimmed(cadence[7..])) orelse
        return errors.invalid("unknown routine weekday in \"{s}\"", .{cadence});
    const l = last orelse return true;
    var next = l + 86400;
    var i: usize = 0;
    while (i < 7) : (i += 1) {
        if (timeutil.civilFromTimestamp(next).weekday == want) return date >= next;
        next += 86400;
    }
    return errors.fail(.io_error, "could not resolve weekly cadence \"{s}\"", .{cadence});
}

pub fn addRoutine(s: *Store, a: std.mem.Allocator, cmd: RoutineCmd) !domain.Routine {
    try validateBinding(cmd.binding);
    const id = trimmed(cmd.id);
    if (id.len == 0) return errors.invalid("routine id is required", .{});
    const cadence = trimmed(cmd.cadence);
    _ = try routineDue(cadence, null, 0);
    var last_day: ?timeutil.Timestamp = null;
    const last_raw = trimmed(cmd.last);
    if (last_raw.len > 0) {
        last_day = timeutil.parseDate(last_raw) catch
            return errors.invalid("last must be YYYY-MM-DD, got \"{s}\"", .{last_raw});
    }
    const scope = cmd.binding.scopes[0];

    try s.begin();
    errdefer s.rollback();
    var exists = try s.db.prepare("SELECT 1 FROM scopes WHERE id = ?");
    defer exists.finalize();
    try exists.bindText(1, scope);
    if (!try exists.step()) return errors.invalid("unknown scope reference {s}", .{scope});
    // routines.id is the primary key, so the guard has to be global.
    var dup_check = try s.db.prepare("SELECT 1 FROM routines WHERE id = ?");
    defer dup_check.finalize();
    try dup_check.bindText(1, id);
    if (try dup_check.step()) return errors.fail(.conflict, "routine {s} already exists", .{id});

    const last_text: ?[]const u8 = if (last_day) |d| try fmtTs(a, d) else null;
    var ins = try s.db.prepare(
        "INSERT INTO routines (id, scope_id, kind, cadence, last_completed_at, active, revision) VALUES (?, ?, 'routine', ?, ?, 1, 1)",
    );
    defer ins.finalize();
    try ins.bindText(1, id);
    try ins.bindText(2, scope);
    try ins.bindText(3, cadence);
    try ins.bindOptText(4, last_text);
    _ = try ins.step();
    try s.commit();

    return .{
        .id = try dup(a, id),
        .scope = try dup(a, scope),
        .kind = try dup(a, "routine"),
        .cadence = try dup(a, cadence),
        .last_completed_at = last_text,
        .active = true,
        .revision = 1,
    };
}

/// dueRoutines returns null, not an empty array, when nothing is due: Go keeps
/// the nil slice and the corpus compares that null.
pub fn dueRoutines(s: *Store, a: std.mem.Allocator, b: domain.Binding, date_text: []const u8) !?[]domain.Routine {
    try validateBinding(b);
    const day = timeutil.parseDate(date_text) catch
        return errors.invalid("date must be YYYY-MM-DD", .{});

    var buf = std.Io.Writer.Allocating.init(a);
    const w = &buf.writer;
    try w.writeAll("SELECT " ++ routine_columns ++ " FROM routines WHERE scope_id IN (");
    try w.writeAll(try scopeFilter(a, b.scopes.len));
    try w.writeAll(") AND active = 1 ORDER BY id");
    var stmt = try s.db.prepare(buf.written());
    defer stmt.finalize();
    _ = try scopeArgs(stmt, 1, b);

    var items = std.ArrayList(domain.Routine).empty;
    while (try stmt.step()) {
        const r = try scanRoutine(a, stmt);
        const last = if (r.last_completed_at) |v| timeutil.parseTime(v) catch null else null;
        if (try routineDue(r.cadence, last, day)) try items.append(a, r);
    }
    if (items.items.len == 0) return null;
    return items.items;
}

pub fn completeRoutine(s: *Store, a: std.mem.Allocator, b: domain.Binding, id: []const u8, date_text: []const u8) !domain.Routine {
    try validateBinding(b);
    const day = timeutil.parseDate(date_text) catch
        return errors.invalid("date must be YYYY-MM-DD", .{});

    try s.begin();
    errdefer s.rollback();
    var sql_buf = std.Io.Writer.Allocating.init(a);
    const w = &sql_buf.writer;
    try w.writeAll("SELECT " ++ routine_columns ++ " FROM routines WHERE id = ? AND scope_id IN (");
    try w.writeAll(try scopeFilter(a, b.scopes.len));
    try w.writeAll(")");
    var stmt = try s.db.prepare(sql_buf.written());
    defer stmt.finalize();
    try stmt.bindText(1, id);
    _ = try scopeArgs(stmt, 2, b);
    if (!try stmt.step()) return rowAccessError(s, "routines", "routine", id);
    var r = try scanRoutine(a, stmt);
    if (!r.active) return errors.fail(.invalid_transition, "routine {s} is inactive", .{id});

    const day_text = try fmtTs(a, day);
    var upd = try s.db.prepare("UPDATE routines SET last_completed_at = ?, revision = ? WHERE id = ? AND scope_id = ?");
    defer upd.finalize();
    try upd.bindText(1, day_text);
    try upd.bindInt(2, r.revision + 1);
    try upd.bindText(3, id);
    try upd.bindText(4, r.scope);
    _ = try upd.step();
    try s.commit();

    r.last_completed_at = day_text;
    r.revision += 1;
    return r;
}

// ---- check ----

pub const CheckReport = struct {
    ok: bool,
    errors: []const []const u8,
};

const CheckRun = struct {
    s: *Store,
    a: std.mem.Allocator,
    failures: std.ArrayList([]const u8) = .empty,

    fn fail(self: *CheckRun, comptime fmt: []const u8, args: anytype) !void {
        try self.failures.append(self.a, try std.fmt.allocPrint(self.a, fmt, args));
    }

    /// Runs a single-column id query, binding the scope list and/or profile.
    fn collect(self: *CheckRun, query: []const u8, b: ?domain.Binding, profile: ?[]const u8) ![]const []const u8 {
        var stmt = try self.s.db.prepare(query);
        defer stmt.finalize();
        var idx: c_int = 1;
        if (b) |binding| idx = try scopeArgs(stmt, idx, binding);
        if (profile) |p| {
            try stmt.bindText(idx, p);
            idx += 1;
        }
        var out: std.ArrayList([]const u8) = .empty;
        while (try stmt.step()) try out.append(self.a, try dup(self.a, stmt.text(0)));
        return out.items;
    }
};

fn cat(a: std.mem.Allocator, base: []const u8, suffix: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, "{s}{s}", .{ base, suffix });
}

/// Valida el store completo. Con binding, los checks de fila se limitan a sus
/// scopes y perfil; la integridad referencial siempre cubre toda la base.
pub fn runCheck(s: *Store, a: std.mem.Allocator, b: ?domain.Binding) !CheckReport {
    var run = CheckRun{ .s = s, .a = a };
    if (b) |binding| try validateBinding(binding);

    var scope_sql: []const u8 = "";
    if (b) |binding| scope_sql = try std.fmt.allocPrint(a, " AND scope_id IN ({s})", .{try scopeFilter(a, binding.scopes.len)});
    const plan_sql = " AND profile_id = ?";
    const bound = b != null;
    const profile: ?[]const u8 = if (b) |binding| binding.profile else null;

    // 1. Integridad referencial.
    {
        var stmt = try s.db.prepare("PRAGMA foreign_key_check");
        defer stmt.finalize();
        while (try stmt.step()) {
            const rowid = if (stmt.isNull(1)) "NULL" else stmt.text(1);
            try run.fail("foreign key violation in {s} (rowid {s}) references {s}", .{ stmt.text(0), rowid, stmt.text(2) });
        }
    }

    // 2. Campos requeridos.
    for (try run.collect(try cat(a, "SELECT id FROM work_items WHERE title IS NULL OR trim(title) = ''", scope_sql), b, null)) |id|
        try run.fail("work item {s} has no title", .{id});
    for (try run.collect(try cat(a, "SELECT id FROM work_items WHERE json_valid(custom_fields) = 0 OR json_type(custom_fields) <> 'object'", scope_sql), b, null)) |id|
        try run.fail("work item {s} has custom fields that are not a JSON object", .{id});
    for (try run.collect(try cat(a, "SELECT id FROM captures WHERE original_text = '' OR content_hash = ''", scope_sql), b, null)) |id|
        try run.fail("capture {s} is missing original text or content hash", .{id});
    for (try run.collect(try cat(a, "SELECT id FROM plans WHERE trim(period) = ''", plan_sql), null, profile)) |id|
        try run.fail("plan {s} has no period", .{id});
    for (try run.collect("SELECT id FROM scopes WHERE trim(name) = ''", null, null)) |id|
        try run.fail("scope {s} has no name", .{id});

    // 3. Invariantes de espera y archivo.
    for (try run.collect(try cat(a, "SELECT id FROM work_items WHERE lifecycle = 'waiting' AND (waiting_on IS NULL OR waiting_on = '')", scope_sql), b, null)) |id|
        try run.fail("work item {s} is waiting without waiting_on", .{id});
    for (try run.collect(try cat(a, "SELECT id FROM work_items WHERE lifecycle = 'archived' AND (closed_at IS NULL OR resolution IS NULL OR resolution = '')", scope_sql), b, null)) |id|
        try run.fail("work item {s} is archived without closed_at or resolution", .{id});
    for (try run.collect(try cat(a, "SELECT id FROM work_items WHERE lifecycle <> 'archived' AND (closed_at IS NOT NULL OR closure_kind IS NOT NULL OR (resolution IS NOT NULL AND resolution <> ''))", scope_sql), b, null)) |id|
        try run.fail("work item {s} carries closure fields while not archived", .{id});

    // 4. Estado de captura frente a review_after y outcome.
    for (try run.collect(try cat(a, "SELECT id FROM captures WHERE (processing_state = 'deferred') <> (review_after IS NOT NULL)", scope_sql), b, null)) |id|
        try run.fail("capture {s} has a review_after that does not match its state", .{id});
    for (try run.collect(try cat(a, "SELECT id FROM captures WHERE processing_state IN ('processed','discarded') AND processing_outcome IS NULL", scope_sql), b, null)) |id|
        try run.fail("capture {s} is processed or discarded without a recorded outcome", .{id});
    for (try run.collect(try cat(a, "SELECT id FROM captures WHERE processing_state = 'pending' AND processing_outcome IS NOT NULL", scope_sql), b, null)) |id|
        try run.fail("capture {s} is pending with a recorded outcome", .{id});

    // 5. Identidad externa completa y sin duplicados.
    for (try run.collect(try cat(a, "SELECT id FROM captures WHERE external_id IS NOT NULL AND external_revision IS NULL", scope_sql), b, null)) |id|
        try run.fail("capture {s} has an external id without an external revision", .{id});
    for (try run.collect(try cat(a, "SELECT id FROM captures WHERE external_revision IS NOT NULL AND external_id IS NULL", scope_sql), b, null)) |id|
        try run.fail("capture {s} has an external revision without an external id", .{id});
    for (try run.collect(
        try cat(a, "SELECT scope_id || '/' || source_id || '/' || external_id || '/' || ifnull(external_revision, '<null>') FROM captures WHERE external_id IS NOT NULL", try std.fmt.allocPrint(a, "{s} GROUP BY scope_id, source_id, external_id, external_revision HAVING count(*) > 1", .{scope_sql})),
        b,
        null,
    )) |id| try run.fail("duplicate external identity {s}", .{id});

    // 6. Registro de fuentes.
    for (try run.collect(try cat(a, "SELECT id FROM sources WHERE NOT EXISTS (SELECT 1 FROM scopes WHERE scopes.id = sources.scope_id)", scope_sql), b, null)) |id|
        try run.fail("source {s} references a missing scope", .{id});
    for (try run.collect("SELECT id FROM sources GROUP BY id HAVING count(*) > 1", null, null)) |id|
        try run.fail("duplicate source id {s}", .{id});
    for (try run.collect("SELECT id FROM source_reviews WHERE NOT EXISTS (SELECT 1 FROM sources WHERE sources.id = source_reviews.source_id)", null, null)) |id|
        try run.fail("source review {s} references a missing source", .{id});
    for (try run.collect("SELECT id FROM source_reviews WHERE result_kind NOT IN ('observed','reported') OR coverage_state NOT IN ('unknown','unverified','partial','complete','failed')", null, null)) |id|
        try run.fail("source review {s} has an invalid result kind or coverage", .{id});
    for (try run.collect(try cat(a, "SELECT id FROM captures WHERE external_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM sources WHERE sources.id = captures.source_id)", scope_sql), b, null)) |id|
        try run.fail("capture {s} references a missing source", .{id});

    // 7. Capa de documentos.
    for (try run.collect(try cat(a, "SELECT id FROM documents WHERE NOT EXISTS (SELECT 1 FROM scopes WHERE scopes.id = documents.scope_id)", scope_sql), b, null)) |id|
        try run.fail("document {s} references a missing scope", .{id});
    for (try run.collect(try cat(a, "SELECT id FROM documents WHERE kind NOT IN ('knowledge','knowledge_index','project_note','plan_daily','plan_weekly','review','journal','calendar','adoption','passion','routine')", scope_sql), b, null)) |id|
        try run.fail("document {s} has an unknown kind", .{id});
    for (try run.collect(try cat(a, "SELECT id FROM documents WHERE status NOT IN ('draft','verified','superseded')", scope_sql), b, null)) |id|
        try run.fail("document {s} has an unknown status", .{id});
    for (try run.collect(try cat(a, "SELECT id FROM documents WHERE trim(slug) = ''", scope_sql), b, null)) |id|
        try run.fail("document {s} has an empty slug", .{id});

    // 8. Metadatos de repositorio de proyectos.
    for (try run.collect(try cat(a, "SELECT id FROM projects WHERE clone_path <> '' AND NOT (substr(clone_path, 1, 1) IN ('/', '\\') OR (length(clone_path) >= 3 AND substr(clone_path, 1, 1) GLOB '[A-Za-z]' AND substr(clone_path, 2, 1) = ':' AND substr(clone_path, 3, 1) IN ('/', '\\')))", scope_sql), b, null)) |id|
        try run.fail("project {s} has a relative clone path", .{id});
    for (try run.collect(try cat(a, "SELECT id FROM projects WHERE clone_path <> '' AND ('/' || replace(clone_path, '\\', '/') || '/') LIKE '%/../%'", scope_sql), b, null)) |id|
        try run.fail("project {s} has a clone path with a .. segment", .{id});
    for (try run.collect(try cat(a, "SELECT id FROM projects WHERE repo_url <> '' AND instr(repo_url, '://') = 0 AND repo_url NOT GLOB '*@*:*'", scope_sql), b, null)) |id|
        try run.fail("project {s} has a non-absolute repository url", .{id});

    // 9. Historial como evidencia de cada mutación.
    for (try run.collect(try cat(a, "SELECT id FROM captures WHERE NOT EXISTS (SELECT 1 FROM history_events h WHERE h.entity_type = 'capture' AND h.entity_id = captures.id)", scope_sql), b, null)) |id|
        try run.fail("capture {s} has no history events", .{id});
    for (try run.collect(try cat(a, "SELECT id FROM work_items WHERE NOT EXISTS (SELECT 1 FROM history_events h WHERE h.entity_type = 'work_item' AND h.entity_id = work_items.id)", scope_sql), b, null)) |id|
        try run.fail("work item {s} has no history events", .{id});
    for (try run.collect(try cat(a, "SELECT id FROM plans WHERE NOT EXISTS (SELECT 1 FROM history_events h WHERE h.entity_type = 'plan' AND h.entity_id = plans.id)", plan_sql), null, profile)) |id|
        try run.fail("plan {s} has no history events", .{id});

    // 10. Work items de planes fuera de los scopes del perfil.
    {
        const base = "SELECT pi.work_item_id, pi.plan_id FROM plan_items pi JOIN plans p ON p.id = pi.plan_id JOIN work_items w ON w.id = pi.work_item_id WHERE w.scope_id NOT IN (SELECT scope_id FROM profile_scopes WHERE profile_id = p.profile_id)";
        const query = if (bound) try cat(a, base, " AND p.profile_id = ?") else base;
        var stmt = try s.db.prepare(query);
        defer stmt.finalize();
        if (profile) |p| try stmt.bindText(1, p);
        while (try stmt.step()) {
            try run.fail("plan {s} references work item {s} outside the profile scopes", .{ stmt.text(1), stmt.text(0) });
        }
    }

    // 11. Invariantes de recorrido.
    for (try run.collect("SELECT actor_id FROM focus_sessions WHERE ended_at IS NULL GROUP BY actor_id HAVING count(*) > 1", null, null)) |id|
        try run.fail("actor {s} has more than one open focus", .{id});
    for (try run.collect("SELECT f.id FROM focus_sessions f JOIN work_items w ON w.id = f.work_item_id WHERE w.scope_id NOT IN (SELECT scope_id FROM profile_scopes WHERE profile_id = f.profile_id)", null, null)) |id|
        try run.fail("focus {s} uses a work item outside its profile scopes", .{id});
    for (try run.collect("SELECT c.id FROM checkpoints c JOIN work_items w ON w.id = c.work_item_id WHERE c.scope_id <> w.scope_id", null, null)) |id|
        try run.fail("checkpoint {s} has a scope that differs from its work item", .{id});
    for (try run.collect("SELECT profile_id || '/' || kind || '/' || period FROM reviews GROUP BY profile_id, kind, period HAVING count(*) > 1", null, null)) |id|
        try run.fail("review {s} duplicates a profile/kind/period", .{id});

    // 12. Solo avisa a quien practica la aserción de calendario: un perfil sin
    // ninguna aserción no la usa, así que no se le exige.
    if (b) |binding| {
        const q = "SELECT r.id FROM reviews r WHERE r.kind = 'daily' AND r.profile_id = ? AND EXISTS (SELECT 1 FROM calendar_review_assertions cra WHERE cra.profile_id = r.profile_id) AND NOT EXISTS (SELECT 1 FROM calendar_review_assertions cra WHERE cra.profile_id = r.profile_id AND cra.actor_id = ? AND cra.local_date = r.period)";
        var stmt = try s.db.prepare(q);
        defer stmt.finalize();
        try stmt.bindText(1, binding.profile);
        try stmt.bindText(2, binding.actor);
        while (try stmt.step()) try run.fail("daily review {s} has no calendar assertion", .{stmt.text(0)});
    }

    return .{ .ok = run.failures.items.len == 0, .errors = run.failures.items };
}

// ------------------------------------------------------------ documents

pub const document_columns = "id, scope_id, kind, slug, title, body, status, revision, created_at, updated_at, record_kind, rationale, options_json, approved_by, approved_at, valid_from, supersedes_id";
const joined_document_columns = "documents.id, documents.scope_id, documents.kind, documents.slug, documents.title, documents.body, documents.status, documents.revision, documents.created_at, documents.updated_at, documents.record_kind, documents.rationale, documents.options_json, documents.approved_by, documents.approved_at, documents.valid_from, documents.supersedes_id";

pub const document_kinds = [_][]const u8{
    "knowledge", "knowledge_index", "project_note", "plan_daily", "plan_weekly",
    "review",    "journal",         "calendar",     "adoption",   "passion",
    "routine",
};

pub fn validDocumentKind(kind: []const u8) bool {
    for (document_kinds) |k| if (std.mem.eql(u8, k, kind)) return true;
    return false;
}

pub fn validDocumentStatus(status: []const u8) bool {
    return std.mem.eql(u8, status, "draft") or
        std.mem.eql(u8, status, "verified") or
        std.mem.eql(u8, status, "superseded");
}

fn validDocumentSlug(slug: []const u8) bool {
    if (slug.len == 0) return false;
    for (slug) |ch| {
        if (!(std.ascii.isAlphanumeric(ch) or ch == '.' or ch == '_' or ch == '/' or ch == '-')) return false;
    }
    return true;
}

fn scanDocument(a: std.mem.Allocator, stmt: sqlite.Statement) !domain.Document {
    return .{
        .id = try dup(a, stmt.text(0)),
        .scope = try dup(a, stmt.text(1)),
        .kind = try dup(a, stmt.text(2)),
        .slug = try dup(a, stmt.text(3)),
        .title = try dup(a, stmt.text(4)),
        .body = try dup(a, stmt.text(5)),
        .status = try dup(a, stmt.text(6)),
        .revision = stmt.int(7),
        .created_at = try reformat(a, stmt.text(8), "documents.created_at"),
        .updated_at = try reformat(a, stmt.text(9), "documents.updated_at"),
        .record_kind = try dupOpt(a, stmt.optText(10)),
        .rationale = try dupOpt(a, stmt.optText(11)),
        .options_json = try dupOpt(a, stmt.optText(12)),
        .approved_by = try dupOpt(a, stmt.optText(13)),
        .approved_at = try dupOpt(a, stmt.optText(14)),
        .valid_from = try dupOpt(a, stmt.optText(15)),
        .supersedes_id = try dupOpt(a, stmt.optText(16)),
    };
}

fn documentFromValue(a: std.mem.Allocator, v: std.json.Value) !domain.Document {
    return .{
        .id = try dup(a, jsonw.strField(v, "id") orelse return errors.invalid("document result is missing id", .{})),
        .scope = try dup(a, jsonw.strField(v, "scope") orelse ""),
        .kind = try dup(a, jsonw.strField(v, "kind") orelse ""),
        .slug = try dup(a, jsonw.strField(v, "slug") orelse ""),
        .title = try dup(a, jsonw.strField(v, "title") orelse ""),
        .body = try dup(a, jsonw.strField(v, "body") orelse ""),
        .status = try dup(a, jsonw.strField(v, "status") orelse ""),
        .revision = jsonw.intField(v, "revision") orelse 0,
        .created_at = try dup(a, jsonw.strField(v, "created_at") orelse ""),
        .updated_at = try dup(a, jsonw.strField(v, "updated_at") orelse ""),
        .record_kind = try dupOpt(a, jsonw.strField(v, "record_kind")),
        .rationale = try dupOpt(a, jsonw.strField(v, "rationale")),
        .options_json = blk: {
            const opt = jsonw.field(v, "options") orelse break :blk null;
            var ow = std.Io.Writer.Allocating.init(a);
            try jsonw.writeValue(a, &ow.writer, opt);
            break :blk try dup(a, ow.written());
        },
        .approved_by = try dupOpt(a, jsonw.strField(v, "approved_by")),
        .approved_at = try dupOpt(a, jsonw.strField(v, "approved_at")),
        .valid_from = try dupOpt(a, jsonw.strField(v, "valid_from")),
        .supersedes_id = try dupOpt(a, jsonw.strField(v, "supersedes_id")),
    };
}

fn requireScopeDeclared(s: *Store, scope: []const u8) !void {
    var stmt = try s.db.prepare("SELECT 1 FROM scopes WHERE id = ?");
    defer stmt.finalize();
    try stmt.bindText(1, scope);
    if (!try stmt.step()) return errors.invalid("unknown scope reference {s}", .{scope});
}

pub const DocumentCmd = struct {
    binding: domain.Binding,
    scope: []const u8 = "",
    kind: []const u8,
    slug: []const u8,
    title: []const u8,
    body: []const u8,
    status: []const u8 = "draft",
    expected: i64 = 0,
    draft_only: bool = false,
    record_kind: []const u8 = "",
    rationale: []const u8 = "",
    options_json: []const u8 = "",
    evidence: []const []const u8 = &.{},
    approved_by: []const u8 = "",
    valid_from: []const u8 = "",
};

pub const record_kinds = [_][]const u8{ "fact", "decision", "constraint", "procedure", "reference" };

pub fn validRecordKind(kind: []const u8) bool {
    for (record_kinds) |k| if (std.mem.eql(u8, k, kind)) return true;
    return false;
}

fn validateDocumentCmd(cmd: DocumentCmd) !void {
    try validateBinding(cmd.binding);
    if (cmd.scope.len > 0 and !cmd.binding.allows(cmd.scope)) {
        return errors.fail(.scope_denied, "document scope is outside this binding", .{});
    }
    if (!validDocumentKind(cmd.kind)) {
        return errors.invalid("unknown document kind \"{s}\"", .{cmd.kind});
    }
    if (!validDocumentStatus(cmd.status)) {
        return errors.invalid("unknown document status \"{s}\" (want draft, verified or superseded)", .{cmd.status});
    }
    // Superseded is a verdict produced by `doc supersede`, never a plain write:
    // setting it directly can leave a dead document or two live versions.
    if (std.mem.eql(u8, cmd.status, "superseded")) {
        return errors.invalid("use `doc supersede OLD NEW` to supersede a document", .{});
    }
    if (!validDocumentSlug(cmd.slug)) {
        return errors.invalid("document slug must be non-empty and use only letters, digits, -, _, / and .", .{});
    }
    if (trimmed(cmd.title).len == 0) return errors.invalid("document title is required", .{});
    if (trimmed(cmd.body).len == 0) return errors.invalid("document body is required", .{});
    if (cmd.expected < 0) return errors.invalid("expected revision cannot be negative", .{});
    if (cmd.draft_only and !std.mem.eql(u8, cmd.status, "draft")) {
        return errors.invalid("draft-only write cannot set status \"{s}\" (want draft)", .{cmd.status});
    }
    if (cmd.record_kind.len > 0 and !validRecordKind(cmd.record_kind)) {
        return errors.invalid("unknown record kind \"{s}\" (want fact, decision, constraint, procedure or reference)", .{cmd.record_kind});
    }
    if (cmd.options_json.len > 0) {
        const parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, cmd.options_json, .{}) catch
            return errors.invalid("options must be a JSON array", .{});
        defer parsed.deinit();
        if (parsed.value != .array) return errors.invalid("options must be a JSON array", .{});
    }
    if (cmd.status.len > 0 and std.mem.eql(u8, cmd.status, "verified") and
        std.mem.eql(u8, cmd.record_kind, "decision") and cmd.approved_by.len == 0)
    {
        return errors.invalid("approved_by is required to verify a decision", .{});
    }
    for (cmd.evidence) |id| {
        if (trimmed(id).len == 0) return errors.invalid("evidence id must not be blank", .{});
    }
}

fn writeDocumentRequest(w: *std.Io.Writer, cmd: DocumentCmd) !void {
    var o = try jsonw.Obj.init(w);
    try writeBinding(&o, .{ .profile = "", .actor = "", .scopes = &.{} });
    try o.str("Kind", cmd.kind);
    try o.str("Slug", cmd.slug);
    try o.str("Title", cmd.title);
    try o.str("Body", cmd.body);
    try o.str("Status", cmd.status);
    try o.int("Expected", cmd.expected);
    try o.str("RecordKind", cmd.record_kind);
    try o.str("Rationale", cmd.rationale);
    try o.str("Options", cmd.options_json);
    var ev = try o.arr("Evidence");
    for (cmd.evidence) |id| try ev.str(id);
    try ev.end();
    try o.str("ApprovedBy", cmd.approved_by);
    try o.str("ValidFrom", cmd.valid_from);
    try o.end();
}

pub fn putDocument(s: *Store, a: std.mem.Allocator, cmd: DocumentCmd, now: Timestamp) !domain.Document {
    try validateDocumentCmd(cmd);
    const scope = if (cmd.scope.len > 0) cmd.scope else cmd.binding.scopes[0];

    var aw = std.Io.Writer.Allocating.init(a);
    try writeDocumentRequest(&aw.writer, cmd);
    const hash = sha256hex(aw.written());
    // The key carries the payload hash: an unconditional put of the same slug
    // is a new request, while an exact retry still replays.
    const key = try std.fmt.allocPrint(a, "{s}|{s}|{s}|{d}|{s}", .{ scope, cmd.kind, cmd.slug, cmd.expected, &hash });

    try s.begin();
    errdefer s.rollback();
    if (try lookupIdemStmt(s, a, "doc put", key, &hash)) |stored| {
        const doc = try docFromStored(a, stored);
        try s.commit();
        return doc;
    }
    // Releases before the hash was part of the key stored it without it; a retry
    // of a write that succeeded then must replay instead of bumping the revision.
    const legacy_key = try std.fmt.allocPrint(a, "{s}|{s}|{s}|{d}", .{ scope, cmd.kind, cmd.slug, cmd.expected });
    if (try lookupIdemStmt(s, a, "doc put", legacy_key, &hash)) |stored| {
        const doc = try docFromStored(a, stored);
        try s.commit();
        return doc;
    }
    try requireScopeDeclared(s, scope);

    var existing: ?domain.Document = null;
    {
        var q = try s.db.prepare("SELECT " ++ document_columns ++ " FROM documents WHERE scope_id = ? AND kind = ? AND slug = ?");
        defer q.finalize();
        try q.bindText(1, scope);
        try q.bindText(2, cmd.kind);
        try q.bindText(3, cmd.slug);
        if (try q.step()) existing = try scanDocument(a, q);
    }

    const now_s = try fmtTs(a, now);
    const event: []const u8 = if (existing) |e| blk: {
        if (cmd.draft_only and cmd.expected == 0) {
            return errors.fail(
                .stale_revision,
                "document {s}/{s} already exists at revision {d} in scope {s}, so expected must be its current revision",
                .{ cmd.kind, cmd.slug, e.revision, scope },
            );
        }
        if (cmd.expected != 0 and cmd.expected != e.revision) {
            return errors.fail(.stale_revision, "document {s}/{s} is at revision {d}, expected {d}", .{ cmd.kind, cmd.slug, e.revision, cmd.expected });
        }
        if (cmd.draft_only and !std.mem.eql(u8, e.status, "draft")) {
            return errors.fail(.invalid_transition, "document {s}/{s} is {s}, so a draft-only write cannot update it", .{ cmd.kind, cmd.slug, e.status });
        }
        if (std.mem.eql(u8, e.status, "superseded")) {
            return errors.fail(.invalid_transition, "document {s}/{s} is superseded; write its successor instead", .{ cmd.kind, cmd.slug });
        }
        break :blk "updated";
    } else blk: {
        if (cmd.expected != 0) {
            return errors.fail(.stale_revision, "no document {s}/{s} exists in scope {s}, so expected must be 0", .{ cmd.kind, cmd.slug, scope });
        }
        break :blk "created";
    };

    const rec_kind: ?[]const u8 = if (cmd.record_kind.len > 0) try dup(a, cmd.record_kind) else if (existing) |e| e.record_kind else null;
    const rationale: ?[]const u8 = if (cmd.rationale.len > 0) try dup(a, cmd.rationale) else if (existing) |e| e.rationale else null;
    const options: ?[]const u8 = if (cmd.options_json.len > 0) try dup(a, cmd.options_json) else if (existing) |e| e.options_json else null;
    // An approval covers the exact body that was approved, nothing else.
    const same_body = if (existing) |e| std.mem.eql(u8, e.body, cmd.body) else false;
    const approved_by: ?[]const u8 = if (cmd.approved_by.len > 0)
        try dup(a, cmd.approved_by)
    else if (existing) |e|
        (if (same_body) e.approved_by else null)
    else
        null;
    const valid_from: ?[]const u8 = if (cmd.valid_from.len > 0) try dup(a, cmd.valid_from) else if (existing) |e| e.valid_from else null;
    const approved_at: ?[]const u8 = if (approved_by != null and std.mem.eql(u8, cmd.status, "verified")) now_s else null;
    if (approved_by == null and std.mem.eql(u8, cmd.status, "verified") and
        rec_kind != null and std.mem.eql(u8, rec_kind.?, "decision"))
    {
        return errors.invalid("approved_by is required to verify a decision", .{});
    }

    var out: domain.Document = undefined;
    if (existing) |e| {
        out = .{
            .id = e.id,
            .scope = e.scope,
            .kind = e.kind,
            .slug = e.slug,
            .title = try dup(a, cmd.title),
            .body = try dup(a, cmd.body),
            .status = try dup(a, cmd.status),
            .revision = e.revision + 1,
            .created_at = e.created_at,
            .updated_at = now_s,
            .record_kind = rec_kind,
            .rationale = rationale,
            .options_json = options,
            .approved_by = approved_by,
            .approved_at = approved_at,
            .valid_from = valid_from,
            .supersedes_id = e.supersedes_id,
        };
        var up = try s.db.prepare(
            "UPDATE documents SET title = ?, body = ?, status = ?, revision = ?, updated_at = ?, record_kind = ?, " ++
                "rationale = ?, options_json = ?, approved_by = ?, approved_at = ?, valid_from = ? " ++
                "WHERE id = ? AND scope_id = ? AND kind = ? AND slug = ?",
        );
        defer up.finalize();
        try up.bindText(1, out.title);
        try up.bindText(2, out.body);
        try up.bindText(3, out.status);
        try up.bindInt(4, out.revision);
        try up.bindText(5, out.updated_at);
        try up.bindOptText(6, out.record_kind);
        try up.bindOptText(7, out.rationale);
        try up.bindOptText(8, out.options_json);
        try up.bindOptText(9, out.approved_by);
        try up.bindOptText(10, out.approved_at);
        try up.bindOptText(11, out.valid_from);
        try up.bindText(12, out.id);
        try up.bindText(13, scope);
        try up.bindText(14, cmd.kind);
        try up.bindText(15, cmd.slug);
        _ = try up.step();
    } else {
        const id = try std.fmt.allocPrint(a, "doc:{s}:{s}:{s}", .{ scope, cmd.kind, cmd.slug });
        out = .{
            .id = id,
            .scope = try dup(a, scope),
            .kind = try dup(a, cmd.kind),
            .slug = try dup(a, cmd.slug),
            .title = try dup(a, cmd.title),
            .body = try dup(a, cmd.body),
            .status = try dup(a, cmd.status),
            .revision = 1,
            .created_at = now_s,
            .updated_at = now_s,
            .record_kind = rec_kind,
            .rationale = rationale,
            .options_json = options,
            .approved_by = approved_by,
            .approved_at = approved_at,
            .valid_from = valid_from,
        };
        var ins = try s.db.prepare(
            "INSERT INTO documents (id, scope_id, kind, slug, title, body, status, revision, created_at, updated_at, " ++
                "record_kind, rationale, options_json, approved_by, approved_at, valid_from) " ++
                "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
        );
        defer ins.finalize();
        try ins.bindText(1, out.id);
        try ins.bindText(2, out.scope);
        try ins.bindText(3, out.kind);
        try ins.bindText(4, out.slug);
        try ins.bindText(5, out.title);
        try ins.bindText(6, out.body);
        try ins.bindText(7, out.status);
        try ins.bindInt(8, out.revision);
        try ins.bindText(9, out.created_at);
        try ins.bindText(10, out.updated_at);
        try ins.bindOptText(11, out.record_kind);
        try ins.bindOptText(12, out.rationale);
        try ins.bindOptText(13, out.options_json);
        try ins.bindOptText(14, out.approved_by);
        try ins.bindOptText(15, out.approved_at);
        try ins.bindOptText(16, out.valid_from);
        _ = try ins.step();
    }

    for (cmd.evidence) |ev_id| {
        const ev_kind = entityKind(ev_id) orelse return errors.invalid("unknown evidence id \"{s}\"", .{ev_id});
        if (!try entityLinkedInScope(s, ev_kind, ev_id, scope)) {
            return errors.fail(.not_found, "evidence {s} not found", .{ev_id});
        }
        try insertLink(s, a, "document", out.id, ev_kind, ev_id, "evidence", scope, now);
    }

    try insertHistory(s, a, "document", out.id, event, scope, "", out.revision, .{ .document = out }, now);
    try writeIdem(s, a, "doc put", key, &hash, .{ .document = out }, now);
    try s.commit();
    return out;
}

fn docFromStored(a: std.mem.Allocator, stored: []const u8) !domain.Document {
    const parsed = std.json.parseFromSlice(std.json.Value, a, stored, .{}) catch
        return errors.invalid("stored document result is not valid JSON", .{});
    return try documentFromValue(a, parsed.value);
}

pub fn getDocument(s: *Store, a: std.mem.Allocator, b: domain.Binding, kind: []const u8, slug: []const u8, scope: []const u8) !domain.Document {
    try validateBinding(b);
    var sql_buf = std.Io.Writer.Allocating.init(a);
    try sql_buf.writer.writeAll("SELECT " ++ document_columns ++ " FROM documents WHERE scope_id ");
    if (scope.len > 0) {
        if (!b.allows(scope)) return errors.fail(.scope_denied, "document scope is outside this binding", .{});
        try sql_buf.writer.writeAll("= ?");
    } else {
        try sql_buf.writer.print("IN ({s})", .{try scopeFilter(a, b.scopes.len)});
    }
    try sql_buf.writer.writeAll(" AND kind = ? AND slug = ? ORDER BY scope_id LIMIT 2");
    var q = try s.db.prepare(sql_buf.written());
    defer q.finalize();
    var idx: c_int = 1;
    if (scope.len > 0) {
        try q.bindText(idx, scope);
        idx += 1;
    } else {
        idx = try scopeArgs(q, idx, b);
    }
    try q.bindText(idx, kind);
    try q.bindText(idx + 1, slug);
    if (!try q.step()) return errors.fail(.not_found, "document {s}/{s} not found", .{ kind, slug });
    const doc = try scanDocument(a, q);
    if (try q.step()) {
        return errors.fail(.conflict, "document {s}/{s} exists in multiple bound scopes; specify scope", .{ kind, slug });
    }
    return doc;
}

pub fn listDocuments(s: *Store, a: std.mem.Allocator, b: domain.Binding, kind: []const u8) ![]const domain.Document {
    try validateBinding(b);
    var sql_buf = std.Io.Writer.Allocating.init(a);
    try sql_buf.writer.print("SELECT " ++ document_columns ++ " FROM documents WHERE scope_id IN ({s})", .{try scopeFilter(a, b.scopes.len)});
    if (kind.len > 0) try sql_buf.writer.writeAll(" AND kind = ?");
    try sql_buf.writer.writeAll(" ORDER BY kind, slug");
    var q = try s.db.prepare(sql_buf.written());
    defer q.finalize();
    var idx = try scopeArgs(q, 1, b);
    if (kind.len > 0) {
        try q.bindText(idx, kind);
        idx += 1;
    }
    var out: std.ArrayList(domain.Document) = .empty;
    while (try q.step()) try out.append(a, try scanDocument(a, q));
    return out.items;
}

pub const DocumentSearchHit = struct {
    document: domain.Document,
    rank: f64,
    snippet: []const u8,
};

fn ftsQuery(a: std.mem.Allocator, query: []const u8) ![]const u8 {
    var aw = std.Io.Writer.Allocating.init(a);
    var it = std.mem.tokenizeAny(u8, query, " \t\n\r\x0b\x0c");
    var first = true;
    while (it.next()) |token| {
        if (!first) try aw.writer.writeAll(" AND ");
        first = false;
        try aw.writer.writeByte('"');
        for (token) |ch| {
            if (ch == '"') try aw.writer.writeByte('"');
            try aw.writer.writeByte(ch);
        }
        try aw.writer.writeByte('"');
    }
    return aw.written();
}

pub const DocumentLogEntry = struct {
    seq: i64,
    event: []const u8,
    revision: i64,
    created_at: []const u8,
    scope: []const u8,
    kind: []const u8,
    slug: []const u8,
};

pub fn listDocumentHistory(s: *Store, a: std.mem.Allocator, b: domain.Binding, kind: []const u8, slug: []const u8, limit: i64) ![]const DocumentLogEntry {
    try validateBinding(b);
    if (kind.len > 0 and !validDocumentKind(kind)) return errors.invalid("unknown document kind \"{s}\"", .{kind});
    const n: i64 = if (limit <= 0) 50 else if (limit > 500) 500 else limit;
    var sql_buf = std.Io.Writer.Allocating.init(a);
    try sql_buf.writer.print(
        "SELECT h.seq, h.event, h.revision, h.created_at, d.scope_id, d.kind, d.slug " ++
            "FROM history_events h JOIN documents d ON d.id = h.entity_id " ++
            "WHERE h.entity_type = 'document' AND d.scope_id IN ({s})",
        .{try scopeFilter(a, b.scopes.len)},
    );
    if (kind.len > 0) try sql_buf.writer.writeAll(" AND d.kind = ?");
    if (slug.len > 0) try sql_buf.writer.writeAll(" AND d.slug = ?");
    try sql_buf.writer.writeAll(" ORDER BY h.seq DESC LIMIT ?");
    var q = try s.db.prepare(sql_buf.written());
    defer q.finalize();
    var idx = try scopeArgs(q, 1, b);
    if (kind.len > 0) {
        try q.bindText(idx, kind);
        idx += 1;
    }
    if (slug.len > 0) {
        try q.bindText(idx, slug);
        idx += 1;
    }
    try q.bindInt(idx, n);
    var out: std.ArrayList(DocumentLogEntry) = .empty;
    while (try q.step()) {
        try out.append(a, .{
            .seq = q.int(0),
            .event = try dup(a, q.text(1)),
            .revision = q.int(2),
            .created_at = try reformat(a, q.text(3), "history_events.created_at"),
            .scope = try dup(a, q.text(4)),
            .kind = try dup(a, q.text(5)),
            .slug = try dup(a, q.text(6)),
        });
    }
    return out.items;
}

// -------------------------------------------------------------- sources

fn validSourceId(id: []const u8) bool {
    if (id.len < 2 or id.len > 64) return false;
    if (!std.ascii.isLower(id[0])) return false;
    for (id[1..]) |ch| {
        if (!(std.ascii.isLower(ch) or std.ascii.isDigit(ch) or ch == '_' or ch == '-')) return false;
    }
    return true;
}

pub const SourceCmd = struct {
    binding: domain.Binding,
    id: []const u8,
    name: []const u8,
    scope: []const u8,
    kind: []const u8,
    connector: []const u8,
    provider: []const u8 = "",
    connection_ref: []const u8 = "",
    non_secret_query: []const u8 = "",
    cadence: []const u8 = "",
};

fn validateSourceCmd(a: std.mem.Allocator, cmd: SourceCmd) !void {
    try validateBinding(cmd.binding);
    if (!validSourceId(cmd.id)) return errors.invalid("source id must match [a-z][a-z0-9_-]{{1,63}}", .{});
    if (trimmed(cmd.name).len == 0) return errors.invalid("source name is required", .{});
    if (!std.mem.eql(u8, cmd.kind, "capture") and !std.mem.eql(u8, cmd.kind, "calendar")) {
        return errors.invalid("unknown source kind \"{s}\"", .{cmd.kind});
    }
    if (!std.mem.eql(u8, cmd.connector, "manual") and
        !std.mem.eql(u8, cmd.connector, "directory") and
        !std.mem.eql(u8, cmd.connector, "host_mcp") and
        !std.mem.eql(u8, cmd.connector, "host_cli"))
    {
        return errors.invalid("unknown source connector \"{s}\"", .{cmd.connector});
    }
    if (cmd.scope.len == 0) return errors.invalid("source scope is required", .{});
    if (!cmd.binding.allows(cmd.scope)) {
        return errors.fail(.scope_denied, "scope {s} is outside the active scopes", .{cmd.scope});
    }
    if (std.mem.eql(u8, cmd.connector, "directory")) {
        _ = parseDirectoryRoots(a, cmd.id, cmd.connection_ref) catch |e| return e;
    }
}

fn sameSourceConfig(a: domain.Source, cmd: SourceCmd) bool {
    return std.mem.eql(u8, a.name, cmd.name) and
        std.mem.eql(u8, a.scope, cmd.scope) and
        std.mem.eql(u8, a.kind, cmd.kind) and
        std.mem.eql(u8, a.connector, cmd.connector) and
        std.mem.eql(u8, a.provider, cmd.provider) and
        std.mem.eql(u8, a.connection_ref, cmd.connection_ref) and
        std.mem.eql(u8, a.non_secret_query, cmd.non_secret_query) and
        std.mem.eql(u8, a.cadence, cmd.cadence);
}

fn loadSourceAny(s: *Store, a: std.mem.Allocator, id: []const u8) !?domain.Source {
    var q = try s.db.prepare("SELECT " ++ source_columns ++ " FROM sources WHERE id = ?");
    defer q.finalize();
    try q.bindText(1, id);
    if (!try q.step()) return null;
    return try scanSource(a, q);
}

fn loadSourceScope(s: *Store, a: std.mem.Allocator, b: domain.Binding, id: []const u8) !domain.Source {
    const clause = try scopeFilter(a, b.scopes.len);
    const sql = try std.fmt.allocPrint(a, "SELECT " ++ source_columns ++ " FROM sources WHERE id = ? AND scope_id IN ({s})", .{clause});
    var q = try s.db.prepare(sql);
    defer q.finalize();
    try q.bindText(1, id);
    _ = try scopeArgs(q, 2, b);
    if (!try q.step()) return rowAccessError(s, "sources", "source", id);
    return try scanSource(a, q);
}

fn refuseReusedSourceId(s: *Store, id: []const u8) !void {
    var q = try s.db.prepare("SELECT 1 FROM history_events WHERE entity_type = 'source' AND entity_id = ? AND event = 'deleted' LIMIT 1");
    defer q.finalize();
    try q.bindText(1, id);
    if (try q.step()) {
        return errors.fail(.conflict, "source id {s} was deleted and cannot be reused; choose another id", .{id});
    }
}

pub fn addSource(s: *Store, a: std.mem.Allocator, cmd: SourceCmd, now: Timestamp) !domain.Source {
    try validateSourceCmd(a, cmd);
    const now_s = try fmtTs(a, now);

    try s.begin();
    errdefer s.rollback();
    try requireScopeDeclared(s, cmd.scope);
    if (try loadSourceAny(s, a, cmd.id)) |existing| {
        try s.commit();
        if (sameSourceConfig(existing, cmd)) return existing;
        return errors.fail(.conflict, "source id {s} is already registered; choose another id", .{cmd.id});
    }
    try refuseReusedSourceId(s, cmd.id);
    const src = domain.Source{
        .id = try dup(a, cmd.id),
        .name = try dup(a, cmd.name),
        .scope = try dup(a, cmd.scope),
        .kind = try dup(a, cmd.kind),
        .connector = try dup(a, cmd.connector),
        .provider = try dup(a, cmd.provider),
        .connection_ref = try dup(a, cmd.connection_ref),
        .non_secret_query = try dup(a, cmd.non_secret_query),
        .cadence = try dup(a, cmd.cadence),
        .auth_state = "unknown",
        .coverage = "unknown",
        .cursor = "",
        .created_at = now_s,
        .updated_at = now_s,
    };
    var ins = try s.db.prepare(
        "INSERT INTO sources (id, name, scope_id, kind, connector, provider, connection_ref, non_secret_query, cadence, " ++
            "auth_state, coverage_state, cursor, last_attempt_at, last_success_at, created_at, updated_at) " ++
            "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, '', NULL, NULL, ?, ?)",
    );
    defer ins.finalize();
    try ins.bindText(1, src.id);
    try ins.bindText(2, src.name);
    try ins.bindText(3, src.scope);
    try ins.bindText(4, src.kind);
    try ins.bindText(5, src.connector);
    try ins.bindText(6, src.provider);
    try ins.bindText(7, src.connection_ref);
    try ins.bindText(8, src.non_secret_query);
    try ins.bindText(9, src.cadence);
    try ins.bindText(10, src.auth_state);
    try ins.bindText(11, src.coverage);
    try ins.bindText(12, src.created_at);
    try ins.bindText(13, src.updated_at);
    _ = try ins.step();
    try insertHistory(s, a, "source", src.id, "created", src.scope, "", 1, .{ .source = src }, now);
    try s.commit();
    return src;
}

fn lessStr(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

fn sourceDeleteCommand(a: std.mem.Allocator, b: domain.Binding) ![64]u8 {
    const scopes = try a.dupe([]const u8, b.scopes);
    std.mem.sort([]const u8, scopes, {}, lessStr);
    var aw = std.Io.Writer.Allocating.init(a);
    try aw.writer.print("source_delete:{s}\x00", .{b.profile});
    try aw.writer.print("{s}\x00", .{b.actor});
    var first = true;
    for (scopes) |sc| {
        if (!first) try aw.writer.writeByte(0);
        first = false;
        try aw.writer.writeAll(sc);
    }
    return sha256hex(aw.written());
}

fn sourceFromValue(a: std.mem.Allocator, v: std.json.Value) !domain.Source {
    return .{
        .id = try dup(a, jsonw.strField(v, "id") orelse ""),
        .name = try dup(a, jsonw.strField(v, "name") orelse ""),
        .scope = try dup(a, jsonw.strField(v, "scope") orelse ""),
        .kind = try dup(a, jsonw.strField(v, "kind") orelse ""),
        .connector = try dup(a, jsonw.strField(v, "connector") orelse ""),
        .provider = try dup(a, jsonw.strField(v, "provider") orelse ""),
        .connection_ref = try dup(a, jsonw.strField(v, "connection_ref") orelse ""),
        .non_secret_query = try dup(a, jsonw.strField(v, "non_secret_query") orelse ""),
        .cadence = try dup(a, jsonw.strField(v, "cadence") orelse ""),
        .auth_state = try dup(a, jsonw.strField(v, "auth_state") orelse "unknown"),
        .coverage = try dup(a, jsonw.strField(v, "coverage") orelse "unknown"),
        .cursor = try dup(a, jsonw.strField(v, "cursor") orelse ""),
        .last_attempt_at = try dupOpt(a, jsonw.strField(v, "last_attempt_at")),
        .last_success_at = try dupOpt(a, jsonw.strField(v, "last_success_at")),
        .created_at = try dup(a, jsonw.strField(v, "created_at") orelse ""),
        .updated_at = try dup(a, jsonw.strField(v, "updated_at") orelse ""),
    };
}

pub fn deleteSource(s: *Store, a: std.mem.Allocator, b: domain.Binding, id: []const u8, key: []const u8, now: Timestamp) !domain.Source {
    try validateBinding(b);
    if (!validSourceId(id)) return errors.invalid("source id must match [a-z][a-z0-9_-]{{1,63}}", .{});
    const command = try sourceDeleteCommand(a, b);
    var req = std.Io.Writer.Allocating.init(a);
    var ro = try jsonw.Obj.init(&req.writer);
    try ro.str("command", &command);
    try ro.str("id", id);
    try ro.end();
    const hash = sha256hex(req.written());

    try s.begin();
    errdefer s.rollback();
    if (key.len > 0) {
        if (try lookupIdemStmt(s, a, "source_delete", key, &hash)) |stored| {
            const parsed = std.json.parseFromSlice(std.json.Value, a, stored, .{}) catch
                return errors.invalid("stored source result is not valid JSON", .{});
            const out = try sourceFromValue(a, parsed.value);
            try s.commit();
            return out;
        }
    }
    const src = try loadSourceScope(s, a, b, id);
    const sql = try std.fmt.allocPrint(a, "SELECT " ++
        "(SELECT count(*) FROM captures c WHERE c.source_id = ? AND c.scope_id = ? AND NOT " ++
        "(c.source_id = 'legacy' AND EXISTS (SELECT 1 FROM history_events h WHERE h.entity_type = 'capture' AND h.entity_id = c.id AND h.scope_id = c.scope_id AND h.event = 'imported'))), " ++
        "(SELECT count(*) FROM source_reviews WHERE source_id = ?)", .{});
    var q = try s.db.prepare(sql);
    defer q.finalize();
    try q.bindText(1, id);
    try q.bindText(2, src.scope);
    try q.bindText(3, id);
    _ = try q.step();
    const captures = q.int(0);
    const reviews = q.int(1);
    if (captures > 0 or reviews > 0) {
        return errors.fail(.conflict, "source {s} is referenced by {d} captures and {d} reviews; it cannot be deleted", .{ id, captures, reviews });
    }
    var del = try s.db.prepare("DELETE FROM sources WHERE id = ? AND scope_id = ?");
    defer del.finalize();
    try del.bindText(1, id);
    try del.bindText(2, src.scope);
    _ = try del.step();
    try insertHistory(s, a, "source", src.id, "deleted", src.scope, "", 1, .{ .source = src }, now);
    if (key.len > 0) try writeIdem(s, a, "source_delete", key, &hash, .{ .source = src }, now);
    try s.commit();
    return src;
}

pub const SourceReviewCmd = struct {
    binding: domain.Binding,
    source_id: []const u8,
    batch_id: []const u8,
    key: []const u8,
    result_kind: []const u8 = "reported",
    retrieval: domain.SourceRetrieval = .{},
    items: []const domain.SourceItem = &.{},
};

/// The `body_ref` a provider summary may carry: where the full body lives when
/// only an excerpt was ingested.
fn metadataBodyRef(a: std.mem.Allocator, summary: ?[]const u8) !?[]const u8 {
    const raw = summary orelse return null;
    const parsed = std.json.parseFromSlice(std.json.Value, a, raw, .{}) catch return null;
    if (parsed.value != .object) return null;
    const ref = jsonw.strField(parsed.value, "body_ref") orelse return null;
    if (ref.len == 0) return null;
    return try dup(a, ref);
}

fn validateSourceItem(item: domain.SourceItem) !void {
    if (trimmed(item.original_text).len == 0) return errors.invalid("source item text is required", .{});
    if (item.original_text.len > 64 * 1024) return errors.invalid("source item text exceeds {d} bytes", .{64 * 1024});
    if (!std.unicode.utf8ValidateSlice(item.original_text)) return errors.invalid("source item text must be valid UTF-8", .{});
    const has_id = item.external_id.len > 0;
    const has_rev = item.external_revision.len > 0;
    if (has_id != has_rev) return errors.invalid("external id and external revision must be provided together", .{});
}

fn validateSourceReviewCmd(cmd: SourceReviewCmd) !void {
    try validateBinding(cmd.binding);
    if (!validSourceId(cmd.source_id)) return errors.invalid("source id must match [a-z][a-z0-9_-]{{1,63}}", .{});
    if (trimmed(cmd.batch_id).len == 0) return errors.invalid("batch id is required", .{});
    try requireKey(cmd.key);
    if (!std.mem.eql(u8, cmd.result_kind, "observed") and !std.mem.eql(u8, cmd.result_kind, "reported")) {
        return errors.invalid("unknown result kind \"{s}\"", .{cmd.result_kind});
    }
    if (cmd.items.len > 500) return errors.invalid("source batch exceeds 500 items", .{});
    for (cmd.items, 0..) |item, i| {
        validateSourceItem(item) catch |e| {
            if (e == error.Ztd) {
                var tmp: [4096]u8 = undefined;
                return errors.invalid("source item {d}: {s}", .{ i, errors.detailCopy(&tmp) });
            }
            return e;
        };
    }
}

fn sourceReviewCoverage(cmd: SourceReviewCmd) []const u8 {
    const failures = if (cmd.retrieval.failures) |f| f.len else 0;
    if (std.mem.eql(u8, cmd.result_kind, "observed")) {
        if (cmd.retrieval.complete_window and !cmd.retrieval.truncated and failures == 0) return "complete";
        return "partial";
    }
    if (cmd.items.len == 0 and failures > 0) return "failed";
    if (failures > 0 or cmd.retrieval.truncated) return "partial";
    return "unverified";
}

fn writeSourceReviewRequest(w: *std.Io.Writer, cmd: SourceReviewCmd) !void {
    var o = try jsonw.Obj.init(w);
    try writeBinding(&o, cmd.binding);
    try o.str("SourceID", cmd.source_id);
    try o.str("BatchID", cmd.batch_id);
    try o.str("Key", cmd.key);
    try o.str("ResultKind", cmd.result_kind);
    var r = try o.obj("Retrieval");
    try cmd.retrieval.write(&r);
    try r.end();
    var items = try o.arr("Items");
    for (cmd.items) |item| {
        var it = try items.obj();
        try it.str("external_id", item.external_id);
        try it.str("external_revision", item.external_revision);
        try it.str("original_text", item.original_text);
        if (item.source_uri) |v| try it.str("source_uri", v);
        if (item.occurred_at) |v| try it.str("occurred_at", v);
        if (item.provider_metadata_summary) |v| try it.str("provider_metadata_summary", v);
        try it.end();
    }
    try items.end();
    try o.end();
}

pub const SourceReviewResult = struct {
    review: domain.SourceReview,
    captures: []const domain.Capture,
};

fn writeSourceReviewResult(w: *std.Io.Writer, r: SourceReviewResult) !void {
    var o = try jsonw.Obj.init(w);
    // The CLI result is a Go map: sorted keys, and a nil slice becomes [].
    var arr = try o.arr("captures");
    for (r.captures) |cap| {
        var item = try arr.obj();
        try cap.write(&item);
        try item.end();
    }
    try arr.end();
    var rev = try o.obj("review");
    try r.review.write(&rev);
    try rev.end();
    try o.end();
}

pub fn recordSourceReview(s: *Store, a: std.mem.Allocator, cmd: SourceReviewCmd, now: Timestamp) !SourceReviewResult {
    try validateSourceReviewCmd(cmd);
    var req = std.Io.Writer.Allocating.init(a);
    try writeSourceReviewRequest(&req.writer, cmd);
    const hash = sha256hex(req.written());
    const now_s = try fmtTs(a, now);
    const date = try idDate(a, now);

    try s.begin();
    errdefer s.rollback();
    if (try lookupIdemStmt(s, a, "source_review", cmd.key, &hash)) |stored| {
        const parsed = std.json.parseFromSlice(std.json.Value, a, stored, .{}) catch
            return errors.invalid("stored source review result is not valid JSON", .{});
        const out = try sourceReviewResultFromValue(a, parsed.value);
        try s.commit();
        return out;
    }
    const src = try loadSourceScope(s, a, cmd.binding, cmd.source_id);
    const coverage = sourceReviewCoverage(cmd);

    const failure_count = if (cmd.retrieval.failures) |f| f.len else 0;
    var cursor = src.cursor;
    if (std.mem.eql(u8, cmd.result_kind, "observed") and cmd.retrieval.complete_window and
        !cmd.retrieval.truncated and failure_count == 0)
    {
        cursor = try dup(a, cmd.retrieval.cursor);
    }
    var last_success = src.last_success_at;
    if (std.mem.eql(u8, cmd.result_kind, "observed") and failure_count == 0) {
        last_success = try dup(a, now_s);
    }
    // The reported watermark is an advisory hint: it records where the host
    // said it read, without claiming coverage.
    var reported_cursor = src.reported_cursor;
    var last_reported = src.last_reported_at;
    if (std.mem.eql(u8, cmd.result_kind, "reported")) {
        reported_cursor = try dup(a, cmd.retrieval.cursor);
        last_reported = try dup(a, now_s);
    }

    var rid = std.Io.Writer.Allocating.init(a);
    try rid.writer.print("SR-{s}-{d:0>3}", .{ date, @as(u32, @intCast(try store.nextDailySeq(s.db, "source_reviews", try std.fmt.allocPrint(a, "SR-{s}-", .{date})))) });

    var review = domain.SourceReview{
        .id = rid.written(),
        .source_id = src.id,
        .batch_id = try dup(a, cmd.batch_id),
        .result_kind = try dup(a, cmd.result_kind),
        .coverage = coverage,
        .retrieval = cmd.retrieval,
        .capture_ids = null,
        .created_at = now_s,
    };

    var ins = try s.db.prepare(
        "INSERT INTO source_reviews (id, source_id, batch_id, idempotency_key, request_hash, result_kind, coverage_state, retrieval_json, created_at) " ++
            "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
    );
    defer ins.finalize();
    try ins.bindText(1, review.id);
    try ins.bindText(2, review.source_id);
    try ins.bindText(3, review.batch_id);
    try ins.bindText(4, cmd.key);
    try ins.bindText(5, &hash);
    try ins.bindText(6, review.result_kind);
    try ins.bindText(7, review.coverage);
    var rj = std.Io.Writer.Allocating.init(a);
    var rjo = try jsonw.Obj.init(&rj.writer);
    try cmd.retrieval.write(&rjo);
    try rjo.end();
    try ins.bindText(8, rj.written());
    try ins.bindText(9, review.created_at);
    _ = ins.step() catch |e| {
        if (e == error.Ztd) {
            const msg = errors.detail();
            if (std.mem.indexOf(u8, msg, "source_reviews.batch_id") != null) {
                return errors.fail(.conflict, "batch {s} was already recorded for source {s}", .{ cmd.batch_id, cmd.source_id });
            }
            if (std.mem.indexOf(u8, msg, "source_reviews.idempotency_key") != null) {
                return errors.fail(.conflict, "idempotency key was already recorded for source {s}", .{cmd.source_id});
            }
        }
        return e;
    };

    var captures: std.ArrayList(domain.Capture) = .empty;
    var capture_ids: std.ArrayList([]const u8) = .empty;
    for (cmd.items) |item| {
        if (item.external_id.len > 0) {
            var q = try s.db.prepare(
                "SELECT 1 FROM captures WHERE scope_id = ? AND source_id = ? AND external_id = ? AND external_revision = ?",
            );
            defer q.finalize();
            try q.bindText(1, src.scope);
            try q.bindText(2, src.id);
            try q.bindText(3, item.external_id);
            try q.bindText(4, item.external_revision);
            if (try q.step()) continue;
        }
        const cap_id = try std.fmt.allocPrint(a, "C-{s}-{d:0>3}", .{
            date, @as(u32, @intCast(try store.nextDailySeq(s.db, "captures", try std.fmt.allocPrint(a, "C-{s}-", .{date})))),
        });
        // Copied into the arena: the capture outlives this loop iteration, so a
        // pointer to the stack buffer would dangle (garbage on other ABIs).
        const content_hash = try dup(a, &sha256hex(item.original_text));
        const ext_id: ?[]const u8 = if (item.external_id.len > 0) item.external_id else null;
        const ext_rev: ?[]const u8 = if (item.external_id.len > 0) item.external_revision else null;
        const cap = domain.Capture{
            .id = cap_id,
            .scope = src.scope,
            .source_id = src.id,
            .external_id = ext_id,
            .external_revision = ext_rev,
            .original_text = item.original_text,
            .content_hash = content_hash,
            .source_uri = item.source_uri,
            .occurred_at = item.occurred_at,
            .captured_at = now_s,
            .state = "pending",
            .outcome = null,
            .review_after = null,
            .revision = 1,
        };
        var ci = try s.db.prepare(
            "INSERT INTO captures (id, scope_id, source_id, source_review_id, batch_id, provider_metadata, external_id, external_revision, original_text, content_hash, source_uri, body_ref, occurred_at, captured_at, processing_state, processing_outcome, review_after, revision) " ++
                "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'pending', NULL, NULL, 1)",
        );
        defer ci.finalize();
        try ci.bindText(1, cap.id);
        try ci.bindText(2, cap.scope);
        try ci.bindText(3, cap.source_id);
        try ci.bindText(4, review.id);
        try ci.bindText(5, cmd.batch_id);
        try ci.bindText(6, item.provider_metadata_summary orelse "{}");
        try ci.bindOptText(7, cap.external_id);
        try ci.bindOptText(8, cap.external_revision);
        try ci.bindText(9, cap.original_text);
        try ci.bindText(10, cap.content_hash);
        try ci.bindOptText(11, cap.source_uri);
        try ci.bindOptText(12, try metadataBodyRef(a, item.provider_metadata_summary));
        try ci.bindOptText(13, cap.occurred_at);
        try ci.bindText(14, cap.captured_at);
        _ = try ci.step();
        try insertHistory(s, a, "capture", cap.id, "captured", cap.scope, "", 1, .{ .capture = cap }, now);
        try insertLink(s, a, "source_review", review.id, "capture", cap.id, "produced", cap.scope, now);
        try captures.append(a, cap);
        try capture_ids.append(a, cap.id);
    }
    if (capture_ids.items.len > 0) review.capture_ids = capture_ids.items;

    var up = try s.db.prepare(
        "UPDATE sources SET coverage_state = ?, last_attempt_at = ?, last_success_at = ?, cursor = ?, updated_at = ?, " ++
            "reported_cursor = ?, last_reported_at = ? WHERE id = ?",
    );
    defer up.finalize();
    try up.bindText(1, coverage);
    try up.bindText(2, now_s);
    try up.bindOptText(3, last_success);
    try up.bindText(4, cursor);
    try up.bindText(5, now_s);
    try up.bindText(6, reported_cursor);
    try up.bindOptText(7, last_reported);
    try up.bindText(8, src.id);
    _ = try up.step();

    try insertHistory(s, a, "source_review", review.id, "recorded", src.scope, "", 1, .{ .source_review = review }, now);
    const out = SourceReviewResult{ .review = review, .captures = captures.items };
    try writeIdem(s, a, "source_review", cmd.key, &hash, .{ .source_review_result = out }, now);
    try s.commit();
    return out;
}

fn retrievalFromValue(a: std.mem.Allocator, v: std.json.Value) !domain.SourceRetrieval {
    if (v != .object) return .{};
    var out = domain.SourceRetrieval{
        .window = try dup(a, jsonw.strField(v, "window") orelse ""),
        .cursor = try dup(a, jsonw.strField(v, "cursor") orelse ""),
        .requested_limit = jsonw.intField(v, "requested_limit") orelse 0,
        .provider_returned_limit = jsonw.intField(v, "provider_returned_limit") orelse 0,
        .complete_window = jsonw.boolField(v, "complete_window") orelse false,
        .truncated = jsonw.boolField(v, "truncated") orelse false,
    };
    if (jsonw.arrField(v, "failures")) |list| {
        var failures: std.ArrayList([]const u8) = .empty;
        for (list) |f| {
            if (f != .string) continue;
            try failures.append(a, try dup(a, f.string));
        }
        out.failures = failures.items;
    }
    return out;
}

fn sourceReviewResultFromValue(a: std.mem.Allocator, v: std.json.Value) !SourceReviewResult {
    const rev_value = jsonw.field(v, "review") orelse return errors.invalid("stored source review is missing review", .{});
    var review = domain.SourceReview{
        .id = try dup(a, jsonw.strField(rev_value, "id") orelse ""),
        .source_id = try dup(a, jsonw.strField(rev_value, "source_id") orelse ""),
        .batch_id = try dup(a, jsonw.strField(rev_value, "batch_id") orelse ""),
        .result_kind = try dup(a, jsonw.strField(rev_value, "result_kind") orelse ""),
        .coverage = try dup(a, jsonw.strField(rev_value, "coverage") orelse ""),
        .retrieval = try retrievalFromValue(a, jsonw.field(rev_value, "retrieval") orelse .null),
        .capture_ids = null,
        .created_at = try dup(a, jsonw.strField(rev_value, "created_at") orelse ""),
    };
    if (jsonw.arrField(rev_value, "capture_ids")) |list| {
        var ids: std.ArrayList([]const u8) = .empty;
        for (list) |id| {
            if (id != .string) continue;
            try ids.append(a, try dup(a, id.string));
        }
        review.capture_ids = ids.items;
    }
    var captures: std.ArrayList(domain.Capture) = .empty;
    if (jsonw.arrField(v, "captures")) |list| {
        for (list) |item| try captures.append(a, try captureFromValue(a, item));
    }
    return .{ .review = review, .captures = captures.items };
}

// ------------------------------------------------- directory connector (observed)

fn parseDirectoryRoots(a: std.mem.Allocator, id: []const u8, connection_ref: []const u8) ![]const []const u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, a, connection_ref, .{}) catch
        return errors.invalid("directory source {s} must list its roots as a JSON array of absolute paths in connection_ref", .{id});
    if (parsed.value != .array) {
        return errors.invalid("directory source {s} must list its roots as a JSON array of absolute paths in connection_ref", .{id});
    }
    var roots: std.ArrayList([]const u8) = .empty;
    for (parsed.value.array.items) |item| {
        if (item != .string) {
            return errors.invalid("directory source {s} must list its roots as a JSON array of absolute paths in connection_ref", .{id});
        }
        if (!std.Io.Dir.path.isAbsolute(item.string)) {
            return errors.invalid("directory root {s} must be an absolute path", .{item.string});
        }
        // A trailing slash would make the containment test see "//file".
        var root = item.string;
        while (root.len > 1 and root[root.len - 1] == '/') root = root[0 .. root.len - 1];
        try roots.append(a, try dup(a, root));
    }
    if (roots.items.len == 0) return errors.invalid("directory source {s} needs at least one root", .{id});
    return roots.items;
}

fn realpathAlloc(a: std.mem.Allocator, path: []const u8) ![]const u8 {
    const z = try a.dupeSentinel(u8, path, 0);
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    // Windows has no realpath; _fullpath absolutizes without resolving links.
    const resolved = if (builtin.os.tag == .windows)
        c._fullpath(&buf, z.ptr, buf.len)
    else
        c.realpath(z.ptr, &buf);
    if (resolved == null) return error.RealpathFailed;
    return a.dupe(u8, std.mem.span(resolved.?));
}

fn insideRoot(path: []const u8, root: []const u8) bool {
    if (std.mem.eql(u8, path, root)) return true;
    if (std.mem.eql(u8, root, "/")) return path.len > 0 and path[0] == '/';
    return std.mem.startsWith(u8, path, root) and path.len > root.len and path[root.len] == '/';
}

fn readPrefix(a: std.mem.Allocator, io: std.Io, path: []const u8, limit: usize) ![]const u8 {
    var file = try std.Io.Dir.openFileAbsolute(io, path, .{});
    defer file.close(io);
    var buf: [4096]u8 = undefined;
    var fr = file.reader(io, &buf);
    return fr.interface.readAllocShort(a, limit);
}

/// Walks a directory source and records one observed review. The cursor only
/// moves when the window is complete: every root resolved and listed, no read
/// failures, nothing truncated. A suspicious path (a symlink leaving its root)
/// counts as a failure and never as content.
pub fn scanDirectory(s: *Store, a: std.mem.Allocator, io: std.Io, b: domain.Binding, source_id: []const u8, key_in: []const u8, now: Timestamp) !SourceReviewResult {
    const src = try loadSourceScope(s, a, b, source_id);
    if (!std.mem.eql(u8, src.connector, "directory")) {
        return errors.invalid("source {s} is not a directory source", .{src.id});
    }
    const roots = try parseDirectoryRoots(a, src.id, src.connection_ref);

    var items: std.ArrayList(domain.SourceItem) = .empty;
    var failures: std.ArrayList([]const u8) = .empty;
    var seen = std.StringHashMap(void).init(a);
    var complete = true;
    var truncated = false;
    var max_mtime: Timestamp = 0;

    // Files this source already ingested are skipped before the per-scan cap,
    // so a tree larger than the cap drains across scans instead of re-reading
    // the same head forever.
    {
        var q = try s.db.prepare(
            "SELECT external_id, external_revision FROM captures WHERE scope_id = ? AND source_id = ? AND external_id IS NOT NULL",
        );
        defer q.finalize();
        try q.bindText(1, src.scope);
        try q.bindText(2, src.id);
        while (try q.step()) {
            const key = try std.fmt.allocPrint(a, "{s}\x00{s}", .{ q.text(0), q.text(1) });
            try seen.put(key, {});
        }
    }

    for (roots) |root| {
        const real_root = realpathAlloc(a, root) catch {
            try failures.append(a, try std.fmt.allocPrint(a, "root {s} cannot be resolved", .{root}));
            complete = false;
            continue;
        };
        // The root is canonicalised before use, so containment is checked
        // against the directory actually read. A root that only differs by
        // canonicalisation (/tmp -> /private/tmp) is fine; whatever it points
        // at is what the approval covers, and entries are still confined to it.
        var dir = std.Io.Dir.openDirAbsolute(io, real_root, .{ .iterate = true }) catch {
            try failures.append(a, try std.fmt.allocPrint(a, "root {s} cannot be opened", .{root}));
            complete = false;
            continue;
        };
        defer dir.close(io);
        var walker = dir.walk(a) catch {
            try failures.append(a, try std.fmt.allocPrint(a, "root {s} cannot be listed", .{root}));
            complete = false;
            continue;
        };
        defer walker.deinit();
        while (true) {
            const entry = walker.next(io) catch {
                try failures.append(a, try std.fmt.allocPrint(a, "root {s} cannot be listed completely", .{root}));
                complete = false;
                break;
            } orelse break;
            if (entry.kind != .file and entry.kind != .sym_link) continue;
            const full = try std.fmt.allocPrint(a, "{s}/{s}", .{ real_root, entry.path });
            const real = realpathAlloc(a, full) catch {
                try failures.append(a, try std.fmt.allocPrint(a, "path {s} cannot be resolved", .{full}));
                complete = false;
                continue;
            };
            if (!insideRoot(real, real_root)) {
                try failures.append(a, try std.fmt.allocPrint(a, "path {s} resolves outside root {s}", .{ full, real_root }));
                complete = false;
                continue;
            }
            const st = std.Io.Dir.statFile(dir, io, entry.path, .{}) catch {
                try failures.append(a, try std.fmt.allocPrint(a, "path {s} cannot be read", .{full}));
                complete = false;
                continue;
            };
            if (st.kind == .directory) continue;
            const seconds = st.mtime.toSeconds();
            const revision = try std.fmt.allocPrint(a, "{d}:{d}", .{ seconds, st.size });
            // `seen` starts with the files this source already ingested, so the
            // cap below counts new items and a rescan drains the tail.
            const dedupe_key = try std.fmt.allocPrint(a, "{s}\x00{s}", .{ real, revision });
            if (seen.contains(dedupe_key)) continue;
            try seen.put(dedupe_key, {});
            if (items.items.len >= 500) {
                truncated = true;
                continue;
            }
            const text = readPrefix(a, io, real, 64 * 1024) catch {
                try failures.append(a, try std.fmt.allocPrint(a, "path {s} cannot be read", .{full}));
                complete = false;
                continue;
            };
            // A binary file in an approved tree is simply not a capture: skip it
            // without failing the window, or one .png freezes the cursor forever.
            if (!std.unicode.utf8ValidateSlice(text)) continue;
            const tail = if (st.size > 64 * 1024) errors.utf8Prefix(text, text.len) else text;
            if (trimmed(tail).len == 0) continue;
            try items.append(a, .{
                .external_id = real,
                .external_revision = revision,
                .original_text = tail,
                .source_uri = try std.fmt.allocPrint(a, "file://{s}", .{real}),
                .occurred_at = null,
                .provider_metadata_summary = if (st.size > 64 * 1024)
                    try std.fmt.allocPrint(a, "{{\"body_ref\":\"file://{s}\",\"bytes\":{d}}}", .{ real, st.size })
                else
                    null,
            });
            if (seconds > max_mtime) max_mtime = seconds;
        }
    }

    // Deterministic order: the capture IDs must not depend on the walk order.
    std.mem.sort(domain.SourceItem, items.items, {}, struct {
        fn less(_: void, lhs: domain.SourceItem, rhs: domain.SourceItem) bool {
            return std.mem.lessThan(u8, lhs.external_id, rhs.external_id);
        }
    }.less);

    const cursor = if (max_mtime > 0) try fmtTs(a, max_mtime) else src.cursor;
    // One batch per scan: the nanosecond stamp keeps two scans in the same
    // second from colliding on the (source, batch) unique key.
    const stamp = std.Io.Timestamp.now(io, .real).nanoseconds;
    const key = if (key_in.len > 0) key_in else try std.fmt.allocPrint(a, "scan:{s}:{d}", .{ src.id, stamp });
    const batch_id = try std.fmt.allocPrint(a, "scan:{s}:{d}", .{ src.id, stamp });
    return recordSourceReview(s, a, .{
        .binding = b,
        .source_id = src.id,
        .batch_id = batch_id,
        .key = key,
        .result_kind = "observed",
        .retrieval = .{
            .window = try std.fmt.allocPrint(a, "{s}..{s}", .{ src.cursor, cursor }),
            .cursor = cursor,
            .requested_limit = 0,
            .provider_returned_limit = @intCast(items.items.len),
            .complete_window = complete,
            .truncated = truncated,
            .failures = if (failures.items.len > 0) failures.items else null,
        },
        .items = items.items,
    }, now);
}

// --------------------------------------------------- scopes, contexts, projects

pub fn addScope(s: *Store, a: std.mem.Allocator, cmd: ScopeCmd, now: Timestamp) !domain.Scope {
    if (!configIdValid(cmd.id)) return errors.invalid("scope id must start with a lowercase letter and use only a-z 0-9 _ : . - (max 64 chars, no , | or =)", .{});
    var kind_ok = false;
    for ([_][]const u8{ "personal", "work", "client", "opensource" }) |k| {
        if (std.mem.eql(u8, k, cmd.kind)) kind_ok = true;
    }
    if (!kind_ok) return errors.invalid("unknown scope kind \"{s}\" (personal, work, client or opensource)", .{cmd.kind});
    const name = if (cmd.name.len > 0) cmd.name else cmd.id;
    var existing: ?domain.Scope = null;
    {
        var q = try s.db.prepare("SELECT id, name, kind, created_at FROM scopes WHERE id = ?");
        defer q.finalize();
        try q.bindText(1, cmd.id);
        if (try q.step()) existing = .{
            .id = try dup(a, q.text(0)),
            .name = try dup(a, q.text(1)),
            .kind = try dup(a, q.text(2)),
            .created_at = try reformat(a, q.text(3), "scopes.created_at"),
        };
    }
    if (existing) |e| {
        if (!std.mem.eql(u8, e.kind, cmd.kind) or !std.mem.eql(u8, e.name, name)) {
            return errors.fail(.conflict, "scope {s} already exists with a different kind or name", .{cmd.id});
        }
        return e;
    }
    const out: domain.Scope = .{
        .id = try dup(a, cmd.id),
        .name = try dup(a, name),
        .kind = try dup(a, cmd.kind),
        .created_at = try fmtTs(a, now),
    };
    var ins = try s.db.prepare("INSERT INTO scopes (id, name, kind, created_at) VALUES (?, ?, ?, ?)");
    defer ins.finalize();
    try ins.bindText(1, out.id);
    try ins.bindText(2, out.name);
    try ins.bindText(3, out.kind);
    try ins.bindText(4, out.created_at);
    _ = try ins.step();
    return out;
}

pub const ContextCmd = struct { binding: domain.Binding, name: []const u8 };

pub fn addContext(s: *Store, a: std.mem.Allocator, cmd: ContextCmd, now: Timestamp) !domain.Context {
    try validateBinding(cmd.binding);
    if (trimmed(cmd.name).len == 0) return errors.invalid("context name is required", .{});
    const scope = cmd.binding.scopes[0];
    try s.begin();
    errdefer s.rollback();
    try requireScopeDeclared(s, scope);
    {
        var q = try s.db.prepare("SELECT id, scope_id, name, revision FROM contexts WHERE scope_id = ? AND name = ?");
        defer q.finalize();
        try q.bindText(1, scope);
        try q.bindText(2, cmd.name);
        if (try q.step()) {
            const existing: domain.Context = .{
                .id = try dup(a, q.text(0)),
                .scope = try dup(a, q.text(1)),
                .name = try dup(a, q.text(2)),
                .revision = q.int(3),
            };
            try s.commit();
            return existing;
        }
    }
    const out: domain.Context = .{
        .id = try std.fmt.allocPrint(a, "ctx:{s}:{s}", .{ scope, cmd.name }),
        .scope = try dup(a, scope),
        .name = try dup(a, cmd.name),
        .revision = 1,
    };
    var ins = try s.db.prepare("INSERT INTO contexts (id, scope_id, name, revision) VALUES (?, ?, ?, 1)");
    defer ins.finalize();
    try ins.bindText(1, out.id);
    try ins.bindText(2, out.scope);
    try ins.bindText(3, out.name);
    _ = try ins.step();
    try insertHistory(s, a, "context", out.id, "created", scope, "", 1, .{ .context = out }, now);
    try s.commit();
    return out;
}

pub fn listContexts(s: *Store, a: std.mem.Allocator, b: domain.Binding) ![]const domain.Context {
    try validateBinding(b);
    const sql = try std.fmt.allocPrint(a, "SELECT id, scope_id, name, revision FROM contexts WHERE scope_id IN ({s}) ORDER BY name", .{try scopeFilter(a, b.scopes.len)});
    var q = try s.db.prepare(sql);
    defer q.finalize();
    _ = try scopeArgs(q, 1, b);
    var out: std.ArrayList(domain.Context) = .empty;
    while (try q.step()) {
        try out.append(a, .{
            .id = try dup(a, q.text(0)),
            .scope = try dup(a, q.text(1)),
            .name = try dup(a, q.text(2)),
            .revision = q.int(3),
        });
    }
    return out.items;
}

pub const ProjectCmd = struct {
    binding: domain.Binding,
    id: []const u8,
    desired_outcome: []const u8 = "",
    status: []const u8 = "active",
    repo_url: []const u8 = "",
    clone_path: []const u8 = "",
};

fn clonePathValid(p: []const u8) bool {
    if (!(p.len > 0 and (p[0] == '/' or p[0] == '\\')) and
        !(p.len >= 3 and p[1] == ':' and (p[2] == '/' or p[2] == '\\') and std.ascii.isAlphabetic(p[0])))
    {
        return false;
    }
    var it = std.mem.tokenizeAny(u8, p, "/\\");
    while (it.next()) |seg| if (std.mem.eql(u8, seg, "..")) return false;
    return true;
}

fn repoUrlHasCredentials(u: []const u8) bool {
    const start = std.mem.indexOf(u8, u, "://") orelse return false;
    var i = start + 3;
    while (i < u.len) : (i += 1) {
        const ch = u[i];
        if (ch == '/' or ch == '?' or ch == '#') return false;
        if (ch == '@') return true;
    }
    return false;
}

fn repoUrlScp(u: []const u8) bool {
    const at = std.mem.indexOfScalar(u8, u, '@') orelse return false;
    if (at == 0) return false;
    for (u[0..at]) |ch| {
        if (!(std.ascii.isAlphanumeric(ch) or ch == '.' or ch == '_' or ch == '-')) return false;
    }
    const rest = u[at + 1 ..];
    const colon = std.mem.indexOfScalar(u8, rest, ':') orelse return false;
    if (colon == 0) return false;
    for (rest[0..colon]) |ch| {
        if (!(std.ascii.isAlphanumeric(ch) or ch == '.' or ch == '-')) return false;
    }
    const path = rest[colon + 1 ..];
    if (path.len == 0) return false;
    for (path) |ch| if (std.ascii.isWhitespace(ch)) return false;
    return true;
}

fn repoUrlValid(u: []const u8) bool {
    if (repoUrlScp(u)) return true;
    return std.mem.indexOf(u8, u, "://") != null and !repoUrlHasCredentials(u);
}

fn validateProjectCmd(cmd: ProjectCmd) !void {
    try validateBinding(cmd.binding);
    if (trimmed(cmd.id).len == 0) return errors.invalid("project id is required", .{});
    var ok = false;
    for ([_][]const u8{ "active", "paused", "completed", "cancelled" }) |st| {
        if (std.mem.eql(u8, st, cmd.status)) ok = true;
    }
    if (!ok) return errors.invalid("project status must be active, paused, completed or cancelled, got \"{s}\"", .{cmd.status});
    if (cmd.clone_path.len > 0 and !clonePathValid(cmd.clone_path)) {
        return errors.invalid("clone path must be an absolute path without .. segments, got \"{s}\"", .{cmd.clone_path});
    }
    if (cmd.repo_url.len > 0 and !repoUrlValid(cmd.repo_url)) {
        if (repoUrlHasCredentials(cmd.repo_url)) return errors.invalid("repository url must not contain credentials", .{});
        return errors.invalid("repository url must include a scheme or use user@host:path, got \"{s}\"", .{cmd.repo_url});
    }
}

fn sameProjectConfig(p: domain.Project, cmd: ProjectCmd, scope: []const u8) bool {
    return std.mem.eql(u8, p.scope, scope) and
        std.mem.eql(u8, p.desired_outcome, cmd.desired_outcome) and
        std.mem.eql(u8, p.status, cmd.status) and
        std.mem.eql(u8, p.repo_url, cmd.repo_url) and
        std.mem.eql(u8, p.clone_path, cmd.clone_path);
}

fn scanProjectRow(a: std.mem.Allocator, q: sqlite.Statement) !domain.Project {
    return .{
        .id = try dup(a, q.text(0)),
        .scope = try dup(a, q.text(1)),
        .area_id = try dupOpt(a, q.optText(2)),
        .desired_outcome = try dup(a, q.text(3)),
        .status = try dup(a, q.text(4)),
        .repo_url = try dup(a, q.text(5)),
        .clone_path = try dup(a, q.text(6)),
        .revision = q.int(7),
    };
}

const project_columns = "id, scope_id, area_id, desired_outcome, status, repo_url, clone_path, revision";

pub fn addProject(s: *Store, a: std.mem.Allocator, cmd: ProjectCmd, now: Timestamp) !domain.Project {
    try validateProjectCmd(cmd);
    const scope = cmd.binding.scopes[0];
    try s.begin();
    errdefer s.rollback();
    try requireScopeDeclared(s, scope);
    {
        var q = try s.db.prepare("SELECT " ++ project_columns ++ " FROM projects WHERE id = ?");
        defer q.finalize();
        try q.bindText(1, cmd.id);
        if (try q.step()) {
            const existing = try scanProjectRow(a, q);
            if (!sameProjectConfig(existing, cmd, scope)) {
                return errors.fail(.conflict, "project {s} already exists with a different configuration", .{cmd.id});
            }
            try s.commit();
            return existing;
        }
    }
    const out: domain.Project = .{
        .id = try dup(a, cmd.id),
        .scope = try dup(a, scope),
        .area_id = null,
        .desired_outcome = try dup(a, cmd.desired_outcome),
        .status = try dup(a, cmd.status),
        .repo_url = try dup(a, cmd.repo_url),
        .clone_path = try dup(a, cmd.clone_path),
        .revision = 1,
    };
    var ins = try s.db.prepare(
        "INSERT INTO projects (id, scope_id, area_id, desired_outcome, status, repo_url, clone_path, revision) " ++
            "VALUES (?, ?, NULL, ?, ?, ?, ?, 1)",
    );
    defer ins.finalize();
    try ins.bindText(1, out.id);
    try ins.bindText(2, out.scope);
    try ins.bindText(3, out.desired_outcome);
    try ins.bindText(4, out.status);
    try ins.bindText(5, out.repo_url);
    try ins.bindText(6, out.clone_path);
    _ = try ins.step();
    try insertHistory(s, a, "project", out.id, "created", scope, "", 1, .{ .project = out }, now);
    try s.commit();
    return out;
}

pub fn listProjects(s: *Store, a: std.mem.Allocator, b: domain.Binding) ![]const domain.Project {
    try validateBinding(b);
    const sql = try std.fmt.allocPrint(a, "SELECT " ++ project_columns ++ " FROM projects WHERE scope_id IN ({s}) ORDER BY id", .{try scopeFilter(a, b.scopes.len)});
    var q = try s.db.prepare(sql);
    defer q.finalize();
    _ = try scopeArgs(q, 1, b);
    var out: std.ArrayList(domain.Project) = .empty;
    while (try q.step()) try out.append(a, try scanProjectRow(a, q));
    return out.items;
}

pub fn getProject(s: *Store, a: std.mem.Allocator, b: domain.Binding, id: []const u8) !domain.Project {
    try validateBinding(b);
    const sql = try std.fmt.allocPrint(a, "SELECT " ++ project_columns ++ " FROM projects WHERE id = ? AND scope_id IN ({s})", .{try scopeFilter(a, b.scopes.len)});
    var q = try s.db.prepare(sql);
    defer q.finalize();
    try q.bindText(1, id);
    _ = try scopeArgs(q, 2, b);
    if (!try q.step()) return errors.fail(.not_found, "project {s} not found", .{id});
    return try scanProjectRow(a, q);
}

/// Synchronizes a user-owned source configuration: inserts new sources and
/// updates changed ones, keeping coverage, cursor and auth state.
pub fn applySources(s: *Store, a: std.mem.Allocator, cmds: []const SourceCmd, now: Timestamp) ![]const domain.Source {
    if (cmds.len == 0) return errors.invalid("source configuration is empty", .{});
    if (cmds.len > 200) return errors.invalid("source configuration exceeds 200 entries", .{});
    for (cmds, 0..) |cmd, i| {
        try validateSourceCmd(a, cmd);
        for (cmds[0..i]) |prev| {
            if (std.mem.eql(u8, prev.id, cmd.id)) return errors.invalid("duplicate source id {s}", .{cmd.id});
        }
    }
    const now_s = try fmtTs(a, now);
    try s.begin();
    errdefer s.rollback();
    var out: std.ArrayList(domain.Source) = .empty;
    for (cmds) |cmd| {
        try requireScopeDeclared(s, cmd.scope);
        if (try loadSourceAny(s, a, cmd.id)) |existing| {
            if (!std.mem.eql(u8, existing.scope, cmd.scope)) {
                return errors.fail(.conflict, "source id {s} is already registered; choose another id", .{cmd.id});
            }
            if (sameSourceConfig(existing, cmd)) {
                try out.append(a, existing);
                continue;
            }
            var upd = try s.db.prepare(
                "UPDATE sources SET name = ?, kind = ?, connector = ?, provider = ?, connection_ref = ?, " ++
                    "non_secret_query = ?, cadence = ?, updated_at = ? WHERE id = ?",
            );
            defer upd.finalize();
            try upd.bindText(1, cmd.name);
            try upd.bindText(2, cmd.kind);
            try upd.bindText(3, cmd.connector);
            try upd.bindText(4, cmd.provider);
            try upd.bindText(5, cmd.connection_ref);
            try upd.bindText(6, cmd.non_secret_query);
            try upd.bindText(7, cmd.cadence);
            try upd.bindText(8, now_s);
            try upd.bindText(9, cmd.id);
            _ = try upd.step();
            const updated = domain.Source{
                .id = existing.id,
                .name = try dup(a, cmd.name),
                .scope = existing.scope,
                .kind = try dup(a, cmd.kind),
                .connector = try dup(a, cmd.connector),
                .provider = try dup(a, cmd.provider),
                .connection_ref = try dup(a, cmd.connection_ref),
                .non_secret_query = try dup(a, cmd.non_secret_query),
                .cadence = try dup(a, cmd.cadence),
                .auth_state = existing.auth_state,
                .coverage = existing.coverage,
                .cursor = existing.cursor,
                .last_attempt_at = existing.last_attempt_at,
                .last_success_at = existing.last_success_at,
                .created_at = existing.created_at,
                .updated_at = now_s,
            };
            try insertHistory(s, a, "source", updated.id, "updated", updated.scope, "", 1, .{ .source = updated }, now);
            try out.append(a, updated);
            continue;
        }
        try refuseReusedSourceId(s, cmd.id);
        const src = domain.Source{
            .id = try dup(a, cmd.id),
            .name = try dup(a, cmd.name),
            .scope = try dup(a, cmd.scope),
            .kind = try dup(a, cmd.kind),
            .connector = try dup(a, cmd.connector),
            .provider = try dup(a, cmd.provider),
            .connection_ref = try dup(a, cmd.connection_ref),
            .non_secret_query = try dup(a, cmd.non_secret_query),
            .cadence = try dup(a, cmd.cadence),
            .auth_state = "unknown",
            .coverage = "unknown",
            .cursor = "",
            .created_at = now_s,
            .updated_at = now_s,
        };
        var ins = try s.db.prepare(
            "INSERT INTO sources (id, name, scope_id, kind, connector, provider, connection_ref, non_secret_query, cadence, " ++
                "auth_state, coverage_state, cursor, last_attempt_at, last_success_at, created_at, updated_at) " ++
                "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, '', NULL, NULL, ?, ?)",
        );
        defer ins.finalize();
        try ins.bindText(1, src.id);
        try ins.bindText(2, src.name);
        try ins.bindText(3, src.scope);
        try ins.bindText(4, src.kind);
        try ins.bindText(5, src.connector);
        try ins.bindText(6, src.provider);
        try ins.bindText(7, src.connection_ref);
        try ins.bindText(8, src.non_secret_query);
        try ins.bindText(9, src.cadence);
        try ins.bindText(10, src.auth_state);
        try ins.bindText(11, src.coverage);
        try ins.bindText(12, src.created_at);
        try ins.bindText(13, src.updated_at);
        _ = try ins.step();
        try insertHistory(s, a, "source", src.id, "created", src.scope, "", 1, .{ .source = src }, now);
        try out.append(a, src);
    }
    try s.commit();
    return out.items;
}

// ------------------------------------------------------------ durability

const TableDef = struct { name: []const u8, pk: []const u8 };

const canonical_tables = [_]TableDef{
    .{ .name = "scopes", .pk = "id" },
    .{ .name = "profiles", .pk = "id" },
    .{ .name = "profile_scopes", .pk = "profile_id, scope_id" },
    .{ .name = "contexts", .pk = "id" },
    .{ .name = "areas", .pk = "id" },
    .{ .name = "projects", .pk = "id" },
    .{ .name = "documents", .pk = "id" },
    .{ .name = "links", .pk = "from_type, from_id, to_type, to_id, relation" },
    .{ .name = "captures", .pk = "id" },
    .{ .name = "sources", .pk = "id" },
    .{ .name = "source_reviews", .pk = "id" },
    .{ .name = "work_items", .pk = "id" },
    .{ .name = "plans", .pk = "id" },
    .{ .name = "plan_items", .pk = "plan_id, work_item_id" },
    .{ .name = "routines", .pk = "id" },
    .{ .name = "daily_limit_overrides", .pk = "id" },
    .{ .name = "calendar_review_assertions", .pk = "id" },
    .{ .name = "focus_sessions", .pk = "id" },
    .{ .name = "checkpoints", .pk = "id" },
    .{ .name = "reviews", .pk = "id" },
    .{ .name = "history_events", .pk = "seq" },
    .{ .name = "idempotency_records", .pk = "command, idempotency_key" },
    .{ .name = "import_runs", .pk = "id" },
    .{ .name = "legacy_records", .pk = "source, entity_type, entity_id" },
};

fn lessTable(_: void, a: TableDef, b: TableDef) bool {
    return std.mem.order(u8, a.name, b.name) == .lt;
}

const ColumnIdx = struct { name: []const u8, idx: c_int };

fn lessIndexByName(_: void, a: ColumnIdx, b: ColumnIdx) bool {
    return std.mem.order(u8, a.name, b.name) == .lt;
}

fn writeCell(w: *std.Io.Writer, stmt: sqlite.Statement, col: c_int) !void {
    switch (stmt.columnType(col)) {
        .null_value => try w.writeAll("null"),
        .integer => try w.print("{d}", .{stmt.int(col)}),
        .float => try jsonw.writeFloat(w, stmt.real(col)),
        .text => try jsonw.writeString(w, stmt.text(col)),
        .blob => try jsonw.writeString(w, stmt.bytes(col)),
    }
}

/// Writes every canonical table row to one deterministic JSON document.
pub fn exportTo(s: *Store, a: std.mem.Allocator, io: std.Io, out: []const u8) !void {
    if (trimmed(out).len == 0) return errors.invalid("export path is required", .{});
    var defs = canonical_tables;
    std.mem.sort(TableDef, &defs, {}, lessTable);

    var aw = std.Io.Writer.Allocating.init(a);
    var o = try jsonw.Obj.init(&aw.writer);
    try o.str("format", "ztd-export");
    try o.int("version", 2);
    var tables = try o.obj("tables");
    // One read transaction: without it each SELECT takes its own WAL snapshot
    // and a concurrent writer can leave a torn export that restores cleanly.
    try s.begin();
    errdefer s.rollback();
    for (defs) |def| {
        const sql = try std.fmt.allocPrint(a, "SELECT * FROM {s} ORDER BY {s}", .{ def.name, def.pk });
        var stmt = try s.db.prepare(sql);
        defer stmt.finalize();
        const n = stmt.columnCount();
        const idxs = try a.alloc(ColumnIdx, @intCast(n));
        for (0..@intCast(n)) |i| {
            idxs[i] = .{ .name = stmt.columnName(@intCast(i)), .idx = @intCast(i) };
        }
        std.mem.sort(ColumnIdx, idxs, {}, lessIndexByName);
        var arr = try tables.arr(def.name);
        while (try stmt.step()) {
            var row = try arr.obj();
            for (idxs) |it| {
                try row.key(it.name);
                try writeCell(&aw.writer, stmt, it.idx);
            }
            try row.end();
        }
        try arr.end();
    }
    try s.commit();
    try tables.end();
    try o.end();
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = out, .data = aw.written() }) catch |e|
        return errors.fail(.io_error, "write export: {s}", .{@errorName(e)});
}

pub const TableCount = struct { name: []const u8, count: i64 };

fn lessCount(_: void, a: TableCount, b: TableCount) bool {
    return std.mem.order(u8, a.name, b.name) == .lt;
}

fn joinCapped(a: std.mem.Allocator, errs: []const []const u8) ![]const u8 {
    var aw = std.Io.Writer.Allocating.init(a);
    const shown = @min(errs.len, 10);
    for (errs[0..shown], 0..) |e, i| {
        if (i > 0) try aw.writer.writeAll("; ");
        try aw.writer.writeAll(e);
    }
    if (errs.len > shown) try aw.writer.print(" (+{d} more)", .{errs.len - shown});
    return aw.written();
}

fn columnSet(s: *Store, a: std.mem.Allocator, table: []const u8) !std.StringHashMap(void) {
    var set = std.StringHashMap(void).init(a);
    var q = try s.db.prepare("SELECT name FROM pragma_table_info(?)");
    defer q.finalize();
    try q.bindText(1, table);
    while (try q.step()) try set.put(try dup(a, q.text(0)), {});
    return set;
}

fn insertExportRow(s: *Store, a: std.mem.Allocator, table: []const u8, cols: std.StringHashMap(void), row: std.json.Value) !void {
    if (row != .object or row.object.count() == 0) {
        return errors.fail(.unsupported_format, "table {s} contains an empty row object", .{table});
    }
    var names: std.ArrayList([]const u8) = .empty;
    var it = row.object.iterator();
    while (it.next()) |entry| {
        if (!cols.contains(entry.key_ptr.*)) {
            return errors.fail(.unsupported_format, "table {s} has no column \"{s}\"", .{ table, entry.key_ptr.* });
        }
        try names.append(a, entry.key_ptr.*);
    }
    std.mem.sort([]const u8, names.items, {}, lessStr);

    var aw = std.Io.Writer.Allocating.init(a);
    try aw.writer.print("INSERT INTO {s} (", .{table});
    for (names.items, 0..) |n, i| {
        if (i > 0) try aw.writer.writeAll(", ");
        try aw.writer.writeAll(n);
    }
    try aw.writer.print(") VALUES ({s})", .{try scopeFilter(a, names.items.len)});

    var stmt = try s.db.prepare(aw.written());
    defer stmt.finalize();
    for (names.items, 0..) |n, i| {
        const idx: c_int = @intCast(i + 1);
        switch (row.object.get(n).?) {
            .null => try stmt.bindNull(idx),
            .string => |v| try stmt.bindText(idx, v),
            .bool => |v| try stmt.bindInt(idx, if (v) 1 else 0),
            .integer => |v| try stmt.bindInt(idx, v),
            .float => |v| try stmt.bindDouble(idx, v),
            else => return errors.fail(.unsupported_format, "table {s} column {s}: unsupported JSON value", .{ table, n }),
        }
    }
    _ = stmt.step() catch {
        return errors.fail(.unsupported_format, "restore table {s}: {s}", .{ table, s.db.errmsg() });
    };
}

fn knownTable(name: []const u8) bool {
    for (canonical_tables) |def| if (std.mem.eql(u8, def.name, name)) return true;
    return false;
}

pub fn restoreFrom(s: *Store, a: std.mem.Allocator, io: std.Io, from: []const u8) ![]const TableCount {
    if (trimmed(from).len == 0) return errors.invalid("restore source is required", .{});
    const raw = std.Io.Dir.cwd().readFileAlloc(io, from, a, .limited(1 << 31)) catch |e|
        return errors.fail(.io_error, "read export: {s}", .{@errorName(e)});
    const parsed = std.json.parseFromSlice(std.json.Value, a, raw, .{}) catch
        return errors.fail(.unsupported_format, "input is not a valid export document: invalid JSON", .{});
    const doc = parsed.value;
    if (doc != .object) {
        return errors.fail(.unsupported_format, "input is not a valid export document: not an object", .{});
    }
    const format = jsonw.strField(doc, "format") orelse "";
    const version = jsonw.intField(doc, "version") orelse 0;
    if (!std.mem.eql(u8, format, "ztd-export") or (version != 1 and version != 2)) {
        return errors.fail(
            .unsupported_format,
            "unsupported export format \"{s}\" version {d} (want ztd-export version 2)",
            .{ format, version },
        );
    }
    const empty_tables = std.json.ObjectMap.init(a, &.{}, &.{}) catch return errors.fail(.io_error, "out of memory", .{});
    const tables_val = jsonw.field(doc, "tables") orelse std.json.Value{ .object = empty_tables };
    const tables_obj = if (tables_val == .object) tables_val.object else empty_tables;
    // A version 1 export predates the knowledge consolidation: it carries
    // knowledge_records and has no links table. Both are accepted and mapped.
    const legacy = version == 1;
    for (canonical_tables) |def| {
        if (legacy and std.mem.eql(u8, def.name, "links")) continue;
        if (!tables_obj.contains(def.name)) {
            return errors.fail(.unsupported_format, "export is missing table {s}", .{def.name});
        }
    }
    var kit = tables_obj.iterator();
    while (kit.next()) |entry| {
        const known = knownTable(entry.key_ptr.*) or (legacy and std.mem.eql(u8, entry.key_ptr.*, "knowledge_records"));
        if (!known) {
            return errors.fail(.unsupported_format, "export contains unknown table {s}", .{entry.key_ptr.*});
        }
    }

    try s.begin();
    errdefer s.rollback();
    for (canonical_tables) |def| {
        const sql = try std.fmt.allocPrint(a, "SELECT count(*) FROM {s}", .{def.name});
        var q = try s.db.prepare(sql);
        defer q.finalize();
        _ = try q.step();
        if (q.int(0) > 0) {
            return errors.fail(.destination_not_empty, "restore target already contains rows in {s}", .{def.name});
        }
    }
    try s.db.exec("PRAGMA defer_foreign_keys = ON");
    var counts: std.ArrayList(TableCount) = .empty;
    for (canonical_tables) |def| {
        const cols = try columnSet(s, a, def.name);
        var n: i64 = 0;
        if (tables_obj.get(def.name)) |rows_val| {
            if (rows_val != .array) return errors.fail(.unsupported_format, "table {s} is not an array", .{def.name});
            for (rows_val.array.items) |row| {
                try insertExportRow(s, a, def.name, cols, row);
                n += 1;
            }
        }
        try counts.append(a, .{ .name = def.name, .count = n });
    }
    if (legacy) {
        if (tables_obj.get("knowledge_records")) |rows_val| {
            if (rows_val == .array) {
                for (rows_val.array.items) |row| try insertLegacyKnowledge(s, row);
            }
        }
    }
    const report = try runCheck(s, a, null);
    if (!report.ok) {
        const joined = try joinCapped(a, report.errors);
        return errors.invalid("restored data failed validation: {s}", .{joined});
    }
    try s.commit();
    return counts.items;
}

pub fn snapshot(s: *Store, a: std.mem.Allocator, io: std.Io, out: []const u8) ![]const u8 {
    if (trimmed(out).len == 0) return errors.invalid("snapshot path is required", .{});
    const cwd = try std.process.currentPathAlloc(io, a);
    const abs = try std.fs.path.resolveAlloc(a, &.{ cwd, out });
    if (std.Io.Dir.cwd().access(io, abs, .{})) |_| {
        return errors.fail(.destination_not_empty, "snapshot destination {s} already exists", .{abs});
    } else |e| switch (e) {
        error.FileNotFound => {},
        else => return errors.fail(.io_error, "inspect snapshot destination: {s}", .{@errorName(e)}),
    }
    var stmt = try s.db.prepare("VACUUM INTO ?");
    defer stmt.finalize();
    try stmt.bindText(1, abs);
    _ = stmt.step() catch {
        const msg = s.db.errmsg();
        if (std.mem.indexOf(u8, msg, "already exists") != null) {
            return errors.fail(.destination_not_empty, "snapshot destination {s} already exists", .{abs});
        }
        if (isBusyMessage(msg)) return errors.fail(.db_busy, "{s}", .{msg});
        return errors.fail(.io_error, "snapshot: {s}", .{msg});
    };
    return abs;
}

pub const InboxStats = struct { pending: i64, due: i64, remaining: i64 };

pub fn inboxStats(s: *Store, a: std.mem.Allocator, b: domain.Binding, now: Timestamp) !InboxStats {
    try validateBinding(b);
    const sql = try std.fmt.allocPrint(a, "SELECT COALESCE(SUM(CASE WHEN processing_state = 'pending' THEN 1 ELSE 0 END), 0), " ++
        "COALESCE(SUM(CASE WHEN processing_state = 'deferred' AND review_after <= ? THEN 1 ELSE 0 END), 0) " ++
        "FROM captures WHERE scope_id IN ({s})", .{try scopeFilter(a, b.scopes.len)});
    var stmt = try s.db.prepare(sql);
    defer stmt.finalize();
    try stmt.bindText(1, try fmtTs(a, now));
    _ = try scopeArgs(stmt, 2, b);
    _ = try stmt.step();
    const pending = stmt.int(0);
    const due = stmt.int(1);
    return .{ .pending = pending, .due = due, .remaining = pending + due };
}

/// Maps one version 1 knowledge_records row into the consolidated documents
/// table, exactly like migration 0010 does.
fn insertLegacyKnowledge(s: *Store, row: std.json.Value) !void {
    const id = jsonw.strField(row, "id") orelse return errors.fail(.unsupported_format, "knowledge row has no id", .{});
    var slug_buf: [128]u8 = undefined;
    const slug = std.fmt.bufPrint(&slug_buf, "kr/{s}", .{id}) catch
        return errors.fail(.unsupported_format, "knowledge id is too long: {s}", .{id});
    const text = jsonw.strField(row, "text") orelse "";
    var title_buf: [80]u8 = undefined;
    const title = try firstLineTitle(id, text, &title_buf);
    const state = jsonw.strField(row, "state") orelse "";
    const review = jsonw.strField(row, "review_state") orelse "";
    const status = if (std.mem.eql(u8, state, "superseded"))
        "superseded"
    else if (std.mem.eql(u8, review, "verified"))
        "verified"
    else
        "draft";
    const reviewed = jsonw.strField(row, "reviewed_at");
    const created = jsonw.strField(row, "created_at") orelse "";
    const updated = reviewed orelse created;
    var ins = try s.db.prepare(
        "INSERT INTO documents (id, scope_id, kind, slug, title, body, status, revision, " ++
            "created_at, updated_at, record_kind, approved_at, valid_from, source_refs, supersedes_id) " ++
            "VALUES (?, ?, 'knowledge', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
    );
    defer ins.finalize();
    try ins.bindText(1, id);
    try ins.bindText(2, jsonw.strField(row, "scope_id") orelse "");
    try ins.bindText(3, slug);
    try ins.bindText(4, title);
    try ins.bindText(5, text);
    try ins.bindText(6, status);
    try ins.bindInt(7, jsonw.intField(row, "revision") orelse 1);
    try ins.bindText(8, created);
    try ins.bindText(9, updated);
    try ins.bindText(10, jsonw.strField(row, "kind") orelse "fact");
    try ins.bindOptText(11, reviewed);
    try ins.bindOptText(12, jsonw.strField(row, "valid_from"));
    try ins.bindText(13, jsonw.strField(row, "source_refs") orelse "[]");
    try ins.bindOptText(14, jsonw.strField(row, "supersedes_id"));
    _ = try ins.step();
}

fn firstLineTitle(id: []const u8, text: []const u8, buf: []u8) ![]const u8 {
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        const line_trimmed = std.mem.trim(u8, line, " \t\r");
        if (line_trimmed.len == 0) continue;
        const stripped = std.mem.trim(u8, std.mem.trimStart(u8, line_trimmed, "#"), " \t");
        const chosen = if (stripped.len > 0) stripped else line_trimmed;
        const cut = errors.utf8Prefix(chosen, 80);
        @memcpy(buf[0..cut.len], cut);
        return buf[0..cut.len];
    }
    const cut = errors.utf8Prefix(id, 80);
    @memcpy(buf[0..cut.len], cut);
    return buf[0..cut.len];
}

// ------------------------------------------------------------ provenance

pub const TraceEdge = struct {
    relation: []const u8,
    from_type: []const u8,
    from_id: []const u8,
    to_type: []const u8,
    to_id: []const u8,
};

pub const TraceResult = struct {
    id: []const u8,
    kind: []const u8,
    label: []const u8 = "",
    edges: []const TraceEdge,
};

pub fn entityKind(id: []const u8) ?[]const u8 {
    if (std.mem.startsWith(u8, id, "C-")) return "capture";
    if (std.mem.startsWith(u8, id, "CP-")) return "checkpoint";
    if (std.mem.startsWith(u8, id, "T-")) return "work_item";
    if (std.mem.startsWith(u8, id, "SR-")) return "source_review";
    if (std.mem.startsWith(u8, id, "F-")) return "focus_session";
    if (std.mem.startsWith(u8, id, "P-")) return "plan";
    if (std.mem.startsWith(u8, id, "R-")) return "review";
    if (std.mem.startsWith(u8, id, "G-")) return "goal";
    if (std.mem.startsWith(u8, id, "doc:")) return "document";
    return null;
}

fn traceLabel(a: std.mem.Allocator, s: *Store, id: []const u8) ![]const u8 {
    if (std.mem.startsWith(u8, id, "T-")) {
        var q = try s.db.prepare("SELECT title FROM work_items WHERE id = ?");
        defer q.finalize();
        try q.bindText(1, id);
        if (try q.step()) return dup(a, q.text(0));
        return "";
    }
    if (std.mem.startsWith(u8, id, "doc:")) {
        var q = try s.db.prepare("SELECT title FROM documents WHERE id = ?");
        defer q.finalize();
        try q.bindText(1, id);
        if (try q.step()) return dup(a, q.text(0));
        return "";
    }
    return "";
}

pub fn clip(a: std.mem.Allocator, text: []const u8, max: usize) ![]const u8 {
    if (text.len <= max) return dup(a, text);
    return dup(a, errors.utf8Prefix(text, max));
}

/// One hop of the provenance graph around `id`, both directions.
/// Edges of a document that point at entities other than documents; the
/// compact extension `doc related` uses for its `links` field.
pub fn externalEdges(s: *Store, a: std.mem.Allocator, id: []const u8) ![]const TraceEdge {
    var q = try s.db.prepare(
        "SELECT relation, from_type, from_id, to_type, to_id FROM links " ++
            "WHERE (from_id = ? AND to_type <> 'document') OR (to_id = ? AND from_type <> 'document') " ++
            "ORDER BY relation, from_id, to_id",
    );
    defer q.finalize();
    try q.bindText(1, id);
    try q.bindText(2, id);
    var edges: std.ArrayList(TraceEdge) = .empty;
    while (try q.step()) {
        try edges.append(a, .{
            .relation = try dup(a, q.text(0)),
            .from_type = try dup(a, q.text(1)),
            .from_id = try dup(a, q.text(2)),
            .to_type = try dup(a, q.text(3)),
            .to_id = try dup(a, q.text(4)),
        });
    }
    return edges.items;
}

pub fn traceEntity(s: *Store, a: std.mem.Allocator, id: []const u8) !TraceResult {
    const kind = entityKind(id) orelse return errors.invalid("unknown id \"{s}\"", .{id});
    if (!try entityExists(s, kind, id)) return errors.fail(.not_found, "{s} not found", .{id});
    var q = try s.db.prepare(
        "SELECT relation, from_type, from_id, to_type, to_id FROM links WHERE from_id = ? OR to_id = ? " ++
            "ORDER BY relation, from_id, to_id",
    );
    defer q.finalize();
    try q.bindText(1, id);
    try q.bindText(2, id);
    var edges: std.ArrayList(TraceEdge) = .empty;
    while (try q.step()) {
        try edges.append(a, .{
            .relation = try dup(a, q.text(0)),
            .from_type = try dup(a, q.text(1)),
            .from_id = try dup(a, q.text(2)),
            .to_type = try dup(a, q.text(3)),
            .to_id = try dup(a, q.text(4)),
        });
    }
    return .{ .id = try dup(a, id), .kind = try dup(a, kind), .label = try traceLabel(a, s, id), .edges = edges.items };
}

/// Evidence and trace checks only need existence inside the document's scope;
/// profile-scoped entities have no scope column and are checked by id alone.
fn requireDecision(s: *Store, decision: []const u8, scope: []const u8) !void {
    const kind = entityKind(decision) orelse return errors.invalid("unknown decision id \"{s}\"", .{decision});
    if (!std.mem.eql(u8, kind, "document")) return errors.invalid("unknown decision id \"{s}\"", .{decision});
    if (!try entityLinkedInScope(s, kind, decision, scope)) {
        return errors.fail(.not_found, "decision {s} not found", .{decision});
    }
}

fn entityTable(kind: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, kind, "capture")) return "captures";
    if (std.mem.eql(u8, kind, "work_item")) return "work_items";
    if (std.mem.eql(u8, kind, "checkpoint")) return "checkpoints";
    if (std.mem.eql(u8, kind, "document")) return "documents";
    if (std.mem.eql(u8, kind, "plan")) return "plans";
    if (std.mem.eql(u8, kind, "review")) return "reviews";
    if (std.mem.eql(u8, kind, "focus_session")) return "focus_sessions";
    if (std.mem.eql(u8, kind, "goal")) return "goals";
    if (std.mem.eql(u8, kind, "source_review")) return "source_reviews";
    return null;
}

fn entityExists(s: *Store, kind: []const u8, id: []const u8) !bool {
    const table = entityTable(kind) orelse return false;
    const sql = try std.fmt.allocPrint(std.heap.page_allocator, "SELECT 1 FROM {s} WHERE id = ?", .{table});
    var q = try s.db.prepare(sql);
    defer q.finalize();
    try q.bindText(1, id);
    return try q.step();
}

fn entityLinkedInScope(s: *Store, kind: []const u8, id: []const u8, scope: []const u8) !bool {
    const has_scope = std.mem.eql(u8, kind, "capture") or std.mem.eql(u8, kind, "work_item") or
        std.mem.eql(u8, kind, "checkpoint") or std.mem.eql(u8, kind, "document");
    const table = if (std.mem.eql(u8, kind, "capture")) "captures" else if (std.mem.eql(u8, kind, "work_item")) "work_items" else if (std.mem.eql(u8, kind, "checkpoint")) "checkpoints" else if (std.mem.eql(u8, kind, "document")) "documents" else if (std.mem.eql(u8, kind, "plan")) "plans" else if (std.mem.eql(u8, kind, "review")) "reviews" else if (std.mem.eql(u8, kind, "focus_session")) "focus_sessions" else if (std.mem.eql(u8, kind, "goal")) "goals" else if (std.mem.eql(u8, kind, "source_review")) "source_reviews" else return false;
    const sql = if (has_scope)
        try std.fmt.allocPrint(std.heap.page_allocator, "SELECT 1 FROM {s} WHERE id = ? AND scope_id = ?", .{table})
    else
        try std.fmt.allocPrint(std.heap.page_allocator, "SELECT 1 FROM {s} WHERE id = ?", .{table});
    var q = try s.db.prepare(sql);
    defer q.finalize();
    try q.bindText(1, id);
    if (has_scope) try q.bindText(2, scope);
    return try q.step();
}

pub fn supersedeDocument(
    s: *Store,
    a: std.mem.Allocator,
    b: domain.Binding,
    kind: []const u8,
    scope_in: []const u8,
    old_slug: []const u8,
    new_slug: []const u8,
    now: Timestamp,
) !domain.Document {
    try validateBinding(b);
    const scope = if (scope_in.len > 0) scope_in else b.scopes[0];
    if (!b.allows(scope)) return errors.fail(.scope_denied, "document scope is outside this binding", .{});
    if (std.mem.eql(u8, old_slug, new_slug)) return errors.invalid("a document cannot supersede itself", .{});

    try s.begin();
    errdefer s.rollback();
    const now_s = try fmtTs(a, now);
    var old = try getDocument(s, a, b, kind, old_slug, scope);
    var new = try getDocument(s, a, b, kind, new_slug, scope);
    if (new.supersedes_id != null) {
        return errors.fail(.invalid_transition, "document {s}/{s} already supersedes another document", .{ kind, new_slug });
    }
    if (std.mem.eql(u8, old.status, "superseded")) {
        return errors.fail(.invalid_transition, "document {s}/{s} is already superseded", .{ kind, old_slug });
    }

    new.supersedes_id = try dup(a, old.id);
    new.revision += 1;
    new.updated_at = now_s;
    old.status = "superseded";
    old.revision += 1;
    old.updated_at = now_s;

    for ([_]*domain.Document{ &new, &old }) |doc| {
        var up = try s.db.prepare(
            "UPDATE documents SET status = ?, revision = ?, updated_at = ?, supersedes_id = ? WHERE id = ?",
        );
        defer up.finalize();
        try up.bindText(1, doc.status);
        try up.bindInt(2, doc.revision);
        try up.bindText(3, doc.updated_at);
        try up.bindOptText(4, doc.supersedes_id);
        try up.bindText(5, doc.id);
        _ = try up.step();
    }
    try insertLink(s, a, "document", new.id, "document", old.id, "supersedes", scope, now);
    try insertHistory(s, a, "document", new.id, "updated", scope, "", new.revision, .{ .document = new }, now);
    try insertHistory(s, a, "document", old.id, "superseded", scope, "", old.revision, .{ .document = old }, now);
    try s.commit();
    return new;
}

pub const LearnCmd = struct {
    binding: domain.Binding,
    review: []const u8,
    slug: []const u8,
    title: []const u8 = "",
    body: []const u8,
    record_kind: []const u8 = "",
    evidence: []const []const u8 = &.{},
};

/// `learn propose`: stores the knowledge card a human wrote while closing a
/// review, as a draft tied to that review (`learned`). Promotion stays a human
/// `doc put --status verified --approved-by`.
pub fn proposeLearning(s: *Store, a: std.mem.Allocator, cmd: LearnCmd, now: Timestamp) !domain.Document {
    try validateBinding(cmd.binding);
    if (cmd.review.len == 0) return errors.invalid("--review is required", .{});
    if (cmd.slug.len == 0) return errors.invalid("--slug is required", .{});

    var profile: ?[]const u8 = null;
    {
        var q = try s.db.prepare("SELECT profile_id FROM reviews WHERE id = ?");
        defer q.finalize();
        try q.bindText(1, cmd.review);
        if (try q.step()) profile = try dup(a, q.text(0));
    }
    const review_profile = profile orelse
        return errors.fail(.not_found, "review {s} not found", .{cmd.review});
    if (!std.mem.eql(u8, review_profile, cmd.binding.profile)) {
        return errors.fail(.scope_denied, "review {s} belongs to another profile", .{cmd.review});
    }

    const scope = cmd.binding.scopes[0];
    var existing: ?domain.Document = null;
    {
        var q = try s.db.prepare("SELECT " ++ document_columns ++ " FROM documents WHERE scope_id = ? AND kind = ? AND slug = ?");
        defer q.finalize();
        try q.bindText(1, scope);
        try q.bindText(2, "knowledge");
        try q.bindText(3, cmd.slug);
        if (try q.step()) existing = try scanDocument(a, q);
    }
    const want_title = if (cmd.title.len > 0) cmd.title else cmd.slug;
    if (existing) |e| {
        if (!std.mem.eql(u8, e.status, "draft")) {
            return errors.fail(.invalid_transition, "document {s}/{s} is {s}; learn propose only writes drafts", .{ "knowledge", cmd.slug, e.status });
        }
        const cur_kind = e.record_kind orelse "";
        if (std.mem.eql(u8, e.title, want_title) and std.mem.eql(u8, e.body, cmd.body) and
            std.mem.eql(u8, cur_kind, cmd.record_kind))
        {
            try insertLink(s, a, "review", cmd.review, "document", e.id, "learned", scope, now);
            return e;
        }
    }
    const doc = try putDocument(s, a, .{
        .binding = cmd.binding,
        .kind = "knowledge",
        .slug = cmd.slug,
        .title = want_title,
        .body = cmd.body,
        .expected = if (existing) |e| e.revision else 0,
        .draft_only = true,
        .record_kind = cmd.record_kind,
        .evidence = cmd.evidence,
    }, now);
    // Reached on replay too: putDocument returns early there, the edge is still owed.
    try insertLink(s, a, "review", cmd.review, "document", doc.id, "learned", scope, now);
    return doc;
}

pub fn searchDocumentsBy(
    s: *Store,
    a: std.mem.Allocator,
    b: domain.Binding,
    query: []const u8,
    kind: []const u8,
    record_kind: []const u8,
    limit: i64,
) ![]const DocumentSearchHit {
    try validateBinding(b);
    const match = try ftsQuery(a, query);
    if (match.len == 0) return errors.invalid("search query is required", .{});
    if (kind.len > 0 and !validDocumentKind(kind)) return errors.invalid("unknown document kind \"{s}\"", .{kind});
    if (record_kind.len > 0 and !validRecordKind(record_kind)) {
        return errors.invalid("unknown record kind \"{s}\"", .{record_kind});
    }
    const n: i64 = if (limit <= 0) 10 else if (limit > 50) 50 else limit;

    var sql_buf = std.Io.Writer.Allocating.init(a);
    try sql_buf.writer.print(
        "SELECT " ++ joined_document_columns ++ ", bm25(documents_fts), snippet(documents_fts, 5, '[', ']', '…', 20) " ++
            "FROM documents_fts JOIN documents ON documents.id = documents_fts.doc_id " ++
            "WHERE documents_fts MATCH ? AND documents_fts.scope_id IN ({s})",
        .{try scopeFilter(a, b.scopes.len)},
    );
    if (kind.len > 0) try sql_buf.writer.writeAll(" AND documents_fts.kind = ?");
    if (record_kind.len > 0) try sql_buf.writer.writeAll(" AND documents.record_kind = ?");
    try sql_buf.writer.writeAll(" ORDER BY bm25(documents_fts) ASC, documents.kind, documents.slug LIMIT ?");
    var q = try s.db.prepare(sql_buf.written());
    defer q.finalize();
    try q.bindText(1, match);
    var idx = try scopeArgs(q, 2, b);
    if (kind.len > 0) {
        try q.bindText(idx, kind);
        idx += 1;
    }
    if (record_kind.len > 0) {
        try q.bindText(idx, record_kind);
        idx += 1;
    }
    try q.bindInt(idx, n);
    var out: std.ArrayList(DocumentSearchHit) = .empty;
    while (try q.step()) {
        try out.append(a, .{
            .document = try scanDocument(a, q),
            .rank = q.real(17),
            .snippet = try dup(a, q.text(18)),
        });
    }
    return out.items;
}

// ------------------------------------------------------- derived metrics

fn metricsFromValue(a: std.mem.Allocator, v: std.json.Value) ![]const u8 {
    const mv = jsonw.field(v, "metrics") orelse return "";
    var aw = std.Io.Writer.Allocating.init(a);
    try jsonw.writeValue(a, &aw.writer, mv);
    return aw.written();
}

const PeriodRange = struct {
    start: Timestamp,
    end: Timestamp,
    start_date: []const u8,
    end_date: []const u8,
};

/// ISO weeks in a year: 28 December always falls in the last one.
fn isoWeeks(year: i32) u8 {
    return timeutil.isoWeek(timeutil.daysFromCivil(year, 12, 28) * 86400).week;
}

/// A weekly period must be a real ISO week of that year: W53 exists only when
/// the year has 53 weeks, and 2025-W53 would otherwise alias 2026-W01.
fn validWeekPeriod(period: []const u8) bool {
    if (period.len != 8 or period[4] != '-' or period[5] != 'W') return false;
    const year = std.fmt.parseInt(i32, period[0..4], 10) catch return false;
    const week = std.fmt.parseInt(u8, period[6..8], 10) catch return false;
    if (week < 1 or week > isoWeeks(year)) return false;
    return true;
}

fn periodRange(a: std.mem.Allocator, kind: []const u8, period: []const u8) !PeriodRange {
    var start_days: i64 = 0;
    var end_days: i64 = 0;
    if (std.mem.eql(u8, kind, "daily")) {
        const ts = timeutil.parseDate(period) catch
            return errors.invalid("period must be YYYY-MM-DD for daily reviews", .{});
        start_days = @divFloor(ts, 86400);
        end_days = start_days + 1;
    } else if (std.mem.eql(u8, kind, "weekly")) {
        if (period.len != 8 or period[4] != '-' or period[5] != 'W') {
            return errors.invalid("period must be YYYY-Www for weekly reviews", .{});
        }
        const year = std.fmt.parseInt(i32, period[0..4], 10) catch
            return errors.invalid("period must be YYYY-Www for weekly reviews", .{});
        if (!validWeekPeriod(period)) return errors.invalid("period must be YYYY-Www for weekly reviews", .{});
        const week = std.fmt.parseInt(i64, period[6..8], 10) catch
            return errors.invalid("period must be YYYY-Www for weekly reviews", .{});
        // ISO week 1 is the week holding January 4th.
        const jan4 = timeutil.daysFromCivil(year, 1, 4);
        const monday_offset = @mod(jan4 + 3, 7);
        start_days = jan4 - monday_offset + (week - 1) * 7;
        end_days = start_days + 7;
    } else if (std.mem.eql(u8, kind, "monthly")) {
        if (period.len != 7 or period[4] != '-') return errors.invalid("period must be YYYY-MM for monthly reviews", .{});
        const year = std.fmt.parseInt(i32, period[0..4], 10) catch
            return errors.invalid("period must be YYYY-MM for monthly reviews", .{});
        const month = std.fmt.parseInt(u8, period[5..7], 10) catch
            return errors.invalid("period must be YYYY-MM for monthly reviews", .{});
        if (month < 1 or month > 12) return errors.invalid("period must be YYYY-MM for monthly reviews", .{});
        start_days = timeutil.daysFromCivil(year, month, 1);
        end_days = if (month == 12)
            timeutil.daysFromCivil(year + 1, 1, 1)
        else
            timeutil.daysFromCivil(year, month + 1, 1);
    } else if (std.mem.eql(u8, kind, "yearly")) {
        const year = std.fmt.parseInt(i32, std.mem.trim(u8, period, " \t\n\r"), 10) catch
            return errors.invalid("period must be YYYY for yearly reviews", .{});
        start_days = timeutil.daysFromCivil(year, 1, 1);
        end_days = timeutil.daysFromCivil(year + 1, 1, 1);
    } else {
        return errors.invalid("unknown review kind \"{s}\"", .{kind});
    }
    const start: Timestamp = start_days * 86400;
    const end: Timestamp = end_days * 86400;
    return .{
        .start = start,
        .end = end,
        .start_date = try dateOf(a, start),
        .end_date = try dateOf(a, end - 86400),
    };
}

fn dateOf(a: std.mem.Allocator, ts: Timestamp) ![]const u8 {
    var buf: [10]u8 = undefined;
    return dup(a, timeutil.date(ts, &buf));
}

fn sumInt(stmt: sqlite.Statement, col: c_int) i64 {
    return if (stmt.isNull(col)) 0 else stmt.int(col);
}

/// Computes `metrics_json` from the period's plans, work items, captures,
/// focus sessions and routines. Keys are written alphabetically so the stored
/// block has one stable shape.
fn computeMetrics(s: *Store, a: std.mem.Allocator, b: domain.Binding, kind: []const u8, period: []const u8) ![]const u8 {
    const range = try periodRange(a, kind, period);

    var plan_items: i64 = 0;
    var mit_planned: i64 = 0;
    var completed_items: i64 = 0;
    var mit_completed: i64 = 0;
    {
        var q = try s.db.prepare(
            "SELECT COUNT(*), " ++
                "COALESCE(SUM(CASE WHEN pi.role = 'mit' THEN 1 ELSE 0 END), 0), " ++
                "COALESCE(SUM(CASE WHEN w.lifecycle = 'archived' AND w.closure_kind = 'completed' THEN 1 ELSE 0 END), 0), " ++
                "COALESCE(SUM(CASE WHEN pi.role = 'mit' AND w.lifecycle = 'archived' AND w.closure_kind = 'completed' THEN 1 ELSE 0 END), 0) " ++
                "FROM plan_items pi JOIN plans p ON p.id = pi.plan_id " ++
                "JOIN work_items w ON w.id = pi.work_item_id " ++
                "WHERE p.profile_id = ? AND p.kind = 'daily' AND p.period >= ? AND p.period <= ?",
        );
        defer q.finalize();
        try q.bindText(1, b.profile);
        try q.bindText(2, range.start_date);
        try q.bindText(3, range.end_date);
        if (try q.step()) {
            plan_items = sumInt(q, 0);
            mit_planned = sumInt(q, 1);
            completed_items = sumInt(q, 2);
            mit_completed = sumInt(q, 3);
        }
    }

    var captures_received: i64 = 0;
    var captures_processed: i64 = 0;
    {
        const scope_sql = try scopeFilter(a, b.scopes.len);
        var sql_buf = std.Io.Writer.Allocating.init(a);
        try sql_buf.writer.print(
            "SELECT COUNT(*), COALESCE(SUM(CASE WHEN processing_state IN ('processed','discarded') THEN 1 ELSE 0 END), 0) " ++
                "FROM captures WHERE scope_id IN ({s}) AND captured_at >= ? AND captured_at < ?",
            .{scope_sql},
        );
        var q = try s.db.prepare(sql_buf.written());
        defer q.finalize();
        const idx = try scopeArgs(q, 1, b);
        try q.bindText(idx, try fmtTs(a, range.start));
        try q.bindText(idx + 1, try fmtTs(a, range.end));
        if (try q.step()) {
            captures_received = sumInt(q, 0);
            captures_processed = sumInt(q, 1);
        }
    }

    var focus_sessions: i64 = 0;
    var focus_minutes: i64 = 0;
    {
        var q = try s.db.prepare(
            "SELECT started_at, ended_at FROM focus_sessions WHERE profile_id = ? AND started_at >= ? AND started_at < ?",
        );
        defer q.finalize();
        try q.bindText(1, b.profile);
        try q.bindText(2, try fmtTs(a, range.start));
        try q.bindText(3, try fmtTs(a, range.end));
        while (try q.step()) {
            focus_sessions += 1;
            if (q.optText(1)) |ended| {
                const started_ts = timeutil.parseTime(q.text(0)) catch continue;
                const ended_ts = timeutil.parseTime(ended) catch continue;
                if (ended_ts > started_ts) focus_minutes += @divFloor(ended_ts - started_ts, 60);
            }
        }
    }

    var overdue_routines: i64 = 0;
    {
        const scope_sql = try scopeFilter(a, b.scopes.len);
        var sql_buf = std.Io.Writer.Allocating.init(a);
        try sql_buf.writer.print(
            "SELECT cadence, last_completed_at FROM routines WHERE active = 1 AND scope_id IN ({s})",
            .{scope_sql},
        );
        var q = try s.db.prepare(sql_buf.written());
        defer q.finalize();
        _ = try scopeArgs(q, 1, b);
        while (try q.step()) {
            const last: ?Timestamp = if (q.optText(1)) |text| timeutil.parseTime(text) catch null else null;
            if (try routineDue(q.text(0), last, range.end - 86400)) overdue_routines += 1;
        }
    }

    var aw = std.Io.Writer.Allocating.init(a);
    var o = try jsonw.Obj.init(&aw.writer);
    try o.int("captures_processed", captures_processed);
    try o.int("captures_received", captures_received);
    try o.int("completed_items", completed_items);
    try o.int("focus_minutes", focus_minutes);
    try o.int("focus_sessions", focus_sessions);
    try o.int("mit_completed", mit_completed);
    try o.int("mit_planned", mit_planned);
    try o.int("overdue_routines", overdue_routines);
    try o.int("plan_items", plan_items);
    try o.end();
    return aw.written();
}

fn linkMeasured(s: *Store, a: std.mem.Allocator, b: domain.Binding, kind: []const u8, period: []const u8, review_id: []const u8, now: Timestamp) !void {
    const scope = b.scopes[0];
    {
        var q = try s.db.prepare("SELECT id FROM goals WHERE profile_id = ? AND kind = 'primary' AND status = 'active' LIMIT 1");
        defer q.finalize();
        try q.bindText(1, b.profile);
        if (try q.step()) try insertLink(s, a, "review", review_id, "goal", q.text(0), "measured", scope, now);
    }
    const range = try periodRange(a, kind, period);
    var q = try s.db.prepare(
        "SELECT DISTINCT w.project_id FROM plan_items pi JOIN plans p ON p.id = pi.plan_id " ++
            "JOIN work_items w ON w.id = pi.work_item_id " ++
            "WHERE p.profile_id = ? AND p.kind = 'daily' AND p.period >= ? AND p.period <= ? AND w.project_id IS NOT NULL",
    );
    defer q.finalize();
    try q.bindText(1, b.profile);
    try q.bindText(2, range.start_date);
    try q.bindText(3, range.end_date);
    while (try q.step()) {
        try insertLink(s, a, "review", review_id, "project", q.text(0), "measured", scope, now);
    }
}

fn recordCalendarAssertion(s: *Store, a: std.mem.Allocator, b: domain.Binding, local_date: []const u8, statement: []const u8, now: Timestamp) !void {
    if (timeutil.parseDate(local_date)) |_| {} else |_| {
        return errors.invalid("calendar assertion requires a daily review period", .{});
    }
    const id = try std.fmt.allocPrint(a, "cra:{s}:{s}:{s}", .{ b.profile, b.actor, local_date });
    var q = try s.db.prepare(
        "INSERT INTO calendar_review_assertions (id, profile_id, actor_id, local_date, statement, created_at) " ++
            "VALUES (?, ?, ?, ?, ?, ?) " ++
            "ON CONFLICT(profile_id, actor_id, local_date) DO UPDATE SET statement = excluded.statement",
    );
    defer q.finalize();
    try q.bindText(1, id);
    try q.bindText(2, b.profile);
    try q.bindText(3, b.actor);
    try q.bindText(4, local_date);
    try q.bindText(5, statement);
    try q.bindText(6, try fmtTs(a, now));
    _ = try q.step();
}

pub const ReviewMetrics = struct {
    id: []const u8,
    kind: []const u8,
    period: []const u8,
    metrics_json: []const u8,
};

pub fn reviewShow(s: *Store, a: std.mem.Allocator, b: domain.Binding, kind: []const u8, period: []const u8) !ReviewMetrics {
    try validateBinding(b);
    const kind_ok = std.mem.eql(u8, kind, "daily") or std.mem.eql(u8, kind, "weekly") or
        std.mem.eql(u8, kind, "monthly") or std.mem.eql(u8, kind, "yearly");
    if (!kind_ok) return errors.invalid("unknown review kind \"{s}\"", .{kind});
    if (period.len == 0) return errors.invalid("period is required", .{});
    var q = try s.db.prepare(
        "SELECT id, metrics_json FROM reviews WHERE profile_id = ? AND kind = ? AND period = ?",
    );
    defer q.finalize();
    try q.bindText(1, b.profile);
    try q.bindText(2, kind);
    try q.bindText(3, period);
    if (!try q.step()) return errors.fail(.not_found, "review {s} {s} not found", .{ kind, period });
    return .{
        .id = try dup(a, q.text(0)),
        .kind = kind,
        .period = period,
        .metrics_json = try dup(a, q.text(1)),
    };
}

pub const OverrideRow = struct {
    id: []const u8,
    actor: []const u8,
    rule: []const u8,
    local_date: []const u8,
    reason: []const u8,
    created_at: []const u8,
};

pub fn addOverride(s: *Store, a: std.mem.Allocator, b: domain.Binding, rule: []const u8, date_text: []const u8, reason: []const u8, actor_in: []const u8, now: Timestamp) !OverrideRow {
    try validateBinding(b);
    if (!std.mem.eql(u8, rule, "mit") and !std.mem.eql(u8, rule, "focus")) {
        return errors.invalid("override rule must be mit or focus", .{});
    }
    if (timeutil.parseDate(date_text)) |_| {} else |_| {
        return errors.invalid("date must be YYYY-MM-DD", .{});
    }
    if (trimmed(reason).len == 0) return errors.invalid("reason is required", .{});
    const actor = if (actor_in.len > 0) actor_in else b.actor;
    const id = try std.fmt.allocPrint(a, "override:{s}:{s}:{s}", .{ actor, rule, date_text });
    const created_at = try fmtTs(a, now);
    var q = try s.db.prepare(
        "INSERT OR REPLACE INTO daily_limit_overrides (id, actor_id, local_date, rule, reason, created_by, created_at) " ++
            "VALUES (?, ?, ?, ?, ?, ?, ?)",
    );
    defer q.finalize();
    try q.bindText(1, id);
    try q.bindText(2, actor);
    try q.bindText(3, date_text);
    try q.bindText(4, rule);
    try q.bindText(5, reason);
    try q.bindText(6, b.actor);
    try q.bindText(7, created_at);
    _ = try q.step();
    return .{ .id = id, .actor = actor, .rule = rule, .local_date = date_text, .reason = reason, .created_at = created_at };
}
