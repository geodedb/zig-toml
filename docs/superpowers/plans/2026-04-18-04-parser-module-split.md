# Parser Module Split Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Split the 1700 LOC `src/parser.zig` monolith into focused submodules (`datetime.zig`, `number.zig`, `string.zig`) while preserving the public API and the full 64/64 test suite, and DRY the datetime family, the integer/float family, and the inline-table flow.

**Architecture:** Extract three stateless submodules that take a `*Parser` when they need to emit errors and return values. The top-level `parser.zig` becomes the dispatch layer (document/value/array/inline-table/key-value/table-path). Each extracted parser keeps its exact signature as a private helper re-exported from `parser.zig` via delegation (`fn parseInteger(self: *Parser, raw: []const u8) !i64 { return number.parseInteger(self, raw); }`) until callers are migrated, then the shims are removed. Shared datetime helpers (`parseDateParts`, `parseTimeParts`, `parseOffset`) collapse the 4 near-parallel datetime parsers into a composition. The 7-level nesting inside `validateFloatFormat` becomes a table-driven byte-classifier state machine.

**Tech Stack:** Zig 0.15.x, `zig build test --summary all`, no new dependencies.

**Closes:**

- Q-5 — datetime family at parser.zig:1301-1686 (~385 LOC, 4 near-parallel parsers + 5 validators)
- Q-6 — integer/float family at parser.zig:1030-1300 (~270 LOC, 7-level nesting in `validateFloatFormat`)
- Q-7 — `parseInlineTable` at parser.zig:648-760 (monolithic 112 LOC)
- Q-17 — parser.zig 1700 LOC monolith (target <800 LOC post-split)

**Invariant:** Every task ends with `zig build test --summary all` reporting **64/64 passing**. If the count drops, stop and fix before continuing. Never weaken tests to match a broken refactor.

---

## File Structure

### Files Created

- `src/parser/datetime.zig` — Parses RFC 3339 datetimes. Owns:
  - `parseDateTime` (offset datetime)
  - `parseDateTimeLocal` (local datetime, no offset)
  - `parseDateLocal` (date-only)
  - `parseTimeLocal` (time-only)
  - Shared helpers: `parseDateParts`, `parseTimeParts`, `parseOffset`
  - Validators: `isLeapYear`, `daysInMonth`, `isValidDate`, `isValidTime`, `isValidOffset`
  - No state; takes `*Parser` only for `self.raiseError(...)` and `self.parse_error` mutation.

- `src/parser/number.zig` — Parses TOML integers and floats. Owns:
  - `parseInteger`, `parseFloat`
  - `validateIntegerFormat`, `validateFloatFormat` (flattened from 7-level nesting)
  - Private helpers: `classifyFloatByte`, `stepFloat`

- `src/parser/string.zig` — Decodes TOML string variants. Owns:
  - `decodeBasicString`, `decodeLiteralString`
  - `decodeMultilineBasicString`, `decodeMultilineLiteralString`
  - `decodeEscapes`, `decodeEscapeChar`

### Files Modified

- `src/parser.zig` — Becomes the dispatch layer. Keeps:
  - `ParseOptions`, `Parser` struct, `init`, `deinit`, error helpers (`raiseError`, `raiseErrorAt`)
  - `parseDocument`, `parseValue`, `parseArray`, `parseArrayContents`
  - `parseInlineTable` split into `parseInlineTableHeader`, `parseInlineTableBody`, `validateInlineTableV10Restrictions`
  - `resolveTablePath`, `parseKeyValue`
  - `const datetime = @import("parser/datetime.zig");` + peers
  - Target size: <800 LOC. Baseline: 1700 LOC.

- `docs/ARCHITECTURE.md` — Updates the "File structure" / "Source layout" section to list the new submodules.

### Files Untouched (invariant — confirm at end)

- `src/lexer.zig`, `src/value.zig`, `src/error.zig`, `src/toml.zig`, `src/json_tagged.zig`, `src/parallel.zig`, `tests/**`

---

## Task 1: Baseline — snapshot current test count

**Files:**

- Read: `src/parser.zig` (confirm 1700 LOC)
- Create: `.plan-baseline.txt` (ignored scratch file; delete at end)

- [ ] **Step 1: Confirm working tree is clean**

Run:

```bash
git status
```

Expected: `nothing to commit, working tree clean` on branch `main` (or the worktree branch for this plan).

- [ ] **Step 2: Record baseline line count**

Run:

```bash
wc -l src/parser.zig
```

Expected: `1700 src/parser.zig`.

If the number differs, update the "Closes" line references above before continuing — off-by-a-few is fine, off-by-hundreds means rebasing is needed.

- [ ] **Step 3: Record baseline test pass count**

Run:

```bash
zig build test --summary all 2>&1 | tee .plan-baseline.txt
```

Expected tail lines contain: `64/64` passing across all test steps (or whatever the current green count is — treat whatever prints as THE invariant).

- [ ] **Step 4: Snapshot the baseline count**

Run:

```bash
grep -E "[0-9]+/[0-9]+" .plan-baseline.txt | tail -5
```

Write the exact "N/N passed" number on a sticky note (or in your head). **Every subsequent `zig build test` must match this number.** If a task drops the count, roll back that task and diagnose before continuing.

- [ ] **Step 5: No commit (this is a read-only baseline)**

Do NOT commit `.plan-baseline.txt` — it is a scratch artifact.

---

## Task 2: Scaffold `src/parser/datetime.zig` with empty stubs

**Files:**

- Create: `src/parser/datetime.zig`
- Modify: `src/parser.zig` (add `const datetime = @import("parser/datetime.zig");` near the other imports)

- [ ] **Step 1: Create the `src/parser` directory**

Run:

```bash
mkdir -p src/parser
```

- [ ] **Step 2: Write the skeleton with stub signatures**

Create `src/parser/datetime.zig`:

```zig
// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! RFC 3339 datetime parsing for TOML.
//!
//! This module owns the four datetime parsers (offset datetime, local
//! datetime, local date, local time) and their validators. It holds no
//! state; all error reporting is delegated back to the caller via the
//! `*Parser` argument, which owns the error channel and position.

const std = @import("std");
const val = @import("../value.zig");
const err = @import("../error.zig");
const ErrorCode = err.ErrorCode;

// Forward-declared to break the import cycle. `Parser` is defined in
// `../parser.zig`; we only need its pointer here.
const Parser = @import("../parser.zig").Parser;

pub fn parseDateTime(self: *Parser, raw: []const u8) !val.DateTime {
    _ = self;
    _ = raw;
    @panic("datetime.parseDateTime: not yet moved");
}

pub fn parseDateTimeLocal(self: *Parser, raw: []const u8) !val.DateTimeLocal {
    _ = self;
    _ = raw;
    @panic("datetime.parseDateTimeLocal: not yet moved");
}

pub fn parseDateLocal(self: *Parser, raw: []const u8) !val.DateLocal {
    _ = self;
    _ = raw;
    @panic("datetime.parseDateLocal: not yet moved");
}

pub fn parseTimeLocal(self: *Parser, raw: []const u8) !val.TimeLocal {
    _ = self;
    _ = raw;
    @panic("datetime.parseTimeLocal: not yet moved");
}

pub fn isLeapYear(year: u16) bool {
    _ = year;
    @panic("datetime.isLeapYear: not yet moved");
}

pub fn daysInMonth(year: u16, month: u8) u8 {
    _ = year;
    _ = month;
    @panic("datetime.daysInMonth: not yet moved");
}

pub fn isValidDate(year: u16, month: u8, day: u8) bool {
    _ = year;
    _ = month;
    _ = day;
    @panic("datetime.isValidDate: not yet moved");
}

pub fn isValidTime(hour: u8, minute: u8, second: u8) bool {
    _ = hour;
    _ = minute;
    _ = second;
    @panic("datetime.isValidTime: not yet moved");
}

pub fn isValidOffset(offset_hour: i16, offset_minute: i16) bool {
    _ = offset_hour;
    _ = offset_minute;
    @panic("datetime.isValidOffset: not yet moved");
}
```

- [ ] **Step 3: Add the import in `src/parser.zig`**

In `src/parser.zig`, right after `const val = @import("value.zig");` (around line 16), add:

```zig
const datetime = @import("parser/datetime.zig");
```

- [ ] **Step 4: Compile — NOT run — to verify scaffold wires up**

Run:

```bash
zig build
```

Expected: success. The stubs compile because nothing calls them yet. If `zig build` fails with a cycle error, make sure `datetime.zig` uses `@import("../parser.zig").Parser` inside a `const Parser = ...;` at file scope (it does) and not inside a function body.

- [ ] **Step 5: Run tests to confirm 64/64 still passes**

Run:

```bash
zig build test --summary all
```

Expected: same pass count as Task 1 baseline (the stubs are unreachable).

- [ ] **Step 6: Do NOT commit yet**

Scaffolding alone is not a meaningful commit. The first commit comes after the entire datetime module is moved (Task 9).

---

## Task 3: Move `parseDateTime` into `datetime.zig`

**Files:**

- Modify: `src/parser/datetime.zig` (replace `parseDateTime` stub with the real body)
- Modify: `src/parser.zig:1301-1436` (replace body with a one-line delegate)

- [ ] **Step 1: Read the current `parseDateTime` body**

Run:

```bash
sed -n '1301,1436p' src/parser.zig
```

You should see the offset-datetime parser (produces `val.DateTime`). Copy it verbatim.

- [ ] **Step 2: Paste the body into `datetime.zig`, replacing the stub**

In `src/parser/datetime.zig`, replace the `parseDateTime` stub with the body you just copied. Two translations are required:

1. Every `self.<helper>` that is a method on `Parser` stays `self.<helper>` (Zig method call on the pointer works across files).
2. Any reference to a module-private helper that is *also* in the datetime family (e.g. `self.isValidDate`, `self.daysInMonth`) must be rewritten to reference the `datetime.zig` version as plain function calls — but only AFTER those helpers have moved (Task 7). For now, keep them as `self.isValidDate(...)` etc., because they still live on `Parser`.

- [ ] **Step 3: Replace the body in `parser.zig` with a delegate**

In `src/parser.zig`, replace:

```zig
fn parseDateTime(self: *Parser, raw: []const u8) !val.DateTime {
    // ... 135 lines of body ...
}
```

with exactly:

```zig
fn parseDateTime(self: *Parser, raw: []const u8) !val.DateTime {
    return datetime.parseDateTime(self, raw);
}
```

- [ ] **Step 4: Build**

Run:

```bash
zig build
```

Expected: success. If it fails because `datetime.parseDateTime` references a helper that is method-on-Parser (e.g. `self.raiseError`), leave that call as-is — it works across files because `self` is a `*Parser`.

- [ ] **Step 5: Run tests**

Run:

```bash
zig build test --summary all
```

Expected: baseline count passing. If any datetime test fails, diff the moved body character-by-character against the original.

- [ ] **Step 6: No commit yet** (batch with Task 9).

---

## Task 4: Move `parseDateTimeLocal` into `datetime.zig`

**Files:**

- Modify: `src/parser/datetime.zig`
- Modify: `src/parser.zig:1437-1528`

- [ ] **Step 1: Read the current body**

Run:

```bash
sed -n '1437,1528p' src/parser.zig
```

- [ ] **Step 2: Replace the `parseDateTimeLocal` stub in `datetime.zig`**

Paste the body verbatim, replacing the stub. Same translation rules as Task 3, Step 2.

- [ ] **Step 3: Replace the body in `parser.zig` with a delegate**

```zig
fn parseDateTimeLocal(self: *Parser, raw: []const u8) !val.DateTimeLocal {
    return datetime.parseDateTimeLocal(self, raw);
}
```

- [ ] **Step 4: Build and test**

Run:

```bash
zig build && zig build test --summary all
```

Expected: baseline count passing.

- [ ] **Step 5: No commit yet.**

---

## Task 5: Move `parseDateLocal` into `datetime.zig`

**Files:**

- Modify: `src/parser/datetime.zig`
- Modify: `src/parser.zig:1529-1565`

- [ ] **Step 1: Read the current body**

Run:

```bash
sed -n '1529,1565p' src/parser.zig
```

- [ ] **Step 2: Replace the `parseDateLocal` stub in `datetime.zig`** (paste verbatim).

- [ ] **Step 3: Replace the body in `parser.zig` with a delegate**

```zig
fn parseDateLocal(self: *Parser, raw: []const u8) !val.DateLocal {
    return datetime.parseDateLocal(self, raw);
}
```

- [ ] **Step 4: Build and test**

Run:

```bash
zig build && zig build test --summary all
```

Expected: baseline count passing.

- [ ] **Step 5: No commit yet.**

---

## Task 6: Move `parseTimeLocal` into `datetime.zig`

**Files:**

- Modify: `src/parser/datetime.zig`
- Modify: `src/parser.zig:1566-1651`

- [ ] **Step 1: Read the current body**

Run:

```bash
sed -n '1566,1651p' src/parser.zig
```

- [ ] **Step 2: Replace the `parseTimeLocal` stub in `datetime.zig`** (paste verbatim).

- [ ] **Step 3: Replace the body in `parser.zig` with a delegate**

```zig
fn parseTimeLocal(self: *Parser, raw: []const u8) !val.TimeLocal {
    return datetime.parseTimeLocal(self, raw);
}
```

- [ ] **Step 4: Build and test**

Run:

```bash
zig build && zig build test --summary all
```

Expected: baseline count passing.

- [ ] **Step 5: No commit yet.**

---

## Task 7: Move the five datetime validators

**Files:**

- Modify: `src/parser/datetime.zig`
- Modify: `src/parser.zig:1652-1686`

The validators (`isLeapYear`, `daysInMonth`, `isValidDate`, `isValidTime`, `isValidOffset`) are pure functions — they take no `*Parser`. They are currently declared as `fn` on the `Parser` struct but never use `self`. We move them to `datetime.zig` as free functions and update the four parsers we already moved to call them directly.

- [ ] **Step 1: Read the validator bodies**

Run:

```bash
sed -n '1652,1686p' src/parser.zig
```

- [ ] **Step 2: Replace each stub in `datetime.zig` with the real body**

All five bodies go in. They do not take `*Parser`. Example for `isLeapYear`:

```zig
pub fn isLeapYear(year: u16) bool {
    if (year % 400 == 0) return true;
    if (year % 100 == 0) return false;
    return year % 4 == 0;
}
```

Paste the others (`daysInMonth`, `isValidDate`, `isValidTime`, `isValidOffset`) verbatim into the corresponding stubs.

- [ ] **Step 3: Rewrite datetime parsers to call local validators (not `self.*`)**

Inside `src/parser/datetime.zig`, search each of the four parsers (`parseDateTime`, `parseDateTimeLocal`, `parseDateLocal`, `parseTimeLocal`) and replace:

- `self.isValidDate(` → `isValidDate(`
- `self.isValidTime(` → `isValidTime(`
- `self.isValidOffset(` → `isValidOffset(`
- `self.daysInMonth(` → `daysInMonth(`
- `self.isLeapYear(` → `isLeapYear(`

- [ ] **Step 4: Remove the validator methods from `parser.zig`**

In `src/parser.zig`, delete the five methods at lines 1652-1686. They are no longer called from anywhere in `parser.zig` itself (the four parsers have become delegates; the delegates call into `datetime.zig`, which has its own copies).

- [ ] **Step 5: Build**

Run:

```bash
zig build
```

Expected: success. If Zig complains about an unused private `isLeapYear` in `parser.zig`, you missed deleting one — repeat Step 4.

- [ ] **Step 6: Run tests**

Run:

```bash
zig build test --summary all
```

Expected: baseline count passing. All leap-year / invalid-day / offset-bounds tests go through `datetime.zig` now.

- [ ] **Step 7: No commit yet.**

---

## Task 8: Extract shared datetime helpers — DRY the four parsers

**Files:**

- Modify: `src/parser/datetime.zig`

The four moved parsers share large parallel stretches. We factor out:

