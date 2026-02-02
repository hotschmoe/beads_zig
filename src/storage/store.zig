//! In-memory issue store for beads_zig.
//!
//! Provides CRUD operations for issues using in-memory storage with:
//! - Arena allocator for issue memory management
//! - ArrayList + StringHashMap for fast ID lookup
//! - Dirty tracking for sync operations
//! - JSONL persistence via JsonlFile

const std = @import("std");
const JsonlFile = @import("jsonl.zig").JsonlFile;
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
    VersionMismatch,
};

/// Result of loading the store with corruption tracking.
pub const StoreLoadResult = struct {
    /// Number of corrupt JSONL entries skipped.
    jsonl_corruption_count: usize = 0,
    /// Line numbers of corrupt JSONL entries (1-indexed).
    jsonl_corrupt_lines: []const usize = &.{},

    pub fn hasCorruption(self: StoreLoadResult) bool {
        return self.jsonl_corruption_count > 0;
    }

    pub fn deinit(self: *StoreLoadResult, allocator: std.mem.Allocator) void {
        if (self.jsonl_corrupt_lines.len > 0) {
            allocator.free(self.jsonl_corrupt_lines);
        }
    }
};

pub const IssueStore = struct {
    allocator: std.mem.Allocator,
    issues: std.ArrayListUnmanaged(Issue),
    id_index: std.StringHashMapUnmanaged(usize),
    dirty_ids: std.StringHashMapUnmanaged(i64),
    dirty: bool,
    jsonl_path: []const u8,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, jsonl_path: []const u8) Self {
        return .{
            .allocator = allocator,
            .issues = .{},
            .id_index = .{},
            .dirty_ids = .{},
            .dirty = false,
            .jsonl_path = jsonl_path,
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.issues.items) |*issue| {
            issue.deinit(self.allocator);
        }
        self.issues.deinit(self.allocator);

        var id_it = self.id_index.keyIterator();
        while (id_it.next()) |key| {
            self.allocator.free(key.*);
        }
        self.id_index.deinit(self.allocator);

        var dirty_it = self.dirty_ids.keyIterator();
        while (dirty_it.next()) |key| {
            self.allocator.free(key.*);
        }
        self.dirty_ids.deinit(self.allocator);
    }

    /// Load issues from the JSONL file into memory.
    pub fn loadFromFile(self: *Self) !void {
        var jsonl = JsonlFile.init(self.jsonl_path, self.allocator);
        const loaded_issues = try jsonl.readAll();
        defer self.allocator.free(loaded_issues);

        for (loaded_issues) |issue| {
            const id_copy = try self.allocator.dupe(u8, issue.id);
            errdefer self.allocator.free(id_copy);

            const idx = self.issues.items.len;
            try self.issues.append(self.allocator, issue);
            try self.id_index.put(self.allocator, id_copy, idx);
        }

        self.dirty = false;
    }

    /// Load issues from the JSONL file with graceful corruption recovery.
    /// Logs and skips corrupt entries instead of failing.
    /// Returns statistics about the load including corruption count.
    pub fn loadFromFileWithRecovery(self: *Self) !StoreLoadResult {
        var jsonl = JsonlFile.init(self.jsonl_path, self.allocator);
        var load_result = try jsonl.readAllWithRecovery();
        // Take ownership of corrupt_lines before freeing issues slice
        const corrupt_lines = load_result.corrupt_lines;
        load_result.corrupt_lines = &.{}; // Prevent double-free
        errdefer if (corrupt_lines.len > 0) self.allocator.free(corrupt_lines);

        const loaded_issues = load_result.issues;
        defer self.allocator.free(loaded_issues);

        for (loaded_issues) |issue| {
            const id_copy = try self.allocator.dupe(u8, issue.id);
            errdefer self.allocator.free(id_copy);

            const idx = self.issues.items.len;
            try self.issues.append(self.allocator, issue);
            try self.id_index.put(self.allocator, id_copy, idx);
        }

        self.dirty = false;

        return StoreLoadResult{
            .jsonl_corruption_count = load_result.corruption_count,
            .jsonl_corrupt_lines = corrupt_lines,
        };
    }

    /// Save all issues to the JSONL file.
    pub fn saveToFile(self: *Self) !void {
        var jsonl = JsonlFile.init(self.jsonl_path, self.allocator);
        try jsonl.writeAll(self.issues.items);
        self.dirty = false;

        // Clear dirty tracking
        var dirty_it = self.dirty_ids.keyIterator();
        while (dirty_it.next()) |key| {
            self.allocator.free(key.*);
        }
        self.dirty_ids.clearRetainingCapacity();
    }

    /// Insert a new issue into the store.
    pub fn insert(self: *Self, issue: Issue) !void {
        if (self.id_index.contains(issue.id)) {
            return IssueStoreError.DuplicateId;
        }

        const cloned = try issue.clone(self.allocator);
        errdefer {
            var c = cloned;
            c.deinit(self.allocator);
        }

        const id_copy = try self.allocator.dupe(u8, cloned.id);
        errdefer self.allocator.free(id_copy);

        const idx = self.issues.items.len;
        try self.issues.append(self.allocator, cloned);
        try self.id_index.put(self.allocator, id_copy, idx);

        try self.markDirty(issue.id);
    }

    /// Get an issue by ID (without embedded relations).
    pub fn get(self: *Self, id: []const u8) !?Issue {
        const idx = self.id_index.get(id) orelse return null;
        if (idx >= self.issues.items.len) return null;

        return try self.issues.items[idx].clone(self.allocator);
    }

    /// Get an issue with all embedded relations (labels, deps, comments).
    /// Since we store everything in-memory, this just returns the issue as-is.
    pub fn getWithRelations(self: *Self, id: []const u8) !?Issue {
        return try self.get(id);
    }

    /// Get a reference to the stored issue (no clone).
    /// Caller must NOT free or modify the returned issue.
    pub fn getRef(self: *Self, id: []const u8) ?*Issue {
        const idx = self.id_index.get(id) orelse return null;
        if (idx >= self.issues.items.len) return null;
        return &self.issues.items[idx];
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

        /// Expected version for optimistic locking.
        /// If set, update will fail with VersionMismatch if issue.version != expected_version.
        expected_version: ?u64 = null,
    };

    /// Update an issue with the given fields.
    /// If updates.expected_version is set, performs optimistic locking check.
    pub fn update(self: *Self, id: []const u8, updates: IssueUpdate, now: i64) !void {
        const idx = self.id_index.get(id) orelse return IssueStoreError.IssueNotFound;
        if (idx >= self.issues.items.len) return IssueStoreError.IssueNotFound;

        var issue = &self.issues.items[idx];

        // Optimistic locking check
        if (updates.expected_version) |expected| {
            if (issue.version != expected) {
                return IssueStoreError.VersionMismatch;
            }
        }

        // Increment version on every update
        issue.version += 1;

        // Update timestamp
        issue.updated_at = Rfc3339Timestamp{ .value = now };

        // Apply updates
        if (updates.title) |v| {
            self.allocator.free(issue.title);
            issue.title = try self.allocator.dupe(u8, v);
        }
        if (updates.description) |v| {
            if (issue.description) |d| self.allocator.free(d);
            issue.description = try self.allocator.dupe(u8, v);
        }
        if (updates.design) |v| {
            if (issue.design) |d| self.allocator.free(d);
            issue.design = try self.allocator.dupe(u8, v);
        }
        if (updates.acceptance_criteria) |v| {
            if (issue.acceptance_criteria) |a| self.allocator.free(a);
            issue.acceptance_criteria = try self.allocator.dupe(u8, v);
        }
        if (updates.notes) |v| {
            if (issue.notes) |n| self.allocator.free(n);
            issue.notes = try self.allocator.dupe(u8, v);
        }
        if (updates.status) |v| {
            freeStatus(issue.status, self.allocator);
            issue.status = try cloneStatus(v, self.allocator);
        }
        if (updates.priority) |v| {
            issue.priority = v;
        }
        if (updates.issue_type) |v| {
            freeIssueType(issue.issue_type, self.allocator);
            issue.issue_type = try cloneIssueType(v, self.allocator);
        }
        if (updates.assignee) |v| {
            if (issue.assignee) |a| self.allocator.free(a);
            issue.assignee = try self.allocator.dupe(u8, v);
        }
        if (updates.owner) |v| {
            if (issue.owner) |o| self.allocator.free(o);
            issue.owner = try self.allocator.dupe(u8, v);
        }
        if (updates.estimated_minutes) |v| {
            issue.estimated_minutes = v;
        }
        if (updates.closed_at) |v| {
            issue.closed_at = OptionalRfc3339Timestamp{ .value = v };
        }
        if (updates.close_reason) |v| {
            if (issue.close_reason) |r| self.allocator.free(r);
            issue.close_reason = try self.allocator.dupe(u8, v);
        }
        if (updates.closed_by_session) |v| {
            if (issue.closed_by_session) |s| self.allocator.free(s);
            issue.closed_by_session = try self.allocator.dupe(u8, v);
        }
        if (updates.due_at) |v| {
            issue.due_at = OptionalRfc3339Timestamp{ .value = v };
        }
        if (updates.defer_until) |v| {
            issue.defer_until = OptionalRfc3339Timestamp{ .value = v };
        }
        if (updates.external_ref) |v| {
            if (issue.external_ref) |e| self.allocator.free(e);
            issue.external_ref = try self.allocator.dupe(u8, v);
        }
        if (updates.source_system) |v| {
            if (issue.source_system) |s| self.allocator.free(s);
            issue.source_system = try self.allocator.dupe(u8, v);
        }
        if (updates.pinned) |v| {
            issue.pinned = v;
        }
        if (updates.is_template) |v| {
            issue.is_template = v;
        }
        if (updates.content_hash) |v| {
            if (issue.content_hash) |h| self.allocator.free(h);
            issue.content_hash = try self.allocator.dupe(u8, v);
        }

        try self.markDirty(id);
    }

    /// Soft delete an issue by setting its status to tombstone.
    pub fn delete(self: *Self, id: []const u8, now: i64) !void {
        try self.update(id, .{ .status = .tombstone }, now);
    }

    /// Filters for listing issues.
    pub const ListFilters = struct {
        status: ?Status = null,
        priority: ?Priority = null,
        priority_min: ?Priority = null,
        priority_max: ?Priority = null,
        issue_type: ?IssueType = null,
        assignee: ?[]const u8 = null,
        label: ?[]const u8 = null,
        label_any: []const []const u8 = &[_][]const u8{},
        title_contains: ?[]const u8 = null,
        desc_contains: ?[]const u8 = null,
        notes_contains: ?[]const u8 = null,
        include_tombstones: bool = false,
        overdue: bool = false,
        include_deferred: bool = false,
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
        var results: std.ArrayListUnmanaged(Issue) = .{};
        errdefer {
            for (results.items) |*issue| {
                issue.deinit(self.allocator);
            }
            results.deinit(self.allocator);
        }

        const now = if (filters.overdue) std.time.timestamp() else 0;

        for (self.issues.items) |issue| {
            // Filter tombstones
            if (!filters.include_tombstones and statusEql(issue.status, .tombstone)) {
                continue;
            }

            // Apply filters
            if (filters.status) |s| {
                // When include_deferred is set, allow deferred issues through even when filtering for open
                const status_matches = statusEql(issue.status, s);
                const deferred_allowed = filters.include_deferred and statusEql(issue.status, .deferred);
                if (!status_matches and !deferred_allowed) continue;
            }
            if (filters.priority) |p| {
                if (issue.priority.value != p.value) continue;
            }
            if (filters.issue_type) |t| {
                if (!issueTypeEql(issue.issue_type, t)) continue;
            }
            if (filters.assignee) |a| {
                if (issue.assignee == null) continue;
                if (!std.mem.eql(u8, issue.assignee.?, a)) continue;
            }
            if (filters.label) |lbl| {
                var found = false;
                for (issue.labels) |label| {
                    if (std.mem.eql(u8, label, lbl)) {
                        found = true;
                        break;
                    }
                }
                if (!found) continue;
            }

            // label_any: OR logic - issue must have at least ONE of the specified labels
            if (filters.label_any.len > 0) {
                var found_any = false;
                for (filters.label_any) |any_label| {
                    for (issue.labels) |issue_label| {
                        if (std.mem.eql(u8, issue_label, any_label)) {
                            found_any = true;
                            break;
                        }
                    }
                    if (found_any) break;
                }
                if (!found_any) continue;
            }

            // Priority range filters (lower value = higher priority)
            if (filters.priority_min) |min_p| {
                if (issue.priority.value < min_p.value) continue;
            }
            if (filters.priority_max) |max_p| {
                if (issue.priority.value > max_p.value) continue;
            }

            // Substring filters (case-insensitive)
            if (filters.title_contains) |query| {
                if (!containsIgnoreCase(issue.title, query)) continue;
            }
            if (filters.desc_contains) |query| {
                if (issue.description) |desc| {
                    if (!containsIgnoreCase(desc, query)) continue;
                } else continue;
            }
            if (filters.notes_contains) |query| {
                if (issue.notes) |notes| {
                    if (!containsIgnoreCase(notes, query)) continue;
                } else continue;
            }

            // Overdue filter: only include issues past their due date
            if (filters.overdue) {
                if (issue.due_at.value) |due_time| {
                    if (due_time >= now) continue;
                } else continue;
            }

            try results.append(self.allocator, try issue.clone(self.allocator));
        }

        // Sort
        const SortContext = struct {
            order_by: ListFilters.OrderBy,
            order_desc: bool,
        };
        const ctx = SortContext{ .order_by = filters.order_by, .order_desc = filters.order_desc };

        std.mem.sortUnstable(Issue, results.items, ctx, struct {
            fn lessThan(c: SortContext, a: Issue, b: Issue) bool {
                const cmp: i64 = switch (c.order_by) {
                    .created_at => a.created_at.value - b.created_at.value,
                    .updated_at => a.updated_at.value - b.updated_at.value,
                    .priority => @as(i64, a.priority.value) - @as(i64, b.priority.value),
                };
                return if (c.order_desc) cmp > 0 else cmp < 0;
            }
        }.lessThan);

        // Apply offset and limit
        var start: usize = 0;
        if (filters.offset) |off| {
            start = @min(off, results.items.len);
        }

        var end: usize = results.items.len;
        if (filters.limit) |lim| {
            end = @min(start + lim, results.items.len);
        }

        // Free items outside the range
        for (results.items[0..start]) |*issue| {
            issue.deinit(self.allocator);
        }
        for (results.items[end..]) |*issue| {
            issue.deinit(self.allocator);
        }

        // Return slice
        const slice = try self.allocator.dupe(Issue, results.items[start..end]);
        results.deinit(self.allocator);
        return slice;
    }

    /// Result from counting issues.
    pub const CountResult = struct {
        key: []const u8,
        count: u64,
    };

    /// Count issues, optionally grouped by a field.
    pub fn count(self: *Self, group_by: ?GroupBy) ![]CountResult {
        var counts: std.StringHashMapUnmanaged(u64) = .{};
        defer counts.deinit(self.allocator);

        for (self.issues.items) |issue| {
            if (statusEql(issue.status, .tombstone)) continue;

            const key_str: []const u8 = if (group_by) |g| switch (g) {
                .status => issue.status.toString(),
                .priority => switch (issue.priority.value) {
                    0 => "0",
                    1 => "1",
                    2 => "2",
                    3 => "3",
                    4 => "4",
                    else => unreachable,
                },
                .issue_type => issue.issue_type.toString(),
                .assignee => issue.assignee orelse "(unassigned)",
            } else "total";

            const entry = counts.getOrPutValue(self.allocator, key_str, 0) catch continue;
            entry.value_ptr.* += 1;
        }

        var results: std.ArrayListUnmanaged(CountResult) = .{};
        errdefer {
            for (results.items) |r| {
                self.allocator.free(r.key);
            }
            results.deinit(self.allocator);
        }

        var it = counts.iterator();
        while (it.next()) |entry| {
            const key = try self.allocator.dupe(u8, entry.key_ptr.*);
            try results.append(self.allocator, .{ .key = key, .count = entry.value_ptr.* });
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
        return self.id_index.contains(id);
    }

    /// Get labels for an issue.
    pub fn getLabels(self: *Self, issue_id: []const u8) ![]const []const u8 {
        const idx = self.id_index.get(issue_id) orelse return &[_][]const u8{};
        if (idx >= self.issues.items.len) return &[_][]const u8{};

        const issue = self.issues.items[idx];
        if (issue.labels.len == 0) return &[_][]const u8{};

        const labels = try self.allocator.alloc([]const u8, issue.labels.len);
        errdefer self.allocator.free(labels);

        for (issue.labels, 0..) |label, i| {
            labels[i] = try self.allocator.dupe(u8, label);
        }
        return labels;
    }

    /// Add a label to an issue.
    pub fn addLabel(self: *Self, issue_id: []const u8, label: []const u8) !void {
        const idx = self.id_index.get(issue_id) orelse return IssueStoreError.IssueNotFound;
        if (idx >= self.issues.items.len) return IssueStoreError.IssueNotFound;

        var issue = &self.issues.items[idx];

        // Check if already exists
        for (issue.labels) |existing| {
            if (std.mem.eql(u8, existing, label)) return;
        }

        // Add new label
        const label_copy = try self.allocator.dupe(u8, label);
        errdefer self.allocator.free(label_copy);

        const new_labels = try self.allocator.alloc([]const u8, issue.labels.len + 1);
        @memcpy(new_labels[0..issue.labels.len], issue.labels);
        new_labels[issue.labels.len] = label_copy;

        if (issue.labels.len > 0) {
            self.allocator.free(issue.labels);
        }
        issue.labels = new_labels;

        try self.markDirty(issue_id);
    }

    /// Remove a label from an issue.
    pub fn removeLabel(self: *Self, issue_id: []const u8, label: []const u8) !void {
        const idx = self.id_index.get(issue_id) orelse return IssueStoreError.IssueNotFound;
        if (idx >= self.issues.items.len) return IssueStoreError.IssueNotFound;

        var issue = &self.issues.items[idx];

        var found_idx: ?usize = null;
        for (issue.labels, 0..) |existing, i| {
            if (std.mem.eql(u8, existing, label)) {
                found_idx = i;
                break;
            }
        }

        if (found_idx) |fi| {
            self.allocator.free(issue.labels[fi]);

            if (issue.labels.len == 1) {
                self.allocator.free(issue.labels);
                issue.labels = &[_][]const u8{};
            } else {
                const new_labels = try self.allocator.alloc([]const u8, issue.labels.len - 1);
                var j: usize = 0;
                for (issue.labels, 0..) |lbl, i| {
                    if (i != fi) {
                        new_labels[j] = lbl;
                        j += 1;
                    }
                }
                self.allocator.free(issue.labels);
                issue.labels = new_labels;
            }

            try self.markDirty(issue_id);
        }
    }

    /// Get dependencies for an issue.
    pub fn getDependencies(self: *Self, issue_id: []const u8) ![]const Dependency {
        const idx = self.id_index.get(issue_id) orelse return &[_]Dependency{};
        if (idx >= self.issues.items.len) return &[_]Dependency{};

        const issue = self.issues.items[idx];
        if (issue.dependencies.len == 0) return &[_]Dependency{};

        const deps = try self.allocator.alloc(Dependency, issue.dependencies.len);
        errdefer self.allocator.free(deps);

        for (issue.dependencies, 0..) |dep, i| {
            deps[i] = try cloneDependency(dep, self.allocator);
        }
        return deps;
    }

    /// Get comments for an issue.
    pub fn getComments(self: *Self, issue_id: []const u8) ![]const Comment {
        const idx = self.id_index.get(issue_id) orelse return &[_]Comment{};
        if (idx >= self.issues.items.len) return &[_]Comment{};

        const issue = self.issues.items[idx];
        if (issue.comments.len == 0) return &[_]Comment{};

        const comments = try self.allocator.alloc(Comment, issue.comments.len);
        errdefer self.allocator.free(comments);

        for (issue.comments, 0..) |c, i| {
            comments[i] = try cloneComment(c, self.allocator);
        }
        return comments;
    }

    /// Add a comment to an issue.
    pub fn addComment(self: *Self, issue_id: []const u8, comment: Comment) !void {
        const idx = self.id_index.get(issue_id) orelse return IssueStoreError.IssueNotFound;
        if (idx >= self.issues.items.len) return IssueStoreError.IssueNotFound;

        var issue = &self.issues.items[idx];

        const cloned = try cloneComment(comment, self.allocator);
        errdefer freeComment(@constCast(&cloned), self.allocator);

        const new_comments = try self.allocator.alloc(Comment, issue.comments.len + 1);
        @memcpy(new_comments[0..issue.comments.len], issue.comments);
        new_comments[issue.comments.len] = cloned;

        if (issue.comments.len > 0) {
            self.allocator.free(issue.comments);
        }
        issue.comments = new_comments;

        try self.markDirty(issue_id);
    }

    /// Mark an issue as dirty for sync.
    pub fn markDirty(self: *Self, id: []const u8) !void {
        self.dirty = true;
        const now = std.time.timestamp();

        if (!self.dirty_ids.contains(id)) {
            const id_copy = try self.allocator.dupe(u8, id);
            try self.dirty_ids.put(self.allocator, id_copy, now);
        } else {
            self.dirty_ids.getPtr(id).?.* = now;
        }
    }

    /// Clear dirty flag for an issue.
    pub fn clearDirty(self: *Self, id: []const u8) !void {
        if (self.dirty_ids.fetchRemove(id)) |kv| {
            self.allocator.free(kv.key);
        }
    }

    /// Get all dirty issue IDs.
    pub fn getDirtyIds(self: *Self) ![][]const u8 {
        var ids: std.ArrayListUnmanaged([]const u8) = .{};
        errdefer {
            for (ids.items) |id| {
                self.allocator.free(id);
            }
            ids.deinit(self.allocator);
        }

        var it = self.dirty_ids.keyIterator();
        while (it.next()) |key| {
            const id = try self.allocator.dupe(u8, key.*);
            try ids.append(self.allocator, id);
        }

        return ids.toOwnedSlice(self.allocator);
    }

    /// Check if the store has unsaved changes.
    pub fn isDirty(self: *Self) bool {
        return self.dirty;
    }

    /// Get total number of issues (excluding tombstones).
    pub fn countTotal(self: *Self) usize {
        var total: usize = 0;
        for (self.issues.items) |issue| {
            if (!statusEql(issue.status, .tombstone)) {
                total += 1;
            }
        }
        return total;
    }

    /// Get all issues as a slice (no clone, read-only).
    pub fn getAllRef(self: *Self) []const Issue {
        return self.issues.items;
    }

    /// Suggestion for similar ID lookup.
    pub const IdSuggestion = struct {
        id: []const u8,
        title: []const u8,
    };

    /// Find similar IDs when a lookup fails (for "did you mean" suggestions).
    /// Uses prefix matching and Levenshtein-like scoring.
    /// Returns up to `max_count` suggestions, caller must free.
    pub fn findSimilarIds(self: *Self, target: []const u8, max_count: usize) ![]IdSuggestion {
        if (self.issues.items.len == 0) return &[_]IdSuggestion{};

        const Scored = struct {
            id: []const u8,
            title: []const u8,
            score: i32,
        };

        var candidates: std.ArrayListUnmanaged(Scored) = .{};
        defer candidates.deinit(self.allocator);

        for (self.issues.items) |issue| {
            if (statusEql(issue.status, .tombstone)) continue;

            const score = computeSimilarity(target, issue.id);
            if (score > 0) {
                try candidates.append(self.allocator, .{
                    .id = issue.id,
                    .title = issue.title,
                    .score = score,
                });
            }
        }

        if (candidates.items.len == 0) return &[_]IdSuggestion{};

        // Sort by score descending
        std.mem.sortUnstable(Scored, candidates.items, {}, struct {
            fn lessThan(_: void, a: Scored, b: Scored) bool {
                return a.score > b.score;
            }
        }.lessThan);

        const result_count = @min(max_count, candidates.items.len);
        var suggestions = try self.allocator.alloc(IdSuggestion, result_count);
        errdefer self.allocator.free(suggestions);

        for (0..result_count) |i| {
            suggestions[i] = .{
                .id = try self.allocator.dupe(u8, candidates.items[i].id),
                .title = try self.allocator.dupe(u8, candidates.items[i].title),
            };
        }

        return suggestions;
    }

    /// Free suggestions returned by findSimilarIds.
    pub fn freeSuggestions(self: *Self, suggestions: []IdSuggestion) void {
        for (suggestions) |s| {
            self.allocator.free(s.id);
            self.allocator.free(s.title);
        }
        self.allocator.free(suggestions);
    }
};

