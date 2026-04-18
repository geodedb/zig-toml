# Public Mutation API Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Promote the internal `tableSet` / `arrayAppend` / `tableGetOrCreate` helpers to a first-class public mutation surface on `Value` and `Document`, add typed accessor helpers (`asI64`, `asString`, ...), iterators (`TableIter`, `ArrayIter`), and a `Document.setPath` dotted-path mutator.

**Architecture:** Extend `src/value.zig` only — no parser, lexer, or JSON-emitter changes. Add pure methods on `Value` and `Document`, plus keep the existing free functions intact for parser back-compat. All mutations go through an externally supplied `Allocator` (typically the document arena via `doc.allocator()`), so ownership semantics match the rest of the library. `setPath` splits dotted input, walks/creates intermediate `table` values, and sets the leaf via the same helpers used by the parser — intentionally the same code path to avoid behavioural drift.

**Tech Stack:** Zig 0.15+, `std.mem.Allocator`, `std.mem.eql`, `std.mem.splitScalar`. No new dependencies.

**Gaps closed:**

- GAP-0009 — public mutable Value API (mutation helpers currently internal-only)
- GAP-0012 — table/array iterators
- GAP-0013 — path-based setter (only `getPath` exists today)
- GAP-0014 — typed conversion helpers (`asI64`, `asString`, `asBool`, etc.)

---

## File Structure

All implementation lives in `src/value.zig`. No new files, no restructure.

- **Modify:** `src/value.zig` — add `asX()` typed accessors, `TableIter`, `ArrayIter`, `Value.iterator()`, `Value.tableSetOwned`, `Value.tableGetOrCreateOwned`, `Value.arrayAppendOwned`, `Document.setPath`, `Document.setPathSegments`. Existing free functions (`tableSet`, `tableGetOrCreate`, `arrayAppend`, `tableContains`) remain as-is so the parser keeps compiling; the public methods delegate into them.
- **Modify:** `docs/API.md` — document every new symbol under a new "Mutation API" section.
- **Modify:** `CHANGELOG.md` — add entries under `[Unreleased] / Added` for each gap closed.
- **Create:** `examples/mutation.zig` — runnable example building a `Document` programmatically using the new API.

### Value field/type reference (DO NOT INVENT NEW NAMES)

The **actual** `Value` shape in `src/value.zig` is a tagged union with these arms (the task request's quick-sketch used slightly different names — ignore the sketch, follow the code):

```zig
pub const ValueTag = enum {
    table, array, string, integer, float, bool,
    datetime, datetime_local, date_local, time_local,
};

pub const Value = union(ValueTag) {
    table: Table,            // struct { entries: []TableEntry, is_inline: bool, ... }
    array: Array,            // struct { items: []*Value, is_static: bool }
    string: []const u8,
    integer: i64,
    float: f64,
    bool: bool,
    datetime: DateTime,
    datetime_local: DateTimeLocal,
    date_local: DateLocal,
    time_local: TimeLocal,
};
```

The existing getter `Value.getPath` takes `path: []const []const u8` (array-of-segments), **NOT** a dotted string. The new `Document.setPath` accepts a dotted string for symmetry with how users naturally type paths; `Document.setPathSegments` is the segment-array counterpart that mirrors the existing getter exactly.

---

## Task 1: Write failing tests for typed accessors

**Files:**

- Modify: `src/value.zig` (append tests at bottom of file, after the existing `test "U-T DateTime.format handles i16.minInt offset without panic"` block around line 308)

- [ ] **Step 1: Write the failing tests**

Append at the end of `src/value.zig`:

```zig
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
    var items_buf: [0]*Value = .{};
    var v_arr: Value = .{ .array = .{ .items = items_buf[0..] } };
    try std.testing.expect(v_arr.asArray() != null);

    var v_int: Value = .{ .integer = 0 };
    try std.testing.expect(v_int.asArray() == null);
}

test "U-V asTable returns pointer for table, null for other tags" {
    var entries_buf: [0]TableEntry = .{};
    var v_tbl: Value = .{ .table = .{ .entries = entries_buf[0..] } };
    try std.testing.expect(v_tbl.asTable() != null);

    var v_int: Value = .{ .integer = 0 };
    try std.testing.expect(v_int.asTable() == null);
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `zig build test 2>&1 | head -60`
Expected: Compile error or test failure naming `asI64`, `asF64`, `asBool`, `asString`, `asArray`, `asTable` as undefined on `Value`.

---

## Task 2: Implement typed accessors (`asI64`, `asF64`, `asBool`, `asString`, `asArray`, `asTable`)

**Files:**

- Modify: `src/value.zig:189-201` (insert new methods on `Value` between the existing `get` method and the closing `};` of the `Value` union)

- [ ] **Step 1: Add the method implementations inside the `Value` union**

Insert directly after the existing `get` method (which ends at line 201 with `};`) and before the closing `};` of the `Value` union:

```zig
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
```

- [ ] **Step 2: Run tests to verify they pass**

Run: `zig build test 2>&1 | tail -20`
Expected: All tests pass, including the six new `U-V as*` tests.

- [ ] **Step 3: Run `zig build check` to confirm clean compile**

Run: `zig build check`
Expected: Exit 0, no output.

---

## Task 3: Commit typed accessors

- [ ] **Step 1: Stage and commit**

```bash
git add src/value.zig
git commit -m "feat(value): close GAP-0014 — typed accessors on Value

