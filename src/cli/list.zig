//! List command for beads_zig.
//!
//! `bz list [--status X] [--priority X] [--type X] [--assignee X] [--label X] [-n LIMIT] [--all]`
//!
//! Lists issues with optional filters.

const std = @import("std");
const models = @import("../models/mod.zig");
const common = @import("common.zig");
const args = @import("args.zig");
const test_util = @import("../test_util.zig");

const Issue = models.Issue;
const Status = models.Status;
const Priority = models.Priority;
const IssueType = models.IssueType;
const IssueStore = common.IssueStore;
const CommandContext = common.CommandContext;

pub const ListError = error{
    WorkspaceNotInitialized,
    InvalidFilter,
    StorageError,
    OutOfMemory,
};

pub const ListResult = struct {
    success: bool,
    issues: ?[]const IssueCompact = null,
    count: ?usize = null,
    message: ?[]const u8 = null,

    const IssueCompact = struct {
        id: []const u8,
        title: []const u8,
        status: []const u8,
        priority: u3,
        issue_type: []const u8,
        assignee: ?[]const u8 = null,
    };
};

pub fn run(
    list_args: args.ListArgs,
    global: args.GlobalOptions,
    allocator: std.mem.Allocator,
) !void {
    var ctx = (try CommandContext.init(allocator, global)) orelse {
        return ListError.WorkspaceNotInitialized;
    };
    defer ctx.deinit();

    var filters = IssueStore.ListFilters{};

    if (list_args.status) |s| {
        filters.status = Status.fromString(s);
    } else if (!list_args.all) {
        filters.status = .open;
    }

    if (list_args.priority) |p| {
        filters.priority = Priority.fromString(p) catch {
            try outputError(&ctx.output, global.isStructuredOutput(), "invalid priority value");
            return ListError.InvalidFilter;
        };
    }

    if (list_args.issue_type) |t| {
        filters.issue_type = IssueType.fromString(t);
    }

    if (list_args.assignee) |a| {
        filters.assignee = a;
    }

    if (list_args.label) |l| {
        filters.label = l;
    }

    if (list_args.limit) |n| {
        filters.limit = n;
    }

    // Apply sort options
    filters.order_by = switch (list_args.sort) {
        .created_at => .created_at,
        .updated_at => .updated_at,
        .priority => .priority,
    };
    filters.order_desc = list_args.sort_desc;

    const issues = try ctx.store.list(filters);
    defer {
        for (issues) |*issue| {
            var i = issue.*;
            i.deinit(allocator);
        }
        allocator.free(issues);
    }

    if (global.isStructuredOutput()) {
        var compact_issues = try allocator.alloc(ListResult.IssueCompact, issues.len);
        defer allocator.free(compact_issues);

        for (issues, 0..) |issue, i| {
            compact_issues[i] = .{
                .id = issue.id,
                .title = issue.title,
                .status = issue.status.toString(),
                .priority = issue.priority.value,
                .issue_type = issue.issue_type.toString(),
                .assignee = issue.assignee,
            };
        }

        try ctx.output.printJson(ListResult{
            .success = true,
            .issues = compact_issues,
            .count = issues.len,
        });
    } else {
        try ctx.output.printIssueList(issues);
        if (!global.quiet and issues.len == 0) {
            try ctx.output.info("No issues found", .{});
        }
    }
}

fn outputError(output: *common.Output, structured_mode: bool, message: []const u8) !void {
    if (structured_mode) {
        try output.printJson(ListResult{
            .success = false,
            .message = message,
        });
    } else {
        try output.err("{s}", .{message});
    }
}

// --- Tests ---

test "ListError enum exists" {
    const err: ListError = ListError.WorkspaceNotInitialized;
    try std.testing.expect(err == ListError.WorkspaceNotInitialized);
}

test "ListResult struct works" {
    const result = ListResult{
        .success = true,
        .count = 5,
    };
    try std.testing.expect(result.success);
    try std.testing.expectEqual(@as(usize, 5), result.count.?);
}

test "run detects uninitialized workspace" {
    const allocator = std.testing.allocator;

    const list_args = args.ListArgs{};
    const global = args.GlobalOptions{ .silent = true, .data_path = "/nonexistent/path" };

    const result = run(list_args, global, allocator);
    try std.testing.expectError(ListError.WorkspaceNotInitialized, result);
}

test "run lists issues successfully" {
    const allocator = std.testing.allocator;

    const tmp_dir_path = try test_util.createTestDir(allocator, "list_success");
    defer allocator.free(tmp_dir_path);
    defer test_util.cleanupTestDir(tmp_dir_path);

    const data_path = try std.fs.path.join(allocator, &.{ tmp_dir_path, ".beads" });
    defer allocator.free(data_path);

    try std.fs.cwd().makeDir(data_path);

    const issues_path = try std.fs.path.join(allocator, &.{ data_path, "issues.jsonl" });
    defer allocator.free(issues_path);

    const f = try std.fs.cwd().createFile(issues_path, .{});
    defer f.close();

    const list_args = args.ListArgs{ .all = true };
    const global = args.GlobalOptions{ .silent = true, .data_path = data_path };

    try run(list_args, global, allocator);
}
