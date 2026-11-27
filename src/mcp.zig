//! MCP JSON-RPC 2.0 server over stdio.
//!
//! The tool and prompt catalogs are the Go SDK's own serialized `tools/list`
//! and `prompts/list` payloads, embedded verbatim so the host sees exactly the
//! same schemas and descriptions. Tool results are re-serialized with sorted
//! object keys, which is what the Go SDK's map-based structuredContent emits.

const std = @import("std");
const Io = std.Io;
const jsonw = @import("json.zig");
const domain = @import("domain.zig");
const core = @import("store/core.zig");
const store_mod = @import("store/store.zig");
const errors = @import("errors.zig");
const timeutil = @import("timeutil.zig");
const version = @import("version.zig").version;

const Store = store_mod.Store;

const tools_default = @embedFile("mcp_assets/tools.json");
const tools_delete = @embedFile("mcp_assets/tools_delete.json");
const prompts_json = @embedFile("mcp_assets/prompts.json");
const prompt_texts = @embedFile("mcp_assets/prompt_texts.json");

const trace_cap = 1024;
const max_doc_put_bytes = 512 << 10;

pub fn serve(arena: std.mem.Allocator, io: Io, w: *Io.Writer, st: *Store, b: domain.Binding, allow_delete: bool) !void {
    var in_buf: [1 << 20]u8 = undefined;
    var in: Io.File.Reader = .init(.stdin(), io, &in_buf);
    while (true) {
        // takeDelimiterExclusive is broken in 0.17.0; trim inclusive instead.
        const raw = in.interface.takeDelimiterInclusive('\n') catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        const parsed = std.json.parseFromSlice(std.json.Value, arena, line, .{}) catch continue;
        const msg = switch (parsed.value) {
            .object => |o| o,
            else => continue,
        };
        const method = blk: {
            const m = msg.get("method") orelse break :blk "";
            break :blk switch (m) {
                .string => |s| s,
                else => "",
            };
        };
        const id = msg.get("id");
        const params: ?std.json.Value = msg.get("params");
        if (std.mem.startsWith(u8, method, "notifications/")) continue;

        if (std.mem.eql(u8, method, "initialize")) {
            var requested: []const u8 = "2025-06-18";
            if (params) |p| if (p == .object) {
                if (p.object.get("protocolVersion")) |v| if (v == .string) {
                    requested = v.string;
                };
            };
            try header(w, id);
            try w.writeAll(",\"result\":{\"capabilities\":{\"logging\":{},\"prompts\":{\"listChanged\":true},\"tools\":{\"listChanged\":true}},\"protocolVersion\":");
            try jsonw.writeString(w, requested);
            try w.writeAll(",\"serverInfo\":{\"name\":\"ztd\",\"version\":");
            try jsonw.writeString(w, version);
            try w.writeAll("}}}\n");
            try w.flush();
        } else if (std.mem.eql(u8, method, "ping")) {
            try header(w, id);
            try w.writeAll(",\"result\":{}}\n");
            try w.flush();
        } else if (std.mem.eql(u8, method, "tools/list")) {
            try header(w, id);
            try w.writeAll(",\"result\":");
            try w.writeAll(if (allow_delete) tools_delete else tools_default);
            try w.writeAll("}\n");
            try w.flush();
        } else if (std.mem.eql(u8, method, "prompts/list")) {
            try header(w, id);
            try w.writeAll(",\"result\":");
            try w.writeAll(prompts_json);
            try w.writeAll("}\n");
            try w.flush();
        } else if (std.mem.eql(u8, method, "prompts/get")) {
            const name = blk: {
                const p = params orelse break :blk "";
                if (p != .object) break :blk "";
                const nv = p.object.get("name") orelse break :blk "";
                break :blk switch (nv) {
                    .string => |s| s,
                    else => "",
                };
            };
            const texts = std.json.parseFromSlice(std.json.Value, arena, prompt_texts, .{}) catch
                return sendError(w, id, -32603, "prompt catalog is not available");
            const found = switch (texts.value) {
                .object => |o| o.get(name),
                else => null,
            };
            if (found) |v| {
                try header(w, id);
                try w.writeAll(",\"result\":");
                try writeSorted(w, v);
                try w.writeAll("}\n");
                try w.flush();
            } else {
                const msg2 = try std.fmt.allocPrint(arena, "unknown prompt \"{s}\"", .{name});
                try sendError(w, id, -32602, msg2);
            }
        } else if (std.mem.eql(u8, method, "tools/call")) {
            const p = params orelse {
                try sendError(w, id, -32602, "missing params");
                continue;
            };
            if (p != .object) {
                try sendError(w, id, -32602, "invalid params");
                continue;
            }
            const name = blk: {
                const nv = p.object.get("name") orelse break :blk "";
                break :blk switch (nv) {
                    .string => |s| s,
                    else => "",
                };
            };
            const args = p.object.get("arguments");
            const payload = callTool(arena, io, st, b, allow_delete, name, args) catch |err| {
                if (err == error.Ztd) {
                    const msg2 = try std.fmt.allocPrint(arena, "{s}: {s}", .{ errors.getFamily().text(), errors.detail() });
                    try errorReply(w, id, msg2);
                } else {
                    const msg2 = try std.fmt.allocPrint(arena, "io_error: {s}", .{@errorName(err)});
                    try errorReply(w, id, msg2);
                }
                continue;
            };
            const sorted = try sortBytes(arena, payload);
            try resultReply(w, id, sorted);
        } else {
            try sendError(w, id, -32601, "Method not found");
        }
    }
}

