const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const enable_integration = b.option(bool, "enable_integration", "Enable integration tests") orelse false;

    const root_mod = b.addModule("zigscan_mod", .{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "zigscan",
        .root_module = root_mod,
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run zigscan");
    run_step.dependOn(&run_cmd.step);

    // Unit tests
    const tests_mod = b.addModule("zigscan_tests", .{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    const unit_tests = b.addTest(.{ .root_module = tests_mod });
    const test_run = b.addRunArtifact(unit_tests);
    if (enable_integration) {
        test_run.addArg("--enable-integration");
    }
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&test_run.step);
}
