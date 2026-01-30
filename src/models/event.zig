//! Event struct and EventType enum for the audit log system.
//!
//! Events track changes to issues for audit and history purposes.
//! Each event records who made a change, what changed, and when.

const std = @import("std");
const Status = @import("status.zig").Status;
const Priority = @import("priority.zig").Priority;

/// Types of events that can occur on an issue.
pub const EventType = enum {
    created,
    updated,
    status_changed,
    priority_changed,
    assignee_changed,
    commented,
    closed,
    reopened,
    dependency_added,
    dependency_removed,
    label_added,
    label_removed,
    compacted,
    deleted,
    restored,

    const Self = @This();

    /// Convert EventType to its string representation.
    pub fn toString(self: Self) []const u8 {
        return @tagName(self);
    }

    /// Parse a string into an EventType.
    /// Returns null for unknown values.
    pub fn fromString(s: []const u8) ?Self {
        return std.meta.stringToEnum(Self, s);
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
        return fromString(str) orelse error.UnexpectedToken;
    }

    /// JSON deserialization from already-parsed value.
    pub fn jsonParseFromValue(allocator: std.mem.Allocator, source: std.json.Value, options: std.json.ParseOptions) !Self {
        _ = allocator;
        _ = options;
        return switch (source) {
            .string => |s| fromString(s) orelse error.UnexpectedToken,
            else => error.UnexpectedToken,
        };
    }
};

/// Validation errors for Event.
pub const EventError = error{
    EmptyActor,
    EmptyIssueId,
};

