//! Issue struct - the primary entity in beads_zig.
//!
//! Issues track tasks, bugs, features, and other work items. All fields align
//! with beads_rust for JSONL compatibility. Timestamps are Unix epoch internally
//! but serialize to RFC3339 format in JSON for JSONL export.

const std = @import("std");
const Status = @import("status.zig").Status;
const Priority = @import("priority.zig").Priority;
const IssueType = @import("issue_type.zig").IssueType;
const Dependency = @import("dependency.zig").Dependency;
const Comment = @import("comment.zig").Comment;

/// Validation errors for Issue.
pub const IssueError = error{
    EmptyTitle,
    TitleTooLong,
    EmptyId,
};

/// RFC3339 timestamp wrapper for JSON serialization.
/// Stores Unix epoch internally but serializes as RFC3339 string.
pub const Rfc3339Timestamp = struct {
    value: i64,

    const Self = @This();

    pub fn jsonStringify(self: Self, jws: anytype) !void {
        const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = @intCast(self.value) };
        const day_seconds = epoch_seconds.getDaySeconds();
        const epoch_day = epoch_seconds.getEpochDay();
        const year_day = epoch_day.calculateYearDay();
        const month_day = year_day.calculateMonthDay();

        var buf: [25]u8 = undefined;
        const formatted = std.fmt.bufPrint(&buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
            year_day.year,
            @as(u32, month_day.month.numeric()),
            @as(u32, month_day.day_index) + 1,
            day_seconds.getHoursIntoDay(),
            day_seconds.getMinutesIntoHour(),
            day_seconds.getSecondsIntoMinute(),
        }) catch unreachable;

        try jws.write(formatted);
    }

    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !Self {
        const token = try source.nextAllocMax(allocator, .alloc_if_needed, options.max_value_len.?);
        const str = switch (token) {
            .string, .allocated_string => |s| s,
            else => return error.UnexpectedToken,
        };
        return Self{ .value = parseRfc3339(str) orelse return error.InvalidCharacter };
    }

    pub fn jsonParseFromValue(allocator: std.mem.Allocator, source: std.json.Value, options: std.json.ParseOptions) !Self {
        _ = allocator;
        _ = options;
        return switch (source) {
            .string => |s| Self{ .value = parseRfc3339(s) orelse return error.InvalidCharacter },
            .integer => |i| Self{ .value = i },
            else => error.UnexpectedToken,
        };
    }
};

/// Optional RFC3339 timestamp wrapper for nullable timestamp fields.
pub const OptionalRfc3339Timestamp = struct {
    value: ?i64,

    const Self = @This();

    pub fn jsonStringify(self: Self, jws: anytype) !void {
        if (self.value) |v| {
            const ts = Rfc3339Timestamp{ .value = v };
            try ts.jsonStringify(jws);
        } else {
            try jws.write(null);
        }
    }

    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !Self {
        const token = try source.nextAllocMax(allocator, .alloc_if_needed, options.max_value_len.?);
        return switch (token) {
            .null => Self{ .value = null },
            .string, .allocated_string => |s| Self{ .value = parseRfc3339(s) orelse return error.InvalidCharacter },
            else => error.UnexpectedToken,
        };
    }

    pub fn jsonParseFromValue(allocator: std.mem.Allocator, source: std.json.Value, options: std.json.ParseOptions) !Self {
        _ = allocator;
        _ = options;
        return switch (source) {
            .null => Self{ .value = null },
            .string => |s| Self{ .value = parseRfc3339(s) orelse return error.InvalidCharacter },
            .integer => |i| Self{ .value = i },
            else => error.UnexpectedToken,
        };
    }
};

