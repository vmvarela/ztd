const std = @import("std");
const engine = @import("engine.zig");
const platform = @import("platform.zig");
const store_mod = @import("store.zig");
const model = @import("model.zig");
const agent = @import("agent.zig");
const db = @import("db.zig");

const Ctx = struct {
    io: std.Io,
    alloc: std.mem.Allocator,
    root: ?[]const u8,
    today: platform.Date,
    read_only: bool = false,
    scope: ?[]const u8 = null,
    agent_mode: bool = false,
    agent_scope: ?[]const u8 = null,
    agent_db: ?[]const u8 = null,
};

const ToolError = error{
    ReadOnly,
    ScopeDenied,
    UnknownTool,
    BadParams,
    NotFound,
};

pub fn serve(io: std.Io, alloc: std.mem.Allocator, args: []const []const u8, root: ?[]const u8, today: platform.Date) !void {
    var ctx = Ctx{ .io = io, .alloc = alloc, .root = root, .today = today };
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--read-only")) {
            ctx.read_only = true;
            continue;
        }
        if (std.mem.eql(u8, a, "--scope")) {
            if (i + 1 >= args.len) return error.BadParams;
            ctx.scope = args[i + 1];
            i += 1;
            continue;
        }
        if (std.mem.eql(u8, a, "--agent-scope")) {
            if (i + 1 >= args.len) return error.BadParams;
            ctx.agent_mode = true;
            ctx.agent_scope = args[i + 1];
            i += 1;
            continue;
        }
        if (std.mem.eql(u8, a, "--agent-db")) {
            if (i + 1 >= args.len) return error.BadParams;
            ctx.agent_db = args[i + 1];
            i += 1;
            continue;
        }
        return error.BadParams;
    }
    // --agent-db only makes sense in agent mode, which requires --agent-scope.
    if (ctx.agent_db != null and ctx.agent_scope == null) return error.BadParams;

    var buf: [64 * 1024]u8 = undefined;
    var reader = std.Io.File.stdin().reader(io, &buf);
    while (try reader.interface.takeDelimiter('\n')) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        handleLine(&ctx, trimmed) catch |err| {
            if (err == error.BrokenPipe) return;
            std.debug.print("ztd mcp: {s}\n", .{@errorName(err)});
        };
    }
}

fn handleLine(ctx: *Ctx, line: []const u8) !void {
    const parsed = std.json.parseFromSlice(std.json.Value, ctx.alloc, line, .{}) catch {
        return sendError(ctx, .null, -32700, "parse error");
    };
    const root = parsed.value;
    if (root != .object) return sendError(ctx, .null, -32600, "invalid request");
    const obj = root.object;
    const method = getString(obj, "method") orelse return sendError(ctx, .null, -32600, "missing method");
    const id = obj.get("id");
    if (id == null) return; // notification

    const params = obj.get("params") orelse std.json.Value{ .null = {} };

    if (std.mem.eql(u8, method, "initialize")) {
        return sendResult(ctx, id.?, initializeResult(ctx));
    }
    if (std.mem.eql(u8, method, "ping")) {
        return sendResult(ctx, id.?, .{ .object = .empty });
    }
    if (std.mem.eql(u8, method, "tools/list")) {
        return sendResult(ctx, id.?, toolsList(ctx));
    }
    if (std.mem.eql(u8, method, "tools/call")) {
        return toolsCall(ctx, id.?, params);
    }
    if (std.mem.eql(u8, method, "resources/list")) {
        return sendResult(ctx, id.?, resourcesList(ctx));
    }
    if (std.mem.eql(u8, method, "resources/read")) {
        // Agent mode exposes no resources at all.
        if (ctx.agent_mode) return sendError(ctx, id.?, -32601, "method not found");
        return resourcesRead(ctx, id.?, params);
    }
    return sendError(ctx, id.?, -32601, "method not found");
}

fn initializeResult(ctx: *Ctx) std.json.Value {
    var caps: std.json.ObjectMap = .empty;
    caps.put(ctx.alloc, "tools", .{ .object = .empty }) catch {};
    if (!ctx.agent_mode) caps.put(ctx.alloc, "resources", .{ .object = .empty }) catch {};
    var info: std.json.ObjectMap = .empty;
    info.put(ctx.alloc, "name", .{ .string = "ztd" }) catch {};
    info.put(ctx.alloc, "version", .{ .string = @import("build_options").version }) catch {};
    var out: std.json.ObjectMap = .empty;
    out.put(ctx.alloc, "protocolVersion", .{ .string = "2025-06-18" }) catch {};
    out.put(ctx.alloc, "capabilities", .{ .object = caps }) catch {};
    out.put(ctx.alloc, "serverInfo", .{ .object = info }) catch {};
    out.put(ctx.alloc, "instructions", .{ .string = if (ctx.agent_mode) agent_instructions else legacy_instructions }) catch {};
    return .{ .object = out };
}

