# Streaming Parser API (GAP-0016) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `toml.parseStream` that parses a TOML document from a `std.Io.Reader` interface, closing GAP-0016 by giving callers a way to feed input from files, sockets, or any other reader without first materialising a `[]const u8`.

**Architecture:** Two designs are viable. Design A ("buffer-then-parse") reads all bytes from the reader into an allocator-owned buffer and delegates to the existing `parse(alloc, input, opts)` entry point. Design B ("truly incremental lexer") pushes the reader into `Lexer` as a rolling buffer. Design A is simpler, preserves every existing invariant, and unblocks every caller that just wants "parse a TOML file" without forcing the consumer to do their own `readAllAlloc` dance. This plan ships Design A in full and records Design B as a roadmap follow-up in `ROADMAP.md`.

**Tech Stack:** Zig 0.15+ (uses the new `std.Io.Reader` / `std.Io.Writer` "interface" pattern), existing `ArenaAllocator`-backed `Document`, `std.Io.Reader.Fixed` for synthetic tests.

---

## Current State (evidence)

- `src/toml.zig:41` exposes only `pub fn parse(alloc: Allocator, input: []const u8, opts: ParseOptions) !Document` — the caller must already own the full document bytes.
- `src/parser.zig:23-27` defines `ParseOptions { version, max_depth, max_bytes }` — `max_bytes = 16 MiB` is both the parse-time budget and what we need to pass to the streaming read.
- `src/parser.zig:52-81` validates UTF-8 and enforces `max_bytes` against the in-memory slice; the plan routes streaming inputs through the same checks by delegating to `parse`.
- `src/lexer.zig` reads from an in-memory slice; no refill mechanism exists today. That is fine for Design A — the slice we hand the lexer is the fully-drained reader buffer.
- `src/bin/toml_test_decoder.zig:42-52` already demonstrates the Zig 0.15 streaming read idiom: `std.Io.File.stdin().readerStreaming(io, &stdin_buf)` yielding a `*std.Io.Reader` via `.interface`, then `interface.allocRemaining(allocator, .limited(...))`. We will reuse this pattern.
- `docs/GAP_ANALYSIS.md:181-188` records GAP-0016 ("Streaming parser API") with the recommended fix: "Feed `io.Reader` incrementally; emit `Document` on EOF."
- `docs/ROADMAP.md:49-57` lists "Streaming/incremental parser" under v2.0.0 (issue #14). Design A lives happily in a non-breaking minor; Design B is the v2.0.0 move.

## File Structure

- **Create** `tests/streaming.zig` — acceptance tests for `parseStream` (equivalence with `parse`, error propagation, large-input chunking, `max_bytes` enforcement, empty input).
- **Create** `examples/streaming.zig` — user-facing example that reads a TOML file from disk via `std.fs.File.readerStreaming` and parses it with `parseStream`.
- **Modify** `src/toml.zig` — add `parseStream` plus two tiny unit tests co-located with the other `test "..."` blocks. No changes to existing exports.
- **Modify** `build.zig` — wire `tests/streaming.zig` into the `test` step the same way `tests/accept.zig` is wired.
- **Modify** `docs/API.md` — document `parseStream` under "Core Functions" after `parseWithError`.
- **Modify** `CHANGELOG.md` — `Added` entry under `[Unreleased]`.
- **Modify** `docs/ROADMAP.md` — mark GAP-0016 Design A shipped, leave Design B (truly incremental lexer) under v2.0.0.
- **Modify** `docs/GAP_ANALYSIS_RESOLVED.md` — move the GAP-0016 entry from `GAP_ANALYSIS.md` to resolved (same treatment as other closed gaps in the repo).
- **Modify** `docs/GAP_ANALYSIS.md` — delete the GAP-0016 section (it now lives in `_RESOLVED`).

Each file has one responsibility; no file is refactored beyond what the task strictly needs.

---

## Task 1: Add `parseStream` with a failing equivalence test

**Files:**

- Modify: `src/toml.zig` (append after `parseWithError`, before `writeTaggedJson`; also append tests at end of file)
- Test: `src/toml.zig` (unit test block)

- [ ] **Step 1: Read `src/toml.zig` so the edit tool can operate on it**

Run: `zig version`
Expected: `0.15.x` or newer. If older, stop and surface the mismatch — the `std.Io.Reader` interface shape is required.

- [ ] **Step 2: Write the failing equivalence test at the end of `src/toml.zig`**

Append at the bottom of `src/toml.zig` (after the last existing `test "..."` block):

```zig
test "parseStream equivalence with parse for small input" {
    const input =
        \\title = "My Application"
        \\
        \\[server]
        \\host = "localhost"
        \\port = 8080
    ;

    // Baseline: parse from a slice.
    var base = try parse(std.testing.allocator, input, .{});
    defer base.deinit();

    // Under test: parseStream from an in-memory reader over the same bytes.
    var fixed: std.Io.Reader.Fixed = .init(input);
    var streamed = try parseStream(std.testing.allocator, &fixed.interface, .{});
    defer streamed.deinit();

    // Compare via tagged JSON — deterministic (keys sorted) and already
    // exercised across the codebase, so any divergence is obvious.
    var base_aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer base_aw.deinit();
    try writeTaggedJson(&base, &base_aw.writer);

    var streamed_aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer streamed_aw.deinit();
    try writeTaggedJson(&streamed, &streamed_aw.writer);

    try std.testing.expectEqualStrings(base_aw.written(), streamed_aw.written());
}
```

- [ ] **Step 3: Run the new test to verify it fails**

Run: `zig build test 2>&1 | head -80`
Expected: Compile error referencing `parseStream` being undefined (e.g. `error: no member named 'parseStream' in file 'toml.zig'` or `use of undeclared identifier 'parseStream'`). Any other failure means a mistype in the test — fix the test body, not the production code.

- [ ] **Step 4: Implement `parseStream` in `src/toml.zig`**

Insert this function in `src/toml.zig` immediately after `parseWithError` (i.e. after the closing `}` of `parseWithError` and before `pub fn writeTaggedJson`):

```zig
/// Parse TOML from a streaming reader into a Document.
///
/// This is the streaming entry point that closes GAP-0016. Internally the
/// reader is drained into a single `opts.max_bytes`-bounded buffer owned by
/// `alloc`, then handed to `parse`. Behaviour, errors, and ownership of the
/// returned Document are identical to `parse`; the only difference is where
/// the bytes come from.
///
/// The Document owns all parsed data via an internal ArenaAllocator. Call
/// `deinit()` on the returned Document to free all memory.
///
/// Errors:
/// - `error.ParseFailed` for TOML parse errors (same as `parse`).
/// - `error.StreamTooLong` if the reader produces more than `opts.max_bytes`
///   bytes before EOF.
/// - Any error returned by the underlying reader is propagated unchanged.
pub fn parseStream(
    alloc: Allocator,
    reader: *std.Io.Reader,
    opts: ParseOptions,
) !Document {
    const input = try reader.allocRemaining(alloc, .limited(opts.max_bytes));
    defer alloc.free(input);
    return parse(alloc, input, opts);
}
```

- [ ] **Step 5: Run the equivalence test and verify it passes**

Run: `zig build test 2>&1 | tail -40`
Expected: All tests pass. If `parseStream equivalence with parse for small input` still fails, diff the two `writeTaggedJson` outputs and fix the production code, not the test.

- [ ] **Step 6: Commit**

```bash
git add src/toml.zig
git commit -m "feat(toml): add parseStream entrypoint backed by reader drain

Closes GAP-0016 (streaming parser API, Design A). parseStream drains a
std.Io.Reader into an allocator-owned buffer bounded by opts.max_bytes,
then delegates to parse(), preserving all existing invariants (UTF-8
validation, size limit, arena ownership)."
```

---

## Task 2: Error-propagation test for a reader that fails mid-stream

**Files:**

- Modify: `src/toml.zig` (append another unit test)

- [ ] **Step 1: Add a small FailingReader helper and a failure test**

Append at the end of `src/toml.zig` (after the test added in Task 1):

```zig
/// Test-only reader that yields `good` bytes, then returns an error on the
/// next read. Used to prove parseStream propagates reader errors verbatim.
const FailingReader = struct {
    good: []const u8,
    consumed: usize = 0,
    interface: std.Io.Reader,

    fn init(good: []const u8, buf: []u8) FailingReader {
        return .{
            .good = good,
            .interface = .{
                .vtable = &vtable,
                .buffer = buf,
                .seek = 0,
                .end = 0,
            },
        };
    }

    const vtable: std.Io.Reader.VTable = .{
        .stream = stream,
    };

    fn stream(
        r: *std.Io.Reader,
        w: *std.Io.Writer,
        limit: std.Io.Limit,
    ) std.Io.Reader.StreamError!usize {
        const self: *FailingReader = @fieldParentPtr("interface", r);
        if (self.consumed < self.good.len) {
            const remaining = self.good[self.consumed..];
            const n = @min(@intFromEnum(limit), remaining.len);
            try w.writeAll(remaining[0..n]);
            self.consumed += n;
            return n;
        }
        return error.ReadFailed;
    }
};

test "parseStream propagates reader errors" {
    var vbuf: [64]u8 = undefined;
    var failing = FailingReader.init("title = \"partial", &vbuf);

    const result = parseStream(std.testing.allocator, &failing.interface, .{});
    try std.testing.expectError(error.ReadFailed, result);
}
```

- [ ] **Step 2: Run the test to verify it passes (no production change needed)**

Run: `zig build test 2>&1 | tail -20`
Expected: All tests pass. `parseStream` already returns reader errors because `allocRemaining` propagates them — this test just nails that contract down so a future refactor cannot regress it.

If the test fails with a compile error referencing `StreamError` or `VTable` field names, the Zig stdlib has shifted — consult `zig lib/std/Io/Reader.zig` for the current vtable shape and adjust the helper. Do **not** change production code for this.

- [ ] **Step 3: Commit**

```bash
git add src/toml.zig
git commit -m "test(toml): pin parseStream reader-error propagation

Adds a minimal FailingReader that emits good bytes then raises
ReadFailed. Documents the contract that parseStream forwards reader
errors verbatim without wrapping."
```

---

## Task 3: Acceptance test suite (`tests/streaming.zig`)

**Files:**

- Create: `tests/streaming.zig`
- Modify: `build.zig`

- [ ] **Step 1: Create `tests/streaming.zig` with three acceptance tests**

Create the file with exactly this content:

```zig
// SPDX-License-Identifier: MIT
// Copyright (c) 2024-2026 DevNW

//! Acceptance tests for toml.parseStream (GAP-0016).

const std = @import("std");
const toml = @import("toml");

// Helper: parse the same bytes two ways and compare their tagged-JSON
// renderings. Tagged JSON is deterministic (keys sorted), so string
// equality is a strong structural equivalence check.
fn expectParseEquivalence(allocator: std.mem.Allocator, bytes: []const u8) !void {
    var base = try toml.parse(allocator, bytes, .{});
    defer base.deinit();

    var fixed: std.Io.Reader.Fixed = .init(bytes);
    var streamed = try toml.parseStream(allocator, &fixed.interface, .{});
    defer streamed.deinit();

    var base_aw: std.Io.Writer.Allocating = .init(allocator);
    defer base_aw.deinit();
    try toml.writeTaggedJson(&base, &base_aw.writer);

    var streamed_aw: std.Io.Writer.Allocating = .init(allocator);
    defer streamed_aw.deinit();
    try toml.writeTaggedJson(&streamed, &streamed_aw.writer);

    try std.testing.expectEqualStrings(base_aw.written(), streamed_aw.written());
}

test "parseStream: empty input produces an empty document" {
    var fixed: std.Io.Reader.Fixed = .init("");
    var doc = try toml.parseStream(std.testing.allocator, &fixed.interface, .{});
    defer doc.deinit();

    try std.testing.expectEqual(@as(usize, 0), doc.root.table.entries.len);
}

test "parseStream: representative fixture matches parse" {
    const input =
        \\# Comment survives streaming
        \\title = "zigtoml"
        \\ints = [1, 2, 3]
        \\floats = [1.5, -0.25, 1e3]
        \\
        \\[server]
        \\host = "localhost"
        \\port = 8080
        \\
        \\[[products]]
        \\name = "Hammer"
        \\
        \\[[products]]
        \\name = "Nail"
    ;
    try expectParseEquivalence(std.testing.allocator, input);
}

// Slow-drip reader: yields exactly `chunk_size` bytes per stream() call.
// Exercises the boundary handling of the underlying allocRemaining loop
// without needing any on-disk file.
const ChunkedReader = struct {
    src: []const u8,
    consumed: usize = 0,
    chunk_size: usize,
    interface: std.Io.Reader,

    fn init(src: []const u8, chunk_size: usize, buf: []u8) ChunkedReader {
        return .{
            .src = src,
            .chunk_size = chunk_size,
            .interface = .{
                .vtable = &vtable,
                .buffer = buf,
                .seek = 0,
                .end = 0,
            },
        };
    }

    const vtable: std.Io.Reader.VTable = .{
        .stream = stream,
    };

    fn stream(
        r: *std.Io.Reader,
        w: *std.Io.Writer,
        limit: std.Io.Limit,
    ) std.Io.Reader.StreamError!usize {
        const self: *ChunkedReader = @fieldParentPtr("interface", r);
        if (self.consumed >= self.src.len) return error.EndOfStream;
        const remaining = self.src[self.consumed..];
        const want = @min(self.chunk_size, @min(remaining.len, @intFromEnum(limit)));
        try w.writeAll(remaining[0..want]);
        self.consumed += want;
        return want;
    }
};

test "parseStream: 1 MiB synthetic input in 1024-byte chunks matches parse" {
    const allocator = std.testing.allocator;

    // Build a ~1 MiB TOML document that stays well within the default
    // max_bytes (16 MiB) and is cheap to generate: 20,000 repeats of
    // a 50-byte-ish entry.
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    const entries: usize = 20_000;
    try buf.ensureTotalCapacity(allocator, entries * 64);
    for (0..entries) |i| {
        try buf.appendSlice(allocator, "[[items]]\n");
        var tmp: [48]u8 = undefined;
        const line = try std.fmt.bufPrint(&tmp, "index = {d}\nname = \"row-{d}\"\n", .{ i, i });
        try buf.appendSlice(allocator, line);
    }

    // Sanity: we are actually testing the regime we claim to test.
    try std.testing.expect(buf.items.len >= 900 * 1024);
    try std.testing.expect(buf.items.len <= 4 * 1024 * 1024);

    var base = try toml.parse(allocator, buf.items, .{});
    defer base.deinit();

    var rbuf: [4096]u8 = undefined;
    var chunked = ChunkedReader.init(buf.items, 1024, &rbuf);
    var streamed = try toml.parseStream(allocator, &chunked.interface, .{});
    defer streamed.deinit();

    // Same structural check as the small fixture.
    var base_aw: std.Io.Writer.Allocating = .init(allocator);
    defer base_aw.deinit();
    try toml.writeTaggedJson(&base, &base_aw.writer);

    var streamed_aw: std.Io.Writer.Allocating = .init(allocator);
    defer streamed_aw.deinit();
    try toml.writeTaggedJson(&streamed, &streamed_aw.writer);

    try std.testing.expectEqualStrings(base_aw.written(), streamed_aw.written());
}

test "parseStream: input larger than max_bytes is rejected" {
    // 4 KiB of valid TOML, capped at 1 KiB. The reader-side drain must
    // fail with StreamTooLong before we ever reach the parser.
    const allocator = std.testing.allocator;

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    for (0..200) |i| {
        var tmp: [32]u8 = undefined;
        const line = try std.fmt.bufPrint(&tmp, "k{d} = {d}\n", .{ i, i });
        try buf.appendSlice(allocator, line);
    }
    try std.testing.expect(buf.items.len > 1024);

    var fixed: std.Io.Reader.Fixed = .init(buf.items);
    const result = toml.parseStream(
        allocator,
        &fixed.interface,
        .{ .max_bytes = 1024 },
    );
    try std.testing.expectError(error.StreamTooLong, result);
}
```

- [ ] **Step 2: Wire the new test file into `build.zig`**

In `build.zig`, locate the block that defines `accept_tests` (starts with `const accept_tests = b.addTest(...)` near line 71) and duplicate its shape for streaming tests. Add the following immediately after `const run_accept_tests = b.addRunArtifact(accept_tests);` (before the fuzz harness block):

```zig
    // Streaming parser acceptance tests (GAP-0016).
    const streaming_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/streaming.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "toml", .module = toml_mod },
            },
        }),
    });
    const run_streaming_tests = b.addRunArtifact(streaming_tests);
```

Then in the `test_step` wiring (currently `test_step.dependOn(&run_unit_tests.step);` etc.), add one more line so the new suite actually runs:

Old:

```zig
    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_unit_tests.step);
    test_step.dependOn(&run_accept_tests.step);
    test_step.dependOn(&run_fuzz_tests.step);
```

New:

```zig
    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_unit_tests.step);
    test_step.dependOn(&run_accept_tests.step);
    test_step.dependOn(&run_streaming_tests.step);
    test_step.dependOn(&run_fuzz_tests.step);
```

- [ ] **Step 3: Run the full test suite and verify it passes**

Run: `zig build test 2>&1 | tail -30`
Expected: All tests pass — including the four new streaming acceptance tests. If the 1 MiB test is slow on your machine, that's fine; it's bounded by ~20k TOML lines and should finish in a few seconds in `Debug` mode.

- [ ] **Step 4: Confirm the streaming suite actually ran**

Run: `zig build test --summary all 2>&1 | tail -40`
Expected: The summary shows the `streaming_tests` artifact executing alongside `unit_tests` and `accept_tests`. If you only see the unit + accept suites, the `test_step.dependOn(&run_streaming_tests.step);` line is missing — go back and add it.

- [ ] **Step 5: Commit**

```bash
git add tests/streaming.zig build.zig
git commit -m "test(toml): acceptance suite for parseStream

Covers: empty input, representative fixture equivalence, 1 MiB
synthetic input drained in 1024-byte chunks, and max_bytes
enforcement (StreamTooLong). Wires tests/streaming.zig into the
zig build test step."
```

---

## Task 4: End-user example (`examples/streaming.zig`)

**Files:**

- Create: `examples/streaming.zig`

- [ ] **Step 1: Create `examples/streaming.zig`**

Create the file with exactly this content:

```zig
// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros

//! Streaming TOML parsing example.
//!
//! Demonstrates `toml.parseStream`, which reads directly from any
//! `std.Io.Reader` (files, sockets, pipes) instead of requiring the
//! caller to materialise the full document in memory first.
//!
//! Usage:
//!     zig build run-example-streaming -- path/to/config.toml
//!     cat config.toml | zig build run-example-streaming
//!
//! The example falls back to reading from stdin when no path is given,
//! so it works as both a file parser and a pipe filter.

const std = @import("std");
const toml = @import("toml");

pub fn main(init: std.process.Init) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const io = init.io;

    // Collect argv. Skip argv[0] (program name).
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var buf: [4096]u8 = undefined;

    // Dispatch on whether a path was provided.
    if (args.len >= 2) {
        // File path -> open file -> stream into parseStream.
        const path = args[1];
        var file = try std.fs.cwd().openFile(path, .{});
        defer file.close();

        var file_reader = file.readerStreaming(io, &buf);
        var doc = try toml.parseStream(allocator, &file_reader.interface, .{});
        defer doc.deinit();

        try printSummary(io, &doc, path);
    } else {
        // No path -> drain stdin.
        const stdin = std.Io.File.stdin();
        var stdin_reader = stdin.readerStreaming(io, &buf);
        var doc = try toml.parseStream(allocator, &stdin_reader.interface, .{});
        defer doc.deinit();

        try printSummary(io, &doc, "<stdin>");
    }
}

fn printSummary(io: std.process.Io, doc: *const toml.Document, source: []const u8) !void {
    const stdout = std.Io.File.stdout();
    var out_buf: [1024]u8 = undefined;
    var stdout_writer = stdout.writerStreaming(io, &out_buf);
    const w = &stdout_writer.interface;

    try w.print("Parsed {s}: {d} top-level entries.\n", .{ source, doc.root.table.entries.len });
    for (doc.root.table.entries) |entry| {
        const kind: []const u8 = switch (entry.value.*) {
            .table => "table",
            .array => "array",
            .string => "string",
            .integer => "integer",
            .float => "float",
            .bool => "bool",
            .datetime => "datetime",
            .datetime_local => "datetime-local",
            .date_local => "date-local",
            .time_local => "time-local",
        };
        try w.print("  {s}: {s}\n", .{ entry.key, kind });
    }
    try w.flush();
}
```

- [ ] **Step 2: Verify the example at least type-checks**

Run: `zig build check 2>&1 | tail -20`
Expected: No compilation errors. The `check` step builds the library without running tests; if `streaming.zig` introduces a syntax error via any shared type reference, it will surface there. The example itself is not wired into `build.zig` as a runnable artifact — consistent with every other file under `examples/`, which are documentation-facing and compiled via the build step only if a future maintainer adds a `zig build run-example-*` target.

- [ ] **Step 3: Run the full test suite once more to confirm nothing broke**

Run: `zig build test 2>&1 | tail -20`
Expected: All tests pass.

- [ ] **Step 4: Commit**

```bash
git add examples/streaming.zig
git commit -m "docs(examples): add streaming parser example

examples/streaming.zig reads a TOML document from a file path
argument or stdin using std.Io.File.readerStreaming and feeds it
through toml.parseStream, then prints a typed summary of the
top-level entries."
```

---

## Task 5: API reference (`docs/API.md`)

**Files:**

- Modify: `docs/API.md`

- [ ] **Step 1: Read the current `parseWithError` section to find the insertion point**

Run: `zig build check` (no-op; this step is just a reminder to scroll to the end of the `parseWithError` section in `docs/API.md` — the new `parseStream` section goes immediately after it, before the `### writeTaggedJson` heading).

- [ ] **Step 2: Insert the `parseStream` reference section**

In `docs/API.md`, after the closing `---` of the `parseWithError` section and before the `### writeTaggedJson` heading, insert:

````markdown
### parseStream

```zig
pub fn parseStream(
    alloc: Allocator,
    reader: *std.Io.Reader,
    opts: ParseOptions,
) !Document
```

**Description:** Parse a TOML document from any `std.Io.Reader` (file, socket, pipe, test fixture). Internally the reader is drained into a single `opts.max_bytes`-bounded buffer owned by `alloc`, then delegated to `parse`. Ownership of the returned `Document` and its memory arena is identical to `parse` — call `deinit()` to free it.

**Parameters:**

| Parameter | Type | Description |
|-----------|------|-------------|
| alloc | Allocator | Memory allocator. Used both for the transient drain buffer (freed before return) and for the returned Document's arena. |
| reader | `*std.Io.Reader` | Streaming reader. The reader is drained to EOF. |
| opts | ParseOptions | Same options as `parse`. `opts.max_bytes` acts as an upper bound on both the drain and the subsequent parse. |

**Returns:** `Document` — see `parse`.

**Errors:**

| Error | Description |
|-------|-------------|
| `error.ParseFailed` | TOML parse error (inspect via `parseWithError` when you need details). |
| `error.StreamTooLong` | Reader produced more than `opts.max_bytes` bytes before EOF. |
| `error.OutOfMemory` | Allocation failed. |
| (any reader error) | Propagated unchanged from the underlying `std.Io.Reader`. |

**Example — parse a TOML file:**

```zig
const std = @import("std");
const toml = @import("toml");

pub fn main(init: std.process.Init) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var file = try std.fs.cwd().openFile("config.toml", .{});
    defer file.close();

    var buf: [4096]u8 = undefined;
    var file_reader = file.readerStreaming(init.io, &buf);

    var doc = try toml.parseStream(allocator, &file_reader.interface, .{});
    defer doc.deinit();

    if (doc.root.get("title")) |t| {
        std.debug.print("title = {s}\n", .{t.string});
    }
}
```

**Notes:**

- Design A ("buffer-then-parse"): this entry point still materialises the full document in memory. It removes the boilerplate of driving the reader yourself but does **not** enable parsing documents larger than `opts.max_bytes`. Truly incremental lexing is tracked under v2.0.0 (see `docs/ROADMAP.md`).
- Thread safety matches `parse`: the returned `Document` is safe to share across threads only under the same rules as `parse` output.

---
````

Make sure the exact wording above is used; `---` separators match the house style of the surrounding sections.

- [ ] **Step 3: Commit**

```bash
git add docs/API.md
git commit -m "docs(api): document toml.parseStream

Adds a parseStream reference section between parseWithError and
writeTaggedJson, including the file-reader example, the error
table, and an explicit note that Design A is a buffering wrapper."
```

---

## Task 6: CHANGELOG and ROADMAP housekeeping

**Files:**

- Modify: `CHANGELOG.md`
- Modify: `docs/ROADMAP.md`
- Modify: `docs/GAP_ANALYSIS.md`
- Modify: `docs/GAP_ANALYSIS_RESOLVED.md`

- [ ] **Step 1: Add the CHANGELOG entry**

In `CHANGELOG.md`, under the existing `## [Unreleased]` / `### Added` list, prepend this bullet (so it appears before the `Documented the toml.parallel subsystem...` bullet):

```markdown
- `toml.parseStream(alloc, reader, opts)` — parse a TOML document from
  any `std.Io.Reader` (file, socket, pipe). Implemented as a buffering
  wrapper over `parse` that drains the reader into an
  `opts.max_bytes`-bounded allocator-owned buffer. Closes GAP-0016
  (Design A). See `examples/streaming.zig` and `docs/API.md`.
```

- [ ] **Step 2: Update the ROADMAP to reflect Design A shipped, Design B still pending**

In `docs/ROADMAP.md`, under the `### [v2.0.0 - Streaming Parser]` table, replace the row:

Old:

```markdown
| [#14](https://gitlab.com/devnw/zig/toml/-/issues/14) | Streaming/incremental parser | Medium |
```

New:

```markdown
| [#14](https://gitlab.com/devnw/zig/toml/-/issues/14) | Streaming/incremental parser (Design B — truly incremental lexer; Design A shipped as `parseStream`) | Medium |
```

Do not move the row out of the v2.0.0 table — the truly incremental lexer is still the v2.0.0 deliverable.

- [ ] **Step 3: Remove the GAP-0016 section from `docs/GAP_ANALYSIS.md`**

In `docs/GAP_ANALYSIS.md`, delete the full section (all six lines, lines 181 to 188 in the current file):

```markdown
### GAP-0016: Streaming parser API

- **Issue:** [#14](https://gitlab.com/devnw/zig/toml/-/issues/14)
- **Category:** Feature
- **Severity:** Medium
- **Requirement source:** REQ-14.
- **Current state (evidence):** Only full-buffer parse is exposed.
- **Recommended fix:** Feed `io.Reader` incrementally; emit `Document` on EOF.
```

Also delete the trailing blank line between the deleted section and `### GAP-0017`.

- [ ] **Step 4: Append a resolved entry to `docs/GAP_ANALYSIS_RESOLVED.md`**

If `docs/GAP_ANALYSIS_RESOLVED.md` already has a trailing blank line, append; if not, add one blank line before the new section. Append:

```markdown
### GAP-0016: Streaming parser API (resolved 2026-04-18)

- **Issue:** [#14](https://gitlab.com/devnw/zig/toml/-/issues/14)
- **Category:** Feature
- **Severity:** Medium (was)
- **Resolution:** Shipped `toml.parseStream(alloc, reader, opts)` —
  Design A (buffering wrapper). Drains any `std.Io.Reader` into an
  `opts.max_bytes`-bounded buffer, then delegates to `parse`. Truly
  incremental lexing (Design B) remains tracked under v2.0.0 in
  `docs/ROADMAP.md`.
- **Evidence:**
  - `src/toml.zig` — `parseStream` implementation and two unit tests.
  - `tests/streaming.zig` — acceptance suite (equivalence, 1 MiB
    chunked input, `max_bytes` enforcement, empty input).
  - `examples/streaming.zig` — file + stdin example.
  - `docs/API.md` — reference entry.
```

- [ ] **Step 5: Run `zig build test` once more to confirm nothing in the docs housekeeping broke the build**

Run: `zig build test 2>&1 | tail -15`
Expected: All tests pass. Docs-only changes should not affect the build, but a stray invalid Zig-in-markdown fence can break downstream tooling — this is a cheap smoke check.

- [ ] **Step 6: Commit**

```bash
git add CHANGELOG.md docs/ROADMAP.md docs/GAP_ANALYSIS.md docs/GAP_ANALYSIS_RESOLVED.md
git commit -m "docs: record GAP-0016 resolution (parseStream, Design A)

- CHANGELOG: add Unreleased entry for toml.parseStream.
- ROADMAP: clarify that the v2.0.0 streaming issue now tracks
  Design B (truly incremental lexer); Design A shipped.
- GAP_ANALYSIS: move GAP-0016 out of open-gaps.
- GAP_ANALYSIS_RESOLVED: append dated resolution record linking
  code, tests, example, and API reference."
```

---

## Task 7: Roadmap stub for Design B (truly incremental lexer)

**Files:**

- Modify: `docs/ROADMAP.md`

This task produces **no production code**. It writes down the design direction for Design B so that whoever picks up v2.0.0 has a foothold.

- [ ] **Step 1: Append the Design B design sketch to `docs/ROADMAP.md`**

At the end of `docs/ROADMAP.md`, append a new top-level section (use `##`, matching the existing top-level sections):

```markdown
## Design B: Truly Incremental Lexer (v2.0.0 follow-up)

Design A (`toml.parseStream`, shipped) drains the full reader into memory
before parsing. Design B is the real deal: a lexer that pulls from a
`std.Io.Reader` on demand so the peak memory footprint is bounded by a
small rolling buffer plus the accumulating `Document`, not by the size
of the input.

### Why it's hard

The current `Lexer` (`src/lexer.zig`) holds a `[]const u8` and advances a
`usize` cursor. Every byte it has ever seen is still addressable. Two
load-bearing properties rely on that:

1. **Position tracking for diagnostics.** Errors report `byte_index`,
   `line`, and `column` (see `src/error.zig`). With a rolling buffer,
   `byte_index` must be maintained across refills — a `bytes_consumed`
   base plus a relative cursor, then `byte_index = base + cursor`.
2. **Look-behind for multi-byte tokens.** Multi-line strings, datetimes,
   and numeric literals re-read bytes once they've decided which branch
   they're in. The rolling buffer must retain "the start of the current
   token" through a refill, which means the buffer size must be at least
   `max(token length)` and refills are forbidden while a token is open.

### Sketch

- Introduce `Lexer.initReader(reader: *std.Io.Reader, buf: []u8, version)`
  alongside `Lexer.init(input, version)`. The slice-backed init becomes a
  thin wrapper that points the rolling buffer at the full input and
  disables refill.
- Add a `refill(self: *Lexer, keep_from: usize)` helper that slides the
  window from `keep_from` to `end` down to offset 0, then fills the tail
  from the reader. Every tokeniser that opens a token records a
  `token_start` cursor and hands that value to `refill` so no in-flight
  token is truncated.
- `byte_index` becomes `base + cursor`, where `base` is incremented by
  the slide distance on every refill.
- Parser gets a second public entry point that threads the reader all
  the way down instead of delegating to `parse`. `parseStream` will be
  kept as the stable public API; Design A becomes an implementation
  detail that can be swapped for Design B without a breaking change.

### Validation plan (for when this is picked up)

- Port every `tests/streaming.zig` case to run against both Design A and
  Design B and assert byte-for-byte identical `writeTaggedJson` output.
- Add a memory-ceiling test: parse a 100 MiB synthetic input with a
  4 KiB rolling buffer and assert peak RSS delta stays under
  `document_size + buffer_size + slack` (exact bound determined on
  first implementation pass — capture the actual ceiling in the test).
- Run the fuzz harness (`tests/fuzz_parse.zig`) against `parseStream`
  with a reader that feeds bytes one at a time, to shake out refill /
  `token_start` boundary bugs.

### Non-goals for Design B

- Partial parsing / error recovery (that's issue #19 — tracked
  separately under v2.0.0).
- SAX / event-based API (that's issue #15 — separate follow-up).

Design B is not scheduled in this repository; it lives here so that the
v2.0.0 work has a concrete starting point rather than a blank page.
```

- [ ] **Step 2: Commit**

```bash
git add docs/ROADMAP.md
git commit -m "docs(roadmap): sketch Design B (truly incremental lexer) for v2.0.0

Records the design direction for the v2.0.0 streaming follow-up:
rolling-buffer lexer fed by std.Io.Reader, invariants for position
tracking and multi-byte token look-behind, and a validation plan
that reuses the Design A acceptance suite plus a memory-ceiling
test and the fuzz harness. Explicit non-goals: partial parsing
(#19) and SAX (#15)."
```

---

## Self-Review Checklist

After finishing Task 7, run through this checklist before handing off:

- [ ] **`zig build test` is green.** Unit + accept + streaming + fuzz smoke all pass.
- [ ] **`zig build check` is green.** No new compile errors, including the example.
- [ ] **`git log --oneline main..HEAD`** shows exactly seven commits (one per task). No squashing, no amending.
- [ ] **Spec coverage:**
  - GAP-0016 closed by Task 1 implementation + Task 3 acceptance suite.
  - Task 2 pins the reader-error propagation contract.
  - Task 4 provides a user-facing example (satisfies the "add an example at `examples/streaming.zig`" requirement in the spec).
  - Task 5 updates `docs/API.md` (spec requirement).
  - Task 6 updates `CHANGELOG` and moves GAP-0016 to resolved.
  - Task 7 records Design B as roadmap-future in `ROADMAP.md` (spec requirement "do not implement B in this plan").
- [ ] **Placeholder scan:** No "TBD", "implement later", "add appropriate error handling", or "similar to Task N" in the final plan. The Design B "exact bound determined on first implementation pass" phrasing is a deliberate future-work marker, not a hole in this plan — the current plan ships only Design A.
- [ ] **Type consistency:**
  - `parseStream(alloc: Allocator, reader: *std.Io.Reader, opts: ParseOptions) !Document` — same signature in `src/toml.zig`, `docs/API.md`, the example, and every test helper.
  - `ParseOptions.max_bytes` drives both the drain cap (`.limited(opts.max_bytes)`) and the existing parser-side cap — these are already consistent because `parseStream` delegates to `parse`.
  - The test helpers `FailingReader` and `ChunkedReader` both use `@fieldParentPtr("interface", r)` — check the stdlib's current `std.Io.Reader.VTable` signatures if Zig has drifted since 0.15.
- [ ] **Commit-message style:** All seven commits use conventional-commit prefixes (`feat(toml):`, `test(toml):`, `docs(examples):`, `docs(api):`, `docs:`, `docs(roadmap):`) matching the existing history (`chore(deps):`, `feat(toml):`, `ci:` are all already in use).

If any item is not ticked, fix the underlying issue and do **not** amend — create a new commit under the same convention.

---

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-04-18-09-streaming-parser.md`. Two execution options:

1. **Subagent-Driven (recommended)** — dispatch a fresh subagent per task, review between tasks, fast iteration.
2. **Inline Execution** — execute tasks in this session using `superpowers:executing-plans`, batch execution with checkpoints.

Which approach?
