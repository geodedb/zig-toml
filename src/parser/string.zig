// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! TOML string decoding (basic, literal, multi-line variants, escapes).

const std = @import("std");
const Allocator = std.mem.Allocator;
const err = @import("../error.zig");
const ErrorCode = err.ErrorCode;

const Parser = @import("../parser.zig").Parser;

pub fn decodeBasicString(self: *Parser, alloc: Allocator, raw: []const u8) ![]const u8 {
    // Remove quotes
    const content = raw[1 .. raw.len - 1];
    return decodeEscapes(self, alloc, content);
}

pub fn decodeLiteralString(self: *Parser, raw: []const u8) []const u8 {
    _ = self;
    // Remove quotes, no escape processing
    return raw[1 .. raw.len - 1];
}

pub fn decodeMultilineBasicString(self: *Parser, alloc: Allocator, raw: []const u8) ![]const u8 {
    // The lexer consumes """ + content + """ + up to 2 extra quotes
    // Count trailing quotes to determine how many are extra (absorbed by lexer)
    var extra_quotes: usize = 0;
    var idx = raw.len;
    while (idx > 3 and raw[idx - 1] == '"') {
        idx -= 1;
        extra_quotes += 1;
        if (extra_quotes > 2) break; // Max 2 extra quotes
    }

    // Remove opening """ and closing """ (but keep extra content quotes)
    // The lexer absorbed up to 2 extra quotes, so we strip 3 + extra_quotes from end
    const content_end = raw.len - 3; // Just remove closing """
    var content = raw[3..content_end];

    // Skip leading newline
    if (content.len > 0 and content[0] == '\n') {
        content = content[1..];
    } else if (content.len > 1 and content[0] == '\r' and content[1] == '\n') {
        content = content[2..];
    }

    return decodeMultilineEscapes(self, alloc, content);
}

pub fn decodeMultilineLiteralString(self: *Parser, raw: []const u8) []const u8 {
    _ = self;
    // Remove opening ''' and closing '''
    // The lexer consumed ''' + content + ''' + up to 2 extra quotes
    const content_end = raw.len - 3;
    var content = raw[3..content_end];

    // Skip leading newline
    if (content.len > 0 and content[0] == '\n') {
        content = content[1..];
    } else if (content.len > 1 and content[0] == '\r' and content[1] == '\n') {
        content = content[2..];
    }

    return content;
}

pub fn decodeEscapes(self: *Parser, alloc: Allocator, content: []const u8) ![]const u8 {
    // Pre-size to the raw length; escape decoding only shrinks (or leaves
    // unchanged) the byte count, so this is a safe upper bound and avoids
    // the ArrayList doubling ladder entirely on the hot string path.
    var result: std.ArrayList(u8) = try .initCapacity(alloc, content.len);

    var i: usize = 0;
    while (i < content.len) {
        if (content[i] == '\\') {
            i += 1;
            if (i >= content.len) {
                self.parse_error = err.makeError(.InvalidEscape, self.current.pos, "incomplete escape sequence");
                return error.ParseFailed;
            }

            try decodeEscapeChar(self, alloc, content, &i, &result);
        } else {
            try result.append(alloc, content[i]);
            i += 1;
        }
    }

    return result.toOwnedSlice(alloc);
}

pub fn decodeMultilineEscapes(self: *Parser, alloc: Allocator, content: []const u8) ![]const u8 {
    // Same upper-bound reasoning as decodeEscapes: output length <= input.
    var result: std.ArrayList(u8) = try .initCapacity(alloc, content.len);

    var i: usize = 0;
    while (i < content.len) {
        if (content[i] == '\\') {
            i += 1;
            if (i >= content.len) {
                self.parse_error = err.makeError(.InvalidEscape, self.current.pos, "incomplete escape sequence");
                return error.ParseFailed;
            }

            // Line-ending backslash: \ followed by optional whitespace then newline
            // Skip any whitespace between \ and newline
            var temp_i = i;
            while (temp_i < content.len and (content[temp_i] == ' ' or content[temp_i] == '\t')) {
                temp_i += 1;
            }
            if (temp_i < content.len and (content[temp_i] == '\n' or content[temp_i] == '\r')) {
                // This is a line-ending backslash - skip all whitespace until next content
                i = temp_i;
                while (i < content.len and (content[i] == '\n' or content[i] == '\r' or content[i] == ' ' or content[i] == '\t')) {
                    i += 1;
                }
            } else {
                try decodeEscapeChar(self, alloc, content, &i, &result);
            }
        } else if (content[i] == '\r' and i + 1 < content.len and content[i + 1] == '\n') {
            // Normalize CRLF to LF
            try result.append(alloc, '\n');
            i += 2;
        } else {
            try result.append(alloc, content[i]);
            i += 1;
        }
    }

    return result.toOwnedSlice(alloc);
}

