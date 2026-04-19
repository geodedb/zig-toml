// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros

//! Shared microbenchmark harness (GAP-0011).
//!
//! Not a test: `zig build test` must never depend on this file. Each
//! benchmark's `main()` calls `runBench` and prints one line of CSV to
//! stdout plus a human-readable summary to stderr.
//!
//! Zig 0.16 notes
//! --------------
//! `std.time.Timer` was removed in 0.16. We use `clock_gettime(.MONOTONIC)`
//! directly via `std.posix`. `std.heap.GeneralPurposeAllocator` was renamed
//! to `DebugAllocator`; benchmark entry points use `DebugAllocator(.{})` so
//! we still get leak detection between iterations. Stdout writes go through
//! `std.Io.File.stdout().writerStreaming(init.io, ...)` which requires the
//! `std.process.Init` main signature.

const std = @import("std");

/// Monotonic nanoseconds since an unspecified epoch. Replacement for
/// `std.time.Timer`.
pub fn monotonicNs() u64 {
    var ts: std.posix.timespec = undefined;
    const rc = std.posix.system.clock_gettime(.MONOTONIC, &ts);
    std.debug.assert(std.posix.errno(rc) == .SUCCESS);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s +
        @as(u64, @intCast(ts.nsec));
}

pub const Stats = struct {
    name: []const u8,
    iters: u64,
    total_ns: u64,
    p50_ns: u64,
    p99_ns: u64,
    bytes_peak: usize,
    bytes_total: u64,

    pub fn opsPerSec(self: Stats) f64 {
        if (self.total_ns == 0) return 0;
        const secs = @as(f64, @floatFromInt(self.total_ns)) / 1e9;
        return @as(f64, @floatFromInt(self.iters)) / secs;
    }

    pub fn nsPerIter(self: Stats) f64 {
        if (self.iters == 0) return 0;
        return @as(f64, @floatFromInt(self.total_ns)) /
            @as(f64, @floatFromInt(self.iters));
    }

    /// CSV row: name,iters,ops_per_sec,p50_ns,p99_ns,bytes_peak,bytes_total
    pub fn formatCsv(self: Stats, buf: []u8) ![]const u8 {
        return std.fmt.bufPrint(
            buf,
            "{s},{d},{d:.2},{d},{d},{d},{d}\n",
            .{
                self.name,
                self.iters,
                self.opsPerSec(),
                self.p50_ns,
                self.p99_ns,
                self.bytes_peak,
                self.bytes_total,
            },
        );
    }

    /// Human-readable one-liner. Always succeeds (falls back to truncation).
    pub fn printHuman(self: Stats) void {
        std.debug.print(
            "{s}: {d} iters, {d:.0} ops/s, p50={d} ns, p99={d} ns, peak={d} B\n",
            .{
                self.name,
                self.iters,
                self.opsPerSec(),
                self.p50_ns,
                self.p99_ns,
                self.bytes_peak,
            },
        );
    }
};

/// Allocator wrapper that observes peak outstanding bytes + total bytes
/// requested across a single benchmark run. Wraps any backing allocator.
///
/// All counters are atomic so callers can share one CountingAllocator
/// across worker threads (parallel_parse relies on this). Peak-update is
/// a compare-exchange loop so the observed peak is the true maximum of
/// outstanding bytes seen at any instant, even under contention.
pub const CountingAllocator = struct {
    backing: std.mem.Allocator,
    bytes_outstanding: std.atomic.Value(usize) = .init(0),
    bytes_peak: std.atomic.Value(usize) = .init(0),
    bytes_total: std.atomic.Value(u64) = .init(0),

    pub fn allocator(self: *CountingAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable = std.mem.Allocator.VTable{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn bumpPeak(self: *CountingAllocator, new_outstanding: usize) void {
        var cur = self.bytes_peak.load(.monotonic);
        while (new_outstanding > cur) {
            const prev = self.bytes_peak.cmpxchgWeak(
                cur,
                new_outstanding,
                .monotonic,
                .monotonic,
            );
            if (prev == null) return;
            cur = prev.?;
        }
    }

    fn add(self: *CountingAllocator, n: usize) void {
        const prev = self.bytes_outstanding.fetchAdd(n, .monotonic);
        _ = self.bytes_total.fetchAdd(n, .monotonic);
        self.bumpPeak(prev + n);
    }

    fn sub(self: *CountingAllocator, n: usize) void {
        _ = self.bytes_outstanding.fetchSub(n, .monotonic);
    }

    fn alloc(
        ctx: *anyopaque,
        len: usize,
        alignment: std.mem.Alignment,
        ret: usize,
    ) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const p = self.backing.rawAlloc(len, alignment, ret);
        if (p != null) self.add(len);
        return p;
    }

    fn resize(
        ctx: *anyopaque,
        buf: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ret: usize,
    ) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const ok = self.backing.rawResize(buf, alignment, new_len, ret);
        if (ok) {
            if (new_len > buf.len) {
                self.add(new_len - buf.len);
            } else {
                self.sub(buf.len - new_len);
            }
        }
        return ok;
    }

    fn remap(
        ctx: *anyopaque,
        buf: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ret: usize,
    ) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const p = self.backing.rawRemap(buf, alignment, new_len, ret);
        if (p != null) {
            if (new_len > buf.len) {
                self.add(new_len - buf.len);
            } else {
                self.sub(buf.len - new_len);
            }
        }
        return p;
    }

    fn free(
        ctx: *anyopaque,
        buf: []u8,
        alignment: std.mem.Alignment,
        ret: usize,
    ) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.sub(buf.len);
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
    name: []const u8,
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
        std.debug.assert(counting.bytes_outstanding.load(.monotonic) == 0);
    }

    // Reset peak/total after warmup so we measure only timed iterations.
    counting.bytes_peak.store(0, .monotonic);
    counting.bytes_total.store(0, .monotonic);

    const samples = try backing.alloc(u64, iters);
    defer backing.free(samples);

    const total_start = monotonicNs();

    var i: u64 = 0;
    while (i < iters) : (i += 1) {
        const iter_start = monotonicNs();
        try work(a);
        const iter_end = monotonicNs();
        samples[i] = iter_end - iter_start;
        std.debug.assert(counting.bytes_outstanding.load(.monotonic) == 0);
    }

    const total_ns = monotonicNs() - total_start;

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
        .bytes_peak = counting.bytes_peak.load(.monotonic),
        .bytes_total = counting.bytes_total.load(.monotonic),
    };
}

/// Deterministic RNG seeded from a fixed compile-time seed so every run
/// produces byte-identical inputs. Do NOT use a time-based seed in bench/*.
pub fn seededPrng(seed: u64) std.Random.Xoshiro256 {
    return std.Random.Xoshiro256.init(seed);
}

/// Wrapper around `std.Io.File.stdout()` + `writerStreaming` that returns a
/// `*Writer` interface pointer suitable for `printCsv`. The returned writer
/// is owned by the caller -- call `.flush()` before exit.
pub const StdoutWriter = struct {
    file_writer: std.Io.File.Writer,

    pub fn interface(self: *StdoutWriter) *std.Io.Writer {
        return &self.file_writer.interface;
    }

    pub fn flush(self: *StdoutWriter) !void {
        try self.file_writer.interface.flush();
    }
};

pub fn stdoutWriter(io: std.Io, buf: []u8) StdoutWriter {
    return .{
        .file_writer = std.Io.File.stdout().writerStreaming(io, buf),
    };
}
