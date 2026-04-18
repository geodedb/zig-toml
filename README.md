# toml

A fully compliant TOML v1.1.0 parser for Zig 0.15.2 with v1.0.0 compatibility mode.

## Supported TOML Versions

- **TOML v1.1.0** (default) - Full support including:
  - Inline tables with trailing commas and newlines
  - Local time with omitted seconds (assumes `:00`)
- **TOML v1.0.0** - Strict compatibility mode with v1.0 restrictions

## Status

| Aspect | Info |
|--------|------|
| API Stability | Beta |
| Zig Version | 0.15.2+ |
| Platforms | Linux, macOS, Windows |

## Features

- Full TOML v1.1.0 compliance with typed value tree output
- Version-gated parsing (v1.0.0 / v1.1.0)
- toml-test compatible tagged JSON emitter with deterministic sorted keys
- UTF-8 validation (rejects invalid UTF-8)
- All TOML types: string, integer, float, bool, datetime, date, time, array, table
- String escapes: `\b \t \n \f \r \e \" \\ \x \u \U`
- Numbers with underscores and bases (hex, octal, binary)
- Configurable limits: `max_depth`, `max_bytes`
- Detailed error diagnostics with line/column location
- Arena-based memory management

## Installation

Add to your `build.zig.zon`:

```zig
.dependencies = .{
    .toml = .{
        .url = "https://gitlab.com/devnw/zig/toml/-/archive/main/toml-main.tar.gz",
        // .hash = "...",
    },
},
```

Then in your `build.zig`:

```zig
const toml_dep = b.dependency("toml", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("toml", toml_dep.module("toml"));
```

## API Usage

### Basic Parsing

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
        \\
        \\[database]
        \\url = "postgres://localhost/db"
    ;

    const doc = try toml.parse(allocator, input, .{});
    defer doc.deinit();

    // Access values
    if (doc.root.get("server")) |server| {
        if (server.get("host")) |host| {
            std.debug.print("Host: {s}\n", .{host.string});
        }
        if (server.get("port")) |port| {
            std.debug.print("Port: {d}\n", .{port.integer});
        }
    }

    // Path-based lookup
    const path = &[_][]const u8{ "database", "url" };
    if (doc.getPath(path)) |url| {
        std.debug.print("DB URL: {s}\n", .{url.string});
    }
}
```

### Parse with Error Handling

```zig
const result = toml.parseWithError(allocator, input, .{});
switch (result) {
    .ok => |*doc| {
        defer doc.deinit();
        // Use document...
    },
    .err => |e| {
        std.debug.print("Parse error at line {d}, column {d}: {s}\n", .{
            e.line, e.column, e.message,
        });
    },
}
```

### Version Selection

```zig
// TOML v1.1.0 (default)
const doc = try toml.parse(allocator, input, .{ .version = .v1_1_0 });

// TOML v1.0.0 strict mode
const doc = try toml.parse(allocator, input, .{ .version = .v1_0_0 });
```

### Tagged JSON Output (toml-test format)

```zig
const doc = try toml.parse(allocator, input, .{});
defer doc.deinit();

const stdout = std.io.getStdOut().writer();
try toml.writeTaggedJson(doc, stdout);
```

### Limits

```zig
const doc = try toml.parse(allocator, input, .{
    .max_depth = 64,              // Maximum nesting depth (default: 128)
    .max_bytes = 1024 * 1024,     // Maximum input size (default: 16MB)
});
```

### Parallel (Batch) API

For large fan-outs -- validating many config snippets in CI, lint
passes over a directory tree, etc. -- `toml.parallel` exposes a batch
entrypoint that runs across worker threads from a shared
`thread_pool`-backed pool:

```zig
const toml = @import("toml");
var inputs: [32][]const u8 = undefined;
for (&inputs) |*s| s.* = "key = \"value\"";

var ctx = try toml.parallel.ParallelContext.initDefault(allocator);
defer ctx.deinit();

var results: [32]toml.parallel.ParseResult = undefined;
ctx.parseDocuments(&inputs, &results);
defer for (&results) |*r| if (r.doc) |d| d.deinit();
```

Every successful result carries the parsed `Document`; the caller owns
deinit. See [docs/API.md](docs/API.md) for the full contract.

## CLI Usage

### toml-test-decoder

A CLI binary for use with [toml-test](https://github.com/toml-lang/toml-test):

```bash
# Build
zig build

# Run decoder
echo 'a = 42' | ./zig-out/bin/toml-test-decoder
# Output: {"a":{"type":"integer","value":"42"}}

# Use with toml-test
toml-test ./zig-out/bin/toml-test-decoder
```

- Reads TOML from stdin
- On success: prints tagged JSON to stdout, exits 0
- On failure: prints one-line diagnostic to stderr, exits 1

## Public Types

```zig
pub const TomlVersion = enum { v1_0_0, v1_1_0 };

pub const ParseOptions = struct {
    version: TomlVersion = .v1_1_0,
    max_depth: u16 = 128,
    max_bytes: usize = 16 * 1024 * 1024,
};

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
    // ...
};

pub const ParseError = struct {
    code: ErrorCode,
    byte_index: usize,
    line: u32,      // 1-based
    column: u32,    // 1-based (bytes, not graphemes)
    message: []const u8,
};

pub const ValueTag = enum {
    table, array, string, integer, float, bool,
    datetime, datetime_local, date_local, time_local,
};

pub const Value = union(ValueTag) { /* ... */ };

pub const Document = struct {
    pub fn deinit(self: *Document) void;
    pub fn getPath(self: *const Document, path: []const []const u8) ?*const Value;
};

pub fn parse(alloc: Allocator, input: []const u8, opts: ParseOptions) !*Document;
pub fn parseWithError(alloc: Allocator, input: []const u8, opts: ParseOptions) ParseResult;
pub fn writeTaggedJson(doc: *const Document, writer: anytype) !void;
```

## Running Tests

```bash
# Verify Zig version
zig version  # must be 0.15.2

# Run all tests
zig build test

# Build CLI only
zig build
```

## File Structure

```text
/toml
  build.zig
  LICENSE
  README.md
  src/
    toml.zig           # Public API
    parser.zig         # TOML parser
    lexer.zig          # Tokenizer
    value.zig          # Value types and Document
    error.zig          # Error types
    json_tagged.zig    # Tagged JSON emitter
    bin/
      toml_test_decoder.zig  # CLI binary
  tests/
    accept.zig         # Acceptance tests
```

## Design Rationale

- **Arena allocator**: Document owns all memory via ArenaAllocator; single `deinit()` frees everything
- **Version gating**: TomlVersion enum enables strict v1.0 or permissive v1.1 parsing at parse time
- **Deterministic JSON**: Keys sorted lexicographically (byte order) at every level for reproducible output
- **Typed errors**: ErrorCode enum + ParseError struct with exact byte/line/column for diagnostics
- **No external dependencies**: Zig stdlib only; works on POSIX and Windows
- **Security first**: UTF-8 validation, bounds checks, configurable depth/size limits, no panics on malformed input
- **Zero-copy where possible**: String slices reference arena-allocated copies; path lookup without allocation

## License

Apache-2.0 License - see LICENSE file for details.
