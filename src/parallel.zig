// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! Parallel TOML operations using thread-pool flat task submission.
//!
//! Provides high-performance parallel implementations for batch TOML
//! document parsing and validation.
//!
//! ## Overview
//!
//! This module enables parallel processing of TOML operations
//! using the thread-pool library with submitBatch/WaitGroup. Operations
//! automatically fall back to sequential processing when the pool is
//! unavailable or input sizes are below thresholds.
//!
//! ## Build Configuration
//!
//! Enable parallel processing with `-Dthread-pool=true` (default: enabled).
//! Disable with `-Dthread-pool=false` for sequential-only execution.
//!
//! ## Usage Example
//!
//! ```zig
//! const parallel = @import("parallel.zig");
//!
//! // Parse multiple TOML documents in parallel
//! var inputs: [16][]const u8 = undefined;
//! var results: [16]parallel.ParseResult = undefined;
//!
//! // Initialize inputs with TOML content...
//! parallel.parseDocuments(allocator, &inputs, &results);
//!
//! // Validate multiple TOML documents
//! var valid_results: [16]parallel.ValidateResult = undefined;
//! parallel.validateDocuments(&inputs, &valid_results);
//!
//! // Cleanup: call deinitPool() when done
//! parallel.deinitPool();
//! ```
//!
//! ## Performance Thresholds
//!
//! | Operation          | Threshold    | Sequential Below |
//! |--------------------|--------------|------------------|
//! | Document Parse     | 4 documents  | Yes              |
//! | Document Validate  | 8 documents  | Yes              |
//! | Key Extract        | 8 documents  | Yes              |

const std = @import("std");
const tp = @import("thread_pool");
const toml = @import("toml.zig");
const Document = toml.Document;

// ============================================================================
// Caller-Owned Thread Pool (Q-4 / S-4 / S-5 / P-7)
// ============================================================================
//
// Prior versions exposed a process-global `?tp.ThreadPool` behind a mutex.
// That singleton had three concrete defects:
//
//   Q-4 / S-4 (CWE-416): `getPool` returned a raw `*tp.ThreadPool` pointer;
//     another thread calling `deinitPool` could free the pool while the
//     first thread still held that pointer.
//   S-5 (CWE-248/400):  `@panic("thread-pool: init failed")` on allocator
//     failure turned a recoverable OOM into a DoS vector for library
//     consumers who had no way to opt in to non-panicking behavior.
//   P-7:                 The global used `std.heap.page_allocator`; every
//     call took the mutex just to check a non-null pointer.
//
// The new shape is a `ParallelContext` the caller owns. `initDefault`
// returns `!*ParallelContext`, `deinit` joins workers then frees the pool,
// and the batch entry points are methods so the pool pointer cannot be
// observed without a live reference to the context.
//
// The legacy `getPool` / `deinitPool` / free-function entry points remain
// for one deprecation cycle. They route through a lazily-initialized
// `legacy_ctx` global. Because `std.once` does not exist in Zig 0.16 we
// implement the once-guard manually via an atomic "done" flag checked
// on the hot path plus a mutex that only contends on the very first
// call. After initialization completes, `callLegacyOnce` performs a
// single acquire load and returns without locking. `getPool` now
// returns `!*tp.ThreadPool` rather than a raw pointer. `deinitPool`
// tears down the legacy context if it was constructed. Because no
// concurrent-caller synchronization is possible on a process-global
// singleton without reference counting, calling `deinitPool` while
// other threads hold pointers returned by `getPool()` is undefined
// behavior — which is exactly why the whole thing is deprecated.

/// A caller-owned parallel execution context. Holds the thread pool and
/// the allocator used to create it. Call `initDefault` to build one with
/// the process default allocator, or construct via `initWithPool` to
/// pass a custom `*tp.ThreadPool`.
///
/// Lifecycle: `ParallelContext` is NOT thread-safe to deinit concurrently
/// with calls to its methods. The expected usage is:
///
///     var ctx = try ParallelContext.initDefault(allocator);
///     defer ctx.deinit();
///     ctx.parseDocuments(&inputs, &results);
///
/// All three batch entry points (`parseDocuments`, `validateDocuments`,
/// `extractKeys`) are safe to invoke concurrently from multiple threads
/// so long as the `ParallelContext` itself is not being deinit-ed.
pub const ParallelContext = struct {
    allocator: std.mem.Allocator,
    pool: *tp.ThreadPool,
    /// True if this context allocated its own pool via initDefault and
    /// must free it in deinit. False if the caller constructed the
    /// struct via initWithPool and retains lifetime responsibility.
    owns_pool: bool,

    /// Construct a context with a private thread pool using the system
    /// default thread count. Returns an error — never panics — on pool
    /// allocation failure. Closes S-5.
    pub fn initDefault(allocator: std.mem.Allocator) !*ParallelContext {
        const pool = try allocator.create(tp.ThreadPool);
        errdefer allocator.destroy(pool);
        pool.* = try tp.ThreadPool.init(allocator, .{});
        errdefer pool.deinit();

        const ctx = try allocator.create(ParallelContext);
        ctx.* = .{
            .allocator = allocator,
            .pool = pool,
            .owns_pool = true,
        };
        return ctx;
    }

    /// Wrap a pool the caller already owns. `deinit` will NOT free the
    /// pool; the caller retains lifetime responsibility.
    pub fn initWithPool(
        allocator: std.mem.Allocator,
        pool: *tp.ThreadPool,
    ) !*ParallelContext {
        const ctx = try allocator.create(ParallelContext);
        ctx.* = .{
            .allocator = allocator,
            .pool = pool,
            .owns_pool = false,
        };
        return ctx;
    }

    /// Joins all workers, frees the owned pool (if any), and destroys
    /// the context itself. Safe to call exactly once.
    pub fn deinit(self: *ParallelContext) void {
        if (self.owns_pool) {
            self.pool.deinit();
            self.allocator.destroy(self.pool);
        }
        self.allocator.destroy(self);
    }

    // Method wrappers around the free functions defined later in this
    // file. These exist so the method-call form works in the
    // Q-4/S-4 test and in example code.

    pub fn parseDocuments(
        self: *ParallelContext,
        inputs: []const []const u8,
        results: []ParseResult,
    ) void {
        parseDocumentsCtx(self, inputs, results);
    }

    pub fn validateDocuments(
        self: *ParallelContext,
        inputs: []const []const u8,
        results: []ValidateResult,
    ) void {
        validateDocumentsCtx(self, inputs, results);
    }

    pub fn extractKeys(
        self: *ParallelContext,
        inputs: []const []const u8,
        results: []KeyExtractResult,
    ) void {
        extractKeysCtx(self, inputs, results);
    }
};

