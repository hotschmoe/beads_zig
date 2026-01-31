//! Status enum for issue lifecycle states.
//!
//! Represents the current state of an issue in its lifecycle.
//! Supports both predefined states and custom user-defined statuses.

const std = @import("std");

/// Issue lifecycle states.
pub const Status = union(enum) {
    open,
    in_progress,
    blocked,
    deferred,
    closed,
    tombstone,
    pinned,
    custom: []const u8,

    const Self = @This();

    /// Convert Status to its string representation.
    pub fn toString(self: Self) []const u8 {
        return switch (self) {
            .open => "open",
            .in_progress => "in_progress",
            .blocked => "blocked",
            .deferred => "deferred",
            .closed => "closed",
            .tombstone => "tombstone",
            .pinned => "pinned",
            .custom => |s| s,
        };
    }

    /// Parse a string into a Status (case-insensitive for known values).
    /// Returns .custom for unknown values.
    pub fn fromString(s: []const u8) Self {
        if (std.ascii.eqlIgnoreCase(s, "open")) return .open;
        if (std.ascii.eqlIgnoreCase(s, "in_progress")) return .in_progress;
        if (std.ascii.eqlIgnoreCase(s, "blocked")) return .blocked;
        if (std.ascii.eqlIgnoreCase(s, "deferred")) return .deferred;
        if (std.ascii.eqlIgnoreCase(s, "closed")) return .closed;
        if (std.ascii.eqlIgnoreCase(s, "tombstone")) return .tombstone;
        if (std.ascii.eqlIgnoreCase(s, "pinned")) return .pinned;
        return .{ .custom = s };
    }

    /// JSON serialization for std.json.
    pub fn jsonStringify(self: Self, jws: anytype) !void {
        try jws.write(self.toString());
    }

    /// JSON deserialization for std.json.
    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !Self {
        const token = try source.nextAllocMax(allocator, .alloc_if_needed, options.max_value_len.?);
        const str = switch (token) {
            .string, .allocated_string => |s| s,
            else => return error.UnexpectedToken,
        };
        return fromString(str);
    }

    /// JSON deserialization from already-parsed value.
    pub fn jsonParseFromValue(allocator: std.mem.Allocator, source: std.json.Value, options: std.json.ParseOptions) !Self {
        _ = allocator;
        _ = options;
        return switch (source) {
            .string => |s| fromString(s),
            else => error.UnexpectedToken,
        };
    }

    /// Check equality between two Status values.
    pub fn eql(self: Self, other: Self) bool {
        const Tag = std.meta.Tag(Self);
        const self_tag: Tag = self;
        const other_tag: Tag = other;
        if (self_tag != other_tag) return false;
        return if (self_tag == .custom) std.mem.eql(u8, self.custom, other.custom) else true;
    }
};

test "toString returns correct strings for known statuses" {
    try std.testing.expectEqualStrings("open", (Status{ .open = {} }).toString());
    try std.testing.expectEqualStrings("in_progress", (Status{ .in_progress = {} }).toString());
    try std.testing.expectEqualStrings("blocked", (Status{ .blocked = {} }).toString());
    try std.testing.expectEqualStrings("deferred", (Status{ .deferred = {} }).toString());
    try std.testing.expectEqualStrings("closed", (Status{ .closed = {} }).toString());
    try std.testing.expectEqualStrings("tombstone", (Status{ .tombstone = {} }).toString());
    try std.testing.expectEqualStrings("pinned", (Status{ .pinned = {} }).toString());
}

test "toString returns custom string for custom status" {
    const custom = Status{ .custom = "my_custom_status" };
    try std.testing.expectEqualStrings("my_custom_status", custom.toString());
}

test "fromString parses known statuses correctly" {
    try std.testing.expectEqual(Status.open, Status.fromString("open"));
    try std.testing.expectEqual(Status.in_progress, Status.fromString("in_progress"));
    try std.testing.expectEqual(Status.blocked, Status.fromString("blocked"));
    try std.testing.expectEqual(Status.deferred, Status.fromString("deferred"));
    try std.testing.expectEqual(Status.closed, Status.fromString("closed"));
    try std.testing.expectEqual(Status.tombstone, Status.fromString("tombstone"));
    try std.testing.expectEqual(Status.pinned, Status.fromString("pinned"));
}

test "fromString is case-insensitive" {
    try std.testing.expectEqual(Status.open, Status.fromString("OPEN"));
    try std.testing.expectEqual(Status.open, Status.fromString("Open"));
    try std.testing.expectEqual(Status.open, Status.fromString("oPeN"));
    try std.testing.expectEqual(Status.in_progress, Status.fromString("IN_PROGRESS"));
    try std.testing.expectEqual(Status.in_progress, Status.fromString("In_Progress"));
    try std.testing.expectEqual(Status.blocked, Status.fromString("BLOCKED"));
    try std.testing.expectEqual(Status.closed, Status.fromString("CLOSED"));
}

test "fromString returns custom for unknown values" {
    const result = Status.fromString("unknown_status");
    switch (result) {
        .custom => |s| try std.testing.expectEqualStrings("unknown_status", s),
        else => return error.TestExpectedCustom,
    }
}

test "toString/fromString roundtrip for known statuses" {
    const statuses = [_]Status{
        .open,
        .in_progress,
        .blocked,
        .deferred,
        .closed,
        .tombstone,
        .pinned,
    };

    for (statuses) |status| {
        const str = status.toString();
        const parsed = Status.fromString(str);
        try std.testing.expectEqual(status, parsed);
    }
}

test "toString/fromString roundtrip for custom status" {
    const original = Status{ .custom = "my_workflow_state" };
    const str = original.toString();
    const parsed = Status.fromString(str);

    switch (parsed) {
        .custom => |s| try std.testing.expectEqualStrings("my_workflow_state", s),
        else => return error.TestExpectedCustom,
    }
}

test "JSON serialization roundtrip" {
    const allocator = std.testing.allocator;

    const statuses = [_]Status{
        .open,
        .in_progress,
        .blocked,
        .deferred,
        .closed,
        .tombstone,
        .pinned,
    };

    for (statuses) |status| {
        var aw: std.io.Writer.Allocating = .init(allocator);
        defer aw.deinit();

        try std.json.Stringify.value(status, .{}, &aw.writer);
        const json_str = aw.written();

        const parsed = try std.json.parseFromSlice(Status, allocator, json_str, .{});
        defer parsed.deinit();

        try std.testing.expectEqual(status, parsed.value);
    }
}

test "JSON deserialization of custom status" {
    const allocator = std.testing.allocator;

    const json_str = "\"custom_workflow\"";
    const parsed = try std.json.parseFromSlice(Status, allocator, json_str, .{});
    defer parsed.deinit();

    switch (parsed.value) {
        .custom => |s| try std.testing.expectEqualStrings("custom_workflow", s),
        else => return error.TestExpectedCustom,
    }
}
