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

/// Validate `value` against `node`, recording every violation into
/// `diags`. Returns `error.OutOfMemory` if a diagnostic cannot be
/// stored; never returns `SchemaViolation` (callers check `diags.len()`).
pub fn validateNode(
    node: *const SchemaNode,
    value: *const Value,
    path: []const u8,
    diags: *DiagnosticList,
) error{OutOfMemory}!void {
    switch (node.*) {
        .string => |opts| try validateString(opts, value, path, diags),
        .integer => |opts| try validateInteger(opts, value, path, diags),
        .float => |opts| try validateFloat(opts, value, path, diags),
        .boolean => try expectKind(.bool, value, path, diags),
        .datetime => try expectKind(.datetime, value, path, diags),
        .datetime_local => try expectKind(.datetime_local, value, path, diags),
        .date_local => try expectKind(.date_local, value, path, diags),
        .time_local => try expectKind(.time_local, value, path, diags),
        .array => |a| try validateArray(a.element, a.opts, value, path, diags),
        .object => |o| try validateObject(o.fields, o.unknown, value, path, diags),
        .one_of => |variants| try validateOneOf(variants, value, path, diags),
    }
}

fn expectKind(
    expected: ValueTag,
    value: *const Value,
    path: []const u8,
    diags: *DiagnosticList,
) error{OutOfMemory}!void {
    const got = @as(ValueTag, value.*);
    if (got == expected) return;
    try diags.append(path, .type_mismatch, expected, got, "type mismatch");
}

fn validateString(
    opts: StringOpts,
    value: *const Value,
    path: []const u8,
    diags: *DiagnosticList,
) error{OutOfMemory}!void {
    if (value.* != .string) {
        try diags.append(path, .type_mismatch, .string, @as(ValueTag, value.*), "expected string");
        return;
    }
    const s = value.string;
    if (opts.min_len) |m| {
        if (s.len < m) try diags.append(path, .string_too_short, .string, .string, "string shorter than min_len");
    }
    if (opts.max_len) |m| {
        if (s.len > m) try diags.append(path, .string_too_long, .string, .string, "string longer than max_len");
    }
}

fn validateInteger(
    opts: IntOpts,
    value: *const Value,
    path: []const u8,
    diags: *DiagnosticList,
) error{OutOfMemory}!void {
    if (value.* != .integer) {
        try diags.append(path, .type_mismatch, .integer, @as(ValueTag, value.*), "expected integer");
        return;
    }
    const n = value.integer;
    if (opts.min) |m| {
        if (n < m) try diags.append(path, .integer_out_of_range, .integer, .integer, "integer below min");
    }
    if (opts.max) |m| {
        if (n > m) try diags.append(path, .integer_out_of_range, .integer, .integer, "integer above max");
    }
}

fn validateFloat(
    opts: FloatOpts,
    value: *const Value,
    path: []const u8,
    diags: *DiagnosticList,
) error{OutOfMemory}!void {
    if (value.* != .float) {
        try diags.append(path, .type_mismatch, .float, @as(ValueTag, value.*), "expected float");
        return;
    }
    const f = value.float;
    if (std.math.isNan(f) and !opts.allow_nan) {
        try diags.append(path, .float_out_of_range, .float, .float, "NaN not allowed");
        return;
    }
    if (std.math.isInf(f) and !opts.allow_inf) {
        try diags.append(path, .float_out_of_range, .float, .float, "infinity not allowed");
        return;
    }
    if (opts.min) |m| {
        if (f < m) try diags.append(path, .float_out_of_range, .float, .float, "float below min");
    }
    if (opts.max) |m| {
        if (f > m) try diags.append(path, .float_out_of_range, .float, .float, "float above max");
    }
}

fn joinPath(
    alloc: Allocator,
    base: []const u8,
    child: []const u8,
) ![]u8 {
    if (base.len == 0) return alloc.dupe(u8, child);
    return try std.fmt.allocPrint(alloc, "{s}.{s}", .{ base, child });
}

