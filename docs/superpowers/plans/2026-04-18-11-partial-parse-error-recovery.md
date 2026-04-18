# Partial-Parse / Error-Recovery Mode Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close GAP-0020 by adding an error-recovery parse mode so tools (editors, linters, IDE integrations) can show every error in a TOML file at once while still retrieving a (possibly partial) `Document` for everything that parsed cleanly.

**Architecture:** Extend `ParseOptions` with a `recovery_mode` field plus a `max_recovery_errors` cap. Add a new `RecoveryResult` type (`Document` + `[]ParseError`) and a new public entry point `parseRecover`. Inside a new `recoverParseLoop`, call `parseKeyValue` / `parseTableHeader` through try/catch; on failure, log the error into an errors list and advance to the next safe synchronisation point (newline, `[`, `[[`). Track open `{` / `[` state during recovery so we skip past matching closers without infinite-looping.

**Tech Stack:** Zig 0.15.x, `std.heap.ArenaAllocator`, existing `src/parser.zig` / `src/error.zig` / `src/toml.zig` public surface.

---

## Scope Check

Single subsystem (parser recovery). No split required.

## File Structure

- **Modify** `src/parser.zig`
  - Add `RecoveryMode` enum.
  - Extend `ParseOptions` with `recovery_mode` and `max_recovery_errors`.
  - Add `parseRecoverDocument` top-level function plus helpers `recoverParseLoop`, `recoverAdvancePastLine`, `recordParserError`.
- **Modify** `src/toml.zig`
  - Re-export `RecoveryMode`.
  - Add public `RecoveryResult` type.
  - Add public `parseRecover` function.
  - Add unit tests for recovery behaviour.
- **Create** `examples/lint_toml.zig`
  - CLI-style example that reads a file, calls `parseRecover`, prints every error with line context.
- **Modify** `build.zig`
  - Wire the new `lint_toml` example behind a `lint-example` step.
- **Modify** `docs/API.md`
  - Document `parseRecover`, `RecoveryResult`, `RecoveryMode`, `max_recovery_errors`.
- **Modify** `CHANGELOG.md`
  - Add entry under Unreleased for GAP-0020.
- **Modify** `docs/GAP_ANALYSIS.md` / `docs/GAP_ANALYSIS_RESOLVED.md`
  - Mark GAP-0020 resolved.

Each task below shows exact file paths and line anchors where relevant.

---

## Task 1: Add `RecoveryMode` enum and extend `ParseOptions`

**Files:**

- Modify: `src/parser.zig` (around lines 21-27 where `ParseOptions` is defined)
- Test: `src/toml.zig` (append a new unit test at the bottom)

- [ ] **Step 1: Write the failing test**

Append to `src/toml.zig` (keep all existing tests; add at end of file):

```zig
test "ParseOptions exposes recovery_mode and max_recovery_errors" {
    const opts: ParseOptions = .{};
    try std.testing.expectEqual(parser_mod.RecoveryMode.strict, opts.recovery_mode);
    try std.testing.expectEqual(@as(usize, 100), opts.max_recovery_errors);

    const custom: ParseOptions = .{
        .recovery_mode = .recover,
        .max_recovery_errors = 7,
    };
    try std.testing.expectEqual(parser_mod.RecoveryMode.recover, custom.recovery_mode);
    try std.testing.expectEqual(@as(usize, 7), custom.max_recovery_errors);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test --summary all 2>&1 | tail -40`
Expected: compile error along the lines of `no member named 'RecoveryMode' in struct 'parser_mod'` or `no field named 'recovery_mode'`.

- [ ] **Step 3: Implement the minimal change**

In `src/parser.zig`, replace the existing `ParseOptions` block (currently lines 23-27):

```zig
pub const RecoveryMode = enum {
    /// Abort on the first parse error (default).
    strict,
    /// Log each error, skip to the next safe point, and keep going.
    recover,
};

pub const ParseOptions = struct {
    version: TomlVersion = .v1_1_0,
    max_depth: u16 = 128,
    max_bytes: usize = 16 * 1024 * 1024,
    /// Parse strictly (default) or accumulate errors and produce a partial document.
    recovery_mode: RecoveryMode = .strict,
    /// Maximum number of errors to log in `recover` mode before stopping.
    /// Only consulted when `recovery_mode == .recover`.
    max_recovery_errors: usize = 100,
};
```

- [ ] **Step 4: Run test to verify it passes**

Run: `zig build test --summary all 2>&1 | tail -20`
Expected: all tests pass including `ParseOptions exposes recovery_mode and max_recovery_errors`.

- [ ] **Step 5: Commit**

```bash
git add src/parser.zig src/toml.zig
git commit -m "feat(parser): add RecoveryMode and recovery options to ParseOptions

Part of GAP-0020."
```

---

