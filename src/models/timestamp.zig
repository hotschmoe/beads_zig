//! RFC3339 timestamp utilities for JSONL compatibility.
//!
//! Timestamps are stored internally as Unix epoch seconds (i64) but serialized
//! to JSON as RFC3339 UTC strings for JSONL export compatibility with beads_rust.
//!
//! Example formats:
//! - "2024-01-29T15:30:00Z" (UTC with Z suffix)
//! - "2024-01-29T15:30:00+00:00" (UTC with explicit offset)
//! - "2024-01-29T15:30:00.123Z" (with fractional seconds, ignored on parse)
//! - "2024-01-29T15:30:00-05:00" (with timezone offset)

const std = @import("std");

pub const TimestampError = error{
    InvalidFormat,
    InvalidDate,
    InvalidTime,
    InvalidTimezone,
    BufferTooSmall,
};

/// RFC3339 timestamp length: "YYYY-MM-DDTHH:MM:SSZ" = 20 chars
pub const RFC3339_LEN: usize = 20;

/// Minimum buffer size for formatRfc3339
pub const RFC3339_BUFFER_SIZE: usize = 25;

/// Parse RFC3339 timestamp string to Unix epoch seconds.
///
/// Accepts formats:
/// - "2024-01-29T15:30:00Z" (UTC)
/// - "2024-01-29T15:30:00+HH:MM" (positive offset)
/// - "2024-01-29T15:30:00-HH:MM" (negative offset)
/// - "2024-01-29T15:30:00.NNNZ" (with fractional seconds, ignored)
///
/// Returns null for invalid input (for compatibility with existing code).
pub fn parseRfc3339(s: []const u8) ?i64 {
    return parseRfc3339Strict(s) catch null;
}

/// Parse RFC3339 timestamp string to Unix epoch seconds.
/// Returns a detailed error for invalid input.
pub fn parseRfc3339Strict(s: []const u8) TimestampError!i64 {
    if (s.len < 20) return TimestampError.InvalidFormat;

    // Parse date: YYYY-MM-DD
    const year = std.fmt.parseInt(i32, s[0..4], 10) catch return TimestampError.InvalidFormat;
    if (s[4] != '-') return TimestampError.InvalidFormat;
    const month = std.fmt.parseInt(u8, s[5..7], 10) catch return TimestampError.InvalidFormat;
    if (s[7] != '-') return TimestampError.InvalidFormat;
    const day = std.fmt.parseInt(u8, s[8..10], 10) catch return TimestampError.InvalidFormat;

    // Validate date components
    if (month < 1 or month > 12) return TimestampError.InvalidDate;
    if (day < 1 or day > daysInMonth(year, month)) return TimestampError.InvalidDate;

    // Parse time separator
    if (s[10] != 'T' and s[10] != 't') return TimestampError.InvalidFormat;

    // Parse time: HH:MM:SS
    const hour = std.fmt.parseInt(u8, s[11..13], 10) catch return TimestampError.InvalidFormat;
    if (s[13] != ':') return TimestampError.InvalidFormat;
    const minute = std.fmt.parseInt(u8, s[14..16], 10) catch return TimestampError.InvalidFormat;
    if (s[16] != ':') return TimestampError.InvalidFormat;
    const second = std.fmt.parseInt(u8, s[17..19], 10) catch return TimestampError.InvalidFormat;

    // Validate time components
    if (hour > 23) return TimestampError.InvalidTime;
    if (minute > 59) return TimestampError.InvalidTime;
    if (second > 59) return TimestampError.InvalidTime;

    // Parse timezone offset
    var pos: usize = 19;

    // Skip fractional seconds if present (.NNN)
    if (pos < s.len and s[pos] == '.') {
        pos += 1;
        while (pos < s.len and std.ascii.isDigit(s[pos])) {
            pos += 1;
        }
    }

    var tz_offset_seconds: i64 = 0;
    if (pos < s.len) {
        const tz_char = s[pos];
        if (tz_char == 'Z' or tz_char == 'z') {
            // UTC, offset stays 0
        } else if (tz_char == '+' or tz_char == '-') {
            // Parse offset: +HH:MM or -HH:MM
            if (s.len < pos + 6) return TimestampError.InvalidTimezone;

            const tz_hour = std.fmt.parseInt(u8, s[pos + 1 .. pos + 3], 10) catch return TimestampError.InvalidTimezone;
            if (s[pos + 3] != ':') return TimestampError.InvalidTimezone;
            const tz_minute = std.fmt.parseInt(u8, s[pos + 4 .. pos + 6], 10) catch return TimestampError.InvalidTimezone;

            if (tz_hour > 23 or tz_minute > 59) return TimestampError.InvalidTimezone;

            tz_offset_seconds = @as(i64, tz_hour) * 3600 + @as(i64, tz_minute) * 60;
            if (tz_char == '-') {
                tz_offset_seconds = -tz_offset_seconds;
            }
        } else {
            return TimestampError.InvalidTimezone;
        }
    } else {
        return TimestampError.InvalidTimezone;
    }

    // Calculate epoch day
    const epoch_day = yearMonthDayToEpochDay(year, month, day);

    // Calculate total seconds
    const day_seconds: i64 = @as(i64, hour) * 3600 + @as(i64, minute) * 60 + @as(i64, second);
    const total_seconds = epoch_day * std.time.epoch.secs_per_day + day_seconds;

    // Apply timezone offset (subtract because we're converting to UTC)
    return total_seconds - tz_offset_seconds;
}

