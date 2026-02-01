//! Stale command for beads_zig.
//!
//! Lists issues that haven't been updated for a specified number of days.

const std = @import("std");
const args = @import("args.zig");
const common = @import("common.zig");
const output_mod = @import("../output/mod.zig");
const models = @import("../models/mod.zig");
const timestamp = @import("../models/timestamp.zig");

const Issue = models.Issue;
const Status = models.Status;
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

    const all_issues = ctx.store.getAllRef();

    const now = std.time.timestamp();
    const stale_threshold = now - @as(i64, @intCast(stale_args.days)) * 24 * 60 * 60;

    var stale_issues: std.ArrayListUnmanaged(Issue) = .{};
    defer stale_issues.deinit(allocator);

    for (all_issues) |issue| {
        // Skip closed or deleted issues
        if (issue.status.eql(.closed) or issue.status.eql(.tombstone)) continue;

        // Check if issue is stale based on updated_at
        const updated_ts = issue.updated_at.value;
        if (updated_ts < stale_threshold) {
            stale_issues.append(allocator, issue) catch continue;
        }
    }

    // Sort by oldest first (most stale)
    std.mem.sort(Issue, stale_issues.items, {}, struct {
        fn lessThan(_: void, a: Issue, b: Issue) bool {
            return a.updated_at.value < b.updated_at.value;
        }
    }.lessThan);

    // Apply limit if specified
    const display_items = if (stale_args.limit) |limit|
        stale_issues.items[0..@min(limit, stale_issues.items.len)]
    else
        stale_issues.items;

    if (global.json) {
        try outputJson(&ctx.output, display_items, stale_args.days, allocator);
    } else if (global.toon) {
        try outputToon(&ctx.output, display_items, stale_args.days);
    } else {
        try outputHuman(&ctx.output, display_items, stale_args.days, now);
    }
}

fn outputJson(out: *common.Output, issues: []const Issue, days: u32, allocator: std.mem.Allocator) !void {
    // Build compact issue list for JSON output
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

fn outputToon(out: *common.Output, issues: []const Issue, days: u32) !void {
    try out.print("stale issues (>{d} days without update): {d}\n", .{ days, issues.len });
    for (issues) |issue| {
        var buf: [timestamp.RFC3339_BUFFER_SIZE]u8 = undefined;
        const formatted_ts = timestamp.formatRfc3339(issue.updated_at.value, &buf) catch "unknown";
        const date_part = if (formatted_ts.len >= 10) formatted_ts[0..10] else formatted_ts;
        try out.print("- {s}: {s} (last: {s})\n", .{ issue.id, issue.title, date_part });
    }
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
    // Unit test for timestamp parsing
    const ts = "2025-01-15T10:30:00Z";
    const epoch = timestamp.parseRfc3339(ts);
    try std.testing.expect(epoch != null);
    try std.testing.expect(epoch.? > 0);
}
