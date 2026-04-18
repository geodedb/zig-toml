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
                // `-offset` overflows when offset == i16.minInt (-32768)
                // because i16 cannot represent +32768. Use @abs to get an
                // unsigned u16 directly; valid TOML offsets are
                // [-23:59, +23:59] but the parser elsewhere validates the
                // range, so defensive handling here means even a
                // hand-constructed out-of-range Value cannot panic.
                const abs_offset: u16 = @abs(offset);
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

/// Table entry snapshot returned by `tableIterator`. The underlying
/// storage is a `std.StringArrayHashMapUnmanaged(*Value)`; this struct
/// exists only so callers (JSON emitter, accept tests) have a stable
/// shape to sort and iterate without reaching into hash-map internals.
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

    /// Insertion-ordered, hash-indexed table storage.
    /// O(1) get/put, iteration follows insertion order.
    pub const Table = struct {
        map: std.StringArrayHashMapUnmanaged(*Value) = .{},
        is_inline: bool = false,
        is_array_of_tables: bool = false,
        defined_explicitly: bool = false,
        defined_by_dotted_key: bool = false, // created implicitly via dotted key in key=value
        is_closed_inline: bool = false, // true for inline tables from { ... } syntax (cannot be extended)
    };

    pub const Array = struct {
        items: std.ArrayListUnmanaged(Value) = .empty,
        is_static: bool = false, // true if defined as [] syntax, not [[]]
    };

    /// Get a nested value by key path.
    pub fn getPath(self: *const Value, path: []const []const u8) ?*const Value {
        if (path.len == 0) return self;

        switch (self.*) {
            .table => |*t| {
                const child = t.map.get(path[0]) orelse return null;
                return child.getPath(path[1..]);
            },
            else => return null,
        }
    }

    /// Get a value from a table by key. O(1).
    pub fn get(self: *const Value, key: []const u8) ?*const Value {
        return switch (self.*) {
            .table => |*t| t.map.get(key),
            else => null,
        };
    }

    /// Return the integer payload if this value is tagged `.integer`,
    /// otherwise `null`. Does not perform type coercion (a `.float` of
    /// 1.0 returns `null`, not `1`). No panic on wrong tag.
    pub fn asI64(self: *const Value) ?i64 {
        return switch (self.*) {
            .integer => |i| i,
            else => null,
        };
    }

    /// Return the float payload if this value is tagged `.float`,
    /// otherwise `null`. No panic on wrong tag.
    pub fn asF64(self: *const Value) ?f64 {
        return switch (self.*) {
            .float => |f| f,
            else => null,
        };
    }

    /// Return the boolean payload if this value is tagged `.bool`,
    /// otherwise `null`.
    pub fn asBool(self: *const Value) ?bool {
        return switch (self.*) {
            .bool => |b| b,
            else => null,
        };
    }

    /// Return the string slice if this value is tagged `.string`,
    /// otherwise `null`. The returned slice is owned by whatever
    /// allocator built the Value (typically the document arena).
    pub fn asString(self: *const Value) ?[]const u8 {
        return switch (self.*) {
            .string => |s| s,
            else => null,
        };
    }

    /// Return a pointer to the Array struct if this value is tagged
    /// `.array`, otherwise `null`. The pointer is valid for the
    /// lifetime of the surrounding Value.
    pub fn asArray(self: *Value) ?*Array {
        return switch (self.*) {
            .array => &self.array,
            else => null,
        };
    }

    /// Return a pointer to the Table struct if this value is tagged
    /// `.table`, otherwise `null`. The pointer is valid for the
    /// lifetime of the surrounding Value.
    pub fn asTable(self: *Value) ?*Table {
        return switch (self.*) {
            .table => &self.table,
            else => null,
        };
    }

    /// Return a `ValueIterator` dispatched on the value's tag:
    /// - `.table`  → `.table_iter` (yields `{ key, value: *Value }`)
    /// - `.array`  → `.array_iter` (yields `*Value`)
    /// - other     → `.empty`
    ///
    /// The iterator borrows the underlying slices and stays valid for
    /// the lifetime of this Value. Mutations to the table/array that
    /// grow the backing storage (e.g. via `tableSetOwned`) invalidate
    /// the iterator — do not mutate while iterating.
    ///
    /// Note: `ArrayIter` returns `*Value` pointers into the array's
    /// backing slice. Growing the array via `arrayAppendOwned` may
    /// reallocate that slice and invalidate previously-yielded
    /// pointers.
    pub fn iterator(self: *const Value) ValueIterator {
        return switch (self.*) {
            .table => |*t| .{ .table_iter = .{
                .keys = t.map.keys(),
                .values = t.map.values(),
                .index = 0,
            } },
            .array => |*a| .{ .array_iter = .{
                .items = a.items.items,
                .index = 0,
            } },
            else => .empty,
        };
    }
};

