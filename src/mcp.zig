const std = @import("std");
const engine = @import("engine.zig");
const platform = @import("platform.zig");
const store_mod = @import("store.zig");
const model = @import("model.zig");

const Ctx = struct {
    io: std.Io,
    alloc: std.mem.Allocator,
    root: ?[]const u8,
    today: platform.Date,
    read_only: bool = false,
    scope: ?[]const u8 = null,
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
        return error.BadParams;
    }

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
        return resourcesRead(ctx, id.?, params);
    }
    return sendError(ctx, id.?, -32601, "method not found");
}

fn initializeResult(ctx: *Ctx) std.json.Value {
    var caps: std.json.ObjectMap = .empty;
    caps.put(ctx.alloc, "tools", .{ .object = .empty }) catch {};
    caps.put(ctx.alloc, "resources", .{ .object = .empty }) catch {};
    var info: std.json.ObjectMap = .empty;
    info.put(ctx.alloc, "name", .{ .string = "ztd" }) catch {};
    info.put(ctx.alloc, "version", .{ .string = @import("build_options").version }) catch {};
    var out: std.json.ObjectMap = .empty;
    out.put(ctx.alloc, "protocolVersion", .{ .string = "2025-06-18" }) catch {};
    out.put(ctx.alloc, "capabilities", .{ .object = caps }) catch {};
    out.put(ctx.alloc, "serverInfo", .{ .object = info }) catch {};
    out.put(ctx.alloc, "instructions", .{ .string =
        \\ZTD task manager. Tasks live in Markdown under ztd/.
        \\Use ztd_capture to add, ztd_list/ztd_show to inspect, ztd_move to change list or fields, ztd_plan for a daily plan.
        \\IDs look like T-YYYYMMDD-NNN. Lists: inbox, next, waiting, someday, archive.
        \\The binary only edits Markdown; commit changes yourself.
    }) catch {};
    return .{ .object = out };
}

fn toolsList(ctx: *Ctx) std.json.Value {
    var arr = std.json.Array.init(ctx.alloc);
    const defs = [_]struct { name: []const u8, desc: []const u8 }{
        .{ .name = "ztd_capture", .desc = "Capture one or more texts into the inbox." },
        .{ .name = "ztd_list", .desc = "List active tasks, optionally filtered by context, client, project or list." },
        .{ .name = "ztd_show", .desc = "Show one task by id." },
        .{ .name = "ztd_move", .desc = "Move a task to another list and optionally update fields." },
        .{ .name = "ztd_plan", .desc = "Read the daily plan for a context." },
        .{ .name = "ztd_check", .desc = "Validate the workspace." },
    };
    for (defs) |d| {
        var schema: std.json.ObjectMap = .empty;
        schema.put(ctx.alloc, "type", .{ .string = "object" }) catch {};
        schema.put(ctx.alloc, "additionalProperties", .{ .bool = true }) catch {};
        var tool: std.json.ObjectMap = .empty;
        tool.put(ctx.alloc, "name", .{ .string = d.name }) catch {};
        tool.put(ctx.alloc, "description", .{ .string = d.desc }) catch {};
        tool.put(ctx.alloc, "inputSchema", .{ .object = schema }) catch {};
        arr.append(.{ .object = tool }) catch {};
    }
    var out: std.json.ObjectMap = .empty;
    out.put(ctx.alloc, "tools", .{ .array = arr }) catch {};
    return .{ .object = out };
}

fn resourcesList(ctx: *Ctx) std.json.Value {
    var arr = std.json.Array.init(ctx.alloc);
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
        else => null,
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
