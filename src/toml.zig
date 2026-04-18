// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! # zigtoml - TOML v1.1.0 Parser for Zig
//!
//! A fully compliant TOML parser supporting v1.1.0 (default) and v1.0.0 compatibility mode.
//! Outputs typed value trees and can emit toml-test compatible tagged JSON.

const std = @import("std");
const Allocator = std.mem.Allocator;

// Re-export public types
pub const error_mod = @import("error.zig");
pub const ErrorCode = error_mod.ErrorCode;
pub const ParseError = error_mod.ParseError;

pub const value_mod = @import("value.zig");
pub const Value = value_mod.Value;
pub const ValueTag = value_mod.ValueTag;
pub const Document = value_mod.Document;
pub const DateTime = value_mod.DateTime;
pub const DateTimeLocal = value_mod.DateTimeLocal;
pub const DateLocal = value_mod.DateLocal;
pub const TimeLocal = value_mod.TimeLocal;

pub const parser_mod = @import("parser.zig");
pub const TomlVersion = parser_mod.TomlVersion;
pub const ParseOptions = parser_mod.ParseOptions;

pub const json_tagged = @import("json_tagged.zig");

pub const parallel = @import("parallel.zig");

/// Parse TOML input into a Document.
///
/// The Document owns all parsed data via an internal ArenaAllocator.
/// Call `deinit()` on the returned Document to free all memory.
///
/// Returns error.ParseFailed on parse errors. Access detailed error
/// information via the parser's parse_error field when using the Parser directly.
pub fn parse(alloc: Allocator, input: []const u8, opts: ParseOptions) !*Document {
    var parser = parser_mod.Parser.init(alloc, input, opts);
    return parser.parse() catch |e| {
        if (parser.parse_error) |_| {
            return error.ParseFailed;
        }
        return e;
    };
}

/// Parse TOML with detailed error reporting.
/// Returns either a Document or a ParseError with location information.
pub const ParseResult = union(enum) {
    ok: *Document,
    err: ParseError,
};

pub fn parseWithError(alloc: Allocator, input: []const u8, opts: ParseOptions) ParseResult {
    var parser = parser_mod.Parser.init(alloc, input, opts);
    const doc = parser.parse() catch {
        if (parser.parse_error) |pe| {
            return .{ .err = pe };
        }
        return .{ .err = .{
            .code = .UnexpectedToken,
            .byte_index = 0,
            .line = 1,
            .column = 1,
            .message = "unknown parse error",
        } };
    };
    return .{ .ok = doc };
}

/// Write toml-test compatible tagged JSON.
/// Keys are sorted lexicographically at every level for determinism.
pub fn writeTaggedJson(doc: *const Document, writer: anytype) !void {
    try json_tagged.writeTaggedJson(doc, writer);
}

// Unit tests
test "parse simple key-value" {
    const input = "a = 42\n";
    const doc = try parse(std.testing.allocator, input, .{});
    defer doc.deinit();

    const a = doc.root.get("a") orelse unreachable;
    try std.testing.expectEqual(@as(i64, 42), a.integer);
}

test "parse string with escapes" {
    const input =
        \\str = "hello\tworld\n"
    ;
    const doc = try parse(std.testing.allocator, input, .{});
    defer doc.deinit();

    const str = doc.root.get("str") orelse unreachable;
    try std.testing.expectEqualStrings("hello\tworld\n", str.string);
}

test "parse array" {
    const input = "arr = [1, 2, 3]\n";
    const doc = try parse(std.testing.allocator, input, .{});
    defer doc.deinit();

    const arr = doc.root.get("arr") orelse unreachable;
    try std.testing.expectEqual(@as(usize, 3), arr.array.items.items.len);
    try std.testing.expectEqual(@as(i64, 1), arr.array.items.items[0].integer);
    try std.testing.expectEqual(@as(i64, 2), arr.array.items.items[1].integer);
    try std.testing.expectEqual(@as(i64, 3), arr.array.items.items[2].integer);
}

test "parse table" {
    const input =
        \\[server]
        \\host = "localhost"
        \\port = 8080
    ;
    const doc = try parse(std.testing.allocator, input, .{});
    defer doc.deinit();

    const server = doc.root.get("server") orelse unreachable;
    const host = server.get("host") orelse unreachable;
    const port = server.get("port") orelse unreachable;

    try std.testing.expectEqualStrings("localhost", host.string);
    try std.testing.expectEqual(@as(i64, 8080), port.integer);
}

test "parse inline table" {
    const input = "point = { x = 1, y = 2 }\n";
    const doc = try parse(std.testing.allocator, input, .{});
    defer doc.deinit();

    const point = doc.root.get("point") orelse unreachable;
    const x = point.get("x") orelse unreachable;
    const y = point.get("y") orelse unreachable;

    try std.testing.expectEqual(@as(i64, 1), x.integer);
    try std.testing.expectEqual(@as(i64, 2), y.integer);
}

