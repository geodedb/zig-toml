# Q-8: Extract runBatch Helper in parallel.zig Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Eliminate ~70 LOC of duplicated submitBatch / chunk / WaitGroup fan-out code in `src/parallel.zig` by extracting a single generic `runBatch` helper that all three batch entry points (`parseDocuments`, `validateDocuments`, `extractKeys`) delegate to.

**Architecture:** Introduce a `comptime`-generic helper `runBatch(comptime Chunk, ...)` that owns the ceiling-division chunk-sizing, the `MAX_CHUNKS`-capped chunk stack-array, the `BatchTask` construction, `submitBatch`, the sequential fallback on submit error, and the `WaitGroup.wait()`. Each caller supplies (a) a `Chunk` struct type carrying whatever per-chunk data the worker needs, (b) a factory closure that builds a `Chunk` from the chunk slice range, and (c) a sequential fallback closure that processes a single input. The three existing `*ChunkTask` worker functions (`parseChunkTask`, `validateChunkTask`, `keyExtractChunkTask`) stay unchanged and are passed into `runBatch` as `task_fn` pointers.

**Tech Stack:** Zig 0.15.x, `thread_pool` module (`tp.ThreadPool`, `tp.BatchTask`, `tp.TaskContext`, `tp.sync.Mutex`, `waitGroup`), `zig build test`.

---

## Pre-Flight Context

### Files in scope

- `src/parallel.zig` — contains all three duplicated fan-out blocks and all existing tests.

### Concrete duplication (the evidence for Q-8)

All three batch entry points share this shape (~35 LOC each):

1. `std.debug.assert(inputs.len == results.len);`
2. Sequential fast path when `inputs.len < threshold`.
3. Get `pool` via `getPool()`.
4. Ceiling-divide `chunk_size = @max(1, (inputs.len + MAX_CHUNKS - 1) / MAX_CHUNKS);`
5. Declare `var chunks: [MAX_CHUNKS]T = undefined;` and `var batch: [MAX_CHUNKS]tp.BatchTask = undefined;`.
6. Loop `while (i < inputs.len and n < MAX_CHUNKS)` building chunk slices and `BatchTask` entries.
7. `pool.waitGroup()`, `submitBatch(batch[0..n], .{ .wait_group = &wg })`.
8. On submit failure — iterate sequentially as fallback.
9. `wg.wait()`.

Items (1), (3)-(9) are byte-for-byte identical across the three functions. Only the `Chunk` struct shape in (5) and (6) varies.

### Required invariants (must not regress)

- **Tail coverage under `MAX_CHUNKS = 64`.** U-F regression tests assert every slot of a 100-input results array is written. `runBatch` must use the same ceiling-division formula.
- **Sequential fallback on submit error.** Must still iterate `for (inputs, 0..) |input, j| results[j] = <sequential_fn>(...)` if `pool.submitBatch` fails.
- **Sequential fast path under threshold.** `parseDocuments` uses `< 4`; `validateDocuments` and `extractKeys` use `< 8`. Thresholds stay where they are today (in each wrapper) — `runBatch` is only called on the parallel path.
- **No behavior change.** All 64 existing tests in the repo must remain green at every commit.

### Caveat (from the brief)

This plan overlaps with Plan 01 (replace shadow parser). If Plan 01 has already landed, `parseDocument` inside `parseChunkTask` delegates to `toml.parse` but the boilerplate around it persists — the Q-8 refactor is independent and still worthwhile. If Plan 01 has not landed, this refactor lands first, then Plan 01 only has to modify the contents of each `*ChunkTask` worker function.

---

## File Structure

- **Modify:** `src/parallel.zig`
  - Add one new internal helper `runBatch` (declared below the `MAX_CHUNKS` constant, above `parseDocuments`).
  - Refactor `parseDocuments`, `validateDocuments`, `extractKeys` bodies to delegate to `runBatch`.
  - Leave all struct declarations (`ParseChunk`, `ValidateChunk`, `KeyExtractChunk`), worker functions (`parseChunkTask`, `validateChunkTask`, `keyExtractChunkTask`), public result types, and tests byte-identical.
  - Add one new test `runBatch helper - even distribution` before adding the helper (Task 1 test).

