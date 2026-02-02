//! Count command for beads_zig.
//!
//! Counts issues with optional grouping by field.

const std = @import("std");
const args = @import("args.zig");
const common = @import("common.zig");
const models = @import("../models/mod.zig");

const Issue = models.Issue;
const Status = models.Status;
const Priority = models.Priority;
const IssueType = models.IssueType;
const CommandContext = common.CommandContext;

pub const CountError = common.CommandError || error{WriteError};

pub const CountResult = struct {
    success: bool,
    count: ?usize = null,
    group_by: ?[]const u8 = null,
    message: ?[]const u8 = null,
};

const GroupEntry = struct {
    key: []const u8,
    value: usize,
};

pub fn run(
    count_args: args.CountArgs,
    global: args.GlobalOptions,
    allocator: std.mem.Allocator,
) !void {
    var ctx = (try CommandContext.init(allocator, global)) orelse {
        return CountError.WorkspaceNotInitialized;
    };
    defer ctx.deinit();

    const all_issues = ctx.store.getAllRef();

    // Filter out deleted issues
    var active_count: usize = 0;
    for (all_issues) |issue| {
        if (!issue.status.eql(.tombstone)) active_count += 1;
    }

    if (count_args.group_by) |group_field| {
        try outputGrouped(&ctx.output, all_issues, group_field, global, allocator);
    } else {
        try outputTotal(&ctx.output, active_count, global);
    }
}

fn outputTotal(out: *common.Output, count: usize, global: args.GlobalOptions) !void {
    if (global.isStructuredOutput()) {
        try out.printJson(.{ .count = count });
    } else {
        try out.println("{d}", .{count});
    }
}

fn outputGrouped(
    out: *common.Output,
    issues: []const Issue,
    group_field: []const u8,
    global: args.GlobalOptions,
    allocator: std.mem.Allocator,
) !void {
    var counts = std.StringHashMap(usize).init(allocator);
    defer {
        var it = counts.keyIterator();
        while (it.next()) |key| {
            allocator.free(key.*);
        }
        counts.deinit();
    }

    for (issues) |issue| {
        if (issue.status.eql(.tombstone)) continue;

        const value = getFieldValue(issue, group_field) orelse "none";
        const owned_value = allocator.dupe(u8, value) catch continue;

        if (counts.get(owned_value)) |existing| {
            counts.put(owned_value, existing + 1) catch continue;
            allocator.free(owned_value);
        } else {
            counts.put(owned_value, 1) catch {
                allocator.free(owned_value);
                continue;
            };
        }
    }

    // Convert to array for sorting
    var entries: std.ArrayListUnmanaged(GroupEntry) = .{};
    defer entries.deinit(allocator);

    var it = counts.iterator();
    while (it.next()) |entry| {
        entries.append(allocator, .{ .key = entry.key_ptr.*, .value = entry.value_ptr.* }) catch continue;
    }

    // Sort by count descending
    std.mem.sort(GroupEntry, entries.items, {}, struct {
        fn lessThan(_: void, a: GroupEntry, b: GroupEntry) bool {
            return a.value > b.value;
        }
    }.lessThan);

    if (global.isStructuredOutput()) {
        try outputGroupedJson(out, entries.items, group_field);
    } else {
        try outputGroupedHuman(out, entries.items, group_field);
    }
}

fn getFieldValue(issue: Issue, field: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, field, "status")) {
        return issue.status.toString();
    } else if (std.mem.eql(u8, field, "priority")) {
        return issue.priority.toString();
    } else if (std.mem.eql(u8, field, "type") or std.mem.eql(u8, field, "issue_type")) {
        return issue.issue_type.toString();
    } else if (std.mem.eql(u8, field, "assignee")) {
        return issue.assignee;
    } else {
        return null;
    }
}

fn outputGroupedJson(out: *common.Output, entries: []const GroupEntry, field: []const u8) !void {
    try out.raw("{\"group_by\":\"");
    try out.raw(field);
    try out.raw("\",\"groups\":[");

    for (entries, 0..) |entry, i| {
        if (i > 0) try out.raw(",");
        try out.raw("{\"");
        try out.raw(entry.key);
        try out.raw("\":");
        try out.print("{d}", .{entry.value});
        try out.raw("}");
    }

    try out.raw("]}\n");
}

fn outputGroupedHuman(out: *common.Output, entries: []const GroupEntry, field: []const u8) !void {
    try out.print("Issues by {s}:\n", .{field});
    var total: usize = 0;
    for (entries) |entry| {
        try out.print("  {s}: {d}\n", .{ entry.key, entry.value });
        total += entry.value;
    }
    try out.print("\nTotal: {d}\n", .{total});
}

test "getFieldValue returns status" {
    const issue = Issue{
        .id = "test-123",
        .content_hash = null,
        .title = "Test",
        .description = null,
        .design = null,
        .acceptance_criteria = null,
        .notes = null,
        .status = .open,
        .priority = Priority.MEDIUM,
        .issue_type = .task,
        .assignee = null,
        .owner = null,
        .created_at = .{ .value = 1704067200 },
        .created_by = null,
        .updated_at = .{ .value = 1704067200 },
        .closed_at = .{ .value = null },
        .close_reason = null,
        .due_at = .{ .value = null },
        .defer_until = .{ .value = null },
        .estimated_minutes = null,
        .external_ref = null,
        .source_system = null,
        .pinned = false,
        .is_template = false,
        .ephemeral = false,
        .labels = &.{},
        .dependencies = &.{},
        .comments = &.{},
    };

    const status = getFieldValue(issue, "status");
    try std.testing.expectEqualStrings("open", status.?);
}

test "getFieldValue returns priority" {
    const issue = Issue{
        .id = "test-123",
        .content_hash = null,
        .title = "Test",
        .description = null,
        .design = null,
        .acceptance_criteria = null,
        .notes = null,
        .status = .open,
        .priority = Priority.HIGH,
        .issue_type = .task,
        .assignee = null,
        .owner = null,
        .created_at = .{ .value = 1704067200 },
        .created_by = null,
        .updated_at = .{ .value = 1704067200 },
        .closed_at = .{ .value = null },
        .close_reason = null,
        .due_at = .{ .value = null },
        .defer_until = .{ .value = null },
        .estimated_minutes = null,
        .external_ref = null,
        .source_system = null,
        .pinned = false,
        .is_template = false,
        .ephemeral = false,
        .labels = &.{},
        .dependencies = &.{},
        .comments = &.{},
    };

    const priority = getFieldValue(issue, "priority");
    try std.testing.expectEqualStrings("high", priority.?);
}

test "getFieldValue returns null for unknown field" {
    const issue = Issue{
        .id = "test-123",
        .content_hash = null,
        .title = "Test",
        .description = null,
        .design = null,
        .acceptance_criteria = null,
        .notes = null,
        .status = .open,
        .priority = Priority.MEDIUM,
        .issue_type = .task,
        .assignee = null,
        .owner = null,
        .created_at = .{ .value = 1704067200 },
        .created_by = null,
        .updated_at = .{ .value = 1704067200 },
        .closed_at = .{ .value = null },
        .close_reason = null,
        .due_at = .{ .value = null },
        .defer_until = .{ .value = null },
        .estimated_minutes = null,
        .external_ref = null,
        .source_system = null,
        .pinned = false,
        .is_template = false,
        .ephemeral = false,
        .labels = &.{},
        .dependencies = &.{},
        .comments = &.{},
    };

    const unknown = getFieldValue(issue, "unknown");
    try std.testing.expect(unknown == null);
}
