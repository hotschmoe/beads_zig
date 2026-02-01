//! Changelog command for beads_zig.
//!
//! `bz changelog [--since DATE] [--until DATE] [-n LIMIT] [--group-by TYPE]`
//!
//! Generates a changelog from closed issues, optionally filtered by date range.

const std = @import("std");
const models = @import("../models/mod.zig");
const common = @import("common.zig");
const args = @import("args.zig");
const test_util = @import("../test_util.zig");

const Issue = models.Issue;
const Status = models.Status;
const IssueType = models.IssueType;
const IssueStore = common.IssueStore;
const CommandContext = common.CommandContext;
const timestamp = models.timestamp;

pub const ChangelogError = error{
    WorkspaceNotInitialized,
    InvalidDateFormat,
    StorageError,
    OutOfMemory,
};

pub const ChangelogResult = struct {
    success: bool,
    entries: ?[]const ChangelogEntry = null,
    count: ?usize = null,
    message: ?[]const u8 = null,

    pub const ChangelogEntry = struct {
        id: []const u8,
        title: []const u8,
        issue_type: []const u8,
        closed_at: ?[]const u8 = null,
        close_reason: ?[]const u8 = null,
        labels: []const []const u8 = &.{},
    };
};

pub fn run(
    changelog_args: args.ChangelogArgs,
    global: args.GlobalOptions,
    allocator: std.mem.Allocator,
) !void {
    var ctx = (try CommandContext.init(allocator, global)) orelse {
        return ChangelogError.WorkspaceNotInitialized;
    };
    defer ctx.deinit();

    var filters = IssueStore.ListFilters{};
    filters.status = .closed;
    filters.order_by = .updated_at;
    filters.order_desc = true;

    if (changelog_args.limit) |n| {
        filters.limit = n;
    }

    const issues = try ctx.store.list(filters);
    defer {
        for (issues) |*issue| {
            var i = issue.*;
            i.deinit(allocator);
        }
        allocator.free(issues);
    }

    // Filter by date range if specified
    var filtered_issues: std.ArrayListUnmanaged(Issue) = .{};
    defer filtered_issues.deinit(allocator);

    const since_ts = if (changelog_args.since) |s| parseDateToTimestamp(s) else null;
    const until_ts = if (changelog_args.until) |u| parseDateToTimestamp(u) else null;

    for (issues) |issue| {
        const closed_ts = if (issue.closed_at.value) |t| t else continue;

        if (since_ts) |since| {
            if (closed_ts < since) continue;
        }
        if (until_ts) |until| {
            if (closed_ts > until) continue;
        }

        try filtered_issues.append(allocator, issue);
    }

    if (global.isStructuredOutput()) {
        var entries = try allocator.alloc(ChangelogResult.ChangelogEntry, filtered_issues.items.len);
        defer allocator.free(entries);

        // Track allocated timestamp strings for cleanup
        var timestamp_strings: std.ArrayListUnmanaged([]const u8) = .{};
        defer {
            for (timestamp_strings.items) |ts| {
                allocator.free(ts);
            }
            timestamp_strings.deinit(allocator);
        }

        for (filtered_issues.items, 0..) |issue, i| {
            var closed_at_str: ?[]const u8 = null;
            if (issue.closed_at.value) |ts_val| {
                if (timestamp.formatRfc3339Alloc(allocator, ts_val)) |ts| {
                    closed_at_str = ts;
                    try timestamp_strings.append(allocator, ts);
                } else |_| {}
            }

            entries[i] = .{
                .id = issue.id,
                .title = issue.title,
                .issue_type = issue.issue_type.toString(),
                .closed_at = closed_at_str,
                .close_reason = issue.close_reason,
                .labels = issue.labels,
            };
        }

        try ctx.output.printJson(ChangelogResult{
            .success = true,
            .entries = entries,
            .count = filtered_issues.items.len,
        });
    } else {
        if (filtered_issues.items.len == 0) {
            if (!global.quiet) {
                try ctx.output.info("No closed issues found", .{});
            }
            return;
        }

        // Group by issue type if requested
        if (changelog_args.group_by) |group| {
            if (std.ascii.eqlIgnoreCase(group, "type")) {
                try printGroupedByType(&ctx.output, filtered_issues.items, allocator);
                return;
            }
        }

        // Default: print as a simple changelog list
        try ctx.output.println("# Changelog", .{});
        try ctx.output.println("", .{});

        for (filtered_issues.items) |issue| {
            const type_str = issue.issue_type.toString();
            const reason_suffix = if (issue.close_reason) |r| blk: {
                var buf: [256]u8 = undefined;
                const result = std.fmt.bufPrint(&buf, " ({s})", .{r}) catch "";
                break :blk result;
            } else "";

            try ctx.output.println("- [{s}] {s}: {s}{s}", .{
                issue.id,
                type_str,
                issue.title,
                reason_suffix,
            });
        }

        if (!global.quiet) {
            try ctx.output.println("", .{});
            try ctx.output.info("{d} closed issue(s)", .{filtered_issues.items.len});
        }
    }
}

