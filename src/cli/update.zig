//! Update command for beads_zig.
//!
//! `bz update <id> [--status X] [--priority X] [--title X] [--description X] [--assignee X] [--type X]`
//!
//! Modifies an existing issue.

const std = @import("std");
const models = @import("../models/mod.zig");
const common = @import("common.zig");
const args = @import("args.zig");
const test_util = @import("../test_util.zig");
const storage = @import("../storage/mod.zig");
const Event = @import("../models/event.zig").Event;

const Status = models.Status;
const Priority = models.Priority;
const IssueType = models.IssueType;
const IssueUpdate = storage.IssueUpdate;
const CommandContext = common.CommandContext;

pub const UpdateError = error{
    WorkspaceNotInitialized,
    IssueNotFound,
    InvalidArgument,
    StorageError,
    OutOfMemory,
};

pub const UpdateResult = struct {
    success: bool,
    id: ?[]const u8 = null,
    message: ?[]const u8 = null,
};

pub fn run(
    update_args: args.UpdateArgs,
    global: args.GlobalOptions,
    allocator: std.mem.Allocator,
) !void {
    var ctx = (try CommandContext.init(allocator, global)) orelse {
        return UpdateError.WorkspaceNotInitialized;
    };
    defer ctx.deinit();

    const structured_output = global.isStructuredOutput();
    if (!try ctx.issue_store.exists(update_args.id)) {
        try common.outputNotFoundError(UpdateResult, &ctx.output, structured_output, update_args.id, allocator);
        return UpdateError.IssueNotFound;
    }

    var updates = IssueUpdate{};

    if (update_args.title) |t| {
        updates.title = t;
    }

    if (update_args.description) |d| {
        updates.description = d;
    }

    // Handle --claim flag: set assignee to actor AND status to in_progress
    if (update_args.claim) {
        const actor = global.actor orelse common.getDefaultActor() orelse {
            try common.outputErrorTyped(UpdateResult, &ctx.output, structured_output, "--claim requires an actor (use --actor or set $USER)");
            return UpdateError.InvalidArgument;
        };
        updates.assignee = actor;
        updates.status = .in_progress;
    }

    if (update_args.status) |s| {
        updates.status = Status.fromString(s);
    }

    if (update_args.priority) |p| {
        updates.priority = Priority.fromString(p) catch {
            try common.outputErrorTyped(UpdateResult, &ctx.output, structured_output, "invalid priority value");
            return UpdateError.InvalidArgument;
        };
    }

    if (update_args.issue_type) |t| {
        updates.issue_type = IssueType.fromString(t);
    }

    if (update_args.assignee) |a| {
        updates.assignee = a;
    }

    if (update_args.owner) |o| {
        updates.owner = o;
    }

    if (update_args.design) |d| {
        updates.design = d;
    }

    if (update_args.acceptance_criteria) |ac| {
        updates.acceptance_criteria = ac;
    }

    if (update_args.external_ref) |er| {
        updates.external_ref = er;
    }

    const now = std.time.timestamp();
    ctx.issue_store.update(update_args.id, updates, now) catch {
        try common.outputErrorTyped(UpdateResult, &ctx.output, structured_output, "failed to update issue");
        return UpdateError.StorageError;
    };

    // Record audit event
    const actor = global.actor orelse "unknown";
    ctx.recordEvent(Event{
        .id = 0,
        .issue_id = update_args.id,
        .event_type = .updated,
        .actor = actor,
        .old_value = null,
        .new_value = null,
        .created_at = now,
    });

    if (structured_output) {
        try ctx.output.printJson(UpdateResult{
            .success = true,
            .id = update_args.id,
        });
    } else if (global.quiet) {
        try ctx.output.raw(update_args.id);
        try ctx.output.raw("\n");
    } else {
        try ctx.output.success("Updated issue {s}", .{update_args.id});
    }
}

// --- Tests ---

test "UpdateError enum exists" {
    const err: UpdateError = UpdateError.IssueNotFound;
    try std.testing.expect(err == UpdateError.IssueNotFound);
}

test "UpdateResult struct works" {
    const result = UpdateResult{
        .success = true,
        .id = "bd-abc123",
    };
    try std.testing.expect(result.success);
    try std.testing.expectEqualStrings("bd-abc123", result.id.?);
}

test "run detects uninitialized workspace" {
    const allocator = std.testing.allocator;

    const update_args = args.UpdateArgs{ .id = "bd-test" };
    const global = args.GlobalOptions{ .silent = true, .data_path = "/nonexistent/path" };

    const result = run(update_args, global, allocator);
    try std.testing.expectError(UpdateError.WorkspaceNotInitialized, result);
}

test "run returns error for missing issue" {
    const allocator = std.testing.allocator;

    const tmp_dir_path = try test_util.createTestDir(allocator, "update_missing");
    defer allocator.free(tmp_dir_path);
    defer test_util.cleanupTestDir(tmp_dir_path);

    const data_path = try std.fs.path.join(allocator, &.{ tmp_dir_path, ".beads" });
    defer allocator.free(data_path);

    // Initialize workspace
    const init_mod = @import("init.zig");
    try init_mod.run(.{ .prefix = "bd" }, .{ .silent = true, .data_path = data_path }, allocator);

    const update_args = args.UpdateArgs{ .id = "bd-nonexistent", .title = "New title" };
    const global = args.GlobalOptions{ .silent = true, .data_path = data_path };

    const result = run(update_args, global, allocator);
    try std.testing.expectError(UpdateError.IssueNotFound, result);
}
