// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros

//! Run every benchmark in sequence and print a single formatted table.
//! Intended for humans. CI should prefer the per-benchmark steps so a
//! single benchmark failure does not hide the others.

const std = @import("std");
const common = @import("common.zig");

const parse_small = @import("parse_small.zig");
const parse_large = @import("parse_large.zig");
const parse_wide_table = @import("parse_wide_table.zig");
const parse_deep_nest = @import("parse_deep_nest.zig");
const parse_strings = @import("parse_strings.zig");
const parse_datetime = @import("parse_datetime.zig");
const parallel_parse = @import("parallel_parse.zig");

const Entry = struct {
    name: []const u8,
    run: *const fn (alloc: std.mem.Allocator) anyerror!common.Stats,
};

pub fn main(init: std.process.Init) !void {
    var gpa: std.heap.DebugAllocator(.{
        .enable_memory_limit = true,
        .retain_metadata = true,
    }) = .init;
    defer _ = gpa.deinit();
    const a = gpa.allocator();

    const entries = [_]Entry{
        .{ .name = "parse_small", .run = parse_small.runAndPrint },
        .{ .name = "parse_large", .run = parse_large.runAndPrint },
        .{ .name = "parse_wide_table", .run = parse_wide_table.runAndPrint },
        .{ .name = "parse_deep_nest", .run = parse_deep_nest.runAndPrint },
        .{ .name = "parse_strings", .run = parse_strings.runAndPrint },
        .{ .name = "parse_datetime", .run = parse_datetime.runAndPrint },
        // parallel_parse.runAndPrint prints all N sizes to stderr and
        // returns the final (n=256) sample for the summary row.
        .{ .name = "parallel_parse", .run = parallel_parse.runAndPrint },
    };

    var all_stats: std.ArrayList(common.Stats) = .empty;
    defer all_stats.deinit(a);

    const stdout = std.Io.File.stdout();
    var sink_buf: [512]u8 = undefined;
    var sw = stdout.writerStreaming(init.io, &sink_buf);

    // CSV header on stderr so pipelines that redirect stdout still have
    // a column key.
    std.debug.print(
        "name,iters,ops_per_sec,p50_ns,p99_ns,bytes_peak,bytes_total\n",
        .{},
    );
    for (entries) |e| {
        const s = try e.run(a);
        try all_stats.append(a, s);
        var csv_buf: [256]u8 = undefined;
        const line = try s.formatCsv(&csv_buf);
        try sw.interface.writeAll(line);
    }
    try sw.interface.flush();

    // Human-readable table at the end.
    std.debug.print("\n=== bench summary ===\n", .{});
    for (all_stats.items) |s| s.printHuman();
}