## Task 2: Add `RecoveryResult` type and `parseRecover` stub

**Files:**

- Modify: `src/toml.zig` (add public type + stub function just below `ParseResult`)
- Modify: `src/parser.zig` (add stub `parseRecoverDocument`)
- Test: `src/toml.zig`

- [ ] **Step 1: Write the failing test**

Append to `src/toml.zig`:

```zig
test "parseRecover returns empty document for empty input" {
    var result = try parseRecover(std.testing.allocator, "", .{ .recovery_mode = .recover });
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 0), result.errors.len);
    try std.testing.expect(result.document.root.* == .table);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test --summary all 2>&1 | tail -20`
Expected: compile error `no member named 'parseRecover'` in `toml`.

- [ ] **Step 3: Write the minimal stub implementation**

In `src/toml.zig`, insert the following after the existing `parseWithError` function (currently ends around line 73) and before `writeTaggedJson`:

```zig
pub const RecoveryMode = parser_mod.RecoveryMode;

/// Result of a recovery-mode parse.
///
/// `document` contains everything that parsed successfully. When any errors
/// occurred the document is necessarily partial but it is always valid (can
/// be traversed with `get` / `getPath`) and must be `deinit`-ed by the caller.
///
/// `errors` is allocated with the allocator passed to `parseRecover` and must
/// be freed by calling `deinit` on this result.
pub const RecoveryResult = struct {
    document: Document,
    errors: []ParseError,

    pub fn deinit(self: *RecoveryResult, alloc: Allocator) void {
        self.document.deinit();
        alloc.free(self.errors);
    }
};

/// Parse TOML in recovery mode.
///
/// Unlike `parse`/`parseWithError`, this never returns an error that represents
/// a parse failure. Syntactic problems are logged into `RecoveryResult.errors`
/// and parsing resumes at the next safe point. Only allocator/OOM errors are
/// propagated.
///
/// The caller typically passes `opts.recovery_mode = .recover`. If `opts.recovery_mode`
/// is `.strict`, this function still behaves recoveringly (i.e. it forces
/// recovery semantics) so callers who use `parseRecover` unconditionally get
/// what they expect.
pub fn parseRecover(alloc: Allocator, input: []const u8, opts: ParseOptions) !RecoveryResult {
    var effective = opts;
    effective.recovery_mode = .recover;
    return parser_mod.parseRecoverDocument(alloc, input, effective);
}
```

Also in `src/parser.zig`, add this stub function at the end of the file (after the `Parser` struct, at module scope):

```zig
/// Recover-mode entry point. Produces a (possibly partial) Document plus a
/// list of errors. On allocator failure propagates the allocator error.
pub fn parseRecoverDocument(
    alloc: Allocator,
    input: []const u8,
    opts: ParseOptions,
) !@import("toml.zig").RecoveryResult {
    _ = alloc;
    _ = input;
    _ = opts;
    @panic("parseRecoverDocument not yet implemented");
}
```

- [ ] **Step 4: Run build check to verify compile succeeds**

Run: `zig build check 2>&1 | tail -20`
Expected: compiles cleanly (running the test will panic, but we are only checking compilation here).

- [ ] **Step 5: Commit**

```bash
git add src/parser.zig src/toml.zig
git commit -m "feat(parser): add RecoveryResult type and parseRecover stub

Part of GAP-0020."
```

---

## Task 3: Implement recovery loop -- basic single-error test

**Files:**

- Modify: `src/parser.zig`
- Test: `src/toml.zig`

- [ ] **Step 1: Write the failing test**

Append to `src/toml.zig`:

```zig
test "parseRecover: one bad line between good ones" {
    const input = "a = 1\nb = = 2\nc = 3\n";
    var result = try parseRecover(std.testing.allocator, input, .{ .recovery_mode = .recover });
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), result.errors.len);
    try std.testing.expectEqual(@as(u32, 2), result.errors[0].line);

    const a = result.document.root.get("a") orelse unreachable;
    try std.testing.expectEqual(@as(i64, 1), a.integer);

    const c = result.document.root.get("c") orelse unreachable;
    try std.testing.expectEqual(@as(i64, 3), c.integer);

    // The bad key "b" must not have been inserted.
    try std.testing.expect(result.document.root.get("b") == null);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test --summary all 2>&1 | tail -20`
Expected: panic from the `parseRecoverDocument` stub, or (if the stub was changed) incorrect results.

- [ ] **Step 3: Implement the real `parseRecoverDocument`**

In `src/parser.zig`, replace the `parseRecoverDocument` stub with the implementation below. The helpers `recoverParseLoop`, `recoverAdvancePastLine`, and `recordParserError` are defined immediately after it at module scope.

