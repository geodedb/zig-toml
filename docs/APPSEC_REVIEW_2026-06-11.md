# Application Security Code Review — `devnw/zig/toml`

**Reviewer role:** Defensive AppSec code review · **Framework:** OWASP Top 10:2025 + CIS Controls v8.1.2
**Date:** 2026-06-11 · **Scope commit:** `e6b3a0f` (branch `main`, v0.1.4) · **Toolchain:** Zig 0.16.0 (min 0.15.1)

---

## 1. Scope and Assumptions

**Reviewed (entire library source tree under `src/`):**
`toml.zig`, `parser.zig`, `parser/{array,datetime,events_sink,inline_table,number,recovery,string,table_path}.zig`, `lexer.zig`, `value.zig`, `parallel.zig`, `encoder.zig`, `encoder_cli.zig`, `schema.zig`, `events.zig`, `json_tagged.zig`, `error.zig`, `bin/{toml_test_decoder,toml_test_encoder}.zig`, plus `build.zig` / `build.zig.zon`.

**Trust boundary (per provided threat model):** untrusted TOML bytes (and untrusted stdin / tagged-JSON for the two CLI binaries) crossing into the parser/encoder. No authn/authz, no network service, no SQL/OS/template sinks. Therefore OWASP categories A01/A04/A05(injection)/A07 are largely **not applicable**; the live attack surface is **memory safety, resource exhaustion, exceptional-condition handling (A10), insecure design (A06), and supply chain (A03)**.

**Methodology:** full read of every file; manual trace of all recursive-descent entrypoints and all fixed-width slice operations; live reproduction by building the CLI binaries (`zig build -Doptimize=Debug`) and feeding crafted inputs to `toml-test-decoder` (stdin → `parse`) and `toml-test-encoder` (stdin → JSON → encode).

**Assumptions:**

- The `thread_pool` dependency (pinned by tag + commit SHA + content hash) is out of scope for internal review; treated as trusted per its pin.
- The stale `docs/SECURITY_GAP_ANALYSIS.md` (2026-04-19) was **not** trusted; all findings are substantiated against current source.
- Library is source-distributed; consumers may build any optimize mode. Findings note the difference between safe modes (panic) and `ReleaseFast`/`ReleaseSmall` (UB).

**Confidence:** High. Both substantive findings were reproduced with concrete crashing inputs and backtraces.

---

## 2. Executive Summary

- **Two confirmed, attacker-reachable crashes from tiny untrusted inputs.** Both are reachable through the **primary public `parse`/`parseWithError` API** and through **both CLI binaries**. They are availability/robustness defects (DoS); calibrated to a no-network parsing library they are **Medium**, but they directly undermine the library's advertised "safe parsing with resource caps" contract and would crash any service worker that parses attacker-supplied TOML.
- **APP-01 (Medium):** Datetime/local-datetime parsers slice fixed-width fields (`raw[i..i+4]`, `raw[i..i+2]`) **without bounds checks**. A truncated datetime token such as `d = 1234-12:` triggers an out-of-bounds slice → **panic (SIGABRT) in Debug/ReleaseSafe, out-of-bounds heap read (UB) in ReleaseFast**. Confirmed on decoder + encoder CLIs.
- **APP-02 (Medium):** `mergeTables` (dotted keys inside inline tables) is an **unbounded recursive function not guarded by `max_depth`**, and dotted-key path length is itself uncapped. Input `x = { a.a…a = 1, a.a…a = 2 }` causes a **stack-overflow segfault** (~30k recursive frames reproduced) with **default options** — a direct `max_depth` bypass.
- **The answer to threat-model Q1 is "No."** `max_depth` is correctly enforced on every *parse-recursion* entrypoint (`parseValue`, `parseArray`, `parseArrayContents`, `parseNestedArrayFromDoubleBracket`, `parseInlineTable`), but `mergeTables` recurses over already-built structure with no guard (APP-02).
- **Otherwise the library is well-defended.** UTF-8 validation is correct and bounds-checked; integer/float parsing delegates to overflow-checked `std.fmt`; the lexer's `peek`/`lookAhead` return `0` on truncation; the arena ownership model avoids use-after-free; the `parallel.zig` concurrency hazards are confined to an explicitly-deprecated legacy global API; the encoder replaced former `unreachable` panics with typed errors. No injection, no secrets, no crypto, no auth surface.
- **Supply chain (A03) is healthy:** the single dependency is pinned by immutable commit SHA + Zig content hash; CI runs SAST/dependency/secret scanning + SBOM per the deployment notes.

