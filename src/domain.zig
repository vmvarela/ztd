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

/// One Markdown-shaped record identified by (scope, kind, slug). The v3
/// record fields stay absent from JSON when unset, so v2-shaped documents
/// keep their exact output.
pub const Document = struct {
    id: []const u8,
    scope: []const u8,
    kind: []const u8,
    slug: []const u8,
    title: []const u8,
    body: []const u8,
    status: []const u8,
    revision: i64,
    created_at: []const u8,
    updated_at: []const u8,
    record_kind: ?[]const u8 = null,
    rationale: ?[]const u8 = null,
    options_json: ?[]const u8 = null,
    approved_by: ?[]const u8 = null,
    approved_at: ?[]const u8 = null,
    valid_from: ?[]const u8 = null,
    supersedes_id: ?[]const u8 = null,

    pub fn write(self: Document, o: *json.Obj) !void {
        try o.str("id", self.id);
        try o.str("scope", self.scope);
        try o.str("kind", self.kind);
        try o.str("slug", self.slug);
        try o.str("title", self.title);
        try o.str("body", self.body);
        try o.str("status", self.status);
        try o.int("revision", self.revision);
        try o.str("created_at", self.created_at);
        try o.str("updated_at", self.updated_at);
        if (self.record_kind) |v| try o.str("record_kind", v);
        if (self.rationale) |v| try o.str("rationale", v);
        if (self.options_json) |v| try o.raw("options", v);
        if (self.approved_by) |v| try o.str("approved_by", v);
        if (self.approved_at) |v| try o.str("approved_at", v);
        if (self.valid_from) |v| try o.str("valid_from", v);
        if (self.supersedes_id) |v| try o.str("supersedes_id", v);
    }
};

pub const Context = struct {
    id: []const u8,
    scope: []const u8,
    name: []const u8,
    revision: i64,

    pub fn write(self: Context, o: *json.Obj) !void {
        try o.str("id", self.id);
        try o.str("scope", self.scope);
        try o.str("name", self.name);
        try o.int("revision", self.revision);
    }
};

pub const Project = struct {
    id: []const u8,
    scope: []const u8,
    area_id: ?[]const u8,
    desired_outcome: []const u8,
    status: []const u8,
    repo_url: []const u8,
    clone_path: []const u8,
    revision: i64,

    pub fn write(self: Project, o: *json.Obj) !void {
        try o.str("id", self.id);
        try o.str("scope", self.scope);
        if (self.area_id) |area| try o.str("area_id", area);
        try o.str("desired_outcome", self.desired_outcome);
        try o.str("status", self.status);
        if (self.repo_url.len > 0) try o.str("repo_url", self.repo_url);
        if (self.clone_path.len > 0) try o.str("clone_path", self.clone_path);
        try o.int("revision", self.revision);
    }
};

pub const Goal = struct {
    id: []const u8,
    profile_id: []const u8,
    kind: []const u8,
    start_on: []const u8,
    end_on: ?[]const u8 = null,
    statement: []const u8,
    status: []const u8,

    pub fn write(self: Goal, o: *json.Obj) !void {
        try o.str("id", self.id);
        try o.str("profile_id", self.profile_id);
        try o.str("kind", self.kind);
        try o.str("start_on", self.start_on);
        try o.optStr("end_on", self.end_on);
        try o.str("statement", self.statement);
        try o.str("status", self.status);
    }
};

pub const PlanItem = struct {
    work_item_id: []const u8,
    role: []const u8,
    position: i64,

    pub fn write(self: PlanItem, o: *json.Obj) !void {
        try o.str("work_item_id", self.work_item_id);
        try o.str("role", self.role);
        try o.int("position", self.position);
    }
};

pub const Plan = struct {
    id: []const u8,
    profile: []const u8,
    kind: []const u8,
    period: []const u8,
    status: []const u8,
    revision: i64,
    items: []const PlanItem = &.{},
    created_at: []const u8,
    updated_at: []const u8,

    pub fn write(self: Plan, o: *json.Obj) !void {
        try o.str("id", self.id);
        try o.str("profile", self.profile);
        try o.str("kind", self.kind);
        try o.str("period", self.period);
        try o.str("status", self.status);
        try o.int("revision", self.revision);
        if (self.items.len > 0) {
            var arr = try o.arr("items");
            for (self.items) |item| {
                var io = try arr.obj();
                try item.write(&io);
                try io.end();
            }
            try arr.end();
        }
        try o.str("created_at", self.created_at);
        try o.str("updated_at", self.updated_at);
    }
};

