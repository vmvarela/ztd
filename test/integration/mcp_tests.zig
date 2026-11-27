//! The MCP stdio suite, ported from `test/integration/mcp_test.go`:
//! journey, source flow, document tools, and the three delete/capture
//! privacy tests plus doc_put. Assertions stay exactly as strict as Go's:
//! a disagreement with the binary is reported, never weakened.

const std = @import("std");
const json = std.json;
const harness = @import("harness.zig");
const mcp = @import("mcpclient.zig");

const Ctx = harness.Ctx;
const ToolResult = mcp.ToolResult;

// ------------------------------------------------------------- shared types

const Capture = struct {
    id: []const u8 = "",
    scope: []const u8 = "",
    original_text: []const u8 = "",
    processing_state: []const u8 = "",
    revision: i64 = 0,
};

const WorkItem = struct {
    id: []const u8 = "",
    title: []const u8 = "",
    origin_capture_id: []const u8 = "",
    lifecycle: []const u8 = "",
    revision: i64 = 0,
};

const ProcessData = struct {
    capture: Capture = .{},
    work_items: []WorkItem = &.{},
};

const PlanItem = struct {
    work_item_id: []const u8 = "",
    role: []const u8 = "",
};

const PlanData = struct {
    id: []const u8 = "",
    status: []const u8 = "",
    revision: i64 = 0,
    items: []PlanItem = &.{},
};

const PrepareData = struct {
    date: []const u8 = "",
    next: []WorkItem = &.{},
    plan: ?PlanData = null,
};

const Focus = struct {
    id: []const u8 = "",
    work_item_id: []const u8 = "",
    ended_at: ?[]const u8 = null,
};

const FocusStartData = struct {
    focus: Focus = .{},
};

const Checkpoint = struct {
    id: []const u8 = "",
    work_item_id: []const u8 = "",
    result: []const u8 = "",
    next_action: []const u8 = "",
};

const Review = struct {
    id: []const u8 = "",
    kind: []const u8 = "",
    completion_state: []const u8 = "",
};

const SourceView = struct {
    id: []const u8 = "",
    kind: []const u8 = "",
    connector: []const u8 = "",
    coverage: []const u8 = "",
};

const SourcesEnv = struct {
    sources: []SourceView = &.{},
};

const ReviewView = struct {
    id: []const u8 = "",
    source_id: []const u8 = "",
    batch_id: []const u8 = "",
    result_kind: []const u8 = "",
    coverage: []const u8 = "",
};

const SourceReviewEnv = struct {
    review: ReviewView = .{},
    captures: []Capture = &.{},
};

const NextEnv = struct {
    capture: Capture = .{},
    stats: struct {
        pending: i64 = 0,
        due: i64 = 0,
        remaining: i64 = 0,
    } = .{},
};

const Document = struct {
    id: []const u8 = "",
    scope: []const u8 = "",
    kind: []const u8 = "",
    slug: []const u8 = "",
    title: []const u8 = "",
    body: []const u8 = "",
    status: []const u8 = "",
    revision: i64 = 0,
};

const RelationsEnv = struct {
    source: Document = .{},
    outlinks: []Document = &.{},
    backlinks: []Document = &.{},
};

const DocHit = struct {
    document: struct {
        kind: []const u8 = "",
        slug: []const u8 = "",
        body: []const u8 = "",
    } = .{},
    rank: f64 = 0,
    snippet: []const u8 = "",
};

const SearchEnv = struct {
    hits: []DocHit = &.{},
};

const LogEntry = struct {
    seq: i64 = 0,
    event: []const u8 = "",
    revision: i64 = 0,
    scope: []const u8 = "",
    kind: []const u8 = "",
    slug: []const u8 = "",
};

const initArgs = [_][]const u8{
    "init",
    "--scope",
    "id=personal,kind=personal",
    "--scope",
    "id=opensource,kind=opensource",
};

// ------------------------------------------------------------------ helpers

fn initDB(ctx: *Ctx, db: []const u8) !void {
    _ = try ctx.wantOK(try ctx.run(db, &initArgs), "init");
}

fn contains(hay: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, hay, needle) != null;
}

/// Go's `mcpCall`: a protocol error (unknown method, broken pipe) is fatal.
fn call(ctx: *Ctx, cs: *mcp.Client, name: []const u8, args: ?json.Value) !ToolResult {
    return cs.callTool(name, args) catch |err| switch (err) {
        error.McpProtocol => ctx.fatal("{s}: {s}", .{ name, cs.last_protocol_error }),
        else => ctx.fatal("{s}: {s}", .{ name, @errorName(err) }),
    };
}

fn wantToolOK(ctx: *Ctx, name: []const u8, res: ToolResult) !void {
    if (res.is_error)
        return ctx.fatal("{s}: isError=true, want success; content: {s}", .{ name, res.text });
    if (res.structured == null)
        return ctx.fatal("{s}: structured content is nil", .{name});
}

fn scJSON(res: ToolResult) []const u8 {
    if (res.structured) |v| return harness.dump(std.heap.page_allocator, v);
    return "<nil>";
}

fn scDecode(ctx: *Ctx, comptime T: type, name: []const u8, res: ToolResult) !T {
    try wantToolOK(ctx, name, res);
    return ctx.decode(T, res.structured.?);
}

/// Accepts either a bare capture object or a {capture: ...} envelope, because
/// the tool result shape is owned by the mcpserver lane.
fn scCapture(ctx: *Ctx, name: []const u8, res: ToolResult) !Capture {
    try wantToolOK(ctx, name, res);
    const direct = try ctx.decode(Capture, res.structured.?);
    if (direct.id.len != 0) return direct;
    const wrapped = try ctx.decode(struct { capture: Capture = .{} }, res.structured.?);
    if (wrapped.capture.id.len == 0)
        return ctx.fatal("{s}: no capture in structured content {s}", .{ name, scJSON(res) });
    return wrapped.capture;
}

/// Accepts the wrapped {focus, checkpoints} shape or a bare focus session.
fn scFocus(ctx: *Ctx, res: ToolResult) !Focus {
    const wrapped = try ctx.decode(FocusStartData, res.structured.?);
    if (wrapped.focus.id.len != 0) return wrapped.focus;
    const flat = try ctx.decode(Focus, res.structured.?);
    if (flat.id.len == 0)
        return ctx.fatal("focus_start: no focus in structured content {s}", .{scJSON(res)});
    return flat;
}

fn structuredHas(ctx: *Ctx, res: ToolResult, want: []const u8) bool {
    _ = ctx;
    if (res.structured) |v| return harness.containsString(v, want);
    return false;
}

fn containsID(items: []const WorkItem, id: []const u8) bool {
    for (items) |item| if (std.mem.eql(u8, item.id, id)) return true;
    return false;
}

// --------------------------------------------------------- TestMCPStdioJourney

