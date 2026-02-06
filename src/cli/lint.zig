//! Lint command for beads_zig.
//!
//! `bz lint` - Validate database consistency
//!
//! Performs comprehensive validation checks on the issue database:
//! - ID format validation
//! - Orphaned hierarchical children
//! - Orphaned dependencies
//! - Circular dependencies
//! - Empty or invalid titles
//! - Duplicate content hashes
//! - Invalid status combinations
//! - Future timestamps

const std = @import("std");
const common = @import("common.zig");
const args = @import("args.zig");
const id_mod = @import("../id/mod.zig");
const orphans = @import("orphans.zig");

const IssueStore = common.IssueStore;
const CommandContext = common.CommandContext;

pub const LintError = error{
    WorkspaceNotInitialized,
    StorageError,
    OutOfMemory,
};

pub const LintIssue = struct {
    id: ?[]const u8,
    severity: []const u8, // "error", "warning", "info"
    category: []const u8,
    message: []const u8,
};

pub const LintResult = struct {
    success: bool,
    issues: ?[]const LintIssue = null,
    errors: usize = 0,
    warnings: usize = 0,
    infos: usize = 0,
    message: ?[]const u8 = null,
};

pub fn run(
    cmd_args: args.LintArgs,
    global: args.GlobalOptions,
    allocator: std.mem.Allocator,
) !void {
    var ctx = (try CommandContext.init(allocator, global)) orelse {
        return LintError.WorkspaceNotInitialized;
    };
    defer ctx.deinit();

    var issues: std.ArrayListUnmanaged(LintIssue) = .{};
    defer issues.deinit(allocator);

    // Run all lint checks
    try lintIdFormats(&ctx, allocator, &issues);
    try lintOrphanedHierarchy(&ctx, allocator, &issues);
    try lintOrphanedDependencies(&ctx, allocator, &issues);
    try lintCircularDependencies(&ctx, allocator, &issues);
    try lintTitles(&ctx, allocator, &issues);
    try lintDuplicateHashes(&ctx, allocator, &issues);
    try lintStatusConsistency(&ctx, allocator, &issues);
    try lintTimestamps(&ctx, allocator, &issues);

    // Count by severity
    var errors: usize = 0;
    var warnings: usize = 0;
    var infos: usize = 0;

    for (issues.items) |issue| {
        if (std.mem.eql(u8, issue.severity, "error")) {
            errors += 1;
        } else if (std.mem.eql(u8, issue.severity, "warning")) {
            warnings += 1;
        } else {
            infos += 1;
        }
    }

    // Apply limit if specified
    const display_issues = if (cmd_args.limit) |limit|
        issues.items[0..@min(limit, issues.items.len)]
    else
        issues.items;

    if (global.isStructuredOutput()) {
        try ctx.output.printJson(LintResult{
            .success = errors == 0,
            .issues = display_issues,
            .errors = errors,
            .warnings = warnings,
            .infos = infos,
        });
    } else if (!global.quiet) {
        if (issues.items.len == 0) {
            try ctx.output.println("No issues found. Database is consistent.", .{});
        } else {
            try ctx.output.println("Database Lint Results", .{});
            try ctx.output.print("\n", .{});

            for (display_issues) |issue| {
                const icon = if (std.mem.eql(u8, issue.severity, "error"))
                    "[ERR]"
                else if (std.mem.eql(u8, issue.severity, "warning"))
                    "[WARN]"
                else
                    "[INFO]";

                if (issue.id) |id| {
                    try ctx.output.print("{s} {s}: {s}\n", .{ icon, id, issue.message });
                } else {
                    try ctx.output.print("{s} {s}\n", .{ icon, issue.message });
                }
            }

            try ctx.output.print("\nSummary: {d} error(s), {d} warning(s), {d} info(s)\n", .{ errors, warnings, infos });

            if (cmd_args.limit) |limit| {
                if (issues.items.len > limit) {
                    try ctx.output.print("(showing {d} of {d}, use --limit to see more)\n", .{ limit, issues.items.len });
                }
            }
        }
    }
}

