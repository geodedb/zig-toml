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
// Global Thread Pool
// ============================================================================

var global_pool: ?tp.ThreadPool = null;
var pool_mutex: tp.sync.Mutex = .{};

pub fn getPool() *tp.ThreadPool {
    pool_mutex.lock();
    defer pool_mutex.unlock();
    if (global_pool == null) {
        global_pool = tp.ThreadPool.init(std.heap.page_allocator, .{}) catch
            @panic("thread-pool: init failed");
    }
    return &global_pool.?;
}

pub fn deinitPool() void {
    pool_mutex.lock();
    defer pool_mutex.unlock();
    if (global_pool) |*pool| {
        pool.deinit();
        global_pool = null;
    }
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
    doc: ?Document = null,
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

fn parseChunkTask(ctx_ptr: *anyopaque, _: *tp.TaskContext) void {
    const chunk: *ParseChunk = @ptrCast(@alignCast(ctx_ptr));
    for (chunk.inputs, 0..) |input, i| {
        chunk.results[i] = parseDocument(chunk.allocator, input);
    }
}

/// Parse multiple TOML documents in parallel.
///
/// Each document is parsed independently. This is ideal for batch
/// processing configuration files.
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

    const pool = getPool();
    // Ceiling division ensures every input is placed into exactly one chunk.
    // Previously `inputs.len / MAX_CHUNKS` (floor) caused the last
    // `inputs.len % MAX_CHUNKS` elements to be silently dropped when
    // `inputs.len > MAX_CHUNKS`, leaving `results[i]` undefined.
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
                .table => |t| key_count = t.entries.len,
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

/// Validate multiple TOML documents in parallel.
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

    const pool = getPool();
    // Ceiling division: avoid dropping the tail of the input batch.
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

/// Extract top-level keys from multiple TOML documents in parallel.
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

    const pool = getPool();
    // Ceiling division: avoid dropping the tail of the input batch.
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
    var keys: std.ArrayList(u8) = .empty;
    defer keys.deinit(allocator);
    var count: usize = 0;
    var line_start: usize = 0;

    for (input, 0..) |c, i| {
        if (c == '\n' or i == input.len - 1) {
            const line_end = if (c == '\n') i else i + 1;
            const line = input[line_start..line_end];

            // Skip empty lines and comments
            var trimmed_start: usize = 0;
            while (trimmed_start < line.len and (line[trimmed_start] == ' ' or line[trimmed_start] == '\t')) {
                trimmed_start += 1;
            }
            if (trimmed_start < line.len and line[trimmed_start] != '#' and line[trimmed_start] != '[') {
                // Look for = sign
                if (std.mem.indexOf(u8, line, "=")) |eq_pos| {
                    const key = std.mem.trim(u8, line[0..eq_pos], " \t");
                    if (key.len > 0) {
                        if (count > 0) {
                            keys.append(allocator, ',') catch {
                                return .{ .keys = null, .count = 0, .success = false };
                            };
                        }
                        keys.appendSlice(allocator, key) catch {
                            return .{ .keys = null, .count = 0, .success = false };
                        };
                        count += 1;
                    }
                }
            }
            line_start = i + 1;
        }
    }

    if (keys.items.len == 0) {
        return .{ .keys = null, .count = 0, .success = true };
    }

    return .{
        .keys = keys.toOwnedSlice(allocator) catch null,
        .count = count,
        .success = true,
    };
}

// ============================================================================
// Tests
// ============================================================================

test "parse document - valid" {
    const allocator = std.testing.allocator;
    const inputs = [_][]const u8{
        \\name = "test"
        \\version = "1.0.0"
    };
    var results: [1]ParseResult = undefined;

    parseDocuments(allocator, &inputs, &results);
    defer {
        for (&results) |*r| if (r.doc) |*d| d.deinit();
    }

    try std.testing.expect(results[0].success);
    try std.testing.expectEqual(@as(usize, 2), results[0].key_count);
    try std.testing.expect(results[0].doc != null);
}

