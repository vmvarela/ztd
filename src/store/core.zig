//! Core persistence: scopes/profiles, captures, work items and the shared
//! idempotency, history and id-sequence helpers.

const std = @import("std");
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

fn dup(a: std.mem.Allocator, s: []const u8) ![]const u8 {
    return a.dupe(u8, s) catch errors.fail(.io_error, "out of memory", .{});
}

fn dupOpt(a: std.mem.Allocator, s: ?[]const u8) !?[]const u8 {
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

fn scopeFilter(a: std.mem.Allocator, n: usize) ![]const u8 {
    const buf = a.alloc(u8, n * 2) catch return errors.fail(.io_error, "out of memory", .{});
    return store.scopeFilter(buf, n);
}

fn scopeArgs(stmt: sqlite.Statement, start: c_int, b: domain.Binding) !c_int {
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

fn reformat(a: std.mem.Allocator, stored: []const u8, column: []const u8) ![]const u8 {
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

fn scanCapture(a: std.mem.Allocator, stmt: sqlite.Statement) !domain.Capture {
    const occurred: ?[]const u8 = if (stmt.optText(8)) |occ| try reformat(a, occ, "captures.occurred_at") else null;
    const review_after = try dupOpt(a, stmt.optText(12));
    var outcome: ?*const domain.Outcome = null;
    if (stmt.optText(11)) |kind| {
        const out = try a.create(domain.Outcome);
        out.* = .{ .kind = try dup(a, kind) };
        if (std.mem.eql(u8, kind, "defer")) out.review_after = review_after;
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
    var legacy_req = std.Io.Writer.Allocating.init(a);
    try writeCaptureRequest(&legacy_req.writer, 2, cmd, "manual");
    const legacy_hash = sha256hex(legacy_req.written());
    _ = legacy_hash;

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
        if (!try ref.step()) return errors.invalid("unknown source reference {s}", .{source});
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

const HistoryPayload = union(enum) {
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
    }
    try o.end();
}

fn insertHistory(
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

/// Returns the stored result JSON when the key replays, null when the key is
/// new, and a conflict when the payload hash differs.
fn lookupIdemStmt(
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

fn writeIdem(
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
        const buf = std.fmt.allocPrint(std.heap.page_allocator, "", .{}) catch unreachable;
        _ = buf;
        var tb: [20]u8 = undefined;
        try inner.str("OccurredAt", timeutil.fmtTime(t, &tb));
    } else {
        try inner.raw("OccurredAt", "null");
    }
    try inner.end();
    try o.end();
}

fn writeBinding(o: *jsonw.Obj, b: domain.Binding) !void {
    var inner = try o.obj("Binding");
    try inner.str("profile", b.profile);
    try inner.str("actor", b.actor);
    var a = try inner.arr("scopes");
    for (b.scopes) |s| try a.str(s);
    try a.end();
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

pub fn process(s: *Store, a: std.mem.Allocator, cmd: ProcessCmd, now: Timestamp) !ProcessResult {
    try validateBinding(cmd.binding);
    try requireKey(cmd.key);
    if (cmd.id.len == 0) return errors.invalid("capture id is required", .{});
    try validateOutcome(cmd.outcome);

    var aw = std.Io.Writer.Allocating.init(a);
    try writeProcessRequest(&aw.writer, cmd);
    const hash = sha256hex(aw.written());
    const now_s = try fmtTs(a, now);

    try s.begin();
    errdefer s.rollback();

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
        try upd.bindText(2, cmd.outcome.kind);
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
    try writeIdem(s, a, "process", cmd.key, &hash, .{ .capture = updated }, now);
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

fn writeProcessRequest(w: *std.Io.Writer, cmd: ProcessCmd) !void {
    var o = try jsonw.Obj.init(w);
    try writeBinding(&o, cmd.binding);
    try o.str("Key", cmd.key);
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
        for (list) |v| try items.append(a, try workItemFromValue(a, v));
    }
    return .{ .capture = try captureFromValue(a, cap_val), .work_items = items.items };
}

fn workItemFromValue(a: std.mem.Allocator, v: std.json.Value) !domain.WorkItem {
    return .{
        .id = try dup(a, jsonw.strField(v, "id") orelse ""),
        .scope = try dup(a, jsonw.strField(v, "scope") orelse ""),
        .title = try dup(a, jsonw.strField(v, "title") orelse ""),
        .lifecycle = try dup(a, jsonw.strField(v, "lifecycle") orelse "next"),
        .revision = jsonw.intField(v, "revision") orelse 1,
        .created_at = try dup(a, jsonw.strField(v, "created_at") orelse ""),
        .updated_at = try dup(a, jsonw.strField(v, "updated_at") orelse ""),
    };
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
    const date_buf = try idDate(a, now);
    _ = date_buf;
    if (cmd.start_on.len == 0) {
        var dbuf: [10]u8 = undefined;
        cmd.start_on = try dup(a, timeutil.date(now, &dbuf));
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
        "SELECT " ++ goal_columns ++ " FROM goals WHERE profile_id = ? AND kind = 'primary' " ++
            "ORDER BY status = 'active' DESC, created_at DESC, id DESC LIMIT 1",
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
    "auth_state, coverage_state, cursor, last_attempt_at, last_success_at, created_at, updated_at";

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

fn writeCommitPlanRequest(w: *std.Io.Writer, cmd: CommitPlanCmd) !void {
    var o = try jsonw.Obj.init(w);
    try writeBinding(&o, cmd.binding);
    try o.str("Key", cmd.key);
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
        date = try dup(a, timeutil.date(now, &dbuf));
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
            const item = getWorkItem(s, a, b, it.work_item_id) catch continue;
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
        const sql = try std.fmt.allocPrint(a,
            "SELECT " ++ work_item_columns ++ " FROM work_items WHERE lifecycle = ? AND scope_id IN ({s}) " ++
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

pub fn commitPlan(s: *Store, a: std.mem.Allocator, cmd: CommitPlanCmd, now: Timestamp) !domain.Plan {
    try validateBinding(cmd.binding);
    try requireKey(cmd.key);
    if (!std.mem.eql(u8, cmd.kind, "daily") and !std.mem.eql(u8, cmd.kind, "weekly")) {
        return errors.invalid("plan kind must be daily or weekly", .{});
    }
    if (cmd.period.len == 0) return errors.invalid("period is required", .{});
    var aw = std.Io.Writer.Allocating.init(a);
    try writeCommitPlanRequest(&aw.writer, cmd);
    const hash = sha256hex(aw.written());
    const now_s = try fmtTs(a, now);

    try s.begin();
    errdefer s.rollback();
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
    const plan_id = if (existing) |p| p.id else
        try std.fmt.allocPrint(a, "P-{s}-{s}-{s}", .{ cmd.binding.profile, cmd.kind, cmd.period });
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
                return errors.fail(.rules_acknowledgement_required,
                    "daily plan has {d} MITs; 1..3 need no override, otherwise record a daily limit override", .{mit_count});
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
        try items.append(a, .{ .work_item_id = it.work_item_id, .role = it.role, .position = it.position });
    }
    plan.items = items.items;
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

fn writeReviewRequest(w: *std.Io.Writer, cmd: ReviewCmd) !void {
    var o = try jsonw.Obj.init(w);
    try writeBinding(&o, cmd.binding);
    try o.str("Key", cmd.key);
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

pub fn recordReview(s: *Store, a: std.mem.Allocator, cmd: ReviewCmd, now: Timestamp) !domain.Review {
    try validateBinding(cmd.binding);
    try requireKey(cmd.key);
    const kind_ok = std.mem.eql(u8, cmd.kind, "daily") or std.mem.eql(u8, cmd.kind, "weekly") or
        std.mem.eql(u8, cmd.kind, "monthly") or std.mem.eql(u8, cmd.kind, "yearly");
    if (!kind_ok) return errors.invalid("unknown review kind \"{s}\"", .{cmd.kind});
    if (cmd.period.len == 0) return errors.invalid("period is required", .{});
    if (cmd.outcomes.len == 0) return errors.invalid("outcomes are required", .{});
    if (cmd.coverage.len == 0) return errors.invalid("coverage is required", .{});
    var aw = std.Io.Writer.Allocating.init(a);
    try writeReviewRequest(&aw.writer, cmd);
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
            "UPDATE reviews SET outcomes = ?, coverage = ?, completion_state = ?, revision = ? WHERE id = ?",
        );
        defer upd.finalize();
        try upd.bindText(1, cmd.outcomes);
        try upd.bindText(2, cmd.coverage);
        try upd.bindText(3, state);
        try upd.bindInt(4, rev);
        try upd.bindText(5, id);
        _ = try upd.step();
    } else {
        var ins = try s.db.prepare(
            "INSERT INTO reviews (id, profile_id, kind, period, outcomes, coverage, completion_state, created_at, revision) " ++
                "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
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
    };
    try insertHistory(s, a, "review", id, "recorded", "", cmd.binding.profile, rev, .{ .review = review }, now);
    try writeIdem(s, a, "review", cmd.key, &hash, .{ .review = review }, now);
    try s.commit();
    return review;
}
