//! Update command for beads_zig.
//!
//! `bz update <id> [--status X] [--priority X] [--title X] [--description X] [--assignee X] [--type X]`
//!
//! Modifies an existing issue.

const std = @import("std");
const models = @import("../models/mod.zig");
const storage = @import("../storage/mod.zig");
const Output = @import("../output/mod.zig").Output;
const OutputOptions = @import("../output/mod.zig").OutputOptions;
const args = @import("args.zig");
const test_util = @import("../test_util.zig");

const Issue = models.Issue;
const Status = models.Status;
const Priority = models.Priority;
const IssueType = models.IssueType;
const IssueStore = storage.IssueStore;

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
    var output = Output.init(allocator, OutputOptions{
        .json = global.json,
        .quiet = global.quiet,
        .no_color = global.no_color,
    });

    // Determine workspace path
    const beads_dir = global.data_path orelse ".beads";
    const issues_path = try std.fs.path.join(allocator, &.{ beads_dir, "issues.jsonl" });
    defer allocator.free(issues_path);

    // Check if workspace is initialized
    std.fs.cwd().access(issues_path, .{}) catch |err| {
        if (err == error.FileNotFound) {
            try outputError(&output, global.json, "workspace not initialized. Run 'bz init' first.");
            return UpdateError.WorkspaceNotInitialized;
        }
        try outputError(&output, global.json, "cannot access workspace");
        return UpdateError.StorageError;
    };

    // Load issues
    var store = IssueStore.init(allocator, issues_path);
    defer store.deinit();

    store.loadFromFile() catch |err| {
        if (err != error.FileNotFound) {
            try outputError(&output, global.json, "failed to load issues");
            return UpdateError.StorageError;
        }
    };

    // Check if issue exists
    if (!try store.exists(update_args.id)) {
        const msg = try std.fmt.allocPrint(allocator, "issue not found: {s}", .{update_args.id});
        defer allocator.free(msg);
        try outputError(&output, global.json, msg);
        return UpdateError.IssueNotFound;
    }

    // Build update struct
    var updates = IssueStore.IssueUpdate{};

    if (update_args.title) |t| {
        updates.title = t;
    }

    if (update_args.description) |d| {
        updates.description = d;
    }

    if (update_args.status) |s| {
        updates.status = Status.fromString(s);
    }

    if (update_args.priority) |p| {
        updates.priority = Priority.fromString(p) catch {
            try outputError(&output, global.json, "invalid priority value");
            return UpdateError.InvalidArgument;
        };
    }

    if (update_args.issue_type) |t| {
        updates.issue_type = IssueType.fromString(t);
    }

    if (update_args.assignee) |a| {
        updates.assignee = a;
    }

    // Apply update
    const now = std.time.timestamp();
    store.update(update_args.id, updates, now) catch {
        try outputError(&output, global.json, "failed to update issue");
        return UpdateError.StorageError;
    };

    // Save to file
    if (!global.no_auto_flush) {
        store.saveToFile() catch {
            try outputError(&output, global.json, "failed to save issues");
            return UpdateError.StorageError;
        };
    }

    // Output
    if (global.json) {
        try output.printJson(UpdateResult{
            .success = true,
            .id = update_args.id,
        });
    } else if (global.quiet) {
        try output.raw(update_args.id);
        try output.raw("\n");
    } else {
        try output.success("Updated issue {s}", .{update_args.id});
    }
}

fn outputError(output: *Output, json_mode: bool, message: []const u8) !void {
    if (json_mode) {
        try output.printJson(UpdateResult{
            .success = false,
            .message = message,
        });
    } else {
        try output.err("{s}", .{message});
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
    const global = args.GlobalOptions{ .quiet = true, .data_path = "/nonexistent/path" };

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

    try std.fs.cwd().makeDir(data_path);

    const issues_path = try std.fs.path.join(allocator, &.{ data_path, "issues.jsonl" });
    defer allocator.free(issues_path);

    const f = try std.fs.cwd().createFile(issues_path, .{});
    f.close();

    const update_args = args.UpdateArgs{ .id = "bd-nonexistent", .title = "New title" };
    const global = args.GlobalOptions{ .quiet = true, .data_path = data_path };

    const result = run(update_args, global, allocator);
    try std.testing.expectError(UpdateError.IssueNotFound, result);
}
