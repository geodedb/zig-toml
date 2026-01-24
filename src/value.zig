// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! TOML value types and Document container.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// TOML value type tag.
pub const ValueTag = enum {
    table,
    array,
    string,
    integer,
    float,
    bool,
    datetime,
    datetime_local,
    date_local,
    time_local,
};

/// DateTime with timezone offset.
pub const DateTime = struct {
    year: u16,
    month: u8,
    day: u8,
    hour: u8,
    minute: u8,
    second: u8,
    nanosecond: u32 = 0,
    offset_minutes: ?i16, // null for Z (UTC), otherwise minutes from UTC

    pub fn format(self: DateTime, writer: anytype) !void {
        try writer.print("{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}", .{
            self.year,
            self.month,
            self.day,
            self.hour,
            self.minute,
            self.second,
        });
        if (self.nanosecond > 0) {
            // Format fractional seconds, trimming trailing zeros
            var ns = self.nanosecond;
            var digits: u8 = 9;
            while (ns % 10 == 0 and digits > 1) {
                ns /= 10;
                digits -= 1;
            }
            try writer.print(".{d:0>[1]}", .{ ns, digits });
        }
        if (self.offset_minutes) |offset| {
            if (offset == 0) {
                try writer.writeAll("Z");
            } else {
                const sign: u8 = if (offset < 0) '-' else '+';
                const abs_offset: u16 = @intCast(if (offset < 0) -offset else offset);
                const hours = abs_offset / 60;
                const mins = abs_offset % 60;
                try writer.print("{c}{d:0>2}:{d:0>2}", .{ sign, hours, mins });
            }
        } else {
            try writer.writeAll("Z");
        }
    }
};

/// Local DateTime (no timezone).
pub const DateTimeLocal = struct {
    year: u16,
    month: u8,
    day: u8,
    hour: u8,
    minute: u8,
    second: u8,
    nanosecond: u32 = 0,

    pub fn format(self: DateTimeLocal, writer: anytype) !void {
        try writer.print("{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}", .{
            self.year,
            self.month,
            self.day,
            self.hour,
            self.minute,
            self.second,
        });
        if (self.nanosecond > 0) {
            var ns = self.nanosecond;
            var digits: u8 = 9;
            while (ns % 10 == 0 and digits > 1) {
                ns /= 10;
                digits -= 1;
            }
            try writer.print(".{d:0>[1]}", .{ ns, digits });
        }
    }
};

/// Local Date.
pub const DateLocal = struct {
    year: u16,
    month: u8,
    day: u8,

    pub fn format(self: DateLocal, writer: anytype) !void {
        try writer.print("{d:0>4}-{d:0>2}-{d:0>2}", .{ self.year, self.month, self.day });
    }
};

/// Local Time.
pub const TimeLocal = struct {
    hour: u8,
    minute: u8,
    second: u8,
    nanosecond: u32 = 0,

    pub fn format(self: TimeLocal, writer: anytype) !void {
        try writer.print("{d:0>2}:{d:0>2}:{d:0>2}", .{ self.hour, self.minute, self.second });
        if (self.nanosecond > 0) {
            var ns = self.nanosecond;
            var digits: u8 = 9;
            while (ns % 10 == 0 and digits > 1) {
                ns /= 10;
                digits -= 1;
            }
            try writer.print(".{d:0>[1]}", .{ ns, digits });
        }
    }
};

/// Table entry for ordered key-value storage.
pub const TableEntry = struct {
    key: []const u8,
    value: *Value,
};

