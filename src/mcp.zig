//! Hand-written MCP JSON-RPC 2.0 server over stdio — the Stage 0 spike.
//! It answers initialize / ping / tools/list / tools/call and stays silent on
//! notifications. Stage 2 replaces the toy tool with the real 19-tool surface.

const std = @import("std");
const Io = std.Io;

const Empty = struct {};
const Caps = struct {
    tools: Empty = .{},
    prompts: Empty = .{},
};

pub fn serve(arena: std.mem.Allocator, io: Io, w: *Io.Writer) !void {
    var in_buf: [1 << 20]u8 = undefined;
    var in: Io.File.Reader = .init(.stdin(), io, &in_buf);
    while (true) {
        // takeDelimiterExclusive is broken in 0.17.0 (it leaves the delimiter
        // in the buffer and returns empty slices forever), so trim inclusive.
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
        const method = if (msg.get("method")) |m| switch (m) {
            .string => |s| s,
            else => "",
        } else "";
        const id: ?std.json.Value = msg.get("id");

        if (std.mem.eql(u8, method, "initialize")) {
            var requested: []const u8 = "2025-06-18";
            if (msg.get("params")) |p| if (p == .object) {
                if (p.object.get("protocolVersion")) |v| if (v == .string) {
                    requested = v.string;
                };
            };
            if (id) |n| try respond(w, n, .{
                .protocolVersion = requested,
                .capabilities = Caps{},
                .serverInfo = .{ .name = "ztd", .version = @import("version.zig").version },
            });
        } else if (std.mem.startsWith(u8, method, "notifications/")) {
            continue;
        } else if (std.mem.eql(u8, method, "ping")) {
            if (id) |n| try respond(w, n, .{});
        } else if (std.mem.eql(u8, method, "tools/list")) {
            if (id) |n| try respond(w, n, .{
                .tools = &.{.{
                    .name = "ping",
                    .description = "Echo a message back.",
                    .inputSchema = .{
                        .type = "object",
                        .properties = .{ .message = .{ .type = "string" } },
                        .required = &.{"message"},
                    },
                }},
            });
        } else if (std.mem.eql(u8, method, "tools/call")) {
            const name = blk: {
                const p = msg.get("params") orelse break :blk "";
                if (p != .object) break :blk "";
                const nv = p.object.get("name") orelse break :blk "";
                break :blk switch (nv) {
                    .string => |s| s,
                    else => "",
                };
            };
            if (id) |n| {
                if (std.mem.eql(u8, name, "ping")) {
                    try respond(w, n, .{ .content = &.{.{ .type = "text", .text = "pong" }} });
                } else {
                    try respond(w, n, .{ .isError = true, .content = &.{.{ .type = "text", .text = "unknown tool" }} });
                }
            }
        } else if (id) |n| {
            try sendError(w, n, -32601, "Method not found");
        }
    }
}

fn respond(w: *Io.Writer, id: std.json.Value, result: anytype) !void {
    try std.json.Stringify.value(.{ .jsonrpc = "2.0", .id = id, .result = result }, .{}, w);
    try w.writeByte('\n');
    try w.flush();
}

fn sendError(w: *Io.Writer, id: std.json.Value, code: i64, message: []const u8) !void {
    try std.json.Stringify.value(.{ .jsonrpc = "2.0", .id = id, .@"error" = .{ .code = code, .message = message } }, .{}, w);
    try w.writeByte('\n');
    try w.flush();
}
