//! Show command for beads_zig.
//!
//! `bz show <id>`
//!
//! Displays detailed information about a single issue.

const std = @import("std");
const models = @import("../models/mod.zig");
const common = @import("common.zig");
const args = @import("args.zig");
const test_util = @import("../test_util.zig");

const Issue = models.Issue;
const Comment = models.Comment;
const CommandContext = common.CommandContext;
const Rfc3339Timestamp = @import("../models/issue.zig").Rfc3339Timestamp;

/// Extended issue JSON for show --json, includes dependencies and comments arrays.
/// Field order matches br's show JSON output.
const ShowIssueFull = struct {
    id: []const u8,
    title: []const u8,
    description: ?[]const u8 = null,
    status: []const u8,
    priority: models.Priority,
    issue_type: []const u8,
    created_at: Rfc3339Timestamp,
    created_by: ?[]const u8 = null,
    updated_at: Rfc3339Timestamp,
    source_repo: []const u8 = ".",
    compaction_level: u32 = 0,
    original_size: u64 = 0,
    labels: ?[]const []const u8 = null,
    dependencies: []const DepDetail = &.{},
    comments: []const CommentDetail = &.{},
};

const DepDetail = struct {
    id: []const u8,
    title: []const u8,
    status: []const u8,
    priority: models.Priority,
    dependency_type: []const u8,
};

const CommentDetail = struct {
    id: i64,
    issue_id: []const u8,
    author: []const u8,
    text: []const u8,
    created_at: Rfc3339Timestamp,
};

pub const ShowError = error{
    WorkspaceNotInitialized,
    IssueNotFound,
    StorageError,
    OutOfMemory,
};

pub const ShowResult = struct {
    success: bool,
    issue: ?Issue = null,
    depends_on: ?[]const []const u8 = null,
    blocks: ?[]const []const u8 = null,
    message: ?[]const u8 = null,
};

pub fn run(
    show_args: args.ShowArgs,
    global: args.GlobalOptions,
    allocator: std.mem.Allocator,
) !void {
    var ctx = (try CommandContext.init(allocator, global)) orelse {
        return ShowError.WorkspaceNotInitialized;
    };
    defer ctx.deinit();

    const structured_output = global.isStructuredOutput();

    // Get issue with labels, dependencies, and comments embedded
    var issue = (try ctx.issue_store.getWithRelations(show_args.id)) orelse {
        try common.outputNotFoundError(ShowResult, &ctx.output, structured_output, show_args.id, allocator);
        return ShowError.IssueNotFound;
    };
    defer issue.deinit(allocator);

    // Get dependency info (issues this depends on, and issues that depend on this)
    const deps = try ctx.dep_store.getDependencies(show_args.id);
    defer ctx.dep_store.freeDependencies(deps);

    const dependents = try ctx.dep_store.getDependents(show_args.id);
    defer ctx.dep_store.freeDependencies(dependents);

    if (structured_output) {
        // Build dependency detail array
        // Keep dep issues alive until after JSON serialization
        var dep_issues = try allocator.alloc(?Issue, deps.len);
        defer {
            for (dep_issues) |*di_opt| {
                if (di_opt.*) |*di| di.deinit(allocator);
            }
            allocator.free(dep_issues);
        }

        var dep_details = try allocator.alloc(DepDetail, deps.len);
        defer allocator.free(dep_details);

        for (deps, 0..) |dep, i| {
            dep_issues[i] = ctx.issue_store.get(dep.depends_on_id) catch null;
            const di = dep_issues[i];
            dep_details[i] = .{
                .id = dep.depends_on_id,
                .title = if (di) |d| d.title else "(not found)",
                .status = if (di) |d| d.status.toString() else "unknown",
                .priority = if (di) |d| d.priority else .{ .value = 2 },
                .dependency_type = dep.dep_type.toString(),
            };
        }

        // Build comment detail array
        var comment_details = try allocator.alloc(CommentDetail, issue.comments.len);
        defer allocator.free(comment_details);

        for (issue.comments, 0..) |c, i| {
            comment_details[i] = .{
                .id = c.id,
                .issue_id = c.issue_id,
                .author = c.author,
                .text = c.text,
                .created_at = .{ .value = c.created_at },
            };
        }

        const show_full = ShowIssueFull{
            .id = issue.id,
            .title = issue.title,
            .description = issue.description,
            .status = issue.status.toString(),
            .priority = issue.priority,
            .issue_type = issue.issue_type.toString(),
            .created_at = issue.created_at,
            .created_by = issue.created_by,
            .updated_at = issue.updated_at,
            .source_repo = issue.source_repo orelse ".",
            .compaction_level = issue.compaction_level,
            .original_size = if (issue.original_size) |size| @as(u64, @intCast(size)) else 0,
            .labels = if (issue.labels.len > 0) issue.labels else null,
            .dependencies = dep_details,
            .comments = comment_details,
        };

        const arr = [_]ShowIssueFull{show_full};
        try ctx.output.printJson(&arr);
    } else {
        try ctx.output.printIssue(issue);

        if (deps.len > 0) {
            try ctx.output.print("\nDepends on:\n", .{});
            for (deps) |dep| {
                try ctx.output.print("  - {s}\n", .{dep.depends_on_id});
            }
        }

        if (dependents.len > 0) {
            try ctx.output.print("\nBlocks:\n", .{});
            for (dependents) |dep| {
                try ctx.output.print("  - {s}\n", .{dep.issue_id});
            }
        }

        // Display comments if requested and present
        if (show_args.with_comments and issue.comments.len > 0) {
            try ctx.output.print("\n--- Comments ({d}) ---\n", .{issue.comments.len});
            for (issue.comments) |comment| {
                try printComment(&ctx.output, comment, allocator);
            }
        }

        // Display history from event store
        if (show_args.with_history) {
            const events = try ctx.event_store.getForIssue(show_args.id);
            defer {
                for (events) |evt| {
                    allocator.free(evt.issue_id);
                    allocator.free(evt.actor);
                    if (evt.old_value) |v| allocator.free(v);
                    if (evt.new_value) |v| allocator.free(v);
                    if (evt.comment) |v| allocator.free(v);
                }
                allocator.free(events);
            }

            try ctx.output.print("\n--- History ({d}) ---\n", .{events.len});
            for (events) |evt| {
                const ts_str: ?[]const u8 = common.formatTimestamp(evt.created_at, allocator) catch null;
                defer if (ts_str) |ts| allocator.free(ts);
                try ctx.output.print("  [{s}] {s} by {s}\n", .{
                    ts_str orelse "unknown",
                    evt.event_type.toString(),
                    evt.actor,
                });
            }
        }
    }
}

