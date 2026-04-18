# Real Parallel Parser Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the shadow byte-level "shape-checker" parser in `src/parallel.zig` with thin wrappers around the real `toml.parse` parser so that `parallel.parseDocuments`, `parallel.validateDocuments`, and `parallel.extractKeys` produce the same accept/reject decisions as serial `toml.parse`, closing the false-oracle gaps GAP-0001, Q-1, Q-2, P-6, S-1, S-2, and S-3.

**Architecture:** Each worker task invokes the existing `toml.parse(task_allocator, input, options)` function and stores the returned `Document` on the `ParseResult`. `ParseResult` gains an optional `doc: ?toml.Document` field whose lifetime is tied to a per-result `ArenaAllocator` that the caller drains by invoking `doc.?.deinit()`. `validateDocument` is implemented as `parseDocument` followed by an immediate `deinit`. `extractKeysFromDocument` walks `document.root.table.entries` and duplicates top-level keys into the caller's allocator. The existing thread-pool chunking and `submitBatch` harness are unchanged — only the inner per-document kernels swap shadow-parser-for-real-parser.

**Tech Stack:** Zig 0.15.1, `std.heap.ArenaAllocator`, `std.mem.Allocator`, `std.testing`, the in-tree `toml.parse` and `toml.parseWithError` at `src/toml.zig:41-73`, `ParseError` / `ErrorCode` at `src/error.zig:9-38`, `Document` at `src/value.zig:205-223`, the `thread_pool` dependency (`ThreadPool`, `BatchTask`, `WaitGroup`) wired via `build.zig:14-28`.

---

## Codebase Primer (read before starting Task 1)

New engineers should skim this section before touching code. All line numbers were current as of commit `535e23e` and may drift; if a reference looks stale, re-grep.

### Repository layout

- `src/toml.zig` — public module root. Exports `parse`, `parseWithError`, `writeTaggedJson`, and `parallel` (re-export of `parallel.zig`).
- `src/parser.zig` — ~1636 LOC recursive-descent TOML parser. Owns the arena it allocates into.
- `src/lexer.zig` — token producer consumed by the parser.
- `src/value.zig` — `Value` union, `Document`, `Table`, and helpers like `tableSet` / `tableGetOrCreate`.
- `src/error.zig` — `ErrorCode`, `ParseError`, and `Position`.
- `src/parallel.zig` — the file this plan rewrites. Contains `ParseResult`, `ValidateResult`, `KeyExtractResult`, and the shadow `parseDocument` / `validateDocument` / `extractKeysFromDocument` kernels. Also hosts the in-source unit tests for the parallel module.
- `src/json_tagged.zig` — toml-test tagged JSON emitter (not relevant to this plan).
- `src/bin/toml_test_decoder.zig` — CLI binary (not relevant).
- `tests/accept.zig`, `tests/fuzz_parse.zig` — out-of-tree test drivers wired into `build.zig`.
- `build.zig`, `build.zig.zon` — build graph + dep lockfile.
- `docs/*.md` — human docs; we will update `docs/API.md`, `docs/ARCHITECTURE.md`, `CHANGELOG.md`.

### Key types you will touch

- `toml.Document` at `src/value.zig:205-223`:

  ```zig
  pub const Document = struct {
      root: *Value,
      arena: std.heap.ArenaAllocator,
      pub fn deinit(self: *Document) void { self.arena.deinit(); }
      pub fn getPath(self: *const Document, path: []const []const u8) ?*const Value { ... }
      pub fn allocator(self: *Document) Allocator { return self.arena.allocator(); }
  };
  ```

- `toml.ParseResult` (top-level, **not** the parallel one) at `src/toml.zig:53-56`:

  ```zig
  pub const ParseResult = union(enum) {
      ok: Document,
      err: ParseError,
  };
  ```

- `ParseError` at `src/error.zig:33-54`: has `code: ErrorCode`, `byte_index: usize`, `line: u32`, `column: u32`, `message: []const u8`.
- `toml.parse(alloc, input, opts) !Document` at `src/toml.zig:41-49` — returns `error.ParseFailed` on any parse error.
- `toml.parseWithError(alloc, input, opts) ParseResult` at `src/toml.zig:58-73` — returns a `ParseResult` union with `ok` or `err`. This is the one we call from `parallel.zig` because we want structured error info.

### Parallel module surface (before this plan)

- `parallel.ParseResult` struct at `src/parallel.zig:83-94` — has `success`, `error_code: u8`, `error_line`, `error_column`, `key_count`. This is a **different** `ParseResult` than `toml.ParseResult` — do not confuse them.
- `parallel.ValidateResult` at `src/parallel.zig:250-257`.
- `parallel.KeyExtractResult` at `src/parallel.zig:364-371`.
- `parallel.parseDocument` at `src/parallel.zig:169-243` — the shadow char-scanner this plan deletes.
- `parallel.validateDocument` at `src/parallel.zig:319-357` — the UTF-8 + bracket-balance checker this plan deletes.
- `parallel.extractKeysFromDocument` at `src/parallel.zig:438-484` — the line-splitting key extractor this plan replaces.

### Test infrastructure

- `zig build test --summary all` — runs unit tests (in-source `test "..."` blocks in `src/`) plus `tests/accept.zig` plus `tests/fuzz_parse.zig`.
- `zig build check` — compile-only.
- `zig fmt --check src/ tests/ examples/ build.zig` — formatter gate.
- `pre-commit run` — repo hooks (run via `pre-commit run --all-files` for full sweep, or `pre-commit run --files <paths>` for targeted).
- Tests live either in-source (inside `src/parallel.zig` after the implementation) or in `tests/accept.zig`. **Put the new differential test in `src/parallel.zig`** next to the existing `test "U-M …"` block so it compiles under the same unit-test module and has direct access to the internal `parseDocument` etc. via the file scope.

### Conventions

- Zig test blocks use `test "name" { ... }`.
- Always `defer …deinit()` anything allocated.
- Use `std.testing.allocator` in tests — it leak-checks.
- Commits follow Conventional Commits: `fix(parallel): …`, `feat(parallel): …`, `chore(docs): …`, etc.
- Co-author trailer required on all commits produced by the automated plan.

---

## File Structure

**Modify:**

- `src/parallel.zig` — replace three shadow kernels (`parseDocument`, `validateDocument`, `extractKeysFromDocument`), widen `ParseResult`, flip xfail test expectations, add new differential test.
- `src/toml.zig` — the `parallel re-export is reachable` smoke test at `src/toml.zig:393-409` must still pass; ensure teardown calls `result.deinit()` where the new `doc` field is populated.
- `docs/API.md` — update the Parallel section to reflect real-parser semantics and the new `doc: ?Document` field.
- `docs/ARCHITECTURE.md` — remove "shape-checker" language; describe the wrapper approach.
- `CHANGELOG.md` — entry under a new `## [0.2.0]` heading with migration notes.
- `build.zig.zon` — bump `.version` from `"0.1.0"` to `"0.2.0"`.
- `README.md` — remove the "Important: today, `parallel.parseDocuments` is a lightweight … shape-checker" warning block (lines around 157-165).

**Create:**

- None. All tests live inline in `src/parallel.zig`.

**Delete:**

- The three shadow kernel bodies inside `src/parallel.zig`. File stays; bodies are replaced in place.

---

## Task 1: Add differential corpus test comparing `parallel.parseDocuments` to `toml.parseWithError`

Goal: lock in the contract that `parallel.parseDocuments[i].success == (toml.parseWithError(inputs[i]) is ok)` on a 20-input corpus of mixed valid and invalid TOML. This test must **fail red** before any implementation work, because the current shadow parser accepts 4+ of the invalids.

**Files:**

- Modify: `src/parallel.zig` — append a new `test` block directly after the `U-M baseline` test near line 720.

- [ ] **Step 1.1: Write the failing differential corpus test**

Append the following block at the very end of `src/parallel.zig` (after the final closing `}` of `test "U-F no dropped inputs past MAX_CHUNKS - extractKeys"` on line 789):

