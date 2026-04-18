# Schema Validation Module Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close GAP-0015 by adding a schema validation module (`src/schema.zig`) that offers both a runtime `Schema` value for data-driven validation and a comptime-reflective `decode(T, ...)` decoder mapping a `Document` into a user-defined Zig struct.

**Architecture:** Two orthogonal validation styles live in one module. Style A defines `SchemaNode` as a tagged union describing expected shape/constraints and validates a `*const Value` against it, accumulating `Diagnostic` entries on a user-supplied list. Style B uses `@typeInfo` at comptime to reflect a user struct `T`, then walks the `Document` and allocates `T` (with owned slices/strings) inside a caller-provided allocator. Style A and B share the same error-code enum (`SchemaError`) and the `Diagnostic` representation so callers can route errors uniformly.

**Tech Stack:** Zig 0.15+, existing `value.zig` (`Value`, `ValueTag`, `Document`), std.ArrayList, std.mem.Allocator, std.testing. No new third-party dependencies.

---

## File Structure

- Create `src/schema.zig` — the module's public surface: `SchemaNode`, `Schema`, `Diagnostic`, `DiagnosticList`, `SchemaError`, `decode`, tests.
- Modify `src/toml.zig` — re-export `schema` module and the `decode` function so callers see them via `const toml = @import("toml");`.
- Modify `build.zig` — nothing functionally, but verify the new file is picked up by the unit-tests module (it is, because `src/toml.zig` imports it).
- Create `examples/schema_validation.zig` — end-to-end example using both styles.
- Modify `docs/API.md` — add "Schema Validation" section documenting `SchemaNode`, `Schema.validate`, `decode`.
- Modify `CHANGELOG.md` — note GAP-0015 closure.
- Modify `docs/GAP_ANALYSIS.md` / `docs/GAP_ANALYSIS_RESOLVED.md` — move GAP-0015 to Resolved.

Boundary rules:

- `schema.zig` MUST only depend on `value.zig` (plus `std`). It MUST NOT import `parser.zig` or `lexer.zig`.
- `Value` is never mutated by schema code. Validators take `*const Value`.
- `decode` allocates into the caller's allocator — never into the document's arena.

---

## Task 1: Scaffold src/schema.zig

**Files:**

- Create: `src/schema.zig`
- Modify: `src/toml.zig`

- [ ] **Step 1: Create the stub module**

Write `src/schema.zig`:

```zig
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

test "schema module compiles" {
    // Placeholder to ensure the module is reachable from the unit-test build.
    try std.testing.expect(true);
}
```

- [ ] **Step 2: Re-export from the library root**

Edit `src/toml.zig`. Locate the block near the top that lists `pub const parallel = @import("parallel.zig");` and add below it:

```zig
pub const schema = @import("schema.zig");
pub const SchemaError = schema.SchemaError;
```

- [ ] **Step 3: Run check to verify the module compiles**

Run: `zig build check`
Expected: No compile errors.

- [ ] **Step 4: Run the placeholder test**

Run: `zig build test`
Expected: All tests pass (including the new `schema module compiles` test).

- [ ] **Step 5: Commit**

```bash
git add src/schema.zig src/toml.zig
git commit -m "feat(schema): scaffold module"
```

---

## Task 2: Define Diagnostic, DiagnosticList, PathSegment

**Files:**

- Modify: `src/schema.zig`

- [ ] **Step 1: Write failing test for Diagnostic construction**

Append to `src/schema.zig` (below the placeholder test):

```zig
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test`
Expected: Compile error — `Diagnostic`, `DiagnosticCode` not declared.

- [ ] **Step 3: Add Diagnostic types**

Insert above the tests in `src/schema.zig`:

```zig
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `zig build test`
Expected: PASS.

- [ ] **Step 5: Add DiagnosticList append/len test**

Append to `src/schema.zig`:

```zig
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
```

- [ ] **Step 6: Run tests**

Run: `zig build test`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add src/schema.zig
git commit -m "feat(schema): add Diagnostic and DiagnosticList types"
```

---

## Task 3: Define SchemaNode union

**Files:**

- Modify: `src/schema.zig`

- [ ] **Step 1: Write failing test for SchemaNode construction**

Append to `src/schema.zig`:

```zig
test "SchemaNode.string builds a string node" {
    const node = SchemaNode.string(.{});
    try std.testing.expectEqual(SchemaNode.Kind.string, node.kind());
}

test "SchemaNode.integer honors min and max" {
    const node = SchemaNode.integer(.{ .min = 1, .max = 65535 });
    try std.testing.expectEqual(SchemaNode.Kind.integer, node.kind());
    try std.testing.expectEqual(@as(i64, 1), node.integer.min.?);
    try std.testing.expectEqual(@as(i64, 65535), node.integer.max.?);
}
```

- [ ] **Step 2: Run to verify failure**

Run: `zig build test`
Expected: Compile error — `SchemaNode` not declared.

- [ ] **Step 3: Implement SchemaNode**

Insert in `src/schema.zig` (above Diagnostic declarations is fine; grouping all schema types together):

