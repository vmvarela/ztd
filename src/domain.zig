//! Domain values shared by the CLI and the store, plus their JSON form.
//!
//! Field order and omitempty behaviour mirror the Go structs exactly: the
//! golden corpus compares compacted JSON text, so a reordered field is a diff.

const std = @import("std");
const json = @import("json.zig");

pub const Binding = struct {
    profile: []const u8,
    actor: []const u8,
    scopes: []const []const u8,

    pub fn validate(self: Binding) error{Invalid}!void {
        if (std.mem.trim(u8, self.profile, " \t\n\r").len == 0) return error.Invalid;
        if (std.mem.trim(u8, self.actor, " \t\n\r").len == 0) return error.Invalid;
        if (self.scopes.len == 0) return error.Invalid;
    }

    pub fn allows(self: Binding, scope: []const u8) bool {
        for (self.scopes) |s| if (std.mem.eql(u8, s, scope)) return true;
        return false;
    }
};

pub const Scope = struct {
    id: []const u8,
    name: []const u8,
    kind: []const u8,
    created_at: []const u8,

    pub fn write(self: Scope, o: *json.Obj) !void {
        try o.str("id", self.id);
        try o.str("name", self.name);
        try o.str("kind", self.kind);
        try o.str("created_at", self.created_at);
    }
};

pub const Profile = struct {
    id: []const u8,
    name: []const u8,
    kind: []const u8,
    owner_actor: []const u8,
    timezone: []const u8,
    status: []const u8,
    scopes: []const []const u8,

    pub fn write(self: Profile, o: *json.Obj) !void {
        try o.str("id", self.id);
        try o.str("name", self.name);
        try o.str("kind", self.kind);
        try o.str("owner_actor_id", self.owner_actor);
        try o.str("timezone", self.timezone);
        try o.str("status", self.status);
        var a = try o.arr("scopes");
        for (self.scopes) |s| try a.str(s);
        try a.end();
    }
};

pub const Outcome = struct {
    kind: []const u8 = "",
    titles: []const []const u8 = &.{},
    project_id: ?[]const u8 = null,
    area_id: ?[]const u8 = null,
    context_id: ?[]const u8 = null,
    waiting_on: []const u8 = "",
    review_after: ?[]const u8 = null,
    reason: []const u8 = "",
    result_evidence: []const u8 = "",

    pub fn write(self: Outcome, o: *json.Obj) !void {
        try o.str("kind", self.kind);
        if (self.titles.len > 0) {
            var a = try o.arr("titles");
            for (self.titles) |t| try a.str(t);
            try a.end();
        }
        try o.optStr("project_id", self.project_id);
        try o.optStr("area_id", self.area_id);
        try o.optStr("context_id", self.context_id);
        if (self.waiting_on.len > 0) try o.str("waiting_on", self.waiting_on);
        try o.optStr("review_after", self.review_after);
        if (self.reason.len > 0) try o.str("reason", self.reason);
        if (self.result_evidence.len > 0) try o.str("result_evidence", self.result_evidence);
    }
};

pub const Capture = struct {
    id: []const u8,
    scope: []const u8,
    source_id: []const u8,
    external_id: ?[]const u8 = null,
    external_revision: ?[]const u8 = null,
    original_text: []const u8,
    content_hash: []const u8,
    source_uri: ?[]const u8 = null,
    occurred_at: ?[]const u8 = null,
    captured_at: []const u8,
    state: []const u8,
    outcome: ?*const Outcome = null,
    review_after: ?[]const u8 = null,
    revision: i64,

    pub fn write(self: Capture, o: *json.Obj) !void {
        try o.str("id", self.id);
        try o.str("scope", self.scope);
        try o.str("source_id", self.source_id);
        try o.optStr("external_id", self.external_id);
        try o.optStr("external_revision", self.external_revision);
        try o.str("original_text", self.original_text);
        try o.str("content_hash", self.content_hash);
        try o.optStr("source_uri", self.source_uri);
        try o.optStr("occurred_at", self.occurred_at);
        try o.str("captured_at", self.captured_at);
        try o.str("processing_state", self.state);
        if (self.outcome) |out| {
            var inner = try o.obj("processing_outcome");
            try out.write(&inner);
            try inner.end();
        }
        try o.optStr("review_after", self.review_after);
        try o.int("revision", self.revision);
    }
};

