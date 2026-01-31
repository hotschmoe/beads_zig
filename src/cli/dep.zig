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
const common = @import("common.zig");
const args = @import("args.zig");
const test_util = @import("../test_util.zig");

const Dependency = models.Dependency;
const DependencyType = models.DependencyType;
const CommandContext = common.CommandContext;
const DependencyGraph = common.DependencyGraph;
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
    var ctx = (try CommandContext.init(allocator, global)) orelse {
        return DepError.WorkspaceNotInitialized;
    };
    defer ctx.deinit();

    var graph = ctx.createGraph();

    switch (dep_args.subcommand) {
        .add => |add| try runAdd(&graph, &ctx, add, global, allocator),
        .remove => |remove| try runRemove(&graph, &ctx, remove, global),
        .list => |list| try runList(&graph, &ctx.output, list, global, allocator),
        .tree => |tree| try runTree(&ctx.output, tree, global),
        .cycles => try runCycles(&graph, &ctx.output, global, allocator),
    }
}

fn runAdd(
    graph: *DependencyGraph,
    ctx: *CommandContext,
    add_args: anytype,
    global: args.GlobalOptions,
    allocator: std.mem.Allocator,
) !void {
    const structured_output = global.isStructuredOutput();
    if (!try ctx.store.exists(add_args.child)) {
        try common.outputNotFoundError(DepResult, &ctx.output, structured_output, add_args.child, allocator);
        return DepError.IssueNotFound;
    }

    if (!try ctx.store.exists(add_args.parent)) {
        try common.outputNotFoundError(DepResult, &ctx.output, structured_output, add_args.parent, allocator);
        return DepError.IssueNotFound;
    }

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

    graph.addDependency(dep) catch |err| {
        const msg = switch (err) {
            DependencyGraphError.SelfDependency => "cannot depend on self",
            DependencyGraphError.CycleDetected => "adding dependency would create a cycle",
            DependencyGraphError.IssueNotFound => "issue not found",
            else => "failed to add dependency",
        };
        try outputError(&ctx.output, structured_output, msg);

        return switch (err) {
            DependencyGraphError.SelfDependency => DepError.SelfDependency,
            DependencyGraphError.CycleDetected => DepError.CycleDetected,
            DependencyGraphError.IssueNotFound => DepError.IssueNotFound,
            else => DepError.StorageError,
        };
    };

    try ctx.saveIfAutoFlush();

    if (structured_output) {
        try ctx.output.printJson(DepResult{
            .success = true,
            .action = "added",
            .child = add_args.child,
            .parent = add_args.parent,
        });
    } else if (!global.quiet) {
        try ctx.output.success("Added dependency: {s} depends on {s}", .{ add_args.child, add_args.parent });
    }
}

fn runRemove(
    graph: *DependencyGraph,
    ctx: *CommandContext,
    remove_args: anytype,
    global: args.GlobalOptions,
) !void {
    const structured_output = global.isStructuredOutput();
    graph.removeDependency(remove_args.child, remove_args.parent) catch |err| {
        const msg = if (err == DependencyGraphError.IssueNotFound)
            "issue not found"
        else
            "failed to remove dependency";
        try outputError(&ctx.output, structured_output, msg);

        return if (err == DependencyGraphError.IssueNotFound)
            DepError.IssueNotFound
        else
            DepError.StorageError;
    };

    try ctx.saveIfAutoFlush();

    if (structured_output) {
        try ctx.output.printJson(DepResult{
            .success = true,
            .action = "removed",
            .child = remove_args.child,
            .parent = remove_args.parent,
        });
    } else if (!global.quiet) {
        try ctx.output.success("Removed dependency: {s} no longer depends on {s}", .{ remove_args.child, remove_args.parent });
    }
}

fn runList(
    graph: *DependencyGraph,
    output: *common.Output,
    list_args: anytype,
    global: args.GlobalOptions,
    allocator: std.mem.Allocator,
) !void {
    const deps = try graph.getDependencies(list_args.id);
    defer graph.freeDependencies(deps);

    const dependents = try graph.getDependents(list_args.id);
    defer graph.freeDependencies(dependents);

    if (global.isStructuredOutput()) {
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
    output: *common.Output,
    tree_args: anytype,
    global: args.GlobalOptions,
) !void {
    _ = tree_args;

    if (global.isStructuredOutput()) {
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
    output: *common.Output,
    global: args.GlobalOptions,
    allocator: std.mem.Allocator,
) !void {
    const cycles = try graph.detectCycles();
    const structured_output = global.isStructuredOutput();

    if (cycles) |c| {
        defer graph.freeCycles(c);

        if (structured_output) {
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
        if (structured_output) {
            try output.printJson(.{
                .success = true,
                .cycles_found = false,
            });
        } else {
            try output.success("No cycles detected", .{});
        }
    }
}

fn outputError(output: *common.Output, json_mode: bool, message: []const u8) !void {
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
    const global = args.GlobalOptions{ .silent = true, .data_path = "/nonexistent/path" };

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
    const global = args.GlobalOptions{ .silent = true, .data_path = data_path };

    try run(dep_args, global, allocator);
}
