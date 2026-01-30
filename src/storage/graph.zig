//! Dependency graph operations for beads_zig.
//!
//! Provides dependency management including:
//! - Add/remove dependencies
//! - Cycle detection (DFS algorithm)
//! - Query dependencies and dependents
//! - Ready/blocked issue queries

const std = @import("std");
const store_mod = @import("store.zig");
const IssueStore = store_mod.IssueStore;
const Issue = @import("../models/issue.zig").Issue;
const Dependency = @import("../models/dependency.zig").Dependency;
const DependencyType = @import("../models/dependency.zig").DependencyType;
const Status = @import("../models/status.zig").Status;

pub const DependencyGraphError = error{
    SelfDependency,
    CycleDetected,
    DependencyNotFound,
    IssueNotFound,
};

pub const DependencyGraph = struct {
    store: *IssueStore,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(store: *IssueStore, allocator: std.mem.Allocator) Self {
        return .{
            .store = store,
            .allocator = allocator,
        };
    }

    /// Add a dependency (issue_id depends on depends_on_id).
    /// Returns error.SelfDependency if trying to depend on self.
    /// Returns error.CycleDetected if adding would create a cycle.
    pub fn addDependency(self: *Self, dep: Dependency) !void {
        // Check for self-dependency
        if (std.mem.eql(u8, dep.issue_id, dep.depends_on_id)) {
            return DependencyGraphError.SelfDependency;
        }

        // Check if issue exists
        const issue = self.store.getRef(dep.issue_id) orelse
            return DependencyGraphError.IssueNotFound;

        // Check for cycles before inserting
        if (try self.wouldCreateCycle(dep.issue_id, dep.depends_on_id)) {
            return DependencyGraphError.CycleDetected;
        }

        // Check if dependency already exists
        for (issue.dependencies) |existing| {
            if (std.mem.eql(u8, existing.depends_on_id, dep.depends_on_id)) {
                return; // Already exists, no-op
            }
        }

        // Clone and add the dependency
        const cloned = try cloneDependency(dep, self.allocator);
        errdefer freeDependency(@constCast(&cloned), self.allocator);

        const new_deps = try self.allocator.alloc(Dependency, issue.dependencies.len + 1);
        @memcpy(new_deps[0..issue.dependencies.len], issue.dependencies);
        new_deps[issue.dependencies.len] = cloned;

        // Only free the old array, not the dependency contents (they're now in new_deps)
        if (issue.dependencies.len > 0) {
            self.allocator.free(issue.dependencies);
        }
        issue.dependencies = new_deps;

        try self.store.markDirty(dep.issue_id);
    }

    /// Remove a dependency.
    pub fn removeDependency(self: *Self, issue_id: []const u8, depends_on_id: []const u8) !void {
        const issue = self.store.getRef(issue_id) orelse
            return DependencyGraphError.IssueNotFound;

        var found_idx: ?usize = null;
        for (issue.dependencies, 0..) |dep, i| {
            if (std.mem.eql(u8, dep.depends_on_id, depends_on_id)) {
                found_idx = i;
                break;
            }
        }

        if (found_idx) |fi| {
            freeDependency(@constCast(&issue.dependencies[fi]), self.allocator);

            if (issue.dependencies.len == 1) {
                self.allocator.free(issue.dependencies);
                issue.dependencies = &[_]Dependency{};
            } else {
                const new_deps = try self.allocator.alloc(Dependency, issue.dependencies.len - 1);
                var j: usize = 0;
                for (issue.dependencies, 0..) |dep, i| {
                    if (i != fi) {
                        new_deps[j] = dep;
                        j += 1;
                    }
                }
                self.allocator.free(issue.dependencies);
                issue.dependencies = new_deps;
            }

            try self.store.markDirty(issue_id);
        }
    }

    /// Get dependencies for an issue (what it depends on).
    pub fn getDependencies(self: *Self, issue_id: []const u8) ![]Dependency {
        const issue = self.store.getRef(issue_id) orelse return &[_]Dependency{};

        if (issue.dependencies.len == 0) return &[_]Dependency{};

        const deps = try self.allocator.alloc(Dependency, issue.dependencies.len);
        errdefer self.allocator.free(deps);

        for (issue.dependencies, 0..) |dep, i| {
            deps[i] = try cloneDependency(dep, self.allocator);
        }

        return deps;
    }

    /// Get dependents of an issue (what depends on it).
    pub fn getDependents(self: *Self, issue_id: []const u8) ![]Dependency {
        var deps: std.ArrayListUnmanaged(Dependency) = .{};
        errdefer {
            for (deps.items) |*dep| {
                freeDependency(dep, self.allocator);
            }
            deps.deinit(self.allocator);
        }

        for (self.store.getAllRef()) |issue| {
            for (issue.dependencies) |dep| {
                if (std.mem.eql(u8, dep.depends_on_id, issue_id)) {
                    const cloned = try cloneDependency(dep, self.allocator);
                    try deps.append(self.allocator, cloned);
                }
            }
        }

        return deps.toOwnedSlice(self.allocator);
    }

    /// Check if adding a dependency would create a cycle.
    /// Uses DFS from depends_on_id to see if it can reach issue_id.
    pub fn wouldCreateCycle(self: *Self, issue_id: []const u8, depends_on_id: []const u8) !bool {
        var visited: std.StringHashMapUnmanaged(void) = .{};
        defer {
            var key_it = visited.keyIterator();
            while (key_it.next()) |key| {
                self.allocator.free(key.*);
            }
            visited.deinit(self.allocator);
        }

        return try self.dfsReachable(depends_on_id, issue_id, &visited);
    }

    fn dfsReachable(self: *Self, from: []const u8, target: []const u8, visited: *std.StringHashMapUnmanaged(void)) !bool {
        if (std.mem.eql(u8, from, target)) return true;
        if (visited.contains(from)) return false;

        const from_copy = try self.allocator.dupe(u8, from);
        errdefer self.allocator.free(from_copy);
        try visited.put(self.allocator, from_copy, {});

        const issue = self.store.getRef(from) orelse return false;

        for (issue.dependencies) |dep| {
            if (try self.dfsReachable(dep.depends_on_id, target, visited)) {
                return true;
            }
        }
        return false;
    }

    /// Detect all cycles in the dependency graph.
    /// Returns array of cycle paths, or null if no cycles.
    pub fn detectCycles(self: *Self) !?[][]const u8 {
        var all_issues: std.StringHashMapUnmanaged(void) = .{};
        defer {
            var it = all_issues.keyIterator();
            while (it.next()) |key| {
                self.allocator.free(key.*);
            }
            all_issues.deinit(self.allocator);
        }

        // Collect all issue IDs involved in dependencies
        for (self.store.getAllRef()) |issue| {
            if (issue.dependencies.len > 0) {
                if (!all_issues.contains(issue.id)) {
                    const id_copy = try self.allocator.dupe(u8, issue.id);
                    try all_issues.put(self.allocator, id_copy, {});
                }
                for (issue.dependencies) |dep| {
                    if (!all_issues.contains(dep.depends_on_id)) {
                        const id_copy = try self.allocator.dupe(u8, dep.depends_on_id);
                        try all_issues.put(self.allocator, id_copy, {});
                    }
                }
            }
        }

        var cycles: std.ArrayListUnmanaged([]const u8) = .{};
        errdefer {
            for (cycles.items) |c| {
                self.allocator.free(c);
            }
            cycles.deinit(self.allocator);
        }

        var visited: std.StringHashMapUnmanaged(void) = .{};
        defer visited.deinit(self.allocator);

        var rec_stack: std.StringHashMapUnmanaged(void) = .{};
        defer rec_stack.deinit(self.allocator);

        var it = all_issues.keyIterator();
        while (it.next()) |key| {
            if (!visited.contains(key.*)) {
                var path: std.ArrayListUnmanaged([]const u8) = .{};
                defer path.deinit(self.allocator);

                if (try self.detectCycleDfs(key.*, &visited, &rec_stack, &path)) {
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
        visited: *std.StringHashMapUnmanaged(void),
        rec_stack: *std.StringHashMapUnmanaged(void),
        path: *std.ArrayListUnmanaged([]const u8),
    ) !bool {
        try visited.put(self.allocator, node, {});
        try rec_stack.put(self.allocator, node, {});
        try path.append(self.allocator, node);

        const issue = self.store.getRef(node) orelse {
            _ = path.popOrNull();
            _ = rec_stack.remove(node);
            return false;
        };

        for (issue.dependencies) |dep| {
            if (!visited.contains(dep.depends_on_id)) {
                if (try self.detectCycleDfs(dep.depends_on_id, visited, rec_stack, path)) {
                    return true;
                }
            } else if (rec_stack.contains(dep.depends_on_id)) {
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

        var results: std.ArrayListUnmanaged(Issue) = .{};
        errdefer {
            for (results.items) |*issue| {
                issue.deinit(self.allocator);
            }
            results.deinit(self.allocator);
        }

        for (self.store.getAllRef()) |issue| {
            // Must be open
            if (!statusEql(issue.status, .open)) continue;

            // Must not be deferred to future
            if (issue.defer_until.value) |defer_time| {
                if (defer_time > now) continue;
            }

            // Must not have any open blockers
            var has_open_blocker = false;
            for (issue.dependencies) |dep| {
                if (self.store.getRef(dep.depends_on_id)) |blocker| {
                    if (!statusEql(blocker.status, .closed) and
                        !statusEql(blocker.status, .tombstone))
                    {
                        has_open_blocker = true;
                        break;
                    }
                }
            }
            if (has_open_blocker) continue;

            try results.append(self.allocator, try issue.clone(self.allocator));
        }

        // Sort by priority then created_at
        std.mem.sortUnstable(Issue, results.items, {}, struct {
            fn lessThan(_: void, a: Issue, b: Issue) bool {
                if (a.priority.value != b.priority.value) {
                    return a.priority.value < b.priority.value;
                }
                return a.created_at.value < b.created_at.value;
            }
        }.lessThan);

        return results.toOwnedSlice(self.allocator);
    }

    /// Get all blocked issues (open issues with unresolved dependencies).
    pub fn getBlockedIssues(self: *Self) ![]Issue {
        var results: std.ArrayListUnmanaged(Issue) = .{};
        errdefer {
            for (results.items) |*issue| {
                issue.deinit(self.allocator);
            }
            results.deinit(self.allocator);
        }

        for (self.store.getAllRef()) |issue| {
            // Must be open
            if (!statusEql(issue.status, .open)) continue;

            // Must have at least one open blocker
            var has_open_blocker = false;
            for (issue.dependencies) |dep| {
                if (self.store.getRef(dep.depends_on_id)) |blocker| {
                    if (!statusEql(blocker.status, .closed) and
                        !statusEql(blocker.status, .tombstone))
                    {
                        has_open_blocker = true;
                        break;
                    }
                }
            }
            if (!has_open_blocker) continue;

            try results.append(self.allocator, try issue.clone(self.allocator));
        }

        // Sort by priority then created_at
        std.mem.sortUnstable(Issue, results.items, {}, struct {
            fn lessThan(_: void, a: Issue, b: Issue) bool {
                if (a.priority.value != b.priority.value) {
                    return a.priority.value < b.priority.value;
                }
                return a.created_at.value < b.created_at.value;
            }
        }.lessThan);

        return results.toOwnedSlice(self.allocator);
    }

    /// Get blockers for an issue (open issues that this issue depends on).
    pub fn getBlockers(self: *Self, issue_id: []const u8) ![]Issue {
        var results: std.ArrayListUnmanaged(Issue) = .{};
        errdefer {
            for (results.items) |*issue| {
                issue.deinit(self.allocator);
            }
            results.deinit(self.allocator);
        }

        const issue = self.store.getRef(issue_id) orelse return results.toOwnedSlice(self.allocator);

        for (issue.dependencies) |dep| {
            if (self.store.getRef(dep.depends_on_id)) |blocker| {
                if (!statusEql(blocker.status, .closed) and
                    !statusEql(blocker.status, .tombstone))
                {
                    try results.append(self.allocator, try blocker.clone(self.allocator));
                }
            }
        }

        return results.toOwnedSlice(self.allocator);
    }

    /// Free an array of dependencies.
    pub fn freeDependencies(self: *Self, deps: []Dependency) void {
        for (deps) |*dep| {
            freeDependency(dep, self.allocator);
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

// Helper functions
fn statusEql(a: Status, b: Status) bool {
    const Tag = std.meta.Tag(Status);
    const tag_a: Tag = a;
    const tag_b: Tag = b;
    if (tag_a != tag_b) return false;
    return if (tag_a == .custom) std.mem.eql(u8, a.custom, b.custom) else true;
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

// --- Tests ---

test "DependencyGraph rejects self-dependency" {
    const allocator = std.testing.allocator;
    var store = IssueStore.init(allocator, "test.jsonl");
    defer store.deinit();

    try store.insert(Issue.init("bd-self", "Self", 1706540000));

    var graph = DependencyGraph.init(&store, allocator);

    const dep = Dependency{
        .issue_id = "bd-self",
        .depends_on_id = "bd-self",
        .dep_type = .blocks,
        .created_at = 1706540000,
        .created_by = null,
        .metadata = null,
        .thread_id = null,
    };

    try std.testing.expectError(DependencyGraphError.SelfDependency, graph.addDependency(dep));
}

test "DependencyGraph rejects direct cycle" {
    const allocator = std.testing.allocator;
    var store = IssueStore.init(allocator, "test.jsonl");
    defer store.deinit();

    try store.insert(Issue.init("bd-a", "A", 1706540000));
    try store.insert(Issue.init("bd-b", "B", 1706540000));

    var graph = DependencyGraph.init(&store, allocator);

    // A depends on B
    try graph.addDependency(.{
        .issue_id = "bd-a",
        .depends_on_id = "bd-b",
        .dep_type = .blocks,
        .created_at = 1706540000,
        .created_by = null,
        .metadata = null,
        .thread_id = null,
    });

    // B depends on A would create a cycle
    try std.testing.expectError(DependencyGraphError.CycleDetected, graph.addDependency(.{
        .issue_id = "bd-b",
        .depends_on_id = "bd-a",
        .dep_type = .blocks,
        .created_at = 1706540000,
        .created_by = null,
        .metadata = null,
        .thread_id = null,
    }));
}

test "DependencyGraph rejects indirect cycle" {
    const allocator = std.testing.allocator;
    var store = IssueStore.init(allocator, "test.jsonl");
    defer store.deinit();

    try store.insert(Issue.init("bd-a", "A", 1706540000));
    try store.insert(Issue.init("bd-b", "B", 1706540000));
    try store.insert(Issue.init("bd-c", "C", 1706540000));

    var graph = DependencyGraph.init(&store, allocator);

    // A depends on B
    try graph.addDependency(.{
        .issue_id = "bd-a",
        .depends_on_id = "bd-b",
        .dep_type = .blocks,
        .created_at = 1706540000,
        .created_by = null,
        .metadata = null,
        .thread_id = null,
    });

    // B depends on C
    try graph.addDependency(.{
        .issue_id = "bd-b",
        .depends_on_id = "bd-c",
        .dep_type = .blocks,
        .created_at = 1706540000,
        .created_by = null,
        .metadata = null,
        .thread_id = null,
    });

    // C depends on A would create a cycle
    try std.testing.expectError(DependencyGraphError.CycleDetected, graph.addDependency(.{
        .issue_id = "bd-c",
        .depends_on_id = "bd-a",
        .dep_type = .blocks,
        .created_at = 1706540000,
        .created_by = null,
        .metadata = null,
        .thread_id = null,
    }));
}

test "DependencyGraph getReadyIssues excludes blocked" {
    const allocator = std.testing.allocator;
    var store = IssueStore.init(allocator, "test.jsonl");
    defer store.deinit();

    try store.insert(Issue.init("bd-blocker", "Blocker", 1706540000));
    try store.insert(Issue.init("bd-blocked", "Blocked", 1706540000));
    try store.insert(Issue.init("bd-ready", "Ready", 1706540000));

    var graph = DependencyGraph.init(&store, allocator);

    try graph.addDependency(.{
        .issue_id = "bd-blocked",
        .depends_on_id = "bd-blocker",
        .dep_type = .blocks,
        .created_at = 1706540000,
        .created_by = null,
        .metadata = null,
        .thread_id = null,
    });

    const ready = try graph.getReadyIssues();
    defer graph.freeIssues(ready);

    try std.testing.expectEqual(@as(usize, 2), ready.len);

    // Verify blocked is not in the list
    for (ready) |issue| {
        try std.testing.expect(!std.mem.eql(u8, issue.id, "bd-blocked"));
    }
}

test "DependencyGraph getReadyIssues includes when blocker closed" {
    const allocator = std.testing.allocator;
    var store = IssueStore.init(allocator, "test.jsonl");
    defer store.deinit();

    var blocker = Issue.init("bd-blocker", "Blocker", 1706540000);
    blocker.status = .closed;
    try store.insert(blocker);
    try store.insert(Issue.init("bd-child", "Child", 1706540000));

    var graph = DependencyGraph.init(&store, allocator);

    try graph.addDependency(.{
        .issue_id = "bd-child",
        .depends_on_id = "bd-blocker",
        .dep_type = .blocks,
        .created_at = 1706540000,
        .created_by = null,
        .metadata = null,
        .thread_id = null,
    });

    const ready = try graph.getReadyIssues();
    defer graph.freeIssues(ready);

    try std.testing.expectEqual(@as(usize, 1), ready.len);
    try std.testing.expectEqualStrings("bd-child", ready[0].id);
}

test "DependencyGraph getBlockedIssues returns only blocked" {
    const allocator = std.testing.allocator;
    var store = IssueStore.init(allocator, "test.jsonl");
    defer store.deinit();

    try store.insert(Issue.init("bd-blocker", "Blocker", 1706540000));
    try store.insert(Issue.init("bd-blocked", "Blocked", 1706540000));
    try store.insert(Issue.init("bd-ready", "Ready", 1706540000));

    var graph = DependencyGraph.init(&store, allocator);

    try graph.addDependency(.{
        .issue_id = "bd-blocked",
        .depends_on_id = "bd-blocker",
        .dep_type = .blocks,
        .created_at = 1706540000,
        .created_by = null,
        .metadata = null,
        .thread_id = null,
    });

    const blocked = try graph.getBlockedIssues();
    defer graph.freeIssues(blocked);

    try std.testing.expectEqual(@as(usize, 1), blocked.len);
    try std.testing.expectEqualStrings("bd-blocked", blocked[0].id);
}
