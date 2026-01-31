//! Search command for beads_zig.
//!
//! `bz search <query> [-n LIMIT]` - Full-text search across issues
//!
//! Searches issue titles, descriptions, and notes using substring matching.

const std = @import("std");
const models = @import("../models/mod.zig");
const common = @import("common.zig");
const args = @import("args.zig");
const test_util = @import("../test_util.zig");

const Issue = models.Issue;
const Status = models.Status;
const IssueStore = common.IssueStore;
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
        match_field: []const u8, // Which field matched
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

    const query_lower = try toLower(search_args.query, allocator);
    defer allocator.free(query_lower);

    var matches: std.ArrayListUnmanaged(MatchedIssue) = .{};
    defer matches.deinit(allocator);

    // Linear scan with substring matching
    for (ctx.store.issues.items) |issue| {
        // Skip tombstoned issues
        if (issue.status.eql(.tombstone)) continue;

        // Check title
        const title_lower = try toLower(issue.title, allocator);
        defer allocator.free(title_lower);

        if (std.mem.indexOf(u8, title_lower, query_lower) != null) {
            try matches.append(allocator, .{ .issue = issue, .match_field = "title" });
            continue;
        }

        // Check description
        if (issue.description) |desc| {
            const desc_lower = try toLower(desc, allocator);
            defer allocator.free(desc_lower);

            if (std.mem.indexOf(u8, desc_lower, query_lower) != null) {
                try matches.append(allocator, .{ .issue = issue, .match_field = "description" });
                continue;
            }
        }

        // Check notes
        if (issue.notes) |notes| {
            const notes_lower = try toLower(notes, allocator);
            defer allocator.free(notes_lower);

            if (std.mem.indexOf(u8, notes_lower, query_lower) != null) {
                try matches.append(allocator, .{ .issue = issue, .match_field = "notes" });
                continue;
            }
        }

        // Check ID
        const id_lower = try toLower(issue.id, allocator);
        defer allocator.free(id_lower);

        if (std.mem.indexOf(u8, id_lower, query_lower) != null) {
            try matches.append(allocator, .{ .issue = issue, .match_field = "id" });
            continue;
        }
    }

    // Apply limit
    const limit = search_args.limit orelse 50;
    const display_count = @min(matches.items.len, limit);
    const display_matches = matches.items[0..display_count];

    if (global.isStructuredOutput()) {
        var result_issues = try allocator.alloc(SearchResult.IssueMatch, display_count);
        defer allocator.free(result_issues);

        for (display_matches, 0..) |m, i| {
            result_issues[i] = .{
                .id = m.issue.id,
                .title = m.issue.title,
                .status = m.issue.status.toString(),
                .priority = m.issue.priority.value,
                .match_field = m.match_field,
            };
        }

        try ctx.output.printJson(SearchResult{
            .success = true,
            .query = search_args.query,
            .issues = result_issues,
            .count = matches.items.len,
        });
    } else if (global.quiet) {
        for (display_matches) |m| {
            try ctx.output.print("{s}\n", .{m.issue.id});
        }
    } else {
        if (display_matches.len == 0) {
            try ctx.output.info("No issues matching \"{s}\"", .{search_args.query});
        } else {
            try ctx.output.println("Search results for \"{s}\" ({d} match{s}):", .{
                search_args.query,
                matches.items.len,
                if (matches.items.len == 1) "" else "es",
            });
            try ctx.output.print("\n", .{});

            for (display_matches) |m| {
                try ctx.output.print("{s}  [{s}]  {s}  (matched in {s})\n", .{
                    m.issue.id,
                    m.issue.status.toString(),
                    m.issue.title,
                    m.match_field,
                });
            }

            if (matches.items.len > display_count) {
                try ctx.output.print("\n...and {d} more (use -n to increase limit)\n", .{
                    matches.items.len - display_count,
                });
            }
        }
    }
}

const MatchedIssue = struct {
    issue: Issue,
    match_field: []const u8,
};

fn toLower(s: []const u8, allocator: std.mem.Allocator) ![]u8 {
    const result = try allocator.alloc(u8, s.len);
    for (s, 0..) |c, i| {
        result[i] = std.ascii.toLower(c);
    }
    return result;
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

test "toLower converts string correctly" {
    const allocator = std.testing.allocator;
    const result = try toLower("Hello World", allocator);
    defer allocator.free(result);

    try std.testing.expectEqualStrings("hello world", result);
}

test "run returns empty for no matches" {
    const allocator = std.testing.allocator;

    const tmp_dir_path = try test_util.createTestDir(allocator, "search_empty");
    defer allocator.free(tmp_dir_path);
    defer test_util.cleanupTestDir(tmp_dir_path);

    const data_path = try std.fs.path.join(allocator, &.{ tmp_dir_path, ".beads" });
    defer allocator.free(data_path);

    try std.fs.cwd().makeDir(data_path);

    const issues_path = try std.fs.path.join(allocator, &.{ data_path, "issues.jsonl" });
    defer allocator.free(issues_path);

    const f = try std.fs.cwd().createFile(issues_path, .{});
    f.close();

    const search_args = args.SearchArgs{ .query = "nonexistent" };
    const global = args.GlobalOptions{ .silent = true, .data_path = data_path };

    try run(search_args, global, allocator);
}
