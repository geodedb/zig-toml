# TOML Parser Architecture

**Status:** Implemented
**Date:** 2025-01-24
**Version:** 1.0

## Overview

The zigtoml library is a fully compliant TOML v1.0.0/v1.1.0 parser implemented in Zig. This document describes the internal architecture, design decisions, and component interactions.

## Architecture Diagram

```text
                                    ┌─────────────────┐
                                    │   User Code     │
                                    └────────┬────────┘
                                             │
                                             ▼
┌────────────────────────────────────────────────────────────────┐
│                         toml.zig (Public API)                   │
│  ┌──────────────────┐  ┌────────────────┐  ┌────────────────┐  │
│  │ parse()          │  │ parseWithError │  │ writeTaggedJson│  │
│  └────────┬─────────┘  └───────┬────────┘  └───────┬────────┘  │
└───────────┼────────────────────┼───────────────────┼───────────┘
            │                    │                   │
            ▼                    ▼                   ▼
    ┌───────────────────────────────────┐    ┌──────────────────┐
    │           parser.zig              │    │ json_tagged.zig  │
    │  ┌─────────────────────────────┐  │    │                  │
    │  │ Parser                      │  │    │ Tagged JSON      │
    │  │  - parseDocument() (real)   │  │    │ emitter for      │
    │  │  - parseTableHeader()       │  │    │ toml-test        │
    │  │  - parseKeyValue()          │  │    │                  │
    │  │  - parseValue()             │  │    └──────────────────┘
    │  │  - parseArray()             │  │
    │  │  - parseInlineTable()       │  │
    │  └──────────────┬──────────────┘  │
    └─────────────────┼─────────────────┘
                      │
                      ▼
              ┌───────────────┐
              │  lexer.zig    │
              │  ┌─────────┐  │
              │  │ Lexer   │  │
              │  │ - next()│  │
              │  │ - peek()│  │
              │  └─────────┘  │
              └───────┬───────┘
                      │
        ┌─────────────┼─────────────┐
        ▼             ▼             ▼
┌─────────────┐ ┌───────────┐ ┌───────────┐
│ value.zig   │ │ error.zig │ │  Input    │
│             │ │           │ │  (UTF-8)  │
│ Value types │ │ ErrorCode │ └───────────┘
│ Document    │ │ ParseError│
└─────────────┘ └───────────┘
```

## Component Overview

### 1. Public API (toml.zig)

The public interface layer that users interact with.

**Responsibilities:**

- Expose parse functions with clean error handling
- Re-export public types (Value, Document, ParseOptions, etc.)
- Provide the tagged JSON output function
- Hide internal implementation details

**Key Design Decisions:**

- Single entry point for parsing operations
- Two parse variants: one returning errors, one returning results
- All internal modules accessible only through re-exports

### 2. Lexer (lexer.zig)

Tokenizes raw TOML input into a stream of tokens.

**Responsibilities:**

- Convert byte stream into typed tokens
- Handle whitespace and comments
- Recognize all TOML token types (strings, numbers, brackets, etc.)
- Track source positions (line, column, byte offset)
- Validate character-level constraints (UTF-8, control characters)

**Token Types:**

| Category | Tokens |
|----------|--------|
| Structural | `[`, `]`, `[[`, `]]`, `{`, `}`, `=`, `,`, `.` |
| Values | bare_key, basic_string, literal_string, ml_basic_string, ml_literal_string |
| Numbers | integer, float |
| Booleans | bool_true, bool_false |
| Datetime | datetime, datetime_local, date_local, time_local |
| Special | newline, comment, eof |

**Stateless Design:**
The lexer is stateless between tokens. It does not maintain context about table headers or value positions - this is handled by the parser.

### 3. Parser (parser.zig + parser/)

Builds the value tree from the token stream. The parser is split into
a top-level dispatch file (`src/parser.zig`) and three leaf submodules
under `src/parser/` — `datetime.zig`, `number.zig`, and `string.zig` —
each handling a single value family. The dispatch file holds the
recursive-descent loop (`parseDocument` / `parseValue` / `parseArray`
/ `parseInlineTable` / `parseKeyValue`) and all table-path resolution;
the submodules are purely functional decoders that take a `*Parser`
plus the raw token slice and return the decoded value or an error.

