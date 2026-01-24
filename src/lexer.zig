// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! TOML lexer/tokenizer.

const std = @import("std");
const err = @import("error.zig");
const ErrorCode = err.ErrorCode;
const ParseError = err.ParseError;
const Position = err.Position;

pub const TomlVersion = enum { v1_0_0, v1_1_0 };

pub const TokenTag = enum {
    // Structural
    left_bracket,
    right_bracket,
    left_brace,
    right_brace,
    equals,
    comma,
    dot,
    newline,

    // Values
    bare_key,
    basic_string,
    literal_string,
    ml_basic_string,
    ml_literal_string,
    integer,
    float,
    bool_true,
    bool_false,
    datetime,
    datetime_local,
    date_local,
    time_local,

    // Special
    eof,
    comment,
    double_bracket_open, // [[
    double_bracket_close, // ]]
    invalid, // Invalid token (e.g., malformed datetime)
};

pub const Token = struct {
    tag: TokenTag,
    start: usize,
    end: usize,
    pos: Position,

    pub fn slice(self: Token, input: []const u8) []const u8 {
        return input[self.start..self.end];
    }
};

pub const Lexer = struct {
    input: []const u8,
    pos: Position,
    version: TomlVersion,
    parse_error: ?ParseError,

    pub fn init(input: []const u8, version: TomlVersion) Lexer {
        return .{
            .input = input,
            .pos = .{},
            .version = version,
            .parse_error = null,
        };
    }

    pub fn next(self: *Lexer) !Token {
        try self.skipWhitespace();

        if (self.pos.byte_index >= self.input.len) {
            return Token{
                .tag = .eof,
                .start = self.pos.byte_index,
                .end = self.pos.byte_index,
                .pos = self.pos,
            };
        }

        const start_pos = self.pos;
        const c = self.peek();

        // Comment
        if (c == '#') {
            return try self.lexComment();
        }

        // Newline (LF or CR+LF)
        if (c == '\n') {
            self.advance();
            return Token{
                .tag = .newline,
                .start = start_pos.byte_index,
                .end = self.pos.byte_index,
                .pos = start_pos,
            };
        }
        if (c == '\r') {
            if (self.lookAhead(1) == '\n') {
                self.advance(); // CR
                self.advance(); // LF
                return Token{
                    .tag = .newline,
                    .start = start_pos.byte_index,
                    .end = self.pos.byte_index,
                    .pos = start_pos,
                };
            } else {
                self.parse_error = err.makeError(.BareCarriageReturn, start_pos, "bare carriage return not allowed");
                return error.ParseFailed;
            }
        }

        // Structural tokens
        if (c == '=') {
            self.advance();
            return Token{ .tag = .equals, .start = start_pos.byte_index, .end = self.pos.byte_index, .pos = start_pos };
        }
        if (c == ',') {
            self.advance();
            return Token{ .tag = .comma, .start = start_pos.byte_index, .end = self.pos.byte_index, .pos = start_pos };
        }
        if (c == '.') {
            self.advance();
            return Token{ .tag = .dot, .start = start_pos.byte_index, .end = self.pos.byte_index, .pos = start_pos };
        }
        if (c == '{') {
            self.advance();
            return Token{ .tag = .left_brace, .start = start_pos.byte_index, .end = self.pos.byte_index, .pos = start_pos };
        }
        if (c == '}') {
            self.advance();
            return Token{ .tag = .right_brace, .start = start_pos.byte_index, .end = self.pos.byte_index, .pos = start_pos };
        }
        if (c == '[') {
            self.advance();
            if (self.peek() == '[') {
                self.advance();
                return Token{ .tag = .double_bracket_open, .start = start_pos.byte_index, .end = self.pos.byte_index, .pos = start_pos };
            }
            return Token{ .tag = .left_bracket, .start = start_pos.byte_index, .end = self.pos.byte_index, .pos = start_pos };
        }
        if (c == ']') {
            self.advance();
            if (self.peek() == ']') {
                self.advance();
                return Token{ .tag = .double_bracket_close, .start = start_pos.byte_index, .end = self.pos.byte_index, .pos = start_pos };
            }
            return Token{ .tag = .right_bracket, .start = start_pos.byte_index, .end = self.pos.byte_index, .pos = start_pos };
        }

        // Strings
        if (c == '"') {
            if (self.lookAhead(1) == '"' and self.lookAhead(2) == '"') {
                return self.lexMultilineBasicString();
            }
            return self.lexBasicString();
        }
        if (c == '\'') {
            if (self.lookAhead(1) == '\'' and self.lookAhead(2) == '\'') {
                return self.lexMultilineLiteralString();
            }
            return self.lexLiteralString();
        }

        // Numbers, dates, times, or bare keys
        if (isDigit(c) or c == '+' or c == '-') {
            return self.lexNumberOrDateTime();
        }

        // Boolean or bare key
        if (isBareKeyChar(c)) {
            return self.lexBareKeyOrBool();
        }

        self.parse_error = err.makeError(.UnexpectedToken, start_pos, "unexpected character");
        return error.ParseFailed;
    }

    fn lexComment(self: *Lexer) !Token {
        const start = self.pos.byte_index;
        const start_pos = self.pos;
        while (self.pos.byte_index < self.input.len) {
            const c = self.peek();
            // Check for newline (LF or CR+LF ends comment)
            if (c == '\n') break;
            if (c == '\r') {
                // CR+LF is a valid line ending
                if (self.lookAhead(1) == '\n') break;
                // Bare CR is not allowed
                self.parse_error = err.makeError(.BareCarriageReturn, self.pos, "bare carriage return not allowed in comment");
                return error.ParseFailed;
            }
            // Check for control characters (not allowed in comments except TAB)
            if (isControlCharInComment(c)) {
                self.parse_error = err.makeError(.InvalidControlCharacter, self.pos, "control character not allowed in comment");
                return error.ParseFailed;
            }
            self.advance();
        }
        return Token{
            .tag = .comment,
            .start = start,
            .end = self.pos.byte_index,
            .pos = start_pos,
        };
    }

    fn lexBasicString(self: *Lexer) !Token {
        const start = self.pos.byte_index;
        const start_pos = self.pos;
        self.advance(); // consume opening "

        while (self.pos.byte_index < self.input.len) {
            const c = self.peek();
            if (c == '"') {
                self.advance();
                return Token{
                    .tag = .basic_string,
                    .start = start,
                    .end = self.pos.byte_index,
                    .pos = start_pos,
                };
            }
            if (c == '\\') {
                self.advance();
                if (self.pos.byte_index < self.input.len) {
                    self.advance(); // skip escaped char
                }
            } else if (c == '\n') {
                self.parse_error = err.makeError(.UnterminatedString, start_pos, "newline in basic string");
                return error.ParseFailed;
            } else if (isControlCharInBasicString(c)) {
                self.parse_error = err.makeError(.InvalidControlCharacter, self.pos, "control character must be escaped in basic string");
                return error.ParseFailed;
            } else {
                self.advance();
            }
        }

        self.parse_error = err.makeError(.UnterminatedString, start_pos, "unterminated basic string");
        return error.ParseFailed;
    }

    fn lexMultilineBasicString(self: *Lexer) !Token {
        const start = self.pos.byte_index;
        const start_pos = self.pos;
        self.advance(); // "
        self.advance(); // "
        self.advance(); // "

        // Skip optional newline immediately after opening quotes
        if (self.peek() == '\n') {
            self.advance();
        } else if (self.peek() == '\r' and self.lookAhead(1) == '\n') {
            self.advance();
            self.advance();
        }

        while (self.pos.byte_index < self.input.len) {
            const c = self.peek();
            if (c == '"' and self.lookAhead(1) == '"' and self.lookAhead(2) == '"') {
                self.advance();
                self.advance();
                self.advance();
                // Handle up to 2 additional quotes (for strings ending in quotes)
                while (self.peek() == '"' and self.pos.byte_index < self.input.len) {
                    // Check if we have too many quotes
                    if (self.lookAhead(1) == '"' and self.lookAhead(2) == '"') break;
                    self.advance();
                }
                return Token{
                    .tag = .ml_basic_string,
                    .start = start,
                    .end = self.pos.byte_index,
                    .pos = start_pos,
                };
            }
            if (c == '\\') {
                self.advance();
                if (self.pos.byte_index < self.input.len) {
                    self.advance();
                }
            } else if (c == '\r') {
                // Check for bare CR (CR not followed by LF)
                if (self.lookAhead(1) != '\n') {
                    self.parse_error = err.makeError(.BareCarriageReturn, self.pos, "bare carriage return not allowed");
                    return error.ParseFailed;
                }
                self.advance(); // CR
                self.advance(); // LF
            } else if (isControlCharInMultilineString(c)) {
                self.parse_error = err.makeError(.InvalidControlCharacter, self.pos, "control character must be escaped in multiline string");
                return error.ParseFailed;
            } else {
                self.advance();
            }
        }

        self.parse_error = err.makeError(.UnterminatedString, start_pos, "unterminated multiline basic string");
        return error.ParseFailed;
    }

    fn lexLiteralString(self: *Lexer) !Token {
        const start = self.pos.byte_index;
        const start_pos = self.pos;
        self.advance(); // consume opening '

        while (self.pos.byte_index < self.input.len) {
            const c = self.peek();
            if (c == '\'') {
                self.advance();
                return Token{
                    .tag = .literal_string,
                    .start = start,
                    .end = self.pos.byte_index,
                    .pos = start_pos,
                };
            }
            if (c == '\n') {
                self.parse_error = err.makeError(.UnterminatedString, start_pos, "newline in literal string");
                return error.ParseFailed;
            }
            if (isControlCharInLiteralString(c)) {
                self.parse_error = err.makeError(.InvalidControlCharacter, self.pos, "control character not allowed in literal string");
                return error.ParseFailed;
            }
            self.advance();
        }

        self.parse_error = err.makeError(.UnterminatedString, start_pos, "unterminated literal string");
        return error.ParseFailed;
    }

    fn lexMultilineLiteralString(self: *Lexer) !Token {
        const start = self.pos.byte_index;
        const start_pos = self.pos;
        self.advance(); // '
        self.advance(); // '
        self.advance(); // '

        // Skip optional newline immediately after opening quotes
        if (self.peek() == '\n') {
            self.advance();
        } else if (self.peek() == '\r' and self.lookAhead(1) == '\n') {
            self.advance();
            self.advance();
        }

        while (self.pos.byte_index < self.input.len) {
            const c = self.peek();
            if (c == '\'' and self.lookAhead(1) == '\'' and self.lookAhead(2) == '\'') {
                self.advance();
                self.advance();
                self.advance();
                // Handle up to 2 additional quotes
                while (self.peek() == '\'' and self.pos.byte_index < self.input.len) {
                    if (self.lookAhead(1) == '\'' and self.lookAhead(2) == '\'') break;
                    self.advance();
                }
                return Token{
                    .tag = .ml_literal_string,
                    .start = start,
                    .end = self.pos.byte_index,
                    .pos = start_pos,
                };
            }
            if (c == '\r') {
                // Check for bare CR (CR not followed by LF)
                if (self.lookAhead(1) != '\n') {
                    self.parse_error = err.makeError(.BareCarriageReturn, self.pos, "bare carriage return not allowed");
                    return error.ParseFailed;
                }
                self.advance(); // CR
                self.advance(); // LF
            } else if (isControlCharInMultilineString(c)) {
                self.parse_error = err.makeError(.InvalidControlCharacter, self.pos, "control character not allowed in multiline literal string");
                return error.ParseFailed;
            } else {
                self.advance();
            }
        }

        self.parse_error = err.makeError(.UnterminatedString, start_pos, "unterminated multiline literal string");
        return error.ParseFailed;
    }

    fn lexNumberOrDateTime(self: *Lexer) !Token {
        const start = self.pos.byte_index;
        const start_pos = self.pos;

        // Consume sign if present
        const has_sign = self.peek() == '+' or self.peek() == '-';
        if (has_sign) {
            self.advance();
        }

        // Check for special float values: inf, nan
        if (self.peek() == 'i' or self.peek() == 'n') {
            // Consume the keyword
            while (self.pos.byte_index < self.input.len and isBareKeyChar(self.peek())) {
                self.advance();
            }
            return Token{
                .tag = .float,
                .start = start,
                .end = self.pos.byte_index,
                .pos = start_pos,
            };
        }

        // If sign is followed by a non-digit letter, this is a bare key like "-key"
        if (has_sign and !isDigit(self.peek()) and isBareKeyChar(self.peek())) {
            while (self.pos.byte_index < self.input.len and isBareKeyChar(self.peek())) {
                self.advance();
            }
            return Token{
                .tag = .bare_key,
                .start = start,
                .end = self.pos.byte_index,
                .pos = start_pos,
            };
        }

        // Count digits and look for date/time patterns
        var digit_count: usize = 0;
        var has_dash = false;
        var has_colon = false;
        var has_dot = false;
        var has_underscore = false;
        var has_exp = false;
        var has_base_prefix = false;
        var has_datetime_sep = false;

        // Check for 0x, 0o, 0b prefix
        if (self.peek() == '0') {
            const next_char = self.lookAhead(1);
            if (next_char == 'x' or next_char == 'o' or next_char == 'b') {
                has_base_prefix = true;
                self.advance(); // 0
                self.advance(); // x/o/b
            }
        }

        // Scan the number/datetime
        while (self.pos.byte_index < self.input.len) {
            const c = self.peek();
            if (isDigit(c) or (has_base_prefix and isHexDigit(c))) {
                digit_count += 1;
                self.advance();
            } else if (c == '_') {
                has_underscore = true;
                self.advance();
            } else if (c == '-') {
                // Only consume dash if followed by a digit (date pattern like YYYY-MM-DD)
                const next_ch = self.lookAhead(1);
                if (isDigit(next_ch)) {
                    has_dash = true;
                    self.advance();
                } else if (isBareKeyChar(next_ch)) {
                    // Dash followed by letter - this is a bare key like "2000-datetime"
                    // Consume rest as bare key
                    self.advance(); // consume -
                    while (self.pos.byte_index < self.input.len and isBareKeyChar(self.peek())) {
                        self.advance();
                    }
                    return Token{
                        .tag = .bare_key,
                        .start = start,
                        .end = self.pos.byte_index,
                        .pos = start_pos,
                    };
                } else {
                    break; // Dash not followed by valid char
                }
            } else if (c == ':') {
                has_colon = true;
                self.advance();
            } else if (c == '.') {
                has_dot = true;
                self.advance();
            } else if (c == 'e' or c == 'E') {
                has_exp = true;
                self.advance();
                if (self.peek() == '+' or self.peek() == '-') {
                    self.advance();
                }
            } else if (c == '+') {
                // Could be timezone offset
                self.advance();
            } else if (c == 'T' or c == 't' or c == ' ') {
                // Date-time separator - only valid after YYYY-MM-DD (at least 8 digits)
                // Only consume if followed by a digit (start of time)
                if (has_dash and digit_count >= 8) {
                    const next_ch = self.lookAhead(1);
                    if (isDigit(next_ch)) {
                        has_datetime_sep = true;
                        self.advance();
                    } else {
                        break;
                    }
                } else {
                    break;
                }
            } else if (c == 'Z' or c == 'z') {
                self.advance();
                break;
            } else {
                break;
            }
        }

        // Check if there are more bare key chars (letters) following
        // If so, this is a bare key like "1key", not a number
        if (self.pos.byte_index < self.input.len and !has_base_prefix) {
            const c = self.peek();
            if ((c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z')) {
                // Consume rest as bare key
                while (self.pos.byte_index < self.input.len and isBareKeyChar(self.peek())) {
                    self.advance();
                }
                return Token{
                    .tag = .bare_key,
                    .start = start,
                    .end = self.pos.byte_index,
                    .pos = start_pos,
                };
            }
        }

        const text = self.input[start..self.pos.byte_index];

        // Determine token type based on content
        // If we consumed a datetime separator (T) but no time (colon), it's invalid
        const tag: TokenTag = if (has_datetime_sep and !has_colon)
            .invalid // Date with T but no time part
        else if (has_dash and has_colon)
            if (containsTimezone(text)) .datetime else .datetime_local
        else if (has_dash and !has_colon and !has_exp)
            .date_local
        else if (has_colon and !has_dash)
            .time_local
        else if (has_dot or has_exp)
            .float
        else
            .integer;

        return Token{
            .tag = tag,
            .start = start,
            .end = self.pos.byte_index,
            .pos = start_pos,
        };
    }

    fn lexBareKeyOrBool(self: *Lexer) Token {
        const start = self.pos.byte_index;
        const start_pos = self.pos;

        while (self.pos.byte_index < self.input.len and isBareKeyChar(self.peek())) {
            self.advance();
        }

        const text = self.input[start..self.pos.byte_index];

        const tag: TokenTag = if (std.mem.eql(u8, text, "true"))
            .bool_true
        else if (std.mem.eql(u8, text, "false"))
            .bool_false
        else if (std.mem.eql(u8, text, "inf") or std.mem.eql(u8, text, "+inf") or std.mem.eql(u8, text, "-inf"))
            .float
        else if (std.mem.eql(u8, text, "nan") or std.mem.eql(u8, text, "+nan") or std.mem.eql(u8, text, "-nan"))
            .float
        else
            .bare_key;

        return Token{
            .tag = tag,
            .start = start,
            .end = self.pos.byte_index,
            .pos = start_pos,
        };
    }

    fn skipWhitespace(self: *Lexer) !void {
        while (self.pos.byte_index < self.input.len) {
            const c = self.peek();
            if (c == ' ' or c == '\t') {
                self.advance();
            } else if (c == '\r') {
                // CR must be followed by LF
                if (self.lookAhead(1) != '\n') {
                    self.parse_error = err.makeError(.BareCarriageReturn, self.pos, "bare carriage return not allowed");
                    return error.ParseFailed;
                }
                // Don't consume CR here, let newline handling deal with CR+LF
                break;
            } else {
                break;
            }
        }
    }

    fn peek(self: *Lexer) u8 {
        if (self.pos.byte_index >= self.input.len) return 0;
        return self.input[self.pos.byte_index];
    }

    fn lookAhead(self: *Lexer, offset: usize) u8 {
        const idx = self.pos.byte_index + offset;
        if (idx >= self.input.len) return 0;
        return self.input[idx];
    }

    fn advance(self: *Lexer) void {
        if (self.pos.byte_index < self.input.len) {
            self.pos.advance(self.input[self.pos.byte_index]);
        }
    }
};

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

fn isHexDigit(c: u8) bool {
    return isDigit(c) or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
}

fn isBareKeyChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or
        (c >= 'A' and c <= 'Z') or
        (c >= '0' and c <= '9') or
        c == '_' or c == '-';
}