/// Parse RFC3339 timestamp string to Unix epoch seconds.
/// Accepts formats: "2024-01-29T15:30:00Z" or "2024-01-29T15:30:00+00:00"
fn parseRfc3339(s: []const u8) ?i64 {
    if (s.len < 20) return null;

    const year = std.fmt.parseInt(u16, s[0..4], 10) catch return null;
    if (s[4] != '-') return null;
    const month = std.fmt.parseInt(u8, s[5..7], 10) catch return null;
    if (s[7] != '-') return null;
    const day = std.fmt.parseInt(u8, s[8..10], 10) catch return null;
    if (s[10] != 'T') return null;
    const hour = std.fmt.parseInt(u8, s[11..13], 10) catch return null;
    if (s[13] != ':') return null;
    const minute = std.fmt.parseInt(u8, s[14..16], 10) catch return null;
    if (s[16] != ':') return null;
    const second = std.fmt.parseInt(u8, s[17..19], 10) catch return null;

    if (month < 1 or month > 12) return null;
    if (day < 1 or day > 31) return null;
    if (hour > 23) return null;
    if (minute > 59) return null;
    if (second > 59) return null;

    const epoch_day = yearMonthDayToEpochDay(year, month, day) orelse return null;
    const day_seconds: i64 = @as(i64, hour) * 3600 + @as(i64, minute) * 60 + @as(i64, second);

    return epoch_day * std.time.epoch.secs_per_day + day_seconds;
}

/// Convert year/month/day to epoch day (days since 1970-01-01).
fn yearMonthDayToEpochDay(year: u16, month: u8, day: u8) ?i64 {
    const epoch_year: i32 = std.time.epoch.epoch_year;
    const year_i32: i32 = @intCast(year);

    // Calculate days from years
    var total_days: i64 = 0;
    if (year_i32 >= epoch_year) {
        var y: i32 = epoch_year;
        while (y < year_i32) : (y += 1) {
            total_days += std.time.epoch.getDaysInYear(@intCast(y));
        }
    } else {
        var y: i32 = year_i32;
        while (y < epoch_year) : (y += 1) {
            total_days -= std.time.epoch.getDaysInYear(@intCast(y));
        }
    }

    // Add days from months
    const is_leap = std.time.epoch.isLeapYear(year);
    const days_in_months = if (is_leap)
        [_]u16{ 0, 31, 60, 91, 121, 152, 182, 213, 244, 274, 305, 335 }
    else
        [_]u16{ 0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334 };

    total_days += days_in_months[month - 1];
    total_days += day - 1;

    return total_days;
}

