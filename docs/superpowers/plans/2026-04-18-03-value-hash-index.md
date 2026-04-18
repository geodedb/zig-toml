# Value Hash Index, Arena-Owned Input, and Document Ownership Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Eliminate O(n^2) growth and lookup costs in TOML tables/arrays, kill a latent bare-key use-after-free risk tied to input lifetime, and make `Document` ownership move-safe by design.

**Architecture:** Three interlocking workstreams. **(A) Hash-indexed tables:** replace `Value.Table.entries: []TableEntry` with `std.StringArrayHashMapUnmanaged(*Value)` — preserves insertion order, O(1) `put`/`get`, and the JSON emitter keeps its "sort keys for determinism" contract. **(B) Arena-owned input:** copy the user's input byte buffer into the parse arena once at the top of `Parser.parse`, then drop all the defensive `alloc.dupe` calls for bare keys, literal strings, and dotted-key slices that currently mask a dangling-pointer bug waiting to happen when a caller frees their input before `Document.deinit`. **(C) Document ownership:** hold `*ArenaAllocator` instead of an `ArenaAllocator` by value inside `Document`, and change the public API to return `*Document`, so a copy/move of the `Document` struct cannot invalidate the arena's internal self-pointers.

**Tech Stack:** Zig 0.16.0, `std.heap.ArenaAllocator`, `std.StringArrayHashMapUnmanaged`, `std.StringHashMapUnmanaged`, `std.testing`, `std.time.Timer`.

---

## Background and Failure Modes Closed

These are the concrete defects this plan retires. Each task below references the defect ID to keep coverage traceable.

- **P-1 (quadratic table/array growth):** `src/value.zig:255-258`, `:278-281`, `:302-305` each do `alloc.alloc(new_len) + @memcpy(old_slice)` on every insert. Appending N keys therefore allocates and copies O(N^2) bytes under an arena allocator that never frees the old buffers. A 10k-key table does ~50M byte copies and wastes ~400MB of arena.
- **P-2 (linear `std.mem.eql` scans in lookups):** `Value.get` (value.zig:189-201), `Value.getPath` (value.zig:172-186), `tableGetOrCreate` (value.zig:244-249), `tableContains` (value.zig:285-294), `tableSet` (value.zig:268-274), `mergeTables` (parser.zig:787-804), `resolveTablePath` (parser.zig:161-166), and the dotted-key walker in `parseKeyValue` (parser.zig:285-291) all loop over `entries` and do byte-compare on each key. Every lookup is O(n); every parse of N keys is O(N^2) even before the allocator pain.
- **P-5 (redundant dupes + latent UAF in bare keys):** `parser.zig:337,341,344` dupe dotted-key parts unnecessarily. `parser.zig:367-380` takes `.bare_key` and datetime-shaped keys as *direct slices of `self.input`* — which is the caller's buffer. A caller who frees the input before calling `Document.deinit` dangles every bare key.
- **P-12 (inline-table dup-check is O(n^2)):** `parser.zig:709-723` and `:730-735` do linear scans of `entries.items` for each inserted key. A 1000-key inline table performs ~500k byte-compares.
- **Q-12 (Document-by-value arena invalidation):** `std.heap.ArenaAllocator` contains a `ChildAllocator` interface and a linked list of buffer nodes. Even when not directly self-referential, the `Allocator` returned by `arena.allocator()` embeds a `*anyopaque` pointer to *that exact* `ArenaAllocator` instance. If `Document` is copied (moved) by value, the old address is captured and the copied arena cannot be `deinit`ed safely. Holding `*ArenaAllocator` eliminates the footgun by construction.

---

## File Structure

This plan modifies existing files rather than splitting new ones. Each file has one responsibility. Where a file grows by one function, it stays; where a file would grow past ~400 lines of behavior, the plan splits new helpers into a focused file.

- **`src/value.zig`** — owns `Value`, `Value.Table`, `Value.Array`, `Document`, and the table/array mutation primitives (`tableSet`, `tableGetOrCreate`, `tableContains`, `arrayAppend`, `Value.get`, `Value.getPath`). Workstream A and C both edit here.
- **`src/parser.zig`** — parser state and recursive-descent logic. Workstream B (arena-owned input) and the caller sites for the new table API live here. `mergeTables` and `resolveTablePath` need to be rewritten around the hash-indexed map.
- **`src/json_tagged.zig`** — emits toml-test tagged JSON. The table iteration code must switch to iterating the `StringArrayHashMapUnmanaged` in insertion order, then sort a scratch buffer of `TableEntry` by key for deterministic output.
- **`src/toml.zig`** — public API. The `parse` and `parseWithError` entrypoints change from returning `Document` to `*Document`, and the `ParseResult` union's `ok` variant becomes `*Document`. Re-exports stay.
- **`src/parallel.zig`** — `parseDocuments` is a byte-level shape-checker that never produces a real `Document`, so it is untouched structurally. Only a smoke test that exercises `toml.parse` from within parallel paths needs updating if the `Document` handle type changes.
- **`examples/basic_parsing.zig`, `examples/*.zig`** — callers of `toml.parse`. Each needs a mechanical update from `var doc = try ...; defer doc.deinit();` to `const doc = try ...; defer doc.deinit();`.
- **`docs/API.md`, `docs/ARCHITECTURE.md`, `CHANGELOG.md`** — update `Document` section, ownership notes, and migration guide.
- **`tests/accept.zig`** — acceptance tests that reach into `table.entries.len` need to call the new counting API.

---

## Conventions Used in This Plan

- Run all Zig commands from the repo root (`/home/benji/src/devnw/zig/toml`).
- Test runner: `zig build test` (runs unit, accept, and fuzz smoke). Individual file: `zig test src/value.zig`.
- Commits follow the repo's existing conventional-commit style: `perf(scope): ...`, `fix(scope): ...`, `refactor(scope): ...`, `test(scope): ...`, `docs(scope): ...`.
- Every task ends with a commit. Do not amend across tasks.
- When a step says "Expected: PASS", run the command and verify. If it fails for a reason the plan didn't predict, stop and investigate — do not skip ahead.

---

## Task 1: Establish a table-insertion baseline benchmark

**Files:**

- Create: `tests/bench_table_insert.zig`
- Modify: `build.zig` to register a `bench` step that runs this benchmark (opt-in, not part of `test`).

- [ ] **Step 1: Create the benchmark file with a failing assertion that pins the current baseline**

The goal of this step is to capture current wall-clock cost. We write a test that measures insertion of 10_000 unique keys via the public `toml.parse` API (so we exercise `tableSet` exactly as the real parser does), and we log the measured time so the commit records the baseline in CI logs.

Create `tests/bench_table_insert.zig` with exactly this content:

```zig
// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! Performance baseline for large-table parsing.
//!
//! This file is intentionally NOT wired into `zig build test`. It runs
//! under `zig build bench` and produces a wall-clock baseline that later
//! tasks must beat. The test asserts success and records the elapsed
//! nanoseconds via std.log so the number lands in CI logs and commit
//! artifacts.

const std = @import("std");
const toml = @import("toml");

const KEY_COUNT: usize = 10_000;

fn buildInput(alloc: std.mem.Allocator) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(alloc);
    try buf.ensureTotalCapacity(alloc, KEY_COUNT * 16);
    var i: usize = 0;
    while (i < KEY_COUNT) : (i += 1) {
        try buf.writer(alloc).print("k{d} = {d}\n", .{ i, i });
    }
    return buf.toOwnedSlice(alloc);
}

test "B-1 parse 10k top-level keys (baseline)" {
    const alloc = std.testing.allocator;
    const input = try buildInput(alloc);
    defer alloc.free(input);

    var timer = try std.time.Timer.start();
    var doc = try toml.parse(alloc, input, .{});
    defer doc.deinit();
    const elapsed_ns = timer.read();

    // Sanity: the document must contain exactly KEY_COUNT top-level keys.
    // We intentionally read via the public get API so this exercises the
    // O(1) path after the hash-index refactor and the O(n) path today.
    var i: usize = 0;
    var hits: usize = 0;
    var name_buf: [32]u8 = undefined;
    while (i < KEY_COUNT) : (i += 1) {
        const name = try std.fmt.bufPrint(&name_buf, "k{d}", .{i});
        if (doc.root.get(name)) |v| {
            if (v.integer == @as(i64, @intCast(i))) hits += 1;
        }
    }
    try std.testing.expectEqual(KEY_COUNT, hits);

    std.log.warn("B-1 baseline: parse+lookup 10k keys = {d} ns", .{elapsed_ns});
}
```

