//! Delete command for beads_zig.
//!
//! `bz delete <id>` - Soft delete an issue (set status to tombstone)
//! `bz delete --from-file <path>` - Delete multiple issues from a file
//! `bz delete <id> --cascade` - Delete issue and all its dependents
//! `bz delete <id> --dry-run` - Preview what would be deleted
//!
//! By default, this is a soft delete - the issue is marked as tombstone but remains
//! in the database for audit purposes. Use `bz list --all` to see tombstoned issues.

const std = @import("std");
const models = @import("../models/mod.zig");
const storage = @import("../storage/mod.zig");
const common = @import("common.zig");
const args = @import("args.zig");
const test_util = @import("../test_util.zig");
const Event = @import("../models/event.zig").Event;

const Status = models.Status;
const CommandContext = common.CommandContext;
const Output = common.Output;

/// Output a list of IDs, one per line (used for quiet/robot output).
fn outputIdList(output: *Output, ids: []const []const u8) !void {
    for (ids) |id| {
        try output.raw(id);
        try output.raw("\n");
    }
}

/// Create a slice of IDs from the ArrayList (for JSON output).
fn createIdSlice(allocator: std.mem.Allocator, ids: std.ArrayListUnmanaged([]const u8)) ![]const []const u8 {
    const id_slice = try allocator.alloc([]const u8, ids.items.len);
    for (ids.items, 0..) |id, i| {
        id_slice[i] = id;
    }
    return id_slice;
}

pub const DeleteError = error{
    WorkspaceNotInitialized,
    IssueNotFound,
    AlreadyDeleted,
    StorageError,
    OutOfMemory,
    FileReadError,
    InvalidInput,
};

pub const DeleteResult = struct {
    success: bool,
    ids: ?[]const []const u8 = null,
    deleted_count: ?usize = null,
    message: ?[]const u8 = null,
    dry_run: bool = false,
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

    // Collect all IDs to delete
    var ids_to_delete: std.ArrayListUnmanaged([]const u8) = .{};
    defer ids_to_delete.deinit(allocator);

    if (delete_args.from_file) |file_path| {
        // Read IDs from file
        const file = std.fs.cwd().openFile(file_path, .{}) catch {
            try common.outputErrorTyped(DeleteResult, &ctx.output, structured_output, "cannot open file");
            return DeleteError.FileReadError;
        };
        defer file.close();

        const content = file.readToEndAlloc(allocator, 1024 * 1024) catch {
            try common.outputErrorTyped(DeleteResult, &ctx.output, structured_output, "cannot read file");
            return DeleteError.FileReadError;
        };
        defer allocator.free(content);

        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0) continue;
            if (trimmed[0] == '#') continue; // Skip comments
            const id_copy = try allocator.dupe(u8, trimmed);
            try ids_to_delete.append(allocator, id_copy);
        }

        if (ids_to_delete.items.len == 0) {
            try common.outputErrorTyped(DeleteResult, &ctx.output, structured_output, "no valid IDs in file");
            return DeleteError.InvalidInput;
        }
    } else if (delete_args.id) |id| {
        const id_copy = try allocator.dupe(u8, id);
        try ids_to_delete.append(allocator, id_copy);
    } else {
        try common.outputErrorTyped(DeleteResult, &ctx.output, structured_output, "no issue ID specified");
        return DeleteError.InvalidInput;
    }
    defer {
        for (ids_to_delete.items) |id| {
            allocator.free(id);
        }
    }

    // If cascade mode, expand to include all dependents
    if (delete_args.cascade) {
        var expanded_ids: std.StringHashMapUnmanaged(void) = .{};
        defer {
            var key_it = expanded_ids.keyIterator();
            while (key_it.next()) |key| {
                allocator.free(key.*);
            }
            expanded_ids.deinit(allocator);
        }

        // Add initial IDs
        for (ids_to_delete.items) |id| {
            if (!expanded_ids.contains(id)) {
                const id_copy = try allocator.dupe(u8, id);
                try expanded_ids.put(allocator, id_copy, {});
            }
        }

        // Recursively add all dependents using BFS
        var work_queue: std.ArrayListUnmanaged([]const u8) = .{};
        defer work_queue.deinit(allocator);

        for (ids_to_delete.items) |id| {
            try work_queue.append(allocator, id);
        }

        while (work_queue.items.len > 0) {
            const current_id = work_queue.orderedRemove(0);
            const dependents = ctx.dep_store.getDependents(current_id) catch continue;
            defer ctx.dep_store.freeDependencies(dependents);

            for (dependents) |dep| {
                if (!expanded_ids.contains(dep.issue_id)) {
                    const dep_id_copy = try allocator.dupe(u8, dep.issue_id);
                    try expanded_ids.put(allocator, dep_id_copy, {});
                    try work_queue.append(allocator, dep_id_copy);
                }
            }
        }

        // Replace ids_to_delete with expanded set
        for (ids_to_delete.items) |id| {
            allocator.free(id);
        }
        ids_to_delete.clearRetainingCapacity();

        var id_it = expanded_ids.keyIterator();
        while (id_it.next()) |key| {
            const id_copy = try allocator.dupe(u8, key.*);
            try ids_to_delete.append(allocator, id_copy);
        }
    }

    // Dry run mode - just report what would be deleted
    if (delete_args.dry_run) {
        if (structured_output) {
            const id_slice = try createIdSlice(allocator, ids_to_delete);
            defer allocator.free(id_slice);
            try ctx.output.printJson(DeleteResult{
                .success = true,
                .ids = id_slice,
                .deleted_count = ids_to_delete.items.len,
                .dry_run = true,
                .message = "dry run - no changes made",
            });
        } else if (global.robot) {
            try ctx.output.raw("DRY_RUN\t");
            try ctx.output.print("{d}\n", .{ids_to_delete.items.len});
            try outputIdList(&ctx.output, ids_to_delete.items);
        } else if (global.quiet) {
            try outputIdList(&ctx.output, ids_to_delete.items);
        } else {
            try ctx.output.print("Would delete {d} issue(s):\n", .{ids_to_delete.items.len});
            for (ids_to_delete.items) |id| {
                try ctx.output.print("  {s}\n", .{id});
            }
        }
        return;
    }

    // Perform the actual deletion
    const now = std.time.timestamp();
    const actor = common.getDefaultActor() orelse "system";
    var deleted_count: usize = 0;
    var not_found_count: usize = 0;

    for (ids_to_delete.items) |id| {
        const issue = (try ctx.issue_store.get(id)) orelse {
            not_found_count += 1;
            continue;
        };
        defer {
            var i = issue;
            i.deinit(allocator);
        }

        if (issue.status.eql(.tombstone) and !delete_args.hard) {
            continue;
        }

        if (delete_args.hard) {
            ctx.issue_store.hardDelete(id) catch {
                continue;
            };
            ctx.recordEvent(Event.issueDeleted(id, actor, now));
        } else {
            ctx.issue_store.softDelete(id, actor, "deleted", now) catch |err| {
                if (err == storage.IssueStoreError.IssueNotFound) {
                    not_found_count += 1;
                }
                continue;
            };
            ctx.recordEvent(Event.issueDeleted(id, actor, now));
        }
        deleted_count += 1;
    }

    // Output result
    if (structured_output) {
        const id_slice = try createIdSlice(allocator, ids_to_delete);
        defer allocator.free(id_slice);
        try ctx.output.printJson(DeleteResult{
            .success = deleted_count > 0,
            .ids = id_slice,
            .deleted_count = deleted_count,
        });
    } else if (global.robot) {
        try ctx.output.raw("OK\t");
        try ctx.output.print("{d}\n", .{deleted_count});
        try outputIdList(&ctx.output, ids_to_delete.items);
    } else if (global.quiet) {
        try outputIdList(&ctx.output, ids_to_delete.items);
    } else {
        if (deleted_count == 1 and ids_to_delete.items.len == 1) {
            if (delete_args.hard) {
                try ctx.output.success("Permanently deleted issue {s}", .{ids_to_delete.items[0]});
            } else {
                try ctx.output.success("Deleted issue {s}", .{ids_to_delete.items[0]});
            }
        } else {
            if (delete_args.hard) {
                try ctx.output.success("Permanently deleted {d} issue(s)", .{deleted_count});
            } else {
                try ctx.output.success("Deleted {d} issue(s)", .{deleted_count});
            }
        }

        if (not_found_count > 0) {
            try ctx.output.warn("{d} issue(s) not found", .{not_found_count});
        }
    }
}

