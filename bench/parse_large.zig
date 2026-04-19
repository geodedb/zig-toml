// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros

//! Bench: parse a 1 MiB synthetic TOML generated from a fixed seed.
//!
//! Baseline (ReleaseFast, zig 0.16.0, Linux x86_64):
//!   p50_ns=35951447, p99_ns=42345900, peak=32853194 B
//! Reference-only; docs/PERFORMANCE.md holds the regression thresholds.

const std = @import("std");
const toml = @import("toml");
const common = @import("common.zig");
const inputs = @import("inputs.zig");

const TARGET_BYTES: usize = 1 * 1024 * 1024;

// Generated once per process; reused across iterations. The input lives
// in the backing allocator, NOT in the counting allocator, so it isn't
// attributed to per-iteration memory accounting.
var g_input: ?[]u8 = null;

fn work(alloc: std.mem.Allocator) !void {
    const doc = try toml.parse(alloc, g_input.?, .{});
    doc.deinit();
}

pub fn runAndPrint(alloc: std.mem.Allocator) !common.Stats {
    g_input = try inputs.generateLarge(alloc, TARGET_BYTES);
    defer {
        alloc.free(g_input.?);
        g_input = null;
    }
    std.debug.assert(g_input.?.len >= TARGET_BYTES);

    const stats = try common.runBench("parse_large", alloc, 3, 50, work);
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
