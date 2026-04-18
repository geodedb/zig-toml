// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! toml-test compatible tagged JSON emitter.
//! Outputs deterministic JSON with sorted keys.

const std = @import("std");
const val = @import("value.zig");
const Value = val.Value;
const Document = val.Document;
const TableEntry = val.TableEntry;

/// Write a Document as toml-test tagged JSON.
/// Keys are sorted lexicographically (byte order) at every level.
pub fn writeTaggedJson(doc: *const Document, writer: anytype) !void {
    try writeValue(doc.root, writer);
    try writer.writeByte('\n');
}

fn tableEntryLessThan(_: void, a: TableEntry, b: TableEntry) bool {
    return std.mem.order(u8, a.key, b.key) == .lt;
}

fn writeValue(v: *const Value, writer: anytype) !void {
    switch (v.*) {
        .table => |t| {
            try writer.writeByte('{');
            // Always sort keys so the emitter output is deterministic
            // regardless of input-order choices the parser makes. For
            // small tables we copy onto a stack buffer; for larger ones we
            // allocate scratch from the SMP allocator. Previously tables
            // with >256 entries fell through to the parser's insertion
            // order, violating the documented "sorted at every level"
            // contract (toml-test comparison failures under adversarial
            // inputs; non-reproducible diffs).
            var stack_sorted: [256]TableEntry = undefined;
            var heap_sorted: ?[]TableEntry = null;
            defer if (heap_sorted) |slice| std.heap.smp_allocator.free(slice);

            const sorted_slice: []TableEntry = if (t.entries.len <= stack_sorted.len) blk: {
                @memcpy(stack_sorted[0..t.entries.len], t.entries);
                break :blk stack_sorted[0..t.entries.len];
            } else blk: {
                const buf = try std.heap.smp_allocator.alloc(TableEntry, t.entries.len);
                @memcpy(buf, t.entries);
                heap_sorted = buf;
                break :blk buf;
            };
            std.sort.pdq(TableEntry, sorted_slice, {}, tableEntryLessThan);

            for (sorted_slice, 0..) |entry, i| {
                if (i > 0) try writer.writeByte(',');
                try writeJsonString(entry.key, writer);
                try writer.writeByte(':');
                try writeValue(entry.value, writer);
            }
            try writer.writeByte('}');
        },
        .array => |a| {
            try writer.writeByte('[');
            for (a.items, 0..) |item, i| {
                if (i > 0) try writer.writeByte(',');
                try writeValue(item, writer);
            }
            try writer.writeByte(']');
        },
        .string => |s| {
            try writer.writeAll("{\"type\":\"string\",\"value\":");
            try writeJsonString(s, writer);
            try writer.writeByte('}');
        },
        .integer => |n| {
            try writer.writeAll("{\"type\":\"integer\",\"value\":\"");
            try writer.print("{d}", .{n});
            try writer.writeAll("\"}");
        },
        .float => |f| {
            try writer.writeAll("{\"type\":\"float\",\"value\":\"");
            if (std.math.isNan(f)) {
                try writer.writeAll("nan");
            } else if (std.math.isInf(f)) {
                if (f < 0) {
                    try writer.writeAll("-inf");
                } else {
                    try writer.writeAll("inf");
                }
            } else {
                // Format float with full precision
                try formatFloat(f, writer);
            }
            try writer.writeAll("\"}");
        },
        .bool => |b| {
            try writer.writeAll("{\"type\":\"bool\",\"value\":\"");
            try writer.writeAll(if (b) "true" else "false");
            try writer.writeAll("\"}");
        },
        .datetime => |dt| {
            try writer.writeAll("{\"type\":\"datetime\",\"value\":\"");
            try dt.format(writer);
            try writer.writeAll("\"}");
        },
        .datetime_local => |dt| {
            try writer.writeAll("{\"type\":\"datetime-local\",\"value\":\"");
            try dt.format(writer);
            try writer.writeAll("\"}");
        },
        .date_local => |d| {
            try writer.writeAll("{\"type\":\"date-local\",\"value\":\"");
            try d.format(writer);
            try writer.writeAll("\"}");
        },
        .time_local => |t| {
            try writer.writeAll("{\"type\":\"time-local\",\"value\":\"");
            try t.format(writer);
            try writer.writeAll("\"}");
        },
    }
}

fn writeJsonString(s: []const u8, writer: anytype) !void {
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

fn formatFloat(f: f64, writer: anytype) !void {
    // Use a buffer to format the float
    var buf: [64]u8 = undefined;

    // Check if it's an integer value
    if (@floor(f) == f and @abs(f) < 1e15) {
        const int_val: i64 = @intFromFloat(f);
        const result = std.fmt.bufPrint(&buf, "{d}.0", .{int_val}) catch {
            try writer.print("{d}.0", .{int_val});
            return;
        };
        try writer.writeAll(result);
    } else {
        // Format with full precision
        const result = std.fmt.bufPrint(&buf, "{d}", .{f}) catch {
            try writer.print("{d}", .{f});
            return;
        };
        try writer.writeAll(result);
        // Ensure there's a decimal point
        var has_dot = false;
        for (result) |c| {
            if (c == '.' or c == 'e' or c == 'E') {
                has_dot = true;
                break;
            }
        }
        if (!has_dot) {
            try writer.writeAll(".0");
        }
    }
}