/// The primary issue entity. All fields align with beads_rust for JSONL compatibility.
pub const Issue = struct {
    // Identity
    id: []const u8,
    content_hash: ?[]const u8,

    // Content
    title: []const u8,
    description: ?[]const u8,
    design: ?[]const u8,
    acceptance_criteria: ?[]const u8,
    notes: ?[]const u8,

    // Classification
    status: Status,
    priority: Priority,
    issue_type: IssueType,

    // Assignment
    assignee: ?[]const u8,
    owner: ?[]const u8,

    // Timestamps (Unix epoch seconds, serialized as RFC3339)
    created_at: Rfc3339Timestamp,
    created_by: ?[]const u8,
    updated_at: Rfc3339Timestamp,
    closed_at: OptionalRfc3339Timestamp,
    close_reason: ?[]const u8,

    // Scheduling
    due_at: OptionalRfc3339Timestamp,
    defer_until: OptionalRfc3339Timestamp,
    estimated_minutes: ?i32,

    // External references
    external_ref: ?[]const u8,
    source_system: ?[]const u8,

    // Flags
    pinned: bool,
    is_template: bool,

    // Embedded relations (populated on read, not stored in issues table)
    labels: []const []const u8,
    dependencies: []const Dependency,
    comments: []const Comment,

    const Self = @This();

    /// Validate that the issue has all required fields and constraints.
    pub fn validate(self: Self) IssueError!void {
        if (self.id.len == 0) return IssueError.EmptyId;
        if (self.title.len == 0) return IssueError.EmptyTitle;
        if (self.title.len > 500) return IssueError.TitleTooLong;
    }

    /// Check equality between two Issues (compares all fields except embedded relations).
    pub fn eql(a: Self, b: Self) bool {
        if (!std.mem.eql(u8, a.id, b.id)) return false;
        if (!optionalStrEql(a.content_hash, b.content_hash)) return false;
        if (!std.mem.eql(u8, a.title, b.title)) return false;
        if (!optionalStrEql(a.description, b.description)) return false;
        if (!optionalStrEql(a.design, b.design)) return false;
        if (!optionalStrEql(a.acceptance_criteria, b.acceptance_criteria)) return false;
        if (!optionalStrEql(a.notes, b.notes)) return false;
        if (!statusEql(a.status, b.status)) return false;
        if (a.priority.value != b.priority.value) return false;
        if (!issueTypeEql(a.issue_type, b.issue_type)) return false;
        if (!optionalStrEql(a.assignee, b.assignee)) return false;
        if (!optionalStrEql(a.owner, b.owner)) return false;
        if (a.created_at.value != b.created_at.value) return false;
        if (!optionalStrEql(a.created_by, b.created_by)) return false;
        if (a.updated_at.value != b.updated_at.value) return false;
        if (a.closed_at.value != b.closed_at.value) return false;
        if (!optionalStrEql(a.close_reason, b.close_reason)) return false;
        if (a.due_at.value != b.due_at.value) return false;
        if (a.defer_until.value != b.defer_until.value) return false;
        if (a.estimated_minutes != b.estimated_minutes) return false;
        if (!optionalStrEql(a.external_ref, b.external_ref)) return false;
        if (!optionalStrEql(a.source_system, b.source_system)) return false;
        if (a.pinned != b.pinned) return false;
        if (a.is_template != b.is_template) return false;
        return true;
    }

    /// Clone the issue with deep copy of all allocated strings.
    pub fn clone(self: Self, allocator: std.mem.Allocator) !Self {
        var result: Self = undefined;

        result.id = try allocator.dupe(u8, self.id);
        errdefer allocator.free(result.id);

        result.content_hash = if (self.content_hash) |h| try allocator.dupe(u8, h) else null;
        errdefer if (result.content_hash) |h| allocator.free(h);

        result.title = try allocator.dupe(u8, self.title);
        errdefer allocator.free(result.title);

        result.description = if (self.description) |d| try allocator.dupe(u8, d) else null;
        errdefer if (result.description) |d| allocator.free(d);

        result.design = if (self.design) |d| try allocator.dupe(u8, d) else null;
        errdefer if (result.design) |d| allocator.free(d);

        result.acceptance_criteria = if (self.acceptance_criteria) |a| try allocator.dupe(u8, a) else null;
        errdefer if (result.acceptance_criteria) |a| allocator.free(a);

        result.notes = if (self.notes) |n| try allocator.dupe(u8, n) else null;
        errdefer if (result.notes) |n| allocator.free(n);

        result.status = try cloneStatus(self.status, allocator);
        errdefer freeStatus(result.status, allocator);

        result.priority = self.priority;

        result.issue_type = try cloneIssueType(self.issue_type, allocator);
        errdefer freeIssueType(result.issue_type, allocator);

        result.assignee = if (self.assignee) |a| try allocator.dupe(u8, a) else null;
        errdefer if (result.assignee) |a| allocator.free(a);

        result.owner = if (self.owner) |o| try allocator.dupe(u8, o) else null;
        errdefer if (result.owner) |o| allocator.free(o);

        result.created_at = self.created_at;
        result.created_by = if (self.created_by) |c| try allocator.dupe(u8, c) else null;
        errdefer if (result.created_by) |c| allocator.free(c);

        result.updated_at = self.updated_at;
        result.closed_at = self.closed_at;
        result.close_reason = if (self.close_reason) |r| try allocator.dupe(u8, r) else null;
        errdefer if (result.close_reason) |r| allocator.free(r);

        result.due_at = self.due_at;
        result.defer_until = self.defer_until;
        result.estimated_minutes = self.estimated_minutes;

        result.external_ref = if (self.external_ref) |e| try allocator.dupe(u8, e) else null;
        errdefer if (result.external_ref) |e| allocator.free(e);

        result.source_system = if (self.source_system) |s| try allocator.dupe(u8, s) else null;
        errdefer if (result.source_system) |s| allocator.free(s);

        result.pinned = self.pinned;
        result.is_template = self.is_template;

        // Clone labels
        if (self.labels.len > 0) {
            const labels = try allocator.alloc([]const u8, self.labels.len);
            errdefer allocator.free(labels);

            var cloned_count: usize = 0;
            errdefer {
                for (labels[0..cloned_count]) |label| {
                    allocator.free(label);
                }
            }

            for (self.labels, 0..) |label, i| {
                labels[i] = try allocator.dupe(u8, label);
                cloned_count += 1;
            }
            result.labels = labels;
        } else {
            result.labels = &[_][]const u8{};
        }

        // Clone dependencies
        if (self.dependencies.len > 0) {
            const deps = try allocator.alloc(Dependency, self.dependencies.len);
            errdefer allocator.free(deps);

            var cloned_dep_count: usize = 0;
            errdefer {
                for (deps[0..cloned_dep_count]) |*dep| {
                    freeDependency(dep, allocator);
                }
            }

            for (self.dependencies, 0..) |dep, i| {
                deps[i] = try cloneDependency(dep, allocator);
                cloned_dep_count += 1;
            }
            result.dependencies = deps;
        } else {
            result.dependencies = &[_]Dependency{};
        }

        // Clone comments
        if (self.comments.len > 0) {
            const cmnts = try allocator.alloc(Comment, self.comments.len);
            errdefer allocator.free(cmnts);

            var cloned_comment_count: usize = 0;
            errdefer {
                for (cmnts[0..cloned_comment_count]) |*c| {
                    freeComment(c, allocator);
                }
            }

            for (self.comments, 0..) |comment, i| {
                cmnts[i] = try cloneComment(comment, allocator);
                cloned_comment_count += 1;
            }
            result.comments = cmnts;
        } else {
            result.comments = &[_]Comment{};
        }

        return result;
    }

    /// Free all allocated memory for the issue.
    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        if (self.content_hash) |h| allocator.free(h);
        allocator.free(self.title);
        if (self.description) |d| allocator.free(d);
        if (self.design) |d| allocator.free(d);
        if (self.acceptance_criteria) |a| allocator.free(a);
        if (self.notes) |n| allocator.free(n);
        freeStatus(self.status, allocator);
        freeIssueType(self.issue_type, allocator);
        if (self.assignee) |a| allocator.free(a);
        if (self.owner) |o| allocator.free(o);
        if (self.created_by) |c| allocator.free(c);
        if (self.close_reason) |r| allocator.free(r);
        if (self.external_ref) |e| allocator.free(e);
        if (self.source_system) |s| allocator.free(s);

        // Free labels
        if (self.labels.len > 0) {
            for (self.labels) |label| {
                allocator.free(label);
            }
            allocator.free(self.labels);
        }

        // Free dependencies
        if (self.dependencies.len > 0) {
            for (self.dependencies) |dep| {
                var d = dep;
                freeDependency(&d, allocator);
            }
            allocator.free(self.dependencies);
        }

        // Free comments
        if (self.comments.len > 0) {
            for (self.comments) |comment| {
                var c = comment;
                freeComment(&c, allocator);
            }
            allocator.free(self.comments);
        }

        self.* = undefined;
    }

    /// Create a new issue with minimal required fields and defaults.
    pub fn init(id: []const u8, title: []const u8, now: i64) Self {
        return Self{
            .id = id,
            .content_hash = null,
            .title = title,
            .description = null,
            .design = null,
            .acceptance_criteria = null,
            .notes = null,
            .status = .open,
            .priority = Priority.MEDIUM,
            .issue_type = .task,
            .assignee = null,
            .owner = null,
            .created_at = .{ .value = now },
            .created_by = null,
            .updated_at = .{ .value = now },
            .closed_at = .{ .value = null },
            .close_reason = null,
            .due_at = .{ .value = null },
            .defer_until = .{ .value = null },
            .estimated_minutes = null,
            .external_ref = null,
            .source_system = null,
            .pinned = false,
            .is_template = false,
            .labels = &[_][]const u8{},
            .dependencies = &[_]Dependency{},
            .comments = &[_]Comment{},
        };
    }
};

