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
const DependencyStore = common.DependencyStore;
const DependencyStoreError = storage.DependencyStoreError;

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

    switch (dep_args.subcommand) {
        .add => |add| try runAdd(&ctx, add, global, allocator),
        .remove => |remove| try runRemove(&ctx, remove, global),
        .list => |list| try runList(&ctx, list, global, allocator),
        .tree => |tree| try runTree(&ctx, tree, global, allocator),
        .cycles => try runCycles(&ctx, global, allocator),
    }
}

fn runAdd(
    ctx: *CommandContext,
    add_args: anytype,
    global: args.GlobalOptions,
    allocator: std.mem.Allocator,
) !void {
    const structured_output = global.isStructuredOutput();
    if (!try ctx.issue_store.exists(add_args.child)) {
        try common.outputNotFoundError(DepResult, &ctx.output, structured_output, add_args.child, allocator);
        return DepError.IssueNotFound;
    }

    if (!try ctx.issue_store.exists(add_args.parent)) {
        try common.outputNotFoundError(DepResult, &ctx.output, structured_output, add_args.parent, allocator);
        return DepError.IssueNotFound;
    }

    const now = std.time.timestamp();
    const dep_type = DependencyType.fromString(add_args.dep_type);

    ctx.dep_store.add(add_args.child, add_args.parent, dep_type, global.actor, now) catch |err| {
        const msg = switch (err) {
            DependencyStoreError.SelfDependency => "cannot depend on self",
            DependencyStoreError.CycleDetected => "adding dependency would create a cycle",
            else => "failed to add dependency",
        };
        try common.outputErrorTyped(DepResult, &ctx.output, structured_output, msg);

        return switch (err) {
            DependencyStoreError.SelfDependency => DepError.SelfDependency,
            DependencyStoreError.CycleDetected => DepError.CycleDetected,
            else => DepError.StorageError,
        };
    };

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
    ctx: *CommandContext,
    remove_args: anytype,
    global: args.GlobalOptions,
) !void {
    const structured_output = global.isStructuredOutput();
    ctx.dep_store.remove(remove_args.child, remove_args.parent) catch {
        try common.outputErrorTyped(DepResult, &ctx.output, structured_output, "failed to remove dependency");
        return DepError.StorageError;
    };

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
    ctx: *CommandContext,
    list_args: anytype,
    global: args.GlobalOptions,
    allocator: std.mem.Allocator,
) !void {
    const direction = list_args.direction;
    const show_down = direction == .down or direction == .both;
    const show_up = direction == .up or direction == .both;

    var deps: []Dependency = &.{};
    var dependents: []Dependency = &.{};

    if (show_down) {
        deps = try ctx.dep_store.getDependencies(list_args.id);
    }
    defer if (show_down) ctx.dep_store.freeDependencies(deps);

    if (show_up) {
        dependents = try ctx.dep_store.getDependents(list_args.id);
    }
    defer if (show_up) ctx.dep_store.freeDependencies(dependents);

    if (global.isStructuredOutput()) {
        var depends_on_ids: ?[][]const u8 = null;
        var blocks_ids: ?[][]const u8 = null;

        if (show_down and deps.len > 0) {
            depends_on_ids = try allocator.alloc([]const u8, deps.len);
            for (deps, 0..) |dep, i| {
                depends_on_ids.?[i] = dep.depends_on_id;
            }
        }

        if (show_up and dependents.len > 0) {
            blocks_ids = try allocator.alloc([]const u8, dependents.len);
            for (dependents, 0..) |dep, i| {
                blocks_ids.?[i] = dep.issue_id;
            }
        }

        defer {
            if (depends_on_ids) |ids| allocator.free(ids);
            if (blocks_ids) |ids| allocator.free(ids);
        }

        try ctx.output.printJson(DepResult{
            .success = true,
            .depends_on = depends_on_ids,
            .blocks = blocks_ids,
        });
    } else {
        if (show_down) {
            if (deps.len > 0) {
                try ctx.output.println("Depends on:", .{});
                for (deps) |dep| {
                    if (dep.metadata) |meta| {
                        try ctx.output.print("  - {s} ({s}) [{s}]\n", .{ dep.depends_on_id, dep.dep_type.toString(), meta });
                    } else {
                        try ctx.output.print("  - {s} ({s})\n", .{ dep.depends_on_id, dep.dep_type.toString() });
                    }
                }
            } else {
                try ctx.output.println("Depends on: (none)", .{});
            }
        }

        if (show_up) {
            if (dependents.len > 0) {
                try ctx.output.println("Blocks:", .{});
                for (dependents) |dep| {
                    try ctx.output.print("  - {s}\n", .{dep.issue_id});
                }
            } else {
                try ctx.output.println("Blocks: (none)", .{});
            }
        }
    }
}