pub const WorkItem = struct {
    id: []const u8,
    scope: []const u8,
    area_id: ?[]const u8 = null,
    project_id: ?[]const u8 = null,
    context_id: ?[]const u8 = null,
    title: []const u8,
    origin_capture_id: ?[]const u8 = null,
    lifecycle: []const u8,
    waiting_on: []const u8 = "",
    due_at: ?[]const u8 = null,
    closure_kind: []const u8 = "",
    closed_at: ?[]const u8 = null,
    resolution: []const u8 = "",
    custom_fields_json: ?[]const u8 = null,
    revision: i64,
    created_at: []const u8,
    updated_at: []const u8,

    pub fn write(self: WorkItem, o: *json.Obj) !void {
        try o.str("id", self.id);
        try o.str("scope", self.scope);
        try o.optStr("area_id", self.area_id);
        try o.optStr("project_id", self.project_id);
        try o.optStr("context_id", self.context_id);
        try o.str("title", self.title);
        try o.optStr("origin_capture_id", self.origin_capture_id);
        try o.str("lifecycle", self.lifecycle);
        if (self.waiting_on.len > 0) try o.str("waiting_on", self.waiting_on);
        try o.optStr("due_at", self.due_at);
        if (self.closure_kind.len > 0) try o.str("closure_kind", self.closure_kind);
        try o.optStr("closed_at", self.closed_at);
        if (self.resolution.len > 0) try o.str("resolution", self.resolution);
        if (self.custom_fields_json) |fields| try o.raw("custom_fields", fields);
        try o.int("revision", self.revision);
        try o.str("created_at", self.created_at);
        try o.str("updated_at", self.updated_at);
    }
};

pub const Checkpoint = struct {
    id: []const u8,
    scope: []const u8,
    work_item_id: []const u8,
    result: []const u8,
    evidence_refs_json: ?[]const u8 = null,
    uncertainties: []const u8 = "",
    next_action: []const u8 = "",
    created_at: []const u8,
    revision: i64,

    pub fn write(self: Checkpoint, o: *json.Obj) !void {
        try o.str("id", self.id);
        try o.str("scope", self.scope);
        try o.str("work_item_id", self.work_item_id);
        try o.str("result", self.result);
        if (self.evidence_refs_json) |refs| try o.raw("evidence_refs", refs);
        if (self.uncertainties.len > 0) try o.str("uncertainties", self.uncertainties);
        if (self.next_action.len > 0) try o.str("next_action", self.next_action);
        try o.str("created_at", self.created_at);
        try o.int("revision", self.revision);
    }
};

pub const ConfigEntry = struct {
    id: []const u8,
    existed: bool,
};

test "capture emits Go field order and omits empty optionals" {
    var aw = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();
    var o = try json.Obj.init(&aw.writer);
    const cap = Capture{
        .id = "C-1",
        .scope = "personal",
        .source_id = "manual",
        .original_text = "x",
        .content_hash = "h",
        .captured_at = "2026-01-01T00:00:00Z",
        .state = "pending",
        .revision = 1,
    };
    try cap.write(&o);
    try o.end();
    try std.testing.expectEqualStrings(
        "{\"id\":\"C-1\",\"scope\":\"personal\",\"source_id\":\"manual\",\"original_text\":\"x\",\"content_hash\":\"h\",\"captured_at\":\"2026-01-01T00:00:00Z\",\"processing_state\":\"pending\",\"revision\":1}",
        aw.written(),
    );
}
