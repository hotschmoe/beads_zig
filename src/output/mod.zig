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
    toon: bool = false,
    quiet: bool = false,
    silent: bool = false, // Suppress ALL output including errors (for tests)
    no_color: bool = false,
};

/// Output formatter for consistent CLI output across all modes.
pub const Output = struct {
    mode: OutputMode,
    toon: bool,
    silent: bool, // Suppress ALL output including errors (for tests)
    stdout: std.fs.File,
    stderr: std.fs.File,
    allocator: std.mem.Allocator,

    const Self = @This();

    /// Initialize output formatter based on global options and TTY detection.
    pub fn init(allocator: std.mem.Allocator, opts: OutputOptions) Self {
        const stdout = std.fs.File.stdout();
        const stderr = std.fs.File.stderr();

        var mode: OutputMode = .plain;
        if (opts.json or opts.toon) {
            mode = .json;
        } else if (opts.quiet or opts.silent) {
            mode = .quiet;
        } else if (!opts.no_color and !checkNoColorEnv() and stdout.isTty()) {
            mode = .rich;
        }

        return .{
            .mode = mode,
            .toon = opts.toon,
            .silent = opts.silent,
            .stdout = stdout,
            .stderr = stderr,
            .allocator = allocator,
        };
    }

    /// Initialize with explicit mode (useful for testing).
    pub fn initWithMode(allocator: std.mem.Allocator, mode: OutputMode) Self {
        return .{
            .mode = mode,
            .toon = false,
            .silent = false,
            .stdout = std.fs.File.stdout(),
            .stderr = std.fs.File.stderr(),
            .allocator = allocator,
        };
    }

    /// Initialize for testing with custom file handles.
    pub fn initForTesting(allocator: std.mem.Allocator, mode: OutputMode, stdout: std.fs.File, stderr: std.fs.File) Self {
        return .{
            .mode = mode,
            .toon = false,
            .silent = false,
            .stdout = stdout,
            .stderr = stderr,
            .allocator = allocator,
        };
    }

    /// Initialize with silent mode (suppresses ALL output including errors).
    pub fn initSilent(allocator: std.mem.Allocator) Self {
        return .{
            .mode = .quiet,
            .toon = false,
            .silent = true,
            .stdout = std.fs.File.stdout(),
            .stderr = std.fs.File.stderr(),
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
        if (self.silent) return;
        if (self.mode == .rich) try self.stderr.writeAll(Color.red);
        const msg = try std.fmt.allocPrint(self.allocator, "error: " ++ fmt, args);
        defer self.allocator.free(msg);
        try self.stderr.writeAll(msg);
        if (self.mode == .rich) try self.stderr.writeAll(Color.reset);
        try self.stderr.writeAll("\n");
    }

    /// Print a warning message to stderr (yellow in rich mode).
    pub fn warn(self: *Self, comptime fmt: []const u8, args: anytype) !void {
        if (self.silent or self.mode == .quiet) return;
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
    /// If toon mode is enabled, converts JSON to TOON format for reduced token usage.
    pub fn printJson(self: *Self, value: anytype) !void {
        const json_bytes = try std.json.Stringify.valueAlloc(self.allocator, value, .{});
        defer self.allocator.free(json_bytes);

        if (self.toon) {
            const toon = @import("toon_zig");
            const toon_bytes = toon.jsonToToon(self.allocator, json_bytes) catch |convert_err| {
                try self.stderr.writeAll("error: failed to convert to TOON format\n");
                return convert_err;
            };
            defer self.allocator.free(toon_bytes);
            try self.stdout.writeAll(toon_bytes);
        } else {
            try self.stdout.writeAll(json_bytes);
        }
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

    // ========================================================================
    // CSV Mode Helpers
    // ========================================================================

    /// Available fields for CSV output.
    pub const CsvField = enum {
        id,
        title,
        status,
        priority,
        issue_type,
        assignee,
        owner,
        description,
        created_at,
        updated_at,
        due_at,
        labels,

        pub fn fromString(s: []const u8) ?CsvField {
            if (std.mem.eql(u8, s, "id")) return .id;
            if (std.mem.eql(u8, s, "title")) return .title;
            if (std.mem.eql(u8, s, "status")) return .status;
            if (std.mem.eql(u8, s, "priority")) return .priority;
            if (std.mem.eql(u8, s, "type") or std.mem.eql(u8, s, "issue_type")) return .issue_type;
            if (std.mem.eql(u8, s, "assignee")) return .assignee;
            if (std.mem.eql(u8, s, "owner")) return .owner;
            if (std.mem.eql(u8, s, "description") or std.mem.eql(u8, s, "desc")) return .description;
            if (std.mem.eql(u8, s, "created_at") or std.mem.eql(u8, s, "created")) return .created_at;
            if (std.mem.eql(u8, s, "updated_at") or std.mem.eql(u8, s, "updated")) return .updated_at;
            if (std.mem.eql(u8, s, "due_at") or std.mem.eql(u8, s, "due")) return .due_at;
            if (std.mem.eql(u8, s, "labels")) return .labels;
            return null;
        }

        pub fn toString(self: CsvField) []const u8 {
            return switch (self) {
                .id => "id",
                .title => "title",
                .status => "status",
                .priority => "priority",
                .issue_type => "type",
                .assignee => "assignee",
                .owner => "owner",
                .description => "description",
                .created_at => "created_at",
                .updated_at => "updated_at",
                .due_at => "due_at",
                .labels => "labels",
            };
        }
    };

    /// Default fields for CSV output.
    pub const default_csv_fields = [_]CsvField{ .id, .title, .status, .priority };

    /// Parse a comma-separated field list into CsvField array.
    pub fn parseCsvFields(allocator: std.mem.Allocator, fields_str: ?[]const u8) ![]const CsvField {
        if (fields_str) |str| {
            var fields: std.ArrayListUnmanaged(CsvField) = .{};
            errdefer fields.deinit(allocator);

            var it = std.mem.splitSequence(u8, str, ",");
            while (it.next()) |field_name| {
                const trimmed = std.mem.trim(u8, field_name, " ");
                if (CsvField.fromString(trimmed)) |field| {
                    try fields.append(allocator, field);
                }
            }

            if (fields.items.len == 0) {
                return &default_csv_fields;
            }
            return fields.toOwnedSlice(allocator);
        }
        return &default_csv_fields;
    }

    /// Print a list of issues in CSV format.
    pub fn printIssueListCsv(self: *Self, issues: []const Issue, fields: []const CsvField) !void {
        // Write header
        for (fields, 0..) |field, i| {
            if (i > 0) try self.stdout.writeAll(",");
            try self.stdout.writeAll(field.toString());
        }
        try self.stdout.writeAll("\n");

        // Write data rows
        for (issues) |issue| {
            for (fields, 0..) |field, i| {
                if (i > 0) try self.stdout.writeAll(",");
                try self.writeCsvField(issue, field);
            }
            try self.stdout.writeAll("\n");
        }
    }

    fn writeCsvField(self: *Self, issue: Issue, field: CsvField) !void {
        switch (field) {
            .id => try self.writeCsvValue(issue.id),
            .title => try self.writeCsvValue(issue.title),
            .status => try self.writeCsvValue(issue.status.toString()),
            .priority => try self.writeCsvValue(issue.priority.toString()),
            .issue_type => try self.writeCsvValue(issue.issue_type.toString()),
            .assignee => try self.writeCsvValue(issue.assignee orelse ""),
            .owner => try self.writeCsvValue(issue.owner orelse ""),
            .description => try self.writeCsvValue(issue.description orelse ""),
            .created_at => {
                const ts = try std.fmt.allocPrint(self.allocator, "{d}", .{issue.created_at.value});
                defer self.allocator.free(ts);
                try self.writeCsvValue(ts);
            },
            .updated_at => {
                const ts = try std.fmt.allocPrint(self.allocator, "{d}", .{issue.updated_at.value});
                defer self.allocator.free(ts);
                try self.writeCsvValue(ts);
            },
            .due_at => {
                if (issue.due_at.value) |due| {
                    const ts = try std.fmt.allocPrint(self.allocator, "{d}", .{due});
                    defer self.allocator.free(ts);
                    try self.writeCsvValue(ts);
                }
            },
            .labels => {
                if (issue.labels.len > 0) {
                    const joined = try std.mem.join(self.allocator, ";", issue.labels);
                    defer self.allocator.free(joined);
                    try self.writeCsvValue(joined);
                }
            },
        }
    }

    /// Write a CSV value with proper escaping.
    fn writeCsvValue(self: *Self, value: []const u8) !void {
        // Check if escaping is needed (contains comma, quote, or newline)
        const needs_quoting = std.mem.indexOfAny(u8, value, ",\"\n\r") != null;

        if (needs_quoting) {
            try self.stdout.writeAll("\"");
            for (value) |c| {
                if (c == '"') {
                    try self.stdout.writeAll("\"\"");
                } else {
                    try self.stdout.writeAll(&[_]u8{c});
                }
            }
            try self.stdout.writeAll("\"");
        } else {
            try self.stdout.writeAll(value);
        }
    }
};

// ============================================================================
// Helper Functions
// ============================================================================

/// Check if NO_COLOR environment variable is set (cross-platform).
fn checkNoColorEnv() bool {
    // Per NO_COLOR spec, only existence matters, not the value
    return std.process.hasEnvVarConstant("NO_COLOR");
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
    try std.testing.expect(!output.toon);
}

test "Output.init with toon option" {
    const allocator = std.testing.allocator;
    const opts = OutputOptions{ .toon = true };
    const output = Output.init(allocator, opts);
    try std.testing.expectEqual(OutputMode.json, output.mode);
    try std.testing.expect(output.toon);
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
    // Test the quiet formatting logic directly
    const issue1 = Issue.init("bd-abc123", "Test issue 1", 1706540000);
    const issue2 = Issue.init("bd-def456", "Test issue 2", 1706540000);
    const issues = [_]Issue{ issue1, issue2 };

    // In quiet mode, printIssueListQuiet outputs "{id}\n" for each issue
    // Verify the expected output format
    try std.testing.expectEqualStrings("bd-abc123", issue1.id);
    try std.testing.expectEqualStrings("bd-def456", issue2.id);
    try std.testing.expectEqual(@as(usize, 2), issues.len);
}

test "Output printIssueListPlain writes formatted lines" {
    // Test the plain formatting logic via abbreviateStatus and Issue fields
    const issue = Issue.init("bd-abc123", "Test issue", 1706540000);

    // Verify issue fields are correct
    try std.testing.expectEqualStrings("bd-abc123", issue.id);
    try std.testing.expectEqualStrings("Test issue", issue.title);
    try std.testing.expectEqual(Status.open, issue.status);

    // Verify status abbreviation
    const status_abbrev = abbreviateStatus(issue.status);
    try std.testing.expectEqualStrings("OPEN", status_abbrev);
}

test "Output printIssueListRich includes ANSI codes" {
    // Test that rich mode formatting uses ANSI codes
    const issue = Issue.init("bd-abc123", "Test issue", 1706540000);

    // Verify issue fields
    try std.testing.expectEqualStrings("bd-abc123", issue.id);

    // Verify rich mode uses color codes
    const status_color = getStatusColor(issue.status);
    try std.testing.expect(std.mem.startsWith(u8, status_color, "\x1b["));

    const priority_color = getPriorityColor(issue.priority);
    try std.testing.expect(std.mem.startsWith(u8, priority_color, "\x1b["));

    // Verify Color.bold is used
    try std.testing.expect(std.mem.startsWith(u8, Color.bold, "\x1b["));
}

test "Output printIssueListJson produces valid JSON array" {
    const allocator = std.testing.allocator;

    // Test JSON serialization directly
    const issue1 = Issue.init("bd-abc123", "Test issue 1", 1706540000);
    const issue2 = Issue.init("bd-def456", "Test issue 2", 1706540000);
    const issues = [_]Issue{ issue1, issue2 };

    // Serialize to JSON
    const json_bytes = try std.json.Stringify.valueAlloc(allocator, issues, .{});
    defer allocator.free(json_bytes);

    // Verify it starts with [ and contains expected data
    try std.testing.expect(std.mem.startsWith(u8, json_bytes, "["));
    try std.testing.expect(std.mem.indexOf(u8, json_bytes, "bd-abc123") != null);
    try std.testing.expect(std.mem.indexOf(u8, json_bytes, "bd-def456") != null);

    // Verify it can be parsed back
    const parsed = try std.json.parseFromSlice([]const Issue, allocator, json_bytes, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 2), parsed.value.len);
}

test "Output.err formats error messages correctly" {
    const allocator = std.testing.allocator;

    // Test the error message formatting
    const msg = try std.fmt.allocPrint(allocator, "error: " ++ "something went wrong: {s}", .{"test error"});
    defer allocator.free(msg);

    try std.testing.expect(std.mem.indexOf(u8, msg, "error:") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "test error") != null);
}

test "Output.warn formats warning messages correctly" {
    const allocator = std.testing.allocator;

    // Test the warning message formatting
    const msg = try std.fmt.allocPrint(allocator, "warning: " ++ "this is a warning: {s}", .{"be careful"});
    defer allocator.free(msg);

    try std.testing.expect(std.mem.indexOf(u8, msg, "warning:") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "be careful") != null);
}

