//! Ready and blocked commands for beads_zig.
//!
//! `bz ready [-n LIMIT]` - Show issues ready to work on (no blockers)
//! `bz blocked [-n LIMIT]` - Show blocked issues
//!
//! Workflow queries for finding actionable work.

const std = @import("std");
const models = @import("../models/mod.zig");
const storage = @import("../storage/mod.zig");
const common = @import("common.zig");
const args = @import("args.zig");
const test_util = @import("../test_util.zig");

const Issue = models.Issue;
const Priority = models.Priority;
const CommandContext = common.CommandContext;
const DependencyStore = storage.DependencyStore;

pub const ReadyError = error{
    WorkspaceNotInitialized,
    StorageError,
    OutOfMemory,
    InvalidFilter,
};

pub const ReadyResult = struct {
    success: bool,
    issues: ?[]const common.IssueFull = null,
    count: ?usize = null,
    message: ?[]const u8 = null,
};

pub const BlockedResult = struct {
    success: bool,
    issues: ?[]const BlockedIssueFull = null,
    count: ?usize = null,
    message: ?[]const u8 = null,

    /// Full blocked issue representation for agent consumption.
    /// Includes all fields commonly needed for workflow automation.
    const BlockedIssueFull = struct {
        id: []const u8,
        title: []const u8,
        description: ?[]const u8 = null,
        status: []const u8,
        priority: u3,
        issue_type: []const u8,
        assignee: ?[]const u8 = null,
        labels: []const []const u8,
        created_at: i64,
        updated_at: i64,
        blocked_by: []const []const u8, // IDs of blocking issues
        blocks: []const []const u8, // IDs of issues this blocks (dependents)
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

    // Get ready issue IDs from dependency store
    const ready_ids = try ctx.dep_store.getReadyIssueIds();
    defer ctx.dep_store.freeIds(ready_ids);

    // Fetch full Issue objects
    var issues: std.ArrayList(Issue) = .empty;
    defer {
        for (issues.items) |*issue| {
            issue.deinit(allocator);
        }
        issues.deinit(allocator);
    }

    for (ready_ids) |id| {
        if (try ctx.issue_store.get(id)) |issue| {
            // Filter deferred issues if not explicitly included
            if (!ready_args.include_deferred) {
                if (issue.defer_until.value) |defer_time| {
                    const now = std.time.timestamp();
                    if (defer_time > now) {
                        var i = issue;
                        i.deinit(allocator);
                        continue;
                    }
                }
            }
            try issues.append(allocator, issue);
        }
    }

    const issues_slice = try issues.toOwnedSlice(allocator);
    defer allocator.free(issues_slice);

    // Apply parent filter if specified
    var filtered_issues: []Issue = issues_slice;
    var parent_owned: ?[]Issue = null;
    defer if (parent_owned) |owned| {
        for (owned) |*issue| {
            issue.deinit(allocator);
        }
        allocator.free(owned);
    };

    if (ready_args.parent) |parent_id| {
        var parent_filtered: std.ArrayList(Issue) = .empty;
        errdefer parent_filtered.deinit(allocator);

        for (issues_slice) |issue| {
            const is_child = try isChildOf(&ctx.dep_store, issue.id, parent_id, ready_args.recursive, allocator);
            if (is_child) {
                try parent_filtered.append(allocator, issue);
            } else {
                var i = issue;
                i.deinit(allocator);
            }
        }
        parent_owned = try parent_filtered.toOwnedSlice(allocator);
        filtered_issues = parent_owned.?;
    }

    // Apply filters
    const filtered = try applyFilters(allocator, filtered_issues, priority_min, priority_max, ready_args.title_contains, ready_args.desc_contains, ready_args.notes_contains, ready_args.overdue);
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
        var full_issues = try allocator.alloc(common.IssueFull, display_issues.len);
        defer {
            for (full_issues) |fi| {
                common.freeBlocksIds(allocator, fi.blocks);
            }
            allocator.free(full_issues);
        }

        for (display_issues, 0..) |issue, i| {
            full_issues[i] = .{
                .id = issue.id,
                .title = issue.title,
                .description = issue.description,
                .status = issue.status.toString(),
                .priority = issue.priority.value,
                .issue_type = issue.issue_type.toString(),
                .assignee = issue.assignee,
                .labels = issue.labels,
                .created_at = issue.created_at.value,
                .updated_at = issue.updated_at.value,
                .blocks = try common.collectBlocksIds(allocator, &ctx.dep_store, issue.id),
            };
        }

        try ctx.output.printJson(ReadyResult{
            .success = true,
            .issues = full_issues,
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

    // Get blocked issue IDs and their blockers
    const blocked_infos = try ctx.dep_store.getBlockedIssueIds();
    defer ctx.dep_store.freeBlockedInfos(blocked_infos);

    // Fetch full Issue objects
    var issues: std.ArrayList(Issue) = .empty;
    defer {
        for (issues.items) |*issue| {
            issue.deinit(allocator);
        }
        issues.deinit(allocator);
    }

    for (blocked_infos) |info| {
        if (try ctx.issue_store.get(info.issue_id)) |issue| {
            try issues.append(allocator, issue);
        }
    }

    const issues_slice = try issues.toOwnedSlice(allocator);
    defer allocator.free(issues_slice);

    // Apply filters (blocked command doesn't support overdue filter)
    const filtered = try applyFilters(allocator, issues_slice, priority_min, priority_max, blocked_args.title_contains, blocked_args.desc_contains, blocked_args.notes_contains, false);
    defer allocator.free(filtered);

    const display_issues = applyLimit(filtered, blocked_args.limit);

    if (global.isStructuredOutput()) {
        var blocked_issues = try allocator.alloc(BlockedResult.BlockedIssueFull, display_issues.len);
        defer {
            for (blocked_issues) |bi| {
                common.freeBlocksIds(allocator, bi.blocked_by);
                common.freeBlocksIds(allocator, bi.blocks);
            }
            allocator.free(blocked_issues);
        }

        for (display_issues, 0..) |issue, i| {
            // Find the corresponding BlockedInfo for this issue
            var blocker_ids_list: std.ArrayList([]const u8) = .empty;
            defer blocker_ids_list.deinit(allocator);

            for (blocked_infos) |info| {
                if (std.mem.eql(u8, info.issue_id, issue.id)) {
                    // Parse comma-separated blocker IDs
                    var iter = std.mem.splitScalar(u8, info.blocked_by, ',');
                    while (iter.next()) |blocker_id| {
                        try blocker_ids_list.append(allocator, try allocator.dupe(u8, blocker_id));
                    }
                    break;
                }
            }

            const blocker_ids = try blocker_ids_list.toOwnedSlice(allocator);

            blocked_issues[i] = .{
                .id = issue.id,
                .title = issue.title,
                .description = issue.description,
                .status = issue.status.toString(),
                .priority = issue.priority.value,
                .issue_type = issue.issue_type.toString(),
                .assignee = issue.assignee,
                .labels = issue.labels,
                .created_at = issue.created_at.value,
                .updated_at = issue.updated_at.value,
                .blocked_by = blocker_ids,
                .blocks = try common.collectBlocksIds(allocator, &ctx.dep_store, issue.id),
            };
        }

        try ctx.output.printJson(BlockedResult{
            .success = true,
            .issues = blocked_issues,
            .count = display_issues.len,
        });
    } else {
        for (display_issues) |issue| {
            // Find blocker IDs for this issue
            var blocker_ids_list: std.ArrayList([]const u8) = .empty;
            defer {
                for (blocker_ids_list.items) |bid| allocator.free(bid);
                blocker_ids_list.deinit(allocator);
            }

            for (blocked_infos) |info| {
                if (std.mem.eql(u8, info.issue_id, issue.id)) {
                    var iter = std.mem.splitScalar(u8, info.blocked_by, ',');
                    while (iter.next()) |blocker_id| {
                        try blocker_ids_list.append(allocator, try allocator.dupe(u8, blocker_id));
                    }
                    break;
                }
            }

            try ctx.output.print("{s}  {s}\n", .{ issue.id, issue.title });

            if (blocker_ids_list.items.len > 0) {
                try ctx.output.print("  blocked by: ", .{});
                for (blocker_ids_list.items, 0..) |blocker_id, j| {
                    if (j > 0) try ctx.output.print(", ", .{});
                    try ctx.output.print("{s}", .{blocker_id});
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

/// Case-insensitive substring search.
fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var match = true;
        for (0..needle.len) |j| {
            const h = std.ascii.toLower(haystack[i + j]);
            const n = std.ascii.toLower(needle[j]);
            if (h != n) {
                match = false;
                break;
            }
        }
        if (match) return true;
    }
    return false;
}

/// Check if an issue is a child of a parent (optionally recursive).
fn isChildOf(
    dep_store: *DependencyStore,
    issue_id: []const u8,
    parent_id: []const u8,
    recursive: bool,
    allocator: std.mem.Allocator,
) !bool {
    const deps = try dep_store.getDependencies(issue_id);
    defer dep_store.freeDependencies(deps);

    for (deps) |dep| {
        if (dep.dep_type == .parent_child and std.mem.eql(u8, dep.depends_on_id, parent_id)) {
            return true;
        }

        if (recursive and dep.dep_type == .parent_child) {
            if (try isChildOf(dep_store, dep.depends_on_id, parent_id, true, allocator)) {
                return true;
            }
        }
    }

    return false;
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

    // Create a SQLite database instead of issues.jsonl
    const db_path = try std.fs.path.join(allocator, &.{ data_path, "beads.db" });
    defer allocator.free(db_path);

    {
        var db = try storage.SqlDatabase.open(allocator, db_path);
        defer db.close();
        try storage.createSchema(&db);
    }

    const ready_args = args.ReadyArgs{};
    const global = args.GlobalOptions{ .silent = true, .data_path = data_path };

    try run(ready_args, global, allocator);
}
