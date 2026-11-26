//! Entry point: wire stdio writers, hand the arguments to the CLI, and keep
//! the spike-only commands (`mcp`, `selftest`) available.

const std = @import("std");
const Io = std.Io;
const mcp = @import("mcp.zig");
const sqlite = @import("sqlite.zig");
const cli = @import("cli.zig");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);

    var out_buf: [8192]u8 = undefined;
    var out: Io.File.Writer = .initStreaming(.stdout(), io, &out_buf);
    const w = &out.interface;
    var err_buf: [4096]u8 = undefined;
    var errw: Io.File.Writer = .initStreaming(.stderr(), io, &err_buf);
    const ew = &errw.interface;

    const command: []const u8 = blk: {
        for (args[1..]) |a| {
            if (std.mem.startsWith(u8, a, "-")) continue;
            break :blk a;
        }
        break :blk "";
    };

    var code: u8 = 0;
    if (std.mem.eql(u8, command, "mcp")) {
        try mcp.serve(arena, io, w);
        try w.flush();
        return;
    } else if (std.mem.eql(u8, command, "selftest")) {
        try sqlite.selfTest(w);
    } else {
        code = try cli.run(init, w, ew, args[1..]);
    }
    try w.flush();
    try ew.flush();
    if (code != 0) std.process.exit(code);
}