```zig
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

    pub fn kind(self: SchemaNode) Kind {
        return @as(Kind, self);
    }

    pub fn stringNode(opts: StringOpts) SchemaNode {
        return .{ .string = opts };
    }

    pub fn integerNode(opts: IntOpts) SchemaNode {
        return .{ .integer = opts };
    }

    pub fn floatNode(opts: FloatOpts) SchemaNode {
        return .{ .float = opts };
    }

    pub fn booleanNode() SchemaNode {
        return .{ .boolean = {} };
    }

    pub fn datetimeNode() SchemaNode {
        return .{ .datetime = {} };
    }

    pub fn arrayNode(element: *const SchemaNode, opts: ArrayOpts) SchemaNode {
        return .{ .array = .{ .element = element, .opts = opts } };
    }

    pub fn objectNode(fields: []const FieldSchema, unknown: UnknownFieldPolicy) SchemaNode {
        return .{ .object = .{ .fields = fields, .unknown = unknown } };
    }

    pub fn oneOfNode(variants: []const SchemaNode) SchemaNode {
        return .{ .one_of = variants };
    }

    // Short aliases kept as associated constants so tests can write
    // `SchemaNode.string(...)`. Zig does not allow identifiers named after a
    // tag, so these are functions on the type namespace that forward to the
    // node builders above.
    pub const string = stringNode;
    pub const integer = integerNode;
    pub const float = floatNode;
    pub const boolean = booleanNode;
    pub const datetime = datetimeNode;
    pub const array = arrayNode;
    pub const object = objectNode;
    pub const one_of = oneOfNode;
};
```

- [ ] **Step 4: Run tests**

Run: `zig build test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/schema.zig
git commit -m "feat(schema): define SchemaNode union and constraint options"
```

---

## Task 4: Validate integer schema with min/max

**Files:**

- Modify: `src/schema.zig`

- [ ] **Step 1: Write failing tests**

Append to `src/schema.zig`:

```zig
test "validate integer within range" {
    var alloc = std.testing.allocator;
    var diags = DiagnosticList.init(alloc);
    defer diags.deinit();

    const node = SchemaNode.integer(.{ .min = 1, .max = 100 });
    const v = Value{ .integer = 42 };
    try validateNode(&node, &v, "port", &diags);
    try std.testing.expectEqual(@as(usize, 0), diags.len());
}

test "validate integer below min" {
    var alloc = std.testing.allocator;
    var diags = DiagnosticList.init(alloc);
    defer diags.deinit();

    const node = SchemaNode.integer(.{ .min = 1, .max = 100 });
    const v = Value{ .integer = 0 };
    try validateNode(&node, &v, "port", &diags);
    try std.testing.expectEqual(@as(usize, 1), diags.len());
    try std.testing.expectEqual(DiagnosticCode.integer_out_of_range, diags.items.items[0].code);
    try std.testing.expectEqualStrings("port", diags.items.items[0].path);
}

test "validate integer above max" {
    var alloc = std.testing.allocator;
    var diags = DiagnosticList.init(alloc);
    defer diags.deinit();

    const node = SchemaNode.integer(.{ .min = 1, .max = 100 });
    const v = Value{ .integer = 999 };
    try validateNode(&node, &v, "port", &diags);
    try std.testing.expectEqual(@as(usize, 1), diags.len());
    try std.testing.expectEqual(DiagnosticCode.integer_out_of_range, diags.items.items[0].code);
}

test "validate type mismatch records expected/got" {
    var alloc = std.testing.allocator;
    var diags = DiagnosticList.init(alloc);
    defer diags.deinit();

    const node = SchemaNode.integer(.{});
    const v = Value{ .string = "nope" };
    try validateNode(&node, &v, "port", &diags);
    try std.testing.expectEqual(@as(usize, 1), diags.len());
    const d = diags.items.items[0];
    try std.testing.expectEqual(DiagnosticCode.type_mismatch, d.code);
    try std.testing.expectEqual(ValueTag.integer, d.expected.?);
    try std.testing.expectEqual(ValueTag.string, d.got.?);
}
```

- [ ] **Step 2: Run to verify failure**

Run: `zig build test`
Expected: Compile error — `validateNode` not declared.

- [ ] **Step 3: Implement validateNode — scalar cases**

Insert in `src/schema.zig` below `SchemaNode`:

```zig
/// Validate `value` against `node`, recording every violation into
/// `diags`. Returns `SchemaError.OutOfMemory` if a diagnostic cannot be
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
        .array => {}, // implemented in a later task
        .object => {}, // implemented in a later task
        .one_of => {}, // implemented in a later task
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
```

- [ ] **Step 4: Run tests**

Run: `zig build test`
Expected: PASS — four new tests green.

- [ ] **Step 5: Commit**

```bash
git add src/schema.zig
git commit -m "feat(schema): scalar validators for string/integer/float/bool/datetime"
```

---

## Task 5: Object validator (required/unknown fields, recursion)

**Files:**

- Modify: `src/schema.zig`

- [ ] **Step 1: Write failing tests**

Append to `src/schema.zig`:

```zig
test "object validator: all required fields present" {
    const alloc = std.testing.allocator;
    const toml = @import("toml.zig");

    const src =
        \\name = "svc"
        \\port = 8080
    ;
    var doc = try toml.parse(alloc, src, .{});
    defer doc.deinit();

    const name_node = SchemaNode.string(.{});
    const port_node = SchemaNode.integer(.{ .min = 1, .max = 65535 });
    const fields = [_]FieldSchema{
        .{ .name = "name", .schema = &name_node, .required = true },
        .{ .name = "port", .schema = &port_node, .required = true },
    };
    const schema_root = SchemaNode.object(&fields, .strict);

    var diags = DiagnosticList.init(alloc);
    defer diags.deinit();
    try validateNode(&schema_root, doc.root, "", &diags);
    try std.testing.expectEqual(@as(usize, 0), diags.len());
}

test "object validator: missing required field recorded" {
    const alloc = std.testing.allocator;
    const toml = @import("toml.zig");

    const src = "name = \"svc\"\n";
    var doc = try toml.parse(alloc, src, .{});
    defer doc.deinit();

    const name_node = SchemaNode.string(.{});
    const port_node = SchemaNode.integer(.{});
    const fields = [_]FieldSchema{
        .{ .name = "name", .schema = &name_node, .required = true },
        .{ .name = "port", .schema = &port_node, .required = true },
    };
    const schema_root = SchemaNode.object(&fields, .strict);

    var diags = DiagnosticList.init(alloc);
    defer diags.deinit();
    try validateNode(&schema_root, doc.root, "", &diags);
    try std.testing.expectEqual(@as(usize, 1), diags.len());
    try std.testing.expectEqual(DiagnosticCode.missing_required_field, diags.items.items[0].code);
    try std.testing.expectEqualStrings("port", diags.items.items[0].path);
}

test "object validator: unknown field flagged in strict" {
    const alloc = std.testing.allocator;
    const toml = @import("toml.zig");

    const src =
        \\name = "svc"
        \\extra = 1
    ;
    var doc = try toml.parse(alloc, src, .{});
    defer doc.deinit();

    const name_node = SchemaNode.string(.{});
    const fields = [_]FieldSchema{
        .{ .name = "name", .schema = &name_node, .required = true },
    };
    const schema_root = SchemaNode.object(&fields, .strict);

    var diags = DiagnosticList.init(alloc);
    defer diags.deinit();
    try validateNode(&schema_root, doc.root, "", &diags);
    try std.testing.expectEqual(@as(usize, 1), diags.len());
    try std.testing.expectEqual(DiagnosticCode.unknown_field, diags.items.items[0].code);
    try std.testing.expectEqualStrings("extra", diags.items.items[0].path);
}

test "object validator: unknown field ignored in lax" {
    const alloc = std.testing.allocator;
    const toml = @import("toml.zig");

    const src =
        \\name = "svc"
        \\extra = 1
    ;
    var doc = try toml.parse(alloc, src, .{});
    defer doc.deinit();

    const name_node = SchemaNode.string(.{});
    const fields = [_]FieldSchema{
        .{ .name = "name", .schema = &name_node, .required = true },
    };
    const schema_root = SchemaNode.object(&fields, .lax);

    var diags = DiagnosticList.init(alloc);
    defer diags.deinit();
    try validateNode(&schema_root, doc.root, "", &diags);
    try std.testing.expectEqual(@as(usize, 0), diags.len());
}

test "object validator: recursive nested objects accumulate path" {
    const alloc = std.testing.allocator;
    const toml = @import("toml.zig");

    const src =
        \\[server]
        \\host = "localhost"
        \\port = "not_an_int"
    ;
    var doc = try toml.parse(alloc, src, .{});
    defer doc.deinit();

    const host_node = SchemaNode.string(.{});
    const port_node = SchemaNode.integer(.{});
    const inner_fields = [_]FieldSchema{
        .{ .name = "host", .schema = &host_node, .required = true },
        .{ .name = "port", .schema = &port_node, .required = true },
    };
    const server_node = SchemaNode.object(&inner_fields, .strict);
    const root_fields = [_]FieldSchema{
        .{ .name = "server", .schema = &server_node, .required = true },
    };
    const schema_root = SchemaNode.object(&root_fields, .strict);

    var diags = DiagnosticList.init(alloc);
    defer diags.deinit();
    try validateNode(&schema_root, doc.root, "", &diags);
    try std.testing.expectEqual(@as(usize, 1), diags.len());
    try std.testing.expectEqualStrings("server.port", diags.items.items[0].path);
    try std.testing.expectEqual(DiagnosticCode.type_mismatch, diags.items.items[0].code);
}
```

- [ ] **Step 2: Run to verify failure**

Run: `zig build test`
Expected: Failures — object branch is still a no-op.

- [ ] **Step 3: Implement object validator**

Replace the `.object => {}` line in `validateNode` with `.object => |o| try validateObject(o.fields, o.unknown, value, path, diags),` and add the helper:

```zig
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
    const t = value.table;

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
        for (t.entries) |entry| {
            var known = false;
            for (fields) |f| {
                if (std.mem.eql(u8, f.name, entry.key)) {
                    known = true;
                    break;
                }
            }
            if (!known) {
                const child_path = try joinPath(diags.alloc, path, entry.key);
                defer diags.alloc.free(child_path);
                try diags.append(child_path, .unknown_field, null, null, "unknown field");
            }
        }
    }
}
```

- [ ] **Step 4: Run tests**

Run: `zig build test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/schema.zig
git commit -m "feat(schema): object validator with required/unknown policies"
```

---

## Task 6: Array validator with element schema and length bounds

**Files:**

- Modify: `src/schema.zig`

- [ ] **Step 1: Write failing tests**

Append to `src/schema.zig`:

```zig
test "array validator: element type checked" {
    const alloc = std.testing.allocator;
    const toml = @import("toml.zig");

    const src = "tags = [\"a\", \"b\", 3]\n";
    var doc = try toml.parse(alloc, src, .{});
    defer doc.deinit();

    const elem = SchemaNode.string(.{});
    const arr_node = SchemaNode.array(&elem, .{});
    const fields = [_]FieldSchema{
        .{ .name = "tags", .schema = &arr_node, .required = true },
    };
    const schema_root = SchemaNode.object(&fields, .strict);

    var diags = DiagnosticList.init(alloc);
    defer diags.deinit();
    try validateNode(&schema_root, doc.root, "", &diags);
    try std.testing.expectEqual(@as(usize, 1), diags.len());
    try std.testing.expectEqualStrings("tags[2]", diags.items.items[0].path);
    try std.testing.expectEqual(DiagnosticCode.type_mismatch, diags.items.items[0].code);
}

test "array validator: length bounds" {
    const alloc = std.testing.allocator;
    const toml = @import("toml.zig");

    const src = "tags = [\"a\"]\n";
    var doc = try toml.parse(alloc, src, .{});
    defer doc.deinit();

    const elem = SchemaNode.string(.{});
    const arr_node = SchemaNode.array(&elem, .{ .min_len = 2, .max_len = 5 });
    const fields = [_]FieldSchema{
        .{ .name = "tags", .schema = &arr_node, .required = true },
    };
    const schema_root = SchemaNode.object(&fields, .strict);

    var diags = DiagnosticList.init(alloc);
    defer diags.deinit();
    try validateNode(&schema_root, doc.root, "", &diags);
    try std.testing.expectEqual(@as(usize, 1), diags.len());
    try std.testing.expectEqual(DiagnosticCode.array_too_short, diags.items.items[0].code);
    try std.testing.expectEqualStrings("tags", diags.items.items[0].path);
}
```