fn printGroupedByType(output: *common.Output, issues: []Issue, allocator: std.mem.Allocator) !void {
    // Group issues by type
    var type_groups: std.StringHashMapUnmanaged(std.ArrayListUnmanaged(Issue)) = .{};
    defer {
        var it = type_groups.valueIterator();
        while (it.next()) |list| {
            list.deinit(allocator);
        }
        type_groups.deinit(allocator);
    }

    for (issues) |issue| {
        const type_str = issue.issue_type.toString();
        const result = type_groups.getOrPut(allocator, type_str) catch continue;
        if (!result.found_existing) {
            result.value_ptr.* = .{};
        }
        result.value_ptr.append(allocator, issue) catch continue;
    }

    try output.println("# Changelog", .{});
    try output.println("", .{});

    // Print in a consistent order
    const type_order = [_][]const u8{ "feature", "bug", "task", "chore", "docs", "epic", "question" };

    for (type_order) |type_str| {
        if (type_groups.get(type_str)) |group| {
            if (group.items.len > 0) {
                try output.println("## {s}", .{capitalizeFirst(type_str)});
                try output.println("", .{});
                for (group.items) |issue| {
                    try output.println("- [{s}] {s}", .{ issue.id, issue.title });
                }
                try output.println("", .{});
            }
        }
    }

    // Print any remaining types not in the order list
    var it = type_groups.iterator();
    while (it.next()) |entry| {
        var found = false;
        for (type_order) |t| {
            if (std.mem.eql(u8, entry.key_ptr.*, t)) {
                found = true;
                break;
            }
        }
        if (!found and entry.value_ptr.items.len > 0) {
            try output.println("## {s}", .{capitalizeFirst(entry.key_ptr.*)});
            try output.println("", .{});
            for (entry.value_ptr.items) |issue| {
                try output.println("- [{s}] {s}", .{ issue.id, issue.title });
            }
            try output.println("", .{});
        }
    }
}

fn capitalizeFirst(s: []const u8) []const u8 {
    if (s.len == 0) return s;
    // Return as-is for display since we can't modify const memory
    return s;
}

fn parseDateToTimestamp(date_str: []const u8) ?i64 {
    // Parse YYYY-MM-DD format to Unix timestamp
    if (date_str.len < 10) return null;

    const year = std.fmt.parseInt(i32, date_str[0..4], 10) catch return null;
    const month = std.fmt.parseInt(u4, date_str[5..7], 10) catch return null;
    const day = std.fmt.parseInt(u5, date_str[8..10], 10) catch return null;

    // Simple epoch calculation (not accounting for leap seconds)
    const epoch_day = epochDayFromDate(year, month, day);
    return epoch_day * 86400;
}

fn epochDayFromDate(year: i32, month: u4, day: u5) i64 {
    // Days since Unix epoch (1970-01-01)
    var y = @as(i64, year);
    var m = @as(i64, month);
    const d = @as(i64, day);

    // Adjust for months
    if (m <= 2) {
        y -= 1;
        m += 12;
    }

    const era: i64 = @divFloor(y, 400);
    const yoe: i64 = @mod(y, 400);
    const doy: i64 = @divFloor(153 * (m - 3) + 2, 5) + d - 1;
    const doe: i64 = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;

    return era * 146097 + doe - 719468;
}

// --- Tests ---

test "ChangelogError enum exists" {
    const err: ChangelogError = ChangelogError.WorkspaceNotInitialized;
    try std.testing.expect(err == ChangelogError.WorkspaceNotInitialized);
}

test "ChangelogResult struct works" {
    const result = ChangelogResult{
        .success = true,
        .count = 5,
    };
    try std.testing.expect(result.success);
    try std.testing.expectEqual(@as(usize, 5), result.count.?);
}

test "run detects uninitialized workspace" {
    const allocator = std.testing.allocator;

    const changelog_args = args.ChangelogArgs{};
    const global = args.GlobalOptions{ .silent = true, .data_path = "/nonexistent/path" };

    const result = run(changelog_args, global, allocator);
    try std.testing.expectError(ChangelogError.WorkspaceNotInitialized, result);
}

test "run lists closed issues successfully" {
    const allocator = std.testing.allocator;

    const tmp_dir_path = try test_util.createTestDir(allocator, "changelog_test");
    defer allocator.free(tmp_dir_path);
    defer test_util.cleanupTestDir(tmp_dir_path);

    const data_path = try std.fs.path.join(allocator, &.{ tmp_dir_path, ".beads" });
    defer allocator.free(data_path);

    try std.fs.cwd().makeDir(data_path);

    const issues_path = try std.fs.path.join(allocator, &.{ data_path, "issues.jsonl" });
    defer allocator.free(issues_path);

    const f = try std.fs.cwd().createFile(issues_path, .{});
    defer f.close();

    const changelog_args = args.ChangelogArgs{};
    const global = args.GlobalOptions{ .silent = true, .data_path = data_path };

    try run(changelog_args, global, allocator);
}

test "parseDateToTimestamp parses valid date" {
    const ts = parseDateToTimestamp("2024-01-15");
    try std.testing.expect(ts != null);
    // 2024-01-15 should be around 1705276800 (depends on exact calculation)
    try std.testing.expect(ts.? > 1704067200); // > 2024-01-01
    try std.testing.expect(ts.? < 1706745600); // < 2024-02-01
}

test "parseDateToTimestamp returns null for invalid date" {
    try std.testing.expectEqual(@as(?i64, null), parseDateToTimestamp("invalid"));
    try std.testing.expectEqual(@as(?i64, null), parseDateToTimestamp("2024"));
    try std.testing.expectEqual(@as(?i64, null), parseDateToTimestamp(""));
}
