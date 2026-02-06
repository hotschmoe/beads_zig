//! Issue storage operations for beads_zig.
//!
//! Provides CRUD operations for issues including:
//! - Insert new issues
//! - Get issues by ID (with or without embedded relations)
//! - Update issue fields
//! - Soft delete (tombstone)
//! - List issues with filters
//! - Count issues grouped by field

const std = @import("std");
const sqlite = @import("sqlite.zig");
const Database = sqlite.Database;
const Statement = sqlite.Statement;
const SqliteError = sqlite.SqliteError;

const Issue = @import("../models/issue.zig").Issue;
const Rfc3339Timestamp = @import("../models/issue.zig").Rfc3339Timestamp;
const OptionalRfc3339Timestamp = @import("../models/issue.zig").OptionalRfc3339Timestamp;
const Status = @import("../models/status.zig").Status;
const Priority = @import("../models/priority.zig").Priority;
const IssueType = @import("../models/issue_type.zig").IssueType;
const Dependency = @import("../models/dependency.zig").Dependency;
const DependencyType = @import("../models/dependency.zig").DependencyType;
const Comment = @import("../models/comment.zig").Comment;

pub const IssueStoreError = error{
    IssueNotFound,
    DuplicateId,
    InvalidIssue,
};

pub const IssueStore = struct {
    db: *Database,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(db: *Database, allocator: std.mem.Allocator) Self {
        return .{ .db = db, .allocator = allocator };
    }

    pub fn freeIssues(self: *Self, issues: []Issue) void {
        for (issues) |*issue| {
            var i = issue.*;
            i.deinit(self.allocator);
        }
        self.allocator.free(issues);
    }

    /// Insert a new issue into the database.
    pub fn insert(self: *Self, issue: Issue) !void {
        const sql =
            \\INSERT INTO issues (
            \\    id, content_hash, title, description, design, acceptance_criteria,
            \\    notes, status, priority, issue_type, assignee, owner,
            \\    estimated_minutes, created_at, created_by, updated_at,
            \\    closed_at, close_reason, due_at, defer_until,
            \\    external_ref, source_system, pinned, is_template
            \\) VALUES (
            \\    ?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12,
            \\    ?13, ?14, ?15, ?16, ?17, ?18, ?19, ?20, ?21, ?22, ?23, ?24
            \\)
        ;
        var stmt = try self.db.prepare(sql);
        defer stmt.deinit();

        try stmt.bindText(1, issue.id);
        try stmt.bindText(2, issue.content_hash);
        try stmt.bindText(3, issue.title);
        try stmt.bindText(4, issue.description);
        try stmt.bindText(5, issue.design);
        try stmt.bindText(6, issue.acceptance_criteria);
        try stmt.bindText(7, issue.notes);
        try stmt.bindText(8, issue.status.toString());
        try stmt.bindInt(9, @as(i64, issue.priority.value));
        try stmt.bindText(10, issue.issue_type.toString());
        try stmt.bindText(11, issue.assignee);
        try stmt.bindText(12, issue.owner);
        try stmt.bindOptionalInt32(13, issue.estimated_minutes);
        try stmt.bindInt(14, issue.created_at.value);
        try stmt.bindText(15, issue.created_by);
        try stmt.bindInt(16, issue.updated_at.value);
        try stmt.bindOptionalInt(17, issue.closed_at.value);
        try stmt.bindText(18, issue.close_reason);
        try stmt.bindOptionalInt(19, issue.due_at.value);
        try stmt.bindOptionalInt(20, issue.defer_until.value);
        try stmt.bindText(21, issue.external_ref);
        try stmt.bindText(22, issue.source_system);
        try stmt.bindInt(23, if (issue.pinned) 1 else 0);
        try stmt.bindInt(24, if (issue.is_template) 1 else 0);

        _ = try stmt.step();

        try self.markDirty(issue.id);
    }

    /// Get an issue by ID (without embedded relations).
    pub fn get(self: *Self, id: []const u8) !?Issue {
        const sql =
            \\SELECT id, content_hash, title, description, design, acceptance_criteria,
            \\       notes, status, priority, issue_type, assignee, owner,
            \\       estimated_minutes, created_at, created_by, updated_at,
            \\       closed_at, close_reason, due_at, defer_until,
            \\       external_ref, source_system, pinned, is_template
            \\FROM issues WHERE id = ?1
        ;
        var stmt = try self.db.prepare(sql);
        defer stmt.deinit();
        try stmt.bindText(1, id);

        if (try stmt.step()) {
            return try self.rowToIssue(&stmt);
        }
        return null;
    }

    /// Get an issue with all embedded relations (labels, deps, comments).
    pub fn getWithRelations(self: *Self, id: []const u8) !?Issue {
        var issue = try self.get(id) orelse return null;
        issue.labels = try self.getLabels(id);
        issue.dependencies = try self.getDependencies(id);
        issue.comments = try self.getComments(id);
        return issue;
    }

    /// Fields that can be updated on an issue.
    pub const IssueUpdate = struct {
        title: ?[]const u8 = null,
        description: ?[]const u8 = null,
        design: ?[]const u8 = null,
        acceptance_criteria: ?[]const u8 = null,
        notes: ?[]const u8 = null,
        status: ?Status = null,
        priority: ?Priority = null,
        issue_type: ?IssueType = null,
        assignee: ?[]const u8 = null,
        owner: ?[]const u8 = null,
        estimated_minutes: ?i32 = null,
        closed_at: ?i64 = null,
        close_reason: ?[]const u8 = null,
        closed_by_session: ?[]const u8 = null,
        due_at: ?i64 = null,
        defer_until: ?i64 = null,
        external_ref: ?[]const u8 = null,
        source_system: ?[]const u8 = null,
        pinned: ?bool = null,
        is_template: ?bool = null,
        content_hash: ?[]const u8 = null,
    };

    /// Update an issue with the given fields.
    pub fn update(self: *Self, id: []const u8, updates: IssueUpdate, now: i64) !void {
        // Check if issue exists
        const issue_exists = try self.exists(id);
        if (!issue_exists) {
            return IssueStoreError.IssueNotFound;
        }

        // Build dynamic UPDATE SQL
        var sql_buf: [2048]u8 = undefined;
        var params: [22]?[]const u8 = .{null} ** 22;
        var int_params: [22]?i64 = .{null} ** 22;
        var param_count: usize = 0;

        var stream = std.io.fixedBufferStream(&sql_buf);
        const writer = stream.writer();

        try writer.writeAll("UPDATE issues SET updated_at = ?1");
        int_params[0] = now;
        param_count = 1;

        if (updates.title) |v| {
            param_count += 1;
            try writer.print(", title = ?{d}", .{param_count});
            params[param_count - 1] = v;
        }
        if (updates.description) |v| {
            param_count += 1;
            try writer.print(", description = ?{d}", .{param_count});
            params[param_count - 1] = v;
        }
        if (updates.design) |v| {
            param_count += 1;
            try writer.print(", design = ?{d}", .{param_count});
            params[param_count - 1] = v;
        }
        if (updates.acceptance_criteria) |v| {
            param_count += 1;
            try writer.print(", acceptance_criteria = ?{d}", .{param_count});
            params[param_count - 1] = v;
        }
        if (updates.notes) |v| {
            param_count += 1;
            try writer.print(", notes = ?{d}", .{param_count});
            params[param_count - 1] = v;
        }
        if (updates.status) |v| {
            param_count += 1;
            try writer.print(", status = ?{d}", .{param_count});
            params[param_count - 1] = v.toString();
        }
        if (updates.priority) |v| {
            param_count += 1;
            try writer.print(", priority = ?{d}", .{param_count});
            int_params[param_count - 1] = @as(i64, v.value);
        }
        if (updates.issue_type) |v| {
            param_count += 1;
            try writer.print(", issue_type = ?{d}", .{param_count});
            params[param_count - 1] = v.toString();
        }
        if (updates.assignee) |v| {
            param_count += 1;
            try writer.print(", assignee = ?{d}", .{param_count});
            params[param_count - 1] = v;
        }
        if (updates.owner) |v| {
            param_count += 1;
            try writer.print(", owner = ?{d}", .{param_count});
            params[param_count - 1] = v;
        }
        if (updates.estimated_minutes) |v| {
            param_count += 1;
            try writer.print(", estimated_minutes = ?{d}", .{param_count});
            int_params[param_count - 1] = @as(i64, v);
        }
        if (updates.closed_at) |v| {
            param_count += 1;
            try writer.print(", closed_at = ?{d}", .{param_count});
            int_params[param_count - 1] = v;
        }
        if (updates.close_reason) |v| {
            param_count += 1;
            try writer.print(", close_reason = ?{d}", .{param_count});
            params[param_count - 1] = v;
        }
        if (updates.closed_by_session) |v| {
            param_count += 1;
            try writer.print(", closed_by_session = ?{d}", .{param_count});
            params[param_count - 1] = v;
        }
        if (updates.due_at) |v| {
            param_count += 1;
            try writer.print(", due_at = ?{d}", .{param_count});
            int_params[param_count - 1] = v;
        }
        if (updates.defer_until) |v| {
            param_count += 1;
            try writer.print(", defer_until = ?{d}", .{param_count});
            int_params[param_count - 1] = v;
        }
        if (updates.external_ref) |v| {
            param_count += 1;
            try writer.print(", external_ref = ?{d}", .{param_count});
            params[param_count - 1] = v;
        }
        if (updates.source_system) |v| {
            param_count += 1;
            try writer.print(", source_system = ?{d}", .{param_count});
            params[param_count - 1] = v;
        }
        if (updates.pinned) |v| {
            param_count += 1;
            try writer.print(", pinned = ?{d}", .{param_count});
            int_params[param_count - 1] = if (v) 1 else 0;
        }
        if (updates.is_template) |v| {
            param_count += 1;
            try writer.print(", is_template = ?{d}", .{param_count});
            int_params[param_count - 1] = if (v) 1 else 0;
        }
        if (updates.content_hash) |v| {
            param_count += 1;
            try writer.print(", content_hash = ?{d}", .{param_count});
            params[param_count - 1] = v;
        }

        param_count += 1;
        try writer.print(" WHERE id = ?{d}", .{param_count});

        const sql = stream.getWritten();

        var stmt = try self.db.prepare(sql);
        defer stmt.deinit();

        // Bind parameters
        for (0..param_count) |i| {
            const idx: u32 = @intCast(i + 1);
            if (int_params[i]) |v| {
                try stmt.bindInt(idx, v);
            } else if (params[i]) |v| {
                try stmt.bindText(idx, v);
            }
        }
        // Bind the WHERE id parameter
        try stmt.bindText(@intCast(param_count), id);

        _ = try stmt.step();

        try self.markDirty(id);
    }

    /// Soft delete an issue by setting its status to tombstone.
    pub fn delete(self: *Self, id: []const u8, now: i64) !void {
        try self.update(id, .{ .status = .tombstone }, now);
    }

    /// Soft delete an issue with audit information.
    pub fn softDelete(self: *Self, id: []const u8, actor: []const u8, reason: ?[]const u8, now: i64) !void {
        if (!try self.exists(id)) {
            return IssueStoreError.IssueNotFound;
        }

        var stmt = try self.db.prepare(
            \\UPDATE issues SET status = 'tombstone', updated_at = ?1,
            \\    deleted_at = ?2, deleted_by = ?3, delete_reason = ?4
            \\WHERE id = ?5
        );
        defer stmt.deinit();

        try stmt.bindInt(1, now);
        try stmt.bindInt(2, now);
        try stmt.bindText(3, actor);
        try stmt.bindText(4, reason);
        try stmt.bindText(5, id);

        _ = try stmt.step();
        try self.markDirty(id);
    }

    /// Hard delete (permanently remove) an issue from the database.
    pub fn hardDelete(self: *Self, id: []const u8) !void {
        if (!try self.exists(id)) {
            return IssueStoreError.IssueNotFound;
        }

        var delete_stmt = try self.db.prepare("DELETE FROM issues WHERE id = ?1");
        defer delete_stmt.deinit();
        try delete_stmt.bindText(1, id);
        _ = try delete_stmt.step();
    }

    /// Filters for listing issues.
    pub const ListFilters = struct {
        status: ?Status = null,
        priority: ?Priority = null,
        issue_type: ?IssueType = null,
        assignee: ?[]const u8 = null,
        label: ?[]const u8 = null,
        include_tombstones: bool = false,
        limit: ?u32 = null,
        offset: ?u32 = null,
        order_by: OrderBy = .created_at,
        order_desc: bool = true,

        pub const OrderBy = enum {
            created_at,
            updated_at,
            priority,
        };
    };

    /// List issues with optional filters.
    pub fn list(self: *Self, filters: ListFilters) ![]Issue {
        var sql_buf: [1024]u8 = undefined;
        var stream = std.io.fixedBufferStream(&sql_buf);
        const writer = stream.writer();

        // Start building the query
        if (filters.label != null) {
            try writer.writeAll(
                \\SELECT DISTINCT i.id, i.content_hash, i.title, i.description, i.design,
                \\       i.acceptance_criteria, i.notes, i.status, i.priority, i.issue_type,
                \\       i.assignee, i.owner, i.estimated_minutes, i.created_at, i.created_by,
                \\       i.updated_at, i.closed_at, i.close_reason, i.due_at, i.defer_until,
                \\       i.external_ref, i.source_system, i.pinned, i.is_template
                \\FROM issues i
                \\JOIN labels l ON i.id = l.issue_id
                \\WHERE 1=1
            );
        } else {
            try writer.writeAll(
                \\SELECT id, content_hash, title, description, design, acceptance_criteria,
                \\       notes, status, priority, issue_type, assignee, owner,
                \\       estimated_minutes, created_at, created_by, updated_at,
                \\       closed_at, close_reason, due_at, defer_until,
                \\       external_ref, source_system, pinned, is_template
                \\FROM issues
                \\WHERE 1=1
            );
        }

        var params: [6]?[]const u8 = .{null} ** 6;
        var int_params: [6]?i64 = .{null} ** 6;
        var param_count: usize = 0;

        if (!filters.include_tombstones) {
            try writer.writeAll(" AND status != 'tombstone'");
        }

        if (filters.status) |s| {
            param_count += 1;
            try writer.print(" AND status = ?{d}", .{param_count});
            params[param_count - 1] = s.toString();
        }

        if (filters.priority) |p| {
            param_count += 1;
            try writer.print(" AND priority = ?{d}", .{param_count});
            int_params[param_count - 1] = @as(i64, p.value);
        }

        if (filters.issue_type) |t| {
            param_count += 1;
            try writer.print(" AND issue_type = ?{d}", .{param_count});
            params[param_count - 1] = t.toString();
        }

        if (filters.assignee) |a| {
            param_count += 1;
            try writer.print(" AND assignee = ?{d}", .{param_count});
            params[param_count - 1] = a;
        }

        if (filters.label) |lbl| {
            param_count += 1;
            try writer.print(" AND l.label = ?{d}", .{param_count});
            params[param_count - 1] = lbl;
        }

        // Order by
        const order_col = switch (filters.order_by) {
            .created_at => if (filters.label != null) "i.created_at" else "created_at",
            .updated_at => if (filters.label != null) "i.updated_at" else "updated_at",
            .priority => if (filters.label != null) "i.priority" else "priority",
        };
        const order_dir = if (filters.order_desc) "DESC" else "ASC";
        try writer.print(" ORDER BY {s} {s}", .{ order_col, order_dir });

        if (filters.limit) |lim| {
            try writer.print(" LIMIT {d}", .{lim});
        }

        if (filters.offset) |off| {
            try writer.print(" OFFSET {d}", .{off});
        }

        const sql = stream.getWritten();

        var stmt = try self.db.prepare(sql);
        defer stmt.deinit();

        // Bind parameters
        for (0..param_count) |i| {
            const idx: u32 = @intCast(i + 1);
            if (int_params[i]) |v| {
                try stmt.bindInt(idx, v);
            } else if (params[i]) |v| {
                try stmt.bindText(idx, v);
            }
        }

        // Collect results
        var results: std.ArrayList(Issue) = .{};
        errdefer {
            for (results.items) |*issue| {
                issue.deinit(self.allocator);
            }
            results.deinit(self.allocator);
        }

        while (try stmt.step()) {
            const issue = try self.rowToIssue(&stmt);
            try results.append(self.allocator, issue);
        }

        return results.toOwnedSlice(self.allocator);
    }

    /// Result from counting issues.
    pub const CountResult = struct {
        key: []const u8,
        count: u64,
    };

    /// Count issues, optionally grouped by a field.
    pub fn count(self: *Self, group_by: ?GroupBy) ![]CountResult {
        const sql = if (group_by) |g| switch (g) {
            .status => "SELECT status as grp, COUNT(*) as cnt FROM issues WHERE status != 'tombstone' GROUP BY status",
            .priority => "SELECT CAST(priority AS TEXT) as grp, COUNT(*) as cnt FROM issues WHERE status != 'tombstone' GROUP BY priority",
            .issue_type => "SELECT issue_type as grp, COUNT(*) as cnt FROM issues WHERE status != 'tombstone' GROUP BY issue_type",
            .assignee => "SELECT COALESCE(assignee, '(unassigned)') as grp, COUNT(*) as cnt FROM issues WHERE status != 'tombstone' GROUP BY assignee",
        } else "SELECT 'total' as grp, COUNT(*) as cnt FROM issues WHERE status != 'tombstone'";

        var stmt = try self.db.prepare(sql);
        defer stmt.deinit();

        var results: std.ArrayList(CountResult) = .{};
        errdefer {
            for (results.items) |item| {
                self.allocator.free(item.key);
            }
            results.deinit(self.allocator);
        }

        while (try stmt.step()) {
            const key_raw = stmt.columnText(0) orelse "(null)";
            const key = try self.allocator.dupe(u8, key_raw);
            errdefer self.allocator.free(key);

            const cnt: u64 = @intCast(stmt.columnInt(1));
            try results.append(self.allocator, .{ .key = key, .count = cnt });
        }

        return results.toOwnedSlice(self.allocator);
    }

    pub const GroupBy = enum {
        status,
        priority,
        issue_type,
        assignee,
    };

    /// Check if an issue exists.
    pub fn exists(self: *Self, id: []const u8) !bool {
        var stmt = try self.db.prepare("SELECT 1 FROM issues WHERE id = ?1");
        defer stmt.deinit();
        try stmt.bindText(1, id);
        return try stmt.step();
    }

    /// Count total issues (excluding tombstones).
    pub fn countTotal(self: *Self) !usize {
        var stmt = try self.db.prepare("SELECT COUNT(*) FROM issues WHERE status != 'tombstone'");
        defer stmt.deinit();
        if (try stmt.step()) {
            return @intCast(stmt.columnInt(0));
        }
        return 0;
    }

    /// Get labels for an issue.
    pub fn getLabels(self: *Self, issue_id: []const u8) ![]const []const u8 {
        var stmt = try self.db.prepare("SELECT label FROM labels WHERE issue_id = ?1 ORDER BY label");
        defer stmt.deinit();
        try stmt.bindText(1, issue_id);

        var labels: std.ArrayList([]const u8) = .{};
        errdefer {
            for (labels.items) |label| {
                self.allocator.free(label);
            }
            labels.deinit(self.allocator);
        }

        while (try stmt.step()) {
            const label_raw = stmt.columnText(0) orelse continue;
            const label = try self.allocator.dupe(u8, label_raw);
            try labels.append(self.allocator, label);
        }

        return labels.toOwnedSlice(self.allocator);
    }

    /// Add a label to an issue.
    pub fn addLabel(self: *Self, issue_id: []const u8, label: []const u8) !void {
        var stmt = try self.db.prepare(
            "INSERT OR IGNORE INTO labels (issue_id, label) VALUES (?1, ?2)"
        );
        defer stmt.deinit();
        try stmt.bindText(1, issue_id);
        try stmt.bindText(2, label);
        _ = try stmt.step();
        try self.markDirty(issue_id);
    }

    /// Remove a label from an issue.
    pub fn removeLabel(self: *Self, issue_id: []const u8, label: []const u8) !void {
        var stmt = try self.db.prepare(
            "DELETE FROM labels WHERE issue_id = ?1 AND label = ?2"
        );
        defer stmt.deinit();
        try stmt.bindText(1, issue_id);
        try stmt.bindText(2, label);
        _ = try stmt.step();
        try self.markDirty(issue_id);
    }

    /// Get dependencies for an issue (where this issue depends on others).
    pub fn getDependencies(self: *Self, issue_id: []const u8) ![]const Dependency {
        var stmt = try self.db.prepare(
            \\SELECT issue_id, depends_on_id, dep_type, created_at, created_by, metadata, thread_id
            \\FROM dependencies WHERE issue_id = ?1
        );
        defer stmt.deinit();
        try stmt.bindText(1, issue_id);

        var deps: std.ArrayList(Dependency) = .{};
        errdefer {
            for (deps.items) |*dep| {
                self.allocator.free(dep.issue_id);
                self.allocator.free(dep.depends_on_id);
                switch (dep.dep_type) {
                    .custom => |s| self.allocator.free(s),
                    else => {},
                }
                if (dep.created_by) |c| self.allocator.free(c);
                if (dep.metadata) |m| self.allocator.free(m);
                if (dep.thread_id) |t| self.allocator.free(t);
            }
            deps.deinit(self.allocator);
        }

        while (try stmt.step()) {
            var dep: Dependency = undefined;

            const issue_id_raw = stmt.columnText(0) orelse continue;
            dep.issue_id = try self.allocator.dupe(u8, issue_id_raw);
            errdefer self.allocator.free(dep.issue_id);

            const depends_on_raw = stmt.columnText(1) orelse continue;
            dep.depends_on_id = try self.allocator.dupe(u8, depends_on_raw);
            errdefer self.allocator.free(dep.depends_on_id);

            const dep_type_raw = stmt.columnText(2) orelse "blocks";
            const parsed_type = DependencyType.fromString(dep_type_raw);
            dep.dep_type = switch (parsed_type) {
                .custom => |s| DependencyType{ .custom = try self.allocator.dupe(u8, s) },
                else => parsed_type,
            };

            dep.created_at = stmt.columnInt(3);

            if (stmt.columnText(4)) |c| {
                dep.created_by = try self.allocator.dupe(u8, c);
            } else {
                dep.created_by = null;
            }

            if (stmt.columnText(5)) |m| {
                dep.metadata = try self.allocator.dupe(u8, m);
            } else {
                dep.metadata = null;
            }

            if (stmt.columnText(6)) |t| {
                dep.thread_id = try self.allocator.dupe(u8, t);
            } else {
                dep.thread_id = null;
            }

            try deps.append(self.allocator, dep);
        }

        return deps.toOwnedSlice(self.allocator);
    }

    /// Get comments for an issue.
    pub fn getComments(self: *Self, issue_id: []const u8) ![]const Comment {
        var stmt = try self.db.prepare(
            \\SELECT id, issue_id, author, body, created_at
            \\FROM comments WHERE issue_id = ?1 ORDER BY created_at
        );
        defer stmt.deinit();
        try stmt.bindText(1, issue_id);

        var comments: std.ArrayList(Comment) = .{};
        errdefer {
            for (comments.items) |*c| {
                self.allocator.free(c.issue_id);
                self.allocator.free(c.author);
                self.allocator.free(c.text);
            }
            comments.deinit(self.allocator);
        }

        while (try stmt.step()) {
            var comment: Comment = undefined;

            comment.id = stmt.columnInt(0);

            const issue_id_raw = stmt.columnText(1) orelse continue;
            comment.issue_id = try self.allocator.dupe(u8, issue_id_raw);
            errdefer self.allocator.free(comment.issue_id);

            const author_raw = stmt.columnText(2) orelse continue;
            comment.author = try self.allocator.dupe(u8, author_raw);
            errdefer self.allocator.free(comment.author);

            const body_raw = stmt.columnText(3) orelse continue;
            comment.text = try self.allocator.dupe(u8, body_raw);

            comment.created_at = stmt.columnInt(4);

            try comments.append(self.allocator, comment);
        }

        return comments.toOwnedSlice(self.allocator);
    }

    /// Add a comment to an issue.
    pub fn addComment(self: *Self, issue_id: []const u8, comment: Comment) !void {
        var stmt = try self.db.prepare(
            "INSERT INTO comments (issue_id, author, body, created_at) VALUES (?1, ?2, ?3, ?4)",
        );
        defer stmt.deinit();
        try stmt.bindText(1, issue_id);
        try stmt.bindText(2, comment.author);
        try stmt.bindText(3, comment.text);
        try stmt.bindInt(4, comment.created_at);
        _ = try stmt.step();
        try self.markDirty(issue_id);
    }

    /// Count total non-tombstone issues.
    pub fn getAllLabels(self: *Self) ![]const []const u8 {
        var stmt = try self.db.prepare(
            "SELECT DISTINCT label FROM labels ORDER BY label",
        );
        defer stmt.deinit();

        var labels: std.ArrayList([]const u8) = .{};
        errdefer {
            for (labels.items) |label| {
                self.allocator.free(label);
            }
            labels.deinit(self.allocator);
        }

        while (try stmt.step()) {
            const label_raw = stmt.columnText(0) orelse continue;
            const label = try self.allocator.dupe(u8, label_raw);
            try labels.append(self.allocator, label);
        }

        return labels.toOwnedSlice(self.allocator);
    }

    /// Rename a label across all issues. Returns count of affected issues.
    pub fn renameLabel(self: *Self, old_name: []const u8, new_name: []const u8) !usize {
        // For issues that already have the new label, just remove the old one
        var remove_stmt = try self.db.prepare(
            \\DELETE FROM labels WHERE label = ?1 AND issue_id IN (
            \\    SELECT issue_id FROM labels WHERE label = ?2
            \\)
        );
        defer remove_stmt.deinit();
        try remove_stmt.bindText(1, old_name);
        try remove_stmt.bindText(2, new_name);
        _ = try remove_stmt.step();

        // For remaining issues, rename in place
        var rename_stmt = try self.db.prepare(
            "UPDATE labels SET label = ?1 WHERE label = ?2",
        );
        defer rename_stmt.deinit();
        try rename_stmt.bindText(1, new_name);
        try rename_stmt.bindText(2, old_name);
        _ = try rename_stmt.step();

        return @intCast(self.db.changes());
    }

    /// Build an ID index map (used for ID generation collision avoidance).
    pub fn buildIdIndex(self: *Self) !std.StringHashMapUnmanaged(void) {
        var stmt = try self.db.prepare("SELECT id FROM issues WHERE status != 'tombstone'");
        defer stmt.deinit();

        var index: std.StringHashMapUnmanaged(void) = .{};
        errdefer {
            var it = index.keyIterator();
            while (it.next()) |key| {
                self.allocator.free(key.*);
            }
            index.deinit(self.allocator);
        }

        while (try stmt.step()) {
            const id_raw = stmt.columnText(0) orelse continue;
            const id = try self.allocator.dupe(u8, id_raw);
            try index.put(self.allocator, id, {});
        }

        return index;
    }

    /// Search issues using FTS5 full-text search. Falls back to LIKE if FTS5 fails.
    pub fn search(self: *Self, query: []const u8) ![]Issue {
        // Try FTS5 first
        var fts_stmt = self.db.prepare(
            \\SELECT i.id, i.content_hash, i.title, i.description, i.design,
            \\       i.acceptance_criteria, i.notes, i.status, i.priority, i.issue_type,
            \\       i.assignee, i.owner, i.estimated_minutes, i.created_at, i.created_by,
            \\       i.updated_at, i.closed_at, i.close_reason, i.due_at, i.defer_until,
            \\       i.external_ref, i.source_system, i.pinned, i.is_template
            \\FROM issues_fts f
            \\JOIN issues i ON f.rowid = i.rowid
            \\WHERE issues_fts MATCH ?1 AND i.status != 'tombstone'
            \\ORDER BY rank
        ) catch {
            return self.searchFallback(query);
        };
        defer fts_stmt.deinit();
        fts_stmt.bindText(1, query) catch {
            return self.searchFallback(query);
        };

        return self.collectIssuesFromStmt(&fts_stmt) catch {
            return self.searchFallback(query);
        };
    }

    /// Fallback search using LIKE when FTS5 is unavailable.
    fn searchFallback(self: *Self, query: []const u8) ![]Issue {
        var sql_buf: [512]u8 = undefined;
        var stream = std.io.fixedBufferStream(&sql_buf);
        const writer = stream.writer();

        try writer.writeAll(
            \\SELECT id, content_hash, title, description, design, acceptance_criteria,
            \\       notes, status, priority, issue_type, assignee, owner,
            \\       estimated_minutes, created_at, created_by, updated_at,
            \\       closed_at, close_reason, due_at, defer_until,
            \\       external_ref, source_system, pinned, is_template
            \\FROM issues WHERE status != 'tombstone'
            \\ AND (title LIKE ?1 OR description LIKE ?1)
            \\ ORDER BY updated_at DESC
        );

        const sql = stream.getWritten();
        var stmt = try self.db.prepare(sql);
        defer stmt.deinit();

        const like_pattern = try std.fmt.allocPrint(self.allocator, "%{s}%", .{query});
        defer self.allocator.free(like_pattern);
        try stmt.bindText(1, like_pattern);

        return self.collectIssuesFromStmt(&stmt);
    }

    /// Mark an issue as dirty for sync.
    pub fn markDirty(self: *Self, id: []const u8) !void {
        const now = std.time.timestamp();
        var stmt = try self.db.prepare(
            "INSERT OR REPLACE INTO dirty_issues (issue_id, marked_at) VALUES (?1, ?2)",
        );
        defer stmt.deinit();
        try stmt.bindText(1, id);
        try stmt.bindInt(2, now);
        _ = try stmt.step();
    }

    /// Clear dirty flag for an issue.
    pub fn clearDirty(self: *Self, id: []const u8) !void {
        var stmt = try self.db.prepare("DELETE FROM dirty_issues WHERE issue_id = ?1");
        defer stmt.deinit();
        try stmt.bindText(1, id);
        _ = try stmt.step();
    }

    /// Get all dirty issue IDs.
    pub fn getDirtyIds(self: *Self) ![][]const u8 {
        var stmt = try self.db.prepare("SELECT issue_id FROM dirty_issues");
        defer stmt.deinit();

        var ids: std.ArrayList([]const u8) = .{};
        errdefer {
            for (ids.items) |id| {
                self.allocator.free(id);
            }
            ids.deinit(self.allocator);
        }

        while (try stmt.step()) {
            const id_raw = stmt.columnText(0) orelse continue;
            const id = try self.allocator.dupe(u8, id_raw);
            try ids.append(self.allocator, id);
        }

        return ids.toOwnedSlice(self.allocator);
    }

    /// Collect issues from an already-prepared statement.
    /// Useful for callers who need custom SQL but want standard issue parsing.
    pub fn collectIssuesFromStmt(self: *Self, stmt: *Statement) ![]Issue {
        var results: std.ArrayList(Issue) = .{};
        errdefer {
            for (results.items) |*issue| {
                issue.deinit(self.allocator);
            }
            results.deinit(self.allocator);
        }

        while (try stmt.step()) {
            const issue = try self.rowToIssue(stmt);
            try results.append(self.allocator, issue);
        }

        return results.toOwnedSlice(self.allocator);
    }

    /// Convert a database row to an Issue struct.
    fn rowToIssue(self: *Self, stmt: *Statement) !Issue {
        var issue: Issue = undefined;

        // Required fields
        issue.id = try self.dupeColumnText(stmt, 0) orelse return IssueStoreError.InvalidIssue;
        errdefer self.allocator.free(issue.id);

        issue.title = try self.dupeColumnText(stmt, 2) orelse return IssueStoreError.InvalidIssue;
        errdefer self.allocator.free(issue.title);

        // Optional text fields
        issue.content_hash = try self.dupeColumnText(stmt, 1);
        errdefer if (issue.content_hash) |h| self.allocator.free(h);

        issue.description = try self.dupeColumnText(stmt, 3);
        errdefer if (issue.description) |d| self.allocator.free(d);

        issue.design = try self.dupeColumnText(stmt, 4);
        errdefer if (issue.design) |d| self.allocator.free(d);

        issue.acceptance_criteria = try self.dupeColumnText(stmt, 5);
        errdefer if (issue.acceptance_criteria) |a| self.allocator.free(a);

        issue.notes = try self.dupeColumnText(stmt, 6);
        errdefer if (issue.notes) |n| self.allocator.free(n);

        issue.assignee = try self.dupeColumnText(stmt, 10);
        errdefer if (issue.assignee) |a| self.allocator.free(a);

        issue.owner = try self.dupeColumnText(stmt, 11);
        errdefer if (issue.owner) |o| self.allocator.free(o);

        issue.created_by = try self.dupeColumnText(stmt, 14);
        errdefer if (issue.created_by) |c| self.allocator.free(c);

        issue.close_reason = try self.dupeColumnText(stmt, 17);
        errdefer if (issue.close_reason) |r| self.allocator.free(r);

        issue.external_ref = try self.dupeColumnText(stmt, 20);
        errdefer if (issue.external_ref) |e| self.allocator.free(e);

        issue.source_system = try self.dupeColumnText(stmt, 21);
        errdefer if (issue.source_system) |s| self.allocator.free(s);

        // Enum fields with custom variant handling
        const status_raw = stmt.columnText(7) orelse "open";
        const parsed_status = Status.fromString(status_raw);
        issue.status = switch (parsed_status) {
            .custom => |s| Status{ .custom = try self.allocator.dupe(u8, s) },
            else => parsed_status,
        };

        const type_raw = stmt.columnText(9) orelse "task";
        const parsed_type = IssueType.fromString(type_raw);
        issue.issue_type = switch (parsed_type) {
            .custom => |s| IssueType{ .custom = try self.allocator.dupe(u8, s) },
            else => parsed_type,
        };

        issue.priority = Priority.fromInt(stmt.columnInt(8)) catch Priority.MEDIUM;

        // Numeric fields
        issue.estimated_minutes = stmt.columnOptionalInt32(12);
        issue.created_at = Rfc3339Timestamp{ .value = stmt.columnInt(13) };
        issue.updated_at = Rfc3339Timestamp{ .value = stmt.columnInt(15) };
        issue.closed_at = OptionalRfc3339Timestamp{ .value = stmt.columnOptionalInt(16) };
        issue.due_at = OptionalRfc3339Timestamp{ .value = stmt.columnOptionalInt(18) };
        issue.defer_until = OptionalRfc3339Timestamp{ .value = stmt.columnOptionalInt(19) };

        // Boolean fields
        issue.pinned = stmt.columnBool(22);
        issue.is_template = stmt.columnBool(23);

        // Initialize embedded relations as empty
        issue.labels = &[_][]const u8{};
        issue.dependencies = &[_]Dependency{};
        issue.comments = &[_]Comment{};

        return issue;
    }

    /// Helper to duplicate optional column text.
    fn dupeColumnText(self: *Self, stmt: *Statement, idx: u32) !?[]const u8 {
        return if (stmt.columnText(idx)) |text|
            try self.allocator.dupe(u8, text)
        else
            null;
    }
};

