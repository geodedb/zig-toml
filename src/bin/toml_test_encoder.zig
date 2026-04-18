// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! toml-test-encoder CLI
//!
//! Reads toml-test tagged JSON from stdin, outputs TOML to stdout.
//! On success: prints TOML to stdout, exits 0.
//! On failure: prints one-line diagnostic to stderr, exits 1.

const std = @import("std");
const builtin = @import("builtin");
const toml = @import("toml");

pub fn main(init: std.process.Init) !void {
    // In Debug builds use the DebugAllocator so the toml-test harness
    // surfaces any encoder-side leaks. In release builds swap to the SMP
    // allocator for the same reasons toml-test-decoder does: lower
    // per-allocation cost and no leak-tracking overhead that would
    // distort CLI runtime benchmarks (CWE-209 also applies -- DebugGPA
    // metadata must never leak into diagnostic output on release).
    var debug_gpa: std.heap.DebugAllocator(.{}) =
        if (builtin.mode == .Debug) .init else undefined;
    defer if (builtin.mode == .Debug) {
        _ = debug_gpa.deinit();
    };
    const allocator: std.mem.Allocator = if (builtin.mode == .Debug)
        debug_gpa.allocator()
    else
        std.heap.smp_allocator;

    const io = init.io;

    const stdin = std.Io.File.stdin();
    const stdout = std.Io.File.stdout();
    const stderr = std.Io.File.stderr();

    var stdin_buf: [4096]u8 = undefined;
    var stdout_buf: [4096]u8 = undefined;
    var stderr_buf: [256]u8 = undefined;

    var stdin_reader = stdin.readerStreaming(io, &stdin_buf);
    var stdout_writer = stdout.writerStreaming(io, &stdout_buf);
    var stderr_writer = stderr.writerStreaming(io, &stderr_buf);

    // Read all of stdin (16 MiB cap).
    const input = stdin_reader.interface.allocRemaining(allocator, .limited(16 * 1024 * 1024)) catch |e| {
        stderr_writer.interface.print("error: failed to read stdin: {}\n", .{e}) catch {};
        stderr_writer.interface.flush() catch {};
        std.process.exit(1);
    };
    defer allocator.free(input);

    // Main pipeline is wired in Task 19; for now the scaffold just
    // drains stdin so the allocator plumbing and I/O layout can be
    // exercised end-to-end without touching the TOML encoder yet.
    _ = toml;

    stdout_writer.interface.flush() catch {};
}