// ============================================================================
// Legacy global pool (deprecated — will be removed in 0.3.0)
// ============================================================================
//
// Zig 0.16 removed `std.once`, so we implement the once-guard manually:
//
//   legacy_done: atomic flag — set to true after the first (possibly
//     failing) initialization attempt.
//   legacy_init_mutex: acquired only when `legacy_done == false`. The
//     first thread through runs `legacyInit`; subsequent threads observe
//     `legacy_done == true` and skip the mutex entirely.
//
// This makes the hot path a single acquire atomic load with no mutex
// contention after startup — matching the P-7 goal.

var legacy_done = std.atomic.Value(bool).init(false);
var legacy_init_mutex: tp.sync.Mutex = .{};
var legacy_ctx: ?*ParallelContext = null;
var legacy_init_error: ?anyerror = null;

fn legacyInit() void {
    legacy_ctx = ParallelContext.initDefault(std.heap.page_allocator) catch |e| blk: {
        legacy_init_error = e;
        break :blk null;
    };
}

/// Ensure `legacyInit` has been called exactly once across all threads.
/// Fast path: atomic acquire load observes `true` → no lock taken.
/// Slow path: acquire the mutex, re-check under lock, run init, publish
/// `true` with release semantics so other threads see a fully
/// initialized `legacy_ctx` / `legacy_init_error`.
fn callLegacyOnce() void {
    if (legacy_done.load(.acquire)) return;
    legacy_init_mutex.lock();
    defer legacy_init_mutex.unlock();
    if (legacy_done.load(.monotonic)) return;
    legacyInit();
    legacy_done.store(true, .release);
}

/// Deprecated. Use `ParallelContext.initDefault` instead.
/// Returns the legacy process-global thread pool. Unlike the prior
/// version, this returns an error rather than @panicking.
pub fn getPool() !*tp.ThreadPool {
    callLegacyOnce();
    if (legacy_init_error) |e| return e;
    const ctx = legacy_ctx orelse return error.ThreadPoolInitFailed;
    return ctx.pool;
}

/// Deprecated. Callers should own a `ParallelContext` and call
/// `ctx.deinit()` instead.
///
/// For backward compatibility this still tears down the legacy global
/// pool if it was lazily constructed. See the module-level comment for
/// UB caveats when other threads hold pointers.
pub fn deinitPool() void {
    legacy_init_mutex.lock();
    defer legacy_init_mutex.unlock();
    if (legacy_ctx) |ctx| {
        ctx.deinit();
        legacy_ctx = null;
    }
    legacy_init_error = null;
    legacy_done.store(false, .release);
}

// ============================================================================
// Parse Result Types
// ============================================================================

/// Result of TOML document parsing.
///
/// Ownership: when `success` is true, `doc` holds the parsed Document.
/// The caller MUST call `result.doc.?.deinit()` (or iterate the result
/// array and deinit every non-null doc) to free the per-document arena.
/// When `success` is false, `doc` is null and `error_code` / `error_line`
/// / `error_column` describe the failure.
pub const ParseResult = struct {
    /// Whether parsing succeeded.
    success: bool = false,
    /// Error code mapped from `toml.ErrorCode`; 0 indicates success.
    error_code: u8 = 0,
    /// 1-based error line (if failed).
    error_line: ?usize = null,
    /// 1-based error column (if failed).
    error_column: ?usize = null,
    /// Number of top-level keys in the root table when `success` is true.
    key_count: usize = 0,
    /// Parsed document when `success` is true. Caller owns — must deinit.
    doc: ?*Document = null,
};

// ============================================================================
// Parallel Document Parsing
// ============================================================================

const MAX_CHUNKS = 64;

const ParseChunk = struct {
    allocator: std.mem.Allocator,
    inputs: []const []const u8,
    results: []ParseResult,
};

// Each call to parseDocument asks toml.parseWithError to build a
// private ArenaAllocator seeded from chunk.allocator. The caller's
// allocator is only ever reached via alloc/free on arena pages, which
// std.mem.Allocator implementations (including std.testing.allocator
// and std.heap.GeneralPurposeAllocator with thread_safe=true) guarantee
// to be safe for concurrent access. The per-result Document therefore
// owns a distinct arena whose lifetime ends when the caller calls
// result.doc.?.deinit().
fn parseChunkTask(ctx_ptr: *anyopaque, _: *tp.TaskContext) void {
    const chunk: *ParseChunk = @ptrCast(@alignCast(ctx_ptr));
    for (chunk.inputs, 0..) |input, i| {
        chunk.results[i] = parseDocument(chunk.allocator, input);
    }
}

/// Parse multiple TOML documents in parallel using the given context.
///
/// Each document is parsed independently. This is ideal for batch
/// processing configuration files.
pub fn parseDocumentsCtx(
    ctx: *ParallelContext,
    inputs: []const []const u8,
    results: []ParseResult,
) void {
    std.debug.assert(inputs.len == results.len);

    if (inputs.len < 4) {
        for (inputs, 0..) |input, i| {
            results[i] = parseDocument(ctx.allocator, input);
        }
        return;
    }

    const pool = ctx.pool;
    // Ceiling division ensures every input is placed into exactly one chunk.
    const chunk_size = @max(1, (inputs.len + MAX_CHUNKS - 1) / MAX_CHUNKS);
    var chunks: [MAX_CHUNKS]ParseChunk = undefined;
    var batch: [MAX_CHUNKS]tp.BatchTask = undefined;
    var n: usize = 0;
    var i: usize = 0;
    while (i < inputs.len and n < MAX_CHUNKS) {
        const end = @min(i + chunk_size, inputs.len);
        chunks[n] = .{
            .allocator = ctx.allocator,
            .inputs = inputs[i..end],
            .results = results[i..end],
        };
        batch[n] = .{ .task_fn = &parseChunkTask, .ctx = @ptrCast(&chunks[n]) };
        n += 1;
        i = end;
    }
    var wg = pool.waitGroup();
    _ = pool.submitBatch(batch[0..n], .{ .wait_group = &wg }) catch {
        for (inputs, 0..) |input, j| results[j] = parseDocument(ctx.allocator, input);
        return;
    };
    wg.wait();
}

