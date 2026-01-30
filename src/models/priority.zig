//! Priority struct for issue prioritization.
//!
//! Represents issue priority on a 0-4 scale where lower values indicate
//! higher priority. Serializes as an integer in JSON for beads_rust
//! JSONL compatibility.

const std = @import("std");

/// Issue priority levels (0-4, lower = higher priority).
pub const Priority = struct {
    value: u3,

    const Self = @This();

    pub const CRITICAL = Self{ .value = 0 };
    pub const HIGH = Self{ .value = 1 };
    pub const MEDIUM = Self{ .value = 2 };
    pub const LOW = Self{ .value = 3 };
    pub const BACKLOG = Self{ .value = 4 };

    /// Create a Priority from an integer value (0-4).
    pub fn fromInt(n: anytype) !Self {
        const T = @TypeOf(n);
        const val: i64 = switch (@typeInfo(T)) {
            .int, .comptime_int => @intCast(n),
            else => @compileError("fromInt requires an integer type"),
        };
        if (val < 0 or val > 4) return error.InvalidPriority;
        return Self{ .value = @intCast(val) };
    }

    /// Parse a string into a Priority (case-insensitive names or numeric).
    pub fn fromString(s: []const u8) !Self {
        if (std.ascii.eqlIgnoreCase(s, "critical")) return CRITICAL;
        if (std.ascii.eqlIgnoreCase(s, "high")) return HIGH;
        if (std.ascii.eqlIgnoreCase(s, "medium")) return MEDIUM;
        if (std.ascii.eqlIgnoreCase(s, "low")) return LOW;
        if (std.ascii.eqlIgnoreCase(s, "backlog")) return BACKLOG;

        const num = std.fmt.parseInt(u8, s, 10) catch return error.InvalidPriority;
        return fromInt(num);
    }

    /// Convert Priority to its string representation.
    pub fn toString(self: Self) []const u8 {
        return switch (self.value) {
            0 => "critical",
            1 => "high",
            2 => "medium",
            3 => "low",
            4 => "backlog",
            else => unreachable,
        };
    }

    /// Get the raw integer value.
    pub fn toInt(self: Self) u3 {
        return self.value;
    }

    /// Compare two priorities for sorting.
    pub fn compare(a: Self, b: Self) std.math.Order {
        return std.math.order(a.value, b.value);
    }

    /// JSON serialization as integer for std.json.
    pub fn jsonStringify(self: Self, jws: anytype) !void {
        try jws.write(@as(u8, self.value));
    }

    /// JSON deserialization from integer for std.json.
    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) std.json.ParseError(@TypeOf(source.*))!Self {
        _ = allocator;
        _ = options;
        const token = try source.next();
        const num_str = switch (token) {
            .number => |s| s,
            else => return error.UnexpectedToken,
        };
        const num = std.fmt.parseInt(u8, num_str, 10) catch return error.InvalidNumber;
        if (num > 4) return error.InvalidNumber;
        return Self{ .value = @intCast(num) };
    }

    /// JSON deserialization from already-parsed value.
    pub fn jsonParseFromValue(allocator: std.mem.Allocator, source: std.json.Value, options: std.json.ParseOptions) !Self {
        _ = allocator;
        _ = options;
        return switch (source) {
            .integer => |i| fromInt(i),
            else => error.UnexpectedToken,
        };
    }
};

test "fromInt with valid values" {
    const p0 = try Priority.fromInt(0);
    try std.testing.expectEqual(@as(u3, 0), p0.value);

    const p1 = try Priority.fromInt(1);
    try std.testing.expectEqual(@as(u3, 1), p1.value);

    const p2 = try Priority.fromInt(2);
    try std.testing.expectEqual(@as(u3, 2), p2.value);

    const p3 = try Priority.fromInt(3);
    try std.testing.expectEqual(@as(u3, 3), p3.value);

    const p4 = try Priority.fromInt(4);
    try std.testing.expectEqual(@as(u3, 4), p4.value);
}

test "fromInt with invalid values" {
    try std.testing.expectError(error.InvalidPriority, Priority.fromInt(5));
    try std.testing.expectError(error.InvalidPriority, Priority.fromInt(6));
    try std.testing.expectError(error.InvalidPriority, Priority.fromInt(100));
}

test "fromInt with signed negative values" {
    const signed: i32 = -1;
    try std.testing.expectError(error.InvalidPriority, Priority.fromInt(signed));

    const signed2: i8 = -5;
    try std.testing.expectError(error.InvalidPriority, Priority.fromInt(signed2));
}

test "fromString with named priorities" {
    try std.testing.expectEqual(Priority.CRITICAL, try Priority.fromString("critical"));
    try std.testing.expectEqual(Priority.HIGH, try Priority.fromString("high"));
    try std.testing.expectEqual(Priority.MEDIUM, try Priority.fromString("medium"));
    try std.testing.expectEqual(Priority.LOW, try Priority.fromString("low"));
    try std.testing.expectEqual(Priority.BACKLOG, try Priority.fromString("backlog"));
}

test "fromString is case-insensitive" {
    try std.testing.expectEqual(Priority.CRITICAL, try Priority.fromString("CRITICAL"));
    try std.testing.expectEqual(Priority.CRITICAL, try Priority.fromString("Critical"));
    try std.testing.expectEqual(Priority.CRITICAL, try Priority.fromString("cRiTiCaL"));
    try std.testing.expectEqual(Priority.HIGH, try Priority.fromString("HIGH"));
    try std.testing.expectEqual(Priority.HIGH, try Priority.fromString("High"));
    try std.testing.expectEqual(Priority.MEDIUM, try Priority.fromString("MEDIUM"));
    try std.testing.expectEqual(Priority.LOW, try Priority.fromString("LOW"));
    try std.testing.expectEqual(Priority.BACKLOG, try Priority.fromString("BACKLOG"));
}

