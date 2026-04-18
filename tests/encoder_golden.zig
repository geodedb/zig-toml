// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! Golden-output tests for the encoder. These assert the exact bytes
//! emitted for representative inputs, providing a contract against
//! accidental format regressions.

const std = @import("std");
const toml = @import("toml");

fn encodeString(alloc: std.mem.Allocator, src: []const u8, opts: toml.EncodeOptions) ![]u8 {
    const doc = try toml.parse(alloc, src, .{});
    defer doc.deinit();
    var aw: std.Io.Writer.Allocating = .init(alloc);
    errdefer aw.deinit();
    try toml.encode(doc, &aw.writer, opts);
    return aw.toOwnedSlice();
}

test "sort_keys=true produces identical output for reordered input" {
    const a = "b = 1\na = 2\n";
    const b = "a = 2\nb = 1\n";

    const out_a = try encodeString(std.testing.allocator, a, .{ .sort_keys = true });
    defer std.testing.allocator.free(out_a);
    const out_b = try encodeString(std.testing.allocator, b, .{ .sort_keys = true });
    defer std.testing.allocator.free(out_b);

    try std.testing.expectEqualStrings(out_a, out_b);
    try std.testing.expectEqualStrings("a = 2\nb = 1\n", out_a);
}

test "sort_keys=false preserves input order" {
    const src = "b = 1\na = 2\n";
    const out = try encodeString(std.testing.allocator, src, .{ .sort_keys = false });
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("b = 1\na = 2\n", out);
}

test "sort_keys=true applies inside inline tables" {
    const src = "p = { y = 2, x = 1 }\n";
    const out = try encodeString(std.testing.allocator, src, .{ .sort_keys = true });
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("p = { x = 1, y = 2 }\n", out);
}

test "sort_keys=true applies inside header tables" {
    const src = "[s]\nz = 1\na = 2\n";
    const out = try encodeString(std.testing.allocator, src, .{ .sort_keys = true });
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("[s]\na = 2\nz = 1\n", out);
}

test "inline array wraps when length > inline_threshold" {
    const src = "nums = [1, 2, 3, 4, 5]\n";
    const out = try encodeString(std.testing.allocator, src, .{
        .sort_keys = true,
        .indent = 2,
        .inline_threshold = 3,
    });
    defer std.testing.allocator.free(out);

    const expected =
        "nums = [\n" ++
        "  1,\n" ++
        "  2,\n" ++
        "  3,\n" ++
        "  4,\n" ++
        "  5,\n" ++
        "]\n";
    try std.testing.expectEqualStrings(expected, out);
}

test "inline array stays on one line when <= threshold" {
    const src = "nums = [1, 2, 3]\n";
    const out = try encodeString(std.testing.allocator, src, .{
        .sort_keys = true,
        .indent = 2,
        .inline_threshold = 3,
    });
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("nums = [1, 2, 3]\n", out);
}

test "indent=0 disables wrapping regardless of size" {
    const src = "nums = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]\n";
    const out = try encodeString(std.testing.allocator, src, .{
        .sort_keys = true,
        .indent = 0,
        .inline_threshold = 2,
    });
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings(
        "nums = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]\n",
        out,
    );
}
