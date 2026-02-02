//! Audit command for beads_zig.
//!
//! `bz audit` - Show project-wide audit log (default)
//! `bz audit record <kind>` - Record LLM/tool interaction
//! `bz audit label <entry-id> <label>` - Label audit entry
//! `bz audit log <issue-id>` - View audit log for specific issue
//! `bz audit summary` - Summary of audit data over time period

const std = @import("std");
const common = @import("common.zig");
const args = @import("args.zig");
const Event = @import("../models/event.zig").Event;
const EventType = @import("../models/event.zig").EventType;

const CommandContext = common.CommandContext;

pub const AuditError = error{
    WorkspaceNotInitialized,
    StorageError,
    OutOfMemory,
    InvalidKind,
    EntryNotFound,
};

pub const AuditResult = struct {
    success: bool,
    events: ?[]const AuditEvent = null,
    total: ?usize = null,
    event_id: ?i64 = null,
    summary: ?AuditSummary = null,
    message: ?[]const u8 = null,

    pub const AuditEvent = struct {
        id: i64,
        issue_id: []const u8,
        event_type: []const u8,
        actor: []const u8,
        created_at: i64,
        old_value: ?[]const u8 = null,
        new_value: ?[]const u8 = null,
    };

    pub const AuditSummary = struct {
        period_days: u32,
        total_events: usize,
        llm_calls: usize,
        tool_calls: usize,
        issue_creates: usize,
        issue_closes: usize,
        other_events: usize,
        by_actor: ?[]const ActorCount = null,

        pub const ActorCount = struct {
            actor: []const u8,
            count: usize,
        };
    };
};

pub fn run(
    audit_args: args.AuditArgs,
    global: args.GlobalOptions,
    allocator: std.mem.Allocator,
) !void {
    switch (audit_args.subcommand) {
        .record => |record_args| try runRecord(record_args, global, allocator),
        .label => |label_args| try runLabel(label_args, global, allocator),
        .log => |log_args| try runLog(log_args, global, allocator),
        .summary => |summary_args| try runSummary(summary_args, global, allocator),
        .list => |list_args| try runList(list_args, global, allocator),
    }
}

fn runRecord(
    record_args: anytype,
    global: args.GlobalOptions,
    allocator: std.mem.Allocator,
) !void {
    var ctx = (try CommandContext.init(allocator, global)) orelse {
        return AuditError.WorkspaceNotInitialized;
    };
    defer ctx.deinit();

    // Validate kind
    const event_type: EventType = if (std.mem.eql(u8, record_args.kind, "llm_call"))
        .llm_call
    else if (std.mem.eql(u8, record_args.kind, "tool_call"))
        .tool_call
    else {
        if (!global.silent) {
            if (global.isStructuredOutput()) {
                try ctx.output.printJson(AuditResult{
                    .success = false,
                    .message = "Invalid kind. Use 'llm_call' or 'tool_call'",
                });
            } else {
                try ctx.output.err("Invalid kind '{s}'. Use 'llm_call' or 'tool_call'", .{record_args.kind});
            }
        }
        return AuditError.InvalidKind;
    };

    const actor = global.actor orelse "unknown";
    const now = std.time.timestamp();

    // Build metadata JSON with all provided fields
    var metadata_parts: std.ArrayListUnmanaged(u8) = .{};
    defer metadata_parts.deinit(allocator);

    try metadata_parts.appendSlice(allocator, "{");
    var first = true;

    if (record_args.model) |model| {
        if (!first) try metadata_parts.appendSlice(allocator, ",");
        try metadata_parts.appendSlice(allocator, "\"model\":\"");
        try metadata_parts.appendSlice(allocator, model);
        try metadata_parts.appendSlice(allocator, "\"");
        first = false;
    }
    if (record_args.prompt) |prompt| {
        if (!first) try metadata_parts.appendSlice(allocator, ",");
        try metadata_parts.appendSlice(allocator, "\"prompt\":");
        const escaped = try std.json.Stringify.valueAlloc(allocator, prompt, .{});
        defer allocator.free(escaped);
        try metadata_parts.appendSlice(allocator, escaped);
        first = false;
    }
    if (record_args.response) |response| {
        if (!first) try metadata_parts.appendSlice(allocator, ",");
        try metadata_parts.appendSlice(allocator, "\"response\":");
        const escaped = try std.json.Stringify.valueAlloc(allocator, response, .{});
        defer allocator.free(escaped);
        try metadata_parts.appendSlice(allocator, escaped);
        first = false;
    }
    if (record_args.tool_name) |tool_name| {
        if (!first) try metadata_parts.appendSlice(allocator, ",");
        try metadata_parts.appendSlice(allocator, "\"tool_name\":\"");
        try metadata_parts.appendSlice(allocator, tool_name);
        try metadata_parts.appendSlice(allocator, "\"");
        first = false;
    }
    if (record_args.exit_code) |exit_code| {
        if (!first) try metadata_parts.appendSlice(allocator, ",");
        var buf: [32]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "\"exit_code\":{d}", .{exit_code}) catch unreachable;
        try metadata_parts.appendSlice(allocator, s);
        first = false;
    }
    if (record_args.metadata) |metadata| {
        if (!first) try metadata_parts.appendSlice(allocator, ",");
        try metadata_parts.appendSlice(allocator, "\"extra\":");
        try metadata_parts.appendSlice(allocator, metadata);
        first = false;
    }
    try metadata_parts.appendSlice(allocator, "}");

    const new_value = try allocator.dupe(u8, metadata_parts.items);
    defer allocator.free(new_value);

    const event = Event{
        .id = 0,
        .issue_id = record_args.issue_id orelse "",
        .event_type = event_type,
        .actor = actor,
        .old_value = null,
        .new_value = new_value,
        .created_at = now,
    };

    const event_id = try ctx.event_store.append(event);

    if (global.isStructuredOutput()) {
        try ctx.output.printJson(AuditResult{
            .success = true,
            .event_id = event_id,
            .message = "Audit entry recorded",
        });
    } else if (!global.quiet) {
        try ctx.output.println("Recorded audit entry {d}", .{event_id});
    }
}