/// Format Unix epoch seconds as RFC3339 string (UTC).
/// Writes to the provided buffer and returns the formatted slice.
///
/// Buffer must be at least RFC3339_BUFFER_SIZE (25) bytes.
pub fn formatRfc3339(timestamp: i64, buffer: []u8) TimestampError![]const u8 {
    if (buffer.len < RFC3339_BUFFER_SIZE) return TimestampError.BufferTooSmall;

    // Handle negative timestamps (before 1970)
    const is_negative = timestamp < 0;
    const abs_secs: u64 = if (is_negative) @intCast(-timestamp) else @intCast(timestamp);

    var year: i32 = undefined;
    var month: u8 = undefined;
    var day: u8 = undefined;
    var hour: u8 = undefined;
    var minute: u8 = undefined;
    var second: u8 = undefined;

    if (is_negative) {
        // For negative timestamps, work backwards from epoch
        const days_back = @divFloor(abs_secs + std.time.epoch.secs_per_day - 1, std.time.epoch.secs_per_day);
        const remaining_secs = days_back * std.time.epoch.secs_per_day - abs_secs;

        second = @intCast(remaining_secs % 60);
        minute = @intCast((remaining_secs / 60) % 60);
        hour = @intCast((remaining_secs / 3600) % 24);

        epochDayToYearMonthDay(-@as(i64, @intCast(days_back)), &year, &month, &day);
    } else {
        const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = abs_secs };
        const day_seconds = epoch_seconds.getDaySeconds();
        const epoch_day = epoch_seconds.getEpochDay();
        const year_day = epoch_day.calculateYearDay();
        const month_day = year_day.calculateMonthDay();

        year = year_day.year;
        month = month_day.month.numeric();
        day = @intCast(@as(u32, month_day.day_index) + 1);
        hour = day_seconds.getHoursIntoDay();
        minute = day_seconds.getMinutesIntoHour();
        second = day_seconds.getSecondsIntoMinute();
    }

    // For years >= 0, cast to unsigned to avoid '+' sign in output
    const year_unsigned: u32 = if (year >= 0) @intCast(year) else 0;
    const formatted = std.fmt.bufPrint(buffer, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        year_unsigned,
        @as(u32, month),
        @as(u32, day),
        @as(u32, hour),
        @as(u32, minute),
        @as(u32, second),
    }) catch unreachable;

    return formatted;
}

