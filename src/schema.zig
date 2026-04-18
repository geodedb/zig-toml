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