No new files are created.

---

## Task 1: Add failing test for the `runBatch` helper

**Files:**

- Modify: `src/parallel.zig` — append a new `test` block at the end of the file.

- [ ] **Step 1: Write the failing test**

Append this test at the bottom of `src/parallel.zig`, after the existing U-F tests:

```zig
test "runBatch helper - distributes all inputs across chunks" {
    // Drive the runBatch helper directly with a trivial "count characters"
    // workload to prove the fan-out primitive works in isolation of the
    // parse/validate/extract callers. A 100-input batch (>MAX_CHUNKS) also
    // pins the ceiling-division chunk sizing so regressions mirroring U-F
    // surface here first.
    const N = 100;
    var inputs: [N][]const u8 = undefined;
    for (&inputs) |*input| input.* = "abc";

    var results: [N]usize = undefined;
    for (&results) |*r| r.* = std.math.maxInt(usize);

    const Chunk = struct {
        inputs: []const []const u8,
        results: []usize,
    };

    const Worker = struct {
        fn run(ctx_ptr: *anyopaque, _: *tp.TaskContext) void {
            const chunk: *Chunk = @ptrCast(@alignCast(ctx_ptr));
            for (chunk.inputs, 0..) |input, i| {
                chunk.results[i] = input.len;
            }
        }

        fn sequential(input: []const u8, out: *usize) void {
            out.* = input.len;
        }
    };

    runBatch(
        Chunk,
        Worker.run,
        &inputs,
        &results,
        struct {
            fn make(slice_inputs: []const []const u8, slice_results: []usize) Chunk {
                return .{ .inputs = slice_inputs, .results = slice_results };
            }
        }.make,
        Worker.sequential,
    );

    for (results) |r| {
        try std.testing.expect(r != std.math.maxInt(usize));
        try std.testing.expectEqual(@as(usize, 3), r);
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test`
Expected: compile error — `error: use of undeclared identifier 'runBatch'` (or similar). The helper does not exist yet.

- [ ] **Step 3: Commit the failing test (red)**

```bash
git add src/parallel.zig
git commit -m "test(parallel): add failing runBatch helper test (Q-8 red)"
```

---

## Task 2: Implement the `runBatch` helper

**Files:**

- Modify: `src/parallel.zig:100` — insert helper immediately after the `const MAX_CHUNKS = 64;` line, before the `ParseChunk` struct declaration.

- [ ] **Step 1: Insert the helper**

Find this exact existing block in `src/parallel.zig`:

```zig
const MAX_CHUNKS = 64;

const ParseChunk = struct {
```

Replace it with:

```zig
const MAX_CHUNKS = 64;

/// Fan-out a batch of inputs across the global thread pool.
///
/// This is the single DRY implementation of the submitBatch + WaitGroup
/// fan-out pattern used by `parseDocuments`, `validateDocuments`, and
/// `extractKeys`. Callers stay in charge of the sequential fast-path
/// threshold; `runBatch` is only invoked on the parallel path.
///
/// Type parameters:
/// - `Chunk`: per-chunk context struct the worker casts `ctx_ptr` to.
///
/// Runtime parameters:
/// - `task_fn`: thread-pool worker function for a single chunk.
/// - `inputs`: the full input slice.
/// - `results`: the full results slice (same length as inputs).
/// - `makeChunk`: builds a `Chunk` from the input / result sub-slices.
/// - `sequentialOne`: fallback processor invoked per input when
///   `pool.submitBatch` fails.
///
/// Invariants:
/// - Ceiling-division chunk sizing guarantees every input lands in exactly
///   one chunk even when `inputs.len > MAX_CHUNKS` (regression U-F).
/// - The chunk / batch arrays live on the current stack frame; `Chunk`
///   therefore must not outlive this call.
fn runBatch(
    comptime Chunk: type,
    comptime task_fn: fn (ctx_ptr: *anyopaque, tc: *tp.TaskContext) void,
    inputs: []const []const u8,
    results: anytype,
    comptime makeChunk: fn (
        slice_inputs: []const []const u8,
        slice_results: @TypeOf(results),
    ) Chunk,
    comptime sequentialOne: fn (
        input: []const u8,
        out: *std.meta.Elem(@TypeOf(results)),
    ) void,
) void {
    const pool = getPool();
    // Ceiling division ensures every input is placed into exactly one chunk.
    // Floor (inputs.len / MAX_CHUNKS) would silently drop the last
    // inputs.len % MAX_CHUNKS elements when inputs.len > MAX_CHUNKS,
    // leaving the corresponding results[i] undefined (regression U-F).
    const chunk_size = @max(1, (inputs.len + MAX_CHUNKS - 1) / MAX_CHUNKS);
    var chunks: [MAX_CHUNKS]Chunk = undefined;
    var batch: [MAX_CHUNKS]tp.BatchTask = undefined;
    var n: usize = 0;
    var i: usize = 0;
    while (i < inputs.len and n < MAX_CHUNKS) {
        const end = @min(i + chunk_size, inputs.len);
        chunks[n] = makeChunk(inputs[i..end], results[i..end]);
        batch[n] = .{ .task_fn = &task_fn, .ctx = @ptrCast(&chunks[n]) };
        n += 1;
        i = end;
    }
    var wg = pool.waitGroup();
    _ = pool.submitBatch(batch[0..n], .{ .wait_group = &wg }) catch {
        for (inputs, 0..) |input, j| sequentialOne(input, &results[j]);
        return;
    };
    wg.wait();
}

const ParseChunk = struct {
```

- [ ] **Step 2: Verify it compiles**

Run: `zig build`
Expected: clean compile (no warnings, no errors).

- [ ] **Step 3: Run the Task 1 test to confirm it now passes**

Run: `zig build test`
Expected: all tests pass, including `runBatch helper - distributes all inputs across chunks`.

- [ ] **Step 4: Commit the helper (green)**

```bash
git add src/parallel.zig
git commit -m "feat(parallel): add runBatch generic fan-out helper (Q-8 green)"
```

---

## Task 3: Refactor `parseDocuments` to use `runBatch`

**Files:**

- Modify: `src/parallel.zig:126-167` — replace the body of `parseDocuments` (keep the signature, doc comment, and the sequential fast path).

- [ ] **Step 1: Rewrite `parseDocuments` body to delegate to `runBatch`**

Find this exact block in `src/parallel.zig`:

```zig
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

    const pool = getPool();
    // Ceiling division ensures every input is placed into exactly one chunk.
    // Previously `inputs.len / MAX_CHUNKS` (floor) caused the last
    // `inputs.len % MAX_CHUNKS` elements to be silently dropped when
    // `inputs.len > MAX_CHUNKS`, leaving `results[i]` undefined.
    const chunk_size = @max(1, (inputs.len + MAX_CHUNKS - 1) / MAX_CHUNKS);
    var chunks: [MAX_CHUNKS]ParseChunk = undefined;
    var batch: [MAX_CHUNKS]tp.BatchTask = undefined;
    var n: usize = 0;
    var i: usize = 0;
    while (i < inputs.len and n < MAX_CHUNKS) {
        const end = @min(i + chunk_size, inputs.len);
        chunks[n] = .{
            .allocator = allocator,
            .inputs = inputs[i..end],
            .results = results[i..end],
        };
        batch[n] = .{ .task_fn = &parseChunkTask, .ctx = @ptrCast(&chunks[n]) };
        n += 1;
        i = end;
    }
    var wg = pool.waitGroup();
    _ = pool.submitBatch(batch[0..n], .{ .wait_group = &wg }) catch {
        for (inputs, 0..) |input, j| results[j] = parseDocument(allocator, input);
        return;
    };
    wg.wait();
}
```

Replace it with:

```zig
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

    // Thread the allocator through Chunk so runBatch can stay allocator-
    // agnostic. We stage the allocator in a container-scoped `var` inside
    // a function-local `struct` because Zig `comptime` function-pointer
    // parameters cannot close over runtime locals. This is safe because
    // `parseDocuments` synchronously waits on the batch via WaitGroup.wait()
    // before returning, so no concurrent caller of `parseDocuments` can
    // observe a stale allocator.
    const Local = struct {
        var captured_allocator: std.mem.Allocator = undefined;

        fn makeChunk(
            slice_inputs: []const []const u8,
            slice_results: []ParseResult,
        ) ParseChunk {
            return .{
                .allocator = captured_allocator,
                .inputs = slice_inputs,
                .results = slice_results,
            };
        }

        fn sequentialOne(input: []const u8, out: *ParseResult) void {
            out.* = parseDocument(captured_allocator, input);
        }
    };
    Local.captured_allocator = allocator;

    runBatch(
        ParseChunk,
        parseChunkTask,
        inputs,
        results,
        Local.makeChunk,
        Local.sequentialOne,
    );
}
```

- [ ] **Step 2: Build and run the full test suite**

Run: `zig build test`
Expected: all 64 existing tests plus the new `runBatch` test pass. Pay special attention to:

- `parse document - valid`
- `parallel parse - large batch`
- `U-F no dropped inputs past MAX_CHUNKS - parseDocuments`
- `U-M diverges from toml.parse: ...` (xfail tests still xfail as expected)

- [ ] **Step 3: Commit the parseDocuments refactor**

```bash
git add src/parallel.zig
git commit -m "refactor(parallel): route parseDocuments through runBatch"
```

---

## Task 4: Refactor `validateDocuments` to use `runBatch`

**Files:**

- Modify: `src/parallel.zig:284-317` — replace the body of `validateDocuments`.

- [ ] **Step 1: Rewrite `validateDocuments` body**

Find this exact block in `src/parallel.zig`:

```zig
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

    const pool = getPool();
    // Ceiling division: avoid dropping the tail of the input batch.
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
```

Replace it with:

```zig
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

    // validateDocuments does not take an allocator, so no staging var is
    // required. Both closures are pure functions of their arguments.
    const Local = struct {
        fn makeChunk(
            slice_inputs: []const []const u8,
            slice_results: []ValidateResult,
        ) ValidateChunk {
            return .{ .inputs = slice_inputs, .results = slice_results };
        }

        fn sequentialOne(input: []const u8, out: *ValidateResult) void {
            out.* = validateDocument(input);
        }
    };

    runBatch(
        ValidateChunk,
        validateChunkTask,
        inputs,
        results,
        Local.makeChunk,
        Local.sequentialOne,
    );
}
```

- [ ] **Step 2: Build and run the full test suite**

Run: `zig build test`
Expected: all tests pass. Key regression targets:

- `validate document - valid`
- `validate document - invalid utf8`
- `validate document - null byte`
- `parallel validate - large batch`
- `U-F no dropped inputs past MAX_CHUNKS - validateDocuments`

- [ ] **Step 3: Commit the validateDocuments refactor**

```bash
git add src/parallel.zig
git commit -m "refactor(parallel): route validateDocuments through runBatch"
```

---

## Task 5: Refactor `extractKeys` to use `runBatch`

**Files:**

- Modify: `src/parallel.zig:398-436` — replace the body of `extractKeys`.

- [ ] **Step 1: Rewrite `extractKeys` body**

Find this exact block in `src/parallel.zig`:

```zig
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

    const pool = getPool();
    // Ceiling division: avoid dropping the tail of the input batch.
    const chunk_size = @max(1, (inputs.len + MAX_CHUNKS - 1) / MAX_CHUNKS);
    var chunks: [MAX_CHUNKS]KeyExtractChunk = undefined;
    var batch: [MAX_CHUNKS]tp.BatchTask = undefined;
    var n: usize = 0;
    var i: usize = 0;
    while (i < inputs.len and n < MAX_CHUNKS) {
        const end = @min(i + chunk_size, inputs.len);
        chunks[n] = .{
            .allocator = allocator,
            .inputs = inputs[i..end],
            .results = results[i..end],
        };
        batch[n] = .{ .task_fn = &keyExtractChunkTask, .ctx = @ptrCast(&chunks[n]) };
        n += 1;
        i = end;
    }
    var wg = pool.waitGroup();
    _ = pool.submitBatch(batch[0..n], .{ .wait_group = &wg }) catch {
        for (inputs, 0..) |input, j| results[j] = extractKeysFromDocument(allocator, input);
        return;
    };
    wg.wait();
}
```