/// Tree node for JSON output.
const TreeNode = struct {
    id: []const u8,
    title: []const u8,
    status: []const u8,
    children: ?[]const TreeNode = null,
};

fn runTree(
    ctx: *CommandContext,
    tree_args: anytype,
    global: args.GlobalOptions,
    allocator: std.mem.Allocator,
) !void {
    const id = tree_args.id;
    const format = tree_args.format;

    // Check if issue exists
    const issue = try ctx.issue_store.get(id);
    if (issue == null) {
        try common.outputNotFoundError(DepResult, &ctx.output, global.isStructuredOutput(), id, allocator);
        return DepError.IssueNotFound;
    }
    var i = issue.?;
    defer i.deinit(allocator);

    if (global.isStructuredOutput()) {
        // Build tree structure for JSON output
        const root = try buildTreeNode(ctx, id, allocator, 0, 5);
        defer freeTreeNode(root, allocator);

        try ctx.output.printJson(.{
            .success = true,
            .tree = root,
        });
    } else if (format == .mermaid) {
        // Mermaid flowchart output
        try printMermaidTree(ctx, id, allocator);
    } else {
        // ASCII tree output
        try ctx.output.println("{s} - {s} [{s}]", .{ id, i.title, i.status.toString() });

        // Show what this issue depends on (upstream dependencies)
        const deps = try ctx.dep_store.getDependencies(id);
        defer ctx.dep_store.freeDependencies(deps);

        if (deps.len > 0) {
            try ctx.output.println("Depends on:", .{});
            var visited: std.StringHashMapUnmanaged(void) = .{};
            defer {
                var it = visited.keyIterator();
                while (it.next()) |key| allocator.free(key.*);
                visited.deinit(allocator);
            }

            for (deps, 0..) |dep, idx| {
                const is_last = (idx == deps.len - 1);
                try printTreeBranch(ctx, dep.depends_on_id, "", is_last, &visited, allocator, 0, 5);
            }
        }

        // Show what depends on this issue (downstream dependents)
        const dependents = try ctx.dep_store.getDependents(id);
        defer ctx.dep_store.freeDependencies(dependents);

        if (dependents.len > 0) {
            try ctx.output.print("\n", .{});
            try ctx.output.println("Blocked by this:", .{});
            for (dependents, 0..) |dep, idx| {
                const is_last = (idx == dependents.len - 1);
                const prefix = if (is_last) "`-- " else "|-- ";
                const dep_issue = try ctx.issue_store.get(dep.issue_id);
                if (dep_issue) |di| {
                    var d = di;
                    defer d.deinit(allocator);
                    try ctx.output.print("{s}{s} - {s} [{s}]\n", .{ prefix, dep.issue_id, d.title, d.status.toString() });
                } else {
                    try ctx.output.print("{s}{s} (not found)\n", .{ prefix, dep.issue_id });
                }
            }
        }
    }
}

fn printTreeBranch(
    ctx: *CommandContext,
    id: []const u8,
    prefix: []const u8,
    is_last: bool,
    visited: *std.StringHashMapUnmanaged(void),
    allocator: std.mem.Allocator,
    depth: usize,
    max_depth: usize,
) !void {
    // Check for cycles
    if (visited.contains(id)) {
        const branch = if (is_last) "`-- " else "|-- ";
        try ctx.output.print("{s}{s}{s} (cycle)\n", .{ prefix, branch, id });
        return;
    }

    // Depth limit
    if (depth >= max_depth) {
        const branch = if (is_last) "`-- " else "|-- ";
        try ctx.output.print("{s}{s}{s} (...)\n", .{ prefix, branch, id });
        return;
    }

    // Mark as visited
    const id_copy = try allocator.dupe(u8, id);
    errdefer allocator.free(id_copy);
    try visited.put(allocator, id_copy, {});

    // Get issue details
    const issue = try ctx.issue_store.get(id);
    const branch = if (is_last) "`-- " else "|-- ";

    if (issue) |i| {
        var iss = i;
        defer iss.deinit(allocator);
        try ctx.output.print("{s}{s}{s} - {s} [{s}]\n", .{ prefix, branch, id, iss.title, iss.status.toString() });
    } else {
        try ctx.output.print("{s}{s}{s} (not found)\n", .{ prefix, branch, id });
        return;
    }

    // Get dependencies of this issue
    const deps = try ctx.dep_store.getDependencies(id);
    defer ctx.dep_store.freeDependencies(deps);

    // Build new prefix for children
    var new_prefix_buf: [256]u8 = undefined;
    const extension = if (is_last) "    " else "|   ";
    const new_prefix = std.fmt.bufPrint(&new_prefix_buf, "{s}{s}", .{ prefix, extension }) catch prefix;

    for (deps, 0..) |dep, idx| {
        const child_is_last = (idx == deps.len - 1);
        try printTreeBranch(ctx, dep.depends_on_id, new_prefix, child_is_last, visited, allocator, depth + 1, max_depth);
    }
}