/// A TOML value.
pub const Value = union(ValueTag) {
    table: Table,
    array: Array,
    string: []const u8,
    integer: i64,
    float: f64,
    bool: bool,
    datetime: DateTime,
    datetime_local: DateTimeLocal,
    date_local: DateLocal,
    time_local: TimeLocal,

    pub const Table = struct {
        entries: []TableEntry,
        is_inline: bool = false,
        is_array_of_tables: bool = false,
        defined_explicitly: bool = false,
        defined_by_dotted_key: bool = false, // created implicitly via dotted key in key=value
        is_closed_inline: bool = false, // true for inline tables from { ... } syntax (cannot be extended)
    };

    pub const Array = struct {
        items: []*Value,
        is_static: bool = false, // true if defined as [] syntax, not [[]]
    };

    /// Get a nested value by key path.
    pub fn getPath(self: *const Value, path: []const []const u8) ?*const Value {
        if (path.len == 0) return self;

        switch (self.*) {
            .table => |t| {
                for (t.entries) |entry| {
                    if (std.mem.eql(u8, entry.key, path[0])) {
                        return entry.value.getPath(path[1..]);
                    }
                }
                return null;
            },
            else => return null,
        }
    }

    /// Get a value from a table by key.
    pub fn get(self: *const Value, key: []const u8) ?*const Value {
        return switch (self.*) {
            .table => |t| {
                for (t.entries) |entry| {
                    if (std.mem.eql(u8, entry.key, key)) {
                        return entry.value;
                    }
                }
                return null;
            },
            else => null,
        };
    }
};

/// Parsed TOML document with memory ownership.
pub const Document = struct {
    root: *Value,
    arena: std.heap.ArenaAllocator,

    /// Free all memory associated with this document.
    pub fn deinit(self: *Document) void {
        self.arena.deinit();
    }

    /// Get a value by dot-separated path.
    pub fn getPath(self: *const Document, path: []const []const u8) ?*const Value {
        return self.root.getPath(path);
    }

    /// Get allocator for building values.
    pub fn allocator(self: *Document) Allocator {
        return self.arena.allocator();
    }
};

/// Create an empty table value.
pub fn createTable(alloc: Allocator) !*Value {
    const val = try alloc.create(Value);
    val.* = .{ .table = .{ .entries = &.{} } };
    return val;
}

/// Create an empty array value.
pub fn createArray(alloc: Allocator) !*Value {
    const val = try alloc.create(Value);
    val.* = .{ .array = .{ .items = &.{} } };
    return val;
}

/// Add or get a key in a table, returning the value pointer.
pub fn tableGetOrCreate(alloc: Allocator, table: *Value, key: []const u8) !*Value {
    std.debug.assert(table.* == .table);
    const t = &table.table;

    // Check if key exists
    for (t.entries) |entry| {
        if (std.mem.eql(u8, entry.key, key)) {
            return entry.value;
        }
    }

    // Create new entry
    const new_val = try createTable(alloc);
    const key_copy = try alloc.dupe(u8, key);

    var new_entries = try alloc.alloc(TableEntry, t.entries.len + 1);
    @memcpy(new_entries[0..t.entries.len], t.entries);
    new_entries[t.entries.len] = .{ .key = key_copy, .value = new_val };
    t.entries = new_entries;

    return new_val;
}

/// Set a value in a table.
pub fn tableSet(alloc: Allocator, table: *Value, key: []const u8, value: *Value) !void {
    std.debug.assert(table.* == .table);
    const t = &table.table;

    // Check if key exists
    for (t.entries) |*entry| {
        if (std.mem.eql(u8, entry.key, key)) {
            entry.value = value;
            return;
        }
    }

    // Create new entry
    const key_copy = try alloc.dupe(u8, key);
    var new_entries = try alloc.alloc(TableEntry, t.entries.len + 1);
    @memcpy(new_entries[0..t.entries.len], t.entries);
    new_entries[t.entries.len] = .{ .key = key_copy, .value = value };
    t.entries = new_entries;
}

/// Check if a table contains a key.
pub fn tableContains(table: *const Value, key: []const u8) bool {
    return switch (table.*) {
        .table => |t| {
            for (t.entries) |entry| {
                if (std.mem.eql(u8, entry.key, key)) return true;
            }
            return false;
        },
        else => false,
    };
}

/// Append a value to an array.
pub fn arrayAppend(alloc: Allocator, array: *Value, value: *Value) !void {
    std.debug.assert(array.* == .array);
    const a = &array.array;

    var new_items = try alloc.alloc(*Value, a.items.len + 1);
    @memcpy(new_items[0..a.items.len], a.items);
    new_items[a.items.len] = value;
    a.items = new_items;
}
