const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // One translated header for SQLite and the libc calls Zig std lacks.
    const translate = b.addTranslateC(.{
        .root_source_file = b.path("third_party/c.h"),
        .target = target,
        .optimize = optimize,
    });
    translate.addIncludePath(b.path("third_party/sqlite"));
    const c = translate.createModule();

    const exe = b.addExecutable(.{
        .name = "ztd",
        .root_module = productModule(b, target, optimize, b.path("src/main.zig"), c),
    });
    b.installArtifact(exe);

    const run_step = b.step("run", "Run ztd");
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
    run_step.dependOn(&run_cmd.step);

    // src/tests.zig imports every module so its tests are compiled and run.
    const tests = b.addTest(.{
        .root_module = productModule(b, target, optimize, b.path("src/tests.zig"), c),
    });
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);

    // The conformance harnesses spawn the installed binary, so both steps
    // depend on the install artifact and pass its absolute path.
    const corpus = harnessStep(b, target, optimize, "corpus", "Replay the golden corpus", "test/corpus/main.zig", exe, c);
    _ = corpus;
    const integration = harnessStep(b, target, optimize, "integration", "Run the integration suite", "test/integration/main.zig", exe, null);
    _ = integration;
}

/// A test runner that drives the product binary through its CLI and MCP surface.
fn harnessStep(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
    name: []const u8,
    description: []const u8,
    root: []const u8,
    exe: *std.Build.Step.Compile,
    c: ?*std.Build.Module,
) *std.Build.Step {
    const runner = b.addExecutable(.{
        .name = name,
        .root_module = if (c) |sqlite| productModule(b, target, optimize, b.path(root), sqlite) else b.createModule(.{
            .root_source_file = b.path(root),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    // addRunArtifact passes the product binary as argv[1], so the harness
    // never has to guess where the build put it.
    const run = b.addRunArtifact(runner);
    run.addArtifactArg(exe);
    run.has_side_effects = true;
    const step = b.step(name, description);
    step.dependOn(&run.step);
    return step;
}

fn productModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
    root: std.Build.LazyPath,
    c: *std.Build.Module,
) *std.Build.Module {
    const mod = b.createModule(.{
        .root_source_file = root,
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .strip = optimize == .fast or optimize == .small,
        .imports = &.{.{ .name = "c", .module = c }},
    });
    mod.addCSourceFile(.{
        .file = b.path("third_party/sqlite/sqlite3.c"),
        .flags = &.{
            "-std=c99",
            "-DSQLITE_ENABLE_FTS5",
            "-DSQLITE_ENABLE_JSON1",
            "-DSQLITE_THREADSAFE=1",
        },
    });
    mod.addIncludePath(b.path("third_party/sqlite"));
    return mod;
}
