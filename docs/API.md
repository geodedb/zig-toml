# TOML Parser API Reference

**Library Version:** 0.1.6
**TOML Versions:** v1.0.0, v1.1.0
**Last Updated:** 2026-06-11

## Overview

The zigtoml library provides a fully compliant TOML parser for Zig, supporting both TOML v1.0.0 and v1.1.0 specifications. It outputs typed value trees and can emit toml-test compatible tagged JSON.

## Quick Start

```zig
const toml = @import("toml");
const std = @import("std");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const input =
        \\[server]
        \\host = "localhost"
        \\port = 8080
    ;

    const doc = try toml.parse(allocator, input, .{});
    defer doc.deinit();

    if (doc.root.get("server")) |server| {
        if (server.get("host")) |host| {
            std.debug.print("Host: {s}\n", .{host.string});
        }
    }
}
```

## Core Functions

### parse

```zig
pub fn parse(alloc: Allocator, input: []const u8, opts: ParseOptions) !*Document
```

**Description:** Parse TOML input into a Document.

**Parameters:**

| Parameter | Type | Description |
|-----------|------|-------------|
| alloc | Allocator | Memory allocator for the parsed document |
| input | []const u8 | TOML source text (must be valid UTF-8) |
| opts | ParseOptions | Configuration options for parsing |

**Returns:** `*Document` - Pointer to a heap-allocated Document containing
the root table. The caller must call `doc.deinit()` to free the
Document's arena and the Document struct itself.

**Errors:**

| Error | Description |
|-------|-------------|
| error.ParseFailed | Parse error occurred (use parseWithError for details) |
| error.OutOfMemory | Memory allocation failed |

**Example:**

```zig
const doc = try toml.parse(allocator, "key = \"value\"", .{});
defer doc.deinit();

const val = doc.root.get("key").?.string;
```

---

### parseWithError

```zig
pub fn parseWithError(alloc: Allocator, input: []const u8, opts: ParseOptions) ParseResult
```

**Description:** Parse TOML with detailed error reporting. Returns either a Document or a ParseError with location information.

**Parameters:**

| Parameter | Type | Description |
|-----------|------|-------------|
| alloc | Allocator | Memory allocator for the parsed document |
| input | []const u8 | TOML source text (must be valid UTF-8) |
| opts | ParseOptions | Configuration options for parsing |

**Returns:** `ParseResult` - Union of `ok: *Document` or `err: ParseError`

**Example:**

```zig
const result = toml.parseWithError(allocator, input, .{});
switch (result) {
    .ok => |doc| {
        defer doc.deinit();
        // Use document...
    },
    .err => |e| {
        std.debug.print("Error at line {d}, col {d}: {s}\n", .{
            e.line, e.column, e.message,
        });
    },
}
```

---

### parseStream

```zig
pub fn parseStream(
    alloc: Allocator,
    reader: *std.Io.Reader,
    opts: ParseOptions,
) !*Document
```

**Description:** Parse a TOML document from any `std.Io.Reader` (file,
socket, pipe, test fixture). Internally the reader is drained into a
single `opts.max_bytes`-bounded buffer owned by `alloc`, then delegated
to `parse`. Ownership of the returned `*Document` and its memory arena
is identical to `parse` -- call `deinit()` to free it.

**Parameters:**

| Parameter | Type | Description |
|-----------|------|-------------|
| alloc | Allocator | Memory allocator. Used both for the transient drain buffer (freed before return) and for the returned Document's arena. |
| reader | `*std.Io.Reader` | Streaming reader. The reader is drained to EOF. |
| opts | ParseOptions | Same options as `parse`. `opts.max_bytes` acts as an upper bound on both the drain and the subsequent parse. |

**Returns:** `*Document` -- see `parse`.

**Errors:**

| Error | Description |
|-------|-------------|
| `error.ParseFailed` | TOML parse error (use `parseWithError` on a pre-read slice when you need details). |
| `error.StreamTooLong` | Reader produced more than `opts.max_bytes` bytes before EOF. |
| `error.OutOfMemory` | Allocation failed. |
| (any reader error) | Propagated unchanged from the underlying `std.Io.Reader`. |

