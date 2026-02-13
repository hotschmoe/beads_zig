//! Doctor command for beads_zig.
//!
//! `bz doctor` - Run diagnostic checks on the workspace

const std = @import("std");
const storage = @import("../storage/mod.zig");
const common = @import("common.zig");
const args = @import("args.zig");
const JsonlFile = storage.JsonlFile;

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

    // 1. Database file exists and is readable
    try checks.append(allocator, checkDatabaseFile(ctx.db_path));

    // 2. SQLite integrity check
    try checks.append(allocator, try checkIntegrity(ctx.db));

    // 3. Expected tables present
    try checks.append(allocator, try checkSchemaTables(ctx.db));

    // 4. Critical columns present
    try checks.append(allocator, try checkSchemaColumns(ctx.db));

    // 5. Database schema version
    try checks.append(allocator, try checkSchemaVersion(ctx.db));

    // 6. JSONL merge artifacts
    try checks.append(allocator, checkMergeArtifacts(ctx.beads_dir));

    // 7. JSONL conflict markers
    try checks.append(allocator, try checkConflictMarkers(ctx.beads_dir, allocator));

    // 8. JSONL parse
    try checks.append(allocator, try checkJsonlParse(ctx.beads_dir, allocator));

    // 9. DB vs JSONL counts
    try checks.append(allocator, try checkDbVsJsonl(&ctx.issue_store, ctx.beads_dir, allocator));

    // 10. No duplicate IDs
    try checks.append(allocator, try checkDuplicateIds(&ctx.issue_store, allocator));

    // 11. No orphan dependencies
    try checks.append(allocator, try checkOrphanDependencies(&ctx, allocator));

    // 12. No dependency cycles
    try checks.append(allocator, try checkNoCycles(&ctx.dep_store, allocator));

    // 13. All issues have valid titles
    try checks.append(allocator, try checkValidTitles(&ctx.issue_store, allocator));

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
                "OK "
            else if (std.mem.eql(u8, check.status, "fail"))
                "FAIL "
            else
                "WARN ";

            try ctx.output.print("{s} {s}\n", .{ icon, check.name });
            if (check.message) |msg| {
                try ctx.output.print("      {s}\n", .{msg});
            }
        }

        try ctx.output.print("\n{d} passed, {d} warnings, {d} failed\n", .{ passed, warnings, failed });
    }
}

// -- Existing checks --

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

fn checkSchemaVersion(db: *storage.SqlDatabase) !DoctorResult.Check {
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

// -- New checks --

fn checkIntegrity(db: *storage.SqlDatabase) !DoctorResult.Check {
    var stmt = db.prepare("PRAGMA integrity_check") catch {
        return .{
            .name = "SQLite integrity",
            .status = "fail",
            .message = "Could not run integrity check",
        };
    };
    defer stmt.deinit();

    if (try stmt.step()) {
        const result = stmt.columnText(0) orelse "unknown";
        if (std.mem.eql(u8, result, "ok")) {
            return .{
                .name = "SQLite integrity",
                .status = "pass",
                .message = null,
            };
        }
        return .{
            .name = "SQLite integrity",
            .status = "fail",
            .message = "PRAGMA integrity_check reported errors",
        };
    }
    return .{
        .name = "SQLite integrity",
        .status = "fail",
        .message = "PRAGMA integrity_check returned no results",
    };
}

fn checkSchemaTables(db: *storage.SqlDatabase) !DoctorResult.Check {
    const expected = [_][]const u8{
        "issues",
        "dependencies",
        "labels",
        "comments",
        "events",
        "dirty_issues",
        "blocked_issues_cache",
        "config",
        "metadata",
        "export_hashes",
        "child_counters",
    };

    var stmt = db.prepare("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'") catch {
        return .{
            .name = "Schema tables",
            .status = "fail",
            .message = "Could not query sqlite_master",
        };
    };
    defer stmt.deinit();

    var found_count: usize = 0;
    var table_set: [expected.len]bool = .{false} ** expected.len;

    while (try stmt.step()) {
        const name = stmt.columnText(0) orelse continue;
        for (expected, 0..) |exp, i| {
            if (std.mem.eql(u8, name, exp)) {
                table_set[i] = true;
                found_count += 1;
                break;
            }
        }
    }

    if (found_count == expected.len) {
        return .{
            .name = "Schema tables",
            .status = "pass",
            .message = null,
        };
    }

    // Build a message listing missing tables
    var missing_buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&missing_buf);
    const writer = fbs.writer();
    writer.writeAll("Missing tables: ") catch {};
    var first = true;
    for (expected, 0..) |exp, i| {
        if (!table_set[i]) {
            if (!first) writer.writeAll(", ") catch {};
            writer.writeAll(exp) catch {};
            first = false;
        }
    }
    // We return a comptime-known string for simplicity since dynamic alloc
    // would need lifetime management. The specific missing table names are
    // secondary to the fail status for the caller.
    return .{
        .name = "Schema tables",
        .status = "fail",
        .message = "One or more expected tables are missing",
    };
}

