// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! RFC 3339 datetime parsing for TOML.
//!
//! This module owns the four datetime parsers (offset datetime, local
//! datetime, local date, local time) and their validators. It holds no
//! state; all error reporting is delegated back to the caller via the
//! `*Parser` argument, which owns the error channel and position.

const std = @import("std");
const val = @import("../value.zig");
const err = @import("../error.zig");
const ErrorCode = err.ErrorCode;

// Forward-declared to break the import cycle. `Parser` is defined in
// `../parser.zig`; we only need its pointer here.
const Parser = @import("../parser.zig").Parser;

// ---------------------------------------------------------------------------
// Shared helpers
// ---------------------------------------------------------------------------

const DateParts = struct {
    year: u16,
    month: u8,
    day: u8,
    consumed: usize,
};

const TimeParts = struct {
    hour: u8,
    minute: u8,
    second: u8,
    nanosecond: u32,
    consumed: usize,
};

const OffsetParts = struct {
    /// Signed minutes east of UTC. `Z`/`z` → 0. `null` means no offset
    /// was present at `idx` (callers must decide if that is valid).
    offset_minutes: ?i16,
    consumed: usize,
};

/// Parses `YYYY-MM-DD` starting at `raw[idx]`. Always consumes 10
/// characters on success. Validates that the resulting date exists in
/// the proleptic Gregorian calendar.
fn parseDateParts(self: *Parser, raw: []const u8, idx: usize) !DateParts {
    var i: usize = idx;

    // APP-01: YYYY-MM-DD needs exactly 10 chars from idx (year raw[i..i+4],
    // month raw[i+5..i+7], day raw[i+8..i+10]). Guard before slicing so a
    // truncated datetime token returns a clean error instead of an
    // out-of-bounds slice (panic in safe modes, OOB read in ReleaseFast).
    if (idx + 10 > raw.len) {
        self.parse_error = err.makeError(.InvalidDateTime, self.current.pos, "truncated date");
        return error.ParseFailed;
    }

    const year = std.fmt.parseInt(u16, raw[i .. i + 4], 10) catch {
        self.parse_error = err.makeError(.InvalidDateTime, self.current.pos, "invalid year");
        return error.ParseFailed;
    };
    i += 5; // skip YYYY-

    const month = std.fmt.parseInt(u8, raw[i .. i + 2], 10) catch {
        self.parse_error = err.makeError(.InvalidDateTime, self.current.pos, "invalid month");
        return error.ParseFailed;
    };
    i += 3; // skip MM-

    const day = std.fmt.parseInt(u8, raw[i .. i + 2], 10) catch {
        self.parse_error = err.makeError(.InvalidDateTime, self.current.pos, "invalid day");
        return error.ParseFailed;
    };
    i += 2; // skip DD

    return .{ .year = year, .month = month, .day = day, .consumed = i - idx };
}