fn validateObject(
    fields: []const FieldSchema,
    unknown: UnknownFieldPolicy,
    value: *const Value,
    path: []const u8,
    diags: *DiagnosticList,
) error{OutOfMemory}!void {
    if (value.* != .table) {
        try diags.append(path, .type_mismatch, .table, @as(ValueTag, value.*), "expected table");
        return;
    }
    const t = &value.table;

    // Check required fields / recurse into present fields.
    for (fields) |f| {
        const child = value.get(f.name);
        if (child == null) {
            if (f.required) {
                const child_path = try joinPath(diags.alloc, path, f.name);
                defer diags.alloc.free(child_path);
                try diags.append(child_path, .missing_required_field, null, null, "missing required field");
            }
            continue;
        }
        const child_path = try joinPath(diags.alloc, path, f.name);
        defer diags.alloc.free(child_path);
        try validateNode(f.schema, child.?, child_path, diags);
    }

    if (unknown == .strict) {
        const keys = t.map.keys();
        for (keys) |k| {
            var known = false;
            for (fields) |f| {
                if (std.mem.eql(u8, f.name, k)) {
                    known = true;
                    break;
                }
            }
            if (!known) {
                const child_path = try joinPath(diags.alloc, path, k);
                defer diags.alloc.free(child_path);
                try diags.append(child_path, .unknown_field, null, null, "unknown field");
            }
        }
    }
}

fn validateArray(
    element: *const SchemaNode,
    opts: ArrayOpts,
    value: *const Value,
    path: []const u8,
    diags: *DiagnosticList,
) error{OutOfMemory}!void {
    if (value.* != .array) {
        try diags.append(path, .type_mismatch, .array, @as(ValueTag, value.*), "expected array");
        return;
    }
    const items = value.array.items.items;

    if (opts.min_len) |m| {
        if (items.len < m) {
            try diags.append(path, .array_too_short, .array, .array, "array shorter than min_len");
        }
    }
    if (opts.max_len) |m| {
        if (items.len > m) {
            try diags.append(path, .array_too_long, .array, .array, "array longer than max_len");
        }
    }

    for (items, 0..) |*elem_value, i| {
        const child_path = try std.fmt.allocPrint(
            diags.alloc,
            "{s}[{d}]",
            .{ path, i },
        );
        defer diags.alloc.free(child_path);
        try validateNode(element, elem_value, child_path, diags);
    }
}

fn validateOneOf(
    variants: []const SchemaNode,
    value: *const Value,
    path: []const u8,
    diags: *DiagnosticList,
) error{OutOfMemory}!void {
    var scratch = DiagnosticList.init(diags.alloc);
    defer scratch.deinit();

    for (variants) |*variant| {
        scratch.deinit();
        scratch = DiagnosticList.init(diags.alloc);
        try validateNode(variant, value, path, &scratch);
        if (scratch.len() == 0) return; // accepted by this variant
    }

    try diags.append(path, .one_of_no_match, null, @as(ValueTag, value.*), "no variant matched");
}

