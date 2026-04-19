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
const recovery = @import("parser/recovery.zig");
const Value = val.Value;
const Document = val.Document;
const TableEntry = val.TableEntry;

pub const TomlVersion = lex.TomlVersion;

const events_mod = @import("events.zig");
pub const Event = events_mod.Event;
pub const EventHandler = events_mod.EventHandler;

/// Output sink for the shared recursive-descent walker. `parse` uses
/// `.document` (write into an arena-backed Value tree). `parseEvents`
/// uses `.events` (dispatch Event values to the caller).
///
/// Every sink method takes borrowed slices -- the caller must copy
/// anything it needs past the call. For the document sink the parser
/// already dupes into the arena; for the event sink the user is told
/// in the Event docstring that slices only live for the handleFn call.
const ParseSink = union(enum) {
    document: DocSink,
    events: EventSink,

    const DocSink = struct {
        alloc: Allocator,
        root: *Value,
    };

    const EventSink = struct {
        handler: EventHandler,
    };
};

/// Error-handling behaviour for `parse`/`parseWithError` vs. `parseRecover`.
///
/// - `.strict` (default): abort on the first parse error. Matches the
///   historical behaviour of `parse` / `parseWithError`.
/// - `.recover`: accumulate errors into a `RecoveryResult`, advance past
///   each bad statement at the nearest safe boundary (newline, next
///   `[`/`[[`, matching `}`/`]`), and keep going. Only `parseRecover`
///   consults this field; `parse`/`parseWithError` always behave as
///   `.strict`.
pub const RecoveryMode = enum {
    /// Abort on the first parse error (default).
    strict,
    /// Log each error, skip to the next safe point, and keep going.
    recover,
};

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
    /// Parse strictly (default) or accumulate errors and produce a partial
    /// document. Only consulted by `parseRecover`; strict-mode entrypoints
    /// ignore this field.
    recovery_mode: RecoveryMode = .strict,
    /// Maximum number of errors to log in `recover` mode before giving up
    /// and returning what we have so far. Prevents runaway errors on
    /// pathological inputs. Only consulted when
    /// `recovery_mode == .recover`.
    max_recovery_errors: usize = 100,
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
    /// Output sink. `parse` installs `.document`; `parseEvents` installs
    /// `.events`. The walker dispatches to sink helpers (`sinkEmit*`) at
    /// every construct boundary so both modes share a single walk.
    sink: ParseSink,

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
            // Placeholder; the real value is set at the top of parse()
            // or parseEvents() where the actual sink is known.
            .sink = .{ .document = .{ .alloc = alloc, .root = undefined } },
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

        // Install the document sink for this run.
        self.sink = .{ .document = .{ .alloc = arena_alloc, .root = doc.root } };

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

    pub fn parseTableHeader(self: *Parser, alloc: Allocator, root: *Value, is_array_of_tables: bool) !*Value {
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

        // Render the dotted path as a single slice for the event. The
        // slice lives in `alloc` (document arena for document mode,
        // throwaway arena for events mode) -- either way it outlasts
        // the handleFn call because events are emitted synchronously
        // from within this walk.
        if (self.sink == .events) {
            const rendered = try renderKeyPath(alloc, path.items);
            try self.sinkEmitTableHeader(rendered, is_array_of_tables);
        }

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

    pub fn parseKeyValue(self: *Parser, alloc: Allocator, table: *Value) !void {
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

        // In events mode, announce the key BEFORE descending into a
        // container value so handlers see `key_value` -> `array_start` /
        // `inline_table_start`, matching natural reading order. Scalar
        // values are still announced AFTER parsing (when the decoded
        // Value payload is available).
        const value_is_container = switch (self.current.tag) {
            .left_bracket, .double_bracket_open, .left_brace => true,
            else => false,
        };
        if (self.sink == .events and value_is_container) {
            // Use the final key for the event; for dotted keys this is
            // the leaf segment the container is bound to.
            try self.sinkEmitKeyValueContainer(path.items[path.items.len - 1]);
        }

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

        // Set the final key.
        const final_key = path.items[path.items.len - 1];
        switch (self.sink) {
            .document => {
                if (val.tableContains(target, final_key)) {
                    self.parse_error = err.makeError(.DuplicateKey, key_pos, "duplicate key");
                    return error.ParseFailed;
                }
                try val.tableSet(alloc, target, final_key, value);
            },
            .events => {
                // Events mode: scalar key_value fires AFTER value is
                // decoded. Container key_value has already been emitted
                // ahead of parseValue (see `value_is_container` branch
                // above) so its `[`/`{` start event immediately follows
                // the key in the event stream.
                if (!value_is_container) {
                    try self.sinkEmitKeyValueScalar(final_key, value.*);
                }
            },
        }

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

    /// Errors that can flow out of the value-parsing recursion. Includes
    /// the two intrinsic parser errors plus `anyerror` to accommodate
    /// arbitrary errors returned by a user-supplied `EventHandler` when
    /// the parser runs in events mode (GAP-0017). For the document sink
    /// the set still collapses back to `error{ParseFailed, OutOfMemory}`
    /// because the sink helpers do nothing in document mode.
    const ParseValueError = anyerror;

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

        // For event-mode, announce array start before consuming any items.
        try self.sinkEmitSimple(.array_start);

        // Skip whitespace and newlines
        try self.skipArrayWhitespace();

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
                else => try self.sinkEmitSimple(.{ .array_item = item.* }),
            }

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

        try self.sinkEmitSimple(.array_end);

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

        // Event-mode: announce the outer array start. The inner array's
        // own start/end fires from parseArrayContents below, so the
        // consumer observes `[, [, ..., ], ... , ]`.
        try self.sinkEmitSimple(.array_start);

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
            // Same scalar-vs-container distinction as parseArray.
            switch (item.*) {
                .table, .array => {},
                else => try self.sinkEmitSimple(.{ .array_item = item.* }),
            }
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

        try self.sinkEmitSimple(.array_end);

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
        try self.sinkEmitSimple(.array_start);

        try self.skipArrayWhitespace();

        while (self.current.tag != .right_bracket and self.current.tag != .double_bracket_close and self.current.tag != .eof) {
            const item = try self.parseValue(alloc);
            try items.append(alloc, item.*);
            switch (item.*) {
                .table, .array => {},
                else => try self.sinkEmitSimple(.{ .array_item = item.* }),
            }

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

        try self.sinkEmitSimple(.array_end);

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

        // Event-mode: announce the inline table after the `{` has been
        // consumed (inside parseInlineTableHeader) and before the body
        // keys are parsed so the handler sees `{`, kv:..., kv:..., `}`.
        try self.sinkEmitSimple(.inline_table_start);

        // Capture the first offending token position for v1.0 restriction
        // diagnostics so error carets point at the violating `,` / newline
        // rather than at the opening `{` of the inline table.
        var trailing_comma_pos: ?Position = null;
        var newline_inside_pos: ?Position = null;
        try self.parseInlineTableBody(alloc, &header, &trailing_comma_pos, &newline_inside_pos);
        try self.validateInlineTableV10Restrictions(&header, trailing_comma_pos, newline_inside_pos);

        try self.sinkEmitSimple(.inline_table_end);

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

            // Events mode: pre-announce container key_values so handlers
            // see `kv:key -> container_start`. Scalar key_values fire
            // after the value is decoded, below.
            const body_value_is_container = switch (self.current.tag) {
                .left_bracket, .double_bracket_open, .left_brace => true,
                else => false,
            };
            if (self.sink == .events and body_value_is_container) {
                try self.sinkEmitKeyValueContainer(path.items[path.items.len - 1]);
            }

            const value = try self.parseValue(alloc);

            if (self.sink == .events and !body_value_is_container) {
                try self.sinkEmitKeyValueScalar(path.items[path.items.len - 1], value.*);
            }

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

    /// Join dotted-key path segments into a single `a.b.c` slice. The
    /// returned slice is allocated from `alloc` and is therefore stable
    /// for as long as that allocator survives (document arena for
    /// `parse`, throwaway arena for `parseEvents`). Used to render the
    /// slice carried by `.table_header` / `.array_of_tables_header`.
    fn renderKeyPath(alloc: Allocator, parts: []const []const u8) ![]const u8 {
        if (parts.len == 0) return "";
        var total: usize = 0;
        for (parts) |p| total += p.len;
        total += parts.len - 1; // dots
        var out = try alloc.alloc(u8, total);
        var i: usize = 0;
        for (parts, 0..) |p, idx| {
            if (idx != 0) {
                out[i] = '.';
                i += 1;
            }
            @memcpy(out[i .. i + p.len], p);
            i += p.len;
        }
        return out;
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

    fn sinkEmitTableHeader(self: *Parser, rendered_path: []const u8, is_array_of_tables: bool) !void {
        switch (self.sink) {
            .document => {}, // document sink tracks tables via resolveTablePath
            .events => |es| {
                const ev: Event = if (is_array_of_tables)
                    .{ .array_of_tables_header = rendered_path }
                else
                    .{ .table_header = rendered_path };
                try es.handler.handle(ev);
            },
        }
    }

    fn sinkEmitKeyValueScalar(self: *Parser, rendered_key: []const u8, value: Value) !void {
        switch (self.sink) {
            .document => {}, // document sink writes via val.tableSet in caller
            .events => |es| {
                try es.handler.handle(.{ .key_value = .{ .key = rendered_key, .value = value } });
            },
        }
    }

    fn sinkEmitKeyValueContainer(self: *Parser, rendered_key: []const u8) !void {
        switch (self.sink) {
            .document => {},
            .events => |es| {
                try es.handler.handle(.{ .key_value = .{ .key = rendered_key, .value = null } });
            },
        }
    }

    fn sinkEmitSimple(self: *Parser, event: Event) !void {
        switch (self.sink) {
            .document => {},
            .events => |es| {
                try es.handler.handle(event);
            },
        }
    }

    pub fn nextToken(self: *Parser) !Token {
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

/// Run the parser in event-emitting mode. No Document is returned;
/// instead the handler is invoked for every event in document order.
/// Memory allocated during parsing (temporary key strings, rendered
/// paths, decoded escapes) lives in a throwaway arena that is freed
/// before this function returns. Slices handed to the handler are
/// only valid for the duration of the `handleFn` call.
pub fn parseEvents(
    alloc: Allocator,
    input: []const u8,
    handler: EventHandler,
    options: ParseOptions,
) !void {
    // UTF-8 validation is handled by the lexer on the fly (same as
    // Parser.parse). The byte-length cap can be short-circuited up
    // front to avoid spinning the lexer on oversize inputs.
    if (input.len > options.max_bytes) return error.ParseFailed;

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    var parser = Parser.init(alloc, input, options);
    parser.sink = .{ .events = .{ .handler = handler } };
    parser.current = try parser.nextToken();

    // Use the arena for temporary allocations (key paths, decoded
    // strings, container `Value`s that are discarded after each
    // emission). The same entrypoint used by `parse` walks the input.
    const throwaway_root = try val.createTable(arena_alloc);
    try parser.parseDocument(arena_alloc, throwaway_root);
}

/// Recover-mode entry point. Produces a (possibly partial) `*Document`
/// plus a list of parse errors. Implementation lives in
/// `parser/recovery.zig`; this is a thin re-export so the public shape
/// in `toml.zig` (`parser_mod.parseRecoverDocument`) stays unchanged.
pub const parseRecoverDocument = recovery.parseRecoverDocument;

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