Add asI64, asF64, asBool, asString, asArray, asTable methods that
return optionals instead of panicking on tag mismatch. Replaces the
switch-on-tag boilerplate callers were previously forced to write.

Closes: GAP-0014"
```

- [ ] **Step 2: Verify clean status**

Run: `git status`
Expected: `nothing to commit, working tree clean`.

---

## Task 4: Write failing test — table iterator yields all entries in insertion order

**Files:**

- Modify: `src/value.zig` (append test at bottom)

- [ ] **Step 1: Write the failing test**

Append at the end of `src/value.zig`:

```zig
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test 2>&1 | tail -20`
Expected: Compile error — `iterator` / `TableIter` / `table_iter` undefined on `Value`.

---

## Task 5: Implement `TableIter`, `ArrayIter`, `ValueIterator`, and the `iterator()` stub

**Files:**

- Modify: `src/value.zig` — add iterator types at file scope (after the `Value` union's closing `};`, before the `Document` struct declaration) and the `iterator()` method inside the `Value` union

- [ ] **Step 1: Add the three iterator types at file scope**

Insert directly after the `Value` union's closing `};` (around line 202) and before the `Document` struct declaration:

```zig
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
    entries: []const TableEntry,
    index: usize = 0,

    pub fn next(self: *TableIter) ?TableIterEntry {
        if (self.index >= self.entries.len) return null;
        const e = self.entries[self.index];
        self.index += 1;
        return .{ .key = e.key, .value = e.value };
    }

    /// Reset the iterator so the next `next()` call yields the first
    /// entry again. Useful for callers that want to make multiple
    /// passes without re-calling `Value.iterator()`.
    pub fn reset(self: *TableIter) void {
        self.index = 0;
    }
};

