# TOML Encoder Suite Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Land a spec-compliant TOML encoder, a `toml-test-encoder` CLI binary, and pretty-print / deterministic-output options that together close GAP-0006, GAP-0007, and GAP-0008.

**Architecture:** Add a standalone `src/encoder.zig` module with a single public entry point `encode(doc, writer, options) !void` that walks a `Document` and emits TOML v1.0.0 grammar. Add a `src/bin/toml_test_encoder.zig` CLI that consumes toml-test tagged JSON on stdin, reconstructs a `Document` via `std.json`, calls the encoder, and writes TOML to stdout. Pretty-print is an option bundle on the encoder (sort keys, indent, inline-array wrapping), not a separate module.

**Tech Stack:** Zig 0.16.0; `std.Io.Writer`; `std.json` for the CLI's JSON-in direction; arena allocation via `Document.arena`; existing value/datetime types from `src/value.zig`.

---

## Context for the Implementer

You will not have the parser or tagged-JSON emitter authors around to ask questions. Read these files before starting — they are the only ground truth:

- `/home/benji/src/devnw/zig/toml/src/toml.zig` — the public API surface. You will add a new `encode` export that mirrors the shape of `writeTaggedJson` (line 77).
- `/home/benji/src/devnw/zig/toml/src/value.zig` — `Value`, `Document`, `TableEntry`, `DateTime`, `DateTimeLocal`, `DateLocal`, `TimeLocal`. `Value.Table` has `is_inline`, `is_array_of_tables`, `defined_explicitly`, `defined_by_dotted_key`, `is_closed_inline` fields — you will use them in the encoder's decision logic. `Value.Array` has `is_static` (true for `[]`, false for `[[header]]`).
- `/home/benji/src/devnw/zig/toml/src/json_tagged.zig` — the inverse direction. Study `writeValue` (line 24) and `writeJsonString` (line 121). The encoder's structure mirrors it but emits TOML syntax instead of JSON.
- `/home/benji/src/devnw/zig/toml/src/bin/toml_test_decoder.zig` — the sibling CLI. The encoder CLI will duplicate its buffered I/O scaffolding and allocator selection almost line-for-line, only swapping the direction.
- `/home/benji/src/devnw/zig/toml/build.zig` — you will add the encoder CLI as a second executable artifact alongside `toml-test-decoder` (lines 44-56).

