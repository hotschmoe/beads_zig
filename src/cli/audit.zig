//! Audit command for beads_zig.
//!
//! `bz audit [--limit N]` - Show project-wide audit log

const std = @import("std");
const common = @import("common.zig");
const args = @import("args.zig");

const CommandContext = common.CommandContext;

pub const AuditError = error{
    WorkspaceNotInitialized,
    StorageError,
    OutOfMemory,
};

pub const AuditResult = struct {
    success: bool,
    events: ?[]const AuditEvent = null,
    total: ?usize = null,
    message: ?[]const u8 = null,

    pub const AuditEvent = struct {
        issue_id: []const u8,
        event_type: []const u8,
        actor: []const u8,
        created_at: i64,
    };
};

pub fn run(
    audit_args: args.AuditArgs,
    global: args.GlobalOptions,
    allocator: std.mem.Allocator,
) !void {
    var ctx = (try CommandContext.init(allocator, global)) orelse {
        return AuditError.WorkspaceNotInitialized;
    };
    defer ctx.deinit();

    const limit = audit_args.limit orelse 100;

    // Build synthetic audit log from all issues
    var events: std.ArrayListUnmanaged(AuditResult.AuditEvent) = .{};
    defer events.deinit(allocator);

    for (ctx.store.issues.items) |issue| {
        // Created event
        try events.append(allocator, .{
            .issue_id = issue.id,
            .event_type = "created",
            .actor = issue.created_by orelse "unknown",
            .created_at = issue.created_at.value,
        });

        // Closed event
        if (issue.closed_at.value) |closed_ts| {
            try events.append(allocator, .{
                .issue_id = issue.id,
                .event_type = "closed",
                .actor = "unknown",
                .created_at = closed_ts,
            });
        }

        // If tombstoned
        if (issue.status.eql(.tombstone)) {
            try events.append(allocator, .{
                .issue_id = issue.id,
                .event_type = "deleted",
                .actor = "unknown",
                .created_at = issue.updated_at.value,
            });
        }
    }

    // Sort by timestamp descending (most recent first)
    std.mem.sortUnstable(AuditResult.AuditEvent, events.items, {}, struct {
        fn lessThan(_: void, a: AuditResult.AuditEvent, b: AuditResult.AuditEvent) bool {
            return a.created_at > b.created_at;
        }
    }.lessThan);

    // Apply limit
    const display_count = @min(events.items.len, limit);
    const display_events = events.items[0..display_count];

    if (global.isStructuredOutput()) {
        try ctx.output.printJson(AuditResult{
            .success = true,
            .events = display_events,
            .total = events.items.len,
        });
    } else if (global.quiet) {
        for (display_events) |event| {
            try ctx.output.print("{s} {s}\n", .{ event.issue_id, event.event_type });
        }
    } else {
        if (display_events.len == 0) {
            try ctx.output.info("No events found", .{});
        } else {
            try ctx.output.println("Audit Log ({d} events):", .{events.items.len});
            try ctx.output.print("\n", .{});

            for (display_events) |event| {
                try ctx.output.print("[ts:{d}]  {s: <12}  {s: <15}  {s}\n", .{
                    event.created_at,
                    event.issue_id,
                    event.actor,
                    event.event_type,
                });
            }

            if (events.items.len > display_count) {
                try ctx.output.print("\n...and {d} more (use --limit to show more)\n", .{
                    events.items.len - display_count,
                });
            }
        }
    }
}

// --- Tests ---

test "AuditError enum exists" {
    const err: AuditError = AuditError.WorkspaceNotInitialized;
    try std.testing.expect(err == AuditError.WorkspaceNotInitialized);
}

test "AuditResult struct works" {
    const result = AuditResult{
        .success = true,
        .total = 10,
    };
    try std.testing.expect(result.success);
    try std.testing.expectEqual(@as(usize, 10), result.total.?);
}

test "run detects uninitialized workspace" {
    const allocator = std.testing.allocator;

    const audit_args = args.AuditArgs{};
    const global = args.GlobalOptions{ .silent = true, .data_path = "/nonexistent/path" };

    const result = run(audit_args, global, allocator);
    try std.testing.expectError(AuditError.WorkspaceNotInitialized, result);
}
