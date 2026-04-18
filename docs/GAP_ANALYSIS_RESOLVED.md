# Gap Analysis -- Resolved Items

Archive of gap-tracking entries that have been fully closed. Maintained alongside `docs/GAP_ANALYSIS.md`, `docs/QUALITY_GAP_ANALYSIS.md`, `docs/PERF_GAP_ANALYSIS.md`, and `docs/SECURITY_GAP_ANALYSIS.md`.

Entry format: `<ID> | <Title> | Closing commit | Resolution date | Evidence`.

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
