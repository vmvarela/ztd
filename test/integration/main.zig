//! The integration runner: resolves the product binary, gives every test its
//! own throwaway HOME/TMPDIR, and prints a per-test summary. Exit 0 only when
//! every test passes.

const std = @import("std");
const harness = @import("harness.zig");
const mcp_tests = @import("mcp_tests.zig");
const install_tests = @import("install_tests.zig");
const cli_tests = @import("cli_tests.zig");

const Test = struct {
    name: []const u8,
    func: *const fn (*harness.Ctx) anyerror!void,
};

/// Ported from mcp_test.go (8 functions) and install_test.go (5 tests), plus
/// one alias test for the CLI surface no golden covers.
const tests = [_]Test{
    .{ .name = "TestMCPStdioJourney", .func = mcp_tests.testMCPStdioJourney },
    .{ .name = "TestMCPSourceFlow", .func = mcp_tests.testMCPSourceFlow },
    .{ .name = "TestMCPDocumentTools", .func = mcp_tests.testMCPDocumentTools },
    .{ .name = "TestMCPDeleteSource", .func = mcp_tests.testMCPDeleteSource },
    .{ .name = "TestMCPDeleteSourceHiddenByDefault", .func = mcp_tests.testMCPDeleteSourceHiddenByDefault },
    .{ .name = "TestMCPDeleteSourceAnswersMissingAndForeignAlike", .func = mcp_tests.testMCPDeleteSourceAnswersMissingAndForeignAlike },
    .{ .name = "TestMCPCaptureSourceReferenceAnswersAlike", .func = mcp_tests.testMCPCaptureSourceReferenceAnswersAlike },
    .{ .name = "TestMCPDocPut", .func = mcp_tests.testMCPDocPut },
    .{ .name = "TestInstallOpenCodeDryRun", .func = install_tests.testInstallOpenCodeDryRun },
    .{ .name = "TestInstallTemplates", .func = install_tests.testInstallTemplates },
    .{ .name = "TestInstallTemplatesMissingRoot", .func = install_tests.testInstallTemplatesMissingRoot },
    .{ .name = "TestInstallOpenCodeForReal", .func = install_tests.testInstallOpenCodeForReal },
    .{ .name = "TestInstallConflictEnvelope", .func = install_tests.testInstallConflictEnvelope },
    .{ .name = "TestRoutineAliases", .func = cli_tests.testRoutineAliases },
};

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);

    // argv[1] (the build passes the product binary), else ZTD_BIN, else the
    // default install output. Paths stay as given: children inherit cwd.
    var bin: []const u8 = "";
    if (args.len > 1) bin = args[1];
    if (bin.len == 0) {
        if (init.environ_map.get("ZTD_BIN")) |v| bin = v;
    }
    if (bin.len == 0) bin = "./zig-out/bin/ztd";

    // The suites scrub the child environment; the temp base comes from the
    // parent TMPDIR (macOS) with a pre-approved fallback elsewhere.
    const tmp_base = init.environ_map.get("TMPDIR") orelse
        "/private/var/folders/lf/z5n_9g7j64v8d7gk_lqzd8k40000gn/T/opencode";
    const path = init.environ_map.get("PATH") orelse "/usr/bin:/bin";

    var passed: usize = 0;
    var failed: usize = 0;
    for (tests) |t| {
        var ctx = harness.Ctx{
            .arena = arena,
            .io = io,
            .bin = bin,
            .path = path,
            .tmp_base = tmp_base,
        };
        const outcome = t.func(&ctx);
        if (outcome) |_| {
            if (ctx.failures.items.len == 0) {
                passed += 1;
                std.debug.print("PASS {s}\n", .{t.name});
            } else {
                failed += 1;
                printFailure(t.name, ctx.failures.items);
            }
        } else |err| {
            failed += 1;
            if (ctx.failures.items.len == 0) {
                ctx.err("{s}", .{@errorName(err)});
            }
            printFailure(t.name, ctx.failures.items);
        }
    }

    std.debug.print("\n{d} tests: {d} passed, {d} failed\n", .{ tests.len, passed, failed });
    if (failed != 0) std.process.exit(1);
}

fn printFailure(name: []const u8, failures: []const []const u8) void {
    std.debug.print("FAIL {s}\n", .{name});
    for (failures) |msg| {
        std.debug.print("  --- {s}\n", .{msg});
    }
}
