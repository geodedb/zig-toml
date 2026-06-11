# Audit Closure (2026-06-11 iteration 1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close every genuinely-open, actionable finding from the 2026-06-11 fresh appsec review (`docs/APPSEC_REVIEW_2026-06-11.md`) and the refreshed gap/quality/perf audit, with tests proving each fix.

**Architecture:** TOML parser library in Zig 0.16 (min 0.15.1). Fixes are surgical: bounds guards + a depth cap close two confirmed parser crashes; small allocator/number fast-paths close confirmed perf gaps; CI jobs + doc reconciliation close the remaining tracked gaps. Every code change is gated by `zig build test` (243 tests today) + `zig fmt --check src`.

**Tech Stack:** Zig std only; one dep (`thread_pool` v0.2.5). Tests are inline `test {}` blocks in `src/*.zig` and integration suites under `tests/`. Build via `zig build`; tests via `zig build test --summary all`.

**Verification command (run after every task):**

```text
cd /data/home/benji/src/gl/gitlab.com/devnw/zig/toml
zig build test --summary all && zig fmt --check src
```

---

## Findings → Tasks map

| Finding | Severity | Task |
|---|---|---|
| APP-01 datetime OOB slice (crash) | Med (sec) | 1 |
| APP-02 mergeTables recursion / uncapped dotted path (crash) | Med (sec) | 2 |
| GAP-0024 spurious "failed command" test banner | Med (gap) | 3 |
| P-NEW-2 number scratch alloc when no `_` | P2 (perf) | 4 |
| P-NEW-5 / P-16 recover-path UTF-8 double-pass | P3 (perf) | 5 |
| P-NEW-4 duplicate-key double hash probe | P3 (perf) | 6 |
| Q-23 9 internal-only `pub` helpers | Low (qual) | 7 |
| Q-NEW-1 version/CHANGELOG drift + hygiene test | Low-Med (qual) | 8 |
| GAP-0004 conformance CI not blocking merge | High (gap) | 9 |
| GAP-0018/0019 no Windows/macOS CI | Med (gap) | 10 |
| Doc reconciliation (resolved + deferred items) | — | 11 |

Deferred-with-rationale (recorded in Task 11, not code-changed this iteration): APP-03 (deprecated legacy pool, slated 0.3.0 removal), APP-04 (consumer-misuse doc note — add doc-comment in Task 11), P-15 (needs flamegraph), P-NEW-1/P-NEW-3/P-NEW-6 (invasive allocator restructures — separate perf plan), Q-21 (schema split, internals clean), Q-NEW-2 (cosmetic long fn).

---

### Task 1: APP-01 — bounds-guard fixed-width datetime slices

**Files:**

- Modify: `src/parser/datetime.zig:49-71` (`parseDateParts`), `src/parser/datetime.zig:77-95` (`parseTimeParts` hour/minute)
- Test: add to `tests/api_v1_2.zig` (new test block) OR `src/parser.zig` test section — use `src/parser/datetime.zig` bottom `test` block (already has datetime tests near line 290+).

**Root cause:** `parseDateParts`/`parseTimeParts` slice `raw[i..i+4]` / `raw[i..i+2]` with no length check; `parseDateTime`/`parseDateTimeLocal` call them with no `raw.len` precheck (unlike `parseDateLocal`/`parseTimeLocal`). A truncated token (`1234-12:`) → OOB slice → panic (Debug/Safe) / OOB read (Fast).

- [ ] **Step 1: Write failing tests** (append to the `test` section at the end of `src/parser/datetime.zig`):

```zig
test "APP-01 truncated datetime tokens error, never panic" {
    const toml = @import("../toml.zig");
    const cases = [_][]const u8{
        "d = 1234-12:\n",
        "d = 1234-12:Z\n",
        "d = 2020-01-01T01:\n",
        "d = 2020-01-01T01:02:\n",
        "d = 0000-0\n",
        "d = 1234-1\n",
    };
    for (cases) |src| {
        const r = toml.parseWithError(std.testing.allocator, src, .{});
        defer r.deinit(std.testing.allocator);
        try std.testing.expect(r == .err); // must be a clean error, not a crash
    }
}
```

