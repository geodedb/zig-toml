# TOML Specification Compliance Matrix

**Scope:** TOML v1.0.0 and v1.1.0
**Implementation:** `zigtoml` (this repository)
**Source of truth:**

- TOML v1.0.0 spec: <https://toml.io/en/v1.0.0>
- TOML v1.1.0 spec: <https://toml.io/en/v1.1.0>
- toml-test corpus: <https://github.com/toml-lang/toml-test>

## Legend

| Symbol | Meaning |
|--------|---------|
| Yes    | Implemented and covered by at least one unit or acceptance test |
| Parser | Implemented in the parser; rejected/accepted correctly |
| Fuzz   | Implemented; exercised by the `zig build test --fuzz` harness |
| Partial| Implemented with known gaps (linked to gap ID) |
| No     | Not implemented |
| N/A    | Not applicable to this implementation |

## v1.0.0 / v1.1.0 Feature Matrix

| Section | Feature | v1.0.0 | v1.1.0 | Status | Evidence |
|---------|---------|--------|--------|--------|----------|
| Comments | `# line comment` | required | required | Yes | `src/lexer.zig`; accept.zig "comments" |
| Key/Value | Bare keys | required | required | Yes | `parser.zig::parseKey`; toml.zig "parse simple key-value" |
| Key/Value | Quoted keys (basic) | required | required | Yes | `parser.zig::parseKey` |
| Key/Value | Quoted keys (literal) | required | required | Yes | `parser.zig::parseKey` |
| Key/Value | Dotted keys | required | required | Yes | toml.zig "parse dotted keys" |
| Key/Value | Duplicate keys rejected | required | required | Yes | accept.zig "duplicate key" |
| String | Basic (`"…"`) | required | required | Yes | toml.zig "parse string with escapes" |
| String | Multiline basic (`"""…"""`) | required | required | Yes | toml.zig "multiline basic string" |
| String | Literal (`'…'`) | required | required | Yes | accept.zig |
| String | Multiline literal (`'''…'''`) | required | required | Yes | toml.zig "multiline literal string" |
| String | Escape `\b \t \n \f \r \" \\` | required | required | Yes | `parser/string.zig::decodeEscapeChar` |
| String | Escape `\e` (ESC) | No | required | Yes (v1.1) | `parser/string.zig::decodeEscapeChar` |
| String | Escape `\x` (1-byte hex) | No | required | Yes (v1.1) | `parser/string.zig::decodeEscapeChar` |
| String | Escape `\uXXXX`, `\UXXXXXXXX` | required | required | Yes | `parser/string.zig::decodeEscapeChar` |
| String | UTF-8 validation | required | required | Yes | `toml.zig::parse`, toml.zig "invalid UTF-8 rejected" |
| String | Line-ending backslash | required | required | Yes | `parser/string.zig::decodeMultilineEscapes` |
| Integer | Decimal | required | required | Yes | toml.zig "parse simple key-value" |
| Integer | Hex (`0xDEADBEEF`) | required | required | Yes | toml.zig "hex integer" |
| Integer | Octal (`0o755`) | required | required | Yes | toml.zig "octal integer" |
| Integer | Binary (`0b…`) | required | required | Yes | toml.zig "binary integer" |
| Integer | Underscore separators | required | required | Yes | `parser/number.zig::parseInteger` |
| Float | Standard | required | required | Yes | toml.zig "parse float" |
| Float | `inf`, `-inf`, `nan` | required | required | Yes | toml.zig "special floats" |
| Float | Underscore separators | required | required | Yes | `parser/number.zig::parseFloat` |
| Boolean | `true` / `false` | required | required | Yes | toml.zig "parse bool" |
| DateTime | Offset (`Z`, `+HH:MM`) | required | required | Yes | toml.zig "parse date-time" |
| DateTime | Local (`YYYY-MM-DDTHH:MM:SS`) | required | required | Yes | `parser/datetime.zig::parseDateTimeLocal` |
| DateTime | Fractional seconds | required | required | Yes | toml.zig "U-R malformed fractional seconds rejected" (negative test) |
| DateTime | Malformed tz offset rejected | required | required | Yes (S-7 closed) | toml.zig "U-R malformed timezone hours rejected" |
| Date (local) | `YYYY-MM-DD` | required | required | Yes | `parser/datetime.zig::parseDateLocal` |
| Time (local) | `HH:MM:SS` | required | required | Yes | toml.zig "parse local time" |
| Time (local) | Seconds omitted (`HH:MM`) | No (rejected) | required | Yes | `parser/datetime.zig::parseTimeLocal` version-gated |
| Array | Homogeneous/heterogeneous | required | required | Yes | toml.zig "parse array" |
| Array | Trailing comma | required | required | Yes | `parser/array.zig::parseArray` |
| Array | Nested depth guard | required | required | Yes (S-6 closed) | toml.zig "U-H deep nesting rejected by defense-in-depth guards" |
| Table | `[header]` | required | required | Yes | toml.zig "parse table" |
| Table | Inline `{…}` | required | required | Yes | toml.zig "parse inline table" |
| Table | Inline newlines allowed | rejected | required | Yes | version-gated in `parseInlineTable` |
| Table | Inline trailing comma allowed | rejected | required | Yes | version-gated in `parseInlineTable` |
| Table | Redefinition rejected | required | required | Yes | `parser/table_path.zig::resolveTablePath` |
| Array of tables | `[[array]]` | required | required | Yes | toml.zig "parse array of tables" |
| Limits | `max_depth` | optional | optional | Yes | `ParseOptions.max_depth`, toml.zig "U-H" tests |
| Limits | `max_bytes` | optional | optional | Yes | `ParseOptions.max_bytes`, `parser.zig::parse` |
| Output | Tagged JSON (toml-test) | N/A | N/A | Yes | `json_tagged.zig`; accept.zig "tagged JSON minimal"; "tagged JSON sorts 300 keys deterministically" (U-U) |
| Output | Sorted keys at every level | N/A | N/A | Yes (P-9 closed) | same as above |

