//! Stats command for beads_zig.
//!
//! `bz stats` - Show project statistics
//! `bz stats --activity` - Show git-based activity statistics
//! `bz stats --activity-hours 48` - Show activity for last 48 hours

const std = @import("std");
const common = @import("common.zig");
const args = @import("args.zig");

const CommandContext = common.CommandContext;

pub const StatsError = error{
    WorkspaceNotInitialized,
    StorageError,
    OutOfMemory,
    GitError,
};

pub const StatsResult = struct {
    success: bool,
    total: ?usize = null,
    open: ?usize = null,
    closed: ?usize = null,
    by_status: ?[]const CountEntry = null,
    by_priority: ?[]const CountEntry = null,
    by_type: ?[]const CountEntry = null,
    activity: ?ActivityStats = null,
    message: ?[]const u8 = null,

    pub const CountEntry = struct {
        key: []const u8,
        count: usize,
    };

    pub const ActivityStats = struct {
        period_hours: u32,
        git_commits: usize,
        issues_created: usize,
        issues_closed: usize,
        issues_updated: usize,
        commits_with_issue_refs: usize,
        issue_refs: ?[]const IssueRef = null,

        pub const IssueRef = struct {
            issue_id: []const u8,
            commit_count: usize,
        };
    };
};

pub fn run(
    stats_args: args.StatsArgs,
    global: args.GlobalOptions,
    allocator: std.mem.Allocator,
) !void {
    var ctx = (try CommandContext.init(allocator, global)) orelse {
        return StatsError.WorkspaceNotInitialized;
    };
    defer ctx.deinit();

    // Count totals
    var total: usize = 0;
    var open: usize = 0;
    var closed: usize = 0;

    // Count by status
    var status_counts: std.StringHashMapUnmanaged(usize) = .{};
    defer status_counts.deinit(allocator);

    // Count by priority
    var priority_counts: [5]usize = .{ 0, 0, 0, 0, 0 };

    // Count by type
    var type_counts: std.StringHashMapUnmanaged(usize) = .{};
    defer type_counts.deinit(allocator);

    const all_issues = try ctx.issue_store.list(.{});
    defer {
        for (all_issues) |*issue| {
            var i = issue.*;
            i.deinit(allocator);
        }
        allocator.free(all_issues);
    }

    for (all_issues) |issue| {
        if (issue.status.eql(.tombstone)) continue;

        total += 1;

        // Status
        const status_str = issue.status.toString();
        const status_entry = try status_counts.getOrPutValue(allocator, status_str, 0);
        status_entry.value_ptr.* += 1;

        if (issue.status.eql(.open) or issue.status.eql(.in_progress) or issue.status.eql(.blocked)) {
            open += 1;
        } else if (issue.status.eql(.closed)) {
            closed += 1;
        }

        // Priority
        if (issue.priority.value <= 4) {
            priority_counts[issue.priority.value] += 1;
        }

        // Type
        const type_str = issue.issue_type.toString();
        const type_entry = try type_counts.getOrPutValue(allocator, type_str, 0);
        type_entry.value_ptr.* += 1;
    }

    // Convert to arrays for output
    var status_list: std.ArrayListUnmanaged(StatsResult.CountEntry) = .{};
    defer status_list.deinit(allocator);

    var status_it = status_counts.iterator();
    while (status_it.next()) |entry| {
        try status_list.append(allocator, .{ .key = entry.key_ptr.*, .count = entry.value_ptr.* });
    }

    var priority_list: std.ArrayListUnmanaged(StatsResult.CountEntry) = .{};
    defer priority_list.deinit(allocator);

    const priority_names = [_][]const u8{ "critical", "high", "medium", "low", "backlog" };
    for (0..5) |i| {
        if (priority_counts[i] > 0) {
            try priority_list.append(allocator, .{ .key = priority_names[i], .count = priority_counts[i] });
        }
    }

    var type_list: std.ArrayListUnmanaged(StatsResult.CountEntry) = .{};
    defer type_list.deinit(allocator);

    var type_it = type_counts.iterator();
    while (type_it.next()) |entry| {
        try type_list.append(allocator, .{ .key = entry.key_ptr.*, .count = entry.value_ptr.* });
    }

    // Activity stats (if requested)
    var activity_stats: ?StatsResult.ActivityStats = null;
    var issue_refs_list: std.ArrayListUnmanaged(StatsResult.ActivityStats.IssueRef) = .{};
    defer issue_refs_list.deinit(allocator);

    if (stats_args.activity) {
        activity_stats = try getActivityStats(allocator, &ctx, stats_args.activity_hours, &issue_refs_list);
    }

    if (global.isStructuredOutput()) {
        try ctx.output.printJson(StatsResult{
            .success = true,
            .total = total,
            .open = open,
            .closed = closed,
            .by_status = status_list.items,
            .by_priority = priority_list.items,
            .by_type = type_list.items,
            .activity = activity_stats,
        });
    } else if (!global.quiet) {
        try ctx.output.println("Issue Statistics", .{});
        try ctx.output.print("\n", .{});
        try ctx.output.print("Total: {d} issues ({d} open, {d} closed)\n", .{ total, open, closed });
        try ctx.output.print("\n", .{});

        if (status_list.items.len > 0) {
            try ctx.output.print("By Status:\n", .{});
            for (status_list.items) |entry| {
                try ctx.output.print("  {s: <12} {d}\n", .{ entry.key, entry.count });
            }
        }

        if (priority_list.items.len > 0) {
            try ctx.output.print("\nBy Priority:\n", .{});
            for (priority_list.items) |entry| {
                try ctx.output.print("  {s: <12} {d}\n", .{ entry.key, entry.count });
            }
        }

        if (type_list.items.len > 0) {
            try ctx.output.print("\nBy Type:\n", .{});
            for (type_list.items) |entry| {
                try ctx.output.print("  {s: <12} {d}\n", .{ entry.key, entry.count });
            }
        }

        if (activity_stats) |activity| {
            try ctx.output.print("\nActivity (last {d} hours):\n", .{activity.period_hours});
            try ctx.output.print("  Git commits:           {d}\n", .{activity.git_commits});
            try ctx.output.print("  Issues created:        {d}\n", .{activity.issues_created});
            try ctx.output.print("  Issues closed:         {d}\n", .{activity.issues_closed});
            try ctx.output.print("  Issues updated:        {d}\n", .{activity.issues_updated});
            try ctx.output.print("  Commits with refs:     {d}\n", .{activity.commits_with_issue_refs});

            if (activity.issue_refs) |refs| {
                if (refs.len > 0) {
                    try ctx.output.print("\n  Referenced Issues:\n", .{});
                    for (refs[0..@min(10, refs.len)]) |ref| {
                        try ctx.output.print("    {s: <12} {d} commits\n", .{ ref.issue_id, ref.commit_count });
                    }
                    if (refs.len > 10) {
                        try ctx.output.print("    ... and {d} more\n", .{refs.len - 10});
                    }
                }
            }
        }
    }
}

