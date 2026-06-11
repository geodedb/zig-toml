# Performance Gap Analysis

## 2026-06-11 audit closure

A fresh perf review (bench harness now exists under `bench/`) verified the
previously-"open" findings against current `main`. **Most were already
resolved**: P-1 (O(n^2) grow -> StringArrayHashMap/ArrayList), P-5 (dupe

+ UAF), P-7 (global pool), P-8 (shadow parser), P-10 (array-of-pointers),
P-12 (inline dup-check), P-16 (strict-path UTF-8 double-pass) are all gone
in current code. Of the rest:

+ **P-NEW-2** -- underscore-free int/float literals skip the scratch alloc.
  **Closed** (commit `21e0f20`). Measured impact within noise on the current
  corpus (less numeric-heavy than estimated); kept as an allocation-reducing
  cleanup, not a headline speedup.
+ **P-NEW-4** -- duplicate-key insert uses one `getOrPut` probe instead of
  contains+put. **Closed** (commit `700485c`).
+ **P-NEW-5 / P-16(recover)** -- the recover-mode UTF-8 pre-pass is a
  **deliberate terminal-condition guard**, not redundant work (removing it
  changes recover semantics). **Won't-fix**; left intact.
+ **P-15** -- residual ~3x throughput gap. **Open, needs-profiling** -- real
  but hotspot attribution requires a flamegraph not produced here.
+ **P-NEW-1** (per-key 128B `path` ArrayList), **P-NEW-3** (array element
  double-alloc), **P-NEW-6** (JSON emitter stack frame). **Open** -- invasive
  allocator restructures deferred to a focused perf plan; P-NEW-1's claimed
  25-40% memory cut was not reproduced on `parse_large` (delta ~1.5KB).

Last updated: 2026-04-19 (Phase 3 reconciliation: P-2 closed; P-8 rescoped; P-15/P-16 added)

Source: Phase 3 perf review (13 findings) -> Phase 4 scoring + issue tracking -> Phase 3 benchmark-driven reconciliation (adds P-15, P-16; closes P-2).

**Phase 5 closure summary:** P-3, P-4, P-9, P-13 fully closed (see Status column and `docs/GAP_ANALYSIS_RESOLVED.md`). P-1, P-5, P-7, P-10, P-11, P-12 unchanged.

**Phase 3 reconciliation (2026-04-19):**

+ **P-2 closed** as resolved. Post P-3/P-4/P-13 the hot-path table lookups all use `StringArrayHashMap` (O(1)) -- linear `std.mem.eql` scans no longer exist in the cited code. Evidence: `src/parser/table_path.zig:46`, `src/parser/inline_table.zig:157,174`, `src/value.zig:162-169`. Issue #30 closed with note.
+ **P-8 rescoped** to bench-harness note. `parallel_parse` n4 = 236 us vs `parse_small` 90 us ~= 2.6x (not 4x); extra ~146 us is thread-spawn overhead, not a parser bug. Do not invest in parallel perf until single-thread > 80 MB/s. The UTF-8 fold-in aspect of original P-8 is now tracked as P-16 for ranked visibility.
+ **P-14 rejected** (not opened). `renderKeyPath` is already gated by `if (self.sink == .events)` at `src/parser.zig:248` with one call site. Phase 2 candidate was based on mis-reading `events_sink.zig` in isolation.
+ **P-15 added** (new, priority::high). `parse_large` ~32 MB/s is 3x below typical hand-written TOML parsers. Lexer branch structure + per-token UTF-8 decoding are primary suspects. PerfScore pending flamegraph.
+ **P-16 added** (new, priority::medium). UTF-8 validation double-pass (parser preamble + lexer). Secondary suspect for 3x gap. PerfScore pending flamegraph.

Scoring formula: `PerfScore = (severity_weight * frequency * blast_radius) / effort_estimate`
Severity weights: P0=10, P1=7, P2=4, P3=2. Frequency / blast / effort on 1-5 scales.

