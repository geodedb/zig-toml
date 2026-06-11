// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! TOML integer and float parsing.

const std = @import("std");
const err = @import("../error.zig");
const ErrorCode = err.ErrorCode;
const Allocator = std.mem.Allocator;

const Parser = @import("../parser.zig").Parser;

pub fn parseInteger(self: *Parser, alloc: Allocator, raw: []const u8) !i64 {
    // Validate integer format
    try validateIntegerFormat(self, raw);

    // Remove underscores. Grow as needed; the configured max_bytes limit
    // caps pathological inputs so we cannot exhaust memory here.
    var clean: std.ArrayList(u8) = try .initCapacity(alloc, 64);

    var base: u8 = 10;
    var start: usize = 0;
    var negative = false;

    if (raw.len > 0 and raw[0] == '+') {
        start = 1;
    } else if (raw.len > 0 and raw[0] == '-') {
        negative = true;
        start = 1;
    }

    if (raw.len > start + 2) {
        if (raw[start] == '0') {
            if (raw[start + 1] == 'x') {
                base = 16;
                start += 2;
            } else if (raw[start + 1] == 'o') {
                base = 8;
                start += 2;
            } else if (raw[start + 1] == 'b') {
                base = 2;
                start += 2;
            }
        }
    }

    // P-NEW-2: fast path. The common case has no underscores, so no scratch
    // buffer is needed. For base 10 the original `raw` (sign included) parses
    // directly; for prefixed bases a sign is disallowed (enforced by
    // validateIntegerFormat) and `raw[start..]` is the bare digit body.
    if (std.mem.indexOfScalar(u8, raw, '_') == null) {
        const body = if (base == 10) raw else raw[start..];
        return std.fmt.parseInt(i64, body, base) catch {
            self.parse_error = err.makeError(.InvalidNumber, self.current.pos, "invalid integer");
            return error.ParseFailed;
        };
    }

    for (raw[start..]) |c| {
        if (c != '_') {
            if (clean.items.len >= self.options.max_bytes) {
                self.parse_error = err.makeError(.InvalidNumber, self.current.pos, "integer exceeds max_bytes");
                return error.ParseFailed;
            }
            try clean.append(alloc, c);
        }
    }

    if (negative) {
        // For negative numbers, include the minus sign in parsing to handle i64.MIN correctly.
        var neg_buf: std.ArrayList(u8) = try .initCapacity(alloc, clean.items.len + 1);
        try neg_buf.append(alloc, '-');
        try neg_buf.appendSlice(alloc, clean.items);
        const result = std.fmt.parseInt(i64, neg_buf.items, base) catch {
            self.parse_error = err.makeError(.InvalidNumber, self.current.pos, "invalid integer");
            return error.ParseFailed;
        };
        return result;
    } else {
        const result = std.fmt.parseInt(i64, clean.items, base) catch {
            self.parse_error = err.makeError(.InvalidNumber, self.current.pos, "invalid integer");
            return error.ParseFailed;
        };
        return result;
    }
}

