// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros

//! Coverage-guided fuzz harness for `toml.parseEvents`.
//!
//! S-15: the SAX-style `parseEvents` path dispatches every lexer token
//! through a caller-supplied `EventHandler` callback, using a throwaway
//! arena that is destroyed when emission finishes. This is structurally
//! distinct from the Document-materializing `parseWithError` path --
//! callback-lifetime bugs, missed emission on error, and sink-state
//! desync are unique to this harness's surface.

const std = @import("std");
const toml = @import("toml");

const CountCtx = struct {
    events: usize = 0,

    fn handle(ctx: *anyopaque, event: toml.Event) anyerror!void {
        _ = event;
        const self: *CountCtx = @ptrCast(@alignCast(ctx));
        self.events += 1;
    }
};

fn testEventsOne(_: void, smith: *std.testing.Smith) !void {
    @disableInstrumentation();

    var buf: [4096]u8 = undefined;
    const len = smith.sliceWeightedBytes(buf[0..], &.{
        .rangeAtMost(u8, 0x00, 0xff, 1),
        .rangeAtMost(u8, 0x20, 0x7e, 4),
        .value(u8, '=', 4),
        .value(u8, '"', 3),
        .value(u8, '[', 2),
        .value(u8, ']', 2),
        .value(u8, '.', 2),
        .value(u8, '\n', 3),
        .value(u8, '#', 1),
    });
    const input = buf[0..len];

    const alloc = std.testing.allocator;
    var ctx = CountCtx{};
    const handler = toml.EventHandler{
        .ctx = &ctx,
        .handleFn = CountCtx.handle,
    };
    toml.parseEvents(alloc, input, handler, .{}) catch return;
    // The event count itself isn't meaningful under random bytes; the
    // property being fuzzed is no panic, no UB, no leak.
}

test "fuzz parseEvents does not crash" {
    try std.testing.fuzz({}, testEventsOne, .{});
}