/// Drives the real binary as an MCP stdio server: the tool listing, the
/// capture-to-review journey, a lost-response replay with the same
/// idempotency key, find without a limit, and the read bound of 5 IDs.
pub fn testMCPStdioJourney(ctx: *Ctx) anyerror!void {
    const db = try ctx.tempDb();
    const period = try ctx.todayUTC();
    try initDB(ctx, db);

    const cs = try mcp.Client.connect(ctx, db, &.{});
    defer cs.close();

    // Go uses t.Errorf here: record, then keep walking the journey.
    const tools = try cs.listTools();
    const want_tools = [_][]const u8{
        "capture",              "inbox_next",  "process_capture", "prepare",
        "commit_plan",          "focus_start", "checkpoint",      "focus_finish",
        "record_review",        "find",        "read",            "sources",
        "record_source_review", "doc_search",  "doc_get",         "doc_related",
        "doc_put",              "trace",
    };
    if (tools.len != want_tools.len)
        ctx.err("listed {d} tools, want {d}", .{ tools.len, want_tools.len });
    for (want_tools) |name| {
        var have = false;
        for (tools) |tool| {
            if (std.mem.eql(u8, mcp.jstr(tool, "name") orelse "", name)) have = true;
        }
        if (!have) ctx.err("tool \"{s}\" not listed", .{name});
    }

    // capture: structured content carries the durable identity.
    const capText = "write the quarterly report over mcp";
    const capKey = "mcp-capture-1";
    const capRes = try call(ctx, cs, "capture", try mcp.obj(ctx.arena, &.{
        .{ "idempotency_key", mcp.val(capKey) },
        .{ "text", mcp.val(capText) },
    }));
    const cap = try scCapture(ctx, "capture", capRes);
    if (!harness.isId(cap.id, "C-"))
        return ctx.fatal("capture id = \"{s}\", want C-YYYYMMDD-NNN", .{cap.id});
    if (!std.mem.eql(u8, cap.processing_state, "pending") or
        !std.mem.eql(u8, cap.original_text, capText) or
        !std.mem.eql(u8, cap.scope, "personal"))
        return ctx.fatal("capture = {s}, want pending personal capture of \"{s}\"", .{ scJSON(capRes), capText });

    // inbox_next: same capture, oldest pending first, plus remaining counts.
    const nextRes = try call(ctx, cs, "inbox_next", null);
    try wantToolOK(ctx, "inbox_next", nextRes);
    const nextEnv = try ctx.decode(NextEnv, nextRes.structured.?);
    if (!std.mem.eql(u8, nextEnv.capture.id, cap.id))
        return ctx.fatal("inbox_next id = \"{s}\", want the captured \"{s}\"", .{ nextEnv.capture.id, cap.id });
    if (nextEnv.stats.pending != 1 or nextEnv.stats.remaining != 1)
        return ctx.fatal("inbox_next stats = pending={d} due={d} remaining={d}, want pending=1 remaining=1", .{
            nextEnv.stats.pending, nextEnv.stats.due, nextEnv.stats.remaining,
        });

    // process_capture: one work item from the pending capture.
    const title = "Draft quarterly report";
    const pr = try scDecode(ctx, ProcessData, "process_capture", try call(ctx, cs, "process_capture", try mcp.obj(ctx.arena, &.{
        .{ "idempotency_key", mcp.val("mcp-process-1") },
        .{ "capture_id", mcp.val(cap.id) },
        .{ "outcome", mcp.val("work_items") },
        .{ "titles", try mcp.arr(ctx.arena, &.{ mcp.val(title), mcp.val("Check report references") }) },
    })));
    if (!std.mem.eql(u8, pr.capture.id, cap.id) or !std.mem.eql(u8, pr.capture.processing_state, "processed"))
        return ctx.fatal("processed capture = id \"{s}\" state \"{s}\", want {s} processed", .{ pr.capture.id, pr.capture.processing_state, cap.id });
    if (pr.work_items.len != 2)
        return ctx.fatal("work items = {d}, want 2", .{pr.work_items.len});
    const item = pr.work_items[0];
    const unplanned = pr.work_items[1];
    if (!harness.isId(item.id, "T-") or !std.mem.eql(u8, item.title, title) or
        !std.mem.eql(u8, item.origin_capture_id, cap.id))
        return ctx.fatal("work item id={s} title=\"{s}\" origin={s}, want a T-YYYYMMDD-NNN titled \"{s}\" from {s}", .{
            item.id, item.title, item.origin_capture_id, title, cap.id,
        });

    // prepare: today's brief contains the new next action.
    const briefRes = try call(ctx, cs, "prepare", try mcp.obj(ctx.arena, &.{.{ "date", mcp.val(period) }}));
    try wantToolOK(ctx, "prepare", briefRes);
    const brief = try ctx.decode(PrepareData, briefRes.structured.?);
    if (!std.mem.eql(u8, brief.date, period))
        return ctx.fatal("prepare date = \"{s}\", want \"{s}\"", .{ brief.date, period });
    if (!containsID(brief.next, item.id))
        return ctx.fatal("prepare next = {s}, want {s}", .{ harness.dump(ctx.arena, briefRes.structured.?), item.id });

    // commit_plan: one MIT for today.
    const planRes = try call(ctx, cs, "commit_plan", try mcp.obj(ctx.arena, &.{
        .{ "idempotency_key", mcp.val("mcp-plan-1") },
        .{ "kind", mcp.val("daily") },
        .{ "period", mcp.val(period) },
        .{ "items", try mcp.arr(ctx.arena, &.{try mcp.obj(ctx.arena, &.{
            .{ "work_item_id", mcp.val(item.id) },
            .{ "role", mcp.val("mit") },
        })}) },
    }));
    try wantToolOK(ctx, "commit_plan", planRes);
    const plan = try ctx.decode(PlanData, planRes.structured.?);
    const want_plan_id = try std.fmt.allocPrint(ctx.arena, "P-personal-daily-{s}", .{period});
    if (!std.mem.eql(u8, plan.id, want_plan_id) or !std.mem.eql(u8, plan.status, "committed") or plan.revision != 1)
        return ctx.fatal("plan = {s}, want committed revision 1 for {s}", .{ harness.dump(ctx.arena, planRes.structured.?), period });
    if (plan.items.len != 1 or !std.mem.eql(u8, plan.items[0].work_item_id, item.id) or
        !std.mem.eql(u8, plan.items[0].role, "mit"))
        return ctx.fatal("plan items = {s}, want [{s} mit]", .{ harness.dump(ctx.arena, planRes.structured.?), item.id });

    // focus: start, checkpoint, finish.
    const fsRes = try call(ctx, cs, "focus_start", try mcp.obj(ctx.arena, &.{
        .{ "idempotency_key", mcp.val("mcp-focus-1") },
        .{ "work_item_id", mcp.val(item.id) },
    }));
    try wantToolOK(ctx, "focus_start", fsRes);
    const focus = try scFocus(ctx, fsRes);
    if (!harness.isId(focus.id, "F-") or !std.mem.eql(u8, focus.work_item_id, item.id))
        return ctx.fatal("focus start = {s}, want F-YYYYMMDD-NNN on {s}", .{ scJSON(fsRes), item.id });

    const cpRes = try call(ctx, cs, "checkpoint", try mcp.obj(ctx.arena, &.{
        .{ "idempotency_key", mcp.val("mcp-checkpoint-1") },
        .{ "work_item_id", mcp.val(item.id) },
        .{ "result", mcp.val("halfway through") },
    }));
    try wantToolOK(ctx, "checkpoint", cpRes);
    const cp = try ctx.decode(Checkpoint, cpRes.structured.?);
    if (!std.mem.eql(u8, cp.work_item_id, item.id) or !std.mem.eql(u8, cp.result, "halfway through"))
        return ctx.fatal("checkpoint = {s}, want result on {s}", .{ scJSON(cpRes), item.id });

    const finRes = try call(ctx, cs, "focus_finish", try mcp.obj(ctx.arena, &.{
        .{ "idempotency_key", mcp.val("mcp-finish-1") },
        .{ "focus_id", mcp.val(focus.id) },
        .{ "outcome", mcp.val("done for now") },
    }));
    try wantToolOK(ctx, "focus_finish", finRes);
    const fin = try ctx.decode(Focus, finRes.structured.?);
    if (!std.mem.eql(u8, fin.id, focus.id) or fin.ended_at == null)
        return ctx.fatal("focus finish = {s}, want {s} with ended_at", .{ scJSON(finRes), focus.id });

    const unplannedFocusRes = try call(ctx, cs, "focus_start", try mcp.obj(ctx.arena, &.{
        .{ "idempotency_key", mcp.val("mcp-focus-unplanned") },
        .{ "work_item_id", mcp.val(unplanned.id) },
    }));
    try wantToolOK(ctx, "focus_start", unplannedFocusRes);
    const unplannedFocus = try scFocus(ctx, unplannedFocusRes);

    const checkpointReadRes = try call(ctx, cs, "read", try mcp.obj(ctx.arena, &.{
        .{ "ids", try mcp.arr(ctx.arena, &.{ mcp.val(item.id), mcp.val(unplanned.id) }) },
    }));
    try wantToolOK(ctx, "read", checkpointReadRes);
    if (!checkpointHas(checkpointReadRes, item.id, cp.result, null) or
        !checkpointHas(checkpointReadRes, unplanned.id, null, null))
        return ctx.fatal("read checkpoints before unplanned checkpoint = {s}, want saved and null entries", .{scJSON(checkpointReadRes)});

    const unplanned_checkpoints = [_]struct { key: []const u8, result: []const u8, next_action: []const u8 }{
        .{ .key = "mcp-checkpoint-unplanned-1", .result = "references checked", .next_action = "" },
        .{ .key = "mcp-checkpoint-unplanned-2", .result = "report ready", .next_action = "send draft" },
    };
    for (unplanned_checkpoints) |c| {
        const checkpointRes = try call(ctx, cs, "checkpoint", try mcp.obj(ctx.arena, &.{
            .{ "idempotency_key", mcp.val(c.key) },
            .{ "work_item_id", mcp.val(unplanned.id) },
            .{ "result", mcp.val(c.result) },
            .{ "next_action", mcp.val(c.next_action) },
        }));
        try wantToolOK(ctx, "checkpoint", checkpointRes);
    }
    const afterRead = try call(ctx, cs, "read", try mcp.obj(ctx.arena, &.{
        .{ "ids", try mcp.arr(ctx.arena, &.{mcp.val(unplanned.id)}) },
    }));
    try wantToolOK(ctx, "read", afterRead);
    if (!checkpointHas(afterRead, unplanned.id, "report ready", "send draft"))
        return ctx.fatal("read unplanned checkpoint = {s}, want latest result and next action", .{scJSON(afterRead)});

    const unplannedFinishRes = try call(ctx, cs, "focus_finish", try mcp.obj(ctx.arena, &.{
        .{ "idempotency_key", mcp.val("mcp-finish-unplanned") },
        .{ "focus_id", mcp.val(unplannedFocus.id) },
        .{ "outcome", mcp.val("done for now") },
    }));
    try wantToolOK(ctx, "focus_finish", unplannedFinishRes);
    const unplannedFinish = try ctx.decode(Focus, unplannedFinishRes.structured.?);
    if (!std.mem.eql(u8, unplannedFinish.id, unplannedFocus.id) or unplannedFinish.ended_at == null)
        return ctx.fatal("read changed active focus: finish = {s}, focus id = {s}", .{ scJSON(unplannedFinishRes), unplannedFocus.id });

    // review: complete daily review for today.
    const revRes = try call(ctx, cs, "record_review", try mcp.obj(ctx.arena, &.{
        .{ "idempotency_key", mcp.val("mcp-review-1") },
        .{ "kind", mcp.val("daily") },
        .{ "period", mcp.val(period) },
        .{ "outcomes", mcp.val("captured and planned") },
        .{ "coverage", mcp.val("inbox+next") },
    }));
    try wantToolOK(ctx, "record_review", revRes);
    const rev = try ctx.decode(Review, revRes.structured.?);
    if (!std.mem.eql(u8, rev.kind, "daily") or !std.mem.eql(u8, rev.completion_state, "complete"))
        return ctx.fatal("review = {s}, want a complete daily review", .{scJSON(revRes)});

    // find without a limit argument: default bound, item is visible.
    const findRes = try call(ctx, cs, "find", try mcp.obj(ctx.arena, &.{.{ "query", mcp.val("quarterly") }}));
    try wantToolOK(ctx, "find", findRes);
    if (!structuredHas(ctx, findRes, item.id))
        return ctx.fatal("find does not return {s}: {s}", .{ item.id, scJSON(findRes) });

    // read within the 5-ID bound.
    const readRes = try call(ctx, cs, "read", try mcp.obj(ctx.arena, &.{
        .{ "ids", try mcp.arr(ctx.arena, &.{ mcp.val(cap.id), mcp.val(item.id) }) },
    }));
    try wantToolOK(ctx, "read", readRes);
    for ([_][]const u8{ cap.id, item.id }) |id| {
        if (!structuredHas(ctx, readRes, id))
            ctx.err("read does not return {s}: {s}", .{ id, scJSON(readRes) });
    }

    // Lost-response replay: a fresh server process with the same key and the
    // same text must return the identity stored by the first call.
    cs.close();
    const cs2 = try mcp.Client.connect(ctx, db, &.{});
    defer cs2.close();

    const replay = try scCapture(ctx, "capture replay", try call(ctx, cs2, "capture", try mcp.obj(ctx.arena, &.{
        .{ "idempotency_key", mcp.val(capKey) },
        .{ "text", mcp.val(capText) },
    })));
    if (!std.mem.eql(u8, replay.id, cap.id))
        return ctx.fatal("replay capture id = \"{s}\", want the original \"{s}\"", .{ replay.id, cap.id });

    const changed_text = try std.fmt.allocPrint(ctx.arena, "{s} changed", .{capText});
    const conflict = try call(ctx, cs2, "capture", try mcp.obj(ctx.arena, &.{
        .{ "idempotency_key", mcp.val(capKey) },
        .{ "text", mcp.val(changed_text) },
    }));
    if (!conflict.is_error or !contains(conflict.text, "idempotency_conflict"))
        return ctx.fatal("same key with different text: want idempotency_conflict; content: {s}", .{conflict.text});

    // find with no limit still works after reconnect.
    try wantToolOK(ctx, "find", try call(ctx, cs2, "find", try mcp.obj(ctx.arena, &.{.{ "query", mcp.val("quarterly") }})));

    // read accepts at most 5 IDs; the sixth is invalid_input.
    const bigRead = try call(ctx, cs2, "read", try mcp.obj(ctx.arena, &.{
        .{ "ids", try mcp.arr(ctx.arena, &.{
            mcp.val(cap.id),   mcp.val(item.id), mcp.val(plan.id),
            mcp.val(focus.id), mcp.val(rev.id),  mcp.val(cp.id),
        }) },
    }));
    if (!bigRead.is_error)
        return ctx.fatal("read with 6 ids: isError=false, want true; content: {s}", .{bigRead.text});
    if (!contains(bigRead.text, "invalid_input"))
        return ctx.fatal("read error text = \"{s}\", want it to contain invalid_input", .{bigRead.text});

    // Scope boundary: foreign and missing IDs must be indistinguishable.
    const foreign = try mcp.Client.connect(ctx, db, &.{ "--scope", "opensource" });
    defer foreign.close();
    const hidden = try call(ctx, foreign, "read", try mcp.obj(ctx.arena, &.{
        .{ "ids", try mcp.arr(ctx.arena, &.{mcp.val(cap.id)}) },
    }));
    if (!hidden.is_error)
        return ctx.fatal("read foreign id: isError=false, want not_found; content: {s}", .{hidden.text});
    if (!contains(hidden.text, "not_found") or contains(hidden.text, "personal"))
        return ctx.fatal("read foreign id leaked scope: \"{s}\"", .{hidden.text});
    const missing = try call(ctx, foreign, "read", try mcp.obj(ctx.arena, &.{
        .{ "ids", try mcp.arr(ctx.arena, &.{mcp.val("C-00000000-000")}) },
    }));
    if (!missing.is_error or !std.mem.eql(u8, missing.text, hidden.text))
        return ctx.fatal("foreign capture error \"{s}\" differs from missing capture error \"{s}\"", .{ hidden.text, missing.text });

    const hidden_item = try call(ctx, foreign, "read", try mcp.obj(ctx.arena, &.{
        .{ "ids", try mcp.arr(ctx.arena, &.{mcp.val(item.id)}) },
    }));
    const workItemError = hidden_item.text;
    if (!hidden_item.is_error or !contains(workItemError, "not_found") or contains(workItemError, "personal"))
        return ctx.fatal("read foreign work item leaked data: \"{s}\"", .{workItemError});
    const missing_item = try call(ctx, foreign, "read", try mcp.obj(ctx.arena, &.{
        .{ "ids", try mcp.arr(ctx.arena, &.{mcp.val("T-00000000-000")}) },
    }));
    if (!missing_item.is_error or !std.mem.eql(u8, missing_item.text, workItemError))
        return ctx.fatal("foreign work item error \"{s}\" differs from missing work item error \"{s}\"", .{ workItemError, missing_item.text });
}

