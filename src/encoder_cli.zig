// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! Encoder CLI helpers.
//!
//! Houses the library-side pieces of `src/bin/toml_test_encoder.zig` so
//! they can be reached from tests and other in-process callers. The bin
//! file itself is kept to a thin main() wrapper -- its `main(init:
//! std.process.Init)` signature would otherwise leak into any
//! `@import` of the file and break roundtrip tests that live outside
//! the bin/ module path.

const std = @import("std");
const value_mod = @import("value.zig");
const parser_mod = @import("parser.zig");
const encoder_mod = @import("encoder.zig");
const json_tagged_mod = @import("json_tagged.zig");

const Value = value_mod.Value;
const Document = value_mod.Document;
const DateTime = value_mod.DateTime;
const DateTimeLocal = value_mod.DateTimeLocal;
const DateLocal = value_mod.DateLocal;
const TimeLocal = value_mod.TimeLocal;

/// Convert a toml-test tagged-JSON tree into a Value owned by `alloc`.
///
/// Tagged leaves look like: {"type": "<tag>", "value": "<literal>"}.
/// Objects lacking the exact {type,value} shape are TOML tables.
/// JSON arrays map to TOML arrays. Datetime literals are round-tripped
/// through the real TOML parser so we inherit the lexer's validation
/// rules rather than maintain a second datetime grammar here.
pub fn jsonToValue(alloc: std.mem.Allocator, node: std.json.Value) anyerror!*Value {
    switch (node) {
        .object => |obj| {
            // Detect the tagged-leaf shape. Both keys must be present,
            // both must be strings, and the object must have exactly two
            // entries -- any other object is a TOML table.
            if (obj.count() == 2) {
                const type_entry = obj.get("type");
                const value_entry = obj.get("value");
                if (type_entry != null and value_entry != null and
                    type_entry.? == .string and value_entry.? == .string)
                {
                    return decodeTaggedLeaf(alloc, type_entry.?.string, value_entry.?.string);
                }
            }
            return decodeTable(alloc, obj);
        },
        .array => |arr| return decodeArray(alloc, arr),
        else => return error.InvalidTaggedJson,
    }
}

fn decodeTable(alloc: std.mem.Allocator, obj: std.json.ObjectMap) !*Value {
    const v = try value_mod.createTable(alloc);
    var it = obj.iterator();
    while (it.next()) |kv| {
        const child = try jsonToValue(alloc, kv.value_ptr.*);
        // Dupe the key so the table owns its byte storage independently
        // of the std.json arena that parsed the request.
        const key_copy = try alloc.dupe(u8, kv.key_ptr.*);
        try value_mod.tableSet(alloc, v, key_copy, child);
    }
    return v;
}

fn decodeArray(alloc: std.mem.Allocator, arr: std.json.Array) !*Value {
    const v = try value_mod.createArray(alloc);
    // is_static=true so the encoder emits this as an inline array. Arrays
    // of tables that would land as [[header]] only come from the TOML
    // parser side; a JSON-authored corpus always projects to inline form.
    v.array.is_static = true;
    for (arr.items) |item| {
        const child = try jsonToValue(alloc, item);
        // Array stores Values by value (not by pointer); copy the tag +
        // payload into the array slot. The child pointer itself is then
        // unreferenced, but the inner storage (strings, inner tables)
        // lives on the arena and remains valid.
        try value_mod.arrayAppend(alloc, v, child.*);
    }
    return v;
}

fn decodeTaggedLeaf(alloc: std.mem.Allocator, tag: []const u8, literal: []const u8) !*Value {
    const v = try alloc.create(Value);
    if (std.mem.eql(u8, tag, "string")) {
        v.* = .{ .string = try alloc.dupe(u8, literal) };
    } else if (std.mem.eql(u8, tag, "integer")) {
        v.* = .{ .integer = try std.fmt.parseInt(i64, literal, 10) };
    } else if (std.mem.eql(u8, tag, "float")) {
        v.* = .{ .float = try parseFloatLiteral(literal) };
    } else if (std.mem.eql(u8, tag, "bool")) {
        v.* = .{ .bool = std.mem.eql(u8, literal, "true") };
    } else if (std.mem.eql(u8, tag, "datetime")) {
        v.* = .{ .datetime = try parseDatetimeLiteral(.datetime, literal) };
    } else if (std.mem.eql(u8, tag, "datetime-local")) {
        v.* = .{ .datetime_local = try parseDatetimeLiteral(.datetime_local, literal) };
    } else if (std.mem.eql(u8, tag, "date-local")) {
        v.* = .{ .date_local = try parseDatetimeLiteral(.date_local, literal) };
    } else if (std.mem.eql(u8, tag, "time-local")) {
        v.* = .{ .time_local = try parseDatetimeLiteral(.time_local, literal) };
    } else {
        return error.UnknownTag;
    }
    return v;
}

fn parseFloatLiteral(s: []const u8) !f64 {
    if (std.mem.eql(u8, s, "nan") or
        std.mem.eql(u8, s, "+nan") or
        std.mem.eql(u8, s, "-nan")) return std.math.nan(f64);
    if (std.mem.eql(u8, s, "inf") or std.mem.eql(u8, s, "+inf")) return std.math.inf(f64);
    if (std.mem.eql(u8, s, "-inf")) return -std.math.inf(f64);
    return try std.fmt.parseFloat(f64, s);
}

