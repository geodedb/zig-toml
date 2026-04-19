// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros

//! TOML array parsing: `[ ... ]` literals and the awkward `[[ ... ]]`
//! nested-array-in-value edge case.
//!
//! Extracted from `src/parser.zig` (Q-17). The module hosts three
//! closely related walkers plus the shared whitespace/comment skipper
//! that they all share:
//!
//! - `parseArray` — top-level `[ item, item, ... ]`
//! - `parseNestedArrayFromDoubleBracket` — `[[` in value context
//!   (arrays nested inside other arrays), where the lexer produced a
//!   single `double_bracket_open` token for what is semantically two
//!   `[` tokens
//! - `parseArrayContents` — inner helper used by the `[[` path once
//!   the first `[` has already been consumed
//! - `skipArrayWhitespace` — newline/comment skip; arrays permit both
//!   freely between items and before `]`
//!
//! All three walkers share the `]]` → `]` splitting trick so the
//! outer context can consume its own closing bracket.
//!
//! Stateless; all data flows through `*Parser`.

const std = @import("std");
const Allocator = std.mem.Allocator;

const err = @import("../error.zig");
const ErrorCode = err.ErrorCode;

const lex = @import("../lexer.zig");
const Token = lex.Token;

const val = @import("../value.zig");
const Value = val.Value;

const events_sink = @import("events_sink.zig");

// Forward-declared to break the import cycle.
const parser_mod = @import("../parser.zig");
const Parser = parser_mod.Parser;
const ParseValueError = Parser.ParseValueError;

pub fn parseArray(self: *Parser, alloc: Allocator) ParseValueError!Value {
    // Defense-in-depth: parseArray is normally called via parseValue
    // (which already guards), but any alternate caller (e.g. future
    // direct invocation) would bypass the recursion cap. Guard here
    // too so the protection holds regardless of call path.
    try self.enterDepth();
    defer self.exitDepth();

    self.current = try self.nextToken(); // consume [

    // 16-slot initial capacity covers most literal arrays without
    // the ArrayList's doubling ladder (0->8->16 saves two reallocs).
    // After P-10, items are Value (not *Value) so the parser's
    // per-element `create(Value)` allocation in parseValue is the
    // only heap touch per element; elements live contiguously here.
    var items: std.ArrayListUnmanaged(Value) = .empty;
    try items.ensureTotalCapacity(alloc, 16);

    // For event-mode, announce array start before consuming any items.
    try events_sink.emitSimple(self, .array_start);

    // Skip whitespace and newlines
    try skipArrayWhitespace(self);

    while (self.current.tag != .right_bracket and self.current.tag != .double_bracket_close and self.current.tag != .eof) {
        const item = try self.parseValue(alloc);
        try items.append(alloc, item.*);
        // For scalar items, also emit array_item. Container items
        // (tables / nested arrays) have already fired their own
        // start/end events from inside parseValue -> parseInlineTable
        // / parseArray; we do NOT want to wrap them in an
        // `array_item`.
        switch (item.*) {
            .table, .array => {},
            else => try events_sink.emitSimple(self, .{ .array_item = item.* }),
        }

        try skipArrayWhitespace(self);

        if (self.current.tag == .comma) {
            self.current = try self.nextToken();
            try skipArrayWhitespace(self);
        } else if (self.current.tag != .right_bracket and self.current.tag != .double_bracket_close) {
            self.parse_error = err.makeError(.UnexpectedToken, self.current.pos, "expected ',' or ']'");
            return error.ParseFailed;
        }
    }

    try consumeArrayClose(self);
    try events_sink.emitSimple(self, .array_end);

    return Value{ .array = .{ .items = items, .is_static = true } };
}

