//! Output formatting for beads_zig.
//!
//! Provides a unified interface for displaying output in different modes:
//! - plain: No colors, basic formatting (default for non-TTY)
//! - rich: Colors and formatting (default for TTY)
//! - json: Structured JSON output for machine consumption
//! - quiet: Minimal output (IDs only)
//!
//! Respects NO_COLOR environment variable and --no-color flag.

const std = @import("std");
const models = @import("../models/mod.zig");
const Issue = models.Issue;
const Status = models.Status;
const Priority = models.Priority;
const IssueType = models.IssueType;

/// Output mode determines formatting and verbosity.
pub const OutputMode = enum {
    plain, // No colors, basic formatting
    rich, // Colors and formatting (TTY)
    json, // Structured JSON output
    quiet, // Minimal output (IDs only)
};

/// ANSI color escape codes.
pub const Color = struct {
    pub const reset = "\x1b[0m";
    pub const bold = "\x1b[1m";
    pub const dim = "\x1b[2m";
    pub const italic = "\x1b[3m";
    pub const underline = "\x1b[4m";

    pub const red = "\x1b[31m";
    pub const green = "\x1b[32m";
    pub const yellow = "\x1b[33m";
    pub const blue = "\x1b[34m";
    pub const magenta = "\x1b[35m";
    pub const cyan = "\x1b[36m";
    pub const white = "\x1b[37m";
    pub const gray = "\x1b[90m";

    pub const bright_red = "\x1b[91m";
    pub const bright_green = "\x1b[92m";
    pub const bright_yellow = "\x1b[93m";
    pub const bright_blue = "\x1b[94m";
    pub const bright_magenta = "\x1b[95m";
    pub const bright_cyan = "\x1b[96m";

    pub const bg_red = "\x1b[41m";
    pub const bg_green = "\x1b[42m";
    pub const bg_yellow = "\x1b[43m";
    pub const bg_blue = "\x1b[44m";
};

/// Global options that affect output formatting.
/// This mirrors the relevant fields from cli.args.GlobalOptions.
pub const OutputOptions = struct {
    json: bool = false,
    quiet: bool = false,
    no_color: bool = false,
};

