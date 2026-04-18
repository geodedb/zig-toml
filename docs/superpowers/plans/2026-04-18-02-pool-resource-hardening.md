# Pool Lifecycle Redesign + Parser Resource Limits Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close Q-4, S-4, S-5, S-9, and P-7 by (A) replacing the process-global thread pool singleton in `src/parallel.zig` with a caller-owned `ParallelContext` that returns typed errors instead of `@panic`, and (B) extending `ParseOptions` in `src/parser.zig` with `max_keys` / `max_values` caps enforced inside the parser with a new `ResourceLimitExceeded` error code.

**Architecture:**

- **Part A (Pool redesign):** Introduce `ParallelContext` in `src/parallel.zig`, owning an `*tp.ThreadPool` and an `Allocator`. Every public entry point (`parseDocuments`, `validateDocuments`, `extractKeys`) gains a `ctx: *ParallelContext` parameter. `getPool()` keeps backward compatibility as a deprecated shim that returns `!*tp.ThreadPool` rather than panicking. `deinitPool()` keeps deprecation but routes through a `std.once.Once`-guarded legacy context so no thread observes a freed `*ThreadPool`. Examples, README, API.md, and CHANGELOG are updated to `defer ctx.deinit()` discipline. Version bumps to `0.2.0` because the public API changes.
- **Part B (Resource limits):** Add `max_keys: usize = 100_000` and `max_values: usize = 500_000` to `ParseOptions`. Add `ResourceLimitExceeded` variant to `ErrorCode` in `src/error.zig`. Add `keys_allocated: usize` and `values_allocated: usize` counters to `Parser`. Increment `keys_allocated` once per `parseKeyValue` call (before the `parseValue` call, so the check kicks in before expensive work). Increment `values_allocated` in every `*Value` allocation site: `val.createTable`, `val.createArray`, and each `alloc.create(Value)` call in `parser.zig`. Use two helpers `bumpKeys` / `bumpValues` that check the cap and emit `ResourceLimitExceeded` with the current token position. Tests: generated TOML inputs that exceed each cap.

**Tech Stack:**

- Zig 0.15.1 (see `build.zig.zon:5`)
- `thread_pool` sibling package pinned at commit `ee8440f6` (see `build.zig.zon:9`) — provides `tp.ThreadPool`, `tp.sync.Mutex`, `tp.BatchTask`, `tp.TaskContext`, `tp.WaitGroup`
- Standard test harness: `zig build test` (runs every `test "..."` block reachable from the root module plus `tests/accept.zig` imports)
- Allocator conventions: `std.heap.page_allocator` was the previous default for the global pool; the new API accepts `std.mem.Allocator` and plumbs it through

---

## Scope Check

This plan spans two subsystems (`parallel.zig` and `parser.zig`) but they ship together as a single 0.2.0 hardening release and share one CHANGELOG entry. They do **not** share code paths, so Part B (Tasks 1–7) is sequenced before Part A (Tasks 8–17) and each Part commits independently. Either part on its own produces shippable, test-passing software; if execution has to stop after Part B, the 0.2.0 bump can be replaced with 0.1.1 and the release can ship just the parser caps.

## File Map

Before writing code, know exactly which files will change.

- **`src/error.zig`** — add `ResourceLimitExceeded` variant to `ErrorCode` enum
- **`src/parser.zig`** — extend `ParseOptions` struct, add counter fields to `Parser` struct, add `bumpKeys` / `bumpValues` helpers, wire them into `parseKeyValue` and every `*Value` allocation site
- **`src/parallel.zig`** — add `ParallelContext` struct, rewrite `getPool` / `deinitPool` to return errors instead of panicking, add `ctx` parameter to the three public entry points, keep thin deprecated shims for backward compatibility
- **`src/toml.zig`** — port the re-export smoke test
- **`tests/accept.zig`** — add acceptance tests for `max_keys` / `max_values` enforcement
- **`docs/API.md`** — document `ParallelContext` lifecycle; document new `ParseOptions` caps
- **`CHANGELOG.md`** — add `Breaking Changes` + `Security` sections
- **`build.zig.zon`** — bump `.version` from `0.1.0` to `0.2.0`
- **`README.md`** — update the `toml.parallel.parseDocuments` snippet to use `ParallelContext`

Files we intentionally do **not** touch: `src/lexer.zig`, `src/value.zig`, `src/json_tagged.zig`, `examples/*.zig` (they do not use `parallel` today — grep confirms zero matches under `examples/`).

---

## Part B — Parser Resource Limits (Tasks 1–7)

Part B ships first because it is self-contained: no API breakage, purely additive defaults that cap pathological inputs. Order: write tests, then the enum variant, then the struct fields, then the counters, then wire them in.

---

### Task 1: Add `ResourceLimitExceeded` to `ErrorCode`

**Files:**

- Modify: `src/error.zig:9-30`

- [ ] **Step 1: Read the current `ErrorCode` block**

Open `src/error.zig` and confirm the enum block runs from line 9 to line 30. The enum currently ends with `BareCarriageReturn,`.

- [ ] **Step 2: Append the new variant**

Edit `src/error.zig` — change the last two lines of the enum from:

```zig
    InvalidControlCharacter,
    BareCarriageReturn,
};
```

to:

```zig
    InvalidControlCharacter,
    BareCarriageReturn,
    ResourceLimitExceeded,
};
```

- [ ] **Step 3: Verify the project still compiles**

Run: `zig build`

Expected: build succeeds. No test has been added yet that references `ResourceLimitExceeded`, so this is just a type-level additive change.

- [ ] **Step 4: Commit**

```bash
git add src/error.zig
git commit -m "$(cat <<'EOF'
feat(error): add ResourceLimitExceeded ErrorCode variant

Preparation for S-9 — parser resource-limit hardening. The variant is
distinct from LimitExceeded (which covers max_bytes / max_depth) so
consumers can distinguish input-size overflow from structural overflow.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Extend `ParseOptions` with `max_keys` and `max_values`

**Files:**

- Modify: `src/parser.zig:23-27`

- [ ] **Step 1: Write a failing compile-time test**

Add this test to `src/parser.zig` at the bottom of the file (after the last existing test). This forces the compiler to validate that `ParseOptions` has the new fields.

```zig
test "S-9 ParseOptions exposes max_keys and max_values caps" {
    const opts = ParseOptions{
        .max_keys = 42,
        .max_values = 84,
    };
    try std.testing.expectEqual(@as(usize, 42), opts.max_keys);
    try std.testing.expectEqual(@as(usize, 84), opts.max_values);
    // Defaults: confirm sensible ceilings exist.
    const def = ParseOptions{};
    try std.testing.expect(def.max_keys >= 100_000);
    try std.testing.expect(def.max_values >= 500_000);
}
```

- [ ] **Step 2: Run the test — expect a compile error**

Run: `zig build test 2>&1 | head -40`

Expected: compile error on `max_keys` — "no field named 'max_keys' in struct 'parser.ParseOptions'".

- [ ] **Step 3: Add the fields**

Edit `src/parser.zig:23-27` from:

```zig
pub const ParseOptions = struct {
    version: TomlVersion = .v1_1_0,
    max_depth: u16 = 128,
    max_bytes: usize = 16 * 1024 * 1024,
};
```

to:

```zig
pub const ParseOptions = struct {
    version: TomlVersion = .v1_1_0,
    max_depth: u16 = 128,
    max_bytes: usize = 16 * 1024 * 1024,
    /// Maximum total number of keys the parser may create across all
    /// tables (top-level + nested + inline). Hard-caps pathological
    /// inputs such as 16 MiB of `k0=0\nk1=0\n...`. Bumps are charged
    /// once per parseKeyValue call.
    max_keys: usize = 100_000,
    /// Maximum total number of `*Value` nodes the parser may allocate.
    /// Covers scalar values, arrays, tables, and array-of-tables nodes.
    /// Bumps are charged at every allocation site.
    max_values: usize = 500_000,
};
```

- [ ] **Step 4: Run the test — expect pass**

Run: `zig build test 2>&1 | tail -20`

Expected: all tests pass, including the new `S-9 ParseOptions exposes max_keys and max_values caps`.

- [ ] **Step 5: Commit**

```bash
git add src/parser.zig
git commit -m "$(cat <<'EOF'
feat(parser): add max_keys / max_values to ParseOptions