**Responsibilities (parser.zig):**

- Parse document structure (tables, arrays of tables, key-value pairs)
- Build the Document and Value tree
- Handle dotted keys and table paths
- Enforce TOML semantic rules (no duplicate keys, table redefinition, etc.)
- Version-gated features (v1.0 vs v1.1 differences)
- Orchestrate the inline-table pipeline
  (`parseInlineTableHeader` → `parseInlineTableBody` →
  `validateInlineTableV10Restrictions`)

**Responsibilities (parser/ submodules):**

- `parser/datetime.zig` — RFC 3339 offset/local date/time parsing
  with shared `parseDateParts` / `parseTimeParts` / `parseOffset`
  helpers and leap-year / calendar / range validators
- `parser/number.zig` — integer + float parsing and format validation
  via a flat state machine (`classifyFloatByte` + `stepFloat`)
- `parser/string.zig` — basic / literal / multi-line string decoders
  and escape-sequence handling

**Parsing Strategy:**

The parser uses a recursive descent approach:

```text
Document := (KeyValue | TableHeader | ArrayTableHeader | Comment | Newline)*

TableHeader := '[' KeyPath ']'
ArrayTableHeader := '[[' KeyPath ']]'
KeyValue := KeyPath '=' Value

KeyPath := Key ('.' Key)*
Key := BareKey | BasicString | LiteralString

Value := String | Integer | Float | Bool | DateTime | Array | InlineTable
Array := '[' (Value (',' Value)*)? ']'
InlineTable := '{' (KeyValue (',' KeyValue)*)? '}'
```

**Table Resolution:**

When encountering table headers, the parser:

1. Parses the key path
2. Navigates/creates intermediate tables
3. Validates against existing definitions
4. Sets the current table context

### 4. Value Types (value.zig)

Defines the data structures for parsed TOML values.

**Core Types:**

```zig
Value (tagged union)
├── table: Table { map: StringArrayHashMapUnmanaged(*Value), flags... }
├── array: Array { items: []*Value }
├── string: []const u8
├── integer: i64
├── float: f64
├── bool: bool
├── datetime: DateTime
├── datetime_local: DateTimeLocal
├── date_local: DateLocal
└── time_local: TimeLocal
```

**Table Flags:**

| Flag | Purpose |
|------|---------|
| is_inline | Was defined with `{ }` syntax |
| is_array_of_tables | Part of `[[name]]` array |
| defined_explicitly | Has a `[name]` header |
| defined_by_dotted_key | Created via `a.b.c = val` |
| is_closed_inline | Inline table that cannot be extended |

### 5. Error Handling (error.zig)

Provides structured error types with source location.

**Components:**

- `ErrorCode`: Enumeration of all error types
- `ParseError`: Struct with code, position, and message
- `Position`: Tracks byte_index, line, column

**Error Categories:**

| Category | Examples |
|----------|----------|
| Lexical | InvalidUtf8, UnterminatedString, InvalidControlCharacter |
| Syntactic | UnexpectedToken, UnexpectedEof |
| Semantic | DuplicateKey, TableRedefined, KeyRedefinesNonTable |
| Version | InlineTableNewlineNotAllowed, LocalTimeSecondsOmittedNotAllowed |
| Limits | LimitExceeded (depth, bytes) |

### 6. JSON Output (json_tagged.zig)

Serializes parsed documents to toml-test format.

**Tagged JSON Format:**

```json
{
  "key": {"type": "string", "value": "text"},
  "num": {"type": "integer", "value": "42"}
}
```

**Key Features:**

- Deterministic output (keys sorted lexicographically)
- Proper JSON string escaping
- Float formatting with decimal points
- Support for all datetime types

## Memory Management

### Arena Allocator Strategy

The Document owns an ArenaAllocator that manages all parsed data:

```text
Document
└── ArenaAllocator
    ├── Root Value (Table)
    ├── All nested Values
    ├── String contents (copied from input)
    └── Table entries and array items
```

**Benefits:**

- Single `deinit()` frees everything
- No reference counting needed
- Fast allocation (bump allocator)
- No memory fragmentation

