//! IssueType enum for categorizing issues.
//!
//! Represents the type/category of an issue. Supports both predefined
//! types and custom user-defined types.

const std = @import("std");

/// Issue type/category classification.
pub const IssueType = union(enum) {
    task,
    bug,
    feature,
    epic,
    chore,
    docs,
    question,
    custom: []const u8,

    const Self = @This();

    /// Convert IssueType to its string representation.
    pub fn toString(self: Self) []const u8 {
        return switch (self) {
            .task => "task",
            .bug => "bug",
            .feature => "feature",
            .epic => "epic",
            .chore => "chore",
            .docs => "docs",
            .question => "question",
            .custom => |s| s,
        };
    }

    /// Parse a string into an IssueType (case-insensitive for known values).
    /// Returns .custom for unknown values.
    pub fn fromString(s: []const u8) Self {
        if (std.ascii.eqlIgnoreCase(s, "task")) return .task;
        if (std.ascii.eqlIgnoreCase(s, "bug")) return .bug;
        if (std.ascii.eqlIgnoreCase(s, "feature")) return .feature;
        if (std.ascii.eqlIgnoreCase(s, "epic")) return .epic;
        if (std.ascii.eqlIgnoreCase(s, "chore")) return .chore;
        if (std.ascii.eqlIgnoreCase(s, "docs")) return .docs;
        if (std.ascii.eqlIgnoreCase(s, "question")) return .question;
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
};

test "toString returns correct strings for known types" {
    try std.testing.expectEqualStrings("task", (IssueType{ .task = {} }).toString());
    try std.testing.expectEqualStrings("bug", (IssueType{ .bug = {} }).toString());
    try std.testing.expectEqualStrings("feature", (IssueType{ .feature = {} }).toString());
    try std.testing.expectEqualStrings("epic", (IssueType{ .epic = {} }).toString());
    try std.testing.expectEqualStrings("chore", (IssueType{ .chore = {} }).toString());
    try std.testing.expectEqualStrings("docs", (IssueType{ .docs = {} }).toString());
    try std.testing.expectEqualStrings("question", (IssueType{ .question = {} }).toString());
}

test "toString returns custom string for custom type" {
    const custom = IssueType{ .custom = "my_custom_type" };
    try std.testing.expectEqualStrings("my_custom_type", custom.toString());
}

test "fromString parses known types correctly" {
    try std.testing.expectEqual(IssueType.task, IssueType.fromString("task"));
    try std.testing.expectEqual(IssueType.bug, IssueType.fromString("bug"));
    try std.testing.expectEqual(IssueType.feature, IssueType.fromString("feature"));
    try std.testing.expectEqual(IssueType.epic, IssueType.fromString("epic"));
    try std.testing.expectEqual(IssueType.chore, IssueType.fromString("chore"));
    try std.testing.expectEqual(IssueType.docs, IssueType.fromString("docs"));
    try std.testing.expectEqual(IssueType.question, IssueType.fromString("question"));
}

test "fromString is case-insensitive" {
    try std.testing.expectEqual(IssueType.task, IssueType.fromString("TASK"));
    try std.testing.expectEqual(IssueType.task, IssueType.fromString("Task"));
    try std.testing.expectEqual(IssueType.task, IssueType.fromString("tAsK"));
    try std.testing.expectEqual(IssueType.bug, IssueType.fromString("BUG"));
    try std.testing.expectEqual(IssueType.bug, IssueType.fromString("Bug"));
    try std.testing.expectEqual(IssueType.feature, IssueType.fromString("FEATURE"));
    try std.testing.expectEqual(IssueType.feature, IssueType.fromString("Feature"));
    try std.testing.expectEqual(IssueType.epic, IssueType.fromString("EPIC"));
    try std.testing.expectEqual(IssueType.chore, IssueType.fromString("CHORE"));
    try std.testing.expectEqual(IssueType.docs, IssueType.fromString("DOCS"));
    try std.testing.expectEqual(IssueType.question, IssueType.fromString("QUESTION"));
}

test "fromString returns custom for unknown values" {
    const result = IssueType.fromString("unknown_type");
    switch (result) {
        .custom => |s| try std.testing.expectEqualStrings("unknown_type", s),
        else => return error.TestExpectedCustom,
    }
}

test "toString/fromString roundtrip for known types" {
    const types = [_]IssueType{
        .task,
        .bug,
        .feature,
        .epic,
        .chore,
        .docs,
        .question,
    };

    for (types) |issue_type| {
        const str = issue_type.toString();
        const parsed = IssueType.fromString(str);
        try std.testing.expectEqual(issue_type, parsed);
    }
}

test "toString/fromString roundtrip for custom type" {
    const original = IssueType{ .custom = "my_workflow_type" };
    const str = original.toString();
    const parsed = IssueType.fromString(str);

    switch (parsed) {
        .custom => |s| try std.testing.expectEqualStrings("my_workflow_type", s),
        else => return error.TestExpectedCustom,
    }
}

test "JSON serialization roundtrip" {
    const allocator = std.testing.allocator;

    const types = [_]IssueType{
        .task,
        .bug,
        .feature,
        .epic,
        .chore,
        .docs,
        .question,
    };

    for (types) |issue_type| {
        var aw: std.io.Writer.Allocating = .init(allocator);
        defer aw.deinit();

        try std.json.Stringify.value(issue_type, .{}, &aw.writer);
        const json_str = aw.written();

        const parsed = try std.json.parseFromSlice(IssueType, allocator, json_str, .{});
        defer parsed.deinit();

        try std.testing.expectEqual(issue_type, parsed.value);
    }
}

test "JSON deserialization of custom type" {
    const allocator = std.testing.allocator;

    const json_str = "\"custom_category\"";
    const parsed = try std.json.parseFromSlice(IssueType, allocator, json_str, .{});
    defer parsed.deinit();

    switch (parsed.value) {
        .custom => |s| try std.testing.expectEqualStrings("custom_category", s),
        else => return error.TestExpectedCustom,
    }
}

test "JSON serializes as lowercase string" {
    const allocator = std.testing.allocator;

    var aw: std.io.Writer.Allocating = .init(allocator);
    defer aw.deinit();

    try std.json.Stringify.value(IssueType.task, .{}, &aw.writer);

    try std.testing.expectEqualStrings("\"task\"", aw.written());
}