const legacy_instructions =
    \\ZTD task manager. Tasks live in Markdown under ztd/.
    \\Use ztd_capture to add, ztd_list/ztd_show to inspect, ztd_move to change list or fields, ztd_plan for a daily plan.
    \\IDs look like T-YYYYMMDD-NNN. Lists: inbox, next, waiting, someday, archive.
    \\The binary only edits Markdown; commit changes yourself.
;

const agent_instructions =
    \\ZTD agent store. The store is the agent record: assignments (capture) and checkpoints (checkpoint).
    \\Markdown lists under ztd/ remain the human-facing task lists; this server does not expose them.
    \\prepare reads back stored state for recovery; it is not proof of completeness.
    \\A revision conflict means the assignment moved on: re-read with prepare and retry with the new rev, never a blind retry.
    \\Scope is configured on the server and enforced there; it is never a tool argument.
;

fn toolsList(ctx: *Ctx) std.json.Value {
    var arr = std.json.Array.init(ctx.alloc);
    if (ctx.agent_mode) {
        const defs = [_]struct { name: []const u8, desc: []const u8 }{
            .{ .name = "ztd_agent_capture", .desc = "Record a new assignment in the agent store." },
            .{ .name = "ztd_agent_checkpoint", .desc = "Record a checkpoint against an assignment." },
            .{ .name = "ztd_agent_prepare", .desc = "Read an assignment and its latest checkpoint." },
        };
        for (defs) |d| {
            var tool: std.json.ObjectMap = .empty;
            tool.put(ctx.alloc, "name", .{ .string = d.name }) catch {};
            tool.put(ctx.alloc, "description", .{ .string = d.desc }) catch {};
            tool.put(ctx.alloc, "inputSchema", agentToolSchema(ctx, d.name)) catch {};
            arr.append(.{ .object = tool }) catch {};
        }
        var out: std.json.ObjectMap = .empty;
        out.put(ctx.alloc, "tools", .{ .array = arr }) catch {};
        return .{ .object = out };
    }
    const defs = [_]struct { name: []const u8, desc: []const u8 }{
        .{ .name = "ztd_capture", .desc = "Capture one or more texts into the inbox." },
        .{ .name = "ztd_list", .desc = "List active tasks, optionally filtered by context, client, project or list." },
        .{ .name = "ztd_show", .desc = "Show one task by id." },
        .{ .name = "ztd_move", .desc = "Move a task to another list and optionally update fields." },
        .{ .name = "ztd_plan", .desc = "Read the daily plan for a context." },
        .{ .name = "ztd_check", .desc = "Validate the workspace." },
    };
    for (defs) |d| {
        var tool: std.json.ObjectMap = .empty;
        tool.put(ctx.alloc, "name", .{ .string = d.name }) catch {};
        tool.put(ctx.alloc, "description", .{ .string = d.desc }) catch {};
        tool.put(ctx.alloc, "inputSchema", toolSchema(ctx, d.name)) catch {};
        arr.append(.{ .object = tool }) catch {};
    }
    var out: std.json.ObjectMap = .empty;
    out.put(ctx.alloc, "tools", .{ .array = arr }) catch {};
    return .{ .object = out };
}

fn prop(ctx: *Ctx, type_name: []const u8, desc: []const u8) std.json.Value {
    var m: std.json.ObjectMap = .empty;
    m.put(ctx.alloc, "type", .{ .string = type_name }) catch {};
    if (desc.len > 0) m.put(ctx.alloc, "description", .{ .string = desc }) catch {};
    return .{ .object = m };
}

fn stringListProp(ctx: *Ctx, desc: []const u8) std.json.Value {
    var m: std.json.ObjectMap = .empty;
    m.put(ctx.alloc, "type", .{ .string = "array" }) catch {};
    m.put(ctx.alloc, "items", prop(ctx, "string", "")) catch {};
    if (desc.len > 0) m.put(ctx.alloc, "description", .{ .string = desc }) catch {};
    return .{ .object = m };
}

fn enumProp(ctx: *Ctx, values: []const []const u8) std.json.Value {
    var m: std.json.ObjectMap = .empty;
    m.put(ctx.alloc, "type", .{ .string = "string" }) catch {};
    var arr = std.json.Array.init(ctx.alloc);
    for (values) |v| arr.append(.{ .string = v }) catch {};
    m.put(ctx.alloc, "enum", .{ .array = arr }) catch {};
    return .{ .object = m };
}