**Trade-offs:**

- Cannot free individual values
- Memory held until document is freed
- Large documents hold memory longer

### String Handling

Strings are processed as follows:

1. **Basic/Literal strings**: Escape sequences decoded, result allocated in arena
2. **Multiline strings**: Leading newline trimmed, escapes processed
3. **Keys**: Stored as arena-allocated copies
4. **Zero-copy where possible**: Path lookups don't allocate

## Data Flow

### Parse Flow

```text
Input String
    │
    ▼
┌──────────┐     ┌────────────┐     ┌──────────────┐
│  UTF-8   │────▶│   Lexer    │────▶│    Parser    │
│ Validate │     │ Tokenize   │     │  Build Tree  │
└──────────┘     └────────────┘     └──────────────┘
                                           │
                                           ▼
                                    ┌──────────────┐
                                    │   Document   │
                                    │  + Values    │
                                    └──────────────┘
```

### Lookup Flow

```text
doc.getPath(["server", "db", "host"])
    │
    ▼
┌─────────────────────────────────────────────────┐
│  root.table.map (StringArrayHashMapUnmanaged,   │
│                  insertion-ordered)             │
│    ├── "server" ─────────────────┐              │
│    │       │                     │              │
│    │       ▼                     │              │
│    │   table.map                 │              │
│    │     └── "db" ───────────────┤              │
│    │           │                 │              │
│    │           ▼                 │              │
│    │       table.map             │              │
│    │         └── "host" ─────────┴──▶ Value     │
└─────────────────────────────────────────────────┘
```

`Value.Table` uses `std.StringArrayHashMapUnmanaged(*Value)` as its
backing store. Iteration via `tableIterator` yields entries in insertion
order; lookups via `get` / `getPath` are O(1) amortized. This closes the
P-1 / P-2 / P-12 quadratic-insert/lookup defects.

## Version Differences

### v1.0.0 vs v1.1.0

| Feature | v1.0.0 | v1.1.0 |
|---------|--------|--------|
| Inline table trailing comma | Error | Allowed |
| Inline table newlines | Error | Allowed |
| Time without seconds | Error | Assumes `:00` |

Implementation uses the `TomlVersion` enum to gate these features at parse time.

## Security Considerations

### Input Validation

1. **UTF-8 Validation**: Full validation before parsing
2. **Size Limits**: Configurable `max_bytes` (default 16MB)
3. **Depth Limits**: Configurable `max_depth` (default 128)
4. **No Panics**: All errors returned, no undefined behavior
5. **Control Characters**: Validated per string type

### Resource Limits

```zig
pub const ParseOptions = struct {
    max_depth: u16 = 128,      // Prevents stack overflow
    max_bytes: usize = 16MB,   // Prevents memory exhaustion
};
```

## Performance Characteristics

### Time Complexity

| Operation | Complexity |
|-----------|------------|
| Lexing | O(n) where n = input bytes |
| Parsing | O(n) for simple documents |
| Table lookup (get) | O(k) where k = keys in table |
| Path lookup (getPath) | O(p * k) where p = path length |

### Space Complexity

| Metric | Value |
|--------|-------|
| Parser state | O(1) |
| Document size | O(n) proportional to input |
| String storage | Deduplicated where possible |

## Extension Points

### Adding New Value Types

To add a new TOML value type:

1. Add variant to `ValueTag` enum
2. Add field to `Value` union
3. Extend lexer token recognition
4. Add parser value handling
5. Update JSON tagged output
6. Add tests

### Custom Output Formats

The library architecture allows adding new output formats:

1. Create new output module (e.g., `yaml_output.zig`)
2. Implement value visitor pattern
3. Export from `toml.zig`

## Testing Strategy

### Test Categories

| Category | Location | Purpose |
|----------|----------|---------|
| Unit tests | Each source file | Test individual functions |
| Integration | tests/accept.zig | Full document parsing |
| Compliance | toml-test decoder | TOML spec validation |

### Running Tests

```bash
# Unit tests
zig build test

# toml-test compliance
toml-test ./zig-out/bin/toml-test-decoder
```

## File Structure