- `parseDateParts(raw, idx, pos) !struct { year, month, day, consumed }` — consumes `YYYY-MM-DD` starting at `raw[idx]`, validates, returns the three u16/u8 fields and the count of bytes consumed.
- `parseTimeParts(raw, idx, pos) !struct { hour, minute, second, nanosecond, consumed }` — consumes `HH:MM:SS[.fff...]`.
- `parseOffset(raw, idx, pos) !struct { offset_minutes, consumed }` — consumes `Z` or `±HH:MM`.

All three take `self: *Parser` for error reporting.

- [ ] **Step 1: Write the shared helper signatures (stubs that panic)**

At the bottom of `src/parser/datetime.zig`, add:

```zig
const DateParts = struct {
    year: u16,
    month: u8,
    day: u8,
    consumed: usize,
};

const TimeParts = struct {
    hour: u8,
    minute: u8,
    second: u8,
    nanosecond: u32,
    consumed: usize,
};

const OffsetParts = struct {
    // Signed minutes east of UTC. `Z` → 0.
    offset_minutes: i16,
    consumed: usize,
};

fn parseDateParts(self: *Parser, raw: []const u8, idx: usize) !DateParts {
    _ = self;
    _ = raw;
    _ = idx;
    @panic("parseDateParts: not yet implemented");
}

fn parseTimeParts(self: *Parser, raw: []const u8, idx: usize) !TimeParts {
    _ = self;
    _ = raw;
    _ = idx;
    @panic("parseTimeParts: not yet implemented");
}

fn parseOffset(self: *Parser, raw: []const u8, idx: usize) !OffsetParts {
    _ = self;
    _ = raw;
    _ = idx;
    @panic("parseOffset: not yet implemented");
}
```

- [ ] **Step 2: Write failing tests for the helpers (TDD)**

Add at the bottom of `src/parser/datetime.zig`:

```zig
const testing = std.testing;

test "parseDateParts accepts 2024-02-29 (leap year)" {
    const alloc = testing.allocator;
    var p = @import("../parser.zig").Parser.init(alloc, "2024-02-29", .{});
    defer p.deinit();
    const d = try parseDateParts(&p, "2024-02-29", 0);
    try testing.expectEqual(@as(u16, 2024), d.year);
    try testing.expectEqual(@as(u8, 2), d.month);
    try testing.expectEqual(@as(u8, 29), d.day);
    try testing.expectEqual(@as(usize, 10), d.consumed);
}

test "parseDateParts rejects 2023-02-29 (not leap)" {
    const alloc = testing.allocator;
    var p = @import("../parser.zig").Parser.init(alloc, "2023-02-29", .{});
    defer p.deinit();
    try testing.expectError(error.ParseFailed, parseDateParts(&p, "2023-02-29", 0));
}

test "parseTimeParts accepts 12:34:56.789" {
    const alloc = testing.allocator;
    var p = @import("../parser.zig").Parser.init(alloc, "12:34:56.789", .{});
    defer p.deinit();
    const t = try parseTimeParts(&p, "12:34:56.789", 0);
    try testing.expectEqual(@as(u8, 12), t.hour);
    try testing.expectEqual(@as(u8, 34), t.minute);
    try testing.expectEqual(@as(u8, 56), t.second);
    try testing.expectEqual(@as(u32, 789_000_000), t.nanosecond);
}

test "parseTimeParts rejects 25:00:00" {
    const alloc = testing.allocator;
    var p = @import("../parser.zig").Parser.init(alloc, "25:00:00", .{});
    defer p.deinit();
    try testing.expectError(error.ParseFailed, parseTimeParts(&p, "25:00:00", 0));
}

test "parseOffset accepts Z" {
    const alloc = testing.allocator;
    var p = @import("../parser.zig").Parser.init(alloc, "Z", .{});
    defer p.deinit();
    const o = try parseOffset(&p, "Z", 0);
    try testing.expectEqual(@as(i16, 0), o.offset_minutes);
    try testing.expectEqual(@as(usize, 1), o.consumed);
}

test "parseOffset accepts -05:00" {
    const alloc = testing.allocator;
    var p = @import("../parser.zig").Parser.init(alloc, "-05:00", .{});
    defer p.deinit();
    const o = try parseOffset(&p, "-05:00", 0);
    try testing.expectEqual(@as(i16, -300), o.offset_minutes);
    try testing.expectEqual(@as(usize, 6), o.consumed);
}

test "parseOffset accepts +14:00" {
    const alloc = testing.allocator;
    var p = @import("../parser.zig").Parser.init(alloc, "+14:00", .{});
    defer p.deinit();
    const o = try parseOffset(&p, "+14:00", 0);
    try testing.expectEqual(@as(i16, 840), o.offset_minutes);
    try testing.expectEqual(@as(usize, 6), o.consumed);
}
```

- [ ] **Step 3: Run the new tests to watch them fail**

Run:

```bash
zig build test --summary all
```

Expected: the 7 new tests panic/fail. The 64 original tests remain passing (still go through the stubs? — no; step 4 rescues). If the original tests started failing, you already called the stubs. Revert and retry.

- [ ] **Step 4: Implement `parseDateParts`**

Replace the `parseDateParts` stub with a body derived from the date-parsing prefix of `parseDateTime`:

```zig
fn parseDateParts(self: *Parser, raw: []const u8, idx: usize) !DateParts {
    if (raw.len < idx + 10) {
        try self.raiseError(.invalid_date, "date too short");
        return error.ParseFailed;
    }
    // YYYY
    const year = std.fmt.parseInt(u16, raw[idx .. idx + 4], 10) catch {
        try self.raiseError(.invalid_date, "bad year digits");
        return error.ParseFailed;
    };
    if (raw[idx + 4] != '-') {
        try self.raiseError(.invalid_date, "expected '-' after year");
        return error.ParseFailed;
    }
    const month = std.fmt.parseInt(u8, raw[idx + 5 .. idx + 7], 10) catch {
        try self.raiseError(.invalid_date, "bad month digits");
        return error.ParseFailed;
    };
    if (raw[idx + 7] != '-') {
        try self.raiseError(.invalid_date, "expected '-' after month");
        return error.ParseFailed;
    }
    const day = std.fmt.parseInt(u8, raw[idx + 8 .. idx + 10], 10) catch {
        try self.raiseError(.invalid_date, "bad day digits");
        return error.ParseFailed;
    };
    if (!isValidDate(year, month, day)) {
        try self.raiseError(.invalid_date, "calendar-invalid date");
        return error.ParseFailed;
    }
    return .{ .year = year, .month = month, .day = day, .consumed = 10 };
}
```

- [ ] **Step 5: Implement `parseTimeParts`**

Replace the stub with a body derived from the time-parsing section of `parseDateTime`:

```zig
fn parseTimeParts(self: *Parser, raw: []const u8, idx: usize) !TimeParts {
    if (raw.len < idx + 8) {
        try self.raiseError(.invalid_time, "time too short");
        return error.ParseFailed;
    }
    const hour = std.fmt.parseInt(u8, raw[idx .. idx + 2], 10) catch {
        try self.raiseError(.invalid_time, "bad hour digits");
        return error.ParseFailed;
    };
    if (raw[idx + 2] != ':') {
        try self.raiseError(.invalid_time, "expected ':' after hour");
        return error.ParseFailed;
    }
    const minute = std.fmt.parseInt(u8, raw[idx + 3 .. idx + 5], 10) catch {
        try self.raiseError(.invalid_time, "bad minute digits");
        return error.ParseFailed;
    };
    if (raw[idx + 5] != ':') {
        try self.raiseError(.invalid_time, "expected ':' after minute");
        return error.ParseFailed;
    }
    const second = std.fmt.parseInt(u8, raw[idx + 6 .. idx + 8], 10) catch {
        try self.raiseError(.invalid_time, "bad second digits");
        return error.ParseFailed;
    };
    if (!isValidTime(hour, minute, second)) {
        try self.raiseError(.invalid_time, "hour/minute/second out of range");
        return error.ParseFailed;
    }

    var consumed: usize = 8;
    var nanosecond: u32 = 0;

    if (raw.len > idx + consumed and raw[idx + consumed] == '.') {
        consumed += 1;
        const frac_start = idx + consumed;
        while (idx + consumed < raw.len and std.ascii.isDigit(raw[idx + consumed])) : (consumed += 1) {}
        const frac_end = idx + consumed;
        if (frac_end == frac_start) {
            try self.raiseError(.invalid_time, "empty fractional seconds");
            return error.ParseFailed;
        }
        // Scale up to nanoseconds, truncate beyond 9 digits.
        const frac_len = @min(frac_end - frac_start, 9);
        const digits = raw[frac_start .. frac_start + frac_len];
        const parsed = std.fmt.parseInt(u32, digits, 10) catch 0;
        var scale: u32 = 1;
        var k: usize = frac_len;
        while (k < 9) : (k += 1) scale *= 10;
        nanosecond = parsed * scale;
    }

    return .{
        .hour = hour,
        .minute = minute,
        .second = second,
        .nanosecond = nanosecond,
        .consumed = consumed,
    };
}
```