---

## 3. Findings Table

| ID | Severity | Confidence | Title | Location | OWASP 2025 | Status |
|----|----------|-----------|-------|----------|-----------|--------|
| APP-01 | Medium | High | Out-of-bounds slice in datetime parsing on truncated tokens (panic / OOB read) | `src/parser/datetime.zig:52,58,64,85,91` | A10 (CWE-125 / CWE-1284) | Confirmed (reproduced) |
| APP-02 | Medium | High | Unbounded recursion in `mergeTables` bypasses `max_depth` → stack overflow | `src/parser/inline_table.zig:247-267` (+ `parser.zig:354` uncapped path) | A06 (CWE-674) | Confirmed (reproduced) |
| APP-03 | Low | High | Deprecated legacy global pool retains documented UAF / data-race | `src/parallel.zig:235-257` | A06 / A04-integrity (CWE-416) | Confirmed (by design, deprecated) |
| APP-04 | Low | Medium | Batch APIs fan a single caller allocator across worker threads | `src/parallel.zig:380-385,391-415,451-483` | A06 (CWE-362) | Confirmed (documented contract) |

---

## 4. Finding Details

### APP-01 — Out-of-bounds slice in datetime parsing on truncated tokens — Medium (High)

**Location:** `src/parser/datetime.zig` — `parseDateParts` (lines 52, 58, 64) and `parseTimeParts` (lines 85, 91); reached from `parseDateTime` (line 188) and `parseDateTimeLocal` (line 220).

**Evidence.** `parseDateParts` slices fixed windows with no length guard:

```zig
const year  = std.fmt.parseInt(u16, raw[i .. i + 4], 10) ...; i += 5;
const month = std.fmt.parseInt(u8,  raw[i .. i + 2], 10) ...; i += 3;
const day   = std.fmt.parseInt(u8,  raw[i .. i + 2], 10) ...;   // raw[8..10]
```

`parseTimeParts` does the same for hour/minute (lines 85, 91). Critically, `parseDateTime`/`parseDateTimeLocal` call these **without** a length precheck — unlike `parseDateLocal` (line 249, `if (raw.len != 10)`) and `parseTimeLocal` (line 266, `if (raw.len < 5)`), which *do* precheck and are therefore safe. The lexer classifies any run containing a dash + colon as `.datetime`/`.datetime_local` (`lexer.zig:508-515`) **without enforcing a minimum length**, so short tokens reach the unguarded slicers.

**Reproduction (live, against `zig-out/bin/toml-test-decoder`, Debug build):**

```text
$ printf 'd = 1234-12:\n'        | toml-test-decoder   # → exit 134
thread panic: index out of bounds: index 10, len 8
  src/parser/datetime.zig:64  (parseDateParts, day = raw[8..10])
$ printf 'd = 1234-12:Z\n'       | toml-test-decoder   # → exit 134 (len 9)
$ printf 'd = 2020-01-01T01:\n'  | toml-test-decoder   # → exit 134
thread panic: index out of bounds: index 16, len 14
  src/parser/datetime.zig:91  (parseTimeParts, minute = raw[14..16])
```

Also reproduced through the **encoder CLI** (a datetime literal is re-parsed via the real parser at `encoder_cli.zig:121-133`):

```text
printf '{"d":{"type":"datetime-local","value":"1234-12:"}}' | toml-test-encoder  # → exit 134
```

