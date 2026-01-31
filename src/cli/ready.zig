//! Ready and blocked commands for beads_zig.
//!
//! `bz ready [-n LIMIT]` - Show issues ready to work on (no blockers)
//! `bz blocked [-n LIMIT]` - Show blocked issues
//!
//! Workflow queries for finding actionable work.

const std = @import("std");
const models = @import("../models/mod.zig");
const common = @import("common.zig");
const args = @import("args.zig");
const test_util = @import("../test_util.zig");

const Issue = models.Issue;
const CommandContext = common.CommandContext;
const DependencyGraph = common.DependencyGraph;

pub const ReadyError = error{
    WorkspaceNotInitialized,
    StorageError,
    OutOfMemory,
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

    var graph = ctx.createGraph();
    const issues = try graph.getReadyIssues();
    defer graph.freeIssues(issues);

    const display_issues = applyLimit(issues, ready_args.limit);

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

    var graph = ctx.createGraph();
    const issues = try graph.getBlockedIssues();
    defer graph.freeIssues(issues);

    const display_issues = applyLimit(issues, blocked_args.limit);

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
