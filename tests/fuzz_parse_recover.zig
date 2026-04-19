// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros

//! Coverage-guided fuzz harness for `toml.parseRecover`.
//!
//! S-15: the original `fuzz_parse.zig` covers only `parseWithError`.
//! Recovery mode walks a distinct code path (error accumulation loop in
//! `parser/recovery.zig`, separate arena teardown on partial-doc
//! return), so pathological inputs can hit logic the default parser
//! never exercises. This harness feeds random bytes through
//! `parseRecover` and asserts the "no panic, no UB, no leak" property.

const std = @import("std");
const toml = @import("toml");

fn testRecoverOne(_: void, smith: *std.testing.Smith) !void {
    @disableInstrumentation();

    var buf: [4096]u8 = undefined;
    const len = smith.sliceWeightedBytes(buf[0..], &.{
        .rangeAtMost(u8, 0x00, 0xff, 1),
        .rangeAtMost(u8, 0x20, 0x7e, 4),
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

    const alloc = std.testing.allocator;
    var result = toml.parseRecover(alloc, input, .{}) catch return;
    defer result.deinit(alloc);
    // The error slice and partial document are both expected shapes;
    // no assertion needed -- the property under test is the absence of
    // panics, UB, and leaks.
}

test "fuzz parseRecover does not crash" {
    try std.testing.fuzz({}, testRecoverOne, .{});
}