pub fn decodeEscapeChar(self: *Parser, alloc: Allocator, content: []const u8, i: *usize, result: *std.ArrayList(u8)) !void {
    const c = content[i.*];
    i.* += 1;

    switch (c) {
        'b' => try result.append(alloc, 0x08),
        't' => try result.append(alloc, '\t'),
        'n' => try result.append(alloc, '\n'),
        'f' => try result.append(alloc, 0x0C),
        'r' => try result.append(alloc, '\r'),
        'e' => try result.append(alloc, 0x1B),
        '"' => try result.append(alloc, '"'),
        '\\' => try result.append(alloc, '\\'),
        'x' => {
            if (i.* + 2 > content.len) {
                self.parse_error = err.makeError(.InvalidEscape, self.current.pos, "incomplete \\x escape");
                return error.ParseFailed;
            }
            const hex = content[i.* .. i.* + 2];
            i.* += 2;
            const cp = std.fmt.parseInt(u21, hex, 16) catch {
                self.parse_error = err.makeError(.InvalidEscape, self.current.pos, "invalid \\x escape");
                return error.ParseFailed;
            };
            var buf: [4]u8 = undefined;
            const len = std.unicode.utf8Encode(cp, &buf) catch {
                self.parse_error = err.makeError(.InvalidUnicodeScalar, self.current.pos, "invalid unicode scalar");
                return error.ParseFailed;
            };
            try result.appendSlice(alloc, buf[0..len]);
        },
        'u' => {
            if (i.* + 4 > content.len) {
                self.parse_error = err.makeError(.InvalidEscape, self.current.pos, "incomplete \\u escape");
                return error.ParseFailed;
            }
            const hex = content[i.* .. i.* + 4];
            i.* += 4;
            const cp = std.fmt.parseInt(u21, hex, 16) catch {
                self.parse_error = err.makeError(.InvalidEscape, self.current.pos, "invalid \\u escape");
                return error.ParseFailed;
            };
            if (cp >= 0xD800 and cp <= 0xDFFF) {
                self.parse_error = err.makeError(.InvalidUnicodeScalar, self.current.pos, "surrogate code points not allowed");
                return error.ParseFailed;
            }
            var buf: [4]u8 = undefined;
            const len = std.unicode.utf8Encode(cp, &buf) catch {
                self.parse_error = err.makeError(.InvalidUnicodeScalar, self.current.pos, "invalid unicode scalar");
                return error.ParseFailed;
            };
            try result.appendSlice(alloc, buf[0..len]);
        },
        'U' => {
            if (i.* + 8 > content.len) {
                self.parse_error = err.makeError(.InvalidEscape, self.current.pos, "incomplete \\U escape");
                return error.ParseFailed;
            }
            const hex = content[i.* .. i.* + 8];
            i.* += 8;
            const cp = std.fmt.parseInt(u21, hex, 16) catch {
                self.parse_error = err.makeError(.InvalidEscape, self.current.pos, "invalid \\U escape");
                return error.ParseFailed;
            };
            if (cp > 0x10FFFF or (cp >= 0xD800 and cp <= 0xDFFF)) {
                self.parse_error = err.makeError(.InvalidUnicodeScalar, self.current.pos, "invalid unicode scalar");
                return error.ParseFailed;
            }
            var buf: [4]u8 = undefined;
            const len = std.unicode.utf8Encode(cp, &buf) catch {
                self.parse_error = err.makeError(.InvalidUnicodeScalar, self.current.pos, "invalid unicode scalar");
                return error.ParseFailed;
            };
            try result.appendSlice(alloc, buf[0..len]);
        },
        else => {
            self.parse_error = err.makeError(.InvalidEscape, self.current.pos, "invalid escape sequence");
            return error.ParseFailed;
        },
    }
}