Conventions in this codebase (read, don't reinvent):

1. SPDX header on every file: `// SPDX-License-Identifier: Apache-2.0` then `// Copyright (c) 2024-2025 CodePros`.
2. Doc comments use `//!` at file scope and `///` on items. Keep them short and declarative.
3. Tests are colocated at the bottom of the source file under `test "name" { ... }` blocks. Integration / golden tests live in `/home/benji/src/devnw/zig/toml/tests/`.
4. Allocators: library code receives an `Allocator` argument; `Document` exposes an arena via `Document.allocator()`. CLI binaries pick `DebugAllocator` in Debug and `std.heap.smp_allocator` in release (see `toml_test_decoder.zig:22-29`).
5. Writer pattern: callers pass `anytype` writer. See `writeTaggedJson` for the exact signature.
6. Errors: use `!void` returns. Do not invent new ErrorCode values — the encoder should only surface allocator / writer errors.
7. Commits: conventional prefixes (`feat`, `fix`, `docs`, `chore`, `test`). One commit per task (see "Commit" steps).

The plan is TDD. Each task writes the failing test before the implementation. Do not skip the "run the test and watch it fail" step — it guards against dead tests and against accidentally passing for the wrong reason.

---

## File Structure

**New files:**

- `src/encoder.zig` — encoder module. Public: `EncodeOptions`, `encode(doc, writer, options) !void`. Private: helpers for each value kind, a `Ctx` struct carrying options and depth.
- `src/bin/toml_test_encoder.zig` — CLI binary. Reads tagged JSON stdin, reconstructs `Document` via `std.json.parseFromSlice`, calls `encoder.encode`, writes stdout.
- `tests/encoder_roundtrip.zig` — integration tests that assert `parse(encode(parse(x))) == parse(x)` across a corpus of TOML strings.
- `tests/encoder_golden.zig` — golden output tests for pretty-print determinism.

**Modified files:**

- `src/toml.zig` — re-export `encoder` module and add a public `encode` wrapper.
- `build.zig` — add `toml-test-encoder` executable, add `encoder_roundtrip` and `encoder_golden` test steps to `test_step`.
- `.gitlab-ci.yml` — append a toml-test conformance stage that invokes both decoder and encoder (marked `allow_failure: true` initially).
- `docs/API.md` — add an `Encoding` section with the new signatures.
- `docs/ARCHITECTURE.md` — expand the diagram with an Encoder box.
- `CHANGELOG.md` — add `[Unreleased]` bullets.

---

## Encoder Design Notes

These decisions are fixed by the plan. Do not re-litigate them mid-task.

**Header vs inline for tables.** A non-inline table with at least one non-primitive child (nested table or array-of-tables) is emitted as a `[header]` section. A leaf table whose children are all primitives can also use a `[header]` section — prefer headers over inline tables for readability. Only emit `{ ... }` inline tables when the input's `Value.Table.is_inline == true` (i.e. the source used inline syntax) or when an array element is a table (because array-of-tables has its own `[[header]]` syntax but elements of a `static` array of tables must be inline).

**Dotted-key collapse.** Do NOT collapse nested tables into dotted keys. Always emit `[a.b.c]` headers. This yields one obvious output per input and simplifies the encoder.

**Key quoting.** A key is bare if it matches `[A-Za-z0-9_-]+` and is non-empty. Otherwise it becomes a basic string with escapes.

**Integer format.** Always emit decimal. The source format (hex/oct/bin) is not preserved — the round-trip contract is value equality, not byte equality.

**Float format.** Finite values are formatted with Zig's default `{d}` format and a trailing `.0` appended if no `.`, `e`, or `E` appears (same rule as `json_tagged.zig:formatFloat`). `+inf` -> `inf`, `-inf` -> `-inf`, NaN -> `nan`.

**String format.** Always basic (double-quoted) with JSON-style escapes for control chars, `"`, `\`. Do not emit literal strings or multi-line strings — they are the parser's concern, not the encoder's.

**Datetime format.** Delegate to the existing `format` methods on `DateTime`, `DateTimeLocal`, `DateLocal`, `TimeLocal` (see `src/value.zig:34-136`).

**Array format.** Arrays of primitives are inline `[a, b, c]`. Arrays of tables use `[[header]]` syntax when `is_static == false`, and inline `[{...}, {...}]` when `is_static == true` (the source used `[` not `[[`).

**Sort keys.** Default `sort_keys = true`. When true, every table's entries are sorted by key byte order before emission (same rule as `json_tagged.zig:tableEntryLessThan`). When false, preserve insertion order.

**Indent.** `indent: u8 = 0` is the indent-spaces count used for nested inline-array wrapping. `0` means never wrap. When `> 0`, inline arrays with more than `inline_threshold` elements are written one element per line with the configured indent.

**Inline threshold.** `inline_threshold: usize = 8` by default.

---

## Tasks

### Task 1: Create the encoder module scaffold

**Files:**

- Create: `/home/benji/src/devnw/zig/toml/src/encoder.zig`
- Test: colocated in `src/encoder.zig`

- [ ] **Step 1: Write the failing test**

Create `/home/benji/src/devnw/zig/toml/src/encoder.zig` with just this content:

```zig
// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! TOML encoder. Serializes a Document back to TOML text.

const std = @import("std");
const value_mod = @import("value.zig");
const Document = value_mod.Document;

/// Options controlling encoder output.
pub const EncodeOptions = struct {
    sort_keys: bool = true,
    indent: u8 = 0,
    inline_threshold: usize = 8,
};

/// Write `doc` as TOML text to `writer` using `options`.
pub fn encode(doc: *const Document, writer: anytype, options: EncodeOptions) !void {
    _ = doc;
    _ = writer;
    _ = options;
}

test "encode empty document produces empty output" {
    const parser_mod = @import("parser.zig");
    const input = "";
    var parser = parser_mod.Parser.init(std.testing.allocator, input, .{});
    var doc = try parser.parse();
    defer doc.deinit();

    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();

    try encode(&doc, &aw.writer, .{});
    try std.testing.expectEqualStrings("", aw.written());
}
```

- [ ] **Step 2: Wire the module into the test build**

Open `/home/benji/src/devnw/zig/toml/src/toml.zig`. After the `json_tagged` re-export on line 30, add:

```zig
pub const encoder = @import("encoder.zig");
```

This is enough to make `zig build test` pick up the encoder's `test "..."` blocks because the unit-test module roots at `src/toml.zig` (see `build.zig:59-68`).

- [ ] **Step 3: Run the test to verify it passes**

Run: `zig build test 2>&1 | head -40`
Expected: all tests pass; the new "encode empty document" test is among them.

- [ ] **Step 4: Commit**

```bash
git add src/encoder.zig src/toml.zig
git commit -m "feat(encoder): scaffold encoder module

Adds src/encoder.zig with a no-op encode() entry point and an EncodeOptions
struct. Wired into the public toml module so unit tests are discovered.
Groundwork for GAP-0006."
```

---

### Task 2: Encode bare integer key-value

**Files:**

- Modify: `/home/benji/src/devnw/zig/toml/src/encoder.zig`

- [ ] **Step 1: Write the failing test**

Append to `src/encoder.zig` above the existing `test "encode empty document..."`:

```zig
test "encode single integer key-value" {
    const parser_mod = @import("parser.zig");
    const input = "a = 42\n";
    var parser = parser_mod.Parser.init(std.testing.allocator, input, .{});
    var doc = try parser.parse();
    defer doc.deinit();

    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();

    try encode(&doc, &aw.writer, .{});
    try std.testing.expectEqualStrings("a = 42\n", aw.written());
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `zig build test 2>&1 | grep -A2 "encode single integer"`
Expected: FAIL with `expected "a = 42\n", found ""`.

- [ ] **Step 3: Implement the walker skeleton plus integer emission**

Replace the body of `encode` and add helpers. The file should now look like:

```zig
// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! TOML encoder. Serializes a Document back to TOML text.

const std = @import("std");
const value_mod = @import("value.zig");
const Value = value_mod.Value;
const Document = value_mod.Document;
const TableEntry = value_mod.TableEntry;

/// Options controlling encoder output.
pub const EncodeOptions = struct {
    sort_keys: bool = true,
    indent: u8 = 0,
    inline_threshold: usize = 8,
};

/// Write `doc` as TOML text to `writer` using `options`.
pub fn encode(doc: *const Document, writer: anytype, options: EncodeOptions) !void {
    try writeRootTable(doc.root, writer, options);
}

fn writeRootTable(root: *const Value, writer: anytype, options: EncodeOptions) !void {
    std.debug.assert(root.* == .table);
    for (root.table.entries) |entry| {
        try writeBareKeyValue(entry, writer, options);
    }
}

fn writeBareKeyValue(entry: TableEntry, writer: anytype, options: EncodeOptions) !void {
    _ = options;
    try writeKey(entry.key, writer);
    try writer.writeAll(" = ");
    try writeLeafValue(entry.value, writer);
    try writer.writeByte('\n');
}

fn writeKey(key: []const u8, writer: anytype) !void {
    // Bare-key rule: non-empty and every byte in [A-Za-z0-9_-].
    if (isBareKey(key)) {
        try writer.writeAll(key);
        return;
    }
    try writeBasicString(key, writer);
}

fn isBareKey(key: []const u8) bool {
    if (key.len == 0) return false;
    for (key) |c| {
        const ok = (c >= 'A' and c <= 'Z') or
            (c >= 'a' and c <= 'z') or
            (c >= '0' and c <= '9') or
            c == '_' or c == '-';
        if (!ok) return false;
    }
    return true;
}

fn writeBasicString(s: []const u8, writer: anytype) !void {
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

fn writeLeafValue(v: *const Value, writer: anytype) !void {
    switch (v.*) {
        .integer => |n| try writer.print("{d}", .{n}),
        else => return error.Unimplemented,
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `zig build test 2>&1 | grep -E "(encode single integer|FAIL|error)"`
Expected: the encode tests pass. No errors.

- [ ] **Step 5: Commit**

```bash
git add src/encoder.zig
git commit -m "feat(encoder): emit bare-key integer assignments

Walk the root table and emit 'key = <int>' lines. Bare-key detection uses
the TOML v1 rule [A-Za-z0-9_-]+; non-bare keys become basic strings."
```

---

### Task 3: Encode boolean values

**Files:**

- Modify: `/home/benji/src/devnw/zig/toml/src/encoder.zig`

- [ ] **Step 1: Write the failing test**

Append to `src/encoder.zig`:

```zig
test "encode boolean values" {
    const parser_mod = @import("parser.zig");
    const input =
        \\t = true
        \\f = false
        \\
    ;
    var parser = parser_mod.Parser.init(std.testing.allocator, input, .{});
    var doc = try parser.parse();
    defer doc.deinit();

    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();

    try encode(&doc, &aw.writer, .{});
    try std.testing.expectEqualStrings("f = false\nt = true\n", aw.written());
}
```

The test expects keys in sorted order because `sort_keys` defaults to `true`. We will implement sorting later in Task 12 — for now we hard-code it into the root walker. (That ordering is what toml-test demands, so it will hold for the rest of the plan.)

- [ ] **Step 2: Run the test to verify it fails**

Run: `zig build test 2>&1 | grep -A3 "encode boolean values"`
Expected: FAIL — both because booleans are unimplemented AND because sort isn't applied.

- [ ] **Step 3: Implement boolean emission AND sorted root-table traversal**

In `src/encoder.zig`, change `writeRootTable` to sort a copy of the entries before iterating:

```zig
fn writeRootTable(root: *const Value, writer: anytype, options: EncodeOptions) !void {
    std.debug.assert(root.* == .table);
    try writeSortedEntries(root.table.entries, writer, options);
}

fn writeSortedEntries(entries: []const TableEntry, writer: anytype, options: EncodeOptions) !void {
    // Copy to a stack buffer for small tables; allocate from smp_allocator otherwise.
    // Matches the strategy in src/json_tagged.zig for determinism guarantees.
    var stack_sorted: [256]TableEntry = undefined;
    var heap_sorted: ?[]TableEntry = null;
    defer if (heap_sorted) |slice| std.heap.smp_allocator.free(slice);

    const sorted: []TableEntry = if (!options.sort_keys) blk: {
        // Cast away const; we won't mutate when not sorting.
        break :blk @constCast(entries);
    } else if (entries.len <= stack_sorted.len) blk: {
        @memcpy(stack_sorted[0..entries.len], entries);
        break :blk stack_sorted[0..entries.len];
    } else blk: {
        const buf = try std.heap.smp_allocator.alloc(TableEntry, entries.len);
        @memcpy(buf, entries);
        heap_sorted = buf;
        break :blk buf;
    };
    if (options.sort_keys) std.sort.pdq(TableEntry, sorted, {}, entryLessThan);

    for (sorted) |entry| {
        try writeBareKeyValue(entry, writer, options);
    }
}

fn entryLessThan(_: void, a: TableEntry, b: TableEntry) bool {
    return std.mem.order(u8, a.key, b.key) == .lt;
}
```

Extend `writeLeafValue` with the boolean case:

```zig
fn writeLeafValue(v: *const Value, writer: anytype) !void {
    switch (v.*) {
        .integer => |n| try writer.print("{d}", .{n}),
        .bool => |b| try writer.writeAll(if (b) "true" else "false"),
        else => return error.Unimplemented,
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `zig build test 2>&1 | grep -E "(encode boolean|encode single|FAIL|error)"`
Expected: both tests pass.

- [ ] **Step 5: Commit**

```bash
git add src/encoder.zig
git commit -m "feat(encoder): emit booleans and sort root-table keys

Root table entries are sorted by byte order before emission when
sort_keys=true (the default). Uses the same stack/heap sort strategy
as json_tagged.zig for tables of any size."
```

---

### Task 4: Encode string values

**Files:**

- Modify: `/home/benji/src/devnw/zig/toml/src/encoder.zig`

- [ ] **Step 1: Write the failing test**

Append to `src/encoder.zig`:

```zig
test "encode string values with escapes" {
    const parser_mod = @import("parser.zig");
    const input =
        \\plain = "hello"
        \\tab = "a\tb"
        \\newline = "a\nb"
        \\quote = "say \"hi\""
        \\backslash = "a\\b"
        \\
    ;
    var parser = parser_mod.Parser.init(std.testing.allocator, input, .{});
    var doc = try parser.parse();
    defer doc.deinit();

    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();

    try encode(&doc, &aw.writer, .{});
    // Sorted: backslash, newline, plain, quote, tab
    const expected =
        "backslash = \"a\\\\b\"\n" ++
        "newline = \"a\\nb\"\n" ++
        "plain = \"hello\"\n" ++
        "quote = \"say \\\"hi\\\"\"\n" ++
        "tab = \"a\\tb\"\n";
    try std.testing.expectEqualStrings(expected, aw.written());
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `zig build test 2>&1 | grep -A3 "encode string values"`
Expected: FAIL because `.string` arm returns `error.Unimplemented`.

- [ ] **Step 3: Extend `writeLeafValue` with the string case**

```zig
fn writeLeafValue(v: *const Value, writer: anytype) !void {
    switch (v.*) {
        .integer => |n| try writer.print("{d}", .{n}),
        .bool => |b| try writer.writeAll(if (b) "true" else "false"),
        .string => |s| try writeBasicString(s, writer),
        else => return error.Unimplemented,
    }
}
```

`writeBasicString` already exists from Task 2.

- [ ] **Step 4: Run the test to verify it passes**

Run: `zig build test 2>&1 | grep -E "(encode string|FAIL|error)"`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/encoder.zig
git commit -m "feat(encoder): emit basic-string values

Always emits double-quoted basic strings with JSON-style escapes for
control chars, backslash, and double quote. Literal and multi-line
forms are deliberately not used: one canonical output per input."
```

---

### Task 5: Encode float values

**Files:**

- Modify: `/home/benji/src/devnw/zig/toml/src/encoder.zig`

- [ ] **Step 1: Write the failing test**

Append to `src/encoder.zig`:

```zig
test "encode float values including special forms" {
    const parser_mod = @import("parser.zig");
    const input =
        \\pi = 3.14
        \\whole = 1.0
        \\positive_inf = inf
        \\negative_inf = -inf
        \\not_a_number = nan
        \\
    ;
    var parser = parser_mod.Parser.init(std.testing.allocator, input, .{});
    var doc = try parser.parse();
    defer doc.deinit();

    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();

    try encode(&doc, &aw.writer, .{});
    // Sorted: negative_inf, not_a_number, pi, positive_inf, whole
    const expected =
        "negative_inf = -inf\n" ++
        "not_a_number = nan\n" ++
        "pi = 3.14\n" ++
        "positive_inf = inf\n" ++
        "whole = 1.0\n";
    try std.testing.expectEqualStrings(expected, aw.written());
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `zig build test 2>&1 | grep -A3 "encode float values"`
Expected: FAIL (unimplemented).

- [ ] **Step 3: Implement float formatting**

Add a helper and extend `writeLeafValue`:

```zig
fn writeFloat(f: f64, writer: anytype) !void {
    if (std.math.isNan(f)) {
        try writer.writeAll("nan");
        return;
    }
    if (std.math.isInf(f)) {
        try writer.writeAll(if (f < 0) "-inf" else "inf");
        return;
    }
    // Format with default precision, then ensure a decimal indicator exists.
    var buf: [64]u8 = undefined;
    const formatted = try std.fmt.bufPrint(&buf, "{d}", .{f});
    try writer.writeAll(formatted);
    var has_point = false;
    for (formatted) |c| {
        if (c == '.' or c == 'e' or c == 'E') {
            has_point = true;
            break;
        }
    }
    if (!has_point) try writer.writeAll(".0");
}

fn writeLeafValue(v: *const Value, writer: anytype) !void {
    switch (v.*) {
        .integer => |n| try writer.print("{d}", .{n}),
        .bool => |b| try writer.writeAll(if (b) "true" else "false"),
        .string => |s| try writeBasicString(s, writer),
        .float => |f| try writeFloat(f, writer),
        else => return error.Unimplemented,
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `zig build test 2>&1 | grep -E "(encode float|FAIL|error)"`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/encoder.zig
git commit -m "feat(encoder): emit floats including inf and nan

Finite floats are formatted with Zig's default {d} formatter; a trailing
.0 is appended if no decimal indicator is present. inf/-inf/nan map to
the literal TOML tokens."
```

---

### Task 6: Encode datetime/date/time values

**Files:**

- Modify: `/home/benji/src/devnw/zig/toml/src/encoder.zig`

- [ ] **Step 1: Write the failing test**

Append to `src/encoder.zig`:

```zig
test "encode datetime values delegate to Value format methods" {
    const parser_mod = @import("parser.zig");
    const input =
        \\dt_utc = 2024-01-15T10:30:00Z
        \\dt_local = 2024-01-15T10:30:00
        \\d_local = 2024-01-15
        \\t_local = 10:30:00
        \\
    ;
    var parser = parser_mod.Parser.init(std.testing.allocator, input, .{});
    var doc = try parser.parse();
    defer doc.deinit();

    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();

    try encode(&doc, &aw.writer, .{});
    // Sorted: d_local, dt_local, dt_utc, t_local
    const expected =
        "d_local = 2024-01-15\n" ++
        "dt_local = 2024-01-15T10:30:00\n" ++
        "dt_utc = 2024-01-15T10:30:00Z\n" ++
        "t_local = 10:30:00\n";
    try std.testing.expectEqualStrings(expected, aw.written());
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `zig build test 2>&1 | grep -A3 "encode datetime values"`
Expected: FAIL.

- [ ] **Step 3: Extend `writeLeafValue` with datetime arms**

The `DateTime`, `DateTimeLocal`, `DateLocal`, `TimeLocal` structs in `src/value.zig` each already expose a `format(writer)` method that emits the exact TOML lexical form we want. Just delegate:

```zig
fn writeLeafValue(v: *const Value, writer: anytype) !void {
    switch (v.*) {
        .integer => |n| try writer.print("{d}", .{n}),
        .bool => |b| try writer.writeAll(if (b) "true" else "false"),
        .string => |s| try writeBasicString(s, writer),
        .float => |f| try writeFloat(f, writer),
        .datetime => |dt| try dt.format(writer),
        .datetime_local => |dt| try dt.format(writer),
        .date_local => |d| try d.format(writer),
        .time_local => |t| try t.format(writer),
        else => return error.Unimplemented,
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `zig build test 2>&1 | grep -E "(encode datetime|FAIL|error)"`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/encoder.zig
git commit -m "feat(encoder): emit datetime, datetime-local, date, time values

Delegates to the format() methods on DateTime, DateTimeLocal, DateLocal,
and TimeLocal in src/value.zig, which already produce the correct ISO
8601 lexical form."
```

---

### Task 7: Encode inline arrays of primitives

**Files:**

- Modify: `/home/benji/src/devnw/zig/toml/src/encoder.zig`

- [ ] **Step 1: Write the failing test**

Append to `src/encoder.zig`:

```zig
test "encode inline array of integers" {
    const parser_mod = @import("parser.zig");
    const input = "nums = [1, 2, 3]\n";
    var parser = parser_mod.Parser.init(std.testing.allocator, input, .{});
    var doc = try parser.parse();
    defer doc.deinit();

    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();

    try encode(&doc, &aw.writer, .{});
    try std.testing.expectEqualStrings("nums = [1, 2, 3]\n", aw.written());
}

test "encode inline array of strings" {
    const parser_mod = @import("parser.zig");
    const input = "fruits = [\"apple\", \"pear\"]\n";
    var parser = parser_mod.Parser.init(std.testing.allocator, input, .{});
    var doc = try parser.parse();
    defer doc.deinit();

    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();

    try encode(&doc, &aw.writer, .{});
    try std.testing.expectEqualStrings("fruits = [\"apple\", \"pear\"]\n", aw.written());
}

test "encode empty inline array" {
    const parser_mod = @import("parser.zig");
    const input = "x = []\n";
    var parser = parser_mod.Parser.init(std.testing.allocator, input, .{});
    var doc = try parser.parse();
    defer doc.deinit();

    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();

    try encode(&doc, &aw.writer, .{});
    try std.testing.expectEqualStrings("x = []\n", aw.written());
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `zig build test 2>&1 | grep -A3 "encode inline array"`
Expected: FAIL (arrays hit `else => error.Unimplemented`).

- [ ] **Step 3: Add an array-of-primitives helper**

Add to `src/encoder.zig`:

```zig
fn writeInlineArray(arr: *const Value, writer: anytype, options: EncodeOptions) !void {
    std.debug.assert(arr.* == .array);
    const items = arr.array.items;
    try writer.writeByte('[');
    for (items, 0..) |item, i| {
        if (i > 0) try writer.writeAll(", ");
        try writeAnyValue(item, writer, options);
    }
    try writer.writeByte(']');
}

fn writeAnyValue(v: *const Value, writer: anytype, options: EncodeOptions) !void {
    switch (v.*) {
        .array => try writeInlineArray(v, writer, options),
        .table => return error.InlineTableNotYetSupported, // fixed in a later task
        else => try writeLeafValue(v, writer),
    }
}
```

Update the array arm of `writeLeafValue` so it never reaches the `else` branch:

```zig
fn writeLeafValue(v: *const Value, writer: anytype) !void {
    switch (v.*) {
        .integer => |n| try writer.print("{d}", .{n}),
        .bool => |b| try writer.writeAll(if (b) "true" else "false"),
        .string => |s| try writeBasicString(s, writer),
        .float => |f| try writeFloat(f, writer),
        .datetime => |dt| try dt.format(writer),
        .datetime_local => |dt| try dt.format(writer),
        .date_local => |d| try d.format(writer),
        .time_local => |t| try t.format(writer),
        .array, .table => unreachable, // routed via writeAnyValue
    }
}
```

And update `writeBareKeyValue` to dispatch arrays through `writeAnyValue`:

```zig
fn writeBareKeyValue(entry: TableEntry, writer: anytype, options: EncodeOptions) !void {
    try writeKey(entry.key, writer);
    try writer.writeAll(" = ");
    try writeAnyValue(entry.value, writer, options);
    try writer.writeByte('\n');
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `zig build test 2>&1 | grep -E "(encode inline array|encode empty inline|FAIL|error)"`
Expected: PASS for all three array tests.

- [ ] **Step 5: Commit**

```bash
git add src/encoder.zig
git commit -m "feat(encoder): emit inline arrays of primitives

Arrays are emitted as [a, b, c] on a single line. Routing for nested
arrays and inline tables goes through a new writeAnyValue dispatcher."
```

---

### Task 8: Encode nested tables as `[header]` sections

**Files:**

- Modify: `/home/benji/src/devnw/zig/toml/src/encoder.zig`

- [ ] **Step 1: Write the failing test**

Append to `src/encoder.zig`:

```zig
test "encode single-level header table" {
    const parser_mod = @import("parser.zig");
    const input =
        \\title = "Config"
        \\[server]
        \\host = "localhost"
        \\port = 8080
        \\
    ;
    var parser = parser_mod.Parser.init(std.testing.allocator, input, .{});
    var doc = try parser.parse();
    defer doc.deinit();

    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();

    try encode(&doc, &aw.writer, .{});
    // Primitives emitted first (only "title"), then the header section.
    // Inside [server], keys sorted: host, port.
    const expected =
        "title = \"Config\"\n" ++
        "\n" ++
        "[server]\n" ++
        "host = \"localhost\"\n" ++
        "port = 8080\n";
    try std.testing.expectEqualStrings(expected, aw.written());
}

test "encode nested header table" {
    const parser_mod = @import("parser.zig");
    const input =
        \\[a.b.c]
        \\leaf = 1
        \\
    ;
    var parser = parser_mod.Parser.init(std.testing.allocator, input, .{});
    var doc = try parser.parse();
    defer doc.deinit();

    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();

    try encode(&doc, &aw.writer, .{});
    const expected = "[a.b.c]\nleaf = 1\n";
    try std.testing.expectEqualStrings(expected, aw.written());
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `zig build test 2>&1 | grep -A3 "encode single-level header\|encode nested header"`
Expected: FAIL — right now tables inside the root hit `writeAnyValue`'s `error.InlineTableNotYetSupported`.

- [ ] **Step 3: Rework the root walker into a two-pass visitor**

Replace `writeRootTable` and `writeSortedEntries` with a new structure that emits primitive key-values first, then headered subtables. Add path tracking so nested tables produce `[a.b.c]` headers.

```zig
fn writeRootTable(root: *const Value, writer: anytype, options: EncodeOptions) !void {
    std.debug.assert(root.* == .table);

    // Allocate a small ArrayList to track the dotted header path as we recurse.
    var path: std.ArrayList([]const u8) = .empty;
    defer path.deinit(std.heap.smp_allocator);

    try writeTableBody(root, writer, options, &path, true);
}

/// Write the body of a non-inline table.
/// is_root==true suppresses the [header] line for the top-level call.
fn writeTableBody(
    table: *const Value,
    writer: anytype,
    options: EncodeOptions,
    path: *std.ArrayList([]const u8),
    is_root: bool,
) !void {
    std.debug.assert(table.* == .table);

    const entries = try sortedCopy(table.table.entries, options);
    defer freeIfHeap(entries, table.table.entries.len);

    // Pass 1: primitives (including inline arrays and inline tables).
    for (entries.slice) |entry| {
        if (!isHeaderChild(entry.value)) {
            try writeBareKeyValue(entry, writer, options);
        }
    }

    // Pass 2: header children — subtables and arrays-of-tables.
    for (entries.slice) |entry| {
        if (!isHeaderChild(entry.value)) continue;
        try writeHeaderChild(entry, writer, options, path, is_root);
    }
}

/// True if this value should be emitted as a [header] or [[header]] section
/// rather than an inline assignment on the parent line.
fn isHeaderChild(v: *const Value) bool {
    switch (v.*) {
        .table => |t| {
            // Inline tables stay inline.
            if (t.is_inline) return false;
            return true;
        },
        .array => |a| {
            // Array-of-tables uses [[header]]; inline arrays don't.
            if (a.is_static) return false;
            // Non-static arrays in the value tree are array-of-tables.
            return true;
        },
        else => return false,
    }
}

fn writeHeaderChild(
    entry: TableEntry,
    writer: anytype,
    options: EncodeOptions,
    path: *std.ArrayList([]const u8),
    parent_was_root: bool,
) !void {
    try path.append(std.heap.smp_allocator, entry.key);
    defer _ = path.pop();

    switch (entry.value.*) {
        .table => {
            try writer.writeByte('\n');
            try writer.writeByte('[');
            try writeHeaderPath(path.items, writer);
            try writer.writeAll("]\n");
            try writeTableBody(entry.value, writer, options, path, false);
        },
        .array => |a| {
            for (a.items) |item| {
                std.debug.assert(item.* == .table);
                try writer.writeByte('\n');
                try writer.writeAll("[[");
                try writeHeaderPath(path.items, writer);
                try writer.writeAll("]]\n");
                try writeTableBody(item, writer, options, path, false);
            }
        },
        else => unreachable,
    }
    _ = parent_was_root;
}

fn writeHeaderPath(parts: []const []const u8, writer: anytype) !void {
    for (parts, 0..) |p, i| {
        if (i > 0) try writer.writeByte('.');
        try writeKey(p, writer);
    }
}

/// Owned slice that knows whether it was heap-allocated.
const SortedEntries = struct {
    slice: []TableEntry,
    is_heap: bool,
};

threadlocal var sort_stack_buf: [256]TableEntry = undefined;

fn sortedCopy(entries: []const TableEntry, options: EncodeOptions) !SortedEntries {
    if (!options.sort_keys) {
        return .{ .slice = @constCast(entries), .is_heap = false };
    }
    if (entries.len <= sort_stack_buf.len) {
        @memcpy(sort_stack_buf[0..entries.len], entries);
        const slice = sort_stack_buf[0..entries.len];
        std.sort.pdq(TableEntry, slice, {}, entryLessThan);
        return .{ .slice = slice, .is_heap = false };
    }
    const buf = try std.heap.smp_allocator.alloc(TableEntry, entries.len);
    @memcpy(buf, entries);
    std.sort.pdq(TableEntry, buf, {}, entryLessThan);
    return .{ .slice = buf, .is_heap = true };
}

fn freeIfHeap(sorted: SortedEntries, _: usize) void {
    if (sorted.is_heap) std.heap.smp_allocator.free(sorted.slice);
}
```

Note: the old `writeSortedEntries` function is now replaced — delete it. Remove the unused parameter on `writeBareKeyValue` if the compiler complains.

Also: `writeAnyValue` still has a branch for `.table => return error.InlineTableNotYetSupported` — leave that for Task 9 to fix when we add inline tables as leaves.

- [ ] **Step 4: Run the test to verify it passes**

Run: `zig build test 2>&1 | grep -E "(encode single-level header|encode nested header|FAIL|error)"`
Expected: both table tests PASS and all earlier tests still PASS.

- [ ] **Step 5: Commit**

```bash
git add src/encoder.zig
git commit -m "feat(encoder): emit [header] sections and nested subtables

Walks the document in two passes per table: primitives first, then
header children. Path tracking produces dotted headers for nested
tables. Array-of-tables uses [[header]] syntax."
```

---

### Task 9: Encode inline tables (leaf values only)

**Files:**

- Modify: `/home/benji/src/devnw/zig/toml/src/encoder.zig`

- [ ] **Step 1: Write the failing test**

Append to `src/encoder.zig`:

```zig
test "encode inline table" {
    const parser_mod = @import("parser.zig");
    const input = "point = { x = 1, y = 2 }\n";
    var parser = parser_mod.Parser.init(std.testing.allocator, input, .{});
    var doc = try parser.parse();
    defer doc.deinit();

    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();

    try encode(&doc, &aw.writer, .{});
    try std.testing.expectEqualStrings("point = { x = 1, y = 2 }\n", aw.written());
}

test "encode inline table empty" {
    const parser_mod = @import("parser.zig");
    const input = "empty = {}\n";
    var parser = parser_mod.Parser.init(std.testing.allocator, input, .{});
    var doc = try parser.parse();
    defer doc.deinit();

    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();

    try encode(&doc, &aw.writer, .{});
    try std.testing.expectEqualStrings("empty = {}\n", aw.written());
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `zig build test 2>&1 | grep -A3 "encode inline table"`
Expected: FAIL with `error.InlineTableNotYetSupported`.

- [ ] **Step 3: Implement inline tables**

Replace the `.table` arm of `writeAnyValue` with a real implementation:

```zig
fn writeAnyValue(v: *const Value, writer: anytype, options: EncodeOptions) !void {
    switch (v.*) {
        .array => try writeInlineArray(v, writer, options),
        .table => try writeInlineTable(v, writer, options),
        else => try writeLeafValue(v, writer),
    }
}

fn writeInlineTable(v: *const Value, writer: anytype, options: EncodeOptions) !void {
    std.debug.assert(v.* == .table);
    const entries = try sortedCopy(v.table.entries, options);
    defer freeIfHeap(entries, v.table.entries.len);

    if (entries.slice.len == 0) {
        try writer.writeAll("{}");
        return;
    }
    try writer.writeAll("{ ");
    for (entries.slice, 0..) |entry, i| {
        if (i > 0) try writer.writeAll(", ");
        try writeKey(entry.key, writer);
        try writer.writeAll(" = ");
        try writeAnyValue(entry.value, writer, options);
    }
    try writer.writeAll(" }");
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `zig build test 2>&1 | grep -E "(encode inline table|FAIL|error)"`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/encoder.zig
git commit -m "feat(encoder): emit inline tables with sorted keys

Inline tables (Value.Table.is_inline == true) are emitted as
{ k = v, k = v }. Empty inline tables are {}."
```

---

### Task 10: Encode array-of-tables with static (inline) form

**Files:**

- Modify: `/home/benji/src/devnw/zig/toml/src/encoder.zig`

- [ ] **Step 1: Write the failing test**

Append to `src/encoder.zig`:

```zig
test "encode array-of-tables as [[header]]" {
    const parser_mod = @import("parser.zig");
    const input =
        \\[[products]]
        \\name = "Hammer"
        \\
        \\[[products]]
        \\name = "Nail"
        \\
    ;
    var parser = parser_mod.Parser.init(std.testing.allocator, input, .{});
    var doc = try parser.parse();
    defer doc.deinit();

    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();

    try encode(&doc, &aw.writer, .{});
    const expected =
        "\n" ++
        "[[products]]\n" ++
        "name = \"Hammer\"\n" ++
        "\n" ++
        "[[products]]\n" ++
        "name = \"Nail\"\n";
    try std.testing.expectEqualStrings(expected, aw.written());
}

test "encode static array of inline tables" {
    const parser_mod = @import("parser.zig");
    const input = "points = [{ x = 1 }, { x = 2 }]\n";
    var parser = parser_mod.Parser.init(std.testing.allocator, input, .{});
    var doc = try parser.parse();
    defer doc.deinit();

    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();

    try encode(&doc, &aw.writer, .{});
    try std.testing.expectEqualStrings("points = [{ x = 1 }, { x = 2 }]\n", aw.written());
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `zig build test 2>&1 | grep -A3 "array-of-tables\|static array of inline"`
Expected: the `[[header]]` test may already pass from Task 8 (nested header emission handled it). The static-array case should fail or produce wrong output because `writeInlineArray` would call `writeAnyValue` which dispatches tables through `writeInlineTable` — that is actually correct. Run the test first; if both pass immediately, skip straight to Step 4. If one fails, read the diagnostic and adjust.

- [ ] **Step 3: Adjust encoder if necessary**

If the `[[products]]` test emits a leading `\n` you did not expect, check the first-child logic in `writeHeaderChild`. The expected output begins with `\n` because the header child prints a blank line separator before `[[products]]`. That is intentional and tested for. If your test fails on the blank line, do not remove it from the encoder — update nothing; it is the test that is correct per this plan.

If the `is_static` array test fails because `writeInlineArray` did not handle table elements, extend it:

```zig
fn writeInlineArray(arr: *const Value, writer: anytype, options: EncodeOptions) !void {
    std.debug.assert(arr.* == .array);
    const items = arr.array.items;
    try writer.writeByte('[');
    for (items, 0..) |item, i| {
        if (i > 0) try writer.writeAll(", ");
        try writeAnyValue(item, writer, options);
    }
    try writer.writeByte(']');
}
```

If the function is already this shape (it should be, from Task 7), no change is needed.

- [ ] **Step 4: Run the tests**

Run: `zig build test 2>&1 | grep -E "(array-of-tables|static array of inline|FAIL|error)"`
Expected: PASS both.

- [ ] **Step 5: Commit**

```bash
git add src/encoder.zig
git commit -m "feat(encoder): verify array-of-tables and static table arrays

Adds explicit test coverage for [[header]] emission and for inline
table arrays written on a single line. Encoder handles both shapes
through the existing dispatch."
```

---

### Task 11: Encode non-bare keys as quoted basic strings

**Files:**

- Modify: `/home/benji/src/devnw/zig/toml/src/encoder.zig`

- [ ] **Step 1: Write the failing test**

Append to `src/encoder.zig`:

```zig
test "encode quotes non-bare keys" {
    const parser_mod = @import("parser.zig");
    const input =
        \\"key with spaces" = 1
        \\"unicode Ж" = 2
        \\"" = 3
        \\
    ;
    var parser = parser_mod.Parser.init(std.testing.allocator, input, .{});
    var doc = try parser.parse();
    defer doc.deinit();

    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();

    try encode(&doc, &aw.writer, .{});
    // Sorted: "", "key with spaces", "unicode Ж"
    const expected =
        "\"\" = 3\n" ++
        "\"key with spaces\" = 1\n" ++
        "\"unicode Ж\" = 2\n";
    try std.testing.expectEqualStrings(expected, aw.written());
}
```

- [ ] **Step 2: Run the test to verify it passes**

Because `writeKey` already falls back to `writeBasicString` for non-bare keys (Task 2), this test should pass immediately. Run:

```bash
zig build test 2>&1 | grep -E "(encode quotes non-bare|FAIL|error)"
```

Expected: PASS.

- [ ] **Step 3: If the test fails, fix `isBareKey`**

The only likely failure mode: `isBareKey` rejecting a valid bare char or accepting a non-ASCII byte. Inspect the implementation from Task 2 — it should accept exactly `[A-Za-z0-9_-]+` and reject everything else (including multi-byte UTF-8 sequences, which fall through the `c < 0x20` branch). If a fix is needed, make it minimal.

- [ ] **Step 4: Commit**

```bash
git add src/encoder.zig
git commit -m "test(encoder): cover non-bare key quoting

Keys with spaces, non-ASCII bytes, and the empty key all go through
writeBasicString. Adds the regression test so refactors to isBareKey
keep this contract."
```

---

### Task 12: Add a round-trip integration test file

**Files:**

- Create: `/home/benji/src/devnw/zig/toml/tests/encoder_roundtrip.zig`
- Modify: `/home/benji/src/devnw/zig/toml/build.zig`

- [ ] **Step 1: Create the test file**

Create `/home/benji/src/devnw/zig/toml/tests/encoder_roundtrip.zig`:

```zig
// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! Round-trip tests: parse(encode(parse(x))) must yield the same value tree
//! as parse(x). Asserted by re-emitting the tagged JSON and comparing bytes.

const std = @import("std");
const toml = @import("toml");

const corpus = [_][]const u8{
    "a = 42\n",
    "pi = 3.14\n",
    "flag = true\n",
    "s = \"hello\"\n",
    "nums = [1, 2, 3]\n",
    "point = { x = 1, y = 2 }\n",
    "[server]\nhost = \"localhost\"\nport = 8080\n",
    "[a.b.c]\nleaf = 1\n",
    "[[products]]\nname = \"Hammer\"\n\n[[products]]\nname = \"Nail\"\n",
    "dt = 2024-01-15T10:30:00Z\n",
    "dt_local = 2024-01-15T10:30:00\n",
    "d = 2024-01-15\n",
    "t = 10:30:00\n",
    "special_pos = inf\nspecial_neg = -inf\nspecial_nan = nan\n",
    "empty_arr = []\n",
    "empty_table = {}\n",
    "mixed = [1, \"two\", 3.0, true]\n",
    "\"weird key\" = 1\n",
    "nested = { inner = { leaf = 1 } }\n",
};

fn roundTrip(alloc: std.mem.Allocator, src: []const u8) !void {
    var doc1 = try toml.parse(alloc, src, .{});
    defer doc1.deinit();

    var encoded: std.Io.Writer.Allocating = .init(alloc);
    defer encoded.deinit();
    try toml.encoder.encode(&doc1, &encoded.writer, .{});

    var doc2 = toml.parse(alloc, encoded.written(), .{}) catch |e| {
        std.debug.print("re-parse failed for:\n---\n{s}\n---\nencoded:\n---\n{s}\n---\n", .{ src, encoded.written() });
        return e;
    };
    defer doc2.deinit();

    // Compare tagged-JSON projections: if those agree, the value trees agree.
    var json1: std.Io.Writer.Allocating = .init(alloc);
    defer json1.deinit();
    try toml.writeTaggedJson(&doc1, &json1.writer);

    var json2: std.Io.Writer.Allocating = .init(alloc);
    defer json2.deinit();
    try toml.writeTaggedJson(&doc2, &json2.writer);

    std.testing.expectEqualStrings(json1.written(), json2.written()) catch |e| {
        std.debug.print("round-trip mismatch for:\n---\n{s}\n---\nencoded:\n---\n{s}\n---\n", .{ src, encoded.written() });
        return e;
    };
}

test "round-trip corpus" {
    for (corpus) |src| {
        try roundTrip(std.testing.allocator, src);
    }
}
```

- [ ] **Step 2: Wire the test file into `build.zig`**

Open `/home/benji/src/devnw/zig/toml/build.zig`. After the `accept_tests` block (around line 81), add:

```zig
    // Encoder round-trip tests
    const encoder_roundtrip_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/encoder_roundtrip.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "toml", .module = toml_mod },
            },
        }),
    });
    const run_encoder_roundtrip_tests = b.addRunArtifact(encoder_roundtrip_tests);
```

In the `test_step` block a few lines down, add:

```zig
    test_step.dependOn(&run_encoder_roundtrip_tests.step);
```

- [ ] **Step 3: Run the tests**

Run: `zig build test 2>&1 | tail -40`
Expected: PASS. If any corpus entry fails, read the diagnostic printed by `std.debug.print` in `roundTrip`, find the offending case, fix the encoder to handle it.

- [ ] **Step 4: Commit**

```bash
git add tests/encoder_roundtrip.zig build.zig
git commit -m "test(encoder): add round-trip corpus

parse(encode(parse(x))) must yield the same tagged-JSON projection as
parse(x) for 19 corpus cases covering every value kind and table shape.
Wired into zig build test."
```

---

### Task 13: Export the encoder from the public API

**Files:**

- Modify: `/home/benji/src/devnw/zig/toml/src/toml.zig`

- [ ] **Step 1: Write the failing test**

Append to `src/toml.zig` (after the last existing test):

```zig
test "public encode API emits TOML" {
    const input = "a = 42\n";
    var doc = try parse(std.testing.allocator, input, .{});
    defer doc.deinit();

    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();

    try encode(&doc, &aw.writer, .{});
    try std.testing.expectEqualStrings("a = 42\n", aw.written());
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `zig build test 2>&1 | grep -A3 "public encode API"`
Expected: FAIL with "use of undeclared identifier 'encode'".

- [ ] **Step 3: Add the public wrapper**

In `src/toml.zig`, after the `writeTaggedJson` function (around line 79), add:

```zig
pub const EncodeOptions = encoder.EncodeOptions;

/// Encode a Document as TOML text.
/// The output is deterministic: keys are sorted lexicographically by default.
pub fn encode(doc: *const Document, writer: anytype, options: EncodeOptions) !void {
    try encoder.encode(doc, writer, options);
}
```

The `encoder` re-export was already added in Task 1 Step 2.

- [ ] **Step 4: Run the test to verify it passes**

Run: `zig build test 2>&1 | grep -E "(public encode API|FAIL|error)"`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/toml.zig
git commit -m "feat(toml): expose encode() on the public API

Adds toml.encode(doc, writer, options) mirroring toml.writeTaggedJson.
Re-exports EncodeOptions so consumers can tune output formatting."
```

---

### Task 14: Verify pretty-print determinism under sort_keys=true

**Files:**

- Create: `/home/benji/src/devnw/zig/toml/tests/encoder_golden.zig`
- Modify: `/home/benji/src/devnw/zig/toml/build.zig`

- [ ] **Step 1: Create the golden test file**

Create `/home/benji/src/devnw/zig/toml/tests/encoder_golden.zig`:

```zig
// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! Golden-file tests for encoder output. These assert the exact bytes
//! emitted, providing a contract against accidental format changes.

const std = @import("std");
const toml = @import("toml");

fn encodeString(alloc: std.mem.Allocator, src: []const u8, opts: toml.EncodeOptions) ![]u8 {
    var doc = try toml.parse(alloc, src, .{});
    defer doc.deinit();
    var aw: std.Io.Writer.Allocating = .init(alloc);
    errdefer aw.deinit();
    try toml.encode(&doc, &aw.writer, opts);
    return aw.toOwnedSlice();
}

test "sort_keys=true produces identical output for reordered input" {
    const a = "b = 1\na = 2\n";
    const b = "a = 2\nb = 1\n";

    const out_a = try encodeString(std.testing.allocator, a, .{ .sort_keys = true });
    defer std.testing.allocator.free(out_a);
    const out_b = try encodeString(std.testing.allocator, b, .{ .sort_keys = true });
    defer std.testing.allocator.free(out_b);

    try std.testing.expectEqualStrings(out_a, out_b);
    try std.testing.expectEqualStrings("a = 2\nb = 1\n", out_a);
}

test "sort_keys=false preserves input order" {
    const src = "b = 1\na = 2\n";
    const out = try encodeString(std.testing.allocator, src, .{ .sort_keys = false });
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("b = 1\na = 2\n", out);
}

test "sort_keys=true applies inside inline tables" {
    const src = "p = { y = 2, x = 1 }\n";
    const out = try encodeString(std.testing.allocator, src, .{ .sort_keys = true });
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("p = { x = 1, y = 2 }\n", out);
}

test "sort_keys=true applies inside header tables" {
    const src = "[s]\nz = 1\na = 2\n";
    const out = try encodeString(std.testing.allocator, src, .{ .sort_keys = true });
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("[s]\na = 2\nz = 1\n", out);
}
```

- [ ] **Step 2: Wire into `build.zig`**

Add after the `encoder_roundtrip_tests` block from Task 12:

```zig
    // Encoder golden-output tests
    const encoder_golden_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/encoder_golden.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "toml", .module = toml_mod },
            },
        }),
    });
    const run_encoder_golden_tests = b.addRunArtifact(encoder_golden_tests);
```

And add to `test_step`:

```zig
    test_step.dependOn(&run_encoder_golden_tests.step);
```

- [ ] **Step 3: Run the tests**

Run: `zig build test 2>&1 | tail -30`
Expected: all tests PASS. The `sort_keys=false` test exercises the `!options.sort_keys` branch in `sortedCopy` (Task 8), which returns the original slice without sorting.

- [ ] **Step 4: Commit**

```bash
git add tests/encoder_golden.zig build.zig
git commit -m "test(encoder): golden-output tests for sort_keys determinism

Verifies that sort_keys=true makes output independent of input order at
every level (root, inline tables, header tables). sort_keys=false
preserves source order for debugging and 1:1 reproduction."
```

---

### Task 15: Implement wrapped inline arrays via indent+threshold

**Files:**

- Modify: `/home/benji/src/devnw/zig/toml/src/encoder.zig`
- Modify: `/home/benji/src/devnw/zig/toml/tests/encoder_golden.zig`

- [ ] **Step 1: Write the failing test**

Append to `tests/encoder_golden.zig`:

```zig
test "inline array wraps when length > inline_threshold" {
    const src = "nums = [1, 2, 3, 4, 5]\n";
    const out = try encodeString(std.testing.allocator, src, .{
        .sort_keys = true,
        .indent = 2,
        .inline_threshold = 3,
    });
    defer std.testing.allocator.free(out);

    const expected =
        "nums = [\n" ++
        "  1,\n" ++
        "  2,\n" ++
        "  3,\n" ++
        "  4,\n" ++
        "  5,\n" ++
        "]\n";
    try std.testing.expectEqualStrings(expected, out);
}

test "inline array stays on one line when <= threshold" {
    const src = "nums = [1, 2, 3]\n";
    const out = try encodeString(std.testing.allocator, src, .{
        .sort_keys = true,
        .indent = 2,
        .inline_threshold = 3,
    });
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("nums = [1, 2, 3]\n", out);
}

test "indent=0 disables wrapping regardless of size" {
    const src = "nums = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]\n";
    const out = try encodeString(std.testing.allocator, src, .{
        .sort_keys = true,
        .indent = 0,
        .inline_threshold = 2,
    });
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings(
        "nums = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]\n",
        out,
    );
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `zig build test 2>&1 | grep -A3 "inline array wraps\|indent=0 disables"`
Expected: the "wraps" test FAILS (encoder currently always emits single-line); the "stays on one line" test should PASS (already covered by existing behavior); the "indent=0 disables" test should PASS.

- [ ] **Step 3: Teach `writeInlineArray` to wrap**

Replace `writeInlineArray` in `src/encoder.zig`:

```zig
fn writeInlineArray(arr: *const Value, writer: anytype, options: EncodeOptions) !void {
    std.debug.assert(arr.* == .array);
    const items = arr.array.items;

    const should_wrap = options.indent > 0 and items.len > options.inline_threshold;

    if (!should_wrap) {
        try writer.writeByte('[');
        for (items, 0..) |item, i| {
            if (i > 0) try writer.writeAll(", ");
            try writeAnyValue(item, writer, options);
        }
        try writer.writeByte(']');
        return;
    }

    try writer.writeAll("[\n");
    for (items) |item| {
        var n: u8 = 0;
        while (n < options.indent) : (n += 1) try writer.writeByte(' ');
        try writeAnyValue(item, writer, options);
        try writer.writeAll(",\n");
    }
    try writer.writeByte(']');
}
```

- [ ] **Step 4: Run the tests**

Run: `zig build test 2>&1 | grep -E "(inline array wraps|stays on one line|indent=0|FAIL|error)"`
Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add src/encoder.zig tests/encoder_golden.zig
git commit -m "feat(encoder): wrap inline arrays larger than inline_threshold

When indent > 0 and array.len > inline_threshold, emit one element per
line with the configured indent. indent=0 is the default and keeps
everything on one line."
```

---

### Task 16: Finalize GAP-0006 and GAP-0008

- [ ] **Step 1: Run the full test suite**

Run: `zig build test 2>&1 | tail -40`
Expected: all tests PASS.

- [ ] **Step 2: Commit a closure marker**

```bash
git commit --allow-empty -m "feat(encoder): close GAP-0006 and GAP-0008

GAP-0006 (TOML encoder module): src/encoder.zig implements encode()
with full coverage of strings, ints, floats, bools, datetimes,
arrays, inline tables, header tables, and arrays-of-tables.

GAP-0008 (pretty-print / stable-sort): EncodeOptions exposes
sort_keys (default true), indent (default 0), and inline_threshold
(default 8). Golden tests assert deterministic output."
```

---

### Task 17: Scaffold the toml-test-encoder CLI binary

**Files:**

- Create: `/home/benji/src/devnw/zig/toml/src/bin/toml_test_encoder.zig`
- Modify: `/home/benji/src/devnw/zig/toml/build.zig`

- [ ] **Step 1: Create the CLI with a no-op main**

Create `/home/benji/src/devnw/zig/toml/src/bin/toml_test_encoder.zig`:

```zig
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

pub fn main(init: std.process.Init) !void {
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

    _ = stdout_writer; // wired in later tasks
    _ = stderr_writer;
    _ = toml;
    _ = input;

    stdout_writer.interface.flush() catch {};
}
```

The `_ = ...` discards silence compiler warnings until Tasks 18-20 wire each piece.

- [ ] **Step 2: Register the executable in `build.zig`**

In `/home/benji/src/devnw/zig/toml/build.zig`, after the `toml-test-decoder` executable block (around line 56), add:

```zig
    // CLI binary: toml-test-encoder
    const enc_exe = b.addExecutable(.{
        .name = "toml-test-encoder",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/bin/toml_test_encoder.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "toml", .module = toml_mod },
            },
        }),
    });
    b.installArtifact(enc_exe);