/// Deprecated. Use `ParallelContext.parseDocuments` or
/// `parseDocumentsCtx`. This shim borrows the legacy global pool for
/// scheduling but uses the caller-supplied allocator for chunk and
/// document allocations (preserving the pre-refactor contract that
/// every Document's arena is seeded from the caller's allocator).
/// Silently falls back to sequential processing on pool initialization
/// failure instead of @panicking.
///
/// Parameters:
/// - allocator: Memory allocator for parsing
/// - inputs: Array of TOML document strings
/// - results: Array to store parsing results
///
/// Threshold: Uses parallel processing for 4+ documents
pub fn parseDocuments(
    allocator: std.mem.Allocator,
    inputs: []const []const u8,
    results: []ParseResult,
) void {
    std.debug.assert(inputs.len == results.len);

    if (inputs.len < 4) {
        for (inputs, 0..) |input, i| {
            results[i] = parseDocument(allocator, input);
        }
        return;
    }

    callLegacyOnce();
    const legacy = legacy_ctx orelse {
        for (inputs, 0..) |input, i| {
            results[i] = parseDocument(allocator, input);
        }
        return;
    };

    const pool = legacy.pool;
    const chunk_size = @max(1, (inputs.len + MAX_CHUNKS - 1) / MAX_CHUNKS);
    var chunks: [MAX_CHUNKS]ParseChunk = undefined;
    var batch: [MAX_CHUNKS]tp.BatchTask = undefined;
    var n: usize = 0;
    var i: usize = 0;
    while (i < inputs.len and n < MAX_CHUNKS) {
        const end = @min(i + chunk_size, inputs.len);
        chunks[n] = .{
            .allocator = allocator,
            .inputs = inputs[i..end],
            .results = results[i..end],
        };
        batch[n] = .{ .task_fn = &parseChunkTask, .ctx = @ptrCast(&chunks[n]) };
        n += 1;
        i = end;
    }
    var wg = pool.waitGroup();
    _ = pool.submitBatch(batch[0..n], .{ .wait_group = &wg }) catch {
        for (inputs, 0..) |input, j| results[j] = parseDocument(allocator, input);
        return;
    };
    wg.wait();
}

fn parseDocument(allocator: std.mem.Allocator, input: []const u8) ParseResult {
    // Route through the real parser. toml.parseWithError returns a
    // tagged union (ok|err) so we don't lose diagnostic info on failure.
    const r = toml.parseWithError(allocator, input, .{});
    switch (r) {
        .ok => |doc_val| {
            // Count top-level keys in the root table.
            var key_count: usize = 0;
            switch (doc_val.root.*) {
                .table => |*t| key_count = t.map.count(),
                else => {},
            }
            return .{
                .success = true,
                .error_code = 0,
                .error_line = null,
                .error_column = null,
                .key_count = key_count,
                .doc = doc_val,
            };
        },
        .err => |pe| {
            // Map ErrorCode to a nonzero u8. We use @intFromEnum + 1 so
            // 0 stays reserved for "success". Valid ErrorCode ordinals
            // are 0..19 today — well inside u8.
            const code_u8: u8 = @intCast(@intFromEnum(pe.code) + 1);
            return .{
                .success = false,
                .error_code = code_u8,
                .error_line = @intCast(pe.line),
                .error_column = @intCast(pe.column),
                .key_count = 0,
                .doc = null,
            };
        },
    }
}

// ============================================================================
// Validation Types
// ============================================================================

/// Result of TOML validation
pub const ValidateResult = struct {
    /// Whether document is valid TOML
    valid: bool,
    /// Error code (0 = valid)
    error_code: u8,
    /// Error description
    error_msg: ?[]const u8,
};

// ============================================================================
// Parallel Document Validation
// ============================================================================

const ValidateChunk = struct {
    inputs: []const []const u8,
    results: []ValidateResult,
};

fn validateChunkTask(ctx_ptr: *anyopaque, _: *tp.TaskContext) void {
    const chunk: *ValidateChunk = @ptrCast(@alignCast(ctx_ptr));
    for (chunk.inputs, 0..) |input, i| {
        chunk.results[i] = validateDocument(input);
    }
}

/// Validate multiple TOML documents in parallel using the given context.
pub fn validateDocumentsCtx(
    ctx: *ParallelContext,
    inputs: []const []const u8,
    results: []ValidateResult,
) void {
    std.debug.assert(inputs.len == results.len);

    if (inputs.len < 8) {
        for (inputs, 0..) |input, i| {
            results[i] = validateDocument(input);
        }
        return;
    }

    const pool = ctx.pool;
    const chunk_size = @max(1, (inputs.len + MAX_CHUNKS - 1) / MAX_CHUNKS);
    var chunks: [MAX_CHUNKS]ValidateChunk = undefined;
    var batch: [MAX_CHUNKS]tp.BatchTask = undefined;
    var n: usize = 0;
    var i: usize = 0;
    while (i < inputs.len and n < MAX_CHUNKS) {
        const end = @min(i + chunk_size, inputs.len);
        chunks[n] = .{ .inputs = inputs[i..end], .results = results[i..end] };
        batch[n] = .{ .task_fn = &validateChunkTask, .ctx = @ptrCast(&chunks[n]) };
        n += 1;
        i = end;
    }
    var wg = pool.waitGroup();
    _ = pool.submitBatch(batch[0..n], .{ .wait_group = &wg }) catch {
        for (inputs, 0..) |input, j| results[j] = validateDocument(input);
        return;
    };
    wg.wait();
}