// Datetime literals are re-parsed through the real TOML parser by
// wrapping them as `x = <lit>` so we inherit the lexer's validation
// rules instead of maintaining a second datetime grammar here.
fn parseDatetimeLiteral(
    comptime tag: std.meta.Tag(Value),
    s: []const u8,
) !@FieldType(Value, @tagName(tag)) {
    var buf: [128]u8 = undefined;
    const wrapped = try std.fmt.bufPrint(&buf, "x = {s}\n", .{s});
    var p = parser_mod.Parser.init(std.heap.smp_allocator, wrapped, .{});
    const doc = try p.parse();
    defer doc.deinit();
    const v = doc.root.get("x") orelse return error.InvalidDateTime;
    if (v.* != tag) return error.InvalidDateTime;
    return @field(v, @tagName(tag));
}

/// Parse tagged-JSON `input`, reconstruct a Document, and encode it as
/// TOML text to `writer`. The Document and all sub-values live on a
/// private arena that is released before this function returns.
pub fn runEncodePipeline(alloc: std.mem.Allocator, input: []const u8, writer: anytype) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, input, .{});
    defer parsed.deinit();

    // Build a Document that matches value_mod.createDocument's ownership
    // contract: arena pointer + original gpa live on `alloc`, everything
    // else lives on the arena. Using createDocument + root swap keeps the
    // invariants identical to parser-produced Documents.
    const doc = try value_mod.createDocument(alloc);
    defer doc.deinit();

    const new_root = try jsonToValue(doc.allocator(), parsed.value);
    if (new_root.* != .table) return error.ExpectedRootTable;
    doc.root = new_root;

    try encoder_mod.encode(doc, writer, .{});
}

test "json tree to Value: integer" {
    const arena_alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(arena_alloc);
    defer arena.deinit();
    const a = arena.allocator();

    const json_src = "{\"type\":\"integer\",\"value\":\"42\"}";
    var parsed = try std.json.parseFromSlice(std.json.Value, arena_alloc, json_src, .{});
    defer parsed.deinit();

    const v = try jsonToValue(a, parsed.value);
    try std.testing.expectEqual(@as(i64, 42), v.integer);
}

test "json tree to Value: table of primitives" {
    const arena_alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(arena_alloc);
    defer arena.deinit();
    const a = arena.allocator();

    const json_src =
        "{\"a\":{\"type\":\"integer\",\"value\":\"1\"}," ++
        "\"b\":{\"type\":\"bool\",\"value\":\"true\"}}";
    var parsed = try std.json.parseFromSlice(std.json.Value, arena_alloc, json_src, .{});
    defer parsed.deinit();

    const v = try jsonToValue(a, parsed.value);
    try std.testing.expect(v.* == .table);
    const a_child = v.get("a") orelse unreachable;
    try std.testing.expectEqual(@as(i64, 1), a_child.integer);
    const b_child = v.get("b") orelse unreachable;
    try std.testing.expectEqual(true, b_child.bool);
}

test "json tree to Value: array of integers" {
    const arena_alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(arena_alloc);
    defer arena.deinit();
    const a = arena.allocator();

    const json_src =
        "[{\"type\":\"integer\",\"value\":\"1\"}," ++
        "{\"type\":\"integer\",\"value\":\"2\"}]";
    var parsed = try std.json.parseFromSlice(std.json.Value, arena_alloc, json_src, .{});
    defer parsed.deinit();

    const v = try jsonToValue(a, parsed.value);
    try std.testing.expect(v.* == .array);
    try std.testing.expectEqual(@as(usize, 2), v.array.items.items.len);
    try std.testing.expectEqual(@as(i64, 1), v.array.items.items[0].integer);
    try std.testing.expectEqual(@as(i64, 2), v.array.items.items[1].integer);
}

test "encode pipeline: tagged JSON to TOML" {
    const alloc = std.testing.allocator;

    const json_src = "{\"a\":{\"type\":\"integer\",\"value\":\"42\"}}\n";
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    try runEncodePipeline(alloc, json_src, &out.writer);
    try std.testing.expectEqualStrings("a = 42\n", out.written());
}

test "encode pipeline: string, float, bool" {
    const alloc = std.testing.allocator;
    const json_src =
        "{\"s\":{\"type\":\"string\",\"value\":\"hi\"}," ++
        "\"f\":{\"type\":\"float\",\"value\":\"3.14\"}," ++
        "\"b\":{\"type\":\"bool\",\"value\":\"true\"}}";
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try runEncodePipeline(alloc, json_src, &out.writer);
    // encoder.encode sorts keys lexicographically: b, f, s.
    try std.testing.expectEqualStrings(
        "b = true\nf = 3.14\ns = \"hi\"\n",
        out.written(),
    );
}

test "encode pipeline: nested table" {
    const alloc = std.testing.allocator;
    const json_src =
        "{\"server\":{\"host\":{\"type\":\"string\",\"value\":\"localhost\"}," ++
        "\"port\":{\"type\":\"integer\",\"value\":\"8080\"}}}";
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try runEncodePipeline(alloc, json_src, &out.writer);
    try std.testing.expectEqualStrings(
        "[server]\nhost = \"localhost\"\nport = 8080\n",
        out.written(),
    );
}

test "encode pipeline: array of integers" {
    const alloc = std.testing.allocator;
    const json_src =
        "{\"nums\":[{\"type\":\"integer\",\"value\":\"1\"}," ++
        "{\"type\":\"integer\",\"value\":\"2\"}," ++
        "{\"type\":\"integer\",\"value\":\"3\"}]}";
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try runEncodePipeline(alloc, json_src, &out.writer);
    try std.testing.expectEqualStrings("nums = [1, 2, 3]\n", out.written());
}

test "encode pipeline: datetime" {
    const alloc = std.testing.allocator;
    const json_src =
        "{\"dt\":{\"type\":\"datetime\",\"value\":\"2024-01-15T10:30:00Z\"}}";
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try runEncodePipeline(alloc, json_src, &out.writer);
    try std.testing.expectEqualStrings("dt = 2024-01-15T10:30:00Z\n", out.written());
}
