//! Comments commands for beads_zig.
//!
//! `bz comments add <id> <text>` - Add a comment to an issue
//! `bz comments list <id>` - List comments on an issue

const std = @import("std");
const models = @import("../models/mod.zig");
const common = @import("common.zig");
const args = @import("args.zig");

const Comment = models.Comment;
const CommandContext = common.CommandContext;

pub const CommentsError = error{
    WorkspaceNotInitialized,
    StorageError,
    IssueNotFound,
    EmptyCommentBody,
    OutOfMemory,
};

const Rfc3339Timestamp = @import("../models/issue.zig").Rfc3339Timestamp;

pub const CommentsResult = struct {
    success: bool,
    id: ?[]const u8 = null,
    comment_id: ?i64 = null,
    author: ?[]const u8 = null,
    comments: ?[]const CommentInfo = null,
    message: ?[]const u8 = null,

    pub const CommentInfo = struct {
        id: i64,
        author: []const u8,
        text: []const u8,
        created_at: i64,
    };
};

/// Comment JSON representation with RFC3339 timestamp for bare-array output.
const CommentJson = struct {
    id: i64,
    issue_id: []const u8,
    author: []const u8,
    text: []const u8,
    created_at: Rfc3339Timestamp,
};

pub fn run(
    comments_args: args.CommentsArgs,
    global: args.GlobalOptions,
    allocator: std.mem.Allocator,
) !void {
    switch (comments_args.subcommand) {
        .add => |add| try runAdd(add.id, add.text, global, allocator),
        .list => |list| try runList(list.id, global, allocator),
    }
}

fn runAdd(
    id: []const u8,
    text: []const u8,
    global: args.GlobalOptions,
    allocator: std.mem.Allocator,
) !void {
    var ctx = (try CommandContext.init(allocator, global)) orelse {
        return CommentsError.WorkspaceNotInitialized;
    };
    defer ctx.deinit();

    if (text.len == 0) {
        if (global.isStructuredOutput()) {
            try ctx.output.printJson(CommentsResult{
                .success = false,
                .message = "comment text cannot be empty",
            });
        } else {
            try ctx.output.err("comment text cannot be empty", .{});
        }
        return CommentsError.EmptyCommentBody;
    }

    // Verify issue exists
    if (!try ctx.issue_store.exists(id)) {
        if (global.isStructuredOutput()) {
            try ctx.output.printJson(CommentsResult{
                .success = false,
                .id = id,
                .message = "issue not found",
            });
        } else {
            try ctx.output.err("issue not found: {s}", .{id});
        }
        return CommentsError.IssueNotFound;
    }

    // Get actor name
    const actor = global.actor orelse getDefaultActor();
    const now = std.time.timestamp();

    // Generate comment ID (use timestamp for simplicity)
    const comment_id = now;

    const comment = Comment{
        .id = comment_id,
        .issue_id = id,
        .author = actor,
        .text = text,
        .created_at = now,
    };

    try ctx.issue_store.addComment(id, comment);

    if (global.isStructuredOutput()) {
        try ctx.output.printJson(CommentsResult{
            .success = true,
            .id = id,
            .comment_id = comment_id,
            .author = actor,
        });
    } else if (global.quiet) {
        try ctx.output.print("{d}\n", .{comment_id});
    } else {
        try ctx.output.success("Comment added to {s}", .{id});
    }
}

fn runList(
    id: []const u8,
    global: args.GlobalOptions,
    allocator: std.mem.Allocator,
) !void {
    var ctx = (try CommandContext.init(allocator, global)) orelse {
        return CommentsError.WorkspaceNotInitialized;
    };
    defer ctx.deinit();

    // Verify issue exists
    if (!try ctx.issue_store.exists(id)) {
        if (global.isStructuredOutput()) {
            try ctx.output.printJson(CommentsResult{
                .success = false,
                .id = id,
                .message = "issue not found",
            });
        } else {
            try ctx.output.err("issue not found: {s}", .{id});
        }
        return CommentsError.IssueNotFound;
    }

    const comments = try ctx.issue_store.getComments(id);
    defer {
        for (comments) |c| {
            allocator.free(c.issue_id);
            allocator.free(c.author);
            allocator.free(c.text);
        }
        allocator.free(comments);
    }

    if (global.isStructuredOutput()) {
        var comment_jsons = try allocator.alloc(CommentJson, comments.len);
        defer allocator.free(comment_jsons);

        for (comments, 0..) |c, i| {
            comment_jsons[i] = .{
                .id = c.id,
                .issue_id = c.issue_id,
                .author = c.author,
                .text = c.text,
                .created_at = .{ .value = c.created_at },
            };
        }

        try ctx.output.printJson(comment_jsons);
    } else if (global.quiet) {
        for (comments) |c| {
            try ctx.output.print("{d}\n", .{c.id});
        }
    } else {
        if (comments.len == 0) {
            try ctx.output.info("No comments on {s}", .{id});
        } else {
            try ctx.output.println("Comments for {s}:", .{id});
            for (comments) |c| {
                try ctx.output.print("\n", .{});
                const ts_str = common.formatTimestampShort(c.created_at, allocator) catch "unknown";
                defer if (!std.mem.eql(u8, ts_str, "unknown")) allocator.free(ts_str);
                try ctx.output.print("[{s}] at {s} UTC\n", .{ c.author, ts_str });
                try ctx.output.print("  {s}\n", .{c.text});
            }
        }
    }
}

fn getDefaultActor() []const u8 {
    return common.getDefaultActor() orelse "unknown";
}

// --- Tests ---

test "CommentsError enum exists" {
    const err: CommentsError = CommentsError.WorkspaceNotInitialized;
    try std.testing.expect(err == CommentsError.WorkspaceNotInitialized);
}

test "CommentsResult struct works" {
    const result = CommentsResult{
        .success = true,
        .id = "bd-test",
        .comment_id = 123,
    };
    try std.testing.expect(result.success);
    try std.testing.expectEqualStrings("bd-test", result.id.?);
    try std.testing.expectEqual(@as(i64, 123), result.comment_id.?);
}

test "runAdd detects uninitialized workspace" {
    const allocator = std.testing.allocator;

    const comments_args = args.CommentsArgs{
        .subcommand = .{ .add = .{ .id = "bd-test", .text = "test comment" } },
    };
    const global = args.GlobalOptions{ .silent = true, .data_path = "/nonexistent/path" };

    const result = run(comments_args, global, allocator);
    try std.testing.expectError(CommentsError.WorkspaceNotInitialized, result);
}

test "runList detects uninitialized workspace" {
    const allocator = std.testing.allocator;

    const comments_args = args.CommentsArgs{
        .subcommand = .{ .list = .{ .id = "bd-test" } },
    };
    const global = args.GlobalOptions{ .silent = true, .data_path = "/nonexistent/path" };

    const result = run(comments_args, global, allocator);
    try std.testing.expectError(CommentsError.WorkspaceNotInitialized, result);
}