/// Go reads `checkpoints` as map[string]*checkpointData: a missing entry and
/// a JSON null are both nil. `want_result == null` asserts the entry is nil.
fn checkpointHas(res: ToolResult, id: []const u8, want_result: ?[]const u8, want_next: ?[]const u8) bool {
    const structured = res.structured orelse return false;
    const cps = harness.jget(structured, "checkpoints") orelse return false;
    const map = switch (cps) {
        .object => |o| o,
        else => return false,
    };
    const entry = map.get(id) orelse return want_result == null;
    if (entry == .null) return want_result == null;
    const wr = want_result orelse return false;
    if (!std.mem.eql(u8, harness.jstr(entry, "result") orelse "", wr)) return false;
    if (want_next) |wn| {
        if (!std.mem.eql(u8, harness.jstr(entry, "next_action") orelse "", wn)) return false;
    }
    return true;
}

// ----------------------------------------------------------- TestMCPSourceFlow

/// Covers the source boundary end to end: register through the CLI, list it,
/// record a reported batch that becomes a pending capture, replay the same
/// key without duplicating, and refuse an observed claim.
pub fn testMCPSourceFlow(ctx: *Ctx) anyerror!void {
    const db = try ctx.tempDb();
    try initDB(ctx, db);
    _ = try ctx.wantOK(try ctx.run(db, &.{
        "source",           "add",
        "--id",             "notes-dir",
        "--name",           "Notes directory",
        "--scope",          "personal",
        "--kind",           "capture",
        "--connector",      "directory",
        "--connection-ref", "[\"/tmp/notes\"]",
    }), "source add");

    const cs = try mcp.Client.connect(ctx, db, &.{});
    defer cs.close();

    // sources: registry state for the fixed binding, no provider contents.
    const sourcesRes = try call(ctx, cs, "sources", null);
    try wantToolOK(ctx, "sources", sourcesRes);
    const sourcesEnv = try ctx.decode(SourcesEnv, sourcesRes.structured.?);
    if (sourcesEnv.sources.len != 1)
        return ctx.fatal("sources = {s}, want exactly [notes-dir]", .{scJSON(sourcesRes)});
    const src = sourcesEnv.sources[0];
    if (!std.mem.eql(u8, src.id, "notes-dir") or !std.mem.eql(u8, src.kind, "capture") or
        !std.mem.eql(u8, src.connector, "directory") or !std.mem.eql(u8, src.coverage, "unknown"))
        return ctx.fatal("source = {s}, want notes-dir capture/directory coverage unknown", .{scJSON(sourcesRes)});

    // Record one reported item; it becomes a pending capture.
    const itemText = "renew the parking permit before the trip";
    const batchArgs = try mcp.obj(ctx.arena, &.{
        .{ "source_id", mcp.val("notes-dir") },
        .{ "batch_id", mcp.val("batch-1") },
        .{ "idempotency_key", mcp.val("mcp-source-1") },
        .{ "retrieval", try mcp.obj(ctx.arena, &.{
            .{ "window", mcp.val("2026-11-20") },
            .{ "cursor", mcp.val("") },
            .{ "requested_limit", mcp.num(50) },
            .{ "provider_returned_limit", mcp.num(1) },
            .{ "complete_window", mcp.boolean(true) },
            .{ "truncated", mcp.boolean(false) },
            .{ "failures", try mcp.arr(ctx.arena, &.{}) },
        }) },
        .{ "items", try mcp.arr(ctx.arena, &.{try mcp.obj(ctx.arena, &.{
            .{ "external_id", mcp.val("note-001") },
            .{ "external_revision", mcp.val("1") },
            .{ "original_text", mcp.val(itemText) },
            .{ "source_uri", mcp.val("file:///notes/note-001.md") },
            .{ "provider_metadata_summary", mcp.val("file note, title only") },
        })}) },
    });
    const reviewRes = try call(ctx, cs, "record_source_review", batchArgs);
    try wantToolOK(ctx, "record_source_review", reviewRes);
    const reviewEnv = try ctx.decode(SourceReviewEnv, reviewRes.structured.?);
    if (!std.mem.eql(u8, reviewEnv.review.source_id, "notes-dir") or
        !std.mem.eql(u8, reviewEnv.review.result_kind, "reported"))
        return ctx.fatal("review = {s}, want a reported review for notes-dir", .{scJSON(reviewRes)});
    if (!std.mem.eql(u8, reviewEnv.review.coverage, "unverified"))
        return ctx.fatal("coverage = \"{s}\", want unverified: a model batch is never trusted", .{reviewEnv.review.coverage});
    if (reviewEnv.captures.len != 1)
        return ctx.fatal("captures = {s}, want exactly one new capture", .{scJSON(reviewRes)});
    const batchCap = reviewEnv.captures[0];
    if (!std.mem.eql(u8, batchCap.original_text, itemText) or
        !std.mem.eql(u8, batchCap.processing_state, "pending"))
        return ctx.fatal("capture = {s}, want a pending capture of \"{s}\"", .{ scJSON(reviewRes), itemText });

    // Retry with the same key and payload: the stored result replays, so the
    // capture count in the inbox does not grow.
    const retryRes = try call(ctx, cs, "record_source_review", batchArgs);
    try wantToolOK(ctx, "record_source_review", retryRes);
    const retryEnv = try ctx.decode(SourceReviewEnv, retryRes.structured.?);
    if (!std.mem.eql(u8, retryEnv.review.id, reviewEnv.review.id))
        return ctx.fatal("retry review id = \"{s}\", want the original \"{s}\"", .{ retryEnv.review.id, reviewEnv.review.id });
    if (retryEnv.captures.len != 1 or !std.mem.eql(u8, retryEnv.captures[0].id, batchCap.id))
        return ctx.fatal("retry captures = {s}, want the original {s} only", .{ scJSON(retryRes), batchCap.id });

    // The captured item shows up in the inbox as the oldest pending capture.
    const nextRes = try call(ctx, cs, "inbox_next", null);
    try wantToolOK(ctx, "inbox_next", nextRes);
    const nextEnv = try ctx.decode(NextEnv, nextRes.structured.?);
    if (!std.mem.eql(u8, nextEnv.capture.id, batchCap.id) or
        !std.mem.eql(u8, nextEnv.capture.original_text, itemText))
        return ctx.fatal("inbox_next = {s}, want the batch capture {s}", .{ scJSON(nextRes), batchCap.id });
    if (nextEnv.stats.pending != 1 or nextEnv.stats.remaining != 1)
        return ctx.fatal("inbox stats = pending={d} remaining={d}, want a single pending capture after the retry", .{
            nextEnv.stats.pending, nextEnv.stats.remaining,
        });

    // observed is refused at the model-facing boundary with invalid_input.
    const observed = try call(ctx, cs, "record_source_review", try mcp.obj(ctx.arena, &.{
        .{ "source_id", mcp.val("notes-dir") },
        .{ "batch_id", mcp.val("batch-2") },
        .{ "idempotency_key", mcp.val("mcp-source-observed") },
        .{ "result_kind", mcp.val("observed") },
        .{ "items", try mcp.arr(ctx.arena, &.{}) },
    }));
    if (!observed.is_error)
        return ctx.fatal("observed batch: isError=false, want invalid_input; content: {s}", .{observed.text});
    if (!contains(observed.text, "invalid_input"))
        return ctx.fatal("observed batch error text = \"{s}\", want invalid_input", .{observed.text});
}

