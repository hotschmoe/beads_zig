//! Dependency management commands for beads_zig.
//!
//! `bz dep add <child> <parent> [--type blocks]` - Add dependency (child depends on parent)
//! `bz dep remove <child> <parent>` - Remove dependency
//! `bz dep list <id>` - List dependencies for an issue
//!
//! Manages relationships between issues.

const std = @import("std");
const models = @import("../models/mod.zig");
const storage = @import("../storage/mod.zig");
const Output = @import("../output/mod.zig").Output;
const OutputOptions = @import("../output/mod.zig").OutputOptions;
const args = @import("args.zig");
const test_util = @import("../test_util.zig");

const Dependency = models.Dependency;
const DependencyType = models.DependencyType;
const IssueStore = storage.IssueStore;
const DependencyGraph = storage.DependencyGraph;
const DependencyGraphError = storage.DependencyGraphError;

pub const DepError = error{
    WorkspaceNotInitialized,
    IssueNotFound,
    CycleDetected,
    SelfDependency,
    StorageError,
    OutOfMemory,
};

pub const DepResult = struct {
    success: bool,
    action: ?[]const u8 = null,
    child: ?[]const u8 = null,
    parent: ?[]const u8 = null,
    depends_on: ?[]const []const u8 = null,
    blocks: ?[]const []const u8 = null,
    message: ?[]const u8 = null,
};

pub fn run(
    dep_args: args.DepArgs,
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
            return DepError.WorkspaceNotInitialized;
        }
        try outputError(&output, global.json, "cannot access workspace");
        return DepError.StorageError;
    };

    // Load issues
    var store = IssueStore.init(allocator, issues_path);
    defer store.deinit();

    store.loadFromFile() catch |err| {
        if (err != error.FileNotFound) {
            try outputError(&output, global.json, "failed to load issues");
            return DepError.StorageError;
        }
    };

    var graph = DependencyGraph.init(&store, allocator);

    switch (dep_args.subcommand) {
        .add => |add| try runAdd(&graph, &store, &output, add, global, allocator),
        .remove => |remove| try runRemove(&graph, &store, &output, remove, global, allocator),
        .list => |list| try runList(&graph, &output, list, global, allocator),
        .tree => |tree| try runTree(&graph, &output, tree, global, allocator),
        .cycles => try runCycles(&graph, &output, global, allocator),
    }
}

fn runAdd(
    graph: *DependencyGraph,
    store: *IssueStore,
    output: *Output,
    add_args: anytype,
    global: args.GlobalOptions,
    allocator: std.mem.Allocator,
) !void {
    // Verify both issues exist
    if (!try store.exists(add_args.child)) {
        const msg = try std.fmt.allocPrint(allocator, "issue not found: {s}", .{add_args.child});
        defer allocator.free(msg);
        try outputError(output, global.json, msg);
        return DepError.IssueNotFound;
    }

    if (!try store.exists(add_args.parent)) {
        const msg = try std.fmt.allocPrint(allocator, "issue not found: {s}", .{add_args.parent});
        defer allocator.free(msg);
        try outputError(output, global.json, msg);
        return DepError.IssueNotFound;
    }

    // Create dependency
    const now = std.time.timestamp();
    const dep = Dependency{
        .issue_id = add_args.child,
        .depends_on_id = add_args.parent,
        .dep_type = DependencyType.fromString(add_args.dep_type),
        .created_at = now,
        .created_by = global.actor,
        .metadata = null,
        .thread_id = null,
    };

    // Add dependency
    graph.addDependency(dep) catch |err| {
        switch (err) {
            DependencyGraphError.SelfDependency => {
                try outputError(output, global.json, "cannot depend on self");
                return DepError.SelfDependency;
            },
            DependencyGraphError.CycleDetected => {
                try outputError(output, global.json, "adding dependency would create a cycle");
                return DepError.CycleDetected;
            },
            DependencyGraphError.IssueNotFound => {
                try outputError(output, global.json, "issue not found");
                return DepError.IssueNotFound;
            },
            else => {
                try outputError(output, global.json, "failed to add dependency");
                return DepError.StorageError;
            },
        }
    };

    // Save to file
    if (!global.no_auto_flush) {
        store.saveToFile() catch {
            try outputError(output, global.json, "failed to save issues");
            return DepError.StorageError;
        };
    }

    // Output
    if (global.json) {
        try output.printJson(DepResult{
            .success = true,
            .action = "added",
            .child = add_args.child,
            .parent = add_args.parent,
        });
    } else if (!global.quiet) {
        try output.success("Added dependency: {s} depends on {s}", .{ add_args.child, add_args.parent });
    }
}