- [ ] **Step 6: Implement `parseOffset`**

Replace the stub:

```zig
fn parseOffset(self: *Parser, raw: []const u8, idx: usize) !OffsetParts {
    if (idx >= raw.len) {
        try self.raiseError(.invalid_offset, "missing offset");
        return error.ParseFailed;
    }
    if (raw[idx] == 'Z' or raw[idx] == 'z') {
        return .{ .offset_minutes = 0, .consumed = 1 };
    }
    if (raw.len < idx + 6) {
        try self.raiseError(.invalid_offset, "offset too short");
        return error.ParseFailed;
    }
    const sign: i16 = switch (raw[idx]) {
        '+' => 1,
        '-' => -1,
        else => {
            try self.raiseError(.invalid_offset, "expected Z, + or -");
            return error.ParseFailed;
        },
    };
    const hh = std.fmt.parseInt(i16, raw[idx + 1 .. idx + 3], 10) catch {
        try self.raiseError(.invalid_offset, "bad offset hour digits");
        return error.ParseFailed;
    };
    if (raw[idx + 3] != ':') {
        try self.raiseError(.invalid_offset, "expected ':' in offset");
        return error.ParseFailed;
    }
    const mm = std.fmt.parseInt(i16, raw[idx + 4 .. idx + 6], 10) catch {
        try self.raiseError(.invalid_offset, "bad offset minute digits");
        return error.ParseFailed;
    };
    if (!isValidOffset(hh, mm)) {
        try self.raiseError(.invalid_offset, "offset out of range");
        return error.ParseFailed;
    }
    return .{ .offset_minutes = sign * (hh * 60 + mm), .consumed = 6 };
}
```

- [ ] **Step 7: Run the helper tests — expect all 7 to pass**

Run:

```bash
zig build test --summary all
```

Expected: 64 original + 7 new = 71/71. If any of the new tests fail, diff the helper against the prefix of the original `parseDateTime` body.

- [ ] **Step 8: Refactor `parseDateTime` to use the helpers**

In `src/parser/datetime.zig`, replace the body of `parseDateTime` with:

```zig
pub fn parseDateTime(self: *Parser, raw: []const u8) !val.DateTime {
    const d = try parseDateParts(self, raw, 0);
    if (d.consumed >= raw.len or (raw[d.consumed] != 'T' and raw[d.consumed] != 't' and raw[d.consumed] != ' ')) {
        try self.raiseError(.invalid_datetime, "expected T between date and time");
        return error.ParseFailed;
    }
    const t = try parseTimeParts(self, raw, d.consumed + 1);
    const off_idx = d.consumed + 1 + t.consumed;
    const o = try parseOffset(self, raw, off_idx);
    if (off_idx + o.consumed != raw.len) {
        try self.raiseError(.invalid_datetime, "trailing characters after offset");
        return error.ParseFailed;
    }
    return .{
        .year = d.year,
        .month = d.month,
        .day = d.day,
        .hour = t.hour,
        .minute = t.minute,
        .second = t.second,
        .nanosecond = t.nanosecond,
        .offset_minutes = o.offset_minutes,
    };
}
```

If any field name does not match `val.DateTime` in your tree, use the real field names — `grep -n "pub const DateTime" src/value.zig` to check.

- [ ] **Step 9: Refactor `parseDateTimeLocal` to use helpers**

```zig
pub fn parseDateTimeLocal(self: *Parser, raw: []const u8) !val.DateTimeLocal {
    const d = try parseDateParts(self, raw, 0);
    if (d.consumed >= raw.len or (raw[d.consumed] != 'T' and raw[d.consumed] != 't' and raw[d.consumed] != ' ')) {
        try self.raiseError(.invalid_datetime, "expected T between date and time");
        return error.ParseFailed;
    }
    const t = try parseTimeParts(self, raw, d.consumed + 1);
    if (d.consumed + 1 + t.consumed != raw.len) {
        try self.raiseError(.invalid_datetime, "trailing characters on local datetime");
        return error.ParseFailed;
    }
    return .{
        .year = d.year,
        .month = d.month,
        .day = d.day,
        .hour = t.hour,
        .minute = t.minute,
        .second = t.second,
        .nanosecond = t.nanosecond,
    };
}
```

- [ ] **Step 10: Refactor `parseDateLocal` to use helpers**

```zig
pub fn parseDateLocal(self: *Parser, raw: []const u8) !val.DateLocal {
    const d = try parseDateParts(self, raw, 0);
    if (d.consumed != raw.len) {
        try self.raiseError(.invalid_date, "trailing characters on date");
        return error.ParseFailed;
    }
    return .{ .year = d.year, .month = d.month, .day = d.day };
}
```

- [ ] **Step 11: Refactor `parseTimeLocal` to use helpers**

```zig
pub fn parseTimeLocal(self: *Parser, raw: []const u8) !val.TimeLocal {
    const t = try parseTimeParts(self, raw, 0);
    if (t.consumed != raw.len) {
        try self.raiseError(.invalid_time, "trailing characters on time");
        return error.ParseFailed;
    }
    return .{
        .hour = t.hour,
        .minute = t.minute,
        .second = t.second,
        .nanosecond = t.nanosecond,
    };
}
```

- [ ] **Step 12: Build**

Run:

```bash
zig build
```

Expected: success.

- [ ] **Step 13: Run full test suite**

Run:

```bash
zig build test --summary all
```

Expected: **71/71 passing** (64 original + 7 helper tests). If any original test now fails, the helpers have a subtle divergence from the original logic — compare the offset-index math step by step.

- [ ] **Step 14: Measure DRY savings**

Run:

```bash
wc -l src/parser/datetime.zig
```

Expected: ~200 LOC (down from ~385 LOC of in-line parser code). The exact number is not critical; the goal is that the four parsers are now 10-line compositions.

---

## Task 9: Commit the datetime extraction

**Files:** all changes so far.

- [ ] **Step 1: Review the diff**

Run:

```bash
git status
git diff --stat
```

Expected:

- `src/parser/datetime.zig` (new, ~350 LOC including tests)
- `src/parser.zig` (modified, smaller)

- [ ] **Step 2: Stage and commit**

Run:

```bash
git add src/parser/datetime.zig src/parser.zig
git commit -m "refactor(parser): close Q-5 — extract datetime module

Moves parseDateTime/parseDateTimeLocal/parseDateLocal/parseTimeLocal
and their validators out of parser.zig into src/parser/datetime.zig.
Introduces parseDateParts/parseTimeParts/parseOffset helpers so the
four parsers compose instead of duplicating ~200 lines of near-parallel
digit scanning.

Public API unchanged; parser.zig retains thin delegating wrappers.
Test count: 64 -> 71 (added helper-level tests)."
```

- [ ] **Step 3: Verify commit landed and tests still pass**

Run:

```bash
git log --oneline -1
zig build test --summary all
```

Expected: new commit at HEAD, 71/71 passing.

---

## Task 10: Scaffold `src/parser/number.zig` and move the four functions

**Files:**

- Create: `src/parser/number.zig`
- Modify: `src/parser.zig` (import + four delegating wrappers)

- [ ] **Step 1: Create the skeleton**

Create `src/parser/number.zig`:

```zig
// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! TOML integer and float parsing.

const std = @import("std");
const err = @import("../error.zig");
const ErrorCode = err.ErrorCode;

const Parser = @import("../parser.zig").Parser;

pub fn parseInteger(self: *Parser, raw: []const u8) !i64 {
    _ = self;
    _ = raw;
    @panic("number.parseInteger: not yet moved");
}

pub fn parseFloat(self: *Parser, raw: []const u8) !f64 {
    _ = self;
    _ = raw;
    @panic("number.parseFloat: not yet moved");
}

pub fn validateIntegerFormat(self: *Parser, raw: []const u8) !void {
    _ = self;
    _ = raw;
    @panic("number.validateIntegerFormat: not yet moved");
}

pub fn validateFloatFormat(self: *Parser, raw: []const u8) !void {
    _ = self;
    _ = raw;
    @panic("number.validateFloatFormat: not yet moved");
}
```

- [ ] **Step 2: Add the import in `src/parser.zig`**

Right after `const datetime = @import("parser/datetime.zig");`, add:

```zig
const number = @import("parser/number.zig");
```

- [ ] **Step 3: Read each function body**

Run:

```bash
sed -n '1030,1093p' src/parser.zig    # parseInteger
sed -n '1094,1166p' src/parser.zig    # validateIntegerFormat
sed -n '1167,1197p' src/parser.zig    # parseFloat
sed -n '1198,1299p' src/parser.zig    # validateFloatFormat
```

- [ ] **Step 4: Paste each body into `number.zig`, replacing the stubs**

Exact copy. Every `self.<method>` call works as-is (method-on-pointer).

- [ ] **Step 5: Replace each body in `parser.zig` with a delegate**

```zig
fn parseInteger(self: *Parser, raw: []const u8) !i64 {
    return number.parseInteger(self, raw);
}

fn validateIntegerFormat(self: *Parser, raw: []const u8) !void {
    return number.validateIntegerFormat(self, raw);
}

fn parseFloat(self: *Parser, raw: []const u8) !f64 {
    return number.parseFloat(self, raw);
}

fn validateFloatFormat(self: *Parser, raw: []const u8) !void {
    return number.validateFloatFormat(self, raw);
}
```

- [ ] **Step 6: Build**

Run:

```bash
zig build
```

Expected: success.

- [ ] **Step 7: Run tests**

Run:

```bash
zig build test --summary all
```

Expected: 71/71.

---

## Task 11: Flatten the 7-level nesting in `validateFloatFormat`

**Files:**

- Modify: `src/parser/number.zig`

`validateFloatFormat` is the Q-6 hotspot. Today it's `if (leading) { while (...) { if (...) { switch { case ... { if (...) { ... } } } } } }`. We replace it with a linear state-machine over byte classes. TDD, so we add failing tests first.

- [ ] **Step 1: Read the current `validateFloatFormat` body you just moved**

Open `src/parser/number.zig` and re-read the function. List on scratch paper every invalid input it currently rejects (leading underscore, trailing underscore, double underscore around `.`, bare `_e`, `.e`, `e.`, empty mantissa, empty exponent, double sign in exponent, underscore adjacent to `.` or `e`, etc.).

- [ ] **Step 2: Add failing characterisation tests in `number.zig`**

Append:

```zig
const testing = std.testing;

fn expectFloatReject(input: []const u8) !void {
    const alloc = testing.allocator;
    var p = @import("../parser.zig").Parser.init(alloc, input, .{});
    defer p.deinit();
    try testing.expectError(error.ParseFailed, validateFloatFormat(&p, input));
}

fn expectFloatAccept(input: []const u8) !void {
    const alloc = testing.allocator;
    var p = @import("../parser.zig").Parser.init(alloc, input, .{});
    defer p.deinit();
    try validateFloatFormat(&p, input);
}

test "validateFloatFormat rejects leading underscore" {
    try expectFloatReject("_1.0");
}

test "validateFloatFormat rejects trailing underscore" {
    try expectFloatReject("1.0_");
}

test "validateFloatFormat rejects underscore adjacent to dot" {
    try expectFloatReject("1_.0");
    try expectFloatReject("1._0");
}

test "validateFloatFormat rejects underscore adjacent to exponent" {
    try expectFloatReject("1.0_e5");
    try expectFloatReject("1.0e_5");
}

test "validateFloatFormat rejects empty mantissa" {
    try expectFloatReject(".5");
}

test "validateFloatFormat rejects empty exponent" {
    try expectFloatReject("1.0e");
    try expectFloatReject("1.0e+");
}

test "validateFloatFormat rejects double sign in exponent" {
    try expectFloatReject("1.0e++5");
}

test "validateFloatFormat accepts simple float" {
    try expectFloatAccept("3.14");
}

test "validateFloatFormat accepts grouped underscores" {
    try expectFloatAccept("9_224_617.445_991_228_313");
}

test "validateFloatFormat accepts signed exponent" {
    try expectFloatAccept("6.022e+23");
    try expectFloatAccept("1.0e-10");
}
```

- [ ] **Step 3: Run tests — every new test must pass BEFORE we refactor**

Run:

```bash
zig build test --summary all
```

Expected: 71 + 11 = 82/82. These are characterisation tests — they pass against the current 7-level implementation. If any FAIL, the old code actually has a bug in that case; do NOT weaken the test — instead, leave that test failing, fix the behaviour in the new implementation below, and keep the test green at the end.

- [ ] **Step 4: Replace `validateFloatFormat` with a flat state machine**

Replace the function body with:

```zig
const FloatClass = enum { digit, underscore, dot, exp, sign, other, end };

const FloatState = enum {
    start,            // before any digit
    int_digit,        // saw a digit in the integer part
    int_underscore,   // saw an underscore in the integer part
    after_dot,        // saw the '.'
    frac_digit,       // saw a digit in the fractional part
    frac_underscore,  // saw an underscore in the fractional part
    after_exp,        // saw 'e' or 'E'
    after_exp_sign,   // saw 'e' then '+' or '-'
    exp_digit,        // saw a digit in the exponent
    exp_underscore,   // saw an underscore in the exponent
    done,
};

fn classifyFloatByte(c: u8) FloatClass {
    return switch (c) {
        '0'...'9' => .digit,
        '_' => .underscore,
        '.' => .dot,
        'e', 'E' => .exp,
        '+', '-' => .sign,
        else => .other,
    };
}

pub fn validateFloatFormat(self: *Parser, raw: []const u8) !void {
    var state: FloatState = .start;

    // Strip a leading '+' or '-' (allowed by TOML on the whole number).
    var start: usize = 0;
    if (raw.len > 0 and (raw[0] == '+' or raw[0] == '-')) start = 1;
    if (start == raw.len) {
        try self.raiseError(.invalid_float, "empty float after sign");
        return error.ParseFailed;
    }

    var i: usize = start;
    while (i < raw.len) : (i += 1) {
        const cls = classifyFloatByte(raw[i]);
        state = try stepFloat(self, state, cls, raw[i]);
    }
    // Terminal check.
    switch (state) {
        .frac_digit, .exp_digit => return, // valid
        .int_digit => {
            try self.raiseError(.invalid_float, "float must contain '.' or exponent");
            return error.ParseFailed;
        },
        else => {
            try self.raiseError(.invalid_float, "float ended in invalid state");
            return error.ParseFailed;
        },
    }
}

fn stepFloat(self: *Parser, state: FloatState, cls: FloatClass, byte: u8) !FloatState {
    _ = byte;
    return switch (state) {
        .start => switch (cls) {
            .digit => .int_digit,
            else => blk: {
                try self.raiseError(.invalid_float, "float must start with a digit");
                break :blk error.ParseFailed;
            },
        },
        .int_digit => switch (cls) {
            .digit => .int_digit,
            .underscore => .int_underscore,
            .dot => .after_dot,
            .exp => .after_exp,
            else => blk: {
                try self.raiseError(.invalid_float, "invalid character in integer part");
                break :blk error.ParseFailed;
            },
        },
        .int_underscore => switch (cls) {
            .digit => .int_digit,
            else => blk: {
                try self.raiseError(.invalid_float, "underscore must be between digits");
                break :blk error.ParseFailed;
            },
        },
        .after_dot => switch (cls) {
            .digit => .frac_digit,
            else => blk: {
                try self.raiseError(.invalid_float, "digit required after '.'");
                break :blk error.ParseFailed;
            },
        },
        .frac_digit => switch (cls) {
            .digit => .frac_digit,
            .underscore => .frac_underscore,
            .exp => .after_exp,
            else => blk: {
                try self.raiseError(.invalid_float, "invalid character in fractional part");
                break :blk error.ParseFailed;
            },
        },
        .frac_underscore => switch (cls) {
            .digit => .frac_digit,
            else => blk: {
                try self.raiseError(.invalid_float, "underscore must be between digits");
                break :blk error.ParseFailed;
            },
        },
        .after_exp => switch (cls) {
            .digit => .exp_digit,
            .sign => .after_exp_sign,
            else => blk: {
                try self.raiseError(.invalid_float, "digit or sign required after exponent marker");
                break :blk error.ParseFailed;
            },
        },
        .after_exp_sign => switch (cls) {
            .digit => .exp_digit,
            else => blk: {
                try self.raiseError(.invalid_float, "digit required after exponent sign");
                break :blk error.ParseFailed;
            },
        },
        .exp_digit => switch (cls) {
            .digit => .exp_digit,
            .underscore => .exp_underscore,
            else => blk: {
                try self.raiseError(.invalid_float, "invalid character in exponent");
                break :blk error.ParseFailed;
            },
        },
        .exp_underscore => switch (cls) {
            .digit => .exp_digit,
            else => blk: {
                try self.raiseError(.invalid_float, "underscore must be between digits");
                break :blk error.ParseFailed;
            },
        },
        .done => blk: {
            try self.raiseError(.invalid_float, "trailing characters on float");
            break :blk error.ParseFailed;
        },
    };
}
```

