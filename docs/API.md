# TOML Parser API Reference

**Library Version:** 0.2.0
**TOML Versions:** v1.0.0, v1.1.0
**Last Updated:** 2025-01-24

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

API Reference for zigtoml TOML Parser.