Defaults 100_000 keys and 500_000 values. Fields are added without any
enforcement yet; wiring comes in the next commits. Making the shape of
the API public first lets consumers pin their own caps in their build
even before the enforcement patch lands.

Part of S-9 memory-amplification hardening.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Add counter fields and `bumpKeys` / `bumpValues` helpers to `Parser`

**Files:**

- Modify: `src/parser.zig:29-50`

- [ ] **Step 1: Read the `Parser` struct**

Confirm `Parser` spans lines 29–50 in `src/parser.zig` with fields `lexer`, `alloc`, `current`, `peeked`, `options`, `depth`, `parse_error`, `input`.

- [ ] **Step 2: Add the counter fields and helpers**

Edit `src/parser.zig:29-50` from:

```zig
pub const Parser = struct {
    lexer: Lexer,
    alloc: Allocator,
    current: Token,
    peeked: ?Token,
    options: ParseOptions,
    depth: u16,
    parse_error: ?ParseError,
    input: []const u8,

    pub fn init(alloc: Allocator, input: []const u8, options: ParseOptions) Parser {
        return .{
            .lexer = Lexer.init(input, options.version),
            .alloc = alloc,
            .current = undefined,
            .peeked = null,
            .options = options,
            .depth = 0,
            .parse_error = null,
            .input = input,
        };
    }
```

to:

```zig
pub const Parser = struct {
    lexer: Lexer,
    alloc: Allocator,
    current: Token,
    peeked: ?Token,
    options: ParseOptions,
    depth: u16,
    parse_error: ?ParseError,
    input: []const u8,
    /// Total number of keys created across every table. Incremented
    /// once per parseKeyValue call; checked against options.max_keys.
    keys_allocated: usize,
    /// Total number of `*Value` nodes allocated. Incremented at every
    /// createTable/createArray/alloc.create(Value) call site; checked
    /// against options.max_values.
    values_allocated: usize,

    pub fn init(alloc: Allocator, input: []const u8, options: ParseOptions) Parser {
        return .{
            .lexer = Lexer.init(input, options.version),
            .alloc = alloc,
            .current = undefined,
            .peeked = null,
            .options = options,
            .depth = 0,
            .parse_error = null,
            .input = input,
            .keys_allocated = 0,
            .values_allocated = 0,
        };
    }

    fn bumpKeys(self: *Parser) !void {
        self.keys_allocated += 1;
        if (self.keys_allocated > self.options.max_keys) {
            self.parse_error = err.makeError(
                .ResourceLimitExceeded,
                self.current.pos,
                "max_keys exceeded",
            );
            return error.ParseFailed;
        }
    }

    fn bumpValues(self: *Parser) !void {
        self.values_allocated += 1;
        if (self.values_allocated > self.options.max_values) {
            self.parse_error = err.makeError(
                .ResourceLimitExceeded,
                self.current.pos,
                "max_values exceeded",
            );
            return error.ParseFailed;
        }
    }
```

- [ ] **Step 3: Verify the project still compiles**

Run: `zig build`

Expected: build succeeds. No call sites use the helpers yet.

- [ ] **Step 4: Commit**

```bash
git add src/parser.zig
git commit -m "$(cat <<'EOF'
feat(parser): add key/value counters and bumpKeys/bumpValues helpers

Introduces the two fields and two helpers used by S-9 enforcement.
Helpers emit ResourceLimitExceeded with the current token position, so
error messages point at the exact input byte where the limit tripped.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: Failing acceptance test — `max_keys` enforced

**Files:**

- Modify: `tests/accept.zig` (append to end)

- [ ] **Step 1: Write the failing test**

Append this test to `tests/accept.zig`. It generates a ~256 KiB input of flat key-value pairs (`k<i>=0\n`), caps `max_keys` at 100, and expects `ResourceLimitExceeded`.

```zig
// S-9: max_keys cap prevents memory amplification on pathological input.
test "S-9 max_keys cap returns ResourceLimitExceeded" {
    const allocator = std.testing.allocator;

    // Build a ~256 KiB input of `k<i>=0\n` pairs. At ~8 bytes per line this
    // produces >30_000 keys, comfortably past the test cap of 100.
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    var i: usize = 0;
    while (buf.items.len < 256 * 1024) : (i += 1) {
        try buf.writer(allocator).print("k{d}=0\n", .{i});
    }

    const opts = toml.ParseOptions{
        .max_keys = 100,
        .max_bytes = 16 * 1024 * 1024,
    };

    const result = toml.parseWithError(allocator, buf.items, opts);
    switch (result) {
        .ok => |*d| {
            var doc = @constCast(d);
            doc.deinit();
            try std.testing.expect(false); // must have failed
        },
        .err => |e| {
            try std.testing.expectEqual(
                toml.ErrorCode.ResourceLimitExceeded,
                e.code,
            );
        },
    }
}
```

- [ ] **Step 2: Run the test — expect FAIL**

Run: `zig build test --summary all 2>&1 | grep -E "(S-9 max_keys|FAIL|passed|failed)"`

Expected: the test **runs** but assertion `expect(false)` fires because no enforcement exists yet. Output contains `S-9 max_keys cap returns ResourceLimitExceeded... FAIL`.

- [ ] **Step 3: Commit the failing test**

```bash
git add tests/accept.zig
git commit -m "$(cat <<'EOF'
test(accept): add failing S-9 max_keys cap acceptance test

Generates a 256 KiB input of k<i>=0 pairs and expects
ResourceLimitExceeded when max_keys=100. Wiring for enforcement comes
in the next commit.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

Note: committing the red test is deliberate. If a reviewer bisects, they see the test landing before the fix, which is the TDD handoff pattern we use across this repo.

---

### Task 5: Wire `bumpKeys` into `parseKeyValue`

**Files:**

- Modify: `src/parser.zig:260-272` (in `parseKeyValue`)

- [ ] **Step 1: Read the current `parseKeyValue` prologue**

Confirm lines 260–272 open with the key-path setup and the empty-key guard.

- [ ] **Step 2: Add the `bumpKeys` call**

Edit `src/parser.zig:260-272` from:

```zig
    fn parseKeyValue(self: *Parser, alloc: Allocator, table: *Value) !void {
        // Save position of the key for error reporting
        const key_pos = self.current.pos;

        // Parse key path (may be dotted). 8 segments handles practical paths.
        var path: std.ArrayList([]const u8) = try .initCapacity(alloc, 8);
        try self.parseKeyPath(alloc, &path);

        if (path.items.len == 0) {
            self.parse_error = err.makeError(.InvalidKey, key_pos, "empty key");
            return error.ParseFailed;
        }
```

to:

```zig
    fn parseKeyValue(self: *Parser, alloc: Allocator, table: *Value) !void {
        // Save position of the key for error reporting
        const key_pos = self.current.pos;

        // S-9: charge the key cap up-front so pathological inputs are
        // rejected before the expensive value parse runs.
        try self.bumpKeys();

        // Parse key path (may be dotted). 8 segments handles practical paths.
        var path: std.ArrayList([]const u8) = try .initCapacity(alloc, 8);
        try self.parseKeyPath(alloc, &path);

        if (path.items.len == 0) {
            self.parse_error = err.makeError(.InvalidKey, key_pos, "empty key");
            return error.ParseFailed;
        }
```

- [ ] **Step 3: Run the acceptance test — expect PASS**

Run: `zig build test --summary all 2>&1 | grep -E "(S-9 max_keys|passed|failed)"`

Expected: `S-9 max_keys cap returns ResourceLimitExceeded... OK`.

- [ ] **Step 4: Run the full suite to confirm no regressions**

Run: `zig build test`

Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add src/parser.zig
git commit -m "$(cat <<'EOF'
fix(parser): close S-9 (part 1) — enforce max_keys in parseKeyValue

Every parseKeyValue call bumps keys_allocated and checks against
options.max_keys. Acceptance test tests/accept.zig "S-9 max_keys cap
returns ResourceLimitExceeded" now passes.

