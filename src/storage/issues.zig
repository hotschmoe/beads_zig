//! Issue storage operations for beads_zig.
//!
//! Provides CRUD operations for issues including:
//! - Insert new issues
//! - Get issues by ID (with or without embedded relations)
//! - Update issue fields
//! - Soft delete (tombstone)
//! - List issues with filters
//! - Count issues grouped by field
//!
//! This module wraps the in-memory IssueStore for backwards compatibility.

const std = @import("std");
const store_mod = @import("store.zig");
const Issue = @import("../models/issue.zig").Issue;
const Rfc3339Timestamp = @import("../models/issue.zig").Rfc3339Timestamp;
const Status = @import("../models/status.zig").Status;
const Priority = @import("../models/priority.zig").Priority;
const IssueType = @import("../models/issue_type.zig").IssueType;
const Dependency = @import("../models/dependency.zig").Dependency;
const Comment = @import("../models/comment.zig").Comment;

pub const IssueStoreError = store_mod.IssueStoreError;

/// Re-export IssueStore from store.zig for backwards compatibility.
pub const IssueStore = store_mod.IssueStore;

// --- Tests ---

test "IssueStore.insert creates issue" {
    const allocator = std.testing.allocator;
    var store = IssueStore.init(allocator, "test_insert.jsonl");
    defer store.deinit();

    const issue = Issue.init("bd-test1", "Test Issue", 1706540000);
    try store.insert(issue);

    const found = try store.exists("bd-test1");
    try std.testing.expect(found);
}

test "IssueStore.get retrieves issue" {
    const allocator = std.testing.allocator;
    var store = IssueStore.init(allocator, "test_get.jsonl");
    defer store.deinit();

    const original = Issue.init("bd-test2", "Get Test", 1706540000);
    try store.insert(original);

    var retrieved = (try store.get("bd-test2")).?;
    defer retrieved.deinit(allocator);

    try std.testing.expectEqualStrings("bd-test2", retrieved.id);
    try std.testing.expectEqualStrings("Get Test", retrieved.title);
    try std.testing.expectEqual(Status.open, retrieved.status);
    try std.testing.expectEqual(Priority.MEDIUM, retrieved.priority);
}

test "IssueStore.get returns null for missing issue" {
    const allocator = std.testing.allocator;
    var store = IssueStore.init(allocator, "test_missing.jsonl");
    defer store.deinit();

    const result = try store.get("bd-nonexistent");
    try std.testing.expect(result == null);
}

test "IssueStore.update modifies fields" {
    const allocator = std.testing.allocator;
    var store = IssueStore.init(allocator, "test_update.jsonl");
    defer store.deinit();

    const issue = Issue.init("bd-update", "Original Title", 1706540000);
    try store.insert(issue);

    try store.update("bd-update", .{
        .title = "Updated Title",
        .status = .in_progress,
        .priority = Priority.HIGH,
    }, 1706550000);

    var updated = (try store.get("bd-update")).?;
    defer updated.deinit(allocator);

    try std.testing.expectEqualStrings("Updated Title", updated.title);
    try std.testing.expectEqual(@as(i64, 1706550000), updated.updated_at.value);
}

test "IssueStore.update returns error for missing issue" {
    const allocator = std.testing.allocator;
    var store = IssueStore.init(allocator, "test_update_missing.jsonl");
    defer store.deinit();

    const result = store.update("bd-missing", .{ .title = "New" }, 1706550000);
    try std.testing.expectError(IssueStoreError.IssueNotFound, result);
}

test "IssueStore.delete sets tombstone status" {
    const allocator = std.testing.allocator;
    var store = IssueStore.init(allocator, "test_delete.jsonl");
    defer store.deinit();

    const issue = Issue.init("bd-delete", "To Delete", 1706540000);
    try store.insert(issue);
    try store.delete("bd-delete", 1706550000);

    var deleted = (try store.get("bd-delete")).?;
    defer deleted.deinit(allocator);

    try std.testing.expectEqual(Status.tombstone, deleted.status);
}

test "IssueStore.list returns issues" {
    const allocator = std.testing.allocator;
    var store = IssueStore.init(allocator, "test_list.jsonl");
    defer store.deinit();

    try store.insert(Issue.init("bd-list1", "Issue 1", 1706540000));
    try store.insert(Issue.init("bd-list2", "Issue 2", 1706550000));
    try store.insert(Issue.init("bd-list3", "Issue 3", 1706560000));

    const issues = try store.list(.{});
    defer {
        for (issues) |*issue| {
            var i = issue.*;
            i.deinit(allocator);
        }
        allocator.free(issues);
    }

    try std.testing.expectEqual(@as(usize, 3), issues.len);
}

test "IssueStore.list excludes tombstones by default" {
    const allocator = std.testing.allocator;
    var store = IssueStore.init(allocator, "test_tombstone.jsonl");
    defer store.deinit();

    try store.insert(Issue.init("bd-active", "Active", 1706540000));
    try store.insert(Issue.init("bd-deleted", "Deleted", 1706550000));
    try store.delete("bd-deleted", 1706560000);

    const issues = try store.list(.{});
    defer {
        for (issues) |*issue| {
            var i = issue.*;
            i.deinit(allocator);
        }
        allocator.free(issues);
    }

    try std.testing.expectEqual(@as(usize, 1), issues.len);
    try std.testing.expectEqualStrings("bd-active", issues[0].id);
}