/// Ordered iterator over an array's items. Yields `*Value` pointers
/// in index order. Obtained via `Value.iterator()` on a `.array`
/// value.
pub const ArrayIter = struct {
    items: []const *Value,
    index: usize = 0,

    pub fn next(self: *ArrayIter) ?*Value {
        if (self.index >= self.items.len) return null;
        const v = self.items[self.index];
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
```

- [ ] **Step 2: Add the `iterator()` method on `Value`**

Insert inside the `Value` union, immediately after `asTable` (added in Task 2) and before the union's closing `};`:

```zig
    /// Return a `ValueIterator` dispatched on the value's tag:
    /// - `.table`  → `.table_iter` (yields `{ key, value: *Value }`)
    /// - `.array`  → `.array_iter` (yields `*Value`)
    /// - other     → `.empty`
    ///
    /// The iterator borrows the underlying slice and stays valid for
    /// the lifetime of this Value. Mutations to the table/array that
    /// grow the backing slice (e.g. via `tableSetOwned`) invalidate
    /// the iterator — do not mutate while iterating.
    pub fn iterator(self: *const Value) ValueIterator {
        return switch (self.*) {
            .table => |t| .{ .table_iter = .{ .entries = t.entries } },
            .array => |a| .{ .array_iter = .{ .items = a.items } },
            else => .empty,
        };
    }
```

- [ ] **Step 3: Run tests to verify the Task-4 table-iterator test passes**

Run: `zig build test 2>&1 | tail -20`
Expected: All tests pass, including `U-V TableIter yields all entries in insertion order`.

- [ ] **Step 4: Run `zig build check`**

Run: `zig build check`
Expected: Exit 0, no output.

---

## Task 6: Write test — array iterator yields all items in index order

**Files:**

- Modify: `src/value.zig` (append tests at bottom)

- [ ] **Step 1: Write the tests**

Append at the end of `src/value.zig`:

```zig
test "U-V ArrayIter yields all items in index order" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const arr = try createArray(alloc);
    var i: i64 = 0;
    while (i < 5) : (i += 1) {
        const leaf = try alloc.create(Value);
        leaf.* = .{ .integer = i * 10 };
        try arrayAppend(alloc, arr, leaf);
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
```

- [ ] **Step 2: Run the tests**

Run: `zig build test 2>&1 | tail -20`
Expected: Both tests pass — Task 5 implemented the ArrayIter and `.empty` dispatch already, so these tests lock in the behaviour rather than drive new code. If they fail, revisit the Task-5 implementation.

---

## Task 7: Add iterator corner-case tests (empty arrays/tables, reset)

**Files:**

- Modify: `src/value.zig` (append tests)

- [ ] **Step 1: Add corner-case tests**

```zig
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
```

- [ ] **Step 2: Run tests**

Run: `zig build test 2>&1 | tail -20`
Expected: All three tests pass without further code changes.

---

## Task 8: Iterator-dispatch housekeeping checkpoint

This task is a housekeeping checkpoint, not code. The Task-4 test drove the `TableIter` implementation, and Task 5 added `ArrayIter` + `iterator()` in the same commit-unit because both are trivially symmetric; Tasks 6-7 added coverage.

- [ ] **Step 1: Full test suite confirmation**

Run: `zig build test 2>&1 | tail -10`
Expected: `Build Summary: <N>/N steps succeeded` with zero test failures.

---

## Task 9: Commit iterators

- [ ] **Step 1: Stage and commit**

```bash
git add src/value.zig
git commit -m "feat(value): close GAP-0012 — table and array iterators

Add TableIter, ArrayIter, ValueIterator, and Value.iterator() that
dispatches on the tag. Tables iterate in insertion order; arrays in
index order. Non-container values return .empty. Reset is supported
for multi-pass iteration.

Closes: GAP-0012"
```

- [ ] **Step 2: Verify clean tree**

Run: `git status`
Expected: `nothing to commit, working tree clean`.

---

## Task 10: Write failing test — `Document.setPath` creates intermediate tables

**Files:**

- Modify: `src/value.zig` (append test)

- [ ] **Step 1: Write the failing test**

Append at the end of `src/value.zig`:

```zig
test "U-V Document.setPath creates intermediate tables and sets leaf" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    // No defer on arena here — `doc` owns the arena after we transfer
    // it. But we never exit without calling doc.deinit(), so it's fine.

    const root = try createTable(arena.allocator());
    var doc = Document{ .root = root, .arena = arena };
    defer doc.deinit();

    const leaf = try doc.allocator().create(Value);
    leaf.* = .{ .integer = 42 };

    try doc.setPath("a.b.c", leaf);

    const path = &[_][]const u8{ "a", "b", "c" };
    const got = doc.getPath(path) orelse unreachable;
    try std.testing.expectEqual(@as(i64, 42), got.integer);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test 2>&1 | tail -10`
Expected: Compile error — `setPath` undefined on `Document`.

---

## Task 11: Implement `Document.setPath` and `Document.setPathSegments`

**Files:**

- Modify: `src/value.zig:205-223` (inside the `Document` struct)

- [ ] **Step 1: Add the two methods inside the `Document` struct**

Insert directly after the existing `pub fn allocator` method and before the closing `};` of `Document`:

```zig
    /// Set a value at a dotted key path, creating intermediate
    /// tables as needed. Accepts input in the same form a user would
    /// type in a TOML document (`"server.db.host"`).
    ///
    /// Dots inside quoted segments are NOT handled — this is the
    /// library-level dotted key shape, not TOML's full quoted-key
    /// grammar. For a segment containing a dot, use
    /// `setPathSegments(&.{"literal.with.dots", ...}, value)`.
    ///
    /// Collision rules:
    /// - If an intermediate segment already points at a non-table
    ///   value, returns `error.PathCollision`.
    /// - If the leaf key already exists, it is overwritten and the
    ///   old value is leaked into the arena (arena-reclaim on deinit
    ///   is sufficient for the typical use case).
    ///
    /// The `leaf` Value must already be allocated out of this
    /// document's allocator (`doc.allocator()`).
    pub fn setPath(
        self: *Document,
        path: []const u8,
        leaf: *Value,
    ) !void {
        // Collect segments into a small stack buffer. TOML's practical
        // nesting ceiling is well below 64 — the parser's default
        // max_depth is similarly bounded.
        var seg_buf: [64][]const u8 = undefined;
        var n: usize = 0;
        var it = std.mem.splitScalar(u8, path, '.');
        while (it.next()) |seg| {
            if (n == seg_buf.len) return error.PathTooDeep;
            if (seg.len == 0) return error.EmptyPathSegment;
            seg_buf[n] = seg;
            n += 1;
        }
        if (n == 0) return error.EmptyPath;
        try self.setPathSegments(seg_buf[0..n], leaf);
    }

    /// Segment-array counterpart of `setPath`. Mirrors the shape of
    /// `Document.getPath`, which also takes `[]const []const u8`.
    /// Use this when any segment contains a literal `.`.
    pub fn setPathSegments(
        self: *Document,
        segments: []const []const u8,
        leaf: *Value,
    ) !void {
        if (segments.len == 0) return error.EmptyPath;
        const alloc = self.allocator();
        var cursor: *Value = self.root;
        var i: usize = 0;
        while (i + 1 < segments.len) : (i += 1) {
            if (cursor.* != .table) return error.PathCollision;
            const next_val = try tableGetOrCreate(alloc, cursor, segments[i]);
            if (next_val.* != .table) return error.PathCollision;
            cursor = next_val;
        }
        if (cursor.* != .table) return error.PathCollision;
        try tableSet(alloc, cursor, segments[segments.len - 1], leaf);
    }
```

- [ ] **Step 2: Run tests**

Run: `zig build test 2>&1 | tail -10`
Expected: All tests pass, including `U-V Document.setPath creates intermediate tables and sets leaf`.

---

## Task 12: Write corner-case tests for `setPath`

**Files:**

- Modify: `src/value.zig` (append tests)

- [ ] **Step 1: Add tests covering overwrite, collision, single-segment, empty-input, and dots-in-segment flows**

```zig
test "U-V Document.setPath overwrites existing leaf" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    const root = try createTable(arena.allocator());
    var doc = Document{ .root = root, .arena = arena };
    defer doc.deinit();

    const first = try doc.allocator().create(Value);
    first.* = .{ .integer = 1 };
    try doc.setPath("x", first);

    const second = try doc.allocator().create(Value);
    second.* = .{ .integer = 2 };
    try doc.setPath("x", second);

    const path = &[_][]const u8{"x"};
    const got = doc.getPath(path) orelse unreachable;
    try std.testing.expectEqual(@as(i64, 2), got.integer);
}

