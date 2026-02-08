//! SQLite-backed event storage for the beads_zig audit trail.
//!
//! Events are stored in the `events` table with autoincrement IDs.
//! Schema: id, issue_id, event_type, actor, old_value, new_value, comment, created_at

const std = @import("std");
const sqlite = @import("zqlite");
const Database = sqlite.Database;
const Statement = sqlite.Statement;
const Event = @import("../models/event.zig").Event;
const EventType = @import("../models/event.zig").EventType;

pub const EventStoreError = error{
    QueryFailed,
};

pub const EventStore = struct {
    db: *Database,
    allocator: std.mem.Allocator,

    const Self = @This();

    const select_cols = "id, issue_id, event_type, actor, old_value, new_value, comment, created_at";

    pub fn init(db: *Database, allocator: std.mem.Allocator) Self {
        return .{ .db = db, .allocator = allocator };
    }

    pub fn insert(self: *Self, event: Event) !void {
        var stmt = try self.db.prepare(
            "INSERT INTO events (issue_id, event_type, actor, old_value, new_value, comment, created_at) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
        );
        defer stmt.deinit();

        try stmt.bindText(1, event.issue_id);
        try stmt.bindText(2, event.event_type.toString());
        try stmt.bindText(3, event.actor);
        try stmt.bindText(4, event.old_value);
        try stmt.bindText(5, event.new_value);
        try stmt.bindText(6, event.comment);
        try stmt.bindInt(7, event.created_at);

        _ = try stmt.step();
    }

    pub fn getForIssue(self: *Self, issue_id: []const u8) ![]Event {
        var stmt = try self.db.prepare("SELECT " ++ select_cols ++ " FROM events WHERE issue_id = ?1 ORDER BY id ASC");
        defer stmt.deinit();

        try stmt.bindText(1, issue_id);
        return self.collectRows(&stmt);
    }

    pub fn getAll(self: *Self, limit: ?u32) ![]Event {
        if (limit) |lim| {
            var stmt = try self.db.prepare("SELECT " ++ select_cols ++ " FROM events ORDER BY id ASC LIMIT ?1");
            defer stmt.deinit();
            try stmt.bindInt(1, @intCast(lim));
            return self.collectRows(&stmt);
        } else {
            var stmt = try self.db.prepare("SELECT " ++ select_cols ++ " FROM events ORDER BY id ASC");
            defer stmt.deinit();
            return self.collectRows(&stmt);
        }
    }

    pub fn getByType(self: *Self, event_type: []const u8) ![]Event {
        var stmt = try self.db.prepare("SELECT " ++ select_cols ++ " FROM events WHERE event_type = ?1 ORDER BY id ASC");
        defer stmt.deinit();

        try stmt.bindText(1, event_type);
        return self.collectRows(&stmt);
    }

    pub fn count(self: *Self) !u64 {
        var stmt = try self.db.prepare("SELECT COUNT(*) FROM events");
        defer stmt.deinit();
        _ = try stmt.step();
        return @intCast(stmt.columnInt(0));
    }

    pub fn freeEvents(self: *Self, events: []Event) void {
        for (events) |*e| {
            self.freeEvent(@constCast(e));
        }
        self.allocator.free(events);
    }

    fn collectRows(self: *Self, stmt: *Statement) ![]Event {
        var list: std.ArrayList(Event) = .empty;
        errdefer {
            for (list.items) |*e| {
                self.freeEvent(e);
            }
            list.deinit(self.allocator);
        }

        while (try stmt.step()) {
            const event = Event{
                .id = stmt.columnInt(0),
                .issue_id = try self.allocator.dupe(u8, stmt.columnText(1) orelse return error.QueryFailed),
                .event_type = EventType.fromString(stmt.columnText(2) orelse return error.QueryFailed) orelse return error.QueryFailed,
                .actor = try self.allocator.dupe(u8, stmt.columnText(3) orelse return error.QueryFailed),
                .old_value = if (stmt.columnText(4)) |v| try self.allocator.dupe(u8, v) else null,
                .new_value = if (stmt.columnText(5)) |v| try self.allocator.dupe(u8, v) else null,
                .comment = if (stmt.columnText(6)) |v| try self.allocator.dupe(u8, v) else null,
                .created_at = stmt.columnInt(7),
            };
            try list.append(self.allocator, event);
        }

        return list.toOwnedSlice(self.allocator);
    }

    fn freeEvent(self: *Self, e: *Event) void {
        self.allocator.free(e.issue_id);
        self.allocator.free(e.actor);
        if (e.old_value) |v| self.allocator.free(v);
        if (e.new_value) |v| self.allocator.free(v);
        if (e.comment) |v| self.allocator.free(v);
    }
};

// --- Tests ---

const sql_schema = @import("schema.zig");

fn setupTestDb() !struct { db: Database, allocator: std.mem.Allocator } {
    const allocator = std.testing.allocator;
    var db = try Database.open(allocator, ":memory:");
    try sql_schema.createSchema(&db);
    // Insert a test issue for FK constraints
    try db.exec(
        \\INSERT INTO issues (id, title, created_at, updated_at)
        \\VALUES ('bd-test1', 'Test Issue', 1706540000, 1706540000)
    );
    try db.exec(
        \\INSERT INTO issues (id, title, created_at, updated_at)
        \\VALUES ('bd-test2', 'Test Issue 2', 1706540001, 1706540001)
    );
    return .{ .db = db, .allocator = allocator };
}

