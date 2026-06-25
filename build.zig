const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const constants_mod = b.createModule(.{ .root_source_file = b.path("src/constants.zig") });
    const protocol_mod = b.createModule(.{ .root_source_file = b.path("src/protocol/request.zig") });
    protocol_mod.addImport("constants", constants_mod);

    // Main njackd server
    const exe = b.addExecutable(.{
        .name = "njackd",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    exe.linkSystemLibrary("asound");
    exe.linkSystemLibrary("libudev");
    exe.linkLibC();
    exe.root_module.addImport("constants", constants_mod);

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run njackd");
    run_step.dependOn(&run_cmd.step);

    // Test client
    const test_client = b.addExecutable(.{
        .name = "test_client",
        .root_source_file = b.path("test_client.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_client.root_module.addImport("constants", constants_mod);
    test_client.root_module.addImport("protocol", protocol_mod);
    test_client.linkLibC();
    b.installArtifact(test_client);

    const test_client_step = b.step("test-client", "Build test client");
    test_client_step.dependOn(&test_client.step);

    // Unit tests
    const exe_unit_tests = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);
}
