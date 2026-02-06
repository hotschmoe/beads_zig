//! Create and Quick capture commands for beads_zig.
//!
//! - `bz create <title>` - Full issue creation with all optional fields
//! - `bz q <title>` - Quick capture (create + print ID only)

const std = @import("std");
const models = @import("../models/mod.zig");
const storage = @import("../storage/mod.zig");
const common = @import("common.zig");
const args = @import("args.zig");
const test_util = @import("../test_util.zig");
const Event = @import("../models/event.zig").Event;

const Issue = models.Issue;
const Priority = models.Priority;
const IssueType = models.IssueType;
const IdGenerator = common.IdGenerator;
const CommandContext = common.CommandContext;

pub const CreateError = error{
    EmptyTitle,
    TitleTooLong,
    InvalidPriority,
    InvalidIssueType,
    WorkspaceNotInitialized,
    StorageError,
    OutOfMemory,
};

pub const CreateResult = struct {
    success: bool,
    id: ?[]const u8 = null,
    title: ?[]const u8 = null,
    message: ?[]const u8 = null,
};

pub const DryRunResult = struct {
    dry_run: bool = true,
    would_create: struct {
        id: []const u8,
        title: []const u8,
        issue_type: []const u8,
        priority: []const u8,
        assignee: ?[]const u8 = null,
        labels: []const []const u8 = &[_][]const u8{},
    },
};

/// Run the create command.
pub fn run(
    create_args: args.CreateArgs,
    global: args.GlobalOptions,
    allocator: std.mem.Allocator,
) !void {
    var output = common.initOutput(allocator, global);
    const structured_output = global.isStructuredOutput();

    // Handle --file flag (not yet implemented)
    if (create_args.file != null) {
        if (structured_output) {
            try common.outputErrorTyped(CreateResult, &output, structured_output, "markdown import not yet implemented");
        } else {
            try output.err("markdown import not yet implemented", .{});
        }
        return;
    }

    // Validate title
    if (create_args.title.len == 0) {
        try common.outputErrorTyped(CreateResult, &output, structured_output, "title cannot be empty");
        return CreateError.EmptyTitle;
    }
    if (create_args.title.len > 500) {
        try common.outputErrorTyped(CreateResult, &output, structured_output, "title exceeds 500 character limit");
        return CreateError.TitleTooLong;
    }

    // Parse optional fields early (before opening DB)
    const priority = if (create_args.priority) |p|
        Priority.fromString(p) catch {
            try common.outputErrorTyped(CreateResult, &output, structured_output, "invalid priority value");
            return CreateError.InvalidPriority;
        }
    else
        Priority.MEDIUM;

    const issue_type = if (create_args.issue_type) |t|
        IssueType.fromString(t)
    else
        .task;

    // Parse due date if provided
    const due_at: ?i64 = if (create_args.due) |due_str|
        parseDateString(due_str)
    else
        null;

    // Open workspace
    var ctx = (try CommandContext.init(allocator, global)) orelse {
        return CreateError.WorkspaceNotInitialized;
    };
    defer ctx.deinit();

    // Get actor (from flag, env, or default)
    const actor = global.actor orelse common.getDefaultActor();

    // Get config prefix (read from config.yaml or use default)
    const prefix = try common.getConfigPrefix(allocator, ctx.beads_dir);
    defer allocator.free(prefix);

    // Generate ID with collision checking via SQLite exists()
    var generator = IdGenerator.init(prefix);
    const issue_id = try common.generateUniqueId(allocator, &generator, &ctx.issue_store);
    defer allocator.free(issue_id);

    // Create issue
    const now = std.time.timestamp();
    var issue = Issue.init(issue_id, create_args.title, now);
    issue.description = create_args.description;
    issue.priority = priority;
    issue.issue_type = issue_type;
    issue.assignee = create_args.assignee;
    issue.owner = create_args.owner;
    issue.design = create_args.design;
    issue.acceptance_criteria = create_args.acceptance_criteria;
    issue.external_ref = create_args.external_ref;
    issue.created_by = actor;
    issue.due_at = .{ .value = due_at };
    issue.estimated_minutes = create_args.estimate;
    issue.ephemeral = create_args.ephemeral;

    // Handle --status flag
    if (create_args.status) |status_str| {
        const status = @import("../models/status.zig").Status.fromString(status_str);
        issue.status = status;
        if (status == .closed or status == .tombstone) {
            issue.closed_at = .{ .value = now };
        }
    }

    // Handle --defer flag
    if (create_args.defer_until) |defer_str| {
        if (parseDateString(defer_str)) |defer_ts| {
            issue.defer_until = .{ .value = defer_ts };
            // If no explicit status set, auto-set to deferred
            if (create_args.status == null) {
                issue.status = .deferred;
            }
        }
    }

    // Dry-run mode: preview without persisting
    if (create_args.dry_run) {
        if (structured_output) {
            try ctx.output.printJson(DryRunResult{
                .would_create = .{
                    .id = issue_id,
                    .title = create_args.title,
                    .issue_type = issue_type.toString(),
                    .priority = priority.toString(),
                    .assignee = create_args.assignee,
                    .labels = create_args.labels,
                },
            });
        } else {
            try ctx.output.info("Would create: {s} \"{s}\" ({s}, {s})", .{
                issue_id,
                create_args.title,
                issue_type.toString(),
                priority.toString(),
            });
        }
        return;
    }

    // Insert into SQLite
    ctx.issue_store.insert(issue) catch {
        try common.outputErrorTyped(CreateResult, &ctx.output, structured_output, "failed to create issue");
        return CreateError.StorageError;
    };

    // Add labels if provided
    if (create_args.labels.len > 0) {
        for (create_args.labels) |label| {
            ctx.issue_store.addLabel(issue_id, label) catch {};
        }
    }

    // Add dependencies if provided
    if (create_args.deps.len > 0) {
        for (create_args.deps) |dep_id| {
            if (try ctx.issue_store.exists(dep_id)) {
                ctx.dep_store.add(issue_id, dep_id, .blocks, actor, now) catch {};
            }
        }
    }

    // Handle --parent flag (create parent_child dependency)
    if (create_args.parent) |parent_id| {
        if (try ctx.issue_store.exists(parent_id)) {
            ctx.dep_store.add(issue_id, parent_id, .parent_child, actor, now) catch {};
        }
    }

    // Record audit event
    const event_actor = actor orelse "unknown";
    ctx.recordEvent(Event.issueCreated(issue_id, event_actor, now));

    // Output result
    if (structured_output) {
        try ctx.output.printJson(CreateResult{
            .success = true,
            .id = issue_id,
            .title = create_args.title,
        });
    } else if (global.quiet or create_args.silent) {
        try ctx.output.raw(issue_id);
        try ctx.output.raw("\n");
    } else {
        try ctx.output.success("Created {s}: {s}", .{ issue_id, create_args.title });
    }
}

