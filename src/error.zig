// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! Error types and diagnostic information for the TOML parser.

const std = @import("std");

/// Error codes for TOML parsing failures.
pub const ErrorCode = enum {
    InvalidUtf8,
    UnexpectedToken,
    InvalidEscape,
    InvalidUnicodeScalar,
    DuplicateKey,
    KeyRedefinesNonTable,
    TableRedefined,
    ArrayOfTablesConflict,
    InlineTableNewlineNotAllowed,
    InlineTableTrailingCommaNotAllowed,
    LocalTimeSecondsOmittedNotAllowed,
    LimitExceeded,
    UnexpectedEof,
    InvalidNumber,
    InvalidDateTime,
    MixedArrayTypes,
    UnterminatedString,
    InvalidKey,
    InvalidControlCharacter,
    BareCarriageReturn,
};

/// Detailed parse error with location information.
pub const ParseError = struct {
    code: ErrorCode,
    byte_index: usize,
    line: u32,
    column: u32,
    message: []const u8,

    pub fn format(
        self: ParseError,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        try writer.print("error at line {d}, column {d}: {s}", .{
            self.line,
            self.column,
            self.message,
        });
    }
};

/// Position tracker for converting byte offsets to line/column.
pub const Position = struct {
    byte_index: usize = 0,
    line: u32 = 1,
    column: u32 = 1,

    pub fn advance(self: *Position, c: u8) void {
        self.byte_index += 1;
        if (c == '\n') {
            self.line += 1;
            self.column = 1;
        } else {
            self.column += 1;
        }
    }

    pub fn advanceBy(self: *Position, input: []const u8, count: usize) void {
        for (input[0..count]) |c| {
            self.advance(c);
        }
    }
};

/// Create a parse error with the given code and message at the specified position.
pub fn makeError(code: ErrorCode, pos: Position, comptime message: []const u8) ParseError {
    return .{
        .code = code,
        .byte_index = pos.byte_index,
        .line = pos.line,
        .column = pos.column,
        .message = message,
    };
}

/// Create a parse error with a dynamic message.
///
/// INVARIANT: Callers MUST ensure any dynamic `message` outlives every
/// consumer of the returned `ParseError`. In particular,
/// `parallel.validateDocument` carries `pe.message` past a per-call arena —
/// using `makeErrorDynamic` with arena-scoped bytes there will UAF once the
/// arena is freed. Prefer `makeError` (comptime literal) unless you can
/// prove the message storage outlives every downstream reader.
pub fn makeErrorDynamic(code: ErrorCode, pos: Position, message: []const u8) ParseError {
    return .{
        .code = code,
        .byte_index = pos.byte_index,
        .line = pos.line,
        .column = pos.column,
        .message = message,
    };
}
