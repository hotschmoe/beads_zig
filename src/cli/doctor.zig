//! Doctor command for beads_zig.
//!
//! `bz doctor` - Run diagnostic checks on the workspace

const std = @import("std");
const storage = @import("../storage/mod.zig");
const common = @import("common.zig");
const args = @import("args.zig");
const test_util = @import("../test_util.zig");

const IssueStore = common.IssueStore;
const DependencyGraph = storage.DependencyGraph;
const CommandContext = common.CommandContext;

pub const DoctorError = error{
    WorkspaceNotInitialized,
    StorageError,
    OutOfMemory,
};

pub const DoctorResult = struct {
    success: bool,
    checks: ?[]const Check = null,
    passed: ?usize = null,
    failed: ?usize = null,
    warnings: ?usize = null,
    message: ?[]const u8 = null,

    pub const Check = struct {
        name: []const u8,
        status: []const u8, // "pass", "fail", "warn"
        message: ?[]const u8,
    };
};

pub fn run(
    global: args.GlobalOptions,
    allocator: std.mem.Allocator,
) !void {
    var ctx = (try CommandContext.init(allocator, global)) orelse {
        return DoctorError.WorkspaceNotInitialized;
    };
    defer ctx.deinit();

    var checks: std.ArrayListUnmanaged(DoctorResult.Check) = .{};
    defer checks.deinit(allocator);

    // Check 1: JSONL file exists and is readable
    try checks.append(allocator, checkJsonlFile(ctx.issues_path));

    // Check 2: No duplicate IDs
    try checks.append(allocator, checkDuplicateIds(&ctx.store));

    // Check 3: No orphan dependencies (dependencies referencing non-existent issues)
    try checks.append(allocator, try checkOrphanDependencies(&ctx.store, allocator));

    // Check 4: No dependency cycles
    var graph = ctx.createGraph();
    try checks.append(allocator, try checkNoCycles(&graph));

    // Check 5: All issues have valid titles
    try checks.append(allocator, checkValidTitles(&ctx.store));

    // Check 6: WAL file status
    const beads_dir = global.data_path orelse ".beads";
    const wal_path = try std.fs.path.join(allocator, &.{ beads_dir, "beads.wal" });
    defer allocator.free(wal_path);
    try checks.append(allocator, checkWalFile(wal_path));

    // Count results
    var passed: usize = 0;
    var failed: usize = 0;
    var warnings: usize = 0;

    for (checks.items) |check| {
        if (std.mem.eql(u8, check.status, "pass")) {
            passed += 1;
        } else if (std.mem.eql(u8, check.status, "fail")) {
            failed += 1;
        } else if (std.mem.eql(u8, check.status, "warn")) {
            warnings += 1;
        }
    }

    if (global.isStructuredOutput()) {
        try ctx.output.printJson(DoctorResult{
            .success = failed == 0,
            .checks = checks.items,
            .passed = passed,
            .failed = failed,
            .warnings = warnings,
        });
    } else if (!global.quiet) {
        try ctx.output.println("Workspace Health Check", .{});
        try ctx.output.print("\n", .{});

        for (checks.items) |check| {
            const icon = if (std.mem.eql(u8, check.status, "pass"))
                "[OK]  "
            else if (std.mem.eql(u8, check.status, "fail"))
                "[FAIL]"
            else
                "[WARN]";

            try ctx.output.print("{s} {s}\n", .{ icon, check.name });
            if (check.message) |msg| {
                try ctx.output.print("      {s}\n", .{msg});
            }
        }

        try ctx.output.print("\n{d} passed, {d} warnings, {d} failed\n", .{ passed, warnings, failed });
    }
}

fn checkJsonlFile(path: []const u8) DoctorResult.Check {
    std.fs.cwd().access(path, .{}) catch {
        return .{
            .name = "JSONL file exists",
            .status = "fail",
            .message = "issues.jsonl not found",
        };
    };
    return .{
        .name = "JSONL file exists",
        .status = "pass",
        .message = null,
    };
}

fn checkDuplicateIds(store: *IssueStore) DoctorResult.Check {
    // IssueStore already enforces unique IDs via hash map
    // Check if count matches list length
    if (store.id_index.count() == store.issues.items.len) {
        return .{
            .name = "No duplicate IDs",
            .status = "pass",
            .message = null,
        };
    }
    return .{
        .name = "No duplicate IDs",
        .status = "fail",
        .message = "Duplicate issue IDs detected",
    };
}

