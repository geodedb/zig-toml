// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros

//! Bench: 5 000 datetime assignments mixing offset/local datetime, local
//! date, local time. Exercises the datetime parser.
//!
//! Baseline (ReleaseFast, zig 0.16.0, Linux x86_64):
//!   p50_ns=2662148, p99_ns=3094139, peak=2645792 B
//! Reference-only; docs/PERFORMANCE.md holds the regression thresholds.

const std = @import("std");
const toml = @import("toml");
const common = @import("common.zig");
const inputs = @import("inputs.zig");

const DT_COUNT: usize = 5_000;

var g_input: ?[]u8 = null;

fn work(alloc: std.mem.Allocator) !void {
    const doc = try toml.parse(alloc, g_input.?, .{});
    doc.deinit();
}

pub fn runAndPrint(alloc: std.mem.Allocator) !common.Stats {
    g_input = try inputs.generateDateTimes(alloc, DT_COUNT);
    defer {
        alloc.free(g_input.?);
        g_input = null;
    }
    const stats = try common.runBench("parse_datetime", alloc, 5, 100, work);
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