/// Key-value pair yielded by `TableIter.next()`. Both `key` and
/// `value` are borrows: they stay valid for the lifetime of the
/// underlying Value (typically the document arena).
pub const TableIterEntry = struct {
    key: []const u8,
    value: *Value,
};

/// Ordered iterator over a table's key-value pairs. Yields entries in
/// the order they were inserted (the same order the TOML document
/// declared them). Obtained via `Value.iterator()` on a `.table` value.
pub const TableIter = struct {
    keys: []const []const u8,
    values: []const *Value,
    index: usize = 0,

    pub fn next(self: *TableIter) ?TableIterEntry {
        if (self.index >= self.keys.len) return null;
        const entry: TableIterEntry = .{
            .key = self.keys[self.index],
            .value = self.values[self.index],
        };
        self.index += 1;
        return entry;
    }

    /// Reset the iterator so the next `next()` call yields the first
    /// entry again. Useful for callers that want to make multiple
    /// passes without re-calling `Value.iterator()`.
    pub fn reset(self: *TableIter) void {
        self.index = 0;
    }
};

/// Ordered iterator over an array's items. Yields `*Value` pointers
/// in index order. Pointers index into the array's backing slice; do
/// not mutate the array while iterating. Obtained via
/// `Value.iterator()` on a `.array` value.
pub const ArrayIter = struct {
    items: []Value,
    index: usize = 0,

    pub fn next(self: *ArrayIter) ?*Value {
        if (self.index >= self.items.len) return null;
        const v = &self.items[self.index];
        self.index += 1;
        return v;
    }

    pub fn reset(self: *ArrayIter) void {
        self.index = 0;
    }
};

/// Tagged iterator returned by `Value.iterator()`. The caller is
/// expected to know which tag they are iterating (`table_iter` or
/// `array_iter`) and index the matching arm. For non-table/non-array
/// values, `Value.iterator()` returns `.empty`.
pub const ValueIterator = union(enum) {
    table_iter: TableIter,
    array_iter: ArrayIter,
    empty: void,
};

/// Parsed TOML document with memory ownership.
///
/// A Document is always held via pointer (`*Document`). The underlying
/// ArenaAllocator is stored by pointer so the Document can never be
/// moved or copied into a new address — doing so would invalidate the
/// internal pointers `arena.allocator()` embeds into every Allocator
/// handle it hands out.
///
/// Obtain via `toml.parse` (which returns `*Document`) and destroy via
/// `doc.deinit()` (which frees the arena *and* the Document struct
/// itself, which was allocated on the caller's allocator).
pub const Document = struct {
    root: *Value,
    arena: *std.heap.ArenaAllocator,
    /// The allocator the Document struct and its arena were created on;
    /// used by `deinit` to free both.
    gpa: Allocator,

    /// Free all memory associated with this document, including the
    /// Document struct itself. After this call, the `*Document` pointer
    /// is dangling; do not reuse it.
    pub fn deinit(self: *Document) void {
        const gpa = self.gpa;
        self.arena.deinit();
        gpa.destroy(self.arena);
        gpa.destroy(self);
    }

    /// Get a value by dot-separated path.
    pub fn getPath(self: *const Document, path: []const []const u8) ?*const Value {
        return self.root.getPath(path);
    }

    /// Get the arena allocator for building values into this Document.
    pub fn allocator(self: *Document) Allocator {
        return self.arena.allocator();
    }
};

