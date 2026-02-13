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

/// JSON output matches br's summary-based format.
pub const StatsSummary = struct {
    total_issues: usize,
    open_issues: usize,
    in_progress_issues: usize,
    closed_issues: usize,
    blocked_issues: usize,
    deferred_issues: usize,
    ready_issues: usize,
    tombstone_issues: usize,
    pinned_issues: usize,
};

pub const StatsJsonResult = struct {
    summary: StatsSummary,
};

/// Internal struct kept for activity stats.
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

pub fn run(
    stats_args: args.StatsArgs,
    global: args.GlobalOptions,
    allocator: std.mem.Allocator,
) !void {
    var ctx = (try CommandContext.init(allocator, global)) orelse {
        return StatsError.WorkspaceNotInitialized;
    };
    defer ctx.deinit();

    var total: usize = 0;
    var open: usize = 0;
    var closed: usize = 0;
    var in_progress: usize = 0;
    var blocked: usize = 0;
    var deferred: usize = 0;
    var ready: usize = 0;
    var tombstone: usize = 0;
    var pinned: usize = 0;

    const all_issues = try ctx.issue_store.list(.{});
    defer {
        for (all_issues) |*issue| {
            var i = issue.*;
            i.deinit(allocator);
        }
        allocator.free(all_issues);
    }

    for (all_issues) |issue| {
        if (issue.status.eql(.tombstone)) {
            tombstone += 1;
            continue;
        }

        total += 1;

        if (issue.status.eql(.in_progress)) {
            in_progress += 1;
        } else if (issue.status.eql(.closed)) {
            closed += 1;
        } else if (issue.status.eql(.deferred)) {
            deferred += 1;
        }

        if (issue.pinned) pinned += 1;
    }

    // Compute blocked/ready: check dependencies for non-closed issues
    open = total - closed;

    for (all_issues) |issue| {
        if (issue.status.eql(.tombstone) or issue.status.eql(.closed) or issue.status.eql(.in_progress)) continue;

        const deps = try ctx.dep_store.getDependencies(issue.id);
        defer ctx.dep_store.freeDependencies(deps);

        var has_open_blocker = false;
        for (deps) |dep| {
            const blocker = ctx.issue_store.get(dep.depends_on_id) catch null;
            if (blocker) |b| {
                var bi = b;
                defer bi.deinit(allocator);
                if (!bi.status.eql(.closed) and !bi.status.eql(.tombstone)) {
                    has_open_blocker = true;
                    break;
                }
            }
        }

        if (has_open_blocker) {
            blocked += 1;
        } else {
            ready += 1;
        }
    }

    // Activity stats (if requested)
    var activity_stats: ?ActivityStats = null;
    var issue_refs_list: std.ArrayListUnmanaged(ActivityStats.IssueRef) = .{};
    defer issue_refs_list.deinit(allocator);

    if (stats_args.activity) {
        activity_stats = try getActivityStats(allocator, &ctx, stats_args.activity_hours, &issue_refs_list);
    }

    if (global.isStructuredOutput()) {
        try ctx.output.printJson(StatsJsonResult{
            .summary = .{
                .total_issues = total,
                .open_issues = open,
                .in_progress_issues = in_progress,
                .closed_issues = closed,
                .blocked_issues = blocked,
                .deferred_issues = deferred,
                .ready_issues = ready,
                .tombstone_issues = tombstone,
                .pinned_issues = pinned,
            },
        });
    } else if (!global.quiet) {
        try ctx.output.println("Issue Database Status", .{});
        try ctx.output.print("\n", .{});
        try ctx.output.print("Summary:\n", .{});
        try ctx.output.print("  Total Issues:          {d}\n", .{total});
        try ctx.output.print("  Open:                  {d}\n", .{open});
        try ctx.output.print("  In Progress:           {d}\n", .{in_progress});
        try ctx.output.print("  Blocked:               {d}\n", .{blocked});
        try ctx.output.print("  Closed:                {d}\n", .{closed});
        try ctx.output.print("  Ready to Work:         {d}\n", .{ready});
        try ctx.output.print("\nFor more details, use 'bz list' to see individual issues.\n", .{});

        if (activity_stats) |activity| {
            try ctx.output.print("\nRecent Activity (last {d} hours):\n", .{activity.period_hours});
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
    issue_refs_list: *std.ArrayListUnmanaged(ActivityStats.IssueRef),
) !ActivityStats {
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
        return ActivityStats{
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
    std.mem.sortUnstable(ActivityStats.IssueRef, issue_refs_list.items, {}, struct {
        fn lessThan(_: void, a: ActivityStats.IssueRef, b: ActivityStats.IssueRef) bool {
            return a.commit_count > b.commit_count;
        }
    }.lessThan);

    return ActivityStats{
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

test "StatsJsonResult struct works" {
    const result = StatsJsonResult{
        .summary = .{
            .total_issues = 10,
            .open_issues = 5,
            .in_progress_issues = 0,
            .closed_issues = 5,
            .blocked_issues = 0,
            .deferred_issues = 0,
            .ready_issues = 5,
            .tombstone_issues = 0,
            .pinned_issues = 0,
        },
    };
    try std.testing.expectEqual(@as(usize, 10), result.summary.total_issues);
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
