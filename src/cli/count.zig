//! Count command for beads_zig.
//!
//! Counts issues with optional grouping by field.

const std = @import("std");
const args = @import("args.zig");
const common = @import("common.zig");
const storage = @import("../storage/mod.zig");

const CommandContext = common.CommandContext;
const GroupBy = storage.IssueStore.GroupBy;
const GroupCount = storage.IssueStore.CountResult;

pub const CountError = common.CommandError || error{WriteError};

pub const CountResult = struct {
    success: bool,
    count: ?usize = null,
    group_by: ?[]const u8 = null,
    message: ?[]const u8 = null,
};

pub fn run(
    count_args: args.CountArgs,
    global: args.GlobalOptions,
    allocator: std.mem.Allocator,
) !void {
    var ctx = (try CommandContext.init(allocator, global)) orelse {
        return CountError.WorkspaceNotInitialized;
    };
    defer ctx.deinit();

    // Parse group_by field
    const group_by: ?GroupBy = if (count_args.group_by) |field| parseGroupBy(field) else null;

    const counts = try ctx.issue_store.count(group_by);
    defer {
        for (counts) |c| {
            allocator.free(c.key);
        }
        allocator.free(counts);
    }

    if (count_args.group_by != null) {
        try outputGrouped(&ctx.output, counts, count_args.group_by.?, global);
    } else {
        const total: usize = if (counts.len > 0) @intCast(counts[0].count) else 0;
        try outputTotal(&ctx.output, total, global);
    }
}

fn parseGroupBy(field: []const u8) ?GroupBy {
    if (std.mem.eql(u8, field, "status")) return .status;
    if (std.mem.eql(u8, field, "priority")) return .priority;
    if (std.mem.eql(u8, field, "type") or std.mem.eql(u8, field, "issue_type")) return .issue_type;
    if (std.mem.eql(u8, field, "assignee")) return .assignee;
    return null;
}

fn outputTotal(out: *common.Output, count: usize, global: args.GlobalOptions) !void {
    if (global.isStructuredOutput()) {
        try out.printJson(.{ .count = count });
    } else {
        try out.println("{d}", .{count});
    }
}

fn outputGrouped(
    out: *common.Output,
    counts: []const GroupCount,
    field: []const u8,
    global: args.GlobalOptions,
) !void {
    if (global.isStructuredOutput()) {
        try out.raw("{\"group_by\":\"");
        try out.raw(field);
        try out.raw("\",\"groups\":[");

        for (counts, 0..) |entry, i| {
            if (i > 0) try out.raw(",");
            try out.raw("{\"");
            try out.raw(entry.key);
            try out.raw("\":");
            try out.print("{d}", .{entry.count});
            try out.raw("}");
        }

        try out.raw("]}\n");
    } else {
        try out.print("Issues by {s}:\n", .{field});
        var total: u64 = 0;
        for (counts) |entry| {
            try out.print("  {s}: {d}\n", .{ entry.key, entry.count });
            total += entry.count;
        }
        try out.print("\nTotal: {d}\n", .{total});
    }
}

// --- Tests ---

test "parseGroupBy returns correct enum" {
    try std.testing.expect(parseGroupBy("status") == .status);
    try std.testing.expect(parseGroupBy("priority") == .priority);
    try std.testing.expect(parseGroupBy("type") == .issue_type);
    try std.testing.expect(parseGroupBy("issue_type") == .issue_type);
    try std.testing.expect(parseGroupBy("assignee") == .assignee);
    try std.testing.expect(parseGroupBy("unknown") == null);
}

test "CountResult struct works" {
    const result = CountResult{
        .success = true,
        .count = 5,
    };
    try std.testing.expect(result.success);
    try std.testing.expectEqual(@as(usize, 5), result.count.?);
}

test "run detects uninitialized workspace" {
    const allocator = std.testing.allocator;

    const count_args = args.CountArgs{};
    const global = args.GlobalOptions{ .silent = true, .data_path = "/nonexistent/path" };

    const result = run(count_args, global, allocator);
    try std.testing.expectError(CountError.WorkspaceNotInitialized, result);
}
