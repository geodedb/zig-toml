// SPDX-License-Identifier: MIT
// Copyright (c) 2024 DevNW

//! Acceptance tests for zigtoml.
//! These tests verify the exact behavior specified in the requirements.

const std = @import("std");
const toml = @import("toml");

// Test 1: Tagged JSON minimal
test "tagged JSON minimal" {
    const input = "a = 42\n";
    const doc = try toml.parse(std.testing.allocator, input, .{});
    defer doc.deinit();

    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();

    try toml.writeTaggedJson(doc, &aw.writer);

    const expected = "{\"a\":{\"type\":\"integer\",\"value\":\"42\"}}\n";
    try std.testing.expectEqualStrings(expected, aw.written());
}

// Test 2: Duplicate key
test "duplicate key" {
    const input =
        \\a=1
        \\a=2
    ;

    const result = toml.parseWithError(std.testing.allocator, input, .{});
    switch (result) {
        .ok => |doc| {
            doc.deinit();
            try std.testing.expect(false); // Should have failed
        },
        .err => |e| {
            try std.testing.expectEqual(toml.ErrorCode.DuplicateKey, e.code);
            try std.testing.expectEqual(@as(u32, 2), e.line);
            try std.testing.expectEqual(@as(u32, 1), e.column);
        },
    }
}

// Test 3: v1.1 inline table allows trailing comma + newlines
test "v1.1 inline table allows trailing comma and newlines" {
    const input =
        \\t = { a = 1,
        \\      b = 2, }
    ;

    const doc = try toml.parse(std.testing.allocator, input, .{ .version = .v1_1_0 });
    defer doc.deinit();

    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();

    try toml.writeTaggedJson(doc, &aw.writer);

    // Keys must be sorted: a then b
    const expected = "{\"t\":{\"a\":{\"type\":\"integer\",\"value\":\"1\"},\"b\":{\"type\":\"integer\",\"value\":\"2\"}}}\n";
    try std.testing.expectEqualStrings(expected, aw.written());
}

// Test 4: v1.0 inline table rejects newlines/trailing comma
test "v1.0 inline table rejects newlines or trailing comma" {
    const input =
        \\t = { a = 1,
        \\      b = 2, }
    ;

    const result = toml.parseWithError(std.testing.allocator, input, .{ .version = .v1_0_0 });
    switch (result) {
        .ok => |doc| {
            doc.deinit();
            try std.testing.expect(false); // Should have failed
        },
        .err => |e| {
            // Must be one of the inline table restriction errors
            const valid_code = (e.code == .InlineTableNewlineNotAllowed or
                e.code == .InlineTableTrailingCommaNotAllowed);
            try std.testing.expect(valid_code);
            try std.testing.expect(e.line >= 1);
            try std.testing.expect(e.column > 0);
        },
    }
}

// Test 5: v1.1 local time seconds omission
test "v1.1 local time seconds omission" {
    const input = "lt = 07:32\n";

    const doc = try toml.parse(std.testing.allocator, input, .{ .version = .v1_1_0 });
    defer doc.deinit();

    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();

    try toml.writeTaggedJson(doc, &aw.writer);

    const expected = "{\"lt\":{\"type\":\"time-local\",\"value\":\"07:32:00\"}}\n";
    try std.testing.expectEqualStrings(expected, aw.written());
}

// Test 6: v1.0 rejects local time seconds omission
test "v1.0 rejects local time seconds omission" {
    const input = "lt = 07:32\n";

    const result = toml.parseWithError(std.testing.allocator, input, .{ .version = .v1_0_0 });
    switch (result) {
        .ok => |doc| {
            doc.deinit();
            try std.testing.expect(false); // Should have failed
        },
        .err => |e| {
            try std.testing.expectEqual(toml.ErrorCode.LocalTimeSecondsOmittedNotAllowed, e.code);
        },
    }
}