- [ ] **Step 2: Run to verify failure**

Run: `zig build test`
Expected: Failures — `.array => {}` path records nothing.

- [ ] **Step 3: Implement array validator**

Replace `.array => {}` in `validateNode` with `.array => |a| try validateArray(a.element, a.opts, value, path, diags),` and add:

```zig
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
    const items = value.array.items;

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

    for (items, 0..) |elem_value, i| {
        const child_path = try std.fmt.allocPrint(
            diags.alloc,
            "{s}[{d}]",
            .{ path, i },
        );
        defer diags.alloc.free(child_path);
        try validateNode(element, elem_value, child_path, diags);
    }
}
```

- [ ] **Step 4: Run tests**

Run: `zig build test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/schema.zig
git commit -m "feat(schema): array validator with element schema and length bounds"
```

---

## Task 7: one_of variant validator

**Files:**

- Modify: `src/schema.zig`

- [ ] **Step 1: Write failing test**

Append to `src/schema.zig`:

```zig
test "one_of accepts first matching variant" {
    const alloc = std.testing.allocator;
    var diags = DiagnosticList.init(alloc);
    defer diags.deinit();

    const variants = [_]SchemaNode{
        SchemaNode.integer(.{}),
        SchemaNode.string(.{}),
    };
    const node = SchemaNode.one_of(&variants);

    const v_int = Value{ .integer = 5 };
    try validateNode(&node, &v_int, "x", &diags);
    try std.testing.expectEqual(@as(usize, 0), diags.len());

    const v_str = Value{ .string = "ok" };
    try validateNode(&node, &v_str, "x", &diags);
    try std.testing.expectEqual(@as(usize, 0), diags.len());
}

test "one_of emits one diagnostic when no variant matches" {
    const alloc = std.testing.allocator;
    var diags = DiagnosticList.init(alloc);
    defer diags.deinit();

    const variants = [_]SchemaNode{
        SchemaNode.integer(.{}),
        SchemaNode.boolean(),
    };
    const node = SchemaNode.one_of(&variants);

    const v = Value{ .string = "nope" };
    try validateNode(&node, &v, "x", &diags);
    try std.testing.expectEqual(@as(usize, 1), diags.len());
    try std.testing.expectEqual(DiagnosticCode.one_of_no_match, diags.items.items[0].code);
    try std.testing.expectEqualStrings("x", diags.items.items[0].path);
}
```

- [ ] **Step 2: Run to verify failure**

Run: `zig build test`
Expected: FAIL — the `.one_of` branch still records nothing.

- [ ] **Step 3: Implement one_of**

Replace `.one_of => {}` in `validateNode` with `.one_of => |variants| try validateOneOf(variants, value, path, diags),` and add:

```zig
fn validateOneOf(
    variants: []const SchemaNode,
    value: *const Value,
    path: []const u8,
    diags: *DiagnosticList,
) error{OutOfMemory}!void {
    var scratch = DiagnosticList.init(diags.alloc);
    defer scratch.deinit();

    for (variants) |variant| {
        scratch.deinit();
        scratch = DiagnosticList.init(diags.alloc);
        try validateNode(&variant, value, path, &scratch);
        if (scratch.len() == 0) return; // accepted by this variant
    }

    try diags.append(path, .one_of_no_match, null, @as(ValueTag, value.*), "no variant matched");
}
```

- [ ] **Step 4: Run tests**

Run: `zig build test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/schema.zig
git commit -m "feat(schema): one_of variant validator"
```

---

## Task 8: Public Schema wrapper and close GAP-0015 (Style A)

**Files:**

- Modify: `src/schema.zig`

- [ ] **Step 1: Write failing test**

Append to `src/schema.zig`:

```zig
test "Schema.validate returns SchemaViolation when diags non-empty" {
    const alloc = std.testing.allocator;
    const toml = @import("toml.zig");

    const src = "port = \"wrong\"\n";
    var doc = try toml.parse(alloc, src, .{});
    defer doc.deinit();

    const port_node = SchemaNode.integer(.{});
    const fields = [_]FieldSchema{
        .{ .name = "port", .schema = &port_node, .required = true },
    };
    const schema = Schema{ .root = SchemaNode.object(&fields, .strict) };

    var diags = DiagnosticList.init(alloc);
    defer diags.deinit();
    const err = schema.validate(doc.root, &diags);
    try std.testing.expectError(SchemaError.SchemaViolation, err);
    try std.testing.expectEqual(@as(usize, 1), diags.len());
}

test "Schema.validate succeeds when no diags" {
    const alloc = std.testing.allocator;
    const toml = @import("toml.zig");

    const src = "port = 8080\n";
    var doc = try toml.parse(alloc, src, .{});
    defer doc.deinit();

    const port_node = SchemaNode.integer(.{});
    const fields = [_]FieldSchema{
        .{ .name = "port", .schema = &port_node, .required = true },
    };
    const schema = Schema{ .root = SchemaNode.object(&fields, .strict) };

    var diags = DiagnosticList.init(alloc);
    defer diags.deinit();
    try schema.validate(doc.root, &diags);
}
```

