# UTF-8 Fusion & Performance Polish Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close three perf/correctness gaps in the TOML parser: (P-8) fuse UTF-8 validation into the lexer so we stop paying for a full pre-pass; (P-10) store array elements by value to remove per-element heap allocation and pointer indirection; (P-11) replace fixed-size stack scratch buffers with arena-scoped growable buffers so legal-but-long inputs parse.

**Architecture:** Three independent but sequenced sub-workstreams committed separately.

- **A. UTF-8 fusion** — add a codepoint-decoding helper in `src/lexer.zig`, call it from `advance()` whenever a high-bit byte is encountered, and remove the pre-pass call at `src/parser.zig:54`. Errors surface at the true byte/line/column of the bad byte.
- **B. Array by-value** — change `Value.Array.items` from `[]*Value` to `[]Value` in `src/value.zig`, return `Value` (not `*Value`) from `parseValue` into array collectors, and update every accessor (`arr.items[i].*` -> `arr.items[i]`) in the parser, tests, examples, and docs. Tables continue to hold `*Value` so mutation via shared references is preserved.
- **C. Scratch buffers** — replace the three fixed arrays in `src/parser.zig` (`clean: [64]u8`, `clean: [128]u8`, `neg_buf: [65]u8`) with `std.ArrayList(u8)` backed by the arena allocator, capped by `self.options.max_bytes`.

**Tech Stack:** Zig 0.15.x (uses `std.ArrayList(T).initCapacity(alloc, n)` unmanaged form and `appendSlice(alloc, ...)` explicit-allocator calls, matching existing parser idioms); `std.unicode.utf8Encode` already used in `decodeBasicString`; `std.testing` for tests; `zig build test` for the full suite.

---

## File Structure

Changes are confined to a small set of files in the existing layout — no new modules.

- `src/lexer.zig` — add `validateUtf8CodePoint` helper and call from `advance()`; UTF-8 validation now lives here (workstream A).
- `src/parser.zig` — remove pre-pass call at line 54 (A); replace three fixed stack buffers in `parseInteger` and `parseFloat` with arena-scoped growable buffers (C); adapt `parseArray`, `parseArrayContents`, `parseNestedArrayFromDoubleBracket` to collect `Value` instead of `*Value` (B). Callers that currently do `existing.array.items[N]` (table-of-arrays machinery around lines 211-242) must continue to get a mutable `*Value` from the tail of an array-of-tables array; we add a small helper.
- `src/value.zig` — change `Array.items` field type from `[]*Value` to `[]Value`; rewrite `arrayAppend` to take `Value` by value; update `createArray` initializer (B).
- `src/json_tagged.zig` — update the `.array` arm's iteration (B).
- `src/toml.zig` — update the doctest-style `test "parse array"` / `test "parse array of tables"` assertions at lines 108-111 and 212-215 (B).
- `tests/accept.zig` — update assertions at lines 213-314 (B).
- `examples/value_types.zig` — update the two `arr.items` loops at lines 193 and 264 (B).
- `docs/API.md` — update the one-line iteration example at line 478 (B).

All commits are scoped to one workstream each so a bisect points at the right slice.

---

## Self-Review Checklist (for the executing agent)

Before opening the PR, run these checks:

1. **Spec coverage:** P-8 (Task 6 commit), P-10 (Task 12 commit), P-11 (Task 16 commit). Confirm each commit exists.
2. **Tests added:** six new tests (Tasks 1, 4a, 4b, 4c, 5, 7, 14).
3. **Pre-pass removed:** `rg 'utf8ValidateSlice' src/parser.zig` returns no hits.
4. **No `[]*Value` remains in `Array`:** `rg '\[\]\*Value' src/value.zig` returns no hits for the `Array.items` field.
5. **No fixed scratch buffers in number parsing:** `rg 'clean: \[64\]u8|clean: \[128\]u8|neg_buf: \[65\]u8' src/parser.zig` returns no hits.
6. Run `zig build test` at the end of every workstream. Must pass.

---

## Workstream A — UTF-8 Fusion (P-8)

### Task 1: Write the failing test for precise UTF-8 error position

**Files:**

- Test: `src/toml.zig` (append a new test block)

- [ ] **Step 1: Add the failing test**

Append this to `src/toml.zig` (just after the existing `test "invalid UTF-8 rejected"` block):

```zig
test "invalid UTF-8 in middle of line reports precise line/column" {
    // Three lines; bad byte is at line 3, column 7 (the 0xff byte).
    // Layout (each '\n' advances line):
    //   "a = 1\n"      line 1
    //   "b = 2\n"      line 2
    //   "c = \"X\xffY\"\n"   line 3, col 7 is \xff
    const input = "a = 1\nb = 2\nc = \"X\xffY\"\n";
    const result = parseWithError(std.testing.allocator, input, .{});
    switch (result) {
        .ok => |*doc| {
            var d = @constCast(doc);
            d.deinit();
            try std.testing.expect(false);
        },
        .err => |e| {
            try std.testing.expectEqual(ErrorCode.InvalidUtf8, e.code);
            try std.testing.expectEqual(@as(u32, 3), e.line);
            try std.testing.expectEqual(@as(u32, 7), e.column);
        },
    }
}
```

- [ ] **Step 2: Run the test and confirm it fails**

Run: `zig build test -Dtest-filter="invalid UTF-8 in middle of line"`