- [ ] **Step 2: Run, expect failure**

Run: `zig build test --summary all`
Expected: process aborts with `thread panic: index out of bounds` from `src/parser/datetime.zig` (proves the bug).

- [ ] **Step 3: Add the length guards.** In `parseDateParts`, insert immediately after `var i: usize = idx;` (line 50):

```zig
    // APP-01: YYYY-MM-DD needs exactly 10 chars from idx (year raw[i..i+4],
    // month raw[i+5..i+7], day raw[i+8..i+10]). Guard before slicing.
    if (idx + 10 > raw.len) {
        self.parse_error = err.makeError(.InvalidDateTime, self.current.pos, "truncated date");
        return error.ParseFailed;
    }
```

In `parseTimeParts`, insert immediately after `var i: usize = idx;` (line 83):

```zig
    // APP-01: HH:MM needs 5 chars from idx (hour raw[i..i+2], minute
    // raw[i+3..i+5]). The optional :SS / .frac tails already bounds-check.
    if (idx + 5 > raw.len) {
        self.parse_error = err.makeError(.InvalidDateTime, self.current.pos, "truncated time");
        return error.ParseFailed;
    }
```

- [ ] **Step 4: Run, expect pass**

Run: `zig build test --summary all && zig fmt --check src`
Expected: all tests pass (now 244+), no panic.

- [ ] **Step 5: Commit**

```bash
git add src/parser/datetime.zig
git commit -m "fix(parser): bounds-guard truncated datetime tokens (APP-01)

Truncated datetime/local-datetime literals (e.g. '1234-12:') reached the
fixed-width slicers in parseDateParts/parseTimeParts with no length
precheck, causing an out-of-bounds slice -> panic (Debug/ReleaseSafe) or
OOB heap read (ReleaseFast). Add length guards mirroring the existing
parseDateLocal/parseTimeLocal/parseOffset prechecks. Confirmed crash now
returns a clean ParseFailed/.err.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: APP-02 — cap dotted-key path depth (closes mergeTables stack overflow)

**Files:**

- Modify: `src/parser.zig:354-389` (`parseKeyPath`) — add a depth check helper + calls.
- Test: bottom `test` section of `src/parser.zig` (has parser tests) or `src/toml.zig` near the existing "U-H deep nested inline tables rejected" test (`toml.zig:572`).

**Root cause:** `parseKeyPath` appends segments with no cap; a dotted key with ~250k segments builds a 250k-deep nested-table chain, and a sibling dotted key triggers `mergeTables` recursion ~250k deep → stack-overflow segfault with default options. Capping path length at `max_depth` bounds both the chain build and the merge recursion (≤128 frames).

- [ ] **Step 1: Write failing test** (append to `src/toml.zig` test section, near line 572):

```zig
test "APP-02 deeply-dotted inline keys rejected, no stack overflow" {
    const a = std.testing.allocator;
    // depth far above default max_depth (128); two siblings force a merge.
    const N = 5000;
    var buf = std.ArrayList(u8){};
    defer buf.deinit(a);
    try buf.appendSlice(a, "x = { ");
    for (0..2) |dup| {
        if (dup == 1) try buf.appendSlice(a, ", ");
        for (0..N) |k| {
            if (k != 0) try buf.append(a, '.');
            try buf.append(a, 'a');
        }
        try buf.appendSlice(a, " = 1");
    }
    try buf.appendSlice(a, " }\n");

    const r = parseWithError(a, buf.items, .{});
    defer r.deinit(a);
    try std.testing.expect(r == .err); // LimitExceeded, not a segfault
}
```

- [ ] **Step 2: Run, expect failure**

Run: `zig build test --summary all`
Expected: `Segmentation fault` in `mergeTables` (proves the bug). (If 5000 isn't deep enough to overflow but the cap rejects it, the test still passes after the fix — the assertion is `.err`. The pre-fix run should still segfault at higher N; if 5000 doesn't segfault pre-fix it will at least exercise the path. Bump N to 200000 to force the pre-fix segfault if needed.)

- [ ] **Step 3: Add the cap.** In `src/parser.zig`, add this private method right after `parseKeyPath` (after line 389):

```zig
    /// APP-02: bound dotted-key path length by max_depth. A path of length
    /// L builds an (L-1)-deep nested-table chain and bounds mergeTables
    /// recursion to <= L frames; capping L prevents stack-overflow DoS and
    /// the associated unbounded arena allocation.
    fn checkKeyPathDepth(self: *Parser, len: usize) !void {
        if (len > self.options.max_depth) {
            self.parse_error = err.makeError(.LimitExceeded, self.current.pos, "dotted key path exceeds max nesting depth");
            return error.ParseFailed;
        }
    }
