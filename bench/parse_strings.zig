// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros

//! Bench: 2 000 escape-heavy basic + multiline strings. Exercises the
//! lexer's escape-sequence decoder.
//!
//! Baseline (ReleaseFast, zig 0.16.0, Linux x86_64):
//!   p50_ns=1428568, p99_ns=1745899, peak=1178042 B
//! Reference-only; docs/PERFORMANCE.md holds the regression thresholds.

const std = @import("std");
const toml = @import("toml");
const common = @import("common.zig");
const inputs = @import("inputs.zig");

const STRING_COUNT: usize = 2_000;

var g_input: ?[]u8 = null;

fn work(alloc: std.mem.Allocator) !void {
    const doc = try toml.parse(alloc, g_input.?, .{});
    doc.deinit();
}

pub fn runAndPrint(alloc: std.mem.Allocator) !common.Stats {
    g_input = try inputs.generateStrings(alloc, STRING_COUNT);
    defer {
        alloc.free(g_input.?);
        g_input = null;
    }
    const stats = try common.runBench("parse_strings", alloc, 5, 100, work);
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