> Note: no benchmarks exist in the repo (tracked in GitLab #3). Measurements below are
> evidence-anchored estimates until the benchmark harness is in place. All code citations
> were re-verified against `main` at time of writing.

---

## Summary

**Totals by PerfSeverity:** P0 = 3  |  P1 = 3  |  P2 = 4  |  P3 = 3  |  + P1 = 1 (P-15), P2 = 1 (P-16)  |  Total open findings = 15 (including P-15, P-16)

**Blocker:** Install `hyperfine` and ensure `perf record -g` is accessible. Without a flamegraph on `parse_large`, P-15/P-16 ranking is speculation.

**Top 5 risks (by PerfScore + correctness weight):**

1. **P-4 -- ArrayList capacity=0 (9 sites)** -- highest effort-adjusted win; pure quick win, ~5-15% parser speedup expected.
2. **P-3 -- parseDocuments/validateDocuments drops inputs beyond 64** -- correctness defect (returns undefined results) stamped as perf.
3. **P-1 -- O(n^2) table/array grow** -- structural parser quadratic; ~5-20x speedup on large docs once combined with P-2.
4. **P-2 -- linear key scans** -- folds into P-1 via hash-map index.
5. **P-5 -- redundant dupe + latent UAF in parseKey bare-key path** -- correctness bug masquerading as perf debt.

---

## Stack-Ranked Findings

| Rank | PerfSeverity | PerfScore | Finding | Component | Evidence | Measurement | Issue | Fix Summary | Owner | SLA/Due | Status |
|------|--------------|-----------|---------|-----------|----------|-------------|-------|-------------|-------|---------|--------|
| 1 | P1 | 140.0 | ArrayLists initialized at capacity=0 (9 sites) | parser | `parser.zig:128,264,473,530,583,629,648,854,876` | estimate 5-15% speedup; ~6 avoidable reallocs/list | [#31](https://gitlab.com/devnw/zig/toml/-/work_items/31) | Use `initCapacity` with domain-appropriate hints | @maintainers | this sprint | Closed (f92ad8b) |
| 2 | P0 | 125.0 | parseDocuments drops inputs beyond MAX_CHUNKS=64 (correctness + perf) | parallel | `parallel.zig:141,146,294,299,408,413` | repro: inputs.len=100 leaves `results[64..99]` undefined | [#27](https://gitlab.com/devnw/zig/toml/-/work_items/27) | Ceiling-divide `chunk_size`; keep cap as hint | @maintainers | immediate | Closed (037a918) -- ceiling-div + 3 regression tests (N=100) |
| 3 | P0 | 83.3 | O(n^2) table/array grow via alloc+memcpy per insert | value-model | `value.zig:249-252,272-275,296-299` | est. 5-20x speedup at N=1k-10k | [#28](https://gitlab.com/devnw/zig/toml/-/work_items/28) | ArrayListUnmanaged + StringHashMap index | @maintainers | this sprint | triage |
| 4 | P0 | 83.3 | Linear `std.mem.eql` scans on every table op (**P-2**) | value-model, parser | `value.zig:171-173,186-189,239-242,263-265,279-285`; `parser.zig:160-164,286-291,680-695,701-706,760-768` | scan cost = O(entries) per lookup | [#30](https://gitlab.com/devnw/zig/toml/-/work_items/30) | Folds into #28 via hash-map index | @maintainers | this sprint | Closed 2026-04-19 -- verified hot paths now use `StringArrayHashMap` (O(1)) at `parser/table_path.zig:46`, `parser/inline_table.zig:157,174`, `value.zig:162-169` |
| 5 | P1 | 42.0 | Redundant `alloc.dupe` on arena-owned bytes + latent UAF in `parseKey` bare-key path | parser | `parser.zig:336,340,343,367-379,408,416,697,707` + parseKey bare-key branch | est. 10-20% fewer allocs; UAF latent | [#34](https://gitlab.com/devnw/zig/toml/-/work_items/34) | Document ownership invariant; remove redundant dupes; fix bare-key dupe | @maintainers | this sprint | triage |
| 6 | P2 | 30.0 | Unsorted JSON emit for >256 keys + O(n^2) insertion sort at <=256 | json-output | `json_tagged.zig:25-41` | violates deterministic-output claim when N>256 | [#40](https://gitlab.com/devnw/zig/toml/-/work_items/40) | `std.sort.block` over heap slice; always sort | @maintainers | next quarter | Closed (87e7099) -- scratch stack+heap, always-sort |
| 7 | P2 | 24.0 | Inline-table dup-check is O(n^2) | parser | `parser.zig:629-749` | bounded but repeated per inline table | [#40](https://gitlab.com/devnw/zig/toml/-/work_items/40) | Becomes O(1) once #28 lands; otherwise scoped hash set | @maintainers | next quarter | triage |
| 8 | P1 | 21.0 | `parallel.parseDocument` is a toy state machine (**P-8 rescoped**) | parallel, parser | `parallel.zig:165-239` (note `_ = allocator`) | `parallel_parse` n4 = 236 us vs `parse_small` 90 us ~= 2.6x (not 4x); extra ~146 us = thread-spawn overhead, not parser bug | [#37](https://gitlab.com/devnw/zig/toml/-/work_items/37) | Deferred: do not invest in parallel perf until single-thread > 80 MB/s (see P-15). UTF-8 fold-in split out as P-16 | @maintainers | this sprint | rescoped 2026-04-19 -- blocked on P-15 single-thread win |
| 9 | P2 | 18.0 | Global pool page_allocator + panic + lock-per-call | parallel | `parallel.zig:56-67` | panic on init failure; mutex every call | [#40](https://gitlab.com/devnw/zig/toml/-/work_items/40) | Pass allocator, return error, double-checked init | @maintainers | next quarter | triage |
| 10 | P3 | 12.0 | Escape decoder ArrayList starts empty | parser | `parser.zig:811-912` | ~log2(len) extra reallocs per escaped string | [#40](https://gitlab.com/devnw/zig/toml/-/work_items/40) | initCapacity to estimated length (folds into #31) | @maintainers | backlog | Closed (f92ad8b) -- folded into P-4 initCapacity pass |
| 11 | P2 | 10.7 | Extra O(n) UTF-8 pass (no lexer-side validation) | lexer, parser | `parser.zig:54`; `lexer.zig` | ~5-10% speedup fold-in | [#40](https://gitlab.com/devnw/zig/toml/-/work_items/40) | Fold UTF-8 validation into lexer single pass | @maintainers | next quarter | triage |
| 12 | P3 | 6.0 | Fixed stack buffers error on oversized legal input | parser | `parser.zig:1002,1044,1145` | rare, but spec-legal inputs fail | [#40](https://gitlab.com/devnw/zig/toml/-/work_items/40) | Grow on demand with inline-buffer ArrayList; or document limit | @maintainers | backlog | triage |
| 13 | P3 | 3.0 | Heap-indirected arrays of pointers | value-model | `value.zig:151-158,160-162` | pointer-chase per iter; modest win | [#40](https://gitlab.com/devnw/zig/toml/-/work_items/40) | MultiArrayList / SoA; large refactor | @maintainers | backlog | triage |
| 14 | P1 | pending | **P-15** Lexer hot-path review for 3x throughput gap | lexer, parser | `parse_large` ~32 MB/s (3x below typical TOML parsers); suspect: branch-heavy per-byte classifier + per-token `std.unicode.utf8Decode` | Confirmed gap; hotspot attribution pending `perf record -g` flamegraph | [#59](https://gitlab.com/devnw/zig/toml/-/work_items/59) | Flamegraph first; then dispatch-table or SIMD character classification in lexer | @maintainers | 30d after flamegraph | triage (confidence::suspected) |
| 15 | P2 | pending | **P-16** UTF-8 validation potential double-pass | lexer, parser | `parser.zig:54` preamble + per-token `utf8Decode` in `lexer.zig`; overlaps with P-8 in #40 | ~5-15% speedup expected if confirmed via `perf report` attribution to `utf8Validate*` / `utf8Decode` | [#61](https://gitlab.com/devnw/zig/toml/-/work_items/61) | Fuse UTF-8 validation into lexer single pass; emit structured error | @maintainers | 90d after flamegraph | triage (confidence::suspected) |

---

## Findings by Area

### parser (src/parser.zig)

+ **#31** -- ArrayList capacity=0 across 9 sites (quick win). [P1] -- **Closed** commit `f92ad8b`.
+ **#34** -- Redundant dupe on arena-owned bytes + latent UAF in bare-key. [P1, correctness]
+ **#37** -- `parallel.parseDocument` is a toy; route to real parser. [P1, cross-cuts parallel]
+ Folded into umbrella **#40**: P-8 (lexer UTF-8 fold-in), P-11 (stack buffers), P-12 (inline-table dup O(n^2)), P-13 (escape decoder list -- **Closed** commit `f92ad8b` via P-4 pass).

### value-model (src/value.zig)

+ **#28** -- O(n^2) grow via alloc+memcpy on every insert. [P0]
+ **#30** -- Linear `std.mem.eql` scans; folds into #28 via hash-map. [P0]
+ Folded into umbrella **#40**: P-10 (array-of-pointers cache layout).

### parallel (src/parallel.zig)

+ **#27** -- MAX_CHUNKS=64 drops inputs (correctness + perf). [P0] -- **Closed** commit `037a918`.
+ **#37** -- toy `parseDocument`. [P1]
+ Folded into umbrella **#40**: P-7 (global pool allocator/API).

### lexer / json-output / infra

+ **#59** -- **P-15** Lexer hot-path review for 3x throughput gap (`parse_large` ~32 MB/s). [P1, confidence::suspected]
+ **#61** -- **P-16** UTF-8 validation potential double-pass (fold into lexer). [P2, confidence::suspected; also tracked as P-8 checkbox in #40]
+ Folded into umbrella **#40**: P-8 (lexer -- now duplicated by #61 for ranked visibility), P-9 (json-tagged unsorted emit / O(n^2) sort -- **Closed** commit `87e7099`).
+ Benchmark harness (prerequisite to quantify all numbers above): tracked in existing issue **#3**.

---

## Roadmap

### Quick wins (< 1 day)

+ **#31** -- `ArrayList.initCapacity(...)` everywhere. **Closed** commit `f92ad8b`.
+ **#27** -- `chunk_size` ceiling-divide fix. **Closed** commit `037a918`.
+ **#40 / P-9** -- always-sort JSON emit with heap slice. **Closed** commit `87e7099`.
+ **#40 / P-13** -- escape decoder `initCapacity`. **Closed** commit `f92ad8b` (folded into P-4 pass).

### Medium (1-5 days)

+ **#34** -- Ownership-invariant audit + bare-key UAF fix.
+ **#37** -- Wire `parallel.parseDocument` to real parser; per-worker arena.
+ **#40 / P-7** -- Rework global pool: allocator param, no panic, double-checked init.
+ **#40 / P-8** -- Fold UTF-8 validation into lexer.

### Strategic (> 5 days)

+ **#28** -- Value-model refactor to ArrayListUnmanaged + insertion-order preserving index. (P-2/#30 closed -- hash-map lookup already in place; remaining work is the quadratic-grow fix.)
+ **#59 (P-15)** -- Lexer hot-path refactor for single-thread 80+ MB/s: dispatch-table or SIMD-classified character categories. **Prerequisite**: flamegraph from `perf record -g -- zig build bench-parse_large`.
+ **#61 (P-16)** -- Fuse UTF-8 validation into lexer pass (if confirmed as material hotspot).
+ **#40 / P-10** -- MultiArrayList / struct-of-arrays for `Value` variants. Big win for cache, large refactor.
+ **#3** (existing) -- Stand up the benchmark harness so every item above has a measured before/after.

---

## Unknowns / Blockers

+ **Flamegraph tooling gap (P-15/P-16).** Install `hyperfine`; ensure `perf record -g` is accessible (may require `/proc/sys/kernel/perf_event_paranoid <= 1`). Without a flamegraph on `bench-parse_large`, ranking P-15 vs P-16 is speculation. PerfScore for both is "pending" until profiler attribution lands.
+ **No benchmarks** (pre-P-15 context). Every percent-improvement above is an evidence-anchored estimate, not a measurement. Priority: close **#3** (benchmark suite) before merging large refactors so PRs include measured deltas.
+ **parseKey bare-key UAF** (#34) needs an explicit repro test: input freed before Document, assert bare-key string still valid. Confirm via `-fsanitize=address`.
+ **P-3 data loss** (#27) has no test coverage today; add a `parallel_coverage_test.zig` with `inputs.len >= 65` as part of the fix PR.
+ **Value-model refactor** (#28/#30) will interact with json_tagged deterministic-order requirement (#40 / P-9); fix P-9 first or in the same change set so regression tests stay meaningful.
