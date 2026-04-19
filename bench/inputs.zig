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
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(alloc);
    try buf.ensureTotalCapacity(alloc, target_bytes + 4096);

    var prng = common.seededPrng(0xDEADBEEF);
    const rnd = prng.random();

    var n: usize = 0;
    while (buf.items.len < target_bytes) : (n += 1) {
        try buf.print(alloc, "[section.n{d}]\n", .{n});
        try buf.print(alloc, "id = {d}\n", .{rnd.int(i32)});
        try buf.print(alloc, "name = \"item-{d}\"\n", .{n});
        try buf.print(alloc, "weight = {d}\n", .{rnd.int(u16)});
        try buf.print(alloc, "ratio = {d:.4}\n", .{rnd.float(f64)});
        try buf.print(
            alloc,
            "enabled = {s}\n",
            .{if (rnd.boolean()) "true" else "false"},
        );
        try buf.appendSlice(alloc, "tags = [\"a\", \"b\", \"c\"]\n");
        try buf.print(alloc, "count = {d}\n", .{rnd.int(u32)});
        try buf.print(alloc, "offset_ms = {d}\n", .{rnd.int(i16)});
        try buf.print(
            alloc,
            "flag_a = {s}\n",
            .{if (rnd.boolean()) "true" else "false"},
        );
        try buf.print(
            alloc,
            "flag_b = {s}\n",
            .{if (rnd.boolean()) "true" else "false"},
        );
        try buf.append(alloc, '\n');
    }

    return buf.toOwnedSlice(alloc);
}

/// One `[wide]` table followed by `count` keys `k_0 = 0` .. `k_{count-1} = N`.
/// Exercises table-key lookup + insertion on a single hot path.
pub fn generateWideTable(alloc: std.mem.Allocator, count: usize) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(alloc);
    try buf.ensureTotalCapacity(alloc, count * 16 + 64);

    try buf.appendSlice(alloc, "[wide]\n");
    var i: usize = 0;
    while (i < count) : (i += 1) {
        try buf.print(alloc, "k_{d} = {d}\n", .{ i, i });
    }
    return buf.toOwnedSlice(alloc);
}

/// `depth`-deep nested inline-table + array: `a = { b = { c = [ { d = ...`
/// produces a valid TOML value whose parse-tree depth equals `depth`.
pub fn generateDeepNest(alloc: std.mem.Allocator, depth: usize) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(alloc);
    try buf.ensureTotalCapacity(alloc, depth * 8 + 16);

    try buf.appendSlice(alloc, "root = ");
    var i: usize = 0;
    while (i < depth) : (i += 1) {
        // Alternate inline tables and arrays so we hit both code paths.
        if (i % 2 == 0)
            try buf.appendSlice(alloc, "{ n = ")
        else
            try buf.appendSlice(alloc, "[ ");
    }
    try buf.appendSlice(alloc, "42");
    i = 0;
    while (i < depth) : (i += 1) {
        // Unwind in reverse order: the innermost opener is the last one we
        // wrote, so close it first. Opener i matches closer (depth-1-i).
        const j = depth - 1 - i;
        if (j % 2 == 0)
            try buf.appendSlice(alloc, " }")
        else
            try buf.appendSlice(alloc, " ]");
    }
    try buf.append(alloc, '\n');
    return buf.toOwnedSlice(alloc);
}

/// `count` escape-heavy strings (basic + multiline).
pub fn generateStrings(alloc: std.mem.Allocator, count: usize) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(alloc);
    try buf.ensureTotalCapacity(alloc, count * 96);

    var prng = common.seededPrng(0xCAFEBABE);
    const rnd = prng.random();

    var i: usize = 0;
    while (i < count) : (i += 1) {
        if (rnd.boolean()) {
            try buf.print(
                alloc,
                "s_{d} = \"line\\tone\\nline\\ttwo\\u00e9\\u00ff\\\"quoted\\\"end\"\n",
                .{i},
            );
        } else {
            try buf.print(
                alloc,
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
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(alloc);
    try buf.ensureTotalCapacity(alloc, count * 48);

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
            0 => try buf.print(
                alloc,
                "dt_{d} = {d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z\n",
                .{ i, year, mon, day, hh, mm, ss },
            ),
            1 => try buf.print(
                alloc,
                "dt_{d} = {d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}\n",
                .{ i, year, mon, day, hh, mm, ss },
            ),
            2 => try buf.print(
                alloc,
                "dt_{d} = {d:0>4}-{d:0>2}-{d:0>2}\n",
                .{ i, year, mon, day },
            ),
            3 => try buf.print(
                alloc,
                "dt_{d} = {d:0>2}:{d:0>2}:{d:0>2}\n",
                .{ i, hh, mm, ss },
            ),
            else => unreachable,
        }
    }
    return buf.toOwnedSlice(alloc);
}
