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
const datetime = @import("parser/datetime.zig");
const number = @import("parser/number.zig");
const string = @import("parser/string.zig");
const Value = val.Value;
const Document = val.Document;
const TableEntry = val.TableEntry;

pub const TomlVersion = lex.TomlVersion;

pub const ParseOptions = struct {
    version: TomlVersion = .v1_1_0,
    max_depth: u16 = 128,
    max_bytes: usize = 16 * 1024 * 1024,
    /// Maximum total number of keys the parser may create across all
    /// tables (top-level + nested + inline). Hard-caps pathological
    /// inputs such as 16 MiB of `k0=0\nk1=0\n...`. Bumps are charged
    /// once per parseKeyValue call.
    max_keys: usize = 100_000,
    /// Maximum total number of `*Value` nodes the parser may allocate.
    /// Covers scalar values, arrays, tables, and array-of-tables nodes.
    /// Bumps are charged at every allocation site.
    max_values: usize = 500_000,
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
    /// Total number of keys created across every table. Incremented
    /// once per parseKeyValue call; checked against options.max_keys.
    keys_allocated: usize,
    /// Total number of `*Value` nodes allocated. Incremented at every
    /// createTable/createArray/alloc.create(Value) call site; checked
    /// against options.max_values.
    values_allocated: usize,

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
            .keys_allocated = 0,
            .values_allocated = 0,
        };
    }

    fn bumpKeys(self: *Parser) !void {
        self.keys_allocated += 1;
        if (self.keys_allocated > self.options.max_keys) {
            self.parse_error = err.makeError(
                .ResourceLimitExceeded,
                self.current.pos,
                "max_keys exceeded",
            );
            return error.ParseFailed;
        }
    }

    fn bumpValues(self: *Parser) !void {
        self.values_allocated += 1;
        if (self.values_allocated > self.options.max_values) {
            self.parse_error = err.makeError(
                .ResourceLimitExceeded,
                self.current.pos,
                "max_values exceeded",
            );
            return error.ParseFailed;
        }
    }

    pub fn parse(self: *Parser) !*Document {
        // UTF-8 validation is now fused into Lexer.advance() so we avoid
        // a full second pass over the input. See src/lexer.zig:advance.

        // Size limit check.
        if (self.input.len > self.options.max_bytes) {
            self.parse_error = err.makeError(.LimitExceeded, .{}, "input exceeds max_bytes limit");
            return error.ParseFailed;
        }

        // S-9: charge the root table creation against max_values.
        try self.bumpValues();
        const doc = try val.createDocument(self.alloc);
        errdefer doc.deinit();

        const arena_alloc = doc.allocator();

        // Arena-own the input (see Task 9 / P-5 commentary).
        const owned_input = try arena_alloc.dupe(u8, self.input);
        self.input = owned_input;
        self.lexer = Lexer.init(owned_input, self.options.version);

        // Prime the parser
        self.current = try self.nextToken();

        // Parse into the Document's root table.
        try self.parseDocument(arena_alloc, doc.root);

        return doc;
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
                        // Create new table and append to array. After
                        // P-10 (by-value Array storage) the table lives
                        // inside the array's slice; `arrayAppendTable`
                        // returns a pointer to the tail so the parser
                        // can continue populating it.
                        try self.bumpValues();
                        const new_table = try val.createTable(alloc);
                        new_table.table.defined_explicitly = true;
                        return try val.arrayAppendTable(alloc, existing, new_table);
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
                        // Array items are now stored by value (P-10);
                        // take address of the tail to keep `current` as
                        // a mutable pointer into the array's storage.
                        current = &existing.array.items.items[existing.array.items.items.len - 1];
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
                    try self.bumpValues();
                    const arr = try val.createArray(alloc);
                    arr.array.is_static = false;
                    try self.bumpValues();
                    const new_table = try val.createTable(alloc);
                    new_table.table.defined_explicitly = true;
                    new_table.table.is_array_of_tables = true;
                    // By-value Array storage (P-10): the freshly created
                    // table must be reached through its slot inside the
                    // array, not via the original heap pointer.
                    const stored_table = try val.arrayAppendTable(alloc, arr, new_table);
                    try val.tableSet(alloc, current, key, arr);
                    return stored_table;
                } else {
                    // Create implicit table
                    try self.bumpValues();
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

        // S-9: charge the key cap up-front so pathological inputs are
        // rejected before the expensive value parse runs.
        try self.bumpKeys();

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
                try self.bumpValues();
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
                    // Split into parts. Slices are arena-owned (P-5).
                    try path.append(alloc, text[0..dot_pos]);
                    var rest = text[dot_pos + 1 ..];
                    // Handle multiple dots (like 1.2.3)
                    while (std.mem.indexOf(u8, rest, ".")) |next_dot| {
                        try path.append(alloc, rest[0..next_dot]);
                        rest = rest[next_dot + 1 ..];
                    }
                    try path.append(alloc, rest);
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

        try self.bumpValues();
        const result = try alloc.create(Value);

        switch (self.current.tag) {
            .basic_string => {
                result.* = .{ .string = try self.decodeBasicString(alloc, self.current.slice(self.input)) };
                self.current = try self.nextToken();
            },
            .literal_string => {
                // Slice is arena-owned (P-5); no content transformation
                // for literal strings, so no dupe needed.
                result.* = .{ .string = self.decodeLiteralString(self.current.slice(self.input)) };
                self.current = try self.nextToken();
            },
            .ml_basic_string => {
                result.* = .{ .string = try self.decodeMultilineBasicString(alloc, self.current.slice(self.input)) };
                self.current = try self.nextToken();
            },
            .ml_literal_string => {
                result.* = .{ .string = self.decodeMultilineLiteralString(self.current.slice(self.input)) };
                self.current = try self.nextToken();
            },
            .integer => {
                result.* = .{ .integer = try self.parseInteger(alloc, self.current.slice(self.input)) };
                self.current = try self.nextToken();
            },
            .float => {
                result.* = .{ .float = try self.parseFloat(alloc, self.current.slice(self.input)) };
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
        // After P-10, items are Value (not *Value) so the parser's
        // per-element `create(Value)` allocation in parseValue is the
        // only heap touch per element; elements live contiguously here.
        var items: std.ArrayListUnmanaged(Value) = .empty;
        try items.ensureTotalCapacity(alloc, 16);

        // Skip whitespace and newlines
        try self.skipArrayWhitespace();

        while (self.current.tag != .right_bracket and self.current.tag != .double_bracket_close and self.current.tag != .eof) {
            const item = try self.parseValue(alloc);
            try items.append(alloc, item.*);

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

        // Items stored by value (P-10): append the inner array Value
        // directly, without the extra per-element `create(Value)` that
        // was only needed when the slot type was *Value.
        var outer_items: std.ArrayListUnmanaged(Value) = .empty;
        try outer_items.ensureTotalCapacity(alloc, 16);

        // Parse the inner array (we're already "inside" it after consuming [[)
        try self.bumpValues();
        try outer_items.append(alloc, try self.parseArrayContents(alloc));

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
            try outer_items.append(alloc, item.*);
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
        // By-value element storage (P-10): collect Value directly.
        var items: std.ArrayListUnmanaged(Value) = .empty;
        try items.ensureTotalCapacity(alloc, 16);

        try self.skipArrayWhitespace();

        while (self.current.tag != .right_bracket and self.current.tag != .double_bracket_close and self.current.tag != .eof) {
            const item = try self.parseValue(alloc);
            try items.append(alloc, item.*);

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

    /// Scratch state carried from `parseInlineTableHeader` through
    /// `parseInlineTableBody` into `validateInlineTableV10Restrictions`.
    const InlineTableHeader = struct {
        /// Position of the opening `{` — used for trailing-comma errors.
        open_pos: Position,
        /// The entry map under construction. The caller-owned `map` is
        /// wrapped into a `Value.table` by `parseInlineTable` once the
        /// body completes.
        map: std.StringArrayHashMapUnmanaged(*Value),
    };

    fn parseInlineTable(self: *Parser, alloc: Allocator) ParseValueError!Value {
        // Defense-in-depth: inline tables are a recursive construct too.
        try self.enterDepth();
        defer self.exitDepth();

        var header = try self.parseInlineTableHeader(alloc);
        errdefer header.map.deinit(alloc);

        // Capture the first offending token position for v1.0 restriction
        // diagnostics so error carets point at the violating `,` / newline
        // rather than at the opening `{` of the inline table.
        var trailing_comma_pos: ?Position = null;
        var newline_inside_pos: ?Position = null;
        try self.parseInlineTableBody(alloc, &header, &trailing_comma_pos, &newline_inside_pos);
        try self.validateInlineTableV10Restrictions(&header, trailing_comma_pos, newline_inside_pos);

        return Value{ .table = .{ .map = header.map, .is_inline = true, .is_closed_inline = true } };
    }

    fn parseInlineTableHeader(self: *Parser, alloc: Allocator) ParseValueError!InlineTableHeader {
        const open_pos = self.current.pos;
        self.current = try self.nextToken(); // consume {

        // Typical inline tables have a handful of entries; 16 avoids the
        // initial reallocation ladder for essentially every real-world case.
        var map: std.StringArrayHashMapUnmanaged(*Value) = .{};
        errdefer map.deinit(alloc);
        try map.ensureTotalCapacity(alloc, 16);

        return .{ .open_pos = open_pos, .map = map };
    }

    fn parseInlineTableBody(
        self: *Parser,
        alloc: Allocator,
        header: *InlineTableHeader,
        trailing_comma_pos: *?Position,
        newline_inside_pos: *?Position,
    ) ParseValueError!void {
        while (self.current.tag != .right_brace and self.current.tag != .eof) {
            // Track newlines inside the body; v1.0 validation happens later.
            if (self.current.tag == .newline) {
                if (newline_inside_pos.* == null) newline_inside_pos.* = self.current.pos;
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
                try self.bumpValues();
                var current_table = try val.createTable(alloc);
                current_table.table.is_inline = true;
                var target = current_table;

                // Start from index 1, not 0 - the first key becomes the root key
                for (path.items[1 .. path.items.len - 1]) |key| {
                    try self.bumpValues();
                    const nested = try val.createTable(alloc);
                    nested.table.is_inline = true;
                    try val.tableSet(alloc, target, key, nested);
                    target = nested;
                }

                try val.tableSet(alloc, target, path.items[path.items.len - 1], value);

                // Merge or add the root key. O(1) probe.
                const root_key = path.items[0];
                if (header.map.get(root_key)) |existing_value| {
                    // Cannot extend an inline table that was defined with { ... } syntax
                    if (existing_value.* == .table and existing_value.table.is_closed_inline) {
                        self.parse_error = err.makeError(.TableRedefined, self.current.pos, "cannot extend inline table with dotted key");
                        return error.ParseFailed;
                    }
                    // Merge tables - fails if either side is not a table
                    mergeTables(alloc, existing_value, current_table) catch {
                        self.parse_error = err.makeError(.DuplicateKey, self.current.pos, "cannot overwrite key with dotted key");
                        return error.ParseFailed;
                    };
                } else {
                    // root_key is arena-owned (P-5); no dupe.
                    try header.map.put(alloc, root_key, current_table);
                }
            } else {
                // Check for duplicate key. O(1).
                if (header.map.contains(path.items[0])) {
                    self.parse_error = err.makeError(.DuplicateKey, self.current.pos, "duplicate key in inline table");
                    return error.ParseFailed;
                }
                try header.map.put(alloc, path.items[0], value);
            }

            // Skip whitespace/newlines (tracking, not rejecting).
            while (self.current.tag == .newline or self.current.tag == .comment) {
                if (self.current.tag == .newline and newline_inside_pos.* == null) {
                    newline_inside_pos.* = self.current.pos;
                }
                self.current = try self.nextToken();
            }

            if (self.current.tag == .comma) {
                // Capture comma position before consuming in case this
                // turns out to be a trailing comma.
                const comma_pos = self.current.pos;
                self.current = try self.nextToken();

                // Skip whitespace/newlines after comma.
                while (self.current.tag == .newline or self.current.tag == .comment) {
                    if (self.current.tag == .newline and newline_inside_pos.* == null) {
                        newline_inside_pos.* = self.current.pos;
                    }
                    self.current = try self.nextToken();
                }

                // Trailing comma: flag for post-body validation.
                if (self.current.tag == .right_brace and trailing_comma_pos.* == null) {
                    trailing_comma_pos.* = comma_pos;
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
    }

    fn validateInlineTableV10Restrictions(
        self: *Parser,
        header: *const InlineTableHeader,
        trailing_comma_pos: ?Position,
        newline_inside_pos: ?Position,
    ) ParseValueError!void {
        _ = header; // preserved in signature; may be reused for future diagnostics.
        if (self.options.version != .v1_0_0) return;
        if (trailing_comma_pos) |pos| {
            self.parse_error = err.makeError(
                .InlineTableTrailingCommaNotAllowed,
                pos,
                "trailing comma not allowed in inline tables in TOML v1.0",
            );
            return error.ParseFailed;
        }
        if (newline_inside_pos) |pos| {
            self.parse_error = err.makeError(
                .InlineTableNewlineNotAllowed,
                pos,
                "newlines not allowed in inline tables in TOML v1.0",
            );
            return error.ParseFailed;
        }
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
        return string.decodeBasicString(self, alloc, raw);
    }

    fn decodeLiteralString(self: *Parser, raw: []const u8) []const u8 {
        return string.decodeLiteralString(self, raw);
    }

    fn decodeMultilineBasicString(self: *Parser, alloc: Allocator, raw: []const u8) ![]const u8 {
        return string.decodeMultilineBasicString(self, alloc, raw);
    }

    fn decodeMultilineLiteralString(self: *Parser, raw: []const u8) []const u8 {
        return string.decodeMultilineLiteralString(self, raw);
    }

    fn decodeEscapes(self: *Parser, alloc: Allocator, content: []const u8) ![]const u8 {
        return string.decodeEscapes(self, alloc, content);
    }

    fn decodeEscapeChar(
        self: *Parser,
        alloc: Allocator,
        content: []const u8,
        i: *usize,
        result: *std.ArrayList(u8),
    ) !void {
        return string.decodeEscapeChar(self, alloc, content, i, result);
    }

    fn parseInteger(self: *Parser, alloc: Allocator, raw: []const u8) !i64 {
        return number.parseInteger(self, alloc, raw);
    }

    fn validateIntegerFormat(self: *Parser, raw: []const u8) !void {
        return number.validateIntegerFormat(self, raw);
    }

    fn parseFloat(self: *Parser, alloc: Allocator, raw: []const u8) !f64 {
        return number.parseFloat(self, alloc, raw);
    }

    fn validateFloatFormat(self: *Parser, raw: []const u8) !void {
        return number.validateFloatFormat(self, raw);
    }

    fn parseDateTime(self: *Parser, raw: []const u8) !val.DateTime {
        return datetime.parseDateTime(self, raw);
    }

    fn parseDateTimeLocal(self: *Parser, raw: []const u8) !val.DateTimeLocal {
        return datetime.parseDateTimeLocal(self, raw);
    }

    fn parseDateLocal(self: *Parser, raw: []const u8) !val.DateLocal {
        return datetime.parseDateLocal(self, raw);
    }

    fn parseTimeLocal(self: *Parser, raw: []const u8) !val.TimeLocal {
        return datetime.parseTimeLocal(self, raw);
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

test "S-9 ParseOptions exposes max_keys and max_values caps" {
    const opts = ParseOptions{
        .max_keys = 42,
        .max_values = 84,
    };
    try std.testing.expectEqual(@as(usize, 42), opts.max_keys);
    try std.testing.expectEqual(@as(usize, 84), opts.max_values);
    // Defaults: confirm sensible ceilings exist.
    const def = ParseOptions{};
    try std.testing.expect(def.max_keys >= 100_000);
    try std.testing.expect(def.max_values >= 500_000);
}