/// Deprecated. Use `ParallelContext.validateDocuments` or
/// `validateDocumentsCtx`. Borrows the legacy global pool for
/// scheduling; validateDocument itself uses an internal ArenaAllocator
/// seeded from `std.heap.page_allocator` so no caller allocator is
/// required on this path.
///
/// Performs syntax validation without full parsing.
///
/// Parameters:
/// - inputs: Array of TOML document strings
/// - results: Array to store validation results
///
/// Threshold: Uses parallel processing for 8+ documents
pub fn validateDocuments(
    inputs: []const []const u8,
    results: []ValidateResult,
) void {
    std.debug.assert(inputs.len == results.len);

    if (inputs.len < 8) {
        for (inputs, 0..) |input, i| {
            results[i] = validateDocument(input);
        }
        return;
    }

    callLegacyOnce();
    if (legacy_ctx) |ctx| {
        validateDocumentsCtx(ctx, inputs, results);
    } else {
        for (inputs, 0..) |input, i| {
            results[i] = validateDocument(input);
        }
    }
}

fn validateDocument(input: []const u8) ValidateResult {
    // Route through the real parser and discard the Document. Each call
    // gets its own ArenaAllocator so we can drain it on scope exit
    // without touching any caller-provided allocator.
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const r = toml.parseWithError(alloc, input, .{});
    switch (r) {
        .ok => |doc_val| {
            // Drop the Document (the arena above covers its memory). We do
            // NOT call doc_val.deinit() — doing so would double-free the
            // nested ArenaAllocator the parser built. The parser's arena
            // lives inside ours; when our arena deinit fires it will free
            // all allocations including the parser's arena metadata.
            _ = doc_val;
            return .{ .valid = true, .error_code = 0, .error_msg = null };
        },
        .err => |pe| {
            const code_u8: u8 = @intCast(@intFromEnum(pe.code) + 1);
            return .{
                .valid = false,
                .error_code = code_u8,
                // pe.message is a static string literal (ParseError's
                // message field is populated via makeError with a
                // `comptime []const u8`). Safe to carry out past this
                // function's arena.
                .error_msg = pe.message,
            };
        },
    }
}

// ============================================================================
// Key Extraction Types
// ============================================================================

/// Result of key extraction
pub const KeyExtractResult = struct {
    /// Extracted keys (comma-separated)
    keys: ?[]u8,
    /// Number of keys found
    count: usize,
    /// Whether extraction succeeded
    success: bool,
};

// ============================================================================
// Parallel Key Extraction
// ============================================================================

const KeyExtractChunk = struct {
    allocator: std.mem.Allocator,
    inputs: []const []const u8,
    results: []KeyExtractResult,
};

fn keyExtractChunkTask(ctx_ptr: *anyopaque, _: *tp.TaskContext) void {
    const chunk: *KeyExtractChunk = @ptrCast(@alignCast(ctx_ptr));
    for (chunk.inputs, 0..) |input, i| {
        chunk.results[i] = extractKeysFromDocument(chunk.allocator, input);
    }
}

/// Extract top-level keys from multiple TOML documents in parallel
/// using the given context.
pub fn extractKeysCtx(
    ctx: *ParallelContext,
    inputs: []const []const u8,
    results: []KeyExtractResult,
) void {
    std.debug.assert(inputs.len == results.len);

    if (inputs.len < 8) {
        for (inputs, 0..) |input, i| {
            results[i] = extractKeysFromDocument(ctx.allocator, input);
        }
        return;
    }

    const pool = ctx.pool;
    const chunk_size = @max(1, (inputs.len + MAX_CHUNKS - 1) / MAX_CHUNKS);
    var chunks: [MAX_CHUNKS]KeyExtractChunk = undefined;
    var batch: [MAX_CHUNKS]tp.BatchTask = undefined;
    var n: usize = 0;
    var i: usize = 0;
    while (i < inputs.len and n < MAX_CHUNKS) {
        const end = @min(i + chunk_size, inputs.len);
        chunks[n] = .{
            .allocator = ctx.allocator,
            .inputs = inputs[i..end],
            .results = results[i..end],
        };
        batch[n] = .{ .task_fn = &keyExtractChunkTask, .ctx = @ptrCast(&chunks[n]) };
        n += 1;
        i = end;
    }
    var wg = pool.waitGroup();
    _ = pool.submitBatch(batch[0..n], .{ .wait_group = &wg }) catch {
        for (inputs, 0..) |input, j| results[j] = extractKeysFromDocument(ctx.allocator, input);
        return;
    };
    wg.wait();
}

/// Deprecated. Use `ParallelContext.extractKeys` or `extractKeysCtx`.
/// Borrows the legacy global pool for scheduling but uses the
/// caller-supplied allocator for the per-result key buffers (preserving
/// the pre-refactor contract that `result.keys` is allocated from the
/// caller's allocator).
///
/// Parameters:
/// - allocator: Memory allocator for key strings
/// - inputs: Array of TOML document strings
/// - results: Array to store extraction results
///
/// Threshold: Uses parallel processing for 8+ documents
pub fn extractKeys(
    allocator: std.mem.Allocator,
    inputs: []const []const u8,
    results: []KeyExtractResult,
) void {
    std.debug.assert(inputs.len == results.len);

    if (inputs.len < 8) {
        for (inputs, 0..) |input, i| {
            results[i] = extractKeysFromDocument(allocator, input);
        }
        return;
    }

    callLegacyOnce();
    const legacy = legacy_ctx orelse {
        for (inputs, 0..) |input, i| {
            results[i] = extractKeysFromDocument(allocator, input);
        }
        return;
    };

    const pool = legacy.pool;
    const chunk_size = @max(1, (inputs.len + MAX_CHUNKS - 1) / MAX_CHUNKS);
    var chunks: [MAX_CHUNKS]KeyExtractChunk = undefined;
    var batch: [MAX_CHUNKS]tp.BatchTask = undefined;
    var n: usize = 0;
    var i: usize = 0;
    while (i < inputs.len and n < MAX_CHUNKS) {
        const end = @min(i + chunk_size, inputs.len);
        chunks[n] = .{
            .allocator = allocator,
            .inputs = inputs[i..end],
            .results = results[i..end],
        };
        batch[n] = .{ .task_fn = &keyExtractChunkTask, .ctx = @ptrCast(&chunks[n]) };
        n += 1;
        i = end;
    }
    var wg = pool.waitGroup();
    _ = pool.submitBatch(batch[0..n], .{ .wait_group = &wg }) catch {
        for (inputs, 0..) |input, j| results[j] = extractKeysFromDocument(allocator, input);
        return;
    };
    wg.wait();
}