fn optionalStrEql(a: ?[]const u8, b: ?[]const u8) bool {
    const a_val = a orelse return b == null;
    const b_val = b orelse return false;
    return std.mem.eql(u8, a_val, b_val);
}

fn statusEql(a: Status, b: Status) bool {
    const Tag = std.meta.Tag(Status);
    const tag_a: Tag = a;
    const tag_b: Tag = b;
    if (tag_a != tag_b) return false;
    return if (tag_a == .custom) std.mem.eql(u8, a.custom, b.custom) else true;
}

fn issueTypeEql(a: IssueType, b: IssueType) bool {
    const Tag = std.meta.Tag(IssueType);
    const tag_a: Tag = a;
    const tag_b: Tag = b;
    if (tag_a != tag_b) return false;
    return if (tag_a == .custom) std.mem.eql(u8, a.custom, b.custom) else true;
}

fn cloneStatus(status: Status, allocator: std.mem.Allocator) !Status {
    return switch (status) {
        .custom => |s| Status{ .custom = try allocator.dupe(u8, s) },
        else => status,
    };
}

fn freeStatus(status: Status, allocator: std.mem.Allocator) void {
    switch (status) {
        .custom => |s| allocator.free(s),
        else => {},
    }
}

fn cloneIssueType(issue_type: IssueType, allocator: std.mem.Allocator) !IssueType {
    return switch (issue_type) {
        .custom => |s| IssueType{ .custom = try allocator.dupe(u8, s) },
        else => issue_type,
    };
}