test "U-V Document.setPath collides with non-table intermediate" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    const root = try createTable(arena.allocator());
    var doc = Document{ .root = root, .arena = arena };
    defer doc.deinit();

    // Plant an integer at "a" so walking "a.b" must fail.
    const scalar = try doc.allocator().create(Value);
    scalar.* = .{ .integer = 7 };
    try doc.setPath("a", scalar);

    const leaf = try doc.allocator().create(Value);
    leaf.* = .{ .integer = 99 };
    const err = doc.setPath("a.b", leaf);
    try std.testing.expectError(error.PathCollision, err);
}

test "U-V Document.setPath on empty doc with single segment" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    const root = try createTable(arena.allocator());
    var doc = Document{ .root = root, .arena = arena };
    defer doc.deinit();

    const leaf = try doc.allocator().create(Value);
    leaf.* = .{ .string = "ok" };
    try doc.setPath("only", leaf);

    const path = &[_][]const u8{"only"};
    const got = doc.getPath(path) orelse unreachable;
    try std.testing.expectEqualStrings("ok", got.string);
}

test "U-V Document.setPath rejects empty and empty-segment paths" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    const root = try createTable(arena.allocator());
    var doc = Document{ .root = root, .arena = arena };
    defer doc.deinit();

    const leaf = try doc.allocator().create(Value);
    leaf.* = .{ .integer = 0 };
    try std.testing.expectError(error.EmptyPath, doc.setPath("", leaf));
    try std.testing.expectError(error.EmptyPathSegment, doc.setPath("a..b", leaf));
}

test "U-V Document.setPathSegments allows segments containing dots" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    const root = try createTable(arena.allocator());
    var doc = Document{ .root = root, .arena = arena };
    defer doc.deinit();

    const leaf = try doc.allocator().create(Value);
    leaf.* = .{ .integer = 123 };

    // One of the segments literally contains a dot. The dotted-string
    // form of setPath would split this incorrectly; setPathSegments
    // preserves it.
    const segs = &[_][]const u8{ "root", "v1.2.3", "value" };
    try doc.setPathSegments(segs, leaf);

    const got = doc.getPath(segs) orelse unreachable;
    try std.testing.expectEqual(@as(i64, 123), got.integer);
}
```

- [ ] **Step 2: Run tests**

Run: `zig build test 2>&1 | tail -20`
Expected: All five new tests pass.

- [ ] **Step 3: Run `zig build check`**

Run: `zig build check`
Expected: Exit 0.

---

## Task 13: Commit `setPath`

- [ ] **Step 1: Stage and commit**

```bash
git add src/value.zig
git commit -m "feat(document): close GAP-0013 — setPath mutator

Add Document.setPath(path, value) and Document.setPathSegments for
dotted-path writes, creating intermediate tables as needed. Returns
error.PathCollision when an intermediate segment is a non-table,
error.EmptyPath/EmptyPathSegment on malformed input. Mirrors the
shape of the existing getPath getter.