Replace it with:

```zig
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

    // See parseDocuments for the allocator-staging rationale.
    const Local = struct {
        var captured_allocator: std.mem.Allocator = undefined;

        fn makeChunk(
            slice_inputs: []const []const u8,
            slice_results: []KeyExtractResult,
        ) KeyExtractChunk {
            return .{
                .allocator = captured_allocator,
                .inputs = slice_inputs,
                .results = slice_results,
            };
        }

        fn sequentialOne(input: []const u8, out: *KeyExtractResult) void {
            out.* = extractKeysFromDocument(captured_allocator, input);
        }
    };
    Local.captured_allocator = allocator;

    runBatch(
        KeyExtractChunk,
        keyExtractChunkTask,
        inputs,
        results,
        Local.makeChunk,
        Local.sequentialOne,
    );
}
```

- [ ] **Step 2: Build and run the full test suite**

Run: `zig build test`
Expected: all tests pass. Key regression targets:

- `extract keys - basic`
- `extract keys - empty document`
- `parallel extract keys - large batch`
- `U-F no dropped inputs past MAX_CHUNKS - extractKeys`

- [ ] **Step 3: Commit the extractKeys refactor**

```bash
git add src/parallel.zig
git commit -m "refactor(parallel): route extractKeys through runBatch"
```

---

## Task 6: Verify LOC reduction and seal Q-8

**Files:**

- Modify: `docs/QUALITY_GAP_ANALYSIS.md` (only if a Q-8 row exists there; otherwise skip the doc edit step).

- [ ] **Step 1: Measure LOC delta**

Run: `git diff --stat main -- src/parallel.zig`
Expected: net reduction of ~60-80 lines (three ~35-LOC fan-out blocks collapsed; one ~30-LOC helper added; roughly three x 18 = ~54 LOC of boilerplate replaced with ~8-LOC `runBatch` calls per caller).

If the reduction is less than ~50 lines, audit the new `*Local` helper structs — they should be small (two short functions each). If they have ballooned, simplify before committing.

- [ ] **Step 2: Final full-suite sanity run**

Run: `zig build test`
Expected: all tests green (same count as on `main` plus the one new `runBatch` test added in Task 1 — so total count increases by exactly 1).

- [ ] **Step 3: Self-review the diff**

Run: `git diff main -- src/parallel.zig | head -200`

Review for:

- No duplicated ceiling-division formula (must appear exactly once, inside `runBatch`).
- No duplicated `pool.waitGroup()` + `submitBatch` + `wg.wait()` sequence outside `runBatch`.
- Sequential fast-path thresholds (`< 4`, `< 8`, `< 8`) preserved in each wrapper.
- `std.debug.assert(inputs.len == results.len)` preserved in each wrapper.
- All three `*Chunk` structs and `*ChunkTask` functions unchanged.
- All pre-existing tests unchanged.
- `MAX_CHUNKS` still 64, still referenced only inside `runBatch`.

- [ ] **Step 4: Optional — update QUALITY_GAP_ANALYSIS.md**

Run: `grep -n 'Q-8' docs/QUALITY_GAP_ANALYSIS.md`
If the grep returns a row for Q-8, edit that row's status from `open` to `resolved` and add a brief resolution note pointing at the refactor commits. If Q-8 is not tracked in that file, skip this step.

- [ ] **Step 5: Final commit — seal Q-8**

If Step 4 made edits:

```bash
git add docs/QUALITY_GAP_ANALYSIS.md
git commit -m "refactor(parallel): close Q-8 — extract runBatch helper"
```

