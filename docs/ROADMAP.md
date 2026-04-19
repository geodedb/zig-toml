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
| [#14](https://gitlab.com/devnw/zig/toml/-/issues/14) | Streaming/incremental parser (Design B -- truly incremental lexer; Design A shipped as `parseStream`) | Medium |
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

## Design B: Truly Incremental Lexer (v2.0.0 follow-up)

Design A (`toml.parseStream`, shipped) drains the full reader into memory
before parsing. Design B is the real deal: a lexer that pulls from a
`std.Io.Reader` on demand so the peak memory footprint is bounded by a
small rolling buffer plus the accumulating `Document`, not by the size
of the input.

### Why it's hard

The current `Lexer` (`src/lexer.zig`) holds a `[]const u8` and advances a
`usize` cursor. Every byte it has ever seen is still addressable. Two
load-bearing properties rely on that:

1. **Position tracking for diagnostics.** Errors report `byte_index`,
   `line`, and `column` (see `src/error.zig`). With a rolling buffer,
   `byte_index` must be maintained across refills -- a `bytes_consumed`
   base plus a relative cursor, then `byte_index = base + cursor`.
2. **Look-behind for multi-byte tokens.** Multi-line strings, datetimes,
   and numeric literals re-read bytes once they've decided which branch
   they're in. The rolling buffer must retain "the start of the current
   token" through a refill, which means the buffer size must be at least
   `max(token length)` and refills are forbidden while a token is open.

### Sketch

- Introduce `Lexer.initReader(reader: *std.Io.Reader, buf: []u8, version)`
  alongside `Lexer.init(input, version)`. The slice-backed init becomes a
  thin wrapper that points the rolling buffer at the full input and
  disables refill.
- Add a `refill(self: *Lexer, keep_from: usize)` helper that slides the
  window from `keep_from` to `end` down to offset 0, then fills the tail
  from the reader. Every tokeniser that opens a token records a
  `token_start` cursor and hands that value to `refill` so no in-flight
  token is truncated.
- `byte_index` becomes `base + cursor`, where `base` is incremented by
  the slide distance on every refill.
- Parser gets a second public entry point that threads the reader all
  the way down instead of delegating to `parse`. `parseStream` will be
  kept as the stable public API; Design A becomes an implementation
  detail that can be swapped for Design B without a breaking change.

### Validation plan (for when this is picked up)

- Port every `tests/streaming.zig` case to run against both Design A and
  Design B and assert byte-for-byte identical `writeTaggedJson` output.
- Add a memory-ceiling test: parse a 100 MiB synthetic input with a
  4 KiB rolling buffer and assert peak RSS delta stays under
  `document_size + buffer_size + slack` (exact bound determined on
  first implementation pass -- capture the actual ceiling in the test).
- Run the fuzz harness (`tests/fuzz_parse.zig`) against `parseStream`
  with a reader that feeds bytes one at a time, to shake out refill /
  `token_start` boundary bugs.

### Non-goals for Design B

- Partial parsing / error recovery (that's issue #19 -- tracked
  separately under v2.0.0).
- SAX / event-based API (that's issue #15 -- separate follow-up).

Design B is not scheduled in this repository; it lives here so that the
v2.0.0 work has a concrete starting point rather than a blank page.
