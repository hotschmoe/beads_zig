//! SQLite-backed dependency storage for beads_zig.
//!
//! Manages issue dependency relationships via SQLite including:
//! - Add/remove dependencies with cycle detection
//! - Query dependencies and dependents
//! - Ready/blocked issue queries
//! - Blocked cache management

const std = @import("std");
const sqlite = @import("sqlite.zig");
const Database = sqlite.Database;
const Statement = sqlite.Statement;
const Dependency = @import("../models/dependency.zig").Dependency;
const DependencyType = @import("../models/dependency.zig").DependencyType;

pub const DependencyStoreError = error{
    SelfDependency,
    CycleDetected,
    DependencyNotFound,
};

pub const BlockedInfo = struct {
    issue_id: []const u8,
    blocked_by: []const u8,
};

pub const DependencyStore = struct {
    db: *Database,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(db: *Database, allocator: std.mem.Allocator) Self {
        return .{ .db = db, .allocator = allocator };
    }

    pub fn add(
        self: *Self,
        issue_id: []const u8,
        depends_on_id: []const u8,
        dep_type: DependencyType,
        actor: ?[]const u8,
        now: i64,
    ) !void {
        if (std.mem.eql(u8, issue_id, depends_on_id)) {
            return DependencyStoreError.SelfDependency;
        }

        if (try self.wouldCreateCycle(issue_id, depends_on_id)) {
            return DependencyStoreError.CycleDetected;
        }

        const sql =
            \\INSERT OR REPLACE INTO dependencies (issue_id, depends_on_id, dep_type, created_at, created_by)
            \\VALUES (?1, ?2, ?3, ?4, ?5)
        ;
        var stmt = try self.db.prepare(sql);
        defer stmt.deinit();
        try stmt.bindText(1, issue_id);
        try stmt.bindText(2, depends_on_id);
        try stmt.bindText(3, dep_type.toString());
        try stmt.bindInt(4, now);
        try stmt.bindText(5, actor);
        _ = try stmt.step();

        try self.invalidateBlockedCache(issue_id);
        try self.markDirty(issue_id, now);
    }

    pub fn remove(self: *Self, issue_id: []const u8, depends_on_id: []const u8) !void {
        const sql = "DELETE FROM dependencies WHERE issue_id = ?1 AND depends_on_id = ?2";
        var stmt = try self.db.prepare(sql);
        defer stmt.deinit();
        try stmt.bindText(1, issue_id);
        try stmt.bindText(2, depends_on_id);
        _ = try stmt.step();

        try self.invalidateBlockedCache(issue_id);
        try self.markDirty(issue_id, std.time.timestamp());
    }

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

    pub fn getBlockingDeps(self: *Self, issue_id: []const u8) ![]Dependency {
        const sql =
            \\SELECT d.issue_id, d.depends_on_id, d.dep_type, d.created_at,
            \\       d.created_by, d.metadata, d.thread_id
            \\FROM dependencies d
            \\JOIN issues blocker ON d.depends_on_id = blocker.id
            \\WHERE d.issue_id = ?1
            \\AND d.dep_type IN ('blocks', 'conditional_blocks', 'waits_for')
            \\AND blocker.status NOT IN ('closed', 'tombstone')
        ;
        var stmt = try self.db.prepare(sql);
        defer stmt.deinit();
        try stmt.bindText(1, issue_id);
        return try self.collectDependencies(&stmt);
    }

    pub fn getReadyIssueIds(self: *Self) ![][]const u8 {
        const sql =
            \\SELECT i.id FROM issues i
            \\WHERE i.status IN ('open', 'in_progress')
            \\AND i.ephemeral = 0
            \\AND NOT EXISTS (
            \\    SELECT 1 FROM dependencies d
            \\    JOIN issues blocker ON d.depends_on_id = blocker.id
            \\    WHERE d.issue_id = i.id
            \\    AND d.dep_type IN ('blocks', 'conditional_blocks', 'waits_for')
            \\    AND blocker.status NOT IN ('closed', 'tombstone')
            \\)
            \\ORDER BY i.priority ASC, i.created_at ASC
        ;
        var stmt = try self.db.prepare(sql);
        defer stmt.deinit();
        return try self.collectIds(&stmt);
    }

    pub fn getBlockedIssueIds(self: *Self) ![]BlockedInfo {
        const sql =
            \\SELECT d.issue_id, GROUP_CONCAT(d.depends_on_id, ',') as blockers
            \\FROM dependencies d
            \\JOIN issues i ON d.issue_id = i.id
            \\JOIN issues blocker ON d.depends_on_id = blocker.id
            \\WHERE i.status IN ('open', 'in_progress')
            \\AND d.dep_type IN ('blocks', 'conditional_blocks', 'waits_for')
            \\AND blocker.status NOT IN ('closed', 'tombstone')
            \\GROUP BY d.issue_id
            \\ORDER BY i.priority ASC, i.created_at ASC
        ;
        var stmt = try self.db.prepare(sql);
        defer stmt.deinit();

        var results: std.ArrayList(BlockedInfo) = .empty;
        errdefer {
            for (results.items) |item| {
                self.allocator.free(item.issue_id);
                self.allocator.free(item.blocked_by);
            }
            results.deinit(self.allocator);
        }

        while (try stmt.step()) {
            const id_raw = stmt.columnText(0) orelse continue;
            const blockers_raw = stmt.columnText(1) orelse continue;
            try results.append(self.allocator, .{
                .issue_id = try self.allocator.dupe(u8, id_raw),
                .blocked_by = try self.allocator.dupe(u8, blockers_raw),
            });
        }

        return results.toOwnedSlice(self.allocator);
    }

    pub fn checkCycle(self: *Self, from_id: []const u8, to_id: []const u8) !bool {
        return try self.wouldCreateCycle(from_id, to_id);
    }

    pub fn detectAllCycles(self: *Self) ![][]const u8 {
        var all_ids = std.StringHashMap(void).init(self.allocator);
        defer {
            var it = all_ids.keyIterator();
            while (it.next()) |key| self.allocator.free(key.*);
            all_ids.deinit();
        }

        {
            var stmt = try self.db.prepare("SELECT DISTINCT issue_id FROM dependencies");
            defer stmt.deinit();
            while (try stmt.step()) {
                const id = stmt.columnText(0) orelse continue;
                if (!all_ids.contains(id)) {
                    try all_ids.put(try self.allocator.dupe(u8, id), {});
                }
            }
        }
        {
            var stmt = try self.db.prepare("SELECT DISTINCT depends_on_id FROM dependencies");
            defer stmt.deinit();
            while (try stmt.step()) {
                const id = stmt.columnText(0) orelse continue;
                if (!all_ids.contains(id)) {
                    try all_ids.put(try self.allocator.dupe(u8, id), {});
                }
            }
        }

        var cycles: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (cycles.items) |c| self.allocator.free(c);
            cycles.deinit(self.allocator);
        }

        var visited = std.StringHashMap(void).init(self.allocator);
        defer visited.deinit();
        var rec_stack = std.StringHashMap(void).init(self.allocator);
        defer rec_stack.deinit();

        var it = all_ids.keyIterator();
        while (it.next()) |key| {
            if (!visited.contains(key.*)) {
                var path: std.ArrayList([]const u8) = .empty;
                defer path.deinit(self.allocator);

                if (try self.detectCycleDfs(key.*, &visited, &rec_stack, &path)) {
                    const cycle_str = try std.mem.join(self.allocator, " -> ", path.items);
                    try cycles.append(self.allocator, cycle_str);
                }
            }
        }

        if (cycles.items.len == 0) {
            cycles.deinit(self.allocator);
            return &[_][]const u8{};
        }

        return cycles.toOwnedSlice(self.allocator);
    }

    // -- Blocked cache management --

    pub fn rebuildBlockedCache(self: *Self) !void {
        try self.db.exec("DELETE FROM blocked_issues_cache");

        const now = std.time.timestamp();
        const sql =
            \\SELECT d.issue_id, GROUP_CONCAT(d.depends_on_id, ',') as blockers
            \\FROM dependencies d
            \\JOIN issues blocker ON d.depends_on_id = blocker.id
            \\WHERE d.dep_type IN ('blocks', 'conditional_blocks', 'waits_for')
            \\AND blocker.status NOT IN ('closed', 'tombstone')
            \\GROUP BY d.issue_id
        ;
        var select_stmt = try self.db.prepare(sql);
        defer select_stmt.deinit();

        while (try select_stmt.step()) {
            const issue_id = select_stmt.columnText(0) orelse continue;
            const blockers = select_stmt.columnText(1) orelse continue;

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
                "INSERT INTO blocked_issues_cache (issue_id, blocked_by, blocked_at) VALUES (?1, ?2, ?3)",
            );
            defer insert_stmt.deinit();
            try insert_stmt.bindText(1, issue_id);
            try insert_stmt.bindText(2, json_blockers);
            try insert_stmt.bindInt(3, now);
            _ = try insert_stmt.step();
        }
    }

    pub fn getCachedBlockers(self: *Self, issue_id: []const u8) !?[]const u8 {
        var stmt = try self.db.prepare(
            "SELECT blocked_by FROM blocked_issues_cache WHERE issue_id = ?1",
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

    // -- Memory management --

    pub fn freeDependencies(self: *Self, deps: []Dependency) void {
        for (deps) |*dep| {
            self.freeDependency(@constCast(dep));
        }
        self.allocator.free(deps);
    }

    pub fn freeIds(self: *Self, ids: [][]const u8) void {
        for (ids) |id| self.allocator.free(id);
        self.allocator.free(ids);
    }

    pub fn freeBlockedInfos(self: *Self, infos: []BlockedInfo) void {
        for (infos) |info| {
            self.allocator.free(info.issue_id);
            self.allocator.free(info.blocked_by);
        }
        self.allocator.free(infos);
    }

    pub fn freeCycles(self: *Self, cycles: [][]const u8) void {
        for (cycles) |c| self.allocator.free(c);
        self.allocator.free(cycles);
    }

    // -- Internal helpers --

    fn wouldCreateCycle(self: *Self, issue_id: []const u8, depends_on_id: []const u8) !bool {
        var visited = std.StringHashMap(void).init(self.allocator);
        defer {
            var key_it = visited.keyIterator();
            while (key_it.next()) |key| self.allocator.free(key.*);
            visited.deinit();
        }
        return try self.dfsReachable(depends_on_id, issue_id, &visited);
    }

    fn dfsReachable(self: *Self, from: []const u8, target: []const u8, visited: *std.StringHashMap(void)) !bool {
        if (std.mem.eql(u8, from, target)) return true;
        if (visited.contains(from)) return false;

        const from_copy = try self.allocator.dupe(u8, from);
        errdefer self.allocator.free(from_copy);
        try visited.put(from_copy, {});

        const sql = "SELECT depends_on_id FROM dependencies WHERE issue_id = ?1";
        var stmt = try self.db.prepare(sql);
        defer stmt.deinit();
        try stmt.bindText(1, from);

        var neighbors: std.ArrayList([]const u8) = .empty;
        defer {
            for (neighbors.items) |n| self.allocator.free(n);
            neighbors.deinit(self.allocator);
        }

        while (try stmt.step()) {
            const dep_id = stmt.columnText(0) orelse continue;
            try neighbors.append(self.allocator, try self.allocator.dupe(u8, dep_id));
        }

        for (neighbors.items) |neighbor| {
            if (try self.dfsReachable(neighbor, target, visited)) return true;
        }
        return false;
    }

    fn detectCycleDfs(
        self: *Self,
        node: []const u8,
        visited: *std.StringHashMap(void),
        rec_stack: *std.StringHashMap(void),
        path: *std.ArrayList([]const u8),
    ) !bool {
        try visited.put(node, {});
        try rec_stack.put(node, {});
        try path.append(self.allocator, node);

        const sql = "SELECT depends_on_id FROM dependencies WHERE issue_id = ?1";
        var stmt = try self.db.prepare(sql);
        defer stmt.deinit();
        try stmt.bindText(1, node);

        var neighbors: std.ArrayList([]const u8) = .empty;
        defer {
            for (neighbors.items) |n| self.allocator.free(n);
            neighbors.deinit(self.allocator);
        }

        while (try stmt.step()) {
            const dep_id = stmt.columnText(0) orelse continue;
            try neighbors.append(self.allocator, try self.allocator.dupe(u8, dep_id));
        }

        for (neighbors.items) |neighbor| {
            if (!visited.contains(neighbor)) {
                if (try self.detectCycleDfs(neighbor, visited, rec_stack, path)) return true;
            } else if (rec_stack.contains(neighbor)) {
                try path.append(self.allocator, neighbor);
                return true;
            }
        }

        _ = rec_stack.remove(node);
        _ = path.pop();
        return false;
    }

    fn collectDependencies(self: *Self, stmt: *Statement) ![]Dependency {
        var deps: std.ArrayList(Dependency) = .empty;
        errdefer {
            for (deps.items) |*dep| self.freeDependency(dep);
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

    fn collectIds(self: *Self, stmt: *Statement) ![][]const u8 {
        var ids: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (ids.items) |id| self.allocator.free(id);
            ids.deinit(self.allocator);
        }

        while (try stmt.step()) {
            const id_raw = stmt.columnText(0) orelse continue;
            try ids.append(self.allocator, try self.allocator.dupe(u8, id_raw));
        }

        return ids.toOwnedSlice(self.allocator);
    }

    fn dupeOptionalText(self: *Self, text: ?[]const u8) !?[]const u8 {
        return if (text) |t| try self.allocator.dupe(u8, t) else null;
    }

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

    fn invalidateBlockedCache(self: *Self, issue_id: []const u8) !void {
        var stmt = try self.db.prepare("DELETE FROM blocked_issues_cache WHERE issue_id = ?1");
        defer stmt.deinit();
        try stmt.bindText(1, issue_id);
        _ = try stmt.step();
    }

    fn markDirty(self: *Self, id: []const u8, now: i64) !void {
        var stmt = try self.db.prepare(
            "INSERT OR REPLACE INTO dirty_issues (issue_id, marked_at) VALUES (?1, ?2)",
        );
        defer stmt.deinit();
        try stmt.bindText(1, id);
        try stmt.bindInt(2, now);
        _ = try stmt.step();
    }
};

// --- Tests ---

const schema = @import("schema.zig");

fn setupTestDb() !struct { db: Database, allocator: std.mem.Allocator } {
    const allocator = std.testing.allocator;
    var db = try Database.open(allocator, ":memory:");
    try schema.createSchema(&db);
    return .{ .db = db, .allocator = allocator };
}

fn insertTestIssue(db: *Database, id: []const u8, title: []const u8, now: i64) !void {
    var stmt = try db.prepare(
        \\INSERT INTO issues (id, title, status, priority, issue_type, created_at, updated_at, pinned, is_template, ephemeral)
        \\VALUES (?1, ?2, 'open', 2, 'task', ?3, ?3, 0, 0, 0)
    );
    defer stmt.deinit();
    try stmt.bindText(1, id);
    try stmt.bindText(2, title);
    try stmt.bindInt(3, now);
    _ = try stmt.step();
}

fn insertTestIssueWithStatus(db: *Database, id: []const u8, title: []const u8, status: []const u8, now: i64) !void {
    var stmt = try db.prepare(
        \\INSERT INTO issues (id, title, status, priority, issue_type, created_at, updated_at, pinned, is_template, ephemeral)
        \\VALUES (?1, ?2, ?3, 2, 'task', ?4, ?4, 0, 0, 0)
    );
    defer stmt.deinit();
    try stmt.bindText(1, id);
    try stmt.bindText(2, title);
    try stmt.bindText(3, status);
    try stmt.bindInt(4, now);
    _ = try stmt.step();
}

test "DependencyStore.add creates dependency" {
    var ctx = try setupTestDb();
    defer ctx.db.close();

    try insertTestIssue(&ctx.db, "bd-parent", "Parent", 1706540000);
    try insertTestIssue(&ctx.db, "bd-child", "Child", 1706540000);

    var store = DependencyStore.init(&ctx.db, ctx.allocator);
    try store.add("bd-child", "bd-parent", .blocks, null, 1706540000);

    const deps = try store.getDependencies("bd-child");
    defer store.freeDependencies(deps);

    try std.testing.expectEqual(@as(usize, 1), deps.len);
    try std.testing.expectEqualStrings("bd-parent", deps[0].depends_on_id);
    try std.testing.expectEqualStrings("blocks", deps[0].dep_type.toString());
}

test "DependencyStore.add rejects self-dependency" {
    var ctx = try setupTestDb();
    defer ctx.db.close();

    try insertTestIssue(&ctx.db, "bd-self", "Self", 1706540000);

    var store = DependencyStore.init(&ctx.db, ctx.allocator);
    try std.testing.expectError(
        DependencyStoreError.SelfDependency,
        store.add("bd-self", "bd-self", .blocks, null, 1706540000),
    );
}

test "DependencyStore.add rejects direct cycle" {
    var ctx = try setupTestDb();
    defer ctx.db.close();

    try insertTestIssue(&ctx.db, "bd-a", "A", 1706540000);
    try insertTestIssue(&ctx.db, "bd-b", "B", 1706540000);

    var store = DependencyStore.init(&ctx.db, ctx.allocator);
    try store.add("bd-a", "bd-b", .blocks, null, 1706540000);

    try std.testing.expectError(
        DependencyStoreError.CycleDetected,
        store.add("bd-b", "bd-a", .blocks, null, 1706540000),
    );
}

test "DependencyStore.add rejects indirect cycle (A->B->C->A)" {
    var ctx = try setupTestDb();
    defer ctx.db.close();

    try insertTestIssue(&ctx.db, "bd-a", "A", 1706540000);
    try insertTestIssue(&ctx.db, "bd-b", "B", 1706540000);
    try insertTestIssue(&ctx.db, "bd-c", "C", 1706540000);

    var store = DependencyStore.init(&ctx.db, ctx.allocator);
    try store.add("bd-a", "bd-b", .blocks, null, 1706540000);
    try store.add("bd-b", "bd-c", .blocks, null, 1706540000);

    try std.testing.expectError(
        DependencyStoreError.CycleDetected,
        store.add("bd-c", "bd-a", .blocks, null, 1706540000),
    );
}

test "DependencyStore.remove removes dependency" {
    var ctx = try setupTestDb();
    defer ctx.db.close();

    try insertTestIssue(&ctx.db, "bd-parent", "Parent", 1706540000);
    try insertTestIssue(&ctx.db, "bd-child", "Child", 1706540000);

    var store = DependencyStore.init(&ctx.db, ctx.allocator);
    try store.add("bd-child", "bd-parent", .blocks, null, 1706540000);
    try store.remove("bd-child", "bd-parent");

    const deps = try store.getDependencies("bd-child");
    defer store.freeDependencies(deps);
    try std.testing.expectEqual(@as(usize, 0), deps.len);
}

test "DependencyStore.getDependencies returns multiple deps" {
    var ctx = try setupTestDb();
    defer ctx.db.close();

    try insertTestIssue(&ctx.db, "bd-a", "A", 1706540000);
    try insertTestIssue(&ctx.db, "bd-b", "B", 1706540000);
    try insertTestIssue(&ctx.db, "bd-c", "C", 1706540000);

    var store = DependencyStore.init(&ctx.db, ctx.allocator);
    try store.add("bd-a", "bd-b", .blocks, null, 1706540000);
    try store.add("bd-a", "bd-c", .waits_for, null, 1706540000);

    const deps = try store.getDependencies("bd-a");
    defer store.freeDependencies(deps);
    try std.testing.expectEqual(@as(usize, 2), deps.len);
}

test "DependencyStore.getDependents returns dependents" {
    var ctx = try setupTestDb();
    defer ctx.db.close();

    try insertTestIssue(&ctx.db, "bd-parent", "Parent", 1706540000);
    try insertTestIssue(&ctx.db, "bd-child1", "Child 1", 1706540000);
    try insertTestIssue(&ctx.db, "bd-child2", "Child 2", 1706540000);

    var store = DependencyStore.init(&ctx.db, ctx.allocator);
    try store.add("bd-child1", "bd-parent", .blocks, null, 1706540000);
    try store.add("bd-child2", "bd-parent", .blocks, null, 1706540000);

    const dependents = try store.getDependents("bd-parent");
    defer store.freeDependencies(dependents);
    try std.testing.expectEqual(@as(usize, 2), dependents.len);
}

test "DependencyStore.getBlockingDeps returns only blocking types" {
    var ctx = try setupTestDb();
    defer ctx.db.close();

    try insertTestIssue(&ctx.db, "bd-a", "A", 1706540000);
    try insertTestIssue(&ctx.db, "bd-b", "B", 1706540000);
    try insertTestIssue(&ctx.db, "bd-c", "C", 1706540000);

    var store = DependencyStore.init(&ctx.db, ctx.allocator);
    try store.add("bd-a", "bd-b", .blocks, null, 1706540000);
    try store.add("bd-a", "bd-c", .related, null, 1706540000);

    const blocking = try store.getBlockingDeps("bd-a");
    defer store.freeDependencies(blocking);
    try std.testing.expectEqual(@as(usize, 1), blocking.len);
    try std.testing.expectEqualStrings("bd-b", blocking[0].depends_on_id);
}

test "DependencyStore.getReadyIssueIds excludes blocked issues" {
    var ctx = try setupTestDb();
    defer ctx.db.close();

    try insertTestIssue(&ctx.db, "bd-blocker", "Blocker", 1706540000);
    try insertTestIssue(&ctx.db, "bd-blocked", "Blocked", 1706540000);
    try insertTestIssue(&ctx.db, "bd-ready", "Ready", 1706540000);

    var store = DependencyStore.init(&ctx.db, ctx.allocator);
    try store.add("bd-blocked", "bd-blocker", .blocks, null, 1706540000);

    const ready = try store.getReadyIssueIds();
    defer store.freeIds(ready);

    try std.testing.expectEqual(@as(usize, 2), ready.len);
    for (ready) |id| {
        try std.testing.expect(!std.mem.eql(u8, id, "bd-blocked"));
    }
}

test "DependencyStore.getReadyIssueIds includes issue when blocker is closed" {
    var ctx = try setupTestDb();
    defer ctx.db.close();

    try insertTestIssueWithStatus(&ctx.db, "bd-blocker", "Blocker", "closed", 1706540000);
    try insertTestIssue(&ctx.db, "bd-child", "Child", 1706540000);

    var store = DependencyStore.init(&ctx.db, ctx.allocator);
    try store.add("bd-child", "bd-blocker", .blocks, null, 1706540000);

    const ready = try store.getReadyIssueIds();
    defer store.freeIds(ready);

    try std.testing.expectEqual(@as(usize, 1), ready.len);
    try std.testing.expectEqualStrings("bd-child", ready[0]);
}

test "DependencyStore.getBlockedIssueIds returns blocked issues" {
    var ctx = try setupTestDb();
    defer ctx.db.close();

    try insertTestIssue(&ctx.db, "bd-blocker", "Blocker", 1706540000);
    try insertTestIssue(&ctx.db, "bd-blocked", "Blocked", 1706540000);
    try insertTestIssue(&ctx.db, "bd-ready", "Ready", 1706540000);

    var store = DependencyStore.init(&ctx.db, ctx.allocator);
    try store.add("bd-blocked", "bd-blocker", .blocks, null, 1706540000);

    const blocked = try store.getBlockedIssueIds();
    defer store.freeBlockedInfos(blocked);

    try std.testing.expectEqual(@as(usize, 1), blocked.len);
    try std.testing.expectEqualStrings("bd-blocked", blocked[0].issue_id);
    try std.testing.expect(std.mem.indexOf(u8, blocked[0].blocked_by, "bd-blocker") != null);
}

test "DependencyStore.getReadyIssueIds non-blocking deps do not block" {
    var ctx = try setupTestDb();
    defer ctx.db.close();

    try insertTestIssue(&ctx.db, "bd-a", "A", 1706540000);
    try insertTestIssue(&ctx.db, "bd-b", "B", 1706540000);

    var store = DependencyStore.init(&ctx.db, ctx.allocator);
    try store.add("bd-a", "bd-b", .related, null, 1706540000);

    const ready = try store.getReadyIssueIds();
    defer store.freeIds(ready);

    try std.testing.expectEqual(@as(usize, 2), ready.len);
}

test "DependencyStore.rebuildBlockedCache populates cache" {
    var ctx = try setupTestDb();
    defer ctx.db.close();

    try insertTestIssue(&ctx.db, "bd-blocker1", "Blocker 1", 1706540000);
    try insertTestIssue(&ctx.db, "bd-blocker2", "Blocker 2", 1706540000);
    try insertTestIssue(&ctx.db, "bd-blocked", "Blocked", 1706540000);

    var store = DependencyStore.init(&ctx.db, ctx.allocator);
    try store.add("bd-blocked", "bd-blocker1", .blocks, null, 1706540000);
    try store.add("bd-blocked", "bd-blocker2", .blocks, null, 1706540000);

    try store.rebuildBlockedCache();

    const cached = try store.getCachedBlockers("bd-blocked");
    defer if (cached) |c| ctx.allocator.free(c);

    try std.testing.expect(cached != null);
    try std.testing.expect(std.mem.indexOf(u8, cached.?, "bd-blocker1") != null);
    try std.testing.expect(std.mem.indexOf(u8, cached.?, "bd-blocker2") != null);
}

test "DependencyStore.invalidateBlockedCache on remove" {
    var ctx = try setupTestDb();
    defer ctx.db.close();

    try insertTestIssue(&ctx.db, "bd-blocker", "Blocker", 1706540000);
    try insertTestIssue(&ctx.db, "bd-blocked", "Blocked", 1706540000);

    var store = DependencyStore.init(&ctx.db, ctx.allocator);
    try store.add("bd-blocked", "bd-blocker", .blocks, null, 1706540000);
    try store.rebuildBlockedCache();

    const cached1 = try store.getCachedBlockers("bd-blocked");
    try std.testing.expect(cached1 != null);
    ctx.allocator.free(cached1.?);

    try store.remove("bd-blocked", "bd-blocker");

    const cached2 = try store.getCachedBlockers("bd-blocked");
    try std.testing.expect(cached2 == null);
}

test "DependencyStore dirty tracking on add" {
    var ctx = try setupTestDb();
    defer ctx.db.close();

    try insertTestIssue(&ctx.db, "bd-parent", "Parent", 1706540000);
    try insertTestIssue(&ctx.db, "bd-child", "Child", 1706540000);

    var store = DependencyStore.init(&ctx.db, ctx.allocator);
    try store.add("bd-child", "bd-parent", .blocks, "alice", 1706540000);

    var stmt = try ctx.db.prepare("SELECT issue_id FROM dirty_issues WHERE issue_id = 'bd-child'");
    defer stmt.deinit();
    const found = try stmt.step();
    try std.testing.expect(found);
}

test "DependencyStore.add with actor" {
    var ctx = try setupTestDb();
    defer ctx.db.close();

    try insertTestIssue(&ctx.db, "bd-a", "A", 1706540000);
    try insertTestIssue(&ctx.db, "bd-b", "B", 1706540000);

    var store = DependencyStore.init(&ctx.db, ctx.allocator);
    try store.add("bd-a", "bd-b", .blocks, "alice@example.com", 1706540000);

    const deps = try store.getDependencies("bd-a");
    defer store.freeDependencies(deps);

    try std.testing.expectEqual(@as(usize, 1), deps.len);
    try std.testing.expectEqualStrings("alice@example.com", deps[0].created_by.?);
}

test "DependencyStore.checkCycle detects potential cycle" {
    var ctx = try setupTestDb();
    defer ctx.db.close();

    try insertTestIssue(&ctx.db, "bd-a", "A", 1706540000);
    try insertTestIssue(&ctx.db, "bd-b", "B", 1706540000);

    var store = DependencyStore.init(&ctx.db, ctx.allocator);
    try store.add("bd-a", "bd-b", .blocks, null, 1706540000);

    const would_cycle = try store.checkCycle("bd-b", "bd-a");
    try std.testing.expect(would_cycle);

    const no_cycle = try store.checkCycle("bd-a", "bd-b");
    try std.testing.expect(!no_cycle);
}

test "DependencyStore.detectAllCycles returns empty for acyclic graph" {
    var ctx = try setupTestDb();
    defer ctx.db.close();

    try insertTestIssue(&ctx.db, "bd-a", "A", 1706540000);
    try insertTestIssue(&ctx.db, "bd-b", "B", 1706540000);
    try insertTestIssue(&ctx.db, "bd-c", "C", 1706540000);

    var store = DependencyStore.init(&ctx.db, ctx.allocator);
    try store.add("bd-a", "bd-b", .blocks, null, 1706540000);
    try store.add("bd-b", "bd-c", .blocks, null, 1706540000);

    const cycles = try store.detectAllCycles();
    try std.testing.expectEqual(@as(usize, 0), cycles.len);
}

test "DependencyStore.getBlockingDeps filters closed blockers" {
    var ctx = try setupTestDb();
    defer ctx.db.close();

    try insertTestIssue(&ctx.db, "bd-a", "A", 1706540000);
    try insertTestIssue(&ctx.db, "bd-open", "Open Blocker", 1706540000);
    try insertTestIssueWithStatus(&ctx.db, "bd-closed", "Closed Blocker", "closed", 1706540000);

    var store = DependencyStore.init(&ctx.db, ctx.allocator);
    try store.add("bd-a", "bd-open", .blocks, null, 1706540000);
    try store.add("bd-a", "bd-closed", .blocks, null, 1706540000);

    const blocking = try store.getBlockingDeps("bd-a");
    defer store.freeDependencies(blocking);

    try std.testing.expectEqual(@as(usize, 1), blocking.len);
    try std.testing.expectEqualStrings("bd-open", blocking[0].depends_on_id);
}
