//! Dependency graph visualization commands for beads_zig.
//!
//! `bz graph` - Show dependency graph for all issues
//! `bz graph <id>` - Show dependency graph for a specific issue
//! `bz graph --format dot` - Export in DOT format for Graphviz
//!
//! Provides ASCII tree visualization and DOT format export for dependency graphs.

const std = @import("std");
const models = @import("../models/mod.zig");
const storage = @import("../storage/mod.zig");
const common = @import("common.zig");
const args = @import("args.zig");

const Status = models.Status;
const CommandContext = common.CommandContext;
const DependencyGraph = common.DependencyGraph;
const Output = common.Output;

const EdgeItem = struct { from: []const u8, to: []const u8 };

pub const GraphError = error{
    WorkspaceNotInitialized,
    IssueNotFound,
    OutOfMemory,
};

pub const GraphResult = struct {
    success: bool,
    format: ?[]const u8 = null,
    node_count: ?usize = null,
    edge_count: ?usize = null,
    output: ?[]const u8 = null,
    message: ?[]const u8 = null,
};

pub fn run(
    graph_args: args.GraphArgs,
    global: args.GlobalOptions,
    allocator: std.mem.Allocator,
) !void {
    var ctx = (try CommandContext.init(allocator, global)) orelse {
        return GraphError.WorkspaceNotInitialized;
    };
    defer ctx.deinit();

    var dep_graph = ctx.createGraph();

    if (graph_args.id) |id| {
        if (!try ctx.store.exists(id)) {
            try common.outputNotFoundError(GraphResult, &ctx.output, global.isStructuredOutput(), id, allocator);
            return GraphError.IssueNotFound;
        }
        try renderIssueGraph(&dep_graph, &ctx.output, id, graph_args, global, allocator);
    } else {
        try renderFullGraph(&ctx.store, &ctx.output, graph_args, global, allocator);
    }
}

fn renderIssueGraph(
    graph: *DependencyGraph,
    output: *Output,
    issue_id: []const u8,
    graph_args: args.GraphArgs,
    global: args.GlobalOptions,
    allocator: std.mem.Allocator,
) !void {
    switch (graph_args.format) {
        .ascii => try renderAsciiTree(graph, output, issue_id, graph_args.depth, global, allocator),
        .dot => try renderDotGraph(graph, output, issue_id, graph_args.depth, global, allocator),
    }
}

fn renderFullGraph(
    store: *storage.IssueStore,
    output: *Output,
    graph_args: args.GraphArgs,
    global: args.GlobalOptions,
    allocator: std.mem.Allocator,
) !void {
    switch (graph_args.format) {
        .ascii => try renderAsciiFullGraph(store, output, global, allocator),
        .dot => try renderDotFullGraph(store, output, global, allocator),
    }
}

fn renderAsciiTree(
    graph: *DependencyGraph,
    output: *Output,
    root_id: []const u8,
    max_depth: ?u32,
    global: args.GlobalOptions,
    allocator: std.mem.Allocator,
) !void {
    var buf: std.ArrayListUnmanaged(u8) = .{};
    defer buf.deinit(allocator);
    const writer = buf.writer(allocator);

    var visited: std.StringHashMapUnmanaged(void) = .{};
    defer {
        var it = visited.keyIterator();
        while (it.next()) |key| {
            allocator.free(key.*);
        }
        visited.deinit(allocator);
    }

    const issue = graph.store.getRef(root_id) orelse return;
    try writer.print("{s} [{s}] - {s}\n", .{ issue.id, issue.status.toString(), truncateTitle(issue.title, 50) });

    try renderAsciiSubtree(graph, writer, root_id, "", 1, max_depth orelse 10, &visited, allocator);

    if (global.isStructuredOutput()) {
        try output.printJson(GraphResult{
            .success = true,
            .format = "ascii",
            .output = buf.items,
        });
    } else {
        try output.raw(buf.items);
    }
}

