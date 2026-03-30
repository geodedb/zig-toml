// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! Parallel TOML operations using spice heartbeat scheduling.
//!
//! Provides high-performance parallel implementations for batch TOML
//! document parsing and validation.
//!
//! ## Overview
//!
//! This module enables parallel processing of TOML operations
//! using the spice thread pool with fork/join work-stealing. Operations
//! automatically fall back to sequential processing when spice is disabled
//! or input sizes are below thresholds.
//!
//! ## Build Configuration
//!
//! Enable parallel processing with `-Dspice=true` (default: enabled).
//! Disable with `-Dspice=false` for sequential-only execution.
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
const build_options = @import("toml_build_options");

const spice = if (build_options.enable_spice) @import("spice") else struct {
    pub const ThreadPool = void;
    pub const Task = void;
    pub fn Future(comptime I: type, comptime O: type) type {
        _ = I;
        _ = O;
        return void;
    }
};

// ============================================================================
// Global Thread Pool
// ============================================================================

var global_pool: if (build_options.enable_spice) ?spice.ThreadPool else void = if (build_options.enable_spice) null else {};
var pool_mutex: std.Thread.Mutex = .{};

pub fn getPool() if (build_options.enable_spice) *spice.ThreadPool else void {
    if (!build_options.enable_spice) return;

    pool_mutex.lock();
    defer pool_mutex.unlock();

    if (global_pool == null) {
        global_pool = spice.ThreadPool.init(std.heap.page_allocator);
        global_pool.?.start(.{});
    }
    return &global_pool.?;
}

pub fn deinitPool() void {
    if (!build_options.enable_spice) return;

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

/// Result of TOML document parsing
pub const ParseResult = struct {
    /// Whether parsing succeeded
    success: bool,
    /// Error code (0 = success)
    error_code: u8,
    /// Error line (if failed)
    error_line: ?usize,
    /// Error column (if failed)
    error_column: ?usize,
    /// Number of top-level keys found
    key_count: usize,
};

/// Context for parallel parsing
const ParseContext = struct {
    allocator: std.mem.Allocator,
    inputs: []const []const u8,
    results: []ParseResult,
};

// ============================================================================
// Parallel Document Parsing
// ============================================================================

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

    if (!build_options.enable_spice or inputs.len < 4) {
        for (inputs, 0..) |input, i| {
            results[i] = parseDocument(allocator, input);
        }
        return;
    }

    const pool = getPool();
    const ctx = ParseContext{
        .allocator = allocator,
        .inputs = inputs,
        .results = results,
    };
    _ = pool.call(void, parseTask, ctx);
}

fn parseTask(t: *spice.Task, ctx: ParseContext) void {
    const inputs = ctx.inputs;
    const results = ctx.results;

    if (inputs.len < 2) {
        for (inputs, 0..) |input, i| {
            results[i] = parseDocument(ctx.allocator, input);
        }
        return;
    }

    const mid = inputs.len / 2;
    const left_ctx = ParseContext{
        .allocator = ctx.allocator,
        .inputs = inputs[0..mid],
        .results = results[0..mid],
    };
    const right_ctx = ParseContext{
        .allocator = ctx.allocator,
        .inputs = inputs[mid..],
        .results = results[mid..],
    };

    var fut = spice.Future(ParseContext, void).init();
    fut.fork(t, parseTask, right_ctx);

    t.call(void, parseTask, left_ctx);
    if (fut.join(t) == null) {
        t.call(void, parseTask, right_ctx);
    }
}

fn parseDocument(allocator: std.mem.Allocator, input: []const u8) ParseResult {
    _ = allocator;

    // Simple TOML validation - check basic structure
    var key_count: usize = 0;
    var line: usize = 1;
    var column: usize = 1;
    var in_string = false;
    var in_multiline_string = false;
    var i: usize = 0;

    while (i < input.len) {
        const c = input[i];

        if (in_multiline_string) {
            if (i + 2 < input.len and
                input[i] == '"' and input[i + 1] == '"' and input[i + 2] == '"')
            {
                in_multiline_string = false;
                i += 3;
                column += 3;
                continue;
            }
        } else if (in_string) {
            if (c == '"' and (i == 0 or input[i - 1] != '\\')) {
                in_string = false;
            }
        } else {
            if (c == '"') {
                if (i + 2 < input.len and input[i + 1] == '"' and input[i + 2] == '"') {
                    in_multiline_string = true;
                    i += 3;
                    column += 3;
                    continue;
                }
                in_string = true;
            } else if (c == '=') {
                key_count += 1;
            } else if (c == '[') {
                // Table header - could be [[array]] or [table]
                if (i + 1 < input.len and input[i + 1] == '[') {
                    // Array of tables
                    i += 1;
                    column += 1;
                }
            }
        }

        if (c == '\n') {
            line += 1;
            column = 1;
        } else {
            column += 1;
        }
        i += 1;
    }

    if (in_string or in_multiline_string) {
        return .{
            .success = false,
            .error_code = 1,
            .error_line = line,
            .error_column = column,
            .key_count = key_count,
        };
    }

    return .{
        .success = true,
        .error_code = 0,
        .error_line = null,
        .error_column = null,
        .key_count = key_count,
    };
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

/// Context for parallel validation
const ValidateContext = struct {
    inputs: []const []const u8,
    results: []ValidateResult,
};

// ============================================================================
// Parallel Document Validation
// ============================================================================

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

    if (!build_options.enable_spice or inputs.len < 8) {
        for (inputs, 0..) |input, i| {
            results[i] = validateDocument(input);
        }
        return;
    }

    const pool = getPool();
    const ctx = ValidateContext{
        .inputs = inputs,
        .results = results,
    };
    _ = pool.call(void, validateTask, ctx);
}

