//! Delete command for beads_zig.
//!
//! `bz delete <id>` - Soft delete an issue (set status to tombstone)
//!
//! This is a soft delete - the issue is marked as tombstone but remains
//! in the database for audit purposes. Use `bz list --all` to see tombstoned issues.

const std = @import("std");
const models = @import("../models/mod.zig");
const common = @import("common.zig");
const args = @import("args.zig");
const test_util = @import("../test_util.zig");

const Status = models.Status;
const IssueStore = common.IssueStore;
const CommandContext = common.CommandContext;

pub const DeleteError = error{
    WorkspaceNotInitialized,
    IssueNotFound,
    AlreadyDeleted,
    StorageError,
    OutOfMemory,
};

pub const DeleteResult = struct {
    success: bool,
    id: ?[]const u8 = null,
    message: ?[]const u8 = null,
};

pub fn run(
    delete_args: args.DeleteArgs,
    global: args.GlobalOptions,
    allocator: std.mem.Allocator,
) !void {
    var ctx = (try CommandContext.init(allocator, global)) orelse {
        return DeleteError.WorkspaceNotInitialized;
    };
    defer ctx.deinit();

    const structured_output = global.isStructuredOutput();
    const issue_ref = ctx.store.getRef(delete_args.id) orelse {
        try common.outputNotFoundError(DeleteResult, &ctx.output, structured_output, delete_args.id, allocator);
        return DeleteError.IssueNotFound;
    };

    if (statusEql(issue_ref.status, .tombstone)) {
        try common.outputErrorTyped(DeleteResult, &ctx.output, structured_output, "issue is already deleted");
        return DeleteError.AlreadyDeleted;
    }

    const now = std.time.timestamp();
    const updates = IssueStore.IssueUpdate{
        .status = .tombstone,
        .closed_at = now,
        .close_reason = "deleted",
    };

    ctx.store.update(delete_args.id, updates, now) catch {
        try common.outputErrorTyped(DeleteResult, &ctx.output, structured_output, "failed to delete issue");
        return DeleteError.StorageError;
    };

    try ctx.saveIfAutoFlush();

    if (structured_output) {
        try ctx.output.printJson(DeleteResult{
            .success = true,
            .id = delete_args.id,
        });
    } else if (global.quiet) {
        try ctx.output.raw(delete_args.id);
        try ctx.output.raw("\n");
    } else {
        try ctx.output.success("Deleted issue {s}", .{delete_args.id});
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

test "DeleteError enum exists" {
    const err: DeleteError = DeleteError.IssueNotFound;
    try std.testing.expect(err == DeleteError.IssueNotFound);
}

test "DeleteResult struct works" {
    const result = DeleteResult{
        .success = true,
        .id = "bd-abc123",
    };
    try std.testing.expect(result.success);
    try std.testing.expectEqualStrings("bd-abc123", result.id.?);
}

test "run detects uninitialized workspace" {
    const allocator = std.testing.allocator;

    const delete_args = args.DeleteArgs{ .id = "bd-test" };
    const global = args.GlobalOptions{ .silent = true, .data_path = "/nonexistent/path" };

    const result = run(delete_args, global, allocator);
    try std.testing.expectError(DeleteError.WorkspaceNotInitialized, result);
}

test "run returns error for missing issue" {
    const allocator = std.testing.allocator;

    const tmp_dir_path = try test_util.createTestDir(allocator, "delete_missing");
    defer allocator.free(tmp_dir_path);
    defer test_util.cleanupTestDir(tmp_dir_path);

    const data_path = try std.fs.path.join(allocator, &.{ tmp_dir_path, ".beads" });
    defer allocator.free(data_path);

    try std.fs.cwd().makeDir(data_path);

    const issues_path = try std.fs.path.join(allocator, &.{ data_path, "issues.jsonl" });
    defer allocator.free(issues_path);

    const f = try std.fs.cwd().createFile(issues_path, .{});
    f.close();

    const delete_args = args.DeleteArgs{ .id = "bd-nonexistent" };
    const global = args.GlobalOptions{ .silent = true, .data_path = data_path };

    const result = run(delete_args, global, allocator);
    try std.testing.expectError(DeleteError.IssueNotFound, result);
}