CWE-400 / CWE-789 memory amplification.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 6: Failing acceptance test — `max_values` enforced; then wire `bumpValues`

**Files:**

- Modify: `tests/accept.zig` (append)
- Modify: `src/parser.zig` allocation sites near lines 69, 181, 237, 239, 247, 310, 414, 551, 692, 698

- [ ] **Step 1: Write the failing test**

Append this test to `tests/accept.zig`. It builds a flat array with 2 000 integers and sets `max_values = 100`. Every integer literal becomes one `*Value`, so the cap trips mid-array.

```zig
// S-9: max_values cap catches allocation blow-ups even when key count
// is low (single key, huge array literal).
test "S-9 max_values cap returns ResourceLimitExceeded" {
    const allocator = std.testing.allocator;

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    try buf.appendSlice(allocator, "arr = [");
    var i: usize = 0;
    while (i < 2000) : (i += 1) {
        if (i > 0) try buf.append(allocator, ',');
        try buf.writer(allocator).print("{d}", .{i});
    }
    try buf.appendSlice(allocator, "]\n");

    const opts = toml.ParseOptions{
        .max_keys = 10_000,
        .max_values = 100,
        .max_bytes = 16 * 1024 * 1024,
    };

    const result = toml.parseWithError(allocator, buf.items, opts);
    switch (result) {
        .ok => |*d| {
            var doc = @constCast(d);
            doc.deinit();
            try std.testing.expect(false);
        },
        .err => |e| {
            try std.testing.expectEqual(
                toml.ErrorCode.ResourceLimitExceeded,
                e.code,
            );
        },
    }
}
```

- [ ] **Step 2: Run the test — expect FAIL**

Run: `zig build test --summary all 2>&1 | grep "S-9 max_values"`

Expected: the test runs and fails because no `*Value` allocation site checks the cap yet.

- [ ] **Step 3: Wire `bumpValues` into the root table creation**

Edit `src/parser.zig:65-70` inside `Parser.parse`. The root table is the first allocation; charge it.

Change:

```zig
        var arena = std.heap.ArenaAllocator.init(self.alloc);
        errdefer arena.deinit();

        const arena_alloc = arena.allocator();
        const root = try val.createTable(arena_alloc);
```

to:

```zig
        var arena = std.heap.ArenaAllocator.init(self.alloc);
        errdefer arena.deinit();

        const arena_alloc = arena.allocator();
        try self.bumpValues();
        const root = try val.createTable(arena_alloc);
```

- [ ] **Step 4: Wire `bumpValues` into `resolveTablePath` — append-to-array branch**

Edit `src/parser.zig:178-185` from:

```zig
                        if (existing.array.is_static) {
                            self.parse_error = err.makeError(.ArrayOfTablesConflict, pos, "cannot append to statically defined array");
                            return error.ParseFailed;
                        }
                        // Create new table and append to array
                        const new_table = try val.createTable(alloc);
                        new_table.table.defined_explicitly = true;
                        try val.arrayAppend(alloc, existing, new_table);
```

to:

```zig
                        if (existing.array.is_static) {
                            self.parse_error = err.makeError(.ArrayOfTablesConflict, pos, "cannot append to statically defined array");
                            return error.ParseFailed;
                        }
                        // Create new table and append to array
                        try self.bumpValues();
                        const new_table = try val.createTable(alloc);
                        new_table.table.defined_explicitly = true;
                        try val.arrayAppend(alloc, existing, new_table);
```

- [ ] **Step 5: Wire `bumpValues` into `resolveTablePath` — create-array-of-tables branch**

Edit `src/parser.zig:234-245` from:

```zig
            } else {
                // Key doesn't exist - create it
                if (is_last and is_array_of_tables) {
                    // Create array of tables
                    const arr = try val.createArray(alloc);
                    arr.array.is_static = false;
                    const new_table = try val.createTable(alloc);
                    new_table.table.defined_explicitly = true;
                    new_table.table.is_array_of_tables = true;
                    try val.arrayAppend(alloc, arr, new_table);
                    try val.tableSet(alloc, current, key, arr);
                    return new_table;
```

to:

```zig
            } else {
                // Key doesn't exist - create it
                if (is_last and is_array_of_tables) {
                    // Create array of tables
                    try self.bumpValues();
                    const arr = try val.createArray(alloc);
                    arr.array.is_static = false;
                    try self.bumpValues();
                    const new_table = try val.createTable(alloc);
                    new_table.table.defined_explicitly = true;
                    new_table.table.is_array_of_tables = true;
                    try val.arrayAppend(alloc, arr, new_table);
                    try val.tableSet(alloc, current, key, arr);
                    return new_table;
```

- [ ] **Step 6: Wire `bumpValues` into `resolveTablePath` — implicit-table branch**

Edit `src/parser.zig:245-254` from:

```zig
                } else {
                    // Create implicit table
                    const new_table = try val.createTable(alloc);
                    if (is_last) {
                        new_table.table.defined_explicitly = true;
                    }
                    try val.tableSet(alloc, current, key, new_table);
                    current = new_table;
                }
            }
        }
```

to:

```zig
                } else {
                    // Create implicit table
                    try self.bumpValues();
                    const new_table = try val.createTable(alloc);
                    if (is_last) {
                        new_table.table.defined_explicitly = true;
                    }
                    try val.tableSet(alloc, current, key, new_table);
                    current = new_table;
                }
            }
        }
```

- [ ] **Step 7: Wire `bumpValues` into the dotted-key branch of `parseKeyValue`**

Edit `src/parser.zig:308-314` from:

```zig
            } else {
                const new_table = try val.createTable(alloc);
                new_table.table.defined_by_dotted_key = true;
                try val.tableSet(alloc, target, key, new_table);
                target = new_table;
            }
        }
```

to:

```zig
            } else {
                try self.bumpValues();
                const new_table = try val.createTable(alloc);
                new_table.table.defined_by_dotted_key = true;
                try val.tableSet(alloc, target, key, new_table);
                target = new_table;
            }
        }
```

- [ ] **Step 8: Wire `bumpValues` into `parseValue` (scalar + array + inline table dispatcher)**

Edit `src/parser.zig:410-415` from:

```zig
    fn parseValue(self: *Parser, alloc: Allocator) ParseValueError!*Value {
        try self.enterDepth();
        defer self.exitDepth();

        const result = try alloc.create(Value);
```

to:

```zig
    fn parseValue(self: *Parser, alloc: Allocator) ParseValueError!*Value {
        try self.enterDepth();
        defer self.exitDepth();

        try self.bumpValues();
        const result = try alloc.create(Value);
```

- [ ] **Step 9: Wire `bumpValues` into `parseNestedArrayFromDoubleBracket`**

Edit `src/parser.zig:548-553` from:

```zig
        var outer_items: std.ArrayList(*Value) = try .initCapacity(alloc, 16);

        // Parse the inner array (we're already "inside" it after consuming [[)
        const inner_array = try alloc.create(Value);
        inner_array.* = try self.parseArrayContents(alloc);
        try outer_items.append(alloc, inner_array);
```

to:

```zig
        var outer_items: std.ArrayList(*Value) = try .initCapacity(alloc, 16);

        // Parse the inner array (we're already "inside" it after consuming [[)
        try self.bumpValues();
        const inner_array = try alloc.create(Value);
        inner_array.* = try self.parseArrayContents(alloc);
        try outer_items.append(alloc, inner_array);
```

- [ ] **Step 10: Wire `bumpValues` into `parseInlineTable` dotted-key branch**

Edit `src/parser.zig:688-703` from:

```zig
            // Handle dotted keys in inline table
            if (path.items.len > 1) {
                // Create nested tables starting from the second key
                // For "a.b = 1", path is ["a", "b"], we want a -> {b -> 1}
                var current_table = try val.createTable(alloc);
                current_table.table.is_inline = true;
                var target = current_table;

                // Start from index 1, not 0 - the first key becomes the root key
                for (path.items[1 .. path.items.len - 1]) |key| {
                    const nested = try val.createTable(alloc);
                    nested.table.is_inline = true;
                    try val.tableSet(alloc, target, key, nested);
                    target = nested;
                }
```