test "parse dotted keys" {
    const input = "a.b.c = 1\n";
    const doc = try parse(std.testing.allocator, input, .{});
    defer doc.deinit();

    const path = &[_][]const u8{ "a", "b", "c" };
    const c = doc.getPath(path) orelse unreachable;
    try std.testing.expectEqual(@as(i64, 1), c.integer);
}

test "parse float" {
    const input = "f = 3.14\n";
    const doc = try parse(std.testing.allocator, input, .{});
    defer doc.deinit();

    const f = doc.root.get("f") orelse unreachable;
    try std.testing.expectApproxEqRel(@as(f64, 3.14), f.float, 0.001);
}

test "parse bool" {
    const input =
        \\t = true
        \\f = false
    ;
    const doc = try parse(std.testing.allocator, input, .{});
    defer doc.deinit();

    const t = doc.root.get("t") orelse unreachable;
    const f = doc.root.get("f") orelse unreachable;

    try std.testing.expect(t.bool);
    try std.testing.expect(!f.bool);
}

test "parse date-time" {
    const input = "dt = 2024-01-15T10:30:00Z\n";
    const doc = try parse(std.testing.allocator, input, .{});
    defer doc.deinit();

    const dt = doc.root.get("dt") orelse unreachable;
    try std.testing.expectEqual(@as(u16, 2024), dt.datetime.year);
    try std.testing.expectEqual(@as(u8, 1), dt.datetime.month);
    try std.testing.expectEqual(@as(u8, 15), dt.datetime.day);
}

test "parse local time" {
    const input = "lt = 10:30:00\n";
    const doc = try parse(std.testing.allocator, input, .{});
    defer doc.deinit();

    const lt = doc.root.get("lt") orelse unreachable;
    try std.testing.expectEqual(@as(u8, 10), lt.time_local.hour);
    try std.testing.expectEqual(@as(u8, 30), lt.time_local.minute);
    try std.testing.expectEqual(@as(u8, 0), lt.time_local.second);
}

test "parse array of tables" {
    const input =
        \\[[products]]
        \\name = "Hammer"
        \\
        \\[[products]]
        \\name = "Nail"
    ;
    const doc = try parse(std.testing.allocator, input, .{});
    defer doc.deinit();

    const products = doc.root.get("products") orelse unreachable;
    try std.testing.expectEqual(@as(usize, 2), products.array.items.items.len);

    const hammer = products.array.items.items[0].get("name") orelse unreachable;
    const nail = products.array.items.items[1].get("name") orelse unreachable;

    try std.testing.expectEqualStrings("Hammer", hammer.string);
    try std.testing.expectEqualStrings("Nail", nail.string);
}

test "invalid UTF-8 rejected" {
    const input = "a = \"\xff\xfe\"\n";
    const result = parseWithError(std.testing.allocator, input, .{});
    switch (result) {
        .ok => |doc| {
            doc.deinit();
            try std.testing.expect(false);
        },
        .err => |e| {
            try std.testing.expectEqual(ErrorCode.InvalidUtf8, e.code);
        },
    }
}

test "hex integer" {
    const input = "x = 0xDEADBEEF\n";
    const doc = try parse(std.testing.allocator, input, .{});
    defer doc.deinit();

    const x = doc.root.get("x") orelse unreachable;
    try std.testing.expectEqual(@as(i64, 0xDEADBEEF), x.integer);
}

test "octal integer" {
    const input = "x = 0o755\n";
    const doc = try parse(std.testing.allocator, input, .{});
    defer doc.deinit();

    const x = doc.root.get("x") orelse unreachable;
    try std.testing.expectEqual(@as(i64, 0o755), x.integer);
}

test "binary integer" {
    const input = "x = 0b11010110\n";
    const doc = try parse(std.testing.allocator, input, .{});
    defer doc.deinit();

    const x = doc.root.get("x") orelse unreachable;
    try std.testing.expectEqual(@as(i64, 0b11010110), x.integer);
}

test "multiline basic string" {
    const input =
        \\str = """
        \\hello
        \\world"""
    ;
    const doc = try parse(std.testing.allocator, input, .{});
    defer doc.deinit();

    const str = doc.root.get("str") orelse unreachable;
    try std.testing.expectEqualStrings("hello\nworld", str.string);
}

test "multiline literal string" {
    const input =
        \\str = '''
        \\hello
        \\world'''
    ;
    const doc = try parse(std.testing.allocator, input, .{});
    defer doc.deinit();

    const str = doc.root.get("str") orelse unreachable;
    try std.testing.expectEqualStrings("hello\nworld", str.string);
}