// ------------------------------------------------------- TestMCPDocumentTools

/// Covers the read-only document tools over stdio: doc_search, doc_get,
/// doc_related, ambiguity conflicts, and scope privacy.
pub fn testMCPDocumentTools(ctx: *Ctx) anyerror!void {
    const db = try ctx.tempDb();
    try initDB(ctx, db);
    _ = try ctx.wantOK(try ctx.run(db, &.{
        "doc",     "put",            "--kind", "knowledge",                    "--slug", "komorebi/setup",
        "--title", "Komorebi setup", "--body", "the clone lives under repos/",
    }), "doc put");
    _ = try ctx.wantOK(try ctx.run(db, &.{
        "doc",     "put",   "--kind", "knowledge_index",    "--slug", "index",
        "--title", "Index", "--body", "[[komorebi/setup]]",
    }), "doc put");
    _ = try ctx.wantOK(try ctx.run(db, &.{
        "doc",     "put",           "--kind", "knowledge",      "--slug", "private-only",
        "--title", "Personal only", "--body", "private repos/",
    }), "doc put");
    _ = try ctx.wantOK(try ctx.run(db, &.{
        "doc",     "put",         "--kind", "knowledge",              "--slug",  "komorebi/setup",
        "--title", "Other setup", "--body", "separate scope content", "--scope", "opensource",
    }), "doc put");

    const cs = try mcp.Client.connect(ctx, db, &.{});
    defer cs.close();

    // doc_search: hits carry the document, its rank and a snippet.
    const searchRes = try call(ctx, cs, "doc_search", try mcp.obj(ctx.arena, &.{.{ "query", mcp.val("komorebi") }}));
    try wantToolOK(ctx, "doc_search", searchRes);
    const searchEnv = try ctx.decode(SearchEnv, searchRes.structured.?);
    if (searchEnv.hits.len != 3)
        return ctx.fatal("doc_search hits = {d}, want 3; {s}", .{ searchEnv.hits.len, scJSON(searchRes) });
    var found = false;
    for (searchEnv.hits) |h| {
        if (std.mem.eql(u8, h.document.slug, "komorebi/setup") and
            contains(h.document.body, "repos/") and
            h.rank < 0 and h.snippet.len != 0) found = true;
    }
    if (!found)
        return ctx.fatal("doc_search missed the card: {s}", .{scJSON(searchRes)});

    // The kind filter narrows the hits.
    const kindRes = try call(ctx, cs, "doc_search", try mcp.obj(ctx.arena, &.{
        .{ "query", mcp.val("komorebi") },
        .{ "kind", mcp.val("journal") },
    }));
    try wantToolOK(ctx, "doc_search", kindRes);
    if (structuredHas(ctx, kindRes, "komorebi/setup"))
        return ctx.fatal("kind filter returned a knowledge card: {s}", .{scJSON(kindRes)});

    // Duplicate slugs across scopes require an explicit target for reads.
    const ambiguousGet = try call(ctx, cs, "doc_get", try mcp.obj(ctx.arena, &.{
        .{ "kind", mcp.val("knowledge") },
        .{ "slug", mcp.val("komorebi/setup") },
    }));
    if (!ambiguousGet.is_error or !contains(ambiguousGet.text, "conflict"))
        return ctx.fatal("doc_get without scope = \"{s}\", want ambiguity conflict", .{ambiguousGet.text});
    const ambiguousRelated = try call(ctx, cs, "doc_related", try mcp.obj(ctx.arena, &.{
        .{ "kind", mcp.val("knowledge") },
        .{ "slug", mcp.val("komorebi/setup") },
    }));
    if (!ambiguousRelated.is_error or !contains(ambiguousRelated.text, "conflict"))
        return ctx.fatal("doc_related without scope = \"{s}\", want ambiguity conflict", .{ambiguousRelated.text});
    const blank_calls = [_]struct { tool: []const u8, scope: []const u8 }{
        .{ .tool = "doc_get", .scope = "" },
        .{ .tool = "doc_get", .scope = "  " },
        .{ .tool = "doc_related", .scope = "" },
        .{ .tool = "doc_related", .scope = "  " },
    };
    for (blank_calls) |c| {
        const res = try call(ctx, cs, c.tool, try mcp.obj(ctx.arena, &.{
            .{ "kind", mcp.val("knowledge") },
            .{ "slug", mcp.val("komorebi/setup") },
            .{ "scope", mcp.val(c.scope) },
        }));
        if (!res.is_error or !contains(res.text, "invalid_input"))
            return ctx.fatal("{s} blank scope \"{s}\" = \"{s}\", want invalid_input", .{ c.tool, c.scope, res.text });
    }

    // doc_get returns the requested document body.
    const getRes = try call(ctx, cs, "doc_get", try mcp.obj(ctx.arena, &.{
        .{ "kind", mcp.val("knowledge") },
        .{ "slug", mcp.val("komorebi/setup") },
        .{ "scope", mcp.val("personal") },
    }));
    try wantToolOK(ctx, "doc_get", getRes);
    const card = try ctx.decode(Document, getRes.structured.?);
    if (!std.mem.eql(u8, card.kind, "knowledge") or !std.mem.eql(u8, card.slug, "komorebi/setup") or
        !std.mem.eql(u8, card.body, "the clone lives under repos/"))
        return ctx.fatal("doc_get = {s}, want the stored card", .{scJSON(getRes)});

    // doc_related returns the index as the card's backlink.
    const relRes = try call(ctx, cs, "doc_related", try mcp.obj(ctx.arena, &.{
        .{ "kind", mcp.val("knowledge") },
        .{ "slug", mcp.val("komorebi/setup") },
        .{ "scope", mcp.val("personal") },
    }));
    try wantToolOK(ctx, "doc_related", relRes);
    const rel = try ctx.decode(RelationsEnv, relRes.structured.?);
    if (!std.mem.eql(u8, rel.source.slug, "komorebi/setup") or rel.outlinks.len != 0)
        return ctx.fatal("relation source/outlinks = {s}, want the card with no outlinks", .{scJSON(relRes)});
    if (rel.backlinks.len != 1 or !std.mem.eql(u8, rel.backlinks[0].slug, "index"))
        return ctx.fatal("backlinks = {s}, want the index; {s}", .{ scJSON(relRes), scJSON(relRes) });
    const osRel = try call(ctx, cs, "doc_related", try mcp.obj(ctx.arena, &.{
        .{ "kind", mcp.val("knowledge") },
        .{ "slug", mcp.val("komorebi/setup") },
        .{ "scope", mcp.val("opensource") },
    }));
    try wantToolOK(ctx, "doc_related opensource", osRel);
    const osRelations = try ctx.decode(struct { source: Document = .{} }, osRel.structured.?);
    if (!std.mem.eql(u8, osRelations.source.scope, "opensource") or
        !std.mem.eql(u8, osRelations.source.body, "separate scope content"))
        return ctx.fatal("doc_related opensource source = {s}, want opensource document", .{scJSON(osRel)});

    // Scope boundary: a server bound to opensource answers not_found for the
    // personal card without naming the scope, and search must not leak it.
    const foreign = try mcp.Client.connect(ctx, db, &.{ "--scope", "opensource" });
    defer foreign.close();
    const foreign_calls = [_][]const u8{ "doc_get", "doc_related" };
    for (foreign_calls) |tool| {
        const hidden = try call(ctx, foreign, tool, try mcp.obj(ctx.arena, &.{
            .{ "kind", mcp.val("knowledge") },
            .{ "slug", mcp.val("private-only") },
        }));
        if (!hidden.is_error)
            return ctx.fatal("{s} foreign: isError=false, want not_found; content: {s}", .{ tool, hidden.text });
        if (!contains(hidden.text, "not_found") or contains(hidden.text, "personal"))
            return ctx.fatal("{s} foreign leaked scope: \"{s}\"", .{ tool, hidden.text });
    }
    const hiddenSearch = try call(ctx, foreign, "doc_search", try mcp.obj(ctx.arena, &.{.{ "query", mcp.val("private repos") }}));
    try wantToolOK(ctx, "doc_search", hiddenSearch);
    if (structuredHas(ctx, hiddenSearch, "private-only"))
        return ctx.fatal("foreign doc_search leaked the card: {s}", .{scJSON(hiddenSearch)});
}