fn renderAsciiSubtree(
    graph: *DependencyGraph,
    writer: anytype,
    issue_id: []const u8,
    prefix: []const u8,
    depth: u32,
    max_depth: u32,
    visited: *std.StringHashMapUnmanaged(void),
    allocator: std.mem.Allocator,
) !void {
    if (depth > max_depth) return;

    const id_key = try allocator.dupe(u8, issue_id);
    if (visited.contains(id_key)) {
        allocator.free(id_key);
        return;
    }
    try visited.put(allocator, id_key, {});

    const deps = try graph.getDependencies(issue_id);
    defer graph.freeDependencies(deps);

    for (deps, 0..) |dep, i| {
        const is_last_dep = (i == deps.len - 1);
        const connector = if (is_last_dep) "`-- " else "|-- ";
        const new_prefix_ext = if (is_last_dep) "    " else "|   ";

        const new_prefix = try std.mem.concat(allocator, u8, &.{ prefix, new_prefix_ext });
        defer allocator.free(new_prefix);

        if (graph.store.getRef(dep.depends_on_id)) |blocker| {
            const status_indicator = if (statusEql(blocker.status, .closed)) "[x]" else "[ ]";
            try writer.print("{s}{s}{s} {s} - {s}\n", .{
                prefix,
                connector,
                blocker.id,
                status_indicator,
                truncateTitle(blocker.title, 40),
            });

            try renderAsciiSubtree(graph, writer, dep.depends_on_id, new_prefix, depth + 1, max_depth, visited, allocator);
        } else {
            try writer.print("{s}{s}{s} [?] - (not found)\n", .{ prefix, connector, dep.depends_on_id });
        }
    }
}

fn renderAsciiFullGraph(
    store: *storage.IssueStore,
    output: *Output,
    global: args.GlobalOptions,
    allocator: std.mem.Allocator,
) !void {
    var buf: std.ArrayListUnmanaged(u8) = .{};
    defer buf.deinit(allocator);
    const writer = buf.writer(allocator);

    const issues = store.getAllRef();
    var has_deps = false;

    try writer.writeAll("Dependency Graph\n");
    try writer.writeAll("================\n\n");

    for (issues) |issue| {
        if (issue.dependencies.len > 0) {
            has_deps = true;
            const status_indicator = if (statusEql(issue.status, .closed)) "[x]" else "[ ]";
            try writer.print("{s} {s} - {s}\n", .{ issue.id, status_indicator, truncateTitle(issue.title, 50) });

            for (issue.dependencies, 0..) |dep, i| {
                const is_last = (i == issue.dependencies.len - 1);
                const connector = if (is_last) "`-- depends on: " else "|-- depends on: ";

                if (store.getRef(dep.depends_on_id)) |blocker| {
                    const blocker_status = if (statusEql(blocker.status, .closed)) "[x]" else "[ ]";
                    try writer.print("  {s}{s} {s} - {s}\n", .{ connector, blocker.id, blocker_status, truncateTitle(blocker.title, 40) });
                } else {
                    try writer.print("  {s}{s} [?] - (not found)\n", .{ connector, dep.depends_on_id });
                }
            }
            try writer.writeAll("\n");
        }
    }

    if (!has_deps) {
        try writer.writeAll("No dependencies found.\n");
    }

    if (global.isStructuredOutput()) {
        try output.printJson(GraphResult{
            .success = true,
            .format = "ascii",
            .output = buf.items,
        });
    } else {
        try output.raw(buf.items);
    }
}