// Test 7: Array-of-tables cannot append to statically defined array
test "array-of-tables cannot append to static array" {
    const input =
        \\fruits = []
        \\[[fruits]]
        \\name = "a"
    ;

    const result = toml.parseWithError(std.testing.allocator, input, .{});
    switch (result) {
        .ok => |doc| {
            doc.deinit();
            try std.testing.expect(false); // Should have failed
        },
        .err => |e| {
            try std.testing.expectEqual(toml.ErrorCode.ArrayOfTablesConflict, e.code);
            try std.testing.expectEqual(@as(u32, 2), e.line);
            try std.testing.expectEqual(@as(u32, 1), e.column);
        },
    }
}

// Additional acceptance tests for completeness

test "table redefinition error" {
    const input =
        \\[a]
        \\b = 1
        \\[a]
        \\c = 2
    ;

    const result = toml.parseWithError(std.testing.allocator, input, .{});
    switch (result) {
        .ok => |doc| {
            doc.deinit();
            try std.testing.expect(false);
        },
        .err => |e| {
            try std.testing.expectEqual(toml.ErrorCode.TableRedefined, e.code);
        },
    }
}

test "key redefines non-table" {
    const input =
        \\a = 1
        \\[a.b]
        \\c = 2
    ;

    const result = toml.parseWithError(std.testing.allocator, input, .{});
    switch (result) {
        .ok => |doc| {
            doc.deinit();
            try std.testing.expect(false);
        },
        .err => |e| {
            try std.testing.expectEqual(toml.ErrorCode.KeyRedefinesNonTable, e.code);
        },
    }
}

test "nested array of tables" {
    const input =
        \\[[fruit]]
        \\name = "apple"
        \\
        \\[[fruit.variety]]
        \\name = "red delicious"
        \\
        \\[[fruit.variety]]
        \\name = "granny smith"
        \\
        \\[[fruit]]
        \\name = "banana"
        \\
        \\[[fruit.variety]]
        \\name = "plantain"
    ;

    const doc = try toml.parse(std.testing.allocator, input, .{});
    defer doc.deinit();

    const fruit = doc.root.get("fruit") orelse unreachable;
    try std.testing.expectEqual(@as(usize, 2), fruit.array.items.items.len);

    // First fruit (apple) has 2 varieties
    const apple = fruit.array.items.items[0];
    const apple_name = apple.get("name") orelse unreachable;
    try std.testing.expectEqualStrings("apple", apple_name.string);

    const apple_varieties = apple.get("variety") orelse unreachable;
    try std.testing.expectEqual(@as(usize, 2), apple_varieties.array.items.items.len);

    // Second fruit (banana) has 1 variety
    const banana = fruit.array.items.items[1];
    const banana_name = banana.get("name") orelse unreachable;
    try std.testing.expectEqualStrings("banana", banana_name.string);

    const banana_varieties = banana.get("variety") orelse unreachable;
    try std.testing.expectEqual(@as(usize, 1), banana_varieties.array.items.items.len);
}

test "unicode escapes in strings" {
    const input =
        \\a = "\u0048\u0065\u006C\u006C\u006F"
        \\b = "\U0001F600"
    ;

    const doc = try toml.parse(std.testing.allocator, input, .{});
    defer doc.deinit();

    const a = doc.root.get("a") orelse unreachable;
    try std.testing.expectEqualStrings("Hello", a.string);

    const b = doc.root.get("b") orelse unreachable;
    // U+1F600 is the grinning face emoji
    try std.testing.expectEqualStrings("\xF0\x9F\x98\x80", b.string);
}

test "integer with underscores" {
    const input =
        \\a = 1_000_000
        \\b = 0xDEAD_BEEF
        \\c = 0o7_5_5
        \\d = 0b1010_0101
    ;

    const doc = try toml.parse(std.testing.allocator, input, .{});
    defer doc.deinit();

    const a = doc.root.get("a") orelse unreachable;
    try std.testing.expectEqual(@as(i64, 1_000_000), a.integer);

    const b = doc.root.get("b") orelse unreachable;
    try std.testing.expectEqual(@as(i64, 0xDEADBEEF), b.integer);

    const c = doc.root.get("c") orelse unreachable;
    try std.testing.expectEqual(@as(i64, 0o755), c.integer);

    const d = doc.root.get("d") orelse unreachable;
    try std.testing.expectEqual(@as(i64, 0b10100101), d.integer);
}

