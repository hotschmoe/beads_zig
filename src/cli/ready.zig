//! Ready and blocked commands for beads_zig.
//!
//! `bz ready [-n LIMIT]` - Show issues ready to work on (no blockers)
//! `bz blocked [-n LIMIT]` - Show blocked issues
//!
//! Workflow queries for finding actionable work.

const std = @import("std");
const models = @import("../models/mod.zig");
const storage = @import("../storage/mod.zig");
const Output = @import("../output/mod.zig").Output;
const OutputOptions = @import("../output/mod.zig").OutputOptions;
const args = @import("args.zig");
const test_util = @import("../test_util.zig");

const Issue = models.Issue;
const IssueStore = storage.IssueStore;
const DependencyGraph = storage.DependencyGraph;

pub const ReadyError = error{
    WorkspaceNotInitialized,
    StorageError,
    OutOfMemory,
};

pub const ReadyResult = struct {
    success: bool,
    issues: ?[]const IssueCompact = null,
    count: ?usize = null,
    message: ?[]const u8 = null,

    const IssueCompact = struct {
        id: []const u8,
        title: []const u8,
        priority: u3,
    };
};

pub const BlockedResult = struct {
    success: bool,
    issues: ?[]const BlockedIssue = null,
    count: ?usize = null,
    message: ?[]const u8 = null,

    const BlockedIssue = struct {
        id: []const u8,
        title: []const u8,
        priority: u3,
        blocked_by: []const []const u8,
    };
};

pub fn run(
    ready_args: args.ReadyArgs,
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
            return ReadyError.WorkspaceNotInitialized;
        }
        try outputError(&output, global.json, "cannot access workspace");
        return ReadyError.StorageError;
    };

    // Load issues
    var store = IssueStore.init(allocator, issues_path);
    defer store.deinit();

    store.loadFromFile() catch |err| {
        if (err != error.FileNotFound) {
            try outputError(&output, global.json, "failed to load issues");
            return ReadyError.StorageError;
        }
    };

    // Get ready issues
    var graph = DependencyGraph.init(&store, allocator);
    var issues = try graph.getReadyIssues();
    defer graph.freeIssues(issues);

    // Apply limit
    var display_issues = issues;
    if (ready_args.limit) |limit| {
        if (limit < issues.len) {
            display_issues = issues[0..limit];
        }
    }

    // Output
    if (global.json) {
        var compact_issues = try allocator.alloc(ReadyResult.IssueCompact, display_issues.len);
        defer allocator.free(compact_issues);

        for (display_issues, 0..) |issue, i| {
            compact_issues[i] = .{
                .id = issue.id,
                .title = issue.title,
                .priority = issue.priority.value,
            };
        }

        try output.printJson(ReadyResult{
            .success = true,
            .issues = compact_issues,
            .count = display_issues.len,
        });
    } else {
        try output.printIssueList(display_issues);
        if (!global.quiet and display_issues.len == 0) {
            try output.info("No ready issues", .{});
        }
    }
}