fn renderDotGraph(
    graph: *DependencyGraph,
    output: *Output,
    root_id: []const u8,
    max_depth: ?u32,
    global: args.GlobalOptions,
    allocator: std.mem.Allocator,
) !void {
    var buf: std.ArrayListUnmanaged(u8) = .{};
    defer buf.deinit(allocator);
    const writer = buf.writer(allocator);

    var visited: std.StringHashMapUnmanaged(void) = .{};
    defer {
        var it = visited.keyIterator();
        while (it.next()) |key| {
            allocator.free(key.*);
        }
        visited.deinit(allocator);
    }

    var nodes: std.StringHashMapUnmanaged(void) = .{};
    defer {
        var it = nodes.keyIterator();
        while (it.next()) |key| {
            allocator.free(key.*);
        }
        nodes.deinit(allocator);
    }

    var edges: std.ArrayListUnmanaged(EdgeItem) = .{};
    defer {
        for (edges.items) |edge| {
            allocator.free(edge.from);
            allocator.free(edge.to);
        }
        edges.deinit(allocator);
    }

    try collectGraphData(graph, root_id, 0, max_depth orelse 10, &visited, &nodes, &edges, allocator);

    try writer.writeAll("digraph dependencies {\n");
    try writer.writeAll("  rankdir=TB;\n");
    try writer.writeAll("  node [shape=box, style=rounded];\n\n");

    var node_it = nodes.keyIterator();
    while (node_it.next()) |key| {
        if (graph.store.getRef(key.*)) |issue| {
            const shape = if (statusEql(issue.status, .closed)) "box, style=\"rounded,filled\", fillcolor=lightgray" else "box, style=rounded";
            try writer.print("  \"{s}\" [label=\"{s}\\n{s}\", {s}];\n", .{
                key.*,
                key.*,
                escapeDotString(truncateTitle(issue.title, 30)),
                shape,
            });
        }
    }

    try writer.writeAll("\n");

    for (edges.items) |edge| {
        try writer.print("  \"{s}\" -> \"{s}\";\n", .{ edge.from, edge.to });
    }

    try writer.writeAll("}\n");

    if (global.isStructuredOutput()) {
        try output.printJson(GraphResult{
            .success = true,
            .format = "dot",
            .node_count = nodes.count(),
            .edge_count = edges.items.len,
            .output = buf.items,
        });
    } else {
        try output.raw(buf.items);
    }
}

fn renderDotFullGraph(
    store: *storage.IssueStore,
    output: *Output,
    global: args.GlobalOptions,
    allocator: std.mem.Allocator,
) !void {
    var buf: std.ArrayListUnmanaged(u8) = .{};
    defer buf.deinit(allocator);
    const writer = buf.writer(allocator);

    const issues = store.getAllRef();

    try writer.writeAll("digraph dependencies {\n");
    try writer.writeAll("  rankdir=TB;\n");
    try writer.writeAll("  node [shape=box, style=rounded];\n\n");

    var node_count: usize = 0;
    var edge_count: usize = 0;

    for (issues) |issue| {
        if (issue.dependencies.len > 0 or hasAnyDependents(store, issue.id)) {
            const shape = if (statusEql(issue.status, .closed)) "box, style=\"rounded,filled\", fillcolor=lightgray" else "box, style=rounded";
            try writer.print("  \"{s}\" [label=\"{s}\\n{s}\", {s}];\n", .{
                issue.id,
                issue.id,
                escapeDotString(truncateTitle(issue.title, 30)),
                shape,
            });
            node_count += 1;
        }
    }

    try writer.writeAll("\n");

    for (issues) |issue| {
        for (issue.dependencies) |dep| {
            try writer.print("  \"{s}\" -> \"{s}\";\n", .{ issue.id, dep.depends_on_id });
            edge_count += 1;
        }
    }

    try writer.writeAll("}\n");

    if (global.isStructuredOutput()) {
        try output.printJson(GraphResult{
            .success = true,
            .format = "dot",
            .node_count = node_count,
            .edge_count = edge_count,
            .output = buf.items,
        });
    } else {
        try output.raw(buf.items);
    }
}