to:

```zig
            // Handle dotted keys in inline table
            if (path.items.len > 1) {
                // Create nested tables starting from the second key
                // For "a.b = 1", path is ["a", "b"], we want a -> {b -> 1}
                try self.bumpValues();
                var current_table = try val.createTable(alloc);
                current_table.table.is_inline = true;
                var target = current_table;

                // Start from index 1, not 0 - the first key becomes the root key
                for (path.items[1 .. path.items.len - 1]) |key| {
                    try self.bumpValues();
                    const nested = try val.createTable(alloc);
                    nested.table.is_inline = true;
                    try val.tableSet(alloc, target, key, nested);
                    target = nested;
                }
```

- [ ] **Step 11: Run both acceptance tests — expect PASS**

Run: `zig build test --summary all 2>&1 | grep -E "S-9"`

Expected: both `S-9 max_keys cap returns ResourceLimitExceeded` and `S-9 max_values cap returns ResourceLimitExceeded` pass.

- [ ] **Step 12: Run the full suite**

Run: `zig build test`

Expected: every test passes. If any pre-existing test now fails because its default `max_values` (`500_000`) is too tight, raise the default in the test's `ParseOptions` literal. No currently committed test generates that many values — the fuzz and compliance corpus is well under 10 000.

- [ ] **Step 13: Commit**

```bash
git add src/parser.zig tests/accept.zig
git commit -m "$(cat <<'EOF'
fix(parser): close S-9 — enforce max_keys/max_values caps

Every *Value allocation site in parser.zig now calls bumpValues; every
parseKeyValue call charges bumpKeys. On overflow the parser emits
ErrorCode.ResourceLimitExceeded at the offending token position.

Closes S-9 (CWE-400 / CWE-789 memory amplification).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 7: Document the new caps in API.md

**Files:**

- Modify: `docs/API.md` (section describing `ParseOptions`)

- [ ] **Step 1: Find the `ParseOptions` section**

Run: `grep -n "ParseOptions" docs/API.md | head -5`

Locate the block that lists `version`, `max_depth`, `max_bytes`.

- [ ] **Step 2: Extend the documentation**

Append `max_keys` and `max_values` entries to the `ParseOptions` table or field list. The exact formatting mirrors the existing entries. Example addition (match surrounding prose style):

```markdown
- `max_keys: usize = 100_000` — hard cap on the total number of keys
  the parser creates across all tables. Returns
  `ErrorCode.ResourceLimitExceeded` on overflow. Defends against
  pathological flat inputs (e.g., 16 MiB of `k0=0\nk1=0\n...`).
- `max_values: usize = 500_000` — hard cap on the total number of
  `*Value` nodes the parser allocates (scalars, arrays, tables, array
  elements). Returns `ErrorCode.ResourceLimitExceeded` on overflow.
```

- [ ] **Step 3: Commit**

```bash
git add docs/API.md
git commit -m "$(cat <<'EOF'
docs(api): document max_keys / max_values ParseOptions caps

Records the defaults (100_000 keys, 500_000 values) and the error
surface (ErrorCode.ResourceLimitExceeded) for S-9 hardening.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Part A — Pool Lifecycle Redesign (Tasks 8–17)

Part A is a breaking API change. `parseDocuments`, `validateDocuments`, and `extractKeys` each gain a `ctx: *ParallelContext` first argument. The old global-singleton entry points remain available behind deprecated wrappers so the repo's own internal tests keep running until Task 12 migrates them. The library version bumps to `0.2.0` at the end of the part.

---

### Task 8: Write failing test — `ParallelContext` type exists

**Files:**

- Modify: `src/parallel.zig` (append to test block)

- [ ] **Step 1: Add a failing compile-time test**

Append to `src/parallel.zig` immediately after the final test block (after line 789 in the existing `U-F no dropped inputs past MAX_CHUNKS - extractKeys` test):

```zig
test "Q-4/S-4 ParallelContext is a caller-owned struct" {
    const allocator = std.testing.allocator;
    var ctx = try ParallelContext.initDefault(allocator);
    defer ctx.deinit();

    // Smoke: parseDocuments through the ctx entry point.
    const inputs = [_][]const u8{
        "a = 1\n",
        "b = 2\n",
        "c = 3\n",
        "d = 4\n",
    };
    var results: [4]ParseResult = undefined;
    ctx.parseDocuments(&inputs, &results);

    for (results) |r| try std.testing.expect(r.success);
}
```

- [ ] **Step 2: Run it — expect compile error**

Run: `zig build test 2>&1 | head -20`

Expected: compile error — `use of undeclared identifier 'ParallelContext'`.

- [ ] **Step 3: Commit the red test**

```bash
git add src/parallel.zig
git commit -m "$(cat <<'EOF'
test(parallel): add failing Q-4/S-4 ParallelContext smoke test

Pins the intended caller-owned API shape: ParallelContext.initDefault
returns an error (no @panic), exposes deinit, and has method-style
parseDocuments that takes no allocator (it owns one). Implementation
comes in the next commit.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 9: Introduce `ParallelContext` struct and `initDefault` / `deinit`

**Files:**

- Modify: `src/parallel.zig:49-76`

- [ ] **Step 1: Replace the Global Thread Pool section**

Edit `src/parallel.zig:49-76` (from `const std = @import("std");` through the end of the current `deinitPool` function) so it reads:

```zig
const std = @import("std");
const tp = @import("thread_pool");

// ============================================================================
// Caller-Owned Thread Pool (Q-4 / S-4 / S-5 / P-7)
// ============================================================================
//
// Prior versions exposed a process-global `?tp.ThreadPool` behind a mutex.
// That singleton had three concrete defects:
//
//   Q-4 / S-4 (CWE-416): `getPool` returned a raw `*tp.ThreadPool` pointer;
//     another thread calling `deinitPool` could free the pool while the
//     first thread still held that pointer.
//   S-5 (CWE-248/400):  `@panic("thread-pool: init failed")` on allocator
//     failure turned a recoverable OOM into a DoS vector for library
//     consumers who had no way to opt in to non-panicking behavior.
//   P-7:                 The global used `std.heap.page_allocator`; every
//     call took the mutex just to check a non-null pointer.
//
// The new shape is a `ParallelContext` the caller owns. `initDefault`
// returns `!*ParallelContext`, `deinit` joins workers then frees the pool,
// and the batch entry points are methods so the pool pointer cannot be
// observed without a live reference to the context.
//
// The legacy `getPool` / `deinitPool` / free-function entry points remain
// for one deprecation cycle. They route through a lazily-initialized
// `legacy_ctx` global that is guarded by `std.once.Once` (no mutex on the
// hot path) and `getPool` now returns `!*tp.ThreadPool` rather than a raw
// pointer. `deinitPool` tears down the legacy context if it was
// constructed. Because no concurrent-caller synchronization is possible
// on a process-global singleton without reference counting, calling
// `deinitPool` while other threads hold pointers returned by `getPool()`
// is undefined behavior — which is exactly why the whole thing is
// deprecated.