// Tests

const schema = @import("schema.zig");

test "IssueStore.insert creates issue" {
    const allocator = std.testing.allocator;
    var db = try Database.open(allocator, ":memory:");
    defer db.close();

    try schema.createSchema(&db);

    var store = IssueStore.init(&db, allocator);
    const issue = Issue.init("bd-test1", "Test Issue", 1706540000);

    try store.insert(issue);

    // Verify it exists
    const found = try store.exists("bd-test1");
    try std.testing.expect(found);
}

test "IssueStore.get retrieves issue" {
    const allocator = std.testing.allocator;
    var db = try Database.open(allocator, ":memory:");
    defer db.close();

    try schema.createSchema(&db);

    var store = IssueStore.init(&db, allocator);
    const original = Issue.init("bd-test2", "Get Test", 1706540000);

    try store.insert(original);

    var retrieved = (try store.get("bd-test2")).?;
    defer retrieved.deinit(allocator);

    try std.testing.expectEqualStrings("bd-test2", retrieved.id);
    try std.testing.expectEqualStrings("Get Test", retrieved.title);
    try std.testing.expectEqual(Status.open, retrieved.status);
    try std.testing.expectEqual(Priority.MEDIUM, retrieved.priority);
}

test "IssueStore.get returns null for missing issue" {
    const allocator = std.testing.allocator;
    var db = try Database.open(allocator, ":memory:");
    defer db.close();

    try schema.createSchema(&db);

    var store = IssueStore.init(&db, allocator);
    const result = try store.get("bd-nonexistent");
    try std.testing.expect(result == null);
}