/// Re-serializes a result payload with sorted object keys, as the Go SDK's
/// map-based structuredContent does.
fn sortBytes(a: std.mem.Allocator, raw: []const u8) ![]const u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, a, raw, .{}) catch return raw;
    var aw = Io.Writer.Allocating.init(a);
    try writeSorted(&aw.writer, parsed.value);
    return aw.written();
}

fn header(w: *Io.Writer, id: ?std.json.Value) !void {
    try w.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
    if (id) |v| try writeSorted(w, v) else try w.writeAll("null");
}

fn resultReply(w: *Io.Writer, id: ?std.json.Value, data: []const u8) !void {
    try header(w, id);
    try w.writeAll(",\"result\":{\"content\":[{\"type\":\"text\",\"text\":");
    try jsonw.writeString(w, data);
    try w.writeAll("}],\"structuredContent\":");
    try w.writeAll(data);
    try w.writeAll("}}\n");
    try w.flush();
}

fn errorReply(w: *Io.Writer, id: ?std.json.Value, text: []const u8) !void {
    try header(w, id);
    try w.writeAll(",\"result\":{\"content\":[{\"type\":\"text\",\"text\":");
    try jsonw.writeString(w, text);
    try w.writeAll("}],\"isError\":true}}\n");
    try w.flush();
}

fn sendError(w: *Io.Writer, id: ?std.json.Value, code: i64, message: []const u8) !void {
    try header(w, id);
    try w.writeAll(",\"error\":{\"code\":");
    try w.print("{d}", .{code});
    try w.writeAll(",\"message\":");
    try jsonw.writeString(w, message);
    try w.writeAll("}}\n");
    try w.flush();
}

/// Compact JSON with object keys sorted, matching Go's map marshaling.
fn writeSorted(w: *Io.Writer, v: std.json.Value) !void {
    switch (v) {
        .null => try w.writeAll("null"),
        .bool => |b| try w.writeAll(if (b) "true" else "false"),
        .integer => |n| try w.print("{d}", .{n}),
        .float => |f| try jsonw.writeFloat(w, f),
        .number_string => |s| try w.writeAll(s),
        .string => |s| try jsonw.writeString(w, s),
        .array => |arr| {
            try w.writeByte('[');
            for (arr.items, 0..) |item, i| {
                if (i > 0) try w.writeByte(',');
                try writeSorted(w, item);
            }
            try w.writeByte(']');
        },
        .object => |o| {
            try w.writeByte('{');
            const keys = o.keys();
            const sorted = try std.heap.page_allocator.dupe([]const u8, keys);
            defer std.heap.page_allocator.free(sorted);
            std.mem.sort([]const u8, sorted, {}, lessKey);
            for (sorted, 0..) |k, i| {
                if (i > 0) try w.writeByte(',');
                try jsonw.writeString(w, k);
                try w.writeByte(':');
                try writeSorted(w, o.get(k).?);
            }
            try w.writeByte('}');
        },
    }
}