fn checkOrphanDependencies(store: *IssueStore, allocator: std.mem.Allocator) !DoctorResult.Check {
    var orphan_count: usize = 0;

    for (store.issues.items) |issue| {
        if (issue.status.eql(.tombstone)) continue;

        for (issue.dependencies) |dep| {
            if (!store.id_index.contains(dep.depends_on_id)) {
                orphan_count += 1;
            }
        }
    }

    _ = allocator;

    if (orphan_count == 0) {
        return .{
            .name = "No orphan dependencies",
            .status = "pass",
            .message = null,
        };
    }
    return .{
        .name = "No orphan dependencies",
        .status = "warn",
        .message = "Some dependencies reference non-existent issues",
    };
}

fn checkNoCycles(graph: *DependencyGraph) !DoctorResult.Check {
    const cycles = try graph.detectCycles();
    defer if (cycles) |c| graph.allocator.free(c);

    if (cycles == null or cycles.?.len == 0) {
        return .{
            .name = "No dependency cycles",
            .status = "pass",
            .message = null,
        };
    }
    return .{
        .name = "No dependency cycles",
        .status = "fail",
        .message = "Circular dependencies detected",
    };
}

fn checkValidTitles(store: *IssueStore) DoctorResult.Check {
    for (store.issues.items) |issue| {
        if (issue.status.eql(.tombstone)) continue;

        if (issue.title.len == 0) {
            return .{
                .name = "All issues have valid titles",
                .status = "fail",
                .message = "Found issue with empty title",
            };
        }
        if (issue.title.len > 500) {
            return .{
                .name = "All issues have valid titles",
                .status = "warn",
                .message = "Found issue with title > 500 characters",
            };
        }
    }
    return .{
        .name = "All issues have valid titles",
        .status = "pass",
        .message = null,
    };
}

fn checkWalFile(path: []const u8) DoctorResult.Check {
    const file = std.fs.cwd().openFile(path, .{}) catch {
        return .{
            .name = "WAL file status",
            .status = "pass",
            .message = "No pending WAL entries",
        };
    };
    defer file.close();

    const stat = file.stat() catch {
        return .{
            .name = "WAL file status",
            .status = "warn",
            .message = "Could not read WAL file",
        };
    };

    if (stat.size == 0) {
        return .{
            .name = "WAL file status",
            .status = "pass",
            .message = "WAL is empty",
        };
    }

    if (stat.size > 100 * 1024) {
        return .{
            .name = "WAL file status",
            .status = "warn",
            .message = "WAL file is large, consider compacting",
        };
    }

    return .{
        .name = "WAL file status",
        .status = "pass",
        .message = "WAL has pending entries",
    };
}

// --- Tests ---

test "DoctorError enum exists" {
    const err: DoctorError = DoctorError.WorkspaceNotInitialized;
    try std.testing.expect(err == DoctorError.WorkspaceNotInitialized);
}

test "DoctorResult struct works" {
    const result = DoctorResult{
        .success = true,
        .passed = 5,
        .failed = 0,
    };
    try std.testing.expect(result.success);
    try std.testing.expectEqual(@as(usize, 5), result.passed.?);
}

test "run detects uninitialized workspace" {
    const allocator = std.testing.allocator;

    const global = args.GlobalOptions{ .silent = true, .data_path = "/nonexistent/path" };

    const result = run(global, allocator);
    try std.testing.expectError(DoctorError.WorkspaceNotInitialized, result);
}

test "checkJsonlFile returns pass for existing file" {
    const allocator = std.testing.allocator;
    const test_dir = try test_util.createTestDir(allocator, "doctor_jsonl");
    defer allocator.free(test_dir);
    defer test_util.cleanupTestDir(test_dir);

    const path = try std.fs.path.join(allocator, &.{ test_dir, "test.jsonl" });
    defer allocator.free(path);

    const file = try std.fs.cwd().createFile(path, .{});
    file.close();

    const check = checkJsonlFile(path);
    try std.testing.expectEqualStrings("pass", check.status);
}

test "checkJsonlFile returns fail for missing file" {
    const check = checkJsonlFile("/nonexistent/path/issues.jsonl");
    try std.testing.expectEqualStrings("fail", check.status);
}