test "IssueStore.update modifies fields" {
    const allocator = std.testing.allocator;
    var db = try Database.open(allocator, ":memory:");
    defer db.close();

    try schema.createSchema(&db);

    var store = IssueStore.init(&db, allocator);
    const issue = Issue.init("bd-update", "Original Title", 1706540000);

    try store.insert(issue);

    try store.update("bd-update", .{
        .title = "Updated Title",
        .status = .in_progress,
        .priority = Priority.HIGH,
    }, 1706550000);

    var updated = (try store.get("bd-update")).?;
    defer updated.deinit(allocator);

    try std.testing.expectEqualStrings("Updated Title", updated.title);
    try std.testing.expectEqual(Status.in_progress, updated.status);
    try std.testing.expectEqual(Priority.HIGH, updated.priority);
    try std.testing.expectEqual(@as(i64, 1706550000), updated.updated_at.value);
}

test "IssueStore.update returns error for missing issue" {
    const allocator = std.testing.allocator;
    var db = try Database.open(allocator, ":memory:");
    defer db.close();

    try schema.createSchema(&db);

    var store = IssueStore.init(&db, allocator);
    const result = store.update("bd-missing", .{ .title = "New" }, 1706550000);
    try std.testing.expectError(IssueStoreError.IssueNotFound, result);
}