```

- [ ] **Step 3: Verify the binary builds**

Run: `zig build 2>&1 | tail -20`
Expected: no errors. `zig-out/bin/toml-test-encoder` exists.

Run: `ls zig-out/bin/`
Expected: both `toml-test-decoder` and `toml-test-encoder` listed.

- [ ] **Step 4: Commit**

```bash
git add src/bin/toml_test_encoder.zig build.zig
git commit -m "feat(cli): scaffold toml-test-encoder binary

Mirrors toml-test-decoder's allocator selection and buffered I/O
setup. main() currently drains stdin without doing work; JSON decode
and TOML emit land in follow-up tasks."
```

---

### Task 18: Implement the JSON-tagged-tree to Value converter

**Files:**

- Modify: `/home/benji/src/devnw/zig/toml/src/bin/toml_test_encoder.zig`

This task builds the inverse of `src/json_tagged.zig`'s emitter: given a `std.json.Value`, produce a `Value` allocated in an arena. It is tested via a unit test in the CLI file.

- [ ] **Step 1: Write the failing test**

Append to `src/bin/toml_test_encoder.zig`:

```zig
test "json tree to Value: integer" {
    const arena_alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(arena_alloc);
    defer arena.deinit();
    const a = arena.allocator();

    const json_src = "{\"type\":\"integer\",\"value\":\"42\"}";
    const parsed = try std.json.parseFromSlice(std.json.Value, arena_alloc, json_src, .{});
    defer parsed.deinit();

    const v = try jsonToValue(a, parsed.value);
    try std.testing.expectEqual(@as(i64, 42), v.integer);
}

