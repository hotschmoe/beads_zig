//! Query command for beads_zig.
//!
//! `bz query save <name> [filters...]` - Save current filter set as named query
//! `bz query run <name>` - Run a saved query
//! `bz query list` - List all saved queries
//! `bz query delete <name>` - Delete a saved query
//!
//! Saved queries are stored in `.beads/queries.jsonl`.

const std = @import("std");
const json = std.json;
const models = @import("../models/mod.zig");
const common = @import("common.zig");
const args = @import("args.zig");
const test_util = @import("../test_util.zig");

const Status = models.Status;
const Priority = models.Priority;
const IssueType = models.IssueType;
const IssueStore = common.IssueStore;
const CommandContext = common.CommandContext;

pub const QueryError = error{
    WorkspaceNotInitialized,
    QueryNotFound,
    QueryAlreadyExists,
    InvalidQueryName,
    StorageError,
    OutOfMemory,
};

pub const QueryResult = struct {
    success: bool,
    action: ?[]const u8 = null,
    name: ?[]const u8 = null,
    queries: ?[]const SavedQuery = null,
    count: ?usize = null,
    message: ?[]const u8 = null,
};

/// Compact issue representation for query results.
const IssueCompact = struct {
    id: []const u8,
    title: []const u8,
    status: []const u8,
    priority: u3,
    issue_type: []const u8,
    assignee: ?[]const u8 = null,
};

/// Query run result with list of issues.
const QueryRunResult = struct {
    success: bool,
    issues: ?[]const IssueCompact = null,
    count: ?usize = null,
    message: ?[]const u8 = null,
};

/// A saved query definition.
pub const SavedQuery = struct {
    name: []const u8,
    status: ?[]const u8 = null,
    priority: ?[]const u8 = null,
    issue_type: ?[]const u8 = null,
    assignee: ?[]const u8 = null,
    label: ?[]const u8 = null,
    limit: ?u32 = null,
    created_at: i64 = 0,
};

pub fn run(
    query_args: args.QueryArgs,
    global: args.GlobalOptions,
    allocator: std.mem.Allocator,
) !void {
    switch (query_args.subcommand) {
        .save => |save| try runSave(save, global, allocator),
        .run => |run_args| try runRun(run_args, global, allocator),
        .list => try runList(global, allocator),
        .delete => |delete| try runDelete(delete, global, allocator),
    }
}

fn runSave(
    save_args: anytype,
    global: args.GlobalOptions,
    allocator: std.mem.Allocator,
) !void {
    var ctx = (try CommandContext.init(allocator, global)) orelse {
        return QueryError.WorkspaceNotInitialized;
    };
    defer ctx.deinit();

    const beads_dir = global.data_path orelse ".beads";
    const structured_output = global.isStructuredOutput();

    // Validate query name (alphanumeric + dash/underscore)
    if (!isValidQueryName(save_args.name)) {
        try outputError(&ctx.output, structured_output, "Invalid query name. Use alphanumeric characters, dashes, and underscores only.");
        return QueryError.InvalidQueryName;
    }

    // Check if query already exists
    var loaded = try loadQueries(allocator, beads_dir);
    defer loaded.deinit();

    for (loaded.queries) |q| {
        if (std.mem.eql(u8, q.name, save_args.name)) {
            try outputError(&ctx.output, structured_output, "Query with this name already exists. Delete it first or use a different name.");
            return QueryError.QueryAlreadyExists;
        }
    }

    // Create new query
    const now = std.time.timestamp();
    const new_query = SavedQuery{
        .name = save_args.name,
        .status = save_args.status,
        .priority = save_args.priority,
        .issue_type = save_args.issue_type,
        .assignee = save_args.assignee,
        .label = save_args.label,
        .limit = save_args.limit,
        .created_at = now,
    };

    // Append to file
    try appendQuery(allocator, beads_dir, new_query);

    if (structured_output) {
        try ctx.output.printJson(QueryResult{
            .success = true,
            .action = "saved",
            .name = save_args.name,
        });
    } else if (!global.quiet) {
        try ctx.output.success("Saved query '{s}'", .{save_args.name});
    }
}

