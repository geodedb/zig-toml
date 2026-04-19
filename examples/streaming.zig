// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros

//! Streaming TOML parsing example.
//!
//! Demonstrates `toml.parseStream`, which reads directly from any
//! `std.Io.Reader` (files, sockets, pipes) instead of requiring the
//! caller to materialise the full document in memory first.
//!
//! Usage:
//!     zig build run-example-streaming -- path/to/config.toml
//!     cat config.toml | zig build run-example-streaming
//!
//! The example falls back to reading from stdin when no path is given,
//! so it works as both a file parser and a pipe filter.
//!
//! Zig 0.16 note: this file uses the `std.Io.Reader`/`std.Io.Writer`
//! "interface" pattern; see `src/bin/toml_test_decoder.zig` for the
//! production form this example mirrors.

const std = @import("std");
const toml = @import("toml");

pub fn main(init: std.process.Init) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const io = init.io;

    // Collect argv. Skip argv[0] (program name).
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var read_buf: [4096]u8 = undefined;

    // Dispatch on whether a path was provided.
    if (args.len >= 2) {
        // File path -> open file -> stream into parseStream.
        const path = args[1];
        var file = try std.fs.cwd().openFile(path, .{});
        defer file.close();

        var file_reader = file.readerStreaming(io, &read_buf);
        const doc = try toml.parseStream(allocator, &file_reader.interface, .{});
        defer doc.deinit();

        try printSummary(io, doc, path);
    } else {
        // No path -> drain stdin.
        const stdin = std.Io.File.stdin();
        var stdin_reader = stdin.readerStreaming(io, &read_buf);
        const doc = try toml.parseStream(allocator, &stdin_reader.interface, .{});
        defer doc.deinit();

        try printSummary(io, doc, "<stdin>");
    }
}

fn printSummary(io: std.Io, doc: *const toml.Document, source: []const u8) !void {
    const stdout = std.Io.File.stdout();
    var out_buf: [1024]u8 = undefined;
    var stdout_writer = stdout.writerStreaming(io, &out_buf);
    const w = &stdout_writer.interface;

    try w.print("Parsed {s}: {d} top-level entries.\n", .{ source, doc.root.table.map.count() });

    var it = doc.root.table.map.iterator();
    while (it.next()) |entry| {
        const kind: []const u8 = switch (entry.value_ptr.*.*) {
            .table => "table",
            .array => "array",
            .string => "string",
            .integer => "integer",
            .float => "float",
            .bool => "bool",
            .datetime => "datetime",
            .datetime_local => "datetime-local",
            .date_local => "date-local",
            .time_local => "time-local",
        };
        try w.print("  {s}: {s}\n", .{ entry.key_ptr.*, kind });
    }
    try w.flush();
}
