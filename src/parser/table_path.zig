// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros

//! Table-path resolution for TOML headers (`[a.b.c]`, `[[a.b.c]]`).
//!
//! Extracted from `src/parser.zig` (Q-17). Given a dotted key path and
//! the document root, walks or creates each segment, applying the
//! redefinition / array-of-tables / implicit-vs-explicit rules that
//! make TOML's table rules well-defined. The function returns a
//! pointer to the final table that subsequent `key = value` pairs
//! write into.
//!
//! Stateless; all data flows through `*Parser`.

const std = @import("std");
const Allocator = std.mem.Allocator;

const err = @import("../error.zig");
const ErrorCode = err.ErrorCode;
const Position = err.Position;

const val = @import("../value.zig");
const Value = val.Value;

// Forward-declared to break the import cycle.
const Parser = @import("../parser.zig").Parser;

/// Navigate (or create) the table addressed by `path`, returning a
/// pointer to its terminal table so the caller can continue populating
/// it. Honours the TOML rules for array-of-tables, implicit-vs-explicit
/// definition, and inline-table reopen prohibition.
pub fn resolveTablePath(
    self: *Parser,
    alloc: Allocator,
    root: *Value,
    path: []const []const u8,
    is_array_of_tables: bool,
    pos: Position,
) !*Value {
    var current = root;

    for (path, 0..) |key, i| {
        const is_last = (i == path.len - 1);

        if (current.table.map.get(key)) |existing| {
            if (try enterExistingSegment(self, &current, existing, is_last, is_array_of_tables, alloc, pos)) |terminal| {
                return terminal;
            }
        } else if (try createMissingSegment(self, &current, key, is_last, is_array_of_tables, alloc)) |terminal| {
            return terminal;
        }
    }

    return current;
}

/// Walk through a key that already exists on `current.table`. If the
/// segment is terminal and we can return a final table pointer, return
/// it directly. Otherwise update `current` to the next container and
/// return null so the outer loop continues.
fn enterExistingSegment(
    self: *Parser,
    current: **Value,
    existing: *Value,
    is_last: bool,
    is_array_of_tables: bool,
    alloc: Allocator,
    pos: Position,
) !?*Value {
    if (is_last) return try enterExistingTerminal(self, existing, is_array_of_tables, alloc, pos);
    try enterExistingIntermediate(self, current, existing, pos);
    return null;
}

/// Handle the last segment when it names an existing key -- either an
/// array of tables to append to, or a regular table to be marked
/// `defined_explicitly`. Returns the pointer the parser should populate.
fn enterExistingTerminal(
    self: *Parser,
    existing: *Value,
    is_array_of_tables: bool,
    alloc: Allocator,
    pos: Position,
) !*Value {
    if (is_array_of_tables) {
        if (existing.* != .array) {
            self.parse_error = err.makeError(.ArrayOfTablesConflict, pos, "key is not an array of tables");
            return error.ParseFailed;
        }
        if (existing.array.is_static) {
            self.parse_error = err.makeError(.ArrayOfTablesConflict, pos, "cannot append to statically defined array");
            return error.ParseFailed;
        }
        // Create new table and append to array. After P-10 (by-value
        // Array storage) the table lives inside the array's slice;
        // `arrayAppendTable` returns a pointer to the tail so the
        // parser can continue populating it.
        try self.bumpValues();
        const new_table = try val.createTable(alloc);
        new_table.table.defined_explicitly = true;
        return try val.arrayAppendTable(alloc, existing, new_table);
    }

    if (existing.* != .table) {
        self.parse_error = err.makeError(.KeyRedefinesNonTable, pos, "key is not a table");
        return error.ParseFailed;
    }
    if (existing.table.is_inline) {
        self.parse_error = err.makeError(.TableRedefined, pos, "cannot redefine inline table");
        return error.ParseFailed;
    }
    if (existing.table.defined_explicitly and !existing.table.is_array_of_tables) {
        self.parse_error = err.makeError(.TableRedefined, pos, "table already defined");
        return error.ParseFailed;
    }
    if (existing.table.defined_by_dotted_key) {
        self.parse_error = err.makeError(.TableRedefined, pos, "cannot redefine table created via dotted keys");
        return error.ParseFailed;
    }
    existing.table.defined_explicitly = true;
    return existing;
}

/// Handle an intermediate segment (not the last in the path) that
/// already exists. Mutates `current` to point at the next container so
/// the outer loop can continue walking.
fn enterExistingIntermediate(
    self: *Parser,
    current: **Value,
    existing: *Value,
    pos: Position,
) !void {
    switch (existing.*) {
        .array => {
            if (existing.array.items.items.len == 0) {
                self.parse_error = err.makeError(.UnexpectedToken, pos, "empty array in path");
                return error.ParseFailed;
            }
            if (existing.array.is_static) {
                self.parse_error = err.makeError(.TableRedefined, pos, "cannot extend tables in static array");
                return error.ParseFailed;
            }
            // Array items are now stored by value (P-10); take the
            // address of the tail to keep `current` as a mutable
            // pointer into the array's storage.
            current.* = &existing.array.items.items[existing.array.items.items.len - 1];
        },
        .table => {
            if (existing.table.is_inline) {
                self.parse_error = err.makeError(.TableRedefined, pos, "cannot extend inline table");
                return error.ParseFailed;
            }
            current.* = existing;
        },
        else => {
            self.parse_error = err.makeError(.KeyRedefinesNonTable, pos, "intermediate key is not a table");
            return error.ParseFailed;
        },
    }
}

/// Create a fresh segment when the key is absent from `current.table`.
/// Terminal `[[aot]]` returns the newly-appended table pointer;
/// otherwise updates `current` to the implicit table and returns null.
fn createMissingSegment(
    self: *Parser,
    current: **Value,
    key: []const u8,
    is_last: bool,
    is_array_of_tables: bool,
    alloc: Allocator,
) !?*Value {
    if (is_last and is_array_of_tables) {
        try self.bumpValues();
        const arr = try val.createArray(alloc);
        arr.array.is_static = false;
        try self.bumpValues();
        const new_table = try val.createTable(alloc);
        new_table.table.defined_explicitly = true;
        new_table.table.is_array_of_tables = true;
        // By-value Array storage (P-10): reach the freshly created
        // table through its slot inside the array, not via the
        // original heap pointer.
        const stored_table = try val.arrayAppendTable(alloc, arr, new_table);
        try val.tableSet(alloc, current.*, key, arr);
        return stored_table;
    }

    try self.bumpValues();
    const new_table = try val.createTable(alloc);
    if (is_last) new_table.table.defined_explicitly = true;
    try val.tableSet(alloc, current.*, key, new_table);
    current.* = new_table;
    return null;
}
