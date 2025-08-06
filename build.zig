const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const thc = b.addModule("tardy_http_client", .{
        .root_source_file = b.path("src/Client.zig"),
        .target = target,
        .optimize = optimize,
    });

    const tardy = b.dependency("tardy", .{
        .target = target,
        .optimize = optimize,
    }).module("tardy");

    thc.addImport("tardy", tardy);

    add_example(b, "basic", target, optimize, thc);
    add_example(b, "multi_fetch", target, optimize, thc);
    add_example(b, "url_scraper", target, optimize, thc);

    const test_runner = std.Build.Step.Compile.TestRunner{ .path = b.path("test_runner.zig"), .mode = .simple };
    const tests = b.addTest(.{
        .name = "all_tests",
        .root_source_file = b.path("./src/tests.zig"),
        .optimize = optimize,
        .test_runner = test_runner,
    });
    tests.root_module.addImport("tardy", tardy);

    const test_artifact = b.addRunArtifact(tests);
    test_artifact.step.dependOn(&tests.step);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&test_artifact.step);
}

fn add_example(
    b: *std.Build,
    name: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.Mode,
    thc_module: *std.Build.Module,
) void {
    const example = b.addExecutable(.{
        .name = name,
        .root_source_file = b.path(b.fmt("./examples/{s}/main.zig", .{name})),
        .target = target,
        .optimize = optimize,
        .strip = false,
    });

    const tardy = b.dependency("tardy", .{
        .target = target,
        .optimize = optimize,
    }).module("tardy");

    example.root_module.addImport("tardy_http_client", thc_module);
    example.root_module.addImport("tardy", tardy);

    const install_artifact = b.addInstallArtifact(example, .{});
    b.getInstallStep().dependOn(&install_artifact.step);

    const build_step = b.step(b.fmt("{s}", .{name}), b.fmt("Build thc example ({s})", .{name}));
    build_step.dependOn(&install_artifact.step);

    const run_artifact = b.addRunArtifact(example);
    if (b.args) |args| {
        run_artifact.addArgs(args);
    }
    run_artifact.step.dependOn(&install_artifact.step);

    const run_step = b.step(b.fmt("run_{s}", .{name}), b.fmt("Run thc example ({s})", .{name}));
    run_step.dependOn(&install_artifact.step);
    run_step.dependOn(&run_artifact.step);
}
