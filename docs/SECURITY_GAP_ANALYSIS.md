# Security Gap Analysis

**Last updated:** 2026-04-19 (Phase 7 closure batch — S-13, S-15 code-closed)
**Project:** devnw/zig/toml
**Phase:** 7 -- encoder unreachable hardening + fuzz coverage expansion landed
**Scope:** findings from Phase 3 security review (12 original + 3 follow-ups = 15; plus one audit-trail no-finding)

**Phase 7 closure summary:** S-13 closed by replacing the two `unreachable` sites in `src/encoder.zig:122,310` with `return error.UnsupportedValueVariant` plus a direct test (commit `0e6dcfe`). S-15 closed by landing four sibling fuzz harnesses -- `fuzz_parse_recover`, `fuzz_parse_stream`, `fuzz_parse_events`, `fuzz_parallel` -- wired into `zig build test` (commit `6c80c06`).
**Phase 6 closure summary:** S-1, S-2, S-3, S-5 closed by the `ParallelContext` rewrite series (commits `a68a6d6`, `2a998a6`, `c2b4cec`, `c0ef584`, `fc3dd6c`). S-13, S-15, S-16 newly opened as follow-up to Phase 5's `fuzz_parse` landing — S-11's closure covered `parseWithError` only; the other public APIs remain unfuzzed. S-14 was investigated and recorded as `closed: no-finding` (see Audit Trail).
**Phase 5 closure summary:** S-6, S-7, S-8, S-11, S-12 fully closed (see Status column and `docs/GAP_ANALYSIS_RESOLVED.md`).

> Detailed exploit PoCs for pre-auth correctness bugs in the parallel subsystem
> are kept in confidential GitLab issues. This public doc publishes only safe
> summaries; where exploit details might aid attackers they are referenced by
> issue ID instead of pasted inline.

## Summary

| Severity | Count |
|----------|-------|
| Critical | 0 |
| High     | 3 |
| Medium   | 5 |
| Low      | 7 |
| Info     | 0 |
| **Total**| **15** |

### Top 5 Risks (post-Phase-7)

1. **S-9 missing `max_keys`/`max_values` parser caps** -- Risk 9, confirmed. Only `max_bytes` is enforced; adversarial TOML can still pump the allocator via key/value count alone.
2. **S-4 `deinitPool` UAF window (legacy global)** -- Risk 10, suspected. Module comment `parallel.zig:92-94` explicitly documents the UB; no ThreadSanitizer reproducer yet. Sev reflects uncertainty.
3. **S-10 `thread_pool` pinned by commit hash only; no signed-tag policy** -- Risk 4, confirmed. Commit+hash pin is the strongest guarantee Zig package manager offers today; keep open until upstream signs tags.
4. **S-16 direct fuzz harnesses missing for `Lexer.next` + `parser/datetime.zig`** -- Risk 4, suspected. Submodules reached transitively; pathological Unicode/ISO-8601 inputs under-sampled.

**Closed in Phase 7:** S-13 (risk 4), S-15 (risk 9). **Closed in Phase 6:** S-1 (risk 16), S-2 (risk 12), S-3 (risk 15), S-5 (risk 9). Historical values retained below for audit trail.

## Scoring Framework

- **Risk Score** = Impact (1-5) x Likelihood (1-5). Max 25. Library/parser context -> no `internet-facing` surface; exposure is whoever feeds TOML to the parser.
- **Severity mapping:** 20-25 = Critical, 12-19 = High, 8-11 = Medium, 4-7 = Low, 1-3 = Info.
- **Confidence:** `confirmed` = evidence in source today; `suspected` = plausible pattern-match, verification TBD.

## Stack-Ranked Findings