test "special floats" {
    const input =
        \\a = inf
        \\b = -inf
        \\c = nan
    ;
    const doc = try parse(std.testing.allocator, input, .{});
    defer doc.deinit();

    const a = doc.root.get("a") orelse unreachable;
    const b = doc.root.get("b") orelse unreachable;
    const c = doc.root.get("c") orelse unreachable;

    try std.testing.expect(std.math.isPositiveInf(a.float));
    try std.testing.expect(std.math.isNegativeInf(b.float));
    try std.testing.expect(std.math.isNan(c.float));
}

test "U-R malformed timezone hours rejected" {
    // Lexer accepts the datetime token shape; parser must reject the
    // non-digit bytes in the TZ offset instead of silently using 0.
    const input = "dt = 2024-01-15T10:30:00+AB:CD\n";
    const result = parseWithError(std.testing.allocator, input, .{});
    switch (result) {
        .ok => |doc| {
            doc.deinit();
            try std.testing.expect(false);
        },
        .err => {}, // any parse error is acceptable; 0-silent-accept is not
    }
}

test "U-R malformed fractional seconds rejected" {
    // `.` followed by zero digits used to silently become 0; must now error.
    const input = "t = 10:30:00.\n";
    const result = parseWithError(std.testing.allocator, input, .{});
    switch (result) {
        .ok => |doc| {
            doc.deinit();
            try std.testing.expect(false);
        },
        .err => {},
    }
}

test "U-H deep nesting rejected by defense-in-depth guards" {
    // Build a TOML document with >max_depth nested arrays. Every recursion
    // entrypoint (parseValue, parseArray, parseArrayContents,
    // parseNestedArrayFromDoubleBracket, parseInlineTable) must call
    // enterDepth/exitDepth so this cannot be bypassed by any call path.
    const allocator = std.testing.allocator;
    const depth: usize = 40;
    const opts = ParseOptions{ .max_depth = 8, .max_bytes = 1024 * 1024 };

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    try buf.appendSlice(allocator, "x = ");
    for (0..depth) |_| try buf.append(allocator, '[');
    try buf.append(allocator, '0');
    for (0..depth) |_| try buf.append(allocator, ']');
    try buf.append(allocator, '\n');

    const result = parseWithError(allocator, buf.items, opts);
    switch (result) {
        .ok => |doc| {
            doc.deinit();
            try std.testing.expect(false); // should have failed
        },
        .err => |e| {
            try std.testing.expectEqual(ErrorCode.LimitExceeded, e.code);
        },
    }
}

test "U-H deep nested inline tables rejected" {
    // Inline tables also recurse; guard must fire.
    const allocator = std.testing.allocator;
    const depth: usize = 40;
    const opts = ParseOptions{ .max_depth = 8, .max_bytes = 1024 * 1024 };

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    try buf.appendSlice(allocator, "x = ");
    for (0..depth) |_| try buf.appendSlice(allocator, "{ a = ");
    try buf.append(allocator, '1');
    for (0..depth) |_| try buf.appendSlice(allocator, " }");
    try buf.append(allocator, '\n');

    const result = parseWithError(allocator, buf.items, opts);
    switch (result) {
        .ok => |doc| {
            doc.deinit();
            try std.testing.expect(false);
        },
        .err => |e| {
            try std.testing.expectEqual(ErrorCode.LimitExceeded, e.code);
        },
    }
}

test "parallel re-export is reachable" {
    // Smoke test: verify parallel.zig is reachable through the public
    // toml root module and the batch parse entry point works end-to-end.
    const inputs = [_][]const u8{
        "a = 1\n",
        "b = 2\n",
        "c = 3\n",
        "d = 4\n",
    };
    var results: [4]parallel.ParseResult = undefined;
    parallel.parseDocuments(std.testing.allocator, &inputs, &results);
    defer {
        for (&results) |*r| if (r.doc) |d| d.deinit();
        parallel.deinitPool();
    }

    for (results) |r| {
        try std.testing.expect(r.success);
    }
}

test "U-B2 input buffer may be freed before Document.deinit (P-5)" {
    const alloc = std.testing.allocator;
    const input = try alloc.dupe(u8, "server_host = \"localhost\"\n[database]\npool_size = 16\n");

    const doc = try parse(alloc, input, .{});
    defer doc.deinit();

    alloc.free(input);

    const host = doc.root.get("server_host") orelse unreachable;
    try std.testing.expectEqualStrings("localhost", host.string);

    const db = doc.root.get("database") orelse unreachable;
    const pool = db.get("pool_size") orelse unreachable;
    try std.testing.expectEqual(@as(i64, 16), pool.integer);
}