```zig
pub fn parseRecoverDocument(
    alloc: Allocator,
    input: []const u8,
    opts: ParseOptions,
) !@import("toml.zig").RecoveryResult {
    const RecoveryResult = @import("toml.zig").RecoveryResult;

    // Errors are collected in the caller's allocator (not the arena) so they
    // outlive `document.deinit()` if the caller frees them separately. The
    // RecoveryResult.deinit handles both correctly.
    var errors: std.ArrayList(ParseError) = .empty;
    errdefer errors.deinit(alloc);

    var parser = Parser.init(alloc, input, opts);

    // UTF-8 / size checks are hard failures even in recover mode -- if we
    // can't trust the bytes we cannot meaningfully recover.
    if (!std.unicode.utf8ValidateSlice(input)) {
        try errors.append(alloc, err.makeError(.InvalidUtf8, .{}, "input is not valid UTF-8"));
        var arena_empty = std.heap.ArenaAllocator.init(alloc);
        const empty_root = try val.createTable(arena_empty.allocator());
        return RecoveryResult{
            .document = .{ .root = empty_root, .arena = arena_empty },
            .errors = try errors.toOwnedSlice(alloc),
        };
    }
    if (input.len > opts.max_bytes) {
        try errors.append(alloc, err.makeError(.LimitExceeded, .{}, "input exceeds max_bytes limit"));
        var arena_empty = std.heap.ArenaAllocator.init(alloc);
        const empty_root = try val.createTable(arena_empty.allocator());
        return RecoveryResult{
            .document = .{ .root = empty_root, .arena = arena_empty },
            .errors = try errors.toOwnedSlice(alloc),
        };
    }

    var arena = std.heap.ArenaAllocator.init(alloc);
    errdefer arena.deinit();
    const arena_alloc = arena.allocator();
    const root = try val.createTable(arena_alloc);

    // Prime the parser. Lexer errors at prime-time are recorded and we
    // attempt to advance past them.
    parser.current = parser.nextToken() catch |e| blk: {
        try recordParserError(&parser, &errors, alloc, e);
        break :blk .{ .tag = .eof, .pos = .{}, .len = 0 };
    };

    try recoverParseLoop(&parser, arena_alloc, root, &errors, alloc, opts);

    return RecoveryResult{
        .document = .{ .root = root, .arena = arena },
        .errors = try errors.toOwnedSlice(alloc),
    };
}

fn recordParserError(
    parser: *Parser,
    errors: *std.ArrayList(ParseError),
    alloc: Allocator,
    _: anyerror,
) !void {
    if (parser.parse_error) |pe| {
        try errors.append(alloc, pe);
        parser.parse_error = null;
    } else {
        try errors.append(alloc, err.makeError(.UnexpectedToken, parser.current.pos, "unknown parse error"));
    }
}

fn recoverParseLoop(
    parser: *Parser,
    arena_alloc: Allocator,
    root: *Value,
    errors: *std.ArrayList(ParseError),
    alloc: Allocator,
    opts: ParseOptions,
) !void {
    var current_table = root;

    while (parser.current.tag != .eof) {
        if (errors.items.len >= opts.max_recovery_errors) {
            // Cap hit -- stop trying.
            return;
        }

        switch (parser.current.tag) {
            .newline, .comment => {
                parser.current = parser.nextToken() catch |e| {
                    try recordParserError(parser, errors, alloc, e);
                    recoverAdvancePastLine(parser);
                    continue;
                };
            },
            .left_bracket, .double_bracket_open => {
                const is_array = parser.current.tag == .double_bracket_open;
                const next_table = parser.parseTableHeader(arena_alloc, root, is_array) catch |e| {
                    try recordParserError(parser, errors, alloc, e);
                    recoverAdvancePastLine(parser);
                    continue;
                };
                current_table = next_table;
            },
            .bare_key,
            .basic_string,
            .literal_string,
            .float,
            .bool_true,
            .bool_false,
            .integer,
            .datetime,
            .datetime_local,
            .date_local,
            .time_local,
            => {
                parser.parseKeyValue(arena_alloc, current_table) catch |e| {
                    try recordParserError(parser, errors, alloc, e);
                    recoverAdvancePastLine(parser);
                    continue;
                };
            },
            else => {
                try errors.append(alloc, err.makeError(.UnexpectedToken, parser.current.pos, "unexpected token"));
                recoverAdvancePastLine(parser);
            },
        }
    }
}

/// Advance the parser's `current` token until we hit a newline, `[`, `[[`,
/// or EOF. Tokens representing an unterminated inline table / array are
/// skipped by counting `{` / `[` nesting so we do not stop inside them.
fn recoverAdvancePastLine(parser: *Parser) void {
    var brace_depth: i32 = 0;
    var bracket_depth: i32 = 0;

    while (parser.current.tag != .eof) {
        switch (parser.current.tag) {
            .left_brace => brace_depth += 1,
            .right_brace => if (brace_depth > 0) {
                brace_depth -= 1;
            },
            .left_bracket => bracket_depth += 1,
            .right_bracket => if (bracket_depth > 0) {
                bracket_depth -= 1;
            },
            .newline => if (brace_depth == 0 and bracket_depth == 0) {
                // Consume the newline itself so the main loop starts fresh.
                parser.current = parser.nextToken() catch .{ .tag = .eof, .pos = .{}, .len = 0 };
                return;
            },
            else => {},
        }

        // A table header at depth zero is also a statement boundary even
        // without an intervening newline (defensive against missing \n).
        if (brace_depth == 0 and bracket_depth == 0) {
            switch (parser.current.tag) {
                .left_bracket, .double_bracket_open => return,
                else => {},
            }
        }

        parser.current = parser.nextToken() catch .{ .tag = .eof, .pos = .{}, .len = 0 };
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `zig build test --summary all 2>&1 | tail -40`
Expected: `parseRecover: one bad line between good ones` passes. Pre-existing tests still pass.

- [ ] **Step 5: Commit**

```bash
git add src/parser.zig src/toml.zig
git commit -m "feat(parser): implement parseRecover base loop and line sync

Part of GAP-0020."
```

---

## Task 4: Test and fix -- consecutive errors must not infinite-loop

**Files:**

- Test: `src/toml.zig`
- Modify (if needed): `src/parser.zig`

- [ ] **Step 1: Write the failing test**

Append to `src/toml.zig`:

```zig
test "parseRecover: multiple consecutive bad lines log each, no infinite loop" {
    const input =
        \\a = = 1
        \\b = = 2
        \\c = = 3
        \\ok = "fine"
        \\
    ;
    var result = try parseRecover(std.testing.allocator, input, .{ .recovery_mode = .recover });
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 3), result.errors.len);

    const ok = result.document.root.get("ok") orelse unreachable;
    try std.testing.expectEqualStrings("fine", ok.string);
}
```

- [ ] **Step 2: Run the test**

Run: `zig build test --summary all 2>&1 | tail -40`
Expected: either passes (implementation is correct) or reveals that `recoverAdvancePastLine` fails to make progress on one of these inputs.

- [ ] **Step 3: If the test fails, ensure forward progress**

If `recoverAdvancePastLine` returns without advancing (e.g. when `current.tag` is already `.newline` at entry because the failing `parseKeyValue` left us there), add a guaranteed consume-one-token-first step to the top of the function. Modify `recoverAdvancePastLine` in `src/parser.zig` so its body begins with:

```zig
fn recoverAdvancePastLine(parser: *Parser) void {
    // Guarantee forward progress: always consume the token that caused us to
    // enter recovery so we cannot loop on it.
    parser.current = parser.nextToken() catch .{ .tag = .eof, .pos = .{}, .len = 0 };

    var brace_depth: i32 = 0;
    var bracket_depth: i32 = 0;
    // ... existing loop body unchanged ...
}
```

Re-run the test.

- [ ] **Step 4: Run the test to verify pass**

Run: `zig build test --summary all 2>&1 | tail -40`
Expected: passes. No watchdog timeout.

- [ ] **Step 5: Commit**

```bash
git add src/parser.zig src/toml.zig
git commit -m "fix(parser): ensure recovery loop always advances one token

Prevents infinite loops when multiple consecutive lines fail. Part of GAP-0020."
```

---

## Task 5: Test -- error inside `[section]` header skips to next `[`

**Files:**

- Test: `src/toml.zig`

- [ ] **Step 1: Write the failing test**

Append to `src/toml.zig`:

```zig
test "parseRecover: broken table header advances to next valid section" {
    const input =
        \\[good]
        \\x = 1
        \\[bad..section]
        \\y = 2
        \\[also_good]
        \\z = 3
        \\
    ;
    var result = try parseRecover(std.testing.allocator, input, .{ .recovery_mode = .recover });
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.errors.len >= 1);

    const good = result.document.root.get("good") orelse unreachable;
    const x = good.get("x") orelse unreachable;
    try std.testing.expectEqual(@as(i64, 1), x.integer);

    const also_good = result.document.root.get("also_good") orelse unreachable;
    const z = also_good.get("z") orelse unreachable;
    try std.testing.expectEqual(@as(i64, 3), z.integer);
}
```

- [ ] **Step 2: Run test**

Run: `zig build test --summary all 2>&1 | tail -40`
Expected: passes if the Task 3/4 implementation advances correctly on a header error. If it fails, inspect `result.errors` to diagnose; the most common cause is that `recoverAdvancePastLine` does not treat an in-progress `[` header as "skip until newline". We already advance one token first (Task 4), so re-entering the main loop and hitting a `newline` on the bad header line is usually sufficient.

- [ ] **Step 3: If the test fails, refine**

If it fails, change `recoverAdvancePastLine` to also bail at the end of a header line. Replace the second depth-zero switch in that function with:

```zig
if (brace_depth == 0 and bracket_depth == 0) {
    switch (parser.current.tag) {
        .left_bracket, .double_bracket_open => return,
        .newline => {
            parser.current = parser.nextToken() catch .{ .tag = .eof, .pos = .{}, .len = 0 };
            return;
        },
        else => {},
    }
}
```

- [ ] **Step 4: Re-run test**

Run: `zig build test --summary all 2>&1 | tail -40`
Expected: passes.

- [ ] **Step 5: Commit**

```bash
git add src/parser.zig src/toml.zig
git commit -m "test(parser): cover recovery across broken table headers

Part of GAP-0020."
```

---

## Task 6: Test -- error inside an inline table skips past matching `}`

**Files:**

- Test: `src/toml.zig`
- Modify (if needed): `src/parser.zig`

- [ ] **Step 1: Write the failing test**

Append to `src/toml.zig`:

```zig
test "parseRecover: bad inline table is bounded by its closing brace" {
    const input =
        \\a = 1
        \\point = { x = 1, y = = 2, z = 3 }
        \\after = 99
        \\
    ;
    var result = try parseRecover(std.testing.allocator, input, .{ .recovery_mode = .recover });
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.errors.len >= 1);

    const a = result.document.root.get("a") orelse unreachable;
    try std.testing.expectEqual(@as(i64, 1), a.integer);

    const after = result.document.root.get("after") orelse unreachable;
    try std.testing.expectEqual(@as(i64, 99), after.integer);
}
```

- [ ] **Step 2: Run test**

Run: `zig build test --summary all 2>&1 | tail -40`
Expected: passes if `recoverAdvancePastLine` brace-depth counting is correct. If `after = 99` is not populated or the parser loops, investigate and fix per Step 3.

- [ ] **Step 3: If the test fails, strengthen brace handling**

Ensure `.left_brace` and `.right_brace` modify `brace_depth` before the boundary check. If the parser's existing `parseInlineTable` already consumes the opening `{` before erroring, the recovery loop may see `brace_depth == 0` even inside the table. In that case, treat the very next `}` at `brace_depth == 0` as a terminator. In `recoverAdvancePastLine`, replace the `.right_brace` arm with:

```zig
.right_brace => {
    if (brace_depth > 0) {
        brace_depth -= 1;
    } else {
        // Unbalanced close: this is the closer of the inline table we
        // were inside when the error fired. Consume it and treat it as
        // a statement boundary.
        parser.current = parser.nextToken() catch .{ .tag = .eof, .pos = .{}, .len = 0 };
        return;
    }
},
```

Re-run the test.

- [ ] **Step 4: Re-run test**

Run: `zig build test --summary all 2>&1 | tail -40`
Expected: passes.

- [ ] **Step 5: Commit**

```bash
git add src/parser.zig src/toml.zig
git commit -m "fix(parser): bound inline-table error recovery at matching brace

Part of GAP-0020."
```

---

## Task 7: Test -- error inside an array skips past matching `]`

**Files:**

- Test: `src/toml.zig`
- Modify (if needed): `src/parser.zig`

- [ ] **Step 1: Write the failing test**

Append to `src/toml.zig`:

```zig
test "parseRecover: bad array is bounded by its closing bracket" {
    const input =
        \\a = 1
        \\xs = [1, 2, = 3, 4]
        \\after = "ok"
        \\
    ;
    var result = try parseRecover(std.testing.allocator, input, .{ .recovery_mode = .recover });
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.errors.len >= 1);

    const a = result.document.root.get("a") orelse unreachable;
    try std.testing.expectEqual(@as(i64, 1), a.integer);

    const after = result.document.root.get("after") orelse unreachable;
    try std.testing.expectEqualStrings("ok", after.string);
}
```

- [ ] **Step 2: Run test**

Run: `zig build test --summary all 2>&1 | tail -40`
Expected: passes. If it fails, apply the symmetric fix to arrays.

- [ ] **Step 3: If failing, apply symmetric unbalanced-`]` handling**

In `recoverAdvancePastLine`, replace the `.right_bracket` arm with:

```zig
.right_bracket => {
    if (bracket_depth > 0) {
        bracket_depth -= 1;
    } else {
        parser.current = parser.nextToken() catch .{ .tag = .eof, .pos = .{}, .len = 0 };
        return;
    }
},
```

This mirrors the brace logic from Task 6. An unbalanced `]` at depth 0 will also occur legitimately at the end of `[section]`; in that case `parseTableHeader` should have consumed the `]` before erroring, so treating any stray `]` as a boundary is still correct.

- [ ] **Step 4: Re-run test**

Run: `zig build test --summary all 2>&1 | tail -40`
Expected: passes.

- [ ] **Step 5: Commit**

```bash
git add src/parser.zig src/toml.zig
git commit -m "fix(parser): bound array error recovery at matching bracket

