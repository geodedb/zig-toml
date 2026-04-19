// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros

//! Bench: 64-deep nested inline tables + arrays. Exercises recursion +
//! stack frames in the value parser. Each level costs two parser
//! recursion frames (parseValue + parseArray/parseInlineTable), so we
//! override max_depth to 256 to accommodate DEPTH=64.
//!
//! Baseline (ReleaseFast, zig 0.16.0, Linux x86_64):
//!   p50_ns=150357, p99_ns=482091, peak=107196 B
//! Reference-only; docs/PERFORMANCE.md holds the regression thresholds.

const std = @import("std");
const toml = @import("toml");
const common = @import("common.zig");
const inputs = @import("inputs.zig");

const DEPTH: usize = 64;

var g_input: ?[]u8 = null;

// Each alternating { n = / [ level costs 2 parser recursion frames
// (parseValue + parseArray/parseInlineTable), so a DEPTH=64 input needs
// max_depth >= 128*2 headroom. 256 is a safe cap.
const opts: toml.ParseOptions = .{ .max_depth = 256 };

fn work(alloc: std.mem.Allocator) !void {
    const doc = try toml.parse(alloc, g_input.?, opts);
    doc.deinit();
}

pub fn runAndPrint(alloc: std.mem.Allocator) !common.Stats {
    g_input = try inputs.generateDeepNest(alloc, DEPTH);
    defer {
        alloc.free(g_input.?);
        g_input = null;
    }
    const stats = try common.runBench("parse_deep_nest", alloc, 100, 5_000, work);
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
