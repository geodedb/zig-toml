// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros

//! Bench: parse a ~1 KiB handwritten config. Exercises the common path
//! (key/value, nested tables, arrays of tables, inline tables).
//!
//! Baselines recorded in docs/PERFORMANCE.md are the source of truth.
//!
//! Baseline (Debug, zig 0.16.0, Linux x86_64):
//!   p50_ns=268666, p99_ns=516136, peak=23084 B
//! Baseline (ReleaseFast):
//!   p50_ns=90357, p99_ns=130819, peak=23180 B
//! Reference-only; docs/PERFORMANCE.md holds the regression thresholds.

const std = @import("std");
const toml = @import("toml");
const common = @import("common.zig");
const inputs = @import("inputs.zig");

const input_bytes = inputs.small_config;

fn work(alloc: std.mem.Allocator) !void {
    const doc = try toml.parse(alloc, input_bytes, .{});
    doc.deinit();
}

pub fn runAndPrint(alloc: std.mem.Allocator) !common.Stats {
    const stats = try common.runBench(
        "parse_small",
        alloc,
        // warmup iterations
        100,
        // measured iterations
        10_000,
        work,
    );
    stats.printHuman();
    return stats;
}

pub fn main(init: std.process.Init) !void {
    var gpa: std.heap.DebugAllocator(.{
        .enable_memory_limit = true,
        .retain_metadata = true,
    }) = .init;
    defer _ = gpa.deinit();

    const stats = try runAndPrint(gpa.allocator());

    var out_buf: [256]u8 = undefined;
    const line = try stats.formatCsv(&out_buf);

    const stdout = std.Io.File.stdout();
    var sink_buf: [256]u8 = undefined;
    var sw = stdout.writerStreaming(init.io, &sink_buf);
    try sw.interface.writeAll(line);
    try sw.interface.flush();
}