fn lessKey(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

// ---------------------------------------------------------------- arguments

fn optArg(a: std.mem.Allocator, args: ?std.json.Value, name: []const u8) !?[]const u8 {
    const v = argStr(args, name);
    if (v.len == 0) return null;
    return try core.dup(a, v);
}

fn argStr(args: ?std.json.Value, name: []const u8) []const u8 {
    const a = args orelse return "";
    return jsonw.strField(a, name) orelse "";
}

fn argOpt(args: ?std.json.Value, name: []const u8) ?[]const u8 {
    const a = args orelse return null;
    return jsonw.strField(a, name);
}

fn argInt(args: ?std.json.Value, name: []const u8) i64 {
    const a = args orelse return 0;
    return jsonw.intField(a, name) orelse 0;
}

fn argOptBool(args: ?std.json.Value, name: []const u8) ?bool {
    const a = args orelse return null;
    return jsonw.boolField(a, name);
}

fn argArr(args: ?std.json.Value, name: []const u8) ?[]std.json.Value {
    const a = args orelse return null;
    return jsonw.arrField(a, name);
}

fn parseRetrieval(a: std.mem.Allocator, v: ?std.json.Value) !domain.SourceRetrieval {
    const none = domain.SourceRetrieval{};
    const val = v orelse return none;
    if (val != .object) return none;
    var out = none;
    out.window = try core.dup(a, argStr(val, "window"));
    out.cursor = try core.dup(a, argStr(val, "cursor"));
    out.requested_limit = argInt(val, "requested_limit");
    out.provider_returned_limit = argInt(val, "provider_returned_limit");
    out.complete_window = argOptBool(val, "complete_window") orelse false;
    out.truncated = argOptBool(val, "truncated") orelse false;
    if (argArr(val, "failures")) |items| {
        const list = try a.alloc([]const u8, items.len);
        for (items, 0..) |item, i| {
            list[i] = switch (item) {
                .string => |s| try core.dup(a, s),
                else => "",
            };
        }
        out.failures = list;
    }
    return out;
}

fn parseItems(a: std.mem.Allocator, v: ?std.json.Value) ![]const domain.SourceItem {
    const items = argArr(v, "items") orelse return &.{};
    const out = try a.alloc(domain.SourceItem, items.len);
    for (items, 0..) |item, i| {
        out[i] = .{
            .external_id = try core.dup(a, argStr(item, "external_id")),
            .external_revision = try core.dup(a, argStr(item, "external_revision")),
            .original_text = try core.dup(a, argStr(item, "original_text")),
            .source_uri = try core.dupOpt(a, argOpt(item, "source_uri")),
            .occurred_at = try core.dupOpt(a, argOpt(item, "occurred_at")),
            .provider_metadata_summary = try core.dupOpt(a, argOpt(item, "provider_metadata_summary")),
        };
    }
    return out;
}

// ------------------------------------------------------------------- tools

fn callTool(
    arena: std.mem.Allocator,
    io: Io,
    st: *Store,
    b: domain.Binding,
    allow_delete: bool,
    name: []const u8,
    args: ?std.json.Value,
) ![]const u8 {
    const now = timeutil.now(io);
    if (std.mem.eql(u8, name, "capture")) return try toolCapture(arena, st, b, args, now);
    if (std.mem.eql(u8, name, "inbox_next")) return try toolInboxNext(arena, st, b, now);
    if (std.mem.eql(u8, name, "process_capture")) return try toolProcess(arena, st, b, args, now);
    if (std.mem.eql(u8, name, "prepare")) return try toolPrepare(arena, st, b, args, now);
    if (std.mem.eql(u8, name, "commit_plan")) return try toolCommitPlan(arena, st, b, args, now);
    if (std.mem.eql(u8, name, "focus_start")) return try toolFocusStart(arena, st, b, args, now);
    if (std.mem.eql(u8, name, "checkpoint")) return try toolCheckpoint(arena, st, b, args, now);
    if (std.mem.eql(u8, name, "focus_finish")) return try toolFocusFinish(arena, st, b, args, now);
    if (std.mem.eql(u8, name, "record_review")) return try toolReview(arena, st, b, args, now);
    if (std.mem.eql(u8, name, "sources")) return try toolSources(arena, st, b);
    if (std.mem.eql(u8, name, "record_source_review")) return try toolSourceReview(arena, st, b, args, now);
    if (std.mem.eql(u8, name, "find")) return try toolFind(arena, st, b, args);
    if (std.mem.eql(u8, name, "read")) return try toolRead(arena, st, b, args);
    if (std.mem.eql(u8, name, "doc_search")) return try toolDocSearch(arena, st, b, args);
    if (std.mem.eql(u8, name, "doc_get")) return try toolDocGet(arena, st, b, args);
    if (std.mem.eql(u8, name, "doc_related")) return try toolDocRelated(arena, st, b, args);
    if (std.mem.eql(u8, name, "doc_put")) return try toolDocPut(arena, st, b, args, now);
    if (std.mem.eql(u8, name, "trace")) return try toolTrace(arena, st, args);
    if (allow_delete and std.mem.eql(u8, name, "delete_source")) return try toolDeleteSource(arena, st, b, args, now);
    return errors.invalid("unknown tool \"{s}\"", .{name});
}

fn toolCapture(a: std.mem.Allocator, st: *Store, b: domain.Binding, args: ?std.json.Value, now: timeutil.Timestamp) ![]const u8 {
    const source = argStr(args, "source_id");
    const cap = core.capture(st, a, .{
        .binding = b,
        .key = try core.dup(a, argStr(args, "idempotency_key")),
        .text = try core.dup(a, argStr(args, "text")),
        .source_id = try core.dup(a, source),
    }, now) catch |err| {
        // A missing source answers the same not_found as an out-of-scope one.
        if (source.len > 0 and err == error.Ztd) {
            const fam = errors.getFamily();
            if (fam == .not_found or fam == .scope_denied) return errors.fail(.not_found, "not found", .{});
        }
        return err;
    };
    var aw = Io.Writer.Allocating.init(a);
    var o = try jsonw.Obj.init(&aw.writer);
    try cap.write(&o);
    try o.end();
    return aw.written();
}

fn toolInboxNext(a: std.mem.Allocator, st: *Store, b: domain.Binding, now: timeutil.Timestamp) ![]const u8 {
    const cap = try core.inboxNext(st, a, b, now);
    const stats = try core.inboxStats(st, a, b, now);
    var aw = Io.Writer.Allocating.init(a);
    var o = try jsonw.Obj.init(&aw.writer);
    var c = try o.obj("capture");
    try cap.write(&c);
    try c.end();
    var s = try o.obj("stats");
    try s.int("pending", stats.pending);
    try s.int("due", stats.due);
    try s.int("remaining", stats.remaining);
    try s.end();
    try o.end();
    if (aw.written().len <= core.inbox_cap) return aw.written();
    // Over the byte cap: excerpt plus an explicit truncation marker.
    var aw2 = Io.Writer.Allocating.init(a);
    var o2 = try jsonw.Obj.init(&aw2.writer);
    var c2 = try o2.obj("capture");
    const short = try core.clipCapture(a, cap, core.inbox_excerpt);
    try short.write(&c2);
    try c2.end();
    var s2 = try o2.obj("stats");
    try s2.int("pending", stats.pending);
    try s2.int("due", stats.due);
    try s2.int("remaining", stats.remaining);
    try s2.end();
    try o2.boolean("truncated", true);
    try o2.end();
    return aw2.written();
}

fn toolProcess(a: std.mem.Allocator, st: *Store, b: domain.Binding, args: ?std.json.Value, now: timeutil.Timestamp) ![]const u8 {
    var outcome = domain.Outcome{ .kind = try core.dup(a, argStr(args, "outcome")) };
    if (argArr(args, "titles")) |titles| {
        const list = try a.alloc([]const u8, titles.len);
        for (titles, 0..) |t, i| list[i] = switch (t) {
            .string => |s| try core.dup(a, s),
            else => "",
        };
        outcome.titles = list;
    }
    outcome.project_id = try optArg(a, args, "project_id");
    outcome.area_id = try optArg(a, args, "area_id");
    outcome.context_id = try optArg(a, args, "context_id");
    outcome.waiting_on = (try optArg(a, args, "waiting_on")) orelse "";
    outcome.reason = (try optArg(a, args, "reason")) orelse "";
    outcome.result_evidence = (try optArg(a, args, "result_evidence")) orelse "";
    if (argStr(args, "review_after").len > 0) {
        const t = timeutil.parseDate(argStr(args, "review_after")) catch
            return errors.invalid("review_after must be YYYY-MM-DD", .{});
        outcome.review_after = try core.fmtTs(a, t);
    }
    const res = try core.process(st, a, .{
        .binding = b,
        .key = try core.dup(a, argStr(args, "idempotency_key")),
        .id = try core.dup(a, argStr(args, "capture_id")),
        .expected = argInt(args, "expected_revision"),
        .outcome = outcome,
    }, (try optArg(a, args, "decision")) orelse "", now);
    var aw = Io.Writer.Allocating.init(a);
    var o = try jsonw.Obj.init(&aw.writer);
    var c = try o.obj("capture");
    try res.capture.write(&c);
    try c.end();
    if (res.work_items.len > 0) {
        var arr = try o.arr("work_items");
        for (res.work_items) |item| {
            var io_item = try arr.obj();
            try item.write(&io_item);
            try io_item.end();
        }
        try arr.end();
    }
    try o.end();
    return aw.written();
}

fn toolPrepare(a: std.mem.Allocator, st: *Store, b: domain.Binding, args: ?std.json.Value, now: timeutil.Timestamp) ![]const u8 {
    if (argOptBool(args, "packet") orelse false) {
        return core.preparePacket(st, a, b, try core.dup(a, argStr(args, "date")), now);
    }
    const brief = try core.prepare(st, a, b, try core.dup(a, argStr(args, "date")), now);
    var aw = Io.Writer.Allocating.init(a);
    var o = try jsonw.Obj.init(&aw.writer);
    try brief.write(&o);
    try o.end();
    return aw.written();
}

fn toolCommitPlan(a: std.mem.Allocator, st: *Store, b: domain.Binding, args: ?std.json.Value, now: timeutil.Timestamp) ![]const u8 {
    var items: []const core.PlanItemCmd = &.{};
    if (argArr(args, "items")) |raw| {
        const list = try a.alloc(core.PlanItemCmd, raw.len);
        for (raw, 0..) |it, i| {
            list[i] = .{
                .work_item_id = try core.dup(a, argStr(it, "work_item_id")),
                .role = try core.dup(a, argStr(it, "role")),
                .position = @intCast(i),
            };
        }
        items = list;
    }
    const plan = try core.commitPlan(st, a, .{
        .binding = b,
        .key = try core.dup(a, argStr(args, "idempotency_key")),
        .kind = try core.dup(a, argStr(args, "kind")),
        .period = try core.dup(a, argStr(args, "period")),
        .expected = argInt(args, "expected_revision"),
        .override_id = try core.dup(a, argStr(args, "override_id")),
        .items = items,
    }, (try optArg(a, args, "decision")) orelse "", now);
    var aw = Io.Writer.Allocating.init(a);
    var o = try jsonw.Obj.init(&aw.writer);
    try plan.write(&o);
    try o.end();
    return aw.written();
}

fn toolFocusStart(a: std.mem.Allocator, st: *Store, b: domain.Binding, args: ?std.json.Value, now: timeutil.Timestamp) ![]const u8 {
    const res = try core.startFocus(st, a, .{
        .binding = b,
        .key = try core.dup(a, argStr(args, "idempotency_key")),
        .item = try core.dup(a, argStr(args, "work_item_id")),
    }, now);
    var aw = Io.Writer.Allocating.init(a);
    var o = try jsonw.Obj.init(&aw.writer);
    var f = try o.obj("focus");
    try res.focus.write(&f);
    try f.end();
    if (res.checkpoints.len > 0) {
        var arr = try o.arr("checkpoints");
        for (res.checkpoints) |cp| {
            var item = try arr.obj();
            try cp.write(&item);
            try item.end();
        }
        try arr.end();
    }
    try o.end();
    return aw.written();
}

fn toolCheckpoint(a: std.mem.Allocator, st: *Store, b: domain.Binding, args: ?std.json.Value, now: timeutil.Timestamp) ![]const u8 {
    var evidence: []const []const u8 = &.{};
    if (argArr(args, "evidence")) |raw| {
        const list = try a.alloc([]const u8, raw.len);
        for (raw, 0..) |item, i| list[i] = switch (item) {
            .string => |s| try core.dup(a, s),
            else => "",
        };
        evidence = list;
    }
    const cp = try core.recordCheckpoint(st, a, .{
        .binding = b,
        .key = try core.dup(a, argStr(args, "idempotency_key")),
        .item = try core.dup(a, argStr(args, "work_item_id")),
        .result = try core.dup(a, argStr(args, "result")),
        .evidence = evidence,
        .uncertain = try core.dup(a, argStr(args, "uncertainties")),
        .next_action = try core.dup(a, argStr(args, "next_action")),
    }, now);
    var aw = Io.Writer.Allocating.init(a);
    var o = try jsonw.Obj.init(&aw.writer);
    try cp.write(&o);
    try o.end();
    return aw.written();
}

fn toolFocusFinish(a: std.mem.Allocator, st: *Store, b: domain.Binding, args: ?std.json.Value, now: timeutil.Timestamp) ![]const u8 {
    const f = try core.finishFocus(st, a, .{
        .binding = b,
        .key = try core.dup(a, argStr(args, "idempotency_key")),
        .focus = try core.dup(a, argStr(args, "focus_id")),
        .outcome = try core.dup(a, argStr(args, "outcome")),
    }, now);
    var aw = Io.Writer.Allocating.init(a);
    var o = try jsonw.Obj.init(&aw.writer);
    try f.write(&o);
    try o.end();
    return aw.written();
}

fn toolReview(a: std.mem.Allocator, st: *Store, b: domain.Binding, args: ?std.json.Value, now: timeutil.Timestamp) ![]const u8 {
    const r = try core.recordReview(st, a, .{
        .binding = b,
        .key = try core.dup(a, argStr(args, "idempotency_key")),
        .kind = try core.dup(a, argStr(args, "kind")),
        .period = try core.dup(a, argStr(args, "period")),
        .outcomes = try core.dup(a, argStr(args, "outcomes")),
        .coverage = try core.dup(a, argStr(args, "coverage")),
        .complete = argOptBool(args, "complete") orelse true,
    }, argOptBool(args, "derive") orelse false, "", now);
    var aw = Io.Writer.Allocating.init(a);
    var o = try jsonw.Obj.init(&aw.writer);
    try r.write(&o);
    try o.end();
    return aw.written();
}

fn toolSources(a: std.mem.Allocator, st: *Store, b: domain.Binding) ![]const u8 {
    const sources = try core.listSources(st, a, b);
    var aw = Io.Writer.Allocating.init(a);
    var o = try jsonw.Obj.init(&aw.writer);
    var arr = try o.arr("sources");
    for (sources) |src| {
        var item = try arr.obj();
        try src.write(&item);
        try item.end();
    }
    try arr.end();
    try o.end();
    return aw.written();
}

fn toolSourceReview(a: std.mem.Allocator, st: *Store, b: domain.Binding, args: ?std.json.Value, now: timeutil.Timestamp) ![]const u8 {
    var kind = try core.dup(a, argStr(args, "result_kind"));
    if (kind.len == 0) kind = "reported";
    if (!std.mem.eql(u8, kind, "reported")) {
        return errors.invalid("observed coverage requires a trusted host adapter; only reported is accepted here", .{});
    }
    const res = try core.recordSourceReview(st, a, .{
        .binding = b,
        .source_id = try core.dup(a, argStr(args, "source_id")),
        .batch_id = try core.dup(a, argStr(args, "batch_id")),
        .key = try core.dup(a, argStr(args, "idempotency_key")),
        .result_kind = kind,
        .retrieval = try parseRetrieval(a, args),
        .items = try parseItems(a, args),
    }, now);
    var full_aw = Io.Writer.Allocating.init(a);
    try renderSourceReview(&full_aw.writer, res, res.captures.len);
    if (full_aw.written().len <= core.source_review_cap) return full_aw.written();
    var shown = @min(core.compact_capture_ids, res.captures.len);
    while (true) {
        var aw = Io.Writer.Allocating.init(a);
        try renderSourceReview(&aw.writer, res, shown);
        if (aw.written().len <= core.source_review_cap or shown == 0) return aw.written();
        shown -= 1;
    }
}

/// The MCP shape orders `review` before `captures`. `shown` is the exact count.
fn renderSourceReview(w: *Io.Writer, res: core.SourceReviewResult, shown: usize) !void {
    var o = try jsonw.Obj.init(w);
    var r = try o.obj("review");
    var view = res.review;
    if (shown < res.captures.len) {
        if (res.review.capture_ids) |ids| {
            if (ids.len > shown) {
                view.capture_ids = ids[0..shown];
                view.omitted = ids.len - shown;
            }
        }
    }
    try view.write(&r);
    try r.end();
    var arr = try o.arr("captures");
    for (res.captures[0..shown]) |cap| {
        var item = try arr.obj();
        try cap.write(&item);
        try item.end();
    }
    try arr.end();
    try o.end();
}

fn toolFind(a: std.mem.Allocator, st: *Store, b: domain.Binding, args: ?std.json.Value) ![]const u8 {
    var limit = argInt(args, "limit");
    if (limit <= 0) limit = 8;
    if (limit > 20) limit = 20;
    const items = try core.find(st, a, b, try core.dup(a, argStr(args, "query")), limit);
    var aw = Io.Writer.Allocating.init(a);
    var o = try jsonw.Obj.init(&aw.writer);
    if (items.len == 0) {
        try o.raw("items", "null");
    } else {
        var arr = try o.arr("items");
        for (items) |item| {
            var w = try arr.obj();
            try item.write(&w);
            try w.end();
        }
        try arr.end();
    }
    try o.end();
    return aw.written();
}

fn toolRead(a: std.mem.Allocator, st: *Store, b: domain.Binding, args: ?std.json.Value) ![]const u8 {
    const ids = argArr(args, "ids") orelse {
        return errors.invalid("ids is required", .{});
    };
    if (ids.len == 0) return errors.invalid("ids is required", .{});
    if (ids.len > 5) return errors.invalid("at most 5 ids", .{});

    var aw = Io.Writer.Allocating.init(a);
    var o = try jsonw.Obj.init(&aw.writer);
    var captures: std.ArrayList(domain.Capture) = .empty;
    var work_items: std.ArrayList(domain.WorkItem) = .empty;
    var checkpoints = std.StringHashMap(?domain.Checkpoint).init(a);
    for (ids) |idv| {
        const id = switch (idv) {
            .string => |s| s,
            else => "",
        };
        if (std.mem.startsWith(u8, id, "C-")) {
            const cap = core.getCapture(st, a, b, id) catch |err| {
                if (err == error.Ztd) return readError(err);
                return err;
            };
            try captures.append(a, cap);
        } else if (std.mem.startsWith(u8, id, "T-")) {
            const pair = core.getWorkItemWithCheckpoint(st, a, b, id) catch |err| {
                if (err == error.Ztd) return readError(err);
                return err;
            };
            try work_items.append(a, pair.item);
            try checkpoints.put(try core.dup(a, id), pair.checkpoint);
        } else {
            return errors.invalid("unknown id \"{s}\"", .{id});
        }
    }
    if (captures.items.len > 0) {
        var arr = try o.arr("captures");
        for (captures.items) |cap| {
            var item = try arr.obj();
            try cap.write(&item);
            try item.end();
        }
        try arr.end();
    }
    if (work_items.items.len > 0) {
        var arr = try o.arr("work_items");
        for (work_items.items) |wi| {
            var item = try arr.obj();
            try wi.write(&item);
            try item.end();
        }
        try arr.end();
    }
    if (checkpoints.count() > 0) {
        var map_obj = try o.obj("checkpoints");
        var it = checkpoints.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.*) |cp| {
                var item = try map_obj.obj(entry.key_ptr.*);
                try cp.write(&item);
                try item.end();
            } else {
                try map_obj.raw(entry.key_ptr.*, "null");
            }
        }
        try map_obj.end();
    }
    try o.end();
    return aw.written();
}