fn checkSchemaColumns(db: *storage.SqlDatabase) !DoctorResult.Check {
    const TableCheck = struct {
        table: []const u8,
        required: []const []const u8,
    };

    const table_checks = [_]TableCheck{
        .{
            .table = "issues",
            .required = &.{ "id", "title", "status", "priority", "issue_type", "created_at", "updated_at" },
        },
        .{
            .table = "dependencies",
            .required = &.{ "issue_id", "depends_on_id", "dep_type", "created_at" },
        },
    };

    for (table_checks) |tc| {
        var sql_buf: [128]u8 = undefined;
        const sql = std.fmt.bufPrint(&sql_buf, "PRAGMA table_info({s})", .{tc.table}) catch {
            return .{
                .name = "Schema columns",
                .status = "fail",
                .message = "Internal error building PRAGMA query",
            };
        };

        var stmt = db.prepare(sql) catch {
            return .{
                .name = "Schema columns",
                .status = "fail",
                .message = "Could not query table columns",
            };
        };
        defer stmt.deinit();

        var found: [16]bool = .{false} ** 16;
        const required = tc.required;

        while (try stmt.step()) {
            // PRAGMA table_info columns: cid, name, type, notnull, dflt_value, pk
            const col_name = stmt.columnText(1) orelse continue;
            for (required, 0..) |req, i| {
                if (i >= found.len) break;
                if (std.mem.eql(u8, col_name, req)) {
                    found[i] = true;
                    break;
                }
            }
        }

        for (0..required.len) |i| {
            if (!found[i]) {
                return .{
                    .name = "Schema columns",
                    .status = "fail",
                    .message = "Missing required columns in schema",
                };
            }
        }
    }

    return .{
        .name = "Schema columns",
        .status = "pass",
        .message = null,
    };
}

fn checkJsonlParse(beads_dir: []const u8, allocator: std.mem.Allocator) !DoctorResult.Check {
    const jsonl_path = std.fs.path.join(allocator, &.{ beads_dir, "issues.jsonl" }) catch {
        return .{
            .name = "JSONL parse",
            .status = "fail",
            .message = "Out of memory",
        };
    };
    defer allocator.free(jsonl_path);

    // Check if file exists first
    std.fs.cwd().access(jsonl_path, .{}) catch {
        return .{
            .name = "JSONL parse",
            .status = "pass",
            .message = "No issues.jsonl file (not required)",
        };
    };

    // Use arena to avoid leak tracking issues with parseFromSliceLeaky
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    var jsonl = JsonlFile.init(jsonl_path, arena_alloc);
    const result = jsonl.readAllWithRecovery() catch {
        return .{
            .name = "JSONL parse",
            .status = "fail",
            .message = "Failed to read issues.jsonl",
        };
    };

    if (result.corruption_count > 0) {
        return .{
            .name = "JSONL parse",
            .status = "warn",
            .message = "JSONL file has corrupt entries",
        };
    }

    return .{
        .name = "JSONL parse",
        .status = "pass",
        .message = null,
    };
}