- [ ] **Step 2: Add a `bench` step to `build.zig`**

In `/home/benji/src/devnw/zig/toml/build.zig`, insert the following block immediately before the `// Check step (compile without running)` comment (currently at line 105):

```zig
    // Benchmark harness (opt-in; not part of `test`).
    const bench_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/bench_table_insert.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "toml", .module = toml_mod },
            },
        }),
    });
    const run_bench_tests = b.addRunArtifact(bench_tests);
    const bench_step = b.step("bench", "Run performance benchmarks (not part of test)");
    bench_step.dependOn(&run_bench_tests.step);
```

- [ ] **Step 3: Run the benchmark and capture the baseline**

Run: `zig build bench -Doptimize=ReleaseFast 2>&1 | tee /tmp/toml-bench-before.txt`

Expected: the test passes; stderr contains a line like `B-1 baseline: parse+lookup 10k keys = <N> ns`. Note that `<N>` on a modern x86_64 laptop is likely in the 1e8 to 1e9 range (100ms to 1s) because of the O(N^2) insertion cost. Record this number in the commit message.

If the test times out or runs over 60s, that is itself a signal the baseline is worse than expected; still commit the file with a timeout note in the message.

- [ ] **Step 4: Run the full test suite to confirm nothing regressed**

Run: `zig build test`

Expected: all pre-existing tests pass.

- [ ] **Step 5: Commit**

```bash
git add tests/bench_table_insert.zig build.zig
git commit -m "test(bench): add 10k-key table-insert baseline harness (P-1)"
```

---

## Task 2: Correctness test — insertion order, uniqueness, lookup round-trip

**Files:**

- Modify: `src/value.zig` (add tests at end of file)

- [ ] **Step 1: Write a failing test that pins the semantics the new hash-indexed map must preserve**

This test does not exist today; we add it now so later tasks cannot silently break insertion-order semantics or dup-rejection.

Append the following tests to `/home/benji/src/devnw/zig/toml/src/value.zig` (after the existing `test "U-T DateTime.format handles i16.minInt offset without panic"` block, at end of file):

```zig
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
```

Note that these tests reference `tableIterator` and `tableLen` which do not exist yet. That is intentional — they are the API the refactor must produce.

- [ ] **Step 2: Run the test — it must fail**

Run: `zig test src/value.zig`

Expected: FAIL with an error like `error: no member named 'tableIterator' in ...` or `no member named 'tableLen'`. This is the correct failure; it shows we've locked in the API we want.

- [ ] **Step 3: Commit the failing tests**

```bash
git add src/value.zig
git commit -m "test(value): pin table insertion-order and lookup semantics (C-1..C-4, currently fails)"
```

The next tasks make it pass.

---

## Task 3: Introduce `StringArrayHashMapUnmanaged`-backed Table representation

**Files:**

- Modify: `src/value.zig` (types `TableEntry`, `Value.Table`, and every table primitive)

This is the core surgery. We keep the public `TableEntry` type because `json_tagged.zig` and examples use it to iterate, but we change how a table stores its keys from a flat slice to an ordered hash map. The `entries` field goes away; callers that iterated it move to the `tableIterator(t: *const Value)` helper added here.

- [ ] **Step 1: Replace `Value.Table` with the hash-map-backed form and add the new helpers**

Open `/home/benji/src/devnw/zig/toml/src/value.zig`. Replace the block from line 138 (`/// Table entry for ordered key-value storage.`) through the end of `Value.Array` (line 169) — i.e., the `TableEntry` declaration, the `Value` union, and the `Table`/`Array` inner structs — with the following. Note that `TableEntry` is *kept* as a return type for iteration and sorting, but it is now a snapshot, not the storage.

```zig
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
        items: std.ArrayListUnmanaged(*Value) = .{},
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
```

- [ ] **Step 2: Replace the table/array primitives below the `Value` declaration**

In the same file, replace the primitive-function block from `createTable` (line 226) through `arrayAppend` (end of line 306) with the following. This block sits where the old primitives were; the rest of the file (the existing test at lines 308-330) stays untouched.

```zig
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
pub fn arrayAppend(alloc: Allocator, array: *Value, value: *Value) !void {
    std.debug.assert(array.* == .array);
    const a = &array.array;
    try a.items.append(alloc, value);
}

/// Return the number of items in an array.
pub fn arrayLen(array: *const Value) usize {
    return switch (array.*) {
        .array => |*a| a.items.items.len,
        else => 0,
    };
}

/// Return the items slice of an array (insertion order).
pub fn arrayItems(array: *const Value) []const *Value {
    std.debug.assert(array.* == .array);
    return array.array.items.items;
}
```

- [ ] **Step 3: Compile check — this task's changes must at least build even though callers still reference `.entries`**

Run: `zig build check`

Expected: FAIL. The error messages point at `src/parser.zig` and `src/json_tagged.zig` lines that reach into `.entries` or `.items` directly. **Do not fix them yet** — they belong to Tasks 4 and 5.

Take the first 10 lines of the error output and paste them into the commit message so reviewers can see exactly which callers are next.

- [ ] **Step 4: But src/value.zig itself must compile as a standalone test target**

Run: `zig test src/value.zig --test-no-exec`

Expected: PASS (no execution, just type-check). If this fails, the issue is in the edits above, not in callers — fix before proceeding.

- [ ] **Step 5: Commit (with WIP marker — this commit intentionally leaves the tree non-building)**

```bash
git add src/value.zig
git commit -m "refactor(value): switch Table to StringArrayHashMapUnmanaged (A/P-1,P-2, WIP)

Callers in parser.zig and json_tagged.zig still reference the removed
.entries field; Tasks 4 and 5 in docs/superpowers/plans/2026-04-18-03-value-hash-index.md
update them. 'zig build check' fails intentionally between these
commits."
```

---

## Task 4: Update `parser.zig` callers to the new table API

**Files:**

- Modify: `src/parser.zig` (five call sites)

There are five places in `parser.zig` that reach into `table.entries` directly. Each becomes an O(1) map lookup.

- [ ] **Step 1: Replace the dotted-key walk in `parseKeyValue` (lines 285-291)**

Open `/home/benji/src/devnw/zig/toml/src/parser.zig`. Find the block:

```zig
        for (path.items[0 .. path.items.len - 1]) |key| {
            var found: ?*Value = null;
            for (target.table.entries) |entry| {
                if (std.mem.eql(u8, entry.key, key)) {
                    found = entry.value;
                    break;
                }
            }

            if (found) |existing| {
```

Replace it with:

```zig
        for (path.items[0 .. path.items.len - 1]) |key| {
            const found: ?*Value = target.table.map.get(key);

            if (found) |existing| {
```

Everything below `if (found) |existing| {` through the end of the enclosing `for` loop stays unchanged.

- [ ] **Step 2: Replace the table-path walk in `resolveTablePath` (lines 159-166)**

Find:

```zig
            // Check if key exists
            var found: ?*Value = null;
            for (current.table.entries) |entry| {
                if (std.mem.eql(u8, entry.key, key)) {
                    found = entry.value;
                    break;
                }
            }
```

Replace with:

```zig
            // Check if key exists. O(1).
            const found: ?*Value = current.table.map.get(key);
```

- [ ] **Step 3: Rewrite `mergeTables` around the hash-indexed map (lines 781-804)**

Find the entire `fn mergeTables` function body:

```zig
    fn mergeTables(alloc: Allocator, target: *Value, source: *Value) error{ ParseFailed, OutOfMemory }!void {
        // Both must be tables
        if (target.* != .table or source.* != .table) {
            return error.ParseFailed;
        }

        for (source.table.entries) |src_entry| {
            var found = false;
            for (target.table.entries) |*tgt_entry| {
                if (std.mem.eql(u8, tgt_entry.key, src_entry.key)) {
                    // Both values must be tables to merge
                    if (tgt_entry.value.* != .table or src_entry.value.* != .table) {
                        return error.ParseFailed;
                    }
                    try mergeTables(alloc, tgt_entry.value, src_entry.value);
                    found = true;
                    break;
                }
            }
            if (!found) {
                try val.tableSet(alloc, target, src_entry.key, src_entry.value);
            }
        }
    }
```

Replace with:

```zig
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
```

- [ ] **Step 4: Replace the inline-table `entries.toOwnedSlice` return path (line 778)**

Find:

```zig
        return Value{ .table = .{ .entries = try entries.toOwnedSlice(alloc), .is_inline = true, .is_closed_inline = true } };
```

This belongs to `parseInlineTable`. At this point `entries` is a `std.ArrayList(TableEntry)` scratch structure local to the function. Task 6 replaces the dup-check with a direct `StringArrayHashMapUnmanaged` insert path. For *this* task we keep the function working by converting scratch `entries` into a map at the point of return. Replace the line above with:

```zig
        // Convert the scratch entries list into the hash-indexed map
        // form. Task 6 in the plan folds the dup-check into the insert
        // and removes this final conversion pass.
        var map: std.StringArrayHashMapUnmanaged(*Value) = .{};
        errdefer map.deinit(alloc);
        try map.ensureTotalCapacity(alloc, @intCast(entries.items.len));
        for (entries.items) |e| {
            map.putAssumeCapacity(e.key, e.value);
        }
        return Value{ .table = .{ .map = map, .is_inline = true, .is_closed_inline = true } };
```

- [ ] **Step 5: Fix the inline-table dup-check loops (lines 709-724, 730-736)**

These linear scans over `entries.items` remain correct (they operate on the local scratch `std.ArrayList(TableEntry)`), but we keep them in place *for this task* — Task 6 replaces them with an O(1) scratch set. Leave these two blocks exactly as they are in the current source.

- [ ] **Step 6: Build to confirm only `json_tagged.zig` is still broken**

Run: `zig build check`

Expected: FAIL — `src/json_tagged.zig` still references `.entries`. That's Task 5. Confirm that `parser.zig` is now clean by searching for parser.zig entries in the output:

Run: `zig build check 2>&1 | grep -c 'parser.zig'`

Expected: `0`. If non-zero, fix those spots before proceeding.

- [ ] **Step 7: Commit**

```bash
git add src/parser.zig
git commit -m "refactor(parser): use map.get for table lookups (A/P-2, WIP)

Updates five call sites in parser.zig to the hash-indexed Table API:
parseKeyValue dotted-key walk, resolveTablePath, mergeTables, and the
parseInlineTable return assembly. json_tagged.zig still pending."
```

---

## Task 5: Update `json_tagged.zig` to iterate the hash-map and sort for determinism

**Files:**

- Modify: `src/json_tagged.zig` (`writeValue` table case)
- Modify: `tests/accept.zig` (the two remaining `.table.entries.len` consumers)

- [ ] **Step 1: Replace the `.table` case in `writeValue` (lines 26-58)**

Open `/home/benji/src/devnw/zig/toml/src/json_tagged.zig`. Find the block starting `.table => |t| {` at line 26 through its closing `}` at line 58, and replace with:

```zig
        .table => |*t| {
            try writer.writeByte('{');
            // Always sort keys so the emitter output is deterministic
            // regardless of insertion order. The hash-indexed storage
            // gives us O(1) put/get; for emit we snapshot keys+values
            // into a sortable TableEntry buffer. Previously (flat slice
            // world), tables with >256 entries fell through to insertion
            // order, violating the "sorted at every level" contract.
            const n = t.map.count();
            var stack_sorted: [256]TableEntry = undefined;
            var heap_sorted: ?[]TableEntry = null;
            defer if (heap_sorted) |slice| std.heap.smp_allocator.free(slice);

            const sorted_slice: []TableEntry = if (n <= stack_sorted.len) blk: {
                const keys = t.map.keys();
                const values = t.map.values();
                for (0..n) |i| {
                    stack_sorted[i] = .{ .key = keys[i], .value = values[i] };
                }
                break :blk stack_sorted[0..n];
            } else blk: {
                const buf = try std.heap.smp_allocator.alloc(TableEntry, n);
                const keys = t.map.keys();
                const values = t.map.values();
                for (0..n) |i| {
                    buf[i] = .{ .key = keys[i], .value = values[i] };
                }
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
```

- [ ] **Step 2: Replace the `.array` case in `writeValue` (lines 59-66)**

The array backing type changed from `[]*Value` to `std.ArrayListUnmanaged(*Value)`. Find the block starting `.array => |a| {`:

```zig
        .array => |a| {
            try writer.writeByte('[');
            for (a.items, 0..) |item, i| {
                if (i > 0) try writer.writeByte(',');
                try writeValue(item, writer);
            }
            try writer.writeByte(']');
        },
```

Replace with:

```zig
        .array => |*a| {
            try writer.writeByte('[');
            for (a.items.items, 0..) |item, i| {
                if (i > 0) try writer.writeByte(',');
                try writeValue(item, writer);
            }
            try writer.writeByte(']');
        },
```

- [ ] **Step 3: Update the two `.table.entries.len` consumers in `tests/accept.zig`**

Open `/home/benji/src/devnw/zig/toml/tests/accept.zig`. At line 344 find:

```zig
    try std.testing.expectEqual(@as(usize, 0), empty.table.entries.len);
```

Replace with:

```zig
    try std.testing.expectEqual(@as(usize, 0), val_mod.tableLen(empty));
```

At line 347 find:

```zig
    try std.testing.expectEqual(@as(usize, 1), another.table.entries.len);
```

Replace with:

```zig
    try std.testing.expectEqual(@as(usize, 1), val_mod.tableLen(another));
```

At the top of `tests/accept.zig`, ensure this import is present (add it after the existing `const toml = @import("toml");` import line if it is not already there):

```zig
const val_mod = @import("toml").value_mod;
```

- [ ] **Step 4: Build and run tests**

Run: `zig build test`

Expected: all pre-existing tests PASS, including the four new `C-1`..`C-4` tests from Task 2.

- [ ] **Step 5: Run the benchmark and compare to the baseline**

Run: `zig build bench -Doptimize=ReleaseFast 2>&1 | tee /tmp/toml-bench-after-A.txt`

Expected: the `B-1 baseline` log line reports at least a 10x reduction versus `/tmp/toml-bench-before.txt` (typically 50x-500x for 10k keys; the old O(N^2) allocation storm is gone).

