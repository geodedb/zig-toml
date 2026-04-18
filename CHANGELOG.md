# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Documented the `toml.parallel` subsystem in `README.md`, `docs/API.md`,
  `docs/ARCHITECTURE.md`, and `docs/ROADMAP.md`. The docs make the
  current semantics explicit: `parallel.parseDocuments` is a lightweight
  byte-level shape-checker, not a full parser, and will be promoted to
  the real parser in a future release.
- Real coverage-guided fuzz harness (`tests/fuzz_parse.zig`) wired into
  `zig build test --fuzz`. The GitLab CI `fuzz` stage now exercises a
  real target instead of a no-op.
- Defense-in-depth recursion guards (`enterDepth` / `exitDepth`) applied
  to every recursive-descent entrypoint in the parser.

### Fixed

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

### Changed

- `toml-test-decoder` CLI uses `std.heap.smp_allocator` in release
  builds; `DebugAllocator` is gated on `builtin.mode == .Debug` only.

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

[Unreleased]: https://gitlab.com/devnw/zig/toml/-/compare/v0.1.0...HEAD
[0.1.0]: https://gitlab.com/devnw/zig/toml/-/releases/v0.1.0