/// An audit log entry for an issue change.
pub const Event = struct {
    id: i64, // Unique identifier, 0 for new events before insert
    issue_id: []const u8, // The issue this event relates to
    event_type: EventType, // What kind of change occurred
    actor: []const u8, // Who performed the action
    old_value: ?[]const u8, // JSON of previous state (null for creation)
    new_value: ?[]const u8, // JSON of new state (null for deletion)
    created_at: i64, // Unix timestamp

    const Self = @This();

    /// Validate that the event has all required fields populated.
    pub fn validate(self: Self) EventError!void {
        if (self.actor.len == 0) return EventError.EmptyActor;
        if (self.issue_id.len == 0) return EventError.EmptyIssueId;
    }

    /// Check deep equality between two Events.
    pub fn eql(a: Self, b: Self) bool {
        return a.id == b.id and
            a.created_at == b.created_at and
            a.event_type == b.event_type and
            std.mem.eql(u8, a.issue_id, b.issue_id) and
            std.mem.eql(u8, a.actor, b.actor) and
            optionalStrEql(a.old_value, b.old_value) and
            optionalStrEql(a.new_value, b.new_value);
    }

    fn optionalStrEql(a: ?[]const u8, b: ?[]const u8) bool {
        const av = a orelse return b == null;
        const bv = b orelse return false;
        return std.mem.eql(u8, av, bv);
    }

    /// Create an event for issue creation.
    pub fn issueCreated(issue_id: []const u8, actor: []const u8, timestamp: i64) Self {
        return Self{
            .id = 0,
            .issue_id = issue_id,
            .event_type = .created,
            .actor = actor,
            .old_value = null,
            .new_value = null,
            .created_at = timestamp,
        };
    }

    /// Create an event for status change.
    pub fn statusChange(
        allocator: std.mem.Allocator,
        issue_id: []const u8,
        actor: []const u8,
        old_status: Status,
        new_status: Status,
        timestamp: i64,
    ) !Self {
        const old_json = try allocator.dupe(u8, old_status.toString());
        const new_json = try allocator.dupe(u8, new_status.toString());

        return Self{
            .id = 0,
            .issue_id = issue_id,
            .event_type = .status_changed,
            .actor = actor,
            .old_value = old_json,
            .new_value = new_json,
            .created_at = timestamp,
        };
    }

    /// Create an event for priority change.
    pub fn priorityChange(
        allocator: std.mem.Allocator,
        issue_id: []const u8,
        actor: []const u8,
        old_priority: Priority,
        new_priority: Priority,
        timestamp: i64,
    ) !Self {
        var old_buf: [8]u8 = undefined;
        var new_buf: [8]u8 = undefined;

        const old_str = std.fmt.bufPrint(&old_buf, "{d}", .{old_priority.value}) catch unreachable;
        const new_str = std.fmt.bufPrint(&new_buf, "{d}", .{new_priority.value}) catch unreachable;

        const old_json = try allocator.dupe(u8, old_str);
        const new_json = try allocator.dupe(u8, new_str);

        return Self{
            .id = 0,
            .issue_id = issue_id,
            .event_type = .priority_changed,
            .actor = actor,
            .old_value = old_json,
            .new_value = new_json,
            .created_at = timestamp,
        };
    }

    /// Create an event for assignee change.
    pub fn assigneeChange(
        allocator: std.mem.Allocator,
        issue_id: []const u8,
        actor: []const u8,
        old_assignee: ?[]const u8,
        new_assignee: ?[]const u8,
        timestamp: i64,
    ) !Self {
        const old_json = if (old_assignee) |a| try allocator.dupe(u8, a) else null;
        const new_json = if (new_assignee) |a| try allocator.dupe(u8, a) else null;

        return Self{
            .id = 0,
            .issue_id = issue_id,
            .event_type = .assignee_changed,
            .actor = actor,
            .old_value = old_json,
            .new_value = new_json,
            .created_at = timestamp,
        };
    }

    /// Create an event for adding a label.
    pub fn labelAdded(
        allocator: std.mem.Allocator,
        issue_id: []const u8,
        actor: []const u8,
        label: []const u8,
        timestamp: i64,
    ) !Self {
        const new_json = try allocator.dupe(u8, label);

        return Self{
            .id = 0,
            .issue_id = issue_id,
            .event_type = .label_added,
            .actor = actor,
            .old_value = null,
            .new_value = new_json,
            .created_at = timestamp,
        };
    }

    /// Create an event for removing a label.
    pub fn labelRemoved(
        allocator: std.mem.Allocator,
        issue_id: []const u8,
        actor: []const u8,
        label: []const u8,
        timestamp: i64,
    ) !Self {
        const old_json = try allocator.dupe(u8, label);

        return Self{
            .id = 0,
            .issue_id = issue_id,
            .event_type = .label_removed,
            .actor = actor,
            .old_value = old_json,
            .new_value = null,
            .created_at = timestamp,
        };
    }

    /// Create an event for adding a dependency.
    pub fn dependencyAdded(
        allocator: std.mem.Allocator,
        issue_id: []const u8,
        actor: []const u8,
        depends_on_id: []const u8,
        timestamp: i64,
    ) !Self {
        const new_json = try allocator.dupe(u8, depends_on_id);

        return Self{
            .id = 0,
            .issue_id = issue_id,
            .event_type = .dependency_added,
            .actor = actor,
            .old_value = null,
            .new_value = new_json,
            .created_at = timestamp,
        };
    }

    /// Create an event for removing a dependency.
    pub fn dependencyRemoved(
        allocator: std.mem.Allocator,
        issue_id: []const u8,
        actor: []const u8,
        depends_on_id: []const u8,
        timestamp: i64,
    ) !Self {
        const old_json = try allocator.dupe(u8, depends_on_id);

        return Self{
            .id = 0,
            .issue_id = issue_id,
            .event_type = .dependency_removed,
            .actor = actor,
            .old_value = old_json,
            .new_value = null,
            .created_at = timestamp,
        };
    }

    /// Create an event for issue closure.
    pub fn issueClosed(
        allocator: std.mem.Allocator,
        issue_id: []const u8,
        actor: []const u8,
        close_reason: ?[]const u8,
        timestamp: i64,
    ) !Self {
        const new_json = if (close_reason) |r| try allocator.dupe(u8, r) else null;

        return Self{
            .id = 0,
            .issue_id = issue_id,
            .event_type = .closed,
            .actor = actor,
            .old_value = null,
            .new_value = new_json,
            .created_at = timestamp,
        };
    }

    /// Create an event for issue reopening.
    pub fn issueReopened(issue_id: []const u8, actor: []const u8, timestamp: i64) Self {
        return Self{
            .id = 0,
            .issue_id = issue_id,
            .event_type = .reopened,
            .actor = actor,
            .old_value = null,
            .new_value = null,
            .created_at = timestamp,
        };
    }

    /// Create an event for issue deletion (tombstone).
    pub fn issueDeleted(issue_id: []const u8, actor: []const u8, timestamp: i64) Self {
        return Self{
            .id = 0,
            .issue_id = issue_id,
            .event_type = .deleted,
            .actor = actor,
            .old_value = null,
            .new_value = null,
            .created_at = timestamp,
        };
    }

    /// Create an event for issue restoration.
    pub fn issueRestored(issue_id: []const u8, actor: []const u8, timestamp: i64) Self {
        return Self{
            .id = 0,
            .issue_id = issue_id,
            .event_type = .restored,
            .actor = actor,
            .old_value = null,
            .new_value = null,
            .created_at = timestamp,
        };
    }
};

