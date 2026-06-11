// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! TOML encoder. Serializes a Document back to TOML text.

const std = @import("std");
const value_mod = @import("value.zig");
const Value = value_mod.Value;
const Document = value_mod.Document;
const TableEntry = value_mod.TableEntry;

/// Options controlling encoder output.
pub const EncodeOptions = struct {
    sort_keys: bool = true,
    indent: u8 = 0,
    inline_threshold: usize = 8,
};

/// Write `doc` as TOML text to `writer` using `options`.
pub fn encode(doc: *const Document, writer: anytype, options: EncodeOptions) !void {
    try writeRootTable(doc.root, writer, options);
}

fn writeRootTable(root: *const Value, writer: anytype, options: EncodeOptions) !void {
    std.debug.assert(root.* == .table);

    // Track the dotted header path for nested [header] emission.
    var path: std.ArrayList([]const u8) = .empty;
    defer path.deinit(std.heap.smp_allocator);

    var any_output = false;
    try writeTableBody(root, writer, options, &path, &any_output);
}

/// Write the body of a non-inline table. `any_output` is true if the
/// encoder has already emitted bytes before this call — it controls
/// whether a blank-line separator precedes the next [header] line.
fn writeTableBody(
    table: *const Value,
    writer: anytype,
    options: EncodeOptions,
    path: *std.ArrayList([]const u8),
    any_output: *bool,
) anyerror!void {
    std.debug.assert(table.* == .table);

    const sorted = try sortedCopy(table, options);
    defer freeIfHeap(sorted);

    // Pass 1: leaf key-values (primitives, inline arrays, inline tables).
    for (sorted.slice) |entry| {
        if (!isHeaderChild(entry.value)) {
            try writeBareKeyValue(entry, writer, options);
            any_output.* = true;
        }
    }

    // Pass 2: header children - subtables and arrays-of-tables.
    for (sorted.slice) |entry| {
        if (!isHeaderChild(entry.value)) continue;
        try writeHeaderChild(entry, writer, options, path, any_output);
    }
}

/// True if this value should be emitted as a [header] or [[header]] section
/// rather than an inline assignment on the parent line.
fn isHeaderChild(v: *const Value) bool {
    switch (v.*) {
        .table => |t| {
            // Inline tables stay inline on the assignment line.
            if (t.is_inline) return false;
            return true;
        },
        .array => |a| {
            // Static arrays ([] syntax) are inline. Array-of-tables ([[..]])
            // uses is_static=false and emits as [[header]].
            if (a.is_static) return false;
            return true;
        },
        else => return false,
    }
}

fn writeHeaderChild(
    entry: TableEntry,
    writer: anytype,
    options: EncodeOptions,
    path: *std.ArrayList([]const u8),
    any_output: *bool,
) anyerror!void {
    try path.append(std.heap.smp_allocator, entry.key);
    defer _ = path.pop();

    switch (entry.value.*) {
        .table => {
            // Emit a [header] line for this table only when it has direct
            // leaf entries (primitives, inline tables, inline arrays).
            // Pure-container tables (only header children) descend silently
            // so `[a.b.c]\nleaf=1\n` stays compact instead of emitting
            // empty `[a]`, `[a.b]` stubs. A table with zero entries still
            // deserves its header to preserve a round-tripable shape.
            if (shouldEmitHeaderLine(entry.value)) {
                if (any_output.*) try writer.writeByte('\n');
                try writer.writeByte('[');
                try writeHeaderPath(path.items, writer);
                try writer.writeAll("]\n");
                any_output.* = true;
            }
            try writeTableBody(entry.value, writer, options, path, any_output);
        },
        .array => |a| {
            for (a.items.items) |*item| {
                std.debug.assert(item.* == .table);
                if (any_output.*) try writer.writeByte('\n');
                try writer.writeAll("[[");
                try writeHeaderPath(path.items, writer);
                try writer.writeAll("]]\n");
                any_output.* = true;
                try writeTableBody(item, writer, options, path, any_output);
            }
        },
        // writeHeaderChild is only dispatched for container variants; a
        // leaf that slips through is a caller bug, but we turn it into an
        // observable error rather than @panic so a fuzz mutation or a
        // future Value variant cannot crash the host process.
        else => return error.UnsupportedValueVariant,
    }
}