```

Then add `try self.checkKeyPathDepth(path.items.len);` after EACH `path.append` in `parseKeyPath`:

- after `try path.append(alloc, text[0..dot_pos]);` (line 362)
- after `try path.append(alloc, rest[0..next_dot]);` (line 366, inside inner while)
- after `try path.append(alloc, rest);` (line 369)
- after `try path.append(alloc, key);` (line 381)

- [ ] **Step 4: Run, expect pass**

Run: `zig build test --summary all && zig fmt --check src`
Expected: all tests pass; APP-02 test returns `.err`.

- [ ] **Step 5: Commit**

```bash
git add src/parser.zig
git commit -m "fix(parser): cap dotted-key path depth at max_depth (APP-02)

A dotted key with hundreds of thousands of segments built a same-depth
nested-table chain; a sibling dotted key then drove mergeTables recursion
deep enough to overflow the stack (segfault) under DEFAULT options -- a
max_depth bypass, since max_depth only constrained lexical nesting. Cap
path length at options.max_depth in parseKeyPath, which bounds both the
chain construction and the mergeTables recursion to <=128 frames.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: GAP-0024 — silence spurious "failed command" test banner

**Files:**

- Modify: `tests/differential.zig:135,141` (two `std.debug.print` calls)

**Root cause:** `std.debug.print` writes to stderr; Zig's run-artifact driver flags any stderr emission as a "failed command", printing a confusing banner on every green test run.

- [ ] **Step 1: Reproduce** — Run `zig build test --summary all 2>&1 | grep -n "failed command"`; expect a non-empty match (the banner) despite all tests passing.

- [ ] **Step 2: Fix** — Replace the two `std.debug.print("valid corpus: {d} cases\n", ...)` / `("invalid corpus: {d} cases\n", ...)` calls at `tests/differential.zig:135,141` with `std.log.debug(...)` (suppressed at default log level), or delete them if they were dev scaffolding. Prefer `std.log.debug` to preserve the diagnostic when `-Dlog-level` is raised.

- [ ] **Step 3: Verify** — `zig build test --summary all 2>&1 | grep "failed command"` returns empty; `zig build test --summary all` still green.

- [ ] **Step 4: Commit**