fn runLabel(
    label_args: anytype,
    global: args.GlobalOptions,
    allocator: std.mem.Allocator,
) !void {
    var ctx = (try CommandContext.init(allocator, global)) orelse {
        return AuditError.WorkspaceNotInitialized;
    };
    defer ctx.deinit();

    // Record a label event referencing the original entry
    const actor = global.actor orelse "unknown";
    const now = std.time.timestamp();

    // Build the label metadata
    var metadata_parts: std.ArrayListUnmanaged(u8) = .{};
    defer metadata_parts.deinit(allocator);

    var buf: [64]u8 = undefined;
    const header = std.fmt.bufPrint(&buf, "{{\"entry_id\":{d},\"label\":\"{s}\"", .{ label_args.entry_id, label_args.label_value }) catch unreachable;
    try metadata_parts.appendSlice(allocator, header);

    if (label_args.reason) |reason| {
        try metadata_parts.appendSlice(allocator, ",\"reason\":");
        const escaped = try std.json.Stringify.valueAlloc(allocator, reason, .{});
        defer allocator.free(escaped);
        try metadata_parts.appendSlice(allocator, escaped);
    }
    try metadata_parts.appendSlice(allocator, "}");

    const new_value = try allocator.dupe(u8, metadata_parts.items);
    defer allocator.free(new_value);

    // Use 'updated' event type to represent a label action on an existing entry
    const event = Event{
        .id = 0,
        .issue_id = "", // Labels are not issue-specific
        .event_type = .updated,
        .actor = actor,
        .old_value = null,
        .new_value = new_value,
        .created_at = now,
    };

    const event_id = try ctx.event_store.append(event);

    if (global.isStructuredOutput()) {
        try ctx.output.printJson(AuditResult{
            .success = true,
            .event_id = event_id,
            .message = "Label applied to audit entry",
        });
    } else if (!global.quiet) {
        try ctx.output.println("Labeled entry {d} as '{s}'", .{ label_args.entry_id, label_args.label_value });
    }
}