fn runRun(
    run_args: anytype,
    global: args.GlobalOptions,
    allocator: std.mem.Allocator,
) !void {
    var ctx = (try CommandContext.init(allocator, global)) orelse {
        return QueryError.WorkspaceNotInitialized;
    };
    defer ctx.deinit();

    const beads_dir = global.data_path orelse ".beads";
    const structured_output = global.isStructuredOutput();

    // Load queries and find the one we want
    var loaded = try loadQueries(allocator, beads_dir);
    defer loaded.deinit();

    var found_query: ?SavedQuery = null;
    for (loaded.queries) |q| {
        if (std.mem.eql(u8, q.name, run_args.name)) {
            found_query = q;
            break;
        }
    }

    if (found_query == null) {
        try outputError(&ctx.output, structured_output, "Query not found");
        return QueryError.QueryNotFound;
    }

    const query = found_query.?;

    // Build list filters from the saved query
    var filters = IssueStore.ListFilters{};

    if (query.status) |s| {
        filters.status = Status.fromString(s);
    } else {
        filters.status = .open; // Default to open issues
    }

    if (query.priority) |p| {
        filters.priority = Priority.fromString(p) catch null;
    }

    if (query.issue_type) |t| {
        filters.issue_type = IssueType.fromString(t);
    }

    if (query.assignee) |a| {
        filters.assignee = a;
    }

    if (query.label) |l| {
        filters.label = l;
    }

    if (query.limit) |n| {
        filters.limit = n;
    }

    // Run the query
    const issues = try ctx.store.list(filters);
    defer {
        for (issues) |*issue| {
            var i = issue.*;
            i.deinit(allocator);
        }
        allocator.free(issues);
    }

    if (structured_output) {
        var compact_issues = try allocator.alloc(IssueCompact, issues.len);
        defer allocator.free(compact_issues);

        for (issues, 0..) |issue, i| {
            compact_issues[i] = .{
                .id = issue.id,
                .title = issue.title,
                .status = issue.status.toString(),
                .priority = issue.priority.value,
                .issue_type = issue.issue_type.toString(),
                .assignee = issue.assignee,
            };
        }

        try ctx.output.printJson(QueryRunResult{
            .success = true,
            .issues = compact_issues,
            .count = issues.len,
        });
    } else {
        if (!global.quiet) {
            try ctx.output.info("Running query '{s}':", .{run_args.name});
        }
        try ctx.output.printIssueList(issues);
        if (!global.quiet and issues.len == 0) {
            try ctx.output.info("No issues found", .{});
        }
    }
}

fn runList(
    global: args.GlobalOptions,
    allocator: std.mem.Allocator,
) !void {
    var ctx = (try CommandContext.init(allocator, global)) orelse {
        return QueryError.WorkspaceNotInitialized;
    };
    defer ctx.deinit();

    const beads_dir = global.data_path orelse ".beads";

    var loaded = try loadQueries(allocator, beads_dir);
    defer loaded.deinit();

    if (global.isStructuredOutput()) {
        try ctx.output.printJson(QueryResult{
            .success = true,
            .queries = loaded.queries,
            .count = loaded.queries.len,
        });
    } else if (!global.quiet) {
        if (loaded.queries.len == 0) {
            try ctx.output.info("No saved queries", .{});
        } else {
            try ctx.output.println("Saved queries:", .{});
            for (loaded.queries) |q| {
                try ctx.output.print("  {s}", .{q.name});
                var has_filter = false;
                if (q.status) |s| {
                    try ctx.output.print(" --status {s}", .{s});
                    has_filter = true;
                }
                if (q.priority) |p| {
                    try ctx.output.print(" --priority {s}", .{p});
                    has_filter = true;
                }
                if (q.issue_type) |t| {
                    try ctx.output.print(" --type {s}", .{t});
                    has_filter = true;
                }
                if (q.assignee) |a| {
                    try ctx.output.print(" --assignee {s}", .{a});
                    has_filter = true;
                }
                if (q.label) |l| {
                    try ctx.output.print(" --label {s}", .{l});
                    has_filter = true;
                }
                if (q.limit) |n| {
                    try ctx.output.print(" --limit {d}", .{n});
                    has_filter = true;
                }
                if (!has_filter) {
                    try ctx.output.print(" (no filters)", .{});
                }
                try ctx.output.print("\n", .{});
            }
        }
    }
}

fn runDelete(
    delete_args: anytype,
    global: args.GlobalOptions,
    allocator: std.mem.Allocator,
) !void {
    var ctx = (try CommandContext.init(allocator, global)) orelse {
        return QueryError.WorkspaceNotInitialized;
    };
    defer ctx.deinit();

    const beads_dir = global.data_path orelse ".beads";
    const structured_output = global.isStructuredOutput();

    var loaded = try loadQueries(allocator, beads_dir);
    defer loaded.deinit();

    // Find and remove the query
    var found = false;
    var new_queries: std.ArrayListUnmanaged(SavedQuery) = .{};
    defer new_queries.deinit(allocator);

    for (loaded.queries) |q| {
        if (std.mem.eql(u8, q.name, delete_args.name)) {
            found = true;
        } else {
            try new_queries.append(allocator, q);
        }
    }

    if (!found) {
        try outputError(&ctx.output, structured_output, "Query not found");
        return QueryError.QueryNotFound;
    }

    // Rewrite the file
    try saveAllQueries(allocator, beads_dir, new_queries.items);

    if (structured_output) {
        try ctx.output.printJson(QueryResult{
            .success = true,
            .action = "deleted",
            .name = delete_args.name,
        });
    } else if (!global.quiet) {
        try ctx.output.success("Deleted query '{s}'", .{delete_args.name});
    }
}

// --- Helpers ---

fn isValidQueryName(name: []const u8) bool {
    if (name.len == 0 or name.len > 64) return false;
    for (name) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_') {
            return false;
        }
    }
    return true;
}