**Example -- parse a TOML file:**

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

    const doc = try toml.parseStream(allocator, &file_reader.interface, .{});
    defer doc.deinit();

    if (doc.root.get("title")) |t| {
        std.debug.print("title = {s}\n", .{t.string});
    }
}
```

**Notes:**

- Design A ("buffer-then-parse"): this entry point still materialises
  the full document in memory. It removes the boilerplate of driving
  the reader yourself but does **not** enable parsing documents
  larger than `opts.max_bytes`. Truly incremental lexing is tracked
  under v2.0.0 (see `docs/ROADMAP.md`).
- Thread safety matches `parse`: the returned `Document` is safe to
  share across threads only under the same rules as `parse` output.

---

### parseEvents

```zig
pub fn parseEvents(
    alloc: Allocator,
    input: []const u8,
    handler: EventHandler,
    opts: ParseOptions,
) !void
```

**Description:** Parse TOML with SAX-style event emission. No
`Document` is built; the supplied `handler` is invoked for every
event in document order. This is useful for:

- counting or filtering keys without paying the arena cost of a tree,
- streaming large configs to a downstream consumer,
- validation-only passes.

**Parameters:**

| Parameter | Type | Description |
|-----------|------|-------------|
| `alloc` | `Allocator` | Working allocator (backs a short-lived arena freed before return). |
| `input` | `[]const u8` | TOML source text (must be valid UTF-8). |
| `handler` | `EventHandler` | Trait-struct with `ctx: *anyopaque` and `handleFn: *const fn(ctx, Event) anyerror!void`. |
| `opts` | `ParseOptions` | Same options struct as `parse`. |

**Events:** `Event` is a tagged union with the following variants:

| Variant | Payload | Emitted when |
|---------|---------|--------------|
| `table_header` | `[]const u8` | `[section]` header encountered; payload is the dotted path rendered as `"a.b.c"`. |
| `array_of_tables_header` | `[]const u8` | `[[items]]` header encountered. |
| `key_value` | `KeyValue { key: []const u8, value: ?Value }` | Key=value pair. For scalar values `value` is set; for container values (inline table, array) `value` is null and the corresponding `inline_table_start` / `array_start` event fires immediately after. |
| `inline_table_start` / `inline_table_end` | -- | Wrap `{ ... }`. |
| `array_start` / `array_end` | -- | Wrap `[ ... ]`. |
| `array_item` | `Value` | A scalar element of an array. Container elements (nested arrays, inline tables) emit their own start/end pairs instead. |

**Slice lifetime:** All `[]const u8` slices inside an `Event` point at
parser-owned storage and are only valid for the duration of the
`handleFn` call. Copy them (e.g. `allocator.dupe(u8, ...)`) if you
need them longer. The same rule applies to string payloads inside a
`Value`.

**Errors:**

| Error | Description |
|-------|-------------|
| `error.ParseFailed` | TOML parse error (UTF-8, syntax, size limits, resource caps). |
| `error.OutOfMemory` | Working allocator exhausted. |
| *any anyerror the handler returns* | Propagated verbatim. |

**Example:**

```zig
const Counter = struct {
    keys: usize = 0,
    fn handle(ctx: *anyopaque, ev: toml.Event) anyerror!void {
        const self: *Counter = @ptrCast(@alignCast(ctx));
        if (ev == .key_value) self.keys += 1;
    }
};