```zig
// ============================================================================
// GAP-0001: Differential test — parallel.parseDocuments MUST agree with
// toml.parseWithError on both valid and invalid inputs. This test pins the
// contract that parallel path == serial path for accept/reject decisions.
// Before the shadow parser is removed, several xfail fixtures below will
// make this test fail red (the shadow parser accepts inputs the real
// parser rejects). After Task 2 lands the test must pass green.
// ============================================================================

test "GAP-0001 parallel vs serial differential corpus" {
    const toml = @import("toml.zig");
    const allocator = std.testing.allocator;

    const Case = struct {
        input: []const u8,
        expect_success: bool,
        label: []const u8,
    };

    const corpus = [_]Case{
        // --- valid inputs (must accept) ---
        .{ .input = "a = 1\n", .expect_success = true, .label = "simple int" },
        .{ .input = "name = \"zigtoml\"\n", .expect_success = true, .label = "simple string" },
        .{ .input = "[table]\nk = 1\n", .expect_success = true, .label = "table header" },
        .{ .input = "[[arr]]\nk = 1\n", .expect_success = true, .label = "array of tables" },
        .{ .input = "pt = { x = 1, y = 2 }\n", .expect_success = true, .label = "inline table" },
        .{ .input = "a.b.c = 1\n", .expect_success = true, .label = "dotted key" },
        .{ .input = "s = \"\"\"hello\nworld\"\"\"\n", .expect_success = true, .label = "multiline basic string" },
        .{ .input = "s = '''hello\nworld'''\n", .expect_success = true, .label = "multiline literal string" },
        .{ .input = "arr = [1, 2, 3]\n", .expect_success = true, .label = "int array" },
        .{ .input = "x = 0xDEADBEEF\n", .expect_success = true, .label = "hex int" },
        // --- invalid inputs (must reject) ---
        .{ .input = "a = = 1\n", .expect_success = false, .label = "double equals (S-1)" },
        .{ .input = "[unclosed table\n", .expect_success = false, .label = "unclosed table header (S-1)" },
        .{ .input = "a = 1\na = 2\n", .expect_success = false, .label = "duplicate key (S-1)" },
        .{ .input = "a = \"unterminated\n", .expect_success = false, .label = "unterminated string (S-2)" },
        .{ .input = "a = \"bad\\q\"\n", .expect_success = false, .label = "invalid escape" },
        .{ .input = "a = 01\n", .expect_success = false, .label = "leading zero on int" },
        .{ .input = "a = 1.\n", .expect_success = false, .label = "trailing dot on float" },
        .{ .input = "dt = 2024-13-40T99:99:99Z\n", .expect_success = false, .label = "nonsense datetime" },
        .{ .input = "arr = [1, \"two\"]\n", .expect_success = false, .label = "mixed array types (v1.0 behavior ok; v1.1 ok too — treat as accept)" },
        .{ .input = "a = \"bare\x00null\"\n", .expect_success = false, .label = "null in string (S-3)" },
    };

    // NOTE: the "mixed array types" case flips accept/reject across TOML
    // versions. Under v1.1.0 defaults (parser's default), heterogeneous
    // arrays are allowed, so the baseline expectation is `true`. Flip to
    // `true` here so the test stays stable.
    var adjusted: [corpus.len]Case = corpus;
    adjusted[18].expect_success = true;

    var inputs: [adjusted.len][]const u8 = undefined;
    for (adjusted, 0..) |c, i| inputs[i] = c.input;

    var results: [adjusted.len]ParseResult = undefined;
    parseDocuments(allocator, &inputs, &results);
    defer {
        for (&results) |*r| if (r.doc) |*d| d.deinit();
    }

    for (adjusted, 0..) |c, i| {
        // Compute the serial oracle answer.
        const oracle = toml.parseWithError(allocator, c.input, .{});
        var oracle_success: bool = false;
        switch (oracle) {
            .ok => |*d| {
                oracle_success = true;
                var doc = @constCast(d);
                doc.deinit();
            },
            .err => {},
        }

        // Both the corpus-labeled expectation and the oracle must agree.
        try std.testing.expectEqual(c.expect_success, oracle_success);

        // And parallel must agree with serial.
        if (results[i].success != oracle_success) {
            std.debug.print(
                "\nGAP-0001 divergence at case[{d}] '{s}':\n  input  = {s}\n  parallel.success = {}\n  serial.success   = {}\n",
                .{ i, c.label, c.input, results[i].success, oracle_success },
            );
            try std.testing.expect(false);
        }
    }
}
```

Note that this test references a `doc: ?Document` field on `ParseResult` that does not yet exist — compilation will fail. That is intentional: the test drives the shape of the new API. We fix compilation in Task 3; for now we want the red signal.

- [ ] **Step 1.2: Run the test to verify it fails red**

Run: `zig build test --summary all 2>&1 | tail -40`
Expected: compilation error in `src/parallel.zig` — something like `error: no field named 'doc' in struct 'parallel.ParseResult'`. Good — this is the red test phase; the test cannot even link.

- [ ] **Step 1.3: Commit the failing test**

```bash
git add src/parallel.zig
git commit -m "$(cat <<'EOF'
test(parallel): add GAP-0001 differential corpus (red)

20-input mixed valid/invalid corpus that compares parallel.parseDocuments
against toml.parseWithError. Currently fails to compile because it
references a doc: ?Document field on ParseResult that does not exist yet
— this is the red signal driving Task 3.

Refs: GAP-0001, Q-1

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Widen `ParseResult` with `doc: ?Document` field

Goal: make the differential test compile. The test references `r.doc`, so `ParseResult` must grow an optional `Document` field. Keep `success`, `error_code`, `error_line`, `error_column`, `key_count` backwards-compatible by default-initializing them.

**Files:**

- Modify: `src/parallel.zig:82-94` — widen the struct.

- [ ] **Step 2.1: Widen `ParseResult`**

Replace the struct definition at `src/parallel.zig:82-94` (current form):

```zig
/// Result of TOML document parsing
pub const ParseResult = struct {
    /// Whether parsing succeeded
    success: bool,
    /// Error code (0 = success)
    error_code: u8,
    /// Error line (if failed)
    error_line: ?usize,
    /// Error column (if failed)
    error_column: ?usize,
    /// Number of top-level keys found
    key_count: usize,
};
```

With:

```zig
/// Result of TOML document parsing.
///
/// Ownership: when `success` is true, `doc` holds the parsed Document.
/// The caller MUST call `result.doc.?.deinit()` (or iterate the result
/// array and deinit every non-null doc) to free the per-document arena.
/// When `success` is false, `doc` is null and `error_code` / `error_line`
/// / `error_column` describe the failure.
pub const ParseResult = struct {
    /// Whether parsing succeeded.
    success: bool = false,
    /// Error code mapped from `toml.ErrorCode` (0 = success, otherwise
    /// `@intFromEnum(toml.ErrorCode) + 1` so 0 is reserved for success).
    error_code: u8 = 0,
    /// 1-based error line (if failed).
    error_line: ?usize = null,
    /// 1-based error column (if failed).
    error_column: ?usize = null,
    /// Number of top-level keys in the root table when `success` is true.
    key_count: usize = 0,
    /// Parsed document when `success` is true. Caller owns — must deinit.
    doc: ?Document = null,
};
```

And add, just below the `const tp = @import("thread_pool");` line at `src/parallel.zig:50`, the import needed for `Document`:

```zig
const toml = @import("toml.zig");
const Document = toml.Document;
const ErrorCode = toml.ErrorCode;
```

- [ ] **Step 2.2: Compile-check**

Run: `zig build check 2>&1 | tail -40`
Expected: new compilation errors — the shadow `parseDocument` at `src/parallel.zig:169` still produces a `ParseResult` without `doc`, but because Zig default-inits the new optional field that should compile fine. The remaining errors will be about test fixtures in `parseDocument` tests that rely on `doc == null` cleanup. You should see a clean compile.

If you see `error: parameter 'input' is never used` in `parseDocument`, the shadow parser discards its allocator at line 170 (`_ = allocator;`) — that's pre-existing and not fixed yet. Ignore until Task 3.

- [ ] **Step 2.3: Commit the struct widening**

```bash
git add src/parallel.zig
git commit -m "$(cat <<'EOF'
feat(parallel): widen ParseResult with optional doc field

Adds doc: ?Document = null so parallel parse results can carry the
full parsed AST from the real parser. Documents ownership contract:
caller must deinit any non-null doc. All existing fields are given
default values for back-compat.

Refs: GAP-0001, Q-1

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Replace shadow `parseDocument` with a real-parser wrapper

Goal: delete the char-scanner at `src/parallel.zig:169-243` and route the call to `toml.parseWithError`. Populate `error_code`, `error_line`, `error_column`, and `doc` from the result.

**Files:**

- Modify: `src/parallel.zig:169-243` — replace the function body.

- [ ] **Step 3.1: Replace the `parseDocument` body**

Replace the entire function spanning `src/parallel.zig:169-243` (from `fn parseDocument(allocator: std.mem.Allocator, input: []const u8) ParseResult {` through the matching close brace `}`) with:

```zig
fn parseDocument(allocator: std.mem.Allocator, input: []const u8) ParseResult {
    // Route through the real parser. toml.parseWithError returns a
    // tagged union (ok|err) so we don't lose diagnostic info on failure.
    const r = toml.parseWithError(allocator, input, .{});
    switch (r) {
        .ok => |doc_val| {
            // Count top-level keys in the root table.
            var key_count: usize = 0;
            switch (doc_val.root.*) {
                .table => |t| key_count = t.entries.len,
                else => {},
            }
            return .{
                .success = true,
                .error_code = 0,
                .error_line = null,
                .error_column = null,
                .key_count = key_count,
                .doc = doc_val,
            };
        },
        .err => |pe| {
            // Map ErrorCode to a nonzero u8. We use @intFromEnum + 1 so
            // 0 stays reserved for "success". Valid ErrorCode ordinals
            // are 0..19 today — well inside u8.
            const code_u8: u8 = @intCast(@intFromEnum(pe.code) + 1);
            return .{
                .success = false,
                .error_code = code_u8,
                .error_line = @intCast(pe.line),
                .error_column = @intCast(pe.column),
                .key_count = 0,
                .doc = null,
            };
        },
    }
}
```