```bash
git add tests/differential.zig
git commit -m "test: silence spurious 'failed command' banner in differential (GAP-0024)

std.debug.print writes to stderr, which the run-artifact driver treats as
a command failure and reports on every green run. Switch to std.log.debug
(suppressed at default level). Closes GAP-0024.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: P-NEW-2 — no-underscore fast path in integer/float parsing

**Files:**

- Modify: `src/parser/number.zig` (`parseInteger` ~line 19, `parseFloat` ~line 160) — read the file first to confirm exact line numbers and the scratch-buffer construction.

**Root cause:** Both always `initCapacity` a scratch buffer and copy to strip `_`, even when the literal has no `_` (the common case). For an underscore-free literal, parse the original slice directly.

- [ ] **Step 1: Write failing/characterization test** (append to `src/parser/number.zig` test section): assert parse correctness for `1234`, `1_2_3_4`, `3.14`, `1_000.000_1`, negative `-42`, hex/oct/bin `0xFF`, `0o17`, `0b1010` all still parse to the right value (guards the fast-path doesn't change results). This is a green-stays-green test; the perf win is verified separately by bench.

```zig
test "P-NEW-2 number fast-path correctness (with and without underscores)" {
    const toml = @import("../toml.zig");
    const a = std.testing.allocator;
    const Case = struct { src: []const u8, key: []const u8 };
    // value checks via the public API
    {
        const doc = try toml.parse(a, "a = 1234\nb = 1_2_3_4\nc = 0xFF\nd = 0b1010\n", .{});
        defer doc.deinit();
        try std.testing.expectEqual(@as(i64, 1234), doc.root.table.map.get("a").?.integer);
        try std.testing.expectEqual(@as(i64, 1234), doc.root.table.map.get("b").?.integer);
        try std.testing.expectEqual(@as(i64, 255), doc.root.table.map.get("c").?.integer);
        try std.testing.expectEqual(@as(i64, 10), doc.root.table.map.get("d").?.integer);
    }
    {
        const doc = try toml.parse(a, "e = 3.14\nf = 1_000.000_1\n", .{});
        defer doc.deinit();
        try std.testing.expect(@abs(doc.root.table.map.get("e").?.float - 3.14) < 1e-9);
        try std.testing.expect(@abs(doc.root.table.map.get("f").?.float - 1000.0001) < 1e-9);
    }
}
```

- [ ] **Step 2: Run, expect pass** (characterization baseline). `zig build test --summary all`.

- [ ] **Step 3: Implement fast path.** Read `src/parser/number.zig`; in `parseInteger`, before allocating the `clean` scratch list, add: if the digit-body slice contains no `_` (`std.mem.indexOfScalar(u8, body, '_') == null`), pass the original slice straight to `std.fmt.parseInt` (preserving existing sign/radix handling) and return. Mirror in `parseFloat` with `std.fmt.parseFloat`. Keep the underscore path byte-identical.

- [ ] **Step 4: Run, expect pass** — `zig build test --summary all && zig fmt --check src`. All green (correctness unchanged).

- [ ] **Step 5: (optional) measure** — `zig build bench-parse_large -Doptimize=ReleaseFast` before/after; expect lower `bytes_total`.

- [ ] **Step 6: Commit**

```bash
git add src/parser/number.zig
git commit -m "perf(number): skip scratch alloc for underscore-free literals (P-NEW-2)

parseInteger/parseFloat always allocated a scratch buffer to strip '_'.
Most literals have none; detect that with indexOfScalar and parse the
original slice directly, removing a 64-128B alloc + memcpy per number on
the common path. Correctness covered by new value-equality tests.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: P-NEW-5 / P-16 — drop redundant UTF-8 pre-pass in recover mode

**Files:**

- Modify: `src/parser/recovery.zig:57` (the `std.unicode.utf8ValidateSlice` pre-pass)

**Root cause:** `parseRecoverDocument` validates UTF-8 in a full O(n) pass before lexing, but the lexer already validates UTF-8 inline (`Lexer.advance`) and returns `InvalidUtf8`. The pre-pass is redundant work and a second full scan.

- [ ] **Step 1: Confirm behavior is preserved by a test.** Add to `tests/streaming.zig` or `src/parser/recovery.zig` test section: feed `parseRecover` an input with invalid UTF-8 (e.g. a lone `\xff` byte in a value) and assert it still surfaces an error/diagnostic (does not silently accept). Run it green BEFORE the change to capture current behavior.