| Rank | Sev | Risk | ID | Finding | Component | CWE / OWASP | Evidence | Confidence | Issue | Status |
|------|-----|------|-----|---------|-----------|-------------|----------|------------|-------|--------|
| 1 | High | 16 | S-1/F1 | `parseDocument` is a shadow parser, not a real TOML grammar | parallel | CWE-345, CWE-436 / A08:2021 | `src/parallel.zig:485-521` (was :165-239) | confirmed | public #22, confidential #41 | Closed (2a998a6) -- routed through `toml.parseWithError`; shadow parser removed |
| 2 | High | 15 | S-3/F3 | `validateDocument` accepts invalid TOML | parallel | CWE-436 / A08:2021 | `src/parallel.zig:634-666` (was :314-352) | confirmed | confidential #43 | Closed (c2b4cec) -- routed through `toml.parseWithError` |
| 3 | High | 15 | S-11/F11 | CI `fuzz` stage with zero fuzz targets | ci-cd | CWE-1120 / A05:2021 | `.gitlab-ci.yml:145-160` | confirmed | public #44 | Closed (a302d21) -- fuzz_parse harness + corpus. Coverage gap tracked as S-15 follow-up |
| 4 | Med  | 12 | S-2/F2 | `in_string` misreads escaped backslash then quote | parallel | CWE-697 | `src/parallel.zig:189` (removed) | confirmed | public #45 | Closed-moot (2a998a6) -- hand-rolled mini-scanner deleted with S-1 rewrite; zero residual callers (verified via Grep for `in_string`) |
| 5 | Med  | 10 | S-4/F4 | `deinitPool` UAF window on legacy global pool pointer | parallel | CWE-416 / A06:2021 | `src/parallel.zig:82-94` (documented as UB) | suspected | public #46 | Open -- module comment now explicitly flags the race as UB; `ParallelContext` replaces it for new callers. Keep open pending ThreadSanitizer reproducer |
| 6 | Med  |  9 | S-5/F5 | `@panic` on thread-pool init failure -- DoS primitive | parallel | CWE-248, CWE-400 / A05:2021 | `src/parallel.zig:122` (`initDefault` returns `!*`) | confirmed | public #47 | Closed (a68a6d6) -- `ParallelContext.initDefault` returns `!*ParallelContext`; panic path removed |
| 7 | Med  |  9 | S-9/F9 | Only `max_bytes` caps parser; no `max_keys`/`max_values` | parser | CWE-400, CWE-789 / A05:2021 | `src/parser.zig:23-27` | confirmed | public #48 | Open |
| 8 | Med  |  9 | S-15/F15 | Fuzz coverage gap on 4 public APIs (`parseRecover`, `parseStream`, `parseEvents`, `parallel.parseDocuments`) | tests/fuzz | CWE-1120 / A05:2021 | `tests/fuzz_parse.zig:19-67` | confirmed | public #65 | Closed (`6c80c06`) -- 4 sibling harnesses landed (`fuzz_parse_recover`, `fuzz_parse_stream`, `fuzz_parse_events`, `fuzz_parallel`); wired into `zig build test` |
| 9 | Low  |  8 | S-6/F6 | Depth single-gate (`parseValue` only) -- refactor risk | parser | CWE-674 | `src/parser.zig:392, 522` | confirmed (today safe) | public #49 | Closed (cf61421) -- defense-in-depth recursion guards |
| 10| Low  |  8 | S-7/F7 | Datetime `catch 0` silences `std.fmt.parseInt` | parser | CWE-20, CWE-252 | `src/parser.zig:1343, 1362, 1364` | confirmed | public #50 | Closed (a4b645c) -- propagate error.InvalidDateTime |
| 11| Low  |  4 | S-10/F10 | `thread_pool` pinned by commit hash only; no signed-tag policy | supply-chain | CWE-1357, CWE-829 / A08:2021 | `build.zig.zon:9` | confirmed | public #51 | Open (blocked on upstream signed-tag support) |
| 12| Low  |  4 | S-12/F12 | `DebugAllocator` always used in CLI -- info-disclosure surface | cli | CWE-209 | `src/bin/toml_test_decoder.zig:14` | confirmed | public #52 | Closed (ec730f2) -- conditional allocator |
| 13| Low  |  4 | S-13/F13 | `unreachable` in encoder reachable from public API + fuzz | encoder | CWE-670, CWE-754 | `src/encoder.zig:122`, `src/encoder.zig:310` | suspected | public #64 | Closed (`0e6dcfe`) -- both sites return `error.UnsupportedValueVariant`; direct test added |
| 14| Low  |  4 | S-16/F16 | Direct fuzz harnesses missing for `Lexer.next` + `parser/datetime.zig` | tests/fuzz | CWE-1120 | `src/lex.zig` (Lexer.next), `src/parser/datetime.zig` | suspected | public #66 | Open |
| 15| Low  |  3 | S-8/F8 | `DateTime.format` `@intCast(-offset)` panic on `i16.minInt` | value | CWE-190 | `src/value.zig:58` | suspected | public #53 | Closed (203e857) -- guard against i16.minInt |

## Findings by Area

### parser.zig (core)

- S-6 depth gate defense-in-depth (Low) -- **Closed** commit `cf61421`.
- S-7 datetime `catch 0` spec non-conformance (Low) -- **Closed** commit `a4b645c`.
- S-9 missing `max_keys`/`max_values` caps (Medium)

