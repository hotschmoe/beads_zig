//! Show command for beads_zig.
//!
//! `bz show <id>`
//!
//! Displays detailed information about a single issue.

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
            return ShowError.WorkspaceNotInitialized;
        }
        try outputError(&output, global.json, "cannot access workspace");
        return ShowError.StorageError;
    };

    // Load issues
    var store = IssueStore.init(allocator, issues_path);
    defer store.deinit();

    store.loadFromFile() catch |err| {
        if (err != error.FileNotFound) {
            try outputError(&output, global.json, "failed to load issues");
            return ShowError.StorageError;
        }
    };

    // Get issue
    var issue = (try store.getWithRelations(show_args.id)) orelse {
        const msg = try std.fmt.allocPrint(allocator, "issue not found: {s}", .{show_args.id});
        defer allocator.free(msg);
        try outputError(&output, global.json, msg);
        return ShowError.IssueNotFound;
    };
    defer issue.deinit(allocator);

    // Get dependency info
    var graph = DependencyGraph.init(&store, allocator);

    const deps = try graph.getDependencies(show_args.id);
    defer graph.freeDependencies(deps);

    const dependents = try graph.getDependents(show_args.id);
    defer graph.freeDependencies(dependents);

    // Output
    if (global.json) {
        var depends_on_ids: ?[][]const u8 = null;
        var blocks_ids: ?[][]const u8 = null;

        if (deps.len > 0) {
            depends_on_ids = try allocator.alloc([]const u8, deps.len);
            for (deps, 0..) |dep, i| {
                depends_on_ids.?[i] = dep.depends_on_id;
            }
        }

        if (dependents.len > 0) {
            blocks_ids = try allocator.alloc([]const u8, dependents.len);
            for (dependents, 0..) |dep, i| {
                blocks_ids.?[i] = dep.issue_id;
            }
        }

        defer {
            if (depends_on_ids) |ids| allocator.free(ids);
            if (blocks_ids) |ids| allocator.free(ids);
        }

        try output.printJson(ShowResult{
            .success = true,
            .issue = issue,
            .depends_on = depends_on_ids,
            .blocks = blocks_ids,
        });
    } else {
        try output.printIssue(issue);

        // Print dependency info
        if (deps.len > 0) {
            try output.print("\nDepends on:\n", .{});
            for (deps) |dep| {
                try output.print("  - {s}\n", .{dep.depends_on_id});
            }
        }

        if (dependents.len > 0) {
            try output.print("\nBlocks:\n", .{});
            for (dependents) |dep| {
                try output.print("  - {s}\n", .{dep.issue_id});
            }
        }
    }
}

fn outputError(output: *Output, json_mode: bool, message: []const u8) !void {
    if (json_mode) {
        try output.printJson(ShowResult{
            .success = false,
            .message = message,
        });
    } else {
        try output.err("{s}", .{message});
    }
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
    const global = args.GlobalOptions{ .quiet = true, .data_path = "/nonexistent/path" };

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

    try std.fs.cwd().makeDir(data_path);

    const issues_path = try std.fs.path.join(allocator, &.{ data_path, "issues.jsonl" });
    defer allocator.free(issues_path);

    const f = try std.fs.cwd().createFile(issues_path, .{});
    f.close();

    const show_args = args.ShowArgs{ .id = "bd-nonexistent" };
    const global = args.GlobalOptions{ .quiet = true, .data_path = data_path };

    const result = run(show_args, global, allocator);
    try std.testing.expectError(ShowError.IssueNotFound, result);
}