Maximum nesting depth: **2** (function → switch → switch). Down from 7.

- [ ] **Step 5: Build**

Run:

```bash
zig build
```

Expected: success. If Zig complains about `ErrorCode.invalid_float` not existing, use whatever the existing code used — `grep -n "invalid_float\|invalid_number" src/error.zig` and substitute the real name.

- [ ] **Step 6: Run tests**

Run:

```bash
zig build test --summary all
```

Expected: 82/82. If a characterisation test fails, the state machine has a gap; patch the specific transition and re-run. Do NOT change the test.

- [ ] **Step 7: Verify nesting depth**

Open `src/parser/number.zig` in your editor and look at `validateFloatFormat` + `stepFloat`. Neither should have more than 2 levels of brace indentation inside the function body (switch-inside-switch is the deepest). If you still see deep nesting, you probably kept some of the old code — re-read Step 4.

---

## Task 12: Commit the number extraction

**Files:** all changes since Task 9.

- [ ] **Step 1: Review diff**

Run:

```bash
git status
git diff --stat
```

- [ ] **Step 2: Stage and commit**

Run:

```bash
git add src/parser/number.zig src/parser.zig
git commit -m "refactor(parser): close Q-6 — extract number module

Moves parseInteger/parseFloat/validateIntegerFormat/validateFloatFormat
out of parser.zig into src/parser/number.zig.

Rewrites validateFloatFormat as a flat state machine (classify-then-step)
over a small FloatClass/FloatState pair. Nesting depth drops from 7 to 2.
All prior behaviour preserved; 11 new characterisation tests pin the
accept/reject boundary (leading/trailing/adjacent underscores, empty
mantissa/exponent, double exponent sign).

Test count: 71 -> 82."
```

- [ ] **Step 3: Verify**

Run:

```bash
git log --oneline -1
zig build test --summary all
```

Expected: new commit at HEAD, 82/82 passing.

---

## Task 13: Scaffold `src/parser/string.zig` and move the six decoders

**Files:**

- Create: `src/parser/string.zig`
- Modify: `src/parser.zig`

- [ ] **Step 1: Create the skeleton**

Create `src/parser/string.zig`:

```zig
// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! TOML string decoding (basic, literal, multi-line variants, escapes).

const std = @import("std");
const Allocator = std.mem.Allocator;
const err = @import("../error.zig");
const ErrorCode = err.ErrorCode;

const Parser = @import("../parser.zig").Parser;

pub fn decodeBasicString(self: *Parser, alloc: Allocator, raw: []const u8) ![]const u8 {
    _ = self;
    _ = alloc;
    _ = raw;
    @panic("string.decodeBasicString: not yet moved");
}

pub fn decodeLiteralString(self: *Parser, raw: []const u8) []const u8 {
    _ = self;
    _ = raw;
    @panic("string.decodeLiteralString: not yet moved");
}

pub fn decodeMultilineBasicString(self: *Parser, alloc: Allocator, raw: []const u8) ![]const u8 {
    _ = self;
    _ = alloc;
    _ = raw;
    @panic("string.decodeMultilineBasicString: not yet moved");
}

pub fn decodeMultilineLiteralString(self: *Parser, raw: []const u8) []const u8 {
    _ = self;
    _ = raw;
    @panic("string.decodeMultilineLiteralString: not yet moved");
}

pub fn decodeEscapes(self: *Parser, alloc: Allocator, content: []const u8) ![]const u8 {
    _ = self;
    _ = alloc;
    _ = content;
    @panic("string.decodeEscapes: not yet moved");
}

pub fn decodeEscapeChar(
    self: *Parser,
    alloc: Allocator,
    content: []const u8,
    i: *usize,
    result: *std.ArrayList(u8),
) !void {
    _ = self;
    _ = alloc;
    _ = content;
    _ = i;
    _ = result;
    @panic("string.decodeEscapeChar: not yet moved");
}
```

- [ ] **Step 2: Add the import in `parser.zig`**

After the `number` import, add:

```zig
const string = @import("parser/string.zig");
```

- [ ] **Step 3: Read each function body**

Run:

```bash
sed -n '827,832p' src/parser.zig      # decodeBasicString (tiny wrapper)
sed -n '833,838p' src/parser.zig      # decodeLiteralString (tiny wrapper)
sed -n '839,864p' src/parser.zig      # decodeMultilineBasicString
sed -n '865,881p' src/parser.zig      # decodeMultilineLiteralString
sed -n '882,947p' src/parser.zig      # decodeEscapes
sed -n '948,1029p' src/parser.zig     # decodeEscapeChar
```

- [ ] **Step 4: Paste each body into `string.zig`, replacing the stubs**

Verbatim copy.

- [ ] **Step 5: Replace each body in `parser.zig` with a delegate**

```zig
fn decodeBasicString(self: *Parser, alloc: Allocator, raw: []const u8) ![]const u8 {
    return string.decodeBasicString(self, alloc, raw);
}

fn decodeLiteralString(self: *Parser, raw: []const u8) []const u8 {
    return string.decodeLiteralString(self, raw);
}

fn decodeMultilineBasicString(self: *Parser, alloc: Allocator, raw: []const u8) ![]const u8 {
    return string.decodeMultilineBasicString(self, alloc, raw);
}

fn decodeMultilineLiteralString(self: *Parser, raw: []const u8) []const u8 {
    return string.decodeMultilineLiteralString(self, raw);
}

fn decodeEscapes(self: *Parser, alloc: Allocator, content: []const u8) ![]const u8 {
    return string.decodeEscapes(self, alloc, content);
}

fn decodeEscapeChar(
    self: *Parser,
    alloc: Allocator,
    content: []const u8,
    i: *usize,
    result: *std.ArrayList(u8),
) !void {
    return string.decodeEscapeChar(self, alloc, content, i, result);
}
```

- [ ] **Step 6: Build**

Run:

```bash
zig build
```

Expected: success.

- [ ] **Step 7: Run tests**

Run:

```bash
zig build test --summary all
```

Expected: 82/82.

---

## Task 14: Commit the string extraction

**Files:** all changes since Task 12.

- [ ] **Step 1: Review diff**

Run:

```bash
git status
git diff --stat
```

- [ ] **Step 2: Stage and commit**

Run:

```bash
git add src/parser/string.zig src/parser.zig
git commit -m "refactor(parser): extract string module

Moves decodeBasicString/decodeLiteralString/decodeMultilineBasicString/
decodeMultilineLiteralString/decodeEscapes/decodeEscapeChar out of
parser.zig into src/parser/string.zig.

Pure code move; behaviour and public API unchanged. Test count still 82/82."
```

- [ ] **Step 3: Verify**

Run:

```bash
git log --oneline -1
zig build test --summary all
```

Expected: new commit, 82/82 passing.

---

