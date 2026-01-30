//! Dependency storage operations for beads_zig.
//!
//! Provides operations for managing issue dependencies including:
//! - Add/remove dependencies
//! - Cycle detection (prevents circular dependencies)
//! - Query dependencies and dependents
//! - Ready/blocked issue queries
//!
//! This module wraps the DependencyGraph for backwards compatibility.

const std = @import("std");
const graph_mod = @import("graph.zig");
const store_mod = @import("store.zig");
const IssueStore = store_mod.IssueStore;
const Issue = @import("../models/issue.zig").Issue;
const Dependency = @import("../models/dependency.zig").Dependency;
const DependencyType = @import("../models/dependency.zig").DependencyType;

pub const DependencyStoreError = graph_mod.DependencyGraphError;

/// Re-export DependencyGraph as DependencyStore for backwards compatibility.
pub const DependencyStore = graph_mod.DependencyGraph;

// --- Tests ---

test "DependencyStore.add creates dependency" {
    const allocator = std.testing.allocator;
    var store = IssueStore.init(allocator, "/tmp/test_dep_add.jsonl");
    defer store.deinit();

    try store.insert(Issue.init("bd-parent", "Parent", 1706540000));
    try store.insert(Issue.init("bd-child", "Child", 1706540000));

    var dep_store = DependencyStore.init(&store, allocator);

    const dep = Dependency{
        .issue_id = "bd-child",
        .depends_on_id = "bd-parent",
        .dep_type = .blocks,
        .created_at = 1706540000,
        .created_by = null,
        .metadata = null,
        .thread_id = null,
    };

    try dep_store.addDependency(dep);

    const deps = try dep_store.getDependencies("bd-child");
    defer dep_store.freeDependencies(deps);

    try std.testing.expectEqual(@as(usize, 1), deps.len);
    try std.testing.expectEqualStrings("bd-parent", deps[0].depends_on_id);
}

test "DependencyStore.add rejects self-dependency" {
    const allocator = std.testing.allocator;
    var store = IssueStore.init(allocator, "/tmp/test_dep_self.jsonl");
    defer store.deinit();

    try store.insert(Issue.init("bd-self", "Self", 1706540000));

    var dep_store = DependencyStore.init(&store, allocator);

    const dep = Dependency{
        .issue_id = "bd-self",
        .depends_on_id = "bd-self",
        .dep_type = .blocks,
        .created_at = 1706540000,
        .created_by = null,
        .metadata = null,
        .thread_id = null,
    };

    try std.testing.expectError(DependencyStoreError.SelfDependency, dep_store.addDependency(dep));
}