fn toolSchema(ctx: *Ctx, name: []const u8) std.json.Value {
    const lists = [_][]const u8{ "inbox", "next", "waiting", "someday", "archive" };
    var props: std.json.ObjectMap = .empty;
    var required = std.json.Array.init(ctx.alloc);
    if (std.mem.eql(u8, name, "ztd_capture")) {
        props.put(ctx.alloc, "texts", stringListProp(ctx, "One or more capture texts.")) catch {};
        required.append(.{ .string = "texts" }) catch {};
    } else if (std.mem.eql(u8, name, "ztd_list")) {
        props.put(ctx.alloc, "context", prop(ctx, "string", "")) catch {};
        props.put(ctx.alloc, "client", prop(ctx, "string", "")) catch {};
        props.put(ctx.alloc, "project", prop(ctx, "string", "")) catch {};
        props.put(ctx.alloc, "list", enumProp(ctx, &lists)) catch {};
    } else if (std.mem.eql(u8, name, "ztd_show")) {
        props.put(ctx.alloc, "id", prop(ctx, "string", "Task id, e.g. T-20261112-001.")) catch {};
        required.append(.{ .string = "id" }) catch {};
    } else if (std.mem.eql(u8, name, "ztd_move")) {
        props.put(ctx.alloc, "id", prop(ctx, "string", "Task id.")) catch {};
        props.put(ctx.alloc, "to", enumProp(ctx, &lists)) catch {};
        var fields_prop: std.json.ObjectMap = .empty;
        fields_prop.put(ctx.alloc, "type", .{ .string = "object" }) catch {};
        fields_prop.put(ctx.alloc, "additionalProperties", prop(ctx, "string", "")) catch {};
        fields_prop.put(ctx.alloc, "description", .{ .string = "Fields to set, e.g. contexto, espera, resolución." }) catch {};
        props.put(ctx.alloc, "fields", .{ .object = fields_prop }) catch {};
        props.put(ctx.alloc, "unset", stringListProp(ctx, "Field names to remove.")) catch {};
        props.put(ctx.alloc, "text", prop(ctx, "string", "Replace the task title.")) catch {};
        var line_prop: std.json.ObjectMap = .empty;
        line_prop.put(ctx.alloc, "type", .{ .string = "integer" }) catch {};
        line_prop.put(ctx.alloc, "minimum", .{ .integer = 1 }) catch {};
        line_prop.put(ctx.alloc, "description", .{ .string = "Fail unless the task is still on this line." }) catch {};
        props.put(ctx.alloc, "expect_line", .{ .object = line_prop }) catch {};
        required.append(.{ .string = "id" }) catch {};
        required.append(.{ .string = "to" }) catch {};
    } else if (std.mem.eql(u8, name, "ztd_plan")) {
        props.put(ctx.alloc, "context", prop(ctx, "string", "Context whose daily plan is read.")) catch {};
        props.put(ctx.alloc, "client", prop(ctx, "string", "")) catch {};
        props.put(ctx.alloc, "date", prop(ctx, "string", "YYYY-MM-DD; defaults to today.")) catch {};
        required.append(.{ .string = "context" }) catch {};
    }
    var schema: std.json.ObjectMap = .empty;
    schema.put(ctx.alloc, "type", .{ .string = "object" }) catch {};
    schema.put(ctx.alloc, "properties", .{ .object = props }) catch {};
    if (required.items.len > 0) schema.put(ctx.alloc, "required", .{ .array = required }) catch {};
    return .{ .object = schema };
}

/// Agent-mode schemas stay small: the scope comes from server configuration
/// and is never a tool argument.
fn agentToolSchema(ctx: *Ctx, name: []const u8) std.json.Value {
    var props: std.json.ObjectMap = .empty;
    var required = std.json.Array.init(ctx.alloc);
    if (std.mem.eql(u8, name, "ztd_agent_capture")) {
        props.put(ctx.alloc, "request", prop(ctx, "string", "What was asked for.")) catch {};
        props.put(ctx.alloc, "objective", prop(ctx, "string", "Intended outcome.")) catch {};
        props.put(ctx.alloc, "constraints", prop(ctx, "string", "Limits to respect.")) catch {};
        props.put(ctx.alloc, "project", prop(ctx, "string", "Related project.")) catch {};
        props.put(ctx.alloc, "idempotency_key", prop(ctx, "string", "Repeat with the same key to replay.")) catch {};
        required.append(.{ .string = "request" }) catch {};
    } else if (std.mem.eql(u8, name, "ztd_agent_checkpoint")) {
        props.put(ctx.alloc, "assignment_id", prop(ctx, "string", "Assignment id, e.g. A-20261114-001.")) catch {};
        var rev: std.json.ObjectMap = .empty;
        rev.put(ctx.alloc, "type", .{ .string = "integer" }) catch {};
        rev.put(ctx.alloc, "description", .{ .string = "Assignment rev expected; a mismatch is revision_conflict." }) catch {};
        props.put(ctx.alloc, "expect_rev", .{ .object = rev }) catch {};
        props.put(ctx.alloc, "kind", enumProp(ctx, &.{ "progress", "done" })) catch {};
        props.put(ctx.alloc, "result", prop(ctx, "string", "What happened.")) catch {};
        props.put(ctx.alloc, "evidence", prop(ctx, "string", "Link or reference proving it.")) catch {};
        props.put(ctx.alloc, "next_action", prop(ctx, "string", "What to do next.")) catch {};
        props.put(ctx.alloc, "idempotency_key", prop(ctx, "string", "Repeat with the same key to replay.")) catch {};
        required.append(.{ .string = "assignment_id" }) catch {};
        required.append(.{ .string = "expect_rev" }) catch {};
        required.append(.{ .string = "result" }) catch {};
    } else if (std.mem.eql(u8, name, "ztd_agent_prepare")) {
        props.put(ctx.alloc, "assignment_id", prop(ctx, "string", "Assignment id, e.g. A-20261114-001.")) catch {};
        required.append(.{ .string = "assignment_id" }) catch {};
    }
    var schema: std.json.ObjectMap = .empty;
    schema.put(ctx.alloc, "type", .{ .string = "object" }) catch {};
    schema.put(ctx.alloc, "properties", .{ .object = props }) catch {};
    if (required.items.len > 0) schema.put(ctx.alloc, "required", .{ .array = required }) catch {};
    return .{ .object = schema };
}