var c: Counter = .{};
try toml.parseEvents(
    allocator,
    input,
    .{ .ctx = &c, .handleFn = Counter.handle },
    .{},
);
std.debug.print("saw {d} keys\n", .{c.keys});
```

See `examples/sax_parser.zig` for a full handler that counts keys,
tables, array-of-tables, inline tables, and arrays.

---

### writeTaggedJson

```zig
pub fn writeTaggedJson(doc: *const Document, writer: anytype) !void
```

**Description:** Write toml-test compatible tagged JSON. Keys are sorted lexicographically at every level for deterministic output.

**Parameters:**

| Parameter | Type | Description |
|-----------|------|-------------|
| doc | *const Document | The parsed document to serialize |
| writer | anytype | Any type implementing the Writer interface |

**Example:**

```zig
const doc = try toml.parse(allocator, "a = 42", .{});
defer doc.deinit();

const stdout = std.io.getStdOut().writer();
try toml.writeTaggedJson(doc, stdout);
// Output: {"a":{"type":"integer","value":"42"}}
```

## Encoding

### encode

```zig
pub fn encode(doc: *const Document, writer: anytype, options: EncodeOptions) !void
```

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

```zig
var doc = try toml.parse(allocator, "a = 42\n", .{});
defer doc.deinit();