fn extractKeysFromDocument(allocator: std.mem.Allocator, input: []const u8) KeyExtractResult {
    // Use an inner arena so the parser's allocations are freed on return
    // regardless of success/failure. We copy top-level key strings into
    // the caller-provided allocator before the arena is drained.
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const parse_alloc = arena.allocator();

    const r = toml.parseWithError(parse_alloc, input, .{});
    switch (r) {
        .err => {
            return .{ .keys = null, .count = 0, .success = false };
        },
        .ok => |doc_val| {
            // doc_val owns a nested arena inside parse_alloc, but because
            // the outer arena will reclaim everything we don't call
            // doc_val.deinit() — same rationale as validateDocument.
            const root = doc_val.root;
            switch (root.*) {
                .table => |*t| {
                    const n = t.map.count();
                    if (n == 0) {
                        return .{ .keys = null, .count = 0, .success = true };
                    }
                    const keys_slice = t.map.keys();
                    var buf: std.ArrayList(u8) = .empty;
                    errdefer buf.deinit(allocator);
                    // Capacity hint: total bytes = sum(key_len) + (N-1) commas.
                    var cap: usize = 0;
                    for (keys_slice) |k| cap += k.len;
                    cap += n -| 1;
                    buf.ensureTotalCapacity(allocator, cap) catch {
                        return .{ .keys = null, .count = 0, .success = false };
                    };
                    for (keys_slice, 0..) |k, i| {
                        if (i > 0) buf.append(allocator, ',') catch {
                            buf.deinit(allocator);
                            return .{ .keys = null, .count = 0, .success = false };
                        };
                        buf.appendSlice(allocator, k) catch {
                            buf.deinit(allocator);
                            return .{ .keys = null, .count = 0, .success = false };
                        };
                    }
                    const owned = buf.toOwnedSlice(allocator) catch {
                        return .{ .keys = null, .count = 0, .success = false };
                    };
                    return .{ .keys = owned, .count = n, .success = true };
                },
                else => {
                    // root is always a table per the TOML grammar. Defensive fallback.
                    return .{ .keys = null, .count = 0, .success = true };
                },
            }
        },
    }
}

// ============================================================================
// Tests
// ============================================================================

test "parse document - valid" {
    const allocator = std.testing.allocator;
    var ctx = try ParallelContext.initDefault(allocator);
    defer ctx.deinit();

    const inputs = [_][]const u8{
        \\name = "test"
        \\version = "1.0.0"
    };
    var results: [1]ParseResult = undefined;

    ctx.parseDocuments(&inputs, &results);
    defer {
        for (&results) |*r| if (r.doc) |d| d.deinit();
    }

    try std.testing.expect(results[0].success);
    try std.testing.expectEqual(@as(usize, 2), results[0].key_count);
    try std.testing.expect(results[0].doc != null);
}

test "parse document - unclosed string" {
    const allocator = std.testing.allocator;
    var ctx = try ParallelContext.initDefault(allocator);
    defer ctx.deinit();

    const inputs = [_][]const u8{
        \\name = "unclosed
    };
    var results: [1]ParseResult = undefined;

    ctx.parseDocuments(&inputs, &results);
    defer {
        for (&results) |*r| if (r.doc) |d| d.deinit();
    }

    try std.testing.expect(!results[0].success);
    try std.testing.expect(results[0].error_code != 0);
    try std.testing.expect(results[0].error_line != null);
    try std.testing.expect(results[0].doc == null);
}

test "parse document - multiline string" {
    const allocator = std.testing.allocator;
    var ctx = try ParallelContext.initDefault(allocator);
    defer ctx.deinit();

    const inputs = [_][]const u8{
        \\desc = """
        \\This is a
        \\multiline string
        \\"""
    };
    var results: [1]ParseResult = undefined;

    ctx.parseDocuments(&inputs, &results);
    defer {
        for (&results) |*r| if (r.doc) |d| d.deinit();
    }

    try std.testing.expect(results[0].success);
}

test "validate document - valid" {
    const allocator = std.testing.allocator;
    var ctx = try ParallelContext.initDefault(allocator);
    defer ctx.deinit();

    const inputs = [_][]const u8{
        \\[package]
        \\name = "test"
    };
    var results: [1]ValidateResult = undefined;

    ctx.validateDocuments(&inputs, &results);

    try std.testing.expect(results[0].valid);
}

test "validate document - invalid utf8" {
    const allocator = std.testing.allocator;
    var ctx = try ParallelContext.initDefault(allocator);
    defer ctx.deinit();

    const inputs = [_][]const u8{&[_]u8{ 0xFF, 0xFE }};
    var results: [1]ValidateResult = undefined;

    ctx.validateDocuments(&inputs, &results);

    try std.testing.expect(!results[0].valid);
    // Real parser emits ErrorCode.InvalidUtf8 (ordinal 0) -> code 1.
    try std.testing.expect(results[0].error_code != 0);
}

test "validate document - null byte" {
    const allocator = std.testing.allocator;
    var ctx = try ParallelContext.initDefault(allocator);
    defer ctx.deinit();

    const inputs = [_][]const u8{"name\x00= \"test\""};
    var results: [1]ValidateResult = undefined;

    ctx.validateDocuments(&inputs, &results);

    try std.testing.expect(!results[0].valid);
    // Real parser emits an UnexpectedToken or InvalidControlCharacter
    // depending on lexer state; old shadow emitted exactly 3. Loosen.
    try std.testing.expect(results[0].error_code != 0);
}

test "Q-2 validate document rejects grammar-invalid input" {
    // The old validateDocument only checked UTF-8, bare CR, null bytes,
    // and bracket depth. It silently accepted grammar errors like
    // `a = = 1`. After Q-2 the validator routes through the real parser
    // and must reject all inputs the real parser rejects.
    const allocator = std.testing.allocator;
    var ctx = try ParallelContext.initDefault(allocator);
    defer ctx.deinit();

    const grammar_invalid = [_][]const u8{
        "a = = 1\n",
        "[unclosed\n",
        "a = 1\na = 2\n",
        "a = \"bad\\q\"\n",
    };
    var results: [grammar_invalid.len]ValidateResult = undefined;
    ctx.validateDocuments(&grammar_invalid, &results);

    for (results, 0..) |r, i| {
        if (r.valid) {
            std.debug.print(
                "\nQ-2 divergence at case[{d}]: input {s} was accepted by validateDocument but rejected by toml.parse\n",
                .{ i, grammar_invalid[i] },
            );
            try std.testing.expect(false);
        }
    }
}