**Attack scenario (non-destructive).** Any application that calls `toml.parse`/`parseWithError`/`parseRecover`/`parseStream`/`parseEvents`, or runs either CLI, on attacker-influenced TOML is aborted by a 12-byte input. Because the fault is a Zig panic (not a catchable error), even **recover mode** (`parseRecover`) crashes. In `ReleaseFast`/`ReleaseSmall` (bounds checks elided) this becomes a genuine **out-of-bounds heap read** (CWE-125) of 1–2 bytes past the arena-owned input copy; the read bytes are discarded on the ensuing parse error, so no data-exfiltration was demonstrated, but it is undefined behavior and may fault on a page boundary.

**Impact.** Denial of service (process abort) on the primary parse path and both CLIs; OOB read / UB in unsafe build modes. Defeats the library's resource-cap safety contract.

**Root cause.** Fixed-width field slicing without per-slice bounds validation, combined with absent length precheck in the offset-datetime / local-datetime entrypoints (an inconsistency vs. the date-local / time-local entrypoints, which do precheck).

**Remediation (minimal, matches existing patterns).** Add length guards before slicing — mirroring the existing `parseDateLocal`/`parseTimeLocal`/`parseOffset` style:

```zig
fn parseDateParts(self: *Parser, raw: []const u8, idx: usize) !DateParts {
    if (idx + 10 > raw.len) {
        self.parse_error = err.makeError(.InvalidDateTime, self.current.pos, "truncated date");
        return error.ParseFailed;
    }
    // ...existing slicing...
}
fn parseTimeParts(self: *Parser, raw: []const u8, idx: usize, ...) !TimeParts {
    if (idx + 5 > raw.len) {           // covers hour raw[idx..idx+2] and minute raw[idx+3..idx+5]
        self.parse_error = err.makeError(.InvalidDateTime, self.current.pos, "truncated time");
        return error.ParseFailed;
    }
    // ...existing slicing...
}
```

(The seconds branch at line 101 and `parseOffset` at line 163 already bounds-check; only the date and hour/minute slices need guards.)

**Regression tests.** Add cases that must return `.err`/`error.ParseFailed` (never panic): `d = 1234-12:`, `d = 1234-12:Z`, `d = 2020-01-01T01:`, `d = 2020-01-01T01:02:`, `d = 0000-0`, plus a fuzz target that feeds truncations of every valid datetime token at every prefix length.

**Mappings.** OWASP A10 (Mishandling of Exceptional Conditions); CWE-125 (Out-of-bounds Read), CWE-1284 (Improper Validation of Specified Quantity). CIS v8.1.2 16.1 (secure development process), 16.11 (vetted, safe handling), 16.13 (application fuzz/security testing).

---

### APP-02 — Unbounded recursion in `mergeTables` bypasses `max_depth` → stack overflow — Medium (High)

**Location:** `src/parser/inline_table.zig:247-267` (`mergeTables`), reached from `parseInlineTableBody:164`; enabled by uncapped dotted-key path expansion in `Parser.parseKeyPath` (`src/parser.zig:354-389`).

**Evidence.** `parseKeyPath` appends path segments in a `while (true)` loop **with no length cap**. Inside an inline table, a dotted key builds a nested-table chain of depth = path length via a flat loop (`inline_table.zig:140-153`, each table charged once against `max_values`). When a *second* dotted key shares the same root, `mergeTables` is invoked and recurses over the two chains:

```zig
pub fn mergeTables(alloc, target, source) ... {
    var it = val.tableIterator(source);
    while (it.next()) |src_entry| {
        if (target.table.map.get(src_entry.key)) |tgt_value| {
            ...
            try mergeTables(alloc, tgt_value, src_entry.value);   // line 262 — no depth guard
        } ...
    }
}
```

`mergeTables` never calls `enterDepth()`. The `max_depth=128` cap only constrains *lexical* nesting (the input below has lexical depth 2 — a single inline table), so it never trips. With the default `max_values=500_000`, two ~250k-segment dotted keys are buildable, and the merge then recurses ~250k deep.

**Reproduction (live, default options, against `toml-test-decoder`):**