var aw: std.Io.Writer.Allocating = .init(allocator);
defer aw.deinit();
try toml.encode(doc, &aw.writer, .{});
// aw.written() == "a = 42\n"
```

Closes GAP-0006 (encoder feature) and GAP-0008 (pretty-print / stable-sort
output) -- see `docs/GAP_ANALYSIS_RESOLVED.md` for the closure evidence.

### EncodeOptions

```zig
pub const EncodeOptions = struct {
    sort_keys: bool = true,
    indent: u8 = 0,
    inline_threshold: usize = 8,
};
```

| Field | Default | Description |
|-------|---------|-------------|
| sort_keys | true | Sort table keys byte-order at every level |
| indent | 0 | Spaces of indent for wrapped inline arrays (0 disables wrapping) |
| inline_threshold | 8 | Inline arrays longer than this wrap when `indent > 0` |

### Encoder rules

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

## Types

### ParseOptions

Configuration options for the parser.

```zig
pub const ParseOptions = struct {
    version: TomlVersion = .v1_1_0,
    max_depth: u16 = 128,
    max_bytes: usize = 16 * 1024 * 1024,
    max_keys: usize = 100_000,
    max_values: usize = 500_000,
};
```

**Fields:**

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| version | TomlVersion | .v1_1_0 | TOML version for parsing |
| max_depth | u16 | 128 | Maximum nesting depth for arrays/tables |
| max_bytes | usize | 16 MB | Maximum input size in bytes |
| max_keys | usize | 100_000 | Maximum total keys across all tables |
| max_values | usize | 500_000 | Maximum `*Value` nodes allocated by the parser |

#### Resource Limits

The parser enforces per-parse caps that defend against pathological
inputs (CWE-400 / CWE-789 memory amplification -- see S-9 hardening).

- `max_keys` -- hard cap on the total number of keys the parser creates
  across all tables. Each `parseKeyValue` call charges one unit. When
  the cap is exceeded the parser returns `ErrorCode.ResourceLimitExceeded`
  with the byte/line/column of the offending key. Defends against
  pathological flat inputs (e.g., 16 MiB of `k0=0\nk1=0\n...`).
- `max_values` -- hard cap on the total number of `*Value` nodes the
  parser allocates (scalars, arrays, tables, array elements, root
  table). Each `*Value` allocation site in `parser.zig` charges one
  unit. On overflow the parser returns `ErrorCode.ResourceLimitExceeded`
  at the offending token position. Defends against single-key
  allocation blow-ups (e.g., `arr = [0, 1, 2, ...]` with millions of
  elements).

Callers who expect larger documents (>100k keys or >500k values)
should raise these fields explicitly in their `ParseOptions` literal.
The defaults cover every file the TOML compliance corpus ships.

---

### TomlVersion

TOML specification version selector.

```zig
pub const TomlVersion = enum { v1_0_0, v1_1_0 };
```

**Variants:**

| Variant | Description |
|---------|-------------|
| v1_0_0 | Strict TOML v1.0.0 compliance |
| v1_1_0 | TOML v1.1.0 with relaxed syntax (default) |

**Version Differences:**

| Feature | v1.0.0 | v1.1.0 |
|---------|--------|--------|
| Inline table trailing comma | Not allowed | Allowed |
| Inline table newlines | Not allowed | Allowed |
| Local time without seconds | Not allowed | Allowed (assumes :00) |

---

### Document

Parsed TOML document with memory ownership.

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

**Methods:**

#### deinit

```zig
pub fn deinit(self: *Document) void
```

Free all memory associated with this document. Must be called when done with the document.

#### getPath

```zig
pub fn getPath(self: *const Document, path: []const []const u8) ?*const Value
```

Get a value by key path (array of key segments).

**Example:**

```zig
const path = &[_][]const u8{ "server", "database", "url" };
if (doc.getPath(path)) |url| {
    std.debug.print("URL: {s}\n", .{url.string});
}
```

---

### Value

A TOML value (tagged union).

```zig
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

    pub fn get(self: *const Value, key: []const u8) ?*const Value;
    pub fn getPath(self: *const Value, path: []const []const u8) ?*const Value;
};
```

**Methods:**

#### get

```zig
pub fn get(self: *const Value, key: []const u8) ?*const Value
```

Get a value from a table by key. Returns null if not found or if the value is not a table.

**Example:**

```zig
if (doc.root.get("server")) |server| {
    if (server.get("port")) |port| {
        const p: u16 = @intCast(port.integer);
    }
}
```

---

### ValueTag

Type tag for Value union.

```zig
pub const ValueTag = enum {
    table,
    array,
    string,
    integer,
    float,
    bool,
    datetime,
    datetime_local,
    date_local,
    time_local,
};
```

---

### DateTime

DateTime with timezone offset (RFC 3339).

```zig
pub const DateTime = struct {
    year: u16,
    month: u8,
    day: u8,
    hour: u8,
    minute: u8,
    second: u8,
    nanosecond: u32 = 0,
    offset_minutes: ?i16,  // null for Z (UTC)

    pub fn format(self: DateTime, writer: anytype) !void;
};
```

---

### DateTimeLocal

Local DateTime (no timezone).

```zig
pub const DateTimeLocal = struct {
    year: u16,
    month: u8,
    day: u8,
    hour: u8,
    minute: u8,
    second: u8,
    nanosecond: u32 = 0,

    pub fn format(self: DateTimeLocal, writer: anytype) !void;
};
```

---

### DateLocal

Local Date.

```zig
pub const DateLocal = struct {
    year: u16,
    month: u8,
    day: u8,

    pub fn format(self: DateLocal, writer: anytype) !void;
};
```

---

### TimeLocal

Local Time.

```zig
pub const TimeLocal = struct {
    hour: u8,
    minute: u8,
    second: u8,
    nanosecond: u32 = 0,

    pub fn format(self: TimeLocal, writer: anytype) !void;
};
```

---

### ParseError

Detailed parse error with location information.

```zig
pub const ParseError = struct {
    code: ErrorCode,
    byte_index: usize,
    line: u32,      // 1-based
    column: u32,    // 1-based (bytes, not graphemes)
    message: []const u8,
};
```

---

### ErrorCode

Error codes for TOML parsing failures.

```zig
pub const ErrorCode = enum {
    InvalidUtf8,
    UnexpectedToken,
    InvalidEscape,
    InvalidUnicodeScalar,
    DuplicateKey,
    KeyRedefinesNonTable,
    TableRedefined,
    ArrayOfTablesConflict,
    InlineTableNewlineNotAllowed,
    InlineTableTrailingCommaNotAllowed,
    LocalTimeSecondsOmittedNotAllowed,
    LimitExceeded,
    UnexpectedEof,
    InvalidNumber,
    InvalidDateTime,
    MixedArrayTypes,
    UnterminatedString,
    InvalidKey,
    InvalidControlCharacter,
    BareCarriageReturn,
};
```

**Error Descriptions:**

| Code | Description |
|------|-------------|
| InvalidUtf8 | Input contains invalid UTF-8 sequences |
| UnexpectedToken | Unexpected token in input |
| InvalidEscape | Invalid escape sequence in string |
| InvalidUnicodeScalar | Invalid Unicode code point |
| DuplicateKey | Key already defined in current table |
| KeyRedefinesNonTable | Key path references non-table value |
| TableRedefined | Table header defines already-defined table |
| ArrayOfTablesConflict | Conflict between array of tables and other definition |
| InlineTableNewlineNotAllowed | Newline in inline table (v1.0 only) |
| InlineTableTrailingCommaNotAllowed | Trailing comma in inline table (v1.0 only) |
| LocalTimeSecondsOmittedNotAllowed | Seconds omitted in time (v1.0 only) |
| LimitExceeded | max_depth or max_bytes limit exceeded |
| InvalidNumber | Invalid number format |
| InvalidDateTime | Invalid datetime format |
| UnterminatedString | String missing closing quote |
| InvalidControlCharacter | Control character in string |
| BareCarriageReturn | CR without LF |

---

### ParseResult

Result type for parseWithError.

```zig
pub const ParseResult = union(enum) {
    ok: *Document,
    err: ParseError,
};
```

## Usage Patterns

### Loading Configuration Files

```zig
const std = @import("std");
const toml = @import("toml");