// ------------------------------------------------------- TestMCPDeleteSource

/// Drives delete_source over stdio with the explicit --allow-delete-source
/// opt-in: delete, replay, not_found, empty registry.
pub fn testMCPDeleteSource(ctx: *Ctx) anyerror!void {
    const db = try ctx.tempDb();
    try initDB(ctx, db);
    _ = try ctx.wantOK(try ctx.run(db, &.{
        "source",      "add",
        "--id",        "scratch",
        "--name",      "Scratch",
        "--scope",     "personal",
        "--kind",      "capture",
        "--connector", "manual",
    }), "source add");

    const cs = try mcp.Client.connect(ctx, db, &.{"--allow-delete-source"});
    defer cs.close();

    const del = try call(ctx, cs, "delete_source", try mcp.obj(ctx.arena, &.{
        .{ "source_id", mcp.val("scratch") },
        .{ "idempotency_key", mcp.val("mcp-del-1") },
    }));
    try wantToolOK(ctx, "delete_source", del);
    const delEnv = try ctx.decode(struct { source: struct { id: []const u8 = "" } = .{} }, del.structured.?);
    if (!std.mem.eql(u8, delEnv.source.id, "scratch"))
        return ctx.fatal("delete_source = {s}, want scratch", .{scJSON(del)});

    const replay = try call(ctx, cs, "delete_source", try mcp.obj(ctx.arena, &.{
        .{ "source_id", mcp.val("scratch") },
        .{ "idempotency_key", mcp.val("mcp-del-1") },
    }));
    try wantToolOK(ctx, "delete_source replay", replay);

    const missing = try call(ctx, cs, "delete_source", try mcp.obj(ctx.arena, &.{
        .{ "source_id", mcp.val("scratch") },
        .{ "idempotency_key", mcp.val("mcp-del-2") },
    }));
    if (!missing.is_error or !contains(missing.text, "not_found"))
        return ctx.fatal("second delete: isError={any} text=\"{s}\", want not_found", .{ missing.is_error, missing.text });

    const sources = try call(ctx, cs, "sources", null);
    try wantToolOK(ctx, "sources", sources);
    const listEnv = try ctx.decode(SourcesEnv, sources.structured.?);
    if (listEnv.sources.len != 0)
        return ctx.fatal("sources after delete = {s}, want none", .{scJSON(sources)});
}

// ---------------------------------------------- TestMCPDeleteSourceHiddenByDefault

/// Pins the default: without the opt-in flag delete_source is not served, a
/// direct call does not run, and the source survives.
pub fn testMCPDeleteSourceHiddenByDefault(ctx: *Ctx) anyerror!void {
    const db = try ctx.tempDb();
    try initDB(ctx, db);
    _ = try ctx.wantOK(try ctx.run(db, &.{
        "source",      "add",
        "--id",        "scratch",
        "--name",      "Scratch",
        "--scope",     "personal",
        "--kind",      "capture",
        "--connector", "manual",
    }), "source add");

    const cs = try mcp.Client.connect(ctx, db, &.{});
    defer cs.close();

    // Go: `if err == nil && !res.IsError { fatal }` — a protocol error or a
    // tool-level error both mean the tool did not run.
    if (cs.callTool("delete_source", try mcp.obj(ctx.arena, &.{
        .{ "source_id", mcp.val("scratch") },
        .{ "idempotency_key", mcp.val("mcp-hidden-1") },
    }))) |res| {
        if (!res.is_error)
            return ctx.fatal("delete_source ran without the opt-in flag: {s}", .{res.text});
    } else |_| {}

    const listData = try ctx.wantOK(try ctx.run(db, &.{ "source", "list" }), "source list");
    const list = try ctx.decode([]SourceView, listData);
    if (list.len != 1 or !std.mem.eql(u8, list[0].id, "scratch"))
        return ctx.fatal("source list = {s}, want scratch to survive", .{harness.dump(ctx.arena, listData)});
}