fn freeIssueType(issue_type: IssueType, allocator: std.mem.Allocator) void {
    switch (issue_type) {
        .custom => |s| allocator.free(s),
        else => {},
    }
}

fn cloneDependency(dep: Dependency, allocator: std.mem.Allocator) !Dependency {
    var result: Dependency = undefined;

    result.issue_id = try allocator.dupe(u8, dep.issue_id);
    errdefer allocator.free(result.issue_id);

    result.depends_on_id = try allocator.dupe(u8, dep.depends_on_id);
    errdefer allocator.free(result.depends_on_id);

    result.dep_type = switch (dep.dep_type) {
        .custom => |s| .{ .custom = try allocator.dupe(u8, s) },
        else => dep.dep_type,
    };
    errdefer switch (result.dep_type) {
        .custom => |s| allocator.free(s),
        else => {},
    };

    result.created_at = dep.created_at;

    result.created_by = if (dep.created_by) |c| try allocator.dupe(u8, c) else null;
    errdefer if (result.created_by) |c| allocator.free(c);

    result.metadata = if (dep.metadata) |m| try allocator.dupe(u8, m) else null;
    errdefer if (result.metadata) |m| allocator.free(m);

    result.thread_id = if (dep.thread_id) |t| try allocator.dupe(u8, t) else null;

    return result;
}

fn freeDependency(dep: *Dependency, allocator: std.mem.Allocator) void {
    allocator.free(dep.issue_id);
    allocator.free(dep.depends_on_id);
    switch (dep.dep_type) {
        .custom => |s| allocator.free(s),
        else => {},
    }
    if (dep.created_by) |c| allocator.free(c);
    if (dep.metadata) |m| allocator.free(m);
    if (dep.thread_id) |t| allocator.free(t);
}

fn cloneComment(comment: Comment, allocator: std.mem.Allocator) !Comment {
    var result: Comment = undefined;

    result.id = comment.id;
    result.issue_id = try allocator.dupe(u8, comment.issue_id);
    errdefer allocator.free(result.issue_id);

    result.author = try allocator.dupe(u8, comment.author);
    errdefer allocator.free(result.author);

    result.body = try allocator.dupe(u8, comment.body);
    result.created_at = comment.created_at;

    return result;
}

fn freeComment(comment: *Comment, allocator: std.mem.Allocator) void {
    allocator.free(comment.issue_id);
    allocator.free(comment.author);
    allocator.free(comment.body);
}

// --- Tests ---

test "Issue.init creates valid issue with defaults" {
    const issue = Issue.init("bd-abc123", "Test issue", 1706540000);

    try issue.validate();
    try std.testing.expectEqualStrings("bd-abc123", issue.id);
    try std.testing.expectEqualStrings("Test issue", issue.title);
    try std.testing.expectEqual(Status.open, issue.status);
    try std.testing.expectEqual(Priority.MEDIUM, issue.priority);
    try std.testing.expectEqual(IssueType.task, issue.issue_type);
    try std.testing.expectEqual(@as(i64, 1706540000), issue.created_at.value);
    try std.testing.expectEqual(@as(i64, 1706540000), issue.updated_at.value);
    try std.testing.expect(!issue.pinned);
    try std.testing.expect(!issue.is_template);
}

