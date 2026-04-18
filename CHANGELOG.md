# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.2.0] - 2026-04-18

### Changed (BREAKING)

- `parallel.ParseResult` gained a `doc: ?*Document` field. Callers MUST
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
- `Value.Table.entries: []TableEntry` replaced with
  `Value.Table.map: std.StringArrayHashMapUnmanaged(*Value)`. Inserts,
  lookups, and dup-checks are now O(1) amortized. Iteration order is
  preserved. Closes P-1, P-2, P-12.
- `toml.parse` and `toml.parseWithError` return `*Document` /
  `ParseResult { ok: *Document, err: ParseError }` instead of
  `Document` by value. Migration: change
  `var doc = try toml.parse(...)` to `const doc = try toml.parse(...)`;
  `defer doc.deinit();` is unchanged (it is now a method on
  `*Document`). Closes Q-12.
- `toml.parallel` is now caller-owned via a new `ParallelContext`.
  `parseDocuments` / `validateDocuments` / `extractKeys` gain a `ctx`
  first argument when invoked as methods:
  `ctx.parseDocuments(&inputs, &results)`. The legacy free-function
  forms remain as deprecated shims for 0.2.x and will be removed in
  0.3.0.
- `parallel.getPool` now returns `!*ThreadPool` and never `@panic`s.

### Security

- Close Q-4 / S-4 (CWE-416): the process-global `*ThreadPool` pointer
  could be freed by `deinitPool` while another thread held it. The new
  `ParallelContext` makes the pool a caller-owned resource with a
  well-defined lifetime scope.
- Close S-5 (CWE-248 / CWE-400): thread-pool init failure no longer
  `@panic`s. `ParallelContext.initDefault` returns the underlying error.
- Close S-9 (CWE-400 / CWE-789): `ParseOptions` now has `max_keys`
  (default 100 000) and `max_values` (default 500 000). Parser returns
  `ErrorCode.ResourceLimitExceeded` on overflow. Pathological inputs
  such as 16 MiB of `k0=0\nk1=0\n...` or a single huge array literal
  are now rejected in bounded memory.

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
defer for (&results) |*r| if (r.doc) |d| d.deinit();
for (results) |r| {
    if (r.success) {
        // r.doc.? is the parsed *Document — read values directly.
    } else {
        // r.error_code, r.error_line, r.error_column describe the failure.
    }
}
```

Also, for the serial API:

```zig
// Before:
var doc = try toml.parse(alloc, input, .{});
defer doc.deinit();

// After:
const doc = try toml.parse(alloc, input, .{});
defer doc.deinit();
```

### Added

- Real coverage-guided fuzz harness (`tests/fuzz_parse.zig`) wired into
  `zig build test --fuzz`. The GitLab CI `fuzz` stage now exercises a
  real target instead of a no-op.
- Defense-in-depth recursion guards (`enterDepth` / `exitDepth`) applied
  to every recursive-descent entrypoint in the parser.
- `tableIterator`, `tableLen`, `arrayLen`, `arrayItems` helpers in
  `src/value.zig` / re-exported via `toml.value_mod`. Replace direct
  access to the old `table.entries: []TableEntry` field.
- Performance benchmark harness (`zig build bench`) with hard ceilings
  for 10k top-level keys (<200ms ReleaseFast) and 1000-entry inline
  tables (<50ms ReleaseFast).

### Fixed

- Bare-key and literal-string storage are now fully arena-owned
  (`Parser.parse` copies input into its arena before tokenizing).
  Callers may free the input buffer as soon as `toml.parse` returns.
  Closes P-5.
- `Document` now holds `*ArenaAllocator` (pointer-owned). `toml.parse`
  returns `*Document`. This eliminates a latent move-by-value bug
  where the embedded `*anyopaque` in the arena's Allocator handle
  captured an old address. Closes Q-12.
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
- Close P-7: the legacy global-pool hot path is now `std.once`-guarded
  instead of mutex-per-call. No lock on `getPool` after first init.

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