// ------------------------------- TestMCPDeleteSourceAnswersMissingAndForeignAlike

/// Error privacy: a source outside the bound scope and a source that does
/// not exist return the same not_found wire response.
pub fn testMCPDeleteSourceAnswersMissingAndForeignAlike(ctx: *Ctx) anyerror!void {
    const db = try ctx.tempDb();
    try initDB(ctx, db);
    _ = try ctx.wantOK(try ctx.run(db, &.{
        "source",      "add",
        "--id",        "vault",
        "--name",      "Vault",
        "--scope",     "opensource",
        "--kind",      "capture",
        "--connector", "manual",
    }), "source add");

    const cs = try mcp.Client.connect(ctx, db, &.{ "--allow-delete-source", "--scope", "personal" });
    defer cs.close();

    const foreign = try call(ctx, cs, "delete_source", try mcp.obj(ctx.arena, &.{
        .{ "source_id", mcp.val("vault") },
        .{ "idempotency_key", mcp.val("mcp-foreign-1") },
    }));
    const missing = try call(ctx, cs, "delete_source", try mcp.obj(ctx.arena, &.{
        .{ "source_id", mcp.val("ghost") },
        .{ "idempotency_key", mcp.val("mcp-missing-1") },
    }));
    if (!foreign.is_error or !missing.is_error)
        return ctx.fatal("foreign isError={any} missing isError={any}, want both refused", .{ foreign.is_error, missing.is_error });
    if (!contains(missing.text, "not_found"))
        return ctx.fatal("missing source text = \"{s}\", want not_found", .{missing.text});
    if (!std.mem.eql(u8, foreign.text, missing.text))
        return ctx.fatal("foreign and missing differ: \"{s}\" vs \"{s}\"", .{ foreign.text, missing.text });
}

// ------------------------------------ TestMCPCaptureSourceReferenceAnswersAlike

/// Capture privacy: a source registered in another scope and a source that
/// does not exist produce the same wire result, byte for byte.
pub fn testMCPCaptureSourceReferenceAnswersAlike(ctx: *Ctx) anyerror!void {
    const db = try ctx.tempDb();
    try initDB(ctx, db);
    _ = try ctx.wantOK(try ctx.run(db, &.{
        "source",      "add",
        "--id",        "vault",
        "--name",      "Vault",
        "--scope",     "opensource",
        "--kind",      "capture",
        "--connector", "manual",
    }), "source add");

    const cs = try mcp.Client.connect(ctx, db, &.{ "--scope", "personal" });
    defer cs.close();

    const foreign = try call(ctx, cs, "capture", try mcp.obj(ctx.arena, &.{
        .{ "idempotency_key", mcp.val("cap-foreign") },
        .{ "text", mcp.val("x") },
        .{ "source_id", mcp.val("vault") },
    }));
    const missing = try call(ctx, cs, "capture", try mcp.obj(ctx.arena, &.{
        .{ "idempotency_key", mcp.val("cap-missing") },
        .{ "text", mcp.val("x") },
        .{ "source_id", mcp.val("ghost") },
    }));
    if (!foreign.is_error or !missing.is_error)
        return ctx.fatal("foreign isError={any} missing isError={any}, want both refused", .{ foreign.is_error, missing.is_error });
    // Go compares the marshalled CallToolResult of both: equal contents, equal
    // isError and equal structured content presence means the wire results are
    // identical.
    if (!std.mem.eql(u8, foreign.text, missing.text) or
        (foreign.structured != null) != (missing.structured != null))
        return ctx.fatal("capture wire results differ:\nforeign: isError={any} text={s}\nmissing: isError={any} text={s}", .{
            foreign.is_error, foreign.text, missing.is_error, missing.text,
        });
    if (!std.mem.eql(u8, missing.text, "not_found: not found\n"))
        return ctx.fatal("capture missing source text = \"{s}\", want not_found: not found", .{missing.text});
}

/// The Go helper: fixed title, explicit personal scope, explicit revision.
fn docPutArgs(ctx: *Ctx, slug: []const u8, body: []const u8, expected: i64) !json.Value {
    return mcp.obj(ctx.arena, &.{
        .{ "slug", mcp.val(slug) },
        .{ "title", mcp.val("MCP draft") },
        .{ "body", mcp.val(body) },
        .{ "scope", mcp.val("personal") },
        .{ "expected_revision", mcp.num(expected) },
    });
}

// ------------------------------------------------------------- TestMCPDocPut

