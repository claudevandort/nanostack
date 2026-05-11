const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const httpz_dep = b.dependency("httpz", .{
        .target = target,
        .optimize = optimize,
    });
    const httpz_mod = httpz_dep.module("httpz");

    // Library module: re-exports the modules used in tests so we have one
    // place to hang `zig build test` off.
    const lib_mod = b.addModule("nanostack", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
    });
    lib_mod.addImport("httpz", httpz_mod);

    const exe = b.addExecutable(.{
        .name = "nanostack",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "nanostack", .module = lib_mod },
                .{ .name = "httpz", .module = httpz_mod },
            },
        }),
    });
    b.installArtifact(exe);

    const run_step = b.step("run", "Run nanostack");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    // Unit tests reachable from src/lib.zig.
    const lib_tests = b.addTest(.{ .root_module = lib_mod });
    const run_lib_tests = b.addRunArtifact(lib_tests);

    const exe_tests = b.addTest(.{ .root_module = exe.root_module });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_tests.step);
    test_step.dependOn(&run_exe_tests.step);
}