test "EventStore insert and getForIssue" {
    var ctx = try setupTestDb();
    defer ctx.db.close();

    var store = EventStore.init(&ctx.db, ctx.allocator);
    const event = Event.issueCreated("bd-test1", "alice", 1706540000);
    try store.insert(event);

    const events = try store.getForIssue("bd-test1");
    defer store.freeEvents(events);

    try std.testing.expectEqual(@as(usize, 1), events.len);
    try std.testing.expectEqualStrings("bd-test1", events[0].issue_id);
    try std.testing.expectEqual(EventType.created, events[0].event_type);
    try std.testing.expectEqualStrings("alice", events[0].actor);
    try std.testing.expectEqual(@as(i64, 1706540000), events[0].created_at);
    try std.testing.expect(events[0].id > 0);
}

test "EventStore insert multiple and getAll" {
    var ctx = try setupTestDb();
    defer ctx.db.close();

    var store = EventStore.init(&ctx.db, ctx.allocator);

    try store.insert(Event.issueCreated("bd-test1", "alice", 1706540000));
    try store.insert(Event.issueCreated("bd-test2", "bob", 1706540001));
    try store.insert(Event.issueReopened("bd-test1", "charlie", 1706540002));

    const all = try store.getAll(null);
    defer store.freeEvents(all);
    try std.testing.expectEqual(@as(usize, 3), all.len);

    const limited = try store.getAll(2);
    defer store.freeEvents(limited);
    try std.testing.expectEqual(@as(usize, 2), limited.len);
}

test "EventStore getForIssue filters correctly" {
    var ctx = try setupTestDb();
    defer ctx.db.close();

    var store = EventStore.init(&ctx.db, ctx.allocator);

    try store.insert(Event.issueCreated("bd-test1", "alice", 1706540000));
    try store.insert(Event.issueCreated("bd-test2", "bob", 1706540001));
    try store.insert(Event.issueReopened("bd-test1", "charlie", 1706540002));

    const events = try store.getForIssue("bd-test1");
    defer store.freeEvents(events);

    try std.testing.expectEqual(@as(usize, 2), events.len);
    for (events) |e| {
        try std.testing.expectEqualStrings("bd-test1", e.issue_id);
    }
}

test "EventStore getByType" {
    var ctx = try setupTestDb();
    defer ctx.db.close();

    var store = EventStore.init(&ctx.db, ctx.allocator);

    try store.insert(Event.issueCreated("bd-test1", "alice", 1706540000));
    try store.insert(Event.issueReopened("bd-test1", "bob", 1706540001));
    try store.insert(Event.issueCreated("bd-test2", "charlie", 1706540002));

    const events = try store.getByType("created");
    defer store.freeEvents(events);

    try std.testing.expectEqual(@as(usize, 2), events.len);
    for (events) |e| {
        try std.testing.expectEqual(EventType.created, e.event_type);
    }
}

test "EventStore count" {
    var ctx = try setupTestDb();
    defer ctx.db.close();

    var store = EventStore.init(&ctx.db, ctx.allocator);

    try store.insert(Event.issueCreated("bd-test1", "alice", 1706540000));
    try store.insert(Event.issueCreated("bd-test2", "bob", 1706540001));
    try store.insert(Event.issueCreated("bd-test1", "charlie", 1706540002));

    const total = try store.count();
    try std.testing.expectEqual(@as(u64, 3), total);
}

test "EventStore handles old_value and new_value" {
    var ctx = try setupTestDb();
    defer ctx.db.close();

    var store = EventStore.init(&ctx.db, ctx.allocator);

    const event = Event{
        .id = 0,
        .issue_id = "bd-test1",
        .event_type = .status_changed,
        .actor = "alice",
        .old_value = "open",
        .new_value = "closed",
        .created_at = 1706540000,
    };
    try store.insert(event);

    const events = try store.getForIssue("bd-test1");
    defer store.freeEvents(events);

    try std.testing.expectEqual(@as(usize, 1), events.len);
    try std.testing.expectEqualStrings("open", events[0].old_value.?);
    try std.testing.expectEqualStrings("closed", events[0].new_value.?);
}

test "EventStore handles null old_value and new_value" {
    var ctx = try setupTestDb();
    defer ctx.db.close();

    var store = EventStore.init(&ctx.db, ctx.allocator);

    const event = Event.issueCreated("bd-test1", "alice", 1706540000);
    try store.insert(event);

    const events = try store.getForIssue("bd-test1");
    defer store.freeEvents(events);

    try std.testing.expectEqual(@as(usize, 1), events.len);
    try std.testing.expect(events[0].old_value == null);
    try std.testing.expect(events[0].new_value == null);
}

test "EventStore empty result for unknown issue" {
    var ctx = try setupTestDb();
    defer ctx.db.close();

    var store = EventStore.init(&ctx.db, ctx.allocator);

    const events = try store.getForIssue("bd-nonexistent");
    defer store.freeEvents(events);

    try std.testing.expectEqual(@as(usize, 0), events.len);
}

test "EventStore autoincrement IDs" {
    var ctx = try setupTestDb();
    defer ctx.db.close();

    var store = EventStore.init(&ctx.db, ctx.allocator);

    try store.insert(Event.issueCreated("bd-test1", "alice", 1706540000));
    try store.insert(Event.issueCreated("bd-test1", "bob", 1706540001));
    try store.insert(Event.issueCreated("bd-test1", "charlie", 1706540002));

    const events = try store.getForIssue("bd-test1");
    defer store.freeEvents(events);

    try std.testing.expectEqual(@as(usize, 3), events.len);
    try std.testing.expect(events[0].id < events[1].id);
    try std.testing.expect(events[1].id < events[2].id);
}