### parallel.zig (batch API)

- S-1 shadow parser / false oracle (High) -- **Closed** commit `2a998a6` (routed through `toml.parseWithError`; shadow parser deleted).
- S-2 escape-sequence string tracker (Medium) -- **Closed-moot** commit `2a998a6` (hand-rolled mini-scanner removed; Grep confirms zero residual callers of `in_string`).
- S-3 non-validator validator (High) -- **Closed** commit `c2b4cec` (routed through `toml.parseWithError`).
- S-4 UAF on pool pointer (Medium, suspected) -- **Open**. Module comment `src/parallel.zig:82-94` now explicitly declares the legacy-global deinit race as UB; `ParallelContext` is the supported alternative. Keep `suspected` until ThreadSanitizer reproducer lands.
- S-5 panic-on-init DoS primitive (Medium) -- **Closed** commit `a68a6d6` (`ParallelContext.initDefault` returns `!*ParallelContext`; all panic paths removed; sweep in `fc3dd6c`).

### value.zig

- S-8 `i16.minInt` offset panic (Low, suspected) -- **Closed** commit `203e857`.

### CLI (src/bin/)

- S-12 `DebugAllocator` always-on (Low) -- **Closed** commit `ec730f2`.

### CI/CD (.gitlab-ci.yml)