test "json tree to Value: table of primitives" {
    const arena_alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(arena_alloc);
    defer arena.deinit();
    const a = arena.allocator();

    const json_src = "{\"a\":{\"type\":\"integer\",\"value\":\"1\"},\"b\":{\"type\":\"bool\",\"value\":\"true\"}}";
    const parsed = try std.json.parseFromSlice(std.json.Value, arena_alloc, json_src, .{});
    defer parsed.deinit();

    const v = try jsonToValue(a, parsed.value);
    try std.testing.expect(v.* == .table);
    try std.testing.expectEqual(@as(i64, 1), v.get("a").?.integer);
    try std.testing.expectEqual(true, v.get("b").?.bool);
}

test "json tree to Value: array of integers" {
    const arena_alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(arena_alloc);
    defer arena.deinit();
    const a = arena.allocator();

    const json_src = "[{\"type\":\"integer\",\"value\":\"1\"},{\"type\":\"integer\",\"value\":\"2\"}]";
    const parsed = try std.json.parseFromSlice(std.json.Value, arena_alloc, json_src, .{});
    defer parsed.deinit();

    const v = try jsonToValue(a, parsed.value);
    try std.testing.expect(v.* == .array);
    try std.testing.expectEqual(@as(usize, 2), v.array.items.len);
    try std.testing.expectEqual(@as(i64, 1), v.array.items[0].integer);
    try std.testing.expectEqual(@as(i64, 2), v.array.items[1].integer);
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `zig build test 2>&1 | grep -A3 "jsonToValue\|json tree to Value"`
Expected: FAIL with "undeclared identifier 'jsonToValue'".

Note: `zig build test` may not pick up the CLI file automatically. Check `build.zig` — if no test step references `src/bin/toml_test_encoder.zig`, add one:

```zig
    const encoder_cli_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/bin/toml_test_encoder.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "toml", .module = toml_mod },
            },
        }),
    });
    const run_encoder_cli_tests = b.addRunArtifact(encoder_cli_tests);
    test_step.dependOn(&run_encoder_cli_tests.step);
```

Add this next to the other test blocks in `build.zig`.

- [ ] **Step 3: Implement `jsonToValue`**

In `src/bin/toml_test_encoder.zig`, add (above the tests, inside the file but outside `main`):

```zig
const Value = toml.value_mod.Value;
const DateTime = toml.DateTime;
const DateTimeLocal = toml.DateTimeLocal;
const DateLocal = toml.DateLocal;
const TimeLocal = toml.TimeLocal;
const TableEntry = toml.value_mod.TableEntry;

/// Convert a toml-test tagged-JSON tree into a Value owned by `alloc`.
///
/// Tagged leaves look like: {"type": "<tag>", "value": "<literal>"}.
/// Objects lacking the "type"/"value" shape are TOML tables.
/// JSON arrays map to TOML arrays.
pub fn jsonToValue(alloc: std.mem.Allocator, node: std.json.Value) !*Value {
    switch (node) {
        .object => |obj| {
            // Detect the tagged-leaf shape.
            if (obj.count() == 2) {
                const type_entry = obj.get("type");
                const value_entry = obj.get("value");
                if (type_entry != null and value_entry != null and type_entry.? == .string and value_entry.? == .string) {
                    return decodeTaggedLeaf(alloc, type_entry.?.string, value_entry.?.string);
                }
            }
            // It's a table.
            return decodeTable(alloc, obj);
        },
        .array => |arr| {
            return decodeArray(alloc, arr);
        },
        else => return error.InvalidTaggedJson,
    }
}

fn decodeTable(alloc: std.mem.Allocator, obj: std.json.ObjectMap) !*Value {
    const v = try alloc.create(Value);
    const entries = try alloc.alloc(TableEntry, obj.count());
    var it = obj.iterator();
    var i: usize = 0;
    while (it.next()) |kv| : (i += 1) {
        const child = try jsonToValue(alloc, kv.value_ptr.*);
        const key_copy = try alloc.dupe(u8, kv.key_ptr.*);
        entries[i] = .{ .key = key_copy, .value = child };
    }
    v.* = .{ .table = .{ .entries = entries } };
    return v;
}

fn decodeArray(alloc: std.mem.Allocator, arr: std.json.Array) !*Value {
    const v = try alloc.create(Value);
    const items = try alloc.alloc(*Value, arr.items.len);
    for (arr.items, 0..) |item, i| {
        items[i] = try jsonToValue(alloc, item);
    }
    // Static=true so the encoder emits this as an inline array (correct for
    // the toml-test pipeline — arrays of tables always land as [[header]]
    // from the parser side, not from a JSON-authored corpus).
    v.* = .{ .array = .{ .items = items, .is_static = true } };
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
    if (std.mem.eql(u8, s, "nan") or std.mem.eql(u8, s, "+nan") or std.mem.eql(u8, s, "-nan")) {
        return std.math.nan(f64);
    }
    if (std.mem.eql(u8, s, "inf") or std.mem.eql(u8, s, "+inf")) return std.math.inf(f64);
    if (std.mem.eql(u8, s, "-inf")) return -std.math.inf(f64);
    return try std.fmt.parseFloat(f64, s);
}

fn parseDateTime(s: []const u8) !DateTime {
    // Re-parse via the real TOML parser: wrap as "x = <literal>" and read back.
    var buf: [128]u8 = undefined;
    const wrapped = try std.fmt.bufPrint(&buf, "x = {s}\n", .{s});
    var doc = try toml.parse(std.heap.smp_allocator, wrapped, .{});
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
    var doc = try toml.parse(std.heap.smp_allocator, wrapped, .{});
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
    var doc = try toml.parse(std.heap.smp_allocator, wrapped, .{});
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
    var doc = try toml.parse(std.heap.smp_allocator, wrapped, .{});
    defer doc.deinit();
    const v = doc.root.get("x") orelse return error.InvalidDateTime;
    return switch (v.*) {
        .time_local => |t| t,
        else => error.InvalidDateTime,
    };
}
```

- [ ] **Step 4: Run the tests**

Run: `zig build test 2>&1 | grep -E "(json tree to Value|FAIL|error)"`
Expected: all three PASS.

- [ ] **Step 5: Commit**

```bash
git add src/bin/toml_test_encoder.zig build.zig
git commit -m "feat(cli): add tagged-JSON to Value converter

jsonToValue() is the inverse of src/json_tagged.zig: it walks a
std.json.Value tree, detects {type,value} leaves, and reconstructs a
Value graph in a caller-owned arena. Datetime literals are parsed by
wrapping in 'x = <lit>' and re-parsing via toml.parse so we inherit
the real lexer's validation rules."
```

---

### Task 19: Wire the CLI's main() to drive the full pipeline

**Files:**

- Modify: `/home/benji/src/devnw/zig/toml/src/bin/toml_test_encoder.zig`

- [ ] **Step 1: Write the failing test**

Append to `src/bin/toml_test_encoder.zig` a test that exercises the end-to-end path without spawning a subprocess — we drive the same helper that `main` will use:

```zig
test "encode pipeline: tagged JSON to TOML" {
    const alloc = std.testing.allocator;

    const json_src = "{\"a\":{\"type\":\"integer\",\"value\":\"42\"}}\n";
    var out = std.Io.Writer.Allocating.init(alloc);
    defer out.deinit();

    try runEncodePipeline(alloc, json_src, &out.writer);
    // Expected TOML for a single integer key=value.
    try std.testing.expectEqualStrings("a = 42\n", out.written());
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `zig build test 2>&1 | grep -A3 "encode pipeline"`
Expected: FAIL with "undeclared identifier 'runEncodePipeline'".

- [ ] **Step 3: Implement `runEncodePipeline` and call it from `main`**

Add to `src/bin/toml_test_encoder.zig` (above `main`):

```zig
/// Parse tagged-JSON `input`, reconstruct a Document, encode as TOML to `writer`.
pub fn runEncodePipeline(alloc: std.mem.Allocator, input: []const u8, writer: anytype) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, input, .{});
    defer parsed.deinit();

    // Document owns its arena and is deinitialised via doc.deinit().
    var doc = toml.Document{
        .root = undefined,
        .arena = std.heap.ArenaAllocator.init(alloc),
    };
    defer doc.deinit();

    doc.root = try jsonToValue(doc.arena.allocator(), parsed.value);
    if (doc.root.* != .table) return error.ExpectedRootTable;

    try toml.encode(&doc, writer, .{});
}
```

Now update `main` to call it:

```zig
pub fn main(init: std.process.Init) !void {
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

    const input = stdin_reader.interface.allocRemaining(allocator, .limited(16 * 1024 * 1024)) catch |e| {
        stderr_writer.interface.print("error: failed to read stdin: {}\n", .{e}) catch {};
        stderr_writer.interface.flush() catch {};
        std.process.exit(1);
    };
    defer allocator.free(input);

    runEncodePipeline(allocator, input, &stdout_writer.interface) catch |e| {
        stderr_writer.interface.print("error: encode failed: {}\n", .{e}) catch {};
        stderr_writer.interface.flush() catch {};
        std.process.exit(1);
    };
    stdout_writer.interface.flush() catch {};
}
```

Remove the `_ = ...` discards added in Task 17.

- [ ] **Step 4: Run the tests**

Run: `zig build test 2>&1 | grep -E "(encode pipeline|FAIL|error)"`
Expected: PASS.

Run the binary end-to-end:

```bash
zig build && echo '{"a":{"type":"integer","value":"42"}}' | ./zig-out/bin/toml-test-encoder
```

Expected stdout: `a = 42`.

- [ ] **Step 5: Commit**

```bash
git add src/bin/toml_test_encoder.zig
git commit -m "feat(cli): wire runEncodePipeline into toml-test-encoder main

