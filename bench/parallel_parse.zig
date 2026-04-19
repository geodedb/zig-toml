// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros

//! Bench: parallel.parseDocuments across N in {4, 16, 64, 256}.
//! Each input is the small handwritten config; we measure total wall
//! time to fan out + join.
//!
//! Baseline (ReleaseFast, zig 0.16.0, Linux x86_64):
//!   N=4:   p50_ns=182157,  p99_ns=294163,  peak=92720 B
//!   N=16:  p50_ns=647156,  p99_ns=991154,  peak=370880 B
//!   N=64:  p50_ns=2442457, p99_ns=2914510, peak=1483520 B
//!   N=256: p50_ns=6233317, p99_ns=6768032, peak=5934080 B
//! Reference-only; docs/PERFORMANCE.md holds the regression thresholds.

const std = @import("std");
const toml = @import("toml");
const common = @import("common.zig");
const inputs = @import("inputs.zig");

const N_SIZES = [_]usize{ 4, 16, 64, 256 };

// runAndPrint / main share the per-size body below. parseDocuments mutates
// the caller-owned results slice; every successful ParseResult carries a
// *Document we must deinit. The per-N context is stashed in globals so the
// work closure stays matching the `fn(Allocator) anyerror!void` signature.
const Ctx = struct {
    inputs: []const []const u8,
    results: []toml.parallel.ParseResult,
};

var g_ctx: Ctx = undefined;

fn work(alloc: std.mem.Allocator) !void {
    toml.parallel.parseDocuments(alloc, g_ctx.inputs, g_ctx.results);
    for (g_ctx.results) |r| {
        if (!r.success) return error.ParseFailed;
        if (r.doc) |d| d.deinit();
    }
    // Null out doc pointers so the caller's slice does not carry stale
    // pointers between iterations — parseDocuments overwrites entries,
    // but a partial failure mid-batch could leave unreaped docs.
    for (g_ctx.results) |*r| r.doc = null;
}

/// Run the full N_SIZES sweep. Returns the stats for the last N so the
/// orchestrator has a representative row; each individual N also prints a
/// human summary to stderr via runBench.
pub fn runAndPrint(alloc: std.mem.Allocator) !common.Stats {
    var last: common.Stats = undefined;
    for (N_SIZES) |n| {
        const in_slices = try alloc.alloc([]const u8, n);
        defer alloc.free(in_slices);
        for (in_slices) |*s| s.* = inputs.small_config;

        const results = try alloc.alloc(toml.parallel.ParseResult, n);
        defer alloc.free(results);
        for (results) |*r| r.* = .{};

        g_ctx = .{ .inputs = in_slices, .results = results };

        const nm = try std.fmt.allocPrint(alloc, "parallel_parse_n{d}", .{n});
        defer alloc.free(nm);

        var stats = try common.runBench(
            nm,
            alloc,
            3,
            if (n >= 64) 50 else 200,
            work,
        );
        stats.name = nm;
        stats.printHuman();
        last = stats;
    }
    // last.name points at freed memory; overwrite with a stable literal so
    // callers (the bench-all orchestrator summary row) see something sane.
    last.name = "parallel_parse";
    return last;
}

pub fn main(init: std.process.Init) !void {
    var gpa: std.heap.DebugAllocator(.{
        .enable_memory_limit = true,
        .retain_metadata = true,
    }) = .init;
    defer _ = gpa.deinit();

    const alloc = gpa.allocator();

    const stdout = std.Io.File.stdout();
    var sink_buf: [512]u8 = undefined;
    var sw = stdout.writerStreaming(init.io, &sink_buf);

    // main duplicates the per-size loop so every N emits its own CSV row.
    for (N_SIZES) |n| {
        const in_slices = try alloc.alloc([]const u8, n);
        defer alloc.free(in_slices);
        for (in_slices) |*s| s.* = inputs.small_config;

        const results = try alloc.alloc(toml.parallel.ParseResult, n);
        defer alloc.free(results);
        for (results) |*r| r.* = .{};

        g_ctx = .{ .inputs = in_slices, .results = results };

        const nm = try std.fmt.allocPrint(alloc, "parallel_parse_n{d}", .{n});
        defer alloc.free(nm);

        var stats = try common.runBench(
            nm,
            alloc,
            3,
            if (n >= 64) 50 else 200,
            work,
        );
        stats.name = nm;
        stats.printHuman();

        var csv_buf: [256]u8 = undefined;
        const line = try stats.formatCsv(&csv_buf);
        try sw.interface.writeAll(line);
    }
    try sw.interface.flush();
}