pub fn validateIntegerFormat(self: *Parser, raw: []const u8) !void {
    if (raw.len == 0) {
        self.parse_error = err.makeError(.InvalidNumber, self.current.pos, "empty integer");
        return error.ParseFailed;
    }

    var i: usize = 0;

    // Check for sign
    const has_sign = raw[0] == '+' or raw[0] == '-';
    if (has_sign) {
        i = 1;
        if (i >= raw.len) {
            self.parse_error = err.makeError(.InvalidNumber, self.current.pos, "integer sign with no digits");
            return error.ParseFailed;
        }
        // Check for double sign
        if (raw[i] == '+' or raw[i] == '-') {
            self.parse_error = err.makeError(.InvalidNumber, self.current.pos, "double sign not allowed");
            return error.ParseFailed;
        }
    }

    // Check for base prefix (0x, 0o, 0b)
    var is_prefixed = false;
    if (raw.len > i + 1 and raw[i] == '0') {
        const next = raw[i + 1];
        if (next == 'x' or next == 'o' or next == 'b') {
            // Prefixed integers cannot have a sign
            if (has_sign) {
                self.parse_error = err.makeError(.InvalidNumber, self.current.pos, "sign not allowed with hex/oct/bin prefix");
                return error.ParseFailed;
            }
            is_prefixed = true;
            i += 2;
        }
    }

    // Check for leading zeros in decimal integers (including 0_0)
    if (!is_prefixed and raw.len > i + 1 and raw[i] == '0') {
        // "0" by itself is fine, but "01", "00", "0_0" etc are not
        // Check if there's any digit after the leading zero (ignoring underscores)
        var j = i + 1;
        while (j < raw.len and raw[j] == '_') {
            j += 1;
        }
        if (j < raw.len and raw[j] >= '0' and raw[j] <= '9') {
            self.parse_error = err.makeError(.InvalidNumber, self.current.pos, "leading zeros not allowed");
            return error.ParseFailed;
        }
    }

    // Validate underscore placement
    if (i < raw.len and raw[i] == '_') {
        self.parse_error = err.makeError(.InvalidNumber, self.current.pos, "leading underscore not allowed");
        return error.ParseFailed;
    }
    if (raw[raw.len - 1] == '_') {
        self.parse_error = err.makeError(.InvalidNumber, self.current.pos, "trailing underscore not allowed");
        return error.ParseFailed;
    }

    // Check for double underscores
    var prev: u8 = 0;
    for (raw[i..]) |c| {
        if (c == '_' and prev == '_') {
            self.parse_error = err.makeError(.InvalidNumber, self.current.pos, "double underscore not allowed");
            return error.ParseFailed;
        }
        prev = c;
    }
}

pub fn parseFloat(self: *Parser, alloc: Allocator, raw: []const u8) !f64 {
    // Handle special values
    if (std.mem.eql(u8, raw, "inf") or std.mem.eql(u8, raw, "+inf")) return std.math.inf(f64);
    if (std.mem.eql(u8, raw, "-inf")) return -std.math.inf(f64);
    if (std.mem.eql(u8, raw, "nan") or std.mem.eql(u8, raw, "+nan")) return std.math.nan(f64);
    if (std.mem.eql(u8, raw, "-nan")) return -std.math.nan(f64);

    // Validate float format
    try validateFloatFormat(self, raw);

    // P-NEW-2: fast path. No underscores means the raw slice (sign and all)
    // parses directly with no scratch buffer.
    if (std.mem.indexOfScalar(u8, raw, '_') == null) {
        return std.fmt.parseFloat(f64, raw) catch {
            self.parse_error = err.makeError(.InvalidNumber, self.current.pos, "invalid float");
            return error.ParseFailed;
        };
    }

    // Remove underscores. Grow as needed; max_bytes caps pathological inputs.
    var clean: std.ArrayList(u8) = try .initCapacity(alloc, 128);

    for (raw) |c| {
        if (c != '_') {
            if (clean.items.len >= self.options.max_bytes) {
                self.parse_error = err.makeError(.InvalidNumber, self.current.pos, "float exceeds max_bytes");
                return error.ParseFailed;
            }
            try clean.append(alloc, c);
        }
    }

    return std.fmt.parseFloat(f64, clean.items) catch {
        self.parse_error = err.makeError(.InvalidNumber, self.current.pos, "invalid float");
        return error.ParseFailed;
    };
}

// ---------------------------------------------------------------------------
// validateFloatFormat — flat state machine (Q-6).
// Classifies each byte into a FloatClass, then steps a FloatState.
// Maximum nesting depth is 2 (function body -> outer switch -> inner
// switch), down from the 7 levels of the prior imperative version.
// ---------------------------------------------------------------------------

const FloatClass = enum { digit, underscore, dot, exp, sign, other };

