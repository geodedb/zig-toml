// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros

//! Partial-parse error recovery for TOML.
//!
//! Hosts the `parseRecover*` entry point plus the recovery scanning
//! helpers (`recoverParseLoop`, `recoverAdvancePastLine`,
//! `recordParserError`). These were extracted from `src/parser.zig`
//! (Q-17) to keep the dispatch file under its LOC budget while leaving
//! the public API unchanged — `src/parser.zig` re-exports
//! `parseRecoverDocument` as a thin wrapper and `toml.zig` continues to
//! call it from `parseRecover`.
//!
//! The module is stateless; all data flows through the `*Parser` and
//! the caller-owned `errors` list. Only allocator failures (OOM) escape
//! as errors — every syntactic problem becomes an entry in the errors
//! list.

const std = @import("std");
const Allocator = std.mem.Allocator;

const err = @import("../error.zig");
const ErrorCode = err.ErrorCode;
const ParseError = err.ParseError;
const lex = @import("../lexer.zig");
const Lexer = lex.Lexer;
const val = @import("../value.zig");
const Value = val.Value;

// Forward-declared to break the import cycle. `Parser` is defined in
// `../parser.zig`; we only need its pointer here.
const parser_mod = @import("../parser.zig");
const Parser = parser_mod.Parser;
const ParseOptions = parser_mod.ParseOptions;

/// Recover-mode entry point. Produces a (possibly partial) `*Document`
/// plus a list of parse errors. The caller owns both and must free them
/// via `RecoveryResult.deinit(alloc)`.
///
/// Only allocator failures (OOM) escape as errors; every syntactic
/// problem becomes an entry in `RecoveryResult.errors`.
pub fn parseRecoverDocument(
    alloc: Allocator,
    input: []const u8,
    opts: ParseOptions,
) !@import("../toml.zig").RecoveryResult {
    const RecoveryResult = @import("../toml.zig").RecoveryResult;

    // Errors are collected in the caller's allocator so they can outlive
    // the document arena if the caller frees them separately. The
    // RecoveryResult.deinit helper handles both correctly.
    var errors: std.ArrayList(ParseError) = .empty;
    errdefer errors.deinit(alloc);

    // Terminal conditions first -- we cannot meaningfully recover past
    // these so we short-circuit to an empty document plus one error.
    if (!std.unicode.utf8ValidateSlice(input)) {
        try errors.append(alloc, err.makeError(.InvalidUtf8, .{}, "input is not valid UTF-8"));
        const empty_doc = try val.createDocument(alloc);
        return RecoveryResult{
            .document = empty_doc,
            .errors = try errors.toOwnedSlice(alloc),
        };
    }
    if (input.len > opts.max_bytes) {
        try errors.append(alloc, err.makeError(.LimitExceeded, .{}, "input exceeds max_bytes limit"));
        const empty_doc = try val.createDocument(alloc);
        return RecoveryResult{
            .document = empty_doc,
            .errors = try errors.toOwnedSlice(alloc),
        };
    }

    // Build the partial document into a fresh arena. Note we duplicate
    // the input into that arena for P-5 slice-lifetime invariants, just
    // like Parser.parse does.
    const doc = try val.createDocument(alloc);
    errdefer doc.deinit();

    const arena_alloc = doc.allocator();
    const owned_input = try arena_alloc.dupe(u8, input);

    var parser = Parser.init(alloc, owned_input, opts);
    parser.input = owned_input;
    parser.lexer = Lexer.init(owned_input, opts.version);
    parser.sink = .{ .document = .{ .alloc = arena_alloc, .root = doc.root } };

    // Prime the parser. A lexer failure at prime time is recorded and we
    // just continue with EOF so recovery has something to work with.
    parser.current = parser.nextToken() catch blk: {
        try recordParserError(&parser, &errors, alloc);
        break :blk .{ .tag = .eof, .start = 0, .end = 0, .pos = .{} };
    };

    try recoverParseLoop(&parser, arena_alloc, doc.root, &errors, alloc, opts);

    return RecoveryResult{
        .document = doc,
        .errors = try errors.toOwnedSlice(alloc),
    };
}

/// Append the parser's most-recent diagnostic to `errors`. If the parser
/// has no populated `parse_error`, fall back to a generic UnexpectedToken
/// so we still surface *something* to the caller.
fn recordParserError(
    parser: *Parser,
    errors: *std.ArrayList(ParseError),
    alloc: Allocator,
) !void {
    if (parser.parse_error) |pe| {
        try errors.append(alloc, pe);
        parser.parse_error = null;
    } else {
        try errors.append(alloc, err.makeError(.UnexpectedToken, parser.current.pos, "unknown parse error"));
    }
}