fn lintIdFormats(
    ctx: *CommandContext,
    allocator: std.mem.Allocator,
    issues: *std.ArrayListUnmanaged(LintIssue),
) !void {
    const all_issues = try ctx.issue_store.list(.{});
    defer {
        for (all_issues) |*issue| {
            issue.deinit(allocator);
        }
        allocator.free(all_issues);
    }

    for (all_issues) |*issue| {
        if (!id_mod.validateId(issue.id)) {
            try issues.append(allocator, .{
                .id = issue.id,
                .severity = "error",
                .category = "id_format",
                .message = "Invalid issue ID format",
            });
        }
    }
}

fn lintOrphanedHierarchy(
    ctx: *CommandContext,
    allocator: std.mem.Allocator,
    issues: *std.ArrayListUnmanaged(LintIssue),
) !void {
    const all_issues = try ctx.issue_store.list(.{});
    defer {
        for (all_issues) |*issue| {
            issue.deinit(allocator);
        }
        allocator.free(all_issues);
    }

    for (all_issues) |*issue| {
        if (orphans.getParentId(issue.id)) |parent_id| {
            if (!try ctx.issue_store.exists(parent_id)) {
                try issues.append(allocator, .{
                    .id = issue.id,
                    .severity = "warning",
                    .category = "orphan_hierarchy",
                    .message = "Parent issue does not exist",
                });
            }
        }
    }
}

fn lintOrphanedDependencies(
    ctx: *CommandContext,
    allocator: std.mem.Allocator,
    issues: *std.ArrayListUnmanaged(LintIssue),
) !void {
    const all_issues = try ctx.issue_store.list(.{});
    defer {
        for (all_issues) |*issue| {
            issue.deinit(allocator);
        }
        allocator.free(all_issues);
    }

    for (all_issues) |*issue| {
        const deps = try ctx.dep_store.getDependencies(issue.id);
        defer ctx.dep_store.freeDependencies(deps);

        for (deps) |dep| {
            if (!try ctx.issue_store.exists(dep.depends_on_id)) {
                try issues.append(allocator, .{
                    .id = issue.id,
                    .severity = "warning",
                    .category = "orphan_dependency",
                    .message = "Dependency references non-existent issue",
                });
            }
        }
    }
}

fn lintCircularDependencies(
    ctx: *CommandContext,
    allocator: std.mem.Allocator,
    issues: *std.ArrayListUnmanaged(LintIssue),
) !void {
    const cycles = try ctx.dep_store.detectAllCycles();
    defer ctx.dep_store.freeCycles(cycles);

    if (cycles.len > 0) {
        try issues.append(allocator, .{
            .id = null,
            .severity = "error",
            .category = "circular_dependency",
            .message = "Circular dependencies detected in dependency graph",
        });
    }
}

fn lintTitles(
    ctx: *CommandContext,
    allocator: std.mem.Allocator,
    issues: *std.ArrayListUnmanaged(LintIssue),
) !void {
    const all_issues = try ctx.issue_store.list(.{});
    defer {
        for (all_issues) |*issue| {
            issue.deinit(allocator);
        }
        allocator.free(all_issues);
    }

    for (all_issues) |*issue| {
        if (issue.title.len == 0) {
            try issues.append(allocator, .{
                .id = issue.id,
                .severity = "error",
                .category = "empty_title",
                .message = "Issue has empty title",
            });
        } else if (issue.title.len > 500) {
            try issues.append(allocator, .{
                .id = issue.id,
                .severity = "warning",
                .category = "long_title",
                .message = "Title exceeds 500 character limit",
            });
        }
    }
}