test "IssueStore.delete sets tombstone status" {
    const allocator = std.testing.allocator;
    var db = try Database.open(allocator, ":memory:");
    defer db.close();

    try schema.createSchema(&db);

    var store = IssueStore.init(&db, allocator);
    const issue = Issue.init("bd-delete", "To Delete", 1706540000);

    try store.insert(issue);
    try store.delete("bd-delete", 1706550000);

    var deleted = (try store.get("bd-delete")).?;
    defer deleted.deinit(allocator);

    try std.testing.expectEqual(Status.tombstone, deleted.status);
}

test "IssueStore.list returns issues" {
    const allocator = std.testing.allocator;
    var db = try Database.open(allocator, ":memory:");
    defer db.close();

    try schema.createSchema(&db);

    var store = IssueStore.init(&db, allocator);

    try store.insert(Issue.init("bd-list1", "Issue 1", 1706540000));
    try store.insert(Issue.init("bd-list2", "Issue 2", 1706550000));
    try store.insert(Issue.init("bd-list3", "Issue 3", 1706560000));

    const issues = try store.list(.{});
    defer {
        for (issues) |*issue| {
            var i = issue.*;
            i.deinit(allocator);
        }
        allocator.free(issues);
    }

    try std.testing.expectEqual(@as(usize, 3), issues.len);
}