/// Create an empty Document on the given allocator. Used by tests and
/// by `Parser.parse`. The returned pointer must be freed via `deinit`.
pub fn createDocument(gpa: Allocator) !*Document {
    const arena_ptr = try gpa.create(std.heap.ArenaAllocator);
    errdefer gpa.destroy(arena_ptr);
    arena_ptr.* = std.heap.ArenaAllocator.init(gpa);
    errdefer arena_ptr.deinit();

    const doc = try gpa.create(Document);
    errdefer gpa.destroy(doc);

    const root = try createTable(arena_ptr.allocator());
    doc.* = .{
        .root = root,
        .arena = arena_ptr,
        .gpa = gpa,
    };
    return doc;
}

/// Create an empty table value on the given allocator.
pub fn createTable(alloc: Allocator) !*Value {
    const v = try alloc.create(Value);
    v.* = .{ .table = .{} };
    return v;
}

/// Create an empty array value on the given allocator.
pub fn createArray(alloc: Allocator) !*Value {
    const v = try alloc.create(Value);
    v.* = .{ .array = .{} };
    return v;
}

/// Get-or-create a child table by key. Returns the existing pointer if
/// the key is already present (even if its value is not a table — caller
/// is responsible for that invariant). O(1).
pub fn tableGetOrCreate(alloc: Allocator, table: *Value, key: []const u8) !*Value {
    std.debug.assert(table.* == .table);
    const t = &table.table;

    const gop = try t.map.getOrPut(alloc, key);
    if (!gop.found_existing) {
        gop.value_ptr.* = try createTable(alloc);
    }
    return gop.value_ptr.*;
}

/// Set a value in a table by key. Overwrites if the key already exists.
/// The key slice is stored as-is; callers that need to own the bytes
/// (e.g. parser paths that synthesize key text) must dupe before calling.
/// O(1).
pub fn tableSet(alloc: Allocator, table: *Value, key: []const u8, value: *Value) !void {
    std.debug.assert(table.* == .table);
    const t = &table.table;
    try t.map.put(alloc, key, value);
}

/// Check if a table contains a key. O(1).
pub fn tableContains(table: *const Value, key: []const u8) bool {
    return switch (table.*) {
        .table => |*t| t.map.contains(key),
        else => false,
    };
}

/// Return the number of entries in a table.
pub fn tableLen(table: *const Value) usize {
    return switch (table.*) {
        .table => |*t| t.map.count(),
        else => 0,
    };
}

/// Iterator over a table in insertion order.
pub const TableIterator = struct {
    keys: []const []const u8,
    values: []const *Value,
    i: usize,

    pub fn next(self: *TableIterator) ?TableEntry {
        if (self.i >= self.keys.len) return null;
        const entry: TableEntry = .{
            .key = self.keys[self.i],
            .value = self.values[self.i],
        };
        self.i += 1;
        return entry;
    }
};

/// Return an iterator that yields table entries in insertion order.
/// Panics (in debug) if `table` is not a table.
pub fn tableIterator(table: *const Value) TableIterator {
    std.debug.assert(table.* == .table);
    const t = &table.table;
    return .{
        .keys = t.map.keys(),
        .values = t.map.values(),
        .i = 0,
    };
}

/// Append a value to an array. O(1) amortized.
///
/// Takes `value` by value: the Value's representation is copied into the
/// array's contiguous storage. Scalar/table leaves own heap-resident data
/// (strings, inner table maps) that remains valid because only the thin
/// tag-plus-payload is moved, not the referenced storage.
pub fn arrayAppend(alloc: Allocator, array: *Value, value: Value) !void {
    std.debug.assert(array.* == .array);
    const a = &array.array;
    try a.items.append(alloc, value);
}

/// Append a table to an array-of-tables and return a pointer to the tail
/// slot so the parser can continue populating the table in place. After
/// the move to by-value Array storage, the parser cannot keep its
/// freshly created `*Value` table pointer because the table lives inside
/// the array's backing slice, not in a standalone heap allocation.
pub fn arrayAppendTable(alloc: Allocator, array: *Value, table: *Value) !*Value {
    std.debug.assert(array.* == .array);
    std.debug.assert(table.* == .table);
    const a = &array.array;
    try a.items.append(alloc, table.*);
    return &a.items.items[a.items.items.len - 1];
}

/// Return the number of items in an array.
pub fn arrayLen(array: *const Value) usize {
    return switch (array.*) {
        .array => |*a| a.items.items.len,
        else => 0,
    };
}

/// Return the items slice of an array (insertion order).
pub fn arrayItems(array: *const Value) []const Value {
    std.debug.assert(array.* == .array);
    return array.array.items.items;
}