fn resourcesList(ctx: *Ctx) std.json.Value {
    var arr = std.json.Array.init(ctx.alloc);
    if (!ctx.agent_mode) {
        const defs = [_]struct { uri: []const u8, name: []const u8, mime: []const u8 }{
            .{ .uri = "ztd://contexts", .name = "Contexts", .mime = "text/markdown" },
            .{ .uri = "ztd://config", .name = "Config", .mime = "application/json" },
        };
        for (defs) |d| {
            var r: std.json.ObjectMap = .empty;
            r.put(ctx.alloc, "uri", .{ .string = d.uri }) catch {};
            r.put(ctx.alloc, "name", .{ .string = d.name }) catch {};
            r.put(ctx.alloc, "mimeType", .{ .string = d.mime }) catch {};
            arr.append(.{ .object = r }) catch {};
        }
    }
    var out: std.json.ObjectMap = .empty;
    out.put(ctx.alloc, "resources", .{ .array = arr }) catch {};
    return .{ .object = out };
}

fn resourcesRead(ctx: *Ctx, id: std.json.Value, params: std.json.Value) !void {
    if (params != .object) return sendError(ctx, id, -32602, "invalid params");
    const uri = getString(params.object, "uri") orelse return sendError(ctx, id, -32602, "missing uri");
    const resource = readResource(ctx, uri) catch |err| {
        return sendError(ctx, id, -32002, @errorName(err));
    };
    var content: std.json.ObjectMap = .empty;
    content.put(ctx.alloc, "uri", .{ .string = uri }) catch {};
    content.put(ctx.alloc, "mimeType", .{ .string = if (std.mem.endsWith(u8, uri, "config")) "application/json" else "text/markdown" }) catch {};
    content.put(ctx.alloc, "text", .{ .string = resource }) catch {};
    var arr = std.json.Array.init(ctx.alloc);
    try arr.append(.{ .object = content });
    var out: std.json.ObjectMap = .empty;
    out.put(ctx.alloc, "contents", .{ .array = arr }) catch {};
    return sendResult(ctx, id, .{ .object = out });
}

fn readResource(ctx: *Ctx, uri: []const u8) ![]const u8 {
    const rel = if (std.mem.eql(u8, uri, "ztd://contexts"))
        "contexts.md"
    else if (std.mem.eql(u8, uri, "ztd://config"))
        "config.json"
    else if (std.mem.startsWith(u8, uri, "ztd://plan/"))
        try std.fmt.allocPrint(ctx.alloc, "plans/daily/{s}.md", .{uri["ztd://plan/".len..]})
    else
        return error.NotFound;

    const root = try store_mod.resolveRoot(ctx.io, ctx.alloc, ctx.root);
    var store = try store_mod.Store.open(ctx.io, ctx.alloc, root);
    defer store.deinit();
    const text = (try store.readOptional(rel)) orelse return error.NotFound;
    if (ctx.scope) |scope| {
        if (std.mem.eql(u8, uri, "ztd://contexts")) return filterContexts(ctx.alloc, text, scope);
    }
    return text;
}

fn filterContexts(alloc: std.mem.Allocator, text: []const u8, scope: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    var first = true;
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        var keep = true;
        if (std.mem.startsWith(u8, trimmed, "|")) {
            const end = std.mem.indexOfScalarPos(u8, trimmed, 1, '|') orelse trimmed.len;
            const cell = std.mem.trim(u8, trimmed[1..end], " \t");
            keep = cell.len == 0 or std.mem.eql(u8, cell, "Contexto") or std.mem.allEqual(u8, cell, '-') or std.mem.eql(u8, cell, scope);
        }
        if (!keep) continue;
        if (!first) try out.append(alloc, '\n');
        first = false;
        try out.appendSlice(alloc, line);
    }
    return out.toOwnedSlice(alloc);
}

