const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{
        .default_target = .{
            .cpu_arch = .x86_64,
            .os_tag = .windows,
            .abi = .msvc,
        },
    });
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSmall });

    const nats_dep = b.dependency("nats", .{
        .target = target,
        .optimize = optimize,
    });

    const user_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "nats", .module = nats_dep.module("nats") },
        },
    });

    // Build the XLL using the framework's helper
    const xll_build = @import("xll");
    const xll = xll_build.buildXll(b, .{
        .name = "zigxll-connectors-nats",
        .user_module = user_module,
        .target = target,
        .optimize = optimize,
    });

    // Install the XLL (rename .dll to .xll)
    const install_xll = b.addInstallFile(xll.getEmittedBin(), "lib/zigxll-connectors-nats.xll");
    b.getInstallStep().dependOn(&install_xll.step);

    // Native tests — pure logic that doesn't depend on xll or NATS.
    const test_step = b.step("test", "Run native unit tests");
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/value_interp.zig"),
        .target = b.graph.host,
    });
    const value_interp_tests = b.addTest(.{
        .root_module = test_mod,
    });
    test_step.dependOn(&b.addRunArtifact(value_interp_tests).step);
}
