//! Dependency storage operations for beads_zig.
//!
//! Provides operations for managing issue dependencies including:
//! - Add/remove dependencies
//! - Cycle detection (prevents circular dependencies)
//! - Query dependencies and dependents
//! - Ready/blocked issue queries
//! - Blocked cache management

const std = @import("std");
const sqlite = @import("sqlite.zig");
const Database = sqlite.Database;
const Statement = sqlite.Statement;

const issues_mod = @import("issues.zig");
const IssueStore = issues_mod.IssueStore;

const Issue = @import("../models/issue.zig").Issue;
const Dependency = @import("../models/dependency.zig").Dependency;
const DependencyType = @import("../models/dependency.zig").DependencyType;

pub const DependencyStoreError = error{
    SelfDependency,
    CycleDetected,
    DependencyNotFound,
};

pub const DependencyStore = struct {
    db: *Database,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(db: *Database, allocator: std.mem.Allocator) Self {
        return .{ .db = db, .allocator = allocator };
    }

    /// Add a dependency (issue_id depends on depends_on_id).
    /// Returns error.SelfDependency if trying to depend on self.
    /// Returns error.CycleDetected if adding would create a cycle.
    pub fn add(self: *Self, dep: Dependency) !void {
        // Check for self-dependency
        if (std.mem.eql(u8, dep.issue_id, dep.depends_on_id)) {
            return DependencyStoreError.SelfDependency;
        }

        // Check for cycles before inserting
        if (try self.wouldCreateCycle(dep.issue_id, dep.depends_on_id)) {
            return DependencyStoreError.CycleDetected;
        }

        const sql =
            \\INSERT INTO dependencies (issue_id, depends_on_id, dep_type, created_at, created_by, metadata, thread_id)
            \\VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
        ;
        var stmt = try self.db.prepare(sql);
        defer stmt.deinit();
        try stmt.bindText(1, dep.issue_id);
        try stmt.bindText(2, dep.depends_on_id);
        try stmt.bindText(3, dep.dep_type.toString());
        try stmt.bindInt(4, dep.created_at);
        try stmt.bindText(5, dep.created_by);
        try stmt.bindText(6, dep.metadata);
        try stmt.bindText(7, dep.thread_id);
        _ = try stmt.step();

        // Invalidate blocked cache for the dependent issue
        try self.invalidateBlockedCache(dep.issue_id);

        // Mark issue as dirty for sync
        try self.markDirty(dep.issue_id);
    }

    /// Remove a dependency.
    pub fn remove(self: *Self, issue_id: []const u8, depends_on_id: []const u8) !void {
        const sql = "DELETE FROM dependencies WHERE issue_id = ?1 AND depends_on_id = ?2";
        var stmt = try self.db.prepare(sql);
        defer stmt.deinit();
        try stmt.bindText(1, issue_id);
        try stmt.bindText(2, depends_on_id);
        _ = try stmt.step();

        try self.invalidateBlockedCache(issue_id);
        try self.markDirty(issue_id);
    }

    /// Get dependencies for an issue (what it depends on).
    pub fn getDependencies(self: *Self, issue_id: []const u8) ![]Dependency {
        const sql =
            \\SELECT issue_id, depends_on_id, dep_type, created_at, created_by, metadata, thread_id
            \\FROM dependencies WHERE issue_id = ?1
        ;
        var stmt = try self.db.prepare(sql);
        defer stmt.deinit();
        try stmt.bindText(1, issue_id);

        return try self.collectDependencies(&stmt);
    }

    /// Get dependents of an issue (what depends on it).
    pub fn getDependents(self: *Self, issue_id: []const u8) ![]Dependency {
        const sql =
            \\SELECT issue_id, depends_on_id, dep_type, created_at, created_by, metadata, thread_id
            \\FROM dependencies WHERE depends_on_id = ?1
        ;
        var stmt = try self.db.prepare(sql);
        defer stmt.deinit();
        try stmt.bindText(1, issue_id);

        return try self.collectDependencies(&stmt);
    }

    /// Check if adding a dependency would create a cycle.
    /// Uses DFS from depends_on_id to see if it can reach issue_id.
    fn wouldCreateCycle(self: *Self, issue_id: []const u8, depends_on_id: []const u8) !bool {
        var visited = std.StringHashMap(void).init(self.allocator);
        defer {
            // Free all allocated keys
            var key_it = visited.keyIterator();
            while (key_it.next()) |key| {
                self.allocator.free(key.*);
            }
            visited.deinit();
        }

        return try self.dfsReachable(depends_on_id, issue_id, &visited);
    }

    fn dfsReachable(self: *Self, from: []const u8, target: []const u8, visited: *std.StringHashMap(void)) !bool {
        if (std.mem.eql(u8, from, target)) return true;
        if (visited.contains(from)) return false;

        // Need to allocate a copy of 'from' for the hash map since 'from' may be
        // temporary memory from SQLite
        const from_copy = try self.allocator.dupe(u8, from);
        errdefer self.allocator.free(from_copy);
        try visited.put(from_copy, {});

        const deps = try self.getDependencies(from);
        defer self.freeDependencies(deps);

        for (deps) |dep| {
            if (try self.dfsReachable(dep.depends_on_id, target, visited)) {
                return true;
            }
        }
        return false;
    }

    /// Detect all cycles in the dependency graph.
    /// Returns array of cycle paths (each path is issue IDs forming a cycle), or null if no cycles.
    pub fn detectCycles(self: *Self) !?[][]const u8 {
        // Get all unique issue IDs that have dependencies
        var all_issues = std.StringHashMap(void).init(self.allocator);
        defer {
            var it = all_issues.keyIterator();
            while (it.next()) |key| {
                self.allocator.free(key.*);
            }
            all_issues.deinit();
        }

        {
            var stmt = try self.db.prepare("SELECT DISTINCT issue_id FROM dependencies");
            defer stmt.deinit();
            while (try stmt.step()) {
                const id = stmt.columnText(0) orelse continue;
                const id_copy = try self.allocator.dupe(u8, id);
                try all_issues.put(id_copy, {});
            }
        }

        {
            var stmt = try self.db.prepare("SELECT DISTINCT depends_on_id FROM dependencies");
            defer stmt.deinit();
            while (try stmt.step()) {
                const id = stmt.columnText(0) orelse continue;
                if (!all_issues.contains(id)) {
                    const id_copy = try self.allocator.dupe(u8, id);
                    try all_issues.put(id_copy, {});
                }
            }
        }

        var cycles: std.ArrayList([]const u8) = .{};
        errdefer {
            for (cycles.items) |c| {
                self.allocator.free(c);
            }
            cycles.deinit(self.allocator);
        }

        var visited = std.StringHashMap(void).init(self.allocator);
        defer visited.deinit();

        var rec_stack = std.StringHashMap(void).init(self.allocator);
        defer rec_stack.deinit();

        var it = all_issues.keyIterator();
        while (it.next()) |key| {
            if (!visited.contains(key.*)) {
                var path: std.ArrayList([]const u8) = .{};
                defer path.deinit(self.allocator);

                if (try self.detectCycleDfs(key.*, &visited, &rec_stack, &path)) {
                    // Found a cycle - record the path
                    const cycle_str = try std.mem.join(self.allocator, " -> ", path.items);
                    try cycles.append(self.allocator, cycle_str);
                }
            }
        }

        if (cycles.items.len == 0) {
            return null;
        }

        return try cycles.toOwnedSlice(self.allocator);
    }

    fn detectCycleDfs(
        self: *Self,
        node: []const u8,
        visited: *std.StringHashMap(void),
        rec_stack: *std.StringHashMap(void),
        path: *std.ArrayList([]const u8),
    ) !bool {
        const node_copy = try self.allocator.dupe(u8, node);
        errdefer self.allocator.free(node_copy);

        try visited.put(node_copy, {});
        try rec_stack.put(node_copy, {});
        try path.append(self.allocator, node);

        const deps = try self.getDependencies(node);
        defer self.freeDependencies(deps);

        for (deps) |dep| {
            if (!visited.contains(dep.depends_on_id)) {
                if (try self.detectCycleDfs(dep.depends_on_id, visited, rec_stack, path)) {
                    return true;
                }
            } else if (rec_stack.contains(dep.depends_on_id)) {
                // Found a cycle
                try path.append(self.allocator, dep.depends_on_id);
                return true;
            }
        }

        _ = rec_stack.remove(node);
        _ = path.popOrNull();
        return false;
    }

    /// Get all issues that are ready (open, not blocked by open issues, not deferred).
    pub fn getReadyIssues(self: *Self) ![]Issue {
        const now = std.time.timestamp();
        const sql =
            \\SELECT i.id, i.content_hash, i.title, i.description, i.design, i.acceptance_criteria,
            \\       i.notes, i.status, i.priority, i.issue_type, i.assignee, i.owner,
            \\       i.estimated_minutes, i.created_at, i.created_by, i.updated_at,
            \\       i.closed_at, i.close_reason, i.due_at, i.defer_until,
            \\       i.external_ref, i.source_system, i.pinned, i.is_template
            \\FROM issues i
            \\WHERE i.status = 'open'
            \\AND (i.defer_until IS NULL OR i.defer_until <= ?1)
            \\AND NOT EXISTS (
            \\    SELECT 1 FROM dependencies d
            \\    JOIN issues blocker ON d.depends_on_id = blocker.id
            \\    WHERE d.issue_id = i.id
            \\    AND blocker.status NOT IN ('closed', 'tombstone')
            \\)
            \\ORDER BY i.priority ASC, i.created_at ASC
        ;
        var stmt = try self.db.prepare(sql);
        defer stmt.deinit();
        try stmt.bindInt(1, now);

        return try self.collectIssues(&stmt);
    }

    /// Get all blocked issues (open issues with unresolved dependencies).
    pub fn getBlockedIssues(self: *Self) ![]Issue {
        const sql =
            \\SELECT DISTINCT i.id, i.content_hash, i.title, i.description, i.design,
            \\       i.acceptance_criteria, i.notes, i.status, i.priority, i.issue_type,
            \\       i.assignee, i.owner, i.estimated_minutes, i.created_at, i.created_by,
            \\       i.updated_at, i.closed_at, i.close_reason, i.due_at, i.defer_until,
            \\       i.external_ref, i.source_system, i.pinned, i.is_template
            \\FROM issues i
            \\JOIN dependencies d ON d.issue_id = i.id
            \\JOIN issues blocker ON d.depends_on_id = blocker.id
            \\WHERE i.status = 'open'
            \\AND blocker.status NOT IN ('closed', 'tombstone')
            \\ORDER BY i.priority ASC, i.created_at ASC
        ;
        var stmt = try self.db.prepare(sql);
        defer stmt.deinit();

        return try self.collectIssues(&stmt);
    }

    /// Get blockers for an issue (open issues that this issue depends on).
    pub fn getBlockers(self: *Self, issue_id: []const u8) ![]Issue {
        const sql =
            \\SELECT i.id, i.content_hash, i.title, i.description, i.design, i.acceptance_criteria,
            \\       i.notes, i.status, i.priority, i.issue_type, i.assignee, i.owner,
            \\       i.estimated_minutes, i.created_at, i.created_by, i.updated_at,
            \\       i.closed_at, i.close_reason, i.due_at, i.defer_until,
            \\       i.external_ref, i.source_system, i.pinned, i.is_template
            \\FROM issues i
            \\JOIN dependencies d ON d.depends_on_id = i.id
            \\WHERE d.issue_id = ?1
            \\AND i.status NOT IN ('closed', 'tombstone')
        ;
        var stmt = try self.db.prepare(sql);
        defer stmt.deinit();
        try stmt.bindText(1, issue_id);

        return try self.collectIssues(&stmt);
    }

    // --- Blocked Cache Management ---

    /// Invalidate blocked cache for an issue.
    fn invalidateBlockedCache(self: *Self, issue_id: []const u8) !void {
        const sql = "DELETE FROM blocked_cache WHERE issue_id = ?1";
        var stmt = try self.db.prepare(sql);
        defer stmt.deinit();
        try stmt.bindText(1, issue_id);
        _ = try stmt.step();
    }

    /// Rebuild the entire blocked cache from dependencies.
    pub fn rebuildBlockedCache(self: *Self) !void {
        // Clear existing cache
        try self.db.exec("DELETE FROM blocked_cache");

        const now = std.time.timestamp();

        // Find all issues that are blocked
        const sql =
            \\SELECT d.issue_id, GROUP_CONCAT(d.depends_on_id, ',') as blockers
            \\FROM dependencies d
            \\JOIN issues blocker ON d.depends_on_id = blocker.id
            \\WHERE blocker.status NOT IN ('closed', 'tombstone')
            \\GROUP BY d.issue_id
        ;
        var select_stmt = try self.db.prepare(sql);
        defer select_stmt.deinit();

        while (try select_stmt.step()) {
            const issue_id = select_stmt.columnText(0) orelse continue;
            const blockers = select_stmt.columnText(1) orelse continue;

            // Convert comma-separated list to JSON array
            var json_buf: [4096]u8 = undefined;
            var stream = std.io.fixedBufferStream(&json_buf);
            const writer = stream.writer();

            try writer.writeByte('[');
            var first = true;
            var iter = std.mem.splitScalar(u8, blockers, ',');
            while (iter.next()) |blocker_id| {
                if (!first) try writer.writeByte(',');
                try writer.writeByte('"');
                try writer.writeAll(blocker_id);
                try writer.writeByte('"');
                first = false;
            }
            try writer.writeByte(']');

            const json_blockers = stream.getWritten();

            var insert_stmt = try self.db.prepare(
                "INSERT INTO blocked_cache (issue_id, blocked_by, cached_at) VALUES (?1, ?2, ?3)",
            );
            defer insert_stmt.deinit();
            try insert_stmt.bindText(1, issue_id);
            try insert_stmt.bindText(2, json_blockers);
            try insert_stmt.bindInt(3, now);
            _ = try insert_stmt.step();
        }
    }

    /// Get cached blockers for an issue (returns JSON array string or null if not cached).
    pub fn getCachedBlockers(self: *Self, issue_id: []const u8) !?[]const u8 {
        var stmt = try self.db.prepare(
            "SELECT blocked_by FROM blocked_cache WHERE issue_id = ?1",
        );
        defer stmt.deinit();
        try stmt.bindText(1, issue_id);

        if (try stmt.step()) {
            if (stmt.columnText(0)) |blockers| {
                return try self.allocator.dupe(u8, blockers);
            }
        }
        return null;
    }

    // --- Helper Functions ---

    /// Mark an issue as dirty for sync.
    fn markDirty(self: *Self, id: []const u8) !void {
        const now = std.time.timestamp();
        var stmt = try self.db.prepare(
            "INSERT OR REPLACE INTO dirty_issues (issue_id, marked_at) VALUES (?1, ?2)",
        );
        defer stmt.deinit();
        try stmt.bindText(1, id);
        try stmt.bindInt(2, now);
        _ = try stmt.step();
    }

    /// Collect dependencies from a prepared statement.
    fn collectDependencies(self: *Self, stmt: *Statement) ![]Dependency {
        var deps: std.ArrayList(Dependency) = .{};
        errdefer {
            for (deps.items) |*dep| {
                self.freeDependency(dep);
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
            dep.created_by = try self.dupeOptionalText(stmt.columnText(4));
            dep.metadata = try self.dupeOptionalText(stmt.columnText(5));
            dep.thread_id = try self.dupeOptionalText(stmt.columnText(6));

            try deps.append(self.allocator, dep);
        }

        return deps.toOwnedSlice(self.allocator);
    }

    /// Helper to duplicate optional text from a column.
    fn dupeOptionalText(self: *Self, text: ?[]const u8) !?[]const u8 {
        return if (text) |t| try self.allocator.dupe(u8, t) else null;
    }

    /// Collect issues from a prepared statement.
    /// Delegates to IssueStore which owns the canonical rowToIssue implementation.
    fn collectIssues(self: *Self, stmt: *Statement) ![]Issue {
        var issue_store = IssueStore.init(self.db, self.allocator);
        return issue_store.collectIssuesFromStmt(stmt);
    }

    /// Free a single dependency's allocated memory.
    fn freeDependency(self: *Self, dep: *Dependency) void {
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

    /// Free an array of dependencies.
    pub fn freeDependencies(self: *Self, deps: []Dependency) void {
        for (deps) |*dep| {
            self.freeDependency(dep);
        }
        self.allocator.free(deps);
    }

    /// Free an array of issues.
    pub fn freeIssues(self: *Self, issues: []Issue) void {
        for (issues) |*issue| {
            issue.deinit(self.allocator);
        }
        self.allocator.free(issues);
    }

    /// Free an array of cycle strings.
    pub fn freeCycles(self: *Self, cycles: [][]const u8) void {
        for (cycles) |c| {
            self.allocator.free(c);
        }
        self.allocator.free(cycles);
    }
};

// --- Tests ---

const schema = @import("schema.zig");

test "DependencyStore.add creates dependency" {
    const allocator = std.testing.allocator;
    var db = try Database.open(allocator, ":memory:");
    defer db.close();

    try schema.createSchema(&db);

    var issue_store = IssueStore.init(&db, allocator);
    try issue_store.insert(Issue.init("bd-parent", "Parent", 1706540000));
    try issue_store.insert(Issue.init("bd-child", "Child", 1706540000));

    var dep_store = DependencyStore.init(&db, allocator);

    const dep = Dependency{
        .issue_id = "bd-child",
        .depends_on_id = "bd-parent",
        .dep_type = .blocks,
        .created_at = 1706540000,
        .created_by = null,
        .metadata = null,
        .thread_id = null,
    };

    try dep_store.add(dep);

    // Verify dependency exists
    const deps = try dep_store.getDependencies("bd-child");
    defer dep_store.freeDependencies(deps);

    try std.testing.expectEqual(@as(usize, 1), deps.len);
    try std.testing.expectEqualStrings("bd-parent", deps[0].depends_on_id);
}

test "DependencyStore.add rejects self-dependency" {
    const allocator = std.testing.allocator;
    var db = try Database.open(allocator, ":memory:");
    defer db.close();

    try schema.createSchema(&db);

    var issue_store = IssueStore.init(&db, allocator);
    try issue_store.insert(Issue.init("bd-self", "Self", 1706540000));

    var dep_store = DependencyStore.init(&db, allocator);

    const dep = Dependency{
        .issue_id = "bd-self",
        .depends_on_id = "bd-self",
        .dep_type = .blocks,
        .created_at = 1706540000,
        .created_by = null,
        .metadata = null,
        .thread_id = null,
    };

    try std.testing.expectError(DependencyStoreError.SelfDependency, dep_store.add(dep));
}

test "DependencyStore.add rejects direct cycle" {
    const allocator = std.testing.allocator;
    var db = try Database.open(allocator, ":memory:");
    defer db.close();

    try schema.createSchema(&db);

    var issue_store = IssueStore.init(&db, allocator);
    try issue_store.insert(Issue.init("bd-a", "A", 1706540000));
    try issue_store.insert(Issue.init("bd-b", "B", 1706540000));

    var dep_store = DependencyStore.init(&db, allocator);

    // A depends on B
    try dep_store.add(.{
        .issue_id = "bd-a",
        .depends_on_id = "bd-b",
        .dep_type = .blocks,
        .created_at = 1706540000,
        .created_by = null,
        .metadata = null,
        .thread_id = null,
    });

    // B depends on A would create a cycle
    const cycle_dep = Dependency{
        .issue_id = "bd-b",
        .depends_on_id = "bd-a",
        .dep_type = .blocks,
        .created_at = 1706540000,
        .created_by = null,
        .metadata = null,
        .thread_id = null,
    };

    try std.testing.expectError(DependencyStoreError.CycleDetected, dep_store.add(cycle_dep));
}

test "DependencyStore.add rejects indirect cycle (A->B->C->A)" {
    const allocator = std.testing.allocator;
    var db = try Database.open(allocator, ":memory:");
    defer db.close();

    try schema.createSchema(&db);

    var issue_store = IssueStore.init(&db, allocator);
    try issue_store.insert(Issue.init("bd-a", "A", 1706540000));
    try issue_store.insert(Issue.init("bd-b", "B", 1706540000));
    try issue_store.insert(Issue.init("bd-c", "C", 1706540000));

    var dep_store = DependencyStore.init(&db, allocator);

    // A depends on B
    try dep_store.add(.{
        .issue_id = "bd-a",
        .depends_on_id = "bd-b",
        .dep_type = .blocks,
        .created_at = 1706540000,
        .created_by = null,
        .metadata = null,
        .thread_id = null,
    });

    // B depends on C
    try dep_store.add(.{
        .issue_id = "bd-b",
        .depends_on_id = "bd-c",
        .dep_type = .blocks,
        .created_at = 1706540000,
        .created_by = null,
        .metadata = null,
        .thread_id = null,
    });

    // C depends on A would create a cycle
    const cycle_dep = Dependency{
        .issue_id = "bd-c",
        .depends_on_id = "bd-a",
        .dep_type = .blocks,
        .created_at = 1706540000,
        .created_by = null,
        .metadata = null,
        .thread_id = null,
    };

    try std.testing.expectError(DependencyStoreError.CycleDetected, dep_store.add(cycle_dep));
}

test "DependencyStore.remove removes dependency" {
    const allocator = std.testing.allocator;
    var db = try Database.open(allocator, ":memory:");
    defer db.close();

    try schema.createSchema(&db);

    var issue_store = IssueStore.init(&db, allocator);
    try issue_store.insert(Issue.init("bd-parent", "Parent", 1706540000));
    try issue_store.insert(Issue.init("bd-child", "Child", 1706540000));

    var dep_store = DependencyStore.init(&db, allocator);

    try dep_store.add(.{
        .issue_id = "bd-child",
        .depends_on_id = "bd-parent",
        .dep_type = .blocks,
        .created_at = 1706540000,
        .created_by = null,
        .metadata = null,
        .thread_id = null,
    });

    // Remove dependency
    try dep_store.remove("bd-child", "bd-parent");

    // Verify dependency is gone
    const deps = try dep_store.getDependencies("bd-child");
    defer dep_store.freeDependencies(deps);

    try std.testing.expectEqual(@as(usize, 0), deps.len);
}

test "DependencyStore.getDependencies returns dependencies" {
    const allocator = std.testing.allocator;
    var db = try Database.open(allocator, ":memory:");
    defer db.close();

    try schema.createSchema(&db);

    var issue_store = IssueStore.init(&db, allocator);
    try issue_store.insert(Issue.init("bd-a", "A", 1706540000));
    try issue_store.insert(Issue.init("bd-b", "B", 1706540000));
    try issue_store.insert(Issue.init("bd-c", "C", 1706540000));

    var dep_store = DependencyStore.init(&db, allocator);

    // A depends on B and C
    try dep_store.add(.{
        .issue_id = "bd-a",
        .depends_on_id = "bd-b",
        .dep_type = .blocks,
        .created_at = 1706540000,
        .created_by = null,
        .metadata = null,
        .thread_id = null,
    });
    try dep_store.add(.{
        .issue_id = "bd-a",
        .depends_on_id = "bd-c",
        .dep_type = .waits_for,
        .created_at = 1706540000,
        .created_by = null,
        .metadata = null,
        .thread_id = null,
    });

    const deps = try dep_store.getDependencies("bd-a");
    defer dep_store.freeDependencies(deps);

    try std.testing.expectEqual(@as(usize, 2), deps.len);
}

test "DependencyStore.getDependents returns dependents" {
    const allocator = std.testing.allocator;
    var db = try Database.open(allocator, ":memory:");
    defer db.close();

    try schema.createSchema(&db);

    var issue_store = IssueStore.init(&db, allocator);
    try issue_store.insert(Issue.init("bd-parent", "Parent", 1706540000));
    try issue_store.insert(Issue.init("bd-child1", "Child 1", 1706540000));
    try issue_store.insert(Issue.init("bd-child2", "Child 2", 1706540000));

    var dep_store = DependencyStore.init(&db, allocator);

    // Both children depend on parent
    try dep_store.add(.{
        .issue_id = "bd-child1",
        .depends_on_id = "bd-parent",
        .dep_type = .blocks,
        .created_at = 1706540000,
        .created_by = null,
        .metadata = null,
        .thread_id = null,
    });
    try dep_store.add(.{
        .issue_id = "bd-child2",
        .depends_on_id = "bd-parent",
        .dep_type = .blocks,
        .created_at = 1706540000,
        .created_by = null,
        .metadata = null,
        .thread_id = null,
    });

    const dependents = try dep_store.getDependents("bd-parent");
    defer dep_store.freeDependencies(dependents);

    try std.testing.expectEqual(@as(usize, 2), dependents.len);
}

test "DependencyStore.getReadyIssues excludes blocked issues" {
    const allocator = std.testing.allocator;
    var db = try Database.open(allocator, ":memory:");
    defer db.close();

    try schema.createSchema(&db);

    var issue_store = IssueStore.init(&db, allocator);
    try issue_store.insert(Issue.init("bd-blocker", "Blocker", 1706540000));
    try issue_store.insert(Issue.init("bd-blocked", "Blocked", 1706540000));
    try issue_store.insert(Issue.init("bd-ready", "Ready", 1706540000));

    var dep_store = DependencyStore.init(&db, allocator);

    // blocked depends on blocker
    try dep_store.add(.{
        .issue_id = "bd-blocked",
        .depends_on_id = "bd-blocker",
        .dep_type = .blocks,
        .created_at = 1706540000,
        .created_by = null,
        .metadata = null,
        .thread_id = null,
    });

    const ready = try dep_store.getReadyIssues();
    defer dep_store.freeIssues(ready);

    // Should only have ready and blocker (blocker has no deps)
    try std.testing.expectEqual(@as(usize, 2), ready.len);

    // Verify blocked is not in the list
    for (ready) |issue| {
        try std.testing.expect(!std.mem.eql(u8, issue.id, "bd-blocked"));
    }
}

test "DependencyStore.getReadyIssues includes issue when blocker is closed" {
    const allocator = std.testing.allocator;
    var db = try Database.open(allocator, ":memory:");
    defer db.close();

    try schema.createSchema(&db);

    var issue_store = IssueStore.init(&db, allocator);

    var blocker = Issue.init("bd-blocker", "Blocker", 1706540000);
    blocker.status = .closed;
    try issue_store.insert(blocker);

    try issue_store.insert(Issue.init("bd-child", "Child", 1706540000));

    var dep_store = DependencyStore.init(&db, allocator);

    // child depends on blocker (which is closed)
    try dep_store.add(.{
        .issue_id = "bd-child",
        .depends_on_id = "bd-blocker",
        .dep_type = .blocks,
        .created_at = 1706540000,
        .created_by = null,
        .metadata = null,
        .thread_id = null,
    });

    const ready = try dep_store.getReadyIssues();
    defer dep_store.freeIssues(ready);

    // Child should be ready since blocker is closed
    try std.testing.expectEqual(@as(usize, 1), ready.len);
    try std.testing.expectEqualStrings("bd-child", ready[0].id);
}

test "DependencyStore.getBlockedIssues returns only blocked issues" {
    const allocator = std.testing.allocator;
    var db = try Database.open(allocator, ":memory:");
    defer db.close();

    try schema.createSchema(&db);

    var issue_store = IssueStore.init(&db, allocator);
    try issue_store.insert(Issue.init("bd-blocker", "Blocker", 1706540000));
    try issue_store.insert(Issue.init("bd-blocked", "Blocked", 1706540000));
    try issue_store.insert(Issue.init("bd-ready", "Ready", 1706540000));

    var dep_store = DependencyStore.init(&db, allocator);

    // blocked depends on blocker
    try dep_store.add(.{
        .issue_id = "bd-blocked",
        .depends_on_id = "bd-blocker",
        .dep_type = .blocks,
        .created_at = 1706540000,
        .created_by = null,
        .metadata = null,
        .thread_id = null,
    });

    const blocked = try dep_store.getBlockedIssues();
    defer dep_store.freeIssues(blocked);

    try std.testing.expectEqual(@as(usize, 1), blocked.len);
    try std.testing.expectEqualStrings("bd-blocked", blocked[0].id);
}

test "DependencyStore.rebuildBlockedCache populates cache" {
    const allocator = std.testing.allocator;
    var db = try Database.open(allocator, ":memory:");
    defer db.close();

    try schema.createSchema(&db);

    var issue_store = IssueStore.init(&db, allocator);
    try issue_store.insert(Issue.init("bd-blocker1", "Blocker 1", 1706540000));
    try issue_store.insert(Issue.init("bd-blocker2", "Blocker 2", 1706540000));
    try issue_store.insert(Issue.init("bd-blocked", "Blocked", 1706540000));

    var dep_store = DependencyStore.init(&db, allocator);

    // blocked depends on both blockers
    try dep_store.add(.{
        .issue_id = "bd-blocked",
        .depends_on_id = "bd-blocker1",
        .dep_type = .blocks,
        .created_at = 1706540000,
        .created_by = null,
        .metadata = null,
        .thread_id = null,
    });
    try dep_store.add(.{
        .issue_id = "bd-blocked",
        .depends_on_id = "bd-blocker2",
        .dep_type = .blocks,
        .created_at = 1706540000,
        .created_by = null,
        .metadata = null,
        .thread_id = null,
    });

    try dep_store.rebuildBlockedCache();

    const cached = try dep_store.getCachedBlockers("bd-blocked");
    defer if (cached) |c| allocator.free(c);

    try std.testing.expect(cached != null);
    // Cache should contain JSON array with both blockers
    try std.testing.expect(std.mem.indexOf(u8, cached.?, "bd-blocker1") != null);
    try std.testing.expect(std.mem.indexOf(u8, cached.?, "bd-blocker2") != null);
}

test "DependencyStore.invalidateBlockedCache removes cache entry" {
    const allocator = std.testing.allocator;
    var db = try Database.open(allocator, ":memory:");
    defer db.close();

    try schema.createSchema(&db);

    var issue_store = IssueStore.init(&db, allocator);
    try issue_store.insert(Issue.init("bd-blocker", "Blocker", 1706540000));
    try issue_store.insert(Issue.init("bd-blocked", "Blocked", 1706540000));

    var dep_store = DependencyStore.init(&db, allocator);

    try dep_store.add(.{
        .issue_id = "bd-blocked",
        .depends_on_id = "bd-blocker",
        .dep_type = .blocks,
        .created_at = 1706540000,
        .created_by = null,
        .metadata = null,
        .thread_id = null,
    });

    try dep_store.rebuildBlockedCache();

    // Verify cache exists
    const cached1 = try dep_store.getCachedBlockers("bd-blocked");
    try std.testing.expect(cached1 != null);
    allocator.free(cached1.?);

    // Remove dependency (which invalidates cache)
    try dep_store.remove("bd-blocked", "bd-blocker");

    // Cache should be gone
    const cached2 = try dep_store.getCachedBlockers("bd-blocked");
    try std.testing.expect(cached2 == null);
}

test "DependencyStore dirty tracking on add" {
    const allocator = std.testing.allocator;
    var db = try Database.open(allocator, ":memory:");
    defer db.close();

    try schema.createSchema(&db);

    var issue_store = IssueStore.init(&db, allocator);
    try issue_store.insert(Issue.init("bd-parent", "Parent", 1706540000));
    try issue_store.insert(Issue.init("bd-child", "Child", 1706540000));

    // Clear dirty flags from insert
    try issue_store.clearDirty("bd-parent");
    try issue_store.clearDirty("bd-child");

    var dep_store = DependencyStore.init(&db, allocator);

    try dep_store.add(.{
        .issue_id = "bd-child",
        .depends_on_id = "bd-parent",
        .dep_type = .blocks,
        .created_at = 1706540000,
        .created_by = null,
        .metadata = null,
        .thread_id = null,
    });

    // Child should be marked dirty
    const dirty_ids = try issue_store.getDirtyIds();
    defer {
        for (dirty_ids) |id| allocator.free(id);
        allocator.free(dirty_ids);
    }

    try std.testing.expectEqual(@as(usize, 1), dirty_ids.len);
    try std.testing.expectEqualStrings("bd-child", dirty_ids[0]);
}