fn collectGraphData(
    graph: *DependencyGraph,
    issue_id: []const u8,
    depth: u32,
    max_depth: u32,
    visited: *std.StringHashMapUnmanaged(void),
    nodes: *std.StringHashMapUnmanaged(void),
    edges: *std.ArrayListUnmanaged(EdgeItem),
    allocator: std.mem.Allocator,
) !void {
    if (depth > max_depth) return;

    const id_key = try allocator.dupe(u8, issue_id);
    if (visited.contains(id_key)) {
        allocator.free(id_key);
        return;
    }
    try visited.put(allocator, id_key, {});

    if (!nodes.contains(issue_id)) {
        const node_key = try allocator.dupe(u8, issue_id);
        try nodes.put(allocator, node_key, {});
    }

    const deps = try graph.getDependencies(issue_id);
    defer graph.freeDependencies(deps);

    for (deps) |dep| {
        if (!nodes.contains(dep.depends_on_id)) {
            const node_key = try allocator.dupe(u8, dep.depends_on_id);
            try nodes.put(allocator, node_key, {});
        }

        // Must dupe the strings since deps will be freed after this loop
        const from_copy = try allocator.dupe(u8, issue_id);
        errdefer allocator.free(from_copy);
        const to_copy = try allocator.dupe(u8, dep.depends_on_id);
        try edges.append(allocator, .{ .from = from_copy, .to = to_copy });

        try collectGraphData(graph, dep.depends_on_id, depth + 1, max_depth, visited, nodes, edges, allocator);
    }
}

fn hasAnyDependents(store: *storage.IssueStore, issue_id: []const u8) bool {
    for (store.getAllRef()) |issue| {
        for (issue.dependencies) |dep| {
            if (std.mem.eql(u8, dep.depends_on_id, issue_id)) {
                return true;
            }
        }
    }
    return false;
}

fn truncateTitle(title: []const u8, max_len: usize) []const u8 {
    if (title.len <= max_len) return title;
    return title[0..max_len];
}

fn escapeDotString(s: []const u8) []const u8 {
    return s;
}

fn statusEql(a: Status, b: Status) bool {
    const Tag = std.meta.Tag(Status);
    const tag_a: Tag = a;
    const tag_b: Tag = b;
    if (tag_a != tag_b) return false;
    return if (tag_a == .custom) std.mem.eql(u8, a.custom, b.custom) else true;
}

// --- Tests ---

test "GraphError enum exists" {
    const err: GraphError = GraphError.IssueNotFound;
    try std.testing.expect(err == GraphError.IssueNotFound);
}

test "GraphResult struct works" {
    const result = GraphResult{
        .success = true,
        .format = "ascii",
        .node_count = 5,
        .edge_count = 4,
    };
    try std.testing.expect(result.success);
    try std.testing.expectEqualStrings("ascii", result.format.?);
}

test "run detects uninitialized workspace" {
    const allocator = std.testing.allocator;

    const graph_args = args.GraphArgs{};
    const global = args.GlobalOptions{ .silent = true, .data_path = "/nonexistent/path" };

    const result = run(graph_args, global, allocator);
    try std.testing.expectError(GraphError.WorkspaceNotInitialized, result);
}

test "truncateTitle works correctly" {
    const full = "This is a very long title that should be truncated";
    const truncated = truncateTitle(full, 20);
    try std.testing.expectEqual(@as(usize, 20), truncated.len);

    const short = "Short";
    const not_truncated = truncateTitle(short, 20);
    try std.testing.expectEqualStrings("Short", not_truncated);
}

test "GraphFormat.fromString parses correctly" {
    try std.testing.expectEqual(args.GraphFormat.ascii, args.GraphFormat.fromString("ascii").?);
    try std.testing.expectEqual(args.GraphFormat.dot, args.GraphFormat.fromString("dot").?);
    try std.testing.expectEqual(args.GraphFormat.dot, args.GraphFormat.fromString("graphviz").?);
    try std.testing.expectEqual(args.GraphFormat.ascii, args.GraphFormat.fromString("ASCII").?);
    try std.testing.expect(args.GraphFormat.fromString("invalid") == null);
}