pub fn loadConfig(allocator: std.mem.Allocator, path: []const u8) !Config {
    const content = try std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024);
    defer allocator.free(content);

    const doc = try toml.parse(allocator, content, .{});
    defer doc.deinit();

    return Config{
        .host = doc.getPath(&.{ "server", "host" }).?.string,
        .port = @intCast(doc.getPath(&.{ "server", "port" }).?.integer),
    };
}
```

### Iterating Over Arrays

```zig
if (doc.root.get("items")) |items| {
    for (items.array.items.items) |item| {
        const name = item.get("name").?.string;
        const value = item.get("value").?.integer;
        std.debug.print("{s}: {d}\n", .{ name, value });
    }
}
```

### Handling Optional Values

```zig
const host = if (doc.root.get("host")) |h| h.string else "localhost";
const port: u16 = if (doc.root.get("port")) |p| @intCast(p.integer) else 8080;
```

### Version-Specific Parsing

```zig
// TOML v1.0.0 strict mode
const doc_v1 = try toml.parse(allocator, input, .{ .version = .v1_0_0 });

// TOML v1.1.0 (default, allows trailing commas in inline tables)
const doc_v11 = try toml.parse(allocator, input, .{ .version = .v1_1_0 });
```

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

## Memory Management

The Document type uses an ArenaAllocator internally. All parsed data is owned by the document:

- Call `doc.deinit()` to free all memory when done
- String values point to arena-allocated copies
- No need to free individual values

**Important:** Do not store references to values after calling `deinit()`.

```zig
const doc = try toml.parse(allocator, input, .{});
const host = doc.root.get("host").?.string;  // Valid
doc.deinit();
// host is now invalid - do not use!
```

## Thread Safety

The parser is not thread-safe. Each thread should use its own parser instance. Parsed Documents are immutable after creation and can be safely shared between threads (but not modified).

## Limits

Default limits can be configured via ParseOptions:

| Limit | Default | Description |
|-------|---------|-------------|
| max_depth | 128 | Maximum nesting depth |
| max_bytes | 16 MB | Maximum input size |
| max_keys | 100_000 | Maximum total keys across all tables |
| max_values | 500_000 | Maximum `*Value` nodes the parser allocates |

Exceeding `max_depth` / `max_bytes` returns `ErrorCode.LimitExceeded`.
Exceeding `max_keys` / `max_values` returns
`ErrorCode.ResourceLimitExceeded` with position information on the
offending token.

## Parallel (Batch) API

The `toml.parallel` submodule provides a batch-oriented entrypoint for
fan-out workloads (e.g. validating many config snippets in CI, lint
passes over a directory tree). It is NOT a parallel drop-in for
`toml.parse` -- the scope and semantics are intentionally smaller.

### What it does today (honest scope)

`parallel.parseDocuments` invokes the real TOML parser for every input,
so the accept/reject decision and the emitted `Document` are
bit-identical to `toml.parse`. Batching runs on the thread pool above a
4-document threshold; below that, it falls back to sequential
execution. Each successful result carries the parsed `Document`; the
caller must `deinit` any non-null `doc`.

Each input produces a `ParseResult` with the following fields:

| Field          | Type        | Description                                                                         |
|----------------|-------------|-------------------------------------------------------------------------------------|
| `success`      | `bool`      | True iff the parser accepted the input.                                             |
| `error_code`   | `u8`        | Non-zero on failure; mapped from `toml.ErrorCode` ordinals.                         |
| `error_line`   | `?usize`    | 1-based line of the first parse error (null on success).                            |
| `error_column` | `?usize`    | 1-based column of the first parse error (null on success).                          |
| `key_count`    | `usize`     | Number of top-level keys in the root table when `success` is true.                  |
| `doc`          | `?*Document` | Parsed document (populated when `success=true`); caller must call `doc.?.deinit()`. |

`parallel.validateDocuments(inputs, results)` and
`parallel.extractKeys(allocator, inputs, results)` similarly delegate to
the real parser; see the Thresholds section below for batching rules.

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

### Thresholds

The parallel entry points fall back to sequential processing below
small-batch thresholds:

| Operation          | Threshold    | Sequential Below |
|--------------------|--------------|------------------|
| `parseDocuments`   | 4 documents  | Yes              |
| `validateDocuments`| 8 documents  | Yes              |
| `extractKeys`      | 8 documents  | Yes              |

Chunking uses ceiling division, so every input is processed exactly
once regardless of `inputs.len` relative to the internal `MAX_CHUNKS`
cap. Construct a `ParallelContext` once per batch workload (see the
Lifecycle subsection above) and `defer ctx.deinit()` to free the pool
when the workload is finished. The deprecated `parallel.deinitPool()`
shim still exists for the legacy global pool but will be removed in
0.3.0.

### Example

```zig
const toml = @import("toml");
var inputs: [16][]const u8 = undefined;
for (&inputs) |*s| s.* = "key = \"value\"";