test "fromString with numeric strings" {
    try std.testing.expectEqual(Priority.CRITICAL, try Priority.fromString("0"));
    try std.testing.expectEqual(Priority.HIGH, try Priority.fromString("1"));
    try std.testing.expectEqual(Priority.MEDIUM, try Priority.fromString("2"));
    try std.testing.expectEqual(Priority.LOW, try Priority.fromString("3"));
    try std.testing.expectEqual(Priority.BACKLOG, try Priority.fromString("4"));
}

test "fromString with invalid values" {
    try std.testing.expectError(error.InvalidPriority, Priority.fromString("5"));
    try std.testing.expectError(error.InvalidPriority, Priority.fromString("-1"));
    try std.testing.expectError(error.InvalidPriority, Priority.fromString("invalid"));
    try std.testing.expectError(error.InvalidPriority, Priority.fromString(""));
    try std.testing.expectError(error.InvalidPriority, Priority.fromString("highpriority"));
}

test "toString returns correct strings" {
    try std.testing.expectEqualStrings("critical", Priority.CRITICAL.toString());
    try std.testing.expectEqualStrings("high", Priority.HIGH.toString());
    try std.testing.expectEqualStrings("medium", Priority.MEDIUM.toString());
    try std.testing.expectEqualStrings("low", Priority.LOW.toString());
    try std.testing.expectEqualStrings("backlog", Priority.BACKLOG.toString());
}

test "toInt returns correct values" {
    try std.testing.expectEqual(@as(u3, 0), Priority.CRITICAL.toInt());
    try std.testing.expectEqual(@as(u3, 1), Priority.HIGH.toInt());
    try std.testing.expectEqual(@as(u3, 2), Priority.MEDIUM.toInt());
    try std.testing.expectEqual(@as(u3, 3), Priority.LOW.toInt());
    try std.testing.expectEqual(@as(u3, 4), Priority.BACKLOG.toInt());
}

test "comparison ordering" {
    try std.testing.expectEqual(std.math.Order.lt, Priority.compare(Priority.CRITICAL, Priority.HIGH));
    try std.testing.expectEqual(std.math.Order.lt, Priority.compare(Priority.HIGH, Priority.MEDIUM));
    try std.testing.expectEqual(std.math.Order.lt, Priority.compare(Priority.MEDIUM, Priority.LOW));
    try std.testing.expectEqual(std.math.Order.lt, Priority.compare(Priority.LOW, Priority.BACKLOG));

    try std.testing.expectEqual(std.math.Order.gt, Priority.compare(Priority.BACKLOG, Priority.LOW));
    try std.testing.expectEqual(std.math.Order.gt, Priority.compare(Priority.LOW, Priority.MEDIUM));
    try std.testing.expectEqual(std.math.Order.gt, Priority.compare(Priority.MEDIUM, Priority.HIGH));
    try std.testing.expectEqual(std.math.Order.gt, Priority.compare(Priority.HIGH, Priority.CRITICAL));

    try std.testing.expectEqual(std.math.Order.eq, Priority.compare(Priority.CRITICAL, Priority.CRITICAL));
    try std.testing.expectEqual(std.math.Order.eq, Priority.compare(Priority.MEDIUM, Priority.MEDIUM));
    try std.testing.expectEqual(std.math.Order.eq, Priority.compare(Priority.BACKLOG, Priority.BACKLOG));
}

test "toString/fromString roundtrip" {
    const priorities = [_]Priority{
        Priority.CRITICAL,
        Priority.HIGH,
        Priority.MEDIUM,
        Priority.LOW,
        Priority.BACKLOG,
    };

    for (priorities) |priority| {
        const str = priority.toString();
        const parsed = try Priority.fromString(str);
        try std.testing.expectEqual(priority, parsed);
    }
}

test "JSON serialization roundtrip" {
    const allocator = std.testing.allocator;

    const priorities = [_]Priority{
        Priority.CRITICAL,
        Priority.HIGH,
        Priority.MEDIUM,
        Priority.LOW,
        Priority.BACKLOG,
    };

    for (priorities) |priority| {
        var aw: std.io.Writer.Allocating = .init(allocator);
        defer aw.deinit();

        try std.json.Stringify.value(priority, .{}, &aw.writer);
        const json_str = aw.written();

        const parsed = try std.json.parseFromSlice(Priority, allocator, json_str, .{});
        defer parsed.deinit();

        try std.testing.expectEqual(priority, parsed.value);
    }
}

test "JSON serializes as integer" {
    const allocator = std.testing.allocator;

    var aw: std.io.Writer.Allocating = .init(allocator);
    defer aw.deinit();

    try std.json.Stringify.value(Priority.MEDIUM, .{}, &aw.writer);

    try std.testing.expectEqualStrings("2", aw.written());
}

test "JSON deserializes from integer" {
    const allocator = std.testing.allocator;

    const json_str = "2";
    const parsed = try std.json.parseFromSlice(Priority, allocator, json_str, .{});
    defer parsed.deinit();

    try std.testing.expectEqual(Priority.MEDIUM, parsed.value);
}

test "constants have expected values" {
    try std.testing.expectEqual(@as(u3, 0), Priority.CRITICAL.value);
    try std.testing.expectEqual(@as(u3, 1), Priority.HIGH.value);
    try std.testing.expectEqual(@as(u3, 2), Priority.MEDIUM.value);
    try std.testing.expectEqual(@as(u3, 3), Priority.LOW.value);
    try std.testing.expectEqual(@as(u3, 4), Priority.BACKLOG.value);
}