fn validateTask(t: *spice.Task, ctx: ValidateContext) void {
    const inputs = ctx.inputs;
    const results = ctx.results;

    if (inputs.len < 4) {
        for (inputs, 0..) |input, i| {
            results[i] = validateDocument(input);
        }
        return;
    }

    const mid = inputs.len / 2;
    const left_ctx = ValidateContext{
        .inputs = inputs[0..mid],
        .results = results[0..mid],
    };
    const right_ctx = ValidateContext{
        .inputs = inputs[mid..],
        .results = results[mid..],
    };

    var fut = spice.Future(ValidateContext, void).init();
    fut.fork(t, validateTask, right_ctx);

    t.call(void, validateTask, left_ctx);
    if (fut.join(t) == null) {
        t.call(void, validateTask, right_ctx);
    }
}

fn validateDocument(input: []const u8) ValidateResult {
    // Check for valid UTF-8
    if (!std.unicode.utf8ValidateSlice(input)) {
        return .{ .valid = false, .error_code = 1, .error_msg = "Invalid UTF-8" };
    }

    // Check for bare carriage returns (not allowed in TOML)
    var i: usize = 0;
    while (i < input.len) : (i += 1) {
        if (input[i] == '\r' and (i + 1 >= input.len or input[i + 1] != '\n')) {
            return .{ .valid = false, .error_code = 2, .error_msg = "Bare carriage return" };
        }
    }

    // Check for null bytes (not allowed)
    for (input) |c| {
        if (c == 0) {
            return .{ .valid = false, .error_code = 3, .error_msg = "Null byte in document" };
        }
    }

    // Basic bracket matching
    var bracket_depth: i32 = 0;
    var in_string = false;
    for (input) |c| {
        if (!in_string) {
            if (c == '"') in_string = true;
            if (c == '[') bracket_depth += 1;
            if (c == ']') bracket_depth -= 1;
            if (bracket_depth < 0) {
                return .{ .valid = false, .error_code = 4, .error_msg = "Unmatched closing bracket" };
            }
        } else {
            if (c == '"') in_string = false;
        }
    }

    return .{ .valid = true, .error_code = 0, .error_msg = null };
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

/// Context for parallel key extraction
const KeyExtractContext = struct {
    allocator: std.mem.Allocator,
    inputs: []const []const u8,
    results: []KeyExtractResult,
};

// ============================================================================
// Parallel Key Extraction
// ============================================================================

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

    if (!build_options.enable_spice or inputs.len < 8) {
        for (inputs, 0..) |input, i| {
            results[i] = extractKeysFromDocument(allocator, input);
        }
        return;
    }

    const pool = getPool();
    const ctx = KeyExtractContext{
        .allocator = allocator,
        .inputs = inputs,
        .results = results,
    };
    _ = pool.call(void, keyExtractTask, ctx);
}

fn keyExtractTask(t: *spice.Task, ctx: KeyExtractContext) void {
    const inputs = ctx.inputs;
    const results = ctx.results;

    if (inputs.len < 4) {
        for (inputs, 0..) |input, i| {
            results[i] = extractKeysFromDocument(ctx.allocator, input);
        }
        return;
    }

    const mid = inputs.len / 2;
    const left_ctx = KeyExtractContext{
        .allocator = ctx.allocator,
        .inputs = inputs[0..mid],
        .results = results[0..mid],
    };
    const right_ctx = KeyExtractContext{
        .allocator = ctx.allocator,
        .inputs = inputs[mid..],
        .results = results[mid..],
    };

    var fut = spice.Future(KeyExtractContext, void).init();
    fut.fork(t, keyExtractTask, right_ctx);

    t.call(void, keyExtractTask, left_ctx);
    if (fut.join(t) == null) {
        t.call(void, keyExtractTask, right_ctx);
    }
}

fn extractKeysFromDocument(allocator: std.mem.Allocator, input: []const u8) KeyExtractResult {
    var keys = std.ArrayList(u8).init(allocator);
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
                            keys.append(',') catch {
                                return .{ .keys = null, .count = 0, .success = false };
                            };
                        }
                        keys.appendSlice(key) catch {
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
        keys.deinit();
        return .{ .keys = null, .count = 0, .success = true };
    }

    return .{
        .keys = keys.toOwnedSlice() catch null,
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

    try std.testing.expect(results[0].success);
    try std.testing.expectEqual(@as(usize, 2), results[0].key_count);
}

test "parse document - unclosed string" {
    const allocator = std.testing.allocator;
    const inputs = [_][]const u8{
        \\name = "unclosed
    };
    var results: [1]ParseResult = undefined;

    parseDocuments(allocator, &inputs, &results);

    try std.testing.expect(!results[0].success);
    try std.testing.expectEqual(@as(u8, 1), results[0].error_code);
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
    try std.testing.expectEqual(@as(u8, 1), results[0].error_code);
}

test "validate document - null byte" {
    const inputs = [_][]const u8{"name\x00= \"test\""};
    var results: [1]ValidateResult = undefined;

    validateDocuments(&inputs, &results);

    try std.testing.expect(!results[0].valid);
    try std.testing.expectEqual(@as(u8, 3), results[0].error_code);
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

test "parallel parse - large batch" {
    if (!build_options.enable_spice) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var inputs: [16][]const u8 = undefined;
    for (&inputs) |*input| {
        input.* = "key = \"value\"";
    }
    var results: [16]ParseResult = undefined;

    parseDocuments(allocator, &inputs, &results);

    for (results) |result| {
        try std.testing.expect(result.success);
        try std.testing.expectEqual(@as(usize, 1), result.key_count);
    }
}

test "parallel validate - large batch" {
    if (!build_options.enable_spice) return error.SkipZigTest;

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
    if (!build_options.enable_spice) return error.SkipZigTest;

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
