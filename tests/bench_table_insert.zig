// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! Performance baseline for large-table parsing.
//!
//! This file is intentionally NOT wired into `zig build test`. It runs
//! under `zig build bench` and produces a wall-clock baseline that later
//! tasks must beat. The test asserts success and records the elapsed
//! nanoseconds via std.log so the number lands in CI logs and commit
//! artifacts.

const std = @import("std");
const toml = @import("toml");

const KEY_COUNT: usize = 10_000;

/// Monotonic nanoseconds since an unspecified epoch. Replacement for
/// `std.time.Timer`, which was removed in Zig 0.16.0 in favour of the new
/// `std.Io` clock API. The benchmark only needs elapsed ns so we call
/// `clock_gettime(CLOCK_MONOTONIC)` directly via std.posix and convert.
fn monotonicNs() u64 {
    var ts: std.posix.timespec = undefined;
    const rc = std.posix.system.clock_gettime(.MONOTONIC, &ts);
    std.debug.assert(std.posix.errno(rc) == .SUCCESS);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

fn buildInput(alloc: std.mem.Allocator) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(alloc);
    try buf.ensureTotalCapacity(alloc, KEY_COUNT * 16);
    var i: usize = 0;
    var line_buf: [64]u8 = undefined;
    while (i < KEY_COUNT) : (i += 1) {
        const line = try std.fmt.bufPrint(&line_buf, "k{d} = {d}\n", .{ i, i });
        try buf.appendSlice(alloc, line);
    }
    return buf.toOwnedSlice(alloc);
}

test "B-1 parse 10k top-level keys (baseline)" {
    const alloc = std.testing.allocator;
    const input = try buildInput(alloc);
    defer alloc.free(input);

    const t0 = monotonicNs();
    var doc = try toml.parse(alloc, input, .{});
    defer doc.deinit();
    const elapsed_ns = monotonicNs() - t0;

    // Sanity: the document must contain exactly KEY_COUNT top-level keys.
    // We intentionally read via the public get API so this exercises the
    // O(1) path after the hash-index refactor and the O(n) path today.
    var i: usize = 0;
    var hits: usize = 0;
    var name_buf: [32]u8 = undefined;
    while (i < KEY_COUNT) : (i += 1) {
        const name = try std.fmt.bufPrint(&name_buf, "k{d}", .{i});
        if (doc.root.get(name)) |v| {
            if (v.integer == @as(i64, @intCast(i))) hits += 1;
        }
    }
    try std.testing.expectEqual(KEY_COUNT, hits);

    std.log.warn("B-1 baseline: parse+lookup 10k keys = {d} ns", .{elapsed_ns});
}