var ctx = try toml.parallel.ParallelContext.initDefault(allocator);
defer ctx.deinit();

var results: [16]toml.parallel.ParseResult = undefined;
ctx.parseDocuments(&inputs, &results);
defer for (&results) |*r| if (r.doc) |d| d.deinit();

for (results) |r| std.debug.assert(r.success);
```

## CLI Binaries

### toml-test-decoder

Reads TOML from stdin, writes toml-test compatible tagged JSON to stdout.
Exits 0 on success, 1 on parse failure (one-line diagnostic on stderr).

### toml-test-encoder

Reads toml-test compatible tagged JSON from stdin, writes TOML to stdout.
Exits 0 on success, 1 on JSON parse failure or encode failure (one-line
diagnostic on stderr). Used together with `toml-test-decoder` in the
BurntSushi/toml-test harness. Closes GAP-0007.

---

## Mutation API

The mutation surface is designed for programmatic document construction and
in-place updates. All mutations go through an externally supplied
`Allocator` — typically `doc.allocator()`, which returns the document's
arena allocator. Using a foreign allocator will cause use-after-free on
`Document.deinit`.

### Typed accessors on `Value`

Return optionals; never panic on tag mismatch. Replaces the pattern
`switch (v) { .integer => |i| i, else => return null }`.

| Method | Returns | Null when |
|--------|---------|-----------|
| `asI64() ?i64` | `i64` | tag is not `.integer` |
| `asF64() ?f64` | `f64` | tag is not `.float` |
| `asBool() ?bool` | `bool` | tag is not `.bool` |
| `asString() ?[]const u8` | string slice (borrowed from arena) | tag is not `.string` |
| `asArray() ?*Array` | pointer into the Value's array payload | tag is not `.array` |
| `asTable() ?*Table` | pointer into the Value's table payload | tag is not `.table` |

No coercion is performed: a `.float` of `1.0` returns `null` from
`asI64()`, not `1`.

`asArray` and `asTable` take `self: *Value` (mutable) so the returned
pointer can be used to mutate the container. `asI64`/`asF64`/`asBool`/
`asString` take `self: *const Value` since they return payloads by
value and need no mutation.

### Iterators

`Value.iterator()` returns a `ValueIterator` tagged union dispatched on
the value's tag. Each iterator yields entries in insertion / index order
and supports `reset()` for multi-pass iteration.

```zig
pub const ValueIterator = union(enum) {
    table_iter: TableIter,
    array_iter: ArrayIter,
    empty: void,
};
```

`TableIter.next()` yields `?TableIterEntry { key: []const u8, value: *Value }`.
`ArrayIter.next()` yields `?*Value` pointing into the array's backing
slice. `empty` is returned for all non-container tags.

Mutations that grow the backing slice (e.g. `tableSetOwned`,
`arrayAppendOwned`) invalidate the iterator — do not mutate during
iteration.

### Mutation methods on `Value`

| Method | Effect | Notes |
|--------|--------|-------|
| `tableSetOwned(alloc, key, value) !void` | Insert or overwrite `key` in this table | Debug-asserts tag is `.table`; `key` stored as-is; `value` is borrowed (no copy) |
| `tableGetOrCreateOwned(alloc, key) !*Value` | Fetch or create a child empty table | If the key exists but is not a table, returns the existing pointer unchanged |
| `arrayAppendOwned(alloc, value) !void` | Append to this array | Debug-asserts tag is `.array`; the payload of `value.*` is copied into the array's contiguous storage |

The legacy free-function forms (`tableSet`, `tableGetOrCreate`,
`arrayAppend`) remain for internal parser use and behave identically.
Note that `arrayAppend` takes `Value` by value while `arrayAppendOwned`
takes `*Value` and internally passes `value.*` — match the public method
for new callers.

Note: `Value.get` returns `*const Value`, so mutating a value fetched
through it requires `@constCast`. Callers that built the Value
themselves already hold a `*Value` and do not need the cast.

### Dotted-path mutation on `Document`

```zig
pub fn setPath(self: *Document, path: []const u8, leaf: *Value) !void
pub fn setPathSegments(self: *Document, segments: []const []const u8, leaf: *Value) !void
```

`setPath` splits a dotted string (`"server.http.port"`) into segments.
`setPathSegments` accepts a pre-split slice for segments that themselves
contain `.` (e.g. `"v1.2.3"`).

Both create missing intermediate tables. Errors:

| Error | Condition |
|-------|-----------|
| `error.EmptyPath` | `path.len == 0` (or `segments.len == 0`) |
| `error.EmptyPathSegment` | Consecutive dots or a leading/trailing dot |
| `error.PathTooDeep` | More than 64 segments |
| `error.PathCollision` | An intermediate segment already holds a non-table value |

Overwriting an existing leaf is **not** an error — the old value
remains in the arena and is reclaimed at `deinit`.

### Example

See `examples/mutation.zig` for a full end-to-end program that builds a
Document programmatically, reads it back with typed accessors, and
iterates nested tables and arrays.

---

## Schema Validation

Since 0.2.0, zigtoml ships two validation styles in `toml.schema`.

### A. Runtime schema

Build a `SchemaNode` tree and validate a parsed `*const Value` against it:

```zig
const toml = @import("toml");