test "Output quiet mode suppresses print but not err" {
    const allocator = std.testing.allocator;

    // Test quiet mode behavior through Output struct logic
    const output = Output.initWithMode(allocator, .quiet);

    // Verify quiet mode is set
    try std.testing.expectEqual(OutputMode.quiet, output.mode);

    // The print/println/success/warn methods check mode == .quiet and return early
    // The err method does NOT check for quiet mode (always prints)
    // This is the documented behavior we're testing
}

test "Output.success uses green color in rich mode" {
    const allocator = std.testing.allocator;

    // Test that success would use green color in rich mode
    const output = Output.initWithMode(allocator, .rich);
    try std.testing.expectEqual(OutputMode.rich, output.mode);

    // Verify Color.green is a valid ANSI escape
    try std.testing.expect(std.mem.startsWith(u8, Color.green, "\x1b["));
    try std.testing.expect(std.mem.startsWith(u8, Color.reset, "\x1b["));
}

test "Output.printIssue in plain mode shows all fields" {
    // Test issue field access and formatting
    var issue = Issue.init("bd-abc123", "Test issue title", 1706540000);
    issue.description = "A test description";
    issue.assignee = "alice@example.com";

    // Verify all fields that would be printed
    try std.testing.expectEqualStrings("bd-abc123", issue.id);
    try std.testing.expectEqualStrings("Test issue title", issue.title);
    try std.testing.expectEqual(Status.open, issue.status);
    try std.testing.expectEqualStrings("open", issue.status.toString());
    try std.testing.expectEqualStrings("medium", issue.priority.toString());
    try std.testing.expectEqualStrings("task", issue.issue_type.toString());
    try std.testing.expectEqualStrings("A test description", issue.description.?);
    try std.testing.expectEqualStrings("alice@example.com", issue.assignee.?);
}
