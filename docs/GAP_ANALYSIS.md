# Gap Analysis

Generated: 2026-04-18 (Phase 4 of audit)
Last updated: 2026-04-18 (Phase 5 gap closure -- 14 closures landed in 037a918..befaff0)
Platform: GitLab (`gitlab.com/devnw/zig/toml`)
Source of truth: GitLab issue tracker. This file mirrors the tracker for open gaps.

Catalog: originally 21 open gaps. Post-closure status:

- Fully closed: GAP-0002, GAP-0003, GAP-0005, GAP-0006, GAP-0007,
  GAP-0008, GAP-0010, GAP-0021
- Still open: 13 items
Resolved items live in `docs/GAP_ANALYSIS_RESOLVED.md`.

## Gaps

### GAP-0001: parseDocument in parallel.zig is a shadow parser

- **Issue:** [#22](https://gitlab.com/devnw/zig/toml/-/issues/22)
- **Category:** Bug
- **Severity:** Critical
- **Requirement source:** `src/toml.zig:32` (public `parallel` re-export); implicit contract that batch parse must use the real parser.
- **Current state (evidence):**
  - `src/parallel.zig:165-239` -- hand-rolled byte walker, does not call `parser.zig`.
  - `src/parallel.zig:166` -- `_ = allocator;` (allocator discarded).
  - `src/parallel.zig:201` -- counts raw `=` bytes as `key_count`.
- **Why this is a gap:** The parallel batch API silently accepts invalid TOML and returns heuristic key counts, diverging from the single-document `Parser`.
- **Impact/Risk:** Critical correctness bug. Consumers of `toml.parallel.parseDocuments` receive false-positive successes and wrong key counts.
- **Recommended fix:** Replace `parseDocument` body with a call into `parser.zig` (`Parser.init` / `parser.parse`); map real errors to `ParseResult`; derive `key_count` from the `Document` tree.
- **Acceptance criteria:** `parseDocument` invokes `parser.zig`; new test proves invalid TOML fails; `key_count` matches document leaf count; no leaks under `std.testing.allocator`.

### GAP-0002: build.zig.zon version (0.1.0) contradicts docs/API.md ("Library Version 1.0")

- **Status:** Closed -- commit `25a49f2` (2026-04-18). Moved to `docs/GAP_ANALYSIS_RESOLVED.md`.
- **Issue:** [#23](https://gitlab.com/devnw/zig/toml/-/issues/23)
- **Category:** Bug
- **Severity:** Critical
- **Resolution:** `docs/API.md:3` now reads `0.1.0`, matching `build.zig.zon:3`. `CHANGELOG.md` gained two `[Unreleased]` entries (U-F, GAP-0002). MD036 footer removed to satisfy pre-commit markdownlint.
- **Resolution evidence:** `docs/API.md:3`, `CHANGELOG.md` (Unreleased section), commit `25a49f2`.
- **Outstanding:** CI drift gate between `docs/API.md` version header and `build.zig.zon` is not yet added; tracked under umbrella issue #42 (Q-16 -- API-drift check item).

### GAP-0003: GitLab fuzz job runs `zig build test --fuzz` with zero fuzz targets

- **Status:** Closed -- commit `a302d21` (2026-04-18). Moved to `docs/GAP_ANALYSIS_RESOLVED.md`.
- **Issue:** [#24](https://gitlab.com/devnw/zig/toml/-/issues/24)
- **Category:** Test / CI-CD
- **Severity:** Critical
- **Resolution:** Landed `fuzz_parse` harness exercising `toml.parse` via `std.testing.fuzz` with a seed corpus. The CI `--fuzz` stage now has a real target to drive. Cross-closes S-11 (security).
- **Resolution evidence:** `tests/fuzz_parse.zig` (new), seed corpus under `tests/fuzz_corpus/`, commit `a302d21`.
- **Outstanding:** CI still uses `timeout 60 zig build test --fuzz` (treats 124 as success). Upgrading that guard to assert iterations-per-run is parked on umbrella #42 (S-11 strategic item).

### GAP-0004: toml-test integration -- CLI exists but no CI job invokes it

- **Issue:** [#5](https://gitlab.com/devnw/zig/toml/-/issues/5)
- **Category:** Test
- **Severity:** High
- **Requirement source:** REQ-05 (toml-test compatibility) / issue #5.
- **Current state (evidence):**
  - `src/bin/` contains the toml-test decoder/encoder CLI hooks.
  - `.gitlab-ci.yml` has no job that clones `BurntSushi/toml-test` and runs the CLI.
- **Why this is a gap:** We advertise toml-test compatibility but never execute it in CI.
- **Impact/Risk:** Regressions in spec compliance can merge undetected.
- **Recommended fix:** Add a CI stage that checks out a pinned toml-test release, builds the decoder CLI, and runs the suite against both v1.0.0 and v1.1.0 filters.
- **Acceptance criteria:** Green toml-test CI job on main; failures blocking merge.

### GAP-0005: Memory-leak CI gate missing

- **Status:** Closed (full) -- commits `19c9c20` (initial Debug gate, 2026-04-18) and `b62f27e` (four-mode matrix via `.leak-gate` YAML anchor, 2026-04-18).
- **Issue:** [#18](https://gitlab.com/devnw/zig/toml/-/issues/18)
- **Category:** Test / Security
- **Severity:** High
- **Requirement source:** REQ-18.
- **Addressed evidence:** `.gitlab-ci.yml` `.leak-gate` anchor wired into `test`, `test-release-safe`, `test-release-fast`, and `test-release-small`. `CONTRIBUTING.md` documents the gate. Commit `b62f27e`.
- **Outstanding:** None for the in-tree testing surface. valgrind / ASan / TSan coverage of non-test code paths is tracked as a future enhancement under the umbrella issue #42 (Q-16) but is out of scope for REQ-18 as originally defined.

### GAP-0006: TOML encoder not implemented

- **Status:** Closed -- commit `1e731ed` (2026-04-18). Moved to `docs/GAP_ANALYSIS_RESOLVED.md`.
- **Issue:** [#6](https://gitlab.com/devnw/zig/toml/-/issues/6)
- **Category:** Feature
- **Severity:** High
- **Requirement source:** REQ-06.
- **Addressed evidence:** `src/encoder.zig` (Plan 06) implements `encode(doc, writer, options)` with full coverage of integers, floats, booleans, strings, datetimes, inline arrays, inline tables, header tables, and arrays-of-tables. Round-trip corpus at `tests/encoder_roundtrip.zig` verifies parse -> encode -> parse equivalence via tagged-JSON projection. Public API wiring in `src/toml.zig` exposes `toml.encode` and `toml.EncodeOptions`.
- **Outstanding:** None. The toml-test encoder CLI harness is tracked under GAP-0007 (also closed).

### GAP-0007: Encoder CLI not implemented

- **Status:** Closed -- commit `148d790` (2026-04-18). Moved to `docs/GAP_ANALYSIS_RESOLVED.md`.
- **Issue:** [#7](https://gitlab.com/devnw/zig/toml/-/issues/7)
- **Category:** Feature
- **Severity:** High
- **Requirement source:** REQ-07.
- **Resolution:** `src/bin/toml_test_encoder.zig` reads toml-test tagged JSON from stdin and emits TOML via `src/encoder_cli.zig` (`jsonToValue` + `runEncodePipeline`) on stdout. `build.zig` installs the binary alongside `toml-test-decoder`. GitLab CI `toml-test-conformance` stage wires both CLIs into the BurntSushi/toml-test harness (allow_failure until pass-rate is stable; flip tracked under GAP-0004).
- **Resolution evidence:** `src/bin/toml_test_encoder.zig`, `src/encoder_cli.zig`, `.gitlab-ci.yml` `toml-test-conformance` job, commit `148d790`.

### GAP-0008: Pretty-print / stable-sort output formatting missing

- **Status:** Closed -- commit `1e731ed` (2026-04-18). Moved to `docs/GAP_ANALYSIS_RESOLVED.md`.
- **Issue:** [#8](https://gitlab.com/devnw/zig/toml/-/issues/8)
- **Category:** Feature
- **Severity:** High
- **Requirement source:** REQ-08.
- **Addressed evidence:** `EncodeOptions` exposes `sort_keys` (default true), `indent` (default 0), and `inline_threshold` (default 8). `tests/encoder_golden.zig` locks byte-exact output: `sort_keys=true` is independent of input order at every level (root, inline tables, header tables); `sort_keys=false` preserves insertion order; `indent > 0` wraps inline arrays longer than `inline_threshold` across indented lines with a trailing comma per item.

### GAP-0009: Mutable Value API is internal-only; no public mutation surface

- **Issue:** [#9](https://gitlab.com/devnw/zig/toml/-/issues/9)
- **Category:** Feature
- **Severity:** High
- **Requirement source:** REQ-09.
- **Current state (evidence):** `Value` union has only read accessors publicly exposed in `src/value.zig` / `src/toml.zig`.
- **Why this is a gap:** Consumers cannot build or mutate a `Document` without private access.
- **Recommended fix:** Expose `set`, `append`, `remove` on `Value`/`Document` with clear ownership rules.
- **Acceptance criteria:** Public API docs updated; unit tests cover mutation.

### GAP-0010: API docs missing parallel subsystem section

- **Status:** Closed (full) -- commits `a5bf263` (2026-04-18 initial docs), Plan 01 (shadow-parser removal, 2026-04-18), and `52d4297` + `c7fbcb5` (Plan 15 diagram + test guards + CHANGELOG credit, 2026-04-18).
- **Issue:** [#21](https://gitlab.com/devnw/zig/toml/-/issues/21)
- **Category:** Docs
- **Severity:** Medium
- **Addressed evidence:** `docs/API.md`, `docs/ARCHITECTURE.md` (Parallel Subsystem section with ASCII diagram documenting ParallelContext → parseWithError dispatch), `README.md`, `docs/ROADMAP.md`, `CHANGELOG.md` 0.2.0 credit, `tests/docs_hygiene_test.zig` (guards against doc drift). Commits `a5bf263`, Plan 01, `52d4297`, `c7fbcb5`.
- **Outstanding:** None. The shadow parser was removed in Plan 01; the parallel path now delegates to `toml.parseWithError`, so the docs describe the real implementation. Close issue #21.

### GAP-0011: Bench suite not implemented

- **Issue:** [#3](https://gitlab.com/devnw/zig/toml/-/issues/3)
- **Category:** Test
- **Severity:** High
- **Requirement source:** REQ-03.
- **Current state (evidence):** No `bench/` directory; `build.zig` has no `bench` step.
- **Why this is a gap:** Performance regressions cannot be detected.
- **Recommended fix:** Add a `zig build bench` step with reproducible inputs and JSON output.
- **Acceptance criteria:** `zig build bench` runs; CI nightly publishes results.

### GAP-0012: Iterator API for tables/arrays

- **Issue:** [#10](https://gitlab.com/devnw/zig/toml/-/issues/10)
- **Category:** Feature
- **Severity:** Medium
- **Requirement source:** REQ-10.
- **Current state (evidence):** No `iterator()` method on `Table` / `Array` types.
- **Recommended fix:** Add zero-allocation iterators.
- **Acceptance criteria:** Docs + tests cover key/value iteration order.

### GAP-0013: Path-based setter

- **Issue:** [#11](https://gitlab.com/devnw/zig/toml/-/issues/11)
- **Category:** Feature
- **Severity:** Medium
- **Requirement source:** REQ-11.
- **Current state (evidence):** Depends on GAP-0009.
- **Recommended fix:** Implement `Document.setPath("a.b.c", value)`.

### GAP-0014: Typed conversion helpers

- **Issue:** [#12](https://gitlab.com/devnw/zig/toml/-/issues/12)
- **Category:** Feature
- **Severity:** Medium
- **Requirement source:** REQ-12.
- **Current state (evidence):** No `asInt() / asFloat() / asBool()` helpers on `Value`.
- **Recommended fix:** Add safe accessors returning `!T`.

### GAP-0016: Streaming parser API

- **Issue:** [#14](https://gitlab.com/devnw/zig/toml/-/issues/14)
- **Category:** Feature
- **Severity:** Medium
- **Requirement source:** REQ-14.
- **Current state (evidence):** Only full-buffer parse is exposed.
- **Recommended fix:** Feed `io.Reader` incrementally; emit `Document` on EOF.

### GAP-0017: SAX / event API

- **Issue:** [#15](https://gitlab.com/devnw/zig/toml/-/issues/15)
- **Category:** Feature
- **Severity:** Medium
- **Requirement source:** REQ-15.
- **Current state (evidence):** No event callbacks.
- **Recommended fix:** Event enum + visitor interface.

### GAP-0018: Windows CI

- **Issue:** [#16](https://gitlab.com/devnw/zig/toml/-/issues/16)
- **Category:** Test / CI-CD
- **Severity:** Medium
- **Requirement source:** REQ-16.
- **Current state (evidence):** `.gitlab-ci.yml` runs only Linux.
- **Recommended fix:** Add Windows runner job or cross-build + test via wine/actions runner.

### GAP-0019: macOS CI

- **Issue:** [#17](https://gitlab.com/devnw/zig/toml/-/issues/17)
- **Category:** Test / CI-CD
- **Severity:** Medium
- **Requirement source:** REQ-17.
- **Current state (evidence):** `.gitlab-ci.yml` runs only Linux.
- **Recommended fix:** Add macOS runner or GitHub Actions mirror.

### GAP-0020: Partial-parse / error-recovery

- **Issue:** [#19](https://gitlab.com/devnw/zig/toml/-/issues/19)
- **Category:** Feature
- **Severity:** Medium
- **Requirement source:** REQ-19.
- **Current state (evidence):** Parser bails on first error.
- **Recommended fix:** Continue-on-error mode emitting multiple diagnostics.

### GAP-0021: v1.1.0 spec compliance audit matrix

- **Status:** Closed -- commit `bdb64c1` (2026-04-18). Moved to `docs/GAP_ANALYSIS_RESOLVED.md`.
- **Issue:** [#20](https://gitlab.com/devnw/zig/toml/-/issues/20)
- **Category:** Docs
- **Severity:** Low
- **Resolution:** `docs/SPEC_COMPLIANCE.md` now carries a per-spec-section matrix mapping each TOML v1.1.0 bullet to implementing symbols (`src/lexer.zig`, `src/parser.zig`) and the tests/fixtures that exercise it.
- **Resolution evidence:** `docs/SPEC_COMPLIANCE.md`, commit `bdb64c1`.
