// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros

//! Bench: single table with 10 000 keys. Stresses table-key lookup +
//! insertion (P-1 / P-2 in docs/PERF_GAP_ANALYSIS.md). Complements
//! tests/bench_table_insert.zig's B-1 (which asserts a <200ms ceiling
//! under `zig build bench`); this file reports p50/p99/peak instead.
//!
//! Baseline (ReleaseFast, zig 0.16.0, Linux x86_64):
//!   p50_ns=4554356, p99_ns=6009725, peak=5777832 B
//! Reference-only; docs/PERFORMANCE.md holds the regression thresholds.

const std = @import("std");
const toml = @import("toml");
const common = @import("common.zig");
const inputs = @import("inputs.zig");

const KEY_COUNT: usize = 10_000;

var g_input: ?[]u8 = null;

fn work(alloc: std.mem.Allocator) !void {
    const doc = try toml.parse(alloc, g_input.?, .{});
    doc.deinit();
}

pub fn runAndPrint(alloc: std.mem.Allocator) !common.Stats {
    g_input = try inputs.generateWideTable(alloc, KEY_COUNT);
    defer {
        alloc.free(g_input.?);
        g_input = null;
    }
    const stats = try common.runBench("parse_wide_table", alloc, 3, 50, work);
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