fn runLog(
    log_args: anytype,
    global: args.GlobalOptions,
    allocator: std.mem.Allocator,
) !void {
    var ctx = (try CommandContext.init(allocator, global)) orelse {
        return AuditError.WorkspaceNotInitialized;
    };
    defer ctx.deinit();

    const limit = log_args.limit orelse 100;

    // Query events for the specific issue from the event store
    const events = try ctx.event_store.queryEvents(.{
        .issue_id = log_args.issue_id,
        .limit = limit,
    });
    defer ctx.event_store.freeEvents(events);

    var audit_events: std.ArrayListUnmanaged(AuditResult.AuditEvent) = .{};
    defer audit_events.deinit(allocator);

    for (events) |event| {
        try audit_events.append(allocator, .{
            .id = event.id,
            .issue_id = event.issue_id,
            .event_type = event.event_type.toString(),
            .actor = event.actor,
            .created_at = event.created_at,
            .old_value = event.old_value,
            .new_value = event.new_value,
        });
    }

    // Sort by timestamp descending
    std.mem.sortUnstable(AuditResult.AuditEvent, audit_events.items, {}, struct {
        fn lessThan(_: void, a: AuditResult.AuditEvent, b: AuditResult.AuditEvent) bool {
            return a.created_at > b.created_at;
        }
    }.lessThan);

    if (global.isStructuredOutput()) {
        try ctx.output.printJson(AuditResult{
            .success = true,
            .events = audit_events.items,
            .total = audit_events.items.len,
        });
    } else if (global.quiet) {
        for (audit_events.items) |event| {
            try ctx.output.print("{d} {s} {s}\n", .{ event.id, event.issue_id, event.event_type });
        }
    } else {
        if (audit_events.items.len == 0) {
            try ctx.output.info("No events found for issue {s}", .{log_args.issue_id});
        } else {
            try ctx.output.println("Audit Log for {s} ({d} events):", .{ log_args.issue_id, audit_events.items.len });
            try ctx.output.print("\n", .{});

            for (audit_events.items) |event| {
                try ctx.output.print("[{d}] ts:{d}  {s: <15}  {s}\n", .{
                    event.id,
                    event.created_at,
                    event.actor,
                    event.event_type,
                });
                if (event.new_value) |v| {
                    if (v.len > 0 and v.len < 200) {
                        try ctx.output.print("      -> {s}\n", .{v});
                    }
                }
            }
        }
    }
}

fn runSummary(
    summary_args: anytype,
    global: args.GlobalOptions,
    allocator: std.mem.Allocator,
) !void {
    var ctx = (try CommandContext.init(allocator, global)) orelse {
        return AuditError.WorkspaceNotInitialized;
    };
    defer ctx.deinit();

    const now = std.time.timestamp();
    const since = now - @as(i64, @intCast(summary_args.days)) * 24 * 60 * 60;

    // Query all events in the time period
    const events = try ctx.event_store.queryEvents(.{ .since = since });
    defer ctx.event_store.freeEvents(events);

    // Count by type
    var llm_calls: usize = 0;
    var tool_calls: usize = 0;
    var issue_creates: usize = 0;
    var issue_closes: usize = 0;
    var other_events: usize = 0;

    // Count by actor
    var actor_counts: std.StringHashMapUnmanaged(usize) = .{};
    defer actor_counts.deinit(allocator);

    for (events) |event| {
        switch (event.event_type) {
            .llm_call => llm_calls += 1,
            .tool_call => tool_calls += 1,
            .created => issue_creates += 1,
            .closed => issue_closes += 1,
            else => other_events += 1,
        }

        const entry = try actor_counts.getOrPutValue(allocator, event.actor, 0);
        entry.value_ptr.* += 1;
    }

    // Convert actor counts to array
    var actor_list: std.ArrayListUnmanaged(AuditResult.AuditSummary.ActorCount) = .{};
    defer actor_list.deinit(allocator);

    var it = actor_counts.iterator();
    while (it.next()) |entry| {
        try actor_list.append(allocator, .{
            .actor = entry.key_ptr.*,
            .count = entry.value_ptr.*,
        });
    }

    // Sort by count descending
    std.mem.sortUnstable(AuditResult.AuditSummary.ActorCount, actor_list.items, {}, struct {
        fn lessThan(_: void, a: AuditResult.AuditSummary.ActorCount, b: AuditResult.AuditSummary.ActorCount) bool {
            return a.count > b.count;
        }
    }.lessThan);

    const summary = AuditResult.AuditSummary{
        .period_days = summary_args.days,
        .total_events = events.len,
        .llm_calls = llm_calls,
        .tool_calls = tool_calls,
        .issue_creates = issue_creates,
        .issue_closes = issue_closes,
        .other_events = other_events,
        .by_actor = if (actor_list.items.len > 0) actor_list.items else null,
    };

    if (global.isStructuredOutput()) {
        try ctx.output.printJson(AuditResult{
            .success = true,
            .summary = summary,
        });
    } else if (!global.quiet) {
        try ctx.output.println("Audit Summary (last {d} days)", .{summary_args.days});
        try ctx.output.print("\n", .{});
        try ctx.output.print("Total Events:   {d}\n", .{summary.total_events});
        try ctx.output.print("LLM Calls:      {d}\n", .{summary.llm_calls});
        try ctx.output.print("Tool Calls:     {d}\n", .{summary.tool_calls});
        try ctx.output.print("Issues Created: {d}\n", .{summary.issue_creates});
        try ctx.output.print("Issues Closed:  {d}\n", .{summary.issue_closes});
        try ctx.output.print("Other Events:   {d}\n", .{summary.other_events});

        if (actor_list.items.len > 0) {
            try ctx.output.print("\nBy Actor:\n", .{});
            for (actor_list.items[0..@min(10, actor_list.items.len)]) |actor_count| {
                try ctx.output.print("  {s: <20} {d}\n", .{ actor_count.actor, actor_count.count });
            }
        }
    }
}