fn toolsCall(ctx: *Ctx, id: std.json.Value, params: std.json.Value) !void {
    if (params != .object) return sendError(ctx, id, -32602, "invalid params");
    const name = getString(params.object, "name") orelse return sendError(ctx, id, -32602, "missing name");
    const args_val = params.object.get("arguments") orelse std.json.Value{ .object = .empty };
    const args = if (args_val == .object) args_val.object else std.json.ObjectMap.empty;

    const data = handleTool(ctx, name, args) catch |err| {
        const code = toolErrorName(err);
        var body: std.json.ObjectMap = .empty;
        body.put(ctx.alloc, "ok", .{ .bool = false }) catch {};
        body.put(ctx.alloc, "error", .{ .string = code }) catch {};
        const text = std.json.Stringify.valueAlloc(ctx.alloc, std.json.Value{ .object = body }, .{}) catch "{}";
        return sendTool(ctx, id, text, true);
    };
    const text = try std.json.Stringify.valueAlloc(ctx.alloc, data, .{});
    return sendTool(ctx, id, text, false);
}

fn handleTool(ctx: *Ctx, name: []const u8, args: std.json.ObjectMap) !std.json.Value {
    if (ctx.agent_mode) return handleAgentTool(ctx, name, args);
    if (std.mem.eql(u8, name, "ztd_capture")) {
        if (ctx.read_only) return error.ReadOnly;
        const texts_val = args.get("texts") orelse return error.BadParams;
        if (texts_val != .array) return error.BadParams;
        var texts: std.ArrayList([]const u8) = .empty;
        for (texts_val.array.items) |v| {
            if (v != .string) return error.BadParams;
            try texts.append(ctx.alloc, v.string);
        }
        var eng = try engine.Engine.init(ctx.io, ctx.alloc, try store_mod.resolveRoot(ctx.io, ctx.alloc, ctx.root), ctx.today, true);
        defer eng.deinit();
        const created = try eng.capture(texts.items, false);
        return .{ .object = try createdData(ctx, created) };
    }
    if (std.mem.eql(u8, name, "ztd_list")) {
        const context = getString(args, "context");
        const client = getString(args, "client");
        const project = getString(args, "project");
        const list_name = getString(args, "list");
        if (context) |c| try checkScopeOpt(ctx, c);
        var eng = try engine.Engine.init(ctx.io, ctx.alloc, try store_mod.resolveRoot(ctx.io, ctx.alloc, ctx.root), ctx.today, false);
        defer eng.deinit();
        const only = if (list_name) |l| engine.List.parse(l) orelse return error.BadParams else null;
        const tasks = try eng.listTasks(context orelse ctx.scope, client, project, only);
        var out: std.json.ObjectMap = .empty;
        out.put(ctx.alloc, "tasks", .{ .array = try tasksArray(ctx, tasks) }) catch {};
        return .{ .object = out };
    }
    if (std.mem.eql(u8, name, "ztd_show")) {
        const id = getString(args, "id") orelse return error.BadParams;
        var eng = try engine.Engine.init(ctx.io, ctx.alloc, try store_mod.resolveRoot(ctx.io, ctx.alloc, ctx.root), ctx.today, false);
        defer eng.deinit();
        const all = try eng.loadAll();
        const lt = try eng.find(id, all);
        try checkScopeOpt(ctx, lt.task.get("contexto"));
        var out: std.json.ObjectMap = .empty;
        out.put(ctx.alloc, "task", try taskValue(ctx, lt)) catch {};
        out.put(ctx.alloc, "file", .{ .string = lt.file }) catch {};
        out.put(ctx.alloc, "line", .{ .integer = @intCast(lt.line) }) catch {};
        return .{ .object = out };
    }
    if (std.mem.eql(u8, name, "ztd_move")) {
        if (ctx.read_only) return error.ReadOnly;
        const id = getString(args, "id") orelse return error.BadParams;
        const to = getString(args, "to") orelse return error.BadParams;
        const dest = engine.List.parse(to) orelse return error.BadParams;
        var eng = try engine.Engine.init(ctx.io, ctx.alloc, try store_mod.resolveRoot(ctx.io, ctx.alloc, ctx.root), ctx.today, true);
        defer eng.deinit();
        const all = try eng.loadAll();
        const before = try eng.find(id, all);
        try checkScopeOpt(ctx, before.task.get("contexto"));
        var target_context = before.task.get("contexto");
        var set_fields: std.ArrayList([2][]const u8) = .empty;
        if (args.get("fields")) |fields_val| {
            if (fields_val != .object) return error.BadParams;
            var keys: std.ArrayList([]const u8) = .empty;
            var it = fields_val.object.iterator();
            while (it.next()) |entry| try keys.append(ctx.alloc, entry.key_ptr.*);
            std.mem.sort([]const u8, keys.items, {}, lessThan);
            for (keys.items) |k| {
                const v = fields_val.object.get(k) orelse continue;
                if (v != .string) return error.BadParams;
                if (std.mem.eql(u8, k, "contexto")) target_context = v.string;
                try set_fields.append(ctx.alloc, .{ k, v.string });
            }
        }
        try checkScopeOpt(ctx, target_context);
        var unset_fields: std.ArrayList([]const u8) = .empty;
        if (args.get("unset")) |unset_val| {
            if (unset_val != .array) return error.BadParams;
            for (unset_val.array.items) |v| {
                if (v != .string) return error.BadParams;
                try unset_fields.append(ctx.alloc, v.string);
            }
        }
        const expect_line: ?usize = if (args.get("expect_line")) |v| switch (v) {
            .integer => |n| if (n > 0) @intCast(n) else return error.BadParams,
            else => return error.BadParams,
        } else null;
        const moved = try eng.move(id, dest, getString(args, "text"), set_fields.items, unset_fields.items, expect_line, false);
        var out: std.json.ObjectMap = .empty;
        out.put(ctx.alloc, "task", try taskValue(ctx, moved)) catch {};
        out.put(ctx.alloc, "from", .{ .string = if (moved.previous) |p| p.name() else "" }) catch {};
        out.put(ctx.alloc, "to", .{ .string = moved.list.name() }) catch {};
        return .{ .object = out };
    }
    if (std.mem.eql(u8, name, "ztd_plan")) {
        const context = getString(args, "context") orelse return error.BadParams;
        try checkScopeOpt(ctx, context);
        const client = getString(args, "client");
        const date = if (getString(args, "date")) |d| platform.parseDate(d) catch return error.BadParams else ctx.today;
        var eng = try engine.Engine.init(ctx.io, ctx.alloc, try store_mod.resolveRoot(ctx.io, ctx.alloc, ctx.root), ctx.today, false);
        defer eng.deinit();
        const tasks = try eng.planTasks(date, context, client);
        var dbuf: [10]u8 = undefined;
        const ds = date.format(&dbuf);
        var out: std.json.ObjectMap = .empty;
        out.put(ctx.alloc, "date", .{ .string = ds }) catch {};
        out.put(ctx.alloc, "context", .{ .string = context }) catch {};
        out.put(ctx.alloc, "tasks", .{ .array = try tasksArray(ctx, tasks) }) catch {};
        return .{ .object = out };
    }
    if (std.mem.eql(u8, name, "ztd_check")) {
        var eng = try engine.Engine.init(ctx.io, ctx.alloc, try store_mod.resolveRoot(ctx.io, ctx.alloc, ctx.root), ctx.today, false);
        defer eng.deinit();
        if (eng.pending()) return error.PendingTransaction;
        const result = try eng.check(false);
        var out: std.json.ObjectMap = .empty;
        out.put(ctx.alloc, "errors", .{ .array = try stringsArray(ctx, result.errors) }) catch {};
        out.put(ctx.alloc, "warnings", .{ .array = try stringsArray(ctx, result.warnings) }) catch {};
        return .{ .object = out };
    }
    return error.UnknownTool;
}

