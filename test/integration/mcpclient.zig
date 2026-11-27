//! A minimal MCP stdio client for the integration runner: initialize
//! handshake, line-delimited JSON-RPC over pipes, and the tool-result shapes
//! the Go tests read through the official SDK. `takeDelimiterExclusive` is
//! broken in Zig 0.17 (it leaves the delimiter behind and loops), so every
//! read here uses the inclusive variant.

const std = @import("std");
const Io = std.Io;
const json = std.json;
const harness = @import("harness.zig");

const Ctx = harness.Ctx;

pub const ProtocolError = error{McpProtocol};

/// What `tools/call` returned: Go's `mcp.CallToolResult` after the wire
/// decode — `content` text lines joined the way `toolText` does it, plus the
/// optional structured content.
pub const ToolResult = struct {
    is_error: bool,
    text: []const u8,
    structured: ?json.Value,
};

pub const Client = struct {
    ctx: *Ctx,
    child: std.process.Child,
    rd: Io.File.Reader,
    wr: Io.File.Writer,
    next_id: i64 = 0,
    open: bool = true,
    /// Message of the last JSON-RPC error response, for failures that need it.
    last_protocol_error: []const u8 = "",
    rbuf: [1 << 20]u8 = undefined,
    wbuf: [1 << 16]u8 = undefined,

    /// Starts the real binary as an MCP stdio server bound to `db` under a
    /// scrubbed environment, then completes the initialize handshake exactly
    /// like the Go SDK's Connect does.
    pub fn connect(ctx: *Ctx, db: []const u8, extra: []const []const u8) !*Client {
        const home = try ctx.tempDir("-mcp-home");
        const tmp = try ctx.tempDir("-mcp-tmp");
        const env = try ctx.childEnv(home, tmp);

        const argv = try ctx.arena.alloc([]const u8, 4 + extra.len);
        argv[0] = ctx.bin;
        argv[1] = "--db";
        argv[2] = db;
        argv[3] = "mcp";
        @memcpy(argv[4..], extra);

        const child = std.process.spawn(ctx.io, .{
            .argv = argv,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .pipe,
            .environ_map = &env,
        }) catch |err|
            return ctx.fatal("connect mcp over stdio: {s}", .{@errorName(err)});

        const self = try ctx.arena.create(Client);
        self.* = .{ .ctx = ctx, .child = child, .rd = undefined, .wr = undefined };
        self.rd = child.stdout.?.readerStreaming(ctx.io, &self.rbuf);
        self.wr = child.stdin.?.writerStreaming(ctx.io, &self.wbuf);

        // initialize: the server echoes the requested protocol version and
        // names itself; a missing result is a handshake failure.
        const params = try obj(ctx.arena, &.{
            .{ "protocolVersion", val("2025-06-18") },
            .{ "capabilities", try obj(ctx.arena, &.{}) },
            .{ "clientInfo", try obj(ctx.arena, &.{
                .{ "name", val("ztd-integration") },
                .{ "version", val("test") },
            }) },
        });
        const resp = self.request("initialize", params) catch |err| switch (err) {
            error.McpProtocol => return ctx.fatal("initialize: {s}", .{self.last_protocol_error}),
            else => return err,
        };
        const result = jget(resp, "result") orelse
            return ctx.fatal("initialize: no result: {s}", .{harness.dump(ctx.arena, resp)});
        const echoed = jstr(result, "protocolVersion") orelse "";
        if (!std.mem.eql(u8, echoed, "2025-06-18"))
            return ctx.fatal("initialize protocolVersion = \"{s}\", want the echoed request", .{echoed});
        const server = jget(result, "serverInfo") orelse
            return ctx.fatal("initialize: no serverInfo: {s}", .{harness.dump(ctx.arena, resp)});
        const server_name: []const u8 = jstr(server, "name") orelse "";
        if (server_name.len == 0)
            return ctx.fatal("initialize: empty serverInfo.name", .{});
        try self.notify("notifications/initialized", null);
        return self;
    }

    /// Sends one request and returns the raw response object whose id
    /// matches, skipping notifications and anything else.
    pub fn request(self: *Client, method: []const u8, params: ?json.Value) !json.Value {
        self.next_id += 1;
        const id = self.next_id;
        try self.send(.{ .jsonrpc = "2.0", .id = id, .method = method, .params = params });
        return self.recv(id);
    }

    pub fn notify(self: *Client, method: []const u8, params: ?json.Value) !void {
        try self.send(.{ .jsonrpc = "2.0", .method = method, .params = params });
    }

    /// One tools/call. Protocol-level errors (JSON-RPC `error`) come back as
    /// `error.McpProtocol` with the message kept on the client; tool-level
    /// errors arrive as a normal result with `isError`.
    pub fn callTool(self: *Client, name: []const u8, args: ?json.Value) !ToolResult {
        const params = try obj(self.ctx.arena, &.{
            .{ "name", val(name) },
            .{ "arguments", args orelse .null },
        });
        const resp = try self.request("tools/call", params);
        const result = jget(resp, "result") orelse {
            if (jget(resp, "error")) |e| {
                self.last_protocol_error = harness.dump(self.ctx.arena, e);
                return error.McpProtocol;
            }
            return self.ctx.fatal("tools/call {s}: no result: {s}", .{ name, harness.dump(self.ctx.arena, resp) });
        };
        return self.parseToolResult(result);
    }

    fn parseToolResult(self: *Client, result: json.Value) !ToolResult {
        var text: std.ArrayList(u8) = .empty;
        if (jarr(result, "content")) |items| {
            for (items) |item| {
                if (!std.mem.eql(u8, jstr(item, "type") orelse "", "text")) continue;
                const t = jstr(item, "text") orelse "";
                text.appendSlice(self.ctx.arena, t) catch {};
                text.append(self.ctx.arena, '\n') catch {};
            }
        }
        return .{
            .is_error = harness.jbool(result, "isError"),
            .text = text.items,
            .structured = harness.jget(result, "structuredContent"),
        };
    }

    /// tools/list: the tools array out of the result.
    pub fn listTools(self: *Client) ![]json.Value {
        const resp = try self.request("tools/list", null);
        const result = jget(resp, "result") orelse
            return self.ctx.fatal("list tools: no result: {s}", .{harness.dump(self.ctx.arena, resp)});
        return jarr(result, "tools") orelse
            return self.ctx.fatal("list tools: no tools array: {s}", .{harness.dump(self.ctx.arena, result)});
    }

    /// Stops the server: close stdin (the serve loop reads until EOF), then
    /// reap it. Idempotent, like the SDK session's Close.
    pub fn close(self: *Client) void {
        if (!self.open) return;
        self.open = false;
        if (self.child.stdin) |stdin| {
            stdin.close(self.ctx.io);
            self.child.stdin = null;
        }
        _ = self.child.wait(self.ctx.io) catch {};
    }

    const Req = struct {
        jsonrpc: []const u8 = "2.0",
        id: ?i64 = null,
        method: []const u8,
        params: ?json.Value = null,
    };

    fn send(self: *Client, req: Req) !void {
        var aw = Io.Writer.Allocating.init(self.ctx.arena);
        try json.Stringify.value(req, .{ .emit_null_optional_fields = false }, &aw.writer);
        try aw.writer.writeByte('\n');
        self.wr.interface.writeAll(aw.written()) catch |err|
            return self.ctx.fatal("mcp write: {s}", .{@errorName(err)});
        self.wr.interface.flush() catch |err|
            return self.ctx.fatal("mcp flush: {s}", .{@errorName(err)});
    }

    fn recv(self: *Client, want_id: i64) !json.Value {
        while (true) {
            const raw = self.rd.interface.takeDelimiterInclusive('\n') catch |err| switch (err) {
                error.EndOfStream => return self.ctx.fatal("mcp: server closed stdout waiting for id {d}", .{want_id}),
                else => return self.ctx.fatal("mcp read: {s}", .{@errorName(err)}),
            };
            const line = std.mem.trim(u8, raw, " \t\r\n");
            if (line.len == 0) continue;
            // The reader buffer is reused; the parse must own its bytes.
            const owned = self.ctx.arena.dupe(u8, line) catch
                return self.ctx.fatal("mcp: out of memory reading a reply", .{});
            const parsed = json.parseFromSlice(json.Value, self.ctx.arena, owned, .{}) catch continue;
            if (parsed.value != .object) continue;
            // Notifications have no id; replies for other ids are skipped.
            const id = harness.jget(parsed.value, "id") orelse continue;
            if (id != .integer or id.integer != want_id) continue;
            if (harness.jget(parsed.value, "error")) |e| {
                self.last_protocol_error = harness.dump(self.ctx.arena, e);
                return error.McpProtocol;
            }
            return parsed.value;
        }
    }
};

// ------------------------------------------------------------------ values

pub const KV = struct { []const u8, json.Value };

pub fn val(s: []const u8) json.Value {
    return .{ .string = s };
}

pub fn num(n: i64) json.Value {
    return .{ .integer = n };
}

pub fn boolean(v: bool) json.Value {
    return .{ .bool = v };
}

pub fn arr(a: std.mem.Allocator, items: []const json.Value) !json.Value {
    var list = json.Array.init(a);
    for (items) |item| try list.append(item);
    return .{ .array = list };
}

pub fn obj(a: std.mem.Allocator, kvs: []const KV) !json.Value {
    var map: json.ObjectMap = .empty;
    for (kvs) |kv| try map.put(a, kv[0], kv[1]);
    return .{ .object = map };
}

pub fn jget(v: json.Value, key: []const u8) ?json.Value {
    return harness.jget(v, key);
}

pub fn jstr(v: json.Value, key: []const u8) ?[]const u8 {
    return harness.jstr(v, key);
}

pub fn jarr(v: json.Value, key: []const u8) ?[]json.Value {
    return harness.jarr(v, key);
}