/// Decide whether a non-inline table gets its own `[header]` line during
/// emission. Tables with any leaf assignment need a header to anchor those
/// assignments. Fully empty tables also need a header to survive a
/// round-trip. Pure container tables (only header children) skip the
/// header so we do not emit redundant intermediate stubs.
fn shouldEmitHeaderLine(v: *const Value) bool {
    std.debug.assert(v.* == .table);
    const t = &v.table;
    const n = t.map.count();
    if (n == 0) return true;
    const values = t.map.values();
    var has_leaf = false;
    for (values) |child| {
        if (!isHeaderChild(child)) {
            has_leaf = true;
            break;
        }
    }
    return has_leaf;
}

fn writeHeaderPath(parts: []const []const u8, writer: anytype) !void {
    for (parts, 0..) |p, i| {
        if (i > 0) try writer.writeByte('.');
        try writeKey(p, writer);
    }
}

/// Owned snapshot of a table's entries, optionally sorted.
///
/// The snapshot is heap-allocated per call. An earlier version reused a
/// single `threadlocal` stack buffer to avoid the allocation, but
/// `writeTableBody` recurses into nested tables and each recursive
/// `sortedCopy` clobbered the parent's buffer -- the parent loop then read
/// a grandchild entry and emitted a spurious duplicate table header
/// (GAP-0030, toml-test valid/table/sub). Correctness requires each call
/// to own its slice for the lifetime of its loop; the encoder is not on
/// the parse hot path, so the per-table allocation is acceptable.
const SortedEntries = struct {
    slice: []TableEntry,
};

fn sortedCopy(table: *const Value, options: EncodeOptions) !SortedEntries {
    std.debug.assert(table.* == .table);
    const n = table.table.map.count();
    const keys = table.table.map.keys();
    const values = table.table.map.values();

    const buf = try std.heap.smp_allocator.alloc(TableEntry, n);
    for (0..n) |i| {
        buf[i] = .{ .key = keys[i], .value = values[i] };
    }
    if (options.sort_keys) std.sort.pdq(TableEntry, buf, {}, entryLessThan);
    return .{ .slice = buf };
}

fn freeIfHeap(sorted: SortedEntries) void {
    std.heap.smp_allocator.free(sorted.slice);
}

fn entryLessThan(_: void, a: TableEntry, b: TableEntry) bool {
    return std.mem.order(u8, a.key, b.key) == .lt;
}

fn writeBareKeyValue(entry: TableEntry, writer: anytype, options: EncodeOptions) !void {
    try writeKey(entry.key, writer);
    try writer.writeAll(" = ");
    try writeAnyValue(entry.value, writer, options);
    try writer.writeByte('\n');
}

fn writeKey(key: []const u8, writer: anytype) !void {
    // Bare-key rule: non-empty and every byte in [A-Za-z0-9_-].
    if (isBareKey(key)) {
        try writer.writeAll(key);
        return;
    }
    try writeBasicString(key, writer);
}

fn isBareKey(key: []const u8) bool {
    if (key.len == 0) return false;
    for (key) |c| {
        const ok = (c >= 'A' and c <= 'Z') or
            (c >= 'a' and c <= 'z') or
            (c >= '0' and c <= '9') or
            c == '_' or c == '-';
        if (!ok) return false;
    }
    return true;
}