test "extract keys - basic" {
    const allocator = std.testing.allocator;
    var ctx = try ParallelContext.initDefault(allocator);
    defer ctx.deinit();

    const inputs = [_][]const u8{
        \\name = "test"
        \\version = "1.0"
    };
    var results: [1]KeyExtractResult = undefined;

    ctx.extractKeys(&inputs, &results);

    try std.testing.expect(results[0].success);
    try std.testing.expectEqual(@as(usize, 2), results[0].count);
    if (results[0].keys) |keys| {
        defer allocator.free(keys);
        try std.testing.expectEqualStrings("name,version", keys);
    }
}

test "extract keys - empty document" {
    const allocator = std.testing.allocator;
    var ctx = try ParallelContext.initDefault(allocator);
    defer ctx.deinit();

    const inputs = [_][]const u8{"# Just a comment"};
    var results: [1]KeyExtractResult = undefined;

    ctx.extractKeys(&inputs, &results);

    try std.testing.expect(results[0].success);
    try std.testing.expectEqual(@as(usize, 0), results[0].count);
}

test "GAP-0001 extractKeys uses real parser — inline tables + quoted keys" {
    // The old extractor split on `=` per-line and returned keys like
    // "pt" for `pt = { x = 1, y = 2 }` (correct) but also wrongly
    // returned "x" and "y" as top-level keys because it did not
    // recognize inline tables. It also mishandled quoted keys
    // containing `=` and dotted keys.
    const allocator = std.testing.allocator;
    var ctx = try ParallelContext.initDefault(allocator);
    defer ctx.deinit();

    const inputs = [_][]const u8{
        // Inline table: only `pt` is top-level. Old extractor returned
        // pt, x, y.
        \\pt = { x = 1, y = 2 }
        \\name = "zig"
        ,
        // Quoted key with `=`: the key is literally `a=b`. Old extractor
        // split at the first `=` and called it `"a`.
        "\"a=b\" = 42\n",
        // Dotted key: root table has exactly one top-level key, `a`.
        // Old extractor returned `a.b.c`.
        "a.b.c = 1\n",
    };
    var results: [inputs.len]KeyExtractResult = undefined;
    ctx.extractKeys(&inputs, &results);
    defer for (&results) |*r| if (r.keys) |k| allocator.free(k);

    // Case 0: inline table + sibling key.
    try std.testing.expect(results[0].success);
    try std.testing.expectEqual(@as(usize, 2), results[0].count);
    if (results[0].keys) |k| {
        // Keys are joined by ',' in insertion order. Root entries are
        // `pt` and `name`.
        try std.testing.expectEqualStrings("pt,name", k);
    } else try std.testing.expect(false);

    // Case 1: quoted key containing `=`.
    try std.testing.expect(results[1].success);
    try std.testing.expectEqual(@as(usize, 1), results[1].count);
    if (results[1].keys) |k| {
        try std.testing.expectEqualStrings("a=b", k);
    } else try std.testing.expect(false);

    // Case 2: dotted key — only `a` is top-level.
    try std.testing.expect(results[2].success);
    try std.testing.expectEqual(@as(usize, 1), results[2].count);
    if (results[2].keys) |k| {
        try std.testing.expectEqualStrings("a", k);
    } else try std.testing.expect(false);
}

test "parallel parse - large batch" {
    const allocator = std.testing.allocator;
    var ctx = try ParallelContext.initDefault(allocator);
    defer ctx.deinit();

    var inputs: [16][]const u8 = undefined;
    for (&inputs) |*input| {
        input.* = "key = \"value\"";
    }
    var results: [16]ParseResult = undefined;

    ctx.parseDocuments(&inputs, &results);
    defer {
        for (&results) |*r| if (r.doc) |d| d.deinit();
    }

    for (results) |result| {
        try std.testing.expect(result.success);
        try std.testing.expectEqual(@as(usize, 1), result.key_count);
    }
}

test "parallel validate - large batch" {
    const allocator = std.testing.allocator;
    var ctx = try ParallelContext.initDefault(allocator);
    defer ctx.deinit();

    var inputs: [16][]const u8 = undefined;
    for (&inputs) |*input| {
        input.* = "[table]\nkey = \"value\"";
    }
    var results: [16]ValidateResult = undefined;

    ctx.validateDocuments(&inputs, &results);

    for (results) |result| {
        try std.testing.expect(result.valid);
    }
}

test "parallel extract keys - large batch" {
    const allocator = std.testing.allocator;
    var ctx = try ParallelContext.initDefault(allocator);
    defer ctx.deinit();

    var inputs: [16][]const u8 = undefined;
    for (&inputs) |*input| {
        input.* = "name = \"test\"\nversion = \"1.0\"";
    }
    var results: [16]KeyExtractResult = undefined;

    ctx.extractKeys(&inputs, &results);

    for (results) |result| {
        try std.testing.expect(result.success);
        try std.testing.expectEqual(@as(usize, 2), result.count);
        if (result.keys) |keys| {
            allocator.free(keys);
        }
    }
}

// Regression test: U-F -- when inputs.len > MAX_CHUNKS (64), the floor
// division chunk_size previously dropped the tail of the batch. Use a
// sentinel-initialized results array to catch any unwritten slot. All three
// parallel entry points (parse/validate/extract) must touch every element.
// ============================================================================
// U-M: Differential tests between parallel.parseDocuments (current
// shape-checker) and toml.parse (real parser). These pin the CURRENT
// divergent behavior in place so when U-A lands (shape-checker replaced
// by the real parser) the contract change is visible as a concrete test
// diff rather than a surprise in consumer code.
//
// xfail note: all three inputs below pass the shape-checker today but
// MUST fail parsing once U-A lands. When updating parallel.parseDocument
// to call toml.parse, flip these expectations from success=true to
// success=false and update error_code to the appropriate value.
// ============================================================================