/// Agent mode: the scope comes from server configuration and is enforced on
/// every call, never from tool arguments.
fn handleAgentTool(ctx: *Ctx, name: []const u8, args: std.json.ObjectMap) !std.json.Value {
    const capture = std.mem.eql(u8, name, "ztd_agent_capture");
    const checkpoint = std.mem.eql(u8, name, "ztd_agent_checkpoint");
    const prepare = std.mem.eql(u8, name, "ztd_agent_prepare");
    if (!capture and !checkpoint and !prepare) return error.UnknownTool;
    if ((capture or checkpoint) and ctx.read_only) return error.ReadOnly;
    const scope = ctx.agent_scope orelse return error.BadParams;

    const path = try db.resolvePath(ctx.io, ctx.alloc, ctx.agent_db);
    var store = try agent.Store.open(ctx.alloc, ctx.io, path);
    defer store.close();

    if (capture) {
        const r = try store.capture(.{
            .scope = scope,
            .project = try optString(args, "project"),
            .request = (try optString(args, "request")) orelse return error.BadParams,
            .objective = try optString(args, "objective"),
            .constraints = try optString(args, "constraints"),
            .idempotency_key = try optString(args, "idempotency_key"),
        });
        defer store.deinitCaptureResult(r);
        return agentJsonValue(ctx, r);
    }
    if (checkpoint) {
        const expect_rev: i64 = switch (args.get("expect_rev") orelse return error.BadParams) {
            .integer => |n| n,
            else => return error.BadParams,
        };
        const r = try store.checkpoint(.{
            .assignment_id = (try optString(args, "assignment_id")) orelse return error.BadParams,
            .scope = scope,
            .expect_rev = expect_rev,
            .kind = (try optString(args, "kind")) orelse "progress",
            .result = (try optString(args, "result")) orelse return error.BadParams,
            .evidence = try optString(args, "evidence"),
            .next_action = try optString(args, "next_action"),
            .idempotency_key = try optString(args, "idempotency_key"),
        });
        defer store.deinitCheckpointResult(r);
        return agentJsonValue(ctx, r);
    }
    const r = try store.prepare((try optString(args, "assignment_id")) orelse return error.BadParams, scope);
    defer store.deinitPrepareResult(r);
    return agentJsonValue(ctx, r);
}