fn lintDuplicateHashes(
    ctx: *CommandContext,
    allocator: std.mem.Allocator,
    issues: *std.ArrayListUnmanaged(LintIssue),
) !void {
    const all_issues = try ctx.issue_store.list(.{});
    defer {
        for (all_issues) |*issue| {
            issue.deinit(allocator);
        }
        allocator.free(all_issues);
    }

    var hash_map = std.StringHashMap([]const u8).init(allocator);
    defer hash_map.deinit();

    for (all_issues) |*issue| {
        if (issue.content_hash) |hash| {
            if (hash_map.get(hash)) |existing_id| {
                try issues.append(allocator, .{
                    .id = issue.id,
                    .severity = "info",
                    .category = "duplicate_hash",
                    .message = try std.fmt.allocPrint(allocator, "Duplicate content hash with {s}", .{existing_id}),
                });
            } else {
                try hash_map.put(hash, issue.id);
            }
        }
    }
}

fn lintStatusConsistency(
    ctx: *CommandContext,
    allocator: std.mem.Allocator,
    issues: *std.ArrayListUnmanaged(LintIssue),
) !void {
    const all_issues = try ctx.issue_store.list(.{});
    defer {
        for (all_issues) |*issue| {
            issue.deinit(allocator);
        }
        allocator.free(all_issues);
    }

    for (all_issues) |*issue| {
        // Closed issues should have closed_at timestamp
        if (issue.status.eql(.closed) and issue.closed_at.value == null) {
            try issues.append(allocator, .{
                .id = issue.id,
                .severity = "warning",
                .category = "status_consistency",
                .message = "Closed issue missing closed_at timestamp",
            });
        }

        // Deferred issues should have defer_until
        if (issue.status.eql(.deferred) and issue.defer_until.value == null) {
            try issues.append(allocator, .{
                .id = issue.id,
                .severity = "info",
                .category = "status_consistency",
                .message = "Deferred issue missing defer_until date",
            });
        }
    }
}

fn lintTimestamps(
    ctx: *CommandContext,
    allocator: std.mem.Allocator,
    issues: *std.ArrayListUnmanaged(LintIssue),
) !void {
    const all_issues = try ctx.issue_store.list(.{});
    defer {
        for (all_issues) |*issue| {
            issue.deinit(allocator);
        }
        allocator.free(all_issues);
    }

    const now = std.time.timestamp();
    const one_day_future = now + (24 * 60 * 60);

    for (all_issues) |*issue| {
        // Check for timestamps too far in the future (more than 1 day)
        if (issue.created_at.value > one_day_future) {
            try issues.append(allocator, .{
                .id = issue.id,
                .severity = "warning",
                .category = "future_timestamp",
                .message = "created_at timestamp is in the future",
            });
        }

        if (issue.updated_at.value > one_day_future) {
            try issues.append(allocator, .{
                .id = issue.id,
                .severity = "warning",
                .category = "future_timestamp",
                .message = "updated_at timestamp is in the future",
            });
        }

        // Check that updated_at >= created_at
        if (issue.updated_at.value < issue.created_at.value) {
            try issues.append(allocator, .{
                .id = issue.id,
                .severity = "warning",
                .category = "timestamp_order",
                .message = "updated_at is before created_at",
            });
        }
    }
}

// --- Tests ---

test "LintResult struct works" {
    const result = LintResult{
        .success = true,
        .errors = 0,
        .warnings = 0,
        .infos = 0,
    };
    try std.testing.expect(result.success);
    try std.testing.expectEqual(@as(usize, 0), result.errors);
}

test "LintIssue struct works" {
    const issue = LintIssue{
        .id = "bd-abc",
        .severity = "error",
        .category = "id_format",
        .message = "Invalid ID",
    };
    try std.testing.expectEqualStrings("bd-abc", issue.id.?);
    try std.testing.expectEqualStrings("error", issue.severity);
}

test "run detects uninitialized workspace" {
    const allocator = std.testing.allocator;
    const cmd_args = args.LintArgs{};
    const global = args.GlobalOptions{ .silent = true, .data_path = "/nonexistent/path" };

    const result = run(cmd_args, global, allocator);
    try std.testing.expectError(LintError.WorkspaceNotInitialized, result);
}
