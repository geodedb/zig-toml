# SAX / Event-Driven Parser API Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close GAP-0017 by exposing a SAX-style event-driven parser (`toml.parseEvents`) that fires callbacks as the parser traverses the input and never materializes a `Document` tree.

**Architecture:** Introduce a small internal `ParseSink` abstraction inside `src/parser.zig` so the existing `parse` (which builds a `Document` in an arena) and the new `parseEvents` (which emits events via a user-supplied `EventHandler`) share one recursive-descent walk. The new public surface lives in `src/events.zig` (the `Event` union and `EventHandler` trait-struct) and is re-exported from `src/toml.zig`. Under the hood the parser detects its mode via the sink and either appends to the arena-allocated `Value` tree or dispatches `Event` values to the handler.

**Tech Stack:** Zig 0.15.x std, existing `src/lexer.zig` + `src/parser.zig`, `std.testing.allocator` for leak detection, tagged-union dispatch for the sink.

---

## Scope Check

This plan targets a single subsystem -- the parser's event-emission path. It does not touch the encoder (GAP-0006), the streaming reader (GAP-0016), or the parallel subsystem. Those are tracked in their own plans.

## File Structure

```text
src/
  events.zig           NEW   Event union, EventHandler trait-struct. Has no
                             imports of parser.zig to keep the public type
                             surface cycle-free.
  parser.zig           MOD   Introduce internal ParseSink union. Refactor
                             parseKeyValue / parseTableHeader / parseArray /
                             parseInlineTable / parseValue to route output
                             through the sink. Add parseEvents entrypoint.
  toml.zig             MOD   Re-export Event, EventHandler, parseEvents.
examples/
  sax_parser.zig       NEW   Count keys and tables without building a tree.
tests/
  accept.zig           MOD   Add end-to-end events tests (acceptance surface).
docs/
  API.md               MOD   Document the SAX API next to parse/parseWithError.
CHANGELOG.md           MOD   Add Unreleased entry for GAP-0017.
```

### Boundary notes

- `events.zig` is a leaf module: it imports `value.zig` (for `Value`) and
  nothing else. The parser imports `events.zig` in one direction only.
- `parser.zig` grows; keep the sink local (not exported). The only public
  additions are `parseEvents` and the re-exported `Event`/`EventHandler`.
- Unit tests for event emission parity live colocated in `parser.zig` and
  `events.zig` test blocks. End-to-end acceptance assertions go into
  `tests/accept.zig` so CI runs them as part of the acceptance suite.

### Design note (why a sink, not two parsers)

Duplicating the recursive descent is the hard-to-maintain path -- every future
TOML parser fix would have to land twice and drift is guaranteed. Instead the
plan introduces a single `ParseSink` tagged union with two variants:

```zig
const ParseSink = union(enum) {
    document: DocSink,     // current behavior -- write into arena
    events:   EventSink,   // new behavior   -- dispatch to handler
};
```

`DocSink` is a struct wrapper around `(alloc: Allocator, root: *Value)`.
`EventSink` wraps `(handler: EventHandler)`. Every place the old code wrote a
value into a table, added an entry to an inline table, or opened an array now
calls a sink helper (`sinkEmitTableHeader`, `sinkEmitKeyValueScalar`,
`sinkEmitKeyValueContainer`, `sinkEmitSimple`). The sink implementations do
the right thing for their mode. The parser stays a single walker.

The tests at each task verify sink parity at multiple granularities:
per-construct (Task 3), per-section type (Tasks 5a--5d), and whole-document
(Task 5e).

---

## Conventions Used Throughout This Plan

- Run the whole suite with `zig build test`. Zig's test runner does not take
  a name filter out of the box in this repo's `build.zig`, so expected
  output is always "all tests passed" or the specific assertion line that
  fails. Each step notes which file's tests are expected to change.
- The leak-check gate in CI runs `std.testing.allocator`. Every new test
  must free everything it allocates.
- Commit messages follow the pattern used in recent history
  (`feat(toml): ...`, `test(toml): ...`, `docs(toml): ...`, `chore: ...`).

---

## Task 1: Create `src/events.zig` with the `Event` union

**Files:**

- Create: `src/events.zig`

- [ ] **Step 1.1: Write `src/events.zig` with the public `Event` union**

```zig
// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! SAX-style event types for the event-driven TOML parser.
//!
//! Events are emitted in document order by `toml.parseEvents`. See
//! `docs/API.md` (Event API section) for the contract.

const std = @import("std");
const val = @import("value.zig");

pub const Value = val.Value;

/// A single parser event. Slices inside events (e.g. the `key` in
/// `key_value`, the string inside `.table_header`) point at parser-owned
/// storage that is ONLY valid for the duration of the `handleFn` call.
/// Handlers that want to retain a value must copy it.
pub const Event = union(enum) {
    /// Standard table header: `[section]` or `[a.b.c]`.
    /// The slice is the dotted key rendered verbatim (`"a.b.c"`),
    /// with any quoting preserved. Handlers that need the individual
    /// path segments should split on `.` while respecting quoted keys;
    /// a future revision may add a structured variant.
    table_header: []const u8,

    /// Array-of-tables header: `[[items]]`.
    array_of_tables_header: []const u8,

    /// Top-level or in-table key=value pair. The `value` slot carries a
    /// fully decoded scalar for scalar values. For inline tables and
    /// arrays, the handler receives `inline_table_start`/`array_start`
    /// immediately after this event and `value` is null.
    key_value: KeyValue,

    /// Emitted when the parser enters an inline table `{ ... }` that
    /// was introduced by the most recent `key_value`. Paired with
    /// `inline_table_end`.
    inline_table_start,
    inline_table_end,

    /// Emitted when the parser enters a static array `[ ... ]` that
    /// was introduced by the most recent `key_value`. Paired with
    /// `array_end`. Each scalar inside the array is reported via
    /// `array_item`; nested arrays/inline tables emit their own
    /// `array_start`/`inline_table_start` pairs.
    array_start,
    array_end,

    /// A scalar element inside an array. For nested arrays/inline
    /// tables the parser emits their own start/end pairs instead.
    array_item: Value,

    /// Shape of a `key_value` event. For scalar values `.value` is set.
    /// For container values (inline table, array) `.value` is null and
    /// the caller should expect a following container event.
    pub const KeyValue = struct {
        key: []const u8,
        value: ?Value,
    };
};

/// Trait-struct callback -- mirrors the std.mem.Allocator pattern.
/// Callers set `ctx` to their state pointer and `handleFn` to a
/// function that takes that same pointer back.
pub const EventHandler = struct {
    ctx: *anyopaque,
    handleFn: *const fn (ctx: *anyopaque, event: Event) anyerror!void,

    pub fn handle(self: EventHandler, event: Event) anyerror!void {
        return self.handleFn(self.ctx, event);
    }
};

test "Event union tag count is stable" {
    // Pin the variant count so accidental additions trip CI and force
    // the documentation update. Bump the number AND docs/API.md when
    // intentionally adding an event.
    try std.testing.expectEqual(@as(usize, 8), @typeInfo(Event).@"union".fields.len);
}
```

