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
const events_sink = @import("parser/events_sink.zig");
const inline_table = @import("parser/inline_table.zig");
const table_path = @import("parser/table_path.zig");
const array_mod = @import("parser/array.zig");
const Value = val.Value;
const Document = val.Document;
const TableEntry = val.TableEntry;

pub const TomlVersion = lex.TomlVersion;

pub const Event = events_sink.Event;
pub const EventHandler = events_sink.EventHandler;

/// Output sink for the shared recursive-descent walker. Definition is
/// hosted in `parser/events_sink.zig`; re-exported here so `Parser`
/// can embed it by value.
const ParseSink = events_sink.ParseSink;

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
    /// `.events`. The walker dispatches to sink helpers in
    /// `parser/events_sink.zig` (`emit*`) at every construct boundary
    /// so both modes share a single walk.
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

    pub fn bumpKeys(self: *Parser) !void {
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

    pub fn bumpValues(self: *Parser) !void {
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
            const rendered = try events_sink.renderKeyPath(alloc, path.items);
            try events_sink.emitTableHeader(self, rendered, is_array_of_tables);
        }

        // Navigate/create the table path
        return table_path.resolveTablePath(self, alloc, root, path.items, is_array_of_tables, start_pos);
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
            try events_sink.emitKeyValueContainer(self, path.items[path.items.len - 1]);
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
                // P-NEW-4: single getOrPut probe instead of contains+put.
                if (!try val.tableSetIfAbsent(alloc, target, final_key, value)) {
                    self.parse_error = err.makeError(.DuplicateKey, key_pos, "duplicate key");
                    return error.ParseFailed;
                }
            },
            .events => {
                // Events mode: scalar key_value fires AFTER value is
                // decoded. Container key_value has already been emitted
                // ahead of parseValue (see `value_is_container` branch
                // above) so its `[`/`{` start event immediately follows
                // the key in the event stream.
                if (!value_is_container) {
                    try events_sink.emitKeyValueScalar(self, final_key, value.*);
                }
            },
        }

        // Skip to next line
        try self.skipToNewline();
    }

    pub fn parseKeyPath(self: *Parser, alloc: Allocator, path: *std.ArrayList([]const u8)) !void {
        while (true) {
            // Handle float tokens like "1.2" as dotted keys "1"."2"
            if (self.current.tag == .float) {
                const text = self.current.slice(self.input);
                // Check if it contains a dot (not inf/nan)
                if (std.mem.indexOf(u8, text, ".")) |dot_pos| {
                    // Split into parts. Slices are arena-owned (P-5).
                    try path.append(alloc, text[0..dot_pos]);
                    try self.checkKeyPathDepth(path.items.len);
                    var rest = text[dot_pos + 1 ..];
                    // Handle multiple dots (like 1.2.3)
                    while (std.mem.indexOf(u8, rest, ".")) |next_dot| {
                        try path.append(alloc, rest[0..next_dot]);
                        try self.checkKeyPathDepth(path.items.len);
                        rest = rest[next_dot + 1 ..];
                    }
                    try path.append(alloc, rest);
                    try self.checkKeyPathDepth(path.items.len);
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
            try self.checkKeyPathDepth(path.items.len);

            if (self.current.tag == .dot) {
                self.current = try self.nextToken();
            } else {
                break;
            }
        }
    }

    /// APP-02: bound dotted-key path length by max_depth. A path of length L
    /// builds an (L-1)-deep nested-table chain and bounds the recursive
    /// `inline_table.mergeTables` to <= L frames; capping L prevents a
    /// stack-overflow DoS (a `max_depth` bypass, since `max_depth` only
    /// constrained lexical nesting) and the associated unbounded arena
    /// allocation. Default max_depth (128) is far below any stack limit.
    fn checkKeyPathDepth(self: *Parser, len: usize) !void {
        if (len > self.options.max_depth) {
            self.parse_error = err.makeError(.LimitExceeded, self.current.pos, "dotted key path exceeds max nesting depth");
            return error.ParseFailed;
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
    pub const ParseValueError = anyerror;

    /// Increment the recursion depth counter and bail if the configured
    /// max_depth is exceeded. Every recursive descent entrypoint
    /// (parseValue, parseArray, parseInlineTable, parseArrayContents,
    /// parseNestedArrayFromDoubleBracket) MUST call this with a matching
    /// `exitDepth()` in a defer to guarantee resource-exhaustion guards
    /// cannot be bypassed by any alternate call path.
    pub fn enterDepth(self: *Parser) !void {
        self.depth += 1;
        if (self.depth > self.options.max_depth) {
            self.parse_error = err.makeError(.LimitExceeded, self.current.pos, "max nesting depth exceeded");
            return error.ParseFailed;
        }
    }

    pub fn exitDepth(self: *Parser) void {
        self.depth -= 1;
    }

    pub fn parseValue(self: *Parser, alloc: Allocator) ParseValueError!*Value {
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
        return array_mod.parseArray(self, alloc);
    }

    fn parseNestedArrayFromDoubleBracket(self: *Parser, alloc: Allocator) ParseValueError!Value {
        return array_mod.parseNestedArrayFromDoubleBracket(self, alloc);
    }

    fn parseInlineTable(self: *Parser, alloc: Allocator) ParseValueError!Value {
        return inline_table.parseInlineTable(self, alloc);
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

    fn parseInteger(self: *Parser, alloc: Allocator, raw: []const u8) !i64 {
        return number.parseInteger(self, alloc, raw);
    }

    fn parseFloat(self: *Parser, alloc: Allocator, raw: []const u8) !f64 {
        return number.parseFloat(self, alloc, raw);
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