Reads stdin, parses tagged JSON via std.json, reconstructs a Document
with arena ownership, and emits TOML to stdout. Errors print a
one-line diagnostic to stderr and exit 1, matching toml-test-decoder
conventions."
```

---

### Task 20: Add end-to-end CLI tests covering more leaf types

**Files:**

- Modify: `/home/benji/src/devnw/zig/toml/src/bin/toml_test_encoder.zig`

- [ ] **Step 1: Write more pipeline tests**

Append to `src/bin/toml_test_encoder.zig`:

```zig
test "encode pipeline: string, float, bool" {
    const alloc = std.testing.allocator;
    const json_src =
        "{\"s\":{\"type\":\"string\",\"value\":\"hi\"}," ++
        "\"f\":{\"type\":\"float\",\"value\":\"3.14\"}," ++
        "\"b\":{\"type\":\"bool\",\"value\":\"true\"}}";
    var out = std.Io.Writer.Allocating.init(alloc);
    defer out.deinit();
    try runEncodePipeline(alloc, json_src, &out.writer);
    // Sorted keys: b, f, s
    try std.testing.expectEqualStrings(
        "b = true\nf = 3.14\ns = \"hi\"\n",
        out.written(),
    );
}

test "encode pipeline: nested table" {
    const alloc = std.testing.allocator;
    const json_src =
        "{\"server\":{\"host\":{\"type\":\"string\",\"value\":\"localhost\"}," ++
        "\"port\":{\"type\":\"integer\",\"value\":\"8080\"}}}";
    var out = std.Io.Writer.Allocating.init(alloc);
    defer out.deinit();
    try runEncodePipeline(alloc, json_src, &out.writer);
    try std.testing.expectEqualStrings(
        "\n[server]\nhost = \"localhost\"\nport = 8080\n",
        out.written(),
    );
}

