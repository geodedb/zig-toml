# Benchmark Harness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close GAP-0011 by adding a reproducible `zig build bench` microbenchmark suite covering the TOML parser's hot paths, plus CI integration and baseline documentation.

**Architecture:** Introduce a top-level `bench/` directory with one Zig source file per microbenchmark and a shared `bench/common.zig` harness that times iterations with `std.time.Timer` and tracks allocator bytes via a counting wrapper around `std.heap.GeneralPurposeAllocator` with `enable_memory_limit` + `retain_metadata`. Each benchmark is wired as its own `zig build bench-<name>` step so it can be filtered; a composite `zig build bench` step depends on all of them and a separate `zig build bench-all` orchestrator prints a formatted summary. CI gains an `allow_failure: true` bench stage that publishes results but does not gate merges yet.

**Tech Stack:** Zig 0.16.0, `std.time.Timer`, `std.heap.GeneralPurposeAllocator`, `std.Random.Xoshiro256` (seeded), `thread_pool` dep (for `parallel_parse`), GitLab CI.

---

## Pre-flight: Read current state

Before starting, the engineer must read these files in this order so later tasks make sense:

- `/home/benji/src/devnw/zig/toml/build.zig` — current build graph (lines 1-126 are all of it).
- `/home/benji/src/devnw/zig/toml/src/toml.zig` — public `parse`, `parseWithError`, `Document` API.
- `/home/benji/src/devnw/zig/toml/src/parser.zig` — `ParseOptions`, `TomlVersion`.
- `/home/benji/src/devnw/zig/toml/src/parallel.zig` — `parseDocuments`, `ParseResult`.
- `/home/benji/src/devnw/zig/toml/docs/ARCHITECTURE.md` — current (unverified) performance claims.
- `/home/benji/src/devnw/zig/toml/docs/GAP_ANALYSIS.md` — GAP-0011 acceptance criteria (lines 133-142).

The public parse API we target is:

```zig
// src/toml.zig
pub fn parse(alloc: Allocator, input: []const u8, opts: ParseOptions) !Document;
// Document owns an arena; call doc.deinit() to free.
```

The parallel API we target is:

```zig
// src/parallel.zig
pub const ParseResult = struct {
    success: bool,
    error_code: u8,
    error_line: ?usize,
    error_column: ?usize,
    // ... additional fields; see src/parallel.zig
};

pub fn parseDocuments(
    allocator: std.mem.Allocator,
    inputs: []const []const u8,
    results: []ParseResult,
) void;
```

---

## File Structure

Files created by this plan (all paths relative to repo root):

| Path | Responsibility |
|---|---|
| `bench/common.zig` | `Stats` struct, `runBench` harness, percentile calc, `CountingAllocator` for byte accounting, RNG seeding helper. |
| `bench/inputs.zig` | Deterministic synthetic input generators (fixed seeds). Shared by every benchmark. |
| `bench/parse_small.zig` | Benchmarks `toml.parse` on a fixed ~1 KiB handwritten config. |
| `bench/parse_large.zig` | Benchmarks `toml.parse` on a 1 MiB generated config. |
| `bench/parse_wide_table.zig` | One table with 10 000 keys (stresses table key lookup). |
| `bench/parse_deep_nest.zig` | Deeply nested arrays / inline tables (depth 64). |
| `bench/parse_strings.zig` | Escape-heavy basic + multiline strings. |
| `bench/parse_datetime.zig` | Datetime-dense input. |
| `bench/parallel_parse.zig` | `parallel.parseDocuments` for N in {4, 16, 64, 256}. |
| `bench/main.zig` | `zig build bench-all` orchestrator that invokes every benchmark and prints a summary table. |
| `docs/PERFORMANCE.md` | Documents baseline numbers + regression-threshold policy. |

Files modified:

| Path | Change |
|---|---|
| `build.zig` | Add per-benchmark `bench-<name>` steps, an aggregate `bench` step, `bench-all`, and a `-Dbench-filter=<name>` option. |
| `.gitlab-ci.yml` | Add a `bench` stage with `allow_failure: true`. |
| `docs/ARCHITECTURE.md` | Reference `docs/PERFORMANCE.md` and replace unverified Big-O claims with a pointer to the benchmark results. |
| `CHANGELOG.md` | Add entry under `Unreleased` for GAP-0011 closure. |
| `docs/GAP_ANALYSIS.md` | Mark GAP-0011 `Status: Closed`. |
| `docs/GAP_ANALYSIS_RESOLVED.md` | Append the resolved GAP-0011 entry, matching the existing format in that file. |

One benchmark = one file = one build step. DRY: shared harness lives in `bench/common.zig` and all generators in `bench/inputs.zig`.

---

## Task 1: Scaffold `bench/` with the shared harness

**Files:**

- Create: `bench/common.zig`
- Create: `bench/inputs.zig`

- [ ] **Step 1.1: Create `bench/common.zig`**

Exact content:

```zig
// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros

//! Shared microbenchmark harness.
//!
//! Not a test: `zig build test` must never depend on this file. Each
//! benchmark's `main()` calls `runBench` and prints one line of CSV to
//! stdout plus a human-readable summary to stderr.

const std = @import("std");

pub const Stats = struct {
    name: []const u8,
    iters: u64,
    total_ns: u64,
    p50_ns: u64,
    p99_ns: u64,
    bytes_peak: usize,
    bytes_total: u64,

    pub fn ops_per_sec(self: Stats) f64 {
        if (self.total_ns == 0) return 0;
        const secs = @as(f64, @floatFromInt(self.total_ns)) / 1e9;
        return @as(f64, @floatFromInt(self.iters)) / secs;
    }

    pub fn ns_per_iter(self: Stats) f64 {
        if (self.iters == 0) return 0;
        return @as(f64, @floatFromInt(self.total_ns)) / @as(f64, @floatFromInt(self.iters));
    }

    pub fn printCsv(self: Stats, writer: anytype) !void {
        try writer.print(
            "{s},{d},{d:.2},{d},{d},{d},{d}\n",
            .{
                self.name,
                self.iters,
                self.ops_per_sec(),
                self.p50_ns,
                self.p99_ns,
                self.bytes_peak,
                self.bytes_total,
            },
        );
    }

    pub fn printHuman(self: Stats, writer: anytype) !void {
        try writer.print(
            "{s}: {d} iters, {d:.0} ops/s, p50={d} ns, p99={d} ns, peak={d} B\n",
            .{
                self.name,
                self.iters,
                self.ops_per_sec(),
                self.p50_ns,
                self.p99_ns,
                self.bytes_peak,
            },
        );
    }
};

/// Allocator wrapper that observes peak outstanding bytes + total bytes
/// requested across a single benchmark run. Wraps any backing allocator.
pub const CountingAllocator = struct {
    backing: std.mem.Allocator,
    bytes_outstanding: usize = 0,
    bytes_peak: usize = 0,
    bytes_total: u64 = 0,

    pub fn allocator(self: *CountingAllocator) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    const vtable = std.mem.Allocator.VTable{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const p = self.backing.rawAlloc(len, alignment, ret);
        if (p != null) {
            self.bytes_outstanding += len;
            self.bytes_total += len;
            if (self.bytes_outstanding > self.bytes_peak) self.bytes_peak = self.bytes_outstanding;
        }
        return p;
    }

    fn resize(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ret: usize) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const ok = self.backing.rawResize(buf, alignment, new_len, ret);
        if (ok) {
            if (new_len > buf.len) {
                const diff = new_len - buf.len;
                self.bytes_outstanding += diff;
                self.bytes_total += diff;
            } else {
                self.bytes_outstanding -= (buf.len - new_len);
            }
            if (self.bytes_outstanding > self.bytes_peak) self.bytes_peak = self.bytes_outstanding;
        }
        return ok;
    }

    fn remap(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ret: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const p = self.backing.rawRemap(buf, alignment, new_len, ret);
        if (p != null) {
            if (new_len > buf.len) {
                const diff = new_len - buf.len;
                self.bytes_outstanding += diff;
                self.bytes_total += diff;
            } else {
                self.bytes_outstanding -= (buf.len - new_len);
            }
            if (self.bytes_outstanding > self.bytes_peak) self.bytes_peak = self.bytes_outstanding;
        }
        return p;
    }

    fn free(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, ret: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.bytes_outstanding -= buf.len;
        self.backing.rawFree(buf, alignment, ret);
    }
};

/// Run `work` `iters` times after `warmup` un-timed warmup iterations.
/// `work` receives a per-iteration allocator; it must free everything it
/// allocates before returning (the harness asserts zero outstanding bytes
/// between iterations so leaks surface immediately).
///
/// Returns aggregated Stats. Memory accounting is the peak/total observed
/// across all timed iterations.
pub fn runBench(
    comptime name: []const u8,
    backing: std.mem.Allocator,
    warmup: u64,
    iters: u64,
    comptime work: fn (alloc: std.mem.Allocator) anyerror!void,
) !Stats {
    std.debug.assert(iters > 0);

    var counting: CountingAllocator = .{ .backing = backing };
    const a = counting.allocator();

    // Warmup -- not timed, not counted.
    var w: u64 = 0;
    while (w < warmup) : (w += 1) {
        try work(a);
        std.debug.assert(counting.bytes_outstanding == 0);
    }

    // Reset peak/total after warmup so we measure only timed iterations.
    counting.bytes_peak = 0;
    counting.bytes_total = 0;

    const samples = try backing.alloc(u64, iters);
    defer backing.free(samples);

    var timer = try std.time.Timer.start();
    const total_start = timer.read();

    var i: u64 = 0;
    while (i < iters) : (i += 1) {
        const iter_start = timer.read();
        try work(a);
        const iter_end = timer.read();
        samples[i] = iter_end - iter_start;
        std.debug.assert(counting.bytes_outstanding == 0);
    }

    const total_ns = timer.read() - total_start;

    std.mem.sort(u64, samples, {}, std.sort.asc(u64));
    const p50 = samples[iters / 2];
    const p99_idx = (iters * 99) / 100;
    const p99 = samples[if (p99_idx >= iters) iters - 1 else p99_idx];

    return Stats{
        .name = name,
        .iters = iters,
        .total_ns = total_ns,
        .p50_ns = p50,
        .p99_ns = p99,
        .bytes_peak = counting.bytes_peak,
        .bytes_total = counting.bytes_total,
    };
}

/// Deterministic RNG seeded from a fixed compile-time seed so every run
/// produces byte-identical inputs. Do NOT use `std.Random.DefaultPrng` with
/// a time-based seed in bench/*.
pub fn seededPrng(seed: u64) std.Random.Xoshiro256 {
    return std.Random.Xoshiro256.init(seed);
}
```

- [ ] **Step 1.2: Create `bench/inputs.zig`**

Exact content:

```zig
// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros

//! Deterministic synthetic input generators for the bench harness.
//! Every generator takes an allocator and a fixed seed and returns a
//! `[]u8` the caller must `free`.

const std = @import("std");
const common = @import("common.zig");

/// ~1 KiB of handwritten TOML exercising the common paths.
/// Returned slice is `const` and lives for the entire program.
pub const small_config: []const u8 =
    \\# 1 KiB sample config
    \\title = "zigtoml benchmark"
    \\enabled = true
    \\retries = 3
    \\ratio = 0.125
    \\tags = ["alpha", "beta", "gamma"]
    \\
    \\[server]
    \\host = "localhost"
    \\port = 8080
    \\timeout_ms = 250
    \\
    \\[server.tls]
    \\enabled = true
    \\cert = "/etc/ssl/cert.pem"
    \\key  = "/etc/ssl/key.pem"
    \\
    \\[[clients]]
    \\name = "alpha"
    \\weight = 1
    \\
    \\[[clients]]
    \\name = "beta"
    \\weight = 2
    \\
    \\[[clients]]
    \\name = "gamma"
    \\weight = 3
    \\
    \\[log]
    \\level = "info"
    \\format = "json"
    \\rotate = { size = "10M", keep = 7 }
    \\
;

/// Generate ~`target_bytes` of synthetic TOML. Structure: repeating
/// `[section.nN]` blocks each with 10 scalar keys. Output is always
/// slightly larger than `target_bytes` (we stop after writing the
/// section that crosses the boundary) so callers assert `>= target_bytes`.
pub fn generateLarge(alloc: std.mem.Allocator, target_bytes: usize) ![]u8 {
    var buf = try std.ArrayList(u8).initCapacity(alloc, target_bytes + 4096);
    errdefer buf.deinit(alloc);
    const w = buf.writer(alloc);

    var prng = common.seededPrng(0xDEADBEEF);
    const rnd = prng.random();

    var n: usize = 0;
    while (buf.items.len < target_bytes) : (n += 1) {
        try w.print("[section.n{d}]\n", .{n});
        try w.print("id = {d}\n", .{rnd.int(i32)});
        try w.print("name = \"item-{d}\"\n", .{n});
        try w.print("weight = {d}\n", .{rnd.int(u16)});
        try w.print("ratio = {d:.4}\n", .{rnd.float(f64)});
        try w.print("enabled = {s}\n", .{if (rnd.boolean()) "true" else "false"});
        try w.writeAll("tags = [\"a\", \"b\", \"c\"]\n");
        try w.print("count = {d}\n", .{rnd.int(u32)});
        try w.print("offset_ms = {d}\n", .{rnd.int(i16)});
        try w.print("flag_a = {s}\n", .{if (rnd.boolean()) "true" else "false"});
        try w.print("flag_b = {s}\n", .{if (rnd.boolean()) "true" else "false"});
        try w.writeByte('\n');
    }

    return buf.toOwnedSlice(alloc);
}

/// One `[wide]` table followed by `count` keys `k_0 = 0` .. `k_{count-1} = N`.
/// Exercises table-key lookup + insertion on a single hot path.
pub fn generateWideTable(alloc: std.mem.Allocator, count: usize) ![]u8 {
    var buf = try std.ArrayList(u8).initCapacity(alloc, count * 16 + 64);
    errdefer buf.deinit(alloc);
    const w = buf.writer(alloc);

    try w.writeAll("[wide]\n");
    var i: usize = 0;
    while (i < count) : (i += 1) {
        try w.print("k_{d} = {d}\n", .{ i, i });
    }
    return buf.toOwnedSlice(alloc);
}

/// `depth`-deep nested inline-table + array: `a = { b = { c = [ { d = ...`
/// produces a valid TOML value whose parse-tree depth equals `depth`.
pub fn generateDeepNest(alloc: std.mem.Allocator, depth: usize) ![]u8 {
    var buf = try std.ArrayList(u8).initCapacity(alloc, depth * 8 + 16);
    errdefer buf.deinit(alloc);
    const w = buf.writer(alloc);

    try w.writeAll("root = ");
    var i: usize = 0;
    while (i < depth) : (i += 1) {
        // Alternate inline tables and arrays so we hit both code paths.
        if (i % 2 == 0) try w.writeAll("{ n = ") else try w.writeAll("[ ");
    }
    try w.writeAll("42");
    i = 0;
    while (i < depth) : (i += 1) {
        if (i % 2 == 0) try w.writeAll(" }") else try w.writeAll(" ]");
    }
    try w.writeByte('\n');
    return buf.toOwnedSlice(alloc);
}

/// `count` escape-heavy strings (basic + multiline).
pub fn generateStrings(alloc: std.mem.Allocator, count: usize) ![]u8 {
    var buf = try std.ArrayList(u8).initCapacity(alloc, count * 96);
    errdefer buf.deinit(alloc);
    const w = buf.writer(alloc);

    var prng = common.seededPrng(0xCAFEBABE);
    const rnd = prng.random();

    var i: usize = 0;
    while (i < count) : (i += 1) {
        if (rnd.boolean()) {
            try w.print(
                "s_{d} = \"line\\tone\\nline\\ttwo\\u00e9\\u00ff\\\"quoted\\\"end\"\n",
                .{i},
            );
        } else {
            try w.print(
                "m_{d} = \"\"\"line one\\n\\tline two\\n\"\"\"\n",
                .{i},
            );
        }
    }
    return buf.toOwnedSlice(alloc);
}

/// `count` datetime assignments (mix of offset/local date-time, local
/// date, local time).
pub fn generateDateTimes(alloc: std.mem.Allocator, count: usize) ![]u8 {
    var buf = try std.ArrayList(u8).initCapacity(alloc, count * 48);
    errdefer buf.deinit(alloc);
    const w = buf.writer(alloc);

    var prng = common.seededPrng(0xFEEDFACE);
    const rnd = prng.random();

    var i: usize = 0;
    while (i < count) : (i += 1) {
        const year = 1970 + rnd.intRangeAtMost(u16, 0, 100);
        const mon = rnd.intRangeAtMost(u8, 1, 12);
        const day = rnd.intRangeAtMost(u8, 1, 28);
        const hh = rnd.intRangeAtMost(u8, 0, 23);
        const mm = rnd.intRangeAtMost(u8, 0, 59);
        const ss = rnd.intRangeAtMost(u8, 0, 59);
        switch (i % 4) {
            0 => try w.print("dt_{d} = {d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z\n", .{ i, year, mon, day, hh, mm, ss }),
            1 => try w.print("dt_{d} = {d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}\n", .{ i, year, mon, day, hh, mm, ss }),
            2 => try w.print("dt_{d} = {d:0>4}-{d:0>2}-{d:0>2}\n", .{ i, year, mon, day }),
            3 => try w.print("dt_{d} = {d:0>2}:{d:0>2}:{d:0>2}\n", .{ i, hh, mm, ss }),
            else => unreachable,
        }
    }
    return buf.toOwnedSlice(alloc);
}
```

- [ ] **Step 1.3: Verify both files format cleanly**

Run: `zig fmt bench/`
Expected: no output, exit 0.

Run: `zig build-obj bench/common.zig -fno-emit-bin`
Expected: no errors.

Run: `zig build-obj bench/inputs.zig -fno-emit-bin`
Expected: no errors.

- [ ] **Step 1.4: Commit**

```bash
git add bench/common.zig bench/inputs.zig
git commit -m "feat(bench): add shared harness + deterministic input generators

Part of GAP-0011."
```

---

## Task 2: First benchmark -- `parse_small`

**Files:**

- Create: `bench/parse_small.zig`
- Modify: `build.zig` (add `bench-parse_small` step and the filter option)

- [ ] **Step 2.1: Wire the build graph first (will fail)**

Open `/home/benji/src/devnw/zig/toml/build.zig`. Insert the following block immediately before the closing `}` of `pub fn build`:

```zig
    // ------------------------------------------------------------------
    // Benchmark suite (GAP-0011).
    //
    // Each benchmark lives in bench/<name>.zig and is wired as its own
    // build step `zig build bench-<name>`. An aggregate `zig build bench`
    // step depends on all of them. A separate `zig build bench-all` runs
    // every benchmark in a single process and prints a summary table.
    // ------------------------------------------------------------------
    const bench_filter = b.option(
        []const u8,
        "bench-filter",
        "Only run benchmarks whose short name contains this substring",
    );

    const BenchSpec = struct {
        name: []const u8, // short name, e.g. "parse_small"
        root: []const u8, // "bench/parse_small.zig"
    };

    const bench_specs = [_]BenchSpec{
        .{ .name = "parse_small", .root = "bench/parse_small.zig" },
    };

    const bench_step = b.step("bench", "Run all benchmarks");

    for (bench_specs) |spec| {
        if (bench_filter) |f| {
            if (std.mem.indexOf(u8, spec.name, f) == null) continue;
        }
        const mod = b.createModule(.{
            .root_source_file = b.path(spec.root),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "toml", .module = toml_mod },
            },
        });
        if (tp_mod) |tm| mod.addImport("thread_pool", tm);

        const exe_bench = b.addExecutable(.{
            .name = b.fmt("bench-{s}", .{spec.name}),
            .root_module = mod,
        });
        const run_bench = b.addRunArtifact(exe_bench);
        run_bench.step.dependOn(b.getInstallStep());

        const single_step = b.step(
            b.fmt("bench-{s}", .{spec.name}),
            b.fmt("Run the {s} benchmark", .{spec.name}),
        );
        single_step.dependOn(&run_bench.step);
        bench_step.dependOn(&run_bench.step);
    }
```

Run: `zig build bench-parse_small`
Expected: FAIL with `unable to open 'bench/parse_small.zig': FileNotFound` (the build graph compiles, but the source does not yet exist).

- [ ] **Step 2.2: Create `bench/parse_small.zig` to make it pass**

Exact content:

```zig
// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros

//! Bench: parse a ~1 KiB handwritten config. Exercises the common path
//! (key/value, nested tables, arrays of tables, inline tables).
//!
//! Baselines recorded in docs/PERFORMANCE.md are the source of truth.

const std = @import("std");
const toml = @import("toml");
const common = @import("common.zig");
const inputs = @import("inputs.zig");

const input_bytes = inputs.small_config;

fn work(alloc: std.mem.Allocator) !void {
    var doc = try toml.parse(alloc, input_bytes, .{});
    doc.deinit();
}

pub fn runAndPrint(alloc: std.mem.Allocator) !common.Stats {
    const stats = try common.runBench(
        "parse_small",
        alloc,
        // warmup iterations
        100,
        // measured iterations
        10_000,
        work,
    );
    try stats.printHuman(std.io.getStdErr().writer());
    return stats;
}

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{
        .enable_memory_limit = true,
        .retain_metadata = true,
    }) = .{};
    defer _ = gpa.deinit();

    const stats = try runAndPrint(gpa.allocator());
    try stats.printCsv(std.io.getStdOut().writer());
}
```

- [ ] **Step 2.3: Run benchmark in Debug**

Run: `zig build bench-parse_small`
Expected: exit 0. stdout contains a CSV line starting with `parse_small,`; stderr contains a human-readable summary.

- [ ] **Step 2.4: Run with ReleaseFast**

Run: `zig build bench-parse_small -Doptimize=ReleaseFast`
Expected: exit 0, noticeably lower `p50_ns`.

- [ ] **Step 2.5: Record baseline in a top-of-file comment**

Edit `bench/parse_small.zig`. Insert directly after the module docstring a block of the form:

```zig
// Baseline (Debug, zig 0.16.0, Linux x86_64):
//   p50_ns=<PASTE FROM STEP 2.3>, p99_ns=<...>, peak=<...> B
// Baseline (ReleaseFast):
//   p50_ns=<PASTE FROM STEP 2.4>, p99_ns=<...>, peak=<...> B
// These numbers are reference-only; docs/PERFORMANCE.md is the
// source of truth for regression thresholds.
```

Fill `<PASTE ...>` with the actual numbers observed.

- [ ] **Step 2.6: Commit**

```bash
git add bench/parse_small.zig build.zig
git commit -m "feat(bench): add parse_small microbenchmark + build wiring

Part of GAP-0011."
```

---

## Task 3: `parse_large`

**Files:**

- Create: `bench/parse_large.zig`
- Modify: `build.zig` (append entry to `bench_specs`)

- [ ] **Step 3.1: Add the spec entry (will fail)**

In `build.zig`, modify the `bench_specs` array to read:

```zig
    const bench_specs = [_]BenchSpec{
        .{ .name = "parse_small", .root = "bench/parse_small.zig" },
        .{ .name = "parse_large", .root = "bench/parse_large.zig" },
    };
```

Run: `zig build bench-parse_large`
Expected: FAIL -- `FileNotFound`.

- [ ] **Step 3.2: Create `bench/parse_large.zig`**

```zig
// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros

//! Bench: parse a 1 MiB synthetic TOML generated from a fixed seed.

const std = @import("std");
const toml = @import("toml");
const common = @import("common.zig");
const inputs = @import("inputs.zig");

const TARGET_BYTES: usize = 1 * 1024 * 1024;

// Generated once per process; reused across iterations.
var g_input: ?[]u8 = null;

fn work(alloc: std.mem.Allocator) !void {
    var doc = try toml.parse(alloc, g_input.?, .{});
    doc.deinit();
}

pub fn runAndPrint(alloc: std.mem.Allocator) !common.Stats {
    g_input = try inputs.generateLarge(alloc, TARGET_BYTES);
    defer {
        alloc.free(g_input.?);
        g_input = null;
    }
    std.debug.assert(g_input.?.len >= TARGET_BYTES);

    const stats = try common.runBench("parse_large", alloc, 3, 50, work);
    try stats.printHuman(std.io.getStdErr().writer());
    return stats;
}

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{
        .enable_memory_limit = true,
        .retain_metadata = true,
    }) = .{};
    defer _ = gpa.deinit();

    const stats = try runAndPrint(gpa.allocator());
    try stats.printCsv(std.io.getStdOut().writer());
}
```

- [ ] **Step 3.3: Run and record baseline**

Run: `zig build bench-parse_large -Doptimize=ReleaseFast`
Expected: exit 0, CSV line `parse_large,50,...` on stdout.

Copy `p50_ns` / `p99_ns` / `peak` into a `// Baseline (ReleaseFast): ...` comment at the top of `bench/parse_large.zig`, mirroring Task 2.5.

- [ ] **Step 3.4: Commit**

```bash
git add bench/parse_large.zig build.zig
git commit -m "feat(bench): add parse_large (1 MiB synthetic) microbenchmark

Part of GAP-0011."
```

---

## Task 4: `parse_wide_table`

**Files:**

- Create: `bench/parse_wide_table.zig`
- Modify: `build.zig`

This benchmark specifically exercises the table-key lookup path (P-1 / P-2 in `docs/PERF_GAP_ANALYSIS.md`). A 10 000-key table surfaces any O(n²) behavior loud and clear.

- [ ] **Step 4.1: Add spec entry (will fail)**

Append to `bench_specs`:

```zig
        .{ .name = "parse_wide_table", .root = "bench/parse_wide_table.zig" },
```

Run: `zig build bench-parse_wide_table`
Expected: FAIL -- `FileNotFound`.

- [ ] **Step 4.2: Create `bench/parse_wide_table.zig`**

```zig
// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros

//! Bench: single table with 10 000 keys. Stresses table-key lookup +
//! insertion (P-1 / P-2 in docs/PERF_GAP_ANALYSIS.md).

const std = @import("std");
const toml = @import("toml");
const common = @import("common.zig");
const inputs = @import("inputs.zig");

const KEY_COUNT: usize = 10_000;

var g_input: ?[]u8 = null;

fn work(alloc: std.mem.Allocator) !void {
    var doc = try toml.parse(alloc, g_input.?, .{});
    doc.deinit();
}

pub fn runAndPrint(alloc: std.mem.Allocator) !common.Stats {
    g_input = try inputs.generateWideTable(alloc, KEY_COUNT);
    defer {
        alloc.free(g_input.?);
        g_input = null;
    }
    const stats = try common.runBench("parse_wide_table", alloc, 3, 50, work);
    try stats.printHuman(std.io.getStdErr().writer());
    return stats;
}

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{
        .enable_memory_limit = true,
        .retain_metadata = true,
    }) = .{};
    defer _ = gpa.deinit();

    const stats = try runAndPrint(gpa.allocator());
    try stats.printCsv(std.io.getStdOut().writer());
}
```

- [ ] **Step 4.3: Run and record baseline**

Run: `zig build bench-parse_wide_table -Doptimize=ReleaseFast`
Expected: exit 0. Record baseline numbers in a top-of-file comment.

- [ ] **Step 4.4: Commit**

```bash
git add bench/parse_wide_table.zig build.zig
git commit -m "feat(bench): add parse_wide_table (10k keys) microbenchmark

Part of GAP-0011."
```

---

## Task 5: `parse_deep_nest`

**Files:**

- Create: `bench/parse_deep_nest.zig`
- Modify: `build.zig`

- [ ] **Step 5.1: Add spec entry (will fail)**

Append to `bench_specs`:

```zig
        .{ .name = "parse_deep_nest", .root = "bench/parse_deep_nest.zig" },
```

Run: `zig build bench-parse_deep_nest`
Expected: FAIL -- `FileNotFound`.

- [ ] **Step 5.2: Create `bench/parse_deep_nest.zig`**

```zig
// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros

//! Bench: 64-deep nested inline tables + arrays. Exercises recursion +
//! stack frames in the value parser.

const std = @import("std");
const toml = @import("toml");
const common = @import("common.zig");
const inputs = @import("inputs.zig");

const DEPTH: usize = 64;

var g_input: ?[]u8 = null;

fn work(alloc: std.mem.Allocator) !void {
    var doc = try toml.parse(alloc, g_input.?, .{});
    doc.deinit();
}

pub fn runAndPrint(alloc: std.mem.Allocator) !common.Stats {
    g_input = try inputs.generateDeepNest(alloc, DEPTH);
    defer {
        alloc.free(g_input.?);
        g_input = null;
    }
    const stats = try common.runBench("parse_deep_nest", alloc, 100, 5_000, work);
    try stats.printHuman(std.io.getStdErr().writer());
    return stats;
}

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{
        .enable_memory_limit = true,
        .retain_metadata = true,
    }) = .{};
    defer _ = gpa.deinit();

    const stats = try runAndPrint(gpa.allocator());
    try stats.printCsv(std.io.getStdOut().writer());
}
```

- [ ] **Step 5.3: Run and record baseline**

Run: `zig build bench-parse_deep_nest -Doptimize=ReleaseFast`
Expected: exit 0. Record baseline in a top-of-file comment.

- [ ] **Step 5.4: Commit**

```bash
git add bench/parse_deep_nest.zig build.zig
git commit -m "feat(bench): add parse_deep_nest (depth 64) microbenchmark

Part of GAP-0011."
```

---

## Task 6: `parse_strings`

**Files:**

- Create: `bench/parse_strings.zig`
- Modify: `build.zig`

- [ ] **Step 6.1: Add spec entry (will fail)**

Append to `bench_specs`:

```zig
        .{ .name = "parse_strings", .root = "bench/parse_strings.zig" },
```

Run: `zig build bench-parse_strings`
Expected: FAIL -- `FileNotFound`.

- [ ] **Step 6.2: Create `bench/parse_strings.zig`**

```zig
// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros

//! Bench: 2 000 escape-heavy basic + multiline strings. Exercises the
//! lexer's escape-sequence decoder.

const std = @import("std");
const toml = @import("toml");
const common = @import("common.zig");
const inputs = @import("inputs.zig");

const STRING_COUNT: usize = 2_000;

var g_input: ?[]u8 = null;

fn work(alloc: std.mem.Allocator) !void {
    var doc = try toml.parse(alloc, g_input.?, .{});
    doc.deinit();
}

pub fn runAndPrint(alloc: std.mem.Allocator) !common.Stats {
    g_input = try inputs.generateStrings(alloc, STRING_COUNT);
    defer {
        alloc.free(g_input.?);
        g_input = null;
    }
    const stats = try common.runBench("parse_strings", alloc, 5, 100, work);
    try stats.printHuman(std.io.getStdErr().writer());
    return stats;
}

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{
        .enable_memory_limit = true,
        .retain_metadata = true,
    }) = .{};
    defer _ = gpa.deinit();

    const stats = try runAndPrint(gpa.allocator());
    try stats.printCsv(std.io.getStdOut().writer());
}
```

- [ ] **Step 6.3: Run and record baseline**

Run: `zig build bench-parse_strings -Doptimize=ReleaseFast`
Expected: exit 0. Record baseline in a top-of-file comment.

- [ ] **Step 6.4: Commit**

```bash
git add bench/parse_strings.zig build.zig
git commit -m "feat(bench): add parse_strings escape-heavy microbenchmark

Part of GAP-0011."
```

---

## Task 7: `parse_datetime`

**Files:**

- Create: `bench/parse_datetime.zig`
- Modify: `build.zig`

- [ ] **Step 7.1: Add spec entry (will fail)**

Append to `bench_specs`:

```zig
        .{ .name = "parse_datetime", .root = "bench/parse_datetime.zig" },
```

Run: `zig build bench-parse_datetime`
Expected: FAIL -- `FileNotFound`.

- [ ] **Step 7.2: Create `bench/parse_datetime.zig`**

```zig
// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros

//! Bench: 5 000 datetime assignments mixing offset/local datetime, local
//! date, local time. Exercises the datetime parser.

const std = @import("std");
const toml = @import("toml");
const common = @import("common.zig");
const inputs = @import("inputs.zig");

const DT_COUNT: usize = 5_000;

var g_input: ?[]u8 = null;

fn work(alloc: std.mem.Allocator) !void {
    var doc = try toml.parse(alloc, g_input.?, .{});
    doc.deinit();
}

pub fn runAndPrint(alloc: std.mem.Allocator) !common.Stats {
    g_input = try inputs.generateDateTimes(alloc, DT_COUNT);
    defer {
        alloc.free(g_input.?);
        g_input = null;
    }
    const stats = try common.runBench("parse_datetime", alloc, 5, 100, work);
    try stats.printHuman(std.io.getStdErr().writer());
    return stats;
}

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{
        .enable_memory_limit = true,
        .retain_metadata = true,
    }) = .{};
    defer _ = gpa.deinit();

    const stats = try runAndPrint(gpa.allocator());
    try stats.printCsv(std.io.getStdOut().writer());
}
```

- [ ] **Step 7.3: Run and record baseline**

Run: `zig build bench-parse_datetime -Doptimize=ReleaseFast`
Expected: exit 0. Record baseline in a top-of-file comment.

- [ ] **Step 7.4: Commit**

```bash
git add bench/parse_datetime.zig build.zig
git commit -m "feat(bench): add parse_datetime microbenchmark

Part of GAP-0011."
```

---

## Task 8: `parallel_parse`

**Files:**

- Create: `bench/parallel_parse.zig`
- Modify: `build.zig`

- [ ] **Step 8.1: Add spec entry (will fail)**

Append to `bench_specs`:

```zig
        .{ .name = "parallel_parse", .root = "bench/parallel_parse.zig" },
```

Run: `zig build bench-parallel_parse`
Expected: FAIL -- `FileNotFound`.

- [ ] **Step 8.2: Create `bench/parallel_parse.zig`**

```zig
// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros

//! Bench: parallel.parseDocuments across N in {4, 16, 64, 256}.
//! Each input is the small handwritten config; we measure total wall
//! time to fan out + join.

const std = @import("std");
const toml = @import("toml");
const common = @import("common.zig");
const inputs = @import("inputs.zig");

const N_SIZES = [_]usize{ 4, 16, 64, 256 };

const Ctx = struct {
    inputs: []const []const u8,
    results: []toml.parallel.ParseResult,
};

var g_ctx: Ctx = undefined;

fn work(alloc: std.mem.Allocator) !void {
    toml.parallel.parseDocuments(alloc, g_ctx.inputs, g_ctx.results);
    // parseDocuments writes into the caller-owned results slice; the
    // slices themselves do not allocate per call (validator-only),
    // so there is nothing to free here. Sanity-check every result.
    for (g_ctx.results) |r| {
        if (!r.success) return error.ParseFailed;
    }
}

pub fn runAndPrint(alloc: std.mem.Allocator) !common.Stats {
    const stderr = std.io.getStdErr().writer();
    var last: common.Stats = undefined;
    for (N_SIZES) |n| {
        const in_slices = try alloc.alloc([]const u8, n);
        defer alloc.free(in_slices);
        for (in_slices) |*s| s.* = inputs.small_config;

        const results = try alloc.alloc(toml.parallel.ParseResult, n);
        defer alloc.free(results);

        g_ctx = .{ .inputs = in_slices, .results = results };

        const nm = try std.fmt.allocPrint(alloc, "parallel_parse_n{d}", .{n});
        defer alloc.free(nm);

        var stats = try common.runBench(
            "parallel_parse",
            alloc,
            3,
            if (n >= 64) 50 else 200,
            work,
        );
        // runBench's name parameter is comptime; overwrite for display.
        stats.name = nm;
        try stats.printHuman(stderr);
        last = stats;
    }
    return last;
}

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{
        .enable_memory_limit = true,
        .retain_metadata = true,
    }) = .{};
    defer _ = gpa.deinit();

    const alloc = gpa.allocator();
    const stdout = std.io.getStdOut().writer();
    const stderr = std.io.getStdErr().writer();

    // main duplicates the per-size loop so every N emits its own CSV row.
    for (N_SIZES) |n| {
        const in_slices = try alloc.alloc([]const u8, n);
        defer alloc.free(in_slices);
        for (in_slices) |*s| s.* = inputs.small_config;

        const results = try alloc.alloc(toml.parallel.ParseResult, n);
        defer alloc.free(results);

        g_ctx = .{ .inputs = in_slices, .results = results };

        const nm = try std.fmt.allocPrint(alloc, "parallel_parse_n{d}", .{n});
        defer alloc.free(nm);

        var stats = try common.runBench(
            "parallel_parse",
            alloc,
            3,
            if (n >= 64) 50 else 200,
            work,
        );
        stats.name = nm;
        try stats.printCsv(stdout);
        try stats.printHuman(stderr);
    }
}
```

- [ ] **Step 8.3: Run and record baseline**

Run: `zig build bench-parallel_parse -Doptimize=ReleaseFast`
Expected: exit 0, four CSV lines (`parallel_parse_n4`, `..._n16`, `..._n64`, `..._n256`) on stdout.

Record representative numbers (at least `n4` and `n256`) in a top-of-file comment in `bench/parallel_parse.zig`.

- [ ] **Step 8.4: Commit**

```bash
git add bench/parallel_parse.zig build.zig
git commit -m "feat(bench): add parallel_parse microbenchmark (N=4..256)

Part of GAP-0011."
```

---

## Task 9: `bench-all` orchestrator with summary table

The aggregate `bench` step already depends on every per-benchmark executable (set up in Task 2). This task adds a separate orchestrator that runs all benchmarks inside a single process and prints a single formatted table. This is the step most humans will invoke.

**Files:**

- Create: `bench/main.zig`
- Modify: `build.zig` (add a `bench-all` step)

- [ ] **Step 9.1: Create `bench/main.zig`**

```zig
// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros

//! Run every benchmark in sequence and print a single formatted table.
//! Intended for humans. CI should prefer the per-benchmark steps so a
//! single benchmark failure does not hide the others.

const std = @import("std");
const common = @import("common.zig");

const parse_small = @import("parse_small.zig");
const parse_large = @import("parse_large.zig");
const parse_wide_table = @import("parse_wide_table.zig");
const parse_deep_nest = @import("parse_deep_nest.zig");
const parse_strings = @import("parse_strings.zig");
const parse_datetime = @import("parse_datetime.zig");
const parallel_parse = @import("parallel_parse.zig");

const Entry = struct {
    name: []const u8,
    run: *const fn (alloc: std.mem.Allocator) anyerror!common.Stats,
};

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{
        .enable_memory_limit = true,
        .retain_metadata = true,
    }) = .{};
    defer _ = gpa.deinit();
    const a = gpa.allocator();

    const entries = [_]Entry{
        .{ .name = "parse_small", .run = parse_small.runAndPrint },
        .{ .name = "parse_large", .run = parse_large.runAndPrint },
        .{ .name = "parse_wide_table", .run = parse_wide_table.runAndPrint },
        .{ .name = "parse_deep_nest", .run = parse_deep_nest.runAndPrint },
        .{ .name = "parse_strings", .run = parse_strings.runAndPrint },
        .{ .name = "parse_datetime", .run = parse_datetime.runAndPrint },
        // parallel_parse.runAndPrint prints all N sizes to stderr and
        // returns the final (n=256) sample for the summary row.
        .{ .name = "parallel_parse", .run = parallel_parse.runAndPrint },
    };

    var all_stats = std.ArrayList(common.Stats){};
    defer all_stats.deinit(a);

    const stdout = std.io.getStdOut().writer();
    const stderr = std.io.getStdErr().writer();

    // CSV header on stderr so pipelines that redirect stdout still have
    // a column key.
    try stderr.writeAll("name,iters,ops_per_sec,p50_ns,p99_ns,bytes_peak,bytes_total\n");
    for (entries) |e| {
        const s = try e.run(a);
        try all_stats.append(a, s);
        try s.printCsv(stdout);
    }

    // Human-readable table at the end.
    try stderr.writeAll("\n=== bench summary ===\n");
    for (all_stats.items) |s| try s.printHuman(stderr);
}
```

- [ ] **Step 9.2: Add a `bench-all` build step**

In `build.zig`, immediately below the existing `for (bench_specs) |spec| { ... }` loop, add:

```zig
    // Aggregate orchestrator (bench/main.zig). Runs everything in one
    // process and prints a summary table. Separate step so a single
    // benchmark failure does not hide the others.
    const bench_all_mod = b.createModule(.{
        .root_source_file = b.path("bench/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "toml", .module = toml_mod },
        },
    });
    if (tp_mod) |tm| bench_all_mod.addImport("thread_pool", tm);
    const bench_all_exe = b.addExecutable(.{
        .name = "bench-all",
        .root_module = bench_all_mod,
    });
    const run_bench_all = b.addRunArtifact(bench_all_exe);
    run_bench_all.step.dependOn(b.getInstallStep());
    const bench_all_step = b.step("bench-all", "Run all benchmarks in one process");
    bench_all_step.dependOn(&run_bench_all.step);
```

- [ ] **Step 9.3: Run the orchestrator**

Run: `zig build bench-all -Doptimize=ReleaseFast`
Expected: exit 0. stdout carries 7 CSV rows (the `parallel_parse` row is the n=256 one returned by `runAndPrint`; the other three N sizes go to stderr). stderr ends with an `=== bench summary ===` block listing every benchmark.

- [ ] **Step 9.4: Run the existing aggregate too, to confirm it still works**

Run: `zig build bench -Doptimize=ReleaseFast`
Expected: exit 0. Each per-benchmark executable runs once.

- [ ] **Step 9.5: Commit**

```bash
git add bench/main.zig build.zig
git commit -m "feat(bench): add bench-all orchestrator + summary table

Part of GAP-0011."
```

---

## Task 10: CI wiring (allow_failure)

**Files:**

- Modify: `.gitlab-ci.yml`

- [ ] **Step 10.1: Add a `bench` stage**

Edit `/home/benji/src/devnw/zig/toml/.gitlab-ci.yml`. In the `stages:` list, insert `bench` between `fuzz` and `security` so the list reads:

```yaml
stages:
  - lint
  - build
  - test
  - fuzz
  - bench
  - security
  - sbom
  - release
```

- [ ] **Step 10.2: Append the bench job at the end of the file**

```yaml
# Microbenchmark harness (GAP-0011).
# allow_failure: true -- benchmarks publish results only; they do not
# gate merges yet. A follow-up will add regression thresholds (see
# docs/PERFORMANCE.md).
bench:
  stage: bench
  image: debian:bookworm-slim
  before_script:
    - *install-zig
  script:
    - zig build bench-all -Doptimize=ReleaseFast 2>bench.stderr | tee bench.csv
  artifacts:
    when: always
    paths:
      - bench.csv
      - bench.stderr
    expire_in: 4 weeks
  allow_failure: true
  needs:
    - build
```

- [ ] **Step 10.3: Validate YAML locally**

Run: `python3 -c "import yaml; yaml.safe_load(open('.gitlab-ci.yml'))"`
Expected: exit 0, no output.

- [ ] **Step 10.4: Commit**

```bash
git add .gitlab-ci.yml
git commit -m "ci(bench): add allow_failure bench stage publishing bench.csv

Part of GAP-0011."
```

---

## Task 11: `docs/PERFORMANCE.md`

**Files:**

- Create: `docs/PERFORMANCE.md`

- [ ] **Step 11.1: Write the file**

Exact content (replace every `<N>` with numbers captured in Tasks 2.5, 3.3, 4.3, 5.3, 6.3, 7.3, 8.3):

````markdown
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

# Filter by name
zig build bench -Dbench-filter=parse -Doptimize=ReleaseFast
```

All benchmarks live under `bench/`. Input generators live in
`bench/inputs.zig` and are seeded from fixed compile-time constants, so
output is byte-identical across runs.

## Baselines

All numbers below are `ReleaseFast`, Zig 0.16.0, Linux x86_64. Column
definitions:

- `iters`  - number of measured iterations (after warmup)
- `p50_ns` - median wall-clock per iteration
- `p99_ns` - 99th percentile wall-clock per iteration
- `peak_B` - peak outstanding bytes observed across timed iterations

| Benchmark           | iters  | p50_ns | p99_ns | peak_B |
|---                  |---:    |---:    |---:    |---:    |
| parse_small         | 10 000 | <N>    | <N>    | <N>    |
| parse_large (1 MiB) | 50     | <N>    | <N>    | <N>    |
| parse_wide_table    | 50     | <N>    | <N>    | <N>    |
| parse_deep_nest     | 5 000  | <N>    | <N>    | <N>    |
| parse_strings       | 100    | <N>    | <N>    | <N>    |
| parse_datetime      | 100    | <N>    | <N>    | <N>    |
| parallel_parse n4   | 200    | <N>    | <N>    | <N>    |
| parallel_parse n16  | 200    | <N>    | <N>    | <N>    |
| parallel_parse n64  | 50     | <N>    | <N>    | <N>    |
| parallel_parse n256 | 50     | <N>    | <N>    | <N>    |

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
- `parallel_parse` currently exercises the shadow validator in
  `src/parallel.zig` rather than the real parser (see GAP-0001). Once
  GAP-0001 closes, expect its numbers to move materially.
- `peak_B` is observed by the bench harness's `CountingAllocator`
  wrapper and includes the internal arena the parser uses.
````

- [ ] **Step 11.2: Fill in the baseline numbers**

Re-run `zig build bench-all -Doptimize=ReleaseFast 2>/dev/null` and transcribe each CSV row into the table above. Replace every `<N>`.

- [ ] **Step 11.3: Commit**

```bash
git add docs/PERFORMANCE.md
git commit -m "docs(perf): add PERFORMANCE.md with baseline table + policy

Part of GAP-0011."
```

---

## Task 12: Update `docs/ARCHITECTURE.md`

**Files:**

- Modify: `docs/ARCHITECTURE.md`

- [ ] **Step 12.1: Locate the unverified Big-O claims**

Run: `grep -n 'O(n)\|O(k)\|O(1)\|O(n\^2)\|O(n²)' docs/ARCHITECTURE.md`
Expected: 1+ lines printed.

- [ ] **Step 12.2: Replace each claim with a benchmark reference**

For every matched line, replace the inline Big-O assertion with a pointer.

Before (example pattern):

```markdown
Lexing is O(n) in the input length and table lookup is O(k) in the key length.
```

After:

```markdown
See [`docs/PERFORMANCE.md`](PERFORMANCE.md) for measured per-component
baselines. Big-O claims made before 2026-04 are no longer authoritative
-- trust the benchmark table.
```

Apply the same treatment to every Big-O claim found in Step 12.1.

- [ ] **Step 12.3: Add a `Benchmarks` section at the end of the file**

Append:

```markdown

## Benchmarks

Microbenchmarks live under `bench/` and are wired as `zig build bench-<name>`.
Baselines and the regression-threshold policy are in
[`docs/PERFORMANCE.md`](PERFORMANCE.md).
```

- [ ] **Step 12.4: Commit**

```bash
git add docs/ARCHITECTURE.md
git commit -m "docs(arch): replace unverified big-O claims with bench reference

Part of GAP-0011."
```

---

## Task 13: CHANGELOG + gap closure

**Files:**

- Modify: `CHANGELOG.md`
- Modify: `docs/GAP_ANALYSIS.md` (mark GAP-0011 closed)
- Modify: `docs/GAP_ANALYSIS_RESOLVED.md` (append the resolved entry)

- [ ] **Step 13.1: Add CHANGELOG entry**

Read `CHANGELOG.md`. Under the `## [Unreleased]` heading (create one if it doesn't exist), add under an `### Added` subsection:

```markdown
- Microbenchmark suite (`zig build bench`, `zig build bench-all`,
  `-Dbench-filter=<name>`). Seven benchmarks covering small/large/wide/
  deeply-nested/escape-heavy/datetime-heavy parsing plus
  `parallel.parseDocuments` across N in {4, 16, 64, 256}. See
  `docs/PERFORMANCE.md` for baselines. Closes GAP-0011.
```

- [ ] **Step 13.2: Mark GAP-0011 closed in `docs/GAP_ANALYSIS.md`**

Find the `### GAP-0011: Bench suite not implemented` section (around lines 133-142 at time of writing). Insert a new line immediately after the heading:

```markdown
- **Status:** Closed (2026-04-18) -- see commits in this PR and `docs/PERFORMANCE.md`.
```

- [ ] **Step 13.3: Mirror into `docs/GAP_ANALYSIS_RESOLVED.md`**

Open `docs/GAP_ANALYSIS_RESOLVED.md` first and study its format. Append a new entry that matches the existing structure verbatim (fields, indentation, section ordering). Use the closed GAP-0011 text from Step 13.2 as the source.

- [ ] **Step 13.4: Run full test suite to confirm nothing else broke**

Run: `zig build test`
Expected: exit 0. Benchmarks are not part of the test graph, so their presence must not affect `zig build test`.

Run: `zig build check`
Expected: exit 0.

- [ ] **Step 13.5: Commit**

```bash
git add CHANGELOG.md docs/GAP_ANALYSIS.md docs/GAP_ANALYSIS_RESOLVED.md
git commit -m "feat(bench): close GAP-0011 -- benchmark suite

Adds CHANGELOG entry, flips GAP-0011 to Closed, and records the
resolved entry in GAP_ANALYSIS_RESOLVED.md."
```

---

## Task 14: Self-review pass

- [ ] **Step 14.1: Verify `zig build test` still passes**

Run: `zig build test`
Expected: exit 0, no leak-detector output.

- [ ] **Step 14.2: Verify every bench step runs**

Run each in turn:

```bash
zig build bench-parse_small -Doptimize=ReleaseFast
zig build bench-parse_large -Doptimize=ReleaseFast
zig build bench-parse_wide_table -Doptimize=ReleaseFast
zig build bench-parse_deep_nest -Doptimize=ReleaseFast
zig build bench-parse_strings -Doptimize=ReleaseFast
zig build bench-parse_datetime -Doptimize=ReleaseFast
zig build bench-parallel_parse -Doptimize=ReleaseFast
zig build bench-all -Doptimize=ReleaseFast
zig build bench -Doptimize=ReleaseFast
```

Expected: every invocation exits 0.

- [ ] **Step 14.3: Verify `-Dbench-filter` works**

Run: `zig build bench -Dbench-filter=parse_small -Doptimize=ReleaseFast`
Expected: only `parse_small` runs.

Run: `zig build bench -Dbench-filter=nonexistent -Doptimize=ReleaseFast`
Expected: exit 0, zero benchmarks run (no errors).

- [ ] **Step 14.4: Verify CI yaml parses**

Run: `python3 -c "import yaml; yaml.safe_load(open('.gitlab-ci.yml'))"`
Expected: exit 0.

- [ ] **Step 14.5: Verify `docs/PERFORMANCE.md` has no `<N>` left**

Run: `grep -n '<N>' docs/PERFORMANCE.md`
Expected: no output.

- [ ] **Step 14.6: Verify formatting**

Run: `zig fmt --check bench/ build.zig`
Expected: exit 0, no output.

- [ ] **Step 14.7: Final commit (only if self-review uncovered fixes)**

If any of 14.1-14.6 surfaced an issue and you fixed it, commit the fix:

```bash
git add -A
git commit -m "fix(bench): self-review corrections for GAP-0011 closure"
```

If nothing was broken, skip this step -- the preceding commits stand.

---

## Spec coverage check

| Spec requirement | Task(s) |
|---|---|
| `bench/parse_small.zig` -- 1 KB config | Task 2 |
| `bench/parse_large.zig` -- 1 MB synthetic | Task 3 |
| `bench/parse_wide_table.zig` -- 10 k keys | Task 4 |
| `bench/parse_deep_nest.zig` -- deep nesting | Task 5 |
| `bench/parse_strings.zig` -- escape-heavy | Task 6 |
| `bench/parse_datetime.zig` -- datetime | Task 7 |
| `bench/parallel_parse.zig` -- N in {4,16,64,256} | Task 8 |
| Report ops/s, alloc bytes, wall-clock p50/p99 | Task 1 (`Stats`, `runBench`) |
| `zig build bench [-Dbench-filter=name]` | Task 2 (filter), Task 9 (orchestrator) |
| `bench/common.zig` with `runBench` helper | Task 1 |
| Warmup iterations before measurement | Task 1 (`warmup` param; Tasks 2-8 pass non-zero) |
| Deterministic seeded inputs | Task 1 (`seededPrng`) + Task 1 generators (all fixed seeds) |
| GPA with `enable_memory_limit=true`, `retain_metadata=true` | Tasks 2-8 (every `main`) |
| Baseline measurements captured in comments | Tasks 2.5, 3.3, 4.3, 5.3, 6.3, 7.3, 8.3 |
| CI `bench` stage with `allow_failure: true` | Task 10 |
| Top-level `bench` step that prints a table | Task 9 (`bench-all`) |
| Update `docs/ARCHITECTURE.md` to reference benchmarks | Task 12 |
| Add CHANGELOG entry | Task 13.1 |
| Add `docs/PERFORMANCE.md` | Task 11 |
| Commit `feat(bench): close GAP-0011 -- benchmark suite` | Task 13.5 |

All spec items are covered. If a subsequent reading of the spec surfaces a gap, add a new task rather than folding it quietly into an existing one.