```zig
test "P-NEW-5 parseRecover still rejects invalid UTF-8 after pre-pass removal" {
    const toml = @import("../toml.zig"); // adjust import path to file location
    const a = std.testing.allocator;
    var rr = try toml.parseRecover(a, "k = \"a\xffb\"\n", .{ .recovery_mode = .recover });
    defer rr.deinit(a);
    try std.testing.expect(rr.diagnostics.len > 0); // invalid UTF-8 reported
}
```

- [ ] **Step 2: Run, expect pass** (baseline). `zig build test --summary all`.

- [ ] **Step 3: Remove the pre-pass.** Delete the `if (!std.unicode.utf8ValidateSlice(input)) { ... }` block at `recovery.zig:57` (read the file to get the exact extent — it appends a `makeError` and may early-return). The lexer's inline validation now solely owns UTF-8 rejection. If the recover flow needs the error appended rather than returned, confirm the lexer path reports it into the diagnostics list; if not, keep a minimal guard. **Read `recovery.zig` fully before editing** to avoid changing the error contract.

- [ ] **Step 4: Run, expect pass** — `zig build test --summary all && zig fmt --check src`. The Step-1 test still green; no other regressions.

- [ ] **Step 5: Commit**

```bash
git add src/parser/recovery.zig
git commit -m "perf(recovery): drop redundant UTF-8 pre-pass (P-NEW-5/P-16)

parseRecoverDocument validated UTF-8 in a full pass before lexing, but the
lexer already validates inline and reports InvalidUtf8. Remove the second
scan. Behavior preserved: invalid UTF-8 is still reported (new test).

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 6: P-NEW-4 — single hash probe on duplicate-key insert

**Files:**

- Modify: `src/parser.zig:332-336` (the `if (tableContains(...)) error; tableSet(...)` pattern). Read first to confirm the helpers and the exact map type.

**Root cause:** Duplicate-key detection does `contains()` then `put()` = two hash probes per key store. `getOrPut` does one.

- [ ] **Step 1: Characterization test** — duplicate top-level key must still error. Likely already covered by `tests/testdata/toml-test/invalid/key-dup.toml` via the differential suite. Confirm by running `zig build test`; if a direct unit test is absent, add one asserting `parseWithError("a = 1\na = 2\n")` yields `.err` with `DuplicateKey`.

- [ ] **Step 2: Run, expect pass** (baseline).

- [ ] **Step 3: Implement.** Replace the contains-then-set with a single `getOrPut` on the underlying `StringArrayHashMapUnmanaged`: on `found_existing`, set `parse_error = DuplicateKey` and `return error.ParseFailed`; else assign the value pointer. Match the existing `tableSet` ownership (key is arena-owned). Read `src/value.zig` `tableSet`/`tableContains` to keep semantics identical (e.g. last-write-wins vs reject — current code REJECTS duplicates, so preserve reject).

- [ ] **Step 4: Run, expect pass** — `zig build test --summary all && zig fmt --check src`. Duplicate-key cases still error; valid docs unaffected.

- [ ] **Step 5: Commit**

```bash
git add src/parser.zig
git commit -m "perf(parser): single getOrPut probe on key insert (P-NEW-4)

Duplicate-key detection did contains() then put() = two hash probes per
key. Use getOrPut and reject on found_existing -- one probe, identical
DuplicateKey semantics.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 7: Q-23 — drop `pub` on 9 internal-only helpers

**Files:**

- Modify: `src/parser/datetime.zig:290,294,301,307,311` (`isLeapYear`, `daysInMonth`, `isValidDate`, `isValidTime`, `isValidOffset`); `src/parser/string.zig:68,93,134` (`decodeEscapes`, `decodeMultilineEscapes`, `decodeEscapeChar`); `src/parser/inline_table.zig:247` (`mergeTables`).