pub fn parseNestedArrayFromDoubleBracket(self: *Parser, alloc: Allocator) ParseValueError!Value {
    // We saw [[ which the lexer tokenized as double_bracket_open
    // In value context, this is a nested array: [ [ ... ] ... ]
    // We treat the [[ as the start of outer array + start of inner array
    try self.enterDepth();
    defer self.exitDepth();

    self.current = try self.nextToken(); // consume [[

    // Items stored by value (P-10): append the inner array Value
    // directly, without the extra per-element `create(Value)` that
    // was only needed when the slot type was *Value.
    var outer_items: std.ArrayListUnmanaged(Value) = .empty;
    try outer_items.ensureTotalCapacity(alloc, 16);

    // Event-mode: announce the outer array start. The inner array's
    // own start/end fires from parseArrayContents below, so the
    // consumer observes `[, [, ..., ], ... , ]`.
    try events_sink.emitSimple(self, .array_start);

    // Parse the inner array (we're already "inside" it after consuming [[)
    try self.bumpValues();
    try outer_items.append(alloc, try parseArrayContents(self, alloc));

    // Now continue parsing the outer array (same logic as parseArray after first item)
    try skipArrayWhitespace(self);

    while (true) {
        if (self.current.tag == .comma) {
            self.current = try self.nextToken();
            try skipArrayWhitespace(self);
            // Check for trailing comma
            if (self.current.tag == .right_bracket or self.current.tag == .double_bracket_close) break;
        } else if (self.current.tag == .right_bracket or self.current.tag == .double_bracket_close) {
            break;
        } else {
            self.parse_error = err.makeError(.UnexpectedToken, self.current.pos, "expected ',' or ']'");
            return error.ParseFailed;
        }

        const item = try self.parseValue(alloc);
        try outer_items.append(alloc, item.*);
        // Same scalar-vs-container distinction as parseArray.
        switch (item.*) {
            .table, .array => {},
            else => try events_sink.emitSimple(self, .{ .array_item = item.* }),
        }
        try skipArrayWhitespace(self);
    }

    try consumeArrayClose(self);
    try events_sink.emitSimple(self, .array_end);

    return Value{ .array = .{ .items = outer_items, .is_static = true } };
}

fn parseArrayContents(self: *Parser, alloc: Allocator) ParseValueError!Value {
    // Defense-in-depth: guard here too because this function can be
    // reached from parseNestedArrayFromDoubleBracket's inner call.
    try self.enterDepth();
    defer self.exitDepth();

    // Parse array contents after the opening [ has been consumed.
    // By-value element storage (P-10): collect Value directly.
    var items: std.ArrayListUnmanaged(Value) = .empty;
    try items.ensureTotalCapacity(alloc, 16);

    // Event-mode: announce this inner array. Called from
    // parseNestedArrayFromDoubleBracket which has already emitted
    // its own outer `.array_start`.
    try events_sink.emitSimple(self, .array_start);

    try skipArrayWhitespace(self);

    while (self.current.tag != .right_bracket and self.current.tag != .double_bracket_close and self.current.tag != .eof) {
        const item = try self.parseValue(alloc);
        try items.append(alloc, item.*);
        switch (item.*) {
            .table, .array => {},
            else => try events_sink.emitSimple(self, .{ .array_item = item.* }),
        }

        try skipArrayWhitespace(self);

        if (self.current.tag == .comma) {
            self.current = try self.nextToken();
            try skipArrayWhitespace(self);
        } else if (self.current.tag != .right_bracket and self.current.tag != .double_bracket_close) {
            self.parse_error = err.makeError(.UnexpectedToken, self.current.pos, "expected ',' or ']'");
            return error.ParseFailed;
        }
    }

    try consumeArrayClose(self);
    try events_sink.emitSimple(self, .array_end);

    return Value{ .array = .{ .items = items, .is_static = true } };
}

/// Consume the array's closing bracket. Handles the `]]` → `]` split
/// used when a lexer-emitted `double_bracket_close` has to serve as a
/// single `]` for the inner array and leave another `]` for the outer
/// context. Emits the appropriate diagnostic when neither `]` nor `]]`
/// is present.
fn consumeArrayClose(self: *Parser) !void {
    if (self.current.tag == .double_bracket_close) {
        // Leave one ] for the outer context by converting to right_bracket.
        self.current = Token{
            .tag = .right_bracket,
            .start = self.current.start + 1,
            .end = self.current.end,
            .pos = .{
                .byte_index = self.current.pos.byte_index + 1,
                .line = self.current.pos.line,
                .column = self.current.pos.column + 1,
            },
        };
    } else if (self.current.tag == .right_bracket) {
        self.current = try self.nextToken();
    } else {
        self.parse_error = err.makeError(.UnexpectedToken, self.current.pos, "expected ']'");
        return error.ParseFailed;
    }
}

pub fn skipArrayWhitespace(self: *Parser) !void {
    while (self.current.tag == .newline or self.current.tag == .comment) {
        self.current = try self.nextToken();
    }
}