/// Parses `HH:MM[:SS[.frac]]` starting at `raw[idx]`. If the `:SS` is
/// absent and `require_seconds_v1_0` is true, reports
/// `LocalTimeSecondsOmittedNotAllowed` in v1.0 mode. Fractional
/// seconds are normalised to nanoseconds (truncated beyond 9 digits).
fn parseTimeParts(
    self: *Parser,
    raw: []const u8,
    idx: usize,
    require_seconds_v1_0: bool,
) !TimeParts {
    var i: usize = idx;

    // APP-01: HH:MM needs 5 chars from idx (hour raw[i..i+2], minute
    // raw[i+3..i+5]). The optional :SS / .frac tails below already
    // bounds-check; guard the fixed head here.
    if (idx + 5 > raw.len) {
        self.parse_error = err.makeError(.InvalidDateTime, self.current.pos, "truncated time");
        return error.ParseFailed;
    }

    const hour = std.fmt.parseInt(u8, raw[i .. i + 2], 10) catch {
        self.parse_error = err.makeError(.InvalidDateTime, self.current.pos, "invalid hour");
        return error.ParseFailed;
    };
    i += 3; // skip HH:

    const minute = std.fmt.parseInt(u8, raw[i .. i + 2], 10) catch {
        self.parse_error = err.makeError(.InvalidDateTime, self.current.pos, "invalid minute");
        return error.ParseFailed;
    };
    i += 2;

    var second: u8 = 0;

    if (i < raw.len and raw[i] == ':') {
        i += 1;
        if (i + 2 > raw.len) {
            self.parse_error = err.makeError(.InvalidDateTime, self.current.pos, "invalid time format");
            return error.ParseFailed;
        }
        second = std.fmt.parseInt(u8, raw[i .. i + 2], 10) catch {
            self.parse_error = err.makeError(.InvalidDateTime, self.current.pos, "invalid second");
            return error.ParseFailed;
        };
        i += 2;
    } else if (require_seconds_v1_0 and self.options.version == .v1_0_0) {
        self.parse_error = err.makeError(.LocalTimeSecondsOmittedNotAllowed, self.current.pos, "seconds required in time for TOML v1.0");
        return error.ParseFailed;
    }

    var nanosecond: u32 = 0;

    if (i < raw.len and raw[i] == '.') {
        i += 1;
        const frac_start = i;
        while (i < raw.len and raw[i] >= '0' and raw[i] <= '9') {
            i += 1;
        }
        const frac_str = raw[frac_start..i];
        if (frac_str.len == 0) {
            self.parse_error = err.makeError(.InvalidDateTime, self.current.pos, "invalid fractional seconds");
            return error.ParseFailed;
        }
        var frac: u32 = std.fmt.parseInt(u32, frac_str, 10) catch {
            self.parse_error = err.makeError(.InvalidDateTime, self.current.pos, "invalid fractional seconds");
            return error.ParseFailed;
        };
        var digits = frac_str.len;
        while (digits < 9) : (digits += 1) frac *= 10;
        while (digits > 9) : (digits -= 1) frac /= 10;
        nanosecond = frac;
    }

    return .{
        .hour = hour,
        .minute = minute,
        .second = second,
        .nanosecond = nanosecond,
        .consumed = i - idx,
    };
}

/// Parses `Z`, `z`, or `±HH:MM` starting at `raw[idx]`. Returns
/// `offset_minutes == null` (consumed == 0) if no offset marker is
/// present — callers decide whether that is acceptable.
fn parseOffset(self: *Parser, raw: []const u8, idx: usize) !OffsetParts {
    if (idx >= raw.len) {
        return .{ .offset_minutes = null, .consumed = 0 };
    }
    const c = raw[idx];
    if (c == 'Z' or c == 'z') {
        return .{ .offset_minutes = 0, .consumed = 1 };
    }
    if (c != '+' and c != '-') {
        return .{ .offset_minutes = null, .consumed = 0 };
    }
    const sign: i16 = if (c == '-') -1 else 1;
    var i: usize = idx + 1;
    if (i + 5 > raw.len) {
        self.parse_error = err.makeError(.InvalidDateTime, self.current.pos, "invalid timezone offset");
        return error.ParseFailed;
    }
    const hours = std.fmt.parseInt(i16, raw[i .. i + 2], 10) catch {
        self.parse_error = err.makeError(.InvalidDateTime, self.current.pos, "invalid timezone hours");
        return error.ParseFailed;
    };
    i += 3; // skip HH:
    const mins = std.fmt.parseInt(i16, raw[i .. i + 2], 10) catch {
        self.parse_error = err.makeError(.InvalidDateTime, self.current.pos, "invalid timezone minutes");
        return error.ParseFailed;
    };
    i += 2;
    if (!isValidOffset(hours, mins)) {
        self.parse_error = err.makeError(.InvalidDateTime, self.current.pos, "invalid timezone offset");
        return error.ParseFailed;
    }
    return .{ .offset_minutes = sign * (hours * 60 + mins), .consumed = i - idx };
}

// ---------------------------------------------------------------------------
// Public parsers (thin compositions)
// ---------------------------------------------------------------------------

