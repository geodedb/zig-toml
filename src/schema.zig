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

/// A field in an `object` schema.
pub const FieldSchema = struct {
    name: []const u8,
    schema: *const SchemaNode,
    required: bool = true,
};

/// Validation mode for unknown object fields.
pub const UnknownFieldPolicy = enum { strict, lax };

/// Constraint set for string values.
pub const StringOpts = struct {
    min_len: ?usize = null,
    max_len: ?usize = null,
};

/// Constraint set for integer values.
pub const IntOpts = struct {
    min: ?i64 = null,
    max: ?i64 = null,
};

/// Constraint set for float values.
pub const FloatOpts = struct {
    min: ?f64 = null,
    max: ?f64 = null,
    allow_nan: bool = true,
    allow_inf: bool = true,
};

/// Constraint set for array values.
pub const ArrayOpts = struct {
    min_len: ?usize = null,
    max_len: ?usize = null,
};

/// Declarative schema node. Each variant describes the expected value and
/// optional constraints. Heap-allocation is caller-controlled — constructors
/// take slices into memory the caller already owns.
///
/// Construction: Zig forbids a declaration on a union type from sharing a
/// name with a tag field, so we cannot write `SchemaNode.string(...)`
/// directly. Use the `SchemaNode.N` namespace (`N` for "node") instead:
///
/// ```zig
/// const node = SchemaNode.N.string(.{ .min_len = 1 });
/// const int  = SchemaNode.N.integer(.{ .min = 0, .max = 65535 });
/// ```
///
/// Or build literals directly: `SchemaNode{ .string = .{} }`.
pub const SchemaNode = union(Kind) {
    string: StringOpts,
    integer: IntOpts,
    float: FloatOpts,
    boolean: void,
    datetime: void,
    datetime_local: void,
    date_local: void,
    time_local: void,
    array: struct {
        element: *const SchemaNode,
        opts: ArrayOpts = .{},
    },
    object: struct {
        fields: []const FieldSchema,
        unknown: UnknownFieldPolicy = .strict,
    },
    one_of: []const SchemaNode,

    pub const Kind = enum {
        string,
        integer,
        float,
        boolean,
        datetime,
        datetime_local,
        date_local,
        time_local,
        array,
        object,
        one_of,
    };

    /// Constructor namespace. Grouped under `N` because Zig does not
    /// allow a decl to share a name with a union tag field.
    pub const N = struct {
        pub fn string(opts: StringOpts) SchemaNode {
            return .{ .string = opts };
        }

        pub fn integer(opts: IntOpts) SchemaNode {
            return .{ .integer = opts };
        }

        pub fn float(opts: FloatOpts) SchemaNode {
            return .{ .float = opts };
        }

        pub fn boolean() SchemaNode {
            return .{ .boolean = {} };
        }

        pub fn datetime() SchemaNode {
            return .{ .datetime = {} };
        }

        pub fn datetimeLocal() SchemaNode {
            return .{ .datetime_local = {} };
        }

        pub fn dateLocal() SchemaNode {
            return .{ .date_local = {} };
        }

        pub fn timeLocal() SchemaNode {
            return .{ .time_local = {} };
        }

        pub fn array(element: *const SchemaNode, opts: ArrayOpts) SchemaNode {
            return .{ .array = .{ .element = element, .opts = opts } };
        }

        pub fn object(fields: []const FieldSchema, unknown: UnknownFieldPolicy) SchemaNode {
            return .{ .object = .{ .fields = fields, .unknown = unknown } };
        }

        pub fn oneOf(variants: []const SchemaNode) SchemaNode {
            return .{ .one_of = variants };
        }
    };

    pub fn kind(self: SchemaNode) Kind {
        return @as(Kind, self);
    }
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

test "SchemaNode.N.string builds a string node" {
    const node = SchemaNode.N.string(.{});
    try std.testing.expectEqual(SchemaNode.Kind.string, node.kind());
}

test "SchemaNode.N.integer honors min and max" {
    const node = SchemaNode.N.integer(.{ .min = 1, .max = 65535 });
    try std.testing.expectEqual(SchemaNode.Kind.integer, node.kind());
    try std.testing.expectEqual(@as(i64, 1), node.integer.min.?);
    try std.testing.expectEqual(@as(i64, 65535), node.integer.max.?);
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