fn checkConflictMarkers(beads_dir: []const u8, allocator: std.mem.Allocator) !DoctorResult.Check {
    const jsonl_path = std.fs.path.join(allocator, &.{ beads_dir, "issues.jsonl" }) catch {
        return .{
            .name = "No conflict markers",
            .status = "fail",
            .message = "Out of memory",
        };
    };
    defer allocator.free(jsonl_path);

    const file = std.fs.cwd().openFile(jsonl_path, .{}) catch {
        return .{
            .name = "No conflict markers",
            .status = "pass",
            .message = "No issues.jsonl file",
        };
    };
    defer file.close();

    const content = file.readToEndAlloc(allocator, 256 * 1024 * 1024) catch {
        return .{
            .name = "No conflict markers",
            .status = "fail",
            .message = "Failed to read issues.jsonl",
        };
    };
    defer allocator.free(content);

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "<<<<<<<") or
            std.mem.startsWith(u8, line, "=======") or
            std.mem.startsWith(u8, line, ">>>>>>>"))
        {
            return .{
                .name = "No conflict markers",
                .status = "warn",
                .message = "Git conflict markers found in issues.jsonl",
            };
        }
    }

    return .{
        .name = "No conflict markers",
        .status = "pass",
        .message = null,
    };
}

fn checkMergeArtifacts(beads_dir: []const u8) DoctorResult.Check {
    const suffixes = [_][]const u8{ ".base.jsonl", ".left.jsonl", ".right.jsonl" };

    var dir = std.fs.cwd().openDir(beads_dir, .{ .iterate = true }) catch {
        return .{
            .name = "No merge artifacts",
            .status = "pass",
            .message = "Could not open beads directory",
        };
    };
    defer dir.close();

    var iter = dir.iterate();
    while (iter.next() catch null) |entry| {
        for (suffixes) |suffix| {
            if (std.mem.endsWith(u8, entry.name, suffix)) {
                return .{
                    .name = "No merge artifacts",
                    .status = "warn",
                    .message = "Found merge artifact files (*.base.jsonl, *.left.jsonl, or *.right.jsonl)",
                };
            }
        }
    }

    return .{
        .name = "No merge artifacts",
        .status = "pass",
        .message = null,
    };
}