Closes: GAP-0013"
```

- [ ] **Step 2: Verify clean tree**

Run: `git status`
Expected: `nothing to commit, working tree clean`.

---

## Task 14: Write failing tests for public `tableSetOwned` / `arrayAppendOwned` / `tableGetOrCreateOwned` methods on `Value`

**Files:**

- Modify: `src/value.zig` (append tests)

- [ ] **Step 1: Write the failing tests**

```zig
test "U-V Value.tableSetOwned is the public method form of tableSet" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const tbl = try createTable(alloc);
    const leaf = try alloc.create(Value);
    leaf.* = .{ .integer = 1 };

    try tbl.tableSetOwned(alloc, "k", leaf);
    const got = tbl.get("k") orelse unreachable;
    try std.testing.expectEqual(@as(i64, 1), got.integer);
}

test "U-V Value.arrayAppendOwned is the public method form of arrayAppend" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const arr = try createArray(alloc);
    const leaf = try alloc.create(Value);
    leaf.* = .{ .integer = 7 };

    try arr.arrayAppendOwned(alloc, leaf);
    try std.testing.expectEqual(@as(usize, 1), arr.array.items.len);
    try std.testing.expectEqual(@as(i64, 7), arr.array.items[0].integer);
}

test "U-V Value.tableGetOrCreateOwned returns existing or new child table" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const tbl = try createTable(alloc);
    const first = try tbl.tableGetOrCreateOwned(alloc, "sub");
    try std.testing.expect(first.* == .table);

    // Second call returns the same pointer (no duplicate insertion).
    const second = try tbl.tableGetOrCreateOwned(alloc, "sub");
    try std.testing.expect(first == second);
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `zig build test 2>&1 | tail -20`
Expected: Compile error — `tableSetOwned`, `arrayAppendOwned`, `tableGetOrCreateOwned` undefined on `Value`.

---

## Task 15: Implement the public `Value` methods as thin wrappers

**Files:**

- Modify: `src/value.zig` — inside the `Value` union, adjacent to `iterator()` (added in Task 5)

- [ ] **Step 1: Add the three methods inside the `Value` union**

Insert after `iterator()` and before the closing `};` of the `Value` union:

```zig
    /// Insert or overwrite `key` in this table. Takes ownership of
    /// `value` in the sense that the caller MUST have allocated it
    /// using `alloc` (or a parent arena) — no copy is made. The
    /// `key` is duplicated into `alloc`.
    ///
    /// Allocator ownership: pass the same allocator used to build
    /// the containing `Document` (typically `doc.allocator()`). Using
    /// a different allocator will cause use-after-free at `deinit`.
    ///
    /// Asserts in debug that `self` is tagged `.table`. On release
    /// builds, calling this on a non-table value is undefined
    /// behaviour — use `asTable()` first if the tag is not known
    /// statically.
    pub fn tableSetOwned(
        self: *Value,
        alloc: Allocator,
        key: []const u8,
        value: *Value,
    ) !void {
        try tableSet(alloc, self, key, value);
    }

    /// Return the existing child table at `key`, or create a new
    /// empty table, insert it, and return the new pointer. Asserts
    /// in debug that `self` is tagged `.table`.
    ///
    /// Note: if the key exists but points at a non-table value, the
    /// existing value pointer is returned unchanged — callers that
    /// need type-safety must check `.asTable()` on the result.
    pub fn tableGetOrCreateOwned(
        self: *Value,
        alloc: Allocator,
        key: []const u8,
    ) !*Value {
        return tableGetOrCreate(alloc, self, key);
    }

    /// Append `value` to this array. Same allocator-ownership rules
    /// as `tableSetOwned`. Asserts in debug that `self` is tagged
    /// `.array`.
    pub fn arrayAppendOwned(
        self: *Value,
        alloc: Allocator,
        value: *Value,
    ) !void {
        try arrayAppend(alloc, self, value);
    }
```

- [ ] **Step 2: Run tests**

Run: `zig build test 2>&1 | tail -20`
Expected: All three new `U-V Value.*Owned` tests pass alongside every earlier test.

- [ ] **Step 3: Run `zig build check`**

Run: `zig build check`
Expected: Exit 0.

---

## Task 16: Create the mutation example

**Files:**

- Create: `examples/mutation.zig`

- [ ] **Step 1: Write the example**

Create `examples/mutation.zig` with:

```zig
// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! Mutation API Example
//!
//! Build a TOML Document programmatically using the public mutation
//! surface: `Document.setPath`, `Value.tableSetOwned`, and
//! `Value.arrayAppendOwned`. Then read it back with the typed
//! accessors (`asI64`, `asString`) and iterate with `TableIter` /
//! `ArrayIter`.

const std = @import("std");
const toml = @import("toml");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Build an empty document (arena-backed).
    var arena = std.heap.ArenaAllocator.init(allocator);
    const root = try toml.value_mod.createTable(arena.allocator());
    var doc = toml.Document{ .root = root, .arena = arena };
    defer doc.deinit();

    // 1) setPath: write a nested leaf, creating intermediate tables.
    const port = try doc.allocator().create(toml.Value);
    port.* = .{ .integer = 8080 };
    try doc.setPath("server.http.port", port);

    const host = try doc.allocator().create(toml.Value);
    host.* = .{ .string = "0.0.0.0" };
    try doc.setPath("server.http.host", host);

    // 2) arrayAppendOwned: build an array under a new key.
    const tags = try toml.value_mod.createArray(doc.allocator());
    for ([_][]const u8{ "prod", "web", "v2" }) |s| {
        const item = try doc.allocator().create(toml.Value);
        item.* = .{ .string = s };
        try tags.arrayAppendOwned(doc.allocator(), item);
    }
    try doc.setPath("server.tags", tags);

    // 3) Read back with typed accessors.
    const server = doc.root.get("server") orelse unreachable;
    const http = server.get("http") orelse unreachable;
    std.debug.print("host = {s}\n", .{http.get("host").?.asString().?});
    std.debug.print("port = {d}\n", .{http.get("port").?.asI64().?});

    // 4) Iterate the http subtable in insertion order.
    var http_it = http.iterator().table_iter;
    while (http_it.next()) |pair| {
        std.debug.print("  http.{s} (tag: {s})\n", .{ pair.key, @tagName(pair.value.*) });
    }

    // 5) Iterate the tags array.
    var tags_it = server.get("tags").?.iterator().array_iter;
    while (tags_it.next()) |v| {
        std.debug.print("  tag: {s}\n", .{v.asString().?});
    }
}
```

- [ ] **Step 2: Sanity-check by running `zig build check`**

The examples in this repo are not wired into `build.zig` (the existing files under `examples/` — `basic_parsing.zig`, `config_loader.zig`, `error_handling.zig`, `json_output.zig`, `value_types.zig` — are likewise not wired in). They are reference source. The simplest way to confirm the new example at least parses as valid Zig is:

```bash
zig ast-check examples/mutation.zig
```

Expected: Exit 0, no output.

Full compilation against the `toml` module requires manual module wiring (the existing example files have the same caveat). Skip full compilation unless a later task adds an example runner to `build.zig`.

---

## Task 17: Commit the public mutation surface

- [ ] **Step 1: Stage and commit**

```bash
git add src/value.zig examples/mutation.zig
git commit -m "feat(value): close GAP-0009 — public mutation surface

Promote tableSet/tableGetOrCreate/arrayAppend to public methods on
Value (tableSetOwned, tableGetOrCreateOwned, arrayAppendOwned) with
allocator-ownership doc comments. Add examples/mutation.zig showing
setPath + arrayAppendOwned + typed accessors end-to-end.

Closes: GAP-0009"
```

- [ ] **Step 2: Verify clean tree**

Run: `git status`
Expected: `nothing to commit, working tree clean`.

---

## Task 18: Write end-to-end acceptance test

**Files:**

- Modify: `src/value.zig` (append an integration test that exercises every new symbol at once)

- [ ] **Step 1: Write the acceptance test**

```zig
test "U-V public mutation API — end-to-end round trip" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    const root = try createTable(arena.allocator());
    var doc = Document{ .root = root, .arena = arena };
    defer doc.deinit();

    // setPath (GAP-0013)
    const port = try doc.allocator().create(Value);
    port.* = .{ .integer = 5432 };
    try doc.setPath("db.port", port);

    // tableSetOwned + arrayAppendOwned (GAP-0009)
    const hosts = try createArray(doc.allocator());
    for ([_][]const u8{ "a", "b", "c" }) |s| {
        const v = try doc.allocator().create(Value);
        v.* = .{ .string = s };
        try hosts.arrayAppendOwned(doc.allocator(), v);
    }
    const db_const = doc.root.get("db") orelse unreachable;
    // `get` returns *const Value; mutation methods take *Value. This
    // @constCast is the one sharp edge of the public API: callers
    // that built the Value in the first place know it is mutable.
    const db = @constCast(db_const);
    try db.tableSetOwned(doc.allocator(), "hosts", hosts);

    // Typed accessors (GAP-0014)
    try std.testing.expectEqual(@as(i64, 5432), db.get("port").?.asI64().?);
    try std.testing.expect(db.get("hosts").?.asArray() != null);
    try std.testing.expectEqual(@as(?i64, null), db.get("hosts").?.asI64());

    // Iterators (GAP-0012)
    var hit = db.get("hosts").?.iterator().array_iter;
    var seen: usize = 0;
    while (hit.next()) |_| seen += 1;
    try std.testing.expectEqual(@as(usize, 3), seen);

    var dit = db.iterator().table_iter;
    var keys_seen: usize = 0;
    while (dit.next()) |_| keys_seen += 1;
    try std.testing.expectEqual(@as(usize, 2), keys_seen); // port, hosts
}
```