pub const PlanBrief = struct {
    profile: []const u8,
    date: []const u8,
    goal: ?Goal = null,
    mits: []const WorkItem = &.{},
    next: []const WorkItem = &.{},
    waiting: []const WorkItem = &.{},
    sources: ?[]const Source = null,
    checkpoints: ?[]const Checkpoint = null,
    plan: ?Plan = null,
    needs_human: ?[]const []const u8 = null,

    pub fn write(self: PlanBrief, o: *json.Obj) !void {
        try o.str("profile", self.profile);
        try o.str("date", self.date);
        if (self.goal) |g| {
            var inner = try o.obj("goal");
            try g.write(&inner);
            try inner.end();
        }
        try writeWorkItemsOrNull(o, "mits", self.mits);
        try writeWorkItemsOrNull(o, "next", self.next);
        try writeWorkItemsOrNull(o, "waiting", self.waiting);
        if (self.sources) |sources| {
            var arr = try o.arr("sources");
            for (sources) |s| {
                var io = try arr.obj();
                try s.write(&io);
                try io.end();
            }
            try arr.end();
        }
        if (self.checkpoints) |cps| {
            var arr = try o.arr("checkpoints");
            for (cps) |cp| {
                var io = try arr.obj();
                try cp.write(&io);
                try io.end();
            }
            try arr.end();
        }
        if (self.plan) |plan| {
            var inner = try o.obj("plan");
            try plan.write(&inner);
            try inner.end();
        }
        if (self.needs_human) |items| {
            var arr = try o.arr("needs_human");
            for (items) |item| try arr.str(item);
            try arr.end();
        }
    }

    fn writeWorkItems(o: *json.Obj, name: []const u8, items: []const WorkItem) !void {
        var arr = try o.arr(name);
        for (items) |item| {
            var io = try arr.obj();
            try item.write(&io);
            try io.end();
        }
        try arr.end();
    }

    // Go marshals a nil slice as null, and these lists start nil.
    fn writeWorkItemsOrNull(o: *json.Obj, name: []const u8, items: []const WorkItem) !void {
        if (items.len == 0) {
            try o.raw(name, "null");
            return;
        }
        try writeWorkItems(o, name, items);
    }
};

pub const FocusSession = struct {
    id: []const u8,
    profile: []const u8,
    actor: []const u8,
    work_item_id: []const u8,
    started_at: []const u8,
    ended_at: ?[]const u8 = null,
    outcome: ?[]const u8 = null,

    pub fn write(self: FocusSession, o: *json.Obj) !void {
        try o.str("id", self.id);
        try o.str("profile", self.profile);
        try o.str("actor", self.actor);
        try o.str("work_item_id", self.work_item_id);
        try o.str("started_at", self.started_at);
        try o.optStr("ended_at", self.ended_at);
        try o.optStr("outcome", self.outcome);
    }
};

pub const Review = struct {
    id: []const u8,
    profile: []const u8,
    kind: []const u8,
    period: []const u8,
    outcomes: []const u8,
    coverage: []const u8,
    completion_state: []const u8,
    created_at: []const u8,
    metrics_json: []const u8 = "",

    pub fn write(self: Review, o: *json.Obj) !void {
        try o.str("id", self.id);
        try o.str("profile", self.profile);
        try o.str("kind", self.kind);
        try o.str("period", self.period);
        try o.str("outcomes", self.outcomes);
        try o.str("coverage", self.coverage);
        try o.str("completion_state", self.completion_state);
        try o.str("created_at", self.created_at);
        // Derived metrics are new in v3: omit them when empty so v2 documents
        // keep their exact JSON shape.
        if (self.metrics_json.len > 0 and !std.mem.eql(u8, self.metrics_json, "{}")) {
            try o.raw("metrics", self.metrics_json);
        }
    }
};

pub const Source = struct {
    id: []const u8,
    name: []const u8,
    scope: []const u8,
    kind: []const u8,
    connector: []const u8,
    provider: []const u8,
    connection_ref: []const u8,
    non_secret_query: []const u8,
    cadence: []const u8,
    auth_state: []const u8,
    coverage: []const u8,
    cursor: []const u8,
    last_attempt_at: ?[]const u8 = null,
    last_success_at: ?[]const u8 = null,
    created_at: []const u8,
    updated_at: []const u8,
    // Advisory watermark from reported batches (v3). Omitted from JSON when
    // empty so v2 responses stay byte-identical.
    reported_cursor: []const u8 = "",
    last_reported_at: ?[]const u8 = null,

    pub fn write(self: Source, o: *json.Obj) !void {
        try o.str("id", self.id);
        try o.str("name", self.name);
        try o.str("scope", self.scope);
        try o.str("kind", self.kind);
        try o.str("connector", self.connector);
        try o.str("provider", self.provider);
        try o.str("connection_ref", self.connection_ref);
        try o.str("non_secret_query", self.non_secret_query);
        try o.str("cadence", self.cadence);
        try o.str("auth_state", self.auth_state);
        try o.str("coverage", self.coverage);
        try o.str("cursor", self.cursor);
        try o.optStr("last_attempt_at", self.last_attempt_at);
        try o.optStr("last_success_at", self.last_success_at);
        try o.str("created_at", self.created_at);
        try o.str("updated_at", self.updated_at);
        if (self.last_reported_at) |v| try o.str("last_reported_at", v);
        if (self.reported_cursor.len > 0) try o.str("reported_cursor", self.reported_cursor);
    }
};

