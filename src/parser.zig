// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! TOML parser implementation.

const std = @import("std");
const Allocator = std.mem.Allocator;
const err = @import("error.zig");
const ErrorCode = err.ErrorCode;
const ParseError = err.ParseError;
const Position = err.Position;
const lex = @import("lexer.zig");
const Lexer = lex.Lexer;
const Token = lex.Token;
const TokenTag = lex.TokenTag;
const val = @import("value.zig");
const Value = val.Value;
const Document = val.Document;
const TableEntry = val.TableEntry;

pub const TomlVersion = lex.TomlVersion;

pub const ParseOptions = struct {
    version: TomlVersion = .v1_1_0,
    max_depth: u16 = 128,
    max_bytes: usize = 16 * 1024 * 1024,
};

pub const Parser = struct {
    lexer: Lexer,
    alloc: Allocator,
    current: Token,
    peeked: ?Token,
    options: ParseOptions,
    depth: u16,
    parse_error: ?ParseError,
    input: []const u8,

    pub fn init(alloc: Allocator, input: []const u8, options: ParseOptions) Parser {
        return .{
            .lexer = Lexer.init(input, options.version),
            .alloc = alloc,
            .current = undefined,
            .peeked = null,
            .options = options,
            .depth = 0,
            .parse_error = null,
            .input = input,
        };
    }

    pub fn parse(self: *Parser) !Document {
        // UTF-8 validation
        if (!std.unicode.utf8ValidateSlice(self.input)) {
            self.parse_error = err.makeError(.InvalidUtf8, .{}, "input is not valid UTF-8");
            return error.ParseFailed;
        }

        // Size limit check
        if (self.input.len > self.options.max_bytes) {
            self.parse_error = err.makeError(.LimitExceeded, .{}, "input exceeds max_bytes limit");
            return error.ParseFailed;
        }

        var arena = std.heap.ArenaAllocator.init(self.alloc);
        errdefer arena.deinit();

        const arena_alloc = arena.allocator();
        const root = try val.createTable(arena_alloc);

        // Prime the parser
        self.current = try self.nextToken();

        // Parse document
        try self.parseDocument(arena_alloc, root);

        return Document{
            .root = root,
            .arena = arena,
        };
    }

    fn parseDocument(self: *Parser, alloc: Allocator, root: *Value) !void {
        var current_table = root;

        while (self.current.tag != .eof) {
            switch (self.current.tag) {
                .newline, .comment => {
                    self.current = try self.nextToken();
                },
                .left_bracket => {
                    // Table header [key.path]
                    current_table = try self.parseTableHeader(alloc, root, false);
                },
                .double_bracket_open => {
                    // Array of tables [[key.path]]
                    current_table = try self.parseTableHeader(alloc, root, true);
                },
                .bare_key,
                .basic_string,
                .literal_string,
                // Keywords, numbers, and datetime-like tokens are valid bare keys
                .float,
                .bool_true,
                .bool_false,
                .integer,
                .datetime,
                .datetime_local,
                .date_local,
                .time_local,
                => {
                    // Key-value pair
                    try self.parseKeyValue(alloc, current_table);
                },
                else => {
                    self.parse_error = err.makeError(.UnexpectedToken, self.current.pos, "unexpected token");
                    return error.ParseFailed;
                },
            }
        }
    }

    fn parseTableHeader(self: *Parser, alloc: Allocator, root: *Value, is_array_of_tables: bool) !*Value {
        const start_pos = self.current.pos;
        self.current = try self.nextToken(); // consume [ or [[

        // Parse key path. 8 segments covers all realistic dotted paths
        // without reallocating; deeper paths grow normally.
        var path: std.ArrayList([]const u8) = try .initCapacity(alloc, 8);
        try self.parseKeyPath(alloc, &path);

        // Expect closing bracket(s)
        if (is_array_of_tables) {
            if (self.current.tag != .double_bracket_close) {
                self.parse_error = err.makeError(.UnexpectedToken, self.current.pos, "expected ']]'");
                return error.ParseFailed;
            }
        } else {
            if (self.current.tag != .right_bracket) {
                self.parse_error = err.makeError(.UnexpectedToken, self.current.pos, "expected ']'");
                return error.ParseFailed;
            }
        }
        self.current = try self.nextToken();

        // Skip trailing whitespace/newline/comment
        try self.skipToNewline();

        // Navigate/create the table path
        return self.resolveTablePath(alloc, root, path.items, is_array_of_tables, start_pos);
    }

    fn resolveTablePath(self: *Parser, alloc: Allocator, root: *Value, path: []const []const u8, is_array_of_tables: bool, pos: Position) !*Value {
        var current = root;

        for (path, 0..) |key, i| {
            const is_last = (i == path.len - 1);

            // Check if key exists. O(1).
            const found: ?*Value = current.table.map.get(key);

            if (found) |existing| {
                if (is_last) {
                    if (is_array_of_tables) {
                        // Must be an array
                        if (existing.* != .array) {
                            self.parse_error = err.makeError(.ArrayOfTablesConflict, pos, "key is not an array of tables");
                            return error.ParseFailed;
                        }
                        if (existing.array.is_static) {
                            self.parse_error = err.makeError(.ArrayOfTablesConflict, pos, "cannot append to statically defined array");
                            return error.ParseFailed;
                        }
                        // Create new table and append to array
                        const new_table = try val.createTable(alloc);
                        new_table.table.defined_explicitly = true;
                        try val.arrayAppend(alloc, existing, new_table);
                        return new_table;
                    } else {
                        // Regular table - must be a table and not already explicitly defined
                        if (existing.* != .table) {
                            self.parse_error = err.makeError(.KeyRedefinesNonTable, pos, "key is not a table");
                            return error.ParseFailed;
                        }
                        if (existing.table.is_inline) {
                            self.parse_error = err.makeError(.TableRedefined, pos, "cannot redefine inline table");
                            return error.ParseFailed;
                        }
                        if (existing.table.defined_explicitly and !existing.table.is_array_of_tables) {
                            self.parse_error = err.makeError(.TableRedefined, pos, "table already defined");
                            return error.ParseFailed;
                        }
                        // Cannot explicitly define a table that was created via dotted keys
                        if (existing.table.defined_by_dotted_key) {
                            self.parse_error = err.makeError(.TableRedefined, pos, "cannot redefine table created via dotted keys");
                            return error.ParseFailed;
                        }
                        existing.table.defined_explicitly = true;
                        current = existing;
                    }
                } else {
                    // Intermediate key
                    if (existing.* == .array) {
                        // Navigate to last element of array of tables
                        if (existing.array.items.items.len == 0) {
                            self.parse_error = err.makeError(.UnexpectedToken, pos, "empty array in path");
                            return error.ParseFailed;
                        }
                        // Cannot extend tables within static arrays
                        if (existing.array.is_static) {
                            self.parse_error = err.makeError(.TableRedefined, pos, "cannot extend tables in static array");
                            return error.ParseFailed;
                        }
                        current = existing.array.items.items[existing.array.items.items.len - 1];
                    } else if (existing.* == .table) {
                        // Cannot extend inline tables
                        if (existing.table.is_inline) {
                            self.parse_error = err.makeError(.TableRedefined, pos, "cannot extend inline table");
                            return error.ParseFailed;
                        }
                        current = existing;
                    } else {
                        self.parse_error = err.makeError(.KeyRedefinesNonTable, pos, "intermediate key is not a table");
                        return error.ParseFailed;
                    }
                }
            } else {
                // Key doesn't exist - create it
                if (is_last and is_array_of_tables) {
                    // Create array of tables
                    const arr = try val.createArray(alloc);
                    arr.array.is_static = false;
                    const new_table = try val.createTable(alloc);
                    new_table.table.defined_explicitly = true;
                    new_table.table.is_array_of_tables = true;
                    try val.arrayAppend(alloc, arr, new_table);
                    try val.tableSet(alloc, current, key, arr);
                    return new_table;
                } else {
                    // Create implicit table
                    const new_table = try val.createTable(alloc);
                    if (is_last) {
                        new_table.table.defined_explicitly = true;
                    }
                    try val.tableSet(alloc, current, key, new_table);
                    current = new_table;
                }
            }
        }

        return current;
    }

    fn parseKeyValue(self: *Parser, alloc: Allocator, table: *Value) !void {
        // Save position of the key for error reporting
        const key_pos = self.current.pos;

        // Parse key path (may be dotted). 8 segments handles practical paths.
        var path: std.ArrayList([]const u8) = try .initCapacity(alloc, 8);
        try self.parseKeyPath(alloc, &path);

        if (path.items.len == 0) {
            self.parse_error = err.makeError(.InvalidKey, key_pos, "empty key");
            return error.ParseFailed;
        }

        // Expect =
        if (self.current.tag != .equals) {
            self.parse_error = err.makeError(.UnexpectedToken, self.current.pos, "expected '='");
            return error.ParseFailed;
        }
        self.current = try self.nextToken();

        // Parse value
        const value = try self.parseValue(alloc);

        // Navigate to the correct table for dotted keys
        var target = table;
        for (path.items[0 .. path.items.len - 1]) |key| {
            const found: ?*Value = target.table.map.get(key);

            if (found) |existing| {
                if (existing.* != .table) {
                    self.parse_error = err.makeError(.KeyRedefinesNonTable, self.current.pos, "dotted key path references non-table");
                    return error.ParseFailed;
                }
                if (existing.table.is_inline) {
                    self.parse_error = err.makeError(.TableRedefined, self.current.pos, "cannot extend inline table");
                    return error.ParseFailed;
                }
                // Cannot use dotted keys to add to an explicitly defined table
                if (existing.table.defined_explicitly) {
                    self.parse_error = err.makeError(.TableRedefined, self.current.pos, "cannot add to explicitly defined table using dotted keys");
                    return error.ParseFailed;
                }
                target = existing;
            } else {
                const new_table = try val.createTable(alloc);
                new_table.table.defined_by_dotted_key = true;
                try val.tableSet(alloc, target, key, new_table);
                target = new_table;
            }
        }

        // Set the final key
        const final_key = path.items[path.items.len - 1];
        if (val.tableContains(target, final_key)) {
            self.parse_error = err.makeError(.DuplicateKey, key_pos, "duplicate key");
            return error.ParseFailed;
        }
        try val.tableSet(alloc, target, final_key, value);

        // Skip to next line
        try self.skipToNewline();
    }

    fn parseKeyPath(self: *Parser, alloc: Allocator, path: *std.ArrayList([]const u8)) !void {
        while (true) {
            // Handle float tokens like "1.2" as dotted keys "1"."2"
            if (self.current.tag == .float) {
                const text = self.current.slice(self.input);
                // Check if it contains a dot (not inf/nan)
                if (std.mem.indexOf(u8, text, ".")) |dot_pos| {
                    // Split into parts
                    try path.append(alloc, try alloc.dupe(u8, text[0..dot_pos]));
                    var rest = text[dot_pos + 1 ..];
                    // Handle multiple dots (like 1.2.3)
                    while (std.mem.indexOf(u8, rest, ".")) |next_dot| {
                        try path.append(alloc, try alloc.dupe(u8, rest[0..next_dot]));
                        rest = rest[next_dot + 1 ..];
                    }
                    try path.append(alloc, try alloc.dupe(u8, rest));
                    self.current = try self.nextToken();
                    // Check if there's more path
                    if (self.current.tag == .dot) {
                        self.current = try self.nextToken();
                        continue;
                    }
                    return;
                }
            }

            const key = try self.parseKey(alloc);
            try path.append(alloc, key);

            if (self.current.tag == .dot) {
                self.current = try self.nextToken();
            } else {
                break;
            }
        }
    }

    fn parseKey(self: *Parser, alloc: Allocator) ![]const u8 {
        const key = switch (self.current.tag) {
            .bare_key => self.current.slice(self.input),
            .basic_string => try self.decodeBasicString(alloc, self.current.slice(self.input)),
            .literal_string => self.decodeLiteralString(self.current.slice(self.input)),
            // Keywords, numbers, and datetime-like tokens are valid bare keys
            .float,
            .bool_true,
            .bool_false,
            .integer,
            .datetime,
            .datetime_local,
            .date_local,
            .time_local,
            => self.current.slice(self.input),
            else => {
                self.parse_error = err.makeError(.InvalidKey, self.current.pos, "expected key");
                return error.ParseFailed;
            },
        };
        self.current = try self.nextToken();
        return key;
    }

    const ParseValueError = error{ ParseFailed, OutOfMemory };

    /// Increment the recursion depth counter and bail if the configured
    /// max_depth is exceeded. Every recursive descent entrypoint
    /// (parseValue, parseArray, parseInlineTable, parseArrayContents,
    /// parseNestedArrayFromDoubleBracket) MUST call this with a matching
    /// `exitDepth()` in a defer to guarantee resource-exhaustion guards
    /// cannot be bypassed by any alternate call path.
    fn enterDepth(self: *Parser) !void {
        self.depth += 1;
        if (self.depth > self.options.max_depth) {
            self.parse_error = err.makeError(.LimitExceeded, self.current.pos, "max nesting depth exceeded");
            return error.ParseFailed;
        }
    }

    fn exitDepth(self: *Parser) void {
        self.depth -= 1;
    }

    fn parseValue(self: *Parser, alloc: Allocator) ParseValueError!*Value {
        try self.enterDepth();
        defer self.exitDepth();

        const result = try alloc.create(Value);

        switch (self.current.tag) {
            .basic_string => {
                result.* = .{ .string = try self.decodeBasicString(alloc, self.current.slice(self.input)) };
                self.current = try self.nextToken();
            },
            .literal_string => {
                result.* = .{ .string = try alloc.dupe(u8, self.decodeLiteralString(self.current.slice(self.input))) };
                self.current = try self.nextToken();
            },
            .ml_basic_string => {
                result.* = .{ .string = try self.decodeMultilineBasicString(alloc, self.current.slice(self.input)) };
                self.current = try self.nextToken();
            },
            .ml_literal_string => {
                result.* = .{ .string = try alloc.dupe(u8, self.decodeMultilineLiteralString(self.current.slice(self.input))) };
                self.current = try self.nextToken();
            },
            .integer => {
                result.* = .{ .integer = try self.parseInteger(self.current.slice(self.input)) };
                self.current = try self.nextToken();
            },
            .float => {
                result.* = .{ .float = try self.parseFloat(self.current.slice(self.input)) };
                self.current = try self.nextToken();
            },
            .bool_true => {
                result.* = .{ .bool = true };
                self.current = try self.nextToken();
            },
            .bool_false => {
                result.* = .{ .bool = false };
                self.current = try self.nextToken();
            },
            .datetime => {
                result.* = .{ .datetime = try self.parseDateTime(self.current.slice(self.input)) };
                self.current = try self.nextToken();
            },
            .datetime_local => {
                result.* = .{ .datetime_local = try self.parseDateTimeLocal(self.current.slice(self.input)) };
                self.current = try self.nextToken();
            },
            .date_local => {
                result.* = .{ .date_local = try self.parseDateLocal(self.current.slice(self.input)) };
                self.current = try self.nextToken();
            },
            .time_local => {
                result.* = .{ .time_local = try self.parseTimeLocal(self.current.slice(self.input)) };
                self.current = try self.nextToken();
            },
            .left_bracket => {
                result.* = try self.parseArray(alloc);
            },
            .double_bracket_open => {
                // [[ in value context means nested array, not array-of-tables
                result.* = try self.parseNestedArrayFromDoubleBracket(alloc);
            },
            .left_brace => {
                result.* = try self.parseInlineTable(alloc);
            },
            else => {
                self.parse_error = err.makeError(.UnexpectedToken, self.current.pos, "expected value");
                return error.ParseFailed;
            },
        }

        return result;
    }

    fn parseArray(self: *Parser, alloc: Allocator) ParseValueError!Value {
        // Defense-in-depth: parseArray is normally called via parseValue
        // (which already guards), but any alternate caller (e.g. future
        // direct invocation) would bypass the recursion cap. Guard here
        // too so the protection holds regardless of call path.
        try self.enterDepth();
        defer self.exitDepth();

        self.current = try self.nextToken(); // consume [

        // 16-slot initial capacity covers most literal arrays without
        // the ArrayList's doubling ladder (0->8->16 saves two reallocs).
        var items: std.ArrayList(*Value) = try .initCapacity(alloc, 16);

        // Skip whitespace and newlines
        try self.skipArrayWhitespace();

        while (self.current.tag != .right_bracket and self.current.tag != .double_bracket_close and self.current.tag != .eof) {
            const item = try self.parseValue(alloc);
            try items.append(alloc, item);

            try self.skipArrayWhitespace();

            if (self.current.tag == .comma) {
                self.current = try self.nextToken();
                try self.skipArrayWhitespace();
            } else if (self.current.tag != .right_bracket and self.current.tag != .double_bracket_close) {
                self.parse_error = err.makeError(.UnexpectedToken, self.current.pos, "expected ',' or ']'");
                return error.ParseFailed;
            }
        }

        // Handle ]] (double_bracket_close) - consume only one ]
        if (self.current.tag == .double_bracket_close) {
            // Leave one ] for the outer context by converting to right_bracket
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

        return Value{ .array = .{ .items = items, .is_static = true } };
    }

    fn parseNestedArrayFromDoubleBracket(self: *Parser, alloc: Allocator) ParseValueError!Value {
        // We saw [[ which the lexer tokenized as double_bracket_open
        // In value context, this is a nested array: [ [ ... ] ... ]
        // We treat the [[ as the start of outer array + start of inner array
        try self.enterDepth();
        defer self.exitDepth();

        self.current = try self.nextToken(); // consume [[

        var outer_items: std.ArrayList(*Value) = try .initCapacity(alloc, 16);

        // Parse the inner array (we're already "inside" it after consuming [[)
        const inner_array = try alloc.create(Value);
        inner_array.* = try self.parseArrayContents(alloc);
        try outer_items.append(alloc, inner_array);

        // Now continue parsing the outer array (same logic as parseArray after first item)
        try self.skipArrayWhitespace();

        while (true) {
            if (self.current.tag == .comma) {
                self.current = try self.nextToken();
                try self.skipArrayWhitespace();
                // Check for trailing comma
                if (self.current.tag == .right_bracket or self.current.tag == .double_bracket_close) break;
            } else if (self.current.tag == .right_bracket or self.current.tag == .double_bracket_close) {
                break;
            } else {
                self.parse_error = err.makeError(.UnexpectedToken, self.current.pos, "expected ',' or ']'");
                return error.ParseFailed;
            }

            const item = try self.parseValue(alloc);
            try outer_items.append(alloc, item);
            try self.skipArrayWhitespace();
        }

        // Handle ]] (double_bracket_close) - consume only one ]
        if (self.current.tag == .double_bracket_close) {
            // Leave one ] for any outer context by converting to right_bracket
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

        return Value{ .array = .{ .items = outer_items, .is_static = true } };
    }

    fn parseArrayContents(self: *Parser, alloc: Allocator) ParseValueError!Value {
        // Defense-in-depth: guard here too because this function can be
        // reached from parseNestedArrayFromDoubleBracket's inner call.
        try self.enterDepth();
        defer self.exitDepth();

        // Parse array contents after the opening [ has been consumed.
        var items: std.ArrayList(*Value) = try .initCapacity(alloc, 16);

        try self.skipArrayWhitespace();

        while (self.current.tag != .right_bracket and self.current.tag != .double_bracket_close and self.current.tag != .eof) {
            const item = try self.parseValue(alloc);
            try items.append(alloc, item);

            try self.skipArrayWhitespace();

            if (self.current.tag == .comma) {
                self.current = try self.nextToken();
                try self.skipArrayWhitespace();
            } else if (self.current.tag != .right_bracket and self.current.tag != .double_bracket_close) {
                self.parse_error = err.makeError(.UnexpectedToken, self.current.pos, "expected ',' or ']'");
                return error.ParseFailed;
            }
        }

        // Handle ]] (double_bracket_close) - consume only one ]
        if (self.current.tag == .double_bracket_close) {
            // Leave one ] for the outer array by converting to right_bracket
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

        return Value{ .array = .{ .items = items, .is_static = true } };
    }

    fn parseInlineTable(self: *Parser, alloc: Allocator) ParseValueError!Value {
        // Defense-in-depth: inline tables are a recursive construct too.
        try self.enterDepth();
        defer self.exitDepth();

        const start_pos = self.current.pos;
        self.current = try self.nextToken(); // consume {

        // Typical inline tables have a handful of entries; 16 avoids the
        // initial reallocation ladder for essentially every real-world case.
        var entries: std.ArrayList(TableEntry) = try .initCapacity(alloc, 16);

        while (self.current.tag != .right_brace and self.current.tag != .eof) {
            // Check for newlines in v1.0 mode
            if (self.current.tag == .newline) {
                if (self.options.version == .v1_0_0) {
                    self.parse_error = err.makeError(.InlineTableNewlineNotAllowed, self.current.pos, "newlines not allowed in inline tables in TOML v1.0");
                    return error.ParseFailed;
                }
                self.current = try self.nextToken();
                continue;
            }

            if (self.current.tag == .comment) {
                self.current = try self.nextToken();
                continue;
            }

            // Parse key = value
            var path: std.ArrayList([]const u8) = try .initCapacity(alloc, 8);
            try self.parseKeyPath(alloc, &path);

            if (self.current.tag != .equals) {
                self.parse_error = err.makeError(.UnexpectedToken, self.current.pos, "expected '='");
                return error.ParseFailed;
            }
            self.current = try self.nextToken();

            const value = try self.parseValue(alloc);

            // Handle dotted keys in inline table
            if (path.items.len > 1) {
                // Create nested tables starting from the second key
                // For "a.b = 1", path is ["a", "b"], we want a -> {b -> 1}
                var current_table = try val.createTable(alloc);
                current_table.table.is_inline = true;
                var target = current_table;

                // Start from index 1, not 0 - the first key becomes the root key
                for (path.items[1 .. path.items.len - 1]) |key| {
                    const nested = try val.createTable(alloc);
                    nested.table.is_inline = true;
                    try val.tableSet(alloc, target, key, nested);
                    target = nested;
                }

                try val.tableSet(alloc, target, path.items[path.items.len - 1], value);

                // Merge or add the root key
                const root_key = path.items[0];
                var found = false;
                for (entries.items) |*entry| {
                    if (std.mem.eql(u8, entry.key, root_key)) {
                        // Cannot extend an inline table that was defined with { ... } syntax
                        if (entry.value.* == .table and entry.value.table.is_closed_inline) {
                            self.parse_error = err.makeError(.TableRedefined, self.current.pos, "cannot extend inline table with dotted key");
                            return error.ParseFailed;
                        }
                        // Merge tables - fails if either side is not a table
                        mergeTables(alloc, entry.value, current_table) catch {
                            self.parse_error = err.makeError(.DuplicateKey, self.current.pos, "cannot overwrite key with dotted key");
                            return error.ParseFailed;
                        };
                        found = true;
                        break;
                    }
                }
                if (!found) {
                    try entries.append(alloc, .{ .key = try alloc.dupe(u8, root_key), .value = current_table });
                }
            } else {
                // Check for duplicate key
                for (entries.items) |entry| {
                    if (std.mem.eql(u8, entry.key, path.items[0])) {
                        self.parse_error = err.makeError(.DuplicateKey, self.current.pos, "duplicate key in inline table");
                        return error.ParseFailed;
                    }
                }
                try entries.append(alloc, .{ .key = try alloc.dupe(u8, path.items[0]), .value = value });
            }

            // Skip whitespace/newlines
            while (self.current.tag == .newline or self.current.tag == .comment) {
                if (self.options.version == .v1_0_0 and self.current.tag == .newline) {
                    self.parse_error = err.makeError(.InlineTableNewlineNotAllowed, self.current.pos, "newlines not allowed in inline tables in TOML v1.0");
                    return error.ParseFailed;
                }
                self.current = try self.nextToken();
            }

            if (self.current.tag == .comma) {
                self.current = try self.nextToken();

                // Skip whitespace/newlines after comma
                while (self.current.tag == .newline or self.current.tag == .comment) {
                    if (self.options.version == .v1_0_0 and self.current.tag == .newline) {
                        self.parse_error = err.makeError(.InlineTableNewlineNotAllowed, self.current.pos, "newlines not allowed in inline tables in TOML v1.0");
                        return error.ParseFailed;
                    }
                    self.current = try self.nextToken();
                }

                // Check for trailing comma in v1.0
                if (self.current.tag == .right_brace and self.options.version == .v1_0_0) {
                    self.parse_error = err.makeError(.InlineTableTrailingCommaNotAllowed, start_pos, "trailing comma not allowed in inline tables in TOML v1.0");
                    return error.ParseFailed;
                }
            } else if (self.current.tag != .right_brace) {
                // No comma and not closing brace - error
                self.parse_error = err.makeError(.UnexpectedToken, self.current.pos, "expected ',' or '}' in inline table");
                return error.ParseFailed;
            }
        }

        if (self.current.tag != .right_brace) {
            self.parse_error = err.makeError(.UnexpectedToken, self.current.pos, "expected '}'");
            return error.ParseFailed;
        }
        self.current = try self.nextToken();

        // Convert the scratch entries list into the hash-indexed map
        // form. Task 6 in the plan folds the dup-check into the insert
        // and removes this final conversion pass.
        var map: std.StringArrayHashMapUnmanaged(*Value) = .{};
        errdefer map.deinit(alloc);
        try map.ensureTotalCapacity(alloc, @intCast(entries.items.len));
        for (entries.items) |e| {
            map.putAssumeCapacity(e.key, e.value);
        }
        return Value{ .table = .{ .map = map, .is_inline = true, .is_closed_inline = true } };
    }

    fn mergeTables(alloc: Allocator, target: *Value, source: *Value) error{ ParseFailed, OutOfMemory }!void {
        // Both must be tables
        if (target.* != .table or source.* != .table) {
            return error.ParseFailed;
        }

        // Iterate source in insertion order; O(n) with O(1) per probe
        // into target instead of the old O(n*m) nested linear scan.
        var it = val.tableIterator(source);
        while (it.next()) |src_entry| {
            if (target.table.map.get(src_entry.key)) |tgt_value| {
                // Both values must be tables to merge.
                if (tgt_value.* != .table or src_entry.value.* != .table) {
                    return error.ParseFailed;
                }
                try mergeTables(alloc, tgt_value, src_entry.value);
            } else {
                try val.tableSet(alloc, target, src_entry.key, src_entry.value);
            }
        }
    }

    fn skipArrayWhitespace(self: *Parser) !void {
        while (self.current.tag == .newline or self.current.tag == .comment) {
            self.current = try self.nextToken();
        }
    }

    fn skipToNewline(self: *Parser) !void {
        // Skip any comments
        while (self.current.tag == .comment) {
            self.current = try self.nextToken();
        }
        // Must be at newline or EOF after key=value
        if (self.current.tag != .newline and self.current.tag != .eof) {
            self.parse_error = err.makeError(.UnexpectedToken, self.current.pos, "expected newline after key=value");
            return error.ParseFailed;
        }
        if (self.current.tag == .newline) {
            self.current = try self.nextToken();
        }
    }

    fn decodeBasicString(self: *Parser, alloc: Allocator, raw: []const u8) ![]const u8 {
        // Remove quotes
        const content = raw[1 .. raw.len - 1];
        return self.decodeEscapes(alloc, content);
    }

    fn decodeLiteralString(self: *Parser, raw: []const u8) []const u8 {
        _ = self;
        // Remove quotes, no escape processing
        return raw[1 .. raw.len - 1];
    }

    fn decodeMultilineBasicString(self: *Parser, alloc: Allocator, raw: []const u8) ![]const u8 {
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

        return self.decodeMultilineEscapes(alloc, content);
    }

    fn decodeMultilineLiteralString(self: *Parser, raw: []const u8) []const u8 {
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

    fn decodeEscapes(self: *Parser, alloc: Allocator, content: []const u8) ![]const u8 {
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

                try self.decodeEscapeChar(alloc, content, &i, &result);
            } else {
                try result.append(alloc, content[i]);
                i += 1;
            }
        }

        return result.toOwnedSlice(alloc);
    }

    fn decodeMultilineEscapes(self: *Parser, alloc: Allocator, content: []const u8) ![]const u8 {
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
                    try self.decodeEscapeChar(alloc, content, &i, &result);
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

    fn decodeEscapeChar(self: *Parser, alloc: Allocator, content: []const u8, i: *usize, result: *std.ArrayList(u8)) !void {
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

    fn parseInteger(self: *Parser, raw: []const u8) !i64 {
        // Validate integer format
        try self.validateIntegerFormat(raw);

        // Remove underscores
        var clean: [64]u8 = undefined;
        var clean_len: usize = 0;

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

        for (raw[start..]) |c| {
            if (c != '_') {
                if (clean_len >= clean.len) {
                    self.parse_error = err.makeError(.InvalidNumber, self.current.pos, "integer too long");
                    return error.ParseFailed;
                }
                clean[clean_len] = c;
                clean_len += 1;
            }
        }

        if (negative) {
            // For negative numbers, include the minus sign in parsing to handle i64.MIN correctly
            var neg_buf: [65]u8 = undefined;
            neg_buf[0] = '-';
            @memcpy(neg_buf[1 .. clean_len + 1], clean[0..clean_len]);
            const result = std.fmt.parseInt(i64, neg_buf[0 .. clean_len + 1], base) catch {
                self.parse_error = err.makeError(.InvalidNumber, self.current.pos, "invalid integer");
                return error.ParseFailed;
            };
            return result;
        } else {
            const result = std.fmt.parseInt(i64, clean[0..clean_len], base) catch {
                self.parse_error = err.makeError(.InvalidNumber, self.current.pos, "invalid integer");
                return error.ParseFailed;
            };
            return result;
        }
    }

    fn validateIntegerFormat(self: *Parser, raw: []const u8) !void {
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

    fn parseFloat(self: *Parser, raw: []const u8) !f64 {
        // Handle special values
        if (std.mem.eql(u8, raw, "inf") or std.mem.eql(u8, raw, "+inf")) return std.math.inf(f64);
        if (std.mem.eql(u8, raw, "-inf")) return -std.math.inf(f64);
        if (std.mem.eql(u8, raw, "nan") or std.mem.eql(u8, raw, "+nan")) return std.math.nan(f64);
        if (std.mem.eql(u8, raw, "-nan")) return -std.math.nan(f64);

        // Validate float format
        try self.validateFloatFormat(raw);

        // Remove underscores
        var clean: [128]u8 = undefined;
        var clean_len: usize = 0;

        for (raw) |c| {
            if (c != '_') {
                if (clean_len >= clean.len) {
                    self.parse_error = err.makeError(.InvalidNumber, self.current.pos, "float too long");
                    return error.ParseFailed;
                }
                clean[clean_len] = c;
                clean_len += 1;
            }
        }

        return std.fmt.parseFloat(f64, clean[0..clean_len]) catch {
            self.parse_error = err.makeError(.InvalidNumber, self.current.pos, "invalid float");
            return error.ParseFailed;
        };
    }

    fn validateFloatFormat(self: *Parser, raw: []const u8) !void {
        if (raw.len == 0) {
            self.parse_error = err.makeError(.InvalidNumber, self.current.pos, "empty float");
            return error.ParseFailed;
        }

        var i: usize = 0;

        // Check for sign
        if (raw[0] == '+' or raw[0] == '-') {
            i = 1;
            if (i >= raw.len) {
                self.parse_error = err.makeError(.InvalidNumber, self.current.pos, "float sign with no digits");
                return error.ParseFailed;
            }
            // Underscore not allowed immediately after sign
            if (raw[i] == '_') {
                self.parse_error = err.makeError(.InvalidNumber, self.current.pos, "underscore not allowed after sign");
                return error.ParseFailed;
            }
        }

        // Check for leading zeros (not allowed except for 0.xxx)
        if (raw.len > i + 1 and raw[i] == '0') {
            const next = raw[i + 1];
            if (next >= '0' and next <= '9') {
                self.parse_error = err.makeError(.InvalidNumber, self.current.pos, "leading zeros not allowed in float");
                return error.ParseFailed;
            }
        }

        // Check for leading decimal point (.5 is invalid, must be 0.5)
        if (raw[i] == '.') {
            self.parse_error = err.makeError(.InvalidNumber, self.current.pos, "leading decimal point not allowed");
            return error.ParseFailed;
        }

        // Find decimal point and exponent positions
        var dot_pos: ?usize = null;
        var exp_pos: ?usize = null;

        for (raw[i..], i..) |c, idx| {
            if (c == '.' and dot_pos == null) {
                dot_pos = idx;
            } else if ((c == 'e' or c == 'E') and exp_pos == null) {
                exp_pos = idx;
            }
        }

        // Check for trailing decimal point (5. is invalid, must be 5.0)
        if (dot_pos) |dp| {
            // Check if decimal point is at end or followed by exponent
            if (dp + 1 >= raw.len or raw[dp + 1] == 'e' or raw[dp + 1] == 'E') {
                self.parse_error = err.makeError(.InvalidNumber, self.current.pos, "trailing decimal point not allowed");
                return error.ParseFailed;
            }
            // Check for underscore before or after decimal point
            if (dp > 0 and raw[dp - 1] == '_') {
                self.parse_error = err.makeError(.InvalidNumber, self.current.pos, "underscore before decimal point not allowed");
                return error.ParseFailed;
            }
            if (dp + 1 < raw.len and raw[dp + 1] == '_') {
                self.parse_error = err.makeError(.InvalidNumber, self.current.pos, "underscore after decimal point not allowed");
                return error.ParseFailed;
            }
        }

        // Validate exponent if present
        if (exp_pos) |ep| {
            // Check for underscore before exponent
            if (ep > 0 and raw[ep - 1] == '_') {
                self.parse_error = err.makeError(.InvalidNumber, self.current.pos, "underscore before exponent not allowed");
                return error.ParseFailed;
            }
            // Check exponent has digits after sign
            var exp_digit_start = ep + 1;
            if (exp_digit_start < raw.len and (raw[exp_digit_start] == '+' or raw[exp_digit_start] == '-')) {
                exp_digit_start += 1;
            }
            // Check for underscore after exponent sign
            if (exp_digit_start < raw.len and raw[exp_digit_start] == '_') {
                self.parse_error = err.makeError(.InvalidNumber, self.current.pos, "underscore not allowed at start of exponent");
                return error.ParseFailed;
            }
        }

        // Check for trailing underscore
        if (raw[raw.len - 1] == '_') {
            self.parse_error = err.makeError(.InvalidNumber, self.current.pos, "trailing underscore not allowed");
            return error.ParseFailed;
        }

        // Check for double underscores
        var prev: u8 = 0;
        for (raw) |c| {
            if (c == '_' and prev == '_') {
                self.parse_error = err.makeError(.InvalidNumber, self.current.pos, "double underscore not allowed");
                return error.ParseFailed;
            }
            prev = c;
        }
    }

    fn parseDateTime(self: *Parser, raw: []const u8) !val.DateTime {
        // Format: YYYY-MM-DDTHH:MM:SS[.frac](Z|[+-]HH:MM)
        var dt = val.DateTime{
            .year = 0,
            .month = 0,
            .day = 0,
            .hour = 0,
            .minute = 0,
            .second = 0,
            .nanosecond = 0,
            .offset_minutes = null,
        };

        var i: usize = 0;

        // Year
        dt.year = std.fmt.parseInt(u16, raw[i .. i + 4], 10) catch {
            self.parse_error = err.makeError(.InvalidDateTime, self.current.pos, "invalid year");
            return error.ParseFailed;
        };
        i += 5; // skip YYYY-

        // Month
        dt.month = std.fmt.parseInt(u8, raw[i .. i + 2], 10) catch {
            self.parse_error = err.makeError(.InvalidDateTime, self.current.pos, "invalid month");
            return error.ParseFailed;
        };
        i += 3; // skip MM-

        // Day
        dt.day = std.fmt.parseInt(u8, raw[i .. i + 2], 10) catch {
            self.parse_error = err.makeError(.InvalidDateTime, self.current.pos, "invalid day");
            return error.ParseFailed;
        };
        i += 3; // skip DDT or DD (space)

        // Hour
        dt.hour = std.fmt.parseInt(u8, raw[i .. i + 2], 10) catch {
            self.parse_error = err.makeError(.InvalidDateTime, self.current.pos, "invalid hour");
            return error.ParseFailed;
        };
        i += 3; // skip HH:

        // Minute
        dt.minute = std.fmt.parseInt(u8, raw[i .. i + 2], 10) catch {
            self.parse_error = err.makeError(.InvalidDateTime, self.current.pos, "invalid minute");
            return error.ParseFailed;
        };
        i += 2;

        // Second (may be omitted in v1.1)
        if (i < raw.len and raw[i] == ':') {
            i += 1; // skip :
            dt.second = std.fmt.parseInt(u8, raw[i .. i + 2], 10) catch {
                self.parse_error = err.makeError(.InvalidDateTime, self.current.pos, "invalid second");
                return error.ParseFailed;
            };
            i += 2;
        } else {
            // Seconds omitted - check version
            if (self.options.version == .v1_0_0) {
                self.parse_error = err.makeError(.LocalTimeSecondsOmittedNotAllowed, self.current.pos, "seconds required in datetime for TOML v1.0");
                return error.ParseFailed;
            }
            dt.second = 0;
        }

        // Fractional seconds
        if (i < raw.len and raw[i] == '.') {
            i += 1;
            const frac_start = i;
            while (i < raw.len and raw[i] >= '0' and raw[i] <= '9') {
                i += 1;
            }
            const frac_str = raw[frac_start..i];
            if (frac_str.len == 0) {
                self.parse_error = err.makeError(.InvalidDateTime, self.current.pos, "invalid fractional seconds");
                return error.ParseFailed;
            }
            var frac: u32 = std.fmt.parseInt(u32, frac_str, 10) catch {
                self.parse_error = err.makeError(.InvalidDateTime, self.current.pos, "invalid fractional seconds");
                return error.ParseFailed;
            };
            // Normalize to nanoseconds
            var digits = frac_str.len;
            while (digits < 9) : (digits += 1) {
                frac *= 10;
            }
            while (digits > 9) : (digits -= 1) {
                frac /= 10;
            }
            dt.nanosecond = frac;
        }

        // Timezone
        if (i < raw.len) {
            if (raw[i] == 'Z' or raw[i] == 'z') {
                dt.offset_minutes = 0;
            } else if (raw[i] == '+' or raw[i] == '-') {
                const sign: i16 = if (raw[i] == '-') -1 else 1;
                i += 1;
                if (i + 5 > raw.len) {
                    self.parse_error = err.makeError(.InvalidDateTime, self.current.pos, "invalid timezone offset");
                    return error.ParseFailed;
                }
                const hours = std.fmt.parseInt(i16, raw[i .. i + 2], 10) catch {
                    self.parse_error = err.makeError(.InvalidDateTime, self.current.pos, "invalid timezone hours");
                    return error.ParseFailed;
                };
                i += 3; // skip HH:
                const mins = std.fmt.parseInt(i16, raw[i .. i + 2], 10) catch {
                    self.parse_error = err.makeError(.InvalidDateTime, self.current.pos, "invalid timezone minutes");
                    return error.ParseFailed;
                };
                // Validate offset
                if (!isValidOffset(hours, mins)) {
                    self.parse_error = err.makeError(.InvalidDateTime, self.current.pos, "invalid timezone offset");
                    return error.ParseFailed;
                }
                dt.offset_minutes = sign * (hours * 60 + mins);
            }
        }

        // Validate date and time
        if (!isValidDate(dt.year, dt.month, dt.day)) {
            self.parse_error = err.makeError(.InvalidDateTime, self.current.pos, "invalid date value");
            return error.ParseFailed;
        }
        if (!isValidTime(dt.hour, dt.minute, dt.second)) {
            self.parse_error = err.makeError(.InvalidDateTime, self.current.pos, "invalid time value");
            return error.ParseFailed;
        }

        return dt;
    }

    fn parseDateTimeLocal(self: *Parser, raw: []const u8) !val.DateTimeLocal {
        var dt = val.DateTimeLocal{
            .year = 0,
            .month = 0,
            .day = 0,
            .hour = 0,
            .minute = 0,
            .second = 0,
            .nanosecond = 0,
        };

        var i: usize = 0;

        dt.year = std.fmt.parseInt(u16, raw[i .. i + 4], 10) catch {
            self.parse_error = err.makeError(.InvalidDateTime, self.current.pos, "invalid year");
            return error.ParseFailed;
        };
        i += 5;

        dt.month = std.fmt.parseInt(u8, raw[i .. i + 2], 10) catch {
            self.parse_error = err.makeError(.InvalidDateTime, self.current.pos, "invalid month");
            return error.ParseFailed;
        };
        i += 3;

        dt.day = std.fmt.parseInt(u8, raw[i .. i + 2], 10) catch {
            self.parse_error = err.makeError(.InvalidDateTime, self.current.pos, "invalid day");
            return error.ParseFailed;
        };
        i += 3;

        dt.hour = std.fmt.parseInt(u8, raw[i .. i + 2], 10) catch {
            self.parse_error = err.makeError(.InvalidDateTime, self.current.pos, "invalid hour");
            return error.ParseFailed;
        };
        i += 3;

        dt.minute = std.fmt.parseInt(u8, raw[i .. i + 2], 10) catch {
            self.parse_error = err.makeError(.InvalidDateTime, self.current.pos, "invalid minute");
            return error.ParseFailed;
        };
        i += 2;

        // Second (may be omitted in v1.1)
        if (i < raw.len and raw[i] == ':') {
            i += 1;
            dt.second = std.fmt.parseInt(u8, raw[i .. i + 2], 10) catch {
                self.parse_error = err.makeError(.InvalidDateTime, self.current.pos, "invalid second");
                return error.ParseFailed;
            };
            i += 2;
        }

        // Fractional seconds
        if (i < raw.len and raw[i] == '.') {
            i += 1;
            const frac_start = i;
            while (i < raw.len and raw[i] >= '0' and raw[i] <= '9') {
                i += 1;
            }
            const frac_str = raw[frac_start..i];
            if (frac_str.len == 0) {
                self.parse_error = err.makeError(.InvalidDateTime, self.current.pos, "invalid fractional seconds");
                return error.ParseFailed;
            }
            var frac: u32 = std.fmt.parseInt(u32, frac_str, 10) catch {
                self.parse_error = err.makeError(.InvalidDateTime, self.current.pos, "invalid fractional seconds");
                return error.ParseFailed;
            };
            var digits = frac_str.len;
            while (digits < 9) : (digits += 1) {
                frac *= 10;
            }
            while (digits > 9) : (digits -= 1) {
                frac /= 10;
            }
            dt.nanosecond = frac;
        }

        // Validate date and time
        if (!isValidDate(dt.year, dt.month, dt.day)) {
            self.parse_error = err.makeError(.InvalidDateTime, self.current.pos, "invalid date value");
            return error.ParseFailed;
        }
        if (!isValidTime(dt.hour, dt.minute, dt.second)) {
            self.parse_error = err.makeError(.InvalidDateTime, self.current.pos, "invalid time value");
            return error.ParseFailed;
        }

        return dt;
    }

    fn parseDateLocal(self: *Parser, raw: []const u8) !val.DateLocal {
        // Validate length: YYYY-MM-DD is exactly 10 characters
        if (raw.len != 10) {
            self.parse_error = err.makeError(.InvalidDateTime, self.current.pos, "invalid date format");
            return error.ParseFailed;
        }

        var dt = val.DateLocal{
            .year = 0,
            .month = 0,
            .day = 0,
        };

        dt.year = std.fmt.parseInt(u16, raw[0..4], 10) catch {
            self.parse_error = err.makeError(.InvalidDateTime, self.current.pos, "invalid year");
            return error.ParseFailed;
        };

        dt.month = std.fmt.parseInt(u8, raw[5..7], 10) catch {
            self.parse_error = err.makeError(.InvalidDateTime, self.current.pos, "invalid month");
            return error.ParseFailed;
        };

        dt.day = std.fmt.parseInt(u8, raw[8..10], 10) catch {
            self.parse_error = err.makeError(.InvalidDateTime, self.current.pos, "invalid day");
            return error.ParseFailed;
        };

        // Validate date
        if (!isValidDate(dt.year, dt.month, dt.day)) {
            self.parse_error = err.makeError(.InvalidDateTime, self.current.pos, "invalid date value");
            return error.ParseFailed;
        }

        return dt;
    }

    fn parseTimeLocal(self: *Parser, raw: []const u8) !val.TimeLocal {
        // Minimum length is 5 for HH:MM
        if (raw.len < 5) {
            self.parse_error = err.makeError(.InvalidDateTime, self.current.pos, "invalid time format");
            return error.ParseFailed;
        }

        var t = val.TimeLocal{
            .hour = 0,
            .minute = 0,
            .second = 0,
            .nanosecond = 0,
        };

        var i: usize = 0;

        t.hour = std.fmt.parseInt(u8, raw[i .. i + 2], 10) catch {
            self.parse_error = err.makeError(.InvalidDateTime, self.current.pos, "invalid hour");
            return error.ParseFailed;
        };
        i += 3;

        t.minute = std.fmt.parseInt(u8, raw[i .. i + 2], 10) catch {
            self.parse_error = err.makeError(.InvalidDateTime, self.current.pos, "invalid minute");
            return error.ParseFailed;
        };
        i += 2;

        // Second (may be omitted in v1.1)
        if (i < raw.len and raw[i] == ':') {
            i += 1;
            // Need at least 2 more characters for seconds
            if (i + 2 > raw.len) {
                self.parse_error = err.makeError(.InvalidDateTime, self.current.pos, "invalid time format");
                return error.ParseFailed;
            }
            t.second = std.fmt.parseInt(u8, raw[i .. i + 2], 10) catch {
                self.parse_error = err.makeError(.InvalidDateTime, self.current.pos, "invalid second");
                return error.ParseFailed;
            };
            i += 2;
        } else {
            // Seconds omitted - check version
            if (self.options.version == .v1_0_0) {
                self.parse_error = err.makeError(.LocalTimeSecondsOmittedNotAllowed, self.current.pos, "seconds required in local time for TOML v1.0");
                return error.ParseFailed;
            }
            // v1.1 allows omission, default to :00
            t.second = 0;
        }

        // Fractional seconds
        if (i < raw.len and raw[i] == '.') {
            i += 1;
            const frac_start = i;
            while (i < raw.len and raw[i] >= '0' and raw[i] <= '9') {
                i += 1;
            }
            const frac_str = raw[frac_start..i];
            if (frac_str.len == 0) {
                self.parse_error = err.makeError(.InvalidDateTime, self.current.pos, "invalid fractional seconds");
                return error.ParseFailed;
            }
            var frac: u32 = std.fmt.parseInt(u32, frac_str, 10) catch {
                self.parse_error = err.makeError(.InvalidDateTime, self.current.pos, "invalid fractional seconds");
                return error.ParseFailed;
            };
            var digits = frac_str.len;
            while (digits < 9) : (digits += 1) {
                frac *= 10;
            }
            while (digits > 9) : (digits -= 1) {
                frac /= 10;
            }
            t.nanosecond = frac;
        }

        // Validate time
        if (!isValidTime(t.hour, t.minute, t.second)) {
            self.parse_error = err.makeError(.InvalidDateTime, self.current.pos, "invalid time value");
            return error.ParseFailed;
        }

        return t;
    }

    fn isLeapYear(year: u16) bool {
        return (year % 4 == 0 and year % 100 != 0) or (year % 400 == 0);
    }

    fn daysInMonth(year: u16, month: u8) u8 {
        const days = [_]u8{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
        if (month < 1 or month > 12) return 0;
        if (month == 2 and isLeapYear(year)) return 29;
        return days[month - 1];
    }

    fn isValidDate(year: u16, month: u8, day: u8) bool {
        if (month < 1 or month > 12) return false;
        if (day < 1) return false;
        return day <= daysInMonth(year, month);
    }

    fn isValidTime(hour: u8, minute: u8, second: u8) bool {
        return hour <= 23 and minute <= 59 and second <= 59;
    }

    fn isValidOffset(offset_hour: i16, offset_minute: i16) bool {
        // Offset hours -23 to +23, minutes 0-59
        const abs_hour = if (offset_hour < 0) -offset_hour else offset_hour;
        return abs_hour <= 23 and offset_minute >= 0 and offset_minute <= 59;
    }

    fn nextToken(self: *Parser) !Token {
        if (self.peeked) |tok| {
            self.peeked = null;
            return tok;
        }
        const tok = self.lexer.next() catch {
            if (self.lexer.parse_error) |pe| {
                self.parse_error = pe;
            }
            return error.ParseFailed;
        };
        return tok;
    }

    fn peekToken(self: *Parser) !Token {
        if (self.peeked) |tok| {
            return tok;
        }
        self.peeked = try self.nextToken();
        return self.peeked.?;
    }
};