/// Compute similarity score between target and candidate ID.
/// Higher score = more similar.
fn computeSimilarity(target: []const u8, candidate: []const u8) i32 {
    var score: i32 = 0;

    // Exact prefix match (bd-abc matches bd-abc123)
    if (std.mem.startsWith(u8, candidate, target)) {
        score += 100;
    }
    // Candidate is prefix of target (bd-abc123 starts with bd-abc)
    else if (std.mem.startsWith(u8, target, candidate)) {
        score += 80;
    }

    // Common prefix length
    var common_prefix: usize = 0;
    const min_len = @min(target.len, candidate.len);
    for (0..min_len) |i| {
        if (target[i] == candidate[i]) {
            common_prefix += 1;
        } else {
            break;
        }
    }
    score += @intCast(common_prefix * 5);

    // Contains target as substring
    if (std.mem.indexOf(u8, candidate, target) != null) {
        score += 30;
    }

    // Similar length bonus
    const len_diff: i32 = @intCast(@abs(@as(i64, @intCast(target.len)) - @as(i64, @intCast(candidate.len))));
    if (len_diff <= 2) {
        score += 10;
    }

    return score;
}

// Helper functions
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

pub fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;

    const end = haystack.len - needle.len + 1;
    var i: usize = 0;
    while (i < end) : (i += 1) {
        var match = true;
        for (needle, 0..) |nc, j| {
            const hc = haystack[i + j];
            if (std.ascii.toLower(hc) != std.ascii.toLower(nc)) {
                match = false;
                break;
            }
        }
        if (match) return true;
    }
    return false;
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

    result.created_at = dep.created_at;
    result.created_by = if (dep.created_by) |c| try allocator.dupe(u8, c) else null;
    result.metadata = if (dep.metadata) |m| try allocator.dupe(u8, m) else null;
    result.thread_id = if (dep.thread_id) |t| try allocator.dupe(u8, t) else null;

    return result;
}