// --- Tests ---

test "DeleteError enum exists" {
    const err: DeleteError = DeleteError.IssueNotFound;
    try std.testing.expect(err == DeleteError.IssueNotFound);
}

test "DeleteResult struct works" {
    const ids = [_][]const u8{"bd-abc123"};
    const result = DeleteResult{
        .success = true,
        .ids = &ids,
        .deleted_count = 1,
    };
    try std.testing.expect(result.success);
    try std.testing.expectEqual(@as(usize, 1), result.ids.?.len);
    try std.testing.expectEqualStrings("bd-abc123", result.ids.?[0]);
}

test "run detects uninitialized workspace" {
    const allocator = std.testing.allocator;

    const delete_args = args.DeleteArgs{ .id = "bd-test" };
    const global = args.GlobalOptions{ .silent = true, .data_path = "/nonexistent/path" };

    const result = run(delete_args, global, allocator);
    try std.testing.expectError(DeleteError.WorkspaceNotInitialized, result);
}

test "run handles missing issue gracefully" {
    const allocator = std.testing.allocator;

    const tmp_dir_path = try test_util.createTestDir(allocator, "delete_missing");
    defer allocator.free(tmp_dir_path);
    defer test_util.cleanupTestDir(tmp_dir_path);

    const data_path = try std.fs.path.join(allocator, &.{ tmp_dir_path, ".beads" });
    defer allocator.free(data_path);

    // Initialize workspace
    const init_mod = @import("init.zig");
    try init_mod.run(.{ .prefix = "bd" }, .{ .silent = true, .data_path = data_path }, allocator);

    const delete_args = args.DeleteArgs{ .id = "bd-nonexistent" };
    const global = args.GlobalOptions{ .silent = true, .data_path = data_path };

    // softDelete returns IssueNotFound which we catch and count, so run completes
    try run(delete_args, global, allocator);
}
