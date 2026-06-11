# Gap Analysis

Generated: 2026-04-18 (Phase 4 of audit)
Last updated: 2026-06-11 (fresh audit + closure: verified every "open" gap
against current code; closed GAP-0004/0018/0019/0024 and reclassified
GAP-0001/0009/0012/0013/0014/0022 as already-satisfied; +2 new conformance
gaps found by running the full toml-test v1.1.0 corpus)
Platform: GitLab (`gitlab.com/devnw/zig/toml`)
Source of truth: GitLab issue tracker. This file mirrors the tracker for open gaps.

## 2026-06-11 audit closure

A fresh audit re-verified all 10 previously-"open" gaps against current
`main`. Most were already satisfied by code shipped since 2026-04-19; the
rest were closed this iteration.

**Closed this iteration (code/CI landed):**

- **GAP-0024** -- spurious `failed command` test banner removed (commit `c3930fc`).
- **GAP-0004** -- toml-test decoder conformance now ENFORCED (`allow_failure:
  false`) at `-toml 1.1.0`, the version the library targets, skipping the one
  known feature gap (`valid/key/unicode`). Commit `0e8b501`. Encoder direction
  stays monitored pending GAP-0030 (below).
- **GAP-0018 / GAP-0019** -- Windows + macOS cross-compile CI jobs added
  (`build-windows`, `build-macos`); both targets compile clean. Commit `43ba691`.

**Already satisfied (code shipped earlier; treat as resolved):**

- **GAP-0001** -- `parallel.parseDocument` now calls `toml.parseWithError`
  (`src/parallel.zig:485`); invalid TOML rejected; `key_count` from the tree.
- **GAP-0009/0012/0013/0014/0022** -- the v1.2.0 mutation/iteration/typed-accessor
  API is implemented (`src/value.zig`), re-exported (`src/toml.zig:18-39`),
  documented, and tested (`tests/api_v1_2.zig`, green).

**New gaps found this audit (running the full upstream corpus):**

- **GAP-0029** -- TOML 1.1 Unicode bare keys unsupported. The lexer rejects
  `€ = 'x'` (toml-test `valid/key/unicode`). Severity: Medium (1.1 feature gap).
- **GAP-0030** -- Encoder conformance: ~26 `toml-test -encoder` failures at
  `-toml 1.1.0` (escapes, inline tables, dotted keys, datetimes, unicode keys).
  Severity: High (correctness gaps in a shipped feature). Blocks flipping the
  encoder conformance gate to enforced.

Catalog (historical, pre-2026-06-11): originally 21 open gaps; +3
(0022/0023/0024) in 2026-04-19. Post-closure status:

- Fully closed: GAP-0002, GAP-0003, GAP-0005, GAP-0006, GAP-0007,
  GAP-0008, GAP-0010, GAP-0011, GAP-0015, GAP-0016, GAP-0017,
  GAP-0020, GAP-0021, GAP-0023
- Closed 2026-06-11: GAP-0001, 0004, 0009, 0012, 0013, 0014, 0018, 0019, 0022, 0024
- Open after 2026-06-11: GAP-0029 (Unicode bare keys), GAP-0030 (encoder conformance)
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

- **Status:** Closed (2026-04-18) -- see plan
  `docs/superpowers/plans/2026-04-18-12-bench-harness.md` and
  `docs/PERFORMANCE.md`.
