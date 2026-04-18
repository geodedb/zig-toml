// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros

//! Differential tests against a curated BurntSushi/toml-test corpus.
//!
//! Walks tests/testdata/toml-test/valid and tests/testdata/toml-test/invalid
//! at test time. For each valid case, parses the TOML and -- if a matching
//! .json fixture exists -- asserts that writeTaggedJson produces byte-for-byte
//! the same output. For each invalid case, asserts parseWithError returns
//! the .err variant.
//!
//! Paths are resolved relative to `std.Io.Dir.cwd()`, which
//! `zig build test` sets to the repo root.
//!
//! This closes Q-13 (no grammar coverage, no toml-test corpus wired).

const std = @import("std");
const toml = @import("toml");

const corpus_root = "tests/testdata/toml-test";

const CaseKind = enum { valid, invalid };

fn runCase(
    allocator: std.mem.Allocator,
    kind: CaseKind,
    toml_path: []const u8,
    toml_bytes: []const u8,
    maybe_json: ?[]const u8,
) !void {
    switch (kind) {
        .valid => {
            const result = toml.parseWithError(allocator, toml_bytes, .{});
            switch (result) {
                .err => |e| {
                    std.debug.print(
                        "valid fixture {s} rejected: line {d} col {d}: {s}\n",
                        .{ toml_path, e.line, e.column, e.message },
                    );
                    return error.ValidCaseRejected;
                },
                .ok => |doc| {
                    defer doc.deinit();

                    if (maybe_json) |expected_json| {
                        var aw: std.Io.Writer.Allocating = .init(allocator);
                        defer aw.deinit();
                        try toml.writeTaggedJson(doc, &aw.writer);
                        std.testing.expectEqualStrings(expected_json, aw.written()) catch |e| {
                            std.debug.print(
                                "valid fixture {s} produced different tagged JSON\n",
                                .{toml_path},
                            );
                            return e;
                        };
                    }
                },
            }
        },
        .invalid => {
            const result = toml.parseWithError(allocator, toml_bytes, .{});
            switch (result) {
                .ok => |doc| {
                    doc.deinit();
                    std.debug.print(
                        "invalid fixture {s} was accepted -- expected parse error\n",
                        .{toml_path},
                    );
                    return error.InvalidCaseAccepted;
                },
                .err => {}, // expected
            }
        },
    }
}

fn walkAndRun(allocator: std.mem.Allocator, subdir: []const u8, kind: CaseKind) !usize {
    const io = std.testing.io;
    const cwd: std.Io.Dir = .cwd();

    var dir = cwd.openDir(io, subdir, .{ .iterate = true }) catch |e| switch (e) {
        error.FileNotFound => return 0, // empty corpus is allowed (pre-seed state)
        else => return e,
    };
    defer dir.close(io);

    var count: usize = 0;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".toml")) continue;

        const toml_path = try std.fs.path.join(allocator, &.{ subdir, entry.name });
        defer allocator.free(toml_path);

        const toml_bytes = try cwd.readFileAlloc(
            io,
            toml_path,
            allocator,
            .limited(16 * 1024 * 1024),
        );
        defer allocator.free(toml_bytes);

        var maybe_json: ?[]u8 = null;
        defer if (maybe_json) |b| allocator.free(b);

        if (kind == .valid) {
            const stem = entry.name[0 .. entry.name.len - ".toml".len];
            const json_name = try std.fmt.allocPrint(allocator, "{s}.json", .{stem});
            defer allocator.free(json_name);
            const json_path = try std.fs.path.join(allocator, &.{ subdir, json_name });
            defer allocator.free(json_path);

            maybe_json = cwd.readFileAlloc(
                io,
                json_path,
                allocator,
                .limited(16 * 1024 * 1024),
            ) catch |e| switch (e) {
                error.FileNotFound => null,
                else => return e,
            };
        }

        try runCase(allocator, kind, toml_path, toml_bytes, maybe_json);
        count += 1;
    }
    return count;
}

test "toml-test differential: valid corpus parses and matches golden JSON" {
    const allocator = std.testing.allocator;
    const n = try walkAndRun(allocator, corpus_root ++ "/valid", .valid);
    // Pre-seed state: zero is acceptable; Task 5 onwards raises the floor.
    std.debug.print("valid corpus: {d} cases\n", .{n});
}

test "toml-test differential: invalid corpus is rejected" {
    const allocator = std.testing.allocator;
    const n = try walkAndRun(allocator, corpus_root ++ "/invalid", .invalid);
    std.debug.print("invalid corpus: {d} cases\n", .{n});
}