test "encode pipeline: array of integers" {
    const alloc = std.testing.allocator;
    const json_src =
        "{\"nums\":[{\"type\":\"integer\",\"value\":\"1\"}," ++
        "{\"type\":\"integer\",\"value\":\"2\"}," ++
        "{\"type\":\"integer\",\"value\":\"3\"}]}";
    var out = std.Io.Writer.Allocating.init(alloc);
    defer out.deinit();
    try runEncodePipeline(alloc, json_src, &out.writer);
    try std.testing.expectEqualStrings("nums = [1, 2, 3]\n", out.written());
}

test "encode pipeline: datetime" {
    const alloc = std.testing.allocator;
    const json_src =
        "{\"dt\":{\"type\":\"datetime\",\"value\":\"2024-01-15T10:30:00Z\"}}";
    var out = std.Io.Writer.Allocating.init(alloc);
    defer out.deinit();
    try runEncodePipeline(alloc, json_src, &out.writer);
    try std.testing.expectEqualStrings("dt = 2024-01-15T10:30:00Z\n", out.written());
}
```

- [ ] **Step 2: Run the tests**

Run: `zig build test 2>&1 | grep -E "(encode pipeline|FAIL|error)"`
Expected: all PASS. If any fail, the diagnostic will point at either `jsonToValue` or the encoder — fix whichever layer is wrong.

- [ ] **Step 3: Commit**

```bash
git add src/bin/toml_test_encoder.zig
git commit -m "test(cli): broaden pipeline coverage