- [ ] **Step 1.2: Run `zig build test` to confirm the new file compiles**

Run: `zig build test`
Expected: PASS; the "Event union tag count is stable" test runs alongside the
existing suite. If the count test fails, the numeric literal must be updated.

- [ ] **Step 1.3: Commit**

```bash
git add src/events.zig
git commit -m "feat(toml): add Event union and EventHandler scaffolding for GAP-0017"
```

---

## Task 2: Re-export `events` from `src/toml.zig`

**Files:**

- Modify: `src/toml.zig` (add imports near the other `pub const` re-exports)

- [ ] **Step 2.1: Add the `events` module import and re-exports**

Add these lines in `src/toml.zig` directly after the existing
`pub const TomlVersion = parser_mod.TomlVersion;` line and its
`ParseOptions` companion:

```zig
pub const events = @import("events.zig");
pub const Event = events.Event;
pub const EventHandler = events.EventHandler;
```

- [ ] **Step 2.2: Add a smoke test at the bottom of `src/toml.zig`**

Append the following test block. It verifies the type re-export wires through;
`parseEvents` itself does not exist yet (comes in Task 4) so this test only
touches type references.

```zig
test "Event and EventHandler are re-exported from root" {
    const EventType = Event;
    const HandlerType = EventHandler;
    // Type reference is enough; the union tag count lives in events.zig.
    _ = EventType;
    _ = HandlerType;
}
```

- [ ] **Step 2.3: Run `zig build test` to confirm everything still compiles**

Run: `zig build test`
Expected: PASS.

- [ ] **Step 2.4: Commit**

```bash
git add src/toml.zig
git commit -m "feat(toml): re-export Event and EventHandler from toml root module"
```

---

## Task 3: Write a failing end-to-end test for `parseEvents`

This is the first real TDD step: drive the public API contract from a test
before changing any parser internals.

**Files:**

- Modify: `src/toml.zig` (append a test block at the bottom)

- [ ] **Step 3.1: Add the failing test**

Append this block to `src/toml.zig`:

```zig
test "parseEvents emits key_value events for simple pairs" {
    const Collector = struct {
        allocator: std.mem.Allocator,
        keys: std.ArrayList([]const u8),
        ints: std.ArrayList(i64),

        fn init(a: std.mem.Allocator) @This() {
            return .{
                .allocator = a,
                .keys = .empty,
                .ints = .empty,
            };
        }

        fn deinit(self: *@This()) void {
            for (self.keys.items) |k| self.allocator.free(k);
            self.keys.deinit(self.allocator);
            self.ints.deinit(self.allocator);
        }

        fn handle(ctx: *anyopaque, event: Event) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            switch (event) {
                .key_value => |kv| {
                    if (kv.value) |v| switch (v) {
                        .integer => |n| {
                            try self.keys.append(self.allocator, try self.allocator.dupe(u8, kv.key));
                            try self.ints.append(self.allocator, n);
                        },
                        else => {},
                    };
                },
                else => {},
            }
        }
    };

    var collector = Collector.init(std.testing.allocator);
    defer collector.deinit();

    const handler = EventHandler{
        .ctx = &collector,
        .handleFn = Collector.handle,
    };

    try parseEvents(std.testing.allocator, "a = 1\nb = 2\n", handler, .{});

    try std.testing.expectEqual(@as(usize, 2), collector.keys.items.len);
    try std.testing.expectEqualStrings("a", collector.keys.items[0]);
    try std.testing.expectEqualStrings("b", collector.keys.items[1]);
    try std.testing.expectEqual(@as(i64, 1), collector.ints.items[0]);
    try std.testing.expectEqual(@as(i64, 2), collector.ints.items[1]);
}
```

- [ ] **Step 3.2: Run `zig build test` and confirm it fails**

Run: `zig build test`
Expected: FAIL with `error: use of undeclared identifier 'parseEvents'`
(or similar). The failure proves the test exercises the unimplemented API.

- [ ] **Step 3.3: Do NOT commit a red test on its own**

Leave the test uncommitted; Task 4 introduces the implementation and then we
commit the pair together.

---

## Task 4: Implement `ParseSink`, refactor the walker, and add `parseEvents`

This is the biggest task. It replaces direct `val.tableSet`/`val.arrayAppend`
calls with sink calls so the same walk drives either mode.

**Files:**

- Modify: `src/parser.zig`
- Modify: `src/toml.zig` (add the public `parseEvents` wrapper)

The refactor proceeds in sub-steps so any mid-step break is small and
self-contained. Each sub-step keeps the existing `parse` passing.

### Step 4.1: Add the sink definitions at the top of `parser.zig`

Immediately after the existing `pub const TomlVersion = lex.TomlVersion;`
line (roughly line 21 today) insert:

```zig
const events = @import("events.zig");
pub const Event = events.Event;
pub const EventHandler = events.EventHandler;

/// Output sink for the shared recursive-descent walker. `parse` uses
/// `.document` (write into an arena-backed Value tree). `parseEvents`
/// uses `.events` (dispatch Event values to the caller).
///
/// Every sink method takes borrowed slices -- the caller must copy
/// anything it needs past the call. For the document sink the parser
/// already dupes into the arena; for the event sink the user is told
/// in the Event docstring that slices only live for the handleFn call.
const ParseSink = union(enum) {
    document: DocSink,
    events: EventSink,

    const DocSink = struct {
        alloc: Allocator,
        root: *Value,
    };

    const EventSink = struct {
        handler: EventHandler,
    };
};
```

- [ ] **Step 4.1.1: Run `zig build test` -- still green (no behavior change)**

Run: `zig build test`
Expected: PASS.

### Step 4.2: Add a `sink` field to `Parser` and initialize it in `parse`

Replace the existing `Parser` struct field list (keep order of existing
fields) with the following set. The one addition is `sink: ParseSink`.

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
    sink: ParseSink,
```

Update `Parser.init` to set a placeholder sink. Replace the existing
`pub fn init(...)` body with:

```zig
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
            // Placeholder; real value is set at the top of parse() or
            // parseEvents() since only those know the actual sink.
            .sink = .{ .document = .{ .alloc = alloc, .root = undefined } },
        };
    }
```

At the top of the existing `parse` function, *after* the UTF-8 and size
checks and *after* creating the arena and root, add:

```zig
        self.sink = .{ .document = .{ .alloc = arena_alloc, .root = root } };
```

- [ ] **Step 4.2.1: Run `zig build test` -- still green**

Run: `zig build test`
Expected: PASS. No behavior change yet; the sink is initialized but unused.

### Step 4.3: Add sink dispatch helpers inside `Parser`

Insert the following private methods inside the `Parser` struct
(they are `fn`, not `pub fn`):

```zig
    fn sinkEmitTableHeader(self: *Parser, rendered_path: []const u8, is_array_of_tables: bool) !void {
        switch (self.sink) {
            .document => {}, // document sink tracks tables via resolveTablePath
            .events => |es| {
                const ev: Event = if (is_array_of_tables)
                    .{ .array_of_tables_header = rendered_path }
                else
                    .{ .table_header = rendered_path };
                try es.handler.handle(ev);
            },
        }
    }

    fn sinkEmitKeyValueScalar(self: *Parser, rendered_key: []const u8, value: Value) !void {
        switch (self.sink) {
            .document => {}, // document sink writes via val.tableSet in caller
            .events => |es| {
                try es.handler.handle(.{ .key_value = .{ .key = rendered_key, .value = value } });
            },
        }
    }

    fn sinkEmitKeyValueContainer(self: *Parser, rendered_key: []const u8) !void {
        switch (self.sink) {
            .document => {},
            .events => |es| {
                try es.handler.handle(.{ .key_value = .{ .key = rendered_key, .value = null } });
            },
        }
    }

    fn sinkEmitSimple(self: *Parser, event: Event) !void {
        switch (self.sink) {
            .document => {},
            .events => |es| {
                try es.handler.handle(event);
            },
        }
    }
```

- [ ] **Step 4.3.1: Run `zig build test` -- still green**

Run: `zig build test`
Expected: PASS. Still no caller exercises the helpers; they compile because
Zig does not warn on unused struct methods.

### Step 4.4: Wire the sink into `parseKeyValue` (scalar path only)

Locate the end of `parseKeyValue` where the final key is set. Today that
block is:

```zig
        // Set the final key
        const final_key = path.items[path.items.len - 1];
        if (val.tableContains(target, final_key)) {
            self.parse_error = err.makeError(.DuplicateKey, key_pos, "duplicate key");
            return error.ParseFailed;
        }
        try val.tableSet(alloc, target, final_key, value);
```

Replace that block with:

```zig
        // Set the final key.
        const final_key = path.items[path.items.len - 1];
        switch (self.sink) {
            .document => {
                if (val.tableContains(target, final_key)) {
                    self.parse_error = err.makeError(.DuplicateKey, key_pos, "duplicate key");
                    return error.ParseFailed;
                }
                try val.tableSet(alloc, target, final_key, value);
            },
            .events => {
                // Events mode: emit a key_value event per scalar. For
                // container values (inline table / array) the inner
                // walker already emitted its own start/end events while
                // parsing; we still announce the key with a null
                // `.value` so consumers know where the container
                // belongs.
                switch (value.*) {
                    .table, .array => try self.sinkEmitKeyValueContainer(final_key),
                    else => try self.sinkEmitKeyValueScalar(final_key, value.*),
                }
            },
        }
