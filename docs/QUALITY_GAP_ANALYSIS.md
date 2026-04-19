# Quality Gap Analysis

Last updated: 2026-04-19 (Phase 7 closure batch: Q-19, Q-20, Q-22 closed)

Source: Phase 3 quality-reviewer output (23 findings: 18 original + Q-19..Q-23 from 2026-04-19 re-scan). Scoring formula:
`PriorityScore = (severity_weight * blast_radius * recency_of_change) / effort_estimate`
where severity weight Critical=5, High=4, Medium=3, Low=2, Info=1; blast_radius/recency/effort on 1-5 scales.
Q-19..Q-23 use the alternate scale `Impact(1-5) * Likelihood(1-5) * 4` (quality-scoring skill).

## Phase 5 closure summary

- Fully closed: Q-9, Q-10, Q-11, Q-14, Q-15, Q-16, Q-18 (moved to `docs/GAP_ANALYSIS_RESOLVED.md`)
- Unchanged: Q-1, Q-2, Q-3, Q-4, Q-5, Q-6, Q-7, Q-12, Q-13, Q-17
- Closed (Plan 14): Q-8 runBatch helper extracted
- Closed (Plan 15): Q-9 (ARCHITECTURE.md structural accuracy, test-enforced), Q-11 (CHANGELOG reconciliation, test-enforced), Q-16 (leak gate extended to all four optimize modes + api-drift + coverage-floor jobs)

## Phase 7 closure summary (2026-04-19)

- Q-19 closed: 4 dead parser trampolines deleted; parser.zig 679->657 LOC (commit `e96909c`).
- Q-20 closed: 4 CLI datetime parsers deduped into `parseDatetimeLiteral`; encoder_cli.zig 307->268 LOC (commit `bbe989c`).
- Q-22 closed: long-function decomposition across lexer + Q-17 submodules. Four sub-commits -- `a0c2005` (Q-22a `lexer::next` 111->40 LOC), `a8bf3a4` (Q-22b `lexNumberOrDateTime` 167->50 LOC), `76ef503` (Q-22c `resolveTablePath` 120->24 LOC), `22cd76d` (Q-22d `recoverAdvancePastLine` 92->24 LOC).
- Verification: `zig fmt --check` clean; `zig build check` clean; `zig build test --summary all` = 238/238 tests pass, 26/26 build steps succeed.

## Summary

| Severity | Count |
|----------|------:|
| Critical | 1 |
| High | 7 |
| Medium | 11 |
| Low | 4 |
| Total | 23 |

### Top 5 Risks (by PriorityScore)

1. **Q-3 -- Smoke tests only assert `success==true`** (PS 100.0). Masks every parser regression, including Q-1/Q-2.
2. **Q-9 -- `docs/ARCHITECTURE.md` omits parallel.zig; claims stateless lexer** (PS 80.0). Contributors model the system wrong; parallel path invisible to reviewers.
3. **Q-10 -- `docs/API.md` claims v1.0 but `build.zig.zon` is 0.1.0; parallel API undocumented** (PS 80.0). Users mis-target compat; public API is un-discoverable.
4. **Q-2 -- `parallel.validateDocument` ignores the real TOML grammar** (PS 50.0). Returns a different yes/no answer than `parser.parse`.
5. **Q-11 -- CHANGELOG / ROADMAP drift; parallel API unmentioned** (PS 45.0). Release artifacts don't match shipped code.

Note: Q-1 (Critical, PS 41.7) is structurally severe -- two parsers means every spec fix has to be made twice -- but scored below 50 because the effort to unify is L.

## Stack-Ranked Findings