fn agentJsonValue(ctx: *Ctx, result: anytype) !std.json.Value {
    const text = try std.json.Stringify.valueAlloc(ctx.alloc, result, .{});
    return std.json.parseFromSliceLeaky(std.json.Value, ctx.alloc, text, .{});
}

fn createdData(ctx: *Ctx, tasks: []const engine.LoadedTask) !std.json.ObjectMap {
    var out: std.json.ObjectMap = .empty;
    out.put(ctx.alloc, "created", .{ .array = try tasksArray(ctx, tasks) }) catch {};
    return out;
}

fn tasksArray(ctx: *Ctx, tasks: []const engine.LoadedTask) !std.json.Array {
    var arr = std.json.Array.init(ctx.alloc);
    for (tasks) |lt| try arr.append(try taskValue(ctx, lt));
    return arr;
}

fn taskValue(ctx: *Ctx, lt: engine.LoadedTask) !std.json.Value {
    var obj: std.json.ObjectMap = .empty;
    obj.put(ctx.alloc, "id", .{ .string = lt.task.id }) catch {};
    obj.put(ctx.alloc, "title", .{ .string = lt.task.title }) catch {};
    obj.put(ctx.alloc, "status", .{ .string = if (lt.task.status == .done) "done" else "open" }) catch {};
    obj.put(ctx.alloc, "list", .{ .string = lt.list.name() }) catch {};
    obj.put(ctx.alloc, "file", .{ .string = lt.file }) catch {};
    obj.put(ctx.alloc, "line", .{ .integer = @intCast(lt.line) }) catch {};
    var fields = std.json.Array.init(ctx.alloc);
    for (lt.task.fields.items) |f| {
        var fv: std.json.ObjectMap = .empty;
        fv.put(ctx.alloc, "key", .{ .string = f.key }) catch {};
        fv.put(ctx.alloc, "value", .{ .string = f.value }) catch {};
        try fields.append(.{ .object = fv });
    }
    obj.put(ctx.alloc, "fields", .{ .array = fields }) catch {};
    return .{ .object = obj };
}

fn stringsArray(ctx: *Ctx, items: []const []const u8) !std.json.Array {
    var arr = std.json.Array.init(ctx.alloc);
    for (items) |s| try arr.append(.{ .string = s });
    return arr;
}

fn checkScopeOpt(ctx: *Ctx, context: ?[]const u8) !void {
    if (ctx.scope) |s| {
        if (context == null or !std.mem.eql(u8, context.?, s)) return error.ScopeDenied;
    }
}

fn toolErrorName(err: anyerror) []const u8 {
    return switch (err) {
        error.ReadOnly => "read_only",
        error.ScopeDenied => "scope_denied",
        error.UnknownTool => "unknown_tool",
        error.BadParams => "invalid_field",
        error.NotFound => "not_found",
        else => engine.errorName(err),
    };
}

fn sendTool(ctx: *Ctx, id: std.json.Value, text: []const u8, is_error: bool) !void {
    var item: std.json.ObjectMap = .empty;
    item.put(ctx.alloc, "type", .{ .string = "text" }) catch {};
    item.put(ctx.alloc, "text", .{ .string = text }) catch {};
    var arr = std.json.Array.init(ctx.alloc);
    try arr.append(.{ .object = item });
    var result: std.json.ObjectMap = .empty;
    result.put(ctx.alloc, "content", .{ .array = arr }) catch {};
    result.put(ctx.alloc, "isError", .{ .bool = is_error }) catch {};
    return sendResult(ctx, id, .{ .object = result });
}

fn sendResult(ctx: *Ctx, id: std.json.Value, result: std.json.Value) !void {
    var obj: std.json.ObjectMap = .empty;
    obj.put(ctx.alloc, "jsonrpc", .{ .string = "2.0" }) catch {};
    obj.put(ctx.alloc, "id", id) catch {};
    obj.put(ctx.alloc, "result", result) catch {};
    try writeValue(ctx, .{ .object = obj });
}

fn sendError(ctx: *Ctx, id: std.json.Value, code: i64, message: []const u8) !void {
    var err_obj: std.json.ObjectMap = .empty;
    err_obj.put(ctx.alloc, "code", .{ .integer = code }) catch {};
    err_obj.put(ctx.alloc, "message", .{ .string = message }) catch {};
    var obj: std.json.ObjectMap = .empty;
    obj.put(ctx.alloc, "jsonrpc", .{ .string = "2.0" }) catch {};
    obj.put(ctx.alloc, "id", id) catch {};
    obj.put(ctx.alloc, "error", .{ .object = err_obj }) catch {};
    try writeValue(ctx, .{ .object = obj });
}