test "datetime with offset" {
    const input = "dt = 2024-01-15T10:30:00+05:30\n";

    const doc = try toml.parse(std.testing.allocator, input, .{});
    defer doc.deinit();

    const dt = doc.root.get("dt") orelse unreachable;
    try std.testing.expectEqual(@as(u16, 2024), dt.datetime.year);
    try std.testing.expectEqual(@as(u8, 1), dt.datetime.month);
    try std.testing.expectEqual(@as(u8, 15), dt.datetime.day);
    try std.testing.expectEqual(@as(u8, 10), dt.datetime.hour);
    try std.testing.expectEqual(@as(u8, 30), dt.datetime.minute);
    try std.testing.expectEqual(@as(u8, 0), dt.datetime.second);
    try std.testing.expectEqual(@as(?i16, 330), dt.datetime.offset_minutes); // 5*60 + 30
}

test "local date" {
    const input = "d = 2024-01-15\n";

    const doc = try toml.parse(std.testing.allocator, input, .{});
    defer doc.deinit();

    const d = doc.root.get("d") orelse unreachable;
    try std.testing.expectEqual(@as(u16, 2024), d.date_local.year);
    try std.testing.expectEqual(@as(u8, 1), d.date_local.month);
    try std.testing.expectEqual(@as(u8, 15), d.date_local.day);
}

test "multiline array" {
    const input =
        \\arr = [
        \\  1,
        \\  2,
        \\  3,
        \\]
    ;

    const doc = try toml.parse(std.testing.allocator, input, .{});
    defer doc.deinit();

    const arr = doc.root.get("arr") orelse unreachable;
    try std.testing.expectEqual(@as(usize, 3), arr.array.items.items.len);
}

test "quoted keys" {
    const input =
        \\"key with spaces" = 1
        \\'literal key' = 2
    ;

    const doc = try toml.parse(std.testing.allocator, input, .{});
    defer doc.deinit();

    const a = doc.root.get("key with spaces") orelse unreachable;
    try std.testing.expectEqual(@as(i64, 1), a.integer);

    const b = doc.root.get("literal key") orelse unreachable;
    try std.testing.expectEqual(@as(i64, 2), b.integer);
}

test "empty table" {
    const input =
        \\[empty]
        \\[another]
        \\key = "value"
    ;

    const doc = try toml.parse(std.testing.allocator, input, .{});
    defer doc.deinit();

    const empty = doc.root.get("empty") orelse unreachable;
    try std.testing.expectEqual(@as(usize, 0), toml.value_mod.tableLen(empty));

    const another = doc.root.get("another") orelse unreachable;
    try std.testing.expectEqual(@as(usize, 1), toml.value_mod.tableLen(another));
}

test "max depth limit" {
    // Create deeply nested inline tables to exceed max_depth
    // Each inline table adds one level of nesting
    const input = "x = { a = { b = { c = { d = { e = { f = { g = { h = { i = { j = { k = 1 }}}}}}}}}}}";

    const result = toml.parseWithError(std.testing.allocator, input, .{ .max_depth = 5 });
    switch (result) {
        .ok => |doc| {
            doc.deinit();
            // Depth limit should have triggered
            try std.testing.expect(false);
        },
        .err => |e| {
            try std.testing.expectEqual(toml.ErrorCode.LimitExceeded, e.code);
        },
    }
}

test "comments preserved (ignored)" {
    const input =
        \\# This is a comment
        \\key = "value" # inline comment
        \\# Another comment
    ;

    const doc = try toml.parse(std.testing.allocator, input, .{});
    defer doc.deinit();

    const key = doc.root.get("key") orelse unreachable;
    try std.testing.expectEqualStrings("value", key.string);
}

test "escape sequences" {
    const input =
        \\str = "backslash: \\ quote: \" tab: \t newline: \n"
    ;

    const doc = try toml.parse(std.testing.allocator, input, .{});
    defer doc.deinit();

    const str = doc.root.get("str") orelse unreachable;
    try std.testing.expectEqualStrings("backslash: \\ quote: \" tab: \t newline: \n", str.string);
}

