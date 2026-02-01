//! Event storage for beads_zig audit trail.
//!
//! Provides persistent storage for audit events, recording all changes
//! to issues, dependencies, labels, and comments. Events are stored in
//! a JSONL file (events.jsonl) in chronological order.
//!
//! Design:
//! - Events are append-only (never modified once written)
//! - Events use auto-incrementing IDs
//! - Events are stored with the issue ID for efficient filtering
//! - Events can be replayed to reconstruct issue history

const std = @import("std");
const fs = std.fs;
const Event = @import("../models/event.zig").Event;
const EventType = @import("../models/event.zig").EventType;

pub const EventStoreError = error{
    WriteError,
    ParseError,
    FileNotFound,
    OutOfMemory,
};

/// Persistent store for audit events.
pub const EventStore = struct {
    allocator: std.mem.Allocator,
    events_path: []const u8,
    next_id: i64,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, events_path: []const u8) Self {
        return .{
            .allocator = allocator,
            .events_path = events_path,
            .next_id = 1,
        };
    }

    /// Load existing events to determine next ID.
    /// Call this after init to ensure IDs are unique.
    pub fn loadNextId(self: *Self) !void {
        const file = fs.cwd().openFile(self.events_path, .{}) catch |err| switch (err) {
            error.FileNotFound => return, // Start from 1
            else => return err,
        };
        defer file.close();

        const content = file.readToEndAlloc(self.allocator, 100 * 1024 * 1024) catch return EventStoreError.ParseError;
        defer self.allocator.free(content);

        var max_id: i64 = 0;
        var line_start: usize = 0;
        for (content, 0..) |c, i| {
            if (c == '\n') {
                const line = content[line_start..i];
                line_start = i + 1;

                if (line.len == 0) continue;

                if (self.parseEventId(line)) |id| {
                    if (id > max_id) max_id = id;
                }
            }
        }

        // Handle last line
        if (line_start < content.len) {
            const line = content[line_start..];
            if (line.len > 0) {
                if (self.parseEventId(line)) |id| {
                    if (id > max_id) max_id = id;
                }
            }
        }

        self.next_id = max_id + 1;
    }

    /// Parse just the ID from a JSON event line.
    fn parseEventId(self: *Self, line: []const u8) ?i64 {
        const parsed = std.json.parseFromSlice(
            struct { id: i64 },
            self.allocator,
            line,
            .{ .ignore_unknown_fields = true },
        ) catch return null;
        defer parsed.deinit();
        return parsed.value.id;
    }

    /// Append an event to the store.
    /// Returns the assigned event ID.
    pub fn append(self: *Self, event: Event) !i64 {
        const dir = fs.cwd();

        // Ensure parent directory exists
        if (std.fs.path.dirname(self.events_path)) |parent| {
            dir.makePath(parent) catch |err| switch (err) {
                error.PathAlreadyExists => {},
                else => return err,
            };
        }

        // Open or create file in append mode
        const file = dir.createFile(self.events_path, .{
            .truncate = false,
        }) catch return EventStoreError.WriteError;
        defer file.close();

        // Seek to end
        file.seekFromEnd(0) catch return EventStoreError.WriteError;

        // Assign ID
        const event_id = self.next_id;
        self.next_id += 1;

        // Create event with assigned ID
        const stored_event = Event{
            .id = event_id,
            .issue_id = event.issue_id,
            .event_type = event.event_type,
            .actor = event.actor,
            .old_value = event.old_value,
            .new_value = event.new_value,
            .created_at = event.created_at,
        };

        // Serialize
        const json_bytes = std.json.Stringify.valueAlloc(self.allocator, stored_event, .{}) catch return EventStoreError.WriteError;
        defer self.allocator.free(json_bytes);

        // Write
        file.writeAll(json_bytes) catch return EventStoreError.WriteError;
        file.writeAll("\n") catch return EventStoreError.WriteError;

        // fsync for durability
        file.sync() catch return EventStoreError.WriteError;

        return event_id;
    }

    /// Get all events for a specific issue.
    pub fn getEventsForIssue(self: *Self, issue_id: []const u8) ![]Event {
        return self.queryEvents(.{ .issue_id = issue_id });
    }

    /// Get all events (project-wide audit log).
    pub fn getAllEvents(self: *Self) ![]Event {
        return self.queryEvents(.{});
    }

    /// Query parameters for filtering events.
    pub const QueryParams = struct {
        issue_id: ?[]const u8 = null,
        event_type: ?EventType = null,
        actor: ?[]const u8 = null,
        since: ?i64 = null, // Events after this timestamp
        until: ?i64 = null, // Events before this timestamp
        limit: ?usize = null,
    };

    /// Query events with optional filters.
    pub fn queryEvents(self: *Self, params: QueryParams) ![]Event {
        const file = fs.cwd().openFile(self.events_path, .{}) catch |err| switch (err) {
            error.FileNotFound => return &[_]Event{},
            else => return err,
        };
        defer file.close();

        const content = file.readToEndAlloc(self.allocator, 100 * 1024 * 1024) catch return EventStoreError.ParseError;
        defer self.allocator.free(content);

        var events: std.ArrayListUnmanaged(Event) = .{};
        errdefer {
            for (events.items) |*e| {
                self.freeEvent(e);
            }
            events.deinit(self.allocator);
        }

        var line_start: usize = 0;
        for (content, 0..) |c, i| {
            if (c == '\n') {
                const line = content[line_start..i];
                line_start = i + 1;

                if (line.len == 0) continue;

                if (self.parseAndFilterEvent(line, params)) |event| {
                    try events.append(self.allocator, event);

                    // Check limit
                    if (params.limit) |lim| {
                        if (events.items.len >= lim) break;
                    }
                }
            }
        }

        // Handle last line
        if (line_start < content.len) {
            const line = content[line_start..];
            if (line.len > 0) {
                if (self.parseAndFilterEvent(line, params)) |event| {
                    const should_add = if (params.limit) |lim| events.items.len < lim else true;
                    if (should_add) {
                        try events.append(self.allocator, event);
                    } else {
                        var e = event;
                        self.freeEvent(&e);
                    }
                }
            }
        }

        return events.toOwnedSlice(self.allocator);
    }

    /// Parse an event line and check if it matches filters.
    fn parseAndFilterEvent(self: *Self, line: []const u8, params: QueryParams) ?Event {
        const parsed = std.json.parseFromSlice(Event, self.allocator, line, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        }) catch return null;

        const event = parsed.value;

        // Apply filters
        if (params.issue_id) |id| {
            if (!std.mem.eql(u8, event.issue_id, id)) {
                parsed.deinit();
                return null;
            }
        }
        if (params.event_type) |et| {
            if (event.event_type != et) {
                parsed.deinit();
                return null;
            }
        }
        if (params.actor) |a| {
            if (!std.mem.eql(u8, event.actor, a)) {
                parsed.deinit();
                return null;
            }
        }
        if (params.since) |s| {
            if (event.created_at < s) {
                parsed.deinit();
                return null;
            }
        }
        if (params.until) |u| {
            if (event.created_at > u) {
                parsed.deinit();
                return null;
            }
        }

        // Clone strings since parsed will be freed
        const issue_id = self.allocator.dupe(u8, event.issue_id) catch {
            parsed.deinit();
            return null;
        };
        errdefer self.allocator.free(issue_id);

        const actor = self.allocator.dupe(u8, event.actor) catch {
            parsed.deinit();
            return null;
        };
        errdefer self.allocator.free(actor);

        const old_value = if (event.old_value) |v| self.allocator.dupe(u8, v) catch {
            parsed.deinit();
            return null;
        } else null;
        errdefer if (old_value) |v| self.allocator.free(v);

        const new_value = if (event.new_value) |v| self.allocator.dupe(u8, v) catch {
            parsed.deinit();
            return null;
        } else null;

        parsed.deinit();
        return Event{
            .id = event.id,
            .issue_id = issue_id,
            .event_type = event.event_type,
            .actor = actor,
            .old_value = old_value,
            .new_value = new_value,
            .created_at = event.created_at,
        };
    }

    /// Free an event's allocated strings.
    pub fn freeEvent(self: *Self, event: *Event) void {
        self.allocator.free(event.issue_id);
        self.allocator.free(event.actor);
        if (event.old_value) |v| self.allocator.free(v);
        if (event.new_value) |v| self.allocator.free(v);
    }

    /// Free a slice of events.
    pub fn freeEvents(self: *Self, events: []Event) void {
        for (events) |*e| {
            self.freeEvent(e);
        }
        self.allocator.free(events);
    }

    /// Get the total count of events.
    pub fn count(self: *Self) !usize {
        const events = try self.getAllEvents();
        defer self.freeEvents(events);
        return events.len;
    }

    /// Check if the events file exists.
    pub fn exists(self: *Self) bool {
        fs.cwd().access(self.events_path, .{}) catch return false;
        return true;
    }
};