fn writeValue(ctx: *Ctx, value: std.json.Value) !void {
    const text = try std.json.Stringify.valueAlloc(ctx.alloc, value, .{});
    try std.Io.File.stdout().writeStreamingAll(ctx.io, text);
    try std.Io.File.stdout().writeStreamingAll(ctx.io, "\n");
}

fn getString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .string => |s| s,
        .null => null,
        else => null,
    };
}

/// Optional agent argument: absent or null is null, but a present value of the
/// wrong type is an error rather than a silent drop.
fn optString(obj: std.json.ObjectMap, key: []const u8) !?[]const u8 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .string => |s| s,
        .null => null,
        else => error.BadParams,
    };
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

test "tool error names" {
    try std.testing.expectEqualStrings("read_only", toolErrorName(error.ReadOnly));
    try std.testing.expectEqualStrings("scope_denied", toolErrorName(error.ScopeDenied));
    try std.testing.expectEqualStrings("unknown_id", toolErrorName(error.UnknownId));
}

test "tool schemas declare the arguments the handlers read" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var ctx = Ctx{
        .io = undefined,
        .alloc = arena_state.allocator(),
        .root = null,
        .today = .{ .year = 2026, .month = 11, .day = 12 },
    };
    const listed = toolsList(&ctx);
    const tools = listed.object.get("tools").?.array;

    const Case = struct {
        name: []const u8,
        props: []const []const u8,
        required: []const []const u8,
    };
    const cases = [_]Case{
        .{ .name = "ztd_capture", .props = &.{"texts"}, .required = &.{"texts"} },
        .{ .name = "ztd_list", .props = &.{ "context", "client", "project", "list" }, .required = &.{} },
        .{ .name = "ztd_show", .props = &.{"id"}, .required = &.{"id"} },
        .{ .name = "ztd_move", .props = &.{ "id", "to", "fields", "unset", "text", "expect_line" }, .required = &.{ "id", "to" } },
        .{ .name = "ztd_plan", .props = &.{ "context", "client", "date" }, .required = &.{"context"} },
        .{ .name = "ztd_check", .props = &.{}, .required = &.{} },
    };
    try std.testing.expectEqual(cases.len, tools.items.len);
    for (tools.items) |t| {
        const tool_name = t.object.get("name").?.string;
        var expected: ?Case = null;
        for (cases) |c| {
            if (std.mem.eql(u8, c.name, tool_name)) expected = c;
        }
        const c = expected orelse return error.UnknownTool;
        const schema = t.object.get("inputSchema").?.object;
        const props = schema.get("properties").?.object;
        try std.testing.expectEqual(c.props.len, props.count());
        for (c.props) |p| try std.testing.expect(props.get(p) != null);
        const required: []const std.json.Value = if (schema.get("required")) |r| r.array.items else &.{};
        try std.testing.expectEqual(c.required.len, required.len);
        for (c.required) |p| {
            var found = false;
            for (required) |r| {
                if (std.mem.eql(u8, r.string, p)) found = true;
            }
            try std.testing.expect(found);
        }
    }
}

test "agent mode exposes only the three agent tools and no resources" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var ctx = Ctx{
        .io = undefined,
        .alloc = arena_state.allocator(),
        .root = null,
        .today = .{ .year = 2026, .month = 11, .day = 12 },
        .agent_mode = true,
        .agent_scope = "demo",
    };

    const tools = toolsList(&ctx).object.get("tools").?.array;
    const expected = [_][]const u8{ "ztd_agent_capture", "ztd_agent_checkpoint", "ztd_agent_prepare" };
    try std.testing.expectEqual(expected.len, tools.items.len);
    for (tools.items, expected) |t, name| {
        try std.testing.expectEqualStrings(name, t.object.get("name").?.string);
        // scope is server configuration, never a tool argument
        const props = t.object.get("inputSchema").?.object.get("properties").?.object;
        try std.testing.expect(props.get("scope") == null);
    }

    try std.testing.expectEqual(@as(usize, 0), resourcesList(&ctx).object.get("resources").?.array.items.len);
    const instructions = initializeResult(&ctx).object.get("instructions").?.string;
    try std.testing.expect(std.mem.indexOf(u8, instructions, "not proof of completeness") != null);
    try std.testing.expect(std.mem.indexOf(u8, instructions, "re-read") != null);
}

test "agent arguments of the wrong type are rejected, not dropped" {
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        "{\"constraints\":1,\"evidence\":true,\"kind\":3,\"objective\":null}",
        .{},
    );
    defer parsed.deinit();
    const obj = parsed.value.object;
    try std.testing.expectError(error.BadParams, optString(obj, "constraints"));
    try std.testing.expectError(error.BadParams, optString(obj, "evidence"));
    try std.testing.expectError(error.BadParams, optString(obj, "kind"));
    try std.testing.expectEqual(@as(?[]const u8, null), try optString(obj, "objective"));
    try std.testing.expectEqual(@as(?[]const u8, null), try optString(obj, "absent"));
}