fn readError(err: anyerror) anyerror {
    if (err != error.Ztd) return err;
    const fam = errors.getFamily();
    if (fam == .not_found or fam == .scope_denied) return errors.fail(.not_found, "not found", .{});
    return err;
}

fn toolDocSearch(a: std.mem.Allocator, st: *Store, b: domain.Binding, args: ?std.json.Value) ![]const u8 {
    const hits = try core.searchDocumentsBy(
        st,
        a,
        b,
        try core.dup(a, argStr(args, "query")),
        try core.dup(a, argStr(args, "kind")),
        (try optArg(a, args, "record_kind")) orelse "",
        argInt(args, "limit"),
    );
    var shown = hits.len;
    while (true) {
        var aw = Io.Writer.Allocating.init(a);
        var o = try jsonw.Obj.init(&aw.writer);
        var arr = try o.arr("hits");
        for (hits[0..shown]) |h| {
            var item = try arr.obj();
            var d = try item.obj("document");
            try h.document.write(&d);
            try d.end();
            try item.float("rank", h.rank);
            try item.str("snippet", h.snippet);
            try item.end();
        }
        try arr.end();
        if (shown < hits.len) {
            try o.boolean("truncated", true);
            try o.int("omitted", @intCast(hits.len - shown));
        }
        try o.end();
        if (aw.written().len <= core.doc_search_cap or shown <= 1) return aw.written();
        shown -= 1;
    }
}