/// Output formatter for consistent CLI output across all modes.
pub const Output = struct {
    mode: OutputMode,
    stdout: std.fs.File,
    stderr: std.fs.File,
    allocator: std.mem.Allocator,

    const Self = @This();

    /// Initialize output formatter based on global options and TTY detection.
    pub fn init(allocator: std.mem.Allocator, opts: OutputOptions) Self {
        const stdout = std.fs.File.stdout();
        const stderr = std.fs.File.stderr();

        var mode: OutputMode = .plain;
        if (opts.json) {
            mode = .json;
        } else if (opts.quiet) {
            mode = .quiet;
        } else if (!opts.no_color and !checkNoColorEnv() and stdout.isTty()) {
            mode = .rich;
        }

        return .{
            .mode = mode,
            .stdout = stdout,
            .stderr = stderr,
            .allocator = allocator,
        };
    }

    /// Initialize with explicit mode (useful for testing).
    pub fn initWithMode(allocator: std.mem.Allocator, mode: OutputMode) Self {
        return .{
            .mode = mode,
            .stdout = std.fs.File.stdout(),
            .stderr = std.fs.File.stderr(),
            .allocator = allocator,
        };
    }

    /// Initialize for testing with custom file handles.
    pub fn initForTesting(allocator: std.mem.Allocator, mode: OutputMode, stdout: std.fs.File, stderr: std.fs.File) Self {
        return .{
            .mode = mode,
            .stdout = stdout,
            .stderr = stderr,
            .allocator = allocator,
        };
    }

    // ========================================================================
    // Issue Display
    // ========================================================================

    /// Print a single issue in the appropriate format.
    pub fn printIssue(self: *Self, issue: Issue) !void {
        switch (self.mode) {
            .json => try self.printIssueJson(issue),
            .quiet => try self.printIssueQuiet(issue),
            .rich => try self.printIssueRich(issue),
            .plain => try self.printIssuePlain(issue),
        }
    }

    /// Print a list of issues in the appropriate format.
    pub fn printIssueList(self: *Self, issues: []const Issue) !void {
        switch (self.mode) {
            .json => try self.printIssueListJson(issues),
            .quiet => try self.printIssueListQuiet(issues),
            .rich => try self.printIssueListRich(issues),
            .plain => try self.printIssueListPlain(issues),
        }
    }

    // ========================================================================
    // Generic Messages
    // ========================================================================

    /// Print a formatted message to stdout.
    pub fn print(self: *Self, comptime fmt: []const u8, args: anytype) !void {
        if (self.mode == .quiet) return;
        const msg = try std.fmt.allocPrint(self.allocator, fmt, args);
        defer self.allocator.free(msg);
        try self.stdout.writeAll(msg);
    }

    /// Print a formatted message to stdout with newline.
    pub fn println(self: *Self, comptime fmt: []const u8, args: anytype) !void {
        if (self.mode == .quiet) return;
        const msg = try std.fmt.allocPrint(self.allocator, fmt ++ "\n", args);
        defer self.allocator.free(msg);
        try self.stdout.writeAll(msg);
    }

    /// Print a success message (green in rich mode).
    pub fn success(self: *Self, comptime fmt: []const u8, args: anytype) !void {
        if (self.mode == .quiet) return;
        if (self.mode == .rich) try self.stdout.writeAll(Color.green);
        const msg = try std.fmt.allocPrint(self.allocator, fmt, args);
        defer self.allocator.free(msg);
        try self.stdout.writeAll(msg);
        if (self.mode == .rich) try self.stdout.writeAll(Color.reset);
        try self.stdout.writeAll("\n");
    }

    /// Print an error message to stderr (red in rich mode).
    pub fn err(self: *Self, comptime fmt: []const u8, args: anytype) !void {
        if (self.mode == .rich) try self.stderr.writeAll(Color.red);
        const msg = try std.fmt.allocPrint(self.allocator, "error: " ++ fmt, args);
        defer self.allocator.free(msg);
        try self.stderr.writeAll(msg);
        if (self.mode == .rich) try self.stderr.writeAll(Color.reset);
        try self.stderr.writeAll("\n");
    }

    /// Print a warning message to stderr (yellow in rich mode).
    pub fn warn(self: *Self, comptime fmt: []const u8, args: anytype) !void {
        if (self.mode == .quiet) return;
        if (self.mode == .rich) try self.stderr.writeAll(Color.yellow);
        const msg = try std.fmt.allocPrint(self.allocator, "warning: " ++ fmt, args);
        defer self.allocator.free(msg);
        try self.stderr.writeAll(msg);
        if (self.mode == .rich) try self.stderr.writeAll(Color.reset);
        try self.stderr.writeAll("\n");
    }

    /// Print an info message (cyan in rich mode).
    pub fn info(self: *Self, comptime fmt: []const u8, args: anytype) !void {
        if (self.mode == .quiet) return;
        if (self.mode == .rich) try self.stdout.writeAll(Color.cyan);
        const msg = try std.fmt.allocPrint(self.allocator, fmt, args);
        defer self.allocator.free(msg);
        try self.stdout.writeAll(msg);
        if (self.mode == .rich) try self.stdout.writeAll(Color.reset);
        try self.stdout.writeAll("\n");
    }

    /// Print raw bytes to stdout (bypasses mode checks).
    pub fn raw(self: *Self, bytes: []const u8) !void {
        try self.stdout.writeAll(bytes);
    }

    /// Print raw JSON value to stdout (for JSON mode).
    pub fn printJson(self: *Self, value: anytype) !void {
        const json_bytes = try std.json.Stringify.valueAlloc(self.allocator, value, .{});
        defer self.allocator.free(json_bytes);
        try self.stdout.writeAll(json_bytes);
        try self.stdout.writeAll("\n");
    }

    // ========================================================================
    // JSON Mode Helpers
    // ========================================================================

    fn printIssueJson(self: *Self, issue: Issue) !void {
        try self.printJson(issue);
    }

    fn printIssueListJson(self: *Self, issues: []const Issue) !void {
        try self.printJson(issues);
    }

    // ========================================================================
    // Plain Mode Helpers
    // ========================================================================

    fn printIssuePlain(self: *Self, issue: Issue) !void {
        try self.writeFormatted("ID: {s}\n", .{issue.id});
        try self.writeFormatted("Title: {s}\n", .{issue.title});
        try self.writeFormatted("Status: {s}\n", .{issue.status.toString()});
        try self.writeFormatted("Priority: {s}\n", .{issue.priority.toString()});
        try self.writeFormatted("Type: {s}\n", .{issue.issue_type.toString()});

        if (issue.description) |desc| {
            try self.writeFormatted("Description: {s}\n", .{desc});
        }
        if (issue.assignee) |assignee| {
            try self.writeFormatted("Assignee: {s}\n", .{assignee});
        }
        if (issue.labels.len > 0) {
            try self.stdout.writeAll("Labels: ");
            for (issue.labels, 0..) |label, i| {
                if (i > 0) try self.stdout.writeAll(", ");
                try self.stdout.writeAll(label);
            }
            try self.stdout.writeAll("\n");
        }
        if (issue.due_at.value) |due| {
            try self.writeFormatted("Due: {d}\n", .{due});
        }

        try self.writeFormatted("Created: {d}\n", .{issue.created_at.value});
        try self.writeFormatted("Updated: {d}\n", .{issue.updated_at.value});
    }

    fn printIssueListPlain(self: *Self, issues: []const Issue) !void {
        for (issues) |issue| {
            const status_abbrev = abbreviateStatus(issue.status);
            try self.writeFormatted("{s}  [{s}] {s}\n", .{
                issue.id,
                status_abbrev,
                issue.title,
            });
        }
    }

    // ========================================================================
    // Rich Mode Helpers (ANSI colors)
    // ========================================================================

    fn printIssueRich(self: *Self, issue: Issue) !void {
        // Bold ID
        try self.writeFormatted("{s}{s}{s}\n", .{ Color.bold, issue.id, Color.reset });

        // Title
        try self.writeFormatted("  {s}\n", .{issue.title});

        // Status with color
        const status_color = getStatusColor(issue.status);
        try self.writeFormatted("  Status: {s}{s}{s}\n", .{ status_color, issue.status.toString(), Color.reset });

        // Priority with color
        const priority_color = getPriorityColor(issue.priority);
        try self.writeFormatted("  Priority: {s}{s}{s}\n", .{ priority_color, issue.priority.toString(), Color.reset });

        // Type
        try self.writeFormatted("  Type: {s}\n", .{issue.issue_type.toString()});

        // Optional fields
        if (issue.description) |desc| {
            try self.writeFormatted("  Description: {s}{s}{s}\n", .{ Color.dim, desc, Color.reset });
        }
        if (issue.assignee) |assignee| {
            try self.writeFormatted("  Assignee: {s}{s}{s}\n", .{ Color.cyan, assignee, Color.reset });
        }
        if (issue.labels.len > 0) {
            try self.stdout.writeAll("  Labels: ");
            for (issue.labels, 0..) |label, i| {
                if (i > 0) try self.stdout.writeAll(", ");
                try self.writeFormatted("{s}{s}{s}", .{ Color.magenta, label, Color.reset });
            }
            try self.stdout.writeAll("\n");
        }
    }

    fn printIssueListRich(self: *Self, issues: []const Issue) !void {
        for (issues) |issue| {
            const status_color = getStatusColor(issue.status);
            const priority_color = getPriorityColor(issue.priority);
            const status_abbrev = abbreviateStatus(issue.status);

            try self.writeFormatted("{s}{s}{s}  {s}[{s}]{s}  {s}{s}{s}  {s}\n", .{
                Color.bold,
                issue.id,
                Color.reset,
                status_color,
                status_abbrev,
                Color.reset,
                priority_color,
                priorityIndicator(issue.priority),
                Color.reset,
                issue.title,
            });
        }
    }

    // ========================================================================
    // Quiet Mode Helpers
    // ========================================================================

    fn printIssueQuiet(self: *Self, issue: Issue) !void {
        try self.writeFormatted("{s}\n", .{issue.id});
    }

    fn printIssueListQuiet(self: *Self, issues: []const Issue) !void {
        for (issues) |issue| {
            try self.writeFormatted("{s}\n", .{issue.id});
        }
    }

    // ========================================================================
    // Internal Helpers
    // ========================================================================

    fn writeFormatted(self: *Self, comptime fmt: []const u8, args: anytype) !void {
        const msg = try std.fmt.allocPrint(self.allocator, fmt, args);
        defer self.allocator.free(msg);
        try self.stdout.writeAll(msg);
    }
};

