// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros

//! Schema validation and typed decoding for parsed TOML documents.
//!
//! Two validation styles are provided:
//!   1. Runtime `Schema` built from `SchemaNode` values and validated against
//!      a `*const Value` with diagnostics accumulated in a `DiagnosticList`.
//!   2. Comptime `decode(comptime T, alloc, document)` which uses
//!      `@typeInfo(T)` to map a `Document` into a user-defined struct.

const std = @import("std");
const Allocator = std.mem.Allocator;
const value_mod = @import("value.zig");
const Value = value_mod.Value;
const ValueTag = value_mod.ValueTag;
const Document = value_mod.Document;

pub const SchemaError = error{
    SchemaViolation,
    OutOfMemory,
};

/// Enumerated reason a schema violation was recorded.
pub const DiagnosticCode = enum {
    type_mismatch,
    missing_required_field,
    unknown_field,
    integer_out_of_range,
    float_out_of_range,
    string_too_short,
    string_too_long,
    array_too_short,
    array_too_long,
    one_of_no_match,
    custom,
};

/// One schema violation. `path` is an owned slice (alloc-owned by the
/// DiagnosticList); `expected` and `got` are optional because some
/// violations (e.g. missing_required_field) only know one side.
pub const Diagnostic = struct {
    path: []const u8,
    expected: ?ValueTag = null,
    got: ?ValueTag = null,
    code: DiagnosticCode,
    message: []const u8,
};

/// Owning collector for diagnostics. All `path` and `message` slices are
/// duplicated into the caller-provided allocator so the Value tree can be
/// freed independently of the diagnostics.
pub const DiagnosticList = struct {
    items: std.ArrayList(Diagnostic),
    alloc: Allocator,

    pub fn init(alloc: Allocator) DiagnosticList {
        return .{ .items = .empty, .alloc = alloc };
    }

    pub fn deinit(self: *DiagnosticList) void {
        for (self.items.items) |d| {
            self.alloc.free(d.path);
            self.alloc.free(d.message);
        }
        self.items.deinit(self.alloc);
    }

    pub fn append(
        self: *DiagnosticList,
        path: []const u8,
        code: DiagnosticCode,
        expected: ?ValueTag,
        got: ?ValueTag,
        message: []const u8,
    ) !void {
        const path_copy = try self.alloc.dupe(u8, path);
        errdefer self.alloc.free(path_copy);
        const msg_copy = try self.alloc.dupe(u8, message);
        errdefer self.alloc.free(msg_copy);
        try self.items.append(self.alloc, .{
            .path = path_copy,
            .expected = expected,
            .got = got,
            .code = code,
            .message = msg_copy,
        });
    }

    pub fn len(self: *const DiagnosticList) usize {
        return self.items.items.len;
    }
};

test "schema module compiles" {
    // Placeholder to ensure the module is reachable from the unit-test build.
    try std.testing.expect(true);
}

test "Diagnostic stores path and kind information" {
    const d = Diagnostic{
        .path = "server.port",
        .expected = .integer,
        .got = .string,
        .code = .type_mismatch,
        .message = "expected integer",
    };
    try std.testing.expectEqualStrings("server.port", d.path);
    try std.testing.expectEqual(ValueTag.integer, d.expected.?);
    try std.testing.expectEqual(ValueTag.string, d.got.?);
    try std.testing.expectEqual(DiagnosticCode.type_mismatch, d.code);
}

test "DiagnosticList owns path and message copies" {
    var list = DiagnosticList.init(std.testing.allocator);
    defer list.deinit();

    var buf: [32]u8 = undefined;
    const p = try std.fmt.bufPrint(&buf, "a.b[{d}].c", .{0});
    try list.append(p, .type_mismatch, .integer, .string, "expected int");

    // Overwrite the source buffer; diagnostic must have copied.
    @memset(&buf, '!');
    try std.testing.expectEqual(@as(usize, 1), list.len());
    try std.testing.expectEqualStrings("a.b[0].c", list.items.items[0].path);
    try std.testing.expectEqualStrings("expected int", list.items.items[0].message);
}
