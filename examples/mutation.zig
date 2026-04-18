// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! Mutation API Example
//!
//! Build a TOML Document programmatically using the public mutation
//! surface: `Document.setPath`, `Value.tableSetOwned`, and
//! `Value.arrayAppendOwned`. Then read it back with the typed
//! accessors (`asI64`, `asString`) and iterate with `TableIter` /
//! `ArrayIter`.

const std = @import("std");
const toml = @import("toml");

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Build an empty arena-backed document. createDocument wires up
    // the arena pointer so doc.deinit() frees both the arena and the
    // Document struct.
    const doc = try toml.value_mod.createDocument(allocator);
    defer doc.deinit();

    // 1) setPath: write a nested leaf, creating intermediate tables.
    const port = try doc.allocator().create(toml.Value);
    port.* = .{ .integer = 8080 };
    try doc.setPath("server.http.port", port);

    const host = try doc.allocator().create(toml.Value);
    host.* = .{ .string = "0.0.0.0" };
    try doc.setPath("server.http.host", host);

    // 2) arrayAppendOwned: build an array under a new key.
    const tags = try toml.value_mod.createArray(doc.allocator());
    for ([_][]const u8{ "prod", "web", "v2" }) |s| {
        const item = try doc.allocator().create(toml.Value);
        item.* = .{ .string = s };
        try tags.arrayAppendOwned(doc.allocator(), item);
    }
    try doc.setPath("server.tags", tags);

    // 3) Read back with typed accessors.
    const server = doc.root.get("server") orelse unreachable;
    const http = server.get("http") orelse unreachable;
    std.debug.print("host = {s}\n", .{http.get("host").?.asString().?});
    std.debug.print("port = {d}\n", .{http.get("port").?.asI64().?});

    // 4) Iterate the http subtable in insertion order.
    var http_it = http.iterator().table_iter;
    while (http_it.next()) |pair| {
        std.debug.print("  http.{s} (tag: {s})\n", .{ pair.key, @tagName(pair.value.*) });
    }

    // 5) Iterate the tags array.
    var tags_it = server.get("tags").?.iterator().array_iter;
    while (tags_it.next()) |v| {
        std.debug.print("  tag: {s}\n", .{v.asString().?});
    }
}
