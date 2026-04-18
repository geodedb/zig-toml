// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! Basic TOML Parsing Example
//!
//! Demonstrates fundamental TOML parsing operations including:
//! - Parsing a TOML document from a string
//! - Accessing values by key
//! - Using path-based lookups
//! - Iterating over table entries

const std = @import("std");
const toml = @import("toml");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const stdout = std.io.getStdOut().writer();

    // Sample TOML configuration
    const input =
        \\# Application Configuration
        \\title = "My Application"
        \\version = "1.0.0"
        \\debug = true
        \\
        \\[server]
        \\host = "localhost"
        \\port = 8080
        \\timeout_ms = 30000
        \\
        \\[database]
        \\url = "postgres://localhost:5432/mydb"
        \\max_connections = 100
        \\
        \\[logging]
        \\level = "info"
        \\format = "json"
    ;

    // Parse the TOML document
    const doc = try toml.parse(allocator, input, .{});
    defer doc.deinit();

    try stdout.print("=== Basic TOML Parsing Example ===\n\n", .{});

    // Access top-level values
    if (doc.root.get("title")) |title| {
        try stdout.print("Title: {s}\n", .{title.string});
    }

    if (doc.root.get("version")) |version| {
        try stdout.print("Version: {s}\n", .{version.string});
    }

    if (doc.root.get("debug")) |debug| {
        try stdout.print("Debug mode: {}\n", .{debug.bool});
    }

    try stdout.print("\n", .{});

    // Access nested values using table.get()
    if (doc.root.get("server")) |server| {
        try stdout.print("Server Configuration:\n", .{});
        if (server.get("host")) |host| {
            try stdout.print("  Host: {s}\n", .{host.string});
        }
        if (server.get("port")) |port| {
            try stdout.print("  Port: {d}\n", .{port.integer});
        }
        if (server.get("timeout_ms")) |timeout| {
            try stdout.print("  Timeout: {d}ms\n", .{timeout.integer});
        }
    }

    try stdout.print("\n", .{});

    // Use path-based lookup for deep access
    const db_url_path = &[_][]const u8{ "database", "url" };
    if (doc.getPath(db_url_path)) |url| {
        try stdout.print("Database URL (via path): {s}\n", .{url.string});
    }

    const log_level_path = &[_][]const u8{ "logging", "level" };
    if (doc.getPath(log_level_path)) |level| {
        try stdout.print("Log Level (via path): {s}\n", .{level.string});
    }

    try stdout.print("\n", .{});

    // Iterate over table entries
    try stdout.print("All top-level keys:\n", .{});
    var it = toml.value_mod.tableIterator(doc.root);
    while (it.next()) |entry| {
        const type_name = switch (entry.value.*) {
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
        try stdout.print("  {s}: {s}\n", .{ entry.key, type_name });
    }
}