/// Format Unix epoch seconds as RFC3339 string (UTC), heap-allocated.
pub fn formatRfc3339Alloc(allocator: std.mem.Allocator, timestamp: i64) ![]u8 {
    var buf: [RFC3339_BUFFER_SIZE]u8 = undefined;
    const result = try formatRfc3339(timestamp, &buf);
    return allocator.dupe(u8, result);
}

/// Get current time as Unix epoch seconds.
pub fn now() i64 {
    return std.time.timestamp();
}

/// Convert year/month/day to epoch day (days since 1970-01-01).
fn yearMonthDayToEpochDay(year: i32, month: u8, day: u8) i64 {
    const epoch_year: i32 = std.time.epoch.epoch_year;

    // Calculate days from years
    var total_days: i64 = 0;
    if (year >= epoch_year) {
        var y: i32 = epoch_year;
        while (y < year) : (y += 1) {
            total_days += std.time.epoch.getDaysInYear(@intCast(y));
        }
    } else {
        var y: i32 = year;
        while (y < epoch_year) : (y += 1) {
            total_days -= std.time.epoch.getDaysInYear(@intCast(y));
        }
    }

    // Add days from months
    const is_leap = std.time.epoch.isLeapYear(@intCast(year));
    const days_in_months = if (is_leap)
        [_]u16{ 0, 31, 60, 91, 121, 152, 182, 213, 244, 274, 305, 335 }
    else
        [_]u16{ 0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334 };

    total_days += days_in_months[month - 1];
    total_days += day - 1;

    return total_days;
}

/// Convert epoch day to year/month/day.
fn epochDayToYearMonthDay(epoch_day: i64, year: *i32, month: *u8, day: *u8) void {
    const epoch_year: i32 = std.time.epoch.epoch_year;
    var days_remaining = epoch_day;
    var current_year: i32 = epoch_year;

    if (days_remaining >= 0) {
        while (true) {
            const days_in_year = std.time.epoch.getDaysInYear(@intCast(current_year));
            if (days_remaining < days_in_year) break;
            days_remaining -= days_in_year;
            current_year += 1;
        }
    } else {
        while (days_remaining < 0) {
            current_year -= 1;
            const days_in_year = std.time.epoch.getDaysInYear(@intCast(current_year));
            days_remaining += days_in_year;
        }
    }

    year.* = current_year;

    // Find month and day
    const is_leap = std.time.epoch.isLeapYear(@intCast(current_year));
    const days_in_months = if (is_leap)
        [_]u16{ 31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }
    else
        [_]u16{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };

    var m: u8 = 0;
    var day_count: i64 = @intCast(days_remaining);
    while (m < 12) : (m += 1) {
        if (day_count < days_in_months[m]) break;
        day_count -= days_in_months[m];
    }

    month.* = m + 1;
    day.* = @intCast(day_count + 1);
}

