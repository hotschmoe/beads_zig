//! Ready and blocked commands for beads_zig.
//!
//! `bz ready [-n LIMIT]` - Show issues ready to work on (no blockers)
//! `bz blocked [-n LIMIT]` - Show blocked issues
//!
//! Workflow queries for finding actionable work.

const std = @import("std");
const models = @import("../models/mod.zig");
const store = @import("../storage/store.zig");
const common = @import("common.zig");
const args = @import("args.zig");
const test_util = @import("../test_util.zig");

const Issue = models.Issue;
const Priority = models.Priority;
const CommandContext = common.CommandContext;
const DependencyGraph = common.DependencyGraph;
const containsIgnoreCase = store.containsIgnoreCase;

pub const ReadyError = error{
    WorkspaceNotInitialized,
    StorageError,
    OutOfMemory,
    InvalidFilter,
};

pub const ReadyResult = struct {
    success: bool,
    issues: ?[]const IssueCompact = null,
    count: ?usize = null,
    message: ?[]const u8 = null,

    const IssueCompact = struct {
        id: []const u8,
        title: []const u8,
        priority: u3,
    };
};

pub const BlockedResult = struct {
    success: bool,
    issues: ?[]const BlockedIssue = null,
    count: ?usize = null,
    message: ?[]const u8 = null,

    const BlockedIssue = struct {
        id: []const u8,
        title: []const u8,
        priority: u3,
        blocked_by: []const []const u8,
    };
};

pub fn run(
    ready_args: args.ReadyArgs,
    global: args.GlobalOptions,
    allocator: std.mem.Allocator,
) !void {
    var ctx = (try CommandContext.init(allocator, global)) orelse {
        return ReadyError.WorkspaceNotInitialized;
    };
    defer ctx.deinit();

    // Parse priority filters
    var priority_min: ?Priority = null;
    var priority_max: ?Priority = null;
    if (ready_args.priority_min) |p| {
        priority_min = Priority.fromString(p) catch {
            try ctx.output.err("invalid priority-min value", .{});
            return ReadyError.InvalidFilter;
        };
    }
    if (ready_args.priority_max) |p| {
        priority_max = Priority.fromString(p) catch {
            try ctx.output.err("invalid priority-max value", .{});
            return ReadyError.InvalidFilter;
        };
    }

    var graph = ctx.createGraph();
    var issues = try graph.getReadyIssues(ready_args.include_deferred);

    // Apply parent filter if specified (before other filters for efficiency)
    if (ready_args.parent) |parent_id| {
        var parent_filtered: std.ArrayListUnmanaged(Issue) = .{};
        errdefer parent_filtered.deinit(allocator);

        for (issues) |issue| {
            if (graph.isChildOf(issue.id, parent_id, ready_args.recursive)) {
                try parent_filtered.append(allocator, issue);
            } else {
                var i = issue;
                i.deinit(allocator);
            }
        }
        allocator.free(issues);
        issues = try parent_filtered.toOwnedSlice(allocator);
    }
    defer graph.freeIssues(issues);

    // Apply filters
    const filtered = try applyFilters(allocator, issues, priority_min, priority_max, ready_args.title_contains, ready_args.desc_contains, ready_args.notes_contains, ready_args.overdue);
    defer allocator.free(filtered);

    const display_issues = applyLimit(filtered, ready_args.limit);

    // Handle CSV output format
    if (ready_args.format == .csv) {
        const Output = common.Output;
        const fields = try Output.parseCsvFields(allocator, ready_args.fields);
        defer if (ready_args.fields != null) allocator.free(fields);
        try ctx.output.printIssueListCsv(display_issues, fields);
        return;
    }

    if (global.isStructuredOutput()) {
        var compact_issues = try allocator.alloc(ReadyResult.IssueCompact, display_issues.len);
        defer allocator.free(compact_issues);

        for (display_issues, 0..) |issue, i| {
            compact_issues[i] = .{
                .id = issue.id,
                .title = issue.title,
                .priority = issue.priority.value,
            };
        }

        try ctx.output.printJson(ReadyResult{
            .success = true,
            .issues = compact_issues,
            .count = display_issues.len,
        });
    } else {
        try ctx.output.printIssueList(display_issues);
        if (!global.quiet and display_issues.len == 0) {
            try ctx.output.info("No ready issues", .{});
        }
    }
}