/// Run the quick capture command (create + print ID only).
pub fn runQuick(
    quick_args: args.QuickArgs,
    global: args.GlobalOptions,
    allocator: std.mem.Allocator,
) !void {
    // Convert QuickArgs to CreateArgs
    const create_args = args.CreateArgs{
        .title = quick_args.title,
        .priority = quick_args.priority,
    };

    // Force quiet mode for q command unless structured output is specified
    var modified_global = global;
    if (!global.isStructuredOutput()) {
        modified_global.quiet = true;
    }

    try run(create_args, modified_global, allocator);
}

/// Parse a date string in various formats to Unix timestamp.
/// Supports: YYYY-MM-DD, YYYY-MM-DDTHH:MM:SSZ
fn parseDateString(date_str: []const u8) ?i64 {
    // Try RFC3339 format first
    if (@import("../models/timestamp.zig").parseRfc3339(date_str)) |ts| {
        return ts;
    }

    // Try YYYY-MM-DD format
    if (date_str.len == 10 and date_str[4] == '-' and date_str[7] == '-') {
        const year = std.fmt.parseInt(i32, date_str[0..4], 10) catch return null;
        const month = std.fmt.parseInt(u4, date_str[5..7], 10) catch return null;
        const day = std.fmt.parseInt(u5, date_str[8..10], 10) catch return null;

        if (month < 1 or month > 12) return null;
        if (day < 1 or day > 31) return null;

        // Convert to days since epoch
        const epoch_day = epochDayFromYMD(year, month, day) catch return null;

        // Convert to seconds (midnight UTC)
        return @as(i64, epoch_day) * 86400;
    }

    return null;
}

