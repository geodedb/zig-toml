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
const CHANGELOG_PATH = "CHANGELOG.md";
const TOML_ZIG_PATH = "src/toml.zig";
const PUBLIC_API_PATH = "docs/PUBLIC_API.md";

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
        "encoder.zig",
        "encoder_cli.zig",
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

// ---------------------------------------------------------------------
// CHANGELOG.md -- reconciliation guards (Q-11)
// ---------------------------------------------------------------------

test "CHANGELOG mentions every released tag" {
    const allocator = std.testing.allocator;
    const body = try readFile(allocator, CHANGELOG_PATH);
    defer allocator.free(body);

    // Every git tag in this repo must have a heading in the changelog.
    // Keep this array in sync with `git tag -l`. 0.2.0 is a documented
    // in-flight feature target (not yet tagged); 0.1.2/0.1.3/0.1.4 are the
    // released sibling-dependency patch bumps (Q-NEW-1 reconciliation).
    const required_tags = [_][]const u8{
        "[0.1.0]",
        "[0.1.1]",
        "[0.1.2]",
        "[0.1.3]",
        "[0.1.4]",
        "[0.2.0]",
    };
    for (required_tags) |tag| {
        if (std.mem.indexOf(u8, body, tag) == null) {
            std.debug.print("missing '{s}' in {s}\n", .{ tag, CHANGELOG_PATH });
            try std.testing.expect(false);
        }
    }
}

test "CHANGELOG release dates match git history" {
    const allocator = std.testing.allocator;
    const body = try readFile(allocator, CHANGELOG_PATH);
    defer allocator.free(body);

    // v0.1.0 was tagged 2026-01-24; v0.1.1 2026-01-26; v0.1.2/0.1.3/0.1.4
    // were all tagged 2026-05-02 (sibling-dep patch bumps). 0.2.0 is dated
    // 2026-04-18 in the changelog (in-flight feature target, not yet cut).
    const required = [_][]const u8{
        "## [0.1.0] - 2026-01-24",
        "## [0.1.1] - 2026-01-26",
        "## [0.1.2] - 2026-05-02",
        "## [0.1.3] - 2026-05-02",
        "## [0.1.4] - 2026-05-02",
        "## [0.2.0] - 2026-04-18",
    };
    for (required) |needle| {
        if (std.mem.indexOf(u8, body, needle) == null) {
            std.debug.print("missing '{s}' in {s}\n", .{ needle, CHANGELOG_PATH });
            try std.testing.expect(false);
        }
    }
}

test "CHANGELOG documents the current build.zig.zon version (Q-NEW-1)" {
    // Drift guard: whatever version build.zig.zon declares MUST have a
    // matching `## [<version>]` heading in the changelog. This is the
    // check that would have caught the API.md/CHANGELOG vs zon drift.
    const allocator = std.testing.allocator;
    const zon = try readFile(allocator, "build.zig.zon");
    defer allocator.free(zon);

    // Extract the value of the top-level `.version = "X.Y.Z"`. Anchor to
    // the 4-space top-level indent so a future dependency carrying its own
    // (more deeply indented) `.version` field cannot shift the match.
    const marker = "\n    .version = \"";
    const vstart = (std.mem.indexOf(u8, zon, marker) orelse {
        std.debug.print("no top-level .version in build.zig.zon\n", .{});
        return error.TestUnexpectedResult;
    }) + marker.len;
    const vend = std.mem.indexOfScalarPos(u8, zon, vstart, '"') orelse {
        return error.TestUnexpectedResult;
    };
    const version = zon[vstart..vend];

    const body = try readFile(allocator, CHANGELOG_PATH);
    defer allocator.free(body);

    var heading_buf: [64]u8 = undefined;
    const heading = std.fmt.bufPrint(&heading_buf, "## [{s}]", .{version}) catch unreachable;
    if (std.mem.indexOf(u8, body, heading) == null) {
        std.debug.print("build.zig.zon version {s} has no '{s}' heading in {s}\n", .{ version, heading, CHANGELOG_PATH });
        try std.testing.expect(false);
    }
}

test "CHANGELOG credits the 0.2.0 audit closures" {
    const allocator = std.testing.allocator;
    const body = try readFile(allocator, CHANGELOG_PATH);
    defer allocator.free(body);

    // 0.2.0 is the first release to ship the parallel subsystem riding
    // on the real parser, the ParallelContext API, the leak-check CI
    // gate, and the ResourceLimitExceeded guard. Each must be credited
    // by ID so a future maintainer can trace what shipped.
    const required = [_][]const u8{
        "toml.parallel",
        "ParallelContext",
        "leak",
        "GAP-0005",
        "GAP-0001",
        "ResourceLimitExceeded",
    };
    for (required) |needle| {
        if (std.mem.indexOf(u8, body, needle) == null) {
            std.debug.print("missing '{s}' in {s}\n", .{ needle, CHANGELOG_PATH });
            try std.testing.expect(false);
        }
    }
}

// ---------------------------------------------------------------------
// PUBLIC_API.md -- drift gate (Q-16)
// ---------------------------------------------------------------------

/// Extract the leading name after `pub const` / `pub fn`. Returns the
/// identifier up to the first space, `=`, `(`, or `:`.
fn extractPubName(line: []const u8) ?[]const u8 {
    const prefixes = [_][]const u8{ "pub const ", "pub fn " };
    for (prefixes) |p| {
        if (std.mem.startsWith(u8, line, p)) {
            const rest = line[p.len..];
            var end: usize = 0;
            while (end < rest.len) : (end += 1) {
                const c = rest[end];
                if (c == ' ' or c == '=' or c == '(' or c == ':') break;
            }
            if (end == 0) return null;
            return rest[0..end];
        }
    }
    return null;
}

test "extractPubName smoke" {
    try std.testing.expectEqualStrings(
        "parse",
        extractPubName("pub fn parse(alloc: Allocator) !void {").?,
    );
    try std.testing.expectEqualStrings(
        "Value",
        extractPubName("pub const Value = value_mod.Value;").?,
    );
    try std.testing.expectEqual(
        @as(?[]const u8, null),
        extractPubName("const not_pub = 1;"),
    );
}

test "PUBLIC_API.md matches pub symbols in src/toml.zig" {
    const allocator = std.testing.allocator;

    const src = try readFile(allocator, TOML_ZIG_PATH);
    defer allocator.free(src);

    const manifest = try readFile(allocator, PUBLIC_API_PATH);
    defer allocator.free(manifest);

    // Walk src line-by-line; for each `pub const|fn NAME`, assert the
    // manifest contains "const NAME" or "fn NAME" as a substring.
    var it = std.mem.splitScalar(u8, src, '\n');
    var missing: std.ArrayList(u8) = .empty;
    defer missing.deinit(allocator);

    while (it.next()) |line| {
        const name = extractPubName(line) orelse continue;
        const kind: []const u8 = if (std.mem.startsWith(u8, line, "pub fn "))
            "fn "
        else
            "const ";
        var buf: [128]u8 = undefined;
        const needle = std.fmt.bufPrint(&buf, "{s}{s}", .{ kind, name }) catch unreachable;
        if (std.mem.indexOf(u8, manifest, needle) == null) {
            var line_buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(
                &line_buf,
                "missing '{s}' in PUBLIC_API.md\n",
                .{needle},
            ) catch unreachable;
            try missing.appendSlice(allocator, msg);
        }
    }

    if (missing.items.len != 0) {
        std.debug.print("{s}", .{missing.items});
        try std.testing.expect(false);
    }
}