/// Covers draft writes over stdio: agent-selected scopes within the binding,
/// duplicate slugs across scopes, idempotency and revision guards, schema
/// restrictions, and the two-step capture reference flow.
pub fn testMCPDocPut(ctx: *Ctx) anyerror!void {
    const db = try ctx.tempDb();
    try initDB(ctx, db);

    const cs = try mcp.Client.connect(ctx, db, &.{});
    defer cs.close();

    const slug = "komorebi/mcp-draft";
    const oversized_body = try ctx.arena.alloc(u8, (512 << 10) + 1);
    @memset(oversized_body, 'x');
    const oversized = try call(ctx, cs, "doc_put", try mcp.obj(ctx.arena, &.{
        .{ "slug", mcp.val("komorebi/oversized") },
        .{ "title", mcp.val("Oversized") },
        .{ "body", mcp.val(oversized_body) },
        .{ "scope", mcp.val("personal") },
        .{ "expected_revision", mcp.num(0) },
    }));
    if (!oversized.is_error or !contains(oversized.text, "invalid_input"))
        return ctx.fatal("oversized doc_put = \"{s}\", want invalid_input", .{oversized.text});
    const missingOversized = try call(ctx, cs, "doc_get", try mcp.obj(ctx.arena, &.{
        .{ "kind", mcp.val("knowledge") },
        .{ "slug", mcp.val("komorebi/oversized") },
        .{ "scope", mcp.val("personal") },
    }));
    if (!missingOversized.is_error or !contains(missingOversized.text, "not_found"))
        return ctx.fatal("oversized document lookup = \"{s}\", want not_found", .{missingOversized.text});

    // The destination scope is selected explicitly; kind and status are fixed.
    const createRes = try call(ctx, cs, "doc_put", try docPutArgs(ctx, slug, "first body", 0));
    try wantToolOK(ctx, "doc_put", createRes);
    const doc = try ctx.decode(Document, createRes.structured.?);
    if (!std.mem.eql(u8, doc.kind, "knowledge") or !std.mem.eql(u8, doc.status, "draft") or
        !std.mem.eql(u8, doc.scope, "personal") or doc.revision != 1 or
        !std.mem.eql(u8, doc.body, "first body") or !std.mem.eql(u8, doc.slug, slug))
        return ctx.fatal("doc_put create = {s}, want personal knowledge draft at revision 1", .{scJSON(createRes)});

    // Same slug can exist in another bound scope.
    const osCreate = try call(ctx, cs, "doc_put", try mcp.obj(ctx.arena, &.{
        .{ "slug", mcp.val(slug) },
        .{ "title", mcp.val("MCP draft") },
        .{ "body", mcp.val("opensource body") },
        .{ "scope", mcp.val("opensource") },
        .{ "expected_revision", mcp.num(0) },
    }));
    try wantToolOK(ctx, "doc_put opensource", osCreate);
    const osDoc = try ctx.decode(Document, osCreate.structured.?);
    if (!std.mem.eql(u8, osDoc.scope, "opensource") or !std.mem.eql(u8, osDoc.body, "opensource body"))
        return ctx.fatal("doc_put opensource = {s}, want independent opensource document", .{scJSON(osCreate)});
    const ambiguous = try call(ctx, cs, "doc_get", try mcp.obj(ctx.arena, &.{
        .{ "kind", mcp.val("knowledge") },
        .{ "slug", mcp.val(slug) },
    }));
    if (!ambiguous.is_error or !contains(ambiguous.text, "conflict"))
        return ctx.fatal("doc_get without scope = \"{s}\", want ambiguity conflict", .{ambiguous.text});
    const osGet = try call(ctx, cs, "doc_get", try mcp.obj(ctx.arena, &.{
        .{ "kind", mcp.val("knowledge") },
        .{ "slug", mcp.val(slug) },
        .{ "scope", mcp.val("opensource") },
    }));
    try wantToolOK(ctx, "doc_get opensource", osGet);
    const osCurrent = try ctx.decode(Document, osGet.structured.?);
    if (!std.mem.eql(u8, osCurrent.body, "opensource body"))
        return ctx.fatal("doc_get opensource = {s}, want opensource body", .{scJSON(osGet)});

    // Idempotent retry: the identical payload replays the stored document and
    // the history keeps a single event.
    const retryRes = try call(ctx, cs, "doc_put", try docPutArgs(ctx, slug, "first body", 0));
    try wantToolOK(ctx, "doc_put", retryRes);
    const retry = try ctx.decode(Document, retryRes.structured.?);
    if (retry.revision != 1 or !std.mem.eql(u8, retry.body, "first body"))
        return ctx.fatal("retry = {s}, want the original revision 1 document", .{scJSON(retryRes)});
    const log = try ctx.decode([]LogEntry, try ctx.wantOK(try ctx.run(db, &.{ "doc", "log", "--slug", slug }), "doc log"));
    var personal_events: usize = 0;
    var first_personal_event: []const u8 = "";
    for (log) |entry| {
        if (std.mem.eql(u8, entry.scope, "personal")) {
            personal_events += 1;
            if (first_personal_event.len == 0) first_personal_event = entry.event;
        }
    }
    if (personal_events != 1 or !std.mem.eql(u8, first_personal_event, "created"))
        return ctx.fatal("personal doc log after retry = {d} entries (first \"{s}\"), want a single created event", .{ personal_events, first_personal_event });

    // Same derived key (expected 0), different payload: idempotency_conflict.
    const conflict = try call(ctx, cs, "doc_put", try docPutArgs(ctx, slug, "changed body", 0));
    if (!conflict.is_error or !contains(conflict.text, "idempotency_conflict"))
        return ctx.fatal("conflicting payload: want idempotency_conflict; content: {s}", .{conflict.text});

    // update: the current revision advances the draft.
    const updateRes = try call(ctx, cs, "doc_put", try docPutArgs(ctx, slug, "second body", 1));
    try wantToolOK(ctx, "doc_put", updateRes);
    const updated = try ctx.decode(Document, updateRes.structured.?);
    if (updated.revision != 2 or !std.mem.eql(u8, updated.body, "second body") or
        !std.mem.eql(u8, updated.status, "draft"))
        return ctx.fatal("doc_put update = {s}, want revision 2 draft with the new body", .{scJSON(updateRes)});

    // stale revision: a wrong expectation is refused without writing.
    const stale = try call(ctx, cs, "doc_put", try docPutArgs(ctx, slug, "third body", 99));
    if (!stale.is_error or !contains(stale.text, "stale_revision"))
        return ctx.fatal("stale put: want stale_revision; content: {s}", .{stale.text});
    const getRes = try call(ctx, cs, "doc_get", try mcp.obj(ctx.arena, &.{
        .{ "kind", mcp.val("knowledge") },
        .{ "slug", mcp.val(slug) },
        .{ "scope", mcp.val("personal") },
    }));
    try wantToolOK(ctx, "doc_get", getRes);
    const current = try ctx.decode(Document, getRes.structured.?);
    if (!std.mem.eql(u8, current.body, "second body") or current.revision != 2)
        return ctx.fatal("after stale put = {s}, want the untouched revision 2 document", .{scJSON(getRes)});
    // Updating personal did not mutate the same-slug opensource document.
    const osAgain = try call(ctx, cs, "doc_get", try mcp.obj(ctx.arena, &.{
        .{ "kind", mcp.val("knowledge") },
        .{ "slug", mcp.val(slug) },
        .{ "scope", mcp.val("opensource") },
    }));
    try wantToolOK(ctx, "doc_get opensource after personal update", osAgain);
    const osAfter = try ctx.decode(Document, osAgain.structured.?);
    if (!std.mem.eql(u8, osAfter.body, "opensource body") or osAfter.revision != 1)
        return ctx.fatal("opensource sibling changed after personal update: {s}", .{scJSON(osAgain)});

    // Prohibited schema: status and kind are rejected at the protocol boundary;
    // scope and expected_revision are required so both intents are explicit.
    const schema_cases = [_]struct { name: []const u8, args: json.Value, want: []const u8 }{
        .{
            .name = "status",
            .args = try mcp.obj(ctx.arena, &.{
                .{ "slug", mcp.val("k/x.md") },
                .{ "title", mcp.val("T") },
                .{ "body", mcp.val("B") },
                .{ "scope", mcp.val("personal") },
                .{ "expected_revision", mcp.num(0) },
                .{ "status", mcp.val("verified") },
            }),
            .want = "additional properties",
        },
        .{
            .name = "kind",
            .args = try mcp.obj(ctx.arena, &.{
                .{ "slug", mcp.val("k/x.md") },
                .{ "title", mcp.val("T") },
                .{ "body", mcp.val("B") },
                .{ "scope", mcp.val("personal") },
                .{ "expected_revision", mcp.num(0) },
                .{ "kind", mcp.val("journal") },
            }),
            .want = "additional properties",
        },
        .{
            .name = "missing expected_revision",
            .args = try mcp.obj(ctx.arena, &.{
                .{ "slug", mcp.val("k/x.md") },
                .{ "title", mcp.val("T") },
                .{ "body", mcp.val("B") },
                .{ "scope", mcp.val("personal") },
            }),
            .want = "required",
        },
        .{
            .name = "missing scope",
            .args = try mcp.obj(ctx.arena, &.{
                .{ "slug", mcp.val("k/x.md") },
                .{ "title", mcp.val("T") },
                .{ "body", mcp.val("B") },
                .{ "expected_revision", mcp.num(0) },
            }),
            .want = "required",
        },
    };
    // Go runs these as t.Run subtests: a failed subtest records and the
    // parent continues, so every restriction is reported in one run.
    for (schema_cases) |tc| {
        const res = try call(ctx, cs, "doc_put", tc.args);
        if (!res.is_error) {
            ctx.err("doc_put {s}: isError=false, want rejection; content: {s}", .{ tc.name, res.text });
            continue;
        }
        if (!contains(res.text, tc.want))
            ctx.err("doc_put {s}: error text = \"{s}\", want it to contain \"{s}\"", .{ tc.name, res.text, tc.want });
    }
    const unbound = try call(ctx, cs, "doc_put", try mcp.obj(ctx.arena, &.{
        .{ "slug", mcp.val("k/outside") },
        .{ "title", mcp.val("Outside") },
        .{ "body", mcp.val("not written") },
        .{ "scope", mcp.val("outside") },
        .{ "expected_revision", mcp.num(0) },
    }));
    if (!unbound.is_error or !contains(unbound.text, "not_found"))
        return ctx.fatal("doc_put unbound scope: want not_found; content: {s}", .{unbound.text});

    // Fixed scope binding: a server bound to opensource writes only there, and
    // the personal scope cannot see the document.
    const foreign = try mcp.Client.connect(ctx, db, &.{ "--scope", "opensource" });
    defer foreign.close();
    const osRes = try call(ctx, foreign, "doc_put", try mcp.obj(ctx.arena, &.{
        .{ "slug", mcp.val("komorebi/os-draft") },
        .{ "title", mcp.val("OS draft") },
        .{ "body", mcp.val("opensource body") },
        .{ "scope", mcp.val("opensource") },
        .{ "expected_revision", mcp.num(0) },
    }));
    try wantToolOK(ctx, "doc_put", osRes);
    const foreignOSDoc = try ctx.decode(Document, osRes.structured.?);
    if (!std.mem.eql(u8, foreignOSDoc.scope, "opensource") or
        !std.mem.eql(u8, foreignOSDoc.status, "draft") or
        !std.mem.eql(u8, foreignOSDoc.kind, "knowledge"))
        return ctx.fatal("foreign doc_put = {s}, want an opensource knowledge draft", .{scJSON(osRes)});
    try ctx.wantErr(try ctx.run(db, &.{
        "doc",     "get",      "--kind", "knowledge", "--slug", "komorebi/os-draft",
        "--scope", "personal",
    }), 1, "doc", "not_found");
    const osGot = try ctx.decode(Document, try ctx.wantOK(try ctx.run(db, &.{
        "doc",     "get",        "--kind", "knowledge", "--slug", "komorebi/os-draft",
        "--scope", "opensource",
    }), "doc get"));
    if (!std.mem.eql(u8, osGot.body, "opensource body"))
        return ctx.fatal("opensource doc get = {s}, want the written body", .{harness.dump(ctx.arena, json.Value{ .string = osGot.body })});

    // Draft-only write cannot change a non-draft document.
    const seeded_cases = [_]struct { slug: []const u8, status: []const u8, body: []const u8 }{
        .{ .slug = "komorebi/verified-card", .status = "verified", .body = "verified body" },
        .{ .slug = "komorebi/superseded-card", .status = "superseded", .body = "superseded body" },
    };
    for (seeded_cases) |tc| {
        _ = try ctx.wantOK(try ctx.run(db, &.{
            "doc",     "put",   "--kind", "knowledge", "--slug",   tc.slug,
            "--title", tc.slug, "--body", tc.body,     "--status", tc.status,
        }), "doc put");
        const seeded = try ctx.decode(Document, try ctx.wantOK(try ctx.run(db, &.{
            "doc", "get", "--kind", "knowledge", "--slug", tc.slug,
        }), "doc get"));
        if (!std.mem.eql(u8, seeded.status, tc.status) or !std.mem.eql(u8, seeded.body, tc.body) or
            seeded.revision != 1)
            return ctx.fatal("seeded {s} = {s}, want {s} revision 1", .{ tc.slug, seeded.status, tc.status });
        const seedLog = try ctx.decode([]LogEntry, try ctx.wantOK(try ctx.run(db, &.{
            "doc", "log", "--slug", tc.slug,
        }), "doc log"));
        if (seedLog.len != 1)
            return ctx.fatal("seed history for {s} = {d} entries, want one created event", .{ tc.slug, seedLog.len });

        const res = try call(ctx, cs, "doc_put", try mcp.obj(ctx.arena, &.{
            .{ "slug", mcp.val(tc.slug) },
            .{ "title", mcp.val("overwritten") },
            .{ "body", mcp.val("mcp overwrite") },
            .{ "scope", mcp.val("personal") },
            .{ "expected_revision", mcp.num(seeded.revision) },
        }));
        if (!res.is_error or !contains(res.text, "invalid_transition"))
            return ctx.fatal("doc_put over {s}: want invalid_transition; content: {s}", .{ tc.slug, res.text });

        const after = try ctx.decode(Document, try ctx.wantOK(try ctx.run(db, &.{
            "doc", "get", "--kind", "knowledge", "--slug", tc.slug,
        }), "doc get"));
        if (!std.mem.eql(u8, after.status, tc.status) or !std.mem.eql(u8, after.body, tc.body) or
            after.revision != seeded.revision)
            return ctx.fatal("after refused write {s} = {s} revision {d} body \"{s}\", want unchanged {s} revision {d} body \"{s}\"", .{
                tc.slug, after.status, after.revision, after.body, tc.status, seeded.revision, tc.body,
            });
        const afterLog = try ctx.decode([]LogEntry, try ctx.wantOK(try ctx.run(db, &.{
            "doc", "log", "--slug", tc.slug,
        }), "doc log"));
        if (afterLog.len != 1)
            return ctx.fatal("history for {s} after refused write = {d} entries, want still one created event", .{ tc.slug, afterLog.len });
    }

    // Two-step capture flow: a failed draft write leaves the capture pending,
    // a successful write alone still leaves it pending (atomicity is deferred),
    // and only reference processing after the write marks it processed.
    const capRes = try call(ctx, cs, "capture", try mcp.obj(ctx.arena, &.{
        .{ "idempotency_key", mcp.val("mcp-docput-capture") },
        .{ "text", mcp.val("lesson: doc_put before reference") },
    }));
    const lesson = try scCapture(ctx, "capture", capRes);
    if (!std.mem.eql(u8, lesson.scope, "personal"))
        return ctx.fatal("lesson capture scope = \"{s}\", want personal for cross-scope reference test", .{lesson.scope});
    const failedWrite = try call(ctx, cs, "doc_put", try mcp.obj(ctx.arena, &.{
        .{ "slug", mcp.val("komorebi/lesson") },
        .{ "title", mcp.val("Lesson") },
        .{ "body", mcp.val("body") },
        .{ "scope", mcp.val("opensource") },
        .{ "expected_revision", mcp.num(7) },
    }));
    if (!failedWrite.is_error or !contains(failedWrite.text, "stale_revision"))
        return ctx.fatal("failed write: want stale_revision; content: {s}", .{failedWrite.text});
    const pendingRes = try call(ctx, cs, "read", try mcp.obj(ctx.arena, &.{
        .{ "ids", try mcp.arr(ctx.arena, &.{mcp.val(lesson.id)}) },
    }));
    try wantToolOK(ctx, "read", pendingRes);
    const afterFail = try ctx.decode(struct { captures: []Capture = &.{} }, pendingRes.structured.?);
    if (afterFail.captures.len != 1 or !std.mem.eql(u8, afterFail.captures[0].processing_state, "pending"))
        return ctx.fatal("capture after failed write = {s}, want pending", .{scJSON(pendingRes)});
    const okWrite = try call(ctx, cs, "doc_put", try mcp.obj(ctx.arena, &.{
        .{ "slug", mcp.val("komorebi/lesson") },
        .{ "title", mcp.val("Lesson") },
        .{ "body", mcp.val("body") },
        .{ "scope", mcp.val("opensource") },
        .{ "expected_revision", mcp.num(0) },
    }));
    try wantToolOK(ctx, "doc_put", okWrite);
    const lessonDoc = try ctx.decode(Document, okWrite.structured.?);
    if (lessonDoc.id.len == 0 or !std.mem.eql(u8, lessonDoc.scope, "opensource"))
        return ctx.fatal("doc_put returned {s}, want a document ID in opensource: {s}", .{ scJSON(okWrite), scJSON(okWrite) });
    const noPersonalLesson = try call(ctx, cs, "doc_get", try mcp.obj(ctx.arena, &.{
        .{ "kind", mcp.val("knowledge") },
        .{ "slug", mcp.val("komorebi/lesson") },
        .{ "scope", mcp.val("personal") },
    }));
    if (!noPersonalLesson.is_error or !contains(noPersonalLesson.text, "not_found"))
        return ctx.fatal("personal lesson lookup = \"{s}\", want not_found", .{noPersonalLesson.text});
    const stillPending = try call(ctx, cs, "read", try mcp.obj(ctx.arena, &.{
        .{ "ids", try mcp.arr(ctx.arena, &.{mcp.val(lesson.id)}) },
    }));
    try wantToolOK(ctx, "read", stillPending);
    const afterWrite = try ctx.decode(struct { captures: []Capture = &.{} }, stillPending.structured.?);
    if (afterWrite.captures.len != 1 or !std.mem.eql(u8, afterWrite.captures[0].processing_state, "pending"))
        return ctx.fatal("capture after successful write = {s}, want pending until reference", .{scJSON(stillPending)});
    const refRes = try call(ctx, cs, "process_capture", try mcp.obj(ctx.arena, &.{
        .{ "idempotency_key", mcp.val("mcp-docput-reference") },
        .{ "capture_id", mcp.val(lesson.id) },
        .{ "outcome", mcp.val("reference") },
        .{ "reason", mcp.val(lessonDoc.id) },
    }));
    const pr = try scDecode(ctx, ProcessData, "process_capture", refRes);
    if (!std.mem.eql(u8, pr.capture.id, lesson.id) or !std.mem.eql(u8, pr.capture.processing_state, "processed"))
        return ctx.fatal("reference processing = {s}, want {s} processed", .{ scJSON(refRes), lesson.id });
    if (pr.work_items.len != 0)
        return ctx.fatal("reference outcome created {d} work items, want 0", .{pr.work_items.len});
    // The reference must retain the written document's ID in its reason.
    const Outcome = struct { kind: []const u8 = "", reason: []const u8 = "" };
    const refEnv = try ctx.decode(struct {
        capture: struct {
            id: []const u8 = "",
            processing_outcome: ?Outcome = null,
        } = .{},
    }, refRes.structured.?);
    const outcome = refEnv.capture.processing_outcome orelse
        return ctx.fatal("process_capture response exposes no processing_outcome: {s}", .{scJSON(refRes)});
    if (!std.mem.eql(u8, outcome.kind, "reference") or !contains(outcome.reason, lessonDoc.id))
        return ctx.fatal("reference outcome = kind \"{s}\" reason \"{s}\", want kind reference with reason carrying {s}", .{
            outcome.kind, outcome.reason, lessonDoc.id,
        });
}
