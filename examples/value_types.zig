// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! TOML Value Types Example
//!
//! Demonstrates all TOML value types supported by the parser:
//! - Strings (basic, literal, multiline)
//! - Integers (decimal, hex, octal, binary)
//! - Floats (regular, inf, nan)
//! - Booleans
//! - Datetime types (offset datetime, local datetime, local date, local time)
//! - Arrays
//! - Tables (standard, inline, array of tables)

const std = @import("std");
const toml = @import("toml");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const stdout = std.io.getStdOut().writer();

    const input =
        \\# =============================================================================
        \\# TOML Value Types Demonstration
        \\# =============================================================================
        \\
        \\# --- Strings ---
        \\basic_string = "Hello, World!"
        \\literal_string = 'C:\Users\name\file.txt'
        \\escaped_string = "Tab:\t Newline:\n Quote:\""
        \\multiline_basic = """
        \\Roses are red
        \\Violets are blue"""
        \\multiline_literal = '''
        \\No escape processing here: \n \t'''
        \\
        \\# --- Integers ---
        \\decimal = 42
        \\negative = -17
        \\positive = +99
        \\with_underscores = 1_000_000
        \\hex = 0xDEADBEEF
        \\octal = 0o755
        \\binary = 0b11010110
        \\
        \\# --- Floats ---
        \\pi = 3.14159
        \\negative_float = -0.01
        \\exponent = 5e+22
        \\both = 1.0e-5
        \\infinity = inf
        \\neg_infinity = -inf
        \\not_a_number = nan
        \\
        \\# --- Booleans ---
        \\enabled = true
        \\disabled = false
        \\
        \\# --- Datetime Types ---
        \\datetime_utc = 2024-01-15T10:30:00Z
        \\datetime_offset = 2024-01-15T10:30:00-05:00
        \\datetime_local = 2024-01-15T10:30:00
        \\date_local = 2024-01-15
        \\time_local = 10:30:00
        \\time_with_fraction = 10:30:00.123456789
        \\
        \\# --- Arrays ---
        \\numbers = [1, 2, 3, 4, 5]
        \\strings = ["red", "green", "blue"]
        \\mixed_types = [1, "two", 3.0, true]
        \\nested = [[1, 2], [3, 4], [5, 6]]
        \\
        \\# --- Inline Tables ---
        \\point = { x = 10, y = 20 }
        \\person = { name = "Alice", age = 30 }
        \\
        \\# --- Standard Tables ---
        \\[server]
        \\host = "localhost"
        \\port = 8080
        \\
        \\[server.ssl]
        \\enabled = true
        \\cert = "/path/to/cert.pem"
        \\
        \\# --- Array of Tables ---
        \\[[products]]
        \\name = "Hammer"
        \\price = 9.99
        \\
        \\[[products]]
        \\name = "Nail"
        \\price = 0.05
        \\
        \\[[products]]
        \\name = "Screwdriver"
        \\price = 12.50
    ;

    var doc = try toml.parse(allocator, input, .{});
    defer doc.deinit();

    try stdout.print("=== TOML Value Types Example ===\n\n", .{});

    // Strings
    try stdout.print("--- Strings ---\n", .{});
    try printValue(stdout, "basic_string", doc.root.get("basic_string"));
    try printValue(stdout, "literal_string", doc.root.get("literal_string"));
    try printValue(stdout, "escaped_string", doc.root.get("escaped_string"));
    try printValue(stdout, "multiline_basic", doc.root.get("multiline_basic"));
    try printValue(stdout, "multiline_literal", doc.root.get("multiline_literal"));

    // Integers
    try stdout.print("\n--- Integers ---\n", .{});
    try printValue(stdout, "decimal", doc.root.get("decimal"));
    try printValue(stdout, "negative", doc.root.get("negative"));
    try printValue(stdout, "with_underscores", doc.root.get("with_underscores"));
    try printValue(stdout, "hex", doc.root.get("hex"));
    try printValue(stdout, "octal", doc.root.get("octal"));
    try printValue(stdout, "binary", doc.root.get("binary"));

    // Floats
    try stdout.print("\n--- Floats ---\n", .{});
    try printValue(stdout, "pi", doc.root.get("pi"));
    try printValue(stdout, "exponent", doc.root.get("exponent"));
    try printValue(stdout, "infinity", doc.root.get("infinity"));
    try printValue(stdout, "not_a_number", doc.root.get("not_a_number"));

    // Booleans
    try stdout.print("\n--- Booleans ---\n", .{});
    try printValue(stdout, "enabled", doc.root.get("enabled"));
    try printValue(stdout, "disabled", doc.root.get("disabled"));

    // Datetime types
    try stdout.print("\n--- Datetime Types ---\n", .{});
    try printValue(stdout, "datetime_utc", doc.root.get("datetime_utc"));
    try printValue(stdout, "datetime_offset", doc.root.get("datetime_offset"));
    try printValue(stdout, "datetime_local", doc.root.get("datetime_local"));
    try printValue(stdout, "date_local", doc.root.get("date_local"));
    try printValue(stdout, "time_local", doc.root.get("time_local"));

    // Arrays
    try stdout.print("\n--- Arrays ---\n", .{});
    if (doc.root.get("numbers")) |arr| {
        try stdout.print("numbers: ", .{});
        try printArray(stdout, arr);
        try stdout.print("\n", .{});
    }
    if (doc.root.get("strings")) |arr| {
        try stdout.print("strings: ", .{});
        try printArray(stdout, arr);
        try stdout.print("\n", .{});
    }
    if (doc.root.get("nested")) |arr| {
        try stdout.print("nested: ", .{});
        try printArray(stdout, arr);
        try stdout.print("\n", .{});
    }

    // Inline tables
    try stdout.print("\n--- Inline Tables ---\n", .{});
    if (doc.root.get("point")) |point| {
        try stdout.print("point: {{ x = {d}, y = {d} }}\n", .{
            point.get("x").?.integer,
            point.get("y").?.integer,
        });
    }

    // Standard tables
    try stdout.print("\n--- Standard Tables ---\n", .{});
    if (doc.root.get("server")) |server| {
        try stdout.print("[server]\n", .{});
        if (server.get("host")) |host| {
            try stdout.print("  host = \"{s}\"\n", .{host.string});
        }
        if (server.get("port")) |port| {
            try stdout.print("  port = {d}\n", .{port.integer});
        }
        if (server.get("ssl")) |ssl| {
            try stdout.print("  [server.ssl]\n", .{});
            if (ssl.get("enabled")) |enabled| {
                try stdout.print("    enabled = {}\n", .{enabled.bool});
            }
        }
    }

    // Array of tables
    try stdout.print("\n--- Array of Tables ---\n", .{});
    if (doc.root.get("products")) |products| {
        for (products.array.items, 0..) |product, i| {
            try stdout.print("[[products]] ({d})\n", .{i});
            if (product.get("name")) |name| {
                try stdout.print("  name = \"{s}\"\n", .{name.string});
            }
            if (product.get("price")) |price| {
                try stdout.print("  price = {d:.2}\n", .{price.float});
            }
        }
    }
}