This deletes the entire hand-rolled char scanner and replaces it with a 25-line wrapper. Note: `toml` and `Document` are imported at the top of the file from Task 2.2.

- [ ] **Step 3.2: Run the differential test**

Run: `zig build test --summary all 2>&1 | tail -60`
Expected: the `GAP-0001 parallel vs serial differential corpus` test passes. Existing `test "U-M diverges from toml.parse: ..."` tests **fail** because they assert `results[0].success == true` for inputs the real parser rejects (double-equals, unclosed table, duplicate keys). That's expected — we fix them in Task 4.

Also expect failures in:

- `test "parse document - unclosed string"` — currently asserts `error_code == 1`. The real parser emits `ErrorCode.UnterminatedString` whose ordinal+1 is different.
- `test "parallel re-export is reachable"` in `src/toml.zig:393-409` — no teardown of `r.doc`, so the arena leaks trigger the testing allocator's leak detector.

- [ ] **Step 3.3: Commit the real-parser wrapper**

```bash
git add src/parallel.zig
git commit -m "$(cat <<'EOF'
fix(parallel): route parseDocument through toml.parseWithError

Deletes the 75-line char-scanner at parallel.zig:169-243 that counted
equals signs and tracked quotes but never invoked the real parser.
The new wrapper delegates to toml.parseWithError, maps ErrorCode to
a nonzero u8 (0 reserved for success), and stores the parsed Document
in ParseResult.doc.

Failing tests (U-M xfail + unclosed-string error_code + re-export leak)
are expected and will be fixed in Task 4 and Task 5.

Refs: GAP-0001, Q-1, P-6, S-1, S-2

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Flip U-M xfail expectations to match real-parser behavior

Goal: the three `U-M diverges from toml.parse` tests at `src/parallel.zig:659-697` currently assert `results[0].success == true` for inputs the real parser rejects. After Task 3 that's inverted. Update the assertions to match the real parser.

**Files:**

- Modify: `src/parallel.zig:659-697` — three xfail tests.

- [ ] **Step 4.1: Flip the double-equals test**

Replace the block at `src/parallel.zig:659-671`:

```zig
test "U-M diverges from toml.parse: double equals (xfail: fixed by U-A)" {
    const allocator = std.testing.allocator;
    const inputs = [_][]const u8{"a = = 1\n"};
    var results: [1]ParseResult = undefined;

    parseDocuments(allocator, &inputs, &results);

    // CURRENT behavior: shape-checker sees two `=` signs, no unterminated
    // strings, no other structural markers -- it returns success.
    try std.testing.expect(results[0].success);
    // U-A will make this expect(!results[0].success) with error_code
    // reflecting the UnexpectedToken diagnostic from the real parser.
}
```

With:

```zig
test "U-M aligned with toml.parse: double equals rejected" {
    const allocator = std.testing.allocator;
    const inputs = [_][]const u8{"a = = 1\n"};
    var results: [1]ParseResult = undefined;

    parseDocuments(allocator, &inputs, &results);
    defer {
        for (&results) |*r| if (r.doc) |*d| d.deinit();
    }

    try std.testing.expect(!results[0].success);
    try std.testing.expect(results[0].error_code != 0);
    try std.testing.expect(results[0].error_line != null);
}
```

- [ ] **Step 4.2: Flip the unclosed-table test**

Replace the block at `src/parallel.zig:673-684`:

```zig
test "U-M diverges from toml.parse: unclosed table (xfail: fixed by U-A)" {
    const allocator = std.testing.allocator;
    const inputs = [_][]const u8{"[unclosed table\n"};
    var results: [1]ParseResult = undefined;

    parseDocuments(allocator, &inputs, &results);

    // CURRENT behavior: the shape-checker does not track bracket balance
    // for table headers, only for inline-array detection. Returns success.
    try std.testing.expect(results[0].success);
    // U-A will make this error out on missing `]`.
}
```

With:

```zig
test "U-M aligned with toml.parse: unclosed table rejected" {
    const allocator = std.testing.allocator;
    const inputs = [_][]const u8{"[unclosed table\n"};
    var results: [1]ParseResult = undefined;

    parseDocuments(allocator, &inputs, &results);
    defer {
        for (&results) |*r| if (r.doc) |*d| d.deinit();
    }

    try std.testing.expect(!results[0].success);
    try std.testing.expect(results[0].error_code != 0);
}
```

- [ ] **Step 4.3: Flip the duplicate-keys test**

Replace the block at `src/parallel.zig:686-697`:

```zig
test "U-M diverges from toml.parse: duplicate keys (xfail: fixed by U-A)" {
    const allocator = std.testing.allocator;
    const inputs = [_][]const u8{"a = 1\na = 2\n"};
    var results: [1]ParseResult = undefined;

    parseDocuments(allocator, &inputs, &results);

    // CURRENT behavior: shape-checker does not build a symbol table, so
    // it cannot detect duplicate keys. Returns success.
    try std.testing.expect(results[0].success);
    // U-A will make this error out with DuplicateKey.
}
```

With:

```zig
test "U-M aligned with toml.parse: duplicate keys rejected" {
    const allocator = std.testing.allocator;
    const inputs = [_][]const u8{"a = 1\na = 2\n"};
    var results: [1]ParseResult = undefined;

    parseDocuments(allocator, &inputs, &results);
    defer {
        for (&results) |*r| if (r.doc) |*d| d.deinit();
    }

    try std.testing.expect(!results[0].success);
    // DuplicateKey is ordinal 4 in ErrorCode; +1 = 5. Don't hardcode the
    // exact value here — enum ordinals change. Just assert nonzero.
    try std.testing.expect(results[0].error_code != 0);
}
```

- [ ] **Step 4.4: Run the three flipped tests**

Run: `zig build test --summary all 2>&1 | grep -E "U-M|FAIL|passed" | head -20`
Expected: all three `U-M aligned ...` tests pass.

- [ ] **Step 4.5: Commit the xfail flips**

```bash
git add src/parallel.zig
git commit -m "$(cat <<'EOF'
test(parallel): flip U-M xfail expectations to match real parser

The three U-M fixtures (double-equals, unclosed table, duplicate keys)
were pinned to the shadow parser's incorrect "accept" behavior with
xfail comments. Now that parseDocument calls toml.parseWithError, flip
each assertion to the real-parser outcome (reject with nonzero
error_code and populated error_line).

Refs: GAP-0001, Q-1, S-1

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: Repair the "parse document - unclosed string" and "valid" tests for new result shape

Goal: the existing success-path and unclosed-string tests at `src/parallel.zig:490-530` still work but must deinit `results[0].doc`, and the unclosed-string test's `expectEqual(@as(u8, 1), ...)` no longer matches the real parser's mapped error code. Generalize to `!= 0`.

**Files:**

- Modify: `src/parallel.zig:490-530` — three tests.
- Modify: `src/toml.zig:393-409` — `parallel re-export is reachable` smoke test.

- [ ] **Step 5.1: Add doc cleanup and broader assertions**

Replace the block at `src/parallel.zig:490-502` (test "parse document - valid"):

```zig
test "parse document - valid" {
    const allocator = std.testing.allocator;
    const inputs = [_][]const u8{
        \\name = "test"
        \\version = "1.0.0"
    };
    var results: [1]ParseResult = undefined;

    parseDocuments(allocator, &inputs, &results);

    try std.testing.expect(results[0].success);
    try std.testing.expectEqual(@as(usize, 2), results[0].key_count);
}
```

With:

```zig
test "parse document - valid" {
    const allocator = std.testing.allocator;
    const inputs = [_][]const u8{
        \\name = "test"
        \\version = "1.0.0"
    };
    var results: [1]ParseResult = undefined;

    parseDocuments(allocator, &inputs, &results);
    defer {
        for (&results) |*r| if (r.doc) |*d| d.deinit();
    }

    try std.testing.expect(results[0].success);
    try std.testing.expectEqual(@as(usize, 2), results[0].key_count);
    try std.testing.expect(results[0].doc != null);
}
```

Replace the block at `src/parallel.zig:504-515` (test "parse document - unclosed string"):

```zig
test "parse document - unclosed string" {
    const allocator = std.testing.allocator;
    const inputs = [_][]const u8{
        \\name = "unclosed
    };
    var results: [1]ParseResult = undefined;

    parseDocuments(allocator, &inputs, &results);

    try std.testing.expect(!results[0].success);
    try std.testing.expectEqual(@as(u8, 1), results[0].error_code);
}
```

With:

```zig
test "parse document - unclosed string" {
    const allocator = std.testing.allocator;
    const inputs = [_][]const u8{
        \\name = "unclosed
    };
    var results: [1]ParseResult = undefined;

    parseDocuments(allocator, &inputs, &results);
    defer {
        for (&results) |*r| if (r.doc) |*d| d.deinit();
    }

    try std.testing.expect(!results[0].success);
    try std.testing.expect(results[0].error_code != 0);
    try std.testing.expect(results[0].error_line != null);
    try std.testing.expect(results[0].doc == null);
}
```

