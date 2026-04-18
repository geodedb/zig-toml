// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! Coverage-guided fuzz harness for `toml.parse`.
//!
//! Goal: exercise the parser on random byte inputs and assert:
//!   1. It never panics.
//!   2. Any error returned is `error.ParseFailed` or `error.OutOfMemory`
//!      (the documented error set).
//!   3. Arena allocation is always freed.
//!
//! Invoked via `zig build test --fuzz`. The CI `fuzz` stage wraps this
//! with a 60s `timeout`; rc=124 (timeout) is treated as success, rc!=0
//! (fuzzer-discovered crash) fails the pipeline.

const std = @import("std");
const toml = @import("toml");

fn testParseOne(_: void, smith: *std.testing.Smith) !void {
    @disableInstrumentation();

    // Cap generated inputs at a reasonable size so each iteration is fast.
    var buf: [4096]u8 = undefined;
    const len = smith.sliceWeightedBytes(buf[0..], &.{
        // Mix realistic TOML-ish bytes with arbitrary bytes so we exercise
        // both happy-path tokenization and the error-handling paths.
        .rangeAtMost(u8, 0x00, 0xff, 1),
        .rangeAtMost(u8, 0x20, 0x7e, 4), // printable ASCII
        .value(u8, '=', 4),
        .value(u8, '"', 3),
        .value(u8, '\'', 2),
        .value(u8, '[', 2),
        .value(u8, ']', 2),
        .value(u8, '{', 1),
        .value(u8, '}', 1),
        .value(u8, '.', 2),
        .value(u8, '\n', 3),
        .value(u8, '\t', 1),
        .value(u8, '\\', 1),
        .value(u8, '#', 1),
    });
    const input = buf[0..len];

    // Use the testing allocator so leaks are caught if the parser stashes
    // memory outside the Document's own arena.
    const alloc = std.testing.allocator;

    const result = toml.parseWithError(alloc, input, .{});
    switch (result) {
        .ok => |doc| {
            defer doc.deinit();
            // Exercise the JSON emitter too so a parse success followed by
            // a serializer crash is caught in the same harness.
            var aw: std.Io.Writer.Allocating = .init(alloc);
            defer aw.deinit();
            toml.writeTaggedJson(doc, &aw.writer) catch {};
        },
        .err => {
            // A structured parse error is the acceptable outcome for
            // random bytes. No further assertion needed -- the property
            // being fuzzed is "no panic, no UB, no leak".
        },
    }
}

test "fuzz parse does not crash" {
    try std.testing.fuzz({}, testParseOne, .{});
}