- [ ] **Step 2: Run the test**

Run: `zig build test 2>&1 | tail -10`
Expected: All tests pass. The `@constCast` in the body is intentional: `Value.get` returns a `*const Value`, but mutation methods take `*Value`. The next task documents this sharp edge.

---

## Task 19: Update `docs/API.md` — document every new symbol

**Files:**

- Modify: `docs/API.md` (append a new major section before any trailing footer)

- [ ] **Step 1: Read the last 20 lines to find the append point**

Run: `tail -20 docs/API.md`

Locate the last existing content block. Append the new content **after** the last existing section and before any trailing license/footer block.

- [ ] **Step 2: Append the new "Mutation API" section**

Append:

````markdown

## Mutation API

The mutation surface is designed for programmatic document construction and
in-place updates. All mutations go through an externally supplied
`Allocator` — typically `doc.allocator()`, which returns the document's
arena allocator. Using a foreign allocator will cause use-after-free on
`Document.deinit`.

### Typed accessors on `Value`

Return optionals; never panic on tag mismatch. Replaces the pattern
`switch (v) { .integer => |i| i, else => return null }`.

| Method | Returns | Null when |
|--------|---------|-----------|
| `asI64() ?i64` | `i64` | tag is not `.integer` |
| `asF64() ?f64` | `f64` | tag is not `.float` |
| `asBool() ?bool` | `bool` | tag is not `.bool` |
| `asString() ?[]const u8` | string slice (borrowed from arena) | tag is not `.string` |
| `asArray() ?*Array` | pointer into the Value's array payload | tag is not `.array` |
| `asTable() ?*Table` | pointer into the Value's table payload | tag is not `.table` |

No coercion is performed: a `.float` of `1.0` returns `null` from
`asI64()`, not `1`.

### Iterators

`Value.iterator()` returns a `ValueIterator` tagged union dispatched on
the value's tag. Each iterator yields entries in insertion / index order
and supports `reset()` for multi-pass iteration.

```zig
pub const ValueIterator = union(enum) {
    table_iter: TableIter,
    array_iter: ArrayIter,
    empty: void,
};
```

`TableIter.next()` yields `?TableIterEntry { key: []const u8, value: *Value }`.
`ArrayIter.next()` yields `?*Value`. `empty` is returned for all
non-container tags.

Mutations that grow the backing slice (e.g. `tableSetOwned`) invalidate
the iterator — do not mutate during iteration.

### Mutation methods on `Value`

| Method | Effect | Notes |
|--------|--------|-------|
| `tableSetOwned(alloc, key, value) !void` | Insert or overwrite `key` in this table | Debug-asserts tag is `.table`; `key` is duplicated; `value` is borrowed |
| `tableGetOrCreateOwned(alloc, key) !*Value` | Fetch or create a child empty table | If the key exists but is not a table, returns the existing pointer unchanged |
| `arrayAppendOwned(alloc, value) !void` | Append to this array | Debug-asserts tag is `.array`; `value` is borrowed |

The legacy free-function forms (`tableSet`, `tableGetOrCreate`,
`arrayAppend`) remain for internal parser use and behave identically.

Note: `Value.get` returns `*const Value`, so mutating a value fetched
through it requires `@constCast`. Callers that built the Value
themselves already hold a `*Value` and do not need the cast.

### Dotted-path mutation on `Document`

```zig
pub fn setPath(self: *Document, path: []const u8, leaf: *Value) !void
pub fn setPathSegments(self: *Document, segments: []const []const u8, leaf: *Value) !void
```

`setPath` splits a dotted string (`"server.http.port"`) into segments.
`setPathSegments` accepts a pre-split slice for segments that themselves
contain `.` (e.g. `"v1.2.3"`).

Both create missing intermediate tables. Errors:

| Error | Condition |
|-------|-----------|
| `error.EmptyPath` | `path.len == 0` (or `segments.len == 0`) |
| `error.EmptyPathSegment` | Consecutive dots or a leading/trailing dot |
| `error.PathTooDeep` | More than 64 segments |
| `error.PathCollision` | An intermediate segment already holds a non-table value |

Overwriting an existing leaf is **not** an error — the old value
remains in the arena and is reclaimed at `deinit`.

### Example

See `examples/mutation.zig` for a full end-to-end program that builds a
Document programmatically, reads it back with typed accessors, and
iterates nested tables and arrays.
````

- [ ] **Step 3: Verify the file length is sensible**

Run: `wc -l docs/API.md`
Expected: Line count roughly 700-760 (up from 606).

---

## Task 20: Update `CHANGELOG.md`

**Files:**

- Modify: `CHANGELOG.md:8-22` (under the `[Unreleased] / Added` section)