// ============================================================================
// Helper Functions
// ============================================================================

/// Check if NO_COLOR environment variable is set.
fn checkNoColorEnv() bool {
    return std.posix.getenv("NO_COLOR") != null;
}

/// Get ANSI color for a status.
fn getStatusColor(status: Status) []const u8 {
    return switch (status) {
        .open => Color.green,
        .in_progress => Color.yellow,
        .blocked => Color.red,
        .deferred => Color.gray,
        .closed => Color.gray,
        .tombstone => Color.dim,
        .pinned => Color.bright_cyan,
        .custom => Color.blue,
    };
}

/// Get ANSI color for a priority.
fn getPriorityColor(priority: Priority) []const u8 {
    return switch (priority.value) {
        0 => Color.bright_red, // critical
        1 => Color.red, // high
        2 => Color.yellow, // medium
        3 => Color.green, // low
        4 => Color.gray, // backlog
        else => Color.reset,
    };
}

/// Get short status abbreviation.
fn abbreviateStatus(status: Status) []const u8 {
    return switch (status) {
        .open => "OPEN",
        .in_progress => "PROG",
        .blocked => "BLKD",
        .deferred => "DEFR",
        .closed => "DONE",
        .tombstone => "DEL ",
        .pinned => "PIN ",
        .custom => "CUST",
    };
}

