# Security Gap Analysis

**Last updated:** 2026-04-18 (Phase 5 gap closure reconciled in 037a918..befaff0)
**Project:** devnw/zig/toml
**Phase:** 5 -- gap closure reconciliation
**Scope:** findings from Phase 3 security review (12 total)

**Phase 5 closure summary:** S-6, S-7, S-8, S-11, S-12 fully closed (see Status column and `docs/GAP_ANALYSIS_RESOLVED.md`). S-1, S-2, S-3, S-4, S-5, S-9, S-10 unchanged.

> Detailed exploit PoCs for pre-auth correctness bugs in the parallel subsystem
> are kept in confidential GitLab issues. This public doc publishes only safe
> summaries; where exploit details might aid attackers they are referenced by
> issue ID instead of pasted inline.

## Summary

| Severity | Count |
|----------|-------|
| Critical | 0 |
| High     | 3 |
| Medium   | 4 |
| Low      | 5 |
| Info     | 0 |
| **Total**| **12** |

### Top 5 Risks

1. **S-1 shadow parser in `parallel.zig`** -- Risk 16. False-negatives on invalid TOML break the entire `-Dthread-pool` contract. Tracked publicly as issue #22 (GAP-0001) and re-scored as a security finding under a confidential issue.
2. **S-3 `validateDocument` is not a grammar validator** -- Risk 15. Accepts obviously-invalid TOML; shares the false-assurance failure mode as S-1.
3. **S-11 CI `fuzz` stage with zero fuzz targets** -- Risk 15. `timeout 60 zig build test --fuzz` exits 124 on timeout (treated as success) even though no `std.testing.fuzz` targets exist -- pure false assurance in the supply-chain story.
4. **S-2 `in_string` handling misreads `\\"`** -- Risk 12. Escaped-backslash-then-quote desyncs the mini-scanner and compounds S-1/S-3.
5. **S-4 `deinitPool` use-after-free window on the global pool pointer** -- Risk 10, suspected. Needs a race reproducer before elevating.

## Scoring Framework

- **Risk Score** = Impact (1-5) x Likelihood (1-5). Max 25. Library/parser context -> no `internet-facing` surface; exposure is whoever feeds TOML to the parser.
- **Severity mapping:** 20-25 = Critical, 12-19 = High, 8-11 = Medium, 4-7 = Low, 1-3 = Info.
- **Confidence:** `confirmed` = evidence in source today; `suspected` = plausible pattern-match, verification TBD.

## Stack-Ranked Findings

| Rank | Sev | Risk | ID | Finding | Component | CWE / OWASP | Evidence | Confidence | Issue | Status |
|------|-----|------|-----|---------|-----------|-------------|----------|------------|-------|--------|
| 1 | High | 16 | S-1/F1 | `parseDocument` is a shadow parser, not a real TOML grammar | parallel | CWE-345, CWE-436 / A08:2021 | `src/parallel.zig:165-239` | confirmed | public #22, confidential #41 | Open |
| 2 | High | 15 | S-3/F3 | `validateDocument` accepts invalid TOML | parallel | CWE-436 / A08:2021 | `src/parallel.zig:314-352` | confirmed | confidential #43 | Open |
| 3 | High | 15 | S-11/F11 | CI `fuzz` stage with zero fuzz targets | ci-cd | CWE-1120 / A05:2021 | `.gitlab-ci.yml:145-160` | confirmed | public #44 | Closed (a302d21) -- fuzz_parse harness + corpus |
| 4 | Med  | 12 | S-2/F2 | `in_string` misreads escaped backslash then quote | parallel | CWE-697 | `src/parallel.zig:189` | confirmed | public #45 | Open |
| 5 | Med  | 10 | S-4/F4 | `deinitPool` UAF window on `global_pool` pointer | parallel | CWE-416 / A06:2021 | `src/parallel.zig:69-76` | suspected | public #46 | Open |
| 6 | Med  |  9 | S-5/F5 | `@panic` on thread-pool init failure -- DoS primitive | parallel | CWE-248, CWE-400 / A05:2021 | `src/parallel.zig:63-64` | confirmed | public #47 | Open |
| 7 | Med  |  9 | S-9/F9 | Only `max_bytes` caps parser; no `max_keys`/`max_values` | parser | CWE-400, CWE-789 / A05:2021 | `src/parser.zig:23-27` | confirmed | public #48 | Open |
| 8 | Low  |  8 | S-6/F6 | Depth single-gate (`parseValue` only) -- refactor risk | parser | CWE-674 | `src/parser.zig:392, 522` | confirmed (today safe) | public #49 | Closed (cf61421) -- defense-in-depth recursion guards |
| 9 | Low  |  8 | S-7/F7 | Datetime `catch 0` silences `std.fmt.parseInt` | parser | CWE-20, CWE-252 | `src/parser.zig:1343, 1362, 1364` | confirmed | public #50 | Closed (a4b645c) -- propagate error.InvalidDateTime |
| 10| Low  |  4 | S-10/F10 | `thread_pool` pinned by commit hash only; no signed-tag policy | supply-chain | CWE-1357, CWE-829 / A08:2021 | `build.zig.zon:9` | confirmed | public #51 | Open |
| 11| Low  |  4 | S-12/F12 | `DebugAllocator` always used in CLI -- info-disclosure surface | cli | CWE-209 | `src/bin/toml_test_decoder.zig:14` | confirmed | public #52 | Closed (ec730f2) -- conditional allocator |
| 12| Low  |  3 | S-8/F8 | `DateTime.format` `@intCast(-offset)` panic on `i16.minInt` | value | CWE-190 | `src/value.zig:58` | suspected | public #53 | Closed (203e857) -- guard against i16.minInt |