fn cloneComment(comment: Comment, allocator: std.mem.Allocator) !Comment {
    return Comment{
        .id = comment.id,
        .issue_id = try allocator.dupe(u8, comment.issue_id),
        .author = try allocator.dupe(u8, comment.author),
        .body = try allocator.dupe(u8, comment.body),
        .created_at = comment.created_at,
    };
}

fn freeComment(comment: *Comment, allocator: std.mem.Allocator) void {
    allocator.free(comment.issue_id);
    allocator.free(comment.author);
    allocator.free(comment.body);
}

// --- Tests ---

test "IssueStore insert and get" {
    const allocator = std.testing.allocator;
    var store = IssueStore.init(allocator, "test.jsonl");
    defer store.deinit();

    const issue = Issue.init("bd-test1", "Test Issue", 1706540000);
    try store.insert(issue);

    try std.testing.expect(try store.exists("bd-test1"));

    var retrieved = (try store.get("bd-test1")).?;
    defer retrieved.deinit(allocator);

    try std.testing.expectEqualStrings("bd-test1", retrieved.id);
    try std.testing.expectEqualStrings("Test Issue", retrieved.title);
}

test "IssueStore get returns null for missing" {
    const allocator = std.testing.allocator;
    var store = IssueStore.init(allocator, "test.jsonl");
    defer store.deinit();

    const result = try store.get("bd-nonexistent");
    try std.testing.expect(result == null);
}