/// Get priority indicator symbol.
fn priorityIndicator(priority: Priority) []const u8 {
    return switch (priority.value) {
        0 => "!!!",
        1 => "!! ",
        2 => "!  ",
        3 => ".  ",
        4 => "   ",
        else => "   ",
    };
}

// ============================================================================
// Tests
// ============================================================================

test "OutputMode enum values" {
    try std.testing.expectEqual(OutputMode.plain, OutputMode.plain);
    try std.testing.expectEqual(OutputMode.rich, OutputMode.rich);
    try std.testing.expectEqual(OutputMode.json, OutputMode.json);
    try std.testing.expectEqual(OutputMode.quiet, OutputMode.quiet);
}

test "Output.init with json option" {
    const allocator = std.testing.allocator;
    const opts = OutputOptions{ .json = true };
    const output = Output.init(allocator, opts);
    try std.testing.expectEqual(OutputMode.json, output.mode);
}

test "Output.init with quiet option" {
    const allocator = std.testing.allocator;
    const opts = OutputOptions{ .quiet = true };
    const output = Output.init(allocator, opts);
    try std.testing.expectEqual(OutputMode.quiet, output.mode);
}

test "Output.init with no_color option forces plain mode" {
    const allocator = std.testing.allocator;
    const opts = OutputOptions{ .no_color = true };
    const output = Output.init(allocator, opts);
    try std.testing.expectEqual(OutputMode.plain, output.mode);
}

test "Output.init json overrides quiet" {
    const allocator = std.testing.allocator;
    const opts = OutputOptions{ .json = true, .quiet = true };
    const output = Output.init(allocator, opts);
    try std.testing.expectEqual(OutputMode.json, output.mode);
}

test "Output.initWithMode sets explicit mode" {
    const allocator = std.testing.allocator;
    const output = Output.initWithMode(allocator, .rich);
    try std.testing.expectEqual(OutputMode.rich, output.mode);
}

test "abbreviateStatus returns 4-char strings" {
    const statuses = [_]Status{
        .open,
        .in_progress,
        .blocked,
        .deferred,
        .closed,
        .tombstone,
        .pinned,
        .{ .custom = "test" },
    };
    for (statuses) |status| {
        const abbrev = abbreviateStatus(status);
        try std.testing.expectEqual(@as(usize, 4), abbrev.len);
    }
}

test "priorityIndicator returns 3-char strings" {
    var p: u3 = 0;
    while (p <= 4) : (p += 1) {
        const priority = Priority{ .value = p };
        const indicator = priorityIndicator(priority);
        try std.testing.expectEqual(@as(usize, 3), indicator.len);
    }
}

test "getStatusColor returns valid ANSI codes" {
    const statuses = [_]Status{
        .open,
        .in_progress,
        .blocked,
        .deferred,
        .closed,
        .tombstone,
        .pinned,
        .{ .custom = "test" },
    };
    for (statuses) |status| {
        const color = getStatusColor(status);
        try std.testing.expect(color.len > 0);
        try std.testing.expect(std.mem.startsWith(u8, color, "\x1b["));
    }
}

test "getPriorityColor returns valid ANSI codes" {
    var p: u3 = 0;
    while (p <= 4) : (p += 1) {
        const priority = Priority{ .value = p };
        const color = getPriorityColor(priority);
        try std.testing.expect(color.len > 0);
        try std.testing.expect(std.mem.startsWith(u8, color, "\x1b["));
    }
}