test "Issue.validate accepts valid issue" {
    const issue = Issue.init("bd-abc123", "Valid title", 1706540000);
    try issue.validate();
}

test "Issue.validate rejects empty id" {
    const issue = Issue.init("", "Valid title", 1706540000);
    try std.testing.expectError(IssueError.EmptyId, issue.validate());
}

test "Issue.validate rejects empty title" {
    const issue = Issue.init("bd-abc123", "", 1706540000);
    try std.testing.expectError(IssueError.EmptyTitle, issue.validate());
}

test "Issue.validate rejects title longer than 500 chars" {
    const long_title = "x" ** 501;
    const issue = Issue.init("bd-abc123", long_title, 1706540000);
    try std.testing.expectError(IssueError.TitleTooLong, issue.validate());
}

test "Issue.validate accepts title exactly 500 chars" {
    const title_500 = "x" ** 500;
    const issue = Issue.init("bd-abc123", title_500, 1706540000);
    try issue.validate();
}

test "Issue.eql compares identical issues" {
    const issue1 = Issue.init("bd-abc123", "Test issue", 1706540000);
    const issue2 = Issue.init("bd-abc123", "Test issue", 1706540000);

    try std.testing.expect(Issue.eql(issue1, issue2));
}

test "Issue.eql detects different id" {
    const issue1 = Issue.init("bd-abc123", "Test issue", 1706540000);
    const issue2 = Issue.init("bd-xyz789", "Test issue", 1706540000);

    try std.testing.expect(!Issue.eql(issue1, issue2));
}

test "Issue.eql detects different title" {
    const issue1 = Issue.init("bd-abc123", "First title", 1706540000);
    const issue2 = Issue.init("bd-abc123", "Second title", 1706540000);

    try std.testing.expect(!Issue.eql(issue1, issue2));
}

test "Issue.eql detects different priority" {
    var issue1 = Issue.init("bd-abc123", "Test issue", 1706540000);
    var issue2 = Issue.init("bd-abc123", "Test issue", 1706540000);

    issue1.priority = Priority.HIGH;
    issue2.priority = Priority.LOW;

    try std.testing.expect(!Issue.eql(issue1, issue2));
}

test "Issue.eql detects different timestamps" {
    const issue1 = Issue.init("bd-abc123", "Test issue", 1706540000);
    const issue2 = Issue.init("bd-abc123", "Test issue", 1706550000);

    try std.testing.expect(!Issue.eql(issue1, issue2));
}

test "Issue.clone creates deep copy" {
    const allocator = std.testing.allocator;

    var original = Issue.init("bd-abc123", "Test issue", 1706540000);
    original.description = "A description";
    original.notes = "Some notes";

    var cloned = try original.clone(allocator);
    defer cloned.deinit(allocator);

    try std.testing.expect(Issue.eql(original, cloned));
    try std.testing.expect(original.id.ptr != cloned.id.ptr);
    try std.testing.expect(original.title.ptr != cloned.title.ptr);
    try std.testing.expect(original.description.?.ptr != cloned.description.?.ptr);
    try std.testing.expect(original.notes.?.ptr != cloned.notes.?.ptr);
}

test "Issue.clone handles null optional fields" {
    const allocator = std.testing.allocator;

    const original = Issue.init("bd-abc123", "Test issue", 1706540000);

    var cloned = try original.clone(allocator);
    defer cloned.deinit(allocator);

    try std.testing.expect(Issue.eql(original, cloned));
    try std.testing.expect(cloned.description == null);
    try std.testing.expect(cloned.notes == null);
    try std.testing.expect(cloned.assignee == null);
}

test "Issue.clone handles custom status" {
    const allocator = std.testing.allocator;

    var original = Issue.init("bd-abc123", "Test issue", 1706540000);
    original.status = Status{ .custom = "my_custom_status" };

    var cloned = try original.clone(allocator);
    defer cloned.deinit(allocator);

    try std.testing.expect(statusEql(original.status, cloned.status));
    try std.testing.expect(original.status.custom.ptr != cloned.status.custom.ptr);
}

