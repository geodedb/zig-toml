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
    // Q-3: assert structurally -- error code, line, column must be populated
    // so users can surface a diagnostic, not just "something failed".
    const input = "dt = 2024-01-15T10:30:00+AB:CD\n";
    const result = parseWithError(std.testing.allocator, input, .{});
    switch (result) {
        .ok => |doc| {
            doc.deinit();
            try std.testing.expect(false);
        },
        .err => |e| {
            try std.testing.expect(e.line >= 1);
            try std.testing.expect(e.column >= 1);
            try std.testing.expect(e.message.len > 0);
        },
    }
}

test "U-R malformed fractional seconds rejected" {
    // `.` followed by zero digits used to silently become 0; must now error.
    // Q-3: assert structurally -- the .err branch must carry position info.
    const input = "t = 10:30:00.\n";
    const result = parseWithError(std.testing.allocator, input, .{});
    switch (result) {
        .ok => |doc| {
            doc.deinit();
            try std.testing.expect(false);
        },
        .err => |e| {
            try std.testing.expect(e.line == 1);
            try std.testing.expect(e.column >= 1);
            try std.testing.expect(e.message.len > 0);
        },
    }
}

test "Q-3 positive smoke: parse then writeTaggedJson round-trip" {
    // Parse a small doc, emit tagged JSON, re-parse that JSON into a
    // std.json tree, and confirm the shape matches expectations. This
    // catches silent divergence between parser and writeTaggedJson that
    // a .success==true-only check would miss.
    const input =
        \\greeting = "hi"
        \\count = 7
    ;
    const doc = try parse(std.testing.allocator, input, .{});
    defer doc.deinit();

    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try writeTaggedJson(doc, &aw.writer);

    const emitted = aw.written();

    // Byte-exact check: the writer is deterministic (keys sorted).
    const expected =
        "{\"count\":{\"type\":\"integer\",\"value\":\"7\"}," ++
        "\"greeting\":{\"type\":\"string\",\"value\":\"hi\"}}\n";
    try std.testing.expectEqualStrings(expected, emitted);

    // Re-parse to confirm it's syntactically valid JSON -- defence against
    // a future writer bug that emits something that merely LOOKS like JSON.
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        std.mem.trimEnd(u8, emitted, "\n"),
        .{},
    );
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .object);
}