fn writeBasicString(s: []const u8, writer: anytype) !void {
    try writer.writeByte('"');
    for (s) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            0x08 => try writer.writeAll("\\b"),
            0x0C => try writer.writeAll("\\f"),
            else => {
                // TOML requires the control characters U+0000–U+0008,
                // U+000A–U+001F, and U+007F (DEL) to be escaped in basic
                // strings. The named escapes above cover \b/\t/\n/\f/\r;
                // everything else in those ranges is emitted as \uXXXX.
                if (c < 0x20 or c == 0x7f) {
                    try writer.print("\\u{x:0>4}", .{c});
                } else {
                    try writer.writeByte(c);
                }
            },
        }
    }
    try writer.writeByte('"');
}

fn writeAnyValue(v: *const Value, writer: anytype, options: EncodeOptions) anyerror!void {
    switch (v.*) {
        .array => try writeInlineArray(v, writer, options),
        .table => try writeInlineTable(v, writer, options),
        else => try writeLeafValue(v, writer),
    }
}

fn writeInlineArray(arr: *const Value, writer: anytype, options: EncodeOptions) !void {
    std.debug.assert(arr.* == .array);
    const items = arr.array.items.items;

    // Wrap only when indent > 0 AND the item count exceeds the threshold.
    // indent=0 is the default and always stays on one line so short
    // arrays remain compact regardless of inline_threshold value.
    const should_wrap = options.indent > 0 and items.len > options.inline_threshold;

    if (!should_wrap) {
        try writer.writeByte('[');
        for (items, 0..) |*item, i| {
            if (i > 0) try writer.writeAll(", ");
            try writeAnyValue(item, writer, options);
        }
        try writer.writeByte(']');
        return;
    }

    try writer.writeAll("[\n");
    for (items) |*item| {
        var n: u8 = 0;
        while (n < options.indent) : (n += 1) try writer.writeByte(' ');
        try writeAnyValue(item, writer, options);
        try writer.writeAll(",\n");
    }
    try writer.writeByte(']');
}

fn writeInlineTable(v: *const Value, writer: anytype, options: EncodeOptions) !void {
    std.debug.assert(v.* == .table);
    const sorted = try sortedCopy(v, options);
    defer freeIfHeap(sorted);

    if (sorted.slice.len == 0) {
        try writer.writeAll("{}");
        return;
    }
    try writer.writeAll("{ ");
    for (sorted.slice, 0..) |entry, i| {
        if (i > 0) try writer.writeAll(", ");
        try writeKey(entry.key, writer);
        try writer.writeAll(" = ");
        try writeAnyValue(entry.value, writer, options);
    }
    try writer.writeAll(" }");
}

fn writeLeafValue(v: *const Value, writer: anytype) !void {
    switch (v.*) {
        .integer => |n| try writer.print("{d}", .{n}),
        .bool => |b| try writer.writeAll(if (b) "true" else "false"),
        .string => |s| try writeBasicString(s, writer),
        .float => |f| try writeFloat(f, writer),
        .datetime => |dt| try dt.format(writer),
        .datetime_local => |dt| try dt.format(writer),
        .date_local => |d| try d.format(writer),
        .time_local => |t| try t.format(writer),
        // writeLeafValue is only called for scalar variants; a container
        // here is a caller bug. Return a real error instead of UB so the
        // fuzz harness sees it and so a Value-variant drift is observable.
        .array, .table => return error.UnsupportedValueVariant,
    }
}

fn writeFloat(f: f64, writer: anytype) !void {
    if (std.math.isNan(f)) {
        try writer.writeAll("nan");
        return;
    }
    if (std.math.isInf(f)) {
        try writer.writeAll(if (f < 0) "-inf" else "inf");
        return;
    }
    // Format with default precision, then ensure a decimal indicator exists.
    var buf: [64]u8 = undefined;
    const formatted = try std.fmt.bufPrint(&buf, "{d}", .{f});
    try writer.writeAll(formatted);
    var has_point = false;
    for (formatted) |c| {
        if (c == '.' or c == 'e' or c == 'E') {
            has_point = true;
            break;
        }
    }
    if (!has_point) try writer.writeAll(".0");
}