pub fn runBlocked(
    blocked_args: args.BlockedArgs,
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
            return ReadyError.WorkspaceNotInitialized;
        }
        try outputError(&output, global.json, "cannot access workspace");
        return ReadyError.StorageError;
    };

    // Load issues
    var store = IssueStore.init(allocator, issues_path);
    defer store.deinit();

    store.loadFromFile() catch |err| {
        if (err != error.FileNotFound) {
            try outputError(&output, global.json, "failed to load issues");
            return ReadyError.StorageError;
        }
    };

    // Get blocked issues
    var graph = DependencyGraph.init(&store, allocator);
    var issues = try graph.getBlockedIssues();
    defer graph.freeIssues(issues);

    // Apply limit
    var display_issues = issues;
    if (blocked_args.limit) |limit| {
        if (limit < issues.len) {
            display_issues = issues[0..limit];
        }
    }

    // Output
    if (global.json) {
        var blocked_issues = try allocator.alloc(BlockedResult.BlockedIssue, display_issues.len);
        defer {
            for (blocked_issues) |bi| {
                allocator.free(bi.blocked_by);
            }
            allocator.free(blocked_issues);
        }

        for (display_issues, 0..) |issue, i| {
            // Get blockers for this issue
            const blockers = try graph.getBlockers(issue.id);
            defer graph.freeIssues(blockers);

            var blocker_ids = try allocator.alloc([]const u8, blockers.len);
            for (blockers, 0..) |blocker, j| {
                blocker_ids[j] = blocker.id;
            }

            blocked_issues[i] = .{
                .id = issue.id,
                .title = issue.title,
                .priority = issue.priority.value,
                .blocked_by = blocker_ids,
            };
        }

        try output.printJson(BlockedResult{
            .success = true,
            .issues = blocked_issues,
            .count = display_issues.len,
        });
    } else {
        for (display_issues) |issue| {
            // Get blockers
            const blockers = try graph.getBlockers(issue.id);
            defer graph.freeIssues(blockers);

            // Print issue
            try output.print("{s}  {s}\n", .{ issue.id, issue.title });

            // Print blockers
            if (blockers.len > 0) {
                try output.print("  blocked by: ", .{});
                for (blockers, 0..) |blocker, j| {
                    if (j > 0) try output.print(", ", .{});
                    try output.print("{s}", .{blocker.id});
                }
                try output.print("\n", .{});
            }
        }

        if (!global.quiet and display_issues.len == 0) {
            try output.info("No blocked issues", .{});
        }
    }
}

fn outputError(output: *Output, json_mode: bool, message: []const u8) !void {
    if (json_mode) {
        try output.printJson(ReadyResult{
            .success = false,
            .message = message,
        });
    } else {
        try output.err("{s}", .{message});
    }
}

// --- Tests ---

test "ReadyError enum exists" {
    const err: ReadyError = ReadyError.WorkspaceNotInitialized;
    try std.testing.expect(err == ReadyError.WorkspaceNotInitialized);
}

test "ReadyResult struct works" {
    const result = ReadyResult{
        .success = true,
        .count = 3,
    };
    try std.testing.expect(result.success);
    try std.testing.expectEqual(@as(usize, 3), result.count.?);
}

test "BlockedResult struct works" {
    const result = BlockedResult{
        .success = true,
        .count = 2,
    };
    try std.testing.expect(result.success);
    try std.testing.expectEqual(@as(usize, 2), result.count.?);
}

test "run detects uninitialized workspace" {
    const allocator = std.testing.allocator;

    const ready_args = args.ReadyArgs{};
    const global = args.GlobalOptions{ .quiet = true, .data_path = "/nonexistent/path" };

    const result = run(ready_args, global, allocator);
    try std.testing.expectError(ReadyError.WorkspaceNotInitialized, result);
}

test "runBlocked detects uninitialized workspace" {
    const allocator = std.testing.allocator;

    const blocked_args = args.BlockedArgs{};
    const global = args.GlobalOptions{ .quiet = true, .data_path = "/nonexistent/path" };

    const result = runBlocked(blocked_args, global, allocator);
    try std.testing.expectError(ReadyError.WorkspaceNotInitialized, result);
}

test "run returns empty list for empty workspace" {
    const allocator = std.testing.allocator;

    const tmp_dir_path = try test_util.createTestDir(allocator, "ready_empty");
    defer allocator.free(tmp_dir_path);
    defer test_util.cleanupTestDir(tmp_dir_path);

    const data_path = try std.fs.path.join(allocator, &.{ tmp_dir_path, ".beads" });
    defer allocator.free(data_path);

    try std.fs.cwd().makeDir(data_path);

    const issues_path = try std.fs.path.join(allocator, &.{ data_path, "issues.jsonl" });
    defer allocator.free(issues_path);

    const f = try std.fs.cwd().createFile(issues_path, .{});
    f.close();

    const ready_args = args.ReadyArgs{};
    const global = args.GlobalOptions{ .quiet = true, .data_path = data_path };

    try run(ready_args, global, allocator);
}
