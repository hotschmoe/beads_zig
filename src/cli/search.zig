//! Search command for beads_zig.
//!
//! `bz search <query> [-n LIMIT]` - Full-text search across issues
//!
//! Searches issue titles, descriptions, and notes using SQLite FTS5.

const std = @import("std");
const models = @import("../models/mod.zig");
const common = @import("common.zig");
const args = @import("args.zig");
const test_util = @import("../test_util.zig");
const output_mod = @import("../output/mod.zig");

const Issue = models.Issue;
const CommandContext = common.CommandContext;

pub const SearchError = error{
    WorkspaceNotInitialized,
    StorageError,
    OutOfMemory,
};

pub const SearchResult = struct {
    success: bool,
    query: ?[]const u8 = null,
    issues: ?[]const IssueMatch = null,
    count: ?usize = null,
    message: ?[]const u8 = null,

    const IssueMatch = struct {
        id: []const u8,
        title: []const u8,
        status: []const u8,
        priority: u3,
    };
};

pub fn run(
    search_args: args.SearchArgs,
    global: args.GlobalOptions,
    allocator: std.mem.Allocator,
) !void {
    var ctx = (try CommandContext.init(allocator, global)) orelse {
        return SearchError.WorkspaceNotInitialized;
    };
    defer ctx.deinit();

    const issues = try ctx.issue_store.search(search_args.query);
    defer {
        for (issues) |*issue| {
            var i = issue.*;
            i.deinit(allocator);
        }
        allocator.free(issues);
    }

    // Apply limit
    const limit = search_args.limit orelse 50;
    const display_count = @min(issues.len, limit);

    try outputResults(&ctx.output, issues[0..display_count], issues.len, search_args, global, allocator);
}

fn outputResults(
    output: *common.Output,
    display_issues: []const Issue,
    total_count: usize,
    search_args: args.SearchArgs,
    global: args.GlobalOptions,
    allocator: std.mem.Allocator,
) !void {
    if (global.isStructuredOutput()) {
        var full_issues = try allocator.alloc(common.IssueFull, display_issues.len);
        defer allocator.free(full_issues);

        for (display_issues, 0..) |issue, i| {
            full_issues[i] = .{
                .id = issue.id,
                .title = issue.title,
                .description = issue.description,
                .status = issue.status.toString(),
                .priority = issue.priority.toDisplayString(),
                .issue_type = issue.issue_type.toString(),
                .assignee = issue.assignee,
                .created_by = issue.created_by,
                .created_at = issue.created_at,
                .updated_at = issue.updated_at,
            };
        }

        // Bare array matching br format
        try output.printJson(full_issues);
    } else if (global.quiet) {
        for (display_issues) |issue| {
            try output.print("{s}\n", .{issue.id});
        }
    } else {
        if (display_issues.len == 0) {
            try output.println("Found 0 issue(s) matching '{s}'", .{search_args.query});
        } else {
            try output.println("Found {d} issue(s) matching '{s}'", .{
                total_count,
                search_args.query,
            });
            try output.print("\n", .{});

            for (display_issues) |issue| {
                const icon = output_mod.statusIcon(issue.status);
                const bullet = output_mod.priorityBullet(issue.priority);
                try output.print("{s} {s} [{s} {s}]  - {s}\n", .{
                    icon,
                    issue.id,
                    bullet,
                    issue.priority.toDisplayString(),
                    issue.title,
                });
            }

            if (total_count > display_issues.len) {
                try output.print("\n...and {d} more (use -n to increase limit)\n", .{
                    total_count - display_issues.len,
                });
            }
        }
    }
}

// --- Tests ---

test "SearchError enum exists" {
    const err: SearchError = SearchError.WorkspaceNotInitialized;
    try std.testing.expect(err == SearchError.WorkspaceNotInitialized);
}

test "SearchResult struct works" {
    const result = SearchResult{
        .success = true,
        .query = "test",
        .count = 3,
    };
    try std.testing.expect(result.success);
    try std.testing.expectEqualStrings("test", result.query.?);
    try std.testing.expectEqual(@as(usize, 3), result.count.?);
}

test "run detects uninitialized workspace" {
    const allocator = std.testing.allocator;

    const search_args = args.SearchArgs{ .query = "test" };
    const global = args.GlobalOptions{ .silent = true, .data_path = "/nonexistent/path" };

    const result = run(search_args, global, allocator);
    try std.testing.expectError(SearchError.WorkspaceNotInitialized, result);
}

test "run returns empty for no matches" {
    const allocator = std.testing.allocator;

    const tmp_dir_path = try test_util.createTestDir(allocator, "search_empty");
    defer allocator.free(tmp_dir_path);
    defer test_util.cleanupTestDir(tmp_dir_path);

    const data_path = try std.fs.path.join(allocator, &.{ tmp_dir_path, ".beads" });
    defer allocator.free(data_path);

    const init_mod = @import("init.zig");
    try init_mod.run(.{ .prefix = "bd" }, .{ .silent = true, .data_path = data_path }, allocator);

    const search_args = args.SearchArgs{ .query = "nonexistent" };
    const global = args.GlobalOptions{ .silent = true, .data_path = data_path };

    try run(search_args, global, allocator);
}