**Root cause:** Nine `pub fn` helpers have zero cross-module callers; over-exporting widens the API surface.

- [ ] **Step 1: Verify no external callers** — for each symbol run `grep -rn "<name>" src tests bench examples | grep -v "fn <name>"` and confirm all references are within the defining file (datetime helpers used only inside datetime.zig; string decoders only inside string.zig; `mergeTables` only inside inline_table.zig). If any symbol IS referenced cross-module, leave it `pub` and note it.

- [ ] **Step 2: Drop `pub`** on the confirmed-internal subset only (change `pub fn` → `fn`).

- [ ] **Step 3: Run, expect pass** — `zig build test --summary all && zig fmt --check src`. Compilation proves there were no external callers.

- [ ] **Step 4: Commit**

```bash
git add src/parser/datetime.zig src/parser/string.zig src/parser/inline_table.zig
git commit -m "refactor: drop pub on internal-only parser helpers (Q-23)

isLeapYear/daysInMonth/isValidDate/isValidTime/isValidOffset (datetime),
decodeEscapes/decodeMultilineEscapes/decodeEscapeChar (string), and
mergeTables (inline_table) had no cross-module callers. Narrow them to
file-private; build proves no external references.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 8: Q-NEW-1 — reconcile version/CHANGELOG drift + guard with hygiene test

**Files:**

- Modify: `docs/API.md:3` (version string), `CHANGELOG.md` (add released-tag entries), `tests/docs_hygiene_test.zig` (assert newest tag present).
- Read first: `build.zig.zon` (`.version`), `git tag --list`, current `docs/API.md:3`, `CHANGELOG.md` headings, `tests/docs_hygiene_test.zig`.

**Root cause:** `docs/API.md` advertises a version that doesn't match `build.zig.zon` (`0.1.4`); `CHANGELOG.md` documents an untagged `[0.2.0]` and omits the real `v0.1.2/v0.1.3/v0.1.4` tags. The existing hygiene test only checks for `[0.1.1]`, so it doesn't catch this.

- [ ] **Step 1: Establish ground truth** — `grep '\.version' build.zig.zon`; `git tag --list 'v*' | sort -V | tail -3`; `sed -n '1,5p' docs/API.md`; `grep -n '^## \[' CHANGELOG.md`.

- [ ] **Step 2: Write/extend the failing hygiene test** in `tests/docs_hygiene_test.zig`: read `CHANGELOG.md` at comptime/runtime and assert it contains a heading matching the current `build.zig.zon` version (e.g. `## [0.1.4]`). Run it; expect FAIL (entry missing).

- [ ] **Step 3: Reconcile docs** — set `docs/API.md:3` version to match the released line (`0.1.4`); add `## [0.1.4] - 2026-..`, `## [0.1.3]`, `## [0.1.2]` entries to `CHANGELOG.md` (summarize the tagged sibling-dep bumps + the APP-01/APP-02/perf fixes from this iteration under `[Unreleased]` or the next version heading). Keep entries factual and short. Determine dates from `git log -1 --format=%ad <tag>` per tag.

- [ ] **Step 4: Run, expect pass** — `zig build test --summary all` (hygiene test green) `&& zig fmt --check src`. Pre-commit markdownlint must pass (no MD036/MD034 etc.).

- [ ] **Step 5: Commit**