test "Q-3 negative smoke: parseWithError populates error_info on failure" {
    // Guard against a regression where parseWithError returned .err but
    // with zeroed position data, masking user-facing diagnostics.
    const input = "key = \n"; // missing value after '='
    const result = parseWithError(std.testing.allocator, input, .{});
    switch (result) {
        .ok => |doc| {
            doc.deinit();
            try std.testing.expect(false);
        },
        .err => |e| {
            try std.testing.expect(e.line >= 1);
            try std.testing.expect(e.column >= 1);
            try std.testing.expect(e.message.len > 0);
            // byte_index must point into the input slice.
            try std.testing.expect(e.byte_index <= input.len);
        },
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
    const allocator = std.testing.allocator;
    var ctx = try parallel.ParallelContext.initDefault(allocator);
    defer ctx.deinit();

    const inputs = [_][]const u8{
        "a = 1\n",
        "b = 2\n",
        "c = 3\n",
        "d = 4\n",
    };
    var results: [4]parallel.ParseResult = undefined;
    ctx.parseDocuments(&inputs, &results);
    defer for (&results) |*r| if (r.doc) |d| d.deinit();

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

test "parseInlineTable: v1.0 rejects trailing comma" {
    const src = "t = { a = 1, }";
    const alloc = std.testing.allocator;
    if (parse(alloc, src, .{ .version = .v1_0_0 })) |doc| {
        defer doc.deinit();
        return error.TestExpectedError;
    } else |e| {
        try std.testing.expectEqual(error.ParseFailed, e);
    }
}

test "parseInlineTable: v1.1 accepts trailing comma" {
    const src = "t = { a = 1, }";
    const alloc = std.testing.allocator;
    const doc = try parse(alloc, src, .{ .version = .v1_1_0 });
    defer doc.deinit();
    const t = doc.root.get("t") orelse unreachable;
    const a = t.get("a") orelse unreachable;
    try std.testing.expectEqual(@as(i64, 1), a.integer);
}

test "parseInlineTable: v1.0 rejects newline inside" {
    const src = "t = { a = 1,\n  b = 2 }";
    const alloc = std.testing.allocator;
    if (parse(alloc, src, .{ .version = .v1_0_0 })) |doc| {
        defer doc.deinit();
        return error.TestExpectedError;
    } else |e| {
        try std.testing.expectEqual(error.ParseFailed, e);
    }
}

test "parseInlineTable: v1.1 accepts newline inside" {
    const src = "t = { a = 1,\n  b = 2 }";
    const alloc = std.testing.allocator;
    const doc = try parse(alloc, src, .{ .version = .v1_1_0 });
    defer doc.deinit();
    const t = doc.root.get("t") orelse unreachable;
    const a = t.get("a") orelse unreachable;
    try std.testing.expectEqual(@as(i64, 1), a.integer);
    const b = t.get("b") orelse unreachable;
    try std.testing.expectEqual(@as(i64, 2), b.integer);
}

test "invalid UTF-8 in middle of line reports precise line/column" {
    // Three lines; bad byte is at line 3, column 7 (the 0xff byte).
    // Layout (each '\n' advances line):
    //   "a = 1\n"      line 1
    //   "b = 2\n"      line 2
    //   "c = \"X\xffY\"\n"   line 3, col 7 is \xff
    const input = "a = 1\nb = 2\nc = \"X\xffY\"\n";
    const result = parseWithError(std.testing.allocator, input, .{});
    switch (result) {
        .ok => |doc| {
            doc.deinit();
            try std.testing.expect(false);
        },
        .err => |e| {
            try std.testing.expectEqual(ErrorCode.InvalidUtf8, e.code);
            try std.testing.expectEqual(@as(u32, 3), e.line);
            try std.testing.expectEqual(@as(u32, 7), e.column);
        },
    }
}

test "2-byte UTF-8 in basic string parses" {
    const input = "name = \"caf\u{00E9}\"\n"; // é = 0xC3 0xA9
    var doc = try parse(std.testing.allocator, input, .{});
    defer doc.deinit();
    const name = doc.root.get("name") orelse unreachable;
    try std.testing.expectEqualStrings("caf\u{00E9}", name.string);
}

test "3-byte UTF-8 in literal string parses" {
    const input = "sym = 'price \u{20AC}'\n"; // € = 0xE2 0x82 0xAC
    var doc = try parse(std.testing.allocator, input, .{});
    defer doc.deinit();
    const sym = doc.root.get("sym") orelse unreachable;
    try std.testing.expectEqualStrings("price \u{20AC}", sym.string);
}

test "4-byte UTF-8 in multiline basic string parses" {
    // 𝄞 (MUSICAL SYMBOL G CLEF) = U+1D11E = F0 9D 84 9E
    const input = "note = \"\"\"clef \u{1D11E}\"\"\"\n";
    var doc = try parse(std.testing.allocator, input, .{});
    defer doc.deinit();
    const note = doc.root.get("note") orelse unreachable;
    try std.testing.expectEqualStrings("clef \u{1D11E}", note.string);
}

test "orphan UTF-8 continuation byte rejected with position" {
    // 0x80 is a continuation byte; it may not appear as a leading byte.
    const input = "k = \"\x80\"\n";
    const result = parseWithError(std.testing.allocator, input, .{});
    switch (result) {
        .ok => |doc| {
            doc.deinit();
            try std.testing.expect(false);
        },
        .err => |e| {
            try std.testing.expectEqual(ErrorCode.InvalidUtf8, e.code);
            try std.testing.expectEqual(@as(u32, 1), e.line);
            // Column 6: k, space, =, space, ", \x80
            try std.testing.expectEqual(@as(u32, 6), e.column);
        },
    }
}

test "overlong UTF-8 rejected" {
    // 0xC0 0xAF is an overlong encoding of '/' (U+002F).
    const input = "k = \"\xC0\xAF\"\n";
    const result = parseWithError(std.testing.allocator, input, .{});
    switch (result) {
        .ok => |doc| {
            doc.deinit();
            try std.testing.expect(false);
        },
        .err => |e| try std.testing.expectEqual(ErrorCode.InvalidUtf8, e.code),
    }
}

test "invalid UTF-8 start byte rejected" {
    // 0xFE / 0xFF are never valid UTF-8 start bytes.
    const input = "k = \"\xFE\xFF\"\n";
    const result = parseWithError(std.testing.allocator, input, .{});
    switch (result) {
        .ok => |doc| {
            doc.deinit();
            try std.testing.expect(false);
        },
        .err => |e| try std.testing.expectEqual(ErrorCode.InvalidUtf8, e.code),
    }
}

test "array items are stored by value" {
    const input = "arr = [10, 20, 30, 40, 50]\n";
    var doc = try parse(std.testing.allocator, input, .{});
    defer doc.deinit();

    const arr = doc.root.get("arr") orelse unreachable;
    try std.testing.expectEqual(@as(usize, 5), arr.array.items.items.len);

    try std.testing.expectEqual(@as(i64, 10), arr.array.items.items[0].integer);
    try std.testing.expectEqual(@as(i64, 50), arr.array.items.items[4].integer);

    const Elem = @TypeOf(arr.array.items.items[0]);
    try std.testing.expect(@typeInfo(Elem) != .pointer);
}

test "hex integer longer than 64 digits parses (fits i64 after underscore strip)" {
    const input =
        "n = 0x0_0_0_0_0_0_0_0_0_0_0_0_0_0_0_0_0_0_0_0_0_0_0_0_0_0_0_0_0_0_0_0_0_0_0_0_0_0_0_0_0_0_0_0_0_0_0_0_0_0_0_0_0_0_0_0_0_0_0_0_0_0_0_0_0_7F_FF_FF_FF_FF_FF_FF_FF\n";
    var doc = try parse(std.testing.allocator, input, .{});
    defer doc.deinit();
    const n = doc.root.get("n") orelse unreachable;
    try std.testing.expectEqual(@as(i64, 0x7FFFFFFFFFFFFFFF), n.integer);
}

test "float with many underscore separators parses" {
    const input =
        "f = 1_000_000_000_000_000_000_000_000_000_000_000_000_000_000_000_000_000_000_000_000_000_000_000_000_000_000_000_000_000_000_000_000_000_000.0\n";
    var doc = try parse(std.testing.allocator, input, .{});
    defer doc.deinit();
    const f = doc.root.get("f") orelse unreachable;
    try std.testing.expect(f.float > 0.0);
}