fn getActivityStats(
    allocator: std.mem.Allocator,
    ctx: *CommandContext,
    hours: u32,
    issue_refs_list: *std.ArrayListUnmanaged(StatsResult.ActivityStats.IssueRef),
) !StatsResult.ActivityStats {
    const now = std.time.timestamp();
    const since = now - @as(i64, @intCast(hours)) * 60 * 60;

    // Count issue activity in the time period
    var issues_created: usize = 0;
    var issues_closed: usize = 0;
    var issues_updated: usize = 0;

    const activity_issues = try ctx.issue_store.list(.{});
    defer {
        for (activity_issues) |*issue| {
            var i = issue.*;
            i.deinit(allocator);
        }
        allocator.free(activity_issues);
    }

    for (activity_issues) |issue| {
        if (issue.created_at.value >= since) {
            issues_created += 1;
        }
        if (issue.closed_at.value) |closed_ts| {
            if (closed_ts >= since) {
                issues_closed += 1;
            }
        }
        if (issue.updated_at.value >= since and issue.created_at.value < since) {
            issues_updated += 1;
        }
    }

    // Get git commit stats
    var git_commits: usize = 0;
    var commits_with_refs: usize = 0;
    var issue_ref_counts: std.StringHashMapUnmanaged(usize) = .{};
    defer issue_ref_counts.deinit(allocator);

    // Run git log to get recent commits
    const git_result = runGitLog(allocator, hours) catch {
        // Git not available or not a git repo - return partial stats
        return StatsResult.ActivityStats{
            .period_hours = hours,
            .git_commits = 0,
            .issues_created = issues_created,
            .issues_closed = issues_closed,
            .issues_updated = issues_updated,
            .commits_with_issue_refs = 0,
            .issue_refs = null,
        };
    };
    defer allocator.free(git_result);

    // Parse git log output
    var lines = std.mem.splitScalar(u8, git_result, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        git_commits += 1;

        // Look for issue references (bd-xxx pattern)
        var found_ref = false;
        var i: usize = 0;
        while (i < line.len) {
            // Look for "bd-" or similar prefix
            if (i + 3 < line.len and
                (std.mem.eql(u8, line[i .. i + 3], "bd-") or std.mem.eql(u8, line[i .. i + 3], "BD-")))
            {
                // Extract the issue ID
                const start = i;
                i += 3;
                while (i < line.len and (std.ascii.isAlphanumeric(line[i]) or line[i] == '-' or line[i] == '.')) {
                    i += 1;
                }
                const issue_id = line[start..i];
                if (issue_id.len > 3) {
                    // Normalize to lowercase
                    var normalized: [32]u8 = undefined;
                    const len = @min(issue_id.len, 32);
                    for (0..len) |j| {
                        normalized[j] = std.ascii.toLower(issue_id[j]);
                    }
                    const key = normalized[0..len];

                    // Check if this issue exists in our store
                    if (ctx.issue_store.exists(key) catch false) {
                        const entry = try issue_ref_counts.getOrPutValue(allocator, key, 0);
                        entry.value_ptr.* += 1;
                        found_ref = true;
                    }
                }
            } else {
                i += 1;
            }
        }
        if (found_ref) {
            commits_with_refs += 1;
        }
    }

    // Convert issue refs to array
    var it = issue_ref_counts.iterator();
    while (it.next()) |entry| {
        try issue_refs_list.append(allocator, .{
            .issue_id = entry.key_ptr.*,
            .commit_count = entry.value_ptr.*,
        });
    }

    // Sort by commit count descending
    std.mem.sortUnstable(StatsResult.ActivityStats.IssueRef, issue_refs_list.items, {}, struct {
        fn lessThan(_: void, a: StatsResult.ActivityStats.IssueRef, b: StatsResult.ActivityStats.IssueRef) bool {
            return a.commit_count > b.commit_count;
        }
    }.lessThan);

    return StatsResult.ActivityStats{
        .period_hours = hours,
        .git_commits = git_commits,
        .issues_created = issues_created,
        .issues_closed = issues_closed,
        .issues_updated = issues_updated,
        .commits_with_issue_refs = commits_with_refs,
        .issue_refs = if (issue_refs_list.items.len > 0) issue_refs_list.items else null,
    };
}