pub fn parseDateTime(self: *Parser, raw: []const u8) !val.DateTime {
    // Format: YYYY-MM-DDTHH:MM:SS[.frac](Z|[+-]HH:MM)
    const d = try parseDateParts(self, raw, 0);
    // The date helper already consumed `YYYY-MM-DD`; the separator
    // between date and time (T/t/space) is at raw[d.consumed]. The
    // original body advanced past it via `i += 3` after day; we
    // replicate that by starting time parsing at d.consumed + 1.
    const t = try parseTimeParts(self, raw, d.consumed + 1, true);
    const off_idx = d.consumed + 1 + t.consumed;
    const o = try parseOffset(self, raw, off_idx);

    if (!isValidDate(d.year, d.month, d.day)) {
        self.parse_error = err.makeError(.InvalidDateTime, self.current.pos, "invalid date value");
        return error.ParseFailed;
    }
    if (!isValidTime(t.hour, t.minute, t.second)) {
        self.parse_error = err.makeError(.InvalidDateTime, self.current.pos, "invalid time value");
        return error.ParseFailed;
    }

    return .{
        .year = d.year,
        .month = d.month,
        .day = d.day,
        .hour = t.hour,
        .minute = t.minute,
        .second = t.second,
        .nanosecond = t.nanosecond,
        .offset_minutes = o.offset_minutes,
    };
}

pub fn parseDateTimeLocal(self: *Parser, raw: []const u8) !val.DateTimeLocal {
    const d = try parseDateParts(self, raw, 0);
    // Preserve original behaviour: parseDateTimeLocal does NOT emit
    // LocalTimeSecondsOmittedNotAllowed in v1.0 when seconds are
    // omitted (unlike parseDateTime / parseTimeLocal).
    const t = try parseTimeParts(self, raw, d.consumed + 1, false);

    if (!isValidDate(d.year, d.month, d.day)) {
        self.parse_error = err.makeError(.InvalidDateTime, self.current.pos, "invalid date value");
        return error.ParseFailed;
    }
    if (!isValidTime(t.hour, t.minute, t.second)) {
        self.parse_error = err.makeError(.InvalidDateTime, self.current.pos, "invalid time value");
        return error.ParseFailed;
    }

    return .{
        .year = d.year,
        .month = d.month,
        .day = d.day,
        .hour = t.hour,
        .minute = t.minute,
        .second = t.second,
        .nanosecond = t.nanosecond,
    };
}

pub fn parseDateLocal(self: *Parser, raw: []const u8) !val.DateLocal {
    // Validate length: YYYY-MM-DD is exactly 10 characters
    if (raw.len != 10) {
        self.parse_error = err.makeError(.InvalidDateTime, self.current.pos, "invalid date format");
        return error.ParseFailed;
    }

    const d = try parseDateParts(self, raw, 0);

    if (!isValidDate(d.year, d.month, d.day)) {
        self.parse_error = err.makeError(.InvalidDateTime, self.current.pos, "invalid date value");
        return error.ParseFailed;
    }

    return .{ .year = d.year, .month = d.month, .day = d.day };
}

pub fn parseTimeLocal(self: *Parser, raw: []const u8) !val.TimeLocal {
    // Minimum length is 5 for HH:MM
    if (raw.len < 5) {
        self.parse_error = err.makeError(.InvalidDateTime, self.current.pos, "invalid time format");
        return error.ParseFailed;
    }

    const t = try parseTimeParts(self, raw, 0, true);

    if (!isValidTime(t.hour, t.minute, t.second)) {
        self.parse_error = err.makeError(.InvalidDateTime, self.current.pos, "invalid time value");
        return error.ParseFailed;
    }

    return .{
        .hour = t.hour,
        .minute = t.minute,
        .second = t.second,
        .nanosecond = t.nanosecond,
    };
}

// ---------------------------------------------------------------------------
// Validators
// ---------------------------------------------------------------------------

pub fn isLeapYear(year: u16) bool {
    return (year % 4 == 0 and year % 100 != 0) or (year % 400 == 0);
}

pub fn daysInMonth(year: u16, month: u8) u8 {
    const days = [_]u8{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    if (month < 1 or month > 12) return 0;
    if (month == 2 and isLeapYear(year)) return 29;
    return days[month - 1];
}

pub fn isValidDate(year: u16, month: u8, day: u8) bool {
    if (month < 1 or month > 12) return false;
    if (day < 1) return false;
    return day <= daysInMonth(year, month);
}

pub fn isValidTime(hour: u8, minute: u8, second: u8) bool {
    return hour <= 23 and minute <= 59 and second <= 59;
}

pub fn isValidOffset(offset_hour: i16, offset_minute: i16) bool {
    // Offset hours -23 to +23, minutes 0-59
    const abs_hour = if (offset_hour < 0) -offset_hour else offset_hour;
    return abs_hour <= 23 and offset_minute >= 0 and offset_minute <= 59;
}
