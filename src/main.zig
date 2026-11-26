const std = @import("std");
const Io = std.Io;
const mcp = @import("mcp.zig");
const sqlite = @import("sqlite.zig");
const version = @import("version.zig").version;

pub const usage =
    \\ztd — personal ZTD system
    \\
    \\usage: ztd <command> [flags]
    \\
    \\commands:
    \\  version     print the version
    \\  mcp         serve MCP over stdio (spike)
    \\  selftest    check SQLite, FTS5 and JSON1
    \\
;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);

    var out_buf: [8192]u8 = undefined;
    var out: Io.File.Writer = .init(.stdout(), io, &out_buf);
    const w = &out.interface;

    const json = blk: {
        for (args[1..]) |a| if (std.mem.eql(u8, a, "--json")) break :blk true;
        break :blk false;
    };
    const cmd: []const u8 = blk: {
        for (args[1..]) |a| {
            if (std.mem.startsWith(u8, a, "-")) continue;
            break :blk a;
        }
        break :blk "";
    };

    if (std.mem.eql(u8, cmd, "version") or std.mem.eql(u8, cmd, "--version") or std.mem.eql(u8, cmd, "-v")) {
        if (json) {
            try std.json.Stringify.value(.{ .ok = true, .command = "version", .data = .{ .version = version } }, .{}, w);
            try w.writeByte('\n');
        } else {
            try w.print("{s}\n", .{version});
        }
    } else if (std.mem.eql(u8, cmd, "selftest")) {
        try sqlite.selfTest(w);
    } else if (std.mem.eql(u8, cmd, "mcp")) {
        try mcp.serve(arena, io, w);
        return;
    } else if (cmd.len == 0 or std.mem.eql(u8, cmd, "help") or std.mem.eql(u8, cmd, "--help") or std.mem.eql(u8, cmd, "-h")) {
        try w.writeAll(usage);
    } else {
        try w.print("unknown command: {s}\n", .{cmd});
        try w.flush();
        std.process.exit(2);
    }
    try w.flush();
}
