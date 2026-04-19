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

    // CLI binary: toml-test-encoder (inverse of toml-test-decoder; reads
    // tagged-JSON stdin and writes TOML to stdout).
    const enc_exe = b.addExecutable(.{
        .name = "toml-test-encoder",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/bin/toml_test_encoder.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "toml", .module = toml_mod },
            },
        }),
    });
    b.installArtifact(enc_exe);

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

    // Streaming parser acceptance tests (GAP-0016).
    const streaming_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/streaming.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "toml", .module = toml_mod },
            },
        }),
    });
    const run_streaming_tests = b.addRunArtifact(streaming_tests);

    // Encoder round-trip tests -- parse(encode(parse(x))) must yield
    // the same tagged-JSON projection as parse(x) for every corpus case.
    const encoder_roundtrip_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/encoder_roundtrip.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "toml", .module = toml_mod },
            },
        }),
    });
    const run_encoder_roundtrip_tests = b.addRunArtifact(encoder_roundtrip_tests);

    // Encoder golden-output tests -- byte-exact contract for
    // sort_keys determinism and wrapped-array pretty-printing.
    const encoder_golden_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/encoder_golden.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "toml", .module = toml_mod },
            },
        }),
    });
    const run_encoder_golden_tests = b.addRunArtifact(encoder_golden_tests);

    // Differential tests -- walks tests/testdata/toml-test/ corpus.
    const differential_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/differential.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "toml", .module = toml_mod },
            },
        }),
    });
    const run_differential_tests = b.addRunArtifact(differential_tests);

    // Documentation hygiene tests -- guard against drift between source
    // files and ARCHITECTURE.md / CHANGELOG.md / PUBLIC_API.md. See
    // tests/docs_hygiene_test.zig for the full rationale.
    const docs_hygiene_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/docs_hygiene_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_docs_hygiene = b.addRunArtifact(docs_hygiene_tests);

    // Fuzz harness -- exercises toml.parse with random bytes via
    // std.testing.fuzz. Under `zig build test` this runs a single smoke
    // iteration so regressions that panic on well-formed inputs still fail
    // CI. Under `zig build test --fuzz` the Zig runner enters fuzzing mode
    // and the CI `fuzz` stage wraps it with a 60s timeout.
    const fuzz_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/fuzz_parse.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "toml", .module = toml_mod },
            },
        }),
    });
    const run_fuzz_tests = b.addRunArtifact(fuzz_tests);

    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_unit_tests.step);
    test_step.dependOn(&run_accept_tests.step);
    test_step.dependOn(&run_streaming_tests.step);
    test_step.dependOn(&run_encoder_roundtrip_tests.step);
    test_step.dependOn(&run_encoder_golden_tests.step);
    test_step.dependOn(&run_differential_tests.step);
    test_step.dependOn(&run_fuzz_tests.step);
    test_step.dependOn(&run_docs_hygiene.step);

    // Benchmark harness (opt-in; not part of `test`).
    const bench_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/bench_table_insert.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "toml", .module = toml_mod },
            },
        }),
    });
    const run_bench_tests = b.addRunArtifact(bench_tests);
    const bench_step = b.step("bench", "Run performance benchmarks (not part of test)");
    bench_step.dependOn(&run_bench_tests.step);

    // Check step (compile without running)
    const check_mod = b.createModule(.{
        .root_source_file = b.path("src/toml.zig"),
        .target = target,
        .optimize = optimize,
    });
    if (tp_mod) |tm| check_mod.addImport("thread_pool", tm);
    const check = b.addTest(.{
        .root_module = check_mod,
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

    // ------------------------------------------------------------------
    // Benchmark suite (GAP-0011).
    //
    // Each benchmark lives in bench/<name>.zig and is wired as its own
    // build step `zig build bench-<name>`. The pre-existing `bench` step
    // (tests/bench_table_insert.zig) stays wired above; here we add the
    // richer `bench/` tree. A separate `zig build bench-all` orchestrator
    // runs every benchmark in a single process and prints a summary
    // table. `-Dbench-filter=<name>` filters the per-benchmark loop.
    // ------------------------------------------------------------------
    const bench_filter = b.option(
        []const u8,
        "bench-filter",
        "Only run benchmarks whose short name contains this substring",
    );

    const BenchSpec = struct {
        name: []const u8, // short name, e.g. "parse_small"
        root: []const u8, // "bench/parse_small.zig"
    };

    const bench_specs = [_]BenchSpec{
        .{ .name = "parse_small", .root = "bench/parse_small.zig" },
        .{ .name = "parse_large", .root = "bench/parse_large.zig" },
    };

    for (bench_specs) |spec| {
        if (bench_filter) |f| {
            if (std.mem.indexOf(u8, spec.name, f) == null) continue;
        }
        const mod = b.createModule(.{
            .root_source_file = b.path(spec.root),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "toml", .module = toml_mod },
            },
        });
        if (tp_mod) |tm| mod.addImport("thread_pool", tm);

        const exe_bench = b.addExecutable(.{
            .name = b.fmt("bench-{s}", .{spec.name}),
            .root_module = mod,
        });
        const run_bench = b.addRunArtifact(exe_bench);
        run_bench.step.dependOn(b.getInstallStep());

        const single_step = b.step(
            b.fmt("bench-{s}", .{spec.name}),
            b.fmt("Run the {s} benchmark", .{spec.name}),
        );
        single_step.dependOn(&run_bench.step);
        bench_step.dependOn(&run_bench.step);
    }
}