Adds pipeline tests for strings, floats, bools, nested tables, arrays
of integers, and datetimes. Each case verifies the full JSON-stdin to
TOML-stdout path through runEncodePipeline."
```

---

### Task 21: Add an end-to-end roundtrip CLI test (decoder then encoder)

**Files:**

- Modify: `/home/benji/src/devnw/zig/toml/tests/encoder_roundtrip.zig`

- [ ] **Step 1: Write the failing test**

Append to `tests/encoder_roundtrip.zig`:

```zig
test "decoder output feeds directly into encoder" {
    // Simulates running TOML -> JSON -> TOML through the two CLIs by
    // calling the library functions in the same process.
    const cli = @import("../src/bin/toml_test_encoder.zig");

    const original_toml = "[server]\nhost = \"localhost\"\nport = 8080\n";

    // Step A: TOML -> tagged JSON
    var doc = try toml.parse(std.testing.allocator, original_toml, .{});
    defer doc.deinit();

    var tagged_json: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer tagged_json.deinit();
    try toml.writeTaggedJson(&doc, &tagged_json.writer);

    // Step B: tagged JSON -> TOML
    var reencoded: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer reencoded.deinit();
    try cli.runEncodePipeline(std.testing.allocator, tagged_json.written(), &reencoded.writer);

    // The re-encoded TOML must parse to the same value tree as the original.
    try roundTrip(std.testing.allocator, reencoded.written());

    // And its own tagged-JSON projection must equal the original's.
    var doc2 = try toml.parse(std.testing.allocator, reencoded.written(), .{});
    defer doc2.deinit();
    var tagged2: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer tagged2.deinit();
    try toml.writeTaggedJson(&doc2, &tagged2.writer);
    try std.testing.expectEqualStrings(tagged_json.written(), tagged2.written());
}
```

This imports the CLI file directly via a relative path so we can call `runEncodePipeline` from the test.

- [ ] **Step 2: Verify the imports work**

`@import("../src/bin/toml_test_encoder.zig")` needs the CLI file to expose `toml` as an imported module. In `build.zig`, when the `encoder_roundtrip_tests` is defined (Task 12), the module imports list only has `.{ .name = "toml", .module = toml_mod }`. The CLI file uses `@import("toml")` which resolves to the same module. That works.

Run: `zig build test 2>&1 | grep -A5 "decoder output feeds"`
Expected: PASS.

If the import fails because the CLI file also imports `std.process.Init` in its `main` signature (which is only valid as the process entry point), extract `runEncodePipeline`, `jsonToValue`, and all `parseFloatLiteral`/`parseDateTime*`/`parseDateLocal`/`parseTimeLocal` helpers into a new `src/encoder_cli.zig` file and make `src/bin/toml_test_encoder.zig` a thin `main()` wrapper around them.

If that extraction is needed:

1. Create `src/encoder_cli.zig` with the helpers.
2. Re-export from `src/toml.zig`: `pub const encoder_cli = @import("encoder_cli.zig");`
3. Shrink `src/bin/toml_test_encoder.zig` to just the `main` function plus `const cli = @import("toml").encoder_cli; cli.runEncodePipeline(...)`.
4. Update the test import to `const cli = toml.encoder_cli;`.

- [ ] **Step 3: Run all tests**

Run: `zig build test 2>&1 | tail -30`
Expected: all PASS.

- [ ] **Step 4: Commit**

```bash
git add tests/encoder_roundtrip.zig
# If extraction was needed:
# git add src/encoder_cli.zig src/bin/toml_test_encoder.zig src/toml.zig
git commit -m "test(cli): decoder output round-trips through encoder

Drives TOML -> tagged-JSON -> TOML in-process and asserts the two
tagged-JSON projections match byte-for-byte. This is the property
toml-test enforces between the two binaries."
```

---

### Task 22: Add toml-test conformance stage to GitLab CI

**Files:**

- Modify: `/home/benji/src/devnw/zig/toml/.gitlab-ci.yml`

- [ ] **Step 1: Inspect the existing CI file**

Run: `cat .gitlab-ci.yml | head -100`

Find the `test` stage. The new job runs after the existing test stage because it depends on the built binaries.

- [ ] **Step 2: Append the new job**

Open `.gitlab-ci.yml`. After the existing `test` job (the one that runs `zig build test`), add a new job. Place it in the `test` stage:

```yaml
toml-test-conformance:
  stage: test
  allow_failure: true
  before_script:
    - *install-zig
    - apt-get install -y golang-go git
  script:
    - zig build -Doptimize=ReleaseSafe
    - git clone --depth 1 https://github.com/toml-lang/toml-test.git /tmp/toml-test
    - cd /tmp/toml-test && go build ./cmd/toml-test && cd -
    - /tmp/toml-test/toml-test --toml 1.0.0 ./zig-out/bin/toml-test-decoder || true
    - /tmp/toml-test/toml-test --toml 1.0.0 --encoder ./zig-out/bin/toml-test-encoder || true
  artifacts:
    when: always
    paths:
      - zig-out/bin/toml-test-decoder
      - zig-out/bin/toml-test-encoder
    expire_in: 1 week
```

`allow_failure: true` is intentional for the first landing. Once we have evidence the suite runs cleanly against a pinned toml-test release, flip to `false` in a follow-up.

The `|| true` suffixes on each toml-test invocation make the lines never break the job while `allow_failure: true` is set. Keep them for now — they let CI continue so we can read the diff output in the job log.

- [ ] **Step 3: Validate the YAML syntax locally**

Run: `python3 -c "import yaml; yaml.safe_load(open('.gitlab-ci.yml'))"`
Expected: no output (success). If your environment has no PyYAML installed, substitute:

```bash
zig build -Doptimize=ReleaseSafe && ls zig-out/bin/
```

Expected: `toml-test-decoder` and `toml-test-encoder` present.

- [ ] **Step 4: Commit**

```bash
git add .gitlab-ci.yml
git commit -m "ci: add toml-test conformance stage (allow_failure)

Clones BurntSushi/toml-test at HEAD, builds the Go harness, and runs
it against both decoder and encoder binaries. Marked allow_failure
initially; first green run gates flipping to required."
```

---

### Task 23: Finalize GAP-0007

- [ ] **Step 1: Run the full test suite**

Run: `zig build test 2>&1 | tail -40`
Expected: all PASS.

- [ ] **Step 2: Build in ReleaseSafe**

Run: `zig build -Doptimize=ReleaseSafe 2>&1 | tail -10`
Expected: no errors; both binaries produced in `zig-out/bin/`.

- [ ] **Step 3: Smoke-test both binaries end to end**

```bash
echo 'a = 42' | ./zig-out/bin/toml-test-decoder
```

Expected stdout: `{"a":{"type":"integer","value":"42"}}`.

```bash
echo 'a = 42' | ./zig-out/bin/toml-test-decoder | ./zig-out/bin/toml-test-encoder
```

Expected stdout: `a = 42`.

- [ ] **Step 4: Commit closure marker**

```bash
git commit --allow-empty -m "feat(cli): close GAP-0007

toml-test-encoder binary reads tagged-JSON stdin, emits TOML stdout,
and round-trips against toml-test-decoder. Wired into build.zig and
.gitlab-ci.yml (allow_failure:true until suite is confirmed green)."
```

---

### Task 24: Update `docs/API.md`

**Files:**

- Modify: `/home/benji/src/devnw/zig/toml/docs/API.md`

- [ ] **Step 1: Add the Encoding section**

Open `docs/API.md`. After the `writeTaggedJson` documentation, add a new H2 section with headers for `encode`, `EncodeOptions`, and an "Encoder rules" summary. Structure the content like this:

```markdown
## Encoding

### encode

    pub fn encode(doc: *const Document, writer: anytype, options: EncodeOptions) !void

**Description:** Write a Document as TOML text. Output is deterministic when
`sort_keys` is true (the default): keys are byte-order sorted at every level,
and array element order is preserved from the source.

**Parameters:**

| Parameter | Type | Description |
|-----------|------|-------------|
| doc | *const Document | Document to serialize |
| writer | anytype | Any `std.Io.Writer`-shaped sink |
| options | EncodeOptions | Formatting options |

**Returns:** `void` on success.

**Errors:** Bubbles up allocator and writer errors. Will not emit a TOML
parse error because the input is an already-validated `Document`.

**Example:**

    var doc = try toml.parse(allocator, "a = 42\n", .{});
    defer doc.deinit();

    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try toml.encode(&doc, &aw.writer, .{});
    // aw.written() == "a = 42\n"

### EncodeOptions

    pub const EncodeOptions = struct {
        sort_keys: bool = true,
        indent: u8 = 0,
        inline_threshold: usize = 8,
    };

| Field | Default | Description |
|-------|---------|-------------|
| sort_keys | true | Sort table keys byte-order at every level |
| indent | 0 | Spaces of indent for wrapped inline arrays (0 disables wrapping) |
| inline_threshold | 8 | Inline arrays longer than this wrap when `indent > 0` |

## Encoder rules

- Always emits decimal integers (hex/oct/bin source forms are not preserved).
- Always emits basic double-quoted strings with JSON escapes (no literal or
  multi-line forms).
- Nested tables are emitted as `[header]` sections, never as dotted keys.
- Inline tables (`Value.Table.is_inline == true`) stay inline.
- Non-static arrays of tables (`Value.Array.is_static == false`) are emitted
  as `[[header]]` blocks.
- `inf`, `-inf`, and `nan` are emitted literally.
- Datetime values delegate to the format methods on `DateTime`,
  `DateTimeLocal`, `DateLocal`, `TimeLocal` in `src/value.zig`.
```

When copying into `docs/API.md`, use triple-backtick `zig` fences in place of the four-space indented code blocks shown above.

- [ ] **Step 2: Add the CLI section**

Near the bottom of `docs/API.md`, under a "CLI Binaries" heading (create it if absent), document both:

```markdown
## CLI Binaries

### toml-test-decoder

Reads TOML from stdin, writes toml-test compatible tagged JSON to stdout.
Exits 0 on success, 1 on parse failure (one-line diagnostic on stderr).

### toml-test-encoder

Reads toml-test compatible tagged JSON from stdin, writes TOML to stdout.
Exits 0 on success, 1 on JSON parse failure or encode failure (one-line
diagnostic on stderr). Used together with `toml-test-decoder` in the
BurntSushi/toml-test harness.
```

- [ ] **Step 3: Commit**

```bash
git add docs/API.md
git commit -m "docs(api): document encode() and toml-test-encoder CLI

