//! History command for beads_zig.
//!
//! `bz history <id>` - Show history/changelog for an issue

const std = @import("std");
const common = @import("common.zig");
const args = @import("args.zig");
const Event = @import("../models/event.zig").Event;

const CommandContext = common.CommandContext;

pub const HistoryError = error{
    WorkspaceNotInitialized,
    StorageError,
    IssueNotFound,
    OutOfMemory,
};

pub const HistoryResult = struct {
    success: bool,
    id: ?[]const u8 = null,
    events: ?[]const EventInfo = null,
    message: ?[]const u8 = null,

    pub const EventInfo = struct {
        id: i64,
        event_type: []const u8,
        actor: []const u8,
        old_value: ?[]const u8,
        new_value: ?[]const u8,
        created_at: i64,
    };
};

pub fn run(
    history_args: args.HistoryArgs,
    global: args.GlobalOptions,
    allocator: std.mem.Allocator,
) !void {
    var ctx = (try CommandContext.init(allocator, global)) orelse {
        return HistoryError.WorkspaceNotInitialized;
    };
    defer ctx.deinit();

    const id = history_args.id;

    // Verify issue exists
    if (!try ctx.issue_store.exists(id)) {
        if (global.isStructuredOutput()) {
            try ctx.output.printJson(HistoryResult{
                .success = false,
                .id = id,
                .message = "issue not found",
            });
        } else {
            try ctx.output.err("issue not found: {s}", .{id});
        }
        return HistoryError.IssueNotFound;
    }

    // Get real events from the event store
    const stored_events = ctx.event_store.getForIssue(id) catch &[_]Event{};
    defer if (stored_events.len > 0) ctx.event_store.freeEvents(@constCast(stored_events));

    // Convert to output format
    var events: std.ArrayListUnmanaged(HistoryResult.EventInfo) = .{};
    defer events.deinit(allocator);

    for (stored_events) |e| {
        try events.append(allocator, .{
            .id = e.id,
            .event_type = e.event_type.toString(),
            .actor = e.actor,
            .old_value = e.old_value,
            .new_value = e.new_value,
            .created_at = e.created_at,
        });
    }

    // If no stored events, generate synthetic events from issue data for backwards compatibility
    if (events.items.len == 0) {
        const issue_opt = try ctx.issue_store.get(id);
        if (issue_opt) |issue_val| {
            var issue = issue_val;
            defer issue.deinit(allocator);

            // Created event
            try events.append(allocator, .{
                .id = 0,
                .event_type = "created",
                .actor = issue.created_by orelse "unknown",
                .old_value = null,
                .new_value = issue.title,
                .created_at = issue.created_at.value,
            });

            // If closed, add closed event
            if (issue.closed_at.value) |closed_ts| {
                try events.append(allocator, .{
                    .id = 0,
                    .event_type = "closed",
                    .actor = "unknown",
                    .old_value = null,
                    .new_value = issue.close_reason,
                    .created_at = closed_ts,
                });
            }

            // If updated (updated_at != created_at)
            if (issue.updated_at.value != issue.created_at.value) {
                try events.append(allocator, .{
                    .id = 0,
                    .event_type = "updated",
                    .actor = "unknown",
                    .old_value = null,
                    .new_value = null,
                    .created_at = issue.updated_at.value,
                });
            }
        }
    }

    if (global.isStructuredOutput()) {
        try ctx.output.printJson(HistoryResult{
            .success = true,
            .id = id,
            .events = events.items,
        });
    } else if (global.quiet) {
        for (events.items) |event| {
            try ctx.output.print("{s}\n", .{event.event_type});
        }
    } else {
        if (events.items.len == 0) {
            try ctx.output.info("No history for {s}", .{id});
        } else {
            try ctx.output.println("History for {s} ({d} events):", .{ id, events.items.len });
            for (events.items) |event| {
                try ctx.output.print("\n", .{});
                if (event.id > 0) {
                    try ctx.output.print("[#{d}] [{d}] {s}  {s}\n", .{
                        event.id,
                        event.created_at,
                        event.actor,
                        event.event_type,
                    });
                } else {
                    try ctx.output.print("[ts:{d}] {s}  {s}\n", .{
                        event.created_at,
                        event.actor,
                        event.event_type,
                    });
                }
                if (event.old_value != null or event.new_value != null) {
                    if (event.old_value) |old| {
                        try ctx.output.print("  - {s}\n", .{truncate(old, 50)});
                    }
                    if (event.new_value) |new| {
                        try ctx.output.print("  + {s}\n", .{truncate(new, 50)});
                    }
                }
            }
        }
    }
}

fn truncate(s: []const u8, max_len: usize) []const u8 {
    if (s.len <= max_len) return s;
    return s[0..max_len];
}

// --- Tests ---

test "HistoryError enum exists" {
    const err: HistoryError = HistoryError.WorkspaceNotInitialized;
    try std.testing.expect(err == HistoryError.WorkspaceNotInitialized);
}

test "HistoryResult struct works" {
    const result = HistoryResult{
        .success = true,
        .id = "bd-test",
    };
    try std.testing.expect(result.success);
    try std.testing.expectEqualStrings("bd-test", result.id.?);
}

test "run detects uninitialized workspace" {
    const allocator = std.testing.allocator;

    const history_args = args.HistoryArgs{ .id = "bd-test" };
    const global = args.GlobalOptions{ .silent = true, .data_path = "/nonexistent/path" };

    const result = run(history_args, global, allocator);
    try std.testing.expectError(HistoryError.WorkspaceNotInitialized, result);
}

test "truncate handles short strings" {
    const short = "hello";
    try std.testing.expectEqualStrings("hello", truncate(short, 10));
}

test "truncate handles long strings" {
    const long = "this is a very long string that should be truncated";
    const truncated = truncate(long, 10);
    try std.testing.expectEqual(@as(usize, 10), truncated.len);
}
