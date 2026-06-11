// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros

//! TOML inline-table parsing (`{ key = value, ... }`).
//!
//! Extracted from `src/parser.zig` (Q-17). The pipeline is split into:
//!
//! - `parseInlineTableHeader` — consumes `{`, preallocates the entry map
//! - `parseInlineTableBody` — walks the body, parses each `k = v`,
//!   handles dotted keys and duplicate-key diagnostics, and tracks the
//!   first newline / trailing comma for v1.0 diagnostics
//! - `validateInlineTableV10Restrictions` — rejects trailing commas and
//!   interior newlines under TOML v1.0
//! - `mergeTables` — O(n) insertion-order merge used by dotted-key
//!   inline-table writes
//!
//! The module is stateless; all data flows through `*Parser`. The
//! forward-declared `Parser` import breaks the cycle — this file holds
//! no state.

const std = @import("std");
const Allocator = std.mem.Allocator;

const err = @import("../error.zig");
const ErrorCode = err.ErrorCode;
const Position = err.Position;

const val = @import("../value.zig");
const Value = val.Value;

const events_sink = @import("events_sink.zig");

// Forward-declared to break the import cycle.
const parser_mod = @import("../parser.zig");
const Parser = parser_mod.Parser;
const ParseValueError = Parser.ParseValueError;

/// Scratch state carried from `parseInlineTableHeader` through
/// `parseInlineTableBody` into `validateInlineTableV10Restrictions`.
pub const InlineTableHeader = struct {
    /// Position of the opening `{` — used for trailing-comma errors.
    open_pos: Position,
    /// The entry map under construction. The caller-owned `map` is
    /// wrapped into a `Value.table` by `parseInlineTable` once the
    /// body completes.
    map: std.StringArrayHashMapUnmanaged(*Value),
};

pub fn parseInlineTable(self: *Parser, alloc: Allocator) ParseValueError!Value {
    // Defense-in-depth: inline tables are a recursive construct too.
    try self.enterDepth();
    defer self.exitDepth();

    var header = try parseInlineTableHeader(self, alloc);
    errdefer header.map.deinit(alloc);

    // Event-mode: announce the inline table after the `{` has been
    // consumed (inside parseInlineTableHeader) and before the body
    // keys are parsed so the handler sees `{`, kv:..., kv:..., `}`.
    try events_sink.emitSimple(self, .inline_table_start);

    // Capture the first offending token position for v1.0 restriction
    // diagnostics so error carets point at the violating `,` / newline
    // rather than at the opening `{` of the inline table.
    var trailing_comma_pos: ?Position = null;
    var newline_inside_pos: ?Position = null;
    try parseInlineTableBody(self, alloc, &header, &trailing_comma_pos, &newline_inside_pos);
    try validateInlineTableV10Restrictions(self, &header, trailing_comma_pos, newline_inside_pos);

    try events_sink.emitSimple(self, .inline_table_end);

    return Value{ .table = .{ .map = header.map, .is_inline = true, .is_closed_inline = true } };
}

fn parseInlineTableHeader(self: *Parser, alloc: Allocator) ParseValueError!InlineTableHeader {
    const open_pos = self.current.pos;
    self.current = try self.nextToken(); // consume {

    // Typical inline tables have a handful of entries; 16 avoids the
    // initial reallocation ladder for essentially every real-world case.
    var map: std.StringArrayHashMapUnmanaged(*Value) = .{};
    errdefer map.deinit(alloc);
    try map.ensureTotalCapacity(alloc, 16);

    return .{ .open_pos = open_pos, .map = map };
}

