# zigtoml Roadmap

This document outlines the planned development roadmap for zigtoml, organized by milestone.

## Current Status

zigtoml is a fully compliant TOML v1.1.0 parser for Zig with v1.0.0 compatibility mode. The parser is feature-complete for reading TOML documents.

## Milestones

### [v1.0.0 - Stable Release](https://gitlab.com/devnw/zig/toml/-/milestones/1)

The first stable release focuses on production readiness:

| Issue | Description | Priority |
|-------|-------------|----------|
| [#1](https://gitlab.com/devnw/zig/toml/-/issues/1) | Comprehensive API documentation | High |
| [#2](https://gitlab.com/devnw/zig/toml/-/issues/2) | Fuzz testing infrastructure | High |
| [#3](https://gitlab.com/devnw/zig/toml/-/issues/3) | Benchmark suite | Medium |
| [#4](https://gitlab.com/devnw/zig/toml/-/issues/4) | Package publishing setup | High |
| [#5](https://gitlab.com/devnw/zig/toml/-/issues/5) | toml-test suite integration | High |
| [#16](https://gitlab.com/devnw/zig/toml/-/issues/16) | Windows compatibility testing | Medium |
| [#17](https://gitlab.com/devnw/zig/toml/-/issues/17) | macOS compatibility testing | Medium |
| [#18](https://gitlab.com/devnw/zig/toml/-/issues/18) | Memory leak detection in tests | High |
| [#20](https://gitlab.com/devnw/zig/toml/-/issues/20) | TOML v1.1.0 spec compliance audit | High |

### [v1.1.0 - Encoder Support](https://gitlab.com/devnw/zig/toml/-/milestones/2)

Add TOML serialization capabilities:

| Issue | Description | Priority |
|-------|-------------|----------|
| [#6](https://gitlab.com/devnw/zig/toml/-/issues/6) | TOML encoder/serializer module | High |
| [#7](https://gitlab.com/devnw/zig/toml/-/issues/7) | TOML encoder CLI (toml-test-encoder) | Medium |
| [#8](https://gitlab.com/devnw/zig/toml/-/issues/8) | Pretty-print TOML output | Low |

### [v1.2.0 - Enhanced API](https://gitlab.com/devnw/zig/toml/-/milestones/3)

API improvements for better ergonomics:

| Issue | Description | Priority |
|-------|-------------|----------|
| [#9](https://gitlab.com/devnw/zig/toml/-/issues/9) | Mutable value access API | Medium |
| [#10](https://gitlab.com/devnw/zig/toml/-/issues/10) | Table and array iterators | Medium |
| [#11](https://gitlab.com/devnw/zig/toml/-/issues/11) | Path-based setter API | Low |
| [#12](https://gitlab.com/devnw/zig/toml/-/issues/12) | Type conversion helpers | Low |
| [#13](https://gitlab.com/devnw/zig/toml/-/issues/13) | Schema validation support | Low |

### [v2.0.0 - Streaming Parser](https://gitlab.com/devnw/zig/toml/-/milestones/4)

Major version with streaming support:

| Issue | Description | Priority |
|-------|-------------|----------|
| [#14](https://gitlab.com/devnw/zig/toml/-/issues/14) | Streaming/incremental parser | Medium |
| [#15](https://gitlab.com/devnw/zig/toml/-/issues/15) | Event-based parsing API (SAX-style) | Low |
| [#19](https://gitlab.com/devnw/zig/toml/-/issues/19) | Error recovery and partial parsing | Low |

### Parallel (Batch) Subsystem

`toml.parallel` currently exposes a batch shape-checker
(`parseDocuments`), validator (`validateDocuments`), and top-level key
extractor (`extractKeys`). These run in parallel chunks over a shared
`thread_pool`-backed worker pool and are intended for large fan-out
pre-filtering, not as a drop-in replacement for `toml.parse`.

Planned work (tracked as `U-A` in the gap analysis):

- Replace the `parallel.parseDocument` shape-checker with a real
  invocation of `toml.parse`, returning a proper `Document` per input.
- Extend `validateDocuments` to use the strict grammar rather than the
  byte-level scanner.
- Document determinism guarantees across thread counts.

Until that work lands, the "Parallel Subsystem" docs in
[ARCHITECTURE.md](ARCHITECTURE.md) and [API.md](API.md) spell out the
current, narrower semantics.

## Contributing

Contributions are welcome! See the [Contributing Guide](CONTRIBUTING.md) for details.

When picking up an issue:

1. Check the milestone to understand priority
2. Comment on the issue to claim it
3. Follow the acceptance criteria in the issue description
4. Submit a merge request when ready

## Version Policy

- **Patch versions** (1.0.x): Bug fixes, documentation improvements
- **Minor versions** (1.x.0): New features, backward-compatible changes
- **Major versions** (x.0.0): Breaking API changes, major new features