// --- Tests ---

const test_util = @import("../test_util.zig");

test "EventStore.init" {
    const allocator = std.testing.allocator;
    const store = EventStore.init(allocator, "test/events.jsonl");
    try std.testing.expectEqual(@as(i64, 1), store.next_id);
}

test "EventStore.append and query" {
    const allocator = std.testing.allocator;
    const test_dir = try test_util.createTestDir(allocator, "events_append");
    defer allocator.free(test_dir);
    defer test_util.cleanupTestDir(test_dir);

    const events_path = try std.fs.path.join(allocator, &.{ test_dir, "events.jsonl" });
    defer allocator.free(events_path);

    var store = EventStore.init(allocator, events_path);

    // Append an event
    const event = Event.issueCreated("bd-test1", "alice@example.com", 1706540000);
    const id = try store.append(event);

    try std.testing.expectEqual(@as(i64, 1), id);

    // Query events
    const events = try store.getEventsForIssue("bd-test1");
    defer store.freeEvents(events);

    try std.testing.expectEqual(@as(usize, 1), events.len);
    try std.testing.expectEqualStrings("bd-test1", events[0].issue_id);
    try std.testing.expectEqual(EventType.created, events[0].event_type);
}

test "EventStore.append assigns sequential IDs" {
    const allocator = std.testing.allocator;
    const test_dir = try test_util.createTestDir(allocator, "events_seq_ids");
    defer allocator.free(test_dir);
    defer test_util.cleanupTestDir(test_dir);

    const events_path = try std.fs.path.join(allocator, &.{ test_dir, "events.jsonl" });
    defer allocator.free(events_path);

    var store = EventStore.init(allocator, events_path);

    const id1 = try store.append(Event.issueCreated("bd-1", "alice", 1706540000));
    const id2 = try store.append(Event.issueCreated("bd-2", "alice", 1706540001));
    const id3 = try store.append(Event.issueCreated("bd-3", "alice", 1706540002));

    try std.testing.expectEqual(@as(i64, 1), id1);
    try std.testing.expectEqual(@as(i64, 2), id2);
    try std.testing.expectEqual(@as(i64, 3), id3);
}