test "writeLeafValue rejects container variants with a typed error" {
    // S-13 regression: the old else-branch was `unreachable`, which would
    // panic (or UB in ReleaseFast) if a Value variant ever reached a path
    // the parser never produces -- e.g. after fuzz mutation or a new
    // Value variant added upstream. The new contract is a plain error
    // return that the fuzz harness and any direct caller can see.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const tbl = try value_mod.createTable(a);
    const arr = try value_mod.createArray(a);

    var buf: [16]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try std.testing.expectError(error.UnsupportedValueVariant, writeLeafValue(tbl, &w));
    try std.testing.expectError(error.UnsupportedValueVariant, writeLeafValue(arr, &w));
}

test "encode empty document produces empty output" {
    const parser_mod = @import("parser.zig");
    const input = "";
    var parser = parser_mod.Parser.init(std.testing.allocator, input, .{});
    const doc = try parser.parse();
    defer doc.deinit();

    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();

    try encode(doc, &aw.writer, .{});
    try std.testing.expectEqualStrings("", aw.written());
}

test "encode single integer key-value" {
    const parser_mod = @import("parser.zig");
    const input = "a = 42\n";
    var parser = parser_mod.Parser.init(std.testing.allocator, input, .{});
    const doc = try parser.parse();
    defer doc.deinit();

    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();

    try encode(doc, &aw.writer, .{});
    try std.testing.expectEqualStrings("a = 42\n", aw.written());
}

test "encode boolean values" {
    const parser_mod = @import("parser.zig");
    const input =
        \\t = true
        \\f = false
        \\
    ;
    var parser = parser_mod.Parser.init(std.testing.allocator, input, .{});
    const doc = try parser.parse();
    defer doc.deinit();

    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();

    try encode(doc, &aw.writer, .{});
    try std.testing.expectEqualStrings("f = false\nt = true\n", aw.written());
}

test "encode string values with escapes" {
    const parser_mod = @import("parser.zig");
    const input =
        \\plain = "hello"
        \\tab = "a\tb"
        \\newline = "a\nb"
        \\quote = "say \"hi\""
        \\backslash = "a\\b"
        \\
    ;
    var parser = parser_mod.Parser.init(std.testing.allocator, input, .{});
    const doc = try parser.parse();
    defer doc.deinit();

    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();

    try encode(doc, &aw.writer, .{});
    const expected =
        "backslash = \"a\\\\b\"\n" ++
        "newline = \"a\\nb\"\n" ++
        "plain = \"hello\"\n" ++
        "quote = \"say \\\"hi\\\"\"\n" ++
        "tab = \"a\\tb\"\n";
    try std.testing.expectEqualStrings(expected, aw.written());
}

test "encode escapes DEL (U+007F) control character" {
    const parser_mod = @import("parser.zig");
    // A basic string containing a literal DEL (0x7f) must be emitted as
    // an escaped sequence, not a raw control byte (toml-test
    // valid/string/escapes, valid/key/quoted-unicode).
    const input = "k = \"a\\u007Fb\"\n";
    var parser = parser_mod.Parser.init(std.testing.allocator, input, .{});
    const doc = try parser.parse();
    defer doc.deinit();

    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();

    try encode(doc, &aw.writer, .{});
    // Output must contain the escaped form and NOT a raw 0x7f byte.
    try std.testing.expectEqualStrings("k = \"a\\u007fb\"\n", aw.written());
    try std.testing.expect(std.mem.indexOfScalar(u8, aw.written(), 0x7f) == null);
}