// --- EventType Tests ---

test "EventType.toString returns correct strings" {
    try std.testing.expectEqualStrings("created", EventType.created.toString());
    try std.testing.expectEqualStrings("updated", EventType.updated.toString());
    try std.testing.expectEqualStrings("status_changed", EventType.status_changed.toString());
    try std.testing.expectEqualStrings("priority_changed", EventType.priority_changed.toString());
    try std.testing.expectEqualStrings("assignee_changed", EventType.assignee_changed.toString());
    try std.testing.expectEqualStrings("commented", EventType.commented.toString());
    try std.testing.expectEqualStrings("closed", EventType.closed.toString());
    try std.testing.expectEqualStrings("reopened", EventType.reopened.toString());
    try std.testing.expectEqualStrings("dependency_added", EventType.dependency_added.toString());
    try std.testing.expectEqualStrings("dependency_removed", EventType.dependency_removed.toString());
    try std.testing.expectEqualStrings("label_added", EventType.label_added.toString());
    try std.testing.expectEqualStrings("label_removed", EventType.label_removed.toString());
    try std.testing.expectEqualStrings("compacted", EventType.compacted.toString());
    try std.testing.expectEqualStrings("deleted", EventType.deleted.toString());
    try std.testing.expectEqualStrings("restored", EventType.restored.toString());
}

test "EventType.fromString parses known event types" {
    try std.testing.expectEqual(EventType.created, EventType.fromString("created").?);
    try std.testing.expectEqual(EventType.updated, EventType.fromString("updated").?);
    try std.testing.expectEqual(EventType.status_changed, EventType.fromString("status_changed").?);
    try std.testing.expectEqual(EventType.priority_changed, EventType.fromString("priority_changed").?);
    try std.testing.expectEqual(EventType.assignee_changed, EventType.fromString("assignee_changed").?);
    try std.testing.expectEqual(EventType.commented, EventType.fromString("commented").?);
    try std.testing.expectEqual(EventType.closed, EventType.fromString("closed").?);
    try std.testing.expectEqual(EventType.reopened, EventType.fromString("reopened").?);
    try std.testing.expectEqual(EventType.dependency_added, EventType.fromString("dependency_added").?);
    try std.testing.expectEqual(EventType.dependency_removed, EventType.fromString("dependency_removed").?);
    try std.testing.expectEqual(EventType.label_added, EventType.fromString("label_added").?);
    try std.testing.expectEqual(EventType.label_removed, EventType.fromString("label_removed").?);
    try std.testing.expectEqual(EventType.compacted, EventType.fromString("compacted").?);
    try std.testing.expectEqual(EventType.deleted, EventType.fromString("deleted").?);
    try std.testing.expectEqual(EventType.restored, EventType.fromString("restored").?);
}

test "EventType.fromString returns null for unknown values" {
    try std.testing.expect(EventType.fromString("unknown") == null);
    try std.testing.expect(EventType.fromString("") == null);
    try std.testing.expect(EventType.fromString("CREATED") == null);
    try std.testing.expect(EventType.fromString("Created") == null);
}

test "EventType toString/fromString roundtrip" {
    const event_types = [_]EventType{
        .created,
        .updated,
        .status_changed,
        .priority_changed,
        .assignee_changed,
        .commented,
        .closed,
        .reopened,
        .dependency_added,
        .dependency_removed,
        .label_added,
        .label_removed,
        .compacted,
        .deleted,
        .restored,
    };

    for (event_types) |et| {
        const str = et.toString();
        const parsed = EventType.fromString(str);
        try std.testing.expect(parsed != null);
        try std.testing.expectEqual(et, parsed.?);
    }
}