fn docScope(args: ?std.json.Value) ![]const u8 {
    const scope = argOpt(args, "scope") orelse return "";
    if (std.mem.trim(u8, scope, " \t\n\r\x0b\x0c").len == 0) {
        return errors.invalid("scope must not be blank", .{});
    }
    return scope;
}

fn toolDocGet(a: std.mem.Allocator, st: *Store, b: domain.Binding, args: ?std.json.Value) ![]const u8 {
    const d = try core.getDocument(st, a, b, try core.dup(a, argStr(args, "kind")), try core.dup(a, argStr(args, "slug")), try docScope(args));
    var aw = Io.Writer.Allocating.init(a);
    var o = try jsonw.Obj.init(&aw.writer);
    try d.write(&o);
    try o.end();
    return aw.written();
}

fn toolDocRelated(a: std.mem.Allocator, st: *Store, b: domain.Binding, args: ?std.json.Value) ![]const u8 {
    const source = try core.getDocument(st, a, b, try core.dup(a, argStr(args, "kind")), try core.dup(a, argStr(args, "slug")), try docScope(args));
    const all = try core.listDocuments(st, a, b, "");
    const doc = @import("docs.zig");
    const rel = try doc.relatedDocuments(a, all, source);
    var aw = Io.Writer.Allocating.init(a);
    var o = try jsonw.Obj.init(&aw.writer);
    try doc.writeRelations(&o, rel);
    try o.end();
    return aw.written();
}

