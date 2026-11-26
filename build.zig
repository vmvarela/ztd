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
