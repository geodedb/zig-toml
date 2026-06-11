# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.6] - 2026-06-11

### Added

- Microbenchmark suite (`zig build bench`, `zig build bench-all`,
  `-Dbench-filter=<name>`). Seven benchmarks covering small/large/wide/
  deeply-nested/escape-heavy/datetime-heavy parsing plus
  `parallel.parseDocuments` across N in {4, 16, 64, 256}. Shared harness
  in `bench/common.zig` (atomic `CountingAllocator`,
  `clock_gettime(.MONOTONIC)`-backed `monotonicNs`, `runBench` helper)
  plus deterministic input generators in `bench/inputs.zig` (fixed
  seeds `0xDEADBEEF`, `0xCAFEBABE`, `0xFEEDFACE`). CI gains an
  `allow_failure: true` `bench` stage publishing `bench.csv` and
  `bench.stderr` as 4-week artifacts. See
  [`docs/PERFORMANCE.md`](docs/PERFORMANCE.md) for baselines and the
  regression-threshold policy. Closes GAP-0011.
- `toml.parseRecover` entry point plus `RecoveryResult` and
  `RecoveryMode` public types for partial-parse / error-recovery
  workflows (e.g. IDE integrations, linters, CI gates). Logs every
  syntax error instead of aborting on the first one, and returns a
  (possibly partial) `*Document` containing everything that parsed
  cleanly. Configurable via `ParseOptions.recovery_mode` and
  `ParseOptions.max_recovery_errors` (default 100). `InvalidUtf8` and
  `max_bytes` violations are terminal and short-circuit to an empty
  document. Closes GAP-0020. See `docs/API.md` (Error recovery) and
  `examples/lint_toml.zig`.
- SAX-style event parser API (`toml.parseEvents`, `toml.Event`,
  `toml.EventHandler`). Closes GAP-0017. Shares the recursive-descent
  walker with `toml.parse` via a private `ParseSink` abstraction so the
  two APIs cannot drift apart. See `docs/API.md` (Event API) and
  `examples/sax_parser.zig`.
- `toml.parseStream(alloc, reader, opts)` -- parse a TOML document from
  any `std.Io.Reader` (file, socket, pipe). Implemented as a buffering
  wrapper over `parse` that drains the reader into an
  `opts.max_bytes`-bounded allocator-owned buffer. Closes GAP-0016
  (Design A). See `examples/streaming.zig` and `docs/API.md`.
- Schema validation module (`src/schema.zig`) providing both runtime
  `SchemaValidator` with `DiagnosticList` and a comptime-reflective
  `toml.decode(T, alloc, doc)`. Closes GAP-0015. Construction of
  `SchemaNode` values goes through the `SchemaNode.N` sub-namespace
  (Zig forbids a declaration on a union type from sharing a name with
  one of its tag fields). End-to-end example under
  `examples/schema_validation.zig`.
- Public mutation API on `Value` and `Document` (closes GAP-0009,
  GAP-0012, GAP-0013, GAP-0014):
  - Typed accessors: `asI64`, `asF64`, `asBool`, `asString`,
    `asArray`, `asTable` return optionals instead of panicking on
    tag mismatch.
  - Iterators: `Value.iterator()` returns a tagged `ValueIterator`
    with `TableIter` (yields `{ key, value }` in insertion order)
    and `ArrayIter` (yields `*Value` in index order). Non-container
    values return `.empty`. `reset()` supported for multi-pass.
  - `Document.setPath("a.b.c", value)` and
    `Document.setPathSegments(&.{"a", "b", "c"}, value)` write a
    leaf at a dotted key path, creating intermediate tables. Errors
    on path collisions (intermediate non-table), empty paths, and
    empty path segments.
  - `Value.tableSetOwned`, `Value.tableGetOrCreateOwned`, and
    `Value.arrayAppendOwned` are the public method form of the
    previously-internal free functions. `arrayAppendOwned` takes a
    `*Value` and internally copies the payload into the array's
    by-value backing storage.
  - New reference example: `examples/mutation.zig`.
- Root package-level re-exports for the v1.2.0 mutation/iteration API
  so callers can write `toml.Table`, `toml.Array`, `toml.TableIter`,
  `toml.ArrayIter`, `toml.ValueIterator`, `toml.TableIterator`, and
  `toml.tableIterator(...)` without reaching through `toml.value_mod`
  or `toml.Value.Table`. The underlying methods (asI64/asF64/asBool/
  asString/asArray/asTable, tableSetOwned, arrayAppendOwned, setPath,
  setPathSegments) were already reachable via the exported `Value` /
  `Document` types; this change just surfaces the remaining container
  and iterator types at the package root. External consumer-perspective
  coverage lives in `tests/api_v1_2.zig`. Closes GAP-0022.

### Security

- Bounds-guard truncated datetime/local-datetime literals in
  `parseDateParts`/`parseTimeParts`. A short token such as `1234-12:`
  previously reached the fixed-width slicers with no length precheck,
  causing an out-of-bounds slice (panic in safe builds, OOB read in
  `ReleaseFast`). Now returns a clean parse error. (APP-01)
- Cap dotted-key path length at `ParseOptions.max_depth` in
  `parseKeyPath`. Two sibling deeply-dotted keys inside an inline table
  could drive `mergeTables` recursion deep enough to overflow the stack
  (segfault) under default options -- a `max_depth` bypass. Now rejected
  with `LimitExceeded`. (APP-02)

### Fixed

- Silenced a spurious `failed command` banner emitted on every green test
  run by switching the differential corpus case-count diagnostics from
  `std.debug.print` (stderr) to `std.log.debug`. (GAP-0024)

### Changed