- [ ] **Step 2: Run to verify failure**

Run: `zig build test`
Expected: Compile error — `Schema` not declared.

- [ ] **Step 3: Add Schema wrapper**

Insert in `src/schema.zig` (above the tests):

```zig
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
```

- [ ] **Step 4: Run tests**

Run: `zig build test`
Expected: PASS.

- [ ] **Step 5: Commit closing GAP-0015 Style A**

```bash
git add src/schema.zig
git commit -m "feat(schema): close GAP-0015 -- runtime schema validation"
```

---

## Task 9: Decode test for flat struct (Style B)

**Files:**

- Modify: `src/schema.zig`

- [ ] **Step 1: Write failing test**

Append to `src/schema.zig`:

```zig
test "decode: flat struct with string and u16" {
    const alloc = std.testing.allocator;
    const toml = @import("toml.zig");

    const src =
        \\name = "svc"
        \\port = 8080
    ;
    var doc = try toml.parse(alloc, src, .{});
    defer doc.deinit();

    const Config = struct {
        name: []const u8,
        port: u16,
    };

    var decoded = try decode(Config, alloc, &doc);
    defer decoded.deinit();
    try std.testing.expectEqualStrings("svc", decoded.value.name);
    try std.testing.expectEqual(@as(u16, 8080), decoded.value.port);
}
```

- [ ] **Step 2: Run to verify failure**

Run: `zig build test`
Expected: Compile error — `decode` not declared.

- [ ] **Step 3: Implement decode scaffolding and scalar field mapping**

Insert in `src/schema.zig`:

```zig
pub const DecodeError = error{
    TypeMismatch,
    MissingField,
    IntegerOverflow,
    UnsupportedType,
    OutOfMemory,
};

/// Owning wrapper returned by `decode`. Holds an ArenaAllocator that owns
/// every slice/string copied out of the `Document`. The caller's
/// Document can be freed independently.
pub fn Decoded(comptime T: type) type {
    return struct {
        const Self = @This();
        value: T,
        arena: std.heap.ArenaAllocator,

        pub fn deinit(self: *Self) void {
            self.arena.deinit();
        }
    };
}

/// Decode a TOML `Document` into a user-defined Zig type `T`. `T` must be
/// a struct composed of: `[]const u8`, integer, float, bool, optional
/// versions of the above, nested structs, or slices of the above.
pub fn decode(
    comptime T: type,
    alloc: Allocator,
    document: *const Document,
) DecodeError!Decoded(T) {
    var arena = std.heap.ArenaAllocator.init(alloc);
    errdefer arena.deinit();
    const arena_alloc = arena.allocator();

    const value = try decodeValue(T, arena_alloc, document.root);
    return .{ .value = value, .arena = arena };
}

fn decodeValue(
    comptime T: type,
    alloc: Allocator,
    value: *const Value,
) DecodeError!T {
    const info = @typeInfo(T);
    switch (info) {
        .@"struct" => return try decodeStruct(T, alloc, value),
        .int => return try decodeInt(T, value),
        .float => |_| {
            if (value.* != .float and value.* != .integer) return DecodeError.TypeMismatch;
            const f: f64 = if (value.* == .float) value.float else @floatFromInt(value.integer);
            return @as(T, @floatCast(f));
        },
        .bool => {
            if (value.* != .bool) return DecodeError.TypeMismatch;
            return value.bool;
        },
        .pointer => |p| {
            if (p.size == .slice and p.child == u8 and p.is_const) {
                if (value.* != .string) return DecodeError.TypeMismatch;
                return try alloc.dupe(u8, value.string);
            }
            if (p.size == .slice) {
                if (value.* != .array) return DecodeError.TypeMismatch;
                const items = value.array.items;
                const out = try alloc.alloc(p.child, items.len);
                for (items, 0..) |el, i| {
                    out[i] = try decodeValue(p.child, alloc, el);
                }
                return out;
            }
            return DecodeError.UnsupportedType;
        },
        .optional => |o| {
            // The caller of decodeStruct handles presence/absence; this branch
            // decodes a present non-null optional.
            return @as(T, try decodeValue(o.child, alloc, value));
        },
        else => return DecodeError.UnsupportedType,
    }
}

fn decodeInt(
    comptime T: type,
    value: *const Value,
) DecodeError!T {
    if (value.* != .integer) return DecodeError.TypeMismatch;
    const n = value.integer;
    const max_t: i128 = std.math.maxInt(T);
    const min_t: i128 = std.math.minInt(T);
    const widened: i128 = n;
    if (widened < min_t or widened > max_t) return DecodeError.IntegerOverflow;
    return @intCast(n);
}

fn decodeStruct(
    comptime T: type,
    alloc: Allocator,
    value: *const Value,
) DecodeError!T {
    if (value.* != .table) return DecodeError.TypeMismatch;
    var out: T = undefined;
    inline for (@typeInfo(T).@"struct".fields) |field| {
        const child = value.get(field.name);
        const fi = @typeInfo(field.type);
        if (child == null) {
            if (fi == .optional) {
                @field(out, field.name) = null;
                continue;
            }
            if (field.default_value_ptr) |dv_ptr| {
                const dv: *const field.type = @ptrCast(@alignCast(dv_ptr));
                @field(out, field.name) = dv.*;
                continue;
            }
            return DecodeError.MissingField;
        }
        if (fi == .optional) {
            @field(out, field.name) = try decodeValue(fi.optional.child, alloc, child.?);
        } else {
            @field(out, field.name) = try decodeValue(field.type, alloc, child.?);
        }
    }
    return out;
}
```

- [ ] **Step 4: Run tests**

Run: `zig build test`
Expected: PASS — the new `decode: flat struct` test is green.

- [ ] **Step 5: Commit**