| Rank | Severity | PS | Category | Finding | Component | Evidence | Issue | Fix Summary | Owner | ETA | Status |
|-----:|----------|---:|----------|---------|-----------|----------|-------|-------------|-------|-----|--------|
| 1 | High | 100.0 | tests | Q-3 smoke tests only assert success==true | test harness | src/toml.zig:32,307-323; tests/accept.zig | [#29](https://gitlab.com/devnw/zig/toml/-/work_items/29) | Add expectDocument helper, assert structural equality, wire toml-test JSON | @benjiv | 1 wk | open |
| 2 | High | 80.0 | docs | Q-9 ARCHITECTURE.md omits parallel.zig, claims stateless lexer | docs | docs/ARCHITECTURE.md:12-58 | [#36](https://gitlab.com/devnw/zig/toml/-/work_items/36) | Add Parallel Batch Path section; fix lexer description; regenerate diagram | @benjiv | 1 wk | Closed (Plan 15, 52d4297) -- all 10 src files listed; Stateless Design softened; Parallel Subsystem diagram added; drift guarded by tests/docs_hygiene_test.zig |
| 3 | High | 80.0 | docs | Q-10 API.md claims v1.0 but zon=0.1.0; no parallel docs | docs, api | docs/API.md:3-5,140 | [#38](https://gitlab.com/devnw/zig/toml/-/work_items/38) | Sync version to 0.1.0; add Parallel Batch API section + example | @benjiv | 1 wk | Closed (25a49f2 + a5bf263) |
| 4 | High | 50.0 | api-contract | Q-2 validateDocument ignores real grammar | parallel.zig | src/parallel.zig:314-352 | [#26](https://gitlab.com/devnw/zig/toml/-/work_items/26) | Replace body with try/catch around parser.parseDocumentSlice | @benjiv | 1-2 wk | open |
| 5 | Medium | 45.0 | docs | Q-11 CHANGELOG / ROADMAP drift; parallel unmentioned | docs | CHANGELOG, docs/ROADMAP.md | [#42](https://gitlab.com/devnw/zig/toml/-/work_items/42) | Reconcile CHANGELOG + ROADMAP against commits; add parallel entries | @benjiv | 2 d | Closed (Plan 15, c7fbcb5) -- [0.1.1] heading added matching git tag; 0.2.0 entries tagged with audit IDs; leak-gate / api-drift / doc-hygiene credits landed; drift guarded by tests/docs_hygiene_test.zig |
| 6 | Critical | 41.7 | api-contract | Q-1 parallel shadow parser diverges from parser.zig | parallel.zig, parser.zig | src/parallel.zig:165-239 | [#25](https://gitlab.com/devnw/zig/toml/-/work_items/25) | Extract parser.parseDocumentSlice; delete shadow parser; differential test | @benjiv | 2-3 wk | open |
| 7 | High | 26.7 | architecture | Q-4 global pool lazy init + deinitPool UAF window + @panic | parallel.zig | src/parallel.zig:56-76 | [#33](https://gitlab.com/devnw/zig/toml/-/work_items/33) | Caller-owned Pool; return errors not @panic; deinit joins workers | @benjiv | 1-2 wk | open |
| 8 | Medium | 22.5 | maintainability | Q-8 three 35-LOC near-identical submitBatch blocks | parallel.zig | src/parallel.zig:126-163/280-312/393-430 | [#42](https://gitlab.com/devnw/zig/toml/-/work_items/42) | Extract submitBatchImpl(kind) generic | @benjiv | 3 d | Closed (Plan 14) -- runBatch comptime-generic helper owns ceiling-division chunking, submitBatch, sequential fallback, and WaitGroup wait; all 5 call-sites (3 Ctx + 2 legacy shims) delegate to it |
| 9 | Medium | 22.5 | tests | Q-14 parallel tests all well-formed; no negative/diff cases | parallel.zig tests | tests/parallel_* | [#42](https://gitlab.com/devnw/zig/toml/-/work_items/42) | Add negative + serial-vs-parallel differential tests | @benjiv | 3 d | Closed (befaff0) |
| 10 | Low | 20.0 | maintainability | Q-18 MAX_CHUNKS=64 magic caps >64-core machines | parallel.zig | src/parallel.zig:100 | [#42](https://gitlab.com/devnw/zig/toml/-/work_items/42) | Make configurable; default std.Thread.getCpuCount | @benjiv | 1 d | Closed (037a918) -- data-loss fix landed; configurability deferred (reopened if needed) |
| 11 | Low | 20.0 | cleanup | Q-19 dead trampolines in parser.zig (Q-17 leftover) | parser.zig | src/parser.zig:561-573,579-589 | [#54](https://gitlab.com/devnw/zig/toml/-/work_items/54) | Delete decodeEscapes/decodeEscapeChar/validateIntegerFormat/validateFloatFormat; fix SPEC_COMPLIANCE path refs | @benjiv | 30 min | Closed (`e96909c`) -- 4 trampolines deleted; parser.zig 679->657 LOC |
| 12 | Medium | 18.0 | api-contract | Q-12 Document-by-value invalidates arena on copy/move | value.zig, api | src/value.zig:198-217 | [#42](https://gitlab.com/devnw/zig/toml/-/work_items/42) | Switch public API to Document pointer or mark non-copyable | @benjiv | 1 wk | open |
| 13 | High | 16.0 | tests | Q-13 no grammar coverage; toml-test corpus not wired | tests, ci-cd | tests/accept.zig, src/toml.zig | [#39](https://gitlab.com/devnw/zig/toml/-/work_items/39) | Vendor toml-test; add zig build test-compliance; gate CI | @benjiv | 2-3 wk | open |
| 14 | Medium | 16.0 | ci-cd | Q-16 Linux-only CI, no leak gate, no coverage, no API drift | ci-cd | .gitlab-ci.yml | [#42](https://gitlab.com/devnw/zig/toml/-/work_items/42) | Add macOS+Windows matrix, leak gate, coverage threshold, API-drift check | @benjiv | 1 wk | Closed (Plan 15, b62f27e) -- leak gate extended to all 4 optimize modes via `.leak-gate` YAML anchor; `api-drift` job diffs src/toml.zig pub surface against docs/PUBLIC_API.md; `coverage-floor` job enforces COVERAGE_TEST_FLOOR on Build Summary. Cross-platform matrix is tracked separately as GAP-0018 / GAP-0019. |
| 15 | Medium | 13.5 | maintainability | Q-20 duplicate datetime parsers in encoder_cli.zig | encoder_cli.zig, parser/datetime.zig | src/encoder_cli.zig:121-169 | [#55](https://gitlab.com/devnw/zig/toml/-/work_items/55) | Extract shared `datetime.decodeDateTime`; remove duplicates | @benjiv | 1 d | Closed (`bbe989c`) -- 4 parsers deduped into `parseDatetimeLiteral`; encoder_cli.zig 307->268 LOC |
| 16 | Medium | 12.0 | maintainability | Q-22 long functions not previously tracked (lexer + Q-17 submodules) | lexer.zig, parser/recovery.zig, parser/table_path.zig | src/lexer.zig::next(~111), ::lexNumberOrDateTime(~167); src/parser/recovery.zig:198 recoverAdvancePastLine(~92); src/parser/table_path.zig:32 resolveTablePath(~120) | [#57](https://gitlab.com/devnw/zig/toml/-/work_items/57) | Decompose each into <=60 LOC helpers | @benjiv | 3-5 d | Closed (`a0c2005`+`a8bf3a4`+`76ef503`+`22cd76d`) -- all four long functions split to <=60 LOC |
| 17 | Low | 12.0 | ci-cd | Q-15 pre-commit check-todos hook no-op; zig fmt excludes tests/examples | tooling | .pre-commit-config.yaml | [#42](https://gitlab.com/devnw/zig/toml/-/work_items/42) | Fix hook command; broaden fmt scope | @benjiv | 2 h | Closed (a53b38c) |
| 18 | High | 9.0 | maintainability | Q-5 datetime family ~320 LOC, 4 near-parallel parsers | parser.zig | src/parser.zig:1268-1586 | [#35](https://gitlab.com/devnw/zig/toml/-/work_items/35) | Unify into single datetime parser with kind flag; share sub-parsers | @benjiv | 2 wk | open |
| 19 | Low | 8.0 | api-contract | Q-23 over-exports in Q-17 submodules (7 pub helpers with no cross-module callers) | parser/datetime.zig, parser/inline_table.zig, parser/string.zig | datetime.zig:290,294,301,307,311; inline_table.zig:247; string.zig:93 | [#58](https://gitlab.com/devnw/zig/toml/-/work_items/58) | Drop `pub` on 7 internal helpers | @benjiv | 1 h | open |
| 20 | Medium | 4.8 | architecture | Q-17 parser.zig 1636 LOC monolith | parser.zig | src/parser.zig | [#42](https://gitlab.com/devnw/zig/toml/-/work_items/42) | Split into parser_scalar/parser_datetime/parser_table (prereq for Q-5/Q-6/Q-7) | @benjiv | 2-3 wk | Closed (f319529) -- parser.zig under 800 LOC; submodules landed in 5dacdff/faa1f9e/3d0db25/fcec7e7 |
| 21 | Medium | 4.5 | maintainability | Q-6 integer/float ~265 LOC, 7-level nesting | parser.zig | src/parser.zig:997-1267 | [#42](https://gitlab.com/devnw/zig/toml/-/work_items/42) | Extract radix/sign/underscore/base-conversion helpers | @benjiv | 1 wk | open |
| 22 | Medium | 4.5 | architecture | Q-21 src/schema.zig 1199 LOC monolith | schema.zig | src/schema.zig | [#56](https://gitlab.com/devnw/zig/toml/-/work_items/56) | Split into schema/{types,validator,coerce}.zig; keep schema.zig as facade | @benjiv | 1-2 wk | open |
| 23 | Medium | 4.0 | maintainability | Q-7 parseInlineTable 122 LOC | parser.zig | src/parser.zig:625-746 | [#42](https://gitlab.com/devnw/zig/toml/-/work_items/42) | Split into key-parse, value-parse, table-build helpers | @benjiv | 3 d | open |

## Findings by Category

### api-contract (4)

- **Q-1** parallel shadow parser diverges -- [#25](https://gitlab.com/devnw/zig/toml/-/work_items/25)
- **Q-2** validateDocument ignores real grammar -- [#26](https://gitlab.com/devnw/zig/toml/-/work_items/26)
- **Q-12** Document-by-value arena invalidation -- batched [#42](https://gitlab.com/devnw/zig/toml/-/work_items/42)
- **Q-23** over-exports in Q-17 submodules -- [#58](https://gitlab.com/devnw/zig/toml/-/work_items/58)

### tests (3)

- **Q-3** smoke tests only check success bit -- [#29](https://gitlab.com/devnw/zig/toml/-/work_items/29)
- **Q-13** no toml-test corpus wiring -- [#39](https://gitlab.com/devnw/zig/toml/-/work_items/39)
- **Q-14** parallel tests all well-formed -- **Closed** commit `befaff0` (batched [#42](https://gitlab.com/devnw/zig/toml/-/work_items/42))

### docs (3)

- **Q-9** ARCHITECTURE.md omits parallel.zig -- **Closed** Plan 15 commit `52d4297` (all 10 src files listed; Stateless Design softened; Parallel Subsystem diagram added; drift guarded by tests/docs_hygiene_test.zig) -- [#36](https://gitlab.com/devnw/zig/toml/-/work_items/36)
- **Q-10** API.md version + missing parallel docs -- **Closed** commits `25a49f2` + `a5bf263` -- [#38](https://gitlab.com/devnw/zig/toml/-/work_items/38)
- **Q-11** CHANGELOG / ROADMAP drift -- **Closed** Plan 15 commit `c7fbcb5` ([0.1.1] heading added; 0.2.0 entries tagged with audit IDs; leak-gate / api-drift / doc-hygiene credits landed; drift guarded by tests/docs_hygiene_test.zig) -- batched [#42](https://gitlab.com/devnw/zig/toml/-/work_items/42)

### maintainability (7)

- **Q-5** datetime 4 parallel parsers -- [#35](https://gitlab.com/devnw/zig/toml/-/work_items/35)
- **Q-6** int/float 265 LOC, 7-nest -- batched [#42](https://gitlab.com/devnw/zig/toml/-/work_items/42)
- **Q-7** parseInlineTable 122 LOC -- batched [#42](https://gitlab.com/devnw/zig/toml/-/work_items/42)
- **Q-8** 3 near-identical submitBatch blocks -- **Closed** (Plan 14) runBatch helper extracted -- batched [#42](https://gitlab.com/devnw/zig/toml/-/work_items/42)
- **Q-18** MAX_CHUNKS=64 magic -- **Closed** commit `037a918` (data-loss fix; configurability deferred) -- batched [#42](https://gitlab.com/devnw/zig/toml/-/work_items/42)
- **Q-20** duplicate datetime parsers in encoder_cli.zig -- **Closed** commit `bbe989c` -- [#55](https://gitlab.com/devnw/zig/toml/-/work_items/55)
- **Q-22** long functions in lexer + Q-17 submodules -- **Closed** commits `a0c2005` (Q-22a), `a8bf3a4` (Q-22b), `76ef503` (Q-22c), `22cd76d` (Q-22d) -- [#57](https://gitlab.com/devnw/zig/toml/-/work_items/57)

### architecture (3)

- **Q-4** global pool lazy init UAF / @panic -- [#33](https://gitlab.com/devnw/zig/toml/-/work_items/33)
- **Q-17** parser.zig 1636 LOC monolith -- **Closed** commit `f319529` (parser.zig <800 LOC; submodules 5dacdff/faa1f9e/3d0db25/fcec7e7) -- batched [#42](https://gitlab.com/devnw/zig/toml/-/work_items/42)
- **Q-21** schema.zig 1199 LOC monolith -- [#56](https://gitlab.com/devnw/zig/toml/-/work_items/56)

### cleanup (1)

- **Q-19** dead trampolines in parser.zig (Q-17 leftover) -- **Closed** commit `e96909c` -- [#54](https://gitlab.com/devnw/zig/toml/-/work_items/54)

### ci-cd (2)

- **Q-15** pre-commit hooks no-op -- **Closed** commit `a53b38c` -- batched [#42](https://gitlab.com/devnw/zig/toml/-/work_items/42)
- **Q-16** Linux-only CI, no leak gate -- **Closed** Plan 15 commit `b62f27e` (leak gate extended to all 4 optimize modes via `.leak-gate` YAML anchor; `api-drift` job diffs src/toml.zig pub surface against docs/PUBLIC_API.md; `coverage-floor` job enforces COVERAGE_TEST_FLOOR. Cross-platform matrix tracked separately as GAP-0018 / GAP-0019.) -- batched [#42](https://gitlab.com/devnw/zig/toml/-/work_items/42)

## Roadmap

### Quick wins (< 1 day)

- Q-15 fix pre-commit hooks
- Q-18 make MAX_CHUNKS configurable
- Q-11 reconcile CHANGELOG / ROADMAP
- Q-9 documentation patch for ARCHITECTURE.md
- Q-10 documentation patch for API.md
- ~~Q-19 delete dead parser.zig trampolines (30 min)~~ **Done** (`e96909c`)
- Q-23 drop `pub` on 7 internal Q-17 helpers (1 h)

### Medium (1-5 days)

- Q-3 structural test assertions + expectDocument helper
- Q-8 extract submitBatchImpl
- Q-14 add differential parallel tests
- Q-7 refactor parseInlineTable
- Q-2 route validateDocument through real parser
- ~~Q-20 extract shared `datetime.decodeDateTime`; drop encoder_cli duplicates~~ **Done** (`bbe989c`)
- ~~Q-22 decompose long functions in lexer + Q-17 submodules~~ **Done** (`a0c2005`+`a8bf3a4`+`76ef503`+`22cd76d`)

### Strategic (> 5 days)

- Q-1 unify parser entrypoint; remove shadow parser (blocks Q-2 cleanup)
- Q-4 redesign pool lifecycle to caller-owned
- Q-5 datetime unification (depends on Q-17 split)
- Q-6 int/float parser decomposition
- Q-12 Document ownership redesign (public API change -- queue for 0.2.0)
- Q-13 toml-test compliance job (depends on Q-3 helper)
- Q-16 CI matrix + leak gate + coverage + API-drift
- Q-17 parser.zig module split (prereq for Q-5/Q-6/Q-7) -- **Closed** `f319529`
- Q-21 schema.zig split into schema/{types,validator,coerce}.zig

## Cross-Links to Existing Issues

- [#5](https://gitlab.com/devnw/zig/toml/-/work_items/5) toml-test suite integration -- subsumes part of Q-13.
- [#18](https://gitlab.com/devnw/zig/toml/-/work_items/18) Memory leak detection -- subsumed by Q-16.
- [#20](https://gitlab.com/devnw/zig/toml/-/work_items/20) v1.1.0 spec compliance -- complements Q-13.
- [#21](https://gitlab.com/devnw/zig/toml/-/work_items/21) Document parallel batch API -- overlaps Q-10 (parallel API docs).

## Confidence Notes

All 23 findings are tagged `confidence::confirmed`: each cites explicit file:line evidence verified during Phase 3 review. Unknown: Q-11 exact 0.1.0 release date requires a git-tag check (`git log --format='%ai' v0.1.0` or equivalent) to confirm.
