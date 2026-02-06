//! Orphans command for beads_zig.
//!
//! `bz orphans` - Find issues with missing parent references
//!
//! Detects orphaned issues in two ways:
//! 1. Hierarchical orphans: Child issues (e.g., bd-abc.1) whose parent (bd-abc) doesn't exist
//! 2. Dependency orphans: Issues referencing non-existent depends_on_id targets

const std = @import("std");
const common = @import("common.zig");
const args = @import("args.zig");

const IssueStore = common.IssueStore;
const CommandContext = common.CommandContext;

pub const OrphansError = error{
    WorkspaceNotInitialized,
    StorageError,
    OutOfMemory,
};

pub const OrphanInfo = struct {
    id: []const u8,
    orphan_type: []const u8,
    missing_ref: []const u8,
    title: []const u8,
};

pub const OrphansResult = struct {
    success: bool,
    orphans: ?[]const OrphanInfo = null,
    count: usize = 0,
    message: ?[]const u8 = null,
};

pub fn run(
    cmd_args: args.OrphansArgs,
    global: args.GlobalOptions,
    allocator: std.mem.Allocator,
) !void {
    var ctx = (try CommandContext.init(allocator, global)) orelse {
        return OrphansError.WorkspaceNotInitialized;
    };
    defer ctx.deinit();

    var orphans: std.ArrayListUnmanaged(OrphanInfo) = .{};
    defer orphans.deinit(allocator);

    // Check for hierarchical orphans (child IDs with missing parents)
    if (!cmd_args.deps_only) {
        try findHierarchicalOrphans(&ctx.issue_store, allocator, &orphans);
    }

    // Check for dependency orphans (dependencies pointing to non-existent issues)
    if (!cmd_args.hierarchy_only) {
        try findDependencyOrphans(&ctx.issue_store, &ctx.dep_store, allocator, &orphans);
    }

    // Apply limit if specified
    const display_orphans = if (cmd_args.limit) |limit|
        orphans.items[0..@min(limit, orphans.items.len)]
    else
        orphans.items;

    if (global.isStructuredOutput()) {
        try ctx.output.printJson(OrphansResult{
            .success = true,
            .orphans = display_orphans,
            .count = orphans.items.len,
        });
    } else if (!global.quiet) {
        if (orphans.items.len == 0) {
            try ctx.output.println("No orphaned issues found.", .{});
        } else {
            try ctx.output.println("Found {d} orphaned issue(s):", .{orphans.items.len});
            try ctx.output.print("\n", .{});

            for (display_orphans) |orphan| {
                try ctx.output.print("{s}  [{s}]\n", .{ orphan.id, orphan.orphan_type });
                try ctx.output.print("  Title: {s}\n", .{orphan.title});
                try ctx.output.print("  Missing: {s}\n", .{orphan.missing_ref});
                try ctx.output.print("\n", .{});
            }

            if (cmd_args.limit) |limit| {
                if (orphans.items.len > limit) {
                    try ctx.output.print("(showing {d} of {d}, use --limit to see more)\n", .{ limit, orphans.items.len });
                }
            }
        }
    }
}

/// Find issues with hierarchical IDs whose parent doesn't exist.
/// Example: bd-abc.1 exists but bd-abc doesn't.
fn findHierarchicalOrphans(
    issue_store: *IssueStore,
    allocator: std.mem.Allocator,
    orphans: *std.ArrayListUnmanaged(OrphanInfo),
) !void {
    const all_issues = try issue_store.list(.{});
    defer {
        for (all_issues) |*issue| {
            var i = issue.*;
            i.deinit(allocator);
        }
        allocator.free(all_issues);
    }

    for (all_issues) |issue| {
        if (getParentId(issue.id)) |parent_id| {
            if (!try issue_store.exists(parent_id)) {
                try orphans.append(allocator, .{
                    .id = issue.id,
                    .orphan_type = "hierarchy",
                    .missing_ref = parent_id,
                    .title = issue.title,
                });
            }
        }
    }
}

/// Find issues with dependencies pointing to non-existent issues.
fn findDependencyOrphans(
    issue_store: *IssueStore,
    dep_store: *common.DependencyStore,
    allocator: std.mem.Allocator,
    orphans: *std.ArrayListUnmanaged(OrphanInfo),
) !void {
    const all_issues = try issue_store.list(.{});
    defer {
        for (all_issues) |*issue| {
            var i = issue.*;
            i.deinit(allocator);
        }
        allocator.free(all_issues);
    }

    for (all_issues) |issue| {
        const deps = try dep_store.getDependencies(issue.id);
        defer dep_store.freeDependencies(deps);

        for (deps) |dep| {
            if (!try issue_store.exists(dep.depends_on_id)) {
                try orphans.append(allocator, .{
                    .id = issue.id,
                    .orphan_type = "dependency",
                    .missing_ref = dep.depends_on_id,
                    .title = issue.title,
                });
            }
        }
    }
}

/// Extract the parent ID from a hierarchical child ID.
/// Returns null if this is a top-level ID (no parent).
/// Example: "bd-abc.1" -> "bd-abc", "bd-abc.1.2" -> "bd-abc.1"
pub fn getParentId(id: []const u8) ?[]const u8 {
    // Find the last dot in the ID
    const last_dot = std.mem.lastIndexOf(u8, id, ".");
    if (last_dot) |dot_pos| {
        // Verify there's something before the dot
        if (dot_pos > 0) {
            return id[0..dot_pos];
        }
    }
    return null;
}

// --- Tests ---

test "getParentId extracts parent from child ID" {
    try std.testing.expectEqualStrings("bd-abc", getParentId("bd-abc.1").?);
    try std.testing.expectEqualStrings("bd-abc.1", getParentId("bd-abc.1.2").?);
    try std.testing.expectEqualStrings("bd-xyz123", getParentId("bd-xyz123.42").?);
}

test "getParentId returns null for top-level ID" {
    try std.testing.expect(getParentId("bd-abc") == null);
    try std.testing.expect(getParentId("bd-abc123") == null);
    try std.testing.expect(getParentId("proj-xyz") == null);
}

test "getParentId handles edge cases" {
    try std.testing.expect(getParentId("") == null);
    try std.testing.expect(getParentId("nodash") == null);
    try std.testing.expect(getParentId(".invalid") == null);
}

test "OrphansResult struct works" {
    const result = OrphansResult{
        .success = true,
        .count = 0,
    };
    try std.testing.expect(result.success);
    try std.testing.expectEqual(@as(usize, 0), result.count);
}

test "run detects uninitialized workspace" {
    const allocator = std.testing.allocator;
    const cmd_args = args.OrphansArgs{};
    const global = args.GlobalOptions{ .silent = true, .data_path = "/nonexistent/path" };

    const result = run(cmd_args, global, allocator);
    try std.testing.expectError(OrphansError.WorkspaceNotInitialized, result);
}