/// Result of loading queries - stores both arena and query data
const LoadedQueries = struct {
    queries: []SavedQuery,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *LoadedQueries) void {
        self.arena.deinit();
    }
};

fn loadQueries(allocator: std.mem.Allocator, beads_dir: []const u8) !LoadedQueries {
    const queries_path = try std.fs.path.join(allocator, &.{ beads_dir, "queries.jsonl" });
    defer allocator.free(queries_path);

    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();

    const arena_alloc = arena.allocator();

    const file = std.fs.cwd().openFile(queries_path, .{}) catch |err| {
        if (err == error.FileNotFound) {
            return LoadedQueries{
                .queries = try arena_alloc.alloc(SavedQuery, 0),
                .arena = arena,
            };
        }
        return err;
    };
    defer file.close();

    const content = try file.readToEndAlloc(arena_alloc, 10 * 1024 * 1024);

    var queries: std.ArrayListUnmanaged(SavedQuery) = .{};

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;

        const parsed = json.parseFromSlice(SavedQuery, arena_alloc, trimmed, .{
            .allocate = .alloc_always,
        }) catch continue;

        try queries.append(arena_alloc, parsed.value);
    }

    return LoadedQueries{
        .queries = try queries.toOwnedSlice(arena_alloc),
        .arena = arena,
    };
}

fn appendQuery(allocator: std.mem.Allocator, beads_dir: []const u8, query_data: SavedQuery) !void {
    const queries_path = try std.fs.path.join(allocator, &.{ beads_dir, "queries.jsonl" });
    defer allocator.free(queries_path);

    const file = try std.fs.cwd().createFile(queries_path, .{ .truncate = false });
    defer file.close();

    try file.seekFromEnd(0);

    // Serialize to JSON
    const json_bytes = std.json.Stringify.valueAlloc(allocator, query_data, .{}) catch return error.StorageError;
    defer allocator.free(json_bytes);

    // Write to file
    try file.writeAll(json_bytes);
    try file.writeAll("\n");
}

fn saveAllQueries(allocator: std.mem.Allocator, beads_dir: []const u8, queries: []const SavedQuery) !void {
    const queries_path = try std.fs.path.join(allocator, &.{ beads_dir, "queries.jsonl" });
    defer allocator.free(queries_path);

    const tmp_path = try std.fs.path.join(allocator, &.{ beads_dir, "queries.jsonl.tmp" });
    defer allocator.free(tmp_path);

    const file = try std.fs.cwd().createFile(tmp_path, .{});
    errdefer std.fs.cwd().deleteFile(tmp_path) catch {};

    for (queries) |q| {
        const json_bytes = std.json.Stringify.valueAlloc(allocator, q, .{}) catch {
            file.close();
            return error.StorageError;
        };
        defer allocator.free(json_bytes);
        file.writeAll(json_bytes) catch {
            file.close();
            return error.StorageError;
        };
        file.writeAll("\n") catch {
            file.close();
            return error.StorageError;
        };
    }

    try file.sync();
    file.close();

    try std.fs.cwd().rename(tmp_path, queries_path);
}

fn outputError(output: *common.Output, structured_mode: bool, message: []const u8) !void {
    if (structured_mode) {
        try output.printJson(QueryResult{
            .success = false,
            .message = message,
        });
    } else {
        try output.err("{s}", .{message});
    }
}

// --- Tests ---

test "QueryError enum exists" {
    const err: QueryError = QueryError.QueryNotFound;
    try std.testing.expect(err == QueryError.QueryNotFound);
}

test "QueryResult struct works" {
    const result = QueryResult{
        .success = true,
        .action = "saved",
        .name = "my-query",
    };
    try std.testing.expect(result.success);
    try std.testing.expectEqualStrings("saved", result.action.?);
}

test "isValidQueryName accepts valid names" {
    try std.testing.expect(isValidQueryName("my-query"));
    try std.testing.expect(isValidQueryName("my_query"));
    try std.testing.expect(isValidQueryName("myQuery123"));
    try std.testing.expect(isValidQueryName("a"));
}

test "isValidQueryName rejects invalid names" {
    try std.testing.expect(!isValidQueryName(""));
    try std.testing.expect(!isValidQueryName("my query"));
    try std.testing.expect(!isValidQueryName("my.query"));
    try std.testing.expect(!isValidQueryName("my/query"));
}

test "loadQueries returns empty for missing file" {
    const allocator = std.testing.allocator;
    var loaded = try loadQueries(allocator, "/nonexistent/path");
    defer loaded.deinit();
    try std.testing.expectEqual(@as(usize, 0), loaded.queries.len);
}

test "run detects uninitialized workspace" {
    const allocator = std.testing.allocator;

    const query_args = args.QueryArgs{
        .subcommand = .{ .list = {} },
    };
    const global = args.GlobalOptions{ .silent = true, .data_path = "/nonexistent/path" };

    const result = run(query_args, global, allocator);
    try std.testing.expectError(QueryError.WorkspaceNotInitialized, result);
}