test "IssueStore update modifies fields" {
    const allocator = std.testing.allocator;
    var store = IssueStore.init(allocator, "test.jsonl");
    defer store.deinit();

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
    try std.testing.expect(statusEql(updated.status, .in_progress));
    try std.testing.expectEqual(Priority.HIGH, updated.priority);
}

test "IssueStore update increments version" {
    const allocator = std.testing.allocator;
    var store = IssueStore.init(allocator, "test.jsonl");
    defer store.deinit();

    const issue = Issue.init("bd-version", "Version Test", 1706540000);
    try store.insert(issue);

    // Initial version should be 1
    var v1 = (try store.get("bd-version")).?;
    defer v1.deinit(allocator);
    try std.testing.expectEqual(@as(u64, 1), v1.version);

    // Update should increment version
    try store.update("bd-version", .{ .title = "Updated" }, 1706550000);

    var v2 = (try store.get("bd-version")).?;
    defer v2.deinit(allocator);
    try std.testing.expectEqual(@as(u64, 2), v2.version);

    // Another update should increment again
    try store.update("bd-version", .{ .title = "Updated Again" }, 1706560000);

    var v3 = (try store.get("bd-version")).?;
    defer v3.deinit(allocator);
    try std.testing.expectEqual(@as(u64, 3), v3.version);
}