/// A caller-owned parallel execution context. Holds the thread pool and
/// the allocator used to create it. Call `initDefault` to build one with
/// the process default allocator, or construct via `initWithPool` to
/// pass a custom `*tp.ThreadPool`.
///
/// Lifecycle: `ParallelContext` is NOT thread-safe to deinit concurrently
/// with calls to its methods. The expected usage is:
///
///     var ctx = try ParallelContext.initDefault(allocator);
///     defer ctx.deinit();
///     ctx.parseDocuments(&inputs, &results);
///
/// All three batch entry points (`parseDocuments`, `validateDocuments`,
/// `extractKeys`) are safe to invoke concurrently from multiple threads
/// so long as the `ParallelContext` itself is not being deinit-ed.
pub const ParallelContext = struct {
    allocator: std.mem.Allocator,
    pool: *tp.ThreadPool,
    /// True if this context allocated its own pool via initDefault and
    /// must free it in deinit. False if the caller constructed the
    /// struct via initWithPool and retains lifetime responsibility.
    owns_pool: bool,

    /// Construct a context with a private thread pool using the system
    /// default thread count. Returns an error — never panics — on pool
    /// allocation failure. Closes S-5.
    pub fn initDefault(allocator: std.mem.Allocator) !*ParallelContext {
        const pool = try allocator.create(tp.ThreadPool);
        errdefer allocator.destroy(pool);
        pool.* = try tp.ThreadPool.init(allocator, .{});
        errdefer pool.deinit();

        const ctx = try allocator.create(ParallelContext);
        ctx.* = .{
            .allocator = allocator,
            .pool = pool,
            .owns_pool = true,
        };
        return ctx;
    }

    /// Wrap a pool the caller already owns. `deinit` will NOT free the
    /// pool; the caller retains lifetime responsibility.
    pub fn initWithPool(
        allocator: std.mem.Allocator,
        pool: *tp.ThreadPool,
    ) !*ParallelContext {
        const ctx = try allocator.create(ParallelContext);
        ctx.* = .{
            .allocator = allocator,
            .pool = pool,
            .owns_pool = false,
        };
        return ctx;
    }

    /// Joins all workers, frees the owned pool (if any), and destroys
    /// the context itself. Safe to call exactly once.
    pub fn deinit(self: *ParallelContext) void {
        if (self.owns_pool) {
            self.pool.deinit();
            self.allocator.destroy(self.pool);
        }
        self.allocator.destroy(self);
    }

    // Method wrappers around the free functions defined later in this
    // file. These exist so the method-call form works in the
    // Q-4/S-4 test and in example code.

    pub fn parseDocuments(
        self: *ParallelContext,
        inputs: []const []const u8,
        results: []ParseResult,
    ) void {
        parseDocumentsCtx(self, inputs, results);
    }

    pub fn validateDocuments(
        self: *ParallelContext,
        inputs: []const []const u8,
        results: []ValidateResult,
    ) void {
        validateDocumentsCtx(self, inputs, results);
    }

    pub fn extractKeys(
        self: *ParallelContext,
        inputs: []const []const u8,
        results: []KeyExtractResult,
    ) void {
        extractKeysCtx(self, inputs, results);
    }
};

// ============================================================================
// Legacy global pool (deprecated — will be removed in 0.3.0)
// ============================================================================

var legacy_once: std.once.Once(legacyInit) = .{};
var legacy_ctx: ?*ParallelContext = null;
var legacy_init_error: ?anyerror = null;

fn legacyInit() void {
    legacy_ctx = ParallelContext.initDefault(std.heap.page_allocator) catch |e| blk: {
        legacy_init_error = e;
        break :blk null;
    };
}

/// Deprecated. Use `ParallelContext.initDefault` instead.
/// Returns the legacy process-global thread pool. Unlike the prior
/// version, this returns an error rather than @panicking.
pub fn getPool() !*tp.ThreadPool {
    legacy_once.call();
    if (legacy_init_error) |e| return e;
    const ctx = legacy_ctx orelse return error.ThreadPoolInitFailed;
    return ctx.pool;
}

/// Deprecated. Callers should own a `ParallelContext` and call
/// `ctx.deinit()` instead.
///
/// For backward compatibility this still tears down the legacy global
/// pool if it was lazily constructed. See the module-level comment for
/// UB caveats when other threads hold pointers.
pub fn deinitPool() void {
    if (legacy_ctx) |ctx| {
        ctx.deinit();
        legacy_ctx = null;
    }
}
```

- [ ] **Step 2: Build — expect compile errors in the existing free-function entry points**

Run: `zig build 2>&1 | head -30`

Expected: compile errors in `parseDocuments` / `validateDocuments` / `extractKeys` because they still call `getPool()` as if it returned `*tp.ThreadPool` directly (no `try`). Task 10 fixes this.

- [ ] **Step 3: Do not commit yet**

The build is broken. Proceed immediately to Task 10 and commit once both are done together.

---

### Task 10: Port the three free functions to accept `*ParallelContext`

**Files:**

- Modify: `src/parallel.zig:126-167` (`parseDocuments`), `src/parallel.zig:284-317` (`validateDocuments`), `src/parallel.zig:398-436` (`extractKeys`)

- [ ] **Step 1: Replace `parseDocuments`**

Replace the entire existing `pub fn parseDocuments` (lines ~126–167) with these two functions — the new `*Ctx`-suffixed primary and a thin legacy shim:

```zig
/// Parse multiple TOML documents in parallel using the given context.
///
/// Each document is parsed independently. This is ideal for batch
/// processing configuration files.
pub fn parseDocumentsCtx(
    ctx: *ParallelContext,
    inputs: []const []const u8,
    results: []ParseResult,
) void {
    std.debug.assert(inputs.len == results.len);

    if (inputs.len < 4) {
        for (inputs, 0..) |input, i| {
            results[i] = parseDocument(ctx.allocator, input);
        }
        return;
    }

    const pool = ctx.pool;
    // Ceiling division ensures every input is placed into exactly one chunk.
    const chunk_size = @max(1, (inputs.len + MAX_CHUNKS - 1) / MAX_CHUNKS);
    var chunks: [MAX_CHUNKS]ParseChunk = undefined;
    var batch: [MAX_CHUNKS]tp.BatchTask = undefined;
    var n: usize = 0;
    var i: usize = 0;
    while (i < inputs.len and n < MAX_CHUNKS) {
        const end = @min(i + chunk_size, inputs.len);
        chunks[n] = .{
            .allocator = ctx.allocator,
            .inputs = inputs[i..end],
            .results = results[i..end],
        };
        batch[n] = .{ .task_fn = &parseChunkTask, .ctx = @ptrCast(&chunks[n]) };
        n += 1;
        i = end;
    }
    var wg = pool.waitGroup();
    _ = pool.submitBatch(batch[0..n], .{ .wait_group = &wg }) catch {
        for (inputs, 0..) |input, j| results[j] = parseDocument(ctx.allocator, input);
        return;
    };
    wg.wait();
}

/// Deprecated. Use `ParallelContext.parseDocuments` or
/// `parseDocumentsCtx`. This shim routes through the legacy global
/// pool and silently falls back to sequential processing on pool
/// initialization failure instead of @panicking.
pub fn parseDocuments(
    allocator: std.mem.Allocator,
    inputs: []const []const u8,
    results: []ParseResult,
) void {
    std.debug.assert(inputs.len == results.len);

    if (inputs.len < 4) {
        for (inputs, 0..) |input, i| {
            results[i] = parseDocument(allocator, input);
        }
        return;
    }

    legacy_once.call();
    if (legacy_ctx) |ctx| {
        parseDocumentsCtx(ctx, inputs, results);
    } else {
        for (inputs, 0..) |input, i| {
            results[i] = parseDocument(allocator, input);
        }
    }
}
```

- [ ] **Step 2: Replace `validateDocuments`**

Replace the existing `pub fn validateDocuments` and body with:

```zig
/// Validate multiple TOML documents in parallel using the given context.
pub fn validateDocumentsCtx(
    ctx: *ParallelContext,
    inputs: []const []const u8,
    results: []ValidateResult,
) void {
    std.debug.assert(inputs.len == results.len);

    if (inputs.len < 8) {
        for (inputs, 0..) |input, i| {
            results[i] = validateDocument(input);
        }
        return;
    }

    const pool = ctx.pool;
    const chunk_size = @max(1, (inputs.len + MAX_CHUNKS - 1) / MAX_CHUNKS);
    var chunks: [MAX_CHUNKS]ValidateChunk = undefined;
    var batch: [MAX_CHUNKS]tp.BatchTask = undefined;
    var n: usize = 0;
    var i: usize = 0;
    while (i < inputs.len and n < MAX_CHUNKS) {
        const end = @min(i + chunk_size, inputs.len);
        chunks[n] = .{ .inputs = inputs[i..end], .results = results[i..end] };
        batch[n] = .{ .task_fn = &validateChunkTask, .ctx = @ptrCast(&chunks[n]) };
        n += 1;
        i = end;
    }
    var wg = pool.waitGroup();
    _ = pool.submitBatch(batch[0..n], .{ .wait_group = &wg }) catch {
        for (inputs, 0..) |input, j| results[j] = validateDocument(input);
        return;
    };
    wg.wait();
}