// U-U: Tagged-JSON keys must stay sorted at every level even when a
// table has >256 entries. Previously the emitter fell through to the
// parser's insertion order for large tables, breaking determinism
// (toml-test golden-file comparisons and CI diff noise).
test "tagged JSON sorts 300 keys deterministically" {
    const allocator = std.testing.allocator;
    const N: usize = 300;

    // Build input in shuffled-looking order by using an odd stride that
    // visits every key exactly once and does NOT produce lexicographic
    // order. The sorted output must still emit k000, k001, …, k299.
    var input: std.ArrayList(u8) = .empty;
    defer input.deinit(allocator);

    const stride: usize = 97; // coprime with 300
    var visited: usize = 0;
    var cursor: usize = 0;
    var scratch: [64]u8 = undefined;
    while (visited < N) : (visited += 1) {
        const line = try std.fmt.bufPrint(&scratch, "k{d:0>3} = {d}\n", .{ cursor, cursor });
        try input.appendSlice(allocator, line);
        cursor = (cursor + stride) % N;
    }

    const doc = try toml.parse(allocator, input.items, .{});
    defer doc.deinit();

    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try toml.writeTaggedJson(doc, &aw.writer);
    const out = aw.written();

    // Scan key positions in the emitted JSON and assert they are sorted.
    // Each key appears as the literal `"kNNN"` exactly once.
    var prev_pos: ?usize = null;
    var i: usize = 0;
    while (i < N) : (i += 1) {
        var key_buf: [8]u8 = undefined;
        const key = try std.fmt.bufPrint(&key_buf, "\"k{d:0>3}\"", .{i});
        const found = std.mem.indexOf(u8, out, key) orelse {
            std.debug.print("missing key {s} in output\n", .{key});
            try std.testing.expect(false);
            return;
        };
        if (prev_pos) |p| {
            try std.testing.expect(found > p); // strictly increasing
        }
        prev_pos = found;
    }
}

// S-9: max_keys cap prevents memory amplification on pathological input.
test "S-9 max_keys cap returns ResourceLimitExceeded" {
    const allocator = std.testing.allocator;

    // Build a ~256 KiB input of `k<i>=0\n` pairs. At ~8 bytes per line this
    // produces >30_000 keys, comfortably past the test cap of 100.
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    var i: usize = 0;
    var line_buf: [64]u8 = undefined;
    while (buf.items.len < 256 * 1024) : (i += 1) {
        const line = try std.fmt.bufPrint(&line_buf, "k{d}=0\n", .{i});
        try buf.appendSlice(allocator, line);
    }

    const opts = toml.ParseOptions{
        .max_keys = 100,
        .max_bytes = 16 * 1024 * 1024,
    };

    const result = toml.parseWithError(allocator, buf.items, opts);
    switch (result) {
        .ok => |doc| {
            doc.deinit();
            try std.testing.expect(false); // must have failed
        },
        .err => |e| {
            try std.testing.expectEqual(
                toml.ErrorCode.ResourceLimitExceeded,
                e.code,
            );
        },
    }
}

// S-9: max_values cap catches allocation blow-ups even when key count
// is low (single key, huge array literal).
test "S-9 max_values cap returns ResourceLimitExceeded" {
    const allocator = std.testing.allocator;

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    try buf.appendSlice(allocator, "arr = [");
    var i: usize = 0;
    var num_buf: [32]u8 = undefined;
    while (i < 2000) : (i += 1) {
        if (i > 0) try buf.append(allocator, ',');
        const s = try std.fmt.bufPrint(&num_buf, "{d}", .{i});
        try buf.appendSlice(allocator, s);
    }
    try buf.appendSlice(allocator, "]\n");

    const opts = toml.ParseOptions{
        .max_keys = 10_000,
        .max_values = 100,
        .max_bytes = 16 * 1024 * 1024,
    };

    const result = toml.parseWithError(allocator, buf.items, opts);
    switch (result) {
        .ok => |doc| {
            doc.deinit();
            try std.testing.expect(false);
        },
        .err => |e| {
            try std.testing.expectEqual(
                toml.ErrorCode.ResourceLimitExceeded,
                e.code,
            );
        },
    }
}

