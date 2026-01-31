//! Close and reopen commands for beads_zig.
//!
//! `bz close <id> [--reason X]` - Close an issue
//! `bz reopen <id>` - Reopen a closed issue
//!
//! Manages the lifecycle of issues.

const std = @import("std");
const models = @import("../models/mod.zig");
const storage = @import("../storage/mod.zig");
const Output = @import("../output/mod.zig").Output;
const OutputOptions = @import("../output/mod.zig").OutputOptions;
const args = @import("args.zig");
const test_util = @import("../test_util.zig");

const Issue = models.Issue;
const Status = models.Status;
const IssueStore = storage.IssueStore;

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
            return CloseError.WorkspaceNotInitialized;
        }
        try outputError(&output, global.json, "cannot access workspace");
        return CloseError.StorageError;
    };

    // Load issues
    var store = IssueStore.init(allocator, issues_path);
    defer store.deinit();

    store.loadFromFile() catch |err| {
        if (err != error.FileNotFound) {
            try outputError(&output, global.json, "failed to load issues");
            return CloseError.StorageError;
        }
    };

    // Get issue
    const issue_ref = store.getRef(close_args.id) orelse {
        const msg = try std.fmt.allocPrint(allocator, "issue not found: {s}", .{close_args.id});
        defer allocator.free(msg);
        try outputError(&output, global.json, msg);
        return CloseError.IssueNotFound;
    };

    // Check if already closed
    if (statusEql(issue_ref.status, .closed)) {
        try outputError(&output, global.json, "issue is already closed");
        return CloseError.AlreadyClosed;
    }

    // Build update
    const now = std.time.timestamp();
    var updates = IssueStore.IssueUpdate{
        .status = .closed,
        .closed_at = now,
    };

    if (close_args.reason) |r| {
        updates.close_reason = r;
    }

    // Apply update
    store.update(close_args.id, updates, now) catch {
        try outputError(&output, global.json, "failed to close issue");
        return CloseError.StorageError;
    };

    // Save to file
    if (!global.no_auto_flush) {
        store.saveToFile() catch {
            try outputError(&output, global.json, "failed to save issues");
            return CloseError.StorageError;
        };
    }

    // Output
    if (global.json) {
        try output.printJson(CloseResult{
            .success = true,
            .id = close_args.id,
            .action = "closed",
        });
    } else if (global.quiet) {
        try output.raw(close_args.id);
        try output.raw("\n");
    } else {
        try output.success("Closed issue {s}", .{close_args.id});
    }
}

pub fn runReopen(
    reopen_args: args.ReopenArgs,
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
            return CloseError.WorkspaceNotInitialized;
        }
        try outputError(&output, global.json, "cannot access workspace");
        return CloseError.StorageError;
    };

    // Load issues
    var store = IssueStore.init(allocator, issues_path);
    defer store.deinit();

    store.loadFromFile() catch |err| {
        if (err != error.FileNotFound) {
            try outputError(&output, global.json, "failed to load issues");
            return CloseError.StorageError;
        }
    };

    // Get issue
    const issue_ref = store.getRef(reopen_args.id) orelse {
        const msg = try std.fmt.allocPrint(allocator, "issue not found: {s}", .{reopen_args.id});
        defer allocator.free(msg);
        try outputError(&output, global.json, msg);
        return CloseError.IssueNotFound;
    };

    // Check if not closed
    if (!statusEql(issue_ref.status, .closed)) {
        try outputError(&output, global.json, "issue is not closed");
        return CloseError.NotClosed;
    }

    // Build update - use epoch 0 as sentinel to clear closed_at
    const now = std.time.timestamp();
    const updates = IssueStore.IssueUpdate{
        .status = .open,
        .closed_at = 0,
    };

    // Apply update
    store.update(reopen_args.id, updates, now) catch {
        try outputError(&output, global.json, "failed to reopen issue");
        return CloseError.StorageError;
    };

    // Save to file
    if (!global.no_auto_flush) {
        store.saveToFile() catch {
            try outputError(&output, global.json, "failed to save issues");
            return CloseError.StorageError;
        };
    }

    // Output
    if (global.json) {
        try output.printJson(CloseResult{
            .success = true,
            .id = reopen_args.id,
            .action = "reopened",
        });
    } else if (global.quiet) {
        try output.raw(reopen_args.id);
        try output.raw("\n");
    } else {
        try output.success("Reopened issue {s}", .{reopen_args.id});
    }
}

fn outputError(output: *Output, json_mode: bool, message: []const u8) !void {
    if (json_mode) {
        try output.printJson(CloseResult{
            .success = false,
            .message = message,
        });
    } else {
        try output.err("{s}", .{message});
    }
}

fn statusEql(a: Status, b: Status) bool {
    const Tag = std.meta.Tag(Status);
    const tag_a: Tag = a;
    const tag_b: Tag = b;
    if (tag_a != tag_b) return false;
    return if (tag_a == .custom) std.mem.eql(u8, a.custom, b.custom) else true;
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