Expected: FAIL. The current implementation runs `utf8ValidateSlice` on the full input before tokenizing, and when it flags the bad byte it constructs the error with `.{}` (a default `Position`), so the reported `line` is 1 and `column` is 1 — not 3/7.

### Task 2: Add `validateUtf8CodePoint` helper in lexer.zig

**Files:**

- Modify: `src/lexer.zig` (add helper near the other free functions near the end of the file — the region around `isDigit`/`isHexDigit` around line 628).

- [ ] **Step 1: Add the helper**

Insert this free function in `src/lexer.zig` right after `isBareKeyChar` (around line 641):

```zig
/// Validate a UTF-8 codepoint that begins at `input[index]` when the
/// leading byte has the high bit set. Returns the byte length of the
/// sequence (2, 3, or 4). Returns `error.InvalidUtf8` for orphan
/// continuation bytes, overlong forms, truncated tails, surrogates, and
/// codepoints above U+10FFFF.
fn validateUtf8CodePoint(input: []const u8, index: usize) !u3 {
    const first = input[index];

    // Leading byte must not be a continuation byte and must not be one
    // of the five-or-more-byte patterns that were never valid UTF-8.
    if (first < 0x80) return 1; // ASCII: caller should not normally hit this.

    // 2-byte: 110xxxxx 10xxxxxx  (U+0080 .. U+07FF)
    if (first & 0xE0 == 0xC0) {
        if (first < 0xC2) return error.InvalidUtf8; // overlong
        if (index + 1 >= input.len) return error.InvalidUtf8;
        const b1 = input[index + 1];
        if (b1 & 0xC0 != 0x80) return error.InvalidUtf8;
        return 2;
    }

    // 3-byte: 1110xxxx 10xxxxxx 10xxxxxx  (U+0800 .. U+FFFF, excluding surrogates)
    if (first & 0xF0 == 0xE0) {
        if (index + 2 >= input.len) return error.InvalidUtf8;
        const b1 = input[index + 1];
        const b2 = input[index + 2];
        if (b1 & 0xC0 != 0x80) return error.InvalidUtf8;
        if (b2 & 0xC0 != 0x80) return error.InvalidUtf8;
        // Reject overlong: E0 80..9F is an overlong encoding of a 2-byte scalar.
        if (first == 0xE0 and b1 < 0xA0) return error.InvalidUtf8;
        // Reject surrogates: ED A0..BF encodes U+D800..U+DFFF.
        if (first == 0xED and b1 >= 0xA0) return error.InvalidUtf8;
        return 3;
    }

    // 4-byte: 11110xxx 10xxxxxx 10xxxxxx 10xxxxxx  (U+10000 .. U+10FFFF)
    if (first & 0xF8 == 0xF0) {
        if (first > 0xF4) return error.InvalidUtf8; // > U+10FFFF
        if (index + 3 >= input.len) return error.InvalidUtf8;
        const b1 = input[index + 1];
        const b2 = input[index + 2];
        const b3 = input[index + 3];
        if (b1 & 0xC0 != 0x80) return error.InvalidUtf8;
        if (b2 & 0xC0 != 0x80) return error.InvalidUtf8;
        if (b3 & 0xC0 != 0x80) return error.InvalidUtf8;
        // Reject overlong: F0 80..8F is an overlong encoding of a 3-byte scalar.
        if (first == 0xF0 and b1 < 0x90) return error.InvalidUtf8;
        // Reject > U+10FFFF: F4 90..BF is above the Unicode range.
        if (first == 0xF4 and b1 >= 0x90) return error.InvalidUtf8;
        return 4;
    }

    // Orphan continuation byte (10xxxxxx) or reserved leading byte (0xF5..0xFF).
    return error.InvalidUtf8;
}
```

- [ ] **Step 2: Compile-check the helper**

Run: `zig build test -Dtest-filter="lexer helpers never run"` (no matching filter — just forces a compile).

Expected: compile succeeds, zero tests run. If you get "ambiguous import" or "unused function" errors, note them and keep going — the helper is wired up in the next step.

### Task 3: Call `validateUtf8CodePoint` from `advance()`

**Files:**

- Modify: `src/lexer.zig:621-625` (the `advance` method body).
- Modify: `src/lexer.zig:59-72` (adjust the `Lexer` struct to add a `utf8_error` flag).

- [ ] **Step 1: Change the `advance` method to detect multibyte and validate**

Replace the existing `advance`:

```zig
    fn advance(self: *Lexer) void {
        if (self.pos.byte_index < self.input.len) {
            self.pos.advance(self.input[self.pos.byte_index]);
        }
    }
```