fn printMermaidTree(
    ctx: *CommandContext,
    root_id: []const u8,
    allocator: std.mem.Allocator,
) !void {
    // Start Mermaid flowchart
    try ctx.output.println("```mermaid", .{});
    try ctx.output.println("flowchart TD", .{});

    // Track visited nodes to avoid duplicates
    var visited: std.StringHashMapUnmanaged(void) = .{};
    defer {
        var it = visited.keyIterator();
        while (it.next()) |key| allocator.free(key.*);
        visited.deinit(allocator);
    }

    // Track emitted edges to avoid duplicates
    var emitted_edges: std.StringHashMapUnmanaged(void) = .{};
    defer {
        var edge_it = emitted_edges.keyIterator();
        while (edge_it.next()) |key| allocator.free(key.*);
        emitted_edges.deinit(allocator);
    }

    // Collect all nodes and edges starting from root
    try collectMermaidNodes(ctx, root_id, &visited, &emitted_edges, allocator, 0, 5);

    try ctx.output.println("```", .{});
}

fn collectMermaidNodes(
    ctx: *CommandContext,
    id: []const u8,
    visited: *std.StringHashMapUnmanaged(void),
    emitted_edges: *std.StringHashMapUnmanaged(void),
    allocator: std.mem.Allocator,
    depth: usize,
    max_depth: usize,
) !void {
    // Skip if already visited
    if (visited.contains(id)) return;

    // Mark as visited
    const id_copy = try allocator.dupe(u8, id);
    errdefer allocator.free(id_copy);
    try visited.put(allocator, id_copy, {});

    // Get issue details for node label
    const issue = try ctx.issue_store.get(id);
    const safe_id = try sanitizeMermaidId(id, allocator);
    defer allocator.free(safe_id);

    if (issue) |i| {
        var iss = i;
        defer iss.deinit(allocator);
        const safe_title = try sanitizeMermaidLabel(iss.title, allocator);
        defer allocator.free(safe_title);
        try ctx.output.print("    {s}[\"{s}: {s}\"]\n", .{ safe_id, id, safe_title });
    } else {
        try ctx.output.print("    {s}[\"{s}: (not found)\"]\n", .{ safe_id, id });
    }

    if (depth >= max_depth) return;

    // Get dependencies (what this issue depends on)
    const deps = try ctx.dep_store.getDependencies(id);
    defer ctx.dep_store.freeDependencies(deps);

    for (deps) |dep| {
        const target_id = try sanitizeMermaidId(dep.depends_on_id, allocator);
        defer allocator.free(target_id);

        // Create edge key for deduplication
        var edge_buf: [256]u8 = undefined;
        const edge_key = std.fmt.bufPrint(&edge_buf, "{s}->{s}", .{ safe_id, target_id }) catch continue;

        if (!emitted_edges.contains(edge_key)) {
            const edge_copy = try allocator.dupe(u8, edge_key);
            try emitted_edges.put(allocator, edge_copy, {});

            // Emit edge with dependency type as label
            const dep_type_str = dep.dep_type.toString();
            try ctx.output.print("    {s} -->|{s}| {s}\n", .{ safe_id, dep_type_str, target_id });
        }

        // Recurse into dependency
        try collectMermaidNodes(ctx, dep.depends_on_id, visited, emitted_edges, allocator, depth + 1, max_depth);
    }

    // Get dependents (what depends on this issue)
    const dependents = try ctx.dep_store.getDependents(id);
    defer ctx.dep_store.freeDependencies(dependents);

    for (dependents) |dep| {
        const source_id = try sanitizeMermaidId(dep.issue_id, allocator);
        defer allocator.free(source_id);

        // Create edge key for deduplication
        var edge_buf: [256]u8 = undefined;
        const edge_key = std.fmt.bufPrint(&edge_buf, "{s}->{s}", .{ source_id, safe_id }) catch continue;

        if (!emitted_edges.contains(edge_key)) {
            const edge_copy = try allocator.dupe(u8, edge_key);
            try emitted_edges.put(allocator, edge_copy, {});

            const dep_type_str = dep.dep_type.toString();
            try ctx.output.print("    {s} -->|{s}| {s}\n", .{ source_id, dep_type_str, safe_id });
        }

        // Recurse into dependent
        try collectMermaidNodes(ctx, dep.issue_id, visited, emitted_edges, allocator, depth + 1, max_depth);
    }
}

