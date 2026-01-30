//! Dependency types and the Dependency struct for tracking relationships between issues.
//!
//! Dependencies model the relationships between issues - blocking relationships,
//! parent-child hierarchies, and other associations. The dependency graph
//! enables the "ready" query (issues with no blockers) and cycle detection.

const std = @import("std");

/// Dependency relationship types between issues.
pub const DependencyType = union(enum) {
    blocks,
    parent_child,
    conditional_blocks,
    waits_for,
    related,
    discovered_from,
    replies_to,
    relates_to,
    duplicates,
    supersedes,
    caused_by,
    custom: []const u8,

    const Self = @This();

    /// Convert DependencyType to its string representation.
    pub fn toString(self: Self) []const u8 {
        return switch (self) {
            .blocks => "blocks",
            .parent_child => "parent_child",
            .conditional_blocks => "conditional_blocks",
            .waits_for => "waits_for",
            .related => "related",
            .discovered_from => "discovered_from",
            .replies_to => "replies_to",
            .relates_to => "relates_to",
            .duplicates => "duplicates",
            .supersedes => "supersedes",
            .caused_by => "caused_by",
            .custom => |s| s,
        };
    }

    /// Parse a string into a DependencyType (case-insensitive for known values).
    /// Returns .custom for unknown values.
    pub fn fromString(s: []const u8) Self {
        if (std.ascii.eqlIgnoreCase(s, "blocks")) return .blocks;
        if (std.ascii.eqlIgnoreCase(s, "parent_child")) return .parent_child;
        if (std.ascii.eqlIgnoreCase(s, "conditional_blocks")) return .conditional_blocks;
        if (std.ascii.eqlIgnoreCase(s, "waits_for")) return .waits_for;
        if (std.ascii.eqlIgnoreCase(s, "related")) return .related;
        if (std.ascii.eqlIgnoreCase(s, "discovered_from")) return .discovered_from;
        if (std.ascii.eqlIgnoreCase(s, "replies_to")) return .replies_to;
        if (std.ascii.eqlIgnoreCase(s, "relates_to")) return .relates_to;
        if (std.ascii.eqlIgnoreCase(s, "duplicates")) return .duplicates;
        if (std.ascii.eqlIgnoreCase(s, "supersedes")) return .supersedes;
        if (std.ascii.eqlIgnoreCase(s, "caused_by")) return .caused_by;
        return .{ .custom = s };
    }

    /// Check equality between two DependencyTypes.
    pub fn eql(a: Self, b: Self) bool {
        const Tag = std.meta.Tag(Self);
        const tag_a: Tag = a;
        const tag_b: Tag = b;
        if (tag_a != tag_b) return false;
        return if (tag_a == .custom) std.mem.eql(u8, a.custom, b.custom) else true;
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

/// A dependency relationship between two issues.
/// issue_id depends ON depends_on_id (issue_id is blocked BY depends_on_id).
pub const Dependency = struct {
    issue_id: []const u8,
    depends_on_id: []const u8,
    dep_type: DependencyType,
    created_at: i64,
    created_by: ?[]const u8,
    metadata: ?[]const u8,
    thread_id: ?[]const u8,

    const Self = @This();

    /// Check deep equality between two Dependencies.
    pub fn eql(a: Self, b: Self) bool {
        if (!std.mem.eql(u8, a.issue_id, b.issue_id)) return false;
        if (!std.mem.eql(u8, a.depends_on_id, b.depends_on_id)) return false;
        if (!DependencyType.eql(a.dep_type, b.dep_type)) return false;
        if (a.created_at != b.created_at) return false;
        if (!optionalStrEql(a.created_by, b.created_by)) return false;
        if (!optionalStrEql(a.metadata, b.metadata)) return false;
        if (!optionalStrEql(a.thread_id, b.thread_id)) return false;
        return true;
    }

    fn optionalStrEql(a: ?[]const u8, b: ?[]const u8) bool {
        const a_val = a orelse return b == null;
        const b_val = b orelse return false;
        return std.mem.eql(u8, a_val, b_val);
    }
};

// --- DependencyType Tests ---

test "DependencyType.toString returns correct strings for known types" {
    try std.testing.expectEqualStrings("blocks", (DependencyType{ .blocks = {} }).toString());
    try std.testing.expectEqualStrings("parent_child", (DependencyType{ .parent_child = {} }).toString());
    try std.testing.expectEqualStrings("conditional_blocks", (DependencyType{ .conditional_blocks = {} }).toString());
    try std.testing.expectEqualStrings("waits_for", (DependencyType{ .waits_for = {} }).toString());
    try std.testing.expectEqualStrings("related", (DependencyType{ .related = {} }).toString());
    try std.testing.expectEqualStrings("discovered_from", (DependencyType{ .discovered_from = {} }).toString());
    try std.testing.expectEqualStrings("replies_to", (DependencyType{ .replies_to = {} }).toString());
    try std.testing.expectEqualStrings("relates_to", (DependencyType{ .relates_to = {} }).toString());
    try std.testing.expectEqualStrings("duplicates", (DependencyType{ .duplicates = {} }).toString());
    try std.testing.expectEqualStrings("supersedes", (DependencyType{ .supersedes = {} }).toString());
    try std.testing.expectEqualStrings("caused_by", (DependencyType{ .caused_by = {} }).toString());
}

test "DependencyType.toString returns custom string for custom type" {
    const custom = DependencyType{ .custom = "my_custom_dep" };
    try std.testing.expectEqualStrings("my_custom_dep", custom.toString());
}

test "DependencyType.fromString parses known types correctly" {
    try std.testing.expectEqual(DependencyType.blocks, DependencyType.fromString("blocks"));
    try std.testing.expectEqual(DependencyType.parent_child, DependencyType.fromString("parent_child"));
    try std.testing.expectEqual(DependencyType.conditional_blocks, DependencyType.fromString("conditional_blocks"));
    try std.testing.expectEqual(DependencyType.waits_for, DependencyType.fromString("waits_for"));
    try std.testing.expectEqual(DependencyType.related, DependencyType.fromString("related"));
    try std.testing.expectEqual(DependencyType.discovered_from, DependencyType.fromString("discovered_from"));
    try std.testing.expectEqual(DependencyType.replies_to, DependencyType.fromString("replies_to"));
    try std.testing.expectEqual(DependencyType.relates_to, DependencyType.fromString("relates_to"));
    try std.testing.expectEqual(DependencyType.duplicates, DependencyType.fromString("duplicates"));
    try std.testing.expectEqual(DependencyType.supersedes, DependencyType.fromString("supersedes"));
    try std.testing.expectEqual(DependencyType.caused_by, DependencyType.fromString("caused_by"));
}

test "DependencyType.fromString is case-insensitive" {
    try std.testing.expectEqual(DependencyType.blocks, DependencyType.fromString("BLOCKS"));
    try std.testing.expectEqual(DependencyType.blocks, DependencyType.fromString("Blocks"));
    try std.testing.expectEqual(DependencyType.blocks, DependencyType.fromString("bLoCkS"));
    try std.testing.expectEqual(DependencyType.parent_child, DependencyType.fromString("PARENT_CHILD"));
    try std.testing.expectEqual(DependencyType.parent_child, DependencyType.fromString("Parent_Child"));
    try std.testing.expectEqual(DependencyType.waits_for, DependencyType.fromString("WAITS_FOR"));
    try std.testing.expectEqual(DependencyType.duplicates, DependencyType.fromString("DUPLICATES"));
}

test "DependencyType.fromString returns custom for unknown values" {
    const result = DependencyType.fromString("unknown_dep_type");
    switch (result) {
        .custom => |s| try std.testing.expectEqualStrings("unknown_dep_type", s),
        else => return error.TestExpectedCustom,
    }
}

test "DependencyType toString/fromString roundtrip for known types" {
    const dep_types = [_]DependencyType{
        .blocks,
        .parent_child,
        .conditional_blocks,
        .waits_for,
        .related,
        .discovered_from,
        .replies_to,
        .relates_to,
        .duplicates,
        .supersedes,
        .caused_by,
    };

    for (dep_types) |dep_type| {
        const str = dep_type.toString();
        const parsed = DependencyType.fromString(str);
        try std.testing.expectEqual(dep_type, parsed);
    }
}

test "DependencyType toString/fromString roundtrip for custom type" {
    const original = DependencyType{ .custom = "my_workflow_dep" };
    const str = original.toString();
    const parsed = DependencyType.fromString(str);

    switch (parsed) {
        .custom => |s| try std.testing.expectEqualStrings("my_workflow_dep", s),
        else => return error.TestExpectedCustom,
    }
}

test "DependencyType.eql compares correctly" {
    try std.testing.expect(DependencyType.eql(.blocks, .blocks));
    try std.testing.expect(DependencyType.eql(.parent_child, .parent_child));
    try std.testing.expect(!DependencyType.eql(.blocks, .parent_child));
    try std.testing.expect(!DependencyType.eql(.waits_for, .duplicates));

    const custom1 = DependencyType{ .custom = "foo" };
    const custom2 = DependencyType{ .custom = "foo" };
    const custom3 = DependencyType{ .custom = "bar" };
    try std.testing.expect(DependencyType.eql(custom1, custom2));
    try std.testing.expect(!DependencyType.eql(custom1, custom3));
    try std.testing.expect(!DependencyType.eql(custom1, .blocks));
}

test "DependencyType JSON serialization roundtrip" {
    const allocator = std.testing.allocator;

    const dep_types = [_]DependencyType{
        .blocks,
        .parent_child,
        .conditional_blocks,
        .waits_for,
        .related,
        .discovered_from,
        .replies_to,
        .relates_to,
        .duplicates,
        .supersedes,
        .caused_by,
    };

    for (dep_types) |dep_type| {
        var aw: std.io.Writer.Allocating = .init(allocator);
        defer aw.deinit();

        try std.json.Stringify.value(dep_type, .{}, &aw.writer);
        const json_str = aw.written();

        const parsed = try std.json.parseFromSlice(DependencyType, allocator, json_str, .{});
        defer parsed.deinit();

        try std.testing.expectEqual(dep_type, parsed.value);
    }
}

test "DependencyType JSON deserialization of custom type" {
    const allocator = std.testing.allocator;

    const json_str = "\"custom_relationship\"";
    const parsed = try std.json.parseFromSlice(DependencyType, allocator, json_str, .{});
    defer parsed.deinit();

    switch (parsed.value) {
        .custom => |s| try std.testing.expectEqualStrings("custom_relationship", s),
        else => return error.TestExpectedCustom,
    }
}

test "DependencyType JSON serializes as lowercase string" {
    const allocator = std.testing.allocator;

    var aw: std.io.Writer.Allocating = .init(allocator);
    defer aw.deinit();

    try std.json.Stringify.value(DependencyType.blocks, .{}, &aw.writer);

    try std.testing.expectEqualStrings("\"blocks\"", aw.written());
}

// --- Dependency Tests ---

test "Dependency.eql compares all fields" {
    const dep1 = Dependency{
        .issue_id = "bd-abc123",
        .depends_on_id = "bd-def456",
        .dep_type = .blocks,
        .created_at = 1706540000,
        .created_by = "alice@example.com",
        .metadata = null,
        .thread_id = null,
    };

    const dep2 = Dependency{
        .issue_id = "bd-abc123",
        .depends_on_id = "bd-def456",
        .dep_type = .blocks,
        .created_at = 1706540000,
        .created_by = "alice@example.com",
        .metadata = null,
        .thread_id = null,
    };

    try std.testing.expect(Dependency.eql(dep1, dep2));
}

test "Dependency.eql detects issue_id difference" {
    const dep1 = Dependency{
        .issue_id = "bd-abc123",
        .depends_on_id = "bd-def456",
        .dep_type = .blocks,
        .created_at = 1706540000,
        .created_by = null,
        .metadata = null,
        .thread_id = null,
    };

    const dep2 = Dependency{
        .issue_id = "bd-xyz789",
        .depends_on_id = "bd-def456",
        .dep_type = .blocks,
        .created_at = 1706540000,
        .created_by = null,
        .metadata = null,
        .thread_id = null,
    };

    try std.testing.expect(!Dependency.eql(dep1, dep2));
}

test "Dependency.eql detects dep_type difference" {
    const dep1 = Dependency{
        .issue_id = "bd-abc123",
        .depends_on_id = "bd-def456",
        .dep_type = .blocks,
        .created_at = 1706540000,
        .created_by = null,
        .metadata = null,
        .thread_id = null,
    };

    const dep2 = Dependency{
        .issue_id = "bd-abc123",
        .depends_on_id = "bd-def456",
        .dep_type = .waits_for,
        .created_at = 1706540000,
        .created_by = null,
        .metadata = null,
        .thread_id = null,
    };

    try std.testing.expect(!Dependency.eql(dep1, dep2));
}

test "Dependency.eql detects optional field differences" {
    const dep1 = Dependency{
        .issue_id = "bd-abc123",
        .depends_on_id = "bd-def456",
        .dep_type = .blocks,
        .created_at = 1706540000,
        .created_by = "alice@example.com",
        .metadata = null,
        .thread_id = null,
    };

    const dep2 = Dependency{
        .issue_id = "bd-abc123",
        .depends_on_id = "bd-def456",
        .dep_type = .blocks,
        .created_at = 1706540000,
        .created_by = null,
        .metadata = null,
        .thread_id = null,
    };

    try std.testing.expect(!Dependency.eql(dep1, dep2));
}

test "Dependency.eql handles metadata comparison" {
    const dep1 = Dependency{
        .issue_id = "bd-abc123",
        .depends_on_id = "bd-def456",
        .dep_type = .blocks,
        .created_at = 1706540000,
        .created_by = null,
        .metadata = "{\"key\":\"value\"}",
        .thread_id = null,
    };

    const dep2 = Dependency{
        .issue_id = "bd-abc123",
        .depends_on_id = "bd-def456",
        .dep_type = .blocks,
        .created_at = 1706540000,
        .created_by = null,
        .metadata = "{\"key\":\"value\"}",
        .thread_id = null,
    };

    const dep3 = Dependency{
        .issue_id = "bd-abc123",
        .depends_on_id = "bd-def456",
        .dep_type = .blocks,
        .created_at = 1706540000,
        .created_by = null,
        .metadata = "{\"other\":\"data\"}",
        .thread_id = null,
    };

    try std.testing.expect(Dependency.eql(dep1, dep2));
    try std.testing.expect(!Dependency.eql(dep1, dep3));
}

test "Dependency JSON serialization with all fields" {
    const allocator = std.testing.allocator;

    const dep = Dependency{
        .issue_id = "bd-abc123",
        .depends_on_id = "bd-def456",
        .dep_type = .blocks,
        .created_at = 1706540000,
        .created_by = "alice@example.com",
        .metadata = "{\"key\":\"value\"}",
        .thread_id = "thread-001",
    };

    var aw: std.io.Writer.Allocating = .init(allocator);
    defer aw.deinit();

    try std.json.Stringify.value(dep, .{}, &aw.writer);
    const json_str = aw.written();

    const parsed = try std.json.parseFromSlice(Dependency, allocator, json_str, .{});
    defer parsed.deinit();

    try std.testing.expect(Dependency.eql(dep, parsed.value));
}

test "Dependency JSON serialization with null fields" {
    const allocator = std.testing.allocator;

    const dep = Dependency{
        .issue_id = "bd-abc123",
        .depends_on_id = "bd-def456",
        .dep_type = .parent_child,
        .created_at = 1706540000,
        .created_by = null,
        .metadata = null,
        .thread_id = null,
    };

    var aw: std.io.Writer.Allocating = .init(allocator);
    defer aw.deinit();

    try std.json.Stringify.value(dep, .{}, &aw.writer);
    const json_str = aw.written();

    const parsed = try std.json.parseFromSlice(Dependency, allocator, json_str, .{});
    defer parsed.deinit();

    try std.testing.expect(Dependency.eql(dep, parsed.value));
}

test "Dependency JSON serialization roundtrip with custom dep_type" {
    const allocator = std.testing.allocator;

    const dep = Dependency{
        .issue_id = "bd-abc123",
        .depends_on_id = "bd-def456",
        .dep_type = DependencyType{ .custom = "my_custom_relation" },
        .created_at = 1706540000,
        .created_by = "bob@example.com",
        .metadata = null,
        .thread_id = null,
    };

    var aw: std.io.Writer.Allocating = .init(allocator);
    defer aw.deinit();

    try std.json.Stringify.value(dep, .{}, &aw.writer);
    const json_str = aw.written();

    const parsed = try std.json.parseFromSlice(Dependency, allocator, json_str, .{});
    defer parsed.deinit();

    try std.testing.expectEqualStrings(dep.issue_id, parsed.value.issue_id);
    try std.testing.expectEqualStrings(dep.depends_on_id, parsed.value.depends_on_id);
    try std.testing.expectEqual(dep.created_at, parsed.value.created_at);
    switch (parsed.value.dep_type) {
        .custom => |s| try std.testing.expectEqualStrings("my_custom_relation", s),
        else => return error.TestExpectedCustom,
    }
}

test "Dependency JSON contains expected fields" {
    const allocator = std.testing.allocator;

    const dep = Dependency{
        .issue_id = "bd-test",
        .depends_on_id = "bd-blocker",
        .dep_type = .blocks,
        .created_at = 1234567890,
        .created_by = null,
        .metadata = null,
        .thread_id = null,
    };

    var aw: std.io.Writer.Allocating = .init(allocator);
    defer aw.deinit();

    try std.json.Stringify.value(dep, .{}, &aw.writer);
    const json_str = aw.written();

    try std.testing.expect(std.mem.indexOf(u8, json_str, "\"issue_id\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json_str, "\"depends_on_id\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json_str, "\"dep_type\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json_str, "\"created_at\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json_str, "\"created_by\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json_str, "\"metadata\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json_str, "\"thread_id\"") != null);
}
