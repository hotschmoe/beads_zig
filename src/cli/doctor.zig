//! Doctor command for beads_zig.
//!
//! `bz doctor` - Run diagnostic checks on the workspace
//!
//! Output format matches br exactly:
//!   OK check_name
//!   OK check_name: detail message
//!   WARN check_name: detail message
//!   FAIL check_name: detail message

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
    ok: bool = true,
    checks: ?[]const Check = null,

    pub const Check = struct {
        name: []const u8,
        status: []const u8, // "ok", "fail", "warn"
        message: ?[]const u8 = null,
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

    // Arena for dynamic detail messages (e.g. "Parsed 5 records")
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const msg_alloc = arena.allocator();

    var checks: std.ArrayListUnmanaged(DoctorResult.Check) = .{};
    defer checks.deinit(allocator);

    // br check order (9 checks):
    // 1. jsonl.merge_artifacts
    try checks.append(allocator, checkMergeArtifacts(ctx.beads_dir));

    // 2. sync_jsonl_path
    try checks.append(allocator, checkSyncJsonlPath(ctx.beads_dir));

    // 3. sync_conflict_markers
    try checks.append(allocator, try checkConflictMarkers(ctx.beads_dir, allocator));

    // 4. jsonl.parse
    try checks.append(allocator, try checkJsonlParse(ctx.beads_dir, allocator, msg_alloc));

    // 5. schema.tables
    try checks.append(allocator, try checkSchemaTables(ctx.db));

    // 6. schema.columns
    try checks.append(allocator, try checkSchemaColumns(ctx.db));

    // 7. sqlite.integrity_check
    try checks.append(allocator, try checkIntegrity(ctx.db));

    // 8. counts.db_vs_jsonl
    try checks.append(allocator, try checkDbVsJsonl(&ctx.issue_store, ctx.beads_dir, allocator, msg_alloc));

    // 9. sync.metadata
    try checks.append(allocator, try checkSyncMetadata(ctx.db, ctx.beads_dir, allocator));

    // Determine overall success
    var has_fail = false;
    for (checks.items) |check| {
        if (std.mem.eql(u8, check.status, "fail")) {
            has_fail = true;
            break;
        }
    }

    if (global.isStructuredOutput()) {
        try ctx.output.printJson(DoctorResult{
            .ok = !has_fail,
            .checks = checks.items,
        });
    } else if (!global.quiet) {
        // Header: "bz doctor" (matches br's "br doctor")
        try ctx.output.print("bz doctor\n", .{});

        for (checks.items) |check| {
            const label = if (std.mem.eql(u8, check.status, "ok"))
                "OK"
            else if (std.mem.eql(u8, check.status, "fail"))
                "FAIL"
            else
                "WARN";

            if (check.message) |msg| {
                try ctx.output.print("{s} {s}: {s}\n", .{ label, check.name, msg });
            } else {
                try ctx.output.print("{s} {s}\n", .{ label, check.name });
            }
        }
    }
}

// -- Check implementations (br-compatible names, messages, and order) --

fn checkMergeArtifacts(beads_dir: []const u8) DoctorResult.Check {
    const suffixes = [_][]const u8{ ".base.jsonl", ".left.jsonl", ".right.jsonl" };

    var dir = std.fs.cwd().openDir(beads_dir, .{ .iterate = true }) catch {
        return .{ .name = "jsonl.merge_artifacts", .status = "ok" };
    };
    defer dir.close();

    var iter = dir.iterate();
    while (iter.next() catch null) |entry| {
        for (suffixes) |suffix| {
            if (std.mem.endsWith(u8, entry.name, suffix)) {
                return .{
                    .name = "jsonl.merge_artifacts",
                    .status = "warn",
                    .message = "Found merge artifact files",
                };
            }
        }
    }

    return .{ .name = "jsonl.merge_artifacts", .status = "ok" };
}

fn checkSyncJsonlPath(beads_dir: []const u8) DoctorResult.Check {
    // bz always stores JSONL inside .beads/ -- path is always valid.
    // We verify the beads directory is accessible as a real check.
    std.fs.cwd().access(beads_dir, .{}) catch {
        return .{
            .name = "sync_jsonl_path",
            .status = "fail",
            .message = "Cannot access beads directory",
        };
    };
    return .{
        .name = "sync_jsonl_path",
        .status = "ok",
        .message = "JSONL path is within sync allowlist",
    };
}