fn sanitizeMermaidId(id: []const u8, allocator: std.mem.Allocator) ![]u8 {
    // Replace characters that are invalid in Mermaid node IDs
    var result = try allocator.alloc(u8, id.len);
    for (id, 0..) |c, i| {
        result[i] = if (c == '-' or c == '.') '_' else c;
    }
    return result;
}

fn sanitizeMermaidLabel(label: []const u8, allocator: std.mem.Allocator) ![]u8 {
    // Escape special characters in Mermaid labels
    var count: usize = 0;
    for (label) |c| {
        count += if (c == '"' or c == '\\') @as(usize, 2) else @as(usize, 1);
    }

    var result = try allocator.alloc(u8, count);
    var i: usize = 0;
    for (label) |c| {
        if (c == '"') {
            result[i] = '\\';
            result[i + 1] = '"';
            i += 2;
        } else if (c == '\\') {
            result[i] = '\\';
            result[i + 1] = '\\';
            i += 2;
        } else {
            result[i] = c;
            i += 1;
        }
    }
    return result;
}

fn buildTreeNode(
    ctx: *CommandContext,
    id: []const u8,
    allocator: std.mem.Allocator,
    depth: usize,
    max_depth: usize,
) !TreeNode {
    const issue = try ctx.issue_store.get(id);
    var title: []const u8 = "(not found)";
    var status: []const u8 = "unknown";

    if (issue) |i| {
        var iss = i;
        defer iss.deinit(allocator);
        title = try allocator.dupe(u8, iss.title);
        status = iss.status.toString();
    }

    if (depth >= max_depth) {
        return TreeNode{
            .id = try allocator.dupe(u8, id),
            .title = title,
            .status = try allocator.dupe(u8, status),
            .children = null,
        };
    }

    const deps = try ctx.dep_store.getDependencies(id);
    defer ctx.dep_store.freeDependencies(deps);

    var children: ?[]TreeNode = null;
    if (deps.len > 0) {
        var child_nodes = try allocator.alloc(TreeNode, deps.len);
        for (deps, 0..) |dep, idx| {
            child_nodes[idx] = try buildTreeNode(ctx, dep.depends_on_id, allocator, depth + 1, max_depth);
        }
        children = child_nodes;
    }

    return TreeNode{
        .id = try allocator.dupe(u8, id),
        .title = title,
        .status = try allocator.dupe(u8, status),
        .children = children,
    };
}

fn freeTreeNode(node: TreeNode, allocator: std.mem.Allocator) void {
    allocator.free(node.id);
    allocator.free(node.title);
    allocator.free(node.status);
    if (node.children) |children| {
        for (children) |child| {
            freeTreeNode(child, allocator);
        }
        allocator.free(children);
    }
}

fn runCycles(
    ctx: *CommandContext,
    global: args.GlobalOptions,
    allocator: std.mem.Allocator,
) !void {
    const cycles = try ctx.dep_store.detectAllCycles();
    defer ctx.dep_store.freeCycles(cycles);

    const structured_output = global.isStructuredOutput();

    if (cycles.len > 0) {
        if (structured_output) {
            var cycle_strs = try allocator.alloc([]const u8, cycles.len);
            defer allocator.free(cycle_strs);
            for (cycles, 0..) |cycle, i| {
                cycle_strs[i] = cycle;
            }
            try ctx.output.printJson(.{
                .success = true,
                .cycles_found = true,
                .cycles = cycle_strs,
            });
        } else {
            try ctx.output.warn("Cycles detected:", .{});
            for (cycles) |cycle| {
                try ctx.output.print("  {s}\n", .{cycle});
            }
        }
    } else {
        if (structured_output) {
            try ctx.output.printJson(.{
                .success = true,
                .cycles_found = false,
            });
        } else {
            try ctx.output.success("No cycles detected", .{});
        }
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

    const db_path = try std.fs.path.join(allocator, &.{ data_path, "beads.db" });
    defer allocator.free(db_path);

    var db = try storage.SqlDatabase.open(allocator, db_path);
    defer db.close();
    try storage.createSchema(&db);

    const dep_args = args.DepArgs{
        .subcommand = .{ .list = .{ .id = "bd-test" } },
    };
    const global = args.GlobalOptions{ .silent = true, .data_path = data_path };

    try run(dep_args, global, allocator);
}
