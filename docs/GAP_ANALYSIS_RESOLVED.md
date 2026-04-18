# Gap Analysis -- Resolved Items

Archive of gap-tracking entries that have been fully closed. Maintained alongside `docs/GAP_ANALYSIS.md`, `docs/QUALITY_GAP_ANALYSIS.md`, `docs/PERF_GAP_ANALYSIS.md`, and `docs/SECURITY_GAP_ANALYSIS.md`.

Entry format: `<ID> | <Title> | Closing commit | Resolution date | Evidence`.

## Plan 06 closure batch (2026-04-18, feat/encoder-suite)

### Fully closed

| Gap-ID | Title | Closing commit | Resolved | Evidence |
|--------|-------|----------------|----------|----------|
| GAP-0006 | TOML encoder not implemented | `1e731ed` | 2026-04-18 | `src/encoder.zig` full value-kind coverage; `tests/encoder_roundtrip.zig` round-trip corpus; `toml.encode` / `toml.EncodeOptions` public API |
| GAP-0007 | Encoder CLI not implemented | `148d790` | 2026-04-18 | `src/bin/toml_test_encoder.zig` + `src/encoder_cli.zig`; `build.zig` install step; `.gitlab-ci.yml` `toml-test-conformance` stage (allow_failure) |
| GAP-0008 | Pretty-print / stable-sort output formatting missing | `1e731ed` | 2026-04-18 | `EncodeOptions` sort_keys/indent/inline_threshold; `tests/encoder_golden.zig` byte-exact contract |

### Detailed entries

#### GAP-0006: TOML encoder not implemented

- **Status:** Closed -- commit `1e731ed` (2026-04-18). Moved from
  `docs/GAP_ANALYSIS.md`.