```bash
git add src/schema.zig
git commit -m "feat(decode): flat struct decoding via @typeInfo"
```

---

## Task 10: Decode nested struct, slice of strings, optional

**Files:**

- Modify: `src/schema.zig`

- [ ] **Step 1: Write failing tests**

Append to `src/schema.zig`:

```zig
test "decode: nested struct" {
    const alloc = std.testing.allocator;
    const toml = @import("toml.zig");

    const src =
        \\[server]
        \\host = "localhost"
        \\port = 8080
    ;
    var doc = try toml.parse(alloc, src, .{});
    defer doc.deinit();

    const Server = struct {
        host: []const u8,
        port: u16,
    };
    const Config = struct {
        server: Server,
    };

    var decoded = try decode(Config, alloc, &doc);
    defer decoded.deinit();
    try std.testing.expectEqualStrings("localhost", decoded.value.server.host);
    try std.testing.expectEqual(@as(u16, 8080), decoded.value.server.port);
}

test "decode: slice of strings" {
    const alloc = std.testing.allocator;
    const toml = @import("toml.zig");

    const src = "tags = [\"a\", \"b\", \"c\"]\n";
    var doc = try toml.parse(alloc, src, .{});
    defer doc.deinit();

    const Config = struct {
        tags: [][]const u8,
    };

    var decoded = try decode(Config, alloc, &doc);
    defer decoded.deinit();
    try std.testing.expectEqual(@as(usize, 3), decoded.value.tags.len);
    try std.testing.expectEqualStrings("a", decoded.value.tags[0]);
    try std.testing.expectEqualStrings("b", decoded.value.tags[1]);
    try std.testing.expectEqualStrings("c", decoded.value.tags[2]);
}

test "decode: optional absent field becomes null" {
    const alloc = std.testing.allocator;
    const toml = @import("toml.zig");

    const src = "name = \"svc\"\n";
    var doc = try toml.parse(alloc, src, .{});
    defer doc.deinit();

    const Config = struct {
        name: []const u8,
        port: ?u16,
    };

    var decoded = try decode(Config, alloc, &doc);
    defer decoded.deinit();
    try std.testing.expectEqualStrings("svc", decoded.value.name);
    try std.testing.expect(decoded.value.port == null);
}

test "decode: optional present field is decoded" {
    const alloc = std.testing.allocator;
    const toml = @import("toml.zig");

    const src =
        \\name = "svc"
        \\port = 443
    ;
    var doc = try toml.parse(alloc, src, .{});
    defer doc.deinit();

    const Config = struct {
        name: []const u8,
        port: ?u16,
    };

    var decoded = try decode(Config, alloc, &doc);
    defer decoded.deinit();
    try std.testing.expect(decoded.value.port != null);
    try std.testing.expectEqual(@as(u16, 443), decoded.value.port.?);
}

test "decode: struct field with default used when absent" {
    const alloc = std.testing.allocator;
    const toml = @import("toml.zig");

    const src = "name = \"svc\"\n";
    var doc = try toml.parse(alloc, src, .{});
    defer doc.deinit();

    const Config = struct {
        name: []const u8,
        port: u16 = 8080,
    };

    var decoded = try decode(Config, alloc, &doc);
    defer decoded.deinit();
    try std.testing.expectEqual(@as(u16, 8080), decoded.value.port);
}
```

- [ ] **Step 2: Run tests**

Run: `zig build test`
Expected: PASS — the `decodeStruct`/`decodeValue` implementation from Task 9 already handles nested structs, slices of non-u8, optional, and default values. If any case fails, fix the code path now rather than in later tasks.

- [ ] **Step 3: Commit**

```bash
git add src/schema.zig
git commit -m "feat(decode): nested structs, slices, optionals, defaults"
```

---

## Task 11: Decode error paths — missing field, type mismatch, overflow

**Files:**

- Modify: `src/schema.zig`

- [ ] **Step 1: Write failing tests**

Append to `src/schema.zig`:

```zig
test "decode error: missing required field" {
    const alloc = std.testing.allocator;
    const toml = @import("toml.zig");

    const src = "name = \"svc\"\n";
    var doc = try toml.parse(alloc, src, .{});
    defer doc.deinit();

    const Config = struct {
        name: []const u8,
        port: u16,
    };

    try std.testing.expectError(DecodeError.MissingField, decode(Config, alloc, &doc));
}

test "decode error: type mismatch" {
    const alloc = std.testing.allocator;
    const toml = @import("toml.zig");

    const src =
        \\name = "svc"
        \\port = "eighty"
    ;
    var doc = try toml.parse(alloc, src, .{});
    defer doc.deinit();

    const Config = struct {
        name: []const u8,
        port: u16,
    };

    try std.testing.expectError(DecodeError.TypeMismatch, decode(Config, alloc, &doc));
}

test "decode error: integer overflow into u8" {
    const alloc = std.testing.allocator;
    const toml = @import("toml.zig");

    const src = "n = 256\n";
    var doc = try toml.parse(alloc, src, .{});
    defer doc.deinit();

    const Config = struct {
        n: u8,
    };

    try std.testing.expectError(DecodeError.IntegerOverflow, decode(Config, alloc, &doc));
}

test "decode error: negative into unsigned" {
    const alloc = std.testing.allocator;
    const toml = @import("toml.zig");

    const src = "n = -1\n";
    var doc = try toml.parse(alloc, src, .{});
    defer doc.deinit();

    const Config = struct {
        n: u16,
    };

    try std.testing.expectError(DecodeError.IntegerOverflow, decode(Config, alloc, &doc));
}
```

- [ ] **Step 2: Run tests**

Run: `zig build test`
Expected: PASS — `decodeStruct` and `decodeInt` from Task 9 already produce `MissingField`, `TypeMismatch`, and `IntegerOverflow`. Fix any code path that returns the wrong error.