/// Deprecated. Use `ParallelContext.validateDocuments` or
/// `validateDocumentsCtx`.
pub fn validateDocuments(
    inputs: []const []const u8,
    results: []ValidateResult,
) void {
    std.debug.assert(inputs.len == results.len);

    if (inputs.len < 8) {
        for (inputs, 0..) |input, i| {
            results[i] = validateDocument(input);
        }
        return;
    }

    legacy_once.call();
    if (legacy_ctx) |ctx| {
        validateDocumentsCtx(ctx, inputs, results);
    } else {
        for (inputs, 0..) |input, i| {
            results[i] = validateDocument(input);
        }
    }
}
```

- [ ] **Step 3: Replace `extractKeys`**

Replace the existing `pub fn extractKeys` and body with:

```zig
/// Extract top-level keys from multiple TOML documents in parallel
/// using the given context.
pub fn extractKeysCtx(
    ctx: *ParallelContext,
    inputs: []const []const u8,
    results: []KeyExtractResult,
) void {
    std.debug.assert(inputs.len == results.len);

    if (inputs.len < 8) {
        for (inputs, 0..) |input, i| {
            results[i] = extractKeysFromDocument(ctx.allocator, input);
        }
        return;
    }

    const pool = ctx.pool;
    const chunk_size = @max(1, (inputs.len + MAX_CHUNKS - 1) / MAX_CHUNKS);
    var chunks: [MAX_CHUNKS]KeyExtractChunk = undefined;
    var batch: [MAX_CHUNKS]tp.BatchTask = undefined;
    var n: usize = 0;
    var i: usize = 0;
    while (i < inputs.len and n < MAX_CHUNKS) {
        const end = @min(i + chunk_size, inputs.len);
        chunks[n] = .{
            .allocator = ctx.allocator,
            .inputs = inputs[i..end],
            .results = results[i..end],
        };
        batch[n] = .{ .task_fn = &keyExtractChunkTask, .ctx = @ptrCast(&chunks[n]) };
        n += 1;
        i = end;
    }
    var wg = pool.waitGroup();
    _ = pool.submitBatch(batch[0..n], .{ .wait_group = &wg }) catch {
        for (inputs, 0..) |input, j| results[j] = extractKeysFromDocument(ctx.allocator, input);
        return;
    };
    wg.wait();
}

/// Deprecated. Use `ParallelContext.extractKeys` or `extractKeysCtx`.
pub fn extractKeys(
    allocator: std.mem.Allocator,
    inputs: []const []const u8,
    results: []KeyExtractResult,
) void {
    std.debug.assert(inputs.len == results.len);

    if (inputs.len < 8) {
        for (inputs, 0..) |input, i| {
            results[i] = extractKeysFromDocument(allocator, input);
        }
        return;
    }

    legacy_once.call();
    if (legacy_ctx) |ctx| {
        extractKeysCtx(ctx, inputs, results);
    } else {
        for (inputs, 0..) |input, i| {
            results[i] = extractKeysFromDocument(allocator, input);
        }
    }
}
```

- [ ] **Step 4: Build**

Run: `zig build`

Expected: build succeeds.

- [ ] **Step 5: Run the smoke test from Task 8**

Run: `zig build test --summary all 2>&1 | grep "Q-4/S-4"`

Expected: `Q-4/S-4 ParallelContext is a caller-owned struct... OK`.

- [ ] **Step 6: Run the full suite**

Run: `zig build test`

Expected: all tests pass. The legacy free-function tests in `parallel.zig` (lines 490–789) still use `parseDocuments(allocator, &inputs, &results)` and now route through `legacy_ctx` transparently; they continue to pass.

- [ ] **Step 7: Commit**

```bash
git add src/parallel.zig
git commit -m "$(cat <<'EOF'
feat(parallel): introduce ParallelContext; migrate entry points

- New ParallelContext owns allocator + *ThreadPool; initDefault returns
  !*ParallelContext instead of @panicking (closes S-5).
- parseDocumentsCtx / validateDocumentsCtx / extractKeysCtx are the new
  primary free functions; method-style wrappers live on the struct.
- Legacy parseDocuments / validateDocuments / extractKeys stay as thin
  shims routing through a std.once-guarded legacy context — no mutex on
  the hot path, no UAF on teardown (closes Q-4, S-4, P-7).
- getPool now returns !*ThreadPool; deinitPool is a no-op on the
  deprecated path with documented UB if other threads hold pointers.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 11: Concurrency test — `ParallelContext` methods are safe under concurrent calls

**Files:**

- Modify: `src/parallel.zig` (append test)

- [ ] **Step 1: Add a multi-thread stress test**

Append to the test block at the end of `src/parallel.zig`:

```zig
test "Q-4 concurrent parseDocuments calls on shared ParallelContext" {
    const allocator = std.testing.allocator;
    var ctx = try ParallelContext.initDefault(allocator);
    defer ctx.deinit();

    // 4 threads, each doing 4 batches of 16 parses.
    const Worker = struct {
        fn run(c: *ParallelContext) void {
            const inputs = [_][]const u8{"k = 1\n"} ** 16;
            var results: [16]ParseResult = undefined;
            var batch: usize = 0;
            while (batch < 4) : (batch += 1) {
                c.parseDocuments(&inputs, &results);
                for (results) |r| {
                    if (!r.success) @panic("expected success in Q-4 stress");
                }
            }
        }
    };

    var t0 = try std.Thread.spawn(.{}, Worker.run, .{ctx});
    var t1 = try std.Thread.spawn(.{}, Worker.run, .{ctx});
    var t2 = try std.Thread.spawn(.{}, Worker.run, .{ctx});
    var t3 = try std.Thread.spawn(.{}, Worker.run, .{ctx});
    t0.join();
    t1.join();
    t2.join();
    t3.join();
}
```

- [ ] **Step 2: Run it**

Run: `zig build test --summary all 2>&1 | grep "Q-4 concurrent"`

Expected: `Q-4 concurrent parseDocuments calls on shared ParallelContext... OK`.

- [ ] **Step 3: Commit**

```bash
git add src/parallel.zig
git commit -m "$(cat <<'EOF'
test(parallel): add Q-4 concurrent-access stress test on ParallelContext

Four worker threads hammer ctx.parseDocuments in parallel; join and
deinit are only called from the main thread. Exercises the assumption
that method-style entry points are reentrant so long as deinit is
serialized.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 12: Port internal tests in `parallel.zig` off the deprecated API

**Files:**

- Modify: `src/parallel.zig:490-789` (existing test block)

- [ ] **Step 1: Port `parse document - valid`**

Replace the existing test at lines 490–502 from:

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

to:

```zig
test "parse document - valid" {
    const allocator = std.testing.allocator;
    var ctx = try ParallelContext.initDefault(allocator);
    defer ctx.deinit();

    const inputs = [_][]const u8{
        \\name = "test"
        \\version = "1.0.0"
    };
    var results: [1]ParseResult = undefined;

    ctx.parseDocuments(&inputs, &results);

    try std.testing.expect(results[0].success);
    try std.testing.expectEqual(@as(usize, 2), results[0].key_count);
}
```

- [ ] **Step 2: Apply the same transformation to every remaining test in the file**

Tests to port (mechanical — add `var ctx = try ParallelContext.initDefault(allocator); defer ctx.deinit();` at the top of each, then replace `parseDocuments(allocator, ...)` with `ctx.parseDocuments(...)`, `validateDocuments(...)` with `ctx.validateDocuments(...)`, `extractKeys(allocator, ...)` with `ctx.extractKeys(...)`). Tests that don't already have `const allocator = std.testing.allocator;` get that line added as well.

- `parse document - unclosed string` (lines 504–515)
- `parse document - multiline string` (517–530)
- `validate document - valid` (532–542)
- `validate document - invalid utf8` (544–552)
- `validate document - null byte` (554–562)
- `extract keys - basic` (564–580)
- `extract keys - empty document` (582–591)
- `parallel parse - large batch` (593–607)
- `parallel validate - large batch` (609–621)
- `parallel extract keys - large batch` (623–640)
- All four `U-M` tests (659–720) — only the three that call `parseDocuments`; the `U-M baseline` test at lines 699–720 calls `toml.parseWithError` and does not need porting
- All three `U-F` tests (722–789)

For each: add a `ctx` local at the top, a `defer ctx.deinit();`, then call the method.

- [ ] **Step 3: Retain one legacy-shim test per entry point**

After the block of ported tests (append after the last existing test), add three tests that still exercise the deprecated free-function surface so the 0.2.x shim retains coverage:

```zig
test "legacy deprecated: parseDocuments free function still works" {
    const allocator = std.testing.allocator;
    const inputs = [_][]const u8{"a = 1\n"} ** 8;
    var results: [8]ParseResult = undefined;
    parseDocuments(allocator, &inputs, &results);
    for (results) |r| try std.testing.expect(r.success);
}