test "IssueStore update with expected_version succeeds on match" {
    const allocator = std.testing.allocator;
    var store = IssueStore.init(allocator, "test.jsonl");
    defer store.deinit();

    const issue = Issue.init("bd-optlock", "Optimistic Lock Test", 1706540000);
    try store.insert(issue);

    // Get current version (1)
    var current = (try store.get("bd-optlock")).?;
    const current_version = current.version;
    current.deinit(allocator);

    // Update with correct expected version should succeed
    try store.update("bd-optlock", .{
        .title = "Updated with lock",
        .expected_version = current_version,
    }, 1706550000);

    var updated = (try store.get("bd-optlock")).?;
    defer updated.deinit(allocator);
    try std.testing.expectEqualStrings("Updated with lock", updated.title);
    try std.testing.expectEqual(@as(u64, 2), updated.version);
}

test "IssueStore update with expected_version fails on mismatch" {
    const allocator = std.testing.allocator;
    var store = IssueStore.init(allocator, "test.jsonl");
    defer store.deinit();

    const issue = Issue.init("bd-conflict", "Conflict Test", 1706540000);
    try store.insert(issue);

    // Update once to increment version to 2
    try store.update("bd-conflict", .{ .title = "First Update" }, 1706550000);

    // Try to update with stale expected_version (1 instead of 2)
    const result = store.update("bd-conflict", .{
        .title = "Conflicting Update",
        .expected_version = 1, // Stale version
    }, 1706560000);

    try std.testing.expectError(IssueStoreError.VersionMismatch, result);

    // Verify original update is preserved
    var preserved = (try store.get("bd-conflict")).?;
    defer preserved.deinit(allocator);
    try std.testing.expectEqualStrings("First Update", preserved.title);
    try std.testing.expectEqual(@as(u64, 2), preserved.version);
}