test "EventStore.loadNextId resumes from existing events" {
    const allocator = std.testing.allocator;
    const test_dir = try test_util.createTestDir(allocator, "events_load_id");
    defer allocator.free(test_dir);
    defer test_util.cleanupTestDir(test_dir);

    const events_path = try std.fs.path.join(allocator, &.{ test_dir, "events.jsonl" });
    defer allocator.free(events_path);

    // Create some events
    {
        var store = EventStore.init(allocator, events_path);
        _ = try store.append(Event.issueCreated("bd-1", "alice", 1706540000));
        _ = try store.append(Event.issueCreated("bd-2", "alice", 1706540001));
        _ = try store.append(Event.issueCreated("bd-3", "alice", 1706540002));
    }

    // Reopen store and load next ID
    {
        var store = EventStore.init(allocator, events_path);
        try store.loadNextId();

        try std.testing.expectEqual(@as(i64, 4), store.next_id);

        // Append should use next ID
        const id = try store.append(Event.issueCreated("bd-4", "alice", 1706540003));
        try std.testing.expectEqual(@as(i64, 4), id);
    }
}

test "EventStore.queryEvents filters by issue_id" {
    const allocator = std.testing.allocator;
    const test_dir = try test_util.createTestDir(allocator, "events_filter_issue");
    defer allocator.free(test_dir);
    defer test_util.cleanupTestDir(test_dir);

    const events_path = try std.fs.path.join(allocator, &.{ test_dir, "events.jsonl" });
    defer allocator.free(events_path);

    var store = EventStore.init(allocator, events_path);

    _ = try store.append(Event.issueCreated("bd-1", "alice", 1706540000));
    _ = try store.append(Event.issueCreated("bd-2", "bob", 1706540001));
    _ = try store.append(Event.issueReopened("bd-1", "charlie", 1706540002));

    const events = try store.getEventsForIssue("bd-1");
    defer store.freeEvents(events);

    try std.testing.expectEqual(@as(usize, 2), events.len);
    for (events) |e| {
        try std.testing.expectEqualStrings("bd-1", e.issue_id);
    }
}

test "EventStore.queryEvents filters by event_type" {
    const allocator = std.testing.allocator;
    const test_dir = try test_util.createTestDir(allocator, "events_filter_type");
    defer allocator.free(test_dir);
    defer test_util.cleanupTestDir(test_dir);

    const events_path = try std.fs.path.join(allocator, &.{ test_dir, "events.jsonl" });
    defer allocator.free(events_path);

    var store = EventStore.init(allocator, events_path);

    _ = try store.append(Event.issueCreated("bd-1", "alice", 1706540000));
    _ = try store.append(Event.issueReopened("bd-1", "bob", 1706540001));
    _ = try store.append(Event.issueCreated("bd-2", "charlie", 1706540002));

    const events = try store.queryEvents(.{ .event_type = .created });
    defer store.freeEvents(events);

    try std.testing.expectEqual(@as(usize, 2), events.len);
    for (events) |e| {
        try std.testing.expectEqual(EventType.created, e.event_type);
    }
}

test "EventStore.queryEvents returns empty for missing file" {
    const allocator = std.testing.allocator;

    var store = EventStore.init(allocator, "/nonexistent/events.jsonl");
    const events = try store.getAllEvents();
    defer store.freeEvents(events);

    try std.testing.expectEqual(@as(usize, 0), events.len);
}

test "EventStore.count" {
    const allocator = std.testing.allocator;
    const test_dir = try test_util.createTestDir(allocator, "events_count");
    defer allocator.free(test_dir);
    defer test_util.cleanupTestDir(test_dir);

    const events_path = try std.fs.path.join(allocator, &.{ test_dir, "events.jsonl" });
    defer allocator.free(events_path);

    var store = EventStore.init(allocator, events_path);

    _ = try store.append(Event.issueCreated("bd-1", "alice", 1706540000));
    _ = try store.append(Event.issueCreated("bd-2", "bob", 1706540001));
    _ = try store.append(Event.issueCreated("bd-3", "charlie", 1706540002));

    const total = try store.count();
    try std.testing.expectEqual(@as(usize, 3), total);
}