```bash
git add docs/API.md CHANGELOG.md tests/docs_hygiene_test.zig
git commit -m "docs: reconcile version/CHANGELOG drift; guard with hygiene test (Q-NEW-1)

docs/API.md advertised a version out of sync with build.zig.zon, and
CHANGELOG.md omitted the released v0.1.2/v0.1.3/v0.1.4 tags. Reconcile both
and extend docs_hygiene_test to assert the build.zig.zon version has a
CHANGELOG heading so this drift cannot recur.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 9: GAP-0004 — make conformance CI block merges

**Files:**

- Modify: `.gitlab-ci.yml` (`conformance-decoder`, `conformance-encoder` jobs — currently `allow_failure: true`).
- Read first: the full `conformance-*` job definitions and their pass-rate threshold comment.

**Root cause:** The toml-test conformance jobs run but `allow_failure: true`, so a conformance regression cannot fail the pipeline.

- [ ] **Step 1: Read the jobs** — `grep -n "conformance\|allow_failure" .gitlab-ci.yml`; understand how pass/fail is currently determined (script exit code + any `>= 95%` gate comment).

- [ ] **Step 2: Decide gating.** If the decoder currently passes the full corpus, flip `allow_failure: false` so any failure blocks. If a known subset fails (documented threshold), keep the job's internal threshold script but flip `allow_failure: false` so the threshold script's non-zero exit blocks. Do NOT make CI red on a known-acceptable baseline — verify locally first: build the decoder/encoder and run the vendored corpus the same way CI does, confirm exit 0.

- [ ] **Step 3: Apply** — set `allow_failure: false` on both jobs (and, if cheap, add a second decoder run with `-toml-version 1.0.0` per the gap's secondary criterion; otherwise note it as follow-up).

- [ ] **Step 4: Validate YAML** — the repo's pre-commit `check yaml` must pass; `git diff` review confirms only the intended lines changed.

- [ ] **Step 5: Commit**

```bash
git add .gitlab-ci.yml
git commit -m "ci: gate merges on toml-test conformance (GAP-0004)

conformance-decoder/encoder ran with allow_failure:true, so a conformance
regression couldn't fail the pipeline. Flip to allow_failure:false now that
the vendored corpus passes locally, so the differential gate is enforced.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 10: GAP-0018/0019 — Windows + macOS cross-compile CI

**Files:**

- Modify: `.gitlab-ci.yml` (add `test-windows`, `test-macos` jobs in the `test` stage).
- Read first: the existing `test` job (build/test invocation + zig install template) to mirror tags/before_script.

**Root cause:** CI is Linux-only; no Windows/macOS coverage. Cross-compilation is the cheapest portable coverage from Linux runners.

- [ ] **Step 1: Confirm cross-compile works locally** — `zig build test -Dtarget=x86_64-windows` (compiles; running needs Wine) and `zig build -Dtarget=aarch64-macos` (compiles). At minimum the library + tests must *compile* for both targets. Capture any target-specific failures as sub-findings (do not paper over a real portability bug).

- [ ] **Step 2: Add jobs** mirroring the existing `test` job's `before_script` (zig install), each running the cross-compile (`zig build test -Dtarget=x86_64-windows` — note: cross-compiled test binaries can't be *run* on a Linux runner without Wine, so use `zig build -Dtarget=...` to compile, or add Wine for Windows execution). Keep them non-`allow_failure` only if they pass cleanly; if execution needs an emulator not available, gate on *compilation* and document the runtime-execution gap.

- [ ] **Step 3: Validate YAML** — pre-commit `check yaml` passes.

- [ ] **Step 4: Commit**