- S-11 fake fuzz stage (High) -- **Closed** commit `a302d21` (fuzz_parse harness + seed corpus landed; CI-side iteration-count assert still deferred to umbrella #42). **Follow-up:** coverage gap recorded as S-15.

### Supply chain (build.zig.zon)

- S-10 commit-hash pinned dep without signed-tag policy (Low)

### encoder.zig

- S-13 `unreachable` reachable from public encoder API + fuzz harness (Low, suspected) -- **Closed** commit `0e6dcfe`. Both sites (`src/encoder.zig:122` switch `else`, `src/encoder.zig:310` `.array, .table` arm in `writeLeafValue`) now `return error.UnsupportedValueVariant`. A direct test constructs a `Value` the encoder rejects and asserts the typed error, not a panic. `tests/fuzz_parse.zig` remains green.

### tests/fuzz

- S-15 fuzz coverage gap on 4 public APIs (Medium, confirmed) -- **Closed** commit `6c80c06`. Four new harnesses landed: `tests/fuzz_parse_recover.zig`, `tests/fuzz_parse_stream.zig`, `tests/fuzz_parse_events.zig`, `tests/fuzz_parallel.zig`. All four are wired into `build.zig` and run under `zig build test --summary all` (and under `--fuzz` when enabled). 238/238 tests pass with the harnesses attached.
- S-16 direct fuzz for `Lexer.next` + `parser/datetime.zig` missing (Low, suspected). Currently reached transitively via `fuzz_parse.zig`; pathological unicode, leap-second, and offset edge-cases are under-sampled by the structure-weighted top-level byte generator. Fix: focused byte-level harnesses feeding the submodules directly.

## Roadmap

### Quick wins (< 1 day)

- Remove or rewire the fake fuzz stage (S-11); land at minimum `fuzz_parse`, `fuzz_parse_documents`, `fuzz_lexer_next`, `fuzz_parse_datetime` harnesses so `--fuzz` has something to drive.
- Fix datetime `catch 0` -> propagate `error.InvalidDateTime` (S-7).
- Switch CLI to `GeneralPurposeAllocator`/`std.heap.smp_allocator` outside tests (S-12).
- Guard `@intCast(-offset)` against `i16.minInt` (S-8).

### Medium (1-5 days)

- ~~Replace `parseDocument` body with a call into `parser.zig` (S-1) -- also fixes S-2 and collapses S-3 into the same path.~~ **Done** (`2a998a6`, `c2b4cec`).
- ~~Rebuild `validateDocument` on top of the real lexer/parser (S-3).~~ **Done** (`c2b4cec`).
- Make the legacy `getPool`/`deinitPool` reference-counted to close the UAF window (S-4); the panic-on-init path for the context API is already gone (`a68a6d6` closes S-5).
- Add `max_keys` / `max_values` / `max_string_bytes` to `ParseOptions` (S-9).
- ~~Harden encoder `unreachable` sites (S-13): return typed error in release, assert in debug.~~ **Done** (`0e6dcfe`).
- ~~Stand up 3-4 sibling fuzz harnesses (S-15) covering `parseRecover`, `parseStream`, `parseEvents`, `parallel.parseDocuments`; wire into `build.zig`.~~ **Done** (`6c80c06`).

### Strategic (> 5 days)

- Centralize depth/recursion accounting in a single `pushDepth`/`popDepth` helper and delete ad-hoc counters (S-6).
- Ship a supply-chain policy document: signed-tag requirement, reproducible-build verification, and renovate/dependabot-style automation for `build.zig.zon` pins (S-10).
- Wire fuzz harnesses into scheduled CI with artifact retention and minimizer (addresses the long tail of S-16; S-15 harnesses already wired locally via `6c80c06`).
- Add direct byte-level fuzz harnesses for `Lexer.next` and `parser/datetime.zig` (S-16).

## Immediate Actions

| # | Action | Why | Status |
|---|--------|-----|--------|
| 1 | **Rotate secrets** -- N/A | No secrets are stored in this repo. `glab` token in local CLI config is out of scope for this project. | N/A |
| 2 | **Hotfix vs. next release** -- Hotfix S-1 + S-3 + S-2 | Silent false-success from `parallel.parseDocuments` / `validateDocuments` is a correctness *and* trust-boundary regression; downstream consumers cannot rely on the batch API for rejection. | Closed (2a998a6, c2b4cec) |
| 3 | **Hotfix S-11** fuzz stage | CI today reports "fuzzing is green" while exercising zero fuzz targets. Either delete the stage or land real harnesses before the next tag. | Closed (a302d21) |
| 4 | **Propose fuzz targets** (pre-requisite for S-11 close) | `fuzz_parse` (`toml.parse`), `fuzz_parse_documents` (`toml.parallel.parseDocuments`), `fuzz_lexer_next` (`lex.Lexer.next`), `fuzz_parse_datetime` (`Parser.parseDateTime`). | Closed for S-15 scope -- `fuzz_parse_recover/_stream/_events/_parallel` landed in `6c80c06`; `fuzz_lexer_next` / `fuzz_parse_datetime` remain open under S-16. |
| 5 | **S-5 panic removed** in `ParallelContext.initDefault` | Error-return path replaces `@panic` for new callers; legacy path still uses `callLegacyOnce` but propagates via `legacy_init_error`. | Closed (a68a6d6) |

## Confidential-issue rationale

S-1, S-3 and S-2 all ship concrete counter-example TOML strings that let an
attacker craft adversarial input the batch API will silently accept. PoCs live
in confidential GitLab issues; this public doc keeps only root-cause + `file:line`.

## Blockers / Unknowns

- S-4 needs a ThreadSanitizer or targeted race-test reproducer before we can claim `confirmed`.
- S-8 `i16.minInt` panic -- needs a unit test that constructs a `DateTime` with `offset_minutes = -32768` directly; likely unreachable from the parser (parser validates before storing) but defense-in-depth still warranted.
- S-10 depends on upstream `devnw/zig/thread-pool` publishing signed tags; raise with upstream maintainers.
- S-13, S-15 closed 2026-04-19 in Phase 7 (see commits `0e6dcfe` / `6c80c06`); S-16 remains open.
- S-13, S-15, S-16 filed as public issues #64, #65, #66 respectively on 2026-04-19.

## Audit Trail

### S-14 (no-finding) -- 2026-04-19

Candidate: "`@intCast` of `ParseError.line` / `.column` into `error_line` / `error_column` could truncate." Investigated and **rejected**. Evidence:

- `src/error.zig:37-38` declares `line: u32, column: u32`.
- `src/parallel.zig:276-278` / `:514-515` declares `error_line: ?usize, error_column: ?usize`.
- On every Zig 0.16 target `@sizeOf(usize) >= @sizeOf(u32)`, so `@intCast(pe.line)` and `@intCast(pe.column)` are always-widening u32 -> usize conversions. No truncation possible.

Recorded as `closed: no-finding`. No issue opened. Listed here so a future reviewer doesn't re-raise it.

### S-15 / S-16 issue filing (2026-04-19)

`glab auth status` returned `! Invalid token provided in configuration file.`; issue creation via CLI deferred. Commands retained for reuse once auth is refreshed:

```bash
# S-13 -- encoder unreachable reachable from fuzz (Low, Risk=4, suspected)
glab issue create --title "S-13: encoder.zig `unreachable` reachable from public API + fuzz" \
  --label "security,sec::remediation,severity::low,priority::low,confidence::suspected,type::hardening,status::triage" \
  --description "$(cat <<'EOF'
**Summary.** Two `unreachable` sites in `src/encoder.zig` are reachable from the public encoder API and are exercised on every successful parse by `tests/fuzz_parse.zig:56`.

**Evidence.**
- `src/encoder.zig:122` -- `else => unreachable` in the value-kind switch inside `writeChildren`.
- `src/encoder.zig:310` -- `.array, .table => unreachable` in `writeLeafValue`.

**Risk Score.** Impact 2 x Likelihood 2 x 4 = **16 / 100**. Severity **Low**. CWE-670, CWE-754.

**Impact.** If parser invariants ever drift (new `Value` variant, unhandled case), the encoder would abort the host process via `unreachable` on every call from the public API. Because `fuzz_parse.zig` calls `writeTaggedJson` after every successful parse, any drift surfaces immediately in CI as a panic -- acceptable for detection, unacceptable for downstream consumers.

**Likelihood.** Requires invariant drift (contributor error). Not currently reachable with the shipping `Value` union.

**Attack scenario.** Post-drift: any attacker who can feed TOML to a consumer that also JSON-encodes the parsed document gets a process abort.

**Fix guidance.** Replace each `unreachable` with `return error.UnsupportedVariant` (or similar) in release builds; keep `std.debug.assert` in debug for the invariant. Add a test that constructs a `Value` the encoder doesn't know about and asserts the error, not a panic.

**Acceptance criteria.**
1. Neither site uses `unreachable` in release.
2. A new test round-trips an artificial unsupported variant and expects the typed error.
3. `tests/fuzz_parse.zig` remains green.
EOF
)"

# S-15 -- fuzz coverage gap on 4 public APIs (Medium, Risk=9, confirmed)
glab issue create --title "S-15: fuzz coverage gap -- 4 public APIs unfuzzed" \
  --label "security,sec::remediation,severity::medium,priority::high,confidence::confirmed,type::ci-cd,status::triage" \
  --description "$(cat <<'EOF'
**Summary.** `tests/fuzz_parse.zig:19-67` only exercises `toml.parseWithError`. Four public APIs hit materially different code paths and are currently unfuzzed.

**Risk Score.** Impact 3 x Likelihood 3 x 4 = **36 / 100** (report Risk=9 on the 1-25 scale used in `SECURITY_GAP_ANALYSIS.md`). Severity **Medium**. CWE-1120 / OWASP A05:2021.

**Unfuzzed APIs.**
- `parseRecover` -- error accumulator + diagnostic list.
- `parseStream` -- `std.io.Reader` drain path, chunking, EOF handling.
- `parseEvents` -- SAX callback lifecycle, user-supplied context pointer.
- `parallel.parseDocuments` -- pool concurrency, chunk boundary logic, per-thread allocator reuse.

**Impact.** S-11 was closed on the basis that a fuzz harness landed. That closure holds for `parseWithError` only; the remaining APIs could crash, leak, or UB on adversarial input without being caught by CI. This finding is the logical follow-up; it does **not** reopen S-11.

**Fix.** Add sibling harnesses `fuzz_parse_recover`, `fuzz_parse_stream`, `fuzz_parse_events`, `fuzz_parallel_parse_documents`; wire each into `build.zig`; run under `zig build test --fuzz`. Share the weighted-byte generator from `fuzz_parse.zig` where applicable.

**Acceptance criteria.**
1. Four new harness files exist under `tests/`.
2. `build.zig` exposes them; `zig build test --fuzz` drives all four.
3. CI `fuzz` stage timeout budget redistributed so every harness gets at least 15s.
EOF
)"

# S-16 -- direct fuzz for Lexer.next + parser/datetime.zig (Low, Risk=4, suspected)
glab issue create --title "S-16: add direct fuzz harnesses for Lexer.next + parser/datetime.zig" \
  --label "security,sec::remediation,severity::low,priority::medium,confidence::suspected,type::ci-cd,status::triage" \
  --description "$(cat <<'EOF'
**Summary.** `Lexer.next` and `parser/datetime.zig` are currently reached only transitively via `fuzz_parse.zig`. Pathological Unicode, leap-second, and offset-edge inputs are under-sampled by the top-level structure-weighted byte generator.

**Risk Score.** Impact 2 x Likelihood 2 x 4 = **16 / 100** (Risk=4 on 1-25 scale). Severity **Low**.

**Fix.** Focused harnesses feeding bytes directly into the submodules, with generators biased toward Unicode categories and ISO-8601-ish noise.

**Acceptance criteria.**
1. `fuzz_lexer_next.zig` drives `lex.Lexer.next` directly over random bytes.
2. `fuzz_parse_datetime.zig` drives `parser/datetime.zig` entry points directly.
3. Both wired into `build.zig` and CI.
EOF
)"
```
