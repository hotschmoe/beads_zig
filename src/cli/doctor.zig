//! Doctor command for beads_zig.
//!
//! `bz doctor` - Run diagnostic checks on the workspace

const std = @import("std");
const storage = @import("../storage/mod.zig");
const common = @import("common.zig");
const args = @import("args.zig");

const IssueStore = common.IssueStore;
const DependencyStore = common.DependencyStore;
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

    // Check 1: Database file exists and is readable
    try checks.append(allocator, checkDatabaseFile(ctx.db_path));

    // Check 2: No duplicate IDs
    try checks.append(allocator, try checkDuplicateIds(&ctx.issue_store, allocator));

    // Check 3: No orphan dependencies (dependencies referencing non-existent issues)
    try checks.append(allocator, try checkOrphanDependencies(&ctx, allocator));

    // Check 4: No dependency cycles
    try checks.append(allocator, try checkNoCycles(&ctx.dep_store, allocator));

    // Check 5: All issues have valid titles
    try checks.append(allocator, try checkValidTitles(&ctx.issue_store, allocator));

    // Check 6: Database schema version
    try checks.append(allocator, try checkSchemaVersion(&ctx.db, allocator));

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

fn checkDatabaseFile(path: []const u8) DoctorResult.Check {
    std.fs.cwd().access(path, .{}) catch {
        return .{
            .name = "Database file exists",
            .status = "fail",
            .message = "beads.db not found",
        };
    };
    return .{
        .name = "Database file exists",
        .status = "pass",
        .message = null,
    };
}

fn checkDuplicateIds(issue_store: *IssueStore, allocator: std.mem.Allocator) !DoctorResult.Check {
    const issues = try issue_store.list(.{});
    defer {
        for (issues) |*issue| {
            issue.deinit(allocator);
        }
        allocator.free(issues);
    }

    var seen = std.StringHashMap(void).init(allocator);
    defer seen.deinit();

    var has_duplicates = false;
    for (issues) |*issue| {
        if (seen.contains(issue.id)) {
            has_duplicates = true;
            break;
        }
        try seen.put(issue.id, {});
    }

    if (!has_duplicates) {
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

fn checkOrphanDependencies(ctx: *CommandContext, allocator: std.mem.Allocator) !DoctorResult.Check {
    const issues = try ctx.issue_store.list(.{});
    defer {
        for (issues) |*issue| {
            issue.deinit(allocator);
        }
        allocator.free(issues);
    }

    var orphan_count: usize = 0;

    for (issues) |*issue| {
        const deps = try ctx.dep_store.getDependencies(issue.id);
        defer ctx.dep_store.freeDependencies(deps);

        for (deps) |dep| {
            if (!try ctx.issue_store.exists(dep.depends_on_id)) {
                orphan_count += 1;
            }
        }
    }

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

fn checkNoCycles(dep_store: *DependencyStore, _: std.mem.Allocator) !DoctorResult.Check {
    const cycles = try dep_store.detectAllCycles();
    defer dep_store.freeCycles(cycles);

    if (cycles.len == 0) {
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

fn checkValidTitles(issue_store: *IssueStore, allocator: std.mem.Allocator) !DoctorResult.Check {
    const issues = try issue_store.list(.{});
    defer {
        for (issues) |*issue| {
            issue.deinit(allocator);
        }
        allocator.free(issues);
    }

    for (issues) |*issue| {
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

fn checkSchemaVersion(db: *storage.SqlDatabase, allocator: std.mem.Allocator) !DoctorResult.Check {
    _ = allocator;

    const current_version = try storage.getSchemaVersion(db);

    if (current_version) |version| {
        if (version > storage.SQL_SCHEMA_VERSION) {
            return .{
                .name = "Schema version",
                .status = "fail",
                .message = "Database schema is newer than this bz version. Please upgrade bz.",
            };
        }

        if (version < storage.SQL_SCHEMA_VERSION) {
            return .{
                .name = "Schema version",
                .status = "warn",
                .message = "Database schema is older. Migrations available.",
            };
        }

        return .{
            .name = "Schema version",
            .status = "pass",
            .message = null,
        };
    } else {
        return .{
            .name = "Schema version",
            .status = "warn",
            .message = "No schema version found in database.",
        };
    }
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

test "checkDatabaseFile returns pass for existing file" {
    const allocator = std.testing.allocator;

    var temp_dir = std.testing.tmpDir(.{});
    defer temp_dir.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const temp_path = try temp_dir.dir.realpath(".", &path_buf);

    const db_path = try std.fs.path.join(allocator, &.{ temp_path, "test.db" });
    defer allocator.free(db_path);

    const file = try std.fs.cwd().createFile(db_path, .{});
    file.close();

    const check = checkDatabaseFile(db_path);
    try std.testing.expectEqualStrings("pass", check.status);
}

test "checkDatabaseFile returns fail for missing file" {
    const check = checkDatabaseFile("/nonexistent/path/beads.db");
    try std.testing.expectEqualStrings("fail", check.status);
}