```text
$ python3 -c 'N=200000;s="a."*N+"a";import sys;sys.stdout.write("x = { "+s+" = 1, "+s+" = 2 }\n")' \
    | toml-test-decoder
Segmentation fault at address 0x7ffc17f9af78
  src/parser/inline_table.zig:262  in mergeTables   (×~30000 recursive frames)
```

The 800 KB input is far under the 16 MiB `max_bytes` cap; the crash is a stack overflow (~30,000 `mergeTables` frames before the 8 MB stack is exhausted).

**Attack scenario.** A single ~1 MB TOML document with two deeply-dotted sibling keys inside an inline table crashes any consumer of `parse`/`parseWithError`/`parseRecover`/`parseStream` and both CLIs. Default options do not protect against it because the relevant cap (`max_depth`) is not applied to dotted-key path length or to `mergeTables` recursion.

**Impact.** Denial of service via uncontrolled recursion (stack overflow). Bypasses the documented resource-cap defense.

**Root cause.** `max_depth` guards parse recursion but not (a) dotted-key path length in `parseKeyPath`, nor (b) the structural recursion in `mergeTables`.

**Remediation (any one closes it; option A is smallest and also bounds memory):**

- **A — cap path depth in `parseKeyPath`:** reject paths longer than `options.max_depth` segments (`return LimitExceeded`). This also prevents the large allocation up front.
- **B — guard `mergeTables`** with an explicit depth counter (or thread `self`/`enterDepth` through it) that returns `LimitExceeded` past `max_depth`.
- **C — make `mergeTables` iterative** with an explicit work stack bounded by `max_depth`.

**Regression tests.** `x = {` + deep + ` = 1, ` + deep + `= 2 }` with depth > `max_depth` must return `ErrorCode.LimitExceeded` (not crash); add a small-`max_depth` variant analogous to the existing "U-H deep nested inline tables rejected" test in `toml.zig:572`.

**Mappings.** OWASP A06 (Insecure Design — incomplete resource cap), adjacent A10; CWE-674 (Uncontrolled Recursion), CWE-1284. CIS v8.1.2 16.1, 16.11, 16.13.

---

### APP-03 — Deprecated legacy global pool retains documented UAF / data-race — Low (High)

**Location:** `src/parallel.zig:235-257` (`getPool`, `deinitPool`), legacy globals lines 206-209.

**Evidence.** `getPool()` returns a raw `*tp.ThreadPool` into the process-global `legacy_ctx`; `deinitPool()` frees that context and resets `legacy_done` while other threads may still hold the returned pointer. The module header (lines 61-94) and the function docs explicitly document this as **undefined behavior** and **deprecated for removal in 0.3.0**, and provide the safe caller-owned `ParallelContext` alternative (Q-4/S-4/S-5/P-7 remediations are already in place — the panic-on-OOM was removed, the pointer is no longer observable without a live context, etc.).

**Why Low.** Not reachable from untrusted TOML input; the unsafe behavior requires a *consumer* to (a) use the deprecated free-function/`getPool` API and (b) call `deinitPool` concurrently with in-flight users. No attacker-controlled trigger.

**Remediation.** Proceed with the planned 0.3.0 removal; in the interim, mark `getPool`/`deinitPool` with `@compileError`-gated deprecation or a build flag, and ensure README/API docs steer all callers to `ParallelContext`.

**Mappings.** OWASP A06 / A08; CWE-416 (Use After Free), CWE-362 (Race Condition). CIS v8.1.2 16.1, 16.4 (trusted/secure components).

---

### APP-04 — Batch APIs fan a single caller allocator across worker threads — Low (Medium)

**Location:** `src/parallel.zig` — `parseChunkTask:380`, `parseDocumentsCtx:391`, `parseDocuments:451` (and the `parseDocument` worker at 485). Each worker thread calls `toml.parseWithError(chunk.allocator, …)` with the **same** caller-supplied allocator concurrently.