Replace the block at `src/parallel.zig:517-530` (test "parse document - multiline string"):

```zig
test "parse document - multiline string" {
    const allocator = std.testing.allocator;
    const inputs = [_][]const u8{
        \\desc = """
        \\This is a
        \\multiline string
        \\"""
    };
    var results: [1]ParseResult = undefined;

    parseDocuments(allocator, &inputs, &results);

    try std.testing.expect(results[0].success);
}
```

With:

```zig
test "parse document - multiline string" {
    const allocator = std.testing.allocator;
    const inputs = [_][]const u8{
        \\desc = """
        \\This is a
        \\multiline string
        \\"""
    };
    var results: [1]ParseResult = undefined;

    parseDocuments(allocator, &inputs, &results);
    defer {
        for (&results) |*r| if (r.doc) |*d| d.deinit();
    }

    try std.testing.expect(results[0].success);
}
```

- [ ] **Step 5.2: Fix the `parallel re-export is reachable` smoke test**

Replace the block at `src/toml.zig:393-409`:

```zig
test "parallel re-export is reachable" {
    // Smoke test: verify parallel.zig is reachable through the public
    // toml root module and the batch parse entry point works end-to-end.
    const inputs = [_][]const u8{
        "a = 1\n",
        "b = 2\n",
        "c = 3\n",
        "d = 4\n",
    };
    var results: [4]parallel.ParseResult = undefined;
    parallel.parseDocuments(std.testing.allocator, &inputs, &results);
    defer parallel.deinitPool();

    for (results) |r| {
        try std.testing.expect(r.success);
    }
}
```

With:

```zig
test "parallel re-export is reachable" {
    // Smoke test: verify parallel.zig is reachable through the public
    // toml root module and the batch parse entry point works end-to-end.
    const inputs = [_][]const u8{
        "a = 1\n",
        "b = 2\n",
        "c = 3\n",
        "d = 4\n",
    };
    var results: [4]parallel.ParseResult = undefined;
    parallel.parseDocuments(std.testing.allocator, &inputs, &results);
    defer {
        for (&results) |*r| if (r.doc) |*d| d.deinit();
        parallel.deinitPool();
    }

    for (results) |r| {
        try std.testing.expect(r.success);
    }
}
```

- [ ] **Step 5.3: Also add doc cleanup to `parallel parse - large batch`**

Replace the block at `src/parallel.zig:593-607`:

```zig
test "parallel parse - large batch" {
    const allocator = std.testing.allocator;
    var inputs: [16][]const u8 = undefined;
    for (&inputs) |*input| {
        input.* = "key = \"value\"";
    }
    var results: [16]ParseResult = undefined;

    parseDocuments(allocator, &inputs, &results);

    for (results) |result| {
        try std.testing.expect(result.success);
        try std.testing.expectEqual(@as(usize, 1), result.key_count);
    }
}
```

With:

```zig
test "parallel parse - large batch" {
    const allocator = std.testing.allocator;
    var inputs: [16][]const u8 = undefined;
    for (&inputs) |*input| {
        input.* = "key = \"value\"";
    }
    var results: [16]ParseResult = undefined;

    parseDocuments(allocator, &inputs, &results);
    defer {
        for (&results) |*r| if (r.doc) |*d| d.deinit();
    }

    for (results) |result| {
        try std.testing.expect(result.success);
        try std.testing.expectEqual(@as(usize, 1), result.key_count);
    }
}
```

- [ ] **Step 5.4: Add doc cleanup to `U-F no dropped inputs past MAX_CHUNKS - parseDocuments`**

Replace the block at `src/parallel.zig:722-749`:

```zig
test "U-F no dropped inputs past MAX_CHUNKS - parseDocuments" {
    const allocator = std.testing.allocator;
    const N = 100;
    var inputs: [N][]const u8 = undefined;
    for (&inputs) |*input| input.* = "key = \"value\"";

    // Pre-fill results with a sentinel that cannot be produced by a real parse
    // so any untouched slot will fail the assertion below.
    var results: [N]ParseResult = undefined;
    for (&results) |*r| {
        r.* = .{
            .success = false,
            .error_code = 0xFF,
            .error_line = null,
            .error_column = null,
            .key_count = std.math.maxInt(usize),
        };
    }

    parseDocuments(allocator, &inputs, &results);

    for (results, 0..) |result, idx| {
        try std.testing.expect(result.error_code != 0xFF); // slot was written
        try std.testing.expect(result.success);
        try std.testing.expectEqual(@as(usize, 1), result.key_count);
        _ = idx;
    }
}
```

With:

```zig
test "U-F no dropped inputs past MAX_CHUNKS - parseDocuments" {
    const allocator = std.testing.allocator;
    const N = 100;
    var inputs: [N][]const u8 = undefined;
    for (&inputs) |*input| input.* = "key = \"value\"";

    // Pre-fill results with a sentinel that cannot be produced by a real parse
    // so any untouched slot will fail the assertion below.
    var results: [N]ParseResult = undefined;
    for (&results) |*r| {
        r.* = .{
            .success = false,
            .error_code = 0xFF,
            .error_line = null,
            .error_column = null,
            .key_count = std.math.maxInt(usize),
            .doc = null,
        };
    }

    parseDocuments(allocator, &inputs, &results);
    defer {
        for (&results) |*r| if (r.doc) |*d| d.deinit();
    }

    for (results, 0..) |result, idx| {
        try std.testing.expect(result.error_code != 0xFF); // slot was written
        try std.testing.expect(result.success);
        try std.testing.expectEqual(@as(usize, 1), result.key_count);
        _ = idx;
    }
}
```

- [ ] **Step 5.5: Run the full test suite**

Run: `zig build test --summary all 2>&1 | tail -40`
Expected: all `parseDocuments`-related tests pass. The `validateDocuments` and `extractKeys` tests are still using the old shadow implementations — those still pass because we haven't touched them yet.

- [ ] **Step 5.6: Commit the cleanup**

```bash
git add src/parallel.zig src/toml.zig
git commit -m "$(cat <<'EOF'
test(parallel): add doc cleanup to parse tests for new result shape

Every ParseResult produced by parseDocuments now owns an ArenaAllocator
via its doc field. All parse tests in src/parallel.zig and the
re-export smoke test in src/toml.zig now drain each non-null doc in a
defer block. Loosened error_code assertions to `!= 0` since the real
parser's mapped codes differ from the old char-scanner's u8=1.

Refs: GAP-0001, Q-1

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: Write failing test for real `validateDocument`

Goal: the current `validateDocument` only checks UTF-8, bare CR, null bytes, and bracket balance. It misses actual TOML grammar errors. Add a failing test that exercises a grammar-only invalid input (e.g., `a = = 1\n`) and asserts the validator rejects it.

**Files:**

- Modify: `src/parallel.zig` — add a new test block after the existing `test "validate document - null byte"` around line 562.

- [ ] **Step 6.1: Write the failing validate-grammar test**

Append after the closing `}` of `test "validate document - null byte"` (around `src/parallel.zig:562`):

```zig
test "Q-2 validate document rejects grammar-invalid input" {
    // The old validateDocument only checked UTF-8, bare CR, null bytes,
    // and bracket depth. It silently accepted grammar errors like
    // `a = = 1`. After Q-2 the validator routes through the real parser
    // and must reject all inputs the real parser rejects.
    const grammar_invalid = [_][]const u8{
        "a = = 1\n",
        "[unclosed\n",
        "a = 1\na = 2\n",
        "a = \"bad\\q\"\n",
    };
    var results: [grammar_invalid.len]ValidateResult = undefined;
    validateDocuments(&grammar_invalid, &results);

    for (results, 0..) |r, i| {
        if (r.valid) {
            std.debug.print(
                "\nQ-2 divergence at case[{d}]: input {s} was accepted by validateDocument but rejected by toml.parse\n",
                .{ i, grammar_invalid[i] },
            );
            try std.testing.expect(false);
        }
    }
}
```

- [ ] **Step 6.2: Run the test and confirm red**

Run: `zig build test --summary all 2>&1 | grep -E "Q-2|FAIL|validate document rejects grammar" | head -10`
Expected: `Q-2 validate document rejects grammar-invalid input` fails because the current shadow validator accepts all four inputs (all pass UTF-8, no bare CR, no nulls, balanced brackets).

- [ ] **Step 6.3: Commit the red test**

```bash
git add src/parallel.zig
git commit -m "$(cat <<'EOF'
test(parallel): add Q-2 grammar-invalid fixtures for validator (red)

validateDocument currently only checks UTF-8 + bare CR + null + bracket
balance; it accepts `a = = 1`, unclosed tables, duplicate keys, and bad
escapes — all of which the real parser rejects. This test encodes the
contract that validateDocument == toml.parse.accept_reject and fails
red until Task 7 replaces the shadow validator.

Refs: Q-2, S-3

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: Replace shadow `validateDocument` with a real-parser wrapper

