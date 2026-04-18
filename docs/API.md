# TOML Parser API Reference

**Library Version:** 0.1.0
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

    var doc = try toml.parse(allocator, input, .{});
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
pub fn parse(alloc: Allocator, input: []const u8, opts: ParseOptions) !Document
```

**Description:** Parse TOML input into a Document.

**Parameters:**

| Parameter | Type | Description |
|-----------|------|-------------|
| alloc | Allocator | Memory allocator for the parsed document |
| input | []const u8 | TOML source text (must be valid UTF-8) |
| opts | ParseOptions | Configuration options for parsing |

**Returns:** `Document` - The parsed document containing the root table

**Errors:**

| Error | Description |
|-------|-------------|
| error.ParseFailed | Parse error occurred (use parseWithError for details) |
| error.OutOfMemory | Memory allocation failed |

**Example:**

```zig
var doc = try toml.parse(allocator, "key = \"value\"", .{});
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

**Returns:** `ParseResult` - Union of `ok: Document` or `err: ParseError`

**Example:**

```zig
const result = toml.parseWithError(allocator, input, .{});
switch (result) {
    .ok => |*doc| {
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
var doc = try toml.parse(allocator, "a = 42", .{});
defer doc.deinit();

const stdout = std.io.getStdOut().writer();
try toml.writeTaggedJson(&doc, stdout);
// Output: {"a":{"type":"integer","value":"42"}}
```

## Types

### ParseOptions

Configuration options for the parser.

```zig
pub const ParseOptions = struct {
    version: TomlVersion = .v1_1_0,
    max_depth: u16 = 128,
    max_bytes: usize = 16 * 1024 * 1024,
};
```

**Fields:**

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| version | TomlVersion | .v1_1_0 | TOML version for parsing |
| max_depth | u16 | 128 | Maximum nesting depth for arrays/tables |
| max_bytes | usize | 16 MB | Maximum input size in bytes |

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
    arena: std.heap.ArenaAllocator,

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
    ok: Document,
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

    var doc = try toml.parse(allocator, content, .{});
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
    for (items.array.items) |item| {
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
var doc_v1 = try toml.parse(allocator, input, .{ .version = .v1_0_0 });

// TOML v1.1.0 (default, allows trailing commas in inline tables)
var doc_v11 = try toml.parse(allocator, input, .{ .version = .v1_1_0 });
```

## Memory Management

The Document type uses an ArenaAllocator internally. All parsed data is owned by the document:

- Call `doc.deinit()` to free all memory when done
- String values point to arena-allocated copies
- No need to free individual values

**Important:** Do not store references to values after calling `deinit()`.

```zig
var doc = try toml.parse(allocator, input, .{});
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

Exceeding limits returns `ErrorCode.LimitExceeded`.

## Parallel (Batch) API

The `toml.parallel` submodule provides a batch-oriented entrypoint for
fan-out workloads (e.g. validating many config snippets in CI, lint
passes over a directory tree). It is NOT a parallel drop-in for
`toml.parse` -- the scope and semantics are intentionally smaller.

### What it does today (honest scope)

`parallel.parseDocuments(allocator, inputs, results)` runs a lightweight
byte-level shape checker across `inputs` in parallel chunks using the
`thread_pool` dependency. Each input produces a `ParseResult` with:

- `success: bool` -- true iff the shape-checker saw no obvious error.
- `error_code: u8` -- non-zero on shape errors (e.g. unterminated string).
- `error_line`, `error_column` -- 1-based diagnostic position on error.
- `key_count: usize` -- approximate top-level key count.

`parallel.validateDocuments(inputs, results)` runs a UTF-8 + bracket +
control-byte validator (also in parallel).

`parallel.extractKeys(allocator, inputs, results)` returns top-level key
names as a comma-separated string per input.

### What it does NOT do

**`parseDocuments` is a fast shape-check, not a full parser.** It does
*not* produce a `Document`, does *not* decode values, does *not* enforce
the full TOML v1.0/v1.1 grammar (e.g. duplicate-key detection,
array-of-tables semantics, or inline-table closure rules), and will
accept inputs that `toml.parse` rejects. Use it for rejecting
obviously-broken inputs at scale or pre-filtering; use `toml.parse` for
any workload that needs a typed value tree.

A future release (tracked as `U-A` in the gap analysis) will replace
the shape-checker with the real parser under the same API. Until then,
the signature is stable but the semantics are narrower than the name
suggests.

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
cap. Remember to call `parallel.deinitPool()` during shutdown to free
the shared thread pool.

### Example

```zig
const toml = @import("toml");
var inputs: [16][]const u8 = undefined;
for (&inputs) |*s| s.* = "key = \"value\"";

var results: [16]toml.parallel.ParseResult = undefined;
toml.parallel.parseDocuments(allocator, &inputs, &results);
defer toml.parallel.deinitPool();

for (results) |r| std.debug.assert(r.success);
```

---

API Reference for zigtoml TOML Parser.