- `thread_pool` dependency pinned to the `v0.2.5` release tag (was an
  untagged commit).
- Perf: underscore-free integer/float literals skip the scratch-buffer
  allocation (P-NEW-2); duplicate-key insertion uses a single `getOrPut`
  probe (P-NEW-4). Nine internal-only parser helpers are no longer `pub`
  (Q-23).

## [0.1.5] - 2026-06-11

### Changed

- Diamond-dependency sync: converge `thread_pool` onto its `v0.2.5` tag
  (GAP-0838). Released in parallel with the 0.1.6 audit-closure work; this
  tag carries only the dependency convergence. No library API or behavior
  changes.

## [0.1.4] - 2026-05-02

### Changed

- Release bump tracking tagged sibling dependencies. No library API or
  behavior changes.

## [0.1.3] - 2026-05-02

### Changed

- Release bump tracking tagged sibling dependencies. No library API or
  behavior changes.

## [0.1.2] - 2026-05-02

### Changed

- Release bump tracking tagged sibling dependencies. No library API or
  behavior changes.

## [0.1.1] - 2026-01-26

### Changed

- CI: added the `release-semantic` ci-catalog component and
  company-tagged runner configuration so automated releases fire on
  tagged pushes. This closes the gap between the repo settings and
  the actual tag v0.1.1 that was cut on 2026-01-26.

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

### Changed

- Tests: the two "U-R malformed" smoke tests in `src/toml.zig` and two
  new smoke tests now assert `error_info` carries line, column, message,
  and byte_index on failure, instead of only checking `.success == true`
  (closes Q-3).

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

- `toml.encode(doc, writer, options)`: TOML encoder covering strings,
  integers, floats (including `inf`/`-inf`/`nan`), booleans, all four
  datetime forms, inline arrays, inline tables, `[header]` sections,
  and `[[header]]` array-of-tables. Public API lives in `src/encoder.zig`
  and is re-exported as `toml.encode` / `toml.encoder`. Closes GAP-0006.
- `toml.EncodeOptions`: `sort_keys` (default `true`), `indent` (default
  `0`), and `inline_threshold` (default `8`) for deterministic /
  pretty-printed output. `sort_keys=true` sorts keys byte-order at every
  level; `indent > 0` wraps inline arrays longer than `inline_threshold`
  across indented lines. Closes GAP-0008.
- `toml-test-encoder` CLI binary (`src/bin/toml_test_encoder.zig`):
  reads toml-test tagged JSON from stdin, emits TOML to stdout. Pairs
  with `toml-test-decoder` to drive the BurntSushi/toml-test harness.
  Supporting CLI glue lives in `src/encoder_cli.zig` (`jsonToValue`,
  `runEncodePipeline`). Closes GAP-0007.
- GitLab CI `toml-test-conformance` job (marked `allow_failure: true`
  initially): builds both CLIs and runs the upstream toml-test suite
  against each direction. Partially addresses GAP-0004.
- Tests: `tests/encoder_roundtrip.zig` (round-trip corpus) asserts
  `parse(encode(parse(x)))` yields the same tagged-JSON projection as
  `parse(x)` for every value kind and table shape; `tests/encoder_golden.zig`
  locks byte-exact output for sort_keys determinism and wrapped-array
  pretty-printing.
- Tests: `tests/differential.zig` walks a vendored 30-case toml-test
  subset under `tests/testdata/toml-test/` and asserts valid inputs
  produce the expected tagged JSON and invalid inputs are rejected
  (closes Q-13).
- Real coverage-guided fuzz harness (`tests/fuzz_parse.zig`) wired into
  `zig build test --fuzz`. The GitLab CI `fuzz` stage now exercises a
  real target instead of a no-op. (GAP-0003)
- Defense-in-depth recursion guards (`enterDepth` / `exitDepth`) applied
  to every recursive-descent entrypoint in the parser. (S-6)
- `tableIterator`, `tableLen`, `arrayLen`, `arrayItems` helpers in
  `src/value.zig` / re-exported via `toml.value_mod`. Replace direct
  access to the old `table.entries: []TableEntry` field.
- Performance benchmark harness (`zig build bench`) with hard ceilings
  for 10k top-level keys (<200ms ReleaseFast) and 1000-entry inline
  tables (<50ms ReleaseFast).
- CI leak-check gate: the GitLab `test` job now tees `zig build test`
  output and fails on `memory leak detected` / `not freed` banners, on
  missing `Build Summary` lines (runner aborted), and on summary lines
  reporting failures. Closes GAP-0005.
- Parallel-parser negative tests covering duplicate-key, malformed-
  type, and oversized-batch shapes. (Q-14)
- TOML spec compliance matrix in `docs/SPEC_COMPLIANCE.md`. (GAP-0021)
- `docs/ARCHITECTURE.md` Parallel Subsystem section gained an ASCII
  diagram documenting how `ParallelContext` dispatches batches to
  per-worker `parseWithError` calls, and explicitly records that the
  legacy shape-checker has been deleted. Closes GAP-0010 / Q-9.
- Documentation hygiene tests (`tests/docs_hygiene_test.zig`) that
  break the build if `docs/ARCHITECTURE.md` drops a source file from
  the File Structure block, the stale "Stateless Design" phrasing
  resurfaces, or `CHANGELOG.md` drifts from `git tag -l`. Closes Q-9
  and Q-11.

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
[0.2.0]: https://gitlab.com/devnw/zig/toml/-/compare/v0.1.1...v0.2.0
[0.1.1]: https://gitlab.com/devnw/zig/toml/-/compare/v0.1.0...v0.1.1
[0.1.0]: https://gitlab.com/devnw/zig/toml/-/releases/v0.1.0