test "EventType JSON serialization roundtrip" {
    const allocator = std.testing.allocator;

    const event_types = [_]EventType{
        .created,
        .updated,
        .status_changed,
        .priority_changed,
        .assignee_changed,
        .commented,
        .closed,
        .reopened,
        .dependency_added,
        .dependency_removed,
        .label_added,
        .label_removed,
        .compacted,
        .deleted,
        .restored,
    };

    for (event_types) |et| {
        var aw: std.io.Writer.Allocating = .init(allocator);
        defer aw.deinit();

        try std.json.Stringify.value(et, .{}, &aw.writer);
        const json_str = aw.written();

        const parsed = try std.json.parseFromSlice(EventType, allocator, json_str, .{});
        defer parsed.deinit();

        try std.testing.expectEqual(et, parsed.value);
    }
}

// --- Event Tests ---

test "Event.validate accepts valid event" {
    const event = Event{
        .id = 1,
        .issue_id = "bd-abc123",
        .event_type = .created,
        .actor = "alice@example.com",
        .old_value = null,
        .new_value = null,
        .created_at = 1706540000,
    };

    try event.validate();
}

test "Event.validate rejects empty actor" {
    const event = Event{
        .id = 1,
        .issue_id = "bd-abc123",
        .event_type = .created,
        .actor = "",
        .old_value = null,
        .new_value = null,
        .created_at = 1706540000,
    };

    try std.testing.expectError(EventError.EmptyActor, event.validate());
}

test "Event.validate rejects empty issue_id" {
    const event = Event{
        .id = 1,
        .issue_id = "",
        .event_type = .created,
        .actor = "alice@example.com",
        .old_value = null,
        .new_value = null,
        .created_at = 1706540000,
    };

    try std.testing.expectError(EventError.EmptyIssueId, event.validate());
}

test "Event.eql compares all fields" {
    const event1 = Event{
        .id = 1,
        .issue_id = "bd-abc123",
        .event_type = .status_changed,
        .actor = "alice@example.com",
        .old_value = "open",
        .new_value = "closed",
        .created_at = 1706540000,
    };

    const event2 = Event{
        .id = 1,
        .issue_id = "bd-abc123",
        .event_type = .status_changed,
        .actor = "alice@example.com",
        .old_value = "open",
        .new_value = "closed",
        .created_at = 1706540000,
    };

    try std.testing.expect(Event.eql(event1, event2));
}

test "Event.eql detects differences" {
    const base = Event{
        .id = 1,
        .issue_id = "bd-abc123",
        .event_type = .status_changed,
        .actor = "alice@example.com",
        .old_value = "open",
        .new_value = "closed",
        .created_at = 1706540000,
    };

    const diff_id = Event{
        .id = 2,
        .issue_id = "bd-abc123",
        .event_type = .status_changed,
        .actor = "alice@example.com",
        .old_value = "open",
        .new_value = "closed",
        .created_at = 1706540000,
    };
    try std.testing.expect(!Event.eql(base, diff_id));

    const diff_event_type = Event{
        .id = 1,
        .issue_id = "bd-abc123",
        .event_type = .priority_changed,
        .actor = "alice@example.com",
        .old_value = "open",
        .new_value = "closed",
        .created_at = 1706540000,
    };
    try std.testing.expect(!Event.eql(base, diff_event_type));

    const diff_old_value = Event{
        .id = 1,
        .issue_id = "bd-abc123",
        .event_type = .status_changed,
        .actor = "alice@example.com",
        .old_value = "in_progress",
        .new_value = "closed",
        .created_at = 1706540000,
    };
    try std.testing.expect(!Event.eql(base, diff_old_value));

    const null_old_value = Event{
        .id = 1,
        .issue_id = "bd-abc123",
        .event_type = .status_changed,
        .actor = "alice@example.com",
        .old_value = null,
        .new_value = "closed",
        .created_at = 1706540000,
    };
    try std.testing.expect(!Event.eql(base, null_old_value));
}

test "Event JSON serialization roundtrip" {
    const allocator = std.testing.allocator;

    const event = Event{
        .id = 42,
        .issue_id = "bd-abc123",
        .event_type = .status_changed,
        .actor = "alice@example.com",
        .old_value = "open",
        .new_value = "closed",
        .created_at = 1706540000,
    };

    var aw: std.io.Writer.Allocating = .init(allocator);
    defer aw.deinit();

    try std.json.Stringify.value(event, .{}, &aw.writer);
    const json_str = aw.written();

    const parsed = try std.json.parseFromSlice(Event, allocator, json_str, .{});
    defer parsed.deinit();

    try std.testing.expect(Event.eql(event, parsed.value));
}