test "IssueStore.list excludes tombstones by default" {
    const allocator = std.testing.allocator;
    var db = try Database.open(allocator, ":memory:");
    defer db.close();

    try schema.createSchema(&db);

    var store = IssueStore.init(&db, allocator);

    try store.insert(Issue.init("bd-active", "Active", 1706540000));
    try store.insert(Issue.init("bd-deleted", "Deleted", 1706550000));
    try store.delete("bd-deleted", 1706560000);

    const issues = try store.list(.{});
    defer {
        for (issues) |*issue| {
            var i = issue.*;
            i.deinit(allocator);
        }
        allocator.free(issues);
    }

    try std.testing.expectEqual(@as(usize, 1), issues.len);
    try std.testing.expectEqualStrings("bd-active", issues[0].id);
}

test "IssueStore.list with status filter" {
    const allocator = std.testing.allocator;
    var db = try Database.open(allocator, ":memory:");
    defer db.close();

    try schema.createSchema(&db);

    var store = IssueStore.init(&db, allocator);

    var issue1 = Issue.init("bd-open", "Open Issue", 1706540000);
    issue1.status = .open;
    try store.insert(issue1);

    var issue2 = Issue.init("bd-closed", "Closed Issue", 1706550000);
    issue2.status = .closed;
    try store.insert(issue2);

    const issues = try store.list(.{ .status = .open });
    defer {
        for (issues) |*issue| {
            var i = issue.*;
            i.deinit(allocator);
        }
        allocator.free(issues);
    }

    try std.testing.expectEqual(@as(usize, 1), issues.len);
    try std.testing.expectEqualStrings("bd-open", issues[0].id);
}