/// Get number of days in a month.
fn daysInMonth(year: i32, month: u8) u8 {
    const is_leap = std.time.epoch.isLeapYear(@intCast(year));
    const days = if (is_leap)
        [_]u8{ 31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }
    else
        [_]u8{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    return days[month - 1];
}

// --- Tests ---

test "parseRfc3339 basic UTC with Z suffix" {
    const ts = parseRfc3339("2024-01-29T15:30:00Z");
    try std.testing.expect(ts != null);
    // 2024-01-29T15:30:00Z = 1706542200
    try std.testing.expectEqual(@as(i64, 1706542200), ts.?);
}

test "parseRfc3339 UTC with explicit +00:00 offset" {
    const ts = parseRfc3339("2024-01-29T15:30:00+00:00");
    try std.testing.expect(ts != null);
    try std.testing.expectEqual(@as(i64, 1706542200), ts.?);
}

test "parseRfc3339 with positive timezone offset" {
    // 15:30 in +05:00 = 10:30 UTC
    const ts = parseRfc3339("2024-01-29T15:30:00+05:00");
    try std.testing.expect(ts != null);
    // 1706542200 - 5*3600 = 1706524200
    try std.testing.expectEqual(@as(i64, 1706524200), ts.?);
}

test "parseRfc3339 with negative timezone offset" {
    // 15:30 in -05:00 = 20:30 UTC
    const ts = parseRfc3339("2024-01-29T15:30:00-05:00");
    try std.testing.expect(ts != null);
    // 1706542200 + 5*3600 = 1706560200
    try std.testing.expectEqual(@as(i64, 1706560200), ts.?);
}

test "parseRfc3339 with fractional seconds" {
    // Fractional seconds should be ignored
    const ts1 = parseRfc3339("2024-01-29T15:30:00.123Z");
    const ts2 = parseRfc3339("2024-01-29T15:30:00Z");
    try std.testing.expect(ts1 != null);
    try std.testing.expect(ts2 != null);
    try std.testing.expectEqual(ts1.?, ts2.?);
}

test "parseRfc3339 with long fractional seconds" {
    const ts = parseRfc3339("2024-01-29T15:30:00.123456789Z");
    try std.testing.expect(ts != null);
    try std.testing.expectEqual(@as(i64, 1706542200), ts.?);
}

test "parseRfc3339 lowercase t separator" {
    const ts = parseRfc3339("2024-01-29t15:30:00Z");
    try std.testing.expect(ts != null);
    try std.testing.expectEqual(@as(i64, 1706542200), ts.?);
}

test "parseRfc3339 lowercase z suffix" {
    const ts = parseRfc3339("2024-01-29T15:30:00z");
    try std.testing.expect(ts != null);
    try std.testing.expectEqual(@as(i64, 1706542200), ts.?);
}

test "parseRfc3339 rejects invalid formats" {
    try std.testing.expect(parseRfc3339("invalid") == null);
    try std.testing.expect(parseRfc3339("2024-01-29") == null);
    try std.testing.expect(parseRfc3339("2024/01/29T15:30:00Z") == null);
    try std.testing.expect(parseRfc3339("2024-01-29 15:30:00Z") == null);
    try std.testing.expect(parseRfc3339("2024-01-29T15:30:00") == null);
}

test "parseRfc3339 rejects invalid dates" {
    try std.testing.expect(parseRfc3339("2024-00-29T15:30:00Z") == null);
    try std.testing.expect(parseRfc3339("2024-13-29T15:30:00Z") == null);
    try std.testing.expect(parseRfc3339("2024-01-00T15:30:00Z") == null);
    try std.testing.expect(parseRfc3339("2024-01-32T15:30:00Z") == null);
    try std.testing.expect(parseRfc3339("2024-02-30T15:30:00Z") == null);
    try std.testing.expect(parseRfc3339("2023-02-29T15:30:00Z") == null); // Not a leap year
}

test "parseRfc3339 rejects invalid times" {
    try std.testing.expect(parseRfc3339("2024-01-29T24:30:00Z") == null);
    try std.testing.expect(parseRfc3339("2024-01-29T15:60:00Z") == null);
    try std.testing.expect(parseRfc3339("2024-01-29T15:30:60Z") == null);
}

test "parseRfc3339 accepts leap year Feb 29" {
    const ts = parseRfc3339("2024-02-29T12:00:00Z");
    try std.testing.expect(ts != null);
}

test "formatRfc3339 basic" {
    var buf: [RFC3339_BUFFER_SIZE]u8 = undefined;
    const formatted = try formatRfc3339(1706542200, &buf);
    try std.testing.expectEqualStrings("2024-01-29T15:30:00Z", formatted);
}

test "formatRfc3339 epoch zero" {
    var buf: [RFC3339_BUFFER_SIZE]u8 = undefined;
    const formatted = try formatRfc3339(0, &buf);
    try std.testing.expectEqualStrings("1970-01-01T00:00:00Z", formatted);
}

test "formatRfc3339 buffer too small" {
    var buf: [10]u8 = undefined;
    try std.testing.expectError(TimestampError.BufferTooSmall, formatRfc3339(0, &buf));
}

test "formatRfc3339Alloc" {
    const allocator = std.testing.allocator;
    const formatted = try formatRfc3339Alloc(allocator, 1706542200);
    defer allocator.free(formatted);
    try std.testing.expectEqualStrings("2024-01-29T15:30:00Z", formatted);
}

test "roundtrip format -> parse" {
    const original: i64 = 1706542200;
    var buf: [RFC3339_BUFFER_SIZE]u8 = undefined;
    const formatted = try formatRfc3339(original, &buf);
    const parsed = parseRfc3339(formatted);
    try std.testing.expect(parsed != null);
    try std.testing.expectEqual(original, parsed.?);
}

test "roundtrip various timestamps" {
    const test_values = [_]i64{
        0, // Epoch
        1, // One second after epoch
        86400, // One day after epoch
        1706542200, // 2024-01-29T15:30:00Z
        2147483647, // Max 32-bit signed (2038-01-19)
        4102444800, // 2100-01-01T00:00:00Z (year 2038+ test)
    };

    for (test_values) |ts| {
        var buf: [RFC3339_BUFFER_SIZE]u8 = undefined;
        const formatted = try formatRfc3339(ts, &buf);
        const parsed = parseRfc3339(formatted);
        try std.testing.expect(parsed != null);
        try std.testing.expectEqual(ts, parsed.?);
    }
}

test "year 2038+ timestamps" {
    // Test year 2038 problem doesn't affect us
    const ts_2038: i64 = 2147483647; // 2038-01-19T03:14:07Z
    const ts_2100: i64 = 4102444800; // 2100-01-01T00:00:00Z

    var buf: [RFC3339_BUFFER_SIZE]u8 = undefined;

    const formatted_2038 = try formatRfc3339(ts_2038, &buf);
    try std.testing.expectEqualStrings("2038-01-19T03:14:07Z", formatted_2038);

    const formatted_2100 = try formatRfc3339(ts_2100, &buf);
    try std.testing.expectEqualStrings("2100-01-01T00:00:00Z", formatted_2100);
}

test "negative timestamps (before 1970)" {
    // 1969-12-31T23:59:59Z = -1
    const ts_minus_one: i64 = -1;
    var buf: [RFC3339_BUFFER_SIZE]u8 = undefined;

    const formatted = try formatRfc3339(ts_minus_one, &buf);
    try std.testing.expectEqualStrings("1969-12-31T23:59:59Z", formatted);
}

test "negative timestamp roundtrip" {
    const original: i64 = -86400; // One day before epoch
    var buf: [RFC3339_BUFFER_SIZE]u8 = undefined;
    const formatted = try formatRfc3339(original, &buf);
    const parsed = parseRfc3339(formatted);
    try std.testing.expect(parsed != null);
    try std.testing.expectEqual(original, parsed.?);
}

test "now returns reasonable value" {
    const current = now();
    // Should be after 2024-01-01 and before 2100-01-01
    const min_reasonable: i64 = 1704067200; // 2024-01-01T00:00:00Z
    const max_reasonable: i64 = 4102444800; // 2100-01-01T00:00:00Z
    try std.testing.expect(current >= min_reasonable);
    try std.testing.expect(current < max_reasonable);
}

test "parseRfc3339Strict returns specific errors" {
    try std.testing.expectError(TimestampError.InvalidFormat, parseRfc3339Strict("short"));
    try std.testing.expectError(TimestampError.InvalidDate, parseRfc3339Strict("2024-13-01T00:00:00Z"));
    try std.testing.expectError(TimestampError.InvalidTime, parseRfc3339Strict("2024-01-01T25:00:00Z"));
    try std.testing.expectError(TimestampError.InvalidTimezone, parseRfc3339Strict("2024-01-01T00:00:00X"));
}
