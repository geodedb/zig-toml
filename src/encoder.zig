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
    try writeSortedEntries(root, writer, options);
}

/// Snapshot a table's entries into a sortable buffer and emit each as
/// a bare `key = value` line. Uses a stack buffer for small tables and
/// falls back to smp_allocator for large ones, matching json_tagged.zig.
fn writeSortedEntries(table: *const Value, writer: anytype, options: EncodeOptions) !void {
    std.debug.assert(table.* == .table);
    const n = table.table.map.count();
    var stack_sorted: [256]TableEntry = undefined;
    var heap_sorted: ?[]TableEntry = null;
    defer if (heap_sorted) |slice| std.heap.smp_allocator.free(slice);

    const keys = table.table.map.keys();
    const values = table.table.map.values();

    const sorted: []TableEntry = if (n <= stack_sorted.len) blk: {
        for (0..n) |i| {
            stack_sorted[i] = .{ .key = keys[i], .value = values[i] };
        }
        break :blk stack_sorted[0..n];
    } else blk: {
        const buf = try std.heap.smp_allocator.alloc(TableEntry, n);
        for (0..n) |i| {
            buf[i] = .{ .key = keys[i], .value = values[i] };
        }
        heap_sorted = buf;
        break :blk buf;
    };

    if (options.sort_keys) std.sort.pdq(TableEntry, sorted, {}, entryLessThan);

    for (sorted) |entry| {
        try writeBareKeyValue(entry, writer, options);
    }
}

fn entryLessThan(_: void, a: TableEntry, b: TableEntry) bool {
    return std.mem.order(u8, a.key, b.key) == .lt;
}

fn writeBareKeyValue(entry: TableEntry, writer: anytype, options: EncodeOptions) !void {
    _ = options;
    try writeKey(entry.key, writer);
    try writer.writeAll(" = ");
    try writeLeafValue(entry.value, writer);
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
                if (c < 0x20) {
                    try writer.print("\\u{x:0>4}", .{c});
                } else {
                    try writer.writeByte(c);
                }
            },
        }
    }
    try writer.writeByte('"');
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
        else => return error.Unimplemented,
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