test "IssueStore.list with priority filter" {
    const allocator = std.testing.allocator;
    var db = try Database.open(allocator, ":memory:");
    defer db.close();

    try schema.createSchema(&db);

    var store = IssueStore.init(&db, allocator);

    var issue1 = Issue.init("bd-high", "High Priority", 1706540000);
    issue1.priority = Priority.HIGH;
    try store.insert(issue1);

    var issue2 = Issue.init("bd-low", "Low Priority", 1706550000);
    issue2.priority = Priority.LOW;
    try store.insert(issue2);

    const issues = try store.list(.{ .priority = Priority.HIGH });
    defer {
        for (issues) |*issue| {
            var i = issue.*;
            i.deinit(allocator);
        }
        allocator.free(issues);
    }

    try std.testing.expectEqual(@as(usize, 1), issues.len);
    try std.testing.expectEqualStrings("bd-high", issues[0].id);
}

test "IssueStore.list with limit and offset" {
    const allocator = std.testing.allocator;
    var db = try Database.open(allocator, ":memory:");
    defer db.close();

    try schema.createSchema(&db);

    var store = IssueStore.init(&db, allocator);

    try store.insert(Issue.init("bd-1", "Issue 1", 1706540000));
    try store.insert(Issue.init("bd-2", "Issue 2", 1706550000));
    try store.insert(Issue.init("bd-3", "Issue 3", 1706560000));
    try store.insert(Issue.init("bd-4", "Issue 4", 1706570000));

    const issues = try store.list(.{ .limit = 2, .offset = 1 });
    defer {
        for (issues) |*issue| {
            var i = issue.*;
            i.deinit(allocator);
        }
        allocator.free(issues);
    }

    try std.testing.expectEqual(@as(usize, 2), issues.len);
}

