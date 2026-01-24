// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! Error Handling Example
//!
//! Demonstrates proper error handling when parsing TOML:
//! - Using parseWithError for detailed diagnostics
//! - Handling different error codes
//! - Displaying user-friendly error messages

const std = @import("std");
const toml = @import("toml");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const stdout = std.io.getStdOut().writer();

    try stdout.print("=== TOML Error Handling Example ===\n\n", .{});

    // Example 1: Duplicate key error
    try stdout.print("Test 1: Duplicate key\n", .{});
    try parseAndReport(allocator, stdout,
        \\name = "first"
        \\name = "second"
    );

    // Example 2: Invalid escape sequence
    try stdout.print("\nTest 2: Invalid escape sequence\n", .{});
    try parseAndReport(allocator, stdout,
        \\message = "hello\q"
    );

    // Example 3: Unterminated string
    try stdout.print("\nTest 3: Unterminated string\n", .{});
    try parseAndReport(allocator, stdout,
        \\value = "incomplete
    );

    // Example 4: Type mismatch (redefining table as value)
    try stdout.print("\nTest 4: Key redefines non-table\n", .{});
    try parseAndReport(allocator, stdout,
        \\[section]
        \\key = "value"
        \\[section.key]
        \\other = "data"
    );

    // Example 5: Table already defined
    try stdout.print("\nTest 5: Table redefinition\n", .{});
    try parseAndReport(allocator, stdout,
        \\[table]
        \\a = 1
        \\[table]
        \\b = 2
    );

    // Example 6: Invalid number format
    try stdout.print("\nTest 6: Invalid number (leading zeros)\n", .{});
    try parseAndReport(allocator, stdout,
        \\number = 007
    );

    // Example 7: Invalid datetime
    try stdout.print("\nTest 7: Invalid datetime\n", .{});
    try parseAndReport(allocator, stdout,
        \\dt = 2024-13-45T99:99:99Z
    );

    // Example 8: Version-specific error (v1.0 mode)
    try stdout.print("\nTest 8: TOML v1.0 mode - trailing comma in inline table\n", .{});
    try parseAndReportWithVersion(allocator, stdout,
        \\point = { x = 1, y = 2, }
    , .v1_0_0);

    // Example 9: Successful parse
    try stdout.print("\nTest 9: Valid TOML\n", .{});
    try parseAndReport(allocator, stdout,
        \\[config]
        \\name = "valid"
        \\count = 42
    );
}

fn parseAndReport(allocator: std.mem.Allocator, writer: anytype, input: []const u8) !void {
    try parseAndReportWithVersion(allocator, writer, input, .v1_1_0);
}

fn parseAndReportWithVersion(
    allocator: std.mem.Allocator,
    writer: anytype,
    input: []const u8,
    version: toml.TomlVersion,
) !void {
    const result = toml.parseWithError(allocator, input, .{ .version = version });

    switch (result) {
        .ok => |*doc| {
            var d = @constCast(doc);
            defer d.deinit();
            try writer.print("  [OK] Parsed successfully\n", .{});
        },
        .err => |e| {
            try writer.print("  [ERROR] Line {d}, Column {d}\n", .{ e.line, e.column });
            try writer.print("  Code: {s}\n", .{@tagName(e.code)});
            try writer.print("  Message: {s}\n", .{e.message});

            // Show context from input
            var line_num: u32 = 1;
            var line_start: usize = 0;
            var i: usize = 0;

            while (i < input.len and line_num < e.line) : (i += 1) {
                if (input[i] == '\n') {
                    line_num += 1;
                    line_start = i + 1;
                }
            }

            // Find line end
            var line_end = line_start;
            while (line_end < input.len and input[line_end] != '\n') {
                line_end += 1;
            }

            if (line_end > line_start) {
                const line_content = input[line_start..line_end];
                try writer.print("  Source: {s}\n", .{line_content});

                // Print caret pointing to error column
                try writer.print("          ", .{});
                var col: u32 = 1;
                while (col < e.column) : (col += 1) {
                    try writer.print(" ", .{});
                }
                try writer.print("^\n", .{});
            }

            // Provide helpful suggestions based on error code
            const suggestion = getErrorSuggestion(e.code);
            if (suggestion.len > 0) {
                try writer.print("  Suggestion: {s}\n", .{suggestion});
            }
        },
    }
}

fn getErrorSuggestion(code: toml.ErrorCode) []const u8 {
    return switch (code) {
        .DuplicateKey => "Remove or rename one of the duplicate keys",
        .InvalidEscape => "Use valid escape sequences: \\t \\n \\r \\\\ \\\" \\uXXXX \\UXXXXXXXX",
        .UnterminatedString => "Add closing quote to the string",
        .KeyRedefinesNonTable => "Cannot use a non-table value as a table path",
        .TableRedefined => "Each table can only be defined once",
        .InvalidNumber => "Check number format (no leading zeros, valid underscores)",
        .InvalidDateTime => "Use valid ISO 8601 format: YYYY-MM-DDTHH:MM:SSZ",
        .InlineTableTrailingCommaNotAllowed => "Remove trailing comma or use TOML v1.1 mode",
        .InlineTableNewlineNotAllowed => "Remove newlines from inline table or use TOML v1.1 mode",
        .InvalidUtf8 => "Ensure the input is valid UTF-8 encoded text",
        else => "",
    };
}