/// Calculate epoch day from year/month/day.
fn epochDayFromYMD(year: i32, month: u4, day: u5) !i32 {
    // Algorithm from Howard Hinnant's date algorithms
    const y: i32 = if (month <= 2) year - 1 else year;
    const era: i32 = @divTrunc(if (y >= 0) y else y - 399, 400);
    const yoe: u32 = @intCast(y - era * 400);
    const m: u32 = month;
    const doy: u32 = (153 * (if (m > 2) m - 3 else m + 9) + 2) / 5 + day - 1;
    const doe: u32 = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    return era * 146097 + @as(i32, @intCast(doe)) - 719468;
}

// --- Tests ---

test "parseDateString parses YYYY-MM-DD" {
    const result = parseDateString("2024-01-29");
    try std.testing.expect(result != null);
    // 2024-01-29 00:00:00 UTC should be around 1706486400
    const ts = result.?;
    try std.testing.expect(ts > 1706400000 and ts < 1706600000);
}

test "parseDateString parses RFC3339" {
    const result = parseDateString("2024-01-29T14:53:20Z");
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(i64, 1706540000), result.?);
}

test "parseDateString returns null for invalid format" {
    try std.testing.expect(parseDateString("invalid") == null);
    try std.testing.expect(parseDateString("01-29-2024") == null);
    try std.testing.expect(parseDateString("2024/01/29") == null);
}

test "CreateError enum exists" {
    const err: CreateError = CreateError.EmptyTitle;
    try std.testing.expect(err == CreateError.EmptyTitle);
}

test "CreateResult struct works" {
    const result = CreateResult{
        .success = true,
        .id = "bd-abc123",
        .title = "Test issue",
    };
    try std.testing.expect(result.success);
    try std.testing.expectEqualStrings("bd-abc123", result.id.?);
}

test "run validates empty title" {
    const allocator = std.testing.allocator;
    const create_args = args.CreateArgs{ .title = "" };
    const global = args.GlobalOptions{ .silent = true, .data_path = "/nonexistent/path" };

    const result = run(create_args, global, allocator);
    try std.testing.expectError(CreateError.EmptyTitle, result);
}

test "run validates title length" {
    const allocator = std.testing.allocator;
    const long_title = "x" ** 501;
    const create_args = args.CreateArgs{ .title = long_title };
    const global = args.GlobalOptions{ .silent = true, .data_path = "/nonexistent/path" };

    const result = run(create_args, global, allocator);
    try std.testing.expectError(CreateError.TitleTooLong, result);
}

test "run detects uninitialized workspace" {
    const allocator = std.testing.allocator;

    const create_args = args.CreateArgs{ .title = "Test" };
    const global = args.GlobalOptions{ .silent = true, .data_path = "/nonexistent/path" };

    const result = run(create_args, global, allocator);
    try std.testing.expectError(CreateError.WorkspaceNotInitialized, result);
}

test "run creates issue successfully" {
    const allocator = std.testing.allocator;

    const tmp_dir_path = try test_util.createTestDir(allocator, "create_success");
    defer allocator.free(tmp_dir_path);
    defer test_util.cleanupTestDir(tmp_dir_path);

    const data_path = try std.fs.path.join(allocator, &.{ tmp_dir_path, ".beads" });
    defer allocator.free(data_path);

    // Initialize workspace (creates dir, db, schema)
    const init_mod = @import("init.zig");
    try init_mod.run(.{ .prefix = "bd" }, .{ .silent = true, .data_path = data_path }, allocator);

    const create_args = args.CreateArgs{
        .title = "Test issue",
        .description = "A description",
        .priority = "high",
        .issue_type = "bug",
    };
    const global = args.GlobalOptions{ .silent = true, .data_path = data_path };

    try run(create_args, global, allocator);

    // Verify issue was created by opening db and checking
    const db_path = try std.fs.path.join(allocator, &.{ data_path, "beads.db" });
    defer allocator.free(db_path);

    var db = try storage.SqlDatabase.open(allocator, db_path);
    defer db.close();

    var issue_store = storage.IssueStore.init(&db, allocator);
    const issues = try issue_store.list(.{});
    defer {
        for (issues) |*iss| {
            var i = @constCast(iss);
            i.deinit(allocator);
        }
        allocator.free(issues);
    }

    try std.testing.expect(issues.len > 0);
    var found = false;
    for (issues) |iss| {
        if (std.mem.indexOf(u8, iss.title, "Test issue") != null) {
            found = true;
            try std.testing.expectEqual(models.IssueType.bug, iss.issue_type);
            break;
        }
    }
    try std.testing.expect(found);
}