Adds the Encoding section covering encode(), EncodeOptions defaults,
and the encoder's formatting rules. Documents both CLI binaries side
by side."
```

---

### Task 25: Update `docs/ARCHITECTURE.md`

**Files:**

- Modify: `/home/benji/src/devnw/zig/toml/docs/ARCHITECTURE.md`

- [ ] **Step 1: Extend the diagram**

Open `docs/ARCHITECTURE.md`. Find the box labeled `json_tagged.zig` in the ASCII diagram (around line 30). Add an `encoder.zig` sibling box beside it, fed by the same `toml.zig (Public API)` row.

Your edit should look roughly like this — adjust the existing ASCII art to match:

```text
            │                    │                   │                    │
            ▼                    ▼                   ▼                    ▼
    ┌───────────────────────────────────┐    ┌──────────────────┐   ┌──────────────────┐
    │           parser.zig              │    │ json_tagged.zig  │   │   encoder.zig    │
    │                                   │    │                  │   │                  │
    │   Parser                          │    │ Tagged JSON      │   │ TOML emitter     │
    │   - parseDocument()               │    │ emitter for      │   │ - encode()       │
    │   ...                             │    │ toml-test        │   │ - EncodeOptions  │
    └───────────────────────────────────┘    └──────────────────┘   └──────────────────┘
```

- [ ] **Step 2: Add a textual Encoder component paragraph**

Under "Component Overview" (or equivalent), add:

```markdown
### encoder.zig

Encoder component: walks a `Document` and emits TOML v1.0.0 grammar via a
caller-supplied `std.Io.Writer`. Public entry points:

- `EncodeOptions { sort_keys, indent, inline_threshold }`
- `encode(doc, writer, options) !void`

Design decisions:

- Nested tables always become `[header]` sections (never collapsed to
  dotted keys) for readable output.
- Inline-table and static-array shape is preserved from the input's
  `Value.Table.is_inline` and `Value.Array.is_static` flags.
- All integers are emitted decimal; source hex/oct/bin form is not
  preserved.
- Strings are always basic double-quoted with JSON escapes.
- Determinism: when `sort_keys` (default) is true, every table's entries
  are sorted byte-order before emission, mirroring `json_tagged.zig`.
```

- [ ] **Step 3: Commit**

```bash
git add docs/ARCHITECTURE.md
git commit -m "docs(arch): document encoder.zig component

Diagram gains an encoder box alongside json_tagged. Component notes
spell out the design decisions (headers not dotted keys, always
decimal, always basic strings, deterministic sort)."
```

---

### Task 26: Update `CHANGELOG.md`

**Files:**

- Modify: `/home/benji/src/devnw/zig/toml/CHANGELOG.md`

- [ ] **Step 1: Add Unreleased bullets**

Open `CHANGELOG.md`. Under `## [Unreleased]` / `### Added`, prepend these entries:

```markdown
- `toml.encode(doc, writer, options)`: TOML encoder covering strings,
  integers, floats (including inf/-inf/nan), booleans, datetime forms,
  inline arrays, inline tables, `[header]` sections, and `[[header]]`
  array-of-tables. Closes GAP-0006.
- `toml.EncodeOptions`: `sort_keys` (default true), `indent` (default 0),
  and `inline_threshold` (default 8) for deterministic / pretty output.
  Closes GAP-0008.
- `toml-test-encoder` CLI binary: reads toml-test tagged JSON from
  stdin, emits TOML to stdout. Pairs with `toml-test-decoder` to drive
  the BurntSushi/toml-test harness. Closes GAP-0007.
- GitLab CI job `toml-test-conformance` (marked `allow_failure: true`
  initially): builds both CLIs and runs the upstream toml-test suite
  against each direction. Partially addresses GAP-0004.
```

- [ ] **Step 2: Verify markdownlint still passes**

If the repo has a markdownlint config, the CI will have caught missing trailing newlines or long lines. Run:

```bash
zig build 2>&1 | tail -10
```

No error is fine — the markdownlint check runs in CI, not locally.

- [ ] **Step 3: Commit**

```bash
git add CHANGELOG.md
git commit -m "docs(changelog): record encoder, EncodeOptions, and CLI landing

Adds Unreleased entries for GAP-0006 (encoder), GAP-0008 (pretty
options), GAP-0007 (toml-test-encoder CLI), and the new CI
conformance job that partially addresses GAP-0004."
```

---

### Task 27: Update gap-analysis documents

**Files:**

- Modify: `/home/benji/src/devnw/zig/toml/docs/GAP_ANALYSIS.md`
- Modify: `/home/benji/src/devnw/zig/toml/docs/GAP_ANALYSIS_RESOLVED.md`

- [ ] **Step 1: Mark GAP-0006, GAP-0007, GAP-0008 closed in the open tracker**

In `docs/GAP_ANALYSIS.md`, for each of GAP-0006, GAP-0007, GAP-0008:

1. Prepend a `- **Status:** Closed -- commit <sha> (2026-04-18). Moved to docs/GAP_ANALYSIS_RESOLVED.md.` line immediately under the `### GAP-XXXX:` heading.
2. Keep the rest of the entry as-is for the move target.

Get commit hashes for the closure markers:

```bash
git log --oneline -40 | grep "close GAP-000"
```

Use those SHAs in the Status lines. (The closure-marker commits landed in Tasks 16 and 23; their SHAs are what you paste in.)

- [ ] **Step 2: Copy the three entries into `docs/GAP_ANALYSIS_RESOLVED.md`**

Append (or insert in SHA order if that is the file's convention) the three entries to `docs/GAP_ANALYSIS_RESOLVED.md`. Add a `- **Resolution:**` and `- **Resolution evidence:**` field under each, mirroring the style of GAP-0002 in the same file.

Example for GAP-0006:

```markdown
### GAP-0006: TOML encoder not implemented

- **Status:** Closed -- commit <sha> (2026-04-18). Moved from docs/GAP_ANALYSIS.md.
- **Issue:** [#6](https://gitlab.com/devnw/zig/toml/-/issues/6)
- **Category:** Feature
- **Severity:** High
- **Requirement source:** REQ-06.
- **Resolution:** `src/encoder.zig` implements `encode(doc, writer, options)`
  with full coverage of every TOML v1 value kind. Round-trip corpus in
  `tests/encoder_roundtrip.zig` asserts parse(encode(parse(x))) yields the
  same tagged-JSON projection as parse(x).
- **Resolution evidence:** `src/encoder.zig`, `tests/encoder_roundtrip.zig`,
  `tests/encoder_golden.zig`, commit <sha>.
- **Outstanding:** toml-test conformance CI job is in place as
  `allow_failure: true`; flipping to required is tracked under GAP-0004.
```

Write equivalent entries for GAP-0007 and GAP-0008 using the evidence from this plan's deliverables.

- [ ] **Step 3: Commit**

```bash
git add docs/GAP_ANALYSIS.md docs/GAP_ANALYSIS_RESOLVED.md
git commit -m "docs(gap): mark GAP-0006, GAP-0007, GAP-0008 closed

Moves encoder, encoder-CLI, and pretty-print entries from the open
tracker into the resolved tracker with evidence links and remaining
items delegated to GAP-0004 (toml-test CI enforcement)."
```

---

### Task 28: Full verification sweep

- [ ] **Step 1: Run all tests**

Run: `zig build test 2>&1 | tail -50`
Expected: every test passes.

- [ ] **Step 2: Run in ReleaseSafe to catch any Debug-only crutches**

Run: `zig build -Doptimize=ReleaseSafe test 2>&1 | tail -40`
Expected: every test passes.

- [ ] **Step 3: Run in ReleaseFast**

Run: `zig build -Doptimize=ReleaseFast test 2>&1 | tail -40`
Expected: every test passes.

- [ ] **Step 4: Smoke the built binaries**

```bash
echo 'a = 42
b = "hi"
[s]
x = 1' | ./zig-out/bin/toml-test-decoder | ./zig-out/bin/toml-test-encoder
```

Expected: a valid TOML representation of the same document. Pipe back through the decoder one more time and confirm the tagged-JSON projection is stable:

```bash
echo 'a = 42
b = "hi"
[s]
x = 1' | ./zig-out/bin/toml-test-decoder > /tmp/a.json
./zig-out/bin/toml-test-encoder < /tmp/a.json | ./zig-out/bin/toml-test-decoder > /tmp/b.json
diff /tmp/a.json /tmp/b.json
```

Expected: empty diff.

- [ ] **Step 5: Check for leaks**

The in-Debug DebugAllocator in the CLIs and `std.testing.allocator` in the test suite are the leak gates. The final `zig build test` run is your proof — if it printed any "memory leak detected" lines, fix them before closing.

Run: `zig build test 2>&1 | grep -i "leak"`
Expected: no output.

- [ ] **Step 6: Final empty commit (closure marker)**

```bash
git commit --allow-empty -m "feat(encoder-suite): GAP-0006, GAP-0007, GAP-0008 closed

Full encoder pipeline lands:
- src/encoder.zig (encode, EncodeOptions)
- src/bin/toml_test_encoder.zig (CLI)
- tests/encoder_roundtrip.zig, tests/encoder_golden.zig
- docs/API.md, docs/ARCHITECTURE.md, CHANGELOG.md updated
- docs/GAP_ANALYSIS.md / GAP_ANALYSIS_RESOLVED.md updated
- .gitlab-ci.yml conformance stage (allow_failure)

All tests green in Debug, ReleaseSafe, and ReleaseFast. No leaks."
```

---

## Self-Review Checklist

Before declaring the plan done the implementer should verify:

- [ ] **Spec coverage.** Walk the "What this plan closes" list at the top:
  - GAP-0006 (encoder module) — covered by Tasks 1-11 and the closure commit in Task 16.
  - GAP-0007 (CLI binary) — covered by Tasks 17-22 and the closure commit in Task 23.
  - GAP-0008 (pretty-print / sort) — covered by Tasks 8 (sort plumbing), 14 (determinism tests), 15 (wrapping), and the closure commit in Task 16.
- [ ] **No placeholders.** Every step shows exact code, exact files, exact commands.
- [ ] **Type consistency.** `EncodeOptions` carries `sort_keys: bool`, `indent: u8`, `inline_threshold: usize` in every task that mentions it. `encode` signature is `(doc: *const Document, writer: anytype, options: EncodeOptions) !void` in every task that mentions it. `runEncodePipeline` and `jsonToValue` signatures match across Tasks 18, 19, 20, 21.
- [ ] **TDD.** Every implementation task starts with a failing test and a step to verify the failure.
- [ ] **Commits.** One commit per task, conventional prefixes, no force-push / amend.
- [ ] **Docs.** `docs/API.md`, `docs/ARCHITECTURE.md`, `CHANGELOG.md`, `docs/GAP_ANALYSIS.md`, and `docs/GAP_ANALYSIS_RESOLVED.md` are all updated before the final closure marker.

## Out of Scope

The following are explicitly out of scope for this plan — do not add them:

- Full toml-test suite green on main (tracked under GAP-0004; this plan only wires the CI stage with `allow_failure: true`).
- Preserving source integer radix (hex/oct/bin).
- Emitting literal or multi-line strings.
- Collapsing nested tables to dotted keys.
- Public mutation API on `Value` / `Document` (tracked under GAP-0009).
- Bench suite (tracked under GAP-0011).
- Iterator API (tracked under GAP-0012).

Any work touching these items must be a separate plan.