const port = toml.SchemaNode.N.integer(.{ .min = 1, .max = 65535 });
const name = toml.SchemaNode.N.string(.{ .min_len = 1 });
const fields = [_]toml.FieldSchema{
    .{ .name = "name", .schema = &name, .required = true },
    .{ .name = "port", .schema = &port, .required = true },
};
const validator = toml.SchemaValidator{
    .root = toml.SchemaNode.N.object(&fields, .strict),
};

var diags = toml.DiagnosticList.init(alloc);
defer diags.deinit();
try validator.validate(doc.root, &diags);
```

On failure `validate` returns `SchemaError.SchemaViolation` and
`diags.items.items` contains one `Diagnostic` per violation with a dotted
`path` (e.g. `server.port`, `tags[2]`), `code`, and `message`.

`SchemaNode` variants: `string`, `integer`, `float`, `boolean`, `datetime`,
`datetime_local`, `date_local`, `time_local`, `array`, `object`, `one_of`.
Constructors live on the `SchemaNode.N` sub-namespace because Zig does
not let a declaration on a union type share a name with one of its tag
fields.

### B. Comptime-typed decoding

Reflects on a user struct at compile time and allocates the result in a
caller-owned arena:

```zig
const Config = struct {
    name: []const u8,
    port: u16,
    tags: ?[][]const u8,
};

