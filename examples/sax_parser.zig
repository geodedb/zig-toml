// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros

//! SAX-style TOML parsing example.
//!
//! Demonstrates the event-driven parser (`toml.parseEvents`). The
//! handler counts keys, tables, and array-of-tables headers without
//! ever building a `Document` tree. This is more memory-efficient
//! than `toml.parse` for large configuration files where the caller
//! only needs a small subset of the data.

const std = @import("std");
const toml = @import("toml");

const Counter = struct {
    keys: usize = 0,
    tables: usize = 0,
    array_of_tables: usize = 0,
    inline_tables: usize = 0,
    arrays: usize = 0,

    fn handle(ctx: *anyopaque, event: toml.Event) anyerror!void {
        const self: *Counter = @ptrCast(@alignCast(ctx));
        switch (event) {
            .key_value => self.keys += 1,
            .table_header => self.tables += 1,
            .array_of_tables_header => self.array_of_tables += 1,
            .inline_table_start => self.inline_tables += 1,
            .array_start => self.arrays += 1,
            else => {},
        }
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const stdout = std.io.getStdOut().writer();

    const input =
        \\title = "My Application"
        \\version = "1.0.0"
        \\
        \\[server]
        \\host = "localhost"
        \\port = 8080
        \\ports = [80, 443, 8080]
        \\
        \\[database]
        \\url = "postgres://localhost:5432/mydb"
        \\credentials = { user = "admin", pass = "secret" }
        \\
        \\[[users]]
        \\name = "alice"
        \\
        \\[[users]]
        \\name = "bob"
    ;

    var counter: Counter = .{};
    const handler = toml.EventHandler{
        .ctx = &counter,
        .handleFn = Counter.handle,
    };

    try toml.parseEvents(allocator, input, handler, .{});

    try stdout.print("=== SAX Parser Example ===\n\n", .{});
    try stdout.print("key=value pairs : {d}\n", .{counter.keys});
    try stdout.print("[table] headers : {d}\n", .{counter.tables});
    try stdout.print("[[aot]] headers : {d}\n", .{counter.array_of_tables});
    try stdout.print("inline tables   : {d}\n", .{counter.inline_tables});
    try stdout.print("arrays          : {d}\n", .{counter.arrays});
}
