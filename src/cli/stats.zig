//! Stats command for beads_zig.
//!
//! `bz stats` - Show project statistics

const std = @import("std");
const common = @import("common.zig");
const args = @import("args.zig");

const CommandContext = common.CommandContext;

pub const StatsError = error{
    WorkspaceNotInitialized,
    StorageError,
    OutOfMemory,
};

pub const StatsResult = struct {
    success: bool,
    total: ?usize = null,
    open: ?usize = null,
    closed: ?usize = null,
    by_status: ?[]const CountEntry = null,
    by_priority: ?[]const CountEntry = null,
    by_type: ?[]const CountEntry = null,
    message: ?[]const u8 = null,

    pub const CountEntry = struct {
        key: []const u8,
        count: usize,
    };
};

pub fn run(
    global: args.GlobalOptions,
    allocator: std.mem.Allocator,
) !void {
    var ctx = (try CommandContext.init(allocator, global)) orelse {
        return StatsError.WorkspaceNotInitialized;
    };
    defer ctx.deinit();

    // Count totals
    var total: usize = 0;
    var open: usize = 0;
    var closed: usize = 0;

    // Count by status
    var status_counts: std.StringHashMapUnmanaged(usize) = .{};
    defer status_counts.deinit(allocator);

    // Count by priority
    var priority_counts: [5]usize = .{ 0, 0, 0, 0, 0 };

    // Count by type
    var type_counts: std.StringHashMapUnmanaged(usize) = .{};
    defer type_counts.deinit(allocator);

    for (ctx.store.issues.items) |issue| {
        if (issue.status.eql(.tombstone)) continue;

        total += 1;

        // Status
        const status_str = issue.status.toString();
        const status_entry = try status_counts.getOrPutValue(allocator, status_str, 0);
        status_entry.value_ptr.* += 1;

        if (issue.status.eql(.open) or issue.status.eql(.in_progress) or issue.status.eql(.blocked)) {
            open += 1;
        } else if (issue.status.eql(.closed)) {
            closed += 1;
        }

        // Priority
        if (issue.priority.value <= 4) {
            priority_counts[issue.priority.value] += 1;
        }

        // Type
        const type_str = issue.issue_type.toString();
        const type_entry = try type_counts.getOrPutValue(allocator, type_str, 0);
        type_entry.value_ptr.* += 1;
    }

    // Convert to arrays for output
    var status_list: std.ArrayListUnmanaged(StatsResult.CountEntry) = .{};
    defer status_list.deinit(allocator);

    var status_it = status_counts.iterator();
    while (status_it.next()) |entry| {
        try status_list.append(allocator, .{ .key = entry.key_ptr.*, .count = entry.value_ptr.* });
    }

    var priority_list: std.ArrayListUnmanaged(StatsResult.CountEntry) = .{};
    defer priority_list.deinit(allocator);

    const priority_names = [_][]const u8{ "critical", "high", "medium", "low", "backlog" };
    for (0..5) |i| {
        if (priority_counts[i] > 0) {
            try priority_list.append(allocator, .{ .key = priority_names[i], .count = priority_counts[i] });
        }
    }

    var type_list: std.ArrayListUnmanaged(StatsResult.CountEntry) = .{};
    defer type_list.deinit(allocator);

    var type_it = type_counts.iterator();
    while (type_it.next()) |entry| {
        try type_list.append(allocator, .{ .key = entry.key_ptr.*, .count = entry.value_ptr.* });
    }

    if (global.isStructuredOutput()) {
        try ctx.output.printJson(StatsResult{
            .success = true,
            .total = total,
            .open = open,
            .closed = closed,
            .by_status = status_list.items,
            .by_priority = priority_list.items,
            .by_type = type_list.items,
        });
    } else if (!global.quiet) {
        try ctx.output.println("Issue Statistics", .{});
        try ctx.output.print("\n", .{});
        try ctx.output.print("Total: {d} issues ({d} open, {d} closed)\n", .{ total, open, closed });
        try ctx.output.print("\n", .{});

        if (status_list.items.len > 0) {
            try ctx.output.print("By Status:\n", .{});
            for (status_list.items) |entry| {
                try ctx.output.print("  {s: <12} {d}\n", .{ entry.key, entry.count });
            }
        }

        if (priority_list.items.len > 0) {
            try ctx.output.print("\nBy Priority:\n", .{});
            for (priority_list.items) |entry| {
                try ctx.output.print("  {s: <12} {d}\n", .{ entry.key, entry.count });
            }
        }

        if (type_list.items.len > 0) {
            try ctx.output.print("\nBy Type:\n", .{});
            for (type_list.items) |entry| {
                try ctx.output.print("  {s: <12} {d}\n", .{ entry.key, entry.count });
            }
        }
    }
}

// --- Tests ---

test "StatsError enum exists" {
    const err: StatsError = StatsError.WorkspaceNotInitialized;
    try std.testing.expect(err == StatsError.WorkspaceNotInitialized);
}

test "StatsResult struct works" {
    const result = StatsResult{
        .success = true,
        .total = 10,
        .open = 5,
        .closed = 5,
    };
    try std.testing.expect(result.success);
    try std.testing.expectEqual(@as(usize, 10), result.total.?);
}

test "run detects uninitialized workspace" {
    const allocator = std.testing.allocator;

    const global = args.GlobalOptions{ .silent = true, .data_path = "/nonexistent/path" };

    const result = run(global, allocator);
    try std.testing.expectError(StatsError.WorkspaceNotInitialized, result);
}
