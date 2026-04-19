// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros

//! SAX-style event types for the event-driven TOML parser.
//!
//! Events are emitted in document order by `toml.parseEvents`. See
//! `docs/API.md` (Event API section) for the contract.

const std = @import("std");
const val = @import("value.zig");

pub const Value = val.Value;

/// A single parser event. Slices inside events (e.g. the `key` in
/// `key_value`, the string inside `.table_header`) point at parser-owned
/// storage that is ONLY valid for the duration of the `handleFn` call.
/// Handlers that want to retain a value must copy it.
pub const Event = union(enum) {
    /// Standard table header: `[section]` or `[a.b.c]`.
    /// The slice is the dotted key rendered verbatim (`"a.b.c"`),
    /// with any quoting preserved. Handlers that need the individual
    /// path segments should split on `.` while respecting quoted keys;
    /// a future revision may add a structured variant.
    table_header: []const u8,

    /// Array-of-tables header: `[[items]]`.
    array_of_tables_header: []const u8,

    /// Top-level or in-table key=value pair. The `value` slot carries a
    /// fully decoded scalar for scalar values. For inline tables and
    /// arrays, the handler receives `inline_table_start`/`array_start`
    /// immediately after this event and `value` is null.
    key_value: KeyValue,

    /// Emitted when the parser enters an inline table `{ ... }` that
    /// was introduced by the most recent `key_value`. Paired with
    /// `inline_table_end`.
    inline_table_start,
    inline_table_end,

    /// Emitted when the parser enters a static array `[ ... ]` that
    /// was introduced by the most recent `key_value`. Paired with
    /// `array_end`. Each scalar inside the array is reported via
    /// `array_item`; nested arrays/inline tables emit their own
    /// `array_start`/`inline_table_start` pairs.
    array_start,
    array_end,

    /// A scalar element inside an array. For nested arrays/inline
    /// tables the parser emits their own start/end pairs instead.
    array_item: Value,

    /// Shape of a `key_value` event. For scalar values `.value` is set.
    /// For container values (inline table, array) `.value` is null and
    /// the caller should expect a following container event.
    pub const KeyValue = struct {
        key: []const u8,
        value: ?Value,
    };
};

/// Trait-struct callback -- mirrors the std.mem.Allocator pattern.
/// Callers set `ctx` to their state pointer and `handleFn` to a
/// function that takes that same pointer back.
pub const EventHandler = struct {
    ctx: *anyopaque,
    handleFn: *const fn (ctx: *anyopaque, event: Event) anyerror!void,

    pub fn handle(self: EventHandler, event: Event) anyerror!void {
        return self.handleFn(self.ctx, event);
    }
};

test "Event union tag count is stable" {
    // Pin the variant count so accidental additions trip CI and force
    // the documentation update. Bump the number AND docs/API.md when
    // intentionally adding an event.
    try std.testing.expectEqual(@as(usize, 8), @typeInfo(Event).@"union".fields.len);
}