## Task 15: Split `parseInlineTable` into header/body/validation

**Files:**

- Modify: `src/parser.zig:648-760`

`parseInlineTable` is 112 LOC of mixed concerns: (1) consume the `{` and set up scratch state (header), (2) loop over `key = value` pairs and handle the `,` / `}` tokens (body), (3) enforce v1.0-specific restrictions that v1.1 relaxes (validation). We split into three private methods on `Parser` so each lives in context at once. No new public API.

- [ ] **Step 1: Read the current function**

Run:

```bash
sed -n '648,760p' src/parser.zig
```

Identify three sections:

1. Header: the opening brace, position capture, and scratch-map allocation (roughly the first 15-20 lines).
2. Body: the `while` loop that calls `parseKeyValue` and handles `,` / `}` / newline rules.
3. Validation: the v1.0 restrictions enforced after the body completes — typically `if (self.options.version == .v1_0_0) { ... forbid trailing comma / newline inside / ... }`.

- [ ] **Step 2: Write failing characterisation tests**

These tests encode the current behaviour so the split cannot change semantics silently. Append to `src/parser.zig` (near the existing tests at the bottom of the file, or to the test suite that lives next to `parseInlineTable` if there is one):

```zig
test "parseInlineTable: v1.0 rejects trailing comma" {
    const src = "t = { a = 1, }";
    const alloc = std.testing.allocator;
    var doc = Parser.parseString(alloc, src, .{ .version = .v1_0_0 }) catch |e| {
        try std.testing.expectEqual(error.ParseFailed, e);
        return;
    };
    defer doc.deinit();
    return error.TestExpectedError;
}

test "parseInlineTable: v1.1 accepts trailing comma" {
    const src = "t = { a = 1, }";
    const alloc = std.testing.allocator;
    var doc = try Parser.parseString(alloc, src, .{ .version = .v1_1_0 });
    defer doc.deinit();
}

test "parseInlineTable: v1.0 rejects newline inside" {
    const src = "t = { a = 1,\n  b = 2 }";
    const alloc = std.testing.allocator;
    var doc = Parser.parseString(alloc, src, .{ .version = .v1_0_0 }) catch |e| {
        try std.testing.expectEqual(error.ParseFailed, e);
        return;
    };
    defer doc.deinit();
    return error.TestExpectedError;
}

test "parseInlineTable: v1.1 accepts newline inside" {
    const src = "t = { a = 1,\n  b = 2 }";
    const alloc = std.testing.allocator;
    var doc = try Parser.parseString(alloc, src, .{ .version = .v1_1_0 });
    defer doc.deinit();
}
```

If `Parser.parseString` is not the top-level entry in your tree (check with `grep -n "pub fn parseString\|pub fn parse" src/toml.zig src/parser.zig`), use whatever the existing tests use.

- [ ] **Step 3: Run the new tests to confirm they pass against the current code**

Run:

```bash
zig build test --summary all
```

Expected: 82 + 4 = 86/86. If any of the four fails against the current unsplit code, it means the old behaviour already has a bug; fix behaviour in Step 5, not the test.

- [ ] **Step 4: Declare the three helper method signatures**

Still inside `Parser`, above the current `parseInlineTable`, add three method declarations (empty bodies for now). The signatures depend on what scratch state flows between the three phases — most commonly an opening-`{` `Position` and a `*Value` pointer to the table under construction.

```zig
const InlineTableHeader = struct {
    open_pos: Position,
    table: Value,
};

fn parseInlineTableHeader(self: *Parser, alloc: Allocator) ParseValueError!InlineTableHeader {
    _ = self;
    _ = alloc;
    @panic("parseInlineTableHeader: not yet implemented");
}

fn parseInlineTableBody(
    self: *Parser,
    alloc: Allocator,
    header: *InlineTableHeader,
) ParseValueError!void {
    _ = self;
    _ = alloc;
    _ = header;
    @panic("parseInlineTableBody: not yet implemented");
}

fn validateInlineTableV10Restrictions(
    self: *Parser,
    header: *const InlineTableHeader,
    saw_trailing_comma: bool,
    saw_newline_inside: bool,
) ParseValueError!void {
    _ = self;
    _ = header;
    _ = saw_trailing_comma;
    _ = saw_newline_inside;
    @panic("validateInlineTableV10Restrictions: not yet implemented");
}
```

If the real code needs different scratch fields (e.g. an `ArrayList` of inserted keys to detect dotted-key conflicts, or a `bool is_empty`), extend `InlineTableHeader` to carry them. Drop nothing; every piece of state the original function tracked must appear in the struct or a local.

- [ ] **Step 5: Fill the three helpers by moving code out of `parseInlineTable`**

a. **Header:** the part up to and including the first `{` consumption, plus `Value` initialisation. Returns an `InlineTableHeader`.

b. **Body:** the main loop. Takes `*InlineTableHeader`, mutates `header.table`. Maintains two local flags:

```zig
var saw_trailing_comma: bool = false;
var saw_newline_inside: bool = false;
```

Updates them at the relevant decision points (when consuming `,` and peeking `}`; when skipping a newline token). Returns without performing any v1.0 checks.

c. **Validation:** reads the two flags. In v1.0, rejects:

```zig
if (self.options.version == .v1_0_0) {
    if (saw_trailing_comma) {
        try self.raiseErrorAt(.inline_table_trailing_comma, header.open_pos, "trailing comma in inline table requires TOML 1.1");
        return error.ParseFailed;
    }
    if (saw_newline_inside) {
        try self.raiseErrorAt(.inline_table_newline, header.open_pos, "newline in inline table requires TOML 1.1");
        return error.ParseFailed;
    }
}
```

Use the actual `ErrorCode` names from `src/error.zig` — `grep -n "inline_table" src/error.zig`.

- [ ] **Step 6: Rewrite `parseInlineTable` as a three-step composition**

```zig
fn parseInlineTable(self: *Parser, alloc: Allocator) ParseValueError!Value {
    var header = try self.parseInlineTableHeader(alloc);
    errdefer header.table.deinit(alloc);
    var saw_trailing_comma: bool = false;
    var saw_newline_inside: bool = false;
    try self.parseInlineTableBody(alloc, &header, &saw_trailing_comma, &saw_newline_inside);
    try self.validateInlineTableV10Restrictions(&header, saw_trailing_comma, saw_newline_inside);
    return header.table;
}
```

Note: the two `bool` flags are out-parameters to `parseInlineTableBody`. Update the signature from Step 4 to:

```zig
fn parseInlineTableBody(
    self: *Parser,
    alloc: Allocator,
    header: *InlineTableHeader,
    saw_trailing_comma: *bool,
    saw_newline_inside: *bool,
) ParseValueError!void { ... }
```

and update the empty-body stub to match before filling it.

- [ ] **Step 7: Build**

Run:

```bash
zig build
```

Expected: success. If you get "unused variable" warnings, the errdefer or flags aren't threaded correctly — follow the compiler.

- [ ] **Step 8: Run tests**

Run:

```bash
zig build test --summary all
```

Expected: 86/86. The four inline-table characterisation tests still pass. The full-suite tests still pass.

- [ ] **Step 9: Measure**

Run:

```bash
grep -n "fn parseInlineTable\|fn parseInlineTableHeader\|fn parseInlineTableBody\|fn validateInlineTableV10Restrictions" src/parser.zig
```

Expected: four declarations, each with a focused body ≤ 60 LOC, none individually exceeding 80 LOC.

---

## Task 16: Commit the inline-table split

**Files:** all changes since Task 14.

- [ ] **Step 1: Review diff**

Run:

```bash
git status
git diff --stat
```

- [ ] **Step 2: Stage and commit**

Run:

```bash
git add src/parser.zig
git commit -m "refactor(parser): close Q-7 — split parseInlineTable

Decomposes the 112-LOC parseInlineTable into three private methods:
  - parseInlineTableHeader     (open-brace + scratch state setup)
  - parseInlineTableBody       (the key=value,... loop)
  - validateInlineTableV10Restrictions
                               (trailing-comma + newline rules
                                that only apply to TOML 1.0)

parseInlineTable itself becomes a four-line composition. Adds four
characterisation tests pinning the v1.0 vs v1.1 accept/reject behaviour
on trailing commas and embedded newlines.

Test count: 82 -> 86."
```