Part of GAP-0020."
```

---

## Task 8: Test -- `max_recovery_errors` cap stops runaway inputs

**Files:**

- Test: `src/toml.zig`

- [ ] **Step 1: Write the failing test**

Append to `src/toml.zig`:

```zig
test "parseRecover: honours max_recovery_errors cap" {
    // 20 bad lines; cap at 5.
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    var i: usize = 0;
    while (i < 20) : (i += 1) {
        try buf.appendSlice(std.testing.allocator, "x = = 1\n");
    }

    var result = try parseRecover(std.testing.allocator, buf.items, .{
        .recovery_mode = .recover,
        .max_recovery_errors = 5,
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.errors.len <= 5);
    try std.testing.expect(result.errors.len >= 1);
}
```

- [ ] **Step 2: Run test**

Run: `zig build test --summary all 2>&1 | tail -40`
Expected: passes (the cap is already wired through `recoverParseLoop`).

- [ ] **Step 3: If it fails**

Confirm the guard `if (errors.items.len >= opts.max_recovery_errors) return;` sits at the top of `recoverParseLoop`'s `while` body, *before* any token dispatch. If it is positioned after, move it.

- [ ] **Step 4: Re-run test**

Run: `zig build test --summary all 2>&1 | tail -40`
Expected: passes.

- [ ] **Step 5: Commit**

```bash
git add src/parser.zig src/toml.zig
git commit -m "test(parser): verify max_recovery_errors cap is honoured

Part of GAP-0020."
```

---

## Task 9: Test -- strict mode is unaffected by the new machinery

**Files:**

- Test: `src/toml.zig`

- [ ] **Step 1: Write the failing test**

Append to `src/toml.zig`:

```zig
test "strict mode (default) still fails on first error" {
    const input = "a = 1\nb = = 2\nc = 3\n";
    const result = parseWithError(std.testing.allocator, input, .{});
    switch (result) {
        .ok => |*d| {
            var doc = @constCast(d);
            doc.deinit();
            try std.testing.expect(false);
        },
        .err => |e| {
            try std.testing.expectEqual(@as(u32, 2), e.line);
        },
    }
}
```

- [ ] **Step 2: Run test**

Run: `zig build test --summary all 2>&1 | tail -40`
Expected: passes. The `strict` default in `ParseOptions` means `parseWithError` / `parse` behave exactly as before.

- [ ] **Step 3: If it fails**

Check that none of the recovery code paths were accidentally wired into `Parser.parse`. The strict path should never touch `recoverParseLoop`, `recoverAdvancePastLine`, or an errors list.

- [ ] **Step 4: Re-run test**

Run: `zig build test --summary all 2>&1 | tail -40`
Expected: passes.

- [ ] **Step 5: Commit**

```bash
git add src/toml.zig
git commit -m "test(parser): confirm strict mode unaffected by recovery work

Part of GAP-0020."
```

---

## Task 10: Test -- non-recoverable error (invalid UTF-8) still reported

**Files:**

- Test: `src/toml.zig`

- [ ] **Step 1: Write the failing test**

Append to `src/toml.zig`:

```zig
test "parseRecover: invalid UTF-8 reported without partial document" {
    const input = "a = \"\xff\xfe\"\n";
    var result = try parseRecover(std.testing.allocator, input, .{ .recovery_mode = .recover });
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), result.errors.len);
    try std.testing.expectEqual(ErrorCode.InvalidUtf8, result.errors[0].code);
    // Root table should exist but be empty.
    try std.testing.expect(result.document.root.* == .table);
    try std.testing.expectEqual(@as(usize, 0), result.document.root.table.entries.len);
}
```

- [ ] **Step 2: Run test**

Run: `zig build test --summary all 2>&1 | tail -40`
Expected: passes (the early-out branch in `parseRecoverDocument` handles this).

- [ ] **Step 3: Commit**

```bash
git add src/toml.zig
git commit -m "test(parser): invalid UTF-8 surfaces as a recovery error