test "DependencyStore.add rejects direct cycle" {
    const allocator = std.testing.allocator;
    var store = IssueStore.init(allocator, "/tmp/test_dep_direct_cycle.jsonl");
    defer store.deinit();

    try store.insert(Issue.init("bd-a", "A", 1706540000));
    try store.insert(Issue.init("bd-b", "B", 1706540000));

    var dep_store = DependencyStore.init(&store, allocator);

    // A depends on B
    try dep_store.addDependency(.{
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

    try std.testing.expectError(DependencyStoreError.CycleDetected, dep_store.addDependency(cycle_dep));
}

test "DependencyStore.add rejects indirect cycle (A->B->C->A)" {
    const allocator = std.testing.allocator;
    var store = IssueStore.init(allocator, "/tmp/test_dep_indirect_cycle.jsonl");
    defer store.deinit();

    try store.insert(Issue.init("bd-a", "A", 1706540000));
    try store.insert(Issue.init("bd-b", "B", 1706540000));
    try store.insert(Issue.init("bd-c", "C", 1706540000));

    var dep_store = DependencyStore.init(&store, allocator);

    // A depends on B
    try dep_store.addDependency(.{
        .issue_id = "bd-a",
        .depends_on_id = "bd-b",
        .dep_type = .blocks,
        .created_at = 1706540000,
        .created_by = null,
        .metadata = null,
        .thread_id = null,
    });

    // B depends on C
    try dep_store.addDependency(.{
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

    try std.testing.expectError(DependencyStoreError.CycleDetected, dep_store.addDependency(cycle_dep));
}

test "DependencyStore.remove removes dependency" {
    const allocator = std.testing.allocator;
    var store = IssueStore.init(allocator, "/tmp/test_dep_remove.jsonl");
    defer store.deinit();

    try store.insert(Issue.init("bd-parent", "Parent", 1706540000));
    try store.insert(Issue.init("bd-child", "Child", 1706540000));

    var dep_store = DependencyStore.init(&store, allocator);

    try dep_store.addDependency(.{
        .issue_id = "bd-child",
        .depends_on_id = "bd-parent",
        .dep_type = .blocks,
        .created_at = 1706540000,
        .created_by = null,
        .metadata = null,
        .thread_id = null,
    });

    try dep_store.removeDependency("bd-child", "bd-parent");

    const deps = try dep_store.getDependencies("bd-child");
    defer dep_store.freeDependencies(deps);

    try std.testing.expectEqual(@as(usize, 0), deps.len);
}

test "DependencyStore.getDependencies returns dependencies" {
    const allocator = std.testing.allocator;
    var store = IssueStore.init(allocator, "/tmp/test_dep_get.jsonl");
    defer store.deinit();

    try store.insert(Issue.init("bd-a", "A", 1706540000));
    try store.insert(Issue.init("bd-b", "B", 1706540000));
    try store.insert(Issue.init("bd-c", "C", 1706540000));

    var dep_store = DependencyStore.init(&store, allocator);

    // A depends on B and C
    try dep_store.addDependency(.{
        .issue_id = "bd-a",
        .depends_on_id = "bd-b",
        .dep_type = .blocks,
        .created_at = 1706540000,
        .created_by = null,
        .metadata = null,
        .thread_id = null,
    });
    try dep_store.addDependency(.{
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
    var store = IssueStore.init(allocator, "/tmp/test_dep_dependents.jsonl");
    defer store.deinit();

    try store.insert(Issue.init("bd-parent", "Parent", 1706540000));
    try store.insert(Issue.init("bd-child1", "Child 1", 1706540000));
    try store.insert(Issue.init("bd-child2", "Child 2", 1706540000));

    var dep_store = DependencyStore.init(&store, allocator);

    // Both children depend on parent
    try dep_store.addDependency(.{
        .issue_id = "bd-child1",
        .depends_on_id = "bd-parent",
        .dep_type = .blocks,
        .created_at = 1706540000,
        .created_by = null,
        .metadata = null,
        .thread_id = null,
    });
    try dep_store.addDependency(.{
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
    var store = IssueStore.init(allocator, "/tmp/test_dep_ready.jsonl");
    defer store.deinit();

    try store.insert(Issue.init("bd-blocker", "Blocker", 1706540000));
    try store.insert(Issue.init("bd-blocked", "Blocked", 1706540000));
    try store.insert(Issue.init("bd-ready", "Ready", 1706540000));

    var dep_store = DependencyStore.init(&store, allocator);

    // blocked depends on blocker
    try dep_store.addDependency(.{
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
    var store = IssueStore.init(allocator, "/tmp/test_dep_ready_closed.jsonl");
    defer store.deinit();

    var blocker = Issue.init("bd-blocker", "Blocker", 1706540000);
    blocker.status = .closed;
    try store.insert(blocker);

    try store.insert(Issue.init("bd-child", "Child", 1706540000));

    var dep_store = DependencyStore.init(&store, allocator);

    // child depends on blocker (which is closed)
    try dep_store.addDependency(.{
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
    var store = IssueStore.init(allocator, "/tmp/test_dep_blocked.jsonl");
    defer store.deinit();

    try store.insert(Issue.init("bd-blocker", "Blocker", 1706540000));
    try store.insert(Issue.init("bd-blocked", "Blocked", 1706540000));
    try store.insert(Issue.init("bd-ready", "Ready", 1706540000));

    var dep_store = DependencyStore.init(&store, allocator);

    // blocked depends on blocker
    try dep_store.addDependency(.{
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

test "DependencyStore dirty tracking on add" {
    const allocator = std.testing.allocator;
    var store = IssueStore.init(allocator, "/tmp/test_dep_dirty.jsonl");
    defer store.deinit();

    try store.insert(Issue.init("bd-parent", "Parent", 1706540000));
    try store.insert(Issue.init("bd-child", "Child", 1706540000));

    // Clear dirty flags from insert
    try store.clearDirty("bd-parent");
    try store.clearDirty("bd-child");

    var dep_store = DependencyStore.init(&store, allocator);

    try dep_store.addDependency(.{
        .issue_id = "bd-child",
        .depends_on_id = "bd-parent",
        .dep_type = .blocks,
        .created_at = 1706540000,
        .created_by = null,
        .metadata = null,
        .thread_id = null,
    });

    // Child should be marked dirty
    const dirty_ids = try store.getDirtyIds();
    defer {
        for (dirty_ids) |id| allocator.free(id);
        allocator.free(dirty_ids);
    }

    try std.testing.expectEqual(@as(usize, 1), dirty_ids.len);
    try std.testing.expectEqualStrings("bd-child", dirty_ids[0]);
}