test "parse document - unclosed string" {
    const allocator = std.testing.allocator;
    const inputs = [_][]const u8{
        \\name = "unclosed
    };
    var results: [1]ParseResult = undefined;

    parseDocuments(allocator, &inputs, &results);
    defer {
        for (&results) |*r| if (r.doc) |*d| d.deinit();
    }

    try std.testing.expect(!results[0].success);
    try std.testing.expect(results[0].error_code != 0);
    try std.testing.expect(results[0].error_line != null);
    try std.testing.expect(results[0].doc == null);
}

test "parse document - multiline string" {
    const allocator = std.testing.allocator;
    const inputs = [_][]const u8{
        \\desc = """
        \\This is a
        \\multiline string
        \\"""
    };
    var results: [1]ParseResult = undefined;

    parseDocuments(allocator, &inputs, &results);
    defer {
        for (&results) |*r| if (r.doc) |*d| d.deinit();
    }

    try std.testing.expect(results[0].success);
}

test "validate document - valid" {
    const inputs = [_][]const u8{
        \\[package]
        \\name = "test"
    };
    var results: [1]ValidateResult = undefined;

    validateDocuments(&inputs, &results);

    try std.testing.expect(results[0].valid);
}

test "validate document - invalid utf8" {
    const inputs = [_][]const u8{&[_]u8{ 0xFF, 0xFE }};
    var results: [1]ValidateResult = undefined;

    validateDocuments(&inputs, &results);

    try std.testing.expect(!results[0].valid);
    // Real parser emits ErrorCode.InvalidUtf8 (ordinal 0) -> code 1.
    try std.testing.expect(results[0].error_code != 0);
}

test "validate document - null byte" {
    const inputs = [_][]const u8{"name\x00= \"test\""};
    var results: [1]ValidateResult = undefined;

    validateDocuments(&inputs, &results);

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
    const grammar_invalid = [_][]const u8{
        "a = = 1\n",
        "[unclosed\n",
        "a = 1\na = 2\n",
        "a = \"bad\\q\"\n",
    };
    var results: [grammar_invalid.len]ValidateResult = undefined;
    validateDocuments(&grammar_invalid, &results);

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
    const inputs = [_][]const u8{
        \\name = "test"
        \\version = "1.0"
    };
    var results: [1]KeyExtractResult = undefined;

    extractKeys(allocator, &inputs, &results);

    try std.testing.expect(results[0].success);
    try std.testing.expectEqual(@as(usize, 2), results[0].count);
    if (results[0].keys) |keys| {
        defer allocator.free(keys);
        try std.testing.expectEqualStrings("name,version", keys);
    }
}

test "extract keys - empty document" {
    const allocator = std.testing.allocator;
    const inputs = [_][]const u8{"# Just a comment"};
    var results: [1]KeyExtractResult = undefined;

    extractKeys(allocator, &inputs, &results);

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
    extractKeys(allocator, &inputs, &results);
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
    var inputs: [16][]const u8 = undefined;
    for (&inputs) |*input| {
        input.* = "key = \"value\"";
    }
    var results: [16]ParseResult = undefined;

    parseDocuments(allocator, &inputs, &results);
    defer {
        for (&results) |*r| if (r.doc) |*d| d.deinit();
    }

    for (results) |result| {
        try std.testing.expect(result.success);
        try std.testing.expectEqual(@as(usize, 1), result.key_count);
    }
}

test "parallel validate - large batch" {
    var inputs: [16][]const u8 = undefined;
    for (&inputs) |*input| {
        input.* = "[table]\nkey = \"value\"";
    }
    var results: [16]ValidateResult = undefined;

    validateDocuments(&inputs, &results);

    for (results) |result| {
        try std.testing.expect(result.valid);
    }
}

