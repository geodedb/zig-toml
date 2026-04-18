# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.2.0] - 2026-04-18

### Changed (BREAKING)

- `parallel.ParseResult` gained a `doc: ?Document` field. Callers MUST
  drain any non-null `doc` with `result.doc.?.deinit()` (or iterate and
  deinit each result in a loop) to free the per-document arena. All
  existing fields default-init, so struct initializer code that omits
  `doc` continues to compile.
- `parallel.parseDocuments`, `parallel.validateDocuments`, and
  `parallel.extractKeys` now delegate to the real `toml.parse` parser.
  Previously they were implemented as a byte-level "shape-checker" that
  silently accepted grammar-invalid inputs like `a = = 1`, unclosed
  table headers, duplicate keys, and mishandled inline tables / quoted
  keys / dotted keys. The new behavior is that the parallel path
  produces the same accept/reject decision as the serial path for every
  input.
- `toml-test-decoder` CLI uses `std.heap.smp_allocator` in release
  builds; `DebugAllocator` is gated on `builtin.mode == .Debug` only.

### Migration from 0.1.0

Before:

```zig
var results: [N]toml.parallel.ParseResult = undefined;
toml.parallel.parseDocuments(alloc, &inputs, &results);
for (results) |r| { _ = r.success; }
```

After:

```zig
var results: [N]toml.parallel.ParseResult = undefined;
toml.parallel.parseDocuments(alloc, &inputs, &results);
defer for (&results) |*r| if (r.doc) |*d| d.deinit();
for (results) |r| {
    if (r.success) {
        // r.doc.? is the parsed Document — read values directly.
    } else {
        // r.error_code, r.error_line, r.error_column describe the failure.
    }
}
```

### Added

- Real coverage-guided fuzz harness (`tests/fuzz_parse.zig`) wired into
  `zig build test --fuzz`. The GitLab CI `fuzz` stage now exercises a
  real target instead of a no-op.
- Defense-in-depth recursion guards (`enterDepth` / `exitDepth`) applied
  to every recursive-descent entrypoint in the parser.

### Fixed

- GAP-0001 / Q-1: `parallel.parseDocuments` no longer diverges from
  `toml.parse` on accept/reject decisions.
- Q-2: `parallel.validateDocuments` now validates against the full TOML
  grammar, not just UTF-8 / bare CR / null bytes / bracket balance.
- P-6: eliminated the toy state machine at `parallel.zig:169-239`.
- S-1 (CWE-345/436): false-oracle parser removed; parallel path uses
  the real recursive-descent parser. (See confidential issue #41.)
- S-2 (CWE-697): `in_string` escape handling bug at the old
  `parallel.zig:189` no longer exists — the byte-level scanner was
  deleted.
- S-3 (CWE-436): `validateDocument` is no longer a false oracle. (See
  confidential issue #43.)
- `parallel.parseDocuments`/`validateDocuments`/`extractKeys`: ceiling-
  divide `chunk_size` so the tail of large batches (inputs > MAX_CHUNKS)
  is no longer silently dropped. Every `results[i]` slot is now written.
- `docs/API.md`: corrected Library Version header from `1.0` to `0.1.0`
  to match `build.zig.zon` and this changelog.
- Datetime parsing no longer silently substitutes `0` on malformed
  fractional seconds or timezone offsets (e.g. `+AB:CD`); returns
  `ErrorCode.InvalidDateTime`.
- `DateTime.format` no longer panics on `offset_minutes = i16.minInt`.
- `writeTaggedJson` always sorts keys, even for tables with >256 entries
  (previously fell through to insertion order for large tables).

### Removed

- Shadow `parseDocument` char-scanner (`parallel.zig:169-243`,
  75 lines).
- Shadow `validateDocument` byte-checker (`parallel.zig:319-357`,
  38 lines).
- Shadow `extractKeysFromDocument` line-splitter
  (`parallel.zig:438-484`, 47 lines).

### Performance

- Added `initCapacity` hints to nine parser-local ArrayLists (paths=8,
  items=16, escape decoders=raw.len) eliminating the reallocation
  ladder on the hot parse paths.

## [0.1.0] - 2026-01-24

### Added

- Full TOML v1.1.0 compliance with typed value tree output
- TOML v1.0.0 strict compatibility mode
- Version-gated parsing supporting both v1.0.0 and v1.1.0
- Inline tables with trailing commas and newlines (v1.1.0)
- Local time with omitted seconds support (v1.1.0)
- toml-test compatible tagged JSON emitter with deterministic sorted keys
- UTF-8 validation (rejects invalid UTF-8)
- All TOML types: string, integer, float, bool, datetime, date, time, array, table
- String escape sequences: `\b \t \n \f \r \e \" \\ \x \u \U`
- Numbers with underscores and bases (hex, octal, binary)
- Configurable limits: `max_depth`, `max_bytes`
- Detailed error diagnostics with line/column location
- Arena-based memory management for efficient cleanup
- Control character restrictions per TOML spec
- `toml-test-decoder` CLI binary for toml-test integration
- Path-based value lookup via `Document.getPath()`
- `parse()` and `parseWithError()` API functions
- `writeTaggedJson()` for tagged JSON output
- Apache-2.0 open source license
- GitLab CI/CD pipeline with:
  - Security scanning (SAST, Secret Detection, Dependency Scanning)
  - SBOM generation
  - Coverage support
  - devnw/ci-catalog components integration
- Issue templates for bug reports, features, and questions
- Merge request template

### Changed

- Renamed library from `zig-toml` to `toml` (removed 'zig' prefix)

### Security

- UTF-8 validation on all input
- Bounds checking throughout parser
- Configurable depth and size limits to prevent resource exhaustion
- No panics on malformed input

[Unreleased]: https://gitlab.com/devnw/zig/toml/-/compare/v0.2.0...HEAD
[0.2.0]: https://gitlab.com/devnw/zig/toml/-/compare/v0.1.0...v0.2.0
[0.1.0]: https://gitlab.com/devnw/zig/toml/-/releases/v0.1.0