fn runGitLog(allocator: std.mem.Allocator, hours: u32) ![]const u8 {
    var buf: [32]u8 = undefined;
    const since_arg = std.fmt.bufPrint(&buf, "--since={d}.hours.ago", .{hours}) catch unreachable;

    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "git", "log", "--oneline", since_arg },
        .cwd = null,
    }) catch return StatsError.GitError;

    defer allocator.free(result.stderr);

    if (result.term.Exited != 0) {
        allocator.free(result.stdout);
        return StatsError.GitError;
    }

    return result.stdout;
}

// --- Tests ---

test "StatsError enum exists" {
    const err: StatsError = StatsError.WorkspaceNotInitialized;
    try std.testing.expect(err == StatsError.WorkspaceNotInitialized);
}

test "StatsResult struct works" {
    const result = StatsResult{
        .success = true,
        .total = 10,
        .open = 5,
        .closed = 5,
    };
    try std.testing.expect(result.success);
    try std.testing.expectEqual(@as(usize, 10), result.total.?);
}

test "run detects uninitialized workspace" {
    const allocator = std.testing.allocator;

    const stats_args = args.StatsArgs{};
    const global = args.GlobalOptions{ .silent = true, .data_path = "/nonexistent/path" };

    const result = run(stats_args, global, allocator);
    try std.testing.expectError(StatsError.WorkspaceNotInitialized, result);
}

test "StatsArgs default values" {
    const stats_args = args.StatsArgs{};
    try std.testing.expect(!stats_args.activity);
    try std.testing.expectEqual(@as(u32, 24), stats_args.activity_hours);
}

test "parse stats with activity flag" {
    const allocator = std.testing.allocator;
    const cmd_args = [_][]const u8{ "stats", "--activity" };
    var parser = args.ArgParser.init(allocator, &cmd_args);
    var result = parser.parse() catch unreachable;
    defer result.deinit(allocator);

    switch (result.command) {
        .stats => |s| {
            try std.testing.expect(s.activity);
            try std.testing.expectEqual(@as(u32, 24), s.activity_hours);
        },
        else => try std.testing.expect(false),
    }
}

test "parse stats with activity-hours flag" {
    const allocator = std.testing.allocator;
    const cmd_args = [_][]const u8{ "stats", "--activity", "--activity-hours", "48" };
    var parser = args.ArgParser.init(allocator, &cmd_args);
    var result = parser.parse() catch unreachable;
    defer result.deinit(allocator);

    switch (result.command) {
        .stats => |s| {
            try std.testing.expect(s.activity);
            try std.testing.expectEqual(@as(u32, 48), s.activity_hours);
        },
        else => try std.testing.expect(false),
    }
}