test "IssueStore.list ordering" {
    const allocator = std.testing.allocator;
    var db = try Database.open(allocator, ":memory:");
    defer db.close();

    try schema.createSchema(&db);

    var store = IssueStore.init(&db, allocator);

    try store.insert(Issue.init("bd-old", "Old", 1706540000));
    try store.insert(Issue.init("bd-new", "New", 1706550000));

    // Default: created_at DESC
    const desc = try store.list(.{});
    defer {
        for (desc) |*issue| {
            var i = issue.*;
            i.deinit(allocator);
        }
        allocator.free(desc);
    }
    try std.testing.expectEqualStrings("bd-new", desc[0].id);

    // created_at ASC
    const asc = try store.list(.{ .order_desc = false });
    defer {
        for (asc) |*issue| {
            var i = issue.*;
            i.deinit(allocator);
        }
        allocator.free(asc);
    }
    try std.testing.expectEqualStrings("bd-old", asc[0].id);
}

test "IssueStore dirty tracking" {
    const allocator = std.testing.allocator;
    var db = try Database.open(allocator, ":memory:");
    defer db.close();

    try schema.createSchema(&db);

    var store = IssueStore.init(&db, allocator);
    const issue = Issue.init("bd-dirty", "Dirty Test", 1706540000);

    try store.insert(issue);

    // Should be marked dirty after insert
    const dirty_ids = try store.getDirtyIds();
    defer {
        for (dirty_ids) |id| {
            allocator.free(id);
        }
        allocator.free(dirty_ids);
    }

    try std.testing.expectEqual(@as(usize, 1), dirty_ids.len);
    try std.testing.expectEqualStrings("bd-dirty", dirty_ids[0]);

    // Clear dirty
    try store.clearDirty("bd-dirty");

    const after_clear = try store.getDirtyIds();
    defer allocator.free(after_clear);

    try std.testing.expectEqual(@as(usize, 0), after_clear.len);
}

test "IssueStore.getWithRelations includes labels" {
    const allocator = std.testing.allocator;
    var db = try Database.open(allocator, ":memory:");
    defer db.close();

    try schema.createSchema(&db);

    var store = IssueStore.init(&db, allocator);
    const issue = Issue.init("bd-labels", "Issue with Labels", 1706540000);

    try store.insert(issue);

    // Add labels manually
    try db.exec("INSERT INTO labels (issue_id, label) VALUES ('bd-labels', 'bug')");
    try db.exec("INSERT INTO labels (issue_id, label) VALUES ('bd-labels', 'urgent')");

    var retrieved = (try store.getWithRelations("bd-labels")).?;
    defer retrieved.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), retrieved.labels.len);
}