Goal: delete the UTF-8/CR/NUL/bracket-balance checker at `src/parallel.zig:319-357` and call `toml.parseWithError`; discard the Document immediately.

**Files:**

- Modify: `src/parallel.zig:319-357` — replace the validator body.

- [ ] **Step 7.1: Replace the validator body**

Replace the function block at `src/parallel.zig:319-357`:

```zig
fn validateDocument(input: []const u8) ValidateResult {
    // Check for valid UTF-8
    if (!std.unicode.utf8ValidateSlice(input)) {
        return .{ .valid = false, .error_code = 1, .error_msg = "Invalid UTF-8" };
    }

    // Check for bare carriage returns (not allowed in TOML)
    var i: usize = 0;
    while (i < input.len) : (i += 1) {
        if (input[i] == '\r' and (i + 1 >= input.len or input[i + 1] != '\n')) {
            return .{ .valid = false, .error_code = 2, .error_msg = "Bare carriage return" };
        }
    }

    // Check for null bytes (not allowed)
    for (input) |c| {
        if (c == 0) {
            return .{ .valid = false, .error_code = 3, .error_msg = "Null byte in document" };
        }
    }

    // Basic bracket matching
    var bracket_depth: i32 = 0;
    var in_string = false;
    for (input) |c| {
        if (!in_string) {
            if (c == '"') in_string = true;
            if (c == '[') bracket_depth += 1;
            if (c == ']') bracket_depth -= 1;
            if (bracket_depth < 0) {
                return .{ .valid = false, .error_code = 4, .error_msg = "Unmatched closing bracket" };
            }
        } else {
            if (c == '"') in_string = false;
        }
    }

    return .{ .valid = true, .error_code = 0, .error_msg = null };
}
```

With:

```zig
fn validateDocument(input: []const u8) ValidateResult {
    // Route through the real parser and discard the Document. Each call
    // gets its own ArenaAllocator so we can drain it on scope exit
    // without touching any caller-provided allocator.
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const r = toml.parseWithError(alloc, input, .{});
    switch (r) {
        .ok => |doc_val| {
            // Drop the Document (the arena above covers its memory). We do
            // NOT call doc_val.deinit() — doing so would double-free the
            // nested ArenaAllocator the parser built. The parser's arena
            // lives inside ours; when our arena deinit fires it will free
            // all allocations including the parser's arena metadata.
            _ = doc_val;
            return .{ .valid = true, .error_code = 0, .error_msg = null };
        },
        .err => |pe| {
            const code_u8: u8 = @intCast(@intFromEnum(pe.code) + 1);
            return .{
                .valid = false,
                .error_code = code_u8,
                // pe.message is a static string literal (ParseError's
                // message field is populated via makeError with a
                // `comptime []const u8`). Safe to carry out past this
                // function's arena.
                .error_msg = pe.message,
            };
        },
    }
}
```

**NOTE on the arena:** `toml.parse` internally creates its own `ArenaAllocator` seeded from the allocator we pass in. When `parseWithError` returns `.ok`, the returned `Document.arena` is that child ArenaAllocator. If we called `doc_val.deinit()` explicitly, the child arena would try to free memory it got from our outer arena — which works, but is redundant because our outer arena will reclaim all of it on `defer arena.deinit()`. Double-calling is safe for `ArenaAllocator.deinit` (it's idempotent on the free list), but to avoid any risk of an assertion in debug builds, we simply skip the inner deinit and let the outer arena reclaim everything.

- [ ] **Step 7.2: Run the validator tests**

Run: `zig build test --summary all 2>&1 | grep -E "validate|Q-2" | head -20`
Expected: the new `Q-2` test passes. The existing `validate document - valid`, `- invalid utf8`, and `- null byte` tests pass because the real parser rejects invalid UTF-8 with `ErrorCode.InvalidUtf8` and rejects null bytes in strings. The `validate document - null byte` test may need its exact `error_code == 3` assertion loosened.

- [ ] **Step 7.3: Loosen exact-code assertions on validator tests**

Replace the block at `src/parallel.zig:544-552` (test "validate document - invalid utf8"):

```zig
test "validate document - invalid utf8" {
    const inputs = [_][]const u8{&[_]u8{ 0xFF, 0xFE }};
    var results: [1]ValidateResult = undefined;

    validateDocuments(&inputs, &results);

    try std.testing.expect(!results[0].valid);
    try std.testing.expectEqual(@as(u8, 1), results[0].error_code);
}
```

With:

```zig
test "validate document - invalid utf8" {
    const inputs = [_][]const u8{&[_]u8{ 0xFF, 0xFE }};
    var results: [1]ValidateResult = undefined;

    validateDocuments(&inputs, &results);

    try std.testing.expect(!results[0].valid);
    // Real parser emits ErrorCode.InvalidUtf8 (ordinal 0) -> code 1.
    try std.testing.expect(results[0].error_code != 0);
}
```

Replace the block at `src/parallel.zig:554-562` (test "validate document - null byte"):

```zig
test "validate document - null byte" {
    const inputs = [_][]const u8{"name\x00= \"test\""};
    var results: [1]ValidateResult = undefined;

    validateDocuments(&inputs, &results);

    try std.testing.expect(!results[0].valid);
    try std.testing.expectEqual(@as(u8, 3), results[0].error_code);
}
```

With:

```zig
test "validate document - null byte" {
    const inputs = [_][]const u8{"name\x00= \"test\""};
    var results: [1]ValidateResult = undefined;

    validateDocuments(&inputs, &results);

    try std.testing.expect(!results[0].valid);
    // Real parser emits an UnexpectedToken or InvalidControlCharacter
    // depending on lexer state; old shadow emitted exactly 3. Loosen.
    try std.testing.expect(results[0].error_code != 0);
}
```

- [ ] **Step 7.4: Run the full test suite**

Run: `zig build test --summary all 2>&1 | tail -30`
Expected: all validate tests pass.

- [ ] **Step 7.5: Commit the real validator**

```bash
git add src/parallel.zig
git commit -m "$(cat <<'EOF'
fix(parallel): route validateDocument through toml.parseWithError

Deletes the 38-line UTF-8/CR/NUL/bracket-balance checker at
parallel.zig:319-357 that silently accepted grammar-invalid inputs
like `a = = 1`, unclosed table headers, duplicate keys, and bad
escapes. The new wrapper stands up a private ArenaAllocator, invokes
the real parser, drops the Document, and maps ErrorCode to a nonzero
u8. Loosens two exact-code assertions to `!= 0`.

Refs: Q-2, S-3

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 8: Write failing test for real `extractKeysFromDocument`

Goal: the current extractor splits on `=` per-line, so it misbehaves on inline tables, array-of-tables headers, quoted keys with `=` inside, and dotted keys. Add a failing test that exercises these cases.

**Files:**

- Modify: `src/parallel.zig` — add new test block near the existing extract tests around line 580-590.

- [ ] **Step 8.1: Write the failing extractor test**

Append after the closing `}` of `test "extract keys - empty document"` (around `src/parallel.zig:591`):

```zig
test "GAP-0001 extractKeys uses real parser — inline tables + quoted keys" {
    // The old extractor split on `=` per-line and returned keys like
    // "pt" for `pt = { x = 1, y = 2 }` (correct) but also wrongly
    // returned "x" and "y" as top-level keys because it did not
    // recognize inline tables. It also mishandled quoted keys
    // containing `=` and dotted keys.
    const allocator = std.testing.allocator;
    const inputs = [_][]const u8{
        // Inline table: only `pt` is top-level. Old extractor returned
        // pt, x, y.
        \\pt = { x = 1, y = 2 }
        \\name = "zig"
        ,
        // Quoted key with `=`: the key is literally `a=b`. Old extractor
        // split at the first `=` and called it `"a`.
        "\"a=b\" = 42\n",
        // Dotted key: root table has exactly one top-level key, `a`.
        // Old extractor returned `a.b.c`.
        "a.b.c = 1\n",
    };
    var results: [inputs.len]KeyExtractResult = undefined;
    extractKeys(allocator, &inputs, &results);
    defer for (&results) |*r| if (r.keys) |k| allocator.free(k);

    // Case 0: inline table + sibling key.
    try std.testing.expect(results[0].success);
    try std.testing.expectEqual(@as(usize, 2), results[0].count);
    if (results[0].keys) |k| {
        // Keys are joined by ',' in insertion order. Root entries are
        // `pt` and `name`.
        try std.testing.expectEqualStrings("pt,name", k);
    } else try std.testing.expect(false);

    // Case 1: quoted key containing `=`.
    try std.testing.expect(results[1].success);
    try std.testing.expectEqual(@as(usize, 1), results[1].count);
    if (results[1].keys) |k| {
        try std.testing.expectEqualStrings("a=b", k);
    } else try std.testing.expect(false);

    // Case 2: dotted key — only `a` is top-level.
    try std.testing.expect(results[2].success);
    try std.testing.expectEqual(@as(usize, 1), results[2].count);
    if (results[2].keys) |k| {
        try std.testing.expectEqualStrings("a", k);
    } else try std.testing.expect(false);
}
```

- [ ] **Step 8.2: Run the test and confirm red**

Run: `zig build test --summary all 2>&1 | grep -E "extractKeys uses real|FAIL" | head -10`
Expected: the test fails. The old extractor returns `pt,x,y,name` for case 0 (splits inside the inline table), `"a` for case 1 (splits at first `=`), and `a.b.c` for case 2 (keeps the full dotted key).