// --------------------------------------------------------------------
// GAP-0017: SAX-style event API acceptance tests.
// Lock in per-construct + whole-document event parity so future walker
// edits cannot silently drift the event stream from the document tree.
// --------------------------------------------------------------------

test "parseEvents: table header" {
    const Collector = struct {
        allocator: std.mem.Allocator,
        headers: std.ArrayList([]const u8),
        keys: std.ArrayList([]const u8),

        fn init(a: std.mem.Allocator) @This() {
            return .{ .allocator = a, .headers = .empty, .keys = .empty };
        }
        fn deinit(self: *@This()) void {
            for (self.headers.items) |h| self.allocator.free(h);
            for (self.keys.items) |k| self.allocator.free(k);
            self.headers.deinit(self.allocator);
            self.keys.deinit(self.allocator);
        }
        fn handle(ctx: *anyopaque, ev: toml.Event) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            switch (ev) {
                .table_header => |h| try self.headers.append(self.allocator, try self.allocator.dupe(u8, h)),
                .key_value => |kv| try self.keys.append(self.allocator, try self.allocator.dupe(u8, kv.key)),
                else => {},
            }
        }
    };

    var c = Collector.init(std.testing.allocator);
    defer c.deinit();
    try toml.parseEvents(
        std.testing.allocator,
        "[section]\nkey = \"value\"\n",
        .{ .ctx = &c, .handleFn = Collector.handle },
        .{},
    );

    try std.testing.expectEqual(@as(usize, 1), c.headers.items.len);
    try std.testing.expectEqualStrings("section", c.headers.items[0]);
    try std.testing.expectEqual(@as(usize, 1), c.keys.items.len);
    try std.testing.expectEqualStrings("key", c.keys.items[0]);
}

test "parseEvents: array of tables" {
    const Collector = struct {
        allocator: std.mem.Allocator,
        aot_headers: std.ArrayList([]const u8),

        fn init(a: std.mem.Allocator) @This() {
            return .{ .allocator = a, .aot_headers = .empty };
        }
        fn deinit(self: *@This()) void {
            for (self.aot_headers.items) |h| self.allocator.free(h);
            self.aot_headers.deinit(self.allocator);
        }
        fn handle(ctx: *anyopaque, ev: toml.Event) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            switch (ev) {
                .array_of_tables_header => |h| try self.aot_headers.append(self.allocator, try self.allocator.dupe(u8, h)),
                else => {},
            }
        }
    };

    var c = Collector.init(std.testing.allocator);
    defer c.deinit();
    const input =
        \\[[items]]
        \\name = "x"
        \\
        \\[[items]]
        \\name = "y"
    ;
    try toml.parseEvents(
        std.testing.allocator,
        input,
        .{ .ctx = &c, .handleFn = Collector.handle },
        .{},
    );

    try std.testing.expectEqual(@as(usize, 2), c.aot_headers.items.len);
    try std.testing.expectEqualStrings("items", c.aot_headers.items[0]);
    try std.testing.expectEqualStrings("items", c.aot_headers.items[1]);
}

test "parseEvents: inline table brackets correctly" {
    const Tracker = struct {
        depth: i32 = 0,
        max_depth: i32 = 0,
        starts: usize = 0,
        ends: usize = 0,

        fn handle(ctx: *anyopaque, ev: toml.Event) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            switch (ev) {
                .inline_table_start => {
                    self.starts += 1;
                    self.depth += 1;
                    if (self.depth > self.max_depth) self.max_depth = self.depth;
                },
                .inline_table_end => {
                    self.ends += 1;
                    self.depth -= 1;
                },
                else => {},
            }
        }
    };

    var t: Tracker = .{};
    try toml.parseEvents(
        std.testing.allocator,
        "point = { x = 1, y = 2 }\n",
        .{ .ctx = &t, .handleFn = Tracker.handle },
        .{},
    );
    try std.testing.expectEqual(@as(usize, 1), t.starts);
    try std.testing.expectEqual(@as(usize, 1), t.ends);
    try std.testing.expectEqual(@as(i32, 0), t.depth);
    try std.testing.expectEqual(@as(i32, 1), t.max_depth);
}