test "U-T DateTime.format handles i16.minInt offset without panic" {
    // The parser validates offsets to [-23:59, +23:59], but a caller
    // constructing DateTime directly could place any i16 in
    // offset_minutes. The previous `-offset` negation overflowed on
    // i16.minInt. Assert format() now completes without panicking.
    const dt = DateTime{
        .year = 2024,
        .month = 1,
        .day = 15,
        .hour = 10,
        .minute = 30,
        .second = 0,
        .nanosecond = 0,
        .offset_minutes = std.math.minInt(i16), // -32768
    };
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    // Calling format() is the property being tested; no panic and some
    // bytes written are the assertions. The exact offset string is not
    // contractual since the input is already out of TOML spec range.
    try dt.format(&aw.writer);
    try std.testing.expect(aw.written().len > 0);
}

test "C-1 tableSet preserves insertion order for N keys" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const aa = arena.allocator();

    const root = try createTable(aa);

    var i: usize = 0;
    var name_buf: [32]u8 = undefined;
    while (i < 1000) : (i += 1) {
        const name = try std.fmt.bufPrint(&name_buf, "k{d}", .{i});
        const v = try aa.create(Value);
        v.* = .{ .integer = @intCast(i) };
        // name_buf is reused each loop; dupe so the table owns stable bytes.
        const owned = try aa.dupe(u8, name);
        try tableSet(aa, root, owned, v);
    }

    // Iterate and assert we see exactly k0, k1, ..., k999 in order.
    var idx: usize = 0;
    var it = tableIterator(root);
    while (it.next()) |entry| : (idx += 1) {
        var expect_buf: [32]u8 = undefined;
        const expect_name = try std.fmt.bufPrint(&expect_buf, "k{d}", .{idx});
        try std.testing.expectEqualStrings(expect_name, entry.key);
        try std.testing.expectEqual(@as(i64, @intCast(idx)), entry.value.integer);
    }
    try std.testing.expectEqual(@as(usize, 1000), idx);
}

test "C-2 tableSet on existing key overwrites without growing" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const aa = arena.allocator();

    const root = try createTable(aa);

    const v1 = try aa.create(Value);
    v1.* = .{ .integer = 1 };
    try tableSet(aa, root, "k", v1);

    const v2 = try aa.create(Value);
    v2.* = .{ .integer = 2 };
    try tableSet(aa, root, "k", v2);

    try std.testing.expectEqual(@as(usize, 1), tableLen(root));
    const got = root.get("k") orelse unreachable;
    try std.testing.expectEqual(@as(i64, 2), got.integer);
}

test "C-3 tableGetOrCreate returns existing pointer on second call" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const aa = arena.allocator();

    const root = try createTable(aa);
    const a = try tableGetOrCreate(aa, root, "x");
    const b = try tableGetOrCreate(aa, root, "x");
    try std.testing.expectEqual(a, b);
    try std.testing.expectEqual(@as(usize, 1), tableLen(root));
}

test "C-4 tableContains is true after insert, false for missing" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const aa = arena.allocator();

    const root = try createTable(aa);
    const v = try aa.create(Value);
    v.* = .{ .integer = 42 };
    try tableSet(aa, root, "present", v);

    try std.testing.expect(tableContains(root, "present"));
    try std.testing.expect(!tableContains(root, "absent"));
}

test "U-V asI64 returns value for integer, null for other tags" {
    const v_int: Value = .{ .integer = 42 };
    try std.testing.expectEqual(@as(?i64, 42), v_int.asI64());

    const v_str: Value = .{ .string = "hello" };
    try std.testing.expectEqual(@as(?i64, null), v_str.asI64());

    const v_bool: Value = .{ .bool = true };
    try std.testing.expectEqual(@as(?i64, null), v_bool.asI64());
}

test "U-V asF64 returns value for float, null for other tags" {
    const v_flt: Value = .{ .float = 3.14 };
    try std.testing.expectEqual(@as(?f64, 3.14), v_flt.asF64());

    const v_int: Value = .{ .integer = 42 };
    try std.testing.expectEqual(@as(?f64, null), v_int.asF64());
}