test "Event JSON serialization with null old_value" {
    const allocator = std.testing.allocator;

    const event = Event{
        .id = 1,
        .issue_id = "bd-abc123",
        .event_type = .created,
        .actor = "alice@example.com",
        .old_value = null,
        .new_value = "initial state",
        .created_at = 1706540000,
    };

    var aw: std.io.Writer.Allocating = .init(allocator);
    defer aw.deinit();

    try std.json.Stringify.value(event, .{}, &aw.writer);
    const json_str = aw.written();

    const parsed = try std.json.parseFromSlice(Event, allocator, json_str, .{});
    defer parsed.deinit();

    try std.testing.expect(Event.eql(event, parsed.value));
    try std.testing.expect(parsed.value.old_value == null);
}

test "Event JSON serialization with both values null" {
    const allocator = std.testing.allocator;

    const event = Event{
        .id = 1,
        .issue_id = "bd-abc123",
        .event_type = .deleted,
        .actor = "alice@example.com",
        .old_value = null,
        .new_value = null,
        .created_at = 1706540000,
    };

    var aw: std.io.Writer.Allocating = .init(allocator);
    defer aw.deinit();

    try std.json.Stringify.value(event, .{}, &aw.writer);
    const json_str = aw.written();

    const parsed = try std.json.parseFromSlice(Event, allocator, json_str, .{});
    defer parsed.deinit();

    try std.testing.expect(Event.eql(event, parsed.value));
}

// --- Factory Function Tests ---

test "Event.issueCreated produces valid event" {
    const event = Event.issueCreated("bd-abc123", "alice@example.com", 1706540000);

    try std.testing.expectEqualStrings("bd-abc123", event.issue_id);
    try std.testing.expectEqual(EventType.created, event.event_type);
    try std.testing.expectEqualStrings("alice@example.com", event.actor);
    try std.testing.expect(event.old_value == null);
    try std.testing.expect(event.new_value == null);
    try std.testing.expectEqual(@as(i64, 1706540000), event.created_at);
    try std.testing.expectEqual(@as(i64, 0), event.id);

    try event.validate();
}

test "Event.statusChange produces valid event" {
    const allocator = std.testing.allocator;

    const event = try Event.statusChange(
        allocator,
        "bd-abc123",
        "alice@example.com",
        Status.open,
        Status.closed,
        1706540000,
    );
    defer {
        if (event.old_value) |v| allocator.free(v);
        if (event.new_value) |v| allocator.free(v);
    }

    try std.testing.expectEqual(EventType.status_changed, event.event_type);
    try std.testing.expectEqualStrings("open", event.old_value.?);
    try std.testing.expectEqualStrings("closed", event.new_value.?);

    try event.validate();
}

test "Event.priorityChange produces valid event" {
    const allocator = std.testing.allocator;

    const event = try Event.priorityChange(
        allocator,
        "bd-abc123",
        "alice@example.com",
        Priority.LOW,
        Priority.HIGH,
        1706540000,
    );
    defer {
        if (event.old_value) |v| allocator.free(v);
        if (event.new_value) |v| allocator.free(v);
    }

    try std.testing.expectEqual(EventType.priority_changed, event.event_type);
    try std.testing.expectEqualStrings("3", event.old_value.?);
    try std.testing.expectEqualStrings("1", event.new_value.?);

    try event.validate();
}

test "Event.assigneeChange produces valid event" {
    const allocator = std.testing.allocator;

    const event = try Event.assigneeChange(
        allocator,
        "bd-abc123",
        "admin@example.com",
        "alice@example.com",
        "bob@example.com",
        1706540000,
    );
    defer {
        if (event.old_value) |v| allocator.free(v);
        if (event.new_value) |v| allocator.free(v);
    }

    try std.testing.expectEqual(EventType.assignee_changed, event.event_type);
    try std.testing.expectEqualStrings("alice@example.com", event.old_value.?);
    try std.testing.expectEqualStrings("bob@example.com", event.new_value.?);

    try event.validate();
}