/// `options` may arrive as a JSON array (schema) or as a pre-encoded string.
fn optionsArg(a: std.mem.Allocator, args: ?std.json.Value) ![]const u8 {
    const v = jsonw.field(args orelse return "", "options") orelse return "";
    return switch (v) {
        .null => "",
        .string => |str| try core.dup(a, str),
        else => blk: {
            var aw = Io.Writer.Allocating.init(a);
            try jsonw.writeValue(a, &aw.writer, v);
            break :blk aw.written();
        },
    };
}

fn toolTrace(a: std.mem.Allocator, st: *Store, args: ?std.json.Value) ![]const u8 {
    const id = argStr(args, "id");
    const t = try core.traceEntity(st, a, id);
    var edges = t.edges;
    var omitted: i64 = 0;
    var data = try renderTrace(a, t, edges, omitted);
    while (data.len > trace_cap and edges.len > 0) {
        edges = edges[0 .. edges.len - 1];
        omitted += 1;
        data = try renderTrace(a, t, edges, omitted);
    }
    return data;
}

fn renderTrace(a: std.mem.Allocator, t: core.TraceResult, edges: []const core.TraceEdge, omitted: i64) ![]const u8 {
    var aw = Io.Writer.Allocating.init(a);
    var o = try jsonw.Obj.init(&aw.writer);
    try o.str("id", t.id);
    try o.str("kind", t.kind);
    if (t.label.len > 0) try o.str("label", t.label);
    var arr = try o.arr("edges");
    for (edges) |e| {
        var item = try arr.obj();
        try item.str("relation", e.relation);
        try item.str("from_type", e.from_type);
        try item.str("from_id", e.from_id);
        try item.str("to_type", e.to_type);
        try item.str("to_id", e.to_id);
        try item.end();
    }
    try arr.end();
    if (omitted > 0) {
        try o.int("omitted", omitted);
        try o.boolean("truncated", true);
    }
    try o.end();
    return aw.written();
}

