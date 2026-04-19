// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros

//! Coverage-guided fuzz harness for `toml.parseStream`.
//!
//! S-15: `parseStream` adds a reader-drain step in front of the parse
//! core (`reader.allocRemaining` with `max_bytes` cap). Random bytes
//! exercise the drain bookkeeping, the buffer-free path, and the
//! StreamTooLong edge even when the inner parser path is otherwise
//! covered by `fuzz_parse.zig`.

const std = @import("std");
const toml = @import("toml");

fn testStreamOne(_: void, smith: *std.testing.Smith) !void {
    @disableInstrumentation();

    var buf: [4096]u8 = undefined;
    const len = smith.sliceWeightedBytes(buf[0..], &.{
        .rangeAtMost(u8, 0x00, 0xff, 1),
        .rangeAtMost(u8, 0x20, 0x7e, 4),
        .value(u8, '=', 4),
        .value(u8, '"', 3),
        .value(u8, '[', 2),
        .value(u8, ']', 2),
        .value(u8, '.', 2),
        .value(u8, '\n', 3),
        .value(u8, '#', 1),
    });
    const input = buf[0..len];

    const alloc = std.testing.allocator;
    var reader = std.Io.Reader.fixed(input);
    const doc = toml.parseStream(alloc, &reader, .{}) catch return;
    defer doc.deinit();
}

test "fuzz parseStream does not crash" {
    try std.testing.fuzz({}, testStreamOne, .{});
}