fn printComment(output: *common.Output, comment: Comment, allocator: std.mem.Allocator) !void {
    const timestamp_str: ?[]const u8 = common.formatTimestamp(comment.created_at, allocator) catch null;
    defer if (timestamp_str) |ts| allocator.free(ts);

    try output.print("\n[{s}] {s}:\n", .{ timestamp_str orelse "unknown", comment.author });
    try output.print("{s}\n", .{comment.text});
}

// --- Tests ---

test "ShowError enum exists" {
    const err: ShowError = ShowError.IssueNotFound;
    try std.testing.expect(err == ShowError.IssueNotFound);
}

test "ShowResult struct works" {
    const result = ShowResult{
        .success = true,
        .message = "test",
    };
    try std.testing.expect(result.success);
}

test "run detects uninitialized workspace" {
    const allocator = std.testing.allocator;

    const show_args = args.ShowArgs{ .id = "bd-test" };
    const global = args.GlobalOptions{ .silent = true, .data_path = "/nonexistent/path" };

    const result = run(show_args, global, allocator);
    try std.testing.expectError(ShowError.WorkspaceNotInitialized, result);
}

test "run returns error for missing issue" {
    const allocator = std.testing.allocator;

    const tmp_dir_path = try test_util.createTestDir(allocator, "show_missing");
    defer allocator.free(tmp_dir_path);
    defer test_util.cleanupTestDir(tmp_dir_path);

    const data_path = try std.fs.path.join(allocator, &.{ tmp_dir_path, ".beads" });
    defer allocator.free(data_path);

    // Initialize workspace
    const init_mod = @import("init.zig");
    try init_mod.run(.{ .prefix = "bd" }, .{ .silent = true, .data_path = data_path }, allocator);

    const show_args = args.ShowArgs{ .id = "bd-nonexistent" };
    const global = args.GlobalOptions{ .silent = true, .data_path = data_path };

    const result = run(show_args, global, allocator);
    try std.testing.expectError(ShowError.IssueNotFound, result);
}

test "formatTimestamp formats correctly" {
    const allocator = std.testing.allocator;

    const ts_str = try common.formatTimestamp(1706540000, allocator);
    defer allocator.free(ts_str);

    try std.testing.expectEqualStrings("2024-01-29 14:53:20", ts_str);
}

test "ShowArgs default values" {
    const show_args = args.ShowArgs{ .id = "bd-test" };
    try std.testing.expect(show_args.with_comments);
    try std.testing.expect(!show_args.with_history);
}

test "ShowArgs with_comments can be disabled" {
    const show_args = args.ShowArgs{ .id = "bd-test", .with_comments = false };
    try std.testing.expect(!show_args.with_comments);
}

test "ShowArgs with_history can be enabled" {
    const show_args = args.ShowArgs{ .id = "bd-test", .with_history = true };
    try std.testing.expect(show_args.with_history);
}
