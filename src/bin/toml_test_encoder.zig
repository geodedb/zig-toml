// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! toml-test-encoder CLI
//!
//! Reads toml-test tagged JSON from stdin, outputs TOML to stdout.
//! On success: prints TOML to stdout, exits 0.
//! On failure: prints one-line diagnostic to stderr, exits 1.

const std = @import("std");
const builtin = @import("builtin");
const toml = @import("toml");

const Value = toml.value_mod.Value;
const Document = toml.Document;
const DateTime = toml.DateTime;
const DateTimeLocal = toml.DateTimeLocal;
const DateLocal = toml.DateLocal;
const TimeLocal = toml.TimeLocal;

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
    const v = try toml.value_mod.createTable(alloc);
    var it = obj.iterator();
    while (it.next()) |kv| {
        const child = try jsonToValue(alloc, kv.value_ptr.*);
        // Dupe the key so the table owns its byte storage independently
        // of the std.json arena that parsed the request.
        const key_copy = try alloc.dupe(u8, kv.key_ptr.*);
        try toml.value_mod.tableSet(alloc, v, key_copy, child);
    }
    return v;
}

fn decodeArray(alloc: std.mem.Allocator, arr: std.json.Array) !*Value {
    const v = try toml.value_mod.createArray(alloc);
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
        try toml.value_mod.arrayAppend(alloc, v, child.*);
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
        v.* = .{ .datetime = try parseDateTime(literal) };
    } else if (std.mem.eql(u8, tag, "datetime-local")) {
        v.* = .{ .datetime_local = try parseDateTimeLocal(literal) };
    } else if (std.mem.eql(u8, tag, "date-local")) {
        v.* = .{ .date_local = try parseDateLocal(literal) };
    } else if (std.mem.eql(u8, tag, "time-local")) {
        v.* = .{ .time_local = try parseTimeLocal(literal) };
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
fn parseDateTime(s: []const u8) !DateTime {
    var buf: [128]u8 = undefined;
    const wrapped = try std.fmt.bufPrint(&buf, "x = {s}\n", .{s});
    const doc = try toml.parse(std.heap.smp_allocator, wrapped, .{});
    defer doc.deinit();
    const v = doc.root.get("x") orelse return error.InvalidDateTime;
    return switch (v.*) {
        .datetime => |dt| dt,
        else => error.InvalidDateTime,
    };
}

fn parseDateTimeLocal(s: []const u8) !DateTimeLocal {
    var buf: [128]u8 = undefined;
    const wrapped = try std.fmt.bufPrint(&buf, "x = {s}\n", .{s});
    const doc = try toml.parse(std.heap.smp_allocator, wrapped, .{});
    defer doc.deinit();
    const v = doc.root.get("x") orelse return error.InvalidDateTime;
    return switch (v.*) {
        .datetime_local => |dt| dt,
        else => error.InvalidDateTime,
    };
}

fn parseDateLocal(s: []const u8) !DateLocal {
    var buf: [128]u8 = undefined;
    const wrapped = try std.fmt.bufPrint(&buf, "x = {s}\n", .{s});
    const doc = try toml.parse(std.heap.smp_allocator, wrapped, .{});
    defer doc.deinit();
    const v = doc.root.get("x") orelse return error.InvalidDateTime;
    return switch (v.*) {
        .date_local => |d| d,
        else => error.InvalidDateTime,
    };
}

fn parseTimeLocal(s: []const u8) !TimeLocal {
    var buf: [128]u8 = undefined;
    const wrapped = try std.fmt.bufPrint(&buf, "x = {s}\n", .{s});
    const doc = try toml.parse(std.heap.smp_allocator, wrapped, .{});
    defer doc.deinit();
    const v = doc.root.get("x") orelse return error.InvalidDateTime;
    return switch (v.*) {
        .time_local => |t| t,
        else => error.InvalidDateTime,
    };
}

pub fn main(init: std.process.Init) !void {
    // In Debug builds use the DebugAllocator so the toml-test harness
    // surfaces any encoder-side leaks. In release builds swap to the SMP
    // allocator for the same reasons toml-test-decoder does: lower
    // per-allocation cost and no leak-tracking overhead that would
    // distort CLI runtime benchmarks (CWE-209 also applies -- DebugGPA
    // metadata must never leak into diagnostic output on release).
    var debug_gpa: std.heap.DebugAllocator(.{}) =
        if (builtin.mode == .Debug) .init else undefined;
    defer if (builtin.mode == .Debug) {
        _ = debug_gpa.deinit();
    };
    const allocator: std.mem.Allocator = if (builtin.mode == .Debug)
        debug_gpa.allocator()
    else
        std.heap.smp_allocator;

    const io = init.io;

    const stdin = std.Io.File.stdin();
    const stdout = std.Io.File.stdout();
    const stderr = std.Io.File.stderr();

    var stdin_buf: [4096]u8 = undefined;
    var stdout_buf: [4096]u8 = undefined;
    var stderr_buf: [256]u8 = undefined;

    var stdin_reader = stdin.readerStreaming(io, &stdin_buf);
    var stdout_writer = stdout.writerStreaming(io, &stdout_buf);
    var stderr_writer = stderr.writerStreaming(io, &stderr_buf);

    // Read all of stdin (16 MiB cap).
    const input = stdin_reader.interface.allocRemaining(allocator, .limited(16 * 1024 * 1024)) catch |e| {
        stderr_writer.interface.print("error: failed to read stdin: {}\n", .{e}) catch {};
        stderr_writer.interface.flush() catch {};
        std.process.exit(1);
    };
    defer allocator.free(input);

    // Main pipeline is wired in Task 19; for now the scaffold just
    // drains stdin so the allocator plumbing and I/O layout can be
    // exercised end-to-end without touching the TOML encoder yet.
    _ = toml;

    stdout_writer.interface.flush() catch {};
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
