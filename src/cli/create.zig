//! Create and Quick capture commands for beads_zig.
//!
//! - `bz create <title>` - Full issue creation with all optional fields
//! - `bz q <title>` - Quick capture (create + print ID only)

const std = @import("std");
const models = @import("../models/mod.zig");
const storage = @import("../storage/mod.zig");
const id_gen = @import("../id/mod.zig");
const common = @import("common.zig");
const args = @import("args.zig");
const test_util = @import("../test_util.zig");

const Issue = models.Issue;
const Priority = models.Priority;
const IssueType = models.IssueType;
const IssueStore = storage.IssueStore;
const IdGenerator = id_gen.IdGenerator;

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

/// Run the create command.
pub fn run(
    create_args: args.CreateArgs,
    global: args.GlobalOptions,
    allocator: std.mem.Allocator,
) !void {
    var output = common.initOutput(allocator, global);
    const structured_output = global.isStructuredOutput();

    // Validate title
    if (create_args.title.len == 0) {
        try common.outputErrorTyped(CreateResult, &output, structured_output, "title cannot be empty");
        return CreateError.EmptyTitle;
    }
    if (create_args.title.len > 500) {
        try common.outputErrorTyped(CreateResult, &output, structured_output, "title exceeds 500 character limit");
        return CreateError.TitleTooLong;
    }

    // Determine workspace path
    const beads_dir = global.data_path orelse ".beads";
    const issues_path = try std.fs.path.join(allocator, &.{ beads_dir, "issues.jsonl" });
    defer allocator.free(issues_path);

    // Check if workspace is initialized
    std.fs.cwd().access(issues_path, .{}) catch |err| {
        if (err == error.FileNotFound) {
            try common.outputErrorTyped(CreateResult, &output, structured_output, "workspace not initialized. Run 'bz init' first.");
            return CreateError.WorkspaceNotInitialized;
        }
        try common.outputErrorTyped(CreateResult, &output, structured_output, "cannot access workspace");
        return CreateError.StorageError;
    };

    // Load existing issues
    var store = IssueStore.init(allocator, issues_path);
    defer store.deinit();

    store.loadFromFile() catch |err| {
        if (err != error.FileNotFound) {
            try common.outputErrorTyped(CreateResult, &output, structured_output, "failed to load issues");
            return CreateError.StorageError;
        }
    };

    // Parse optional fields
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

    // Get actor (from flag, env, or default)
    const actor = global.actor orelse getDefaultActor();

    // Get config prefix (read from config.yaml or use default)
    const prefix = try getConfigPrefix(allocator, beads_dir);
    defer allocator.free(prefix);

    // Generate ID
    var generator = IdGenerator.init(prefix);
    const issue_count = store.countTotal();
    const issue_id = try generator.generate(allocator, issue_count);
    defer allocator.free(issue_id);

    // Create issue
    const now = std.time.timestamp();
    var issue = Issue.init(issue_id, create_args.title, now);
    issue.description = create_args.description;
    issue.priority = priority;
    issue.issue_type = issue_type;
    issue.assignee = create_args.assignee;
    issue.created_by = actor;
    issue.due_at = .{ .value = due_at };
    issue.estimated_minutes = create_args.estimate;

    // Set labels on issue (will be persisted via WAL)
    if (create_args.labels.len > 0) {
        issue.labels = create_args.labels;
    }

    // Insert into store (for in-memory state and duplicate check)
    store.insert(issue) catch {
        try common.outputErrorTyped(CreateResult, &output, structured_output, "failed to create issue");
        return CreateError.StorageError;
    };

    // Append to WAL for fast persistence (instead of full file rewrite)
    if (!global.no_auto_flush) {
        var wal = storage.Wal.init(beads_dir, allocator) catch {
            try common.outputErrorTyped(CreateResult, &output, structured_output, "failed to initialize WAL");
            return CreateError.StorageError;
        };
        defer wal.deinit();

        wal.addIssue(issue) catch {
            try common.outputErrorTyped(CreateResult, &output, structured_output, "failed to write to WAL");
            return CreateError.StorageError;
        };
    }

    // Output result
    if (structured_output) {
        try output.printJson(CreateResult{
            .success = true,
            .id = issue_id,
            .title = create_args.title,
        });
    } else if (global.quiet) {
        try output.raw(issue_id);
        try output.raw("\n");
    } else {
        try output.success("Created issue {s}", .{issue_id});
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

/// Get the default actor name from environment.
/// On Windows, returns null (env var access requires allocation).
/// Use --actor flag to specify the actor on Windows.
fn getDefaultActor() ?[]const u8 {
    const builtin = @import("builtin");
    if (builtin.os.tag == .windows) return null;
    return std.posix.getenv("USER") orelse std.posix.getenv("USERNAME");
}

/// Read the ID prefix from config.yaml, defaulting to "bd".
fn getConfigPrefix(allocator: std.mem.Allocator, beads_dir: []const u8) ![]u8 {
    const config_path = try std.fs.path.join(allocator, &.{ beads_dir, "config.yaml" });
    defer allocator.free(config_path);

    const file = std.fs.cwd().openFile(config_path, .{}) catch {
        return try allocator.dupe(u8, "bd");
    };
    defer file.close();

    const content = file.readToEndAlloc(allocator, 4096) catch {
        return try allocator.dupe(u8, "bd");
    };
    defer allocator.free(content);

    // Simple YAML parsing for prefix: "value"
    if (std.mem.indexOf(u8, content, "prefix:")) |prefix_pos| {
        const after_prefix = content[prefix_pos + 7 ..];
        // Find the value (skip whitespace, handle quotes)
        var i: usize = 0;
        while (i < after_prefix.len and (after_prefix[i] == ' ' or after_prefix[i] == '\t')) {
            i += 1;
        }

        if (i < after_prefix.len) {
            if (after_prefix[i] == '"') {
                // Quoted value
                i += 1;
                const start = i;
                while (i < after_prefix.len and after_prefix[i] != '"' and after_prefix[i] != '\n') {
                    i += 1;
                }
                if (i > start) {
                    return try allocator.dupe(u8, after_prefix[start..i]);
                }
            } else {
                // Unquoted value
                const start = i;
                while (i < after_prefix.len and after_prefix[i] != '\n' and after_prefix[i] != ' ' and after_prefix[i] != '\t') {
                    i += 1;
                }
                if (i > start) {
                    return try allocator.dupe(u8, after_prefix[start..i]);
                }
            }
        }
    }

    return try allocator.dupe(u8, "bd");
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

test "getConfigPrefix returns default when file missing" {
    const allocator = std.testing.allocator;
    const prefix = try getConfigPrefix(allocator, "/nonexistent/path");
    defer allocator.free(prefix);
    try std.testing.expectEqualStrings("bd", prefix);
}

test "CreateError enum exists" {
    // Just verify the error set compiles
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

    const tmp_dir_path = try test_util.createTestDir(allocator, "create_empty");
    defer allocator.free(tmp_dir_path);
    defer test_util.cleanupTestDir(tmp_dir_path);

    const data_path = try std.fs.path.join(allocator, &.{ tmp_dir_path, ".beads" });
    defer allocator.free(data_path);

    try std.fs.cwd().makeDir(data_path);

    const issues_path = try std.fs.path.join(allocator, &.{ data_path, "issues.jsonl" });
    defer allocator.free(issues_path);

    const f = try std.fs.cwd().createFile(issues_path, .{});
    f.close();

    const create_args = args.CreateArgs{ .title = "" };
    const global = args.GlobalOptions{ .silent = true, .data_path = data_path };

    const result = run(create_args, global, allocator);
    try std.testing.expectError(CreateError.EmptyTitle, result);
}

test "run validates title length" {
    const allocator = std.testing.allocator;

    const tmp_dir_path = try test_util.createTestDir(allocator, "create_long");
    defer allocator.free(tmp_dir_path);
    defer test_util.cleanupTestDir(tmp_dir_path);

    const data_path = try std.fs.path.join(allocator, &.{ tmp_dir_path, ".beads" });
    defer allocator.free(data_path);

    try std.fs.cwd().makeDir(data_path);

    const issues_path = try std.fs.path.join(allocator, &.{ data_path, "issues.jsonl" });
    defer allocator.free(issues_path);

    const f = try std.fs.cwd().createFile(issues_path, .{});
    f.close();

    const long_title = "x" ** 501;
    const create_args = args.CreateArgs{ .title = long_title };
    const global = args.GlobalOptions{ .silent = true, .data_path = data_path };

    const result = run(create_args, global, allocator);
    try std.testing.expectError(CreateError.TitleTooLong, result);
}

test "run creates issue successfully" {
    const allocator = std.testing.allocator;

    const tmp_dir_path = try test_util.createTestDir(allocator, "create_success");
    defer allocator.free(tmp_dir_path);
    defer test_util.cleanupTestDir(tmp_dir_path);

    const data_path = try std.fs.path.join(allocator, &.{ tmp_dir_path, ".beads" });
    defer allocator.free(data_path);

    try std.fs.cwd().makeDir(data_path);

    const issues_path = try std.fs.path.join(allocator, &.{ data_path, "issues.jsonl" });
    defer allocator.free(issues_path);

    const f = try std.fs.cwd().createFile(issues_path, .{});
    f.close();

    const create_args = args.CreateArgs{
        .title = "Test issue",
        .description = "A description",
        .priority = "high",
        .issue_type = "bug",
    };
    const global = args.GlobalOptions{ .silent = true, .data_path = data_path };

    try run(create_args, global, allocator);

    // Verify issue was created by loading via IssueStore (which replays WAL)
    var store = IssueStore.init(allocator, issues_path);
    defer store.deinit();
    try store.loadFromFile();

    // Replay WAL to get the created issue
    var wal = try storage.Wal.init(data_path, allocator);
    defer wal.deinit();
    _ = try wal.replay(&store);

    // Find the created issue
    const issues = store.getAllRef();
    try std.testing.expect(issues.len > 0);

    var found = false;
    for (issues) |issue| {
        if (std.mem.indexOf(u8, issue.title, "Test issue") != null) {
            found = true;
            try std.testing.expectEqual(models.IssueType.bug, issue.issue_type);
            break;
        }
    }
    try std.testing.expect(found);
}

test "run detects uninitialized workspace" {
    const allocator = std.testing.allocator;

    const create_args = args.CreateArgs{ .title = "Test" };
    const global = args.GlobalOptions{ .silent = true, .data_path = "/nonexistent/path" };

    const result = run(create_args, global, allocator);
    try std.testing.expectError(CreateError.WorkspaceNotInitialized, result);
}