/// Public runtime schema handle. Wraps a root `SchemaNode` and provides the
/// top-level `validate` entry point. The `validate` method returns
/// `SchemaError.SchemaViolation` when any diagnostic is recorded, so
/// callers can use `try schema.validate(...)` for happy-path short-circuit.
pub const Schema = struct {
    root: SchemaNode,

    pub fn validate(
        self: *const Schema,
        value: *const Value,
        diags: *DiagnosticList,
    ) SchemaError!void {
        try validateNode(&self.root, value, "", diags);
        if (diags.len() > 0) return SchemaError.SchemaViolation;
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

test "validate integer within range" {
    const alloc = std.testing.allocator;
    var diags = DiagnosticList.init(alloc);
    defer diags.deinit();

    const node = SchemaNode.N.integer(.{ .min = 1, .max = 100 });
    const v = Value{ .integer = 42 };
    try validateNode(&node, &v, "port", &diags);
    try std.testing.expectEqual(@as(usize, 0), diags.len());
}

test "validate integer below min" {
    const alloc = std.testing.allocator;
    var diags = DiagnosticList.init(alloc);
    defer diags.deinit();

    const node = SchemaNode.N.integer(.{ .min = 1, .max = 100 });
    const v = Value{ .integer = 0 };
    try validateNode(&node, &v, "port", &diags);
    try std.testing.expectEqual(@as(usize, 1), diags.len());
    try std.testing.expectEqual(DiagnosticCode.integer_out_of_range, diags.items.items[0].code);
    try std.testing.expectEqualStrings("port", diags.items.items[0].path);
}

test "validate integer above max" {
    const alloc = std.testing.allocator;
    var diags = DiagnosticList.init(alloc);
    defer diags.deinit();

    const node = SchemaNode.N.integer(.{ .min = 1, .max = 100 });
    const v = Value{ .integer = 999 };
    try validateNode(&node, &v, "port", &diags);
    try std.testing.expectEqual(@as(usize, 1), diags.len());
    try std.testing.expectEqual(DiagnosticCode.integer_out_of_range, diags.items.items[0].code);
}

test "validate type mismatch records expected/got" {
    const alloc = std.testing.allocator;
    var diags = DiagnosticList.init(alloc);
    defer diags.deinit();

    const node = SchemaNode.N.integer(.{});
    const v = Value{ .string = "nope" };
    try validateNode(&node, &v, "port", &diags);
    try std.testing.expectEqual(@as(usize, 1), diags.len());
    const d = diags.items.items[0];
    try std.testing.expectEqual(DiagnosticCode.type_mismatch, d.code);
    try std.testing.expectEqual(ValueTag.integer, d.expected.?);
    try std.testing.expectEqual(ValueTag.string, d.got.?);
}

test "validate string length bounds" {
    const alloc = std.testing.allocator;
    var diags = DiagnosticList.init(alloc);
    defer diags.deinit();

    const node = SchemaNode.N.string(.{ .min_len = 2, .max_len = 5 });

    const too_short = Value{ .string = "a" };
    try validateNode(&node, &too_short, "k", &diags);
    try std.testing.expectEqual(@as(usize, 1), diags.len());
    try std.testing.expectEqual(DiagnosticCode.string_too_short, diags.items.items[0].code);

    var diags2 = DiagnosticList.init(alloc);
    defer diags2.deinit();
    const too_long = Value{ .string = "abcdef" };
    try validateNode(&node, &too_long, "k", &diags2);
    try std.testing.expectEqual(@as(usize, 1), diags2.len());
    try std.testing.expectEqual(DiagnosticCode.string_too_long, diags2.items.items[0].code);
}

test "validate bool happy path and type mismatch" {
    const alloc = std.testing.allocator;
    var diags = DiagnosticList.init(alloc);
    defer diags.deinit();

    const node = SchemaNode.N.boolean();
    const v_ok = Value{ .bool = true };
    try validateNode(&node, &v_ok, "flag", &diags);
    try std.testing.expectEqual(@as(usize, 0), diags.len());

    const v_bad = Value{ .integer = 0 };
    try validateNode(&node, &v_bad, "flag", &diags);
    try std.testing.expectEqual(@as(usize, 1), diags.len());
    try std.testing.expectEqual(DiagnosticCode.type_mismatch, diags.items.items[0].code);
}

test "validate float NaN rejected when allow_nan is false" {
    const alloc = std.testing.allocator;
    var diags = DiagnosticList.init(alloc);
    defer diags.deinit();

    const node = SchemaNode.N.float(.{ .allow_nan = false });
    const v = Value{ .float = std.math.nan(f64) };
    try validateNode(&node, &v, "f", &diags);
    try std.testing.expectEqual(@as(usize, 1), diags.len());
    try std.testing.expectEqual(DiagnosticCode.float_out_of_range, diags.items.items[0].code);
}
