// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros

//! Lint Example
//!
//! Reads a TOML file path from `argv[1]` and prints every syntax error it
//! finds using the recovery-mode parser (`toml.parseRecover`). Useful as
//! a sanity check for editor integrations and CI lint jobs -- unlike
//! `toml.parse`, `parseRecover` does not bail on the first error but
//! reports ALL errors in the file in one pass. The partial document that
//! parsed cleanly is also available via `result.document` for tooling
//! that wants to surface both diagnostics and recoverable data.

const std = @import("std");
const toml = @import("toml");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const stdout = std.io.getStdOut().writer();
    const stderr = std.io.getStdErr().writer();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        try stderr.print("usage: lint_toml <file.toml>\n", .{});
        return error.BadUsage;
    }

    const path = args[1];
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    const bytes = try file.readToEndAlloc(allocator, 16 * 1024 * 1024);
    defer allocator.free(bytes);

    var result = try toml.parseRecover(allocator, bytes, .{
        .recovery_mode = .recover,
        .max_recovery_errors = 100,
    });
    defer result.deinit(allocator);

    if (result.errors.len == 0) {
        try stdout.print("{s}: OK\n", .{path});
        return;
    }

    try stdout.print("{s}: {d} error(s)\n", .{ path, result.errors.len });
    for (result.errors) |e| {
        try stdout.print("  line {d}, col {d}: [{s}] {s}\n", .{
            e.line,
            e.column,
            @tagName(e.code),
            e.message,
        });
    }
}