test "Issue.deinit frees all memory" {
    const allocator = std.testing.allocator;

    var issue = Issue{
        .id = try allocator.dupe(u8, "bd-abc123"),
        .content_hash = try allocator.dupe(u8, "hash123"),
        .title = try allocator.dupe(u8, "Test issue"),
        .description = try allocator.dupe(u8, "Description"),
        .design = try allocator.dupe(u8, "Design"),
        .acceptance_criteria = try allocator.dupe(u8, "AC"),
        .notes = try allocator.dupe(u8, "Notes"),
        .status = .open,
        .priority = Priority.MEDIUM,
        .issue_type = .task,
        .assignee = try allocator.dupe(u8, "alice@example.com"),
        .owner = try allocator.dupe(u8, "bob@example.com"),
        .created_at = .{ .value = 1706540000 },
        .created_by = try allocator.dupe(u8, "creator@example.com"),
        .updated_at = .{ .value = 1706540000 },
        .closed_at = .{ .value = null },
        .close_reason = null,
        .due_at = .{ .value = null },
        .defer_until = .{ .value = null },
        .estimated_minutes = 60,
        .external_ref = try allocator.dupe(u8, "JIRA-123"),
        .source_system = try allocator.dupe(u8, "jira"),
        .pinned = false,
        .is_template = false,
        .labels = &[_][]const u8{},
        .dependencies = &[_]Dependency{},
        .comments = &[_]Comment{},
    };

    issue.deinit(allocator);
}

test "Rfc3339Timestamp JSON serialization" {
    const allocator = std.testing.allocator;

    const ts = Rfc3339Timestamp{ .value = 1706540000 };

    var aw: std.io.Writer.Allocating = .init(allocator);
    defer aw.deinit();

    try std.json.Stringify.value(ts, .{}, &aw.writer);
    const json_str = aw.written();

    try std.testing.expectEqualStrings("\"2024-01-29T14:53:20Z\"", json_str);
}

test "Rfc3339Timestamp JSON parse" {
    const allocator = std.testing.allocator;

    const json_str = "\"2024-01-29T14:53:20Z\"";
    const parsed = try std.json.parseFromSlice(Rfc3339Timestamp, allocator, json_str, .{});
    defer parsed.deinit();

    try std.testing.expectEqual(@as(i64, 1706540000), parsed.value.value);
}

test "Rfc3339Timestamp JSON roundtrip" {
    const allocator = std.testing.allocator;

    const original = Rfc3339Timestamp{ .value = 1706540000 };

    var aw: std.io.Writer.Allocating = .init(allocator);
    defer aw.deinit();

    try std.json.Stringify.value(original, .{}, &aw.writer);
    const json_str = aw.written();

    const parsed = try std.json.parseFromSlice(Rfc3339Timestamp, allocator, json_str, .{});
    defer parsed.deinit();

    try std.testing.expectEqual(original.value, parsed.value.value);
}

test "OptionalRfc3339Timestamp JSON serialization with value" {
    const allocator = std.testing.allocator;

    const ts = OptionalRfc3339Timestamp{ .value = 1706540000 };

    var aw: std.io.Writer.Allocating = .init(allocator);
    defer aw.deinit();

    try std.json.Stringify.value(ts, .{}, &aw.writer);
    const json_str = aw.written();

    try std.testing.expectEqualStrings("\"2024-01-29T14:53:20Z\"", json_str);
}

test "OptionalRfc3339Timestamp JSON serialization with null" {
    const allocator = std.testing.allocator;

    const ts = OptionalRfc3339Timestamp{ .value = null };

    var aw: std.io.Writer.Allocating = .init(allocator);
    defer aw.deinit();

    try std.json.Stringify.value(ts, .{}, &aw.writer);
    const json_str = aw.written();

    try std.testing.expectEqualStrings("null", json_str);
}

test "OptionalRfc3339Timestamp JSON parse null" {
    const allocator = std.testing.allocator;

    const json_str = "null";
    const parsed = try std.json.parseFromSlice(OptionalRfc3339Timestamp, allocator, json_str, .{});
    defer parsed.deinit();

    try std.testing.expect(parsed.value.value == null);
}