pub fn runBlocked(
    blocked_args: args.BlockedArgs,
    global: args.GlobalOptions,
    allocator: std.mem.Allocator,
) !void {
    var ctx = (try CommandContext.init(allocator, global)) orelse {
        return ReadyError.WorkspaceNotInitialized;
    };
    defer ctx.deinit();

    // Parse priority filters
    var priority_min: ?Priority = null;
    var priority_max: ?Priority = null;
    if (blocked_args.priority_min) |p| {
        priority_min = Priority.fromString(p) catch {
            try ctx.output.err("invalid priority-min value", .{});
            return ReadyError.InvalidFilter;
        };
    }
    if (blocked_args.priority_max) |p| {
        priority_max = Priority.fromString(p) catch {
            try ctx.output.err("invalid priority-max value", .{});
            return ReadyError.InvalidFilter;
        };
    }

    var graph = ctx.createGraph();
    const issues = try graph.getBlockedIssues();
    defer graph.freeIssues(issues);

    // Apply filters (blocked command doesn't support overdue filter)
    const filtered = try applyFilters(allocator, issues, priority_min, priority_max, blocked_args.title_contains, blocked_args.desc_contains, blocked_args.notes_contains, false);
    defer allocator.free(filtered);

    const display_issues = applyLimit(filtered, blocked_args.limit);

    if (global.isStructuredOutput()) {
        var blocked_issues = try allocator.alloc(BlockedResult.BlockedIssue, display_issues.len);
        defer {
            for (blocked_issues) |bi| {
                allocator.free(bi.blocked_by);
            }
            allocator.free(blocked_issues);
        }

        for (display_issues, 0..) |issue, i| {
            const blockers = try graph.getBlockers(issue.id);
            defer graph.freeIssues(blockers);

            var blocker_ids = try allocator.alloc([]const u8, blockers.len);
            for (blockers, 0..) |blocker, j| {
                blocker_ids[j] = blocker.id;
            }

            blocked_issues[i] = .{
                .id = issue.id,
                .title = issue.title,
                .priority = issue.priority.value,
                .blocked_by = blocker_ids,
            };
        }

        try ctx.output.printJson(BlockedResult{
            .success = true,
            .issues = blocked_issues,
            .count = display_issues.len,
        });
    } else {
        for (display_issues) |issue| {
            const blockers = try graph.getBlockers(issue.id);
            defer graph.freeIssues(blockers);

            try ctx.output.print("{s}  {s}\n", .{ issue.id, issue.title });

            if (blockers.len > 0) {
                try ctx.output.print("  blocked by: ", .{});
                for (blockers, 0..) |blocker, j| {
                    if (j > 0) try ctx.output.print(", ", .{});
                    try ctx.output.print("{s}", .{blocker.id});
                }
                try ctx.output.print("\n", .{});
            }
        }

        if (!global.quiet and display_issues.len == 0) {
            try ctx.output.info("No blocked issues", .{});
        }
    }
}

fn applyLimit(issues: []Issue, limit: ?u32) []Issue {
    if (limit) |n| {
        if (n < issues.len) {
            return issues[0..n];
        }
    }
    return issues;
}

fn applyFilters(
    allocator: std.mem.Allocator,
    issues: []Issue,
    priority_min: ?Priority,
    priority_max: ?Priority,
    title_contains: ?[]const u8,
    desc_contains: ?[]const u8,
    notes_contains: ?[]const u8,
    overdue_only: bool,
) ![]Issue {
    // No filters - return original slice
    if (priority_min == null and priority_max == null and title_contains == null and desc_contains == null and notes_contains == null and !overdue_only) {
        return try allocator.dupe(Issue, issues);
    }

    const now = std.time.timestamp();
    var filtered: std.ArrayListUnmanaged(Issue) = .{};
    errdefer filtered.deinit(allocator);

    for (issues) |issue| {
        // Priority range filters (lower value = higher priority)
        if (priority_min) |min_p| {
            if (issue.priority.value < min_p.value) continue;
        }
        if (priority_max) |max_p| {
            if (issue.priority.value > max_p.value) continue;
        }

        // Substring filters (case-insensitive)
        if (title_contains) |query| {
            if (!containsIgnoreCase(issue.title, query)) continue;
        }
        if (desc_contains) |query| {
            if (issue.description) |desc| {
                if (!containsIgnoreCase(desc, query)) continue;
            } else continue;
        }
        if (notes_contains) |query| {
            if (issue.notes) |notes| {
                if (!containsIgnoreCase(notes, query)) continue;
            } else continue;
        }

        // Overdue filter: only include issues past their due date
        if (overdue_only) {
            if (issue.due_at.value) |due_time| {
                if (due_time >= now) continue;
            } else continue;
        }

        try filtered.append(allocator, issue);
    }

    return filtered.toOwnedSlice(allocator);
}

// --- Tests ---

test "ReadyError enum exists" {
    const err: ReadyError = ReadyError.WorkspaceNotInitialized;
    try std.testing.expect(err == ReadyError.WorkspaceNotInitialized);
}

test "ReadyResult struct works" {
    const result = ReadyResult{
        .success = true,
        .count = 3,
    };
    try std.testing.expect(result.success);
    try std.testing.expectEqual(@as(usize, 3), result.count.?);
}

test "BlockedResult struct works" {
    const result = BlockedResult{
        .success = true,
        .count = 2,
    };
    try std.testing.expect(result.success);
    try std.testing.expectEqual(@as(usize, 2), result.count.?);
}

test "run detects uninitialized workspace" {
    const allocator = std.testing.allocator;

    const ready_args = args.ReadyArgs{};
    const global = args.GlobalOptions{ .silent = true, .data_path = "/nonexistent/path" };

    const result = run(ready_args, global, allocator);
    try std.testing.expectError(ReadyError.WorkspaceNotInitialized, result);
}

test "runBlocked detects uninitialized workspace" {
    const allocator = std.testing.allocator;

    const blocked_args = args.BlockedArgs{};
    const global = args.GlobalOptions{ .silent = true, .data_path = "/nonexistent/path" };

    const result = runBlocked(blocked_args, global, allocator);
    try std.testing.expectError(ReadyError.WorkspaceNotInitialized, result);
}

test "run returns empty list for empty workspace" {
    const allocator = std.testing.allocator;

    const tmp_dir_path = try test_util.createTestDir(allocator, "ready_empty");
    defer allocator.free(tmp_dir_path);
    defer test_util.cleanupTestDir(tmp_dir_path);

    const data_path = try std.fs.path.join(allocator, &.{ tmp_dir_path, ".beads" });
    defer allocator.free(data_path);

    try std.fs.cwd().makeDir(data_path);

    const issues_path = try std.fs.path.join(allocator, &.{ data_path, "issues.jsonl" });
    defer allocator.free(issues_path);

    const f = try std.fs.cwd().createFile(issues_path, .{});
    f.close();

    const ready_args = args.ReadyArgs{};
    const global = args.GlobalOptions{ .silent = true, .data_path = data_path };

    try run(ready_args, global, allocator);
}