fn parseInlineTableBody(
    self: *Parser,
    alloc: Allocator,
    header: *InlineTableHeader,
    trailing_comma_pos: *?Position,
    newline_inside_pos: *?Position,
) ParseValueError!void {
    while (self.current.tag != .right_brace and self.current.tag != .eof) {
        // Track newlines inside the body; v1.0 validation happens later.
        if (self.current.tag == .newline) {
            if (newline_inside_pos.* == null) newline_inside_pos.* = self.current.pos;
            self.current = try self.nextToken();
            continue;
        }

        if (self.current.tag == .comment) {
            self.current = try self.nextToken();
            continue;
        }

        // Parse key = value
        var path: std.ArrayList([]const u8) = try .initCapacity(alloc, 8);
        try self.parseKeyPath(alloc, &path);

        if (self.current.tag != .equals) {
            self.parse_error = err.makeError(.UnexpectedToken, self.current.pos, "expected '='");
            return error.ParseFailed;
        }
        self.current = try self.nextToken();

        // Events mode: pre-announce container key_values so handlers
        // see `kv:key -> container_start`. Scalar key_values fire
        // after the value is decoded, below.
        const body_value_is_container = switch (self.current.tag) {
            .left_bracket, .double_bracket_open, .left_brace => true,
            else => false,
        };
        if (self.sink == .events and body_value_is_container) {
            try events_sink.emitKeyValueContainer(self, path.items[path.items.len - 1]);
        }

        const value = try self.parseValue(alloc);

        if (self.sink == .events and !body_value_is_container) {
            try events_sink.emitKeyValueScalar(self, path.items[path.items.len - 1], value.*);
        }

        // Handle dotted keys in inline table
        if (path.items.len > 1) {
            // Create nested tables starting from the second key
            // For "a.b = 1", path is ["a", "b"], we want a -> {b -> 1}
            try self.bumpValues();
            var current_table = try val.createTable(alloc);
            current_table.table.is_inline = true;
            var target = current_table;

            // Start from index 1, not 0 - the first key becomes the root key
            for (path.items[1 .. path.items.len - 1]) |key| {
                try self.bumpValues();
                const nested = try val.createTable(alloc);
                nested.table.is_inline = true;
                try val.tableSet(alloc, target, key, nested);
                target = nested;
            }

            try val.tableSet(alloc, target, path.items[path.items.len - 1], value);

            // Merge or add the root key. O(1) probe.
            const root_key = path.items[0];
            if (header.map.get(root_key)) |existing_value| {
                // Cannot extend an inline table that was defined with { ... } syntax
                if (existing_value.* == .table and existing_value.table.is_closed_inline) {
                    self.parse_error = err.makeError(.TableRedefined, self.current.pos, "cannot extend inline table with dotted key");
                    return error.ParseFailed;
                }
                // Merge tables - fails if either side is not a table
                mergeTables(alloc, existing_value, current_table) catch {
                    self.parse_error = err.makeError(.DuplicateKey, self.current.pos, "cannot overwrite key with dotted key");
                    return error.ParseFailed;
                };
            } else {
                // root_key is arena-owned (P-5); no dupe.
                try header.map.put(alloc, root_key, current_table);
            }
        } else {
            // Check for duplicate key. O(1).
            if (header.map.contains(path.items[0])) {
                self.parse_error = err.makeError(.DuplicateKey, self.current.pos, "duplicate key in inline table");
                return error.ParseFailed;
            }
            try header.map.put(alloc, path.items[0], value);
        }

        // Skip whitespace/newlines (tracking, not rejecting).
        while (self.current.tag == .newline or self.current.tag == .comment) {
            if (self.current.tag == .newline and newline_inside_pos.* == null) {
                newline_inside_pos.* = self.current.pos;
            }
            self.current = try self.nextToken();
        }

        if (self.current.tag == .comma) {
            // Capture comma position before consuming in case this
            // turns out to be a trailing comma.
            const comma_pos = self.current.pos;
            self.current = try self.nextToken();

            // Skip whitespace/newlines after comma.
            while (self.current.tag == .newline or self.current.tag == .comment) {
                if (self.current.tag == .newline and newline_inside_pos.* == null) {
                    newline_inside_pos.* = self.current.pos;
                }
                self.current = try self.nextToken();
            }

            // Trailing comma: flag for post-body validation.
            if (self.current.tag == .right_brace and trailing_comma_pos.* == null) {
                trailing_comma_pos.* = comma_pos;
            }
        } else if (self.current.tag != .right_brace) {
            // No comma and not closing brace - error
            self.parse_error = err.makeError(.UnexpectedToken, self.current.pos, "expected ',' or '}' in inline table");
            return error.ParseFailed;
        }
    }

    if (self.current.tag != .right_brace) {
        self.parse_error = err.makeError(.UnexpectedToken, self.current.pos, "expected '}'");
        return error.ParseFailed;
    }
    self.current = try self.nextToken();
}

fn validateInlineTableV10Restrictions(
    self: *Parser,
    header: *const InlineTableHeader,
    trailing_comma_pos: ?Position,
    newline_inside_pos: ?Position,
) ParseValueError!void {
    _ = header; // preserved in signature; may be reused for future diagnostics.
    if (self.options.version != .v1_0_0) return;
    if (trailing_comma_pos) |pos| {
        self.parse_error = err.makeError(
            .InlineTableTrailingCommaNotAllowed,
            pos,
            "trailing comma not allowed in inline tables in TOML v1.0",
        );
        return error.ParseFailed;
    }
    if (newline_inside_pos) |pos| {
        self.parse_error = err.makeError(
            .InlineTableNewlineNotAllowed,
            pos,
            "newlines not allowed in inline tables in TOML v1.0",
        );
        return error.ParseFailed;
    }
}

fn mergeTables(alloc: Allocator, target: *Value, source: *Value) error{ ParseFailed, OutOfMemory }!void {
    // Both must be tables
    if (target.* != .table or source.* != .table) {
        return error.ParseFailed;
    }

    // Iterate source in insertion order; O(n) with O(1) per probe
    // into target instead of the old O(n*m) nested linear scan.
    var it = val.tableIterator(source);
    while (it.next()) |src_entry| {
        if (target.table.map.get(src_entry.key)) |tgt_value| {
            // Both values must be tables to merge.
            if (tgt_value.* != .table or src_entry.value.* != .table) {
                return error.ParseFailed;
            }
            try mergeTables(alloc, tgt_value, src_entry.value);
        } else {
            try val.tableSet(alloc, target, src_entry.key, src_entry.value);
        }
    }
}