- [ ] **Step 3: Commit**

```bash
git add src/schema.zig
git commit -m "test(decode): exercise MissingField, TypeMismatch, IntegerOverflow"
```

---

## Task 12: Re-export decode from library root

**Files:**

- Modify: `src/toml.zig`

- [ ] **Step 1: Write failing test**

Append to `src/toml.zig` (below the existing tests):

```zig
test "re-exported toml.decode decodes a struct" {
    const alloc = std.testing.allocator;
    const src =
        \\name = "svc"
        \\port = 443
    ;
    var doc = try parse(alloc, src, .{});
    defer doc.deinit();

    const Config = struct {
        name: []const u8,
        port: u16,
    };

    var decoded = try decode(Config, alloc, &doc);
    defer decoded.deinit();
    try std.testing.expectEqualStrings("svc", decoded.value.name);
    try std.testing.expectEqual(@as(u16, 443), decoded.value.port);
}
```

- [ ] **Step 2: Run to verify failure**

Run: `zig build test`
Expected: Compile error — `decode` not reachable via `src/toml.zig` namespace.

- [ ] **Step 3: Re-export decode and companion types**

Edit `src/toml.zig`. Below the `pub const schema = @import("schema.zig");` line added in Task 1, add the exact block below. The Style A `Schema` wrapper is re-exported as `SchemaValidator` so it does not collide with `SchemaNode`:

```zig
pub const decode = schema.decode;
pub const Decoded = schema.Decoded;
pub const DecodeError = schema.DecodeError;
pub const SchemaValidator = schema.Schema;
pub const SchemaNode = schema.SchemaNode;
pub const FieldSchema = schema.FieldSchema;
pub const Diagnostic = schema.Diagnostic;
pub const DiagnosticCode = schema.DiagnosticCode;
pub const DiagnosticList = schema.DiagnosticList;
```

- [ ] **Step 4: Run tests**

Run: `zig build test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/toml.zig
git commit -m "feat(decode): comptime-typed decoder"
```

---

## Task 13: Add examples/schema_validation.zig

**Files:**

- Create: `examples/schema_validation.zig`

- [ ] **Step 1: Create the example**

Write `examples/schema_validation.zig`:

```zig
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

    try styleA(alloc, &doc);
    try styleB(alloc, &doc);
}

fn styleA(alloc: std.mem.Allocator, doc: *const toml.Document) !void {
    const name = toml.SchemaNode.string(.{ .min_len = 1 });
    const port = toml.SchemaNode.integer(.{ .min = 1, .max = 65535 });
    const tag_elem = toml.SchemaNode.string(.{});
    const tags = toml.SchemaNode.array(&tag_elem, .{});
    const url = toml.SchemaNode.string(.{});
    const max_conn = toml.SchemaNode.integer(.{ .min = 1 });
    const db_fields = [_]toml.FieldSchema{
        .{ .name = "url", .schema = &url, .required = true },
        .{ .name = "max_connections", .schema = &max_conn, .required = true },
    };
    const db = toml.SchemaNode.object(&db_fields, .strict);

    const fields = [_]toml.FieldSchema{
        .{ .name = "name", .schema = &name, .required = true },
        .{ .name = "port", .schema = &port, .required = true },
        .{ .name = "tags", .schema = &tags, .required = false },
        .{ .name = "database", .schema = &db, .required = true },
    };
    const validator = toml.SchemaValidator{ .root = toml.SchemaNode.object(&fields, .strict) };

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
```

- [ ] **Step 2: Sanity-check the main library still compiles**

Run: `zig build check`
Expected: No compile errors.

If `build.zig` wires examples as test or run steps (it does not today — examples are illustrative only), the example would be compiled automatically. If not, the file lives alongside existing `examples/*.zig` for documentation purposes only.

- [ ] **Step 3: Commit**

```bash
git add examples/schema_validation.zig
git commit -m "docs(schema): add schema validation example"
```

---

## Task 14: Document schema in docs/API.md

**Files:**

- Modify: `docs/API.md`

- [ ] **Step 1: Append the "Schema Validation" section**

Add a new `## Schema Validation` section at the end of `docs/API.md`. Include the following content verbatim:

````markdown
## Schema Validation

Since 0.2.0, zigtoml ships two validation styles in `toml.schema`.

### A. Runtime schema

Build a `SchemaNode` tree and validate a parsed `*const Value` against it:

```zig
const toml = @import("toml");

const port = toml.SchemaNode.integer(.{ .min = 1, .max = 65535 });
const name = toml.SchemaNode.string(.{ .min_len = 1 });
const fields = [_]toml.FieldSchema{
    .{ .name = "name", .schema = &name, .required = true },
    .{ .name = "port", .schema = &port, .required = true },
};
const validator = toml.SchemaValidator{
    .root = toml.SchemaNode.object(&fields, .strict),
};

var diags = toml.DiagnosticList.init(alloc);
defer diags.deinit();
try validator.validate(doc.root, &diags);
```

On failure `validate` returns `SchemaError.SchemaViolation` and
`diags.items.items` contains one `Diagnostic` per violation with a dotted
`path` (e.g. `server.port`, `tags[2]`), `code`, and `message`.

`SchemaNode` variants: `string`, `integer`, `float`, `boolean`, `datetime`,
`datetime_local`, `date_local`, `time_local`, `array`, `object`, `one_of`.

### B. Comptime-typed decoding

Reflects on a user struct at compile time and allocates the result in a
caller-owned arena:

```zig
const Config = struct {
    name: []const u8,
    port: u16,
    tags: ?[][]const u8,
};

var decoded = try toml.decode(Config, alloc, &doc);
defer decoded.deinit();
std.debug.print("port={d}\n", .{decoded.value.port});
```