test "U-M aligned with toml.parse: double equals rejected" {
    const allocator = std.testing.allocator;
    var ctx = try ParallelContext.initDefault(allocator);
    defer ctx.deinit();

    const inputs = [_][]const u8{"a = = 1\n"};
    var results: [1]ParseResult = undefined;

    ctx.parseDocuments(&inputs, &results);
    defer {
        for (&results) |*r| if (r.doc) |d| d.deinit();
    }

    try std.testing.expect(!results[0].success);
    try std.testing.expect(results[0].error_code != 0);
    try std.testing.expect(results[0].error_line != null);
}

test "U-M aligned with toml.parse: unclosed table rejected" {
    const allocator = std.testing.allocator;
    var ctx = try ParallelContext.initDefault(allocator);
    defer ctx.deinit();

    const inputs = [_][]const u8{"[unclosed table\n"};
    var results: [1]ParseResult = undefined;

    ctx.parseDocuments(&inputs, &results);
    defer {
        for (&results) |*r| if (r.doc) |d| d.deinit();
    }

    try std.testing.expect(!results[0].success);
    try std.testing.expect(results[0].error_code != 0);
}

test "U-M aligned with toml.parse: duplicate keys rejected" {
    const allocator = std.testing.allocator;
    var ctx = try ParallelContext.initDefault(allocator);
    defer ctx.deinit();

    const inputs = [_][]const u8{"a = 1\na = 2\n"};
    var results: [1]ParseResult = undefined;

    ctx.parseDocuments(&inputs, &results);
    defer {
        for (&results) |*r| if (r.doc) |d| d.deinit();
    }

    try std.testing.expect(!results[0].success);
    // DuplicateKey is ordinal 4 in ErrorCode; +1 = 5. Don't hardcode the
    // exact value here — enum ordinals change. Just assert nonzero.
    try std.testing.expect(results[0].error_code != 0);
}

test "U-M baseline: toml.parse rejects all U-M fixtures" {
    // Pairing baseline: confirm the REAL parser rejects every input the
    // shape-checker accepted above. If this test starts passing
    // together with the xfail ones above, U-A has landed correctly.
    const fixtures = [_][]const u8{
        "a = = 1\n",
        "[unclosed table\n",
        "a = 1\na = 2\n",
    };
    for (fixtures) |input| {
        const r = toml.parseWithError(std.testing.allocator, input, .{});
        switch (r) {
            .ok => |d| {
                d.deinit();
                try std.testing.expect(false); // real parser must reject
            },
            .err => {},
        }
    }
}

test "U-F no dropped inputs past MAX_CHUNKS - parseDocuments" {
    const allocator = std.testing.allocator;
    var ctx = try ParallelContext.initDefault(allocator);
    defer ctx.deinit();

    const N = 100;
    var inputs: [N][]const u8 = undefined;
    for (&inputs) |*input| input.* = "key = \"value\"";

    // Pre-fill results with a sentinel that cannot be produced by a real parse
    // so any untouched slot will fail the assertion below.
    var results: [N]ParseResult = undefined;
    for (&results) |*r| {
        r.* = .{
            .success = false,
            .error_code = 0xFF,
            .error_line = null,
            .error_column = null,
            .key_count = std.math.maxInt(usize),
            .doc = null,
        };
    }

    ctx.parseDocuments(&inputs, &results);
    defer {
        for (&results) |*r| if (r.doc) |d| d.deinit();
    }

    for (results, 0..) |result, idx| {
        try std.testing.expect(result.error_code != 0xFF); // slot was written
        try std.testing.expect(result.success);
        try std.testing.expectEqual(@as(usize, 1), result.key_count);
        _ = idx;
    }
}

test "U-F no dropped inputs past MAX_CHUNKS - validateDocuments" {
    const allocator = std.testing.allocator;
    var ctx = try ParallelContext.initDefault(allocator);
    defer ctx.deinit();

    const N = 100;
    var inputs: [N][]const u8 = undefined;
    for (&inputs) |*input| input.* = "[table]\nkey = \"value\"";

    var results: [N]ValidateResult = undefined;
    for (&results) |*r| {
        r.* = .{ .valid = false, .error_code = 0xFF, .error_msg = null };
    }

    ctx.validateDocuments(&inputs, &results);

    for (results) |result| {
        try std.testing.expect(result.error_code != 0xFF);
        try std.testing.expect(result.valid);
    }
}

test "U-F no dropped inputs past MAX_CHUNKS - extractKeys" {
    const allocator = std.testing.allocator;
    var ctx = try ParallelContext.initDefault(allocator);
    defer ctx.deinit();

    const N = 100;
    var inputs: [N][]const u8 = undefined;
    for (&inputs) |*input| input.* = "name = \"test\"\nversion = \"1.0\"";

    var results: [N]KeyExtractResult = undefined;
    // Sentinel: count = maxInt signals the slot was never written.
    for (&results) |*r| {
        r.* = .{ .keys = null, .count = std.math.maxInt(usize), .success = false };
    }

    ctx.extractKeys(&inputs, &results);

    for (results) |result| {
        try std.testing.expect(result.count != std.math.maxInt(usize));
        try std.testing.expect(result.success);
        try std.testing.expectEqual(@as(usize, 2), result.count);
        if (result.keys) |keys| allocator.free(keys);
    }
}

// ============================================================================
// GAP-0001: Differential test — parallel.parseDocuments MUST agree with
// toml.parseWithError on both valid and invalid inputs. This test pins the
// contract that parallel path == serial path for accept/reject decisions.
// Before the shadow parser is removed, several xfail fixtures below will
// make this test fail red (the shadow parser accepts inputs the real
// parser rejects). After Task 2 lands the test must pass green.
// ============================================================================

