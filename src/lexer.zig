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
    utf8_error: bool,

    pub fn init(input: []const u8, version: TomlVersion) Lexer {
        return .{
            .input = input,
            .pos = .{},
            .version = version,
            .parse_error = null,
            .utf8_error = false,
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
        return switch (c) {
            '#' => try self.lexComment(),
            '\n', '\r' => try self.lexNewline(start_pos),
            '=' => self.singleCharToken(.equals, start_pos),
            ',' => self.singleCharToken(.comma, start_pos),
            '.' => self.singleCharToken(.dot, start_pos),
            '{' => self.singleCharToken(.left_brace, start_pos),
            '}' => self.singleCharToken(.right_brace, start_pos),
            '[' => self.lexBracket(start_pos, .left_bracket, .double_bracket_open),
            ']' => self.lexBracket(start_pos, .right_bracket, .double_bracket_close),
            '"' => if (self.lookAhead(1) == '"' and self.lookAhead(2) == '"')
                self.lexMultilineBasicString()
            else
                self.lexBasicString(),
            '\'' => if (self.lookAhead(1) == '\'' and self.lookAhead(2) == '\'')
                self.lexMultilineLiteralString()
            else
                self.lexLiteralString(),
            else => blk: {
                if (isDigit(c) or c == '+' or c == '-') break :blk self.lexNumberOrDateTime();
                if (isBareKeyChar(c)) break :blk try self.lexBareKeyOrBool();
                self.parse_error = err.makeError(.UnexpectedToken, start_pos, "unexpected character");
                break :blk error.ParseFailed;
            },
        };
    }

    /// Consume a single byte and return a Token with `tag` spanning it.
    fn singleCharToken(self: *Lexer, tag: TokenTag, start_pos: Position) Token {
        self.advance();
        return Token{
            .tag = tag,
            .start = start_pos.byte_index,
            .end = self.pos.byte_index,
            .pos = start_pos,
        };
    }

    /// Consume `[` or `]`, optionally promoting to the doubled form when
    /// the next byte repeats. `single` is the single-bracket tag, `double`
    /// is its doubled variant.
    fn lexBracket(self: *Lexer, start_pos: Position, single: TokenTag, double: TokenTag) Token {
        self.advance();
        const tag = if (self.peek() == self.input[start_pos.byte_index]) blk: {
            self.advance();
            break :blk double;
        } else single;
        return Token{
            .tag = tag,
            .start = start_pos.byte_index,
            .end = self.pos.byte_index,
            .pos = start_pos,
        };
    }

    /// Consume LF or CRLF as a newline token. A bare CR (CR not followed
    /// by LF) is a hard lex error per the TOML spec.
    fn lexNewline(self: *Lexer, start_pos: Position) !Token {
        if (self.peek() == '\r') {
            if (self.lookAhead(1) != '\n') {
                self.parse_error = err.makeError(.BareCarriageReturn, start_pos, "bare carriage return not allowed");
                return error.ParseFailed;
            }
            self.advance(); // CR
        }
        self.advance(); // LF
        return Token{
            .tag = .newline,
            .start = start_pos.byte_index,
            .end = self.pos.byte_index,
            .pos = start_pos,
        };
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
            try self.tryAdvance();
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
                    try self.tryAdvance(); // skip escaped char (may be non-ASCII)
                }
            } else if (c == '\n') {
                self.parse_error = err.makeError(.UnterminatedString, start_pos, "newline in basic string");
                return error.ParseFailed;
            } else if (isControlCharInBasicString(c)) {
                self.parse_error = err.makeError(.InvalidControlCharacter, self.pos, "control character must be escaped in basic string");
                return error.ParseFailed;
            } else {
                try self.tryAdvance();
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
                    try self.tryAdvance();
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
                try self.tryAdvance();
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
            try self.tryAdvance();
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
                try self.tryAdvance();
            }
        }

        self.parse_error = err.makeError(.UnterminatedString, start_pos, "unterminated multiline literal string");
        return error.ParseFailed;
    }

    /// Flags accumulated while scanning a numeric or datetime literal;
    /// together they pick the final TokenTag in classifyNumericToken.
    const NumericScan = struct {
        digit_count: usize = 0,
        has_dash: bool = false,
        has_colon: bool = false,
        has_dot: bool = false,
        has_underscore: bool = false,
        has_exp: bool = false,
        has_base_prefix: bool = false,
        has_datetime_sep: bool = false,
    };

    fn lexNumberOrDateTime(self: *Lexer) !Token {
        const start = self.pos.byte_index;
        const start_pos = self.pos;

        // Consume sign if present
        const has_sign = self.peek() == '+' or self.peek() == '-';
        if (has_sign) self.advance();

        // Special float values (inf, nan, +inf, -nan) are bare words, not numbers.
        if (self.peek() == 'i' or self.peek() == 'n') {
            return self.finishBareKeyRun(start, start_pos, .float);
        }

        // A signed identifier like "-key" also lands here; emit it as a
        // bare key rather than a malformed number.
        if (has_sign and !isDigit(self.peek()) and isBareKeyChar(self.peek())) {
            return self.finishBareKeyRun(start, start_pos, .bare_key);
        }

        var scan = NumericScan{};

        // 0x / 0o / 0b prefixes switch the digit alphabet.
        if (self.peek() == '0') {
            const next_char = self.lookAhead(1);
            if (next_char == 'x' or next_char == 'o' or next_char == 'b') {
                scan.has_base_prefix = true;
                self.advance(); // 0
                self.advance(); // x/o/b
            }
        }

        if (try self.scanNumericBody(&scan, start, start_pos)) |tok| return tok;

        // A trailing letter means this was really a bare key like "1k".
        // Hex/octal/binary literals whitelist letters, so only kick in
        // here when we didn't take a base prefix.
        if (self.pos.byte_index < self.input.len and !scan.has_base_prefix) {
            const c = self.peek();
            if ((c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z')) {
                return self.finishBareKeyRun(start, start_pos, .bare_key);
            }
        }

        return Token{
            .tag = classifyNumericToken(self.input[start..self.pos.byte_index], scan),
            .start = start,
            .end = self.pos.byte_index,
            .pos = start_pos,
        };
    }

    /// Consume the rest of a bare-key run (`isBareKeyChar`) and return a
    /// Token spanning `[start..current]` tagged as `tag`.
    fn finishBareKeyRun(self: *Lexer, start: usize, start_pos: Position, tag: TokenTag) Token {
        while (self.pos.byte_index < self.input.len and isBareKeyChar(self.peek())) {
            self.advance();
        }
        return Token{
            .tag = tag,
            .start = start,
            .end = self.pos.byte_index,
            .pos = start_pos,
        };
    }

    /// Drive the numeric/datetime scan loop. Populates `scan` and returns
    /// a bare-key Token early when the digit run turns out to be
    /// `NNNN-<letter>...` (e.g. `2000-word`). Otherwise returns null and
    /// leaves the caller to classify the final token.
    fn scanNumericBody(
        self: *Lexer,
        scan: *NumericScan,
        start: usize,
        start_pos: Position,
    ) !?Token {
        while (self.pos.byte_index < self.input.len) {
            const c = self.peek();
            if (isDigit(c) or (scan.has_base_prefix and isHexDigit(c))) {
                scan.digit_count += 1;
                self.advance();
            } else if (c == '_') {
                scan.has_underscore = true;
                self.advance();
            } else if (c == '-') {
                const next_ch = self.lookAhead(1);
                if (isDigit(next_ch)) {
                    scan.has_dash = true;
                    self.advance();
                } else if (isBareKeyChar(next_ch)) {
                    // `2000-word` -- bare key, not an RFC3339 date.
                    self.advance(); // consume -
                    return self.finishBareKeyRun(start, start_pos, .bare_key);
                } else break;
            } else if (c == ':') {
                scan.has_colon = true;
                self.advance();
            } else if (c == '.') {
                scan.has_dot = true;
                self.advance();
            } else if (c == 'e' or c == 'E') {
                scan.has_exp = true;
                self.advance();
                if (self.peek() == '+' or self.peek() == '-') self.advance();
            } else if (c == '+') {
                // Likely a timezone offset; the parser validates.
                self.advance();
            } else if (c == 'T' or c == 't' or c == ' ') {
                // Date-time separator only valid after `YYYY-MM-DD` and
                // must be followed by a digit (start of time).
                if (scan.has_dash and scan.digit_count >= 8 and isDigit(self.lookAhead(1))) {
                    scan.has_datetime_sep = true;
                    self.advance();
                } else break;
            } else if (c == 'Z' or c == 'z') {
                self.advance();
                break;
            } else break;
        }
        return null;
    }

    /// Decide the final TokenTag for a numeric/datetime run from the
    /// flags collected in `scanNumericBody`. Pure function over `scan`.
    fn classifyNumericToken(text: []const u8, scan: NumericScan) TokenTag {
        if (scan.has_datetime_sep and !scan.has_colon) return .invalid;
        if (scan.has_dash and scan.has_colon) return if (containsTimezone(text)) .datetime else .datetime_local;
        if (scan.has_dash and !scan.has_colon and !scan.has_exp) return .date_local;
        if (scan.has_colon and !scan.has_dash) return .time_local;
        if (scan.has_dot or scan.has_exp) return .float;
        return .integer;
    }

    fn lexBareKeyOrBool(self: *Lexer) !Token {
        const start = self.pos.byte_index;
        const start_pos = self.pos;

        while (self.pos.byte_index < self.input.len and isBareKeyChar(self.peek())) {
            try self.tryAdvance();
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

    fn tryAdvance(self: *Lexer) !void {
        self.advance();
        if (self.utf8_error) return error.ParseFailed;
    }

    fn advance(self: *Lexer) void {
        if (self.pos.byte_index >= self.input.len) return;
        const b = self.input[self.pos.byte_index];
        if (b < 0x80) {
            self.pos.advance(b);
            return;
        }
        // Multibyte UTF-8 start byte: validate the full sequence at the
        // current byte. On error, stash the diagnostic and leave `pos`
        // at the offending byte so the caller surfaces line/col there.
        const len = validateUtf8CodePoint(self.input, self.pos.byte_index) catch {
            self.parse_error = err.makeError(.InvalidUtf8, self.pos, "invalid UTF-8 sequence");
            self.utf8_error = true;
            return;
        };
        // Valid sequence: consume all `len` bytes. Position counts the
        // codepoint as one column; byte_index still advances by len.
        self.pos.byte_index += len;
        self.pos.column += 1;
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

/// Validate a UTF-8 codepoint that begins at `input[index]` when the
/// leading byte has the high bit set. Returns the byte length of the
/// sequence (2, 3, or 4). Returns `error.InvalidUtf8` for orphan
/// continuation bytes, overlong forms, truncated tails, surrogates, and
/// codepoints above U+10FFFF.
fn validateUtf8CodePoint(input: []const u8, index: usize) !u3 {
    const first = input[index];

    // Leading byte must not be a continuation byte and must not be one
    // of the five-or-more-byte patterns that were never valid UTF-8.
    if (first < 0x80) return 1; // ASCII: caller should not normally hit this.

    // 2-byte: 110xxxxx 10xxxxxx  (U+0080 .. U+07FF)
    if (first & 0xE0 == 0xC0) {
        if (first < 0xC2) return error.InvalidUtf8; // overlong
        if (index + 1 >= input.len) return error.InvalidUtf8;
        const b1 = input[index + 1];
        if (b1 & 0xC0 != 0x80) return error.InvalidUtf8;
        return 2;
    }

    // 3-byte: 1110xxxx 10xxxxxx 10xxxxxx  (U+0800 .. U+FFFF, excluding surrogates)
    if (first & 0xF0 == 0xE0) {
        if (index + 2 >= input.len) return error.InvalidUtf8;
        const b1 = input[index + 1];
        const b2 = input[index + 2];
        if (b1 & 0xC0 != 0x80) return error.InvalidUtf8;
        if (b2 & 0xC0 != 0x80) return error.InvalidUtf8;
        // Reject overlong: E0 80..9F is an overlong encoding of a 2-byte scalar.
        if (first == 0xE0 and b1 < 0xA0) return error.InvalidUtf8;
        // Reject surrogates: ED A0..BF encodes U+D800..U+DFFF.
        if (first == 0xED and b1 >= 0xA0) return error.InvalidUtf8;
        return 3;
    }

    // 4-byte: 11110xxx 10xxxxxx 10xxxxxx 10xxxxxx  (U+10000 .. U+10FFFF)
    if (first & 0xF8 == 0xF0) {
        if (first > 0xF4) return error.InvalidUtf8; // > U+10FFFF
        if (index + 3 >= input.len) return error.InvalidUtf8;
        const b1 = input[index + 1];
        const b2 = input[index + 2];
        const b3 = input[index + 3];
        if (b1 & 0xC0 != 0x80) return error.InvalidUtf8;
        if (b2 & 0xC0 != 0x80) return error.InvalidUtf8;
        if (b3 & 0xC0 != 0x80) return error.InvalidUtf8;
        // Reject overlong: F0 80..8F is an overlong encoding of a 3-byte scalar.
        if (first == 0xF0 and b1 < 0x90) return error.InvalidUtf8;
        // Reject > U+10FFFF: F4 90..BF is above the Unicode range.
        if (first == 0xF4 and b1 >= 0x90) return error.InvalidUtf8;
        return 4;
    }

    // Orphan continuation byte (10xxxxxx) or reserved leading byte (0xF5..0xFF).
    return error.InvalidUtf8;
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