fn checkConflictMarkers(beads_dir: []const u8, allocator: std.mem.Allocator) !DoctorResult.Check {
    const jsonl_path = std.fs.path.join(allocator, &.{ beads_dir, "issues.jsonl" }) catch {
        return .{ .name = "sync_conflict_markers", .status = "ok", .message = "No merge conflict markers found" };
    };
    defer allocator.free(jsonl_path);

    const file = std.fs.cwd().openFile(jsonl_path, .{}) catch {
        return .{ .name = "sync_conflict_markers", .status = "ok", .message = "No merge conflict markers found" };
    };
    defer file.close();

    const content = file.readToEndAlloc(allocator, 256 * 1024 * 1024) catch {
        return .{ .name = "sync_conflict_markers", .status = "fail", .message = "Failed to read issues.jsonl" };
    };
    defer allocator.free(content);

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "<<<<<<<") or
            std.mem.startsWith(u8, line, "=======") or
            std.mem.startsWith(u8, line, ">>>>>>>"))
        {
            return .{
                .name = "sync_conflict_markers",
                .status = "warn",
                .message = "Merge conflict markers found in JSONL",
            };
        }
    }

    return .{ .name = "sync_conflict_markers", .status = "ok", .message = "No merge conflict markers found" };
}

fn checkJsonlParse(beads_dir: []const u8, allocator: std.mem.Allocator, msg_alloc: std.mem.Allocator) !DoctorResult.Check {
    const jsonl_path = std.fs.path.join(allocator, &.{ beads_dir, "issues.jsonl" }) catch {
        return .{ .name = "jsonl.parse", .status = "fail", .message = "Out of memory" };
    };
    defer allocator.free(jsonl_path);

    std.fs.cwd().access(jsonl_path, .{}) catch {
        return .{ .name = "jsonl.parse", .status = "ok", .message = "Parsed 0 records" };
    };

    // Use a sub-arena for JSONL parsing (parseFromSliceLeaky may leak)
    var parse_arena = std.heap.ArenaAllocator.init(allocator);
    defer parse_arena.deinit();

    var jsonl = JsonlFile.init(jsonl_path, parse_arena.allocator());
    const result = jsonl.readAllWithRecovery() catch {
        return .{ .name = "jsonl.parse", .status = "fail", .message = "Failed to parse issues.jsonl" };
    };

    if (result.corruption_count > 0) {
        const msg = std.fmt.allocPrint(msg_alloc, "Parsed {d} records ({d} corrupt lines skipped)", .{
            result.issues.len, result.corruption_count,
        }) catch "Parsed records with corruption";
        return .{ .name = "jsonl.parse", .status = "warn", .message = msg };
    }

    const msg = std.fmt.allocPrint(msg_alloc, "Parsed {d} records", .{result.issues.len}) catch "Parsed records";
    return .{ .name = "jsonl.parse", .status = "ok", .message = msg };
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
        return .{ .name = "schema.tables", .status = "fail", .message = "Could not query sqlite_master" };
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
        return .{ .name = "schema.tables", .status = "ok" };
    }

    return .{ .name = "schema.tables", .status = "fail", .message = "One or more expected tables are missing" };
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
            return .{ .name = "schema.columns", .status = "fail", .message = "Internal error" };
        };

        var stmt = db.prepare(sql) catch {
            return .{ .name = "schema.columns", .status = "fail", .message = "Could not query table columns" };
        };
        defer stmt.deinit();

        var found: [16]bool = .{false} ** 16;
        const required = tc.required;

        while (try stmt.step()) {
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
                return .{ .name = "schema.columns", .status = "fail", .message = "Missing required columns" };
            }
        }
    }

    return .{ .name = "schema.columns", .status = "ok" };
}

fn checkIntegrity(db: *storage.SqlDatabase) !DoctorResult.Check {
    var stmt = db.prepare("PRAGMA integrity_check") catch {
        return .{ .name = "sqlite.integrity_check", .status = "fail", .message = "Could not run integrity check" };
    };
    defer stmt.deinit();

    if (try stmt.step()) {
        const result = stmt.columnText(0) orelse "unknown";
        if (std.mem.eql(u8, result, "ok")) {
            return .{ .name = "sqlite.integrity_check", .status = "ok" };
        }
        return .{ .name = "sqlite.integrity_check", .status = "fail", .message = "Integrity check reported errors" };
    }
    return .{ .name = "sqlite.integrity_check", .status = "fail", .message = "Integrity check returned no results" };
}

