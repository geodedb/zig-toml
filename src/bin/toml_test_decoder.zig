// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! toml-test-decoder CLI
//!
//! Reads TOML from stdin, outputs tagged JSON to stdout.
//! On success: prints tagged JSON to stdout, exits 0.
//! On failure: prints one-line diagnostic to stderr, exits 1.

const std = @import("std");
const toml = @import("toml");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Setup buffered I/O
    const stdin = std.fs.File.stdin();
    const stdout = std.fs.File.stdout();
    const stderr = std.fs.File.stderr();

    var stdout_buf: [4096]u8 = undefined;
    var stderr_buf: [256]u8 = undefined;

    var stdout_writer = stdout.writer(&stdout_buf);
    var stderr_writer = stderr.writer(&stderr_buf);

    // Read all of stdin
    const input = stdin.readToEndAlloc(allocator, 16 * 1024 * 1024) catch |e| {
        stderr_writer.interface.print("error: failed to read stdin: {}\n", .{e}) catch {};
        stderr_writer.interface.flush() catch {};
        std.process.exit(1);
    };
    defer allocator.free(input);

    // Parse TOML
    const result = toml.parseWithError(allocator, input, .{});

    switch (result) {
        .ok => |*doc_const| {
            var doc = @constCast(doc_const);
            defer doc.deinit();

            // Write tagged JSON to stdout
            toml.writeTaggedJson(doc, &stdout_writer.interface) catch |e| {
                stderr_writer.interface.print("error: failed to write JSON: {}\n", .{e}) catch {};
                stderr_writer.interface.flush() catch {};
                std.process.exit(1);
            };
            stdout_writer.interface.flush() catch {};
        },
        .err => |parse_error| {
            stderr_writer.interface.print("error at line {d}, column {d}: {s}\n", .{
                parse_error.line,
                parse_error.column,
                parse_error.message,
            }) catch {};
            stderr_writer.interface.flush() catch {};
            std.process.exit(1);
        },
    }
}