Part of GAP-0020."
```

---

## Task 11: Add `examples/lint_toml.zig`

**Files:**

- Create: `examples/lint_toml.zig`
- Modify: `build.zig` (add example compile target + run step)

- [ ] **Step 1: Write the example**

Create `examples/lint_toml.zig`:

```zig
// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! Lint Example
//!
//! Reads a TOML file path from argv[1] and prints every syntax error using
//! the new `parseRecover` mode. Useful as a sanity check for editor
//! integrations.

const std = @import("std");
const toml = @import("toml");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        try std.io.getStdErr().writer().print("usage: lint_toml <file.toml>\n", .{});
        return error.BadUsage;
    }

    const path = args[1];
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    const bytes = try file.readToEndAlloc(allocator, 16 * 1024 * 1024);
    defer allocator.free(bytes);

    var result = try toml.parseRecover(allocator, bytes, .{
        .recovery_mode = .recover,
        .max_recovery_errors = 100,
    });
    defer result.deinit(allocator);

    const stdout = std.io.getStdOut().writer();

    if (result.errors.len == 0) {
        try stdout.print("{s}: OK\n", .{path});
        return;
    }

    try stdout.print("{s}: {d} error(s)\n", .{ path, result.errors.len });
    for (result.errors) |e| {
        try stdout.print("  line {d}, col {d}: [{s}] {s}\n", .{
            e.line,
            e.column,
            @tagName(e.code),
            e.message,
        });
    }
}
```

- [ ] **Step 2: Wire the example into `build.zig`**

Insert the following immediately before the closing `}` of the `build` function in `build.zig` (after the `run_step` block, currently ending around line 125):

```zig
    // lint_toml example
    const lint_mod = b.createModule(.{
        .root_source_file = b.path("examples/lint_toml.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "toml", .module = toml_mod },
        },
    });
    const lint_exe = b.addExecutable(.{
        .name = "lint_toml",
        .root_module = lint_mod,
    });
    const run_lint = b.addRunArtifact(lint_exe);
    if (b.args) |args2| run_lint.addArgs(args2);
    const lint_step = b.step("lint-example", "Run the lint_toml example");
    lint_step.dependOn(&run_lint.step);
