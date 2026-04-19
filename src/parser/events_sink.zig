// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros

//! Output-sink dispatch for the shared parser walker.
//!
//! `Parser.parse` installs the `.document` variant and writes into an
//! arena-backed `Value` tree. `parseEvents` installs the `.events`
//! variant and forwards each construct boundary to a user-supplied
//! `EventHandler`. The sink helpers collapse to a no-op for whichever
//! mode does not need the call, so the same walker drives both.
//!
//! Extracted from `src/parser.zig` (Q-17) along with `renderKeyPath`
//! for rendering dotted-key paths into a single slice the event stream
//! can carry without copying.

const std = @import("std");
const Allocator = std.mem.Allocator;

const val = @import("../value.zig");
const Value = val.Value;

const events_mod = @import("../events.zig");
pub const Event = events_mod.Event;
pub const EventHandler = events_mod.EventHandler;

// Forward-declared to break the import cycle. `Parser` is defined in
// `../parser.zig`; we only need its pointer here.
const Parser = @import("../parser.zig").Parser;

/// Output sink for the shared recursive-descent walker. `parse` uses
/// `.document` (write into an arena-backed Value tree). `parseEvents`
/// uses `.events` (dispatch Event values to the caller).
///
/// Every sink method takes borrowed slices -- the caller must copy
/// anything it needs past the call. For the document sink the parser
/// already dupes into the arena; for the event sink the user is told
/// in the Event docstring that slices only live for the handleFn call.
pub const ParseSink = union(enum) {
    document: DocSink,
    events: EventSink,

    pub const DocSink = struct {
        alloc: Allocator,
        root: *Value,
    };

    pub const EventSink = struct {
        handler: EventHandler,
    };
};

pub fn emitTableHeader(self: *Parser, rendered_path: []const u8, is_array_of_tables: bool) !void {
    switch (self.sink) {
        .document => {}, // document sink tracks tables via resolveTablePath
        .events => |es| {
            const ev: Event = if (is_array_of_tables)
                .{ .array_of_tables_header = rendered_path }
            else
                .{ .table_header = rendered_path };
            try es.handler.handle(ev);
        },
    }
}

pub fn emitKeyValueScalar(self: *Parser, rendered_key: []const u8, value: Value) !void {
    switch (self.sink) {
        .document => {}, // document sink writes via val.tableSet in caller
        .events => |es| {
            try es.handler.handle(.{ .key_value = .{ .key = rendered_key, .value = value } });
        },
    }
}

pub fn emitKeyValueContainer(self: *Parser, rendered_key: []const u8) !void {
    switch (self.sink) {
        .document => {},
        .events => |es| {
            try es.handler.handle(.{ .key_value = .{ .key = rendered_key, .value = null } });
        },
    }
}

pub fn emitSimple(self: *Parser, event: Event) !void {
    switch (self.sink) {
        .document => {},
        .events => |es| {
            try es.handler.handle(event);
        },
    }
}

/// Join dotted-key path segments into a single `a.b.c` slice. The
/// returned slice is allocated from `alloc` and is therefore stable
/// for as long as that allocator survives (document arena for
/// `parse`, throwaway arena for `parseEvents`). Used to render the
/// slice carried by `.table_header` / `.array_of_tables_header`.
pub fn renderKeyPath(alloc: Allocator, parts: []const []const u8) ![]const u8 {
    if (parts.len == 0) return "";
    var total: usize = 0;
    for (parts) |p| total += p.len;
    total += parts.len - 1; // dots
    var out = try alloc.alloc(u8, total);
    var i: usize = 0;
    for (parts, 0..) |p, idx| {
        if (idx != 0) {
            out[i] = '.';
            i += 1;
        }
        @memcpy(out[i .. i + p.len], p);
        i += p.len;
    }
    return out;
}