## Findings by Area

### parser.zig (core)

- S-6 depth gate defense-in-depth (Low) -- **Closed** commit `cf61421`.
- S-7 datetime `catch 0` spec non-conformance (Low) -- **Closed** commit `a4b645c`.
- S-9 missing `max_keys`/`max_values` caps (Medium)

### parallel.zig (batch API)

- S-1 shadow parser / false oracle (High)
- S-2 escape-sequence string tracker (Medium)
- S-3 non-validator validator (High)
- S-4 UAF on pool pointer (Medium, suspected)
- S-5 panic-on-init DoS primitive (Medium)

### value.zig

- S-8 `i16.minInt` offset panic (Low, suspected) -- **Closed** commit `203e857`.

### CLI (src/bin/)

- S-12 `DebugAllocator` always-on (Low) -- **Closed** commit `ec730f2`.

### CI/CD (.gitlab-ci.yml)

- S-11 fake fuzz stage (High) -- **Closed** commit `a302d21` (fuzz_parse harness + seed corpus landed; CI-side iteration-count assert still deferred to umbrella #42).

### Supply chain (build.zig.zon)

- S-10 commit-hash pinned dep without signed-tag policy (Low)

## Roadmap

### Quick wins (< 1 day)

- Remove or rewire the fake fuzz stage (S-11); land at minimum `fuzz_parse`, `fuzz_parse_documents`, `fuzz_lexer_next`, `fuzz_parse_datetime` harnesses so `--fuzz` has something to drive.
- Fix datetime `catch 0` -> propagate `error.InvalidDateTime` (S-7).
- Switch CLI to `GeneralPurposeAllocator`/`std.heap.smp_allocator` outside tests (S-12).
- Guard `@intCast(-offset)` against `i16.minInt` (S-8).

### Medium (1-5 days)

- Replace `parseDocument` body with a call into `parser.zig` (S-1) -- also fixes S-2 and collapses S-3 into the same path.
- Rebuild `validateDocument` on top of the real lexer/parser (S-3).
- Make `getPool`/`deinitPool` reference-counted or `std.Once`-gated to close the UAF window (S-4) and return a typed error instead of `@panic` (S-5).
- Add `max_keys` / `max_values` / `max_string_bytes` to `ParseOptions` (S-9).

### Strategic (> 5 days)

- Centralize depth/recursion accounting in a single `pushDepth`/`popDepth` helper and delete ad-hoc counters (S-6).
- Ship a supply-chain policy document: signed-tag requirement, reproducible-build verification, and renovate/dependabot-style automation for `build.zig.zon` pins (S-10).
- Wire fuzz harnesses into scheduled CI with artifact retention and minimizer.

## Immediate Actions

| # | Action | Why | Status |
|---|--------|-----|--------|
| 1 | **Rotate secrets** -- N/A | No secrets are stored in this repo. `glab` token in local CLI config is out of scope for this project. | N/A |
| 2 | **Hotfix vs. next release** -- Hotfix S-1 + S-3 + S-2 | Silent false-success from `parallel.parseDocuments` / `validateDocuments` is a correctness *and* trust-boundary regression; downstream consumers cannot rely on the batch API for rejection. | Open |
| 3 | **Hotfix S-11** fuzz stage | CI today reports "fuzzing is green" while exercising zero fuzz targets. Either delete the stage or land real harnesses before the next tag. | Closed (a302d21) |
| 4 | **Propose fuzz targets** (pre-requisite for S-11 close) | `fuzz_parse` (`toml.parse`), `fuzz_parse_documents` (`toml.parallel.parseDocuments`), `fuzz_lexer_next` (`lex.Lexer.next`), `fuzz_parse_datetime` (`Parser.parseDateTime`). | Proposed |

## Confidential-issue rationale

S-1, S-3 and S-2 all ship concrete counter-example TOML strings that let an
attacker craft adversarial input the batch API will silently accept. PoCs live
in confidential GitLab issues; this public doc keeps only root-cause + `file:line`.

## Blockers / Unknowns

- S-4 needs a ThreadSanitizer or targeted race-test reproducer before we can claim `confirmed`.
- S-8 `i16.minInt` panic -- needs a unit test that constructs a `DateTime` with `offset_minutes = -32768` directly; likely unreachable from the parser (parser validates before storing) but defense-in-depth still warranted.
- S-10 depends on upstream `devnw/zig/thread-pool` publishing signed tags; raise with upstream maintainers.
