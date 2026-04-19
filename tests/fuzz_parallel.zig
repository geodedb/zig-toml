// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros

//! Coverage-guided fuzz harness for `toml.parallel.parseDocuments`.
//!
//! S-15: the parallel entry point dispatches work onto a shared thread
//! pool and reconstitutes per-document Documents through a distinct
//! batch/callback path. Fuzzing a handful of chunks at once exercises
//! the pool allocator, per-document arena teardown, error-code u8
//! narrowing, and the empty-input / single-input thresholds.

const std = @import("std");
const toml = @import("toml");

const parallel = toml.parallel;

fn testParallelOne(_: void, smith: *std.testing.Smith) !void {
    @disableInstrumentation();

    var buf: [4096]u8 = undefined;
    const len = smith.sliceWeightedBytes(buf[0..], &.{
        .rangeAtMost(u8, 0x00, 0xff, 1),
        .rangeAtMost(u8, 0x20, 0x7e, 4),
        .value(u8, '=', 4),
        .value(u8, '"', 3),
        .value(u8, '[', 2),
        .value(u8, '.', 2),
        .value(u8, '\n', 3),
    });
    const input = buf[0..len];

    // Split into up to 5 chunks on newline so we hit the >=4-threshold
    // pool path as well as the sequential fallback under short inputs.
    var inputs: [8][]const u8 = undefined;
    var count: usize = 0;
    var it = std.mem.splitScalar(u8, input, '\n');
    while (it.next()) |chunk| {
        if (count >= inputs.len) break;
        inputs[count] = chunk;
        count += 1;
    }

    const alloc = std.testing.allocator;
    var results: [8]parallel.ParseResult = undefined;
    for (results[0..count]) |*r| r.* = .{};
    parallel.parseDocuments(alloc, inputs[0..count], results[0..count]);
    for (results[0..count]) |*r| if (r.doc) |d| d.deinit();
}

test "fuzz parallel.parseDocuments does not crash" {
    try std.testing.fuzz({}, testParallelOne, .{});
}
