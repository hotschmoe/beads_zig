//! Defer and Undefer commands for beads_zig.
//!
//! `bz defer <id> [--until <date>] [--reason <reason>]` - defer an issue
//! `bz undefer <id>` - remove defer status from an issue

const std = @import("std");
const args = @import("args.zig");
const common = @import("common.zig");
const models = @import("../models/mod.zig");
const timestamp = @import("../models/timestamp.zig");

const Issue = models.Issue;
const Status = models.Status;
const CommandContext = common.CommandContext;
const IssueStore = common.IssueStore;

pub const DeferError = error{
    WorkspaceNotInitialized,
    IssueNotFound,
    AlreadyDeferred,
    InvalidDate,
    StorageError,
    OutOfMemory,
};

pub const DeferResult = struct {
    success: bool,
    id: ?[]const u8 = null,
    defer_until: ?i64 = null,
    message: ?[]const u8 = null,
};

pub fn run(
    defer_args: args.DeferArgs,
    global: args.GlobalOptions,
    allocator: std.mem.Allocator,
) !void {
    var ctx = (try CommandContext.init(allocator, global)) orelse {
        return DeferError.WorkspaceNotInitialized;
    };
    defer ctx.deinit();

    // Find the issue
    const issue = ctx.store.getRef(defer_args.id) orelse {
        if (global.isStructuredOutput()) {
            try ctx.output.printJson(DeferResult{
                .success = false,
                .message = "issue not found",
            });
        } else {
            try ctx.output.err("issue not found: {s}", .{defer_args.id});
        }
        return DeferError.IssueNotFound;
    };

    // Check if already deferred
    if (issue.status.eql(.deferred)) {
        if (global.isStructuredOutput()) {
            try ctx.output.printJson(DeferResult{
                .success = false,
                .id = defer_args.id,
                .message = "issue is already deferred",
            });
        } else {
            try ctx.output.warn("issue {s} is already deferred", .{defer_args.id});
        }
        return DeferError.AlreadyDeferred;
    }

    // Parse until date if provided
    var defer_until: ?i64 = null;
    if (defer_args.until) |until_str| {
        defer_until = parseUntilDate(until_str, allocator) catch |err| {
            if (global.isStructuredOutput()) {
                try ctx.output.printJson(DeferResult{
                    .success = false,
                    .message = "invalid date format",
                });
            } else {
                try ctx.output.err("invalid date format: {s}", .{until_str});
            }
            return err;
        };
    }

    // Update the issue
    const now = std.time.timestamp();
    try ctx.store.update(defer_args.id, .{
        .status = .deferred,
        .defer_until = defer_until,
    }, now);

    try ctx.saveIfAutoFlush();

    // Output result
    if (global.isStructuredOutput()) {
        try ctx.output.printJson(DeferResult{
            .success = true,
            .id = defer_args.id,
            .defer_until = defer_until,
        });
    } else {
        if (defer_until) |until| {
            var buf: [timestamp.RFC3339_BUFFER_SIZE]u8 = undefined;
            const formatted = timestamp.formatRfc3339(until, &buf) catch "unknown";
            try ctx.output.success("Deferred issue {s} until {s}", .{ defer_args.id, formatted });
        } else {
            try ctx.output.success("Deferred issue {s} indefinitely", .{defer_args.id});
        }
    }
}

pub fn runUndefer(
    undefer_args: args.UndeferArgs,
    global: args.GlobalOptions,
    allocator: std.mem.Allocator,
) !void {
    var ctx = (try CommandContext.init(allocator, global)) orelse {
        return DeferError.WorkspaceNotInitialized;
    };
    defer ctx.deinit();

    // Find the issue
    const issue = ctx.store.getRef(undefer_args.id) orelse {
        if (global.isStructuredOutput()) {
            try ctx.output.printJson(DeferResult{
                .success = false,
                .message = "issue not found",
            });
        } else {
            try ctx.output.err("issue not found: {s}", .{undefer_args.id});
        }
        return DeferError.IssueNotFound;
    };

    // Check if not deferred
    if (!issue.status.eql(.deferred)) {
        if (global.isStructuredOutput()) {
            try ctx.output.printJson(DeferResult{
                .success = false,
                .id = undefer_args.id,
                .message = "issue is not deferred",
            });
        } else {
            try ctx.output.warn("issue {s} is not deferred", .{undefer_args.id});
        }
        return;
    }

    // Update the issue - set status back to open and clear defer_until
    const now = std.time.timestamp();
    try ctx.store.update(undefer_args.id, .{
        .status = .open,
        .defer_until = null,
    }, now);

    try ctx.saveIfAutoFlush();

    // Output result
    if (global.isStructuredOutput()) {
        try ctx.output.printJson(DeferResult{
            .success = true,
            .id = undefer_args.id,
        });
    } else {
        try ctx.output.success("Undeferred issue {s}", .{undefer_args.id});
    }
}

/// Parse an "until" date string into an epoch timestamp.
/// Supports:
/// - RFC3339: "2025-02-01T00:00:00Z"
/// - ISO date: "2025-02-01"
/// - Relative: "+7d" (7 days from now), "+2w" (2 weeks), "+1m" (1 month)
fn parseUntilDate(s: []const u8, allocator: std.mem.Allocator) !i64 {
    // Try RFC3339 first
    if (timestamp.parseRfc3339(s)) |ts| {
        return ts;
    }

    // Try ISO date (YYYY-MM-DD)
    if (s.len == 10 and s[4] == '-' and s[7] == '-') {
        const with_time = try std.fmt.allocPrint(allocator, "{s}T00:00:00Z", .{s});
        defer allocator.free(with_time);
        if (timestamp.parseRfc3339(with_time)) |ts| {
            return ts;
        }
    }

    // Try relative format (+Nd, +Nw, +Nm)
    if (s.len >= 2 and s[0] == '+') {
        const unit = s[s.len - 1];
        const count_str = s[1 .. s.len - 1];
        const count = std.fmt.parseInt(i64, count_str, 10) catch return DeferError.InvalidDate;

        const now = std.time.timestamp();
        return switch (unit) {
            'd' => now + count * 24 * 60 * 60,
            'w' => now + count * 7 * 24 * 60 * 60,
            'm' => now + count * 30 * 24 * 60 * 60, // Approximate month
            else => return DeferError.InvalidDate,
        };
    }

    return DeferError.InvalidDate;
}

test "parseUntilDate parses RFC3339" {
    const ts = try parseUntilDate("2025-02-01T12:00:00Z", std.testing.allocator);
    try std.testing.expect(ts > 0);
}

test "parseUntilDate parses ISO date" {
    const ts = try parseUntilDate("2025-02-01", std.testing.allocator);
    try std.testing.expect(ts > 0);
}

test "parseUntilDate parses relative days" {
    const now = std.time.timestamp();
    const ts = try parseUntilDate("+7d", std.testing.allocator);
    // Should be approximately 7 days in the future
    try std.testing.expect(ts > now);
    try std.testing.expect(ts < now + 8 * 24 * 60 * 60);
}

test "parseUntilDate parses relative weeks" {
    const now = std.time.timestamp();
    const ts = try parseUntilDate("+2w", std.testing.allocator);
    // Should be approximately 2 weeks in the future
    try std.testing.expect(ts > now);
    try std.testing.expect(ts < now + 15 * 24 * 60 * 60);
}

test "parseUntilDate rejects invalid format" {
    try std.testing.expectError(DeferError.InvalidDate, parseUntilDate("invalid", std.testing.allocator));
}
