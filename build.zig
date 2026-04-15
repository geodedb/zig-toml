// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // thread-pool parallelism option
    const enable_tp = b.option(bool, "thread-pool", "Enable thread-pool-based parallelism") orelse true;

    // Get thread-pool dependency if enabled
    const tp_mod: ?*std.Build.Module = if (enable_tp) blk: {
        const tp_dep = b.dependency("thread_pool", .{
            .target = target,
            .optimize = optimize,
        });
        break :blk tp_dep.module("thread_pool");
    } else null;

    // Library module (for use as dependency)
    const toml_mod = b.addModule("toml", .{
        .root_source_file = b.path("src/toml.zig"),
        .target = target,
        .optimize = optimize,
    });
    if (tp_mod) |tm| toml_mod.addImport("thread_pool", tm);

    // Static library
    const lib_mod = b.createModule(.{
        .root_source_file = b.path("src/toml.zig"),
        .target = target,
        .optimize = optimize,
    });
    if (tp_mod) |tm| lib_mod.addImport("thread_pool", tm);
    const lib = b.addLibrary(.{
        .name = "zigtoml",
        .linkage = .static,
        .root_module = lib_mod,
    });
    b.installArtifact(lib);

    // CLI binary: toml-test-decoder
    const exe = b.addExecutable(.{
        .name = "toml-test-decoder",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/bin/toml_test_decoder.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "toml", .module = toml_mod },
            },
        }),
    });
    b.installArtifact(exe);

    // Unit tests
    const unit_test_mod = b.createModule(.{
        .root_source_file = b.path("src/toml.zig"),
        .target = target,
        .optimize = optimize,
    });
    if (tp_mod) |tm| unit_test_mod.addImport("thread_pool", tm);
    const unit_tests = b.addTest(.{
        .root_module = unit_test_mod,
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);

    // Acceptance tests
    const accept_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/accept.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "toml", .module = toml_mod },
            },
        }),
    });
    const run_accept_tests = b.addRunArtifact(accept_tests);

    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_unit_tests.step);
    test_step.dependOn(&run_accept_tests.step);

    // Check step (compile without running)
    const check = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/toml.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const check_step = b.step("check", "Check for compilation errors");
    check_step.dependOn(&check.step);

    // Run step for CLI
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the toml-test-decoder");
    run_step.dependOn(&run_cmd.step);
}