fn containsTimezone(text: []const u8) bool {
    for (text) |c| {
        if (c == 'Z' or c == 'z') return true;
    }
    // Check for +/-HH:MM offset after T
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (text[i] == 'T' or text[i] == 't' or text[i] == ' ') {
            // Look for timezone offset
            var j = i + 1;
            while (j < text.len) : (j += 1) {
                if (text[j] == '+' or text[j] == '-') {
                    // Check if followed by HH:MM pattern
                    if (j + 5 <= text.len) {
                        return true;
                    }
                }
            }
        }
    }
    return false;
}

/// Check if character is a control character that's not allowed.
/// Control chars are U+0000-U+001F and U+007F (DEL).
/// TAB (0x09) is generally allowed but context-dependent.
fn isControlChar(c: u8) bool {
    return (c <= 0x1F and c != '\t') or c == 0x7F;
}

/// Check if character is a control character not allowed in comments.
/// Only TAB is allowed in comments, not other control chars including newlines.
fn isControlCharInComment(c: u8) bool {
    return (c <= 0x1F and c != '\t') or c == 0x7F;
}

/// Check if character is a control character not allowed in basic strings.
/// TAB is allowed. Other control chars must be escaped.
fn isControlCharInBasicString(c: u8) bool {
    return (c <= 0x1F and c != '\t') or c == 0x7F;
}

/// Check if character is a control character not allowed in literal strings.
/// TAB is allowed. Other control chars are not allowed (can't be escaped).
fn isControlCharInLiteralString(c: u8) bool {
    return (c <= 0x1F and c != '\t') or c == 0x7F;
}

/// Check if character is a control character not allowed in multiline strings.
/// TAB and newlines (LF) are allowed.
fn isControlCharInMultilineString(c: u8) bool {
    return (c <= 0x1F and c != '\t' and c != '\n') or c == 0x7F;
}