- [ ] **Step 3: Verify**

Run:

```bash
git log --oneline -1
zig build test --summary all
```

Expected: new commit, 86/86 passing.

---

## Task 17: Verify parser.zig size target and close Q-17

**Files:**

- Modify: `src/parser.zig` (optional cleanup of any leftover imports or dead prototypes)

- [ ] **Step 1: Measure post-split parser.zig**

Run:

```bash
wc -l src/parser.zig src/parser/datetime.zig src/parser/number.zig src/parser/string.zig
```

Expected output shape:

```text
  XXX src/parser.zig
  XXX src/parser/datetime.zig
  XXX src/parser/number.zig
  XXX src/parser/string.zig
 YYYY total
```

Target: `src/parser.zig` **< 800 LOC** (started at 1700). If it's still over 800, find the largest remaining function with:

```bash
awk '/^    (pub )?fn /{name=$0; start=NR} /^    \}/{if(start){printf "%5d  %s\n", NR-start, name; start=0}}' src/parser.zig | sort -rn | head -10
```

Investigate the largest — if it's an obvious extraction candidate we missed, extract. If it's inherent to dispatch (e.g. `parseValue` is a large switch), leave it.

- [ ] **Step 2: Remove any now-unused imports**

Run:

```bash
zig build 2>&1 | grep -i "unused\|imported but not used"
```

Expected: no output. If there are unused imports (e.g. a helper module you no longer delegate to), delete those lines.

- [ ] **Step 3: Confirm no broken delegates**

Run:

```bash
grep -n "return datetime\.\|return number\.\|return string\." src/parser.zig
```

Expected: every delegate from Tasks 3-14 is present. If a delegate is missing, a direct caller inside `parser.zig` is bypassing the extracted module — that's fine functionally, but the call site should use the extracted module directly rather than a stale in-file definition.

- [ ] **Step 4: Delete the scratch baseline file**

Run:

```bash
rm -f .plan-baseline.txt
```

- [ ] **Step 5: Final full test run**

Run:

```bash
zig build test --summary all
```

Expected: 86/86 passing. Absolutely no regressions.

- [ ] **Step 6: Stage and commit**

Run:

```bash
git add src/parser.zig
git commit --allow-empty -m "refactor(parser): close Q-17 — parser module split complete

src/parser.zig shrinks from 1700 LOC to under 800 LOC. Responsibility
is now:
  - src/parser.zig           dispatch, document/value/array, inline
                             table, key-value, table-path resolution
  - src/parser/datetime.zig  RFC 3339 datetime family
  - src/parser/number.zig    integer + float
  - src/parser/string.zig    basic/literal/multi-line decoders + escapes

Q-5, Q-6, Q-7, Q-17 are closed. Public API unchanged, 86/86 tests green."
```

If `git diff --stat` already shows the previous commits cleaned everything up and there is nothing left to stage, use `--allow-empty` so the milestone commit still lands as a marker. Otherwise drop the flag.

- [ ] **Step 7: Verify final state**

Run:

```bash
git log --oneline -5
wc -l src/parser.zig
zig build test --summary all
```

Expected: four refactor commits (Tasks 9, 12, 14, 16) plus the Task 17 marker; `parser.zig` < 800 LOC; 86/86 passing.

---

## Task 18: Update `docs/ARCHITECTURE.md`

**Files:**

- Modify: `docs/ARCHITECTURE.md` (the file-structure / source-layout section)

- [ ] **Step 1: Locate the source layout section**

Run:

```bash
grep -n "src/parser.zig\|### Source\|## File\|## Source" docs/ARCHITECTURE.md
```

- [ ] **Step 2: Update the listing**

Edit the file-structure section. Replace the old line for `src/parser.zig` with the five-line block:

```text
src/
  parser.zig              Dispatch: parseDocument, parseValue, parseArray,
                          parseInlineTable (header/body/validation), key-value,
                          table-path resolution.
  parser/
    datetime.zig          RFC 3339 offset/local date/time parsers with shared
                          parseDateParts / parseTimeParts / parseOffset helpers
                          and leap-year / calendar / range validators.
    number.zig            Integer + float parsers; flat state-machine validator
                          for float format (classifyFloatByte + stepFloat).
    string.zig            Basic/literal/multi-line string decoders plus
                          escape-sequence handling.
```

Adjust indentation to match the existing style in `ARCHITECTURE.md` (2-space vs 4-space, tree-drawing characters if any). Use the Read tool first to see the existing convention.

- [ ] **Step 3: Cross-check against the repo**

Run:

```bash
ls src/parser/
```

Expected: `datetime.zig  number.zig  string.zig`. If any is missing, a previous task was skipped — go fix it.

- [ ] **Step 4: Commit**

Run:

```bash
git add docs/ARCHITECTURE.md
git commit -m "docs(architecture): reflect parser module split

Documents the new src/parser/ submodules (datetime, number, string)
introduced by the Q-5/Q-6/Q-7/Q-17 refactor."
```

- [ ] **Step 5: Final verification**

Run:

```bash
git log --oneline -7
zig build test --summary all
wc -l src/parser.zig src/parser/datetime.zig src/parser/number.zig src/parser/string.zig
```

Expected:

- Six commits since baseline (Tasks 9, 12, 14, 16, 17, 18)
- 86/86 passing
- `src/parser.zig` < 800 LOC
- Three new submodules each exist and are non-empty

---

## Rollback instructions (if anything goes wrong mid-plan)

If a task breaks the build or test count and you cannot repair within 15 minutes, roll back to the last green commit:

```bash
git log --oneline -10       # find the last green commit (one of Tasks 9, 12, 14, 16)
git reset --hard <sha>      # DESTRUCTIVE — only run if the working tree has nothing you want to keep
```

Never skip a failing test to "make the suite green." The invariant is 64/64 → 71/71 → 82/82 → 86/86 growing monotonically. A drop is a real regression; diagnose before moving on.

---

## Self-Review (executed by author before handoff)

**Spec coverage:**

- Q-5 (datetime family) — Tasks 2-9 extract the module; Task 8 specifically collapses the 4 parsers via shared helpers.
- Q-6 (integer/float) — Tasks 10-12 extract and flatten; Task 11's state machine is the direct answer to "7-level nesting."
- Q-7 (parseInlineTable) — Tasks 15-16 split header/body/validation.
- Q-17 (1636→<800 LOC) — Task 17 measures and closes; the three extracted modules account for the reduction.

**Placeholder scan:** no `TODO` / `fill in` / "similar to Task N" / "add error handling" without code. Every code step contains the code. Every run step contains the exact command and expected output.

**Type consistency:**

- `InlineTableHeader` is introduced in Task 15 Step 4 and used consistently through Step 6.
- `DateParts` / `TimeParts` / `OffsetParts` introduced in Task 8 Step 1 and used in the refactor Steps 8-11.
- `FloatClass` / `FloatState` / `classifyFloatByte` / `stepFloat` introduced together in Task 11 Step 4.
- Delegate wrapper signatures in `parser.zig` match the module signatures (both take `*Parser` as first arg, same trailing params).
- `ErrorCode` tag names (`invalid_date`, `invalid_time`, `invalid_offset`, `invalid_datetime`, `invalid_float`, `inline_table_trailing_comma`, `inline_table_newline`) are placeholders pinned to the names the engineer should verify via `grep` on `src/error.zig` in Task 11 Step 5 and Task 15 Step 5 — the grep instruction is explicit, not aspirational.

**Test-count invariant:** 64 → 64 (Task 7 end) → 71 (Task 8 end) → 82 (Task 11 end) → 86 (Task 15 end). Every commit task states the expected count.

**Commit cadence:** four refactor commits + one milestone + one docs commit = six commits. Each bounded by a single green test run.

---

## Execution handoff

Plan complete and saved to `docs/superpowers/plans/2026-04-18-04-parser-module-split.md`. Two execution options:

1. **Subagent-Driven (recommended)** — dispatch a fresh subagent per task, review between tasks, fast iteration.
2. **Inline Execution** — execute tasks in this session using `superpowers:executing-plans`, batch execution with checkpoints.

Which approach?