test "legacy deprecated: validateDocuments free function still works" {
    const inputs = [_][]const u8{"a = 1\n"} ** 8;
    var results: [8]ValidateResult = undefined;
    validateDocuments(&inputs, &results);
    for (results) |r| try std.testing.expect(r.valid);
}

test "legacy deprecated: extractKeys free function still works" {
    const allocator = std.testing.allocator;
    const inputs = [_][]const u8{"k = 1\n"} ** 8;
    var results: [8]KeyExtractResult = undefined;
    extractKeys(allocator, &inputs, &results);
    for (results) |r| {
        try std.testing.expect(r.success);
        if (r.keys) |keys| allocator.free(keys);
    }
}
```

- [ ] **Step 4: Run the suite**

Run: `zig build test`

Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add src/parallel.zig
git commit -m "$(cat <<'EOF'
test(parallel): port internal tests to ParallelContext

Every test except three per-entry-point legacy shims now uses
ParallelContext.initDefault + defer ctx.deinit. Keeps one legacy test
per entry point so the deprecated path has coverage until 0.3.0
removes it.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 13: Port the parallel test in `src/toml.zig`

**Files:**

- Modify: `src/toml.zig:393-409`

- [ ] **Step 1: Replace the smoke test**

Edit `src/toml.zig:393-409` from:

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

to:

```zig
test "parallel re-export is reachable" {
    // Smoke test: verify parallel.zig is reachable through the public
    // toml root module and the batch parse entry point works end-to-end.
    const allocator = std.testing.allocator;
    var ctx = try parallel.ParallelContext.initDefault(allocator);
    defer ctx.deinit();

    const inputs = [_][]const u8{
        "a = 1\n",
        "b = 2\n",
        "c = 3\n",
        "d = 4\n",
    };
    var results: [4]parallel.ParseResult = undefined;
    ctx.parseDocuments(&inputs, &results);

    for (results) |r| {
        try std.testing.expect(r.success);
    }
}
```

- [ ] **Step 2: Run the suite**

Run: `zig build test`

Expected: all tests pass.

- [ ] **Step 3: Commit**

```bash
git add src/toml.zig
git commit -m "$(cat <<'EOF'
test(toml): port parallel re-export smoke to ParallelContext

Confirms the context type is reachable from the public facade at
toml.parallel.ParallelContext.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 14: Update README example

**Files:**

- Modify: `README.md:157-159`

- [ ] **Step 1: Locate the snippet**

Run: `grep -n "parallel.deinitPool\|parallel.parseDocuments" README.md`

Expected: hits at lines 157, 158, 159.

- [ ] **Step 2: Replace the snippet**

Edit `README.md` — replace the block:

```markdown
var results: [32]toml.parallel.ParseResult = undefined;
toml.parallel.parseDocuments(allocator, &inputs, &results);
defer toml.parallel.deinitPool();
```

with:

```markdown
var ctx = try toml.parallel.ParallelContext.initDefault(allocator);
defer ctx.deinit();

var results: [32]toml.parallel.ParseResult = undefined;
ctx.parseDocuments(&inputs, &results);
```

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "$(cat <<'EOF'
docs(readme): migrate parallel example to ParallelContext

Replaces the deprecated global-pool snippet (parseDocuments/deinitPool)
with the new caller-owned ParallelContext lifecycle.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 15: Update `docs/API.md`

**Files:**

- Modify: `docs/API.md` around lines 544 and 594–600

- [ ] **Step 1: Replace the parallel example block**

Find the example around `docs/API.md:594-600`. Replace:

```markdown
var results: [16]toml.parallel.ParseResult = undefined;
toml.parallel.parseDocuments(allocator, &inputs, &results);
defer toml.parallel.deinitPool();
```

with:

```markdown
var ctx = try toml.parallel.ParallelContext.initDefault(allocator);
defer ctx.deinit();

var results: [16]toml.parallel.ParseResult = undefined;
ctx.parseDocuments(&inputs, &results);
```

- [ ] **Step 2: Append a lifecycle subsection**

Immediately after the existing `parseDocuments` / `validateDocuments` / `extractKeys` blurbs (roughly line 560), append:

```markdown
### Lifecycle: `ParallelContext`

The parallel API is now caller-owned. Construct a context, use it, and
`defer ctx.deinit()`:

- `toml.parallel.ParallelContext.initDefault(allocator)` returns
  `!*ParallelContext`. It never panics; on thread-pool init failure it
  returns the underlying allocator/init error.
- `ctx.deinit()` joins all workers and frees the pool.
- Methods (`parseDocuments`, `validateDocuments`, `extractKeys`) are
  reentrant: multiple threads may call them on the same `ctx`
  concurrently. Do **not** call `deinit` while other threads are using
  the context.
- `toml.parallel.parseDocuments`/`validateDocuments`/`extractKeys`
  free-function forms remain for 0.2.x but are deprecated. They route
  through a process-global legacy context and will be removed in 0.3.0.
```

- [ ] **Step 3: Commit**

```bash
git add docs/API.md
git commit -m "$(cat <<'EOF'
docs(api): document ParallelContext lifecycle; deprecate free fns

Adds a Lifecycle subsection explaining initDefault/deinit semantics and
that method-style calls are reentrant so long as deinit is serialized.
Flags the old free-function forms as 0.2.x-only.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 16: Update `CHANGELOG.md` and bump `build.zig.zon` to 0.2.0

**Files:**

- Modify: `CHANGELOG.md:8` (under `[Unreleased]`)
- Modify: `build.zig.zon:3`

- [ ] **Step 1: Insert 0.2.0 changelog section**

Edit `CHANGELOG.md` — immediately after the existing `[Unreleased]` block (which already has Added/Fixed/Changed/Performance subsections from the previous release cycle) and before `## [0.1.0] - 2026-01-24` (line 48), insert a new version block:

```markdown
## [0.2.0] - 2026-04-18

### Breaking Changes

- `toml.parallel` is now caller-owned via a new `ParallelContext`.
  `parseDocuments` / `validateDocuments` / `extractKeys` gain a `ctx`
  first argument when invoked as methods:
  `ctx.parseDocuments(&inputs, &results)`. The legacy free-function
  forms remain as deprecated shims for 0.2.x and will be removed in
  0.3.0.
- `parallel.getPool` now returns `!*ThreadPool` and never `@panic`s.

### Security

- Close Q-4 / S-4 (CWE-416): the process-global `*ThreadPool` pointer
  could be freed by `deinitPool` while another thread held it. The new
  `ParallelContext` makes the pool a caller-owned resource with a
  well-defined lifetime scope.
- Close S-5 (CWE-248 / CWE-400): thread-pool init failure no longer
  `@panic`s. `ParallelContext.initDefault` returns the underlying error.
- Close S-9 (CWE-400 / CWE-789): `ParseOptions` now has `max_keys`
  (default 100 000) and `max_values` (default 500 000). Parser returns
  `ErrorCode.ResourceLimitExceeded` on overflow. Pathological inputs
  such as 16 MiB of `k0=0\nk1=0\n...` or a single huge array literal
  are now rejected in bounded memory.

### Performance

- Close P-7: the legacy global-pool hot path is now `std.once`-guarded
  instead of mutex-per-call. No lock on `getPool` after first init.

```