```

- [ ] **Step 3: Compile the example**

Run: `zig build 2>&1 | tail -20`
Expected: builds cleanly (no new warnings from `examples/lint_toml.zig`).

- [ ] **Step 4: Smoke-test it against a known-bad file**

Create a temporary scratch file and invoke:

```bash
printf 'a = 1\nb = = 2\nc = 3\n' > /tmp/lint_demo.toml
zig build lint-example -- /tmp/lint_demo.toml
```

Expected output (exact line/col may differ slightly):

```text
/tmp/lint_demo.toml: 1 error(s)
  line 2, col 5: [UnexpectedToken] expected '='
```

- [ ] **Step 5: Commit**

```bash
git add examples/lint_toml.zig build.zig
git commit -m "feat(examples): add lint_toml example driving parseRecover

Part of GAP-0020."
```

---

## Task 12: Update `docs/API.md`

**Files:**

- Modify: `docs/API.md`

- [ ] **Step 1: Add documentation**

Append to `docs/API.md` (under an appropriate section -- if no existing "Recovery" or "Linting" section, add at end):

````markdown
## Error recovery

Use `parseRecover` when you want every syntax error in a file rather than just
the first one (for example, to build an editor integration or a linter).

```zig
const toml = @import("toml");

var result = try toml.parseRecover(allocator, input, .{
    .recovery_mode = .recover,
    .max_recovery_errors = 100, // default
});
defer result.deinit(allocator);