test "GAP-0001 parallel vs serial differential corpus" {
    const allocator = std.testing.allocator;
    var ctx = try ParallelContext.initDefault(allocator);
    defer ctx.deinit();

    const Case = struct {
        input: []const u8,
        expect_success: bool,
        label: []const u8,
    };

    const corpus = [_]Case{
        // --- valid inputs (must accept) ---
        .{ .input = "a = 1\n", .expect_success = true, .label = "simple int" },
        .{ .input = "name = \"zigtoml\"\n", .expect_success = true, .label = "simple string" },
        .{ .input = "[table]\nk = 1\n", .expect_success = true, .label = "table header" },
        .{ .input = "[[arr]]\nk = 1\n", .expect_success = true, .label = "array of tables" },
        .{ .input = "pt = { x = 1, y = 2 }\n", .expect_success = true, .label = "inline table" },
        .{ .input = "a.b.c = 1\n", .expect_success = true, .label = "dotted key" },
        .{ .input = "s = \"\"\"hello\nworld\"\"\"\n", .expect_success = true, .label = "multiline basic string" },
        .{ .input = "s = '''hello\nworld'''\n", .expect_success = true, .label = "multiline literal string" },
        .{ .input = "arr = [1, 2, 3]\n", .expect_success = true, .label = "int array" },
        .{ .input = "x = 0xDEADBEEF\n", .expect_success = true, .label = "hex int" },
        // --- invalid inputs (must reject) ---
        .{ .input = "a = = 1\n", .expect_success = false, .label = "double equals (S-1)" },
        .{ .input = "[unclosed table\n", .expect_success = false, .label = "unclosed table header (S-1)" },
        .{ .input = "a = 1\na = 2\n", .expect_success = false, .label = "duplicate key (S-1)" },
        .{ .input = "a = \"unterminated\n", .expect_success = false, .label = "unterminated string (S-2)" },
        .{ .input = "a = \"bad\\q\"\n", .expect_success = false, .label = "invalid escape" },
        .{ .input = "a = 01\n", .expect_success = false, .label = "leading zero on int" },
        .{ .input = "a = 1.\n", .expect_success = false, .label = "trailing dot on float" },
        .{ .input = "dt = 2024-13-40T99:99:99Z\n", .expect_success = false, .label = "nonsense datetime" },
        .{ .input = "arr = [1, \"two\"]\n", .expect_success = true, .label = "mixed array types (v1.1 allows heterogeneous)" },
        .{ .input = "a = \"bare\x00null\"\n", .expect_success = false, .label = "null in string (S-3)" },
    };

    var inputs: [corpus.len][]const u8 = undefined;
    for (corpus, 0..) |c, i| inputs[i] = c.input;

    var results: [corpus.len]ParseResult = undefined;
    ctx.parseDocuments(&inputs, &results);
    defer {
        for (&results) |*r| if (r.doc) |d| d.deinit();
    }

    for (corpus, 0..) |c, i| {
        // Compute the serial oracle answer.
        const oracle = toml.parseWithError(allocator, c.input, .{});
        var oracle_success: bool = false;
        switch (oracle) {
            .ok => |d| {
                oracle_success = true;
                d.deinit();
            },
            .err => {},
        }

        // Both the corpus-labeled expectation and the oracle must agree.
        try std.testing.expectEqual(c.expect_success, oracle_success);

        // And parallel must agree with serial.
        if (results[i].success != oracle_success) {
            std.debug.print(
                "\nGAP-0001 divergence at case[{d}] '{s}':\n  input  = {s}\n  parallel.success = {}\n  serial.success   = {}\n",
                .{ i, c.label, c.input, results[i].success, oracle_success },
            );
            try std.testing.expect(false);
        }
    }
}

test "Q-4/S-4 ParallelContext is a caller-owned struct" {
    const allocator = std.testing.allocator;
    var ctx = try ParallelContext.initDefault(allocator);
    defer ctx.deinit();

    // Smoke: parseDocuments through the ctx entry point.
    const inputs = [_][]const u8{
        "a = 1\n",
        "b = 2\n",
        "c = 3\n",
        "d = 4\n",
    };
    var results: [4]ParseResult = undefined;
    ctx.parseDocuments(&inputs, &results);
    defer for (&results) |*r| if (r.doc) |d| d.deinit();

    for (results) |r| try std.testing.expect(r.success);
}

test "Q-4 concurrent parseDocuments calls on shared ParallelContext" {
    const allocator = std.testing.allocator;
    var ctx = try ParallelContext.initDefault(allocator);
    defer ctx.deinit();

    // 4 threads, each doing 4 batches of 16 parses.
    const Worker = struct {
        fn run(c: *ParallelContext) void {
            const inputs = [_][]const u8{"k = 1\n"} ** 16;
            var results: [16]ParseResult = undefined;
            var batch: usize = 0;
            while (batch < 4) : (batch += 1) {
                c.parseDocuments(&inputs, &results);
                // Deinit docs each batch to avoid leaking across iterations.
                for (results) |r| {
                    if (!r.success) @panic("expected success in Q-4 stress");
                    if (r.doc) |d| d.deinit();
                }
            }
        }
    };

    var t0 = try std.Thread.spawn(.{}, Worker.run, .{ctx});
    var t1 = try std.Thread.spawn(.{}, Worker.run, .{ctx});
    var t2 = try std.Thread.spawn(.{}, Worker.run, .{ctx});
    var t3 = try std.Thread.spawn(.{}, Worker.run, .{ctx});
    t0.join();
    t1.join();
    t2.join();
    t3.join();
}

test "legacy deprecated: parseDocuments free function still works" {
    const allocator = std.testing.allocator;
    const inputs = [_][]const u8{"a = 1\n"} ** 8;
    var results: [8]ParseResult = undefined;
    parseDocuments(allocator, &inputs, &results);
    defer for (&results) |*r| if (r.doc) |d| d.deinit();
    for (results) |r| try std.testing.expect(r.success);
}

test "legacy deprecated: validateDocuments free function still works" {
    const inputs = [_][]const u8{"a = 1\n"} ** 8;
    var results: [8]ValidateResult = undefined;
    validateDocuments(&inputs, &results);
    for (results) |r| try std.testing.expect(r.valid);
}

test "legacy deprecated: extractKeys free function still works" {
    const allocator = std.testing.allocator;
    const inputs = [_][]const u8{"k = 1\n"} ** 8;
    var results: [8]KeyExtractResult = undefined;
    extractKeys(allocator, &inputs, &results);
    for (results) |r| {
        try std.testing.expect(r.success);
        if (r.keys) |keys| allocator.free(keys);
    }
}