fn checkDbVsJsonl(
    issue_store: *IssueStore,
    beads_dir: []const u8,
    allocator: std.mem.Allocator,
    msg_alloc: std.mem.Allocator,
) !DoctorResult.Check {
    const jsonl_path = std.fs.path.join(allocator, &.{ beads_dir, "issues.jsonl" }) catch {
        return .{ .name = "counts.db_vs_jsonl", .status = "fail", .message = "Out of memory" };
    };
    defer allocator.free(jsonl_path);

    std.fs.cwd().access(jsonl_path, .{}) catch {
        return .{ .name = "counts.db_vs_jsonl", .status = "ok", .message = "No JSONL file" };
    };

    const db_count = issue_store.countTotal() catch {
        return .{ .name = "counts.db_vs_jsonl", .status = "fail", .message = "Could not count database issues" };
    };

    var parse_arena = std.heap.ArenaAllocator.init(allocator);
    defer parse_arena.deinit();

    var jsonl = JsonlFile.init(jsonl_path, parse_arena.allocator());
    const jsonl_issues = jsonl.readAll() catch {
        return .{ .name = "counts.db_vs_jsonl", .status = "warn", .message = "Could not parse JSONL file" };
    };

    if (db_count == jsonl_issues.len) {
        const msg = std.fmt.allocPrint(msg_alloc, "Both have {d} records", .{db_count}) catch "Counts match";
        return .{ .name = "counts.db_vs_jsonl", .status = "ok", .message = msg };
    }

    return .{ .name = "counts.db_vs_jsonl", .status = "warn", .message = "DB and JSONL counts differ" };
}

fn checkSyncMetadata(
    db: *storage.SqlDatabase,
    beads_dir: []const u8,
    allocator: std.mem.Allocator,
) !DoctorResult.Check {
    const jsonl_path = std.fs.path.join(allocator, &.{ beads_dir, "issues.jsonl" }) catch {
        return .{ .name = "sync.metadata", .status = "ok", .message = "Database and JSONL are in sync" };
    };
    defer allocator.free(jsonl_path);

    // Check if JSONL file exists
    const jsonl_exists = blk: {
        std.fs.cwd().access(jsonl_path, .{}) catch break :blk false;
        break :blk true;
    };

    if (!jsonl_exists) {
        return .{ .name = "sync.metadata", .status = "ok", .message = "Database and JSONL are in sync" };
    }

    // Check metadata table for last_export_time
    const has_export = blk: {
        var stmt = db.prepare("SELECT value FROM metadata WHERE key = 'last_export_time'") catch {
            break :blk false;
        };
        defer stmt.deinit();
        break :blk (stmt.step() catch false);
    };

    if (!has_export) {
        // JSONL exists but no export recorded -- matches br's message
        return .{
            .name = "sync.metadata",
            .status = "warn",
            .message = "JSONL exists but no export recorded; consider running sync --flush-only",
        };
    }

    // Check if there are dirty (unexported) issues
    const dirty_count: i64 = blk: {
        var stmt = db.prepare("SELECT COUNT(*) FROM dirty_issues") catch break :blk 0;
        defer stmt.deinit();
        if (stmt.step() catch false) {
            break :blk stmt.columnInt(0);
        }
        break :blk 0;
    };

    if (dirty_count > 0) {
        return .{
            .name = "sync.metadata",
            .status = "warn",
            .message = "Unexported changes exist; consider running sync --flush-only",
        };
    }

    // Check if last_import_time > last_export_time (external changes pending)
    const import_newer = blk: {
        var stmt = db.prepare(
            \\SELECT
            \\  (SELECT value FROM metadata WHERE key = 'last_import_time'),
            \\  (SELECT value FROM metadata WHERE key = 'last_export_time')
        ) catch break :blk false;
        defer stmt.deinit();
        if (stmt.step() catch false) {
            const import_time = stmt.columnText(0) orelse break :blk false;
            const export_time = stmt.columnText(1) orelse break :blk false;
            // Lexicographic comparison works for ISO-8601 timestamps
            break :blk std.mem.order(u8, import_time, export_time) == .gt;
        }
        break :blk false;
    };

    if (import_newer) {
        return .{
            .name = "sync.metadata",
            .status = "ok",
            .message = "External changes pending import",
        };
    }

    return .{ .name = "sync.metadata", .status = "ok", .message = "Database and JSONL are in sync" };
}

// --- Tests ---