```bash
git add .gitlab-ci.yml
git commit -m "ci: add Windows + macOS cross-compile coverage (GAP-0018, GAP-0019)

CI was Linux-only. Add test-windows (x86_64-windows) and test-macos
(aarch64-macos) cross-compile jobs from the Linux runners so portability
breaks are caught. Execution under emulator left as follow-up where a
runtime target isn't available.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 11: Reconcile gap-analysis docs (close resolved, record deferred)

**Files:**

- Modify: `docs/GAP_ANALYSIS.md`, `docs/GAP_ANALYSIS_RESOLVED.md`, `docs/SECURITY_GAP_ANALYSIS.md`, `docs/QUALITY_GAP_ANALYSIS.md`, `docs/PERF_GAP_ANALYSIS.md`.
- Also: add the APP-04 doc-comment to `src/parallel.zig` public `parseDocuments*` signatures (thread-safe-allocator requirement), since that's the agreed APP-04 remediation.

- [ ] **Step 1: Move resolved gaps.** In `docs/GAP_ANALYSIS.md`, move GAP-0001, 0009, 0012, 0013, 0014, 0022 to `docs/GAP_ANALYSIS_RESOLVED.md` with evidence pointers (file:line + passing tests) from the gap-scanner report. Mark GAP-0024 closed (Task 3), GAP-0004 closed (Task 9), GAP-0018/0019 closed (Task 10).

- [ ] **Step 2: Update SECURITY_GAP_ANALYSIS.md.** Record APP-01, APP-02 as closed this iteration (commits from Tasks 1-2). Record APP-03 (deferred → 0.3.0 removal) and APP-04 (closed via doc-comment, Step 5 below) with rationale. Reconcile prior S-9 etc. against current code (caps present).

- [ ] **Step 3: Update QUALITY_GAP_ANALYSIS.md.** Mark Q-1..Q-7, Q-12, Q-13, Q-17 resolved (evidence from quality-reviewer). Mark Q-23 closed (Task 7), Q-NEW-1 closed (Task 8). Record Q-21 + Q-NEW-2 as open-low (deferred, rationale: clean internals / cosmetic).

- [ ] **Step 4: Update PERF_GAP_ANALYSIS.md.** Mark P-1, P-5, P-7, P-8, P-10(array), P-11(scoped), P-12, P-16(strict) resolved (evidence from perf-reviewer). Mark P-NEW-2 (Task 4), P-NEW-5 (Task 5), P-NEW-4 (Task 6) closed. Record P-15 (needs flamegraph), P-NEW-1, P-NEW-3, P-NEW-6 as open with rationale (separate perf plan; invasive allocator restructure).

- [ ] **Step 5: APP-04 doc-comment.** Add a `///`-comment to the public `parseDocuments`/`parseDocumentsCtx` signatures in `src/parallel.zig` stating the caller allocator MUST be thread-safe (the fan-out calls it concurrently). Run `zig build test`.

- [ ] **Step 6: Verify + commit**

```bash
zig build test --summary all && zig fmt --check src
git add docs/ src/parallel.zig
git commit -m "docs(audit): reconcile gap docs to current code; APP-04 thread-safety note

Move resolved gaps (GAP-0001/0009/0012/0013/0014/0022, Q-1..Q-7/12/13/17,
P-1/5/7/8/10/11/12/16) to resolved with evidence; record APP-01/APP-02 and
the perf/quality closures from this iteration; document deferred items
(APP-03 0.3.0 removal, P-15 needs-profiling, P-NEW-1/3/6 perf restructure,
Q-21/Q-NEW-2). Add thread-safe-allocator doc-comment to parallel
parseDocuments* (APP-04).

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Self-Review

- **Spec coverage:** Every genuinely-open finding from the appsec review (APP-01..04) and the gap/quality/perf refresh maps to a task (table above). Doc-only resolved items handled in Task 11.
- **Placeholders:** Tasks 4/5/6/9/10 require reading exact line numbers before editing (number.zig, recovery.zig, parser.zig insert site, .gitlab-ci.yml) — flagged in each, with the precise change described. No "add error handling" hand-waving.
- **Type consistency:** `checkKeyPathDepth(self, len)` (Task 2) and the guard inserts reference real `self.options.max_depth`, `self.parse_error`, `err.makeError`, `.LimitExceeded` (verified present in parser.zig). datetime guards reuse `.InvalidDateTime` + `self.current.pos` (verified).
- **Ordering:** security (1,2) first; independent perf/quality (4-8) next; CI (9,10) and doc reconciliation (11) last so the doc reflects all landed commits.

## Execution

Iteration-1 closure. After all tasks land + full suite green, RE-RUN `/security:appsec-review` and the gap/quality/perf reviewers to confirm no new issues (loop exit condition).
