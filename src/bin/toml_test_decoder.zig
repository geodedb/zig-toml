// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! toml-test-decoder CLI
//!
//! Reads TOML from stdin, outputs tagged JSON to stdout.
//! On success: prints tagged JSON to stdout, exits 0.
//! On failure: prints one-line diagnostic to stderr, exits 1.

const std = @import("std");
const builtin = @import("builtin");
const toml = @import("toml");

pub fn main(init: std.process.Init) !void {
    // In Debug builds use the DebugAllocator so the toml-test harness
    // surfaces any parser leaks. In release builds (ReleaseSafe/Fast/Small)
    // swap to the SMP allocator, which is an order of magnitude cheaper
    // per-allocation and has no leak-tracking overhead that would distort
    // runtime benchmarks or CLI startup latency. It also avoids leaking
    // allocation metadata into diagnostic output (CWE-209).
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

    // Setup buffered I/O
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

    // Parse TOML
    const result = toml.parseWithError(allocator, input, .{});

    switch (result) {
        .ok => |*doc_const| {
            var doc = @constCast(doc_const);
            defer doc.deinit();

            // Write tagged JSON to stdout
            toml.writeTaggedJson(doc, &stdout_writer.interface) catch |e| {
                stderr_writer.interface.print("error: failed to write JSON: {}\n", .{e}) catch {};
                stderr_writer.interface.flush() catch {};
                std.process.exit(1);
            };
            stdout_writer.interface.flush() catch {};
        },
        .err => |parse_error| {
            stderr_writer.interface.print("error at line {d}, column {d}: {s}\n", .{
                parse_error.line,
                parse_error.column,
                parse_error.message,
            }) catch {};
            stderr_writer.interface.flush() catch {};
            std.process.exit(1);
        },
    }
}