**Evidence.** The code documents (lines 372-379) that the allocator "must be safe for concurrent access," but the public `parseDocuments*` entrypoints accept *any* `std.mem.Allocator` and silently switch to parallel execution at ≥4 inputs. A consumer that passes a non-thread-safe allocator (e.g., a bare `ArenaAllocator` or non-thread-safe GPA) gets concurrent allocator calls → data race / heap corruption (CWE-362). `validateDocuments`/`extractKeys` avoid this by using internal `page_allocator` arenas; only the *parse* path forwards the caller allocator.

**Why Low.** Documented contract; consumer-misuse, not attacker-controlled; no exposure from TOML content itself.

**Remediation.** Make the thread-safety requirement loud at the API boundary (doc-comment on the public `parseDocuments` signatures, not only the internal worker), and/or wrap the caller allocator in a thread-safe shim internally before fan-out.

**Mappings.** OWASP A06; CWE-362. CIS v8.1.2 16.1, 16.10 (secure design principles).

---

## 5. Secure Design Notes (positive controls observed)

- **Resource caps are comprehensive on the parse-recursion path.** `enterDepth`/`exitDepth` are correctly placed (with `defer`) on **all** recursive-descent entrypoints — `parseValue` (`parser.zig:442`), `parseArray`/`parseArrayContents`/`parseNestedArrayFromDoubleBracket` (`array.zig:50,103,158`), `parseInlineTable` (`inline_table.zig:51`) — with defense-in-depth comments. `max_bytes` (16 MiB), `max_keys` (100k), `max_values` (500k) are charged at every allocation/key site and short-circuit oversize input up front (`parser.zig:119-175`, `parseEvents:623`, recovery `recovery.zig:65`). The only gaps are APP-01/APP-02.
- **UTF-8 validation is hand-rolled, correct, and fully bounds-checked** (`lexer.zig:623-672`): rejects overlong forms, surrogates, >U+10FFFF, truncated tails, and orphan continuation bytes, with precise line/column. Verified by the existing positive/negative test suite.
- **Integer/float/datetime numeric conversion delegates to overflow-checked `std.fmt`** (`number.zig`), so there is **no manual multiply-accumulate overflow** anywhere (threat-model Q3 = clean). Fractional-second normalization (`datetime.zig:128-135`) is bounded (≤9 digits, `u32`-safe). `DateTime.format` even defends against a hand-constructed `i16.minInt` offset via `@abs` (`value.zig:58-67`).
- **Lexer truncation safety:** `peek()` and `lookAhead()` return `0` past end (`lexer.zig:565-574`); `advance()` no-ops at EOF; all token slices use `[start..pos]` with `pos <= len`. The only place that indexes a window without a precheck is the datetime parser (APP-01) — the lexer itself is clean (threat-model Q5: no unchecked indexing in the lexer).
- **Memory ownership is arena-based and UAF-resistant.** `Document.deinit` (`value.zig:426`) drops a single arena (no recursive free, no double-free); input is duped into the arena (P-5) so the caller may free the source before `deinit` (test at `toml.zig:620`). `validateDocument`/`extractKeysFromDocument` correctly avoid double-freeing the nested parser arena.
- **`unreachable`/`@panic` are not reachable from untrusted input** (threat-model Q2): the only non-test `unreachable`/`@panic` are in comments or a test helper; the encoder deliberately **replaced** former `unreachable` sinks with typed `error.UnsupportedValueVariant` returns (`encoder.zig:126,317`, S-13). The `std.debug.assert(... == .table/.array)` sites operate on parser-built ASTs whose tags are invariant for the dispatched path.
- **`parallel.zig` concurrency was hardened:** the caller-owned `ParallelContext` removed the prior global-pool UAF/OOM-panic for the supported API; `runBatch` keeps per-chunk state on the stack and `wg.wait()`s before returning (no stack-escape), and writes only to disjoint `results[i]` slices.
- **Supply chain (A03) is well-managed:** the lone `thread_pool` dependency is pinned in `build.zig.zon` by tag **and** immutable commit SHA **and** Zig content hash (integrity-verified by the package manager); deployment notes confirm CI runs SAST, dependency scanning, secret scanning, gitleaks, and SBOM generation/scan. No secrets, credentials, or PII in source.
- **CLI input is DoS-bounded at the boundary:** both binaries cap stdin at 16 MiB (`bin/*.zig:47,52`) and use leak-tracking allocators only in Debug, explicitly to avoid leaking allocator metadata into diagnostics (CWE-209 noted in-code). Neither decoder nor encoder takes file-path arguments — they read stdin only, so the path-traversal concern in the threat model has no surface here.

