<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- Copyright (c) 2024-2026 CodePros -->

# Performance Baselines

This document captures the current microbenchmark baselines for the
zigtoml parser, along with the regression-threshold policy CI will
eventually enforce.

## How to run

```sh
# Single benchmark
zig build bench-parse_small -Doptimize=ReleaseFast

# Every benchmark, one process
zig build bench-all -Doptimize=ReleaseFast

# Filter by name (only runs benchmarks whose short name contains the
# substring). Applies to the `zig build bench` aggregate.
zig build bench -Dbench-filter=parse -Doptimize=ReleaseFast
```

All benchmarks live under `bench/`. Input generators live in
`bench/inputs.zig` and are seeded from fixed compile-time constants
(`0xDEADBEEF`, `0xCAFEBABE`, `0xFEEDFACE`), so output is byte-identical
across runs. The shared harness in `bench/common.zig` wraps any backing
allocator with an atomic `CountingAllocator` so `bytes_peak` and
`bytes_total` reflect the peak outstanding bytes observed at any instant
during the timed iterations (after a warmup phase that is excluded from
the sample).

## Baselines

All numbers below are `ReleaseFast`, Zig 0.16.0, Linux x86_64, captured
on a developer laptop on 2026-04-18. Column definitions:

- `iters`  - number of measured iterations (after warmup)
- `p50_ns` - median wall-clock per iteration
- `p99_ns` - 99th percentile wall-clock per iteration
- `peak_B` - peak outstanding bytes observed across timed iterations

| Benchmark           | iters  | p50_ns   | p99_ns   | peak_B     |
|---                  |---:    |---:      |---:      |---:        |
| parse_small         | 10 000 |    90705 |   141662 |     23 180 |
| parse_large (1 MiB) | 50     | 32333978 | 41329431 | 32 853 194 |
| parse_wide_table    | 50     |  4290025 |  4928284 |  5 777 832 |
| parse_deep_nest     | 5 000  |   169902 |   567433 |    107 196 |
| parse_strings       | 100    |  1383062 |  1885549 |  1 178 042 |
| parse_datetime      | 100    |  2474607 |  3043678 |  2 645 792 |
| parallel_parse n4   | 200    |   236646 |   378770 |     92 720 |
| parallel_parse n16  | 200    |   826513 |  1128414 |    370 880 |
| parallel_parse n64  | 50     |  3040235 |  3505665 |  1 483 520 |
| parallel_parse n256 | 50     |  5843367 |  8149206 |  5 934 080 |

## Regression policy

Once three weeks of baseline data are collected, CI will compare
`p50_ns` and `peak_B` against a rolling median:

- `+25%` or worse on `p50_ns`  - job fails.
- `+50%` or worse on `peak_B`  - job fails.

Until then the `bench` stage in `.gitlab-ci.yml` runs with
`allow_failure: true` and only publishes `bench.csv` as a pipeline
artifact.

## Caveats

- Times depend on the CI runner's hardware. The numbers here are a
  local reference, not a deployment target.
- `parallel_parse` routes through the real parser per-input via
  `toml.parallel.parseDocuments`; each successful result carries a
  caller-owned `*Document` that the benchmark's `work` function frees
  before the next iteration, so `peak_B` reflects the live memory for
  `N` concurrently-parsed documents.
- `peak_B` is observed by the bench harness's `CountingAllocator`
  wrapper and includes the internal arena the parser uses. The wrapper's
  counters are atomic so the reading is accurate even when the
  underlying allocator is shared across threads (as in parallel_parse).
- `parse_deep_nest` passes `ParseOptions{ .max_depth = 256 }` so the
  benchmark's 64 alternating inline-table/array levels (which each cost
  two parser recursion frames) clear the default 128-frame guard.