Compute the ratio and include it in the commit message. If the post-change number is not at least 10x better than baseline, **stop** — something is wrong (most likely `StringArrayHashMapUnmanaged` is being re-hashed on every insert because `ensureTotalCapacity` wasn't used where batch sizes are known). Investigate `tableSet` call sites before committing.

- [ ] **Step 6: Commit**

```bash
git add src/json_tagged.zig tests/accept.zig
git commit -m "perf(json,tests): iterate hash-indexed Table, update accept asserts (A/P-1,P-2)

Closes P-1 and P-2: tables are now hash-indexed with insertion order
preserved. 10k-key parse benchmark is <10% of baseline (see commit
body). json_tagged snapshots into a sortable TableEntry buffer so the
'sorted at every level' emit contract still holds for tables of any
size.

Baseline (Task 1): <N> ns
After A:           <M> ns
Speedup:           <N/M>x"
```

---

## Task 6: Remove `TableEntry`-based construction scaffolding in `parseInlineTable`

**Files:**

- Modify: `src/parser.zig` (`parseInlineTable`)

Task 4 Step 4 left `parseInlineTable` assembling a scratch `std.ArrayList(TableEntry)` and then converting it into a map at return. That scaffolding is no longer needed once the function inserts directly into a map. This task is pure cleanup plus the O(1) dup-check that closes P-12.

- [ ] **Step 1: Rewrite the scratch structure in `parseInlineTable` to a `StringArrayHashMapUnmanaged` directly**

Open `/home/benji/src/devnw/zig/toml/src/parser.zig`, function `parseInlineTable` (starts at line 648). Find the scratch declaration:

```zig
        // Typical inline tables have a handful of entries; 16 avoids the
        // initial reallocation ladder for essentially every real-world case.
        var entries: std.ArrayList(TableEntry) = try .initCapacity(alloc, 16);
```

Replace with:

```zig
        // Typical inline tables have a handful of entries; 16 avoids the
        // initial reallocation ladder for essentially every real-world case.
        var map: std.StringArrayHashMapUnmanaged(*Value) = .{};
        errdefer map.deinit(alloc);
        try map.ensureTotalCapacity(alloc, 16);
```

- [ ] **Step 2: Replace the dotted-key branch's linear scan (roughly lines 706-727)**

Find the block starting `// Merge or add the root key`:

```zig
                // Merge or add the root key
                const root_key = path.items[0];
                var found = false;
                for (entries.items) |*entry| {
                    if (std.mem.eql(u8, entry.key, root_key)) {
                        // Cannot extend an inline table that was defined with { ... } syntax
                        if (entry.value.* == .table and entry.value.table.is_closed_inline) {
                            self.parse_error = err.makeError(.TableRedefined, self.current.pos, "cannot extend inline table with dotted key");
                            return error.ParseFailed;
                        }
                        // Merge tables - fails if either side is not a table
                        mergeTables(alloc, entry.value, current_table) catch {
                            self.parse_error = err.makeError(.DuplicateKey, self.current.pos, "cannot overwrite key with dotted key");
                            return error.ParseFailed;
                        };
                        found = true;
                        break;
                    }
                }
                if (!found) {
                    try entries.append(alloc, .{ .key = try alloc.dupe(u8, root_key), .value = current_table });
                }
```

Replace with:

```zig
                // Merge or add the root key. O(1) probe.
                const root_key = path.items[0];
                if (map.get(root_key)) |existing_value| {
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
                    try map.put(alloc, try alloc.dupe(u8, root_key), current_table);
                }
```

- [ ] **Step 3: Replace the single-key branch's linear dup-check (roughly lines 728-737)**

Find:

```zig
            } else {
                // Check for duplicate key
                for (entries.items) |entry| {
                    if (std.mem.eql(u8, entry.key, path.items[0])) {
                        self.parse_error = err.makeError(.DuplicateKey, self.current.pos, "duplicate key in inline table");
                        return error.ParseFailed;
                    }
                }
                try entries.append(alloc, .{ .key = try alloc.dupe(u8, path.items[0]), .value = value });
            }
```

Replace with:

```zig
            } else {
                // Check for duplicate key. O(1).
                if (map.contains(path.items[0])) {
                    self.parse_error = err.makeError(.DuplicateKey, self.current.pos, "duplicate key in inline table");
                    return error.ParseFailed;
                }
                try map.put(alloc, try alloc.dupe(u8, path.items[0]), value);
            }
```

- [ ] **Step 4: Replace the return expression (added in Task 4 Step 4)**

Find:

```zig
        // Convert the scratch entries list into the hash-indexed map
        // form. Task 6 in the plan folds the dup-check into the insert
        // and removes this final conversion pass.
        var map: std.StringArrayHashMapUnmanaged(*Value) = .{};
        errdefer map.deinit(alloc);
        try map.ensureTotalCapacity(alloc, @intCast(entries.items.len));
        for (entries.items) |e| {
            map.putAssumeCapacity(e.key, e.value);
        }
        return Value{ .table = .{ .map = map, .is_inline = true, .is_closed_inline = true } };
```

Replace with:

```zig
        return Value{ .table = .{ .map = map, .is_inline = true, .is_closed_inline = true } };
```

- [ ] **Step 5: Run tests**

Run: `zig build test`

Expected: PASS. All 64+ tests including C-1..C-4 and both deep-inline-table U-H tests still pass.

- [ ] **Step 6: Commit**

```bash
git add src/parser.zig
git commit -m "perf(parser): insert directly into map in parseInlineTable (P-12)

Closes P-12. Removes the scratch ArrayList(TableEntry) + final
conversion pass introduced in Task 4 step 4. Inline tables now
populate the final StringArrayHashMapUnmanaged directly. Dup-check
is now O(1) instead of O(n)."
```

---

## Task 7: Add inline-table duplicate-check performance regression pin

**Files:**

- Modify: `tests/bench_table_insert.zig` (extend with a second benchmark)

- [ ] **Step 1: Add a benchmark for inline-table parsing at N = 1000**

Open `/home/benji/src/devnw/zig/toml/tests/bench_table_insert.zig`. Append:

```zig
const INLINE_KEY_COUNT: usize = 1000;

fn buildInlineInput(alloc: std.mem.Allocator) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(alloc);
    try buf.ensureTotalCapacity(alloc, INLINE_KEY_COUNT * 16);
    try buf.appendSlice(alloc, "t = { ");
    var i: usize = 0;
    while (i < INLINE_KEY_COUNT) : (i += 1) {
        if (i > 0) try buf.appendSlice(alloc, ", ");
        try buf.writer(alloc).print("k{d} = {d}", .{ i, i });
    }
    try buf.appendSlice(alloc, " }\n");
    return buf.toOwnedSlice(alloc);
}

test "B-2 parse 1000-key inline table (P-12 regression pin)" {
    const alloc = std.testing.allocator;
    const input = try buildInlineInput(alloc);
    defer alloc.free(input);

    var timer = try std.time.Timer.start();
    var doc = try toml.parse(alloc, input, .{});
    defer doc.deinit();
    const elapsed_ns = timer.read();

    const t = doc.root.get("t") orelse unreachable;
    try std.testing.expectEqual(INLINE_KEY_COUNT, toml.value_mod.tableLen(t));

    std.log.warn("B-2: parse 1000-key inline table = {d} ns", .{elapsed_ns});

    // Hard ceiling: with O(1) dup-check, parsing a 1000-key inline table
    // should take <50ms in ReleaseFast on any reasonable x86_64 laptop.
    // In Debug this is ~5-10x slower; skip the assertion in Debug.
    if (@import("builtin").mode != .Debug) {
        try std.testing.expect(elapsed_ns < 50 * std.time.ns_per_ms);
    }
}
```

- [ ] **Step 2: Run the benchmark**

Run: `zig build bench -Doptimize=ReleaseFast`

Expected: PASS. B-2 completes well under 50ms.

- [ ] **Step 3: Commit**

```bash
git add tests/bench_table_insert.zig
git commit -m "test(bench): pin 1000-key inline-table parse under 50ms (P-12)"
```

---

## Task 8: Write the arena-owned-input regression test (must fail today)

**Files:**

- Modify: `src/toml.zig` (add a new test case at end of file)

This test captures the latent use-after-free: a caller frees the input buffer before calling `Document.deinit`, then tries to access a bare key. Today's code slices `self.input` directly for bare keys, so the key bytes dangle. Task 9 copies the input into the arena and fixes this.

- [ ] **Step 1: Write the failing test**

Append the following to `/home/benji/src/devnw/zig/toml/src/toml.zig` (after the last existing test, which is `test "parallel re-export is reachable"` around line 393):

```zig
test "U-B2 input buffer may be freed before Document.deinit (P-5)" {
    const alloc = std.testing.allocator;

    // Build an input buffer on an allocator we can free independently.
    const input = try alloc.dupe(u8, "server_host = \"localhost\"\n[database]\npool_size = 16\n");

    var doc = try parse(alloc, input, .{});
    defer doc.deinit();

    // Release the caller's input buffer before touching the Document.
    // After the P-5 fix, all key/string storage is arena-owned, so
    // subsequent lookups must still succeed.
    alloc.free(input);

    const host = doc.root.get("server_host") orelse unreachable;
    try std.testing.expectEqualStrings("localhost", host.string);

    const db = doc.root.get("database") orelse unreachable;
    const pool = db.get("pool_size") orelse unreachable;
    try std.testing.expectEqual(@as(i64, 16), pool.integer);
}
```

- [ ] **Step 2: Run the test under the testing allocator**

Run: `zig test src/toml.zig --test-filter "U-B2 input buffer may be freed"`

Expected: FAIL. Under the testing allocator the freed bytes are poisoned (Zig's `GeneralPurposeAllocator` in safe modes); the bare-key lookup will either find nothing or return garbage, causing the `expectEqualStrings` or the `orelse unreachable` to panic.

If the test unexpectedly passes on some platforms (bytes not yet recycled), it still **must** be in the suite — Task 9's fix is what makes it deterministically correct.

- [ ] **Step 3: Commit the failing test**

```bash
git add src/toml.zig
git commit -m "test(toml): pin input-buffer-independent Document lifetime (U-B2, currently fails)"
```

---

## Task 9: Copy input into the arena inside `Parser.parse`

**Files:**

- Modify: `src/parser.zig` (`Parser.parse`)

- [ ] **Step 1: Move input-ownership into the arena**

Open `/home/benji/src/devnw/zig/toml/src/parser.zig`. Find `pub fn parse(self: *Parser) !Document` at line 52. Replace the function body (lines 53-80) with:

```zig
    pub fn parse(self: *Parser) !Document {
        // UTF-8 validation (against the caller's original buffer; cheap to
        // do before we copy).
        if (!std.unicode.utf8ValidateSlice(self.input)) {
            self.parse_error = err.makeError(.InvalidUtf8, .{}, "input is not valid UTF-8");
            return error.ParseFailed;
        }

        // Size limit check.
        if (self.input.len > self.options.max_bytes) {
            self.parse_error = err.makeError(.LimitExceeded, .{}, "input exceeds max_bytes limit");
            return error.ParseFailed;
        }

        var arena = std.heap.ArenaAllocator.init(self.alloc);
        errdefer arena.deinit();

        const arena_alloc = arena.allocator();

        // Copy the input into the arena so every slice the parser takes
        // of `self.input` (bare keys, literal strings, number text, etc.)
        // is owned by the Document's arena, not the caller's buffer.
        // After this point the parser reads only from the arena-owned
        // copy, so the caller is free to free their original input
        // immediately after parse() returns. Closes P-5 and the latent
        // UAF around parser.zig:367-380.
        const owned_input = try arena_alloc.dupe(u8, self.input);
        self.input = owned_input;
        self.lexer = Lexer.init(owned_input, self.options.version);

        const root = try val.createTable(arena_alloc);

        // Prime the parser
        self.current = try self.nextToken();

        // Parse document
        try self.parseDocument(arena_alloc, root);

        return Document{
            .root = root,
            .arena = arena,
        };
    }
```

Note: we re-init the lexer with the owned buffer. The lexer holds its own pointer into the input; if we didn't update it, the lexer would still read from the caller's buffer and defeat the fix.

- [ ] **Step 2: Run the test suite**

Run: `zig build test`

Expected: PASS, including the new `U-B2` test from Task 8.

- [ ] **Step 3: Commit**

```bash
git add src/parser.zig
git commit -m "fix(parser): copy input into arena so keys outlive caller's buffer (P-5/U-B2)

Closes P-5 by making every slice the parser takes of self.input
arena-owned. The caller may now free their input buffer immediately
after parse() returns. Updates Parser.parse to dupe the input into the
arena, re-init the lexer with the owned copy, and rebind self.input.
Regression pin: test 'U-B2 input buffer may be freed'."
```

---

## Task 10: Drop the redundant `alloc.dupe` calls now that input is arena-owned

**Files:**

- Modify: `src/parser.zig` (multiple sites)

Now that every `self.input[..]` slice points into the arena, the defensive `alloc.dupe` calls at dotted-key path segments, literal-string values, and `parseInlineTable` key inserts are redundant copies that waste arena bytes. Drop them. Keep the dupes that transform content (escape decoding, etc.) — those aren't slices of the input, they're fresh buffers.

- [ ] **Step 1: Dotted-key path segments in `parseKeyPath` (lines 337, 341, 344)**

Open `/home/benji/src/devnw/zig/toml/src/parser.zig`. Find:

```zig
                if (std.mem.indexOf(u8, text, ".")) |dot_pos| {
                    // Split into parts
                    try path.append(alloc, try alloc.dupe(u8, text[0..dot_pos]));
                    var rest = text[dot_pos + 1 ..];
                    // Handle multiple dots (like 1.2.3)
                    while (std.mem.indexOf(u8, rest, ".")) |next_dot| {
                        try path.append(alloc, try alloc.dupe(u8, rest[0..next_dot]));
                        rest = rest[next_dot + 1 ..];
                    }
                    try path.append(alloc, try alloc.dupe(u8, rest));
```

Replace with:

```zig
                if (std.mem.indexOf(u8, text, ".")) |dot_pos| {
                    // Split into parts. Slices are arena-owned (P-5).
                    try path.append(alloc, text[0..dot_pos]);
                    var rest = text[dot_pos + 1 ..];
                    // Handle multiple dots (like 1.2.3)
                    while (std.mem.indexOf(u8, rest, ".")) |next_dot| {
                        try path.append(alloc, rest[0..next_dot]);
                        rest = rest[next_dot + 1 ..];
                    }
                    try path.append(alloc, rest);
```

- [ ] **Step 2: Literal-string value in `parseValue` (lines 422, 430)**

Find:

```zig
            .literal_string => {
                result.* = .{ .string = try alloc.dupe(u8, self.decodeLiteralString(self.current.slice(self.input))) };
                self.current = try self.nextToken();
            },
```

Replace with:

```zig
            .literal_string => {
                // Slice is arena-owned (P-5); no content transformation
                // for literal strings, so no dupe needed.
                result.* = .{ .string = self.decodeLiteralString(self.current.slice(self.input)) };
                self.current = try self.nextToken();
            },
```

And:

```zig
            .ml_literal_string => {
                result.* = .{ .string = try alloc.dupe(u8, self.decodeMultilineLiteralString(self.current.slice(self.input))) };
                self.current = try self.nextToken();
            },
```

Replace with:

```zig
            .ml_literal_string => {
                result.* = .{ .string = self.decodeMultilineLiteralString(self.current.slice(self.input)) };
                self.current = try self.nextToken();
            },
```

- [ ] **Step 3: Inline-table root-key dupes in `parseInlineTable`**

Find (in the dotted-key branch after Task 6):

```zig
                } else {
                    try map.put(alloc, try alloc.dupe(u8, root_key), current_table);
                }
```

Replace with:

```zig
                } else {
                    // root_key is arena-owned (P-5); no dupe.
                    try map.put(alloc, root_key, current_table);
                }
```

And (in the single-key branch):

```zig
                try map.put(alloc, try alloc.dupe(u8, path.items[0]), value);
```

Replace with:

```zig
                try map.put(alloc, path.items[0], value);
```

- [ ] **Step 4: Audit for any remaining `alloc.dupe` call that takes a slice of `self.input`**

Run:

```bash
grep -nE 'alloc\.dupe\([^,]+,\s*(self\.current\.slice\(self\.input\)|self\.input\[)' /home/benji/src/devnw/zig/toml/src/parser.zig
```

Expected: no matches. If any exist, delete the `alloc.dupe` wrapper and leave the slice raw — they are now arena-owned by Task 9.

- [ ] **Step 5: Run tests**

Run: `zig build test`

Expected: PASS including U-B2.

- [ ] **Step 6: Run the benchmark to confirm no regression in B-1 or B-2**

Run: `zig build bench -Doptimize=ReleaseFast`

Expected: PASS; B-1 numbers should be slightly better than Task 5's output because we eliminated per-key dupes.

- [ ] **Step 7: Commit**

```bash
git add src/parser.zig
git commit -m "perf(parser): drop redundant dupes of arena-owned input slices (P-5)

Input is now arena-owned after Task 9, so the defensive alloc.dupe of
every bare-key segment, literal-string, and dotted-key path part is
pure overhead. Removed at parseKeyPath dotted-key split, parseValue
literal/multiline-literal, and parseInlineTable root-key insert."
```

---

## Task 11: Make `Document` hold `*ArenaAllocator` and return `*Document` from the public API

**Files:**

- Modify: `src/value.zig` (`Document`)
- Modify: `src/toml.zig` (`parse`, `parseWithError`, `ParseResult`)
- Modify: `src/parser.zig` (`Parser.parse`)

This task closes Q-12. Holding the arena by pointer, and returning the document by pointer, eliminates the whole class of bugs where a move or copy of the `Document` struct invalidates the internal arena state. The signature change ripples through examples and docs — Task 12 handles those.

- [ ] **Step 1: Rewrite `Document` to own `*ArenaAllocator`**

Open `/home/benji/src/devnw/zig/toml/src/value.zig`. Find:

```zig
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
```

Replace with:

```zig
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
```

- [ ] **Step 2: Rewrite `Parser.parse` to return `*Document`**

Open `/home/benji/src/devnw/zig/toml/src/parser.zig`. Find `pub fn parse(self: *Parser) !Document` and replace its entire body with:

```zig
    pub fn parse(self: *Parser) !*Document {
        // UTF-8 validation (against the caller's original buffer).
        if (!std.unicode.utf8ValidateSlice(self.input)) {
            self.parse_error = err.makeError(.InvalidUtf8, .{}, "input is not valid UTF-8");
            return error.ParseFailed;
        }

        // Size limit check.
        if (self.input.len > self.options.max_bytes) {
            self.parse_error = err.makeError(.LimitExceeded, .{}, "input exceeds max_bytes limit");
            return error.ParseFailed;
        }

        const doc = try val.createDocument(self.alloc);
        errdefer doc.deinit();

        const arena_alloc = doc.allocator();

        // Arena-own the input (see Task 9 / P-5 commentary).
        const owned_input = try arena_alloc.dupe(u8, self.input);
        self.input = owned_input;
        self.lexer = Lexer.init(owned_input, self.options.version);

        // Prime the parser
        self.current = try self.nextToken();

        // Parse into the Document's root table.
        try self.parseDocument(arena_alloc, doc.root);

        return doc;
    }
```

- [ ] **Step 3: Update `toml.parse` and `parseWithError` to return `*Document`**

Open `/home/benji/src/devnw/zig/toml/src/toml.zig`. Replace the `parse` function:

```zig
pub fn parse(alloc: Allocator, input: []const u8, opts: ParseOptions) !Document {
    var parser = parser_mod.Parser.init(alloc, input, opts);
    return parser.parse() catch |e| {
        if (parser.parse_error) |_| {
            return error.ParseFailed;
        }
        return e;
    };
}
```

with:

```zig
pub fn parse(alloc: Allocator, input: []const u8, opts: ParseOptions) !*Document {
    var parser = parser_mod.Parser.init(alloc, input, opts);
    return parser.parse() catch |e| {
        if (parser.parse_error) |_| {
            return error.ParseFailed;
        }
        return e;
    };
}
```

Replace the `ParseResult` union:

```zig
pub const ParseResult = union(enum) {
    ok: Document,
    err: ParseError,
};
```

with:

```zig
pub const ParseResult = union(enum) {
    ok: *Document,
    err: ParseError,
};
```

The `parseWithError` function body is unchanged; only the returned `.ok` variant's *type* changed, and the compiler verifies it automatically.

- [ ] **Step 4: Update every in-tree test that binds `var doc = try parse(...)` to `const doc = try parse(...)`**

All 20+ tests inside `src/toml.zig` currently use `var doc = try parse(...)` and `defer doc.deinit()`. Because `parse` now returns `*Document` (a pointer), `var` is no longer required to call `deinit`; `const` suffices.

Do a bulk edit in `src/toml.zig`: replace every occurrence of `var doc = try parse(` with `const doc = try parse(` and every `var doc = try parseWithError(` with `const doc = try parseWithError(`. The `defer doc.deinit();` line is unchanged — `deinit` is a method on `*Document` which is already the handle we hold.

Similarly, the `parseWithError` tests have patterns like:

```zig
    switch (result) {
        .ok => |*d| {
            var doc = @constCast(d);
            doc.deinit();
            try std.testing.expect(false);
        },
        .err => {},
    }
```

Replace each such block with:

```zig
    switch (result) {
        .ok => |doc| {
            doc.deinit();
            try std.testing.expect(false);
        },
        .err => {},
    }
```

(The `.ok` variant is now `*Document` directly, so no `@constCast` is needed and no local `var doc` is required.)

- [ ] **Step 5: Update `writeTaggedJson` signature if needed**

`writeTaggedJson` currently takes `*const Document`, which is compatible with passing a `*Document` via implicit coercion — no change required. Confirm by searching:

```bash
grep -n 'writeTaggedJson' /home/benji/src/devnw/zig/toml/src/toml.zig /home/benji/src/devnw/zig/toml/src/json_tagged.zig
```

Both signatures should say `*const Document`. If any says `Document` by value, change it to `*const Document`.

- [ ] **Step 6: Run the test suite**

Run: `zig build test`

Expected: PASS. If there are compile errors, they will all be in test call sites — either the `@constCast` pattern in error-path tests or a stray `var doc = try parse` binding. Fix them exactly as described in Step 4.

- [ ] **Step 7: Commit**

```bash
git add src/value.zig src/parser.zig src/toml.zig
git commit -m "refactor(value,toml): Document owns *ArenaAllocator, parse returns *Document (Q-12)

Document now holds a pointer to its ArenaAllocator, not the allocator
by value. This prevents a whole class of move/copy bugs where the
embedded *anyopaque inside the Allocator handle captures the old
address. toml.parse returns *Document so callers cannot accidentally
trigger the same move-by-value footgun at the call site."
```

---

## Task 12: Propagate `*Document` through examples, accept tests, and CLI

**Files:**

- Modify: `examples/basic_parsing.zig`
- Modify: `examples/config_loader.zig`
- Modify: `examples/error_handling.zig`
- Modify: `examples/json_output.zig`
- Modify: `examples/value_types.zig`
- Modify: `tests/accept.zig` (remaining `var doc` binders)
- Modify: `src/bin/toml_test_decoder.zig`

Every caller is mechanically updated: `var doc = try toml.parse(...)` becomes `const doc = try toml.parse(...)`, and any code that did `doc.root.table.entries` becomes `toml.value_mod.tableIterator(doc.root)` or similar. Iterate one file at a time; commit after all examples pass.

- [ ] **Step 1: Update `examples/basic_parsing.zig`**

Open `/home/benji/src/devnw/zig/toml/examples/basic_parsing.zig`. At line 44, change:

```zig
    var doc = try toml.parse(allocator, input, .{});
    defer doc.deinit();
```

to:

```zig
    const doc = try toml.parse(allocator, input, .{});
    defer doc.deinit();
```

Find (around line 95):

```zig
    for (doc.root.table.entries) |entry| {
```

Replace with:

```zig
    var it = toml.value_mod.tableIterator(doc.root);
    while (it.next()) |entry| {
```

The loop body shape is the same; confirm the trailing `}` pairs correctly (one `}` to close the `while` block, same as the old `for`).

- [ ] **Step 2: Update the other four examples**

For each of `config_loader.zig`, `error_handling.zig`, `json_output.zig`, `value_types.zig`, apply the same mechanical `var -> const` change on every `try toml.parse(...)` call. If any example iterates `table.entries`, apply the `tableIterator` replacement from Step 1.

Use this shell command to find all call sites:

```bash
grep -nE 'var doc = try toml\.parse|\.table\.entries|\.array\.items\.len|\.array\.items\[' /home/benji/src/devnw/zig/toml/examples/*.zig
```

For `.array.items.len` occurrences, replace with `toml.value_mod.arrayLen(<expr>)` where `<expr>` is the Value. For `.array.items[i]`, replace with `toml.value_mod.arrayItems(<expr>)[i]`. These helpers were added in Task 3.

- [ ] **Step 3: Update remaining `var doc` binders in `tests/accept.zig`**

Run:

```bash
grep -nE '\.table\.entries|\.array\.items\.len|var doc = try' /home/benji/src/devnw/zig/toml/tests/accept.zig
```

Any remaining hits beyond the two already fixed in Task 5 get the same treatment. `var doc = try toml.parse(...)` becomes `const doc = try toml.parse(...)`.

- [ ] **Step 4: Update `src/bin/toml_test_decoder.zig`**

```bash
grep -nE 'var doc = try toml\.parse|doc\.deinit' /home/benji/src/devnw/zig/toml/src/bin/toml_test_decoder.zig
```

For each `var doc = try toml.parse(...)` hit, change `var` to `const`. If the file pattern-matches on `ParseResult.ok` via `|*d|` + `@constCast` (same shape as `parseWithError` tests), rewrite it to `|doc|` as in Task 11 Step 4.

- [ ] **Step 5: Build everything and run tests**

Run these in sequence:

```bash
zig build check
zig build test
zig build
```

Expected: all three succeed. The last line (`zig build`) ensures the CLI binary still links.

- [ ] **Step 6: Smoke-run the CLI**

Run: `zig build && ./zig-out/bin/toml-test-decoder <<<'a = 42'`

Expected: the CLI emits tagged-JSON for the single key. If it errors out, revisit Step 4.

- [ ] **Step 7: Commit**

```bash
git add examples/ tests/accept.zig src/bin/toml_test_decoder.zig
git commit -m "refactor(examples,tests,cli): use *Document and tableIterator helpers (Q-12)

Mechanical propagation of the Document pointer API. Replaces direct
.table.entries / .array.items access with the new tableIterator,
tableLen, arrayLen, and arrayItems helpers in value.zig."
```

---

## Task 13: Pin the `B-1` speedup with a ReleaseFast assertion

**Files:**

- Modify: `tests/bench_table_insert.zig`

The benchmark in Task 1 records a number but doesn't enforce it. Now that A, B, and C are complete, we can set a hard ceiling so future regressions fail the bench step.

- [ ] **Step 1: Add a ceiling assertion to `B-1`**

Open `/home/benji/src/devnw/zig/toml/tests/bench_table_insert.zig`. At the end of `test "B-1 parse 10k top-level keys (baseline)"`, after the existing `std.log.warn` line, append:

```zig
    // Ceiling: with hash-indexed tables and O(1) inserts, parsing 10k
    // top-level keys in ReleaseFast should take <200ms on any reasonable
    // x86_64 laptop. Debug is ~10x slower; skip the ceiling there.
    if (@import("builtin").mode != .Debug) {
        try std.testing.expect(elapsed_ns < 200 * std.time.ns_per_ms);
    }
```

- [ ] **Step 2: Run the benchmark**

Run: `zig build bench -Doptimize=ReleaseFast`

Expected: PASS. If it fails, either hardware is slower than assumed (raise the ceiling to 500ms and add a comment explaining the machine class) or there's a regression.

- [ ] **Step 3: Commit**

```bash
git add tests/bench_table_insert.zig
git commit -m "test(bench): pin 10k-key parse under 200ms in ReleaseFast (P-1)"
```

---

## Task 14: Document the behavior changes

**Files:**

- Modify: `docs/API.md`
- Modify: `docs/ARCHITECTURE.md`
- Modify: `CHANGELOG.md`
- Modify: `README.md` (only if it contains a snippet that binds `var doc`)

- [ ] **Step 1: Update `docs/API.md`**

Open `/home/benji/src/devnw/zig/toml/docs/API.md`. Find the `Document` section (around line 189-220). Replace the `pub const Document = struct { ... }` block with:

```zig
pub const Document = struct {
    root: *Value,
    arena: *std.heap.ArenaAllocator,
    gpa: Allocator,

    // `toml.parse` returns `*Document`. The struct is heap-allocated
    // on the same allocator passed to `parse`; both the arena and the
    // struct are freed by `deinit`.

    pub fn deinit(self: *Document) void;
    pub fn getPath(self: *const Document, path: []const []const u8) ?*const Value;
    pub fn allocator(self: *Document) Allocator;
};
```

Find the `parse` signature in API.md (around line 44):

```zig
pub fn parse(alloc: Allocator, input: []const u8, opts: ParseOptions) !Document
```

Replace with:

```zig
pub fn parse(alloc: Allocator, input: []const u8, opts: ParseOptions) !*Document
```

Find all usage examples that look like:

```zig
var doc = try toml.parse(allocator, "key = \"value\"", .{});
defer doc.deinit();
```

Replace each with:

```zig
const doc = try toml.parse(allocator, "key = \"value\"", .{});
defer doc.deinit();
```

Also add a new "Input Lifetime" subsection before the existing "Memory Management" section (around line 505). Insert the following Markdown block:

```markdown
### Input Lifetime

The input buffer passed to `toml.parse` may be freed immediately after
`parse` returns. The parser copies the bytes into the Document's arena
during `parse`, so every string, bare key, and path segment stored in
the returned `Document` is arena-owned.

```zig
const input_copy = try allocator.dupe(u8, user_input);
const doc = try toml.parse(allocator, input_copy, .{});
allocator.free(input_copy); // safe — doc owns its own copy
defer doc.deinit();
```

```text

- [ ] **Step 2: Update `docs/ARCHITECTURE.md`**

Find the section at line 281 (`root.table.entries` diagram). Replace any `table.entries` reference with `table.map (StringArrayHashMapUnmanaged, insertion-ordered)`. Keep the tree diagram shape; only the leaf label changes.

Also add a paragraph explaining insertion-order preservation: "`Value.Table` uses `std.StringArrayHashMapUnmanaged(*Value)` as its backing store. Iteration via `tableIterator` yields entries in insertion order; lookups via `get` / `getPath` are O(1)."

- [ ] **Step 3: Update `CHANGELOG.md`**

Open `/home/benji/src/devnw/zig/toml/CHANGELOG.md`. Immediately under the `## [Unreleased]` header's `### Added` section (line 10), insert:

```markdown
- `tableIterator`, `tableLen`, `arrayLen`, `arrayItems` helpers in
  `src/value.zig` / re-exported via `toml.value_mod`. Replace direct
  access to the old `table.entries: []TableEntry` field.
- Performance benchmark harness (`zig build bench`) with hard ceilings
  for 10k top-level keys (<200ms ReleaseFast) and 1000-entry inline
  tables (<50ms ReleaseFast).
```

Under `### Fixed` (line 23), insert:

```markdown
- Bare-key and literal-string storage are now fully arena-owned
  (`Parser.parse` copies input into its arena before tokenizing).
  Callers may free the input buffer as soon as `toml.parse` returns.
  Closes P-5.
- `Document` now holds `*ArenaAllocator` (pointer-owned). `toml.parse`
  returns `*Document`. This eliminates a latent move-by-value bug
  where the embedded `*anyopaque` in the arena's Allocator handle
  captured an old address. Closes Q-12.
```

Under `### Changed` (line 37), insert:

```markdown
- `Value.Table.entries: []TableEntry` replaced with
  `Value.Table.map: std.StringArrayHashMapUnmanaged(*Value)`. Inserts,
  lookups, and dup-checks are now O(1) amortized. Iteration order is
  preserved. Closes P-1, P-2, P-12.
- **Breaking:** `toml.parse` and `toml.parseWithError` return
  `*Document` / `ParseResult { ok: *Document, err: ParseError }`.
  Migration: change `var doc = try toml.parse(...)` to
  `const doc = try toml.parse(...)`; `defer doc.deinit();` is
  unchanged (it is now a method on `*Document`).
```

- [ ] **Step 4: Update `README.md` if it has a code snippet**

Run:

```bash
grep -nE 'var doc = try toml\.parse' /home/benji/src/devnw/zig/toml/README.md
```

If any hits, change `var` to `const` at each site.

- [ ] **Step 5: Build and test once more to make sure no doc change snuck into a code path**

Run: `zig build test`

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add docs/API.md docs/ARCHITECTURE.md CHANGELOG.md README.md
git commit -m "docs: document Table hash-indexing, *Document, and input-lifetime (A/B/C)

API.md: updated Document signature, parse return type, and added an
Input Lifetime subsection. ARCHITECTURE.md: table.entries -> table.map
with insertion-order note. CHANGELOG.md: Unreleased entries for P-1,
P-2, P-5, P-12, Q-12 and the breaking *Document return type."
```

---

## Task 15: Version bump to 0.2.0

**Files:**

- Modify: `build.zig.zon`
- Modify: `CHANGELOG.md` (promote Unreleased -> 0.2.0)
- Modify: `docs/API.md` (Library Version header)

- [ ] **Step 1: Bump the package version**

Open `/home/benji/src/devnw/zig/toml/build.zig.zon`. Change:

```zig
    .version = "0.1.0",
```

to:

```zig
    .version = "0.2.0",
```

- [ ] **Step 2: Promote Unreleased entries to the 0.2.0 section in CHANGELOG.md**

Replace:

```markdown
## [Unreleased]
```

with:

```markdown
## [0.2.0] - 2026-04-18

### Breaking

- `toml.parse` and `toml.parseWithError` now return `*Document` /
  `ParseResult { ok: *Document, err: ParseError }` instead of
  `Document` by value. See the migration note in `### Changed`.

```

Keep the existing `### Added` / `### Fixed` / `### Changed` blocks underneath the new header.

- [ ] **Step 3: Update the Library Version header in `docs/API.md`**

Find the existing Library Version header (a prior commit noted it was corrected from `1.0` to `0.1.0`). Change `0.1.0` -> `0.2.0`.

- [ ] **Step 4: Build and test**

Run: `zig build test`

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add build.zig.zon CHANGELOG.md docs/API.md
git commit -m "chore(release): 0.2.0 -- table hash index, arena-owned input, *Document

Closes P-1, P-2, P-5, P-12, Q-12. Breaking: toml.parse returns
*Document; migration is one line per call site (var -> const)."
```

---

## Task 16: Self-review pass

This is not a commit; it's a checklist you run against the tree after Task 15 lands.

- [ ] **Step 1: Spec coverage check**

Walk each defect in the "Background and Failure Modes Closed" section at the top of this plan and point to the task that closes it:

| Defect | Task | Pin |
|--------|------|-----|
| P-1 (O(n^2) growth) | Task 3 (new storage), Task 13 (perf pin) | B-1 <200ms |
| P-2 (linear lookups) | Task 3 + Task 4 + Task 5 | C-1..C-4 + B-1 |
| P-5 (redundant dupe + UAF) | Task 8 (test), Task 9 (fix), Task 10 (cleanup) | U-B2 |
| P-12 (inline dup-check O(n^2)) | Task 6 (direct-insert), Task 7 (bench pin) | B-2 <50ms |
| Q-12 (Document move invalidation) | Task 11 (pointer-owned arena), Task 12 (propagation) | all existing tests still pass with `*Document` |

If any row has no task, stop and add one.

- [ ] **Step 2: Placeholder scan**

Run:

```bash
grep -nE 'TODO|TBD|FIXME|similar to Task|fill in' /home/benji/src/devnw/zig/toml/docs/superpowers/plans/2026-04-18-03-value-hash-index.md
```

Expect zero hits.

- [ ] **Step 3: Type/name consistency**

Walk the plan for every symbol introduced and confirm the name is identical everywhere it appears:

- `tableIterator` (not `tableIter`, not `iterateTable`) — used in Tasks 2, 3, 4, 12.
- `tableLen`, `arrayLen`, `arrayItems` — used in Tasks 2, 3, 5, 12.
- `Value.Table.map` (not `entries_map` or `index`) — used in Tasks 3, 4, 5, 6.
- `createDocument` — used in Tasks 11.
- `ParseResult.ok: *Document` (not `ok: Document`) — used in Tasks 11, 12.

- [ ] **Step 4: Full-tree sanity run**

Run:

```bash
zig build check
zig build test
zig build bench -Doptimize=ReleaseFast
zig build -Doptimize=ReleaseFast
```

All four must succeed. This is the final acceptance gate before declaring the plan complete.

- [ ] **Step 5: Post-merge hygiene**

Confirm the branch has clean intermediate commits (one per task from 1 through 15), each of which at least compiles individually *except* for the explicitly-marked WIP commits in Task 3 and Task 4. If any non-WIP commit fails `zig build check`, squash or amend the offending change into the next task's commit and re-record the commit message.

---

## Appendix A: Expected final call-site counts

After the plan lands, these greps should return zero:

- `grep -rn 'table\.entries' src/ tests/ examples/` → 0
- `grep -rn 'std\.mem\.eql.*entry\.key' src/` → 0
- `grep -rn 'alloc\.dupe.*self\.current\.slice' src/` → 0
- `grep -rn 'alloc\.dupe.*path\.items\[0\]' src/` → 0
- `grep -rn 'arena: std\.heap\.ArenaAllocator' src/` → 0 (it is now `*std.heap.ArenaAllocator`)
- `grep -rn '!Document' src/` → 0 (it is now `!*Document`)
- `grep -rn 'var doc = try toml\.parse' src/ tests/ examples/` → 0 (all `const`)

## Appendix B: Risk register

- **R1: StringArrayHashMapUnmanaged rehash during inserts** — if `tableSet` is called in a hot loop without `ensureTotalCapacity`, the map doubles its internal buffer a few times. Task 6 addresses this for inline tables (capacity 16 up front); top-level tables don't have an a-priori key count, and `put` amortized is O(1) — acceptable. If Task 5's benchmark shows <10x speedup, revisit this.
- **R2: Key slice aliasing after input copy** — because input is arena-duped in `Parser.parse`, every `self.input[...]` slice is arena-owned. But the lexer must also re-init with the owned copy (Task 9 Step 1 handles this). If tests pass after Task 9 but fail after Task 10, the lexer-reinit step was missed.
- **R3: Examples drift** — Task 12 is the largest mechanical edit. After `zig build` passes, run each example binary once (build and invoke manually) to catch output regressions the compiler can't see.
- **R4: Downstream SemVer** — This is a breaking API change. Task 15 cuts 0.2.0. Any downstream project (referenced in `build.zig.zon` of consumers) must migrate `var` -> `const` on `toml.parse` sites. The migration note in `CHANGELOG.md` makes this explicit.

## Appendix C: Why `StringArrayHashMapUnmanaged` and not `StringHashMapUnmanaged(usize)` as an index-aside?

The `docs/PERF_GAP_ANALYSIS.md` currently floats an `ArrayListUnmanaged(TableEntry) + StringHashMapUnmanaged(usize)` design where the hash map is an *index* into a separate array. That design has two drawbacks versus `StringArrayHashMapUnmanaged(*Value)`:

1. Two allocations per table (list + map) vs one.
2. Every insertion is two operations (`map.put(key, index)` + `list.append(entry)`) that must stay consistent; a partial failure leaves the table corrupt. `StringArrayHashMapUnmanaged.put` is one atomic operation.

`StringArrayHashMapUnmanaged` preserves insertion order *and* gives O(1) lookup in a single structure. There is no semantic benefit to the split design for this workload — the JSON emitter already snapshots to a scratch buffer to sort, so it doesn't care whether keys live in the hash map or a sidecar array.

---

## Execution Handoff

Plan complete. Two execution options:

**1. Subagent-Driven (recommended)** — dispatch a fresh subagent per task, review between tasks, fast iteration.

**2. Inline Execution** — execute tasks in the current session using `superpowers:executing-plans`, batch execution with checkpoints.

Which approach?