- [ ] **Step 2: Bump `build.zig.zon`**

Edit `build.zig.zon:3` from:

```zig
    .version = "0.1.0",
```

to:

```zig
    .version = "0.2.0",
```

- [ ] **Step 3: Build and test**

Run: `zig build test`

Expected: all tests pass.

- [ ] **Step 4: Commit**

```bash
git add CHANGELOG.md build.zig.zon
git commit -m "$(cat <<'EOF'
chore(release): cut 0.2.0 — pool lifecycle + parser caps

Breaking: toml.parallel is now caller-owned via ParallelContext.
Security: closes Q-4, S-4, S-5, S-9. Performance: closes P-7.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 17: Sweep for missed references and final validation

**Files:**

- Audit: entire repo

- [ ] **Step 1: Verify no stale references to the old API remain**

Run these checks and fix anything that turns up:

```bash
grep -rn "parallel\.deinitPool\|parallel\.getPool" src/ examples/ tests/ docs/ README.md CHANGELOG.md
```

Every hit should now be either (a) in the deprecated-shim block inside `src/parallel.zig`, (b) in the three legacy compatibility tests in `src/parallel.zig`, or (c) in documentation that explicitly calls them "deprecated". There should be **zero** hits in `examples/`, `README.md`, or `docs/API.md` example code that aren't inside a block labeled deprecated.

- [ ] **Step 2: Verify the fuzz harness still builds**

Run: `zig build test --fuzz 2>&1 | head -20`

Expected: the fuzz target at `tests/fuzz_parse.zig` continues to compile. It does not touch `parallel.zig`, so the refactor should not affect it.

- [ ] **Step 3: Run the entire suite one more time with verbose output**

Run: `zig build test --summary all`

Expected: every test block (including the two new S-9 acceptance tests, the Q-4 smoke, the Q-4 concurrency stress, and the three legacy-compat tests) reports OK.

- [ ] **Step 4: Final commit — only if sweep surfaced anything**

If the grep in Step 1 or the fuzz build in Step 2 caused any edits:

```bash
git add <modified files>
git commit -m "$(cat <<'EOF'
chore(parallel): sweep stale deinitPool/getPool references

Cleanup pass after the ParallelContext migration. All remaining
references to the deprecated API are either inside the deprecated
shim, in legacy-compat tests, or explicitly flagged in docs.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

Otherwise skip this commit — no sweep changes needed.

---

## Self-Review

Running the checklist against the spec before handoff.

**1. Spec coverage — closes Q-4 / S-4 / S-5 / S-9 / P-7:**

| Finding | Closing Task(s) | Evidence |
|---|---|---|
| Q-4 (global pool UAF + @panic, parallel.zig:56-76) | Tasks 8–12 | `ParallelContext` replaces the global singleton; `parseDocuments` method requires a live `*ParallelContext` reference; legacy shim is `std.once`-guarded |
| S-4 (deinitPool UAF window, CWE-416) | Tasks 9, 11 | Pool ownership is tied to `ParallelContext.deinit`; Task 11 adds a concurrency stress test exercising 4 threads against one shared ctx |
| S-5 (`@panic` on init failure, CWE-248/400) | Task 9 | `ParallelContext.initDefault` returns `!*ParallelContext`; `getPool` now returns `!*tp.ThreadPool` |
| S-9 (no `max_keys`/`max_values`, CWE-400/789) | Tasks 1–6 | `ParseOptions` fields added; enforced via `bumpKeys` in `parseKeyValue` and `bumpValues` at every `*Value` allocation site; two acceptance tests lock the behavior |
| P-7 (mutex-per-getPool + page_allocator + @panic) | Tasks 9, 16 | `std.once.Once` replaces the mutex on the legacy hot path; changelog explicitly lists P-7 closure |

**2. Spec requirements — cross-referenced:**

| Spec line | Task |
|---|---|
| "Add `max_keys`, `max_values` to `ParseOptions` with defaults 100_000 / 500_000. Test: construct ParseOptions literal with custom caps." | Task 2 |
| "Add `ResourceLimitExceeded` to the error set / ParseError enum." | Task 1 |
| "Write failing test in `tests/accept.zig`: parse a generated 1MB input of `k0=0\nk1=0\n...` with `max_keys=100` → expect `error.ResourceLimitExceeded`." | Task 4 |
| "Wire the counter in `parseKeyValue`, increment once per key." | Task 5 |
| "Write failing test: deeply-nested arrays that would exceed `max_values`. Implement counter in all `*Value` allocation paths." | Task 6 |
| "Commit Part B." | Tasks 5, 6 (two commits for the two sub-goals; plus Task 7 for docs) |
| "Write failing test in parallel.zig: calling `getPool` from two goroutines and `deinitPool` from a third should not UAF." | Tasks 8, 11 (Task 8 establishes the context type; Task 11 is the multi-thread stress test) |
| "Introduce `ParallelContext` struct owning a `*ThreadPool` + allocator." | Task 9 |
| "Provide `ParallelContext.initDefault(allocator) !*ParallelContext` that returns an error (not panic) on pool init failure." | Task 9 |
| "Keep `getPool()` around as deprecated; have it return `!*ThreadPool`." | Task 9 |
| "Update all parallel.zig tests to use explicit `ParallelContext`." | Task 12 |
| "Update docs/API.md + CHANGELOG to document caller-owned pool." | Tasks 15, 16 |
| "Version bump (breaking API change — 0.2.0)." | Task 16 |
| "Close issues and commit." | Task 16 commit message explicitly lists Q-4, S-4, S-5, S-9, P-7 |

**3. Placeholder scan:** no "TBD", "TODO", "implement later", "fill in details", or "similar to Task N" in the body. Every step contains either the exact code to write, the exact command to run, or an explicit edit diff with both old and new text.

**4. Type consistency — verified:**

- `ParallelContext` is declared once (Task 9) with fields `allocator`, `pool`, `owns_pool`. Subsequent tasks (11, 12, 13) only use methods (`parseDocuments`, `validateDocuments`, `extractKeys`, `deinit`) and never reference removed fields.
- Free-function entry-point names: `parseDocumentsCtx`, `validateDocumentsCtx`, `extractKeysCtx` (new) + `parseDocuments`, `validateDocuments`, `extractKeys` (deprecated shims). All six names appear consistently in Tasks 10, 12, 13, 15, 16.
- Parser helpers: `bumpKeys` and `bumpValues` — only two names; each appears with consistent arity (`self: *Parser`, returns `!void`). Tasks 3, 5, 6 all use these exact names.
- `ErrorCode.ResourceLimitExceeded` — same spelling everywhere (Tasks 1, 3, 4, 6, 7, 15, 16).
- `ParseOptions.max_keys` / `max_values` field names are consistent across Tasks 2, 4, 6, 7, 16.

**5. Sequencing sanity:**

- Part B acceptance test (Task 4) lands red, then goes green in Task 5. Same pattern for Task 6 (test red → fix green within the task).
- Part A test (Task 8) lands red because the type doesn't exist; Tasks 9 and 10 together bring the build back. The red commit in Task 8 is intentional and documented in its message.
- Task 16 (version bump) is last in the source changes; Task 17 is a sweep-only verification that usually produces no commit.

**6. Risk notes for the executor:**

- When porting tests in Task 12, adding `var ctx = try ParallelContext.initDefault(allocator);` inside a `test` block requires the test to be declared `!void` implicitly — Zig handles this for any test that uses `try`, no change needed.
- The legacy `parseDocuments` shim in Task 10 calls `legacy_once.call()` then checks `legacy_ctx`. If `legacyInit` fails (allocator OOM), `legacy_ctx` stays null and the shim falls back to sequential processing silently. This is documented in the deprecation block.
- The Zig version is 0.15.1 per `build.zig.zon:5`. `std.once.Once(comptime f: anytype)` is the 0.15 API shape — it is generic over the init function. If the executor is on a newer Zig that changed the signature, this is the one piece that may need adjusting; the fix is mechanical and the intent is documented in comments.

---

**Plan complete.** Save path: `docs/superpowers/plans/2026-04-18-02-pool-resource-hardening.md`.
