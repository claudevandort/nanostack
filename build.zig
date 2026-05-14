const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const strip = b.option(bool, "strip", "Strip debug info (used by the perf bench)") orelse false;

    const httpz_dep = b.dependency("httpz", .{
        .target = target,
        .optimize = optimize,
    });
    const httpz_mod = httpz_dep.module("httpz");

    const xml_dep = b.dependency("xml", .{
        .target = target,
        .optimize = optimize,
    });
    const xml_mod = xml_dep.module("xml");

    // Library module: re-exports the modules used in tests so we have one
    // place to hang `zig build test` off.
    const lib_mod = b.addModule("nanostack", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
    });
    lib_mod.addImport("httpz", httpz_mod);
    lib_mod.addImport("xml", xml_mod);

    const exe = b.addExecutable(.{
        .name = "nanostack",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .strip = strip,
            .imports = &.{
                .{ .name = "nanostack", .module = lib_mod },
                .{ .name = "httpz", .module = httpz_mod },
                .{ .name = "xml", .module = xml_mod },
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

    // Perf gate. Runs bench/run.sh which builds ReleaseFast + strip itself,
    // then drives the Python bench. We don't depend on `exe` here because
    // the script reproduces the build to guarantee gated binary == measured.
    const bench_step = b.step("bench", "Run the perf gate (PRD §12)");
    const bench_cmd = b.addSystemCommand(&.{"bash"});
    bench_cmd.addFileArg(b.path("bench/run.sh"));
    if (b.args) |args| bench_cmd.addArgs(args);
    bench_step.dependOn(&bench_cmd.step);

    // Release build: ReleaseFast + stripped exe, installed under
    // `zig-out/release/<triple>/nanostack` so the release workflow can tar
    // each cross-target output directly. Combine with -Dtarget=<triple>
    // to produce one tarball per platform.
    const release_target_triple = b.fmt("{s}", .{target.result.linuxTriple(b.allocator) catch "host"});
    const release_exe = b.addExecutable(.{
        .name = "nanostack",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .strip = true,
            .imports = &.{
                .{ .name = "nanostack", .module = lib_mod },
                .{ .name = "httpz", .module = httpz_mod },
                .{ .name = "xml", .module = xml_mod },
            },
        }),
    });
    const release_install = b.addInstallArtifact(release_exe, .{
        .dest_dir = .{ .override = .{ .custom = b.fmt("release/{s}", .{release_target_triple}) } },
    });
    const release_step = b.step("release", "Cross-compile a stripped ReleaseFast binary (use with -Dtarget=…)");
    release_step.dependOn(&release_install.step);
}