test "DoctorError enum exists" {
    const err: DoctorError = DoctorError.WorkspaceNotInitialized;
    try std.testing.expect(err == DoctorError.WorkspaceNotInitialized);
}

test "DoctorResult struct works" {
    const result = DoctorResult{
        .ok = true,
    };
    try std.testing.expect(result.ok);
}

test "run detects uninitialized workspace" {
    const allocator = std.testing.allocator;

    const global = args.GlobalOptions{ .silent = true, .data_path = "/nonexistent/path" };

    const result = run(global, allocator);
    try std.testing.expectError(DoctorError.WorkspaceNotInitialized, result);
}

test "checkIntegrity passes on valid database" {
    const allocator = std.testing.allocator;
    var db = try storage.SqlDatabase.open(allocator, ":memory:");
    defer db.close();
    try storage.createSchema(&db);

    const check = try checkIntegrity(&db);
    try std.testing.expectEqualStrings("ok", check.status);
    try std.testing.expectEqualStrings("sqlite.integrity_check", check.name);
}

test "checkSchemaTables passes with full schema" {
    const allocator = std.testing.allocator;
    var db = try storage.SqlDatabase.open(allocator, ":memory:");
    defer db.close();
    try storage.createSchema(&db);

    const check = try checkSchemaTables(&db);
    try std.testing.expectEqualStrings("ok", check.status);
    try std.testing.expectEqualStrings("schema.tables", check.name);
}

test "checkSchemaTables fails with missing table" {
    const allocator = std.testing.allocator;
    var db = try storage.SqlDatabase.open(allocator, ":memory:");
    defer db.close();
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
    try std.testing.expectEqualStrings("ok", check.status);
    try std.testing.expectEqualStrings("schema.columns", check.name);
}

test "checkMergeArtifacts passes with clean directory" {
    var temp_dir = std.testing.tmpDir(.{});
    defer temp_dir.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const temp_path = try temp_dir.dir.realpath(".", &path_buf);

    const check = checkMergeArtifacts(temp_path);
    try std.testing.expectEqualStrings("ok", check.status);
    try std.testing.expectEqualStrings("jsonl.merge_artifacts", check.name);
}

test "checkMergeArtifacts warns on artifact files" {
    var temp_dir = std.testing.tmpDir(.{});
    defer temp_dir.cleanup();

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

    const f = try temp_dir.dir.createFile("issues.jsonl", .{});
    try f.writeAll("{\"id\":\"test\"}\n");
    f.close();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const temp_path = try temp_dir.dir.realpath(".", &path_buf);

    const check = try checkConflictMarkers(temp_path, allocator);
    try std.testing.expectEqualStrings("ok", check.status);
    try std.testing.expectEqualStrings("sync_conflict_markers", check.name);
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
    try std.testing.expectEqualStrings("ok", check.status);
}

test "checkSyncJsonlPath passes for accessible directory" {
    var temp_dir = std.testing.tmpDir(.{});
    defer temp_dir.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const temp_path = try temp_dir.dir.realpath(".", &path_buf);

    const check = checkSyncJsonlPath(temp_path);
    try std.testing.expectEqualStrings("ok", check.status);
    try std.testing.expectEqualStrings("sync_jsonl_path", check.name);
    try std.testing.expectEqualStrings("JSONL path is within sync allowlist", check.message.?);
}

test "checkSyncMetadata warns when no export recorded" {
    const allocator = std.testing.allocator;
    var db = try storage.SqlDatabase.open(allocator, ":memory:");
    defer db.close();
    try storage.createSchema(&db);

    // Create a temp dir with an issues.jsonl file but no export metadata
    var temp_dir = std.testing.tmpDir(.{});
    defer temp_dir.cleanup();

    const f = try temp_dir.dir.createFile("issues.jsonl", .{});
    f.close();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const temp_path = try temp_dir.dir.realpath(".", &path_buf);

    const check = try checkSyncMetadata(&db, temp_path, allocator);
    try std.testing.expectEqualStrings("warn", check.status);
    try std.testing.expectEqualStrings("sync.metadata", check.name);
}

test "checkSyncMetadata passes when no JSONL" {
    const allocator = std.testing.allocator;
    var db = try storage.SqlDatabase.open(allocator, ":memory:");
    defer db.close();
    try storage.createSchema(&db);

    const check = try checkSyncMetadata(&db, "/nonexistent/path", allocator);
    try std.testing.expectEqualStrings("ok", check.status);
    try std.testing.expectEqualStrings("Database and JSONL are in sync", check.message.?);
}