for (result.errors) |e| {
    std.debug.print("line {d}, col {d}: {s}\n", .{ e.line, e.column, e.message });
}

// `result.document` is a valid, possibly partial Document that contains
// every key/table that parsed cleanly. All successful lookups work normally.
const maybe_host = result.document.getPath(&.{ "server", "host" });
```

`RecoveryResult` is:

```zig
pub const RecoveryResult = struct {
    document: Document,
    errors: []ParseError,
    pub fn deinit(self: *RecoveryResult, alloc: Allocator) void { ... }
};
```

`RecoveryMode` is:

```zig
pub const RecoveryMode = enum { strict, recover };
```

`.strict` is the default and matches historical behaviour. `.recover` causes
`parseRecover` to log each error and skip to the next safe synchronisation
point (newline, next `[...]` or `[[...]]`), bounded by `max_recovery_errors`
(default `100`).

Notes:
- Errors are one-per-bad-statement; the recovery loop does not attempt to
  repair broken statements.
- Inline tables and arrays are escaped by counting their matching closer,
  so a broken `{...}` or `[...]` does not consume subsequent lines.
- `InvalidUtf8` and `max_bytes` violations are always fatal and return an
  empty document with a single error even in recovery mode.
````

- [ ] **Step 2: Commit**

```bash
git add docs/API.md
git commit -m "docs: document parseRecover API

Part of GAP-0020."
```

---

## Task 13: Update `CHANGELOG.md`

**Files:**

- Modify: `CHANGELOG.md`

- [ ] **Step 1: Add changelog entry**

In `CHANGELOG.md`, locate the `## [Unreleased]` section (create it at the top under the header if it does not exist). Add:

```markdown
### Added
- `toml.parseRecover` entry point and `RecoveryResult` / `RecoveryMode` types
  for partial-parse / error-recovery workflows (e.g., IDE integrations and
  linters). Logs every syntax error instead of aborting on the first one.
  Configurable via `ParseOptions.recovery_mode` and
  `ParseOptions.max_recovery_errors`. Closes GAP-0020.
- `examples/lint_toml.zig` demonstrating the new recovery mode end-to-end.
```

- [ ] **Step 2: Commit**

```bash
git add CHANGELOG.md
git commit -m "chore(changelog): note GAP-0020 closure in Unreleased"
```

---

## Task 14: Mark GAP-0020 resolved

**Files:**

- Modify: `docs/GAP_ANALYSIS.md` and/or `docs/GAP_ANALYSIS_RESOLVED.md`

- [ ] **Step 1: Inspect the current state of the two gap docs**

Run: `grep -n "GAP-0020" docs/GAP_ANALYSIS.md docs/GAP_ANALYSIS_RESOLVED.md 2>/dev/null`

Depending on the repo's existing convention:

- If GAP-0020 appears in `docs/GAP_ANALYSIS.md` only, move it to `docs/GAP_ANALYSIS_RESOLVED.md` preserving its existing header structure.
- If GAP-0020 already has a status line, flip it to `Status: Resolved (2026-04-18)`.
- Add a one-line pointer: `Resolved by plan docs/superpowers/plans/2026-04-18-11-partial-parse-error-recovery.md`.

- [ ] **Step 2: Make the edit**

Make the minimal change to reflect resolution. Example patch shape (adapt to actual file content):

```markdown
### GAP-0020 -- Partial-Parse / Error-Recovery Mode

Status: Resolved (2026-04-18)
Resolved by: parseRecover / RecoveryResult; see
docs/superpowers/plans/2026-04-18-11-partial-parse-error-recovery.md.
```

- [ ] **Step 3: Verify build still green**

Run: `zig build test --summary all 2>&1 | tail -20`
Expected: all tests still pass (docs-only change).

- [ ] **Step 4: Commit**

```bash
git add docs/GAP_ANALYSIS.md docs/GAP_ANALYSIS_RESOLVED.md
git commit -m "docs(gap): mark GAP-0020 resolved"
```

---

## Task 15: Final integration verification

**Files:**

- (no new changes -- this step exists as a self-review gate)

- [ ] **Step 1: Run the entire test suite**

Run: `zig build test --summary all 2>&1 | tail -30`
Expected: all tests pass. No leaks reported by the test allocator.

- [ ] **Step 2: Build all examples and library artifacts**

Run: `zig build 2>&1 | tail -20`
Expected: clean build.

- [ ] **Step 3: Run the lint example one more time**

```bash
printf '[s1]\na = 1\n[s2\nbad = = 2\n[s3]\nok = "done"\n' > /tmp/lint_demo2.toml
zig build lint-example -- /tmp/lint_demo2.toml
```

Expected: exits with status 0, prints >= 1 error, and `s1.a` / `s3.ok` both appear valid.

- [ ] **Step 4: Review the full commit history**

Run: `git log --oneline origin/main..HEAD`
Expected: a clean sequence of small commits, each of which compiles and tests cleanly in isolation.

- [ ] **Step 5: If everything passes, push for PR**

```bash
git push -u origin HEAD
# then follow the repo's usual PR process
```

Final PR title suggestion: `feat(parser): close GAP-0020 -- partial-parse / error-recovery mode`

---

## Design notes (recap)

- Recovery quality is a spectrum; we aim for "one error per bad statement" and
  do not try to repair the statement itself.
- Inline tables and arrays are escaped by counting `{`/`}` and `[`/`]` nesting
  in the recovery advancer; if the lexer has already consumed the opener, an
  unbalanced closer at depth 0 is treated as the statement boundary.
- `max_recovery_errors = 100` by default; callers can lower/raise per call via
  `ParseOptions`.
- `InvalidUtf8` and `max_bytes` violations short-circuit: we return an empty
  `Document` plus one error even in recovery mode, because continuing on
  untrusted bytes is not meaningful.
- Strict mode is untouched: `parse` and `parseWithError` continue to abort on
  the first error exactly as before.

## Self-review checklist (performed)

1. **Spec coverage:** Every numbered task from the source sketch (Tasks 1-11)
   has a corresponding numbered task above. GAP closure tasks (12-14) and a
   final verification step (15) are added.
2. **Placeholder scan:** No "TBD", "TODO", "similar to Task N", or
   unelaborated "handle edge cases" steps. Every code step shows real code.
3. **Type consistency:** `RecoveryMode`, `RecoveryResult`, `parseRecover`,
   `parseRecoverDocument`, `recoverParseLoop`, `recoverAdvancePastLine`,
   `recordParserError`, `max_recovery_errors`, and `recovery_mode` are used
   with the same names everywhere they appear.