with this validating version (still `void` — the error is latched on the struct so the many ASCII-only `advance()` call sites don't have to change):

```zig
    fn advance(self: *Lexer) void {
        if (self.pos.byte_index >= self.input.len) return;
        const b = self.input[self.pos.byte_index];
        if (b < 0x80) {
            self.pos.advance(b);
            return;
        }
        // Multibyte UTF-8 start byte: validate the full sequence at the
        // current byte. On error, stash the diagnostic and leave `pos`
        // at the offending byte so the caller surfaces line/col there.
        const len = validateUtf8CodePoint(self.input, self.pos.byte_index) catch {
            self.parse_error = err.makeError(.InvalidUtf8, self.pos, "invalid UTF-8 sequence");
            self.utf8_error = true;
            return;
        };
        // Valid sequence: consume all `len` bytes. Position counts the
        // codepoint as one column; byte_index still advances by len.
        self.pos.byte_index += len;
        self.pos.column += 1;
    }
```

- [ ] **Step 2: Add the `utf8_error` flag to the Lexer struct**

In `src/lexer.zig`, update the struct definition (around line 59-63) to add a flag:

```zig
pub const Lexer = struct {
    input: []const u8,
    pos: Position,
    version: TomlVersion,
    parse_error: ?ParseError,
    utf8_error: bool,
```

Update `init` (around line 65-72):

```zig
    pub fn init(input: []const u8, version: TomlVersion) Lexer {
        return .{
            .input = input,
            .pos = .{},
            .version = version,
            .parse_error = null,
            .utf8_error = false,
        };
    }
```

- [ ] **Step 3: Propagate the UTF-8 error out of `next`**

Add a `tryAdvance` helper to `Lexer` (place right before `advance`):

```zig
    fn tryAdvance(self: *Lexer) !void {
        self.advance();
        if (self.utf8_error) return error.ParseFailed;
    }
```

Then, inside the scanners that can consume non-ASCII bytes — `lexBasicString`, `lexMultilineBasicString`, `lexLiteralString`, `lexMultilineLiteralString`, `lexComment`, `lexBareKeyOrBool` — replace every `self.advance();` that consumes a user-supplied character with `try self.tryAdvance();`. The ASCII-only structural paths in `next` (`=`, `,`, `.`, `{`, `}`, `[`, `]`, newlines) do not need the `try`.

- [ ] **Step 4: Run the precise-position test again**

Run: `zig build test -Dtest-filter="invalid UTF-8 in middle of line"`

Expected: PASS. The test now reports `line=3, column=7`.

### Task 4: Remove the pre-pass in `parser.zig`

**Files:**

- Modify: `src/parser.zig:52-57` (the `parse` entry).

- [ ] **Step 1: Remove the pre-pass**

Replace:

```zig
    pub fn parse(self: *Parser) !Document {
        // UTF-8 validation
        if (!std.unicode.utf8ValidateSlice(self.input)) {
            self.parse_error = err.makeError(.InvalidUtf8, .{}, "input is not valid UTF-8");
            return error.ParseFailed;
        }

        // Size limit check
```

with:

```zig
    pub fn parse(self: *Parser) !Document {
        // UTF-8 validation is now fused into Lexer.advance() so we avoid
        // a full second pass over the input. See src/lexer.zig:advance.

        // Size limit check
```

- [ ] **Step 2: Propagate the lexer's UTF-8 diagnostic into the parser error**

`Parser.nextToken` (search the file for `fn nextToken`) catches the lexer's error and mirrors `self.lexer.parse_error` into `self.parse_error`. Confirm it already handles `.InvalidUtf8` (the lexer stashes it in the same field). If the mirror is not present, add this at the catch site of `nextToken`:

```zig
        return self.lexer.next() catch |e| {
            if (self.lexer.parse_error) |lex_err| {
                self.parse_error = lex_err;
            }
            return e;
        };
```

- [ ] **Step 3: Run the full test suite**

Run: `zig build test`

Expected: all existing tests still pass. The pre-existing `test "invalid UTF-8 rejected"` at `src/toml.zig:221` keeps passing — it now gets the error from the lexer, not the pre-pass.

### Task 4a: Positive test — 2-byte sequence in basic string

**Files:**

- Test: `src/toml.zig` (append)

- [ ] **Step 1: Write the test**

Append to `src/toml.zig`:

```zig
test "2-byte UTF-8 in basic string parses" {
    const input = "name = \"caf\u{00E9}\"\n"; // é = 0xC3 0xA9
    var doc = try parse(std.testing.allocator, input, .{});
    defer doc.deinit();
    const name = doc.root.get("name") orelse unreachable;
    try std.testing.expectEqualStrings("caf\u{00E9}", name.string);
}
```

- [ ] **Step 2: Run the test**

Run: `zig build test -Dtest-filter="2-byte UTF-8"`

Expected: PASS.

### Task 4b: Positive test — 3-byte sequence in literal string

**Files:**

- Test: `src/toml.zig` (append)

- [ ] **Step 1: Write the test**

```zig
test "3-byte UTF-8 in literal string parses" {
    const input = "sym = 'price \u{20AC}'\n"; // € = 0xE2 0x82 0xAC
    var doc = try parse(std.testing.allocator, input, .{});
    defer doc.deinit();
    const sym = doc.root.get("sym") orelse unreachable;
    try std.testing.expectEqualStrings("price \u{20AC}", sym.string);
}
```

- [ ] **Step 2: Run the test**

Run: `zig build test -Dtest-filter="3-byte UTF-8"`

Expected: PASS.

### Task 4c: Positive test — 4-byte sequence in multiline basic string

**Files:**

- Test: `src/toml.zig` (append)

- [ ] **Step 1: Write the test**

```zig
test "4-byte UTF-8 in multiline basic string parses" {
    // 𝄞 (MUSICAL SYMBOL G CLEF) = U+1D11E = F0 9D 84 9E
    const input = "note = \"\"\"clef \u{1D11E}\"\"\"\n";
    var doc = try parse(std.testing.allocator, input, .{});
    defer doc.deinit();
    const note = doc.root.get("note") orelse unreachable;
    try std.testing.expectEqualStrings("clef \u{1D11E}", note.string);
}
```

- [ ] **Step 2: Run the test**

Run: `zig build test -Dtest-filter="4-byte UTF-8"`

Expected: PASS.

### Task 5: Negative tests — orphan, overlong, invalid start byte

**Files:**

- Test: `src/toml.zig` (append)

- [ ] **Step 1: Write three negative tests**

```zig
test "orphan UTF-8 continuation byte rejected with position" {
    // 0x80 is a continuation byte; it may not appear as a leading byte.
    const input = "k = \"\x80\"\n";
    const result = parseWithError(std.testing.allocator, input, .{});
    switch (result) {
        .ok => |*doc| {
            var d = @constCast(doc);
            d.deinit();
            try std.testing.expect(false);
        },
        .err => |e| {
            try std.testing.expectEqual(ErrorCode.InvalidUtf8, e.code);
            try std.testing.expectEqual(@as(u32, 1), e.line);
            // Column 6: k, space, =, space, ", \x80
            try std.testing.expectEqual(@as(u32, 6), e.column);
        },
    }
}

test "overlong UTF-8 rejected" {
    // 0xC0 0xAF is an overlong encoding of '/' (U+002F).
    const input = "k = \"\xC0\xAF\"\n";
    const result = parseWithError(std.testing.allocator, input, .{});
    switch (result) {
        .ok => |*doc| {
            var d = @constCast(doc);
            d.deinit();
            try std.testing.expect(false);
        },
        .err => |e| try std.testing.expectEqual(ErrorCode.InvalidUtf8, e.code),
    }
}

test "invalid UTF-8 start byte rejected" {
    // 0xFE / 0xFF are never valid UTF-8 start bytes.
    const input = "k = \"\xFE\xFF\"\n";
    const result = parseWithError(std.testing.allocator, input, .{});
    switch (result) {
        .ok => |*doc| {
            var d = @constCast(doc);
            d.deinit();
            try std.testing.expect(false);
        },
        .err => |e| try std.testing.expectEqual(ErrorCode.InvalidUtf8, e.code),
    }
}
```

- [ ] **Step 2: Run all three**

Run: `zig build test -Dtest-filter="UTF-8"`

Expected: PASS for each.

### Task 6: Commit workstream A

- [ ] **Step 1: Run the whole suite once more**

Run: `zig build test`

Expected: all pass.

- [ ] **Step 2: Stage and commit**

```bash
git add src/lexer.zig src/parser.zig src/toml.zig
git commit -m "perf(lexer): close P-8 — fuse UTF-8 validation into lexer

Validate multibyte UTF-8 sequences inside Lexer.advance() at the exact
byte that fails, instead of running std.unicode.utf8ValidateSlice across
the entire input before any tokenization. Errors now carry the real
line and column of the offending byte.

- Add validateUtf8CodePoint helper (2/3/4-byte forms, overlong, surrogate,
  range, truncation, orphan-continuation checks).
- Hook into advance() via a utf8_error flag and a tryAdvance helper that
  surfaces the diagnostic through the existing error plumbing.
- Remove the utf8ValidateSlice pre-pass from Parser.parse.
- Add precise-position regression test, three positive tests (2-, 3-,
  4-byte sequences), three negative tests (orphan, overlong, bad start)."
```

- [ ] **Step 3: Verify**

Run: `git log -1 --stat`

Expected: commit appears with the files above.

---

## Workstream B — Array By-Value (P-10)

> **Heads up:** this workstream touches the hot path of array construction. Do each step carefully — the compiler will loudly complain about every stale `items[i].*` dereference so lean on it. Tables still hold `*Value`; only `Array.items` changes from `[]*Value` to `[]Value`.

### Task 7: Write the failing test for by-value access

**Files:**

- Test: `src/toml.zig` (append)

- [ ] **Step 1: Add a test that exercises the new API shape**

```zig
test "array items are stored by value" {
    const input = "arr = [10, 20, 30, 40, 50]\n";
    var doc = try parse(std.testing.allocator, input, .{});
    defer doc.deinit();

    const arr = doc.root.get("arr") orelse unreachable;
    try std.testing.expectEqual(@as(usize, 5), arr.array.items.len);

    // By-value access: no `.*` dereference required.
    try std.testing.expectEqual(@as(i64, 10), arr.array.items[0].integer);
    try std.testing.expectEqual(@as(i64, 50), arr.array.items[4].integer);

    // Type check: element type must not be a pointer.
    const Elem = @TypeOf(arr.array.items[0]);
    try std.testing.expect(@typeInfo(Elem) != .pointer);
}
```

- [ ] **Step 2: Run and confirm it fails**

Run: `zig build test -Dtest-filter="array items are stored by value"`

Expected: FAIL — compile error on the `@typeInfo(Elem) != .pointer` check because `items[0]` is currently a `*Value`. That is the failure we want.

### Task 8: Change `Array.items` to `[]Value` and update `value.zig` internals

**Files:**

- Modify: `src/value.zig:166-169` (`Array` definition).
- Modify: `src/value.zig:232-236` (`createArray`).
- Modify: `src/value.zig:297-306` (`arrayAppend`).

- [ ] **Step 1: Change the Array struct**

Replace:

```zig
    pub const Array = struct {
        items: []*Value,
        is_static: bool = false, // true if defined as [] syntax, not [[]]
    };
```

with:

```zig
    pub const Array = struct {
        items: []Value,
        is_static: bool = false, // true if defined as [] syntax, not [[]]
    };
```

- [ ] **Step 2: Update `createArray`**

Replace:

```zig
pub fn createArray(alloc: Allocator) !*Value {
    const val = try alloc.create(Value);
    val.* = .{ .array = .{ .items = &.{} } };
    return val;
}
```

with (no behavioral change — `&[_]Value{}` is the empty-slice sentinel for the new element type):

```zig
pub fn createArray(alloc: Allocator) !*Value {
    const val = try alloc.create(Value);
    val.* = .{ .array = .{ .items = &[_]Value{} } };
    return val;
}
```

- [ ] **Step 3: Rewrite `arrayAppend` to take a `Value`, not `*Value`**

Replace the whole function:

```zig
pub fn arrayAppend(alloc: Allocator, array: *Value, value: *Value) !void {
    std.debug.assert(array.* == .array);
    const a = &array.array;

    var new_items = try alloc.alloc(*Value, a.items.len + 1);
    @memcpy(new_items[0..a.items.len], a.items);
    new_items[a.items.len] = value;
    a.items = new_items;
}
```

with:

```zig
pub fn arrayAppend(alloc: Allocator, array: *Value, value: Value) !void {
    std.debug.assert(array.* == .array);
    const a = &array.array;

    var new_items = try alloc.alloc(Value, a.items.len + 1);
    @memcpy(new_items[0..a.items.len], a.items);
    new_items[a.items.len] = value;
    a.items = new_items;
}

/// Append a freshly-created `*Value` to an array of tables, returning a
/// pointer to the element as stored inside the array (so the caller may
/// mutate its table contents in place). The input pointer's pointee is
/// shallow-copied into the array; the original `*Value` allocation is
/// now redundant and will be freed with the arena, which is fine.
pub fn arrayAppendTable(alloc: Allocator, array: *Value, table: *Value) !*Value {
    std.debug.assert(array.* == .array);
    std.debug.assert(table.* == .table);
    const a = &array.array;

    var new_items = try alloc.alloc(Value, a.items.len + 1);
    @memcpy(new_items[0..a.items.len], a.items);
    new_items[a.items.len] = table.*;
    a.items = new_items;
    return &a.items[a.items.len - 1];
}
```

- [ ] **Step 4: Try to compile**

Run: `zig build test`

Expected: FAIL with many type errors across `src/parser.zig`, `src/json_tagged.zig`, `src/toml.zig`, `tests/accept.zig`, and `examples/value_types.zig`. That's fine — we fix each in the next tasks.

### Task 9: Update `src/parser.zig` array construction and access

**Files:**

- Modify: `src/parser.zig:484-536` (`parseArray`)
- Modify: `src/parser.zig:539-596` (`parseNestedArrayFromDoubleBracket`)
- Modify: `src/parser.zig:599-645` (`parseArrayContents`)
- Modify: `src/parser.zig:183` and `src/parser.zig:242` (array-of-tables `arrayAppend` call sites)
- Modify: `src/parser.zig:211-220` (array-of-tables tail access)

- [ ] **Step 1: In `parseArray`, collect `Value` instead of `*Value`**

Find (line ~496):

```zig
        var items: std.ArrayList(*Value) = try .initCapacity(alloc, 16);
```

Replace with:

```zig
        var items: std.ArrayList(Value) = try .initCapacity(alloc, 16);
```

Find (line ~502):

```zig
            const item = try self.parseValue(alloc);
            try items.append(alloc, item);
```

Replace with:

```zig
            const item_ptr = try self.parseValue(alloc);
            try items.append(alloc, item_ptr.*);
```

(We dereference once here; the original `*Value` allocation is arena-owned and will be freed with the document. Leaving the extra `Value` cell there costs ~32B per array element during parsing only, and disappears when the arena resets.)

The `toOwnedSlice(alloc)` call at line ~536 stays as-is — it now returns `[]Value`.

- [ ] **Step 2: Apply the same two changes in `parseArrayContents`**

Lines ~606 and ~611:

```zig
        var items: std.ArrayList(Value) = try .initCapacity(alloc, 16);
```

```zig
            const item_ptr = try self.parseValue(alloc);
            try items.append(alloc, item_ptr.*);
```

- [ ] **Step 3: Apply the same in `parseNestedArrayFromDoubleBracket`**

Lines ~548, ~552-553, and ~571-572:

```zig
        var outer_items: std.ArrayList(Value) = try .initCapacity(alloc, 16);

        // Parse the inner array (we're already "inside" it after consuming [[)
        const inner_array_val = try self.parseArrayContents(alloc);
        try outer_items.append(alloc, inner_array_val);
```

Note: drop the `alloc.create(Value)` — we now store the inner array `Value` directly.

And:

```zig
            const item_ptr = try self.parseValue(alloc);
            try outer_items.append(alloc, item_ptr.*);
```

- [ ] **Step 4: Update the array-of-tables paths at lines 183 and 242**

Replace (line ~183):

```zig
                        try val.arrayAppend(alloc, existing, new_table);
```

with:

```zig
                        _ = try val.arrayAppendTable(alloc, existing, new_table);
```

Replace (line ~242):

```zig
                    try val.arrayAppend(alloc, arr, new_table);
```

with:

```zig
                    _ = try val.arrayAppendTable(alloc, arr, new_table);
```

- [ ] **Step 5: Update array-of-tables tail access at lines 211-220**

Find:

```zig
                        if (existing.array.items.len == 0) {
```

Leave that intact. Find:

```zig
                        current = existing.array.items[existing.array.items.len - 1];
```

`current` here is a `*Value` pointing into the array tail; now that the array stores `Value` by value, take the address of the in-place cell:

```zig
                        current = &existing.array.items[existing.array.items.len - 1];
```

- [ ] **Step 6: Build and triage remaining errors**

Run: `zig build test`

Expected: compile errors only in `src/json_tagged.zig`, `src/toml.zig`, `tests/accept.zig`, `examples/value_types.zig` (and maybe `docs/API.md` code fences). Parser should now compile clean.

### Task 10: Update `src/json_tagged.zig`

**Files:**

- Modify: `src/json_tagged.zig:59-61`

- [ ] **Step 1: Update the array arm**

Read the existing `.array => |a| { ... for (a.items, 0..) |item, i| { ... } }` body first. With `[]Value`, `item` is a `Value` (not `*Value`). Replace any `item.*` with `item`. If the body recurses into a helper that wants `*const Value`, pass `&a.items[i]` instead of `item` (loop captures are not addressable in Zig, but the underlying slice element is).

Exact replacement pattern (adapt to the surrounding framing):

```zig
        .array => |a| {
            // preserve whatever framing this arm wrote before
            for (a.items, 0..) |_, i| {
                try printValue(writer, &a.items[i]);
                // preserve any separator logic that was here
            }
        },
```

- [ ] **Step 2: Compile**

Run: `zig build test 2>&1 | head -30`

Expected: fewer errors; this file should now compile.

### Task 11: Update tests and examples

**Files:**

- Modify: `src/toml.zig:108-111` and `:212-215`
- Modify: `tests/accept.zig:213-314`
- Modify: `examples/value_types.zig:193` and `:264`
- Modify: `docs/API.md:478`

- [ ] **Step 1: Update `src/toml.zig`**

Lines 108-111 already use `arr.array.items[N].integer` (no `.*`), so they remain valid after the switch.

Lines 212-215:

```zig
    const hammer = products.array.items[0].get("name") orelse unreachable;
    const nail = products.array.items[1].get("name") orelse unreachable;
```

`Value.get` takes `*const Value`. `items[0]` is now a `Value` (not a `*Value`), and Zig auto-references `self` for method calls where the receiver is addressable; a slice element is addressable, so `products.array.items[0].get("name")` continues to work. Leave as-is and verify in Step 5.

- [ ] **Step 2: Update `tests/accept.zig`**

Scan the file:

Run: `grep -n 'items\[.*\]\.\*' tests/accept.zig`

Expected: no matches. If matches exist, drop each trailing `.*`.

- [ ] **Step 3: Update `examples/value_types.zig`**

Lines 193 and 264 use `for (arr.array.items, 0..) |item, i|` and `for (products.array.items, 0..) |product, i|`. With `[]Value`, `item` and `product` are `Value`, not `*Value`. Any `item.*` inside these loops must drop the `.*`. Any `item.get(...)` continues to work because `item` is a value and method calls auto-ref.

Run: `grep -n 'item\.\*\|product\.\*' examples/value_types.zig`

Expected: no matches. If matches, drop the `.*`.

- [ ] **Step 4: Update `docs/API.md`**

Line 478:

```zig
    for (items.array.items) |item| {
```

If the surrounding snippet does `item.*.integer` or similar, drop the `.*`. If it does `item.integer`, leave as-is.

- [ ] **Step 5: Build and test**

Run: `zig build test`

Expected: full suite passes, including the new `test "array items are stored by value"` from Task 7.

### Task 12: Commit workstream B

- [ ] **Step 1: Stage and commit**

```bash
git add src/value.zig src/parser.zig src/json_tagged.zig src/toml.zig tests/accept.zig examples/value_types.zig docs/API.md
git commit -m "perf(value): close P-10 — store array items by value

Change Value.Array.items from []*Value to []Value. Elements now live
contiguously in the array storage instead of one heap allocation per
element reached through a pointer — halves cache misses on dense arrays
and removes the per-element Value allocation.

Tables still hold *Value so mutation via shared references is preserved.
Array-of-tables construction uses a new arrayAppendTable helper that
returns a pointer into the array tail for the parser to continue
populating the table in place.

- Rewrite arrayAppend to take Value by value.
- Add arrayAppendTable for the array-of-tables path in parser.
- Collect std.ArrayList(Value) (not *Value) in parseArray,
  parseArrayContents, parseNestedArrayFromDoubleBracket.
- Drop stale item.* / product.* dereferences in tests, examples, docs.
- Add regression test asserting the element type is not a pointer."
```

- [ ] **Step 2: Verify**

Run: `git log -1 --stat && zig build test`

Expected: commit recorded; tests pass.

---

## Workstream C — Growable Scratch Buffers (P-11)

### Task 13: Write the failing test for a long legal hex integer

**Files:**

- Test: `src/toml.zig` (append)

- [ ] **Step 1: Add the failing test**

```zig
test "hex integer longer than 64 digits parses (fits i64 after underscore strip)" {
    // Legal TOML: underscores are allowed as separators. The cleaned
    // digit count exceeds the old 64-byte scratch buffer, but the
    // numeric value fits in i64. We pad the high order with many zero
    // groups so the raw slice is long but the cleaned value is a
    // representable i64.
    const input =
        "n = 0x0_0_0_0_0_0_0_0_0_0_0_0_0_0_0_0_0_0_0_0_0_0_0_0_0_0_0_0_0_0_0_0_0_0_0_0_0_0_0_0_0_0_0_0_0_0_0_0_0_0_0_0_0_0_0_0_0_0_0_0_0_0_0_0_0_7F_FF_FF_FF_FF_FF_FF_FF\n";
    var doc = try parse(std.testing.allocator, input, .{});
    defer doc.deinit();
    const n = doc.root.get("n") orelse unreachable;
    try std.testing.expectEqual(@as(i64, 0x7FFFFFFFFFFFFFFF), n.integer);
}
```

- [ ] **Step 2: Run and confirm it fails**

Run: `zig build test -Dtest-filter="hex integer longer than 64"`

Expected: FAIL with `InvalidNumber: integer too long` — the fixed `clean: [64]u8` buffer overflows on the underscore-stripped digits.

### Task 14: Replace `clean: [64]u8` + `neg_buf: [65]u8` in `parseInteger`

**Files:**

- Modify: `src/parser.zig:1030-1092` (`parseInteger`)
- Modify: `src/parser.zig:434` (call site in `parseValue`)

- [ ] **Step 1: Change the `parseInteger` signature to accept an allocator**

Replace the signature:

```zig
    fn parseInteger(self: *Parser, raw: []const u8) !i64 {
```

with:

```zig
    fn parseInteger(self: *Parser, alloc: Allocator, raw: []const u8) !i64 {
```

- [ ] **Step 2: Rewrite the underscore-stripping buffer to grow**

Replace the body of `parseInteger` (from `var clean: [64]u8 = undefined;` through the end of the function) with:

```zig
        // Validate integer format
        // (validateIntegerFormat was called above; leave that call in place.)

        // Growable scratch buffer on the parser arena. Cap at max_bytes
        // so a pathological input cannot balloon memory beyond the
        // configured limit.
        var clean: std.ArrayList(u8) = try .initCapacity(alloc, 64);

        var base: u8 = 10;
        var start: usize = 0;
        var negative = false;

        if (raw.len > 0 and raw[0] == '+') {
            start = 1;
        } else if (raw.len > 0 and raw[0] == '-') {
            negative = true;
            start = 1;
        }

        if (raw.len > start + 2) {
            if (raw[start] == '0') {
                if (raw[start + 1] == 'x') {
                    base = 16;
                    start += 2;
                } else if (raw[start + 1] == 'o') {
                    base = 8;
                    start += 2;
                } else if (raw[start + 1] == 'b') {
                    base = 2;
                    start += 2;
                }
            }
        }

        for (raw[start..]) |c| {
            if (c != '_') {
                if (clean.items.len >= self.options.max_bytes) {
                    self.parse_error = err.makeError(.LimitExceeded, self.current.pos, "integer exceeds max_bytes");
                    return error.ParseFailed;
                }
                try clean.append(alloc, c);
            }
        }

        if (negative) {
            // Prepend '-' so parseInt can produce i64.MIN correctly.
            var neg: std.ArrayList(u8) = try .initCapacity(alloc, clean.items.len + 1);
            try neg.append(alloc, '-');
            try neg.appendSlice(alloc, clean.items);
            const result = std.fmt.parseInt(i64, neg.items, base) catch {
                self.parse_error = err.makeError(.InvalidNumber, self.current.pos, "invalid integer");
                return error.ParseFailed;
            };
            return result;
        } else {
            const result = std.fmt.parseInt(i64, clean.items, base) catch {
                self.parse_error = err.makeError(.InvalidNumber, self.current.pos, "invalid integer");
                return error.ParseFailed;
            };
            return result;
        }
```

Re-add the `try self.validateIntegerFormat(raw);` as the first statement of the body — it was at the top of the original function and must continue to run before the cleanup loop.

- [ ] **Step 3: Update the call site in `parseValue`**

In `parseValue` (around line 434), replace:

```zig
                result.* = .{ .integer = try self.parseInteger(self.current.slice(self.input)) };
```

with:

```zig
                result.* = .{ .integer = try self.parseInteger(alloc, self.current.slice(self.input)) };
```

- [ ] **Step 4: Run the long-hex test**

Run: `zig build test -Dtest-filter="hex integer longer than 64"`

Expected: PASS.

### Task 15: Replace `clean: [128]u8` in `parseFloat`

**Files:**

- Modify: `src/parser.zig:1167-1196` (`parseFloat`)
- Modify: `src/parser.zig:438` (call site in `parseValue`)

- [ ] **Step 1: Write a regression test for a long float**

Append to `src/toml.zig`:

```zig
test "float with many underscore separators parses" {
    // Legal TOML float: underscores separate digit groups. Exceeds the
    // old 128-byte scratch buffer when counting raw bytes but yields a
    // representable f64.
    const input =
        "f = 1_000_000_000_000_000_000_000_000_000_000_000_000_000_000_000_000_000_000_000_000_000_000_000_000_000_000_000_000_000_000_000_000_000_000.0\n";
    var doc = try parse(std.testing.allocator, input, .{});
    defer doc.deinit();
    const f = doc.root.get("f") orelse unreachable;
    try std.testing.expect(f.float > 0.0);
}
```

- [ ] **Step 2: Run and confirm it fails**

Run: `zig build test -Dtest-filter="float with many underscore"`

Expected: FAIL with `InvalidNumber: float too long`.

- [ ] **Step 3: Change the `parseFloat` signature**

Replace:

```zig
    fn parseFloat(self: *Parser, raw: []const u8) !f64 {
```

with:

```zig
    fn parseFloat(self: *Parser, alloc: Allocator, raw: []const u8) !f64 {
```

- [ ] **Step 4: Rewrite the scratch buffer section**

Replace the relevant section (from `// Remove underscores` through the return statement):

```zig
        // Remove underscores
        var clean: [128]u8 = undefined;
        var clean_len: usize = 0;

        for (raw) |c| {
            if (c != '_') {
                if (clean_len >= clean.len) {
                    self.parse_error = err.makeError(.InvalidNumber, self.current.pos, "float too long");
                    return error.ParseFailed;
                }
                clean[clean_len] = c;
                clean_len += 1;
            }
        }

        return std.fmt.parseFloat(f64, clean[0..clean_len]) catch {
            self.parse_error = err.makeError(.InvalidNumber, self.current.pos, "invalid float");
            return error.ParseFailed;
        };
```

with:

```zig
        // Growable scratch buffer on the arena, capped at max_bytes.
        var clean: std.ArrayList(u8) = try .initCapacity(alloc, 128);

        for (raw) |c| {
            if (c != '_') {
                if (clean.items.len >= self.options.max_bytes) {
                    self.parse_error = err.makeError(.LimitExceeded, self.current.pos, "float exceeds max_bytes");
                    return error.ParseFailed;
                }
                try clean.append(alloc, c);
            }
        }

        return std.fmt.parseFloat(f64, clean.items) catch {
            self.parse_error = err.makeError(.InvalidNumber, self.current.pos, "invalid float");
            return error.ParseFailed;
        };
```

Leave the leading special-value checks (`inf`, `-inf`, `nan`, `-nan`) and the `try self.validateFloatFormat(raw);` call in place — they sit above the section being replaced.

- [ ] **Step 5: Update the call site in `parseValue`**

In `parseValue` (around line 438), replace:

```zig
                result.* = .{ .float = try self.parseFloat(self.current.slice(self.input)) };
```

with:

```zig
                result.* = .{ .float = try self.parseFloat(alloc, self.current.slice(self.input)) };
```

- [ ] **Step 6: Run the long-float test**

Run: `zig build test -Dtest-filter="float with many underscore"`

Expected: PASS.

- [ ] **Step 7: Run the full suite**

Run: `zig build test`

Expected: all tests pass, including the long-hex-integer test from Task 13 and both UTF-8 workstreams.

### Task 16: Commit workstream C

- [ ] **Step 1: Stage and commit**

```bash
git add src/parser.zig src/toml.zig
git commit -m "fix(parser): close P-11 — grow scratch buffers for large inputs

Replace the three fixed-size stack scratch buffers in parseInteger and
parseFloat with arena-scoped std.ArrayList(u8) buffers capped by the
configured max_bytes limit. Legal inputs that stripped to more than 64
digits (integer) or 128 characters (float) now parse successfully
instead of erroring with 'integer too long' / 'float too long'.

- parseInteger: clean [64]u8 + neg_buf [65]u8 -> growable ArrayList
- parseFloat: clean [128]u8 -> growable ArrayList
- Thread arena alloc through parseInteger and parseFloat signatures.
- Cap growth at self.options.max_bytes so a pathological input still
  hits the configured size limit rather than exhausting memory.
- Add regression tests for a long underscore-separated hex integer
  and a long underscore-separated float."
```

- [ ] **Step 2: Verify**

Run: `git log --oneline -3`

Expected: three new commits — one per workstream — labelled P-8, P-10, P-11.

---

## Final Verification

- [ ] **Step 1: Full test pass**

Run: `zig build test`

Expected: 0 failures.

- [ ] **Step 2: Pre-pass is gone**

Run: `grep -n 'utf8ValidateSlice' src/parser.zig`

Expected: no matches.

- [ ] **Step 3: Array is by-value**

Run: `grep -n '\[\]\*Value' src/value.zig`

Expected: the only match (if any) is on `TableEntry.value: *Value`, not on `Array.items`.

- [ ] **Step 4: Fixed buffers are gone**

Run: `grep -n 'clean: \[64\]u8\|clean: \[128\]u8\|neg_buf: \[65\]u8' src/parser.zig`

Expected: no matches.

- [ ] **Step 5: Quick sanity benchmark (optional)**

If `zig build bench` exists, run it before and after the PR merges into your worktree baseline. Document the delta in the PR description. Expected: measurable reduction on an input dominated by dense numeric arrays (workstream B) and on pure-ASCII inputs (workstream A removes one O(n) pass).

---

## Execution Notes

- All three workstreams are independent at the source level but share the test file (`src/toml.zig`). If you execute them in parallel worktrees, expect a trivial merge conflict at the end of `src/toml.zig` — resolve by concatenating all new tests.
- Workstream B is the highest-blast-radius change because the `Array` type is part of the public API. Do not skip the compiler-driven triage step — let `zig build test` point at every stale `.*` dereference.
- Workstream C depends on `self.options.max_bytes` being set; it is (default 16 MiB at `src/parser.zig:26`). The new tests stay well under that limit.
- Keep commits to the three messages above so `git log --grep="close P-"` surfaces exactly three entries.
