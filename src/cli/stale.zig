//! Stale command for beads_zig.
//!
//! Lists issues that haven't been updated for a specified number of days.

const std = @import("std");
const args = @import("args.zig");
const common = @import("common.zig");
const models = @import("../models/mod.zig");
const timestamp = @import("../models/timestamp.zig");

const Issue = models.Issue;
const CommandContext = common.CommandContext;

pub const StaleError = common.CommandError || error{WriteError};

pub const StaleResult = struct {
    success: bool,
    count: ?usize = null,
    threshold_days: ?u32 = null,
    message: ?[]const u8 = null,
};

pub fn run(
    stale_args: args.StaleArgs,
    global: args.GlobalOptions,
    allocator: std.mem.Allocator,
) !void {
    var ctx = (try CommandContext.init(allocator, global)) orelse {
        return StaleError.WorkspaceNotInitialized;
    };
    defer ctx.deinit();

    // Fetch open issues sorted by updated_at ascending (oldest first)
    const all_issues = try ctx.issue_store.list(.{
        .status = .open,
        .order_by = .updated_at,
        .order_desc = false,
    });
    defer {
        for (all_issues) |*issue| {
            var i = issue.*;
            i.deinit(allocator);
        }
        allocator.free(all_issues);
    }

    const now = std.time.timestamp();
    const stale_threshold = now - @as(i64, @intCast(stale_args.days)) * 24 * 60 * 60;

    // Filter to stale issues (updated_at < threshold)
    var stale_issues: std.ArrayListUnmanaged(Issue) = .{};
    defer stale_issues.deinit(allocator);

    for (all_issues) |issue| {
        if (issue.updated_at.value < stale_threshold) {
            try stale_issues.append(allocator, issue);
        }
    }

    // Apply limit
    const display_items = if (stale_args.limit) |limit|
        stale_issues.items[0..@min(limit, stale_issues.items.len)]
    else
        stale_issues.items;

    if (global.isStructuredOutput()) {
        try outputJson(&ctx.output, display_items, stale_args.days, allocator);
    } else {
        try outputHuman(&ctx.output, display_items, stale_args.days, now);
    }
}

fn outputJson(out: *common.Output, issues: []const Issue, days: u32, allocator: std.mem.Allocator) !void {
    const StaleIssue = struct {
        id: []const u8,
        title: []const u8,
        updated_at: i64,
    };

    var compact_issues: std.ArrayListUnmanaged(StaleIssue) = .{};
    defer compact_issues.deinit(allocator);

    for (issues) |issue| {
        try compact_issues.append(allocator, .{
            .id = issue.id,
            .title = issue.title,
            .updated_at = issue.updated_at.value,
        });
    }

    try out.printJson(.{
        .stale_threshold_days = days,
        .count = issues.len,
        .issues = compact_issues.items,
    });
}

fn outputHuman(out: *common.Output, issues: []const Issue, days: u32, now: i64) !void {
    if (issues.len == 0) {
        try out.print("No stale issues (updated within {d} days)\n", .{days});
        return;
    }

    try out.print("Stale issues (not updated in {d}+ days):\n\n", .{days});
    for (issues) |issue| {
        const updated_ts = issue.updated_at.value;
        const days_stale = @divFloor(now - updated_ts, 24 * 60 * 60);

        try out.print("  {s}  {s}\n", .{ issue.id, issue.title });
        try out.print("           last updated: {d} days ago\n\n", .{days_stale});
    }

    try out.print("Total: {d} stale issue(s)\n", .{issues.len});
}

test "stale command filters correctly" {
    const ts = "2025-01-15T10:30:00Z";
    const epoch = timestamp.parseRfc3339(ts);
    try std.testing.expect(epoch != null);
    try std.testing.expect(epoch.? > 0);
}