fn printValue(writer: anytype, key: []const u8, value: ?*const toml.Value) !void {
    if (value) |v| {
        switch (v.*) {
            .string => |s| try writer.print("{s} = \"{s}\"\n", .{ key, s }),
            .integer => |i| try writer.print("{s} = {d}\n", .{ key, i }),
            .float => |f| {
                if (std.math.isNan(f)) {
                    try writer.print("{s} = nan\n", .{key});
                } else if (std.math.isInf(f)) {
                    if (f < 0) {
                        try writer.print("{s} = -inf\n", .{key});
                    } else {
                        try writer.print("{s} = inf\n", .{key});
                    }
                } else {
                    try writer.print("{s} = {d}\n", .{ key, f });
                }
            },
            .bool => |b| try writer.print("{s} = {}\n", .{ key, b }),
            .datetime => |dt| try writer.print("{s} = {d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z\n", .{
                key,
                dt.year,
                dt.month,
                dt.day,
                dt.hour,
                dt.minute,
                dt.second,
            }),
            .datetime_local => |dt| try writer.print("{s} = {d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}\n", .{
                key,
                dt.year,
                dt.month,
                dt.day,
                dt.hour,
                dt.minute,
                dt.second,
            }),
            .date_local => |d| try writer.print("{s} = {d:0>4}-{d:0>2}-{d:0>2}\n", .{
                key,
                d.year,
                d.month,
                d.day,
            }),
            .time_local => |t| try writer.print("{s} = {d:0>2}:{d:0>2}:{d:0>2}\n", .{
                key,
                t.hour,
                t.minute,
                t.second,
            }),
            .table => try writer.print("{s} = <table>\n", .{key}),
            .array => try writer.print("{s} = <array>\n", .{key}),
        }
    } else {
        try writer.print("{s} = <not found>\n", .{key});
    }
}

fn printArray(writer: anytype, arr: *const toml.Value) !void {
    try writer.print("[", .{});
    for (arr.array.items, 0..) |item, i| {
        if (i > 0) try writer.print(", ", .{});
        switch (item.*) {
            .integer => |n| try writer.print("{d}", .{n}),
            .float => |f| try writer.print("{d}", .{f}),
            .string => |s| try writer.print("\"{s}\"", .{s}),
            .bool => |b| try writer.print("{}", .{b}),
            .array => try printArray(writer, item),
            else => try writer.print("...", .{}),
        }
    }
    try writer.print("]", .{});
}
