//! Lint command for beads_zig.
//!
//! `bz lint` - Check issue descriptions for required template sections
//!
//! Scans non-closed issues for missing markdown template sections
//! (matching br's template-checking behavior).

const std = @import("std");
const common = @import("common.zig");
const args = @import("args.zig");
const models = @import("../models/mod.zig");

const Issue = models.Issue;
const CommandContext = common.CommandContext;

pub const LintError = error{
    WorkspaceNotInitialized,
    StorageError,
    OutOfMemory,
};

pub const LintIssue = struct {
    id: []const u8,
    issue_type: []const u8,
    title: []const u8,
    warnings: []const []const u8,
};

pub const LintResult = struct {
    success: bool,
    issues: ?[]const LintIssue = null,
    total_issues: usize = 0,
    total_warnings: usize = 0,
    message: ?[]const u8 = null,
};

const required_sections = [_][]const u8{
    "## Steps to Reproduce",
    "## Acceptance Criteria",
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

    const all_issues = try ctx.issue_store.list(.{});
    defer {
        for (all_issues) |*issue| {
            var i = issue.*;
            i.deinit(allocator);
        }
        allocator.free(all_issues);
    }

    var lint_issues: std.ArrayListUnmanaged(LintIssue) = .{};
    defer {
        for (lint_issues.items) |li| {
            allocator.free(li.warnings);
        }
        lint_issues.deinit(allocator);
    }

    // All allocated warning message strings
    var owned_msgs: std.ArrayListUnmanaged([]const u8) = .{};
    defer {
        for (owned_msgs.items) |msg| allocator.free(msg);
        owned_msgs.deinit(allocator);
    }

    var total_warnings: usize = 0;

    for (all_issues) |issue| {
        if (issue.status.eql(.closed) or issue.status.eql(.tombstone)) continue;

        var missing: std.ArrayListUnmanaged([]const u8) = .{};
        defer missing.deinit(allocator);

        const desc = issue.description orelse "";
        const desc_lower = try toLowerAlloc(allocator, desc);
        defer allocator.free(desc_lower);

        for (required_sections) |section| {
            const section_lower = try toLowerAlloc(allocator, section);
            defer allocator.free(section_lower);

            if (std.mem.indexOf(u8, desc_lower, section_lower) == null) {
                const msg = try std.fmt.allocPrint(allocator, "Missing: {s}", .{section});
                try owned_msgs.append(allocator, msg);
                try missing.append(allocator, msg);
            }
        }

        if (missing.items.len > 0) {
            total_warnings += missing.items.len;
            const warnings_slice = try allocator.dupe([]const u8, missing.items);

            try lint_issues.append(allocator, .{
                .id = issue.id,
                .issue_type = issue.issue_type.toString(),
                .title = issue.title,
                .warnings = warnings_slice,
            });
        }
    }

    // Apply limit
    const display_issues = if (cmd_args.limit) |limit|
        lint_issues.items[0..@min(limit, lint_issues.items.len)]
    else
        lint_issues.items;

    if (global.isStructuredOutput()) {
        try ctx.output.printJson(LintResult{
            .success = total_warnings == 0,
            .issues = display_issues,
            .total_issues = lint_issues.items.len,
            .total_warnings = total_warnings,
        });
    } else if (!global.quiet) {
        try ctx.output.println("Template warnings ({d} issues, {d} warnings):", .{
            lint_issues.items.len,
            total_warnings,
        });

        if (display_issues.len > 0) {
            try ctx.output.print("\n", .{});
            for (display_issues) |lint_issue| {
                try ctx.output.print("{s} [{s}]: {s}\n", .{
                    lint_issue.id,
                    lint_issue.issue_type,
                    lint_issue.title,
                });
                for (lint_issue.warnings) |warning| {
                    try ctx.output.print("  (warning) {s}\n", .{warning});
                }
            }
        }
    }
}

fn toLowerAlloc(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    const result = try allocator.alloc(u8, s.len);
    for (s, 0..) |c, i| {
        result[i] = std.ascii.toLower(c);
    }
    return result;
}

// --- Tests ---

test "LintResult struct works" {
    const result = LintResult{
        .success = true,
        .total_issues = 0,
        .total_warnings = 0,
    };
    try std.testing.expect(result.success);
    try std.testing.expectEqual(@as(usize, 0), result.total_warnings);
}

test "LintIssue struct works" {
    const warnings = [_][]const u8{"Missing: ## Steps to Reproduce"};
    const issue = LintIssue{
        .id = "bd-abc",
        .issue_type = "bug",
        .title = "Test issue",
        .warnings = &warnings,
    };
    try std.testing.expectEqualStrings("bd-abc", issue.id);
    try std.testing.expectEqual(@as(usize, 1), issue.warnings.len);
}

test "run detects uninitialized workspace" {
    const allocator = std.testing.allocator;
    const cmd_args = args.LintArgs{};
    const global = args.GlobalOptions{ .silent = true, .data_path = "/nonexistent/path" };

    const result = run(cmd_args, global, allocator);
    try std.testing.expectError(LintError.WorkspaceNotInitialized, result);
}

test "toLowerAlloc works" {
    const allocator = std.testing.allocator;
    const result = try toLowerAlloc(allocator, "Hello WORLD");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("hello world", result);
}