pub const Routine = struct {
    id: []const u8,
    scope: []const u8,
    kind: []const u8,
    cadence: []const u8,
    last_completed_at: ?[]const u8 = null,
    active: bool,
    revision: i64,

    pub fn write(self: Routine, o: *json.Obj) !void {
        try o.str("id", self.id);
        try o.str("scope", self.scope);
        try o.str("kind", self.kind);
        try o.str("cadence", self.cadence);
        try o.optStr("last_completed_at", self.last_completed_at);
        try o.boolean("active", self.active);
        try o.int("revision", self.revision);
    }
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

pub const SourceRetrieval = struct {
    window: []const u8 = "",
    cursor: []const u8 = "",
    requested_limit: i64 = 0,
    provider_returned_limit: i64 = 0,
    complete_window: bool = false,
    truncated: bool = false,
    /// Files the connector recognised but did not ingest (binary content).
    skipped: usize = 0,
    failures: ?[]const []const u8 = null,

    /// Borrows strings from the parsed value. `a` owns only the failure list.
    pub fn fromValue(a: std.mem.Allocator, value: ?std.json.Value) !SourceRetrieval {
        const v = value orelse return .{};
        var out: SourceRetrieval = .{
            .window = json.strField(v, "window") orelse "",
            .cursor = json.strField(v, "cursor") orelse "",
            .requested_limit = json.intField(v, "requested_limit") orelse 0,
            .provider_returned_limit = json.intField(v, "provider_returned_limit") orelse 0,
            .complete_window = json.boolField(v, "complete_window") orelse false,
            .truncated = json.boolField(v, "truncated") orelse false,
            .skipped = std.math.cast(usize, @max(0, json.intField(v, "skipped") orelse 0)) orelse std.math.maxInt(usize),
        };
        if (json.arrField(v, "failures")) |items| {
            const failures = try a.alloc([]const u8, items.len);
            // Keep the CLI/MCP canonical payload (and therefore old hashes).
            for (items, failures) |item, *failure| failure.* = if (item == .string) item.string else "";
            out.failures = failures;
        }
        return out;
    }

    pub fn write(self: SourceRetrieval, o: *json.Obj) !void {
        try o.str("window", self.window);
        try o.str("cursor", self.cursor);
        try o.int("requested_limit", self.requested_limit);
        try o.int("provider_returned_limit", self.provider_returned_limit);
        try o.boolean("complete_window", self.complete_window);
        try o.boolean("truncated", self.truncated);
        if (self.skipped > 0) try o.int("skipped", @intCast(self.skipped));
        if (self.failures) |list| {
            var arr = try o.arr("failures");
            for (list) |f| try arr.str(f);
            try arr.end();
        } else {
            try o.raw("failures", "null");
        }
    }
};

test "source retrieval keeps canonical failure entries and defaults" {
    const a = std.testing.allocator;
    const parsed = try std.json.parseFromSlice(std.json.Value, a,
        \\{"skipped":3,"failures":["read error",null]}
    , .{});
    defer parsed.deinit();
    const retrieval = try SourceRetrieval.fromValue(a, parsed.value);
    const failures = retrieval.failures.?;
    defer a.free(failures);
    try std.testing.expectEqual(@as(usize, 3), retrieval.skipped);
    try std.testing.expectEqualStrings("read error", failures[0]);
    try std.testing.expectEqualStrings("", failures[1]);
    try std.testing.expectEqual(@as(?[]const []const u8, null), (try SourceRetrieval.fromValue(a, null)).failures);
}

pub const SourceItem = struct {
    external_id: []const u8 = "",
    external_revision: []const u8 = "",
    original_text: []const u8 = "",
    source_uri: ?[]const u8 = null,
    occurred_at: ?[]const u8 = null,
    provider_metadata_summary: ?[]const u8 = null,
};

pub const SourceReview = struct {
    id: []const u8,
    source_id: []const u8,
    batch_id: []const u8,
    result_kind: []const u8,
    coverage: []const u8,
    retrieval: SourceRetrieval,
    capture_ids: ?[]const []const u8 = null,
    created_at: []const u8,
    // Set only on a truncated presentation of the review (v3 cap); never stored.
    omitted: usize = 0,

    pub fn write(self: SourceReview, o: *json.Obj) !void {
        try o.str("id", self.id);
        try o.str("source_id", self.source_id);
        try o.str("batch_id", self.batch_id);
        try o.str("result_kind", self.result_kind);
        try o.str("coverage", self.coverage);
        var inner = try o.obj("retrieval");
        try self.retrieval.write(&inner);
        try inner.end();
        if (self.capture_ids) |list| {
            var arr = try o.arr("capture_ids");
            for (list) |id| try arr.str(id);
            try arr.end();
        } else {
            try o.raw("capture_ids", "null");
        }
        try o.str("created_at", self.created_at);
        if (self.omitted > 0) {
            try o.boolean("truncated", true);
            try o.int("omitted", @intCast(self.omitted));
        }
    }
};
