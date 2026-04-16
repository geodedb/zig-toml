// SPDX-License-Identifier: MIT
// Copyright (c) 2024 DevNW

//! Acceptance tests for zigtoml.
//! These tests verify the exact behavior specified in the requirements.

const std = @import("std");
const toml = @import("toml");

// Test 1: Tagged JSON minimal
test "tagged JSON minimal" {
    const input = "a = 42\n";
    var doc = try toml.parse(std.testing.allocator, input, .{});
    defer doc.deinit();

    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();

    try toml.writeTaggedJson(&doc, &aw.writer);

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
        .ok => |*doc_const| {
            var doc = @constCast(doc_const);
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

    var doc = try toml.parse(std.testing.allocator, input, .{ .version = .v1_1_0 });
    defer doc.deinit();

    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();

    try toml.writeTaggedJson(&doc, &aw.writer);

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
        .ok => |*doc_const| {
            var doc = @constCast(doc_const);
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

    var doc = try toml.parse(std.testing.allocator, input, .{ .version = .v1_1_0 });
    defer doc.deinit();

    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();

    try toml.writeTaggedJson(&doc, &aw.writer);

    const expected = "{\"lt\":{\"type\":\"time-local\",\"value\":\"07:32:00\"}}\n";
    try std.testing.expectEqualStrings(expected, aw.written());
}

// Test 6: v1.0 rejects local time seconds omission
test "v1.0 rejects local time seconds omission" {
    const input = "lt = 07:32\n";

    const result = toml.parseWithError(std.testing.allocator, input, .{ .version = .v1_0_0 });
    switch (result) {
        .ok => |*doc_const| {
            var doc = @constCast(doc_const);
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
        .ok => |*doc_const| {
            var doc = @constCast(doc_const);
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
        .ok => |*doc_const| {
            var doc = @constCast(doc_const);
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
        .ok => |*doc_const| {
            var doc = @constCast(doc_const);
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

    var doc = try toml.parse(std.testing.allocator, input, .{});
    defer doc.deinit();

    const fruit = doc.root.get("fruit") orelse unreachable;
    try std.testing.expectEqual(@as(usize, 2), fruit.array.items.len);

    // First fruit (apple) has 2 varieties
    const apple = fruit.array.items[0];
    const apple_name = apple.get("name") orelse unreachable;
    try std.testing.expectEqualStrings("apple", apple_name.string);

    const apple_varieties = apple.get("variety") orelse unreachable;
    try std.testing.expectEqual(@as(usize, 2), apple_varieties.array.items.len);

    // Second fruit (banana) has 1 variety
    const banana = fruit.array.items[1];
    const banana_name = banana.get("name") orelse unreachable;
    try std.testing.expectEqualStrings("banana", banana_name.string);

    const banana_varieties = banana.get("variety") orelse unreachable;
    try std.testing.expectEqual(@as(usize, 1), banana_varieties.array.items.len);
}

test "unicode escapes in strings" {
    const input =
        \\a = "\u0048\u0065\u006C\u006C\u006F"
        \\b = "\U0001F600"
    ;

    var doc = try toml.parse(std.testing.allocator, input, .{});
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

    var doc = try toml.parse(std.testing.allocator, input, .{});
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

    var doc = try toml.parse(std.testing.allocator, input, .{});
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

    var doc = try toml.parse(std.testing.allocator, input, .{});
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

    var doc = try toml.parse(std.testing.allocator, input, .{});
    defer doc.deinit();

    const arr = doc.root.get("arr") orelse unreachable;
    try std.testing.expectEqual(@as(usize, 3), arr.array.items.len);
}

test "quoted keys" {
    const input =
        \\"key with spaces" = 1
        \\'literal key' = 2
    ;

    var doc = try toml.parse(std.testing.allocator, input, .{});
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

    var doc = try toml.parse(std.testing.allocator, input, .{});
    defer doc.deinit();

    const empty = doc.root.get("empty") orelse unreachable;
    try std.testing.expectEqual(@as(usize, 0), empty.table.entries.len);

    const another = doc.root.get("another") orelse unreachable;
    try std.testing.expectEqual(@as(usize, 1), another.table.entries.len);
}

test "max depth limit" {
    // Create deeply nested inline tables to exceed max_depth
    // Each inline table adds one level of nesting
    const input = "x = { a = { b = { c = { d = { e = { f = { g = { h = { i = { j = { k = 1 }}}}}}}}}}}";

    const result = toml.parseWithError(std.testing.allocator, input, .{ .max_depth = 5 });
    switch (result) {
        .ok => |*doc_const| {
            var doc = @constCast(doc_const);
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

    var doc = try toml.parse(std.testing.allocator, input, .{});
    defer doc.deinit();

    const key = doc.root.get("key") orelse unreachable;
    try std.testing.expectEqualStrings("value", key.string);
}

test "escape sequences" {
    const input =
        \\str = "backslash: \\ quote: \" tab: \t newline: \n"
    ;

    var doc = try toml.parse(std.testing.allocator, input, .{});
    defer doc.deinit();

    const str = doc.root.get("str") orelse unreachable;
    try std.testing.expectEqualStrings("backslash: \\ quote: \" tab: \t newline: \n", str.string);
}