test "Color constants are valid ANSI escape sequences" {
    try std.testing.expect(std.mem.startsWith(u8, Color.reset, "\x1b["));
    try std.testing.expect(std.mem.startsWith(u8, Color.bold, "\x1b["));
    try std.testing.expect(std.mem.startsWith(u8, Color.red, "\x1b["));
    try std.testing.expect(std.mem.startsWith(u8, Color.green, "\x1b["));
    try std.testing.expect(std.mem.startsWith(u8, Color.yellow, "\x1b["));
    try std.testing.expect(std.mem.startsWith(u8, Color.blue, "\x1b["));
    try std.testing.expect(std.mem.startsWith(u8, Color.gray, "\x1b["));
}

test "Output printIssueListQuiet writes IDs only" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const stdout_file = try tmp.dir.createFile("stdout.txt", .{ .read = true });
    defer stdout_file.close();

    const stderr_file = try tmp.dir.createFile("stderr.txt", .{ .read = true });
    defer stderr_file.close();

    var output = Output.initForTesting(allocator, .quiet, stdout_file, stderr_file);

    const issue1 = Issue.init("bd-abc123", "Test issue 1", 1706540000);
    const issue2 = Issue.init("bd-def456", "Test issue 2", 1706540000);
    const issues = [_]Issue{ issue1, issue2 };

    try output.printIssueList(&issues);

    try stdout_file.seekTo(0);
    const content = try stdout_file.readToEndAlloc(allocator, 4096);
    defer allocator.free(content);

    try std.testing.expectEqualStrings("bd-abc123\nbd-def456\n", content);
}

test "Output printIssueListPlain writes formatted lines" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const stdout_file = try tmp.dir.createFile("stdout.txt", .{ .read = true });
    defer stdout_file.close();

    const stderr_file = try tmp.dir.createFile("stderr.txt", .{ .read = true });
    defer stderr_file.close();

    var output = Output.initForTesting(allocator, .plain, stdout_file, stderr_file);

    const issue = Issue.init("bd-abc123", "Test issue", 1706540000);
    const issues = [_]Issue{issue};

    try output.printIssueList(&issues);

    try stdout_file.seekTo(0);
    const content = try stdout_file.readToEndAlloc(allocator, 4096);
    defer allocator.free(content);

    try std.testing.expect(std.mem.indexOf(u8, content, "bd-abc123") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "OPEN") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "Test issue") != null);
}

test "Output printIssueListRich includes ANSI codes" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const stdout_file = try tmp.dir.createFile("stdout.txt", .{ .read = true });
    defer stdout_file.close();

    const stderr_file = try tmp.dir.createFile("stderr.txt", .{ .read = true });
    defer stderr_file.close();

    var output = Output.initForTesting(allocator, .rich, stdout_file, stderr_file);

    const issue = Issue.init("bd-abc123", "Test issue", 1706540000);
    const issues = [_]Issue{issue};

    try output.printIssueList(&issues);

    try stdout_file.seekTo(0);
    const content = try stdout_file.readToEndAlloc(allocator, 4096);
    defer allocator.free(content);

    try std.testing.expect(std.mem.indexOf(u8, content, "\x1b[") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "bd-abc123") != null);
}

test "Output printIssueListJson produces valid JSON array" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const stdout_file = try tmp.dir.createFile("stdout.txt", .{ .read = true });
    defer stdout_file.close();

    const stderr_file = try tmp.dir.createFile("stderr.txt", .{ .read = true });
    defer stderr_file.close();

    var output = Output.initForTesting(allocator, .json, stdout_file, stderr_file);

    const issue1 = Issue.init("bd-abc123", "Test issue 1", 1706540000);
    const issue2 = Issue.init("bd-def456", "Test issue 2", 1706540000);
    const issues = [_]Issue{ issue1, issue2 };

    try output.printIssueList(&issues);

    try stdout_file.seekTo(0);
    const content = try stdout_file.readToEndAlloc(allocator, 8192);
    defer allocator.free(content);

    // Verify it starts with [ and contains expected data
    try std.testing.expect(std.mem.startsWith(u8, content, "["));
    try std.testing.expect(std.mem.indexOf(u8, content, "bd-abc123") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "bd-def456") != null);

    // Verify it can be parsed as JSON
    const trimmed = std.mem.trimRight(u8, content, "\n");
    const parsed = try std.json.parseFromSlice([]const Issue, allocator, trimmed, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 2), parsed.value.len);
}