test "encode nested tables do not alias the sort buffer (GAP-0030)" {
    const parser_mod = @import("parser.zig");
    // Regression: sortedCopy used a single shared threadlocal buffer that
    // recursive writeTableBody calls clobbered, making the parent loop read
    // a grandchild and emit a spurious [a.more]. (toml-test valid/table/sub)
    const input =
        \\[a]
        \\key = 1
        \\[a.extend]
        \\key = 2
        \\[a.extend.more]
        \\key = 3
        \\
    ;
    var parser = parser_mod.Parser.init(std.testing.allocator, input, .{});
    const doc = try parser.parse();
    defer doc.deinit();

    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try encode(doc, &aw.writer, .{});

    const out = aw.written();
    // The correct deep path must appear exactly once; the aliased duplicate
    // [a.more] must not appear at all.
    try std.testing.expect(std.mem.indexOf(u8, out, "[a.extend.more]") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "[a.more]") == null);

    // And it must round-trip: re-parse and check the value lives at a.extend.more.
    var p2 = parser_mod.Parser.init(std.testing.allocator, out, .{});
    const doc2 = try p2.parse();
    defer doc2.deinit();
    const more = doc2.root.get("a").?.get("extend").?.get("more").?;
    try std.testing.expectEqual(@as(i64, 3), more.get("key").?.integer);
    try std.testing.expect(doc2.root.get("a").?.get("more") == null);
}

test "encode datetime values delegate to Value format methods" {
    const parser_mod = @import("parser.zig");
    const input =
        \\dt_utc = 2024-01-15T10:30:00Z
        \\dt_local = 2024-01-15T10:30:00
        \\d_local = 2024-01-15
        \\t_local = 10:30:00
        \\
    ;
    var parser = parser_mod.Parser.init(std.testing.allocator, input, .{});
    const doc = try parser.parse();
    defer doc.deinit();

    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();

    try encode(doc, &aw.writer, .{});
    const expected =
        "d_local = 2024-01-15\n" ++
        "dt_local = 2024-01-15T10:30:00\n" ++
        "dt_utc = 2024-01-15T10:30:00Z\n" ++
        "t_local = 10:30:00\n";
    try std.testing.expectEqualStrings(expected, aw.written());
}

test "encode float values including special forms" {
    const parser_mod = @import("parser.zig");
    const input =
        \\pi = 3.14
        \\whole = 1.0
        \\positive_inf = inf
        \\negative_inf = -inf
        \\not_a_number = nan
        \\
    ;
    var parser = parser_mod.Parser.init(std.testing.allocator, input, .{});
    const doc = try parser.parse();
    defer doc.deinit();

    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();

    try encode(doc, &aw.writer, .{});
    const expected =
        "negative_inf = -inf\n" ++
        "not_a_number = nan\n" ++
        "pi = 3.14\n" ++
        "positive_inf = inf\n" ++
        "whole = 1.0\n";
    try std.testing.expectEqualStrings(expected, aw.written());
}

test "encode inline array of integers" {
    const parser_mod = @import("parser.zig");
    const input = "nums = [1, 2, 3]\n";
    var parser = parser_mod.Parser.init(std.testing.allocator, input, .{});
    const doc = try parser.parse();
    defer doc.deinit();

    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();

    try encode(doc, &aw.writer, .{});
    try std.testing.expectEqualStrings("nums = [1, 2, 3]\n", aw.written());
}

test "encode inline array of strings" {
    const parser_mod = @import("parser.zig");
    const input = "fruits = [\"apple\", \"pear\"]\n";
    var parser = parser_mod.Parser.init(std.testing.allocator, input, .{});
    const doc = try parser.parse();
    defer doc.deinit();

    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();

    try encode(doc, &aw.writer, .{});
    try std.testing.expectEqualStrings("fruits = [\"apple\", \"pear\"]\n", aw.written());
}

test "encode empty inline array" {
    const parser_mod = @import("parser.zig");
    const input = "x = []\n";
    var parser = parser_mod.Parser.init(std.testing.allocator, input, .{});
    const doc = try parser.parse();
    defer doc.deinit();

    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();

    try encode(doc, &aw.writer, .{});
    try std.testing.expectEqualStrings("x = []\n", aw.written());
}

