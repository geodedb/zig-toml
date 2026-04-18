// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! Tagged JSON Output Example
//!
//! Demonstrates the toml-test compatible JSON output:
//! - Converting parsed TOML to tagged JSON format
//! - Understanding the tagged JSON structure
//! - Using the output with toml-test validation

const std = @import("std");
const toml = @import("toml");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const stdout = std.io.getStdOut().writer();

    try stdout.print("=== Tagged JSON Output Example ===\n\n", .{});

    // Example 1: Simple key-value pairs
    try stdout.print("Input 1: Simple values\n", .{});
    try outputTaggedJson(allocator, stdout,
        \\name = "example"
        \\count = 42
        \\enabled = true
        \\pi = 3.14159
    );

    // Example 2: Nested tables
    try stdout.print("\nInput 2: Nested tables\n", .{});
    try outputTaggedJson(allocator, stdout,
        \\[server]
        \\host = "localhost"
        \\port = 8080
        \\
        \\[database]
        \\url = "postgres://localhost/db"
    );

    // Example 3: Arrays
    try stdout.print("\nInput 3: Arrays\n", .{});
    try outputTaggedJson(allocator, stdout,
        \\numbers = [1, 2, 3]
        \\names = ["alice", "bob"]
    );

    // Example 4: Datetime types
    try stdout.print("\nInput 4: Datetime types\n", .{});
    try outputTaggedJson(allocator, stdout,
        \\datetime = 2024-01-15T10:30:00Z
        \\datetime_local = 2024-01-15T10:30:00
        \\date = 2024-01-15
        \\time = 10:30:00.123
    );

    // Example 5: Array of tables
    try stdout.print("\nInput 5: Array of tables\n", .{});
    try outputTaggedJson(allocator, stdout,
        \\[[items]]
        \\name = "first"
        \\value = 1
        \\
        \\[[items]]
        \\name = "second"
        \\value = 2
    );

    try stdout.print("\n--- Tagged JSON Format Explanation ---\n", .{});
    try stdout.print("The tagged JSON format wraps each value with type information:\n", .{});
    try stdout.print("  - {{\"type\":\"string\",\"value\":\"text\"}}\n", .{});
    try stdout.print("  - {{\"type\":\"integer\",\"value\":\"42\"}}\n", .{});
    try stdout.print("  - {{\"type\":\"float\",\"value\":\"3.14\"}}\n", .{});
    try stdout.print("  - {{\"type\":\"bool\",\"value\":\"true\"}}\n", .{});
    try stdout.print("  - {{\"type\":\"datetime\",\"value\":\"2024-01-15T10:30:00Z\"}}\n", .{});
    try stdout.print("  - {{\"type\":\"datetime-local\",\"value\":\"2024-01-15T10:30:00\"}}\n", .{});
    try stdout.print("  - {{\"type\":\"date-local\",\"value\":\"2024-01-15\"}}\n", .{});
    try stdout.print("  - {{\"type\":\"time-local\",\"value\":\"10:30:00\"}}\n", .{});
    try stdout.print("\nTables are represented as plain JSON objects.\n", .{});
    try stdout.print("Arrays are represented as JSON arrays.\n", .{});
    try stdout.print("Keys are sorted lexicographically for deterministic output.\n", .{});
}

fn outputTaggedJson(allocator: std.mem.Allocator, writer: anytype, input: []const u8) !void {
    // Show input
    try writer.print("```toml\n{s}\n```\n\n", .{input});

    // Parse and output
    const doc = try toml.parse(allocator, input, .{});
    defer doc.deinit();

    try writer.print("Output:\n```json\n", .{});
    try toml.writeTaggedJson(doc, writer);
    try writer.print("```\n", .{});
}