const FloatState = enum {
    start, // before any digit
    int_digit, // saw a digit in the integer part
    int_underscore, // saw an underscore in the integer part
    after_dot, // saw the '.'
    frac_digit, // saw a digit in the fractional part
    frac_underscore, // saw an underscore in the fractional part
    after_exp, // saw 'e' or 'E'
    after_exp_sign, // saw 'e' then '+' or '-'
    exp_digit, // saw a digit in the exponent
    exp_underscore, // saw an underscore in the exponent
};

fn classifyFloatByte(c: u8) FloatClass {
    return switch (c) {
        '0'...'9' => .digit,
        '_' => .underscore,
        '.' => .dot,
        'e', 'E' => .exp,
        '+', '-' => .sign,
        else => .other,
    };
}

fn raiseFloat(self: *Parser, comptime msg: []const u8) error{ParseFailed} {
    self.parse_error = err.makeError(.InvalidNumber, self.current.pos, msg);
    return error.ParseFailed;
}

pub fn validateFloatFormat(self: *Parser, raw: []const u8) !void {
    if (raw.len == 0) return raiseFloat(self, "empty float");

    // Strip a leading '+' or '-' (TOML permits it on the whole number).
    var start: usize = 0;
    if (raw[0] == '+' or raw[0] == '-') start = 1;
    if (start == raw.len) return raiseFloat(self, "float sign with no digits");

    var state: FloatState = .start;
    var i: usize = start;
    while (i < raw.len) : (i += 1) {
        state = try stepFloat(self, state, classifyFloatByte(raw[i]));
    }

    // Terminal check: we must end on a digit in the fractional or exponent
    // region. An integer-only string ("5") is not a valid TOML float; nor
    // are strings ending in '_', '.', 'e', or '+/-'.
    return switch (state) {
        .frac_digit, .exp_digit => {},
        .int_digit => raiseFloat(self, "float must contain '.' or exponent"),
        else => raiseFloat(self, "float ended in invalid state"),
    };
}

fn stepFloat(self: *Parser, state: FloatState, cls: FloatClass) !FloatState {
    return switch (state) {
        .start => switch (cls) {
            .digit => .int_digit,
            else => raiseFloat(self, "float must start with a digit"),
        },
        .int_digit => switch (cls) {
            .digit => .int_digit,
            .underscore => .int_underscore,
            .dot => .after_dot,
            .exp => .after_exp,
            else => raiseFloat(self, "invalid character in integer part"),
        },
        .int_underscore => switch (cls) {
            .digit => .int_digit,
            else => raiseFloat(self, "underscore must be between digits"),
        },
        .after_dot => switch (cls) {
            .digit => .frac_digit,
            else => raiseFloat(self, "digit required after '.'"),
        },
        .frac_digit => switch (cls) {
            .digit => .frac_digit,
            .underscore => .frac_underscore,
            .exp => .after_exp,
            else => raiseFloat(self, "invalid character in fractional part"),
        },
        .frac_underscore => switch (cls) {
            .digit => .frac_digit,
            else => raiseFloat(self, "underscore must be between digits"),
        },
        .after_exp => switch (cls) {
            .digit => .exp_digit,
            .sign => .after_exp_sign,
            else => raiseFloat(self, "digit or sign required after exponent marker"),
        },
        .after_exp_sign => switch (cls) {
            .digit => .exp_digit,
            else => raiseFloat(self, "digit required after exponent sign"),
        },
        .exp_digit => switch (cls) {
            .digit => .exp_digit,
            .underscore => .exp_underscore,
            else => raiseFloat(self, "invalid character in exponent"),
        },
        .exp_underscore => switch (cls) {
            .digit => .exp_digit,
            else => raiseFloat(self, "underscore must be between digits"),
        },
    };
}