Supported field types: integers (bounds-checked), floats, bool,
`[]const u8`, slices of any supported element type, nested structs,
optional of any supported type. Missing optional fields become `null`;
missing required fields return `DecodeError.MissingField`.

Errors: `DecodeError = error{ TypeMismatch, MissingField, IntegerOverflow,
UnsupportedType, OutOfMemory }`.
````

- [ ] **Step 2: Commit**

```bash
git add docs/API.md
git commit -m "docs(api): document schema validation and typed decoder"
```

---

## Task 15: Update CHANGELOG and gap analysis

**Files:**

- Modify: `CHANGELOG.md`
- Modify: `docs/GAP_ANALYSIS.md`
- Modify: `docs/GAP_ANALYSIS_RESOLVED.md`

- [ ] **Step 1: Add CHANGELOG entry**

Prepend under the `Unreleased` / latest section in `CHANGELOG.md`:

```markdown
### Added

- Schema validation module (`src/schema.zig`) providing both runtime
  `SchemaValidator` with `DiagnosticList` and a comptime-reflective
  `toml.decode(T, alloc, &doc)`. Closes GAP-0015.
```

- [ ] **Step 2: Move GAP-0015 to the resolved doc**

In `docs/GAP_ANALYSIS.md`, delete the `### GAP-0015: Schema validation module` block (lines 172–179 at time of plan authoring). In `docs/GAP_ANALYSIS_RESOLVED.md`, append:

```markdown
### GAP-0015: Schema validation module (RESOLVED)

- **Issue:** [#13](https://gitlab.com/devnw/zig/toml/-/issues/13)
- **Resolved by:** `src/schema.zig` providing runtime `SchemaValidator`
  and comptime `toml.decode(T, alloc, &doc)`.
- **Tests:** See `src/schema.zig` test block and
  `examples/schema_validation.zig`.
```

- [ ] **Step 3: Verify docs still build / render**

Run: `zig build check && zig build test`
Expected: PASS — no code regressions.

- [ ] **Step 4: Commit**

```bash
git add CHANGELOG.md docs/GAP_ANALYSIS.md docs/GAP_ANALYSIS_RESOLVED.md
git commit -m "docs: record GAP-0015 closure in changelog and gap analysis"
```

---

## Task 16: Self-review and final verification

**Files:** (no edits unless issues found)

- [ ] **Step 1: Run the full test suite**

Run: `zig build test`
Expected: All unit + acceptance + fuzz smoke tests pass.

- [ ] **Step 2: Run check and formatting**

Run: `zig build check`
Expected: No compile errors.

Run: `zig fmt --check src/schema.zig src/toml.zig examples/schema_validation.zig`
Expected: No diffs. If any diffs appear, do NOT amend the previous commit — create a new commit:

```bash
zig fmt src/schema.zig src/toml.zig examples/schema_validation.zig
git add src/schema.zig src/toml.zig examples/schema_validation.zig
git commit -m "style: zig fmt schema module and example"
```

- [ ] **Step 3: Grep for placeholders**

Run Grep for `TODO`, `TBD`, `implement later`, and `fill in` inside `src/schema.zig` and `examples/schema_validation.zig`.
Expected: zero matches.

- [ ] **Step 4: Trace diagnostics paths by hand**

Open the example and trace both styles for a small invalid document. Confirm:

- Paths use `a.b.c` for nested tables and `a[N]` for array elements.
- `type_mismatch` diagnostics always populate both `expected` and `got`.
- `missing_required_field` leaves `expected` and `got` as `null`.

- [ ] **Step 5: Log completion**

If all checks pass, note in the PR description that GAP-0015 is closed by the commits in this plan.

---

## Self-Review Checklist (performed by plan author)

1. **Spec coverage:**
   - Runtime SchemaNode variants (string, integer, float, bool, datetime/datetime_local/date_local/time_local, array, object, one_of) — Tasks 3–8.
   - object with required/unknown strict/lax — Task 5.
   - array with element schema and length bounds — Task 6.
   - Diagnostic with path/expected/got/message — Task 2.
   - comptime `decode(T, alloc, doc)` — Tasks 9–11.
   - nested structs, optional fields, defaults — Task 10.
   - error paths (missing, type mismatch, overflow) — Task 11.
   - examples/schema_validation.zig — Task 13.
   - docs/API.md and CHANGELOG — Tasks 14–15.
   All spec bullets from the sketch map to at least one task.

2. **Placeholder scan:** No "TBD", "implement later", or "similar to" references. Each code-bearing step contains the exact code to type.

3. **Type consistency:**
   - `SchemaNode` constructor aliases (`string`, `integer`, `array`, `object`, `one_of`) are defined once in Task 3 and reused verbatim in Tasks 4–8, 13.
   - `DiagnosticList.append(path, code, expected, got, message)` signature is defined in Task 2 and every caller in Tasks 4–7 uses that exact argument order.
   - `validateNode(node, value, path, diags)` signature is defined in Task 4 and preserved through Tasks 5–8.
   - `decode(T, alloc, &doc)` takes a pointer to `Document` — every test calls it with `&doc` and the signature in Task 9 matches.
   - Re-export name clash between Style A `Schema` and `SchemaNode` is resolved in Task 12 by naming the runtime wrapper `SchemaValidator` at the library root; Style B's `decode` has no clashing public name.

4. **Commit cadence:** Sixteen commits, each one task, each expected to pass `zig build test` independently.

---

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-04-18-08-schema-validation.md`. Two execution options:

1. **Subagent-Driven (recommended)** — dispatch a fresh subagent per task, review between tasks.
2. **Inline Execution** — execute tasks in this session with checkpoints.

Which approach?
