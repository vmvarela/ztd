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