test "Event.assigneeChange handles null assignees" {
    const allocator = std.testing.allocator;

    const event = try Event.assigneeChange(
        allocator,
        "bd-abc123",
        "admin@example.com",
        null,
        "bob@example.com",
        1706540000,
    );
    defer {
        if (event.old_value) |v| allocator.free(v);
        if (event.new_value) |v| allocator.free(v);
    }

    try std.testing.expect(event.old_value == null);
    try std.testing.expectEqualStrings("bob@example.com", event.new_value.?);

    try event.validate();
}

test "Event.labelAdded produces valid event" {
    const allocator = std.testing.allocator;

    const event = try Event.labelAdded(
        allocator,
        "bd-abc123",
        "alice@example.com",
        "urgent",
        1706540000,
    );
    defer {
        if (event.new_value) |v| allocator.free(v);
    }

    try std.testing.expectEqual(EventType.label_added, event.event_type);
    try std.testing.expect(event.old_value == null);
    try std.testing.expectEqualStrings("urgent", event.new_value.?);

    try event.validate();
}

test "Event.labelRemoved produces valid event" {
    const allocator = std.testing.allocator;

    const event = try Event.labelRemoved(
        allocator,
        "bd-abc123",
        "alice@example.com",
        "wontfix",
        1706540000,
    );
    defer {
        if (event.old_value) |v| allocator.free(v);
    }

    try std.testing.expectEqual(EventType.label_removed, event.event_type);
    try std.testing.expectEqualStrings("wontfix", event.old_value.?);
    try std.testing.expect(event.new_value == null);

    try event.validate();
}

test "Event.dependencyAdded produces valid event" {
    const allocator = std.testing.allocator;

    const event = try Event.dependencyAdded(
        allocator,
        "bd-abc123",
        "alice@example.com",
        "bd-def456",
        1706540000,
    );
    defer {
        if (event.new_value) |v| allocator.free(v);
    }

    try std.testing.expectEqual(EventType.dependency_added, event.event_type);
    try std.testing.expect(event.old_value == null);
    try std.testing.expectEqualStrings("bd-def456", event.new_value.?);

    try event.validate();
}

test "Event.dependencyRemoved produces valid event" {
    const allocator = std.testing.allocator;

    const event = try Event.dependencyRemoved(
        allocator,
        "bd-abc123",
        "alice@example.com",
        "bd-def456",
        1706540000,
    );
    defer {
        if (event.old_value) |v| allocator.free(v);
    }

    try std.testing.expectEqual(EventType.dependency_removed, event.event_type);
    try std.testing.expectEqualStrings("bd-def456", event.old_value.?);
    try std.testing.expect(event.new_value == null);

    try event.validate();
}

test "Event.issueClosed produces valid event" {
    const allocator = std.testing.allocator;

    const event = try Event.issueClosed(
        allocator,
        "bd-abc123",
        "alice@example.com",
        "completed",
        1706540000,
    );
    defer {
        if (event.new_value) |v| allocator.free(v);
    }

    try std.testing.expectEqual(EventType.closed, event.event_type);
    try std.testing.expect(event.old_value == null);
    try std.testing.expectEqualStrings("completed", event.new_value.?);

    try event.validate();
}

test "Event.issueClosed handles null close_reason" {
    const allocator = std.testing.allocator;

    const event = try Event.issueClosed(
        allocator,
        "bd-abc123",
        "alice@example.com",
        null,
        1706540000,
    );

    try std.testing.expectEqual(EventType.closed, event.event_type);
    try std.testing.expect(event.old_value == null);
    try std.testing.expect(event.new_value == null);

    try event.validate();
}

test "Event.issueReopened produces valid event" {
    const event = Event.issueReopened("bd-abc123", "alice@example.com", 1706540000);

    try std.testing.expectEqual(EventType.reopened, event.event_type);
    try std.testing.expect(event.old_value == null);
    try std.testing.expect(event.new_value == null);

    try event.validate();
}

test "Event.issueDeleted produces valid event" {
    const event = Event.issueDeleted("bd-abc123", "alice@example.com", 1706540000);

    try std.testing.expectEqual(EventType.deleted, event.event_type);
    try std.testing.expect(event.old_value == null);
    try std.testing.expect(event.new_value == null);

    try event.validate();
}

test "Event.issueRestored produces valid event" {
    const event = Event.issueRestored("bd-abc123", "alice@example.com", 1706540000);

    try std.testing.expectEqual(EventType.restored, event.event_type);
    try std.testing.expect(event.old_value == null);
    try std.testing.expect(event.new_value == null);

    try event.validate();
}