test "Output.err writes to stderr" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const stdout_file = try tmp.dir.createFile("stdout.txt", .{ .read = true });
    defer stdout_file.close();

    const stderr_file = try tmp.dir.createFile("stderr.txt", .{ .read = true });
    defer stderr_file.close();

    var output = Output.initForTesting(allocator, .plain, stdout_file, stderr_file);

    try output.err("something went wrong: {s}", .{"test error"});

    try stderr_file.seekTo(0);
    const content = try stderr_file.readToEndAlloc(allocator, 4096);
    defer allocator.free(content);

    try std.testing.expect(std.mem.indexOf(u8, content, "error:") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "test error") != null);
}

test "Output.warn writes to stderr" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const stdout_file = try tmp.dir.createFile("stdout.txt", .{ .read = true });
    defer stdout_file.close();

    const stderr_file = try tmp.dir.createFile("stderr.txt", .{ .read = true });
    defer stderr_file.close();

    var output = Output.initForTesting(allocator, .plain, stdout_file, stderr_file);

    try output.warn("this is a warning: {s}", .{"be careful"});

    try stderr_file.seekTo(0);
    const content = try stderr_file.readToEndAlloc(allocator, 4096);
    defer allocator.free(content);

    try std.testing.expect(std.mem.indexOf(u8, content, "warning:") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "be careful") != null);
}

test "Output quiet mode suppresses print but not err" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const stdout_file = try tmp.dir.createFile("stdout.txt", .{ .read = true });
    defer stdout_file.close();

    const stderr_file = try tmp.dir.createFile("stderr.txt", .{ .read = true });
    defer stderr_file.close();

    var output = Output.initForTesting(allocator, .quiet, stdout_file, stderr_file);

    try output.print("this should not appear", .{});
    try output.println("this should not appear either", .{});
    try output.success("success should be suppressed", .{});
    try output.warn("warning should be suppressed", .{});
    try output.err("error should still appear", .{});

    try stdout_file.seekTo(0);
    const stdout_content = try stdout_file.readToEndAlloc(allocator, 4096);
    defer allocator.free(stdout_content);

    try stderr_file.seekTo(0);
    const stderr_content = try stderr_file.readToEndAlloc(allocator, 4096);
    defer allocator.free(stderr_content);

    try std.testing.expectEqual(@as(usize, 0), stdout_content.len);
    try std.testing.expect(std.mem.indexOf(u8, stderr_content, "error") != null);
    try std.testing.expect(std.mem.indexOf(u8, stderr_content, "warning") == null);
}

test "Output.success writes in green in rich mode" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const stdout_file = try tmp.dir.createFile("stdout.txt", .{ .read = true });
    defer stdout_file.close();

    const stderr_file = try tmp.dir.createFile("stderr.txt", .{ .read = true });
    defer stderr_file.close();

    var output = Output.initForTesting(allocator, .rich, stdout_file, stderr_file);

    try output.success("operation completed", .{});

    try stdout_file.seekTo(0);
    const content = try stdout_file.readToEndAlloc(allocator, 4096);
    defer allocator.free(content);

    try std.testing.expect(std.mem.indexOf(u8, content, Color.green) != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "operation completed") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, Color.reset) != null);
}

test "Output.printIssue in plain mode shows all fields" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const stdout_file = try tmp.dir.createFile("stdout.txt", .{ .read = true });
    defer stdout_file.close();

    const stderr_file = try tmp.dir.createFile("stderr.txt", .{ .read = true });
    defer stderr_file.close();

    var output = Output.initForTesting(allocator, .plain, stdout_file, stderr_file);

    var issue = Issue.init("bd-abc123", "Test issue title", 1706540000);
    issue.description = "A test description";
    issue.assignee = "alice@example.com";

    try output.printIssue(issue);

    try stdout_file.seekTo(0);
    const content = try stdout_file.readToEndAlloc(allocator, 4096);
    defer allocator.free(content);

    try std.testing.expect(std.mem.indexOf(u8, content, "ID: bd-abc123") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "Title: Test issue title") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "Status: open") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "Priority: medium") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "Type: task") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "Description: A test description") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "Assignee: alice@example.com") != null);
}
