// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! Round-trip tests: parse(encode(parse(x))) must yield the same value tree
//! as parse(x). Asserted by re-emitting the tagged JSON and comparing bytes.

const std = @import("std");
const toml = @import("toml");

const corpus = [_][]const u8{
    "a = 42\n",
    "pi = 3.14\n",
    "flag = true\n",
    "s = \"hello\"\n",
    "nums = [1, 2, 3]\n",
    "point = { x = 1, y = 2 }\n",
    "[server]\nhost = \"localhost\"\nport = 8080\n",
    "[a.b.c]\nleaf = 1\n",
    "[[products]]\nname = \"Hammer\"\n\n[[products]]\nname = \"Nail\"\n",
    "dt = 2024-01-15T10:30:00Z\n",
    "dt_local = 2024-01-15T10:30:00\n",
    "d = 2024-01-15\n",
    "t = 10:30:00\n",
    "special_pos = inf\nspecial_neg = -inf\nspecial_nan = nan\n",
    "empty_arr = []\n",
    "empty_table = {}\n",
    "mixed = [1, \"two\", 3.0, true]\n",
    "\"weird key\" = 1\n",
    "nested = { inner = { leaf = 1 } }\n",
    // Additional cases covering more surface area.
    "neg = -42\n",
    "big = 9223372036854775807\n",
    "sci = 6.022e23\n",
    "hex = 0xDEADBEEF\n",
    "escape = \"a\\tb\\nc\"\n",
    "blank_line_before = 1\n\n[section]\nvalue = 2\n",
    "tab = \"a\\tb\"\n",
    "cr = \"a\\rb\"\n",
    "backslash = \"a\\\\b\"\n",
    "quote = \"say \\\"hi\\\"\"\n",
    "offset_plus = 2024-01-15T10:30:00+05:30\n",
    "offset_minus = 2024-01-15T10:30:00-08:00\n",
    "frac_dt = 2024-01-15T10:30:00.123Z\n",
    "frac_time = 10:30:00.500\n",
    "nested_arr = [[1, 2], [3, 4]]\n",
    "arr_of_tbls_inline = [{ a = 1 }, { a = 2 }, { a = 3 }]\n",
    "[[servers]]\nname = \"alpha\"\nport = 8080\n\n[[servers]]\nname = \"beta\"\nport = 8081\n",
    "[a]\nx = 1\n\n[b]\ny = 2\n",
    "[a.b]\nx = 1\n\n[a.c]\ny = 2\n",
    "nested_inline = { a = { b = { c = 1 } } }\n",
    "multi = [true, false, true, false]\n",
    "strings = [\"a\", \"b\", \"c\"]\n",
    "mixed_root = 1\n[section]\nkey = \"val\"\n",
    "floats = [1.0, 2.5, -3.14]\n",
    "signed = [-1, 0, 1]\n",
    "[top.sub]\ndeep = \"value\"\n",
    "[top.sub.leaf]\nv = 1\n",
    "with_nl_in_str = \"line1\\nline2\"\n",
    "empty_str = \"\"\n",
    "unicode_val = \"café \\u00E9\"\n",
    "zeroed = 0\n",
};

fn roundTrip(alloc: std.mem.Allocator, src: []const u8) !void {
    const doc1 = try toml.parse(alloc, src, .{});
    defer doc1.deinit();

    var encoded: std.Io.Writer.Allocating = .init(alloc);
    defer encoded.deinit();
    try toml.encoder.encode(doc1, &encoded.writer, .{});

    const doc2 = toml.parse(alloc, encoded.written(), .{}) catch |e| {
        std.debug.print("re-parse failed for:\n---\n{s}\n---\nencoded:\n---\n{s}\n---\n", .{ src, encoded.written() });
        return e;
    };
    defer doc2.deinit();

    // Compare tagged-JSON projections: if those agree, the value trees agree.
    var json1: std.Io.Writer.Allocating = .init(alloc);
    defer json1.deinit();
    try toml.writeTaggedJson(doc1, &json1.writer);

    var json2: std.Io.Writer.Allocating = .init(alloc);
    defer json2.deinit();
    try toml.writeTaggedJson(doc2, &json2.writer);

    std.testing.expectEqualStrings(json1.written(), json2.written()) catch |e| {
        std.debug.print("round-trip mismatch for:\n---\n{s}\n---\nencoded:\n---\n{s}\n---\n", .{ src, encoded.written() });
        return e;
    };
}

test "round-trip corpus" {
    for (corpus) |src| {
        try roundTrip(std.testing.allocator, src);
    }
}

test "decoder output feeds directly into encoder" {
    // Simulates running TOML -> JSON -> TOML through the two CLIs by
    // calling the library functions in the same process. This is the
    // property toml-test enforces between the two binaries: the encoder
    // must accept whatever tagged-JSON the decoder emits.
    const cli = toml.encoder_cli;

    const original_toml = "[server]\nhost = \"localhost\"\nport = 8080\n";

    // Step A: TOML -> tagged JSON
    const doc = try toml.parse(std.testing.allocator, original_toml, .{});
    defer doc.deinit();

    var tagged_json: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer tagged_json.deinit();
    try toml.writeTaggedJson(doc, &tagged_json.writer);

    // Step B: tagged JSON -> TOML
    var reencoded: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer reencoded.deinit();
    try cli.runEncodePipeline(std.testing.allocator, tagged_json.written(), &reencoded.writer);

    // The re-encoded TOML must parse to the same value tree as the
    // original; compare tagged-JSON projections byte-for-byte.
    const doc2 = try toml.parse(std.testing.allocator, reencoded.written(), .{});
    defer doc2.deinit();
    var tagged2: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer tagged2.deinit();
    try toml.writeTaggedJson(doc2, &tagged2.writer);
    try std.testing.expectEqualStrings(tagged_json.written(), tagged2.written());
}