test "parseRfc3339 parses valid timestamp" {
    const result = parseRfc3339("2024-01-29T14:53:20Z");
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(i64, 1706540000), result.?);
}

test "parseRfc3339 rejects invalid format" {
    try std.testing.expect(parseRfc3339("invalid") == null);
    try std.testing.expect(parseRfc3339("2024-01-29") == null);
    try std.testing.expect(parseRfc3339("2024/01/29T15:33:20Z") == null);
}

test "Issue JSON serialization roundtrip" {
    const allocator = std.testing.allocator;

    const issue = Issue.init("bd-abc123", "Test issue title", 1706540000);

    var aw: std.io.Writer.Allocating = .init(allocator);
    defer aw.deinit();

    try std.json.Stringify.value(issue, .{}, &aw.writer);
    const json_str = aw.written();

    const parsed = try std.json.parseFromSlice(Issue, allocator, json_str, .{});
    defer parsed.deinit();

    try std.testing.expectEqualStrings(issue.id, parsed.value.id);
    try std.testing.expectEqualStrings(issue.title, parsed.value.title);
    try std.testing.expectEqual(issue.created_at.value, parsed.value.created_at.value);
    try std.testing.expectEqual(issue.priority, parsed.value.priority);
}

test "Issue JSON serialization with all fields" {
    const allocator = std.testing.allocator;

    var issue = Issue.init("bd-abc123", "Full issue", 1706540000);
    issue.content_hash = "hash123";
    issue.description = "A description";
    issue.design = "Design doc";
    issue.acceptance_criteria = "AC here";
    issue.notes = "Some notes";
    issue.status = .in_progress;
    issue.priority = Priority.HIGH;
    issue.issue_type = .bug;
    issue.assignee = "alice@example.com";
    issue.owner = "bob@example.com";
    issue.created_by = "creator@example.com";
    issue.closed_at = .{ .value = 1706550000 };
    issue.close_reason = "Fixed";
    issue.due_at = .{ .value = 1706600000 };
    issue.defer_until = .{ .value = 1706560000 };
    issue.estimated_minutes = 120;
    issue.external_ref = "JIRA-123";
    issue.source_system = "jira";
    issue.pinned = true;
    issue.is_template = false;

    var aw: std.io.Writer.Allocating = .init(allocator);
    defer aw.deinit();

    try std.json.Stringify.value(issue, .{}, &aw.writer);
    const json_str = aw.written();

    const parsed = try std.json.parseFromSlice(Issue, allocator, json_str, .{});
    defer parsed.deinit();

    try std.testing.expectEqualStrings(issue.id, parsed.value.id);
    try std.testing.expectEqualStrings(issue.title, parsed.value.title);
    try std.testing.expectEqualStrings(issue.description.?, parsed.value.description.?);
    try std.testing.expectEqualStrings(issue.design.?, parsed.value.design.?);
    try std.testing.expectEqualStrings(issue.notes.?, parsed.value.notes.?);
    try std.testing.expectEqual(issue.priority, parsed.value.priority);
    try std.testing.expectEqual(issue.estimated_minutes.?, parsed.value.estimated_minutes.?);
    try std.testing.expect(parsed.value.pinned);
}

test "Issue JSON contains expected RFC3339 timestamp format" {
    const allocator = std.testing.allocator;

    const issue = Issue.init("bd-test", "Test", 1706540000);

    var aw: std.io.Writer.Allocating = .init(allocator);
    defer aw.deinit();

    try std.json.Stringify.value(issue, .{}, &aw.writer);
    const json_str = aw.written();

    try std.testing.expect(std.mem.indexOf(u8, json_str, "2024-01-29T14:53:20Z") != null);
}

test "Issue JSON with null optional fields" {
    const allocator = std.testing.allocator;

    const issue = Issue.init("bd-abc123", "Minimal issue", 1706540000);

    var aw: std.io.Writer.Allocating = .init(allocator);
    defer aw.deinit();

    try std.json.Stringify.value(issue, .{}, &aw.writer);
    const json_str = aw.written();

    try std.testing.expect(std.mem.indexOf(u8, json_str, "\"description\":null") != null);
    try std.testing.expect(std.mem.indexOf(u8, json_str, "\"closed_at\":null") != null);
}
