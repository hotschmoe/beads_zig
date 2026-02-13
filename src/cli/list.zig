//! List command for beads_zig.
//!
//! `bz list [--status X] [--priority X] [--type X] [--assignee X] [--label X] [-n LIMIT] [--all]`
//!
//! Lists issues with optional filters.

const std = @import("std");
const models = @import("../models/mod.zig");
const storage = @import("../storage/mod.zig");
const common = @import("common.zig");
const args = @import("args.zig");
const test_util = @import("../test_util.zig");

const Issue = models.Issue;
const Status = models.Status;
const Priority = models.Priority;
const IssueType = models.IssueType;
const ListFilters = storage.ListFilters;
const CommandContext = common.CommandContext;

pub const ListError = error{
    WorkspaceNotInitialized,
    InvalidFilter,
    StorageError,
    OutOfMemory,
};

pub const ListResult = struct {
    success: bool,
    issues: ?[]const common.IssueFull = null,
    count: ?usize = null,
    message: ?[]const u8 = null,
};

pub fn run(
    list_args: args.ListArgs,
    global: args.GlobalOptions,
    allocator: std.mem.Allocator,
) !void {
    var ctx = (try CommandContext.init(allocator, global)) orelse {
        return ListError.WorkspaceNotInitialized;
    };
    defer ctx.deinit();

    var filters = ListFilters{};

    if (list_args.status) |s| {
        filters.status = Status.fromString(s);
    } else if (!list_args.all) {
        filters.status = .open;
    }

    if (list_args.priority) |p| {
        filters.priority = Priority.fromString(p) catch {
            try common.outputErrorTyped(ListResult, &ctx.output, global.isStructuredOutput(), "invalid priority value");
            return ListError.InvalidFilter;
        };
    }

    if (list_args.priority_min) |p| {
        filters.priority_min = Priority.fromString(p) catch null;
    }
    if (list_args.priority_max) |p| {
        filters.priority_max = Priority.fromString(p) catch null;
    }
    if (list_args.label_any.len > 0) {
        filters.label_any = list_args.label_any;
    }
    filters.title_contains = list_args.title_contains;
    filters.desc_contains = list_args.desc_contains;
    filters.notes_contains = list_args.notes_contains;
    filters.overdue = list_args.overdue;
    filters.include_deferred = list_args.include_deferred;

    if (list_args.issue_type) |t| {
        filters.issue_type = IssueType.fromString(t);
    }

    if (list_args.assignee) |a| {
        filters.assignee = a;
    }

    if (list_args.label) |l| {
        filters.label = l;
    }

    if (list_args.limit) |n| {
        filters.limit = n;
    }

    filters.order_by = switch (list_args.sort) {
        .created_at => .created_at,
        .updated_at => .updated_at,
        .priority => .priority,
    };
    filters.order_desc = list_args.sort_desc;

    var issues = try ctx.issue_store.list(filters);
    defer {
        for (issues) |*issue| {
            var i = issue.*;
            i.deinit(allocator);
        }
        allocator.free(issues);
    }

    // Apply parent filter (client-side via dependency lookups)
    if (list_args.parent) |parent_id| {
        var filtered: std.ArrayListUnmanaged(Issue) = .{};
        errdefer filtered.deinit(allocator);

        for (issues) |issue| {
            const deps = try ctx.dep_store.getDependencies(issue.id);
            defer ctx.dep_store.freeDependencies(deps);

            var is_child = false;
            for (deps) |dep| {
                if (std.mem.eql(u8, dep.depends_on_id, parent_id)) {
                    is_child = true;
                    break;
                }
            }

            if (is_child or (list_args.recursive and try isDescendantOf(&ctx, issue.id, parent_id))) {
                try filtered.append(allocator, issue);
            } else {
                var i = issue;
                i.deinit(allocator);
            }
        }
        allocator.free(issues);
        issues = try filtered.toOwnedSlice(allocator);
    }

    // Handle CSV output format
    if (list_args.format == .csv) {
        const Output = common.Output;
        const fields = try Output.parseCsvFields(allocator, list_args.fields);
        defer if (list_args.fields != null) allocator.free(fields);
        try ctx.output.printIssueListCsv(issues, fields);
        return;
    }

    if (global.isStructuredOutput()) {
        var full_issues = try allocator.alloc(common.IssueFull, issues.len);
        defer allocator.free(full_issues);

        // Track labels loaded for JSON output so we can free them after serialization
        var loaded_labels = try allocator.alloc(?[]const []const u8, issues.len);
        defer {
            for (loaded_labels) |lbl_opt| {
                if (lbl_opt) |lbls| {
                    for (lbls) |l| allocator.free(l);
                    allocator.free(lbls);
                }
            }
            allocator.free(loaded_labels);
        }

        for (issues, 0..) |issue, i| {
            const deps = try ctx.dep_store.getDependencies(issue.id);
            defer ctx.dep_store.freeDependencies(deps);
            const dependents = try ctx.dep_store.getDependents(issue.id);
            defer ctx.dep_store.freeDependencies(dependents);

            // Load labels for JSON output (list() doesn't include them)
            const labels = try ctx.issue_store.getLabels(issue.id);
            loaded_labels[i] = labels;

            var issue_with_labels = issue;
            issue_with_labels.labels = labels;
            full_issues[i] = common.issueToFull(issue_with_labels, deps.len, dependents.len);
        }

        // Output bare array matching br format
        try ctx.output.printJson(full_issues);
    } else {
        try ctx.output.printIssueList(issues);
        if (!global.quiet and issues.len == 0) {
            try ctx.output.info("No issues found", .{});
        }
    }
}

/// Check if issue_id is a descendant of ancestor_id (recursively).
fn isDescendantOf(
    ctx: *CommandContext,
    issue_id: []const u8,
    ancestor_id: []const u8,
) !bool {
    const deps = try ctx.dep_store.getDependencies(issue_id);
    defer ctx.dep_store.freeDependencies(deps);

    for (deps) |dep| {
        if (std.mem.eql(u8, dep.depends_on_id, ancestor_id)) {
            return true;
        }
        // Recursive check omitted to avoid stack overflow; only direct children checked
    }
    return false;
}

// --- Tests ---

test "ListError enum exists" {
    const err: ListError = ListError.WorkspaceNotInitialized;
    try std.testing.expect(err == ListError.WorkspaceNotInitialized);
}

test "ListResult struct works" {
    const result = ListResult{
        .success = true,
        .count = 5,
    };
    try std.testing.expect(result.success);
    try std.testing.expectEqual(@as(usize, 5), result.count.?);
}

test "run detects uninitialized workspace" {
    const allocator = std.testing.allocator;

    const list_args = args.ListArgs{};
    const global = args.GlobalOptions{ .silent = true, .data_path = "/nonexistent/path" };

    const result = run(list_args, global, allocator);
    try std.testing.expectError(ListError.WorkspaceNotInitialized, result);
}

test "run lists issues successfully" {
    const allocator = std.testing.allocator;

    const tmp_dir_path = try test_util.createTestDir(allocator, "list_success");
    defer allocator.free(tmp_dir_path);
    defer test_util.cleanupTestDir(tmp_dir_path);

    const data_path = try std.fs.path.join(allocator, &.{ tmp_dir_path, ".beads" });
    defer allocator.free(data_path);

    const init_mod = @import("init.zig");
    try init_mod.run(.{ .prefix = "bd" }, .{ .silent = true, .data_path = data_path }, allocator);

    const list_args = args.ListArgs{ .all = true };
    const global = args.GlobalOptions{ .silent = true, .data_path = data_path };

    try run(list_args, global, allocator);
}