/// Main recovery loop. Mirrors Parser.parseDocument but wraps each
/// top-level construct in a try-catch so a single bad statement does not
/// abort the whole parse. Advances past errors via `recoverAdvancePastLine`,
/// which handles statement boundaries (newline, next `[`/`[[`) as well as
/// matching `}` / `]` for broken inline tables and arrays.
fn recoverParseLoop(
    parser: *Parser,
    arena_alloc: Allocator,
    root: *Value,
    errors: *std.ArrayList(ParseError),
    alloc: Allocator,
    opts: ParseOptions,
) !void {
    var current_table = root;

    while (parser.current.tag != .eof) {
        // Cap check FIRST -- runaway inputs must stop even if we would
        // otherwise make forward progress.
        if (errors.items.len >= opts.max_recovery_errors) return;

        switch (parser.current.tag) {
            .newline, .comment => {
                parser.current = parser.nextToken() catch {
                    try recordParserError(parser, errors, alloc);
                    recoverAdvancePastLine(parser);
                    continue;
                };
            },
            .left_bracket => {
                current_table = parser.parseTableHeader(arena_alloc, root, false) catch {
                    try recordParserError(parser, errors, alloc);
                    recoverAdvancePastLine(parser);
                    continue;
                };
            },
            .double_bracket_open => {
                current_table = parser.parseTableHeader(arena_alloc, root, true) catch {
                    try recordParserError(parser, errors, alloc);
                    recoverAdvancePastLine(parser);
                    continue;
                };
            },
            .bare_key,
            .basic_string,
            .literal_string,
            .float,
            .bool_true,
            .bool_false,
            .integer,
            .datetime,
            .datetime_local,
            .date_local,
            .time_local,
            => {
                parser.parseKeyValue(arena_alloc, current_table) catch {
                    try recordParserError(parser, errors, alloc);
                    recoverAdvancePastLine(parser);
                    continue;
                };
            },
            else => {
                try errors.append(alloc, err.makeError(.UnexpectedToken, parser.current.pos, "unexpected token"));
                recoverAdvancePastLine(parser);
            },
        }
    }
}

/// Advance the parser's `current` token until we hit a statement boundary
/// or EOF. "Statement boundary" is:
///   - a newline at nesting depth zero
///   - a `[` / `[[` at nesting depth zero
///   - a matching `}` for an unbalanced inline-table opener
///   - a matching `]` for an unbalanced array opener
///
/// The first action of the function is to consume one token unconditionally
/// so the recovery loop always makes forward progress -- calling this
/// function on a token that would otherwise re-enter the same error path
/// cannot deadlock the main loop.
fn recoverAdvancePastLine(parser: *Parser) void {
    // Guarantee forward progress: always consume the token that caused us
    // to enter recovery so we cannot loop on it. Lexer failures short-
    // circuit us straight to EOF.
    parser.current = parser.nextToken() catch .{
        .tag = .eof,
        .start = 0,
        .end = 0,
        .pos = .{},
    };

    var brace_depth: i32 = 0;
    var bracket_depth: i32 = 0;

    while (parser.current.tag != .eof) {
        switch (parser.current.tag) {
            .left_brace => brace_depth += 1,
            .right_brace => {
                if (brace_depth > 0) {
                    brace_depth -= 1;
                } else {
                    // Unbalanced close: this is the closer of the inline
                    // table we were inside when the error fired. Consume
                    // it and treat it as a statement boundary.
                    parser.current = parser.nextToken() catch .{
                        .tag = .eof,
                        .start = 0,
                        .end = 0,
                        .pos = .{},
                    };
                    return;
                }
            },
            .left_bracket => bracket_depth += 1,
            .right_bracket => {
                if (bracket_depth > 0) {
                    bracket_depth -= 1;
                } else {
                    parser.current = parser.nextToken() catch .{
                        .tag = .eof,
                        .start = 0,
                        .end = 0,
                        .pos = .{},
                    };
                    return;
                }
            },
            .double_bracket_close => {
                // `]]` unbalanced at depth 0: the recovery array had two
                // trailing `]`. Treat as boundary; consume and return.
                if (bracket_depth <= 1) {
                    parser.current = parser.nextToken() catch .{
                        .tag = .eof,
                        .start = 0,
                        .end = 0,
                        .pos = .{},
                    };
                    return;
                }
                bracket_depth -= 2;
            },
            .newline => {
                if (brace_depth == 0 and bracket_depth == 0) {
                    parser.current = parser.nextToken() catch .{
                        .tag = .eof,
                        .start = 0,
                        .end = 0,
                        .pos = .{},
                    };
                    return;
                }
            },
            else => {},
        }

        // A table header at depth zero is also a statement boundary even
        // without an intervening newline (defensive against missing `\n`).
        if (brace_depth == 0 and bracket_depth == 0) {
            switch (parser.current.tag) {
                .left_bracket, .double_bracket_open => return,
                else => {},
            }
        }

        parser.current = parser.nextToken() catch .{
            .tag = .eof,
            .start = 0,
            .end = 0,
            .pos = .{},
        };
    }
}