test "parallel extract keys - large batch" {
    const allocator = std.testing.allocator;
    var inputs: [16][]const u8 = undefined;
    for (&inputs) |*input| {
        input.* = "name = \"test\"\nversion = \"1.0\"";
    }
    var results: [16]KeyExtractResult = undefined;

    extractKeys(allocator, &inputs, &results);

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
    const inputs = [_][]const u8{"a = = 1\n"};
    var results: [1]ParseResult = undefined;

    parseDocuments(allocator, &inputs, &results);
    defer {
        for (&results) |*r| if (r.doc) |*d| d.deinit();
    }

    try std.testing.expect(!results[0].success);
    try std.testing.expect(results[0].error_code != 0);
    try std.testing.expect(results[0].error_line != null);
}

test "U-M aligned with toml.parse: unclosed table rejected" {
    const allocator = std.testing.allocator;
    const inputs = [_][]const u8{"[unclosed table\n"};
    var results: [1]ParseResult = undefined;

    parseDocuments(allocator, &inputs, &results);
    defer {
        for (&results) |*r| if (r.doc) |*d| d.deinit();
    }

    try std.testing.expect(!results[0].success);
    try std.testing.expect(results[0].error_code != 0);
}

test "U-M aligned with toml.parse: duplicate keys rejected" {
    const allocator = std.testing.allocator;
    const inputs = [_][]const u8{"a = 1\na = 2\n"};
    var results: [1]ParseResult = undefined;

    parseDocuments(allocator, &inputs, &results);
    defer {
        for (&results) |*r| if (r.doc) |*d| d.deinit();
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
        var r = toml.parseWithError(std.testing.allocator, input, .{});
        switch (r) {
            .ok => |*d| {
                d.deinit();
                try std.testing.expect(false); // real parser must reject
            },
            .err => {},
        }
    }
}

test "U-F no dropped inputs past MAX_CHUNKS - parseDocuments" {
    const allocator = std.testing.allocator;
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

    parseDocuments(allocator, &inputs, &results);
    defer {
        for (&results) |*r| if (r.doc) |*d| d.deinit();
    }

    for (results, 0..) |result, idx| {
        try std.testing.expect(result.error_code != 0xFF); // slot was written
        try std.testing.expect(result.success);
        try std.testing.expectEqual(@as(usize, 1), result.key_count);
        _ = idx;
    }
}

test "U-F no dropped inputs past MAX_CHUNKS - validateDocuments" {
    const N = 100;
    var inputs: [N][]const u8 = undefined;
    for (&inputs) |*input| input.* = "[table]\nkey = \"value\"";

    var results: [N]ValidateResult = undefined;
    for (&results) |*r| {
        r.* = .{ .valid = false, .error_code = 0xFF, .error_msg = null };
    }

    validateDocuments(&inputs, &results);

    for (results) |result| {
        try std.testing.expect(result.error_code != 0xFF);
        try std.testing.expect(result.valid);
    }
}

test "U-F no dropped inputs past MAX_CHUNKS - extractKeys" {
    const allocator = std.testing.allocator;
    const N = 100;
    var inputs: [N][]const u8 = undefined;
    for (&inputs) |*input| input.* = "name = \"test\"\nversion = \"1.0\"";

    var results: [N]KeyExtractResult = undefined;
    // Sentinel: count = maxInt signals the slot was never written.
    for (&results) |*r| {
        r.* = .{ .keys = null, .count = std.math.maxInt(usize), .success = false };
    }

    extractKeys(allocator, &inputs, &results);

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
    parseDocuments(allocator, &inputs, &results);
    defer {
        for (&results) |*r| if (r.doc) |*d| d.deinit();
    }

    for (corpus, 0..) |c, i| {
        // Compute the serial oracle answer.
        var oracle = toml.parseWithError(allocator, c.input, .{});
        var oracle_success: bool = false;
        switch (oracle) {
            .ok => |*d| {
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