test "parseEvents: scalar array emits array_item per element" {
    const Tracker = struct {
        starts: usize = 0,
        ends: usize = 0,
        items: std.ArrayList(i64),

        fn init() @This() {
            return .{ .items = .empty };
        }
        fn deinit(self: *@This(), a: std.mem.Allocator) void {
            self.items.deinit(a);
        }
        fn handle(ctx: *anyopaque, ev: toml.Event) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            switch (ev) {
                .array_start => self.starts += 1,
                .array_end => self.ends += 1,
                .array_item => |v| switch (v) {
                    .integer => |n| try self.items.append(std.testing.allocator, n),
                    else => {},
                },
                else => {},
            }
        }
    };

    var t = Tracker.init();
    defer t.deinit(std.testing.allocator);
    try toml.parseEvents(
        std.testing.allocator,
        "arr = [1, 2, 3]\n",
        .{ .ctx = &t, .handleFn = Tracker.handle },
        .{},
    );
    try std.testing.expectEqual(@as(usize, 1), t.starts);
    try std.testing.expectEqual(@as(usize, 1), t.ends);
    try std.testing.expectEqual(@as(usize, 3), t.items.items.len);
    try std.testing.expectEqual(@as(i64, 1), t.items.items[0]);
    try std.testing.expectEqual(@as(i64, 2), t.items.items[1]);
    try std.testing.expectEqual(@as(i64, 3), t.items.items[2]);
}

test "parseEvents: whole-document event ordering matches document sink" {
    const Recorder = struct {
        allocator: std.mem.Allocator,
        log: std.ArrayList([]const u8),

        fn init(a: std.mem.Allocator) @This() {
            return .{ .allocator = a, .log = .empty };
        }
        fn deinit(self: *@This()) void {
            for (self.log.items) |s| self.allocator.free(s);
            self.log.deinit(self.allocator);
        }
        fn push(self: *@This(), s: []const u8) !void {
            try self.log.append(self.allocator, try self.allocator.dupe(u8, s));
        }
        fn handle(ctx: *anyopaque, ev: toml.Event) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            switch (ev) {
                .table_header => |h| {
                    var buf: [128]u8 = undefined;
                    const s = try std.fmt.bufPrint(&buf, "[{s}]", .{h});
                    try self.push(s);
                },
                .array_of_tables_header => |h| {
                    var buf: [128]u8 = undefined;
                    const s = try std.fmt.bufPrint(&buf, "[[{s}]]", .{h});
                    try self.push(s);
                },
                .key_value => |kv| {
                    var buf: [128]u8 = undefined;
                    const s = try std.fmt.bufPrint(&buf, "kv:{s}", .{kv.key});
                    try self.push(s);
                },
                .inline_table_start => try self.push("{"),
                .inline_table_end => try self.push("}"),
                .array_start => try self.push("["),
                .array_end => try self.push("]"),
                .array_item => try self.push("item"),
            }
        }
    };

    const input =
        \\title = "z"
        \\[srv]
        \\host = "h"
        \\ports = [80, 443]
        \\[[users]]
        \\name = "alice"
        \\[[users]]
        \\name = "bob"
    ;

    var rec = Recorder.init(std.testing.allocator);
    defer rec.deinit();
    try toml.parseEvents(
        std.testing.allocator,
        input,
        .{ .ctx = &rec, .handleFn = Recorder.handle },
        .{},
    );

    const expected = [_][]const u8{
        "kv:title",
        "[srv]",
        "kv:host",
        "kv:ports",
        "[",
        "item",
        "item",
        "]",
        "[[users]]",
        "kv:name",
        "[[users]]",
        "kv:name",
    };
    try std.testing.expectEqual(expected.len, rec.log.items.len);
    for (expected, 0..) |want, i| {
        try std.testing.expectEqualStrings(want, rec.log.items[i]);
    }
}
