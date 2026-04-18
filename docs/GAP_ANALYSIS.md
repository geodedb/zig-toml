# Gap Analysis

Generated: 2026-04-18 (Phase 4 of audit)
Last updated: 2026-04-18 (Phase 5 gap closure -- 14 closures landed in 037a918..befaff0)
Platform: GitLab (`gitlab.com/devnw/zig/toml`)
Source of truth: GitLab issue tracker. This file mirrors the tracker for open gaps.

Catalog: originally 21 open gaps. Post-closure status:

- Fully closed: GAP-0002, GAP-0003, GAP-0021
- Partial closure (docs/tooling only, underlying bug deferred): GAP-0005, GAP-0010
- Still open: 16 items
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

- **Status:** Partial -- commit `19c9c20` (2026-04-18). Stays in active tracking; see Outstanding.
- **Issue:** [#18](https://gitlab.com/devnw/zig/toml/-/issues/18)
- **Category:** Test / Security
- **Severity:** High
- **Requirement source:** REQ-18.
- **Addressed in this phase:** `.gitlab-ci.yml` now fails when `std.testing.allocator` reports a leak across the Zig test suite. `CONTRIBUTING.md` documents the gate.
- **Addressed evidence:** `.gitlab-ci.yml` (leak-check stage), `CONTRIBUTING.md`, commit `19c9c20`.
- **Outstanding:** The gate catches leaks observable via `std.testing.allocator` at test exit; it does NOT run under valgrind / ASan / TSan and does NOT cover code paths outside tests. Full coverage remains tracked on umbrella issue #42 (Q-16) as a strategic item. Leave issue #18 open; comment-only until full matrix lands.

### GAP-0006: TOML encoder not implemented

- **Issue:** [#6](https://gitlab.com/devnw/zig/toml/-/issues/6)
- **Category:** Feature
- **Severity:** High
- **Requirement source:** REQ-06.
- **Current state (evidence):** No `encoder.zig` / `Document.encode` code path.
- **Why this is a gap:** Round-trip TOML support promised by the API surface is absent.
- **Impact/Risk:** Library cannot serialize; blocks downstream tooling.
- **Recommended fix:** Land a `src/encoder.zig` producing spec-compliant output; integrate with `Document`.
- **Acceptance criteria:** Round-trip tests pass; toml-test encoder suite green.

### GAP-0007: Encoder CLI not implemented

- **Issue:** [#7](https://gitlab.com/devnw/zig/toml/-/issues/7)
- **Category:** Feature
- **Severity:** High
- **Requirement source:** REQ-07.
- **Current state (evidence):** No `toml-test-encoder` binary target.
- **Why this is a gap:** Required to run the toml-test encoder suite.
- **Impact/Risk:** Blocks GAP-0004 and GAP-0006 validation.
- **Recommended fix:** Add `src/bin/toml-test-encoder.zig` and a `build.zig` install step.
- **Acceptance criteria:** Binary reads tagged JSON from stdin, writes TOML to stdout; passes toml-test encoder suite.

### GAP-0008: Pretty-print / stable-sort output formatting missing

- **Issue:** [#8](https://gitlab.com/devnw/zig/toml/-/issues/8)
- **Category:** Feature
- **Severity:** High
- **Requirement source:** REQ-08.
- **Current state (evidence):** No formatter module; depends on GAP-0006.
- **Why this is a gap:** Deterministic output is required for diffable config generation.
- **Recommended fix:** Extend encoder with options struct (indent, sort keys, align `=`).
- **Acceptance criteria:** Golden-file tests for pretty output.

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

- **Status:** Partial -- commit `a5bf263` (2026-04-18). Docs now honest; stays in active tracking because the subsystem itself has a known critical bug (GAP-0001 / U-A shadow parser).
- **Issue:** [#21](https://gitlab.com/devnw/zig/toml/-/issues/21)
- **Category:** Docs
- **Severity:** Medium
- **Addressed in this phase:** API.md, ARCHITECTURE.md, README.md, and ROADMAP.md gained Parallel Batch sections documenting `-Dthread-pool`, `parseDocuments`, `validateDocuments`, `extractKeys`, and the caveat that the batch path uses a shadow parser pending U-A. Closes the doc facets of Q-9 and Q-11 (partial).
- **Addressed evidence:** `docs/API.md`, `docs/ARCHITECTURE.md`, `README.md`, `docs/ROADMAP.md`, commit `a5bf263`.
- **Outstanding:** The docs describe the current (flawed) batch path. They cannot be considered "complete" in the REQ-01 sense until the shadow parser is replaced per GAP-0001. Keep #21 open; comment only.

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

### GAP-0015: Schema validation module

- **Issue:** [#13](https://gitlab.com/devnw/zig/toml/-/issues/13)
- **Category:** Feature
- **Severity:** Medium
- **Requirement source:** REQ-13.
- **Current state (evidence):** No `schema.zig`.
- **Recommended fix:** Declarative schema with required/optional/type constraints.

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