```

- [ ] **Step 4.4.1: Run `zig build test` -- still green (document path
unchanged, events path still unreachable)**

Run: `zig build test`
Expected: PASS.

### Step 4.5: Emit `array_start`/`array_end`/`array_item` inside `parseArray`

In `parseArray`, add the start event before the item loop and emit
`array_item` for each scalar element. Find:

```zig
        while (self.current.tag != .right_bracket and self.current.tag != .double_bracket_close and self.current.tag != .eof) {
            const item = try self.parseValue(alloc);
            try items.append(alloc, item);

            try self.skipArrayWhitespace();

            if (self.current.tag == .comma) {
```

Replace with:

```zig
        // For event-mode, announce array start before consuming any items.
        try self.sinkEmitSimple(.array_start);

        while (self.current.tag != .right_bracket and self.current.tag != .double_bracket_close and self.current.tag != .eof) {
            const item = try self.parseValue(alloc);
            try items.append(alloc, item);
            // For scalar items, also emit array_item. Container items
            // (tables / nested arrays) have already fired their own
            // start/end events from inside parseValue -> parseInlineTable
            // / parseArray; we do NOT want to wrap them in an
            // `array_item`.
            switch (item.*) {
                .table, .array => {},
                else => try self.sinkEmitSimple(.{ .array_item = item.* }),
            }

            try self.skipArrayWhitespace();

            if (self.current.tag == .comma) {
```

Find the existing `return Value{ .array = ... }` at the end of `parseArray`.
Immediately *before* that return, emit the end event:

```zig
        try self.sinkEmitSimple(.array_end);

        return Value{ .array = .{ .items = try items.toOwnedSlice(alloc), .is_static = true } };
```

Apply the same pattern to `parseArrayContents` and
`parseNestedArrayFromDoubleBracket`: emit `.array_start` after the
`enterDepth` guard, emit `.array_item` for non-container items, and emit
`.array_end` right before the final `return Value{ .array = ... }`.

- [ ] **Step 4.5.1: Run `zig build test` -- still green**

Run: `zig build test`
Expected: PASS.

### Step 4.6: Emit `inline_table_start`/`inline_table_end` inside `parseInlineTable`

In `parseInlineTable`, immediately after the `enterDepth` guard block and the
`self.current = try self.nextToken(); // consume {` line, add:

```zig
        try self.sinkEmitSimple(.inline_table_start);
```

At the end of `parseInlineTable`, right before
`return Value{ .table = ... }`, add:

```zig
        try self.sinkEmitSimple(.inline_table_end);
```

- [ ] **Step 4.6.1: Run `zig build test` -- still green**

Run: `zig build test`
Expected: PASS.

### Step 4.7: Emit `table_header` / `array_of_tables_header` in `parseTableHeader`

In `parseTableHeader`, after `parseKeyPath(alloc, &path)` completes and
*before* the `resolveTablePath` call, insert:

```zig
        // Render the dotted path as a single slice for the event. This
        // slice lives in the caller's arena-allocator, so it outlasts
        // the handleFn call for both sinks.
        const rendered = try renderKeyPath(alloc, path.items);
        try self.sinkEmitTableHeader(rendered, is_array_of_tables);
```

Add a new free function near `mergeTables`:

```zig
fn renderKeyPath(alloc: Allocator, parts: []const []const u8) ![]const u8 {
    if (parts.len == 0) return "";
    var total: usize = 0;
    for (parts) |p| total += p.len;
    total += parts.len - 1; // dots
    var out = try alloc.alloc(u8, total);
    var i: usize = 0;
    for (parts, 0..) |p, idx| {
        if (idx != 0) {
            out[i] = '.';
            i += 1;
        }
        @memcpy(out[i .. i + p.len], p);
        i += p.len;
    }
    return out;
}
```

- [ ] **Step 4.7.1: Run `zig build test` -- still green**

Run: `zig build test`
Expected: PASS.

### Step 4.8: Add `parseEvents` in `parser.zig` and re-export from `toml.zig`

At the bottom of `parser.zig` (above any `test` blocks, outside the
`Parser` struct), add:

```zig
/// Run the parser in event-emitting mode. No Document is returned;
/// instead the handler is invoked for every event in document order.
/// Memory allocated during parsing (temporary key strings, rendered
/// paths, decoded escapes) lives in a throwaway arena that is freed
/// before this function returns. Slices handed to the handler are
/// only valid for the duration of the `handleFn` call.
pub fn parseEvents(
    alloc: Allocator,
    input: []const u8,
    handler: EventHandler,
    options: ParseOptions,
) !void {
    // UTF-8 validation (same as Parser.parse).
    if (!std.unicode.utf8ValidateSlice(input)) return error.ParseFailed;
    if (input.len > options.max_bytes) return error.ParseFailed;

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    var parser = Parser.init(alloc, input, options);
    parser.sink = .{ .events = .{ .handler = handler } };
    parser.current = try parser.nextToken();

    // Use the arena for temporary allocations (key paths, decoded
    // strings). The same entrypoint used by `parse` walks the input.
    const throwaway_root = try val.createTable(arena_alloc);
    try parser.parseDocument(arena_alloc, throwaway_root);
}
```

Update `src/toml.zig` to re-export this new public function. Find the
existing `pub fn parse(...)` block and add below it:

```zig
/// Event-driven TOML parser. See docs/API.md and examples/sax_parser.zig.
pub fn parseEvents(
    alloc: Allocator,
    input: []const u8,
    handler: EventHandler,
    opts: ParseOptions,
) !void {
    return parser_mod.parseEvents(alloc, input, handler, opts);
}
```

- [ ] **Step 4.8.1: Run `zig build test` -- the Task 3 test now passes**

Run: `zig build test`
Expected: PASS including the `"parseEvents emits key_value events for simple
pairs"` test added in Task 3. If it fails, inspect which event was missing
and re-check Steps 4.4 and 4.6.

- [ ] **Step 4.8.2: Commit the Task 3 test + the whole refactor together**

```bash
git add src/parser.zig src/toml.zig src/events.zig
git commit -m "feat(toml): close GAP-0017 -- event-driven parser"
```

---

## Task 5: Acceptance tests for every container construct

Each sub-task writes a new test, runs it, and confirms the code already
passes (because of Task 4). These tests lock in the Task 4 behavior across
all document shapes so future parser edits must preserve sink parity.

**Files:**

- Modify: `tests/accept.zig`

### Step 5a: Test table headers

- [ ] **Step 5a.1: Append this test to `tests/accept.zig`**

```zig
test "parseEvents: table header" {
    const toml = @import("toml");
    const Collector = struct {
        allocator: std.mem.Allocator,
        headers: std.ArrayList([]const u8),
        keys: std.ArrayList([]const u8),

        fn init(a: std.mem.Allocator) @This() {
            return .{ .allocator = a, .headers = .empty, .keys = .empty };
        }
        fn deinit(self: *@This()) void {
            for (self.headers.items) |h| self.allocator.free(h);
            for (self.keys.items) |k| self.allocator.free(k);
            self.headers.deinit(self.allocator);
            self.keys.deinit(self.allocator);
        }
        fn handle(ctx: *anyopaque, ev: toml.Event) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            switch (ev) {
                .table_header => |h| try self.headers.append(self.allocator, try self.allocator.dupe(u8, h)),
                .key_value => |kv| try self.keys.append(self.allocator, try self.allocator.dupe(u8, kv.key)),
                else => {},
            }
        }
    };

    var c = Collector.init(std.testing.allocator);
    defer c.deinit();
    try toml.parseEvents(
        std.testing.allocator,
        "[section]\nkey = \"value\"\n",
        .{ .ctx = &c, .handleFn = Collector.handle },
        .{},
    );

    try std.testing.expectEqual(@as(usize, 1), c.headers.items.len);
    try std.testing.expectEqualStrings("section", c.headers.items[0]);
    try std.testing.expectEqual(@as(usize, 1), c.keys.items.len);
    try std.testing.expectEqualStrings("key", c.keys.items[0]);
}
```

- [ ] **Step 5a.2: Run and confirm it passes**

Run: `zig build test`
Expected: PASS.

### Step 5b: Test array of tables

- [ ] **Step 5b.1: Append this test to `tests/accept.zig`**

```zig
test "parseEvents: array of tables" {
    const toml = @import("toml");
    const Collector = struct {
        allocator: std.mem.Allocator,
        aot_headers: std.ArrayList([]const u8),

        fn init(a: std.mem.Allocator) @This() {
            return .{ .allocator = a, .aot_headers = .empty };
        }
        fn deinit(self: *@This()) void {
            for (self.aot_headers.items) |h| self.allocator.free(h);
            self.aot_headers.deinit(self.allocator);
        }
        fn handle(ctx: *anyopaque, ev: toml.Event) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            switch (ev) {
                .array_of_tables_header => |h| try self.aot_headers.append(self.allocator, try self.allocator.dupe(u8, h)),
                else => {},
            }
        }
    };

    var c = Collector.init(std.testing.allocator);
    defer c.deinit();
    const input =
        \\[[items]]
        \\name = "x"
        \\
        \\[[items]]
        \\name = "y"
    ;
    try toml.parseEvents(
        std.testing.allocator,
        input,
        .{ .ctx = &c, .handleFn = Collector.handle },
        .{},
    );

    try std.testing.expectEqual(@as(usize, 2), c.aot_headers.items.len);
    try std.testing.expectEqualStrings("items", c.aot_headers.items[0]);
    try std.testing.expectEqualStrings("items", c.aot_headers.items[1]);
}
```

- [ ] **Step 5b.2: Run and confirm it passes**

Run: `zig build test`
Expected: PASS.

### Step 5c: Test inline table start/end bracketing

- [ ] **Step 5c.1: Append this test to `tests/accept.zig`**

```zig
test "parseEvents: inline table brackets correctly" {
    const toml = @import("toml");
    const Tracker = struct {
        depth: i32 = 0,
        max_depth: i32 = 0,
        starts: usize = 0,
        ends: usize = 0,

        fn handle(ctx: *anyopaque, ev: toml.Event) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            switch (ev) {
                .inline_table_start => {
                    self.starts += 1;
                    self.depth += 1;
                    if (self.depth > self.max_depth) self.max_depth = self.depth;
                },
                .inline_table_end => {
                    self.ends += 1;
                    self.depth -= 1;
                },
                else => {},
            }
        }
    };

    var t: Tracker = .{};
    try toml.parseEvents(
        std.testing.allocator,
        "point = { x = 1, y = 2 }\n",
        .{ .ctx = &t, .handleFn = Tracker.handle },
        .{},
    );
    try std.testing.expectEqual(@as(usize, 1), t.starts);
    try std.testing.expectEqual(@as(usize, 1), t.ends);
    try std.testing.expectEqual(@as(i32, 0), t.depth);
    try std.testing.expectEqual(@as(i32, 1), t.max_depth);
}
```

- [ ] **Step 5c.2: Run and confirm it passes**

Run: `zig build test`
Expected: PASS.

### Step 5d: Test array start/end/item for scalar arrays

- [ ] **Step 5d.1: Append this test to `tests/accept.zig`**

```zig
test "parseEvents: scalar array emits array_item per element" {
    const toml = @import("toml");
    const Tracker = struct {
        starts: usize = 0,
        ends: usize = 0,
        items: std.ArrayList(i64),

        fn init() @This() {
            return .{ .items = .empty };
        }
        fn deinit(self: *@This(), a: std.mem.Allocator) void {
            self.items.deinit(a);
        }
        fn handle(ctx: *anyopaque, ev: toml.Event) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            switch (ev) {
                .array_start => self.starts += 1,
                .array_end => self.ends += 1,
                .array_item => |v| switch (v) {
                    .integer => |n| try self.items.append(std.testing.allocator, n),
                    else => {},
                },
                else => {},
            }
        }
    };

    var t = Tracker.init();
    defer t.deinit(std.testing.allocator);
    try toml.parseEvents(
        std.testing.allocator,
        "arr = [1, 2, 3]\n",
        .{ .ctx = &t, .handleFn = Tracker.handle },
        .{},
    );
    try std.testing.expectEqual(@as(usize, 1), t.starts);
    try std.testing.expectEqual(@as(usize, 1), t.ends);
    try std.testing.expectEqual(@as(usize, 3), t.items.items.len);
    try std.testing.expectEqual(@as(i64, 1), t.items.items[0]);
    try std.testing.expectEqual(@as(i64, 2), t.items.items[1]);
    try std.testing.expectEqual(@as(i64, 3), t.items.items[2]);
}
```

- [ ] **Step 5d.2: Run and confirm it passes**

Run: `zig build test`
Expected: PASS.

### Step 5e: Test a realistic multi-section document for event ordering parity

- [ ] **Step 5e.1: Append this test to `tests/accept.zig`**

```zig
test "parseEvents: whole-document event ordering matches document sink" {
    const toml = @import("toml");
    const Recorder = struct {
        allocator: std.mem.Allocator,
        log: std.ArrayList([]const u8),

        fn init(a: std.mem.Allocator) @This() {
            return .{ .allocator = a, .log = .empty };
        }
        fn deinit(self: *@This()) void {
            for (self.log.items) |s| self.allocator.free(s);
            self.log.deinit(self.allocator);
        }
        fn push(self: *@This(), s: []const u8) !void {
            try self.log.append(self.allocator, try self.allocator.dupe(u8, s));
        }
        fn handle(ctx: *anyopaque, ev: toml.Event) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            switch (ev) {
                .table_header => |h| {
                    var buf: [128]u8 = undefined;
                    const s = try std.fmt.bufPrint(&buf, "[{s}]", .{h});
                    try self.push(s);
                },
                .array_of_tables_header => |h| {
                    var buf: [128]u8 = undefined;
                    const s = try std.fmt.bufPrint(&buf, "[[{s}]]", .{h});
                    try self.push(s);
                },
                .key_value => |kv| {
                    var buf: [128]u8 = undefined;
                    const s = try std.fmt.bufPrint(&buf, "kv:{s}", .{kv.key});
                    try self.push(s);
                },
                .inline_table_start => try self.push("{"),
                .inline_table_end => try self.push("}"),
                .array_start => try self.push("["),
                .array_end => try self.push("]"),
                .array_item => try self.push("item"),
            }
        }
    };

    const input =
        \\title = "z"
        \\[srv]
        \\host = "h"
        \\ports = [80, 443]
        \\[[users]]
        \\name = "alice"
        \\[[users]]
        \\name = "bob"
    ;

    var rec = Recorder.init(std.testing.allocator);
    defer rec.deinit();
    try toml.parseEvents(
        std.testing.allocator,
        input,
        .{ .ctx = &rec, .handleFn = Recorder.handle },
        .{},
    );

    const expected = [_][]const u8{
        "kv:title",
        "[srv]",
        "kv:host",
        "kv:ports",
        "[",
        "item",
        "item",
        "]",
        "[[users]]",
        "kv:name",
        "[[users]]",
        "kv:name",
    };
    try std.testing.expectEqual(expected.len, rec.log.items.len);
    for (expected, 0..) |want, i| {
        try std.testing.expectEqualStrings(want, rec.log.items[i]);
    }
}
```

- [ ] **Step 5e.2: Run and confirm it passes**

Run: `zig build test`
Expected: PASS. If the order differs, the culprit is almost always the
`sinkEmitTableHeader` call placement in `parseTableHeader`: it must run
*before* `resolveTablePath`, otherwise nested header-to-keyvalue events
interleave incorrectly.

- [ ] **Step 5e.3: Commit all five acceptance tests**

```bash
git add tests/accept.zig
git commit -m "test(toml): acceptance coverage for parseEvents across all constructs"
```

---

## Task 6: Verify nothing else regressed

- [ ] **Step 6.1: Run the full test suite**

Run: `zig build test`
Expected: PASS across unit, accept, and fuzz smoke tests.

- [ ] **Step 6.2: Build the CLI target to prove `parse`'s public shape is unbroken**

Run: `zig build`
Expected: Succeeds with no warnings. The `toml-test-decoder` binary installs
into `zig-out/bin/`.

- [ ] **Step 6.3: Run check**

Run: `zig build check`
Expected: PASS.

No commit for this task; it is a gate before Task 7.

---

## Task 7: Add `examples/sax_parser.zig`

This example demonstrates why an event-driven API is useful: count keys in a
document without ever allocating the `Document` tree.

**Files:**

- Create: `examples/sax_parser.zig`

- [ ] **Step 7.1: Write the example**

```zig
// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! SAX-style TOML parsing example.
//!
//! Demonstrates the event-driven parser (`toml.parseEvents`). The
//! handler counts keys, tables, and array-of-tables headers without
//! ever building a `Document` tree. This is more memory-efficient
//! than `toml.parse` for large configuration files where the caller
//! only needs a small subset of the data.

const std = @import("std");
const toml = @import("toml");

const Counter = struct {
    keys: usize = 0,
    tables: usize = 0,
    array_of_tables: usize = 0,
    inline_tables: usize = 0,
    arrays: usize = 0,

    fn handle(ctx: *anyopaque, event: toml.Event) anyerror!void {
        const self: *Counter = @ptrCast(@alignCast(ctx));
        switch (event) {
            .key_value => self.keys += 1,
            .table_header => self.tables += 1,
            .array_of_tables_header => self.array_of_tables += 1,
            .inline_table_start => self.inline_tables += 1,
            .array_start => self.arrays += 1,
            else => {},
        }
    }
};

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const stdout = std.io.getStdOut().writer();

    const input =
        \\title = "My Application"
        \\version = "1.0.0"
        \\
        \\[server]
        \\host = "localhost"
        \\port = 8080
        \\ports = [80, 443, 8080]
        \\
        \\[database]
        \\url = "postgres://localhost:5432/mydb"
        \\credentials = { user = "admin", pass = "secret" }
        \\
        \\[[users]]
        \\name = "alice"
        \\
        \\[[users]]
        \\name = "bob"
    ;

    var counter: Counter = .{};
    const handler = toml.EventHandler{
        .ctx = &counter,
        .handleFn = Counter.handle,
    };

    try toml.parseEvents(allocator, input, handler, .{});

    try stdout.print("=== SAX Parser Example ===\n\n", .{});
    try stdout.print("key=value pairs : {d}\n", .{counter.keys});
    try stdout.print("[table] headers : {d}\n", .{counter.tables});
    try stdout.print("[[aot]] headers : {d}\n", .{counter.array_of_tables});
    try stdout.print("inline tables   : {d}\n", .{counter.inline_tables});
    try stdout.print("arrays          : {d}\n", .{counter.arrays});
}
```

- [ ] **Step 7.2: Smoke-check that the example compiles**

The other examples (`examples/basic_parsing.zig` etc.) are not wired into
`build.zig` as standalone exes; they are documentation. To give the SAX
example a compile check, run the acceptance suite (which imports the `toml`
module the example depends on) and then do a manual module-only import
check:

Run: `zig build test`
Expected: PASS.

Optional: run `zig ast-check examples/sax_parser.zig` to confirm the file
is syntactically valid. Expected: no output (success).

- [ ] **Step 7.3: Commit**

```bash
git add examples/sax_parser.zig
git commit -m "docs(toml): add SAX parser example demonstrating parseEvents"
```

---

## Task 8: Update `docs/API.md` and `CHANGELOG.md`

**Files:**

- Modify: `docs/API.md`
- Modify: `CHANGELOG.md`

### Step 8.1: Add the Event API section to `docs/API.md`

Insert the following section immediately after the existing `parseWithError`
documentation block (look for the `---` separator following the
`parseWithError` example and insert before the next section):

```markdown
### parseEvents

\`\`\`zig
pub fn parseEvents(
    alloc: Allocator,
    input: []const u8,
    handler: EventHandler,
    opts: ParseOptions,
) !void
\`\`\`

**Description:** Parse TOML with SAX-style event emission. No `Document`
is built; the supplied `handler` is invoked for every event in document
order. This is useful for:

- counting or filtering keys without paying the arena cost of a tree,
- streaming large configs to a downstream consumer,
- validation-only passes.

**Parameters:**

| Parameter | Type | Description |
|-----------|------|-------------|
| alloc | Allocator | Working allocator (backs a short-lived arena freed before return) |
| input | []const u8 | TOML source text (must be valid UTF-8) |
| handler | EventHandler | Callback + opaque context pointer |
| opts | ParseOptions | Same options struct as `parse` |

**Events:** `Event` is a tagged union with the following variants:

| Variant | Payload | Emitted when |
|---------|---------|--------------|
| `table_header` | `[]const u8` | `[section]` header encountered |
| `array_of_tables_header` | `[]const u8` | `[[items]]` header encountered |
| `key_value` | `KeyValue { key, value: ?Value }` | key=value pair (value is null for containers) |
| `inline_table_start` / `inline_table_end` | -- | wraps `{ ... }` |
| `array_start` / `array_end` | -- | wraps `[ ... ]` |
| `array_item` | `Value` | scalar element of an array |

**Slice lifetime:** All slices inside an `Event` are only valid for the
duration of the `handleFn` call. Copy them if you need them longer.

**Errors:**

| Error | Description |
|-------|-------------|
| error.ParseFailed | Parse error (UTF-8, syntax, size limits, ...) |
| error.OutOfMemory | Working allocator exhausted |
| *any anyerror the handler returns* | Propagated verbatim |

**Example:** See `examples/sax_parser.zig`.

---
```

(When you paste this block into `docs/API.md`, replace the
`\`\`\`zig` fences back to triple-backtick `zig` fences -- the escapes
above are present so this plan file itself still renders correctly.)

### Step 8.2: Add a CHANGELOG entry

Locate the `## [Unreleased]` section's `### Added` subsection (around line
10 of `CHANGELOG.md` today) and append the following bullet directly
under the existing bullets:

```markdown
- SAX-style event parser API (`toml.parseEvents`, `toml.Event`,
  `toml.EventHandler`). Closes GAP-0017. Shares the recursive-descent
  walker with `toml.parse` via a private `ParseSink` abstraction so the
  two APIs cannot drift apart. See `docs/API.md` (Event API) and
  `examples/sax_parser.zig`.
```

- [ ] **Step 8.3: Run the test suite**

Run: `zig build test`
Expected: PASS (docs edits cannot break the Zig suite, but run it to
confirm you did not accidentally edit a `.zig` file instead).

- [ ] **Step 8.4: Commit**

```bash
git add docs/API.md CHANGELOG.md
git commit -m "docs(toml): document parseEvents API and changelog entry for GAP-0017"
```

---

## Task 9: Update the gap tracker

**Files:**

- Modify: `docs/GAP_ANALYSIS.md`
- Modify: `docs/GAP_ANALYSIS_RESOLVED.md`

The convention in this repo (see GAP-0002 and GAP-0003 precedents) is:

1. Flip GAP-0017 to "Closed" in `docs/GAP_ANALYSIS.md`.
2. Move the full entry to `docs/GAP_ANALYSIS_RESOLVED.md`.

- [ ] **Step 9.1: In `docs/GAP_ANALYSIS.md`, edit the GAP-0017 block**

Replace the existing block:

```markdown
### GAP-0017: SAX / event API

- **Issue:** [#15](https://gitlab.com/devnw/zig/toml/-/issues/15)
- **Category:** Feature
- **Severity:** Medium
- **Requirement source:** REQ-15.
- **Current state (evidence):** No event callbacks.
- **Recommended fix:** Event enum + visitor interface.
```

with a short "Closed -- see resolved" placeholder (matches the
GAP-0002 / GAP-0003 pattern):

```markdown
### GAP-0017: SAX / event API

- **Status:** Closed -- moved to `docs/GAP_ANALYSIS_RESOLVED.md`.
```

- [ ] **Step 9.2: In `docs/GAP_ANALYSIS_RESOLVED.md`, append the resolved entry**

Append under the existing resolved entries (match their heading level and
field order; the simplest form that matches precedents is):

```markdown
### GAP-0017: SAX / event API -- Closed

- **Issue:** [#15](https://gitlab.com/devnw/zig/toml/-/issues/15)
- **Category:** Feature
- **Severity:** Medium
- **Requirement source:** REQ-15.
- **Resolution:** `toml.parseEvents` lands a SAX-style event-driven
  parser sharing the recursive-descent walker with `toml.parse` via a
  private `ParseSink` abstraction. Public types: `Event`,
  `EventHandler`. See `docs/API.md` (Event API section) and
  `examples/sax_parser.zig`.
- **Resolution evidence:** `src/events.zig` (new), `src/parser.zig`
  (sink refactor + `parseEvents`), `src/toml.zig` (re-exports),
  `tests/accept.zig` (five parity tests),
  `examples/sax_parser.zig` (new).
```

- [ ] **Step 9.3: Run tests and commit**

Run: `zig build test`
Expected: PASS.

```bash
git add docs/GAP_ANALYSIS.md docs/GAP_ANALYSIS_RESOLVED.md
git commit -m "chore: mark GAP-0017 closed in gap tracker"
```

---

## Task 10: Final self-review against the spec

- [ ] **Step 10.1: Re-read the spec header**

Re-confirm each of the following bullets against the code:

1. `Event` union contains `table_header`, `array_of_tables_header`,
   `key_value`, `inline_table_start`, `inline_table_end`, `array_start`,
   `array_end`, `array_item`. (File: `src/events.zig`.)
2. `EventHandler` is a trait-struct with `ctx: *anyopaque` and
   `handleFn: *const fn(ctx: *anyopaque, event: Event) anyerror!void`.
   (File: `src/events.zig`.)
3. `parseEvents(alloc, input, handler, options)` is exposed from the
   `toml` root module and does NOT return a `Document`. (File:
   `src/toml.zig`.)
4. Under the hood the parser walks the same lexer; the `ParseSink`
   abstraction is in `src/parser.zig`. (Check: search `parser.zig` for
   `ParseSink` and `sinkEmit*` helpers.)
5. Tests exist for: simple key=value pairs, table headers,
   array-of-tables, inline tables, arrays, whole-document ordering.
   (Files: `src/toml.zig` -- one unit test; `tests/accept.zig` -- five
   tests.)
6. Example exists that counts keys without building the tree. (File:
   `examples/sax_parser.zig`.)
7. `docs/API.md` has a `parseEvents` section.
8. `CHANGELOG.md` has an Unreleased entry referencing GAP-0017.
9. Gap tracker is updated.

- [ ] **Step 10.2: Run the whole suite one last time**

Run: `zig build test`
Expected: PASS.

- [ ] **Step 10.3: Run `zig build` (full build + install) to confirm the
library surface compiles for downstream consumers**

Run: `zig build`
Expected: Succeeds with no warnings.

- [ ] **Step 10.4: Confirm no leaks reported**

The leak-check CI gate runs `std.testing.allocator`. Since every new test
above frees its collector allocations explicitly, no extra action is
needed here -- but if any tests added by Task 5 fail leak-check, the fix
is always one of:

- missing `defer c.deinit()` -- add it.
- missing `self.allocator.free(h)` loop inside `deinit` -- add it.
- missing `std.testing.allocator` on an ArrayList -- pass it where
  required.

- [ ] **Step 10.5: No extra commit needed**

All code has been committed in Tasks 1, 4, 5, 7, 8, and 9. If any fix was
required in Step 10.4, commit it with
`git commit -m "fix(toml): plug leak in parseEvents acceptance tests"`.

---

## Execution order summary

The plan commits land in this order:

1. `feat(toml): add Event union and EventHandler scaffolding for GAP-0017`
   (Task 1)
2. `feat(toml): re-export Event and EventHandler from toml root module`
   (Task 2)
3. `feat(toml): close GAP-0017 -- event-driven parser` (Task 4, folds
   in Task 3's test)
4. `test(toml): acceptance coverage for parseEvents across all
   constructs` (Task 5)
5. `docs(toml): add SAX parser example demonstrating parseEvents`
   (Task 7)
6. `docs(toml): document parseEvents API and changelog entry for
   GAP-0017` (Task 8)
7. `chore: mark GAP-0017 closed in gap tracker` (Task 9)

Tasks 6 and 10 are verification gates that do not produce commits unless
they turn up a defect.

---

## Rollback plan

Every commit above is self-contained and reversible with `git revert`.
The minimum rollback to undo the feature is to revert commits 1, 2, 3,
4, 5, 6, and 7 from the list above in reverse order. After rollback,
`toml.parse` and all existing consumers remain unchanged because the
`ParseSink` refactor preserves the document-sink path bit-for-bit.

---

## Notes for the implementing agent

- The `Value` type exposed in `Event.array_item` and `Event.KeyValue.value`
  is the existing union from `src/value.zig`. For scalar values this is a
  straight copy (string, integer, float, bool, datetime variants). You do
  NOT need to reuse the parser's arena-allocated pointer; the copy
  semantics match Zig's tagged-union by-value passing.

- `[]const u8` slices inside events point at either the original input
  buffer (for bare keys, literal strings) or a short-lived arena
  (for decoded basic strings, rendered dotted paths). They are stable
  for the duration of the `handleFn` call but NOT longer; the arena is
  freed inside `parseEvents` before the function returns.

- If you discover a case where the event ordering does NOT match the
  document-sink ordering, the canonical fix is to move the sink emit
  call closer to where the document sink mutates state. For example:
  the `table_header` event is emitted BEFORE `resolveTablePath` so the
  handler sees "enter section" before any key_value events inside that
  section fire.

- The `renderKeyPath` helper added in Step 4.7 allocates into whichever
  allocator was passed to `parseDocument`. For document-mode this is
  the document's arena (freed at `Document.deinit`). For events-mode
  this is the throwaway arena in `parseEvents` (freed on return). Either
  way the slice outlives the `handleFn` call.

- The `Counter` struct in `examples/sax_parser.zig` deliberately avoids
  any heap allocation; the example's point is to show that a consumer
  of `parseEvents` can process an arbitrarily large document with
  O(1) additional memory beyond the parser's own arena.
