// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros

//! Acceptance tests for toml.parseStream (GAP-0016).

const std = @import("std");
const toml = @import("toml");

// Helper: parse the same bytes two ways and compare their tagged-JSON
// renderings. Tagged JSON is deterministic (keys sorted), so string
// equality is a strong structural equivalence check.
fn expectParseEquivalence(allocator: std.mem.Allocator, bytes: []const u8) !void {
    const base = try toml.parse(allocator, bytes, .{});
    defer base.deinit();

    var fixed: std.Io.Reader = .fixed(bytes);
    const streamed = try toml.parseStream(allocator, &fixed, .{});
    defer streamed.deinit();

    var base_aw: std.Io.Writer.Allocating = .init(allocator);
    defer base_aw.deinit();
    try toml.writeTaggedJson(base, &base_aw.writer);

    var streamed_aw: std.Io.Writer.Allocating = .init(allocator);
    defer streamed_aw.deinit();
    try toml.writeTaggedJson(streamed, &streamed_aw.writer);

    try std.testing.expectEqualStrings(base_aw.written(), streamed_aw.written());
}

test "parseStream: empty input produces an empty document" {
    var fixed: std.Io.Reader = .fixed("");
    const doc = try toml.parseStream(std.testing.allocator, &fixed, .{});
    defer doc.deinit();

    try std.testing.expectEqual(@as(usize, 0), doc.root.table.map.count());
}

test "parseStream: representative fixture matches parse" {
    const input =
        \\# Comment survives streaming
        \\title = "zigtoml"
        \\ints = [1, 2, 3]
        \\floats = [1.5, -0.25, 1e3]
        \\
        \\[server]
        \\host = "localhost"
        \\port = 8080
        \\
        \\[[products]]
        \\name = "Hammer"
        \\
        \\[[products]]
        \\name = "Nail"
    ;
    try expectParseEquivalence(std.testing.allocator, input);
}

// Slow-drip reader: yields exactly `chunk_size` bytes per stream() call.
// Exercises the boundary handling of the underlying allocRemaining loop
// without needing any on-disk file.
const ChunkedReader = struct {
    src: []const u8,
    consumed: usize = 0,
    chunk_size: usize,
    interface: std.Io.Reader,

    fn init(src: []const u8, chunk_size: usize, buf: []u8) ChunkedReader {
        return .{
            .src = src,
            .chunk_size = chunk_size,
            .interface = .{
                .vtable = &vtable,
                .buffer = buf,
                .seek = 0,
                .end = 0,
            },
        };
    }

    const vtable: std.Io.Reader.VTable = .{
        .stream = stream,
    };

    fn stream(
        r: *std.Io.Reader,
        w: *std.Io.Writer,
        limit: std.Io.Limit,
    ) std.Io.Reader.StreamError!usize {
        const self: *ChunkedReader = @fieldParentPtr("interface", r);
        if (self.consumed >= self.src.len) return error.EndOfStream;
        const remaining = self.src[self.consumed..];
        const want = @min(self.chunk_size, @min(remaining.len, @intFromEnum(limit)));
        try w.writeAll(remaining[0..want]);
        self.consumed += want;
        return want;
    }
};

test "parseStream: ~1 MiB synthetic input in 1024-byte chunks matches parse" {
    const allocator = std.testing.allocator;

    // Build a ~1 MiB TOML document that stays well within the default
    // max_bytes (16 MiB) and is cheap to generate: 20,000 repeats of
    // a small entry.
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    const entries: usize = 20_000;
    try buf.ensureTotalCapacity(allocator, entries * 64);
    for (0..entries) |i| {
        try buf.appendSlice(allocator, "[[items]]\n");
        var tmp: [48]u8 = undefined;
        const line = try std.fmt.bufPrint(&tmp, "index = {d}\nname = \"row-{d}\"\n", .{ i, i });
        try buf.appendSlice(allocator, line);
    }

    // Sanity: we are actually testing the regime we claim to test.
    try std.testing.expect(buf.items.len >= 700 * 1024);
    try std.testing.expect(buf.items.len <= 4 * 1024 * 1024);

    const base = try toml.parse(allocator, buf.items, .{});
    defer base.deinit();

    var rbuf: [4096]u8 = undefined;
    var chunked = ChunkedReader.init(buf.items, 1024, &rbuf);
    const streamed = try toml.parseStream(allocator, &chunked.interface, .{});
    defer streamed.deinit();

    // Same structural check as the small fixture.
    var base_aw: std.Io.Writer.Allocating = .init(allocator);
    defer base_aw.deinit();
    try toml.writeTaggedJson(base, &base_aw.writer);

    var streamed_aw: std.Io.Writer.Allocating = .init(allocator);
    defer streamed_aw.deinit();
    try toml.writeTaggedJson(streamed, &streamed_aw.writer);

    try std.testing.expectEqualStrings(base_aw.written(), streamed_aw.written());
}

test "parseStream: input larger than max_bytes is rejected" {
    // 4 KiB of valid TOML, capped at 1 KiB. The reader-side drain must
    // fail with StreamTooLong before we ever reach the parser.
    const allocator = std.testing.allocator;

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    for (0..200) |i| {
        var tmp: [32]u8 = undefined;
        const line = try std.fmt.bufPrint(&tmp, "k{d} = {d}\n", .{ i, i });
        try buf.appendSlice(allocator, line);
    }
    try std.testing.expect(buf.items.len > 1024);

    var fixed: std.Io.Reader = .fixed(buf.items);
    const result = toml.parseStream(
        allocator,
        &fixed,
        .{ .max_bytes = 1024 },
    );
    try std.testing.expectError(error.StreamTooLong, result);
}