test "IssueStore delete sets tombstone" {
    const allocator = std.testing.allocator;
    var store = IssueStore.init(allocator, "test.jsonl");
    defer store.deinit();

    const issue = Issue.init("bd-delete", "To Delete", 1706540000);
    try store.insert(issue);

    try store.delete("bd-delete", 1706550000);

    var deleted = (try store.get("bd-delete")).?;
    defer deleted.deinit(allocator);

    try std.testing.expect(statusEql(deleted.status, .tombstone));
}

test "IssueStore list returns issues" {
    const allocator = std.testing.allocator;
    var store = IssueStore.init(allocator, "test.jsonl");
    defer store.deinit();

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

test "IssueStore list excludes tombstones" {
    const allocator = std.testing.allocator;
    var store = IssueStore.init(allocator, "test.jsonl");
    defer store.deinit();

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

test "IssueStore dirty tracking" {
    const allocator = std.testing.allocator;
    var store = IssueStore.init(allocator, "test.jsonl");
    defer store.deinit();

    const issue = Issue.init("bd-dirty", "Dirty Test", 1706540000);
    try store.insert(issue);

    try std.testing.expect(store.isDirty());

    const dirty_ids = try store.getDirtyIds();
    defer {
        for (dirty_ids) |id| {
            allocator.free(id);
        }
        allocator.free(dirty_ids);
    }

    try std.testing.expectEqual(@as(usize, 1), dirty_ids.len);
    try std.testing.expectEqualStrings("bd-dirty", dirty_ids[0]);

    try store.clearDirty("bd-dirty");

    const after_clear = try store.getDirtyIds();
    defer allocator.free(after_clear);

    try std.testing.expectEqual(@as(usize, 0), after_clear.len);
}

test "IssueStore addLabel and removeLabel" {
    const allocator = std.testing.allocator;
    var store = IssueStore.init(allocator, "test.jsonl");
    defer store.deinit();

    try store.insert(Issue.init("bd-labels", "Label Test", 1706540000));

    try store.addLabel("bd-labels", "bug");
    try store.addLabel("bd-labels", "urgent");

    const labels = try store.getLabels("bd-labels");
    defer {
        for (labels) |lbl| {
            allocator.free(lbl);
        }
        allocator.free(labels);
    }

    try std.testing.expectEqual(@as(usize, 2), labels.len);

    try store.removeLabel("bd-labels", "bug");

    const after_remove = try store.getLabels("bd-labels");
    defer {
        for (after_remove) |lbl| {
            allocator.free(lbl);
        }
        allocator.free(after_remove);
    }

    try std.testing.expectEqual(@as(usize, 1), after_remove.len);
}

test "StoreLoadResult.hasCorruption" {
    var result = StoreLoadResult{
        .jsonl_corruption_count = 0,
    };
    try std.testing.expect(!result.hasCorruption());

    result.jsonl_corruption_count = 3;
    try std.testing.expect(result.hasCorruption());
}

test "IssueStore loadFromFileWithRecovery handles corrupt entries" {
    const allocator = std.testing.allocator;
    const test_util = @import("../test_util.zig");
    const test_dir = try test_util.createTestDir(allocator, "store_recovery");
    defer allocator.free(test_dir);
    defer test_util.cleanupTestDir(test_dir);

    const test_path = try std.fs.path.join(allocator, &.{ test_dir, "issues.jsonl" });
    defer allocator.free(test_path);

    // Write a file with mixed valid and corrupt entries
    // Use full Issue JSON format (all fields required by parser)
    {
        const file = try std.fs.cwd().createFile(test_path, .{});
        defer file.close();

        // Valid issue
        const valid1 = "{\"id\":\"bd-valid1\",\"content_hash\":null,\"title\":\"Valid Issue\",\"description\":null,\"design\":null,\"acceptance_criteria\":null,\"notes\":null,\"status\":\"open\",\"priority\":2,\"issue_type\":\"task\",\"assignee\":null,\"owner\":null,\"created_at\":\"2024-01-29T10:00:00Z\",\"created_by\":null,\"updated_at\":\"2024-01-29T10:00:00Z\",\"closed_at\":null,\"close_reason\":null,\"due_at\":null,\"defer_until\":null,\"estimated_minutes\":null,\"external_ref\":null,\"source_system\":null,\"pinned\":false,\"is_template\":false,\"labels\":[],\"dependencies\":[],\"comments\":[]}\n";
        try file.writeAll(valid1);

        // Corrupt entry
        try file.writeAll("{invalid json here}\n");

        // Another valid issue
        const valid2 = "{\"id\":\"bd-valid2\",\"content_hash\":null,\"title\":\"Another Valid Issue\",\"description\":null,\"design\":null,\"acceptance_criteria\":null,\"notes\":null,\"status\":\"open\",\"priority\":2,\"issue_type\":\"task\",\"assignee\":null,\"owner\":null,\"created_at\":\"2024-01-29T10:00:00Z\",\"created_by\":null,\"updated_at\":\"2024-01-29T10:00:00Z\",\"closed_at\":null,\"close_reason\":null,\"due_at\":null,\"defer_until\":null,\"estimated_minutes\":null,\"external_ref\":null,\"source_system\":null,\"pinned\":false,\"is_template\":false,\"labels\":[],\"dependencies\":[],\"comments\":[]}\n";
        try file.writeAll(valid2);
    }

    var store = IssueStore.init(allocator, test_path);
    defer store.deinit();

    var result = try store.loadFromFileWithRecovery();
    defer result.deinit(allocator);

    // Should have loaded 2 valid issues
    try std.testing.expectEqual(@as(usize, 2), store.issues.items.len);

    // Should have tracked 1 corrupt entry
    try std.testing.expectEqual(@as(usize, 1), result.jsonl_corruption_count);
    try std.testing.expect(result.hasCorruption());

    // Verify the correct issues were loaded
    try std.testing.expect(try store.exists("bd-valid1"));
    try std.testing.expect(try store.exists("bd-valid2"));
}