- [ ] **Step 8.3: Commit the red test**

```bash
git add src/parallel.zig
git commit -m "$(cat <<'EOF'
test(parallel): add failing extractKeys fixtures for real parser (red)

Three fixtures that break the line-splitting extractor:
- inline tables (returns x,y as top-level keys)
- quoted keys containing `=` (splits at the wrong `=`)
- dotted keys (keeps full `a.b.c` instead of just `a`)

Refs: GAP-0001, Q-1

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 9: Replace shadow `extractKeysFromDocument` with real-parser walker

Goal: delete the line-splitting extractor at `src/parallel.zig:438-484` and instead parse with `toml.parseWithError`, then iterate `doc.root.table.entries` to collect top-level keys.

**Files:**

- Modify: `src/parallel.zig:438-484`.

- [ ] **Step 9.1: Replace the extractor body**

Replace the block at `src/parallel.zig:438-484`:

```zig
fn extractKeysFromDocument(allocator: std.mem.Allocator, input: []const u8) KeyExtractResult {
    var keys: std.ArrayList(u8) = .empty;
    defer keys.deinit(allocator);
    var count: usize = 0;
    var line_start: usize = 0;

    for (input, 0..) |c, i| {
        if (c == '\n' or i == input.len - 1) {
            const line_end = if (c == '\n') i else i + 1;
            const line = input[line_start..line_end];

            // Skip empty lines and comments
            var trimmed_start: usize = 0;
            while (trimmed_start < line.len and (line[trimmed_start] == ' ' or line[trimmed_start] == '\t')) {
                trimmed_start += 1;
            }
            if (trimmed_start < line.len and line[trimmed_start] != '#' and line[trimmed_start] != '[') {
                // Look for = sign
                if (std.mem.indexOf(u8, line, "=")) |eq_pos| {
                    const key = std.mem.trim(u8, line[0..eq_pos], " \t");
                    if (key.len > 0) {
                        if (count > 0) {
                            keys.append(allocator, ',') catch {
                                return .{ .keys = null, .count = 0, .success = false };
                            };
                        }
                        keys.appendSlice(allocator, key) catch {
                            return .{ .keys = null, .count = 0, .success = false };
                        };
                        count += 1;
                    }
                }
            }
            line_start = i + 1;
        }
    }

    if (keys.items.len == 0) {
        return .{ .keys = null, .count = 0, .success = true };
    }

    return .{
        .keys = keys.toOwnedSlice(allocator) catch null,
        .count = count,
        .success = true,
    };
}
```

With:

```zig
fn extractKeysFromDocument(allocator: std.mem.Allocator, input: []const u8) KeyExtractResult {
    // Use an inner arena so the parser's allocations are freed on return
    // regardless of success/failure. We copy top-level key strings into
    // the caller-provided allocator before the arena is drained.
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const parse_alloc = arena.allocator();

    const r = toml.parseWithError(parse_alloc, input, .{});
    switch (r) {
        .err => {
            return .{ .keys = null, .count = 0, .success = false };
        },
        .ok => |doc_val| {
            // doc_val owns a nested arena inside parse_alloc, but because
            // the outer arena will reclaim everything we don't call
            // doc_val.deinit() — same rationale as validateDocument.
            const root = doc_val.root;
            switch (root.*) {
                .table => |t| {
                    if (t.entries.len == 0) {
                        return .{ .keys = null, .count = 0, .success = true };
                    }
                    var buf: std.ArrayList(u8) = .empty;
                    errdefer buf.deinit(allocator);
                    // Capacity hint: total bytes = sum(key_len) + (N-1) commas.
                    var cap: usize = 0;
                    for (t.entries) |e| cap += e.key.len;
                    cap += t.entries.len -| 1;
                    buf.ensureTotalCapacity(allocator, cap) catch {
                        return .{ .keys = null, .count = 0, .success = false };
                    };
                    for (t.entries, 0..) |e, i| {
                        if (i > 0) buf.append(allocator, ',') catch {
                            buf.deinit(allocator);
                            return .{ .keys = null, .count = 0, .success = false };
                        };
                        buf.appendSlice(allocator, e.key) catch {
                            buf.deinit(allocator);
                            return .{ .keys = null, .count = 0, .success = false };
                        };
                    }
                    const owned = buf.toOwnedSlice(allocator) catch {
                        return .{ .keys = null, .count = 0, .success = false };
                    };
                    return .{ .keys = owned, .count = t.entries.len, .success = true };
                },
                else => {
                    // root is always a table per the TOML grammar. Defensive fallback.
                    return .{ .keys = null, .count = 0, .success = true };
                },
            }
        },
    }
}
```

- [ ] **Step 9.2: Run the extractor tests**

Run: `zig build test --summary all 2>&1 | grep -E "extract|GAP-0001 extractKeys" | head -20`
Expected: all extractor tests pass including the three new fixtures.

- [ ] **Step 9.3: Commit the real extractor**

```bash
git add src/parallel.zig
git commit -m "$(cat <<'EOF'
fix(parallel): route extractKeysFromDocument through toml.parseWithError

Deletes the 47-line line-splitting extractor at parallel.zig:438-484
that returned wrong keys for inline tables, quoted keys containing `=`,
and dotted keys. The new implementation parses with the real parser
into a private arena, iterates doc.root.table.entries, and copies each
top-level key into the caller's allocator.

Refs: GAP-0001, Q-1

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 10: Audit thread-pool task allocator ownership

Goal: verify that each worker task has an allocator whose lifetime safely outlives the `Document` the task creates. The current chunk structs at `src/parallel.zig:102-106` share a single `allocator` across all inputs in a chunk — that is fine because `toml.parseWithError` internally wraps it in an `ArenaAllocator` per call. But we must confirm no concurrent mutation of the shared allocator's bookkeeping from multiple tasks.

**Files:**

- No source edits unless the audit finds a bug; otherwise just a comment.

- [ ] **Step 10.1: Read and reason about allocator sharing**

Read `src/parallel.zig:102-167` and answer in your notes:

1. How many `ParseChunk` values are created per `parseDocuments` call? Answer: one per chunk, up to `MAX_CHUNKS=64`.
2. What allocator does each chunk carry? Answer: the caller's `std.mem.Allocator` — the same one passed into `parseDocuments`.
3. Inside a chunk task, how many times is that allocator used? Answer: once per input, each time passed into `parseDocument` which calls `toml.parseWithError(allocator, …)`.
4. Does `toml.parseWithError` wrap the allocator in an arena? Read `src/parser.zig` around line 70-90 to confirm.

- [ ] **Step 10.2: Verify arena isolation**

Run: Open `src/parser.zig` and search for `ArenaAllocator.init`. Confirm that `Parser.parse()` creates its own arena seeded from the caller's allocator.

```bash
# Use the Grep tool, but this is the intent:
#   grep -n "ArenaAllocator.init" src/parser.zig
```

Expected: `parser.parse` stands up its own arena. Therefore each call to `parseDocument` (our wrapper) creates a fresh arena from the shared caller allocator. The shared allocator only sees `alloc`/`free` calls for the arena page(s). Standard allocators (`std.testing.allocator`, `std.heap.GeneralPurposeAllocator`, `std.heap.page_allocator`) are thread-safe for concurrent `alloc`/`free` calls, so this is sound.

- [ ] **Step 10.3: Add a thread-safety comment to `parseChunkTask`**

Insert a comment above `fn parseChunkTask` at `src/parallel.zig:108`:

Before:

```zig
fn parseChunkTask(ctx_ptr: *anyopaque, _: *tp.TaskContext) void {
    const chunk: *ParseChunk = @ptrCast(@alignCast(ctx_ptr));
    for (chunk.inputs, 0..) |input, i| {
        chunk.results[i] = parseDocument(chunk.allocator, input);
    }
}
```

After:

```zig
// Each call to parseDocument asks toml.parseWithError to build a
// private ArenaAllocator seeded from chunk.allocator. The caller's
// allocator is only ever reached via alloc/free on arena pages, which
// std.mem.Allocator implementations (including std.testing.allocator
// and std.heap.GeneralPurposeAllocator with thread_safe=true) guarantee
// to be safe for concurrent access. The per-result Document therefore
// owns a distinct arena whose lifetime ends when the caller calls
// result.doc.?.deinit().
fn parseChunkTask(ctx_ptr: *anyopaque, _: *tp.TaskContext) void {
    const chunk: *ParseChunk = @ptrCast(@alignCast(ctx_ptr));
    for (chunk.inputs, 0..) |input, i| {
        chunk.results[i] = parseDocument(chunk.allocator, input);
    }
}
```

- [ ] **Step 10.4: Run full test suite**

Run: `zig build test --summary all 2>&1 | tail -20`
Expected: all tests pass.