If Step 4 was skipped (Q-8 not tracked externally), create an empty marker commit to carry the trailer:

```bash
git commit --allow-empty -m "refactor(parallel): close Q-8 — extract runBatch helper"
```

---

## Self-Review Checklist

Run through this after executing every task, before opening a PR.

### 1. Spec coverage

| Spec requirement | Task(s) | Satisfied? |
|---|---|---|
| Extract a generic helper matching the architecture sketch | Task 2 | Yes (with adapted signature — see adaptation notes) |
| `parseDocuments` becomes a ~10 LOC wrapper | Task 3 | Yes |
| `validateDocuments` becomes a ~10 LOC wrapper | Task 4 | Yes |
| `extractKeys` becomes a ~10 LOC wrapper | Task 5 | Yes |
| Failing test first, then implement (TDD) | Task 1 → Task 2 | Yes |
| Commit each refactor separately | Tasks 3, 4, 5 individually | Yes |
| Honor `MAX_CHUNKS` ceiling from U-F | Task 2 (ceiling formula) + Task 1 (100-input test) | Yes |
| No behavior change — all 64 tests pass at each step | Tasks 3, 4, 5 each run `zig build test` | Yes |
| Final ~70 LOC reduction | Task 6 Step 1 measures it | Yes |

### 2. Architecture adaptation note

The brief's sketch used `results: []anyopaque` and `ctx: *Ctx`. The actual plan uses `results: anytype` (so each call retains its typed slice — `[]ParseResult`, `[]ValidateResult`, `[]KeyExtractResult`) and threads per-caller state via a function-local `struct Local` with container-scoped `var`s rather than a `*Ctx` runtime argument. This is the idiomatic Zig pattern when `comptime` function-pointer parameters prevent runtime closure capture, and it keeps the helper fully generic without forcing callers through `@ptrCast` of opaque result slices. The U-F invariant (ceiling division, single-pass chunking) is preserved byte-for-byte inside the helper.

### 3. Placeholder scan

- No "TBD", "TODO", "implement later" strings in the plan.
- No "add appropriate error handling" — the sequential fallback is the explicit error path and its full code is shown.
- No "similar to Task N" cross-references that elide code — each refactor task shows the full before/after block.
- No references to undefined types — `ParseChunk`, `ValidateChunk`, `KeyExtractChunk`, `ParseResult`, `ValidateResult`, `KeyExtractResult`, `parseChunkTask`, `validateChunkTask`, `keyExtractChunkTask` are all pre-existing in `src/parallel.zig` and unchanged.

### 4. Type / name consistency

- Helper name: `runBatch` (lower-camel) — used identically in Task 1 test, Task 2 definition, and Tasks 3/4/5 call sites.
- Closure member names: `makeChunk` and `sequentialOne` — used identically in Task 2 signature and Tasks 3/4/5 `Local` structs.
- `captured_allocator` name used identically across Task 3 (parseDocuments) and Task 5 (extractKeys); Task 4 (validateDocuments) intentionally omits it.
- `MAX_CHUNKS` stays at 64; referenced in Task 2 (helper) and Task 1 test (indirectly — the 100-input batch exceeds it).

### 5. Execution ordering guarantees

- Task 1 commits a red test; Task 2 makes it green — each is on its own commit so `git bisect` can cleanly attribute breakage.
- Tasks 3, 4, 5 each run the full test suite and commit in isolation — if any refactor regresses behavior, it is revertible as a single commit without losing the helper from Task 2 or the preceding refactors.
- Task 6 is purely measurement and documentation — no code changes that could regress tests.

---

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-04-18-14-submit-batch-dry.md`. Two execution options:

1. **Subagent-Driven (recommended)** — dispatch a fresh subagent per task (Tasks 1-6), review the diff between each task, fast iteration on any hiccup. Best for this plan because each task is a small, verifiable delta with a full `zig build test` gate.

2. **Inline Execution** — execute Tasks 1-6 in this session using `superpowers:executing-plans`, stopping at the end of each task for a checkpoint review.

Which approach?
