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

        // Check if key exists. O(1).
        const found: ?*Value = current.table.map.get(key);

        if (found) |existing| {
            if (is_last) {
                if (is_array_of_tables) {
                    // Must be an array
                    if (existing.* != .array) {
                        self.parse_error = err.makeError(.ArrayOfTablesConflict, pos, "key is not an array of tables");
                        return error.ParseFailed;
                    }
                    if (existing.array.is_static) {
                        self.parse_error = err.makeError(.ArrayOfTablesConflict, pos, "cannot append to statically defined array");
                        return error.ParseFailed;
                    }
                    // Create new table and append to array. After
                    // P-10 (by-value Array storage) the table lives
                    // inside the array's slice; `arrayAppendTable`
                    // returns a pointer to the tail so the parser
                    // can continue populating it.
                    try self.bumpValues();
                    const new_table = try val.createTable(alloc);
                    new_table.table.defined_explicitly = true;
                    return try val.arrayAppendTable(alloc, existing, new_table);
                } else {
                    // Regular table - must be a table and not already explicitly defined
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
                    // Cannot explicitly define a table that was created via dotted keys
                    if (existing.table.defined_by_dotted_key) {
                        self.parse_error = err.makeError(.TableRedefined, pos, "cannot redefine table created via dotted keys");
                        return error.ParseFailed;
                    }
                    existing.table.defined_explicitly = true;
                    current = existing;
                }
            } else {
                // Intermediate key
                if (existing.* == .array) {
                    // Navigate to last element of array of tables
                    if (existing.array.items.items.len == 0) {
                        self.parse_error = err.makeError(.UnexpectedToken, pos, "empty array in path");
                        return error.ParseFailed;
                    }
                    // Cannot extend tables within static arrays
                    if (existing.array.is_static) {
                        self.parse_error = err.makeError(.TableRedefined, pos, "cannot extend tables in static array");
                        return error.ParseFailed;
                    }
                    // Array items are now stored by value (P-10);
                    // take address of the tail to keep `current` as
                    // a mutable pointer into the array's storage.
                    current = &existing.array.items.items[existing.array.items.items.len - 1];
                } else if (existing.* == .table) {
                    // Cannot extend inline tables
                    if (existing.table.is_inline) {
                        self.parse_error = err.makeError(.TableRedefined, pos, "cannot extend inline table");
                        return error.ParseFailed;
                    }
                    current = existing;
                } else {
                    self.parse_error = err.makeError(.KeyRedefinesNonTable, pos, "intermediate key is not a table");
                    return error.ParseFailed;
                }
            }
        } else {
            // Key doesn't exist - create it
            if (is_last and is_array_of_tables) {
                // Create array of tables
                try self.bumpValues();
                const arr = try val.createArray(alloc);
                arr.array.is_static = false;
                try self.bumpValues();
                const new_table = try val.createTable(alloc);
                new_table.table.defined_explicitly = true;
                new_table.table.is_array_of_tables = true;
                // By-value Array storage (P-10): the freshly created
                // table must be reached through its slot inside the
                // array, not via the original heap pointer.
                const stored_table = try val.arrayAppendTable(alloc, arr, new_table);
                try val.tableSet(alloc, current, key, arr);
                return stored_table;
            } else {
                // Create implicit table
                try self.bumpValues();
                const new_table = try val.createTable(alloc);
                if (is_last) {
                    new_table.table.defined_explicitly = true;
                }
                try val.tableSet(alloc, current, key, new_table);
                current = new_table;
            }
        }
    }

    return current;
}