test "U-V asBool returns value for bool, null for other tags" {
    const v_t: Value = .{ .bool = true };
    try std.testing.expectEqual(@as(?bool, true), v_t.asBool());

    const v_f: Value = .{ .bool = false };
    try std.testing.expectEqual(@as(?bool, false), v_f.asBool());

    const v_int: Value = .{ .integer = 0 };
    try std.testing.expectEqual(@as(?bool, null), v_int.asBool());
}

test "U-V asString returns slice for string, null for other tags" {
    const v_str: Value = .{ .string = "hello" };
    try std.testing.expectEqualStrings("hello", v_str.asString().?);

    const v_int: Value = .{ .integer = 0 };
    try std.testing.expectEqual(@as(?[]const u8, null), v_int.asString());
}

test "U-V asArray returns pointer for array, null for other tags" {
    var v_arr: Value = .{ .array = .{} };
    try std.testing.expect(v_arr.asArray() != null);

    var v_int: Value = .{ .integer = 0 };
    try std.testing.expect(v_int.asArray() == null);
}

test "U-V asTable returns pointer for table, null for other tags" {
    var v_tbl: Value = .{ .table = .{} };
    try std.testing.expect(v_tbl.asTable() != null);

    var v_int: Value = .{ .integer = 0 };
    try std.testing.expect(v_int.asTable() == null);
}

test "U-V TableIter yields all entries in insertion order" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const tbl = try createTable(alloc);

    // Insert five values in a fixed order. The iterator must yield
    // them back in the same order (not hash order, not sorted order).
    const keys = [_][]const u8{ "alpha", "beta", "gamma", "delta", "epsilon" };
    for (keys, 0..) |k, i| {
        const leaf = try alloc.create(Value);
        leaf.* = .{ .integer = @intCast(i) };
        try tableSet(alloc, tbl, k, leaf);
    }

    var it = tbl.iterator().table_iter;
    var idx: usize = 0;
    while (it.next()) |pair| : (idx += 1) {
        try std.testing.expect(idx < keys.len);
        try std.testing.expectEqualStrings(keys[idx], pair.key);
        try std.testing.expectEqual(@as(i64, @intCast(idx)), pair.value.integer);
    }
    try std.testing.expectEqual(keys.len, idx);
}

test "U-V ArrayIter yields all items in index order" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const arr = try createArray(alloc);
    var i: i64 = 0;
    while (i < 5) : (i += 1) {
        // Array stores Values by value; append the payload directly.
        try arrayAppend(alloc, arr, .{ .integer = i * 10 });
    }

    var it = arr.iterator().array_iter;
    var count: i64 = 0;
    while (it.next()) |v| : (count += 1) {
        try std.testing.expectEqual(count * 10, v.integer);
    }
    try std.testing.expectEqual(@as(i64, 5), count);
}

test "U-V iterator() on non-container returns .empty" {
    const v_int: Value = .{ .integer = 1 };
    switch (v_int.iterator()) {
        .empty => {},
        else => try std.testing.expect(false),
    }

    const v_str: Value = .{ .string = "x" };
    switch (v_str.iterator()) {
        .empty => {},
        else => try std.testing.expect(false),
    }
}

test "U-V ArrayIter on empty array yields nothing" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const arr = try createArray(arena.allocator());
    var it = arr.iterator().array_iter;
    try std.testing.expect(it.next() == null);
    try std.testing.expect(it.next() == null); // idempotent after exhaustion
}

test "U-V TableIter on empty table yields nothing" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const tbl = try createTable(arena.allocator());
    var it = tbl.iterator().table_iter;
    try std.testing.expect(it.next() == null);
    try std.testing.expect(it.next() == null);
}

test "U-V TableIter.reset allows two full passes" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const tbl = try createTable(alloc);
    const keys = [_][]const u8{ "a", "b" };
    for (keys) |k| {
        const leaf = try alloc.create(Value);
        leaf.* = .{ .integer = 0 };
        try tableSet(alloc, tbl, k, leaf);
    }

    var it = tbl.iterator().table_iter;
    var pass1: usize = 0;
    while (it.next()) |_| pass1 += 1;
    try std.testing.expectEqual(@as(usize, 2), pass1);

    it.reset();
    var pass2: usize = 0;
    while (it.next()) |_| pass2 += 1;
    try std.testing.expectEqual(@as(usize, 2), pass2);
}