var decoded = try toml.decode(Config, alloc, doc);
defer decoded.deinit();
std.debug.print("port={d}\n", .{decoded.value.port});
```

Supported field types: integers (bounds-checked), floats, bool,
`[]const u8`, slices of any supported element type, nested structs,
optional of any supported type. Missing optional fields become `null`;
struct fields with a default value pick up that default when absent;
otherwise the decoder returns `DecodeError.MissingField`.

Errors: `DecodeError = error{ TypeMismatch, MissingField,
IntegerOverflow, UnsupportedType, OutOfMemory }`.

See `examples/schema_validation.zig` for an end-to-end program that
exercises both styles.

---

## Error recovery

Use `toml.parseRecover` when you want every syntax error in a file
rather than just the first one. Typical users: editors, IDE
integrations, linters, and CI gates that must surface all diagnostics
in a single pass.

```zig
const toml = @import("toml");

var result = try toml.parseRecover(allocator, input, .{
    .recovery_mode = .recover,
    .max_recovery_errors = 100, // default
});
defer result.deinit(allocator);

for (result.errors) |e| {
    std.debug.print("line {d}, col {d}: [{s}] {s}\n", .{
        e.line, e.column, @tagName(e.code), e.message,
    });
}

// `result.document` is a valid, possibly partial *Document that
// contains every key/table that parsed cleanly. All lookups work
// normally.
const maybe_host = result.document.getPath(&.{ "server", "host" });
```

`RecoveryResult` owns the document arena plus the error slice:

```zig
pub const RecoveryResult = struct {
    document: *Document,
    errors: []ParseError,
    pub fn deinit(self: *RecoveryResult, alloc: Allocator) void { ... }
};
```

`RecoveryMode` is a simple enum:

```zig
pub const RecoveryMode = enum { strict, recover };
```

`.strict` is the default on `ParseOptions` and matches historical
behaviour. `.recover` is enabled by calling `parseRecover` (which
forces it internally regardless of what the caller passed in
`opts.recovery_mode`).

When a syntax error fires, the recovery loop advances past it to the
next safe synchronisation point:

- **Newlines** at depth zero terminate a statement.
- **`[` / `[[`** at depth zero starts a new table header (and is a
  boundary even without an intervening newline, as a defence against
  missing `\n`).
- **Matching `}`** closes a broken inline table so subsequent lines
  are not consumed.
- **Matching `]`** closes a broken array so subsequent lines are not
  consumed.

Recovery is bounded by `opts.max_recovery_errors` (default `100`):
once that many errors have been logged, `parseRecover` stops trying
and returns what it has so far.

Non-recoverable errors short-circuit to an empty document plus a
single error:

- `InvalidUtf8` -- we cannot trust the bytes, so recovery is
  meaningless.
- `max_bytes` exceeded -- input is over the configured size cap.

See `examples/lint_toml.zig` for a CLI-style end-to-end program.

---

API Reference for zigtoml TOML Parser.