test "IssueStore.list with status filter" {
    const allocator = std.testing.allocator;
    var store = IssueStore.init(allocator, "test_status_filter.jsonl");
    defer store.deinit();

    var issue1 = Issue.init("bd-open", "Open Issue", 1706540000);
    issue1.status = .open;
    try store.insert(issue1);

    var issue2 = Issue.init("bd-closed", "Closed Issue", 1706550000);
    issue2.status = .closed;
    try store.insert(issue2);

    const issues = try store.list(.{ .status = .open });
    defer {
        for (issues) |*issue| {
            var i = issue.*;
            i.deinit(allocator);
        }
        allocator.free(issues);
    }

    try std.testing.expectEqual(@as(usize, 1), issues.len);
    try std.testing.expectEqualStrings("bd-open", issues[0].id);
}

test "IssueStore.list with priority filter" {
    const allocator = std.testing.allocator;
    var store = IssueStore.init(allocator, "test_priority_filter.jsonl");
    defer store.deinit();

    var issue1 = Issue.init("bd-high", "High Priority", 1706540000);
    issue1.priority = Priority.HIGH;
    try store.insert(issue1);

    var issue2 = Issue.init("bd-low", "Low Priority", 1706550000);
    issue2.priority = Priority.LOW;
    try store.insert(issue2);

    const issues = try store.list(.{ .priority = Priority.HIGH });
    defer {
        for (issues) |*issue| {
            var i = issue.*;
            i.deinit(allocator);
        }
        allocator.free(issues);
    }

    try std.testing.expectEqual(@as(usize, 1), issues.len);
    try std.testing.expectEqualStrings("bd-high", issues[0].id);
}

test "IssueStore.list with limit and offset" {
    const allocator = std.testing.allocator;
    var store = IssueStore.init(allocator, "test_limit_offset.jsonl");
    defer store.deinit();

    try store.insert(Issue.init("bd-1", "Issue 1", 1706540000));
    try store.insert(Issue.init("bd-2", "Issue 2", 1706550000));
    try store.insert(Issue.init("bd-3", "Issue 3", 1706560000));
    try store.insert(Issue.init("bd-4", "Issue 4", 1706570000));

    const issues = try store.list(.{ .limit = 2, .offset = 1 });
    defer {
        for (issues) |*issue| {
            var i = issue.*;
            i.deinit(allocator);
        }
        allocator.free(issues);
    }

    try std.testing.expectEqual(@as(usize, 2), issues.len);
}

test "IssueStore dirty tracking" {
    const allocator = std.testing.allocator;
    var store = IssueStore.init(allocator, "test_dirty.jsonl");
    defer store.deinit();

    const issue = Issue.init("bd-dirty", "Dirty Test", 1706540000);
    try store.insert(issue);

    const dirty_ids = try store.getDirtyIds();
    defer {
        for (dirty_ids) |id| {
            allocator.free(id);
        }
        allocator.free(dirty_ids);
    }

    try std.testing.expectEqual(@as(usize, 1), dirty_ids.len);
    try std.testing.expectEqualStrings("bd-dirty", dirty_ids[0]);

    try store.clearDirty("bd-dirty");

    const after_clear = try store.getDirtyIds();
    defer allocator.free(after_clear);

    try std.testing.expectEqual(@as(usize, 0), after_clear.len);
}

test "IssueStore.count total" {
    const allocator = std.testing.allocator;
    var store = IssueStore.init(allocator, "test_count.jsonl");
    defer store.deinit();

    try store.insert(Issue.init("bd-c1", "Issue 1", 1706540000));
    try store.insert(Issue.init("bd-c2", "Issue 2", 1706550000));
    try store.insert(Issue.init("bd-c3", "Issue 3", 1706560000));

    const counts = try store.count(null);
    defer {
        for (counts) |c| {
            allocator.free(c.key);
        }
        allocator.free(counts);
    }

    try std.testing.expectEqual(@as(usize, 1), counts.len);
    try std.testing.expectEqualStrings("total", counts[0].key);
    try std.testing.expectEqual(@as(u64, 3), counts[0].count);
}

test "IssueStore insert with all fields" {
    const allocator = std.testing.allocator;
    var store = IssueStore.init(allocator, "test_all_fields.jsonl");
    defer store.deinit();

    var issue = Issue.init("bd-full", "Full Issue", 1706540000);
    issue.content_hash = "abc123hash";
    issue.description = "A detailed description";
    issue.design = "Design document";
    issue.acceptance_criteria = "Must work";
    issue.notes = "Some notes";
    issue.status = .in_progress;
    issue.priority = Priority.HIGH;
    issue.issue_type = .bug;
    issue.assignee = "alice@example.com";
    issue.owner = "bob@example.com";
    issue.estimated_minutes = 120;
    issue.created_by = "creator@example.com";
    issue.closed_at = .{ .value = 1706600000 };
    issue.close_reason = "Fixed";
    issue.due_at = .{ .value = 1706700000 };
    issue.defer_until = .{ .value = 1706650000 };
    issue.external_ref = "JIRA-123";
    issue.source_system = "jira";
    issue.pinned = true;
    issue.is_template = false;

    try store.insert(issue);

    var retrieved = (try store.get("bd-full")).?;
    defer retrieved.deinit(allocator);

    try std.testing.expectEqualStrings("Full Issue", retrieved.title);
    try std.testing.expectEqualStrings("abc123hash", retrieved.content_hash.?);
    try std.testing.expectEqualStrings("A detailed description", retrieved.description.?);
    try std.testing.expect(retrieved.pinned);
    try std.testing.expect(!retrieved.is_template);
}