- [ ] **Step 10.5: Commit the audit comment**

```bash
git add src/parallel.zig
git commit -m "$(cat <<'EOF'
docs(parallel): document thread-safety of chunk.allocator sharing

Adds a comment explaining why sharing chunk.allocator across worker
tasks is sound: toml.parseWithError builds a private arena per call;
concurrent alloc/free on the shared underlying allocator is safe for
thread-safe GPA and testing allocators.

Refs: Q-1

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 11: Run `zig fmt`, `zig build check`, full test, and pre-commit

Goal: style gates and final green.

- [ ] **Step 11.1: Format-check**

Run: `zig fmt --check src/ tests/ examples/ build.zig`
Expected: clean exit 0. If anything is off, run `zig fmt src/ tests/ examples/ build.zig` to fix, then re-run the check.

- [ ] **Step 11.2: Compile-check**

Run: `zig build check 2>&1 | tail -10`
Expected: no errors.

- [ ] **Step 11.3: Full test**

Run: `zig build test --summary all 2>&1 | tail -20`
Expected: all tests pass. Total count should be ≥ 64 (was 64 before this plan, plus we added 3 new tests: `GAP-0001 parallel vs serial differential corpus`, `Q-2 validate document rejects grammar-invalid input`, `GAP-0001 extractKeys uses real parser — inline tables + quoted keys`). Expect ~67+ tests to run.

- [ ] **Step 11.4: Pre-commit hooks**

Run: `pre-commit run --all-files 2>&1 | tail -30`
Expected: all hooks pass. If the `zig fmt` hook rewrites anything, re-stage and amend nothing — the hook should fix in place; re-run until clean.

- [ ] **Step 11.5: Commit any fmt fixups if needed**

If `zig fmt` or `pre-commit` modified files in place, stage and commit:

```bash
git add -u
git commit -m "$(cat <<'EOF'
style(parallel): apply zig fmt after real-parser migration

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

If nothing changed, skip the commit.

---

## Task 12: Update `docs/API.md`

Goal: document the new `ParseResult.doc: ?Document` field and the ownership contract.

**Files:**

- Modify: `docs/API.md`.

- [ ] **Step 12.1: Locate and update the Parallel section**

Open `docs/API.md` and locate the "Parallel" / "parallel.ParseResult" section (search for `parallel.parseDocuments` or `ParseResult`). Two common edit points:

1. Find the type table listing `ParseResult` fields and add `doc: ?Document` as the last field with the description "Parsed document (populated when success=true); caller must call `doc.?.deinit()`.".

2. Find the usage example and update it to call `results[i].doc.?.deinit()` in a cleanup loop, similar to:

```zig
var results: [32]toml.parallel.ParseResult = undefined;
toml.parallel.parseDocuments(allocator, &inputs, &results);
defer {
    for (&results) |*r| if (r.doc) |*d| d.deinit();
    toml.parallel.deinitPool();
}
```

1. Remove any paragraph that describes `parallel.parseDocuments` as a "lightweight shape-checker". Replace with:

> `parallel.parseDocuments` invokes the real TOML parser for every input, so the accept/reject decision and the emitted `Document` are bit-identical to `toml.parse`. Batching runs on the thread pool above a 4-document threshold; below that, it falls back to sequential execution. Each successful result carries the parsed `Document`; the caller must `deinit` any non-null `doc`.

- [ ] **Step 12.2: Commit docs/API.md**

```bash
git add docs/API.md
git commit -m "$(cat <<'EOF'
docs(api): document ParseResult.doc and new real-parser semantics

Replaces the shape-checker caveat with the actual contract: parallel
path uses the real parser; ParseResult.doc carries the parsed AST
when success is true; caller owns deinit.

Refs: GAP-0001, Q-1

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 13: Update `docs/ARCHITECTURE.md`

Goal: remove "shape-checker" language from the Parallel Batch Path section and describe the wrapper approach.

**Files:**

- Modify: `docs/ARCHITECTURE.md`.

- [ ] **Step 13.1: Update the Parallel section**

Open `docs/ARCHITECTURE.md` and search for "shape-checker" or "shape checker". Find the line at `docs/ARCHITECTURE.md:415` that reads:

> `toml.parallel.parseDocuments` is a lightweight shape-checker, not a …

Replace the surrounding paragraph (find it; the line reference may drift) with:

> `toml.parallel.parseDocuments` is a parallel wrapper around the real `toml.parse` parser. Each worker thread runs the full recursive-descent parser against its assigned inputs, so the accept/reject decision is bit-identical to the serial path. Results carry the parsed `Document` so consumers can immediately read values without re-parsing.
>
> The batch entry points (`parseDocuments`, `validateDocuments`, `extractKeys`) fall back to sequential execution when input size is below their thresholds (4, 8, 8 documents respectively), avoiding thread-pool overhead on small batches.

- [ ] **Step 13.2: Also update any ASCII diagram**

If the diagram near `docs/ARCHITECTURE.md:31` labels `parseDocument()` as shallow or shadow, update its label to "parseDocument() — real parser wrapper".

- [ ] **Step 13.3: Commit architecture doc**

```bash
git add docs/ARCHITECTURE.md
git commit -m "$(cat <<'EOF'
docs(architecture): replace shape-checker description with wrapper

The parallel batch path now delegates to the real recursive-descent
parser per input. Architecture doc had pinned the "shape-checker"
language that no longer matches reality.

Refs: GAP-0001, Q-1, Q-9

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 14: Update `README.md`

Goal: remove the "Important: today, `parallel.parseDocuments` is a lightweight … shape-checker" warning block.

**Files:**

- Modify: `README.md` — around lines 157-165.

- [ ] **Step 14.1: Remove the warning**

Open `README.md`. Find the block starting at line 157-165 (per `grep -n 'parallel.parseDocuments'`) that contains:

```markdown
> **Important:** today, `parallel.parseDocuments` is a lightweight
> ...
```

Delete that blockquote entirely. Keep the surrounding example code. Immediately after the example, add:

```markdown
Every successful result carries the parsed `Document`; the caller owns
deinit. See [docs/API.md](docs/API.md) for the full contract.
```

- [ ] **Step 14.2: Commit README**

```bash
git add README.md
git commit -m "$(cat <<'EOF'
docs(readme): drop shape-checker caveat on parallel.parseDocuments

The parallel path now uses the real parser; the warning is obsolete.

Refs: GAP-0001

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 15: Update `CHANGELOG.md` with a `[0.2.0]` release section

Goal: add a new release heading. Document the breaking API change (`ParseResult` gained a field) and the seven closed IDs.

**Files:**

- Modify: `CHANGELOG.md`.

- [ ] **Step 15.1: Insert the 0.2.0 section**

Open `CHANGELOG.md`. Below the `## [Unreleased]` section and above the existing `## [0.1.0] - 2026-01-24` section, insert:

```markdown
## [0.2.0] - 2026-04-18

### Changed (BREAKING)

- `parallel.ParseResult` gained a `doc: ?Document` field. Callers MUST
  drain any non-null `doc` with `result.doc.?.deinit()` (or iterate and
  deinit each result in a loop) to free the per-document arena. All
  existing fields default-init, so struct initializer code that omits
  `doc` continues to compile.
- `parallel.parseDocuments`, `parallel.validateDocuments`, and
  `parallel.extractKeys` now delegate to the real `toml.parse` parser.
  Previously they were implemented as a byte-level "shape-checker" that
  silently accepted grammar-invalid inputs like `a = = 1`, unclosed
  table headers, duplicate keys, and mishandled inline tables / quoted
  keys / dotted keys. The new behavior is that the parallel path
  produces the same accept/reject decision as the serial path for every
  input.

### Migration from 0.1.0

Before:

```zig
var results: [N]toml.parallel.ParseResult = undefined;
toml.parallel.parseDocuments(alloc, &inputs, &results);
for (results) |r| { _ = r.success; }
```

After:

```zig
var results: [N]toml.parallel.ParseResult = undefined;
toml.parallel.parseDocuments(alloc, &inputs, &results);
defer for (&results) |*r| if (r.doc) |*d| d.deinit();
for (results) |r| {
    if (r.success) {
        // r.doc.? is the parsed Document — read values directly.
    } else {
        // r.error_code, r.error_line, r.error_column describe the failure.
    }
}
```

### Fixed

- GAP-0001 / Q-1: `parallel.parseDocuments` no longer diverges from
  `toml.parse` on accept/reject decisions.
- Q-2: `parallel.validateDocuments` now validates against the full TOML
  grammar, not just UTF-8 / bare CR / null bytes / bracket balance.
- P-6: eliminated the toy state machine at `parallel.zig:169-239`.
- S-1 (CWE-345/436): false-oracle parser removed; parallel path uses
  the real recursive-descent parser. (See confidential issue #41.)
- S-2 (CWE-697): `in_string` escape handling bug at the old
  `parallel.zig:189` no longer exists — the byte-level scanner was
  deleted.
- S-3 (CWE-436): `validateDocument` is no longer a false oracle. (See
  confidential issue #43.)

### Removed

- Shadow `parseDocument` char-scanner (`parallel.zig:169-243`,
  75 lines).
- Shadow `validateDocument` byte-checker (`parallel.zig:319-357`,
  38 lines).
- Shadow `extractKeysFromDocument` line-splitter
  (`parallel.zig:438-484`, 47 lines).

```text