test "IssueStore.getWithRelations includes dependencies" {
    const allocator = std.testing.allocator;
    var db = try Database.open(allocator, ":memory:");
    defer db.close();

    try schema.createSchema(&db);

    var store = IssueStore.init(&db, allocator);

    try store.insert(Issue.init("bd-parent", "Parent", 1706540000));
    try store.insert(Issue.init("bd-child", "Child", 1706540000));

    // Add dependency
    try db.exec(
        \\INSERT INTO dependencies (issue_id, depends_on_id, dep_type, created_at)
        \\VALUES ('bd-child', 'bd-parent', 'blocks', 1706540000)
    );

    var retrieved = (try store.getWithRelations("bd-child")).?;
    defer retrieved.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), retrieved.dependencies.len);
    try std.testing.expectEqualStrings("bd-parent", retrieved.dependencies[0].depends_on_id);
}

test "IssueStore.getWithRelations includes comments" {
    const allocator = std.testing.allocator;
    var db = try Database.open(allocator, ":memory:");
    defer db.close();

    try schema.createSchema(&db);

    var store = IssueStore.init(&db, allocator);
    const issue = Issue.init("bd-comments", "Issue with Comments", 1706540000);

    try store.insert(issue);

    // Add comments manually
    try db.exec(
        \\INSERT INTO comments (issue_id, author, body, created_at)
        \\VALUES ('bd-comments', 'alice', 'First comment', 1706540000)
    );
    try db.exec(
        \\INSERT INTO comments (issue_id, author, body, created_at)
        \\VALUES ('bd-comments', 'bob', 'Second comment', 1706550000)
    );

    var retrieved = (try store.getWithRelations("bd-comments")).?;
    defer retrieved.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), retrieved.comments.len);
    try std.testing.expectEqualStrings("First comment", retrieved.comments[0].text);
    try std.testing.expectEqualStrings("Second comment", retrieved.comments[1].text);
}

test "IssueStore.count total" {
    const allocator = std.testing.allocator;
    var db = try Database.open(allocator, ":memory:");
    defer db.close();

    try schema.createSchema(&db);

    var store = IssueStore.init(&db, allocator);

    try store.insert(Issue.init("bd-c1", "Issue 1", 1706540000));
    try store.insert(Issue.init("bd-c2", "Issue 2", 1706550000));
    try store.insert(Issue.init("bd-c3", "Issue 3", 1706560000));

    const counts = try store.count(null);
    defer {
        for (counts) |c| {
            allocator.free(c.key);
        }
        allocator.free(counts);
    }

    try std.testing.expectEqual(@as(usize, 1), counts.len);
    try std.testing.expectEqualStrings("total", counts[0].key);
    try std.testing.expectEqual(@as(u64, 3), counts[0].count);
}

test "IssueStore.count by status" {
    const allocator = std.testing.allocator;
    var db = try Database.open(allocator, ":memory:");
    defer db.close();

    try schema.createSchema(&db);

    var store = IssueStore.init(&db, allocator);

    var issue1 = Issue.init("bd-s1", "Open 1", 1706540000);
    issue1.status = .open;
    try store.insert(issue1);

    var issue2 = Issue.init("bd-s2", "Open 2", 1706550000);
    issue2.status = .open;
    try store.insert(issue2);

    var issue3 = Issue.init("bd-s3", "Closed", 1706560000);
    issue3.status = .closed;
    try store.insert(issue3);

    const counts = try store.count(.status);
    defer {
        for (counts) |c| {
            allocator.free(c.key);
        }
        allocator.free(counts);
    }

    // Should have 2 groups: open and closed
    try std.testing.expectEqual(@as(usize, 2), counts.len);
}

test "IssueStore insert with all fields" {
    const allocator = std.testing.allocator;
    var db = try Database.open(allocator, ":memory:");
    defer db.close();

    try schema.createSchema(&db);

    var store = IssueStore.init(&db, allocator);

    var issue = Issue.init("bd-full", "Full Issue", 1706540000);
    issue.content_hash = "abc123hash";
    issue.description = "A detailed description";
    issue.design = "Design document";
    issue.acceptance_criteria = "Must work";
    issue.notes = "Some notes";
    issue.status = .in_progress;
    issue.priority = Priority.HIGH;
    issue.issue_type = .bug;
    issue.assignee = "alice@example.com";
    issue.owner = "bob@example.com";
    issue.estimated_minutes = 120;
    issue.created_by = "creator@example.com";
    issue.closed_at = .{ .value = 1706600000 };
    issue.close_reason = "Fixed";
    issue.due_at = .{ .value = 1706700000 };
    issue.defer_until = .{ .value = 1706650000 };
    issue.external_ref = "JIRA-123";
    issue.source_system = "jira";
    issue.pinned = true;
    issue.is_template = false;

    try store.insert(issue);

    var retrieved = (try store.get("bd-full")).?;
    defer retrieved.deinit(allocator);

    try std.testing.expectEqualStrings("Full Issue", retrieved.title);
    try std.testing.expectEqualStrings("abc123hash", retrieved.content_hash.?);
    try std.testing.expectEqualStrings("A detailed description", retrieved.description.?);
    try std.testing.expectEqualStrings("Design document", retrieved.design.?);
    try std.testing.expectEqualStrings("Must work", retrieved.acceptance_criteria.?);
    try std.testing.expectEqualStrings("Some notes", retrieved.notes.?);
    try std.testing.expectEqual(Status.in_progress, retrieved.status);
    try std.testing.expectEqual(Priority.HIGH, retrieved.priority);
    try std.testing.expectEqual(IssueType.bug, retrieved.issue_type);
    try std.testing.expectEqualStrings("alice@example.com", retrieved.assignee.?);
    try std.testing.expectEqualStrings("bob@example.com", retrieved.owner.?);
    try std.testing.expectEqual(@as(i32, 120), retrieved.estimated_minutes.?);
    try std.testing.expectEqualStrings("creator@example.com", retrieved.created_by.?);
    try std.testing.expectEqual(@as(i64, 1706600000), retrieved.closed_at.value.?);
    try std.testing.expectEqualStrings("Fixed", retrieved.close_reason.?);
    try std.testing.expectEqual(@as(i64, 1706700000), retrieved.due_at.value.?);
    try std.testing.expectEqual(@as(i64, 1706650000), retrieved.defer_until.value.?);
    try std.testing.expectEqualStrings("JIRA-123", retrieved.external_ref.?);
    try std.testing.expectEqualStrings("jira", retrieved.source_system.?);
    try std.testing.expect(retrieved.pinned);
    try std.testing.expect(!retrieved.is_template);
}
