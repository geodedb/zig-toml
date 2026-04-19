// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros

//! GAP-0022: external consumer-perspective coverage for the v1.2.0
//! mutable/typed/iterator/path-setter API. Internal U-V tests in
//! `src/value.zig` exercise these surfaces through their own file, but
//! they can't catch a regression that removes or renames the public
//! root re-exports in `src/toml.zig`. These tests import the `toml`
//! module the way a downstream user does -- through `@import("toml")`
//! -- and therefore fail to compile if any v1.2.0 symbol drops off the
//! package root.

const std = @import("std");
const toml = @import("toml");

test "typed accessors via toml.Value methods" {
    var doc = try toml.parse(std.testing.allocator,
        \\i = 42
        \\f = 3.14
        \\b = true
        \\s = "hello"
    , .{});
    defer doc.deinit();

    try std.testing.expectEqual(@as(?i64, 42), doc.root.get("i").?.asI64());
    try std.testing.expectEqual(@as(?f64, 3.14), doc.root.get("f").?.asF64());
    try std.testing.expectEqual(@as(?bool, true), doc.root.get("b").?.asBool());
    try std.testing.expectEqualStrings("hello", doc.root.get("s").?.asString().?);
    // Wrong-tag accessors return null rather than panicking.
    try std.testing.expect(doc.root.get("i").?.asString() == null);
    try std.testing.expect(doc.root.get("s").?.asI64() == null);
}

test "toml.Table / toml.Array root re-exports resolve to Value.Table / Value.Array" {
    // Compile-time identity check: the v1.2.0 aliases must refer to the
    // exact same types as the long-form paths. If someone accidentally
    // introduces a parallel type this test fails to compile.
    try std.testing.expect(toml.Table == toml.Value.Table);
    try std.testing.expect(toml.Array == toml.Value.Array);
}

test "toml.tableIterator walks a parsed table in insertion order" {
    var doc = try toml.parse(std.testing.allocator,
        \\first = 1
        \\second = 2
        \\third = 3
    , .{});
    defer doc.deinit();

    var it = toml.tableIterator(doc.root);
    var seen: [3][]const u8 = undefined;
    var n: usize = 0;
    while (it.next()) |entry| : (n += 1) {
        seen[n] = entry.key;
    }
    try std.testing.expectEqual(@as(usize, 3), n);
    try std.testing.expectEqualStrings("first", seen[0]);
    try std.testing.expectEqualStrings("second", seen[1]);
    try std.testing.expectEqualStrings("third", seen[2]);
}

test "Document.setPath builds nested tables and the typed accessor reads them back" {
    const doc = try toml.value_mod.createDocument(std.testing.allocator);
    defer doc.deinit();
    const a = doc.allocator();

    const port = try a.create(toml.Value);
    port.* = .{ .integer = 5432 };
    try doc.setPath("db.port", port);

    const via_path = doc.root.getPath(&.{ "db", "port" }).?;
    try std.testing.expectEqual(@as(?i64, 5432), via_path.asI64());
}

test "tableSetOwned + arrayAppendOwned build a table via the public method form" {
    const doc = try toml.value_mod.createDocument(std.testing.allocator);
    defer doc.deinit();
    const a = doc.allocator();

    const hosts = try toml.value_mod.createArray(a);
    for (&[_][]const u8{ "alpha", "beta" }) |h| {
        const v = try a.create(toml.Value);
        v.* = .{ .string = try a.dupe(u8, h) };
        try hosts.arrayAppendOwned(a, v);
    }
    try doc.root.tableSetOwned(a, "hosts", hosts);

    const hosts_v = doc.root.get("hosts").?;
    try std.testing.expect(@constCast(hosts_v).asArray() != null);
    const items = @constCast(hosts_v).asArray().?.items.items;
    try std.testing.expectEqual(@as(usize, 2), items.len);
    try std.testing.expectEqualStrings("alpha", items[0].asString().?);
    try std.testing.expectEqualStrings("beta", items[1].asString().?);
}
