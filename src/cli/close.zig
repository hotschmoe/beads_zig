//! Close and reopen commands for beads_zig.
//!
//! `bz close <id> [--reason X]` - Close an issue
//! `bz reopen <id>` - Reopen a closed issue
//!
//! Manages the lifecycle of issues.

const std = @import("std");
const models = @import("../models/mod.zig");
const common = @import("common.zig");
const args = @import("args.zig");
const test_util = @import("../test_util.zig");

const Status = models.Status;
const IssueStore = common.IssueStore;
const CommandContext = common.CommandContext;

pub const CloseError = error{
    WorkspaceNotInitialized,
    IssueNotFound,
    AlreadyClosed,
    NotClosed,
    StorageError,
    OutOfMemory,
};

pub const CloseResult = struct {
    success: bool,
    id: ?[]const u8 = null,
    action: ?[]const u8 = null,
    message: ?[]const u8 = null,
};

pub fn run(
    close_args: args.CloseArgs,
    global: args.GlobalOptions,
    allocator: std.mem.Allocator,
) !void {
    var ctx = (try CommandContext.init(allocator, global)) orelse {
        return CloseError.WorkspaceNotInitialized;
    };
    defer ctx.deinit();

    const issue_ref = ctx.store.getRef(close_args.id) orelse {
        try common.outputNotFoundError(CloseResult, &ctx.output, global.isStructuredOutput(), close_args.id, allocator);
        return CloseError.IssueNotFound;
    };

    if (statusEql(issue_ref.status, .closed)) {
        try common.outputErrorTyped(CloseResult, &ctx.output, global.isStructuredOutput(), "issue is already closed");
        return CloseError.AlreadyClosed;
    }

    const now = std.time.timestamp();
    var updates = IssueStore.IssueUpdate{
        .status = .closed,
        .closed_at = now,
    };

    if (close_args.reason) |r| {
        updates.close_reason = r;
    }

    ctx.store.update(close_args.id, updates, now) catch {
        try common.outputErrorTyped(CloseResult, &ctx.output, global.isStructuredOutput(), "failed to close issue");
        return CloseError.StorageError;
    };

    try ctx.saveIfAutoFlush();

    try outputSuccess(&ctx.output, global, close_args.id, "closed", "Closed issue {s}");
}

pub fn runReopen(
    reopen_args: args.ReopenArgs,
    global: args.GlobalOptions,
    allocator: std.mem.Allocator,
) !void {
    var ctx = (try CommandContext.init(allocator, global)) orelse {
        return CloseError.WorkspaceNotInitialized;
    };
    defer ctx.deinit();

    const issue_ref = ctx.store.getRef(reopen_args.id) orelse {
        try common.outputNotFoundError(CloseResult, &ctx.output, global.isStructuredOutput(), reopen_args.id, allocator);
        return CloseError.IssueNotFound;
    };

    if (!statusEql(issue_ref.status, .closed)) {
        try common.outputErrorTyped(CloseResult, &ctx.output, global.isStructuredOutput(), "issue is not closed");
        return CloseError.NotClosed;
    }

    const now = std.time.timestamp();
    const updates = IssueStore.IssueUpdate{
        .status = .open,
        .closed_at = 0,
    };

    ctx.store.update(reopen_args.id, updates, now) catch {
        try common.outputErrorTyped(CloseResult, &ctx.output, global.isStructuredOutput(), "failed to reopen issue");
        return CloseError.StorageError;
    };

    try ctx.saveIfAutoFlush();

    try outputSuccess(&ctx.output, global, reopen_args.id, "reopened", "Reopened issue {s}");
}

fn outputSuccess(
    output: *common.Output,
    global: args.GlobalOptions,
    id: []const u8,
    action: []const u8,
    comptime fmt: []const u8,
) !void {
    if (global.isStructuredOutput()) {
        try output.printJson(CloseResult{
            .success = true,
            .id = id,
            .action = action,
        });
    } else if (global.quiet) {
        try output.raw(id);
        try output.raw("\n");
    } else {
        try output.success(fmt, .{id});
    }
}

fn statusEql(a: Status, b: Status) bool {
    const Tag = std.meta.Tag(Status);
    const tag_a: Tag = a;
    const tag_b: Tag = b;
    if (tag_a != tag_b) return false;
    if (tag_a == .custom) {
        return std.mem.eql(u8, a.custom, b.custom);
    }
    return true;
}

// --- Tests ---

test "CloseError enum exists" {
    const err: CloseError = CloseError.IssueNotFound;
    try std.testing.expect(err == CloseError.IssueNotFound);
}

test "CloseResult struct works" {
    const result = CloseResult{
        .success = true,
        .id = "bd-abc123",
        .action = "closed",
    };
    try std.testing.expect(result.success);
    try std.testing.expectEqualStrings("bd-abc123", result.id.?);
    try std.testing.expectEqualStrings("closed", result.action.?);
}

test "run detects uninitialized workspace" {
    const allocator = std.testing.allocator;

    const close_args = args.CloseArgs{ .id = "bd-test" };
    const global = args.GlobalOptions{ .quiet = true, .data_path = "/nonexistent/path" };

    const result = run(close_args, global, allocator);
    try std.testing.expectError(CloseError.WorkspaceNotInitialized, result);
}

test "runReopen detects uninitialized workspace" {
    const allocator = std.testing.allocator;

    const reopen_args = args.ReopenArgs{ .id = "bd-test" };
    const global = args.GlobalOptions{ .quiet = true, .data_path = "/nonexistent/path" };

    const result = runReopen(reopen_args, global, allocator);
    try std.testing.expectError(CloseError.WorkspaceNotInitialized, result);
}

test "run returns error for missing issue" {
    const allocator = std.testing.allocator;

    const tmp_dir_path = try test_util.createTestDir(allocator, "close_missing");
    defer allocator.free(tmp_dir_path);
    defer test_util.cleanupTestDir(tmp_dir_path);

    const data_path = try std.fs.path.join(allocator, &.{ tmp_dir_path, ".beads" });
    defer allocator.free(data_path);

    try std.fs.cwd().makeDir(data_path);

    const issues_path = try std.fs.path.join(allocator, &.{ data_path, "issues.jsonl" });
    defer allocator.free(issues_path);

    const f = try std.fs.cwd().createFile(issues_path, .{});
    f.close();

    const close_args = args.CloseArgs{ .id = "bd-nonexistent" };
    const global = args.GlobalOptions{ .quiet = true, .data_path = data_path };

    const result = run(close_args, global, allocator);
    try std.testing.expectError(CloseError.IssueNotFound, result);
}