fn runRemove(
    graph: *DependencyGraph,
    store: *IssueStore,
    output: *Output,
    remove_args: anytype,
    global: args.GlobalOptions,
    allocator: std.mem.Allocator,
) !void {
    _ = allocator;

    // Remove dependency
    graph.removeDependency(remove_args.child, remove_args.parent) catch |err| {
        switch (err) {
            DependencyGraphError.IssueNotFound => {
                try outputError(output, global.json, "issue not found");
                return DepError.IssueNotFound;
            },
            else => {
                try outputError(output, global.json, "failed to remove dependency");
                return DepError.StorageError;
            },
        }
    };

    // Save to file
    if (!global.no_auto_flush) {
        store.saveToFile() catch {
            try outputError(output, global.json, "failed to save issues");
            return DepError.StorageError;
        };
    }

    // Output
    if (global.json) {
        try output.printJson(DepResult{
            .success = true,
            .action = "removed",
            .child = remove_args.child,
            .parent = remove_args.parent,
        });
    } else if (!global.quiet) {
        try output.success("Removed dependency: {s} no longer depends on {s}", .{ remove_args.child, remove_args.parent });
    }
}

fn runList(
    graph: *DependencyGraph,
    output: *Output,
    list_args: anytype,
    global: args.GlobalOptions,
    allocator: std.mem.Allocator,
) !void {
    // Get dependencies (what this issue depends on)
    const deps = try graph.getDependencies(list_args.id);
    defer graph.freeDependencies(deps);

    // Get dependents (what depends on this issue)
    const dependents = try graph.getDependents(list_args.id);
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

        try output.printJson(DepResult{
            .success = true,
            .depends_on = depends_on_ids,
            .blocks = blocks_ids,
        });
    } else {
        if (deps.len > 0) {
            try output.println("Depends on:", .{});
            for (deps) |dep| {
                try output.print("  - {s} ({s})\n", .{ dep.depends_on_id, dep.dep_type.toString() });
            }
        } else {
            try output.println("Depends on: (none)", .{});
        }

        if (dependents.len > 0) {
            try output.println("Blocks:", .{});
            for (dependents) |dep| {
                try output.print("  - {s}\n", .{dep.issue_id});
            }
        } else {
            try output.println("Blocks: (none)", .{});
        }
    }
}

fn runTree(
    graph: *DependencyGraph,
    output: *Output,
    tree_args: anytype,
    global: args.GlobalOptions,
    allocator: std.mem.Allocator,
) !void {
    _ = allocator;
    _ = tree_args;
    _ = graph;

    // Tree visualization not yet implemented
    if (global.json) {
        try output.printJson(DepResult{
            .success = false,
            .message = "tree command not yet implemented",
        });
    } else {
        try output.info("tree command not yet implemented", .{});
    }
}

fn runCycles(
    graph: *DependencyGraph,
    output: *Output,
    global: args.GlobalOptions,
    allocator: std.mem.Allocator,
) !void {
    const cycles = try graph.detectCycles();

    if (cycles) |c| {
        defer graph.freeCycles(c);

        if (global.json) {
            var cycle_strs = try allocator.alloc([]const u8, c.len);
            defer allocator.free(cycle_strs);
            for (c, 0..) |cycle, i| {
                cycle_strs[i] = cycle;
            }
            try output.printJson(.{
                .success = true,
                .cycles_found = true,
                .cycles = cycle_strs,
            });
        } else {
            try output.warn("Cycles detected:", .{});
            for (c) |cycle| {
                try output.print("  {s}\n", .{cycle});
            }
        }
    } else {
        if (global.json) {
            try output.printJson(.{
                .success = true,
                .cycles_found = false,
            });
        } else {
            try output.success("No cycles detected", .{});
        }
    }
}

fn outputError(output: *Output, json_mode: bool, message: []const u8) !void {
    if (json_mode) {
        try output.printJson(DepResult{
            .success = false,
            .message = message,
        });
    } else {
        try output.err("{s}", .{message});
    }
}

// --- Tests ---

test "DepError enum exists" {
    const err: DepError = DepError.CycleDetected;
    try std.testing.expect(err == DepError.CycleDetected);
}

test "DepResult struct works" {
    const result = DepResult{
        .success = true,
        .action = "added",
        .child = "bd-child",
        .parent = "bd-parent",
    };
    try std.testing.expect(result.success);
    try std.testing.expectEqualStrings("added", result.action.?);
}

test "run detects uninitialized workspace" {
    const allocator = std.testing.allocator;

    const dep_args = args.DepArgs{
        .subcommand = .{ .list = .{ .id = "bd-test" } },
    };
    const global = args.GlobalOptions{ .quiet = true, .data_path = "/nonexistent/path" };

    const result = run(dep_args, global, allocator);
    try std.testing.expectError(DepError.WorkspaceNotInitialized, result);
}

test "runList returns empty for empty workspace" {
    const allocator = std.testing.allocator;

    const tmp_dir_path = try test_util.createTestDir(allocator, "dep_list_empty");
    defer allocator.free(tmp_dir_path);
    defer test_util.cleanupTestDir(tmp_dir_path);

    const data_path = try std.fs.path.join(allocator, &.{ tmp_dir_path, ".beads" });
    defer allocator.free(data_path);

    try std.fs.cwd().makeDir(data_path);

    const issues_path = try std.fs.path.join(allocator, &.{ data_path, "issues.jsonl" });
    defer allocator.free(issues_path);

    const f = try std.fs.cwd().createFile(issues_path, .{});
    f.close();

    const dep_args = args.DepArgs{
        .subcommand = .{ .list = .{ .id = "bd-test" } },
    };
    const global = args.GlobalOptions{ .quiet = true, .data_path = data_path };

    try run(dep_args, global, allocator);
}