fn toolDocPut(a: std.mem.Allocator, st: *Store, b: domain.Binding, args: ?std.json.Value, now: timeutil.Timestamp) ![]const u8 {
    const scope = argStr(args, "scope");
    if (std.mem.trim(u8, scope, " \t\n\r\x0b\x0c").len == 0) {
        return errors.invalid("scope is required", .{});
    }
    const slug = argStr(args, "slug");
    const title = argStr(args, "title");
    const body = argStr(args, "body");
    if (slug.len + title.len + body.len > max_doc_put_bytes) {
        return errors.invalid("combined slug, title and body exceed {d} bytes", .{max_doc_put_bytes});
    }
    var evidence: []const []const u8 = &.{};
    if (argArr(args, "evidence")) |raw| {
        const list = try a.alloc([]const u8, raw.len);
        for (raw, 0..) |item, i| list[i] = try core.dup(a, item.string);
        evidence = list;
    }
    const d = try core.putDocument(st, a, .{
        .binding = b,
        .scope = try core.dup(a, scope),
        .kind = "knowledge",
        .slug = try core.dup(a, slug),
        .title = try core.dup(a, title),
        .body = try core.dup(a, body),
        .status = "draft",
        .expected = argInt(args, "expected_revision"),
        .draft_only = true,
        .record_kind = (try optArg(a, args, "record_kind")) orelse "",
        .rationale = (try optArg(a, args, "rationale")) orelse "",
        .options_json = try optionsArg(a, args),
        .evidence = evidence,
    }, now);
    var aw = Io.Writer.Allocating.init(a);
    var o = try jsonw.Obj.init(&aw.writer);
    try d.write(&o);
    try o.end();
    return aw.written();
}

fn toolDeleteSource(a: std.mem.Allocator, st: *Store, b: domain.Binding, args: ?std.json.Value, now: timeutil.Timestamp) ![]const u8 {
    const src = try core.deleteSource(st, a, b, try core.dup(a, argStr(args, "source_id")), try core.dup(a, argStr(args, "idempotency_key")), now);
    var aw = Io.Writer.Allocating.init(a);
    var o = try jsonw.Obj.init(&aw.writer);
    var inner = try o.obj("source");
    try src.write(&inner);
    try inner.end();
    try o.end();
    return aw.written();
}
