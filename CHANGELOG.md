# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