// ---------------------------------------------------------------------------
// Characterisation tests for validateFloatFormat.
// These pin the accept/reject boundary so the planned Q-6 refactor
// (flat state machine) cannot silently change behaviour.
// ---------------------------------------------------------------------------

const testing = std.testing;

fn expectFloatReject(input: []const u8) !void {
    const alloc = testing.allocator;
    var p = @import("../parser.zig").Parser.init(alloc, input, .{});
    // `current` is `undefined` after init; give it a safe zero Position
    // so the validator's error-construction path (self.current.pos) does
    // not read uninitialised memory during these unit tests.
    p.current = .{ .tag = .eof, .start = 0, .end = 0, .pos = .{} };
    try testing.expectError(error.ParseFailed, validateFloatFormat(&p, input));
}

fn expectFloatAccept(input: []const u8) !void {
    const alloc = testing.allocator;
    var p = @import("../parser.zig").Parser.init(alloc, input, .{});
    p.current = .{ .tag = .eof, .start = 0, .end = 0, .pos = .{} };
    try validateFloatFormat(&p, input);
}

test "validateFloatFormat rejects leading underscore" {
    try expectFloatReject("_1.0");
}

test "validateFloatFormat rejects trailing underscore" {
    try expectFloatReject("1.0_");
}

test "validateFloatFormat rejects underscore adjacent to dot" {
    try expectFloatReject("1_.0");
    try expectFloatReject("1._0");
}

test "validateFloatFormat rejects underscore adjacent to exponent" {
    try expectFloatReject("1.0_e5");
    try expectFloatReject("1.0e_5");
}

test "validateFloatFormat rejects empty mantissa" {
    try expectFloatReject(".5");
}

test "validateFloatFormat rejects empty exponent" {
    try expectFloatReject("1.0e");
    try expectFloatReject("1.0e+");
}

test "validateFloatFormat rejects double sign in exponent" {
    try expectFloatReject("1.0e++5");
}

test "validateFloatFormat accepts simple float" {
    try expectFloatAccept("3.14");
}

test "validateFloatFormat accepts grouped underscores" {
    try expectFloatAccept("9_224_617.445_991_228_313");
}

test "validateFloatFormat accepts signed exponent" {
    try expectFloatAccept("6.022e+23");
    try expectFloatAccept("1.0e-10");
}

test "P-NEW-2 number fast-path correctness (with and without underscores)" {
    const toml = @import("../toml.zig");
    const a = testing.allocator;
    {
        const doc = try toml.parse(a, "a = 1234\nb = 1_2_3_4\nc = 0xFF\nd = 0b1010\ne = 0o17\nf = -42\ng = +7\nh = -9223372036854775808\n", .{});
        defer doc.deinit();
        try testing.expectEqual(@as(i64, 1234), doc.root.table.map.get("a").?.integer);
        try testing.expectEqual(@as(i64, 1234), doc.root.table.map.get("b").?.integer);
        try testing.expectEqual(@as(i64, 255), doc.root.table.map.get("c").?.integer);
        try testing.expectEqual(@as(i64, 10), doc.root.table.map.get("d").?.integer);
        try testing.expectEqual(@as(i64, 15), doc.root.table.map.get("e").?.integer);
        try testing.expectEqual(@as(i64, -42), doc.root.table.map.get("f").?.integer);
        try testing.expectEqual(@as(i64, 7), doc.root.table.map.get("g").?.integer);
        try testing.expectEqual(@as(i64, std.math.minInt(i64)), doc.root.table.map.get("h").?.integer);
    }
    {
        const doc = try toml.parse(a, "x = 3.14\ny = 1_000.000_1\nz = -6.022e+23\n", .{});
        defer doc.deinit();
        try testing.expect(@abs(doc.root.table.map.get("x").?.float - 3.14) < 1e-9);
        try testing.expect(@abs(doc.root.table.map.get("y").?.float - 1000.0001) < 1e-6);
        try testing.expect(doc.root.table.map.get("z").?.float < -6.0e23);
    }
}