---

## 6. Coverage Gaps and Questions

- **`ReleaseFast`/`ReleaseSmall` behavior of APP-01 not exhaustively characterized.** Confirmed the Debug/ReleaseSafe panic; in unsafe modes the same slice is an OOB heap read (UB). Cross-allocation information disclosure not demonstrated (read bytes discarded on parse error), so APP-01's data-confidentiality impact is assessed low but not formally excluded for adversarial allocator layouts.
- **Encoder/schema/decode recursion on *consumer-built* Documents.** `encoder.writeTableBody`/`writeAnyValue`, `schema.validateNode`, and `schema.decodeValue` are recursive. For *parsed* input they are bounded by `max_depth` (≤128). A consumer that hand-builds a very deep `Document` via the public mutation API (`Document.setPath`, `tableSetOwned`, `arrayAppendOwned`) and then calls `encode`/`validate`/`decode` could overflow the stack — out of the parsing threat model, but worth a documented depth limit or iterative rewrite. (`Document.setPath` itself caps at 64 segments — `value.zig:475` — but `setPathSegments` does not.)
- **`encoder_cli` JSON nesting depth** relies on `std.json.parseFromSlice`'s default nesting cap to bound `jsonToValue` recursion (`encoder_cli.zig:33`). std.json depth limit on 0.16 not independently verified; recommend an explicit `std.json.Scanner` depth bound for the encoder CLI to be self-sufficient.
- **Fuzzing coverage.** The repo has strong characterization/differential tests but no evidence of a continuous fuzz target over the parser/encoder. APP-01 and APP-02 are exactly the class a coverage-guided fuzzer (e.g., a `std.testing.fuzz` harness over `parse`) would have surfaced.
- **Not reviewed:** the `tests/` corpus harness internals, `docs/`, and the `thread_pool` dependency source (trusted by pin).

**Open question for the maintainer:** does the CI `toml-test` differential corpus already include truncated-datetime invalid cases? If so, APP-01 may already be producing intermittent CI aborts under ReleaseSafe.

---

## 7. Prioritized Next Actions

1. **Fix APP-01** — add the two length guards in `parseDateParts`/`parseTimeParts` (or a `raw.len` precheck in `parseDateTime`/`parseDateTimeLocal`). Add the truncated-datetime regression cases. *(Smallest patch; removes a one-line crash on the primary API + both CLIs.)*
2. **Fix APP-02** — cap dotted-key path length by `max_depth` in `parseKeyPath` (preferred: also bounds memory) and/or guard `mergeTables` recursion. Add the deep-dotted-key regression test. *(Closes the `max_depth` bypass with default options.)*
3. **Add a fuzz target** over `toml.parse` (and `encoder_cli.runEncodePipeline`) wired into CI to catch this class going forward (CIS 16.13).
4. **APP-04** — surface the thread-safe-allocator requirement at the public `parseDocuments*` signatures, or wrap the allocator internally before fan-out.
5. **APP-03** — complete the planned 0.3.0 removal of `getPool`/`deinitPool`; gate or hard-deprecate in the interim.
6. **Hardening** — document (or enforce) a depth bound for `encode`/`schema.decode` on consumer-built Documents, and give `encoder_cli` an explicit JSON nesting bound.

**Overall assessment:** No injection, secret-exposure, crypto, auth, or supply-chain vulnerabilities were found in the reviewed scope. The library is carefully written with thorough resource caps and memory-safety discipline; the two confirmed defects are localized completeness gaps in those very caps (an unchecked datetime slice and an unguarded merge recursion) and both have small, low-risk fixes that fit the existing code patterns.