```text
src/
├── toml.zig           # Public API and re-exports
├── parser.zig         # Dispatch: parseDocument, parseValue, parseArray,
│                      # parseInlineTable (header/body/validation),
│                      # key-value, table-path resolution
├── parser/
│   ├── datetime.zig   # RFC 3339 offset/local date/time parsers with
│   │                  # shared parseDateParts / parseTimeParts /
│   │                  # parseOffset helpers and leap-year / calendar /
│   │                  # range validators
│   ├── number.zig     # Integer + float parsers; flat state-machine
│   │                  # validator for float format (classifyFloatByte +
│   │                  # stepFloat)
│   └── string.zig     # Basic / literal / multi-line string decoders
│                      # plus escape-sequence handling
├── lexer.zig          # Tokenizer
├── value.zig          # Value types and Document
├── error.zig          # Error types
├── json_tagged.zig    # Tagged JSON emitter
├── parallel.zig       # ParallelContext: fan-out parse/validate/extract
└── bin/
    └── toml_test_decoder.zig  # CLI for toml-test
```

The `parser/` submodules are pure delegates: `src/parser.zig`
re-exposes them via thin wrappers that pin the `ParseValueError` shape,
so the public parser surface is unchanged by the split.

## Future Considerations

### Potential Enhancements

1. **Streaming Parser**: For very large files
2. **Document Modification**: Add/remove/update values
3. **TOML Writer**: Serialize back to TOML format
4. **Comptime Parsing**: Parse TOML at compile time
5. **Schema Validation**: Validate against user-defined schemas

### Known Limitations

1. No comment preservation (comments are discarded)
2. Original formatting is lost after parsing
3. Cannot determine if table was inline vs standard after parsing
4. No support for preserving key order across operations
5. `toml.parallel.parseDocuments` parses with the real recursive-descent
   parser and emits a `Document` per input (see Parallel Subsystem
   below).

## Parallel Subsystem

The `toml.parallel` submodule wraps a `thread_pool` dependency to
fan out batch operations (parse/validate/extract-keys) across worker
threads via `submitBatch` + `WaitGroup`. Each worker thread invokes the
real `toml.parseWithError` parser, so the accept/reject decision is
bit-identical to the serial `toml.parse` path.

### Components

- `ParallelContext` -- caller-owned struct holding the `*ThreadPool`
  and its allocator. Construct with `ParallelContext.initDefault`
  (returns `!*ParallelContext`) and `defer ctx.deinit()`. All batch
  methods (`parseDocuments` / `validateDocuments` / `extractKeys`) are
  reentrant on a shared `*ParallelContext`; only `deinit` must be
  serialized against in-flight method calls.
- `getPool()` / `deinitPool()` -- deprecated shims around a process-
  global legacy context, `std.once`-guarded so `getPool` takes no lock
  after first init. `getPool` now returns `!*ThreadPool` rather than
  panicking on init failure. Scheduled for removal in 0.3.0.
- `parseDocuments` / `validateDocuments` / `extractKeys` -- split
  `inputs` into at most `MAX_CHUNKS` (64) chunks using ceiling
  division so every input lands in exactly one chunk, regardless of
  `inputs.len`.
- Internal per-input routines (`parseDocument`, `validateDocument`,
  `extractKeysFromDocument`) are thin wrappers around
  `toml.parseWithError`.

### Semantics vs `toml.parse`

`toml.parallel.parseDocuments` is a parallel wrapper around the real
`toml.parse` parser. Each worker thread runs the full recursive-descent
parser against its assigned inputs, so the accept/reject decision is
bit-identical to the serial path. Results carry the parsed `Document`
so consumers can immediately read values without re-parsing.

The batch entry points (`parseDocuments`, `validateDocuments`,
`extractKeys`) fall back to sequential execution when input size is
below their thresholds (4, 8, 8 documents respectively), avoiding
thread-pool overhead on small batches.

### Threshold Behavior

Each entry point falls back to a sequential loop below a minimum batch
size (4 for parse, 8 for validate/extract) to amortize thread-pool
submission overhead. Above the threshold, inputs are split via ceiling
division so the tail of a batch is never dropped.

---

Architecture Documentation for zigtoml TOML Parser.
