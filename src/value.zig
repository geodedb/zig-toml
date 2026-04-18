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