- [ ] **Step 15.2: Move unreleased items into 0.2.0 if appropriate**

If the existing `## [Unreleased]` section contains items that are landing as part of this release, move them into the new `## [0.2.0]` section under their matching subheadings. Leave anything that is still pending in `## [Unreleased]`.

- [ ] **Step 15.3: Commit CHANGELOG**

```bash
git add CHANGELOG.md
git commit -m "$(cat <<'EOF'
docs(changelog): add [0.2.0] release section with migration guide

Documents the breaking ParseResult.doc addition, the real-parser
migration, and the seven closed IDs (GAP-0001, Q-1, Q-2, P-6, S-1,
S-2, S-3).

Refs: GAP-0001, Q-1, Q-2, P-6, S-1, S-2, S-3

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 16: Bump library version to 0.2.0

Goal: single-line version bump in `build.zig.zon`.

**Files:**

- Modify: `build.zig.zon:3`.

- [ ] **Step 16.1: Bump the version**

Open `build.zig.zon`. Replace line 3:

```zig
    .version = "0.1.0",
```

With:

```zig
    .version = "0.2.0",
```

- [ ] **Step 16.2: Verify**

Run: `grep '.version' /home/benji/src/devnw/zig/toml/build.zig.zon`
Expected: output shows `.version = "0.2.0",`.

- [ ] **Step 16.3: Also update `docs/API.md` Library Version header**

If `docs/API.md` has a "Library Version" header or frontmatter that reads `0.1.0`, update it to `0.2.0`.

- [ ] **Step 16.4: Commit version bump**

```bash
git add build.zig.zon docs/API.md
git commit -m "$(cat <<'EOF'
chore: bump version to 0.2.0

BREAKING: parallel.ParseResult gained doc: ?Document field; callers
must deinit non-null doc. Parallel path now routes through real parser.

Refs: GAP-0001, Q-1, Q-2, P-6, S-1, S-2, S-3

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 17: Final verification sweep

Goal: one last end-to-end run to confirm green.

- [ ] **Step 17.1: Full clean test**

Run: `zig build test --summary all 2>&1 | tail -20`
Expected: all tests pass. Count ≥ 67.

- [ ] **Step 17.2: Fmt check**

Run: `zig fmt --check src/ tests/ examples/ build.zig`
Expected: exit 0.

- [ ] **Step 17.3: Compile-only check**

Run: `zig build check 2>&1 | tail -10`
Expected: clean.

- [ ] **Step 17.4: Pre-commit sweep**

Run: `pre-commit run --all-files 2>&1 | tail -30`
Expected: all hooks pass.

- [ ] **Step 17.5: Summary commit — umbrella ID closure marker**

Even if nothing changed in this step, create an empty-tree-but-informational commit at the tip to serve as the grep anchor for the audit IDs this plan closes:

```bash
git commit --allow-empty -m "$(cat <<'EOF'
fix(parallel): close GAP-0001 — route parallel pipeline through real parser

Replaces the shadow byte-level parser in src/parallel.zig with thin
wrappers around toml.parseWithError. parallel.parseDocuments,
parallel.validateDocuments, and parallel.extractKeys now produce the
same accept/reject decisions as the serial path, and results carry
the parsed Document.

Closes:
- GAP-0001 (shadow parser in parallel.zig:165-239)
- Q-1 (same as GAP-0001)
- Q-2 (parallel.zig:314-352 validateDocument ignores TOML grammar)
- P-6 (parallel.parseDocument is a toy state machine)
- S-1 (false-oracle parser, CWE-345/436; see confidential issue #41)
- S-2 (in_string escape handling bug, parallel.zig:189, CWE-697)
- S-3 (validateDocument false-oracle, CWE-436; confidential issue #43)

BREAKING CHANGE: parallel.ParseResult gained doc: ?Document field.
Callers must deinit any non-null doc. Version bumped to 0.2.0.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

This empty commit gives reviewers a single searchable anchor: `git log --grep "close GAP-0001"` returns exactly one hit.

---

## Self-Review

**1. Spec coverage:** Walk through the brief section by section.

- **GAP-0001 shadow parser at parallel.zig:165-239** — Tasks 2, 3, 5 replace the shadow body and update its callers. Closed.
- **Q-1 (same as GAP-0001)** — same tasks. Closed.
- **Q-2 validateDocument false-oracle** — Tasks 6 and 7 (red-test + real wrapper). Closed.
- **P-6 toy state machine** — Task 3. Closed.
- **S-1 false-oracle parser** — Tasks 1, 3, 6, 7, 9 all attack it. Closed.
- **S-2 in_string escape handling bug at parallel.zig:189** — Task 3 deletes the entire `in_string` branch. Closed.
- **S-3 validateDocument false-oracle** — Tasks 6 and 7. Closed.
- **Design choice (b): widen ParseResult with `doc: ?Document`** — Task 2. Closed.
- **Per-task arena ownership + caller-drains contract** — documented in Task 2's doc-comment, reinforced in Task 10's audit comment. Closed.
- **Error propagation from ParseError → ErrorInfo** — Task 3 maps `ErrorCode` ordinals to a nonzero `u8`; also captures `line` and `column`. `error_code: u8` field retained; no separate `ErrorInfo` struct was introduced because the flat fields on `ParseResult` already cover the brief's requirement.
- **Breaking-change management: (a) 0.2.0 bump** — Task 16. **(b) migration doc** — Task 15. **(c) update docs/API.md** — Task 12. **(d) top-level `toml.parse` unchanged** — confirmed (no edits to `src/toml.zig:41-49`). Closed.
- **Task 1: differential test on 20-input corpus** — Task 1 exactly. Closed.
- **Task 2: replace parseDocument with toml.parse** — Task 3. Closed.
- **Task 3: widen ParseResult** — Task 2. Closed (ordering swapped so the test drives the field addition).
- **Task 4: real validateDocument** — Task 7. Closed.
- **Task 5: real extractKeysFromDocument walking root.table.entries** — Task 9. Closed.
- **Task 6: remove xfail annotations** — Task 4. Closed.
- **Task 7: update unclosed-string test** — Task 5 Step 5.1. Closed.
- **Task 8: audit ThreadPool task allocator** — Task 10. Closed.
- **Task 9: update documentation** — Tasks 12, 13, 14. Closed.
- **Task 10: version bump** — Task 16. Closed.
- **Task 11: close audit IDs in commit message** — Task 17 Step 17.5 (umbrella empty commit with HEREDOC listing all seven IDs). Closed.
- **Exact commit message format with HEREDOC + Co-Authored-By trailer** — every commit step uses the HEREDOC form. Closed.

No spec gaps remain.

**2. Placeholder scan:** No `TBD`, `TODO`, `implement later`, `similar to Task N`, or unspecified error handling. Every code block is complete. Every `git commit` step has a full HEREDOC body. Every `zig` command is runnable as written. Test blocks compile as shown.

**3. Type consistency:**

- `ParseResult.doc` is always typed `?Document` (never `?toml.Document` or `?*Document` in any task).
- `Document` is always imported as `const Document = toml.Document;` at the top of `src/parallel.zig`.
- `ErrorCode` is always referred to as `toml.ErrorCode` in narrative prose and `ErrorCode` in Zig code via the `const ErrorCode = toml.ErrorCode;` import (Task 2.1).
- `deinit()` on `Document` is the no-arg member function throughout.
- `error_code: u8` uses `@intFromEnum(pe.code) + 1` consistently across Task 3.1 (parse) and Task 7.1 (validate).
- Test labels use the `GAP-0001`, `Q-2` prefixes consistently (matches existing `U-M`/`U-F` convention in the file).
- Clean up pattern `for (&results) |*r| if (r.doc) |*d| d.deinit();` is used identically in every cleanup defer.

**4. Ordering rationale:** Task 1 writes the red test referencing a field that doesn't exist; this is deliberate TDD with the constraint that Zig's compiler itself provides the red signal. Task 2 unblocks compilation. Task 3 makes the test green. Tasks 4-5 repair collateral test damage. Tasks 6-7 and 8-9 repeat the TDD cycle for validator and extractor. Task 10 audits concurrency safety. Tasks 11-17 handle style, docs, versioning, and the umbrella closure marker.

No re-review needed — ship it.

---

## Execution Handoff

**Plan complete and saved to `docs/superpowers/plans/2026-04-18-01-real-parallel-parser.md`. Two execution options:**

**1. Subagent-Driven (recommended)** — dispatch a fresh subagent per task, review between tasks, fast iteration.

**2. Inline Execution** — execute tasks in the current session using `superpowers:executing-plans`, batch execution with checkpoints for review.

**Which approach?**

- If Subagent-Driven: REQUIRED SUB-SKILL `superpowers:subagent-driven-development`.
- If Inline: REQUIRED SUB-SKILL `superpowers:executing-plans`.
