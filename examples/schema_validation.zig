// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros

//! Schema Validation Example
//!
//! Demonstrates two validation styles:
//!   A. Runtime schema via SchemaNode + DiagnosticList.
//!   B. Comptime-typed decoding via toml.decode.

const std = @import("std");
const toml = @import("toml");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const src =
        \\name = "my-service"
        \\port = 8080
        \\tags = ["alpha", "beta"]
        \\[database]
        \\url = "postgres://localhost/db"
        \\max_connections = 50
    ;

    var doc = try toml.parse(alloc, src, .{});
    defer doc.deinit();

    try styleA(alloc, doc);
    try styleB(alloc, doc);
}

fn styleA(alloc: std.mem.Allocator, doc: *const toml.Document) !void {
    const name = toml.SchemaNode.N.string(.{ .min_len = 1 });
    const port = toml.SchemaNode.N.integer(.{ .min = 1, .max = 65535 });
    const tag_elem = toml.SchemaNode.N.string(.{});
    const tags = toml.SchemaNode.N.array(&tag_elem, .{});
    const url = toml.SchemaNode.N.string(.{});
    const max_conn = toml.SchemaNode.N.integer(.{ .min = 1 });
    const db_fields = [_]toml.FieldSchema{
        .{ .name = "url", .schema = &url, .required = true },
        .{ .name = "max_connections", .schema = &max_conn, .required = true },
    };
    const db = toml.SchemaNode.N.object(&db_fields, .strict);

    const fields = [_]toml.FieldSchema{
        .{ .name = "name", .schema = &name, .required = true },
        .{ .name = "port", .schema = &port, .required = true },
        .{ .name = "tags", .schema = &tags, .required = false },
        .{ .name = "database", .schema = &db, .required = true },
    };
    const validator = toml.SchemaValidator{ .root = toml.SchemaNode.N.object(&fields, .strict) };

    var diags = toml.DiagnosticList.init(alloc);
    defer diags.deinit();
    validator.validate(doc.root, &diags) catch |e| {
        std.debug.print("validation failed: {}\n", .{e});
        for (diags.items.items) |d| {
            std.debug.print("  {s}: {s}\n", .{ d.path, d.message });
        }
        return;
    };
    std.debug.print("Style A: OK ({d} diagnostics)\n", .{diags.len()});
}

fn styleB(alloc: std.mem.Allocator, doc: *const toml.Document) !void {
    const Database = struct {
        url: []const u8,
        max_connections: u32,
    };
    const Config = struct {
        name: []const u8,
        port: u16,
        tags: ?[][]const u8,
        database: Database,
    };

    var decoded = try toml.decode(Config, alloc, doc);
    defer decoded.deinit();
    std.debug.print("Style B: name={s} port={d} db.url={s}\n", .{
        decoded.value.name,
        decoded.value.port,
        decoded.value.database.url,
    });
}