- [ ] **Step 1: Append new bullets under `[Unreleased] / Added`**

Insert directly after the last existing bullet under `### Added`:

```markdown
- Public mutation API on `Value` and `Document` (closes GAP-0009,
  GAP-0012, GAP-0013, GAP-0014):
  - Typed accessors: `asI64`, `asF64`, `asBool`, `asString`,
    `asArray`, `asTable` return optionals instead of panicking on
    tag mismatch.
  - Iterators: `Value.iterator()` returns a tagged `ValueIterator`
    with `TableIter` (yields `{ key, value }` in insertion order)
    and `ArrayIter` (yields `*Value` in index order). Non-container
    values return `.empty`.
  - `Document.setPath("a.b.c", value)` and
    `Document.setPathSegments(&.{"a", "b", "c"}, value)` write a
    leaf at a dotted key path, creating intermediate tables. Errors
    on path collisions (intermediate non-table) and malformed input.
  - `Value.tableSetOwned`, `Value.tableGetOrCreateOwned`, and
    `Value.arrayAppendOwned` are the public method form of the
    previously-internal free functions.
  - New runnable example: `examples/mutation.zig`.
```

- [ ] **Step 2: Run `zig build check` as a final sanity pass**

Run: `zig build check`
Expected: Exit 0.

---

## Task 21: Final commit — docs + changelog + end-to-end test

- [ ] **Step 1: Stage and commit**

```bash
git add docs/API.md CHANGELOG.md src/value.zig
git commit -m "docs: document public mutation API (GAP-0009/12/13/14)

Add a Mutation API section to docs/API.md covering typed accessors,
iterators, Value.tableSetOwned/arrayAppendOwned, and
Document.setPath/setPathSegments. Update CHANGELOG under Unreleased.

Also includes the end-to-end acceptance test that exercises every
new symbol together."
```

- [ ] **Step 2: Verify clean tree**

Run: `git status`
Expected: `nothing to commit, working tree clean`.

- [ ] **Step 3: Run the full test suite one final time**

Run: `zig build test 2>&1 | tail -10`
Expected: All tests pass, including every new `U-V *` test.

---

## Self-Review Checklist (performed during plan authoring)

### 1. Spec coverage

- GAP-0009 — public mutation surface: **Tasks 14-15, 17** (tableSetOwned / tableGetOrCreateOwned / arrayAppendOwned + example + commit)
- GAP-0012 — iterators: **Tasks 4-9** (TableIter + ArrayIter + `iterator()` dispatch + commit)
- GAP-0013 — setPath: **Tasks 10-13** (setPath, setPathSegments, corner cases, commit)
- GAP-0014 — typed accessors: **Tasks 1-3** (asI64/asF64/asBool/asString/asArray/asTable + commit)
- Docs (API.md + CHANGELOG): **Tasks 19-21**
- End-to-end acceptance: **Task 18**

**2. Placeholder scan** — none found. Every code block is complete, every test body runs, every command has expected output.

**3. Type consistency** — `Value` union arm names (`.integer`, `.float`, `.bool`, `.string`, `.array`, `.table`, `.datetime*`, `.date_local`, `.time_local`) match `src/value.zig:10-21`. `Value.Table` and `Value.Array` names match. `TableEntry.key/value` match. `tableSet / tableGetOrCreate / arrayAppend` match the free-function signatures at `src/value.zig:240-306`. `getPath` takes `[]const []const u8` — our `setPathSegments` mirrors this exactly; `setPath` adds the dotted-string convenience. Method names used in later tasks (`tableSetOwned`, `arrayAppendOwned`, `tableGetOrCreateOwned`, `asI64`, `iterator`, `setPath`, `setPathSegments`) match the definitions in earlier tasks exactly.

**4. Ownership contract** — every mutation method documents that `alloc` must match the allocator that built the containing `Value` / `Document`. Every test uses `doc.allocator()` (arena) consistently. No ownership drift.

**5. Parser untouched** — `parser.zig` is never modified. The free functions (`tableSet`, `tableGetOrCreate`, `arrayAppend`, `tableContains`) stay put; the new methods delegate to them. Parser calls continue to work unchanged.

**6. Const-correctness sharp edge** — `Value.get` returns `*const Value`, mutation methods take `*Value`. Task 18's acceptance test demonstrates the `@constCast` workaround; Task 19 documents it in API.md.

---

## Execution Handoff

**Plan complete and saved to `docs/superpowers/plans/2026-04-18-07-public-mutation-api.md`. Two execution options:**

**1. Subagent-Driven (recommended)** — Dispatch a fresh subagent per task with review between tasks. Fast iteration and keeps the plan's context window clean.

**2. Inline Execution** — Execute tasks in this session using `superpowers:executing-plans`, batched execution with checkpoints for review.

**Which approach?**