test "encode single-level header table" {
    const parser_mod = @import("parser.zig");
    const input =
        \\title = "Config"
        \\[server]
        \\host = "localhost"
        \\port = 8080
        \\
    ;
    var parser = parser_mod.Parser.init(std.testing.allocator, input, .{});
    const doc = try parser.parse();
    defer doc.deinit();

    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();

    try encode(doc, &aw.writer, .{});
    const expected =
        "title = \"Config\"\n" ++
        "\n" ++
        "[server]\n" ++
        "host = \"localhost\"\n" ++
        "port = 8080\n";
    try std.testing.expectEqualStrings(expected, aw.written());
}

test "encode quotes non-bare keys" {
    const parser_mod = @import("parser.zig");
    const input =
        \\"key with spaces" = 1
        \\"unicode Ж" = 2
        \\"" = 3
        \\
    ;
    var parser = parser_mod.Parser.init(std.testing.allocator, input, .{});
    const doc = try parser.parse();
    defer doc.deinit();

    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();

    try encode(doc, &aw.writer, .{});
    const expected =
        "\"\" = 3\n" ++
        "\"key with spaces\" = 1\n" ++
        "\"unicode Ж\" = 2\n";
    try std.testing.expectEqualStrings(expected, aw.written());
}

test "encode inline table" {
    const parser_mod = @import("parser.zig");
    const input = "point = { x = 1, y = 2 }\n";
    var parser = parser_mod.Parser.init(std.testing.allocator, input, .{});
    const doc = try parser.parse();
    defer doc.deinit();

    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();

    try encode(doc, &aw.writer, .{});
    try std.testing.expectEqualStrings("point = { x = 1, y = 2 }\n", aw.written());
}

test "encode inline table empty" {
    const parser_mod = @import("parser.zig");
    const input = "empty = {}\n";
    var parser = parser_mod.Parser.init(std.testing.allocator, input, .{});
    const doc = try parser.parse();
    defer doc.deinit();

    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();

    try encode(doc, &aw.writer, .{});
    try std.testing.expectEqualStrings("empty = {}\n", aw.written());
}

test "encode array-of-tables as [[header]]" {
    const parser_mod = @import("parser.zig");
    const input =
        \\[[products]]
        \\name = "Hammer"
        \\
        \\[[products]]
        \\name = "Nail"
        \\
    ;
    var parser = parser_mod.Parser.init(std.testing.allocator, input, .{});
    const doc = try parser.parse();
    defer doc.deinit();

    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();

    try encode(doc, &aw.writer, .{});
    const expected =
        "[[products]]\n" ++
        "name = \"Hammer\"\n" ++
        "\n" ++
        "[[products]]\n" ++
        "name = \"Nail\"\n";
    try std.testing.expectEqualStrings(expected, aw.written());
}

test "encode static array of inline tables" {
    const parser_mod = @import("parser.zig");
    const input = "points = [{ x = 1 }, { x = 2 }]\n";
    var parser = parser_mod.Parser.init(std.testing.allocator, input, .{});
    const doc = try parser.parse();
    defer doc.deinit();

    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();

    try encode(doc, &aw.writer, .{});
    try std.testing.expectEqualStrings("points = [{ x = 1 }, { x = 2 }]\n", aw.written());
}

test "encode nested header table" {
    const parser_mod = @import("parser.zig");
    const input =
        \\[a.b.c]
        \\leaf = 1
        \\
    ;
    var parser = parser_mod.Parser.init(std.testing.allocator, input, .{});
    const doc = try parser.parse();
    defer doc.deinit();

    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();

    try encode(doc, &aw.writer, .{});
    const expected = "[a.b.c]\nleaf = 1\n";
    try std.testing.expectEqualStrings(expected, aw.written());
}
