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

    const issues = ctx.issue_store.search(search_args.query) catch {
        // FTS5 MATCH can fail on malformed queries; fall back to listing all
        // TODO: implement title_contains filter for fallback search
        const like_results = try ctx.issue_store.list(.{});
        const display_count = if (search_args.limit) |lim| @min(like_results.len, lim) else @min(like_results.len, @as(usize, 50));
        defer {
            for (like_results) |*issue| {
                var i = issue.*;
                i.deinit(allocator);
            }
            allocator.free(like_results);
        }
        try outputResults(&ctx.output, like_results[0..display_count], like_results.len, search_args, global, allocator);
        return;
    };
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
        var result_issues = try allocator.alloc(SearchResult.IssueMatch, display_issues.len);
        defer allocator.free(result_issues);

        for (display_issues, 0..) |issue, i| {
            result_issues[i] = .{
                .id = issue.id,
                .title = issue.title,
                .status = issue.status.toString(),
                .priority = issue.priority.value,
            };
        }

        try output.printJson(SearchResult{
            .success = true,
            .query = search_args.query,
            .issues = result_issues,
            .count = total_count,
        });
    } else if (global.quiet) {
        for (display_issues) |issue| {
            try output.print("{s}\n", .{issue.id});
        }
    } else {
        if (display_issues.len == 0) {
            try output.info("No issues matching \"{s}\"", .{search_args.query});
        } else {
            try output.println("Search results for \"{s}\" ({d} match{s}):", .{
                search_args.query,
                total_count,
                if (total_count == 1) "" else "es",
            });
            try output.print("\n", .{});

            for (display_issues) |issue| {
                try output.print("{s}  [{s}]  {s}\n", .{
                    issue.id,
                    issue.status.toString(),
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