fn runList(
    list_args: anytype,
    global: args.GlobalOptions,
    allocator: std.mem.Allocator,
) !void {
    var ctx = (try CommandContext.init(allocator, global)) orelse {
        return AuditError.WorkspaceNotInitialized;
    };
    defer ctx.deinit();

    const limit = list_args.limit orelse 100;

    // Build synthetic audit log from all issues
    var events: std.ArrayListUnmanaged(AuditResult.AuditEvent) = .{};
    defer events.deinit(allocator);

    for (ctx.store.issues.items) |issue| {
        // Created event
        try events.append(allocator, .{
            .id = 0,
            .issue_id = issue.id,
            .event_type = "created",
            .actor = issue.created_by orelse "unknown",
            .created_at = issue.created_at.value,
        });

        // Closed event
        if (issue.closed_at.value) |closed_ts| {
            try events.append(allocator, .{
                .id = 0,
                .issue_id = issue.id,
                .event_type = "closed",
                .actor = "unknown",
                .created_at = closed_ts,
            });
        }

        // If tombstoned
        if (issue.status.eql(.tombstone)) {
            try events.append(allocator, .{
                .id = 0,
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

    const audit_args = args.AuditArgs{ .subcommand = .{ .list = .{ .limit = null } } };
    const global = args.GlobalOptions{ .silent = true, .data_path = "/nonexistent/path" };

    const result = run(audit_args, global, allocator);
    try std.testing.expectError(AuditError.WorkspaceNotInitialized, result);
}

test "AuditSubcommand record parses correctly" {
    const allocator = std.testing.allocator;
    const cmd_args = [_][]const u8{ "audit", "record", "llm_call", "--model", "gpt-4", "--prompt", "hello" };
    var parser = args.ArgParser.init(allocator, &cmd_args);
    var result = parser.parse() catch unreachable;
    defer result.deinit(allocator);

    switch (result.command) {
        .audit => |a| {
            switch (a.subcommand) {
                .record => |r| {
                    try std.testing.expectEqualStrings("llm_call", r.kind);
                    try std.testing.expectEqualStrings("gpt-4", r.model.?);
                    try std.testing.expectEqualStrings("hello", r.prompt.?);
                },
                else => try std.testing.expect(false),
            }
        },
        else => try std.testing.expect(false),
    }
}

test "AuditSubcommand summary parses days" {
    const allocator = std.testing.allocator;
    const cmd_args = [_][]const u8{ "audit", "summary", "--days", "30" };
    var parser = args.ArgParser.init(allocator, &cmd_args);
    var result = parser.parse() catch unreachable;
    defer result.deinit(allocator);

    switch (result.command) {
        .audit => |a| {
            switch (a.subcommand) {
                .summary => |s| {
                    try std.testing.expectEqual(@as(u32, 30), s.days);
                },
                else => try std.testing.expect(false),
            }
        },
        else => try std.testing.expect(false),
    }
}

test "AuditSubcommand list is default" {
    const allocator = std.testing.allocator;
    const cmd_args = [_][]const u8{"audit"};
    var parser = args.ArgParser.init(allocator, &cmd_args);
    var result = parser.parse() catch unreachable;
    defer result.deinit(allocator);

    switch (result.command) {
        .audit => |a| {
            switch (a.subcommand) {
                .list => {},
                else => try std.testing.expect(false),
            }
        },
        else => try std.testing.expect(false),
    }
}