fn checkDbVsJsonl(issue_store: *IssueStore, beads_dir: []const u8, allocator: std.mem.Allocator) !DoctorResult.Check {
    const jsonl_path = std.fs.path.join(allocator, &.{ beads_dir, "issues.jsonl" }) catch {
        return .{
            .name = "DB/JSONL count match",
            .status = "fail",
            .message = "Out of memory",
        };
    };
    defer allocator.free(jsonl_path);

    // If JSONL doesn't exist, skip
    std.fs.cwd().access(jsonl_path, .{}) catch {
        return .{
            .name = "DB/JSONL count match",
            .status = "pass",
            .message = "No issues.jsonl file (skipped)",
        };
    };

    const db_count = issue_store.countTotal() catch {
        return .{
            .name = "DB/JSONL count match",
            .status = "fail",
            .message = "Could not count database issues",
        };
    };

    // Use arena for JSONL parsing (parseFromSliceLeaky may leak on failures)
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    var jsonl = JsonlFile.init(jsonl_path, arena_alloc);
    const jsonl_issues = jsonl.readAll() catch {
        return .{
            .name = "DB/JSONL count match",
            .status = "warn",
            .message = "Could not parse JSONL file for comparison",
        };
    };

    if (db_count == jsonl_issues.len) {
        return .{
            .name = "DB/JSONL count match",
            .status = "pass",
            .message = null,
        };
    }

    return .{
        .name = "DB/JSONL count match",
        .status = "warn",
        .message = "Database and JSONL issue counts differ (run 'bz sync' to reconcile)",
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

test "checkIntegrity passes on valid database" {
    const allocator = std.testing.allocator;
    var db = try storage.SqlDatabase.open(allocator, ":memory:");
    defer db.close();
    try storage.createSchema(&db);

    const check = try checkIntegrity(&db);
    try std.testing.expectEqualStrings("pass", check.status);
}

test "checkSchemaTables passes with full schema" {
    const allocator = std.testing.allocator;
    var db = try storage.SqlDatabase.open(allocator, ":memory:");
    defer db.close();
    try storage.createSchema(&db);

    const check = try checkSchemaTables(&db);
    try std.testing.expectEqualStrings("pass", check.status);
}

test "checkSchemaTables fails with missing table" {
    const allocator = std.testing.allocator;
    var db = try storage.SqlDatabase.open(allocator, ":memory:");
    defer db.close();
    // Only create partial schema
    try db.exec("CREATE TABLE issues (id TEXT PRIMARY KEY)");

    const check = try checkSchemaTables(&db);
    try std.testing.expectEqualStrings("fail", check.status);
}

test "checkSchemaColumns passes with full schema" {
    const allocator = std.testing.allocator;
    var db = try storage.SqlDatabase.open(allocator, ":memory:");
    defer db.close();
    try storage.createSchema(&db);

    const check = try checkSchemaColumns(&db);
    try std.testing.expectEqualStrings("pass", check.status);
}

test "checkMergeArtifacts passes with clean directory" {
    var temp_dir = std.testing.tmpDir(.{});
    defer temp_dir.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const temp_path = try temp_dir.dir.realpath(".", &path_buf);

    const check = checkMergeArtifacts(temp_path);
    try std.testing.expectEqualStrings("pass", check.status);
}

test "checkMergeArtifacts warns on artifact files" {
    var temp_dir = std.testing.tmpDir(.{});
    defer temp_dir.cleanup();

    // Create a merge artifact file
    const f = try temp_dir.dir.createFile("issues.base.jsonl", .{});
    f.close();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const temp_path = try temp_dir.dir.realpath(".", &path_buf);

    const check = checkMergeArtifacts(temp_path);
    try std.testing.expectEqualStrings("warn", check.status);
}

test "checkConflictMarkers passes with clean file" {
    const allocator = std.testing.allocator;

    var temp_dir = std.testing.tmpDir(.{});
    defer temp_dir.cleanup();

    // Create a clean JSONL file
    const f = try temp_dir.dir.createFile("issues.jsonl", .{});
    try f.writeAll("{\"id\":\"test\"}\n");
    f.close();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const temp_path = try temp_dir.dir.realpath(".", &path_buf);

    const check = try checkConflictMarkers(temp_path, allocator);
    try std.testing.expectEqualStrings("pass", check.status);
}

test "checkConflictMarkers warns on markers" {
    const allocator = std.testing.allocator;

    var temp_dir = std.testing.tmpDir(.{});
    defer temp_dir.cleanup();

    const f = try temp_dir.dir.createFile("issues.jsonl", .{});
    try f.writeAll("{\"id\":\"test\"}\n<<<<<<< HEAD\n{\"id\":\"a\"}\n=======\n{\"id\":\"b\"}\n>>>>>>> branch\n");
    f.close();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const temp_path = try temp_dir.dir.realpath(".", &path_buf);

    const check = try checkConflictMarkers(temp_path, allocator);
    try std.testing.expectEqualStrings("warn", check.status);
}

test "checkConflictMarkers passes when no file" {
    const allocator = std.testing.allocator;
    const check = try checkConflictMarkers("/nonexistent/path", allocator);
    try std.testing.expectEqualStrings("pass", check.status);
}
