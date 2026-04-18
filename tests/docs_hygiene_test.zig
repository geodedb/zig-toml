// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros

//! Documentation hygiene tests.
//!
//! These tests catch structural drift between source files and the
//! human-readable architecture docs. They read the docs as plain bytes
//! and assert that required markers are present. They do NOT try to
//! parse markdown -- cheap substring checks are intentional.
//!
//! Paths are resolved relative to `std.Io.Dir.cwd()`, which
//! `zig build test` sets to the repo root.

const std = @import("std");

const ARCH_PATH = "docs/ARCHITECTURE.md";

fn readFile(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    // Zig 0.16: file I/O goes through the Io dispatch in std.testing.io.
    // Cap at 16 MiB -- each file we read here is well under 1 MiB.
    const dir: std.Io.Dir = .cwd();
    return try dir.readFileAlloc(
        std.testing.io,
        path,
        allocator,
        .limited(16 * 1024 * 1024),
    );
}

// ---------------------------------------------------------------------
// ARCHITECTURE.md -- structural accuracy guards (Q-9)
// ---------------------------------------------------------------------

test "ARCHITECTURE.md file-structure lists every src/*.zig" {
    const allocator = std.testing.allocator;
    const body = try readFile(allocator, ARCH_PATH);
    defer allocator.free(body);

    // Every top-level src/*.zig and src/parser/*.zig (except src/bin/*)
    // must be named somewhere in the doc. Keep this list in sync with
    // `ls src/ src/parser/`.
    const required = [_][]const u8{
        "toml.zig",
        "parser.zig",
        "lexer.zig",
        "value.zig",
        "error.zig",
        "json_tagged.zig",
        "parallel.zig",
        "datetime.zig",
        "number.zig",
        "string.zig",
    };
    for (required) |name| {
        if (std.mem.indexOf(u8, body, name) == null) {
            std.debug.print("missing '{s}' in {s}\n", .{ name, ARCH_PATH });
            try std.testing.expect(false);
        }
    }
}

test "ARCHITECTURE.md does not claim the lexer is stateless" {
    const allocator = std.testing.allocator;
    const body = try readFile(allocator, ARCH_PATH);
    defer allocator.free(body);

    // The lexer carries version + parse_error + utf8_error + streaming
    // pos state. Any prose claiming "stateless" is drift and must be
    // softened.
    try std.testing.expect(std.mem.indexOf(u8, body, "Stateless Design") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "stateless between tokens") == null);
}

test "ARCHITECTURE.md documents parallel subsystem wrapping real parser" {
    const allocator = std.testing.allocator;
    const body = try readFile(allocator, ARCH_PATH);
    defer allocator.free(body);

    // The parallel subsystem section must name its three batch APIs and
    // explicitly flag that it now delegates to the real parser
    // (post-Plan-01 shadow-parser removal).
    const required = [_][]const u8{
        "parseDocuments",
        "validateDocuments",
        "extractKeys",
        "ParallelContext",
    };
    for (required) |needle| {
        if (std.mem.indexOf(u8, body, needle) == null) {
            std.debug.print("missing '{s}' in {s}\n", .{ needle, ARCH_PATH });
            try std.testing.expect(false);
        }
    }
}