- **Issue:** [#6](https://gitlab.com/devnw/zig/toml/-/issues/6)
- **Category:** Feature
- **Severity:** High
- **Requirement source:** REQ-06.
- **Resolution:** `src/encoder.zig` implements
  `encode(doc, writer, options)` with full coverage of every TOML v1
  value kind. Round-trip corpus in `tests/encoder_roundtrip.zig`
  asserts `parse(encode(parse(x)))` yields the same tagged-JSON
  projection as `parse(x)`.
- **Resolution evidence:** `src/encoder.zig`,
  `tests/encoder_roundtrip.zig`, `tests/encoder_golden.zig`,
  commit `1e731ed`.
- **Outstanding:** toml-test conformance CI job is in place as
  `allow_failure: true`; flipping to required is tracked under
  GAP-0004.

#### GAP-0007: Encoder CLI not implemented

- **Status:** Closed -- commit `148d790` (2026-04-18). Moved from
  `docs/GAP_ANALYSIS.md`.
- **Issue:** [#7](https://gitlab.com/devnw/zig/toml/-/issues/7)
- **Category:** Feature
- **Severity:** High
- **Requirement source:** REQ-07.
- **Resolution:** `src/bin/toml_test_encoder.zig` reads toml-test
  tagged JSON from stdin and emits TOML via
  `src/encoder_cli.zig` (`jsonToValue` + `runEncodePipeline`) on
  stdout. `build.zig` installs the binary alongside
  `toml-test-decoder`. GitLab CI `toml-test-conformance` stage pairs
  the two CLIs to drive the BurntSushi/toml-test harness
  (allow_failure until pass-rate is stable).
- **Resolution evidence:** `src/bin/toml_test_encoder.zig`,
  `src/encoder_cli.zig`, `.gitlab-ci.yml` `toml-test-conformance`
  job, commit `148d790`.
- **Outstanding:** Flipping the conformance gate from
  `allow_failure: true` to required is tracked under GAP-0004.

#### GAP-0008: Pretty-print / stable-sort output formatting missing

- **Status:** Closed -- commit `1e731ed` (2026-04-18). Moved from
  `docs/GAP_ANALYSIS.md`.
- **Issue:** [#8](https://gitlab.com/devnw/zig/toml/-/issues/8)
- **Category:** Feature
- **Severity:** High
- **Requirement source:** REQ-08.
- **Resolution:** `EncodeOptions` exposes `sort_keys` (default
  `true`), `indent` (default `0`), and `inline_threshold` (default
  `8`). `sort_keys=true` sorts keys byte-order at every nesting
  level; `indent > 0` wraps inline arrays longer than
  `inline_threshold` across indented lines with one item per line.
- **Resolution evidence:** `src/encoder.zig` (options plumbing),
  `tests/encoder_golden.zig` (byte-exact output locks), commit
  `1e731ed`.
- **Outstanding:** None.

## Phase 5 closure batch (2026-04-18, commits 037a918..befaff0)

### Fully closed

| Gap-ID | Title | Closing commit | Resolved | Evidence |
|--------|-------|----------------|----------|----------|
| GAP-0002 | build.zig.zon 0.1.0 vs docs/API.md 1.0 drift | `25a49f2` | 2026-04-18 | `docs/API.md:3` now 0.1.0; `CHANGELOG.md` [Unreleased] entries |
| GAP-0003 | CI fuzz stage with zero fuzz targets | `a302d21` | 2026-04-18 | `tests/fuzz_parse.zig`; seed corpus under `tests/fuzz_corpus/` |
| GAP-0021 | v1.1.0 spec compliance audit matrix | `bdb64c1` | 2026-04-18 | `docs/SPEC_COMPLIANCE.md` matrix |
| Q-10 | API.md version drift + missing parallel docs | `25a49f2` + `a5bf263` | 2026-04-18 | `docs/API.md` parallel section + version fix |
| Q-14 | Parallel tests all well-formed (no negatives) | `befaff0` | 2026-04-18 | `tests/parallel_*` negative + differential cases |
| Q-15 | Pre-commit hooks no-op | `a53b38c` | 2026-04-18 | `.pre-commit-config.yaml` hook command + broadened fmt scope |
| Q-18 | MAX_CHUNKS=64 drops tail inputs | `037a918` | 2026-04-18 | `src/parallel.zig` ceiling-division + 3 regression tests (N=100); configurability deferred |
| P-3 | parseDocuments drops inputs past MAX_CHUNKS (U-F) | `037a918` | 2026-04-18 | same `src/parallel.zig` fix + tests |
| P-4 | ArrayList capacity=0 at 9 parser sites | `f92ad8b` | 2026-04-18 | `src/parser.zig` initCapacity hints |
| P-9 | Unsorted JSON emit >256 keys; O(n^2) sort <=256 | `87e7099` | 2026-04-18 | `src/json_tagged.zig` stack+heap scratch; always sort |
| P-13 | Escape decoder ArrayList starts empty | `f92ad8b` | 2026-04-18 | folded into P-4 initCapacity pass |
| S-6 | Depth single-gate refactor risk | `cf61421` | 2026-04-18 | parser defense-in-depth recursion guards |
| S-7 | Datetime `catch 0` silences parseInt | `a4b645c` | 2026-04-18 | parser propagates `error.InvalidDateTime` |
| S-8 | `DateTime.format` panic on `i16.minInt` | `203e857` | 2026-04-18 | `src/value.zig` guarded `@intCast` |
| S-11 | CI fuzz stage with zero fuzz targets | `a302d21` | 2026-04-18 | same harness as GAP-0003 |
| S-12 | `DebugAllocator` always-on in CLI | `ec730f2` | 2026-04-18 | `src/bin/toml_test_decoder.zig` conditional allocator |

### Partial closures (stay in active tracking)

These items had the acute sub-issue fixed but the umbrella requirement remains open. They are NOT removed from `docs/GAP_ANALYSIS.md` / companion files.

| Gap-ID | Title | Partial commit | What landed | What remains |
|--------|-------|----------------|-------------|--------------|
| GAP-0005 | Memory-leak CI gate missing | `19c9c20` | `std.testing.allocator` leak gate in `.gitlab-ci.yml`; `CONTRIBUTING.md` note | Full valgrind/ASan coverage; non-test code paths; tracked on umbrella #42 (Q-16) |
| GAP-0010 | API docs missing parallel subsystem | `a5bf263` | Parallel sections added to API.md / ARCHITECTURE.md / README.md / ROADMAP.md | Docs describe a subsystem with a known critical bug (GAP-0001 / U-A shadow parser); docs are "honest" but not "complete" |
| Q-9 | ARCHITECTURE.md omits parallel.zig | `a5bf263` | Same docs pass as GAP-0010 | Underlying shadow parser U-A open |
| Q-11 | CHANGELOG / ROADMAP drift, parallel unmentioned | `25a49f2` + `a5bf263` | CHANGELOG + ROADMAP now reference parallel | Broader reconciliation (all commits-to-CHANGELOG sync) still pending on umbrella #42 |
| Q-16 | Linux-only CI, no leak gate, no coverage, no API drift | `19c9c20` | Leak gate landed | macOS+Windows matrix, coverage threshold, API-drift check still open |

## Verification

- `zig build test` -- 64/64 passing on commit `befaff0` (pre-report clean tree).
- Each commit above contains a regression test or doc update matching its resolution claim; see commit messages for per-item evidence.

## Platform-issue sync

GitLab issue operations attempted at 2026-04-18 closure time. `glab auth status` reported `Invalid token provided in configuration file` -- token refresh required before issues can be closed or commented. No platform-side state was mutated during Phase 5. The outstanding issue-sync list is carried in the Phase 5 completion report returned by the gap-closer-reporter run.

## Plan 08 closure (2026-04-18, feat/schema-validation)

### GAP-0015: Schema validation module (RESOLVED)

- **Issue:** [#13](https://gitlab.com/devnw/zig/toml/-/issues/13)
- **Resolved by:** `src/schema.zig` providing runtime `SchemaValidator`
  and comptime `toml.decode(T, alloc, doc)`.
- **Tests:** See `src/schema.zig` test block and
  `examples/schema_validation.zig`.