## Batch / Parallel API (non-spec)

These are zigtoml extensions, not part of the TOML spec:

| Feature | Status | Evidence / Notes |
|---------|--------|------------------|
| `parallel.parseDocuments` shape-check | Partial | Lightweight byte-level checker; full-parser promotion tracked as U-A. See [ARCHITECTURE.md](ARCHITECTURE.md#parallel-subsystem). |
| `parallel.validateDocuments` | Partial | UTF-8 + bracket + control-byte validation; does not enforce full grammar. |
| `parallel.extractKeys` | Yes | Top-level key extraction with deterministic chunking. |
| MAX_CHUNKS ceiling division | Yes (U-F closed) | `src/parallel.zig`; parallel.zig "U-F no dropped inputs past MAX_CHUNKS" tests. |

## Known Deviations / Gaps

Tracked in the companion `*GAP_ANALYSIS.md` documents:

- **U-A** -- Parallel shape-checker does not invoke the real parser.
  Accepts some inputs `toml.parse` rejects. Negative tests landed under
  Q-14; behavior promotion deferred to a dedicated branch.
- Comment preservation, original formatting retention, and key-order
  preservation across mutations are out of scope (see
  [ARCHITECTURE.md](ARCHITECTURE.md#known-limitations)).

## How to Update This Matrix

1. When closing a gap that adds or changes TOML behavior, update the
   relevant row's `Status` and `Evidence` cells in the same commit.
2. New test blocks should be referenced by test name plus the source
   file (e.g. `accept.zig "tagged JSON minimal"`).
3. Rows for features added in future TOML revisions should append a new
   column rather than overwriting v1.0.0 / v1.1.0 cells.

---

TOML Specification Compliance for zigtoml.