- **Issue:** [#3](https://gitlab.com/devnw/zig/toml/-/issues/3)
- **Category:** Test
- **Severity:** High
- **Requirement source:** REQ-03.
- **Current state (evidence):** `bench/` directory with seven microbenchmarks
  plus shared harness; `build.zig` exposes `bench-<name>`, `bench`, and
  `bench-all` steps; `.gitlab-ci.yml` publishes `bench.csv` via an
  `allow_failure: true` `bench` stage; `docs/PERFORMANCE.md` records the
  baselines.
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

### GAP-0017: SAX / event API

- **Status:** Closed -- moved to `docs/GAP_ANALYSIS_RESOLVED.md`.

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

- **Status:** Closed -- feat/partial-parse-error-recovery (2026-04-18).
  Moved to `docs/GAP_ANALYSIS_RESOLVED.md`.
- **Issue:** [#19](https://gitlab.com/devnw/zig/toml/-/issues/19)
- **Category:** Feature
- **Severity:** Medium
- **Requirement source:** REQ-19.
- **Resolution:** `toml.parseRecover(alloc, input, opts)` plus
  `RecoveryResult` / `RecoveryMode` public types; `ParseOptions` gained
  `recovery_mode` and `max_recovery_errors`. See
  `docs/GAP_ANALYSIS_RESOLVED.md` (Plan 11 closure) for the full
  evidence list.

### GAP-0021: v1.1.0 spec compliance audit matrix

- **Status:** Closed -- commit `bdb64c1` (2026-04-18). Moved to `docs/GAP_ANALYSIS_RESOLVED.md`.
- **Issue:** [#20](https://gitlab.com/devnw/zig/toml/-/issues/20)
- **Category:** Docs
- **Severity:** Low
- **Resolution:** `docs/SPEC_COMPLIANCE.md` now carries a per-spec-section matrix mapping each TOML v1.1.0 bullet to implementing symbols (`src/lexer.zig`, `src/parser.zig`) and the tests/fixtures that exercise it.
- **Resolution evidence:** `docs/SPEC_COMPLIANCE.md`, commit `bdb64c1`.

### GAP-0022: v1.2.0 API code-complete but unexposed (umbrella for #9/#12/#13/#14)

- **Issue:** [#60](https://gitlab.com/devnw/zig/toml/-/issues/60)
- **Category:** Feature / API
- **Severity:** High
- **Requirement source:** REQ-09, REQ-10, REQ-11, REQ-12 (milestone v1.2.0 - Enhanced API). Umbrella over issues [#9](https://gitlab.com/devnw/zig/toml/-/issues/9), [#12](https://gitlab.com/devnw/zig/toml/-/issues/12), [#13](https://gitlab.com/devnw/zig/toml/-/issues/13), [#14](https://gitlab.com/devnw/zig/toml/-/issues/14).
- **Current state (evidence):**
  - `src/value.zig:200-268` -- typed conversion helpers implemented: `asI64`, `asF64`, `asBool`, `asString`, `asArray`, `asTable`.
  - `src/value.zig:269-415` -- zero-allocation iterators implemented: `TableIter`, `ArrayIter`, `ValueIterator`.
  - `src/value.zig:461-511` -- path-based setters implemented: `Document.setPath`, `Document.setPathSegments`.
  - `src/value.zig:299-343` -- ownership-clear mutation primitives: `tableSetOwned`, `arrayAppendOwned`.
  - 58 internal symbol references across `src/`; 0 re-exports in `src/toml.zig`; 0 tests under `tests/` exercising these as public API.
- **Why this is a gap:** Four v1.2.0 features (REQ-09/10/11/12) are code-complete internally but not reachable from the public entry-point `src/toml.zig`, so they cannot be closed as shipped. Consumers still cannot mutate, iterate, typed-convert, or path-set on a `Document` without private access.
- **Impact/Risk:** Blocks the v1.2.0 milestone. Work done is invisible to users and to toml-test-compatible external consumers. Risk of silent divergence if internals change before exposure.
- **Recommended fix:** (1) Re-export helpers/iterators/setters in `src/toml.zig` under a clearly marked v1.2.0 block with ownership docs; (2) add `tests/api_v1_2.zig` covering asI64/asF64/asBool/asString/asArray/asTable, TableIter/ArrayIter/ValueIterator iteration order, setPath/setPathSegments, and ownership invariants of tableSetOwned/arrayAppendOwned; (3) add entries in `docs/API.md` and `docs/PUBLIC_API.md`; (4) CHANGELOG `[Unreleased]` bullets; (5) close issues #9, #12, #13, #14 in the same PR that lands this umbrella.
- **Acceptance criteria:** Public API symbols reachable via `toml.*`; new acceptance test file green; `docs/API.md` reference entries present; CHANGELOG updated; #9/#12/#13/#14 closed with evidence pointers.

### GAP-0023: SPEC_COMPLIANCE.md + docs/ cite stale `parser.zig::*` symbols after Q-17 extraction

- **Status:** Closed -- commit `e670231` (2026-04-19). Moved to `docs/GAP_ANALYSIS_RESOLVED.md`.
- **Issue:** [#62](https://gitlab.com/devnw/zig/toml/-/issues/62)
- **Category:** Docs
- **Severity:** Medium
- **Resolution:** All 11 stale `parser.zig::*` citations in `docs/SPEC_COMPLIANCE.md` rewritten to their Q-17 submodule homes (`src/parser/<submodule>.zig::<symbol>`). Compliance matrix once again resolves against `src/`.
- **Resolution evidence:** `docs/SPEC_COMPLIANCE.md`, commit `e670231`.
- **Outstanding:** CI/pre-commit grep gate (item 2 in original recommendation) deferred; not blocking.

### GAP-0024: `zig build test` prints spurious "failed command" line despite exit 0

- **Issue:** [#63](https://gitlab.com/devnw/zig/toml/-/issues/63)
- **Category:** CI-CD / DX bug
- **Severity:** Medium
- **Requirement source:** REQ-18 leak gate + general triage-UX contract that a green test run emits no error-shaped lines.
- **Current state (evidence):**
  - `tests/differential.zig:135` and `:141` -- `std.debug.print(...)` writes to stderr during `addRunArtifact --listen` execution.
  - Exit status is `0`, but the run-artifact driver injects a "failed command" banner on any stderr emission, hiding the true failure line during triage of red runs.
- **Why this is a gap:** Every green local and CI run prints what looks like a failure banner. Operators learn to ignore it, which masks genuine failures when they happen.
- **Impact/Risk:** Silent regression risk; violates "green means green" CI contract; obstructs leak-gate triage (REQ-18).
- **Recommended fix:** (1) Replace the `std.debug.print` calls in `tests/differential.zig` with `std.log.debug` gated by verbosity, or remove entirely; (2) confirm a green `zig build test` emits no "failed command" line; (3) add a CI regex gate that asserts stderr contains no "failed command" on exit 0.
- **Acceptance criteria:** Green runs produce zero "failed command" banners; regex gate green in CI; no behavior change on red runs.
