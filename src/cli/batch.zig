//! Batch operations for beads_zig.
//!
//! - `bz add-batch` - Create multiple issues from stdin/file with single lock
//! - `bz import <file>` - Import issues from JSONL file with single lock
//!
//! These operations reduce lock contention for bulk operations by acquiring
//! a single lock, performing all insertions, and releasing.

const std = @import("std");
const models = @import("../models/mod.zig");
const storage = @import("../storage/mod.zig");
const id_gen = @import("../id/mod.zig");
const common = @import("common.zig");
const args = @import("args.zig");
const test_util = @import("../test_util.zig");

const Issue = models.Issue;
const IssueStore = storage.IssueStore;
const JsonlFile = storage.JsonlFile;
const IdGenerator = id_gen.IdGenerator;

pub const BatchError = error{
    WorkspaceNotInitialized,
    StorageError,
    InvalidInput,
    FileReadError,
    NoIssuesToAdd,
    OutOfMemory,
};

pub const BatchResult = struct {
    success: bool,
    issues_created: ?usize = null,
    issues_imported: ?usize = null,
    issues_skipped: ?usize = null,
    ids: ?[]const []const u8 = null,
    message: ?[]const u8 = null,
};

pub const ImportResult = struct {
    success: bool,
    issues_imported: ?usize = null,
    issues_skipped: ?usize = null,
    issues_updated: ?usize = null,
    message: ?[]const u8 = null,
};

/// Run the add-batch command.
/// Creates multiple issues with a single lock acquisition and fsync.
pub fn runAddBatch(
    batch_args: args.AddBatchArgs,
    global: args.GlobalOptions,
    allocator: std.mem.Allocator,
) !void {
    var output = common.initOutput(allocator, global);
    const structured_output = global.isStructuredOutput();

    // Determine workspace path
    const beads_dir = global.data_path orelse ".beads";
    const issues_path = try std.fs.path.join(allocator, &.{ beads_dir, "issues.jsonl" });
    defer allocator.free(issues_path);

    // Check if workspace is initialized
    std.fs.cwd().access(issues_path, .{}) catch |err| {
        if (err == error.FileNotFound) {
            try common.outputErrorTyped(BatchResult, &output, structured_output, "workspace not initialized. Run 'bz init' first.");
            return BatchError.WorkspaceNotInitialized;
        }
        try common.outputErrorTyped(BatchResult, &output, structured_output, "cannot access workspace");
        return BatchError.StorageError;
    };

    // Read input from file
    const file_path = batch_args.file orelse {
        try common.outputErrorTyped(BatchResult, &output, structured_output, "file path required. Use 'bz add-batch <file>' or 'bz add-batch --file <file>'");
        return BatchError.InvalidInput;
    };

    const input_content = readFileContent(file_path, allocator) catch {
        try common.outputErrorTyped(BatchResult, &output, structured_output, "failed to read input file");
        return BatchError.FileReadError;
    };
    defer allocator.free(input_content);

    // Parse input based on format
    var issues_to_add: std.ArrayListUnmanaged(Issue) = .{};
    defer {
        for (issues_to_add.items) |*issue| {
            issue.deinit(allocator);
        }
        issues_to_add.deinit(allocator);
    }

    // Load existing issues to get count for ID generation
    var store = IssueStore.init(allocator, issues_path);
    defer store.deinit();

    store.loadFromFile() catch |err| {
        if (err != error.FileNotFound) {
            try common.outputErrorTyped(BatchResult, &output, structured_output, "failed to load issues");
            return BatchError.StorageError;
        }
    };

    // Get config prefix
    const prefix = try common.getConfigPrefix(allocator, beads_dir);
    defer allocator.free(prefix);

    // Get actor
    const actor = global.actor orelse common.getDefaultActor();

    const now = std.time.timestamp();
    var generator = IdGenerator.init(prefix);
    const issue_count = store.countTotal();

    // Track IDs generated in this batch to avoid intra-batch collisions
    var batch_ids = std.StringHashMap(void).init(allocator);
    defer batch_ids.deinit();

    // Copy existing IDs to check against
    var id_it = store.getIdIndex().keyIterator();
    while (id_it.next()) |key| {
        try batch_ids.put(key.*, {});
    }

    // Parse input and create issues
    switch (batch_args.format) {
        .titles => {
            var line_iter = std.mem.splitScalar(u8, input_content, '\n');
            while (line_iter.next()) |line| {
                const trimmed = std.mem.trim(u8, line, " \t\r");
                if (trimmed.len == 0) continue;
                if (trimmed.len > 500) continue; // Skip titles that are too long

                const issue_id = generator.generateUnique(allocator, issue_count + batch_ids.count(), batch_ids) catch |err| {
                    if (err == error.CollisionLimitExceeded) {
                        try common.outputErrorTyped(BatchResult, &output, structured_output, "failed to generate unique ID after multiple attempts");
                        return BatchError.StorageError;
                    }
                    return err;
                };
                errdefer allocator.free(issue_id);
                try batch_ids.put(issue_id, {});

                var issue = Issue.init(issue_id, trimmed, now);
                issue.created_by = actor;

                // Clone strings for owned storage
                const cloned = try issue.clone(allocator);
                allocator.free(issue_id); // clone made its own copy
                try issues_to_add.append(allocator, cloned);
            }
        },
        .jsonl => {
            var line_iter = std.mem.splitScalar(u8, input_content, '\n');
            while (line_iter.next()) |line| {
                const trimmed = std.mem.trim(u8, line, " \t\r");
                if (trimmed.len == 0) continue;

                // Parse as Issue JSON
                const parsed = std.json.parseFromSlice(
                    Issue,
                    allocator,
                    trimmed,
                    .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
                ) catch continue; // Skip malformed entries

                // If no ID, generate one
                var issue = parsed.value;
                if (issue.id.len == 0) {
                    const new_id = generator.generateUnique(allocator, issue_count + batch_ids.count(), batch_ids) catch |err| {
                        if (err == error.CollisionLimitExceeded) {
                            parsed.deinit();
                            try common.outputErrorTyped(BatchResult, &output, structured_output, "failed to generate unique ID after multiple attempts");
                            return BatchError.StorageError;
                        }
                        return err;
                    };
                    allocator.free(issue.id);
                    issue.id = new_id;
                    try batch_ids.put(new_id, {});
                }

                try issues_to_add.append(allocator, issue);
            }
        },
    }

    if (issues_to_add.items.len == 0) {
        if (structured_output) {
            try output.printJson(BatchResult{
                .success = true,
                .issues_created = 0,
                .message = "no issues to add",
            });
        } else if (!global.quiet) {
            try output.info("No issues to add", .{});
        }
        return;
    }

    // Insert all issues (single save at end)
    var created_ids: std.ArrayListUnmanaged([]const u8) = .{};
    defer {
        for (created_ids.items) |id| {
            allocator.free(id);
        }
        created_ids.deinit(allocator);
    }

    for (issues_to_add.items) |issue| {
        store.insert(issue) catch |err| switch (err) {
            error.DuplicateId => continue, // Skip duplicates
            else => {
                try common.outputErrorTyped(BatchResult, &output, structured_output, "failed to insert issue");
                return BatchError.StorageError;
            },
        };
        const id_copy = try allocator.dupe(u8, issue.id);
        try created_ids.append(allocator, id_copy);
    }

    // Single atomic save
    if (!global.no_auto_flush) {
        store.saveToFile() catch {
            try common.outputErrorTyped(BatchResult, &output, structured_output, "failed to save issues");
            return BatchError.StorageError;
        };
    }

    // Output result
    if (structured_output) {
        try output.printJson(BatchResult{
            .success = true,
            .issues_created = created_ids.items.len,
            .ids = created_ids.items,
        });
    } else if (global.quiet) {
        for (created_ids.items) |id| {
            try output.raw(id);
            try output.raw("\n");
        }
    } else {
        try output.success("Created {d} issue(s)", .{created_ids.items.len});
    }
}

/// Run the import command.
/// Imports issues from a JSONL file with single lock acquisition.
pub fn runImport(
    import_args: args.ImportArgs,
    global: args.GlobalOptions,
    allocator: std.mem.Allocator,
) !void {
    var output = common.initOutput(allocator, global);
    const structured_output = global.isStructuredOutput();

    // Determine workspace path
    const beads_dir = global.data_path orelse ".beads";
    const issues_path = try std.fs.path.join(allocator, &.{ beads_dir, "issues.jsonl" });
    defer allocator.free(issues_path);

    // Check if workspace is initialized
    std.fs.cwd().access(issues_path, .{}) catch |err| {
        if (err == error.FileNotFound) {
            try common.outputErrorTyped(ImportResult, &output, structured_output, "workspace not initialized. Run 'bz init' first.");
            return BatchError.WorkspaceNotInitialized;
        }
        try common.outputErrorTyped(ImportResult, &output, structured_output, "cannot access workspace");
        return BatchError.StorageError;
    };

    // Check for merge conflict markers in import file
    if (try hasMergeConflicts(import_args.file, allocator)) {
        try common.outputErrorTyped(ImportResult, &output, structured_output, "import file contains merge conflict markers");
        return BatchError.InvalidInput;
    }

    // Read and parse the import file
    var import_jsonl = JsonlFile.init(import_args.file, allocator);
    const imported_issues = import_jsonl.readAllWithRecovery() catch {
        try common.outputErrorTyped(ImportResult, &output, structured_output, "failed to read import file");
        return BatchError.FileReadError;
    };
    defer {
        for (imported_issues.issues) |*issue| {
            issue.deinit(allocator);
        }
        allocator.free(imported_issues.issues);
        if (imported_issues.corrupt_lines.len > 0) {
            allocator.free(imported_issues.corrupt_lines);
        }
    }

    if (import_args.dry_run) {
        // Dry run - just report what would be imported
        if (structured_output) {
            try output.printJson(ImportResult{
                .success = true,
                .issues_imported = imported_issues.issues.len,
                .issues_skipped = imported_issues.corruption_count,
                .message = "dry run - no changes made",
            });
        } else if (!global.quiet) {
            try output.info("Would import {d} issue(s), skip {d} corrupt entries", .{
                imported_issues.issues.len,
                imported_issues.corruption_count,
            });
        }
        return;
    }

    // Load existing issues
    var store = IssueStore.init(allocator, issues_path);
    defer store.deinit();

    store.loadFromFile() catch |err| {
        if (err != error.FileNotFound) {
            try common.outputErrorTyped(ImportResult, &output, structured_output, "failed to load existing issues");
            return BatchError.StorageError;
        }
    };

    var imported_count: usize = 0;
    var skipped_count: usize = 0;
    var updated_count: usize = 0;

    const now = std.time.timestamp();

    for (imported_issues.issues) |issue| {
        if (import_args.merge) {
            // Merge mode: update if exists, insert if not
            if (try store.exists(issue.id)) {
                // Update existing issue
                store.update(issue.id, .{
                    .title = issue.title,
                    .description = issue.description,
                    .status = issue.status,
                    .priority = issue.priority,
                    .issue_type = issue.issue_type,
                    .assignee = issue.assignee,
                }, now) catch {
                    skipped_count += 1;
                    continue;
                };
                updated_count += 1;
            } else {
                store.insert(issue) catch {
                    skipped_count += 1;
                    continue;
                };
                imported_count += 1;
            }
        } else {
            // Replace mode: skip if exists
            if (try store.exists(issue.id)) {
                skipped_count += 1;
                continue;
            }
            store.insert(issue) catch {
                skipped_count += 1;
                continue;
            };
            imported_count += 1;
        }
    }

    // Single atomic save
    if (!global.no_auto_flush) {
        store.saveToFile() catch {
            try common.outputErrorTyped(ImportResult, &output, structured_output, "failed to save issues");
            return BatchError.StorageError;
        };
    }

    // Output result
    if (structured_output) {
        try output.printJson(ImportResult{
            .success = true,
            .issues_imported = imported_count,
            .issues_updated = if (import_args.merge) updated_count else null,
            .issues_skipped = skipped_count + imported_issues.corruption_count,
        });
    } else if (!global.quiet) {
        if (import_args.merge and updated_count > 0) {
            try output.success("Imported {d}, updated {d}, skipped {d} issue(s)", .{
                imported_count,
                updated_count,
                skipped_count,
            });
        } else {
            try output.success("Imported {d}, skipped {d} issue(s)", .{ imported_count, skipped_count });
        }
    }
}

/// Read file content into a buffer.
fn readFileContent(path: []const u8, allocator: std.mem.Allocator) ![]u8 {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    return try file.readToEndAlloc(allocator, 100 * 1024 * 1024); // 100MB max
}

/// Check if a file contains git merge conflict markers.
fn hasMergeConflicts(path: []const u8, allocator: std.mem.Allocator) !bool {
    const file = std.fs.cwd().openFile(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 1024 * 1024 * 10);
    defer allocator.free(content);

    const markers = [_][]const u8{ "<<<<<<<", "=======", ">>>>>>>" };
    for (markers) |marker| {
        if (std.mem.indexOf(u8, content, marker) != null) return true;
    }
    return false;
}

// --- Tests ---

test "BatchError enum exists" {
    const err: BatchError = BatchError.WorkspaceNotInitialized;
    try std.testing.expect(err == BatchError.WorkspaceNotInitialized);
}

test "BatchResult struct works" {
    const result = BatchResult{
        .success = true,
        .issues_created = 5,
    };
    try std.testing.expect(result.success);
    try std.testing.expectEqual(@as(usize, 5), result.issues_created.?);
}

test "ImportResult struct works" {
    const result = ImportResult{
        .success = true,
        .issues_imported = 10,
        .issues_skipped = 2,
    };
    try std.testing.expect(result.success);
    try std.testing.expectEqual(@as(usize, 10), result.issues_imported.?);
    try std.testing.expectEqual(@as(usize, 2), result.issues_skipped.?);
}

test "runAddBatch detects uninitialized workspace" {
    const allocator = std.testing.allocator;

    const batch_args = args.AddBatchArgs{};
    const global = args.GlobalOptions{ .silent = true, .data_path = "/nonexistent/path" };

    const result = runAddBatch(batch_args, global, allocator);
    try std.testing.expectError(BatchError.WorkspaceNotInitialized, result);
}

test "runImport detects uninitialized workspace" {
    const allocator = std.testing.allocator;

    const import_args = args.ImportArgs{ .file = "test.jsonl" };
    const global = args.GlobalOptions{ .silent = true, .data_path = "/nonexistent/path" };

    const result = runImport(import_args, global, allocator);
    try std.testing.expectError(BatchError.WorkspaceNotInitialized, result);
}

test "hasMergeConflicts returns false for missing file" {
    const has_conflicts = try hasMergeConflicts("/nonexistent/path.jsonl", std.testing.allocator);
    try std.testing.expect(!has_conflicts);
}

test "hasMergeConflicts returns false for clean file" {
    const allocator = std.testing.allocator;
    const test_dir = try test_util.createTestDir(allocator, "batch_clean");
    defer allocator.free(test_dir);
    defer test_util.cleanupTestDir(test_dir);

    const test_path = try std.fs.path.join(allocator, &.{ test_dir, "clean.jsonl" });
    defer allocator.free(test_path);

    const file = try std.fs.cwd().createFile(test_path, .{});
    try file.writeAll("{\"id\":\"bd-test\",\"title\":\"Test\"}\n");
    file.close();

    const has_conflicts = try hasMergeConflicts(test_path, allocator);
    try std.testing.expect(!has_conflicts);
}

test "hasMergeConflicts returns true for conflicted file" {
    const allocator = std.testing.allocator;
    const test_dir = try test_util.createTestDir(allocator, "batch_conflict");
    defer allocator.free(test_dir);
    defer test_util.cleanupTestDir(test_dir);

    const test_path = try std.fs.path.join(allocator, &.{ test_dir, "conflict.jsonl" });
    defer allocator.free(test_path);

    const file = try std.fs.cwd().createFile(test_path, .{});
    try file.writeAll("<<<<<<< HEAD\n{\"id\":\"bd-test1\"}\n=======\n{\"id\":\"bd-test2\"}\n>>>>>>> branch\n");
    file.close();

    const has_conflicts = try hasMergeConflicts(test_path, allocator);
    try std.testing.expect(has_conflicts);
}

test "runAddBatch creates issues from titles format" {
    const allocator = std.testing.allocator;
    const test_dir = try test_util.createTestDir(allocator, "batch_titles");
    defer allocator.free(test_dir);
    defer test_util.cleanupTestDir(test_dir);

    // Create workspace
    const data_path = try std.fs.path.join(allocator, &.{ test_dir, ".beads" });
    defer allocator.free(data_path);
    try std.fs.cwd().makeDir(data_path);

    const issues_path = try std.fs.path.join(allocator, &.{ data_path, "issues.jsonl" });
    defer allocator.free(issues_path);
    const f = try std.fs.cwd().createFile(issues_path, .{});
    f.close();

    // Create input file with titles
    const input_path = try std.fs.path.join(allocator, &.{ test_dir, "input.txt" });
    defer allocator.free(input_path);
    {
        const input_file = try std.fs.cwd().createFile(input_path, .{});
        try input_file.writeAll("First issue\nSecond issue\nThird issue\n");
        input_file.close();
    }

    const batch_args = args.AddBatchArgs{ .file = input_path, .format = .titles };
    const global = args.GlobalOptions{ .silent = true, .data_path = data_path };

    try runAddBatch(batch_args, global, allocator);

    // Verify issues were created
    var store = IssueStore.init(allocator, issues_path);
    defer store.deinit();
    try store.loadFromFile();

    try std.testing.expectEqual(@as(usize, 3), store.issues.items.len);
}

test "runImport imports issues from JSONL" {
    const allocator = std.testing.allocator;
    const test_dir = try test_util.createTestDir(allocator, "batch_import");
    defer allocator.free(test_dir);
    defer test_util.cleanupTestDir(test_dir);

    // Create workspace
    const data_path = try std.fs.path.join(allocator, &.{ test_dir, ".beads" });
    defer allocator.free(data_path);
    try std.fs.cwd().makeDir(data_path);

    const issues_path = try std.fs.path.join(allocator, &.{ data_path, "issues.jsonl" });
    defer allocator.free(issues_path);
    const f = try std.fs.cwd().createFile(issues_path, .{});
    f.close();

    // Create import file
    const import_path = try std.fs.path.join(allocator, &.{ test_dir, "import.jsonl" });
    defer allocator.free(import_path);
    {
        const import_file = try std.fs.cwd().createFile(import_path, .{});
        const issue1 = "{\"id\":\"bd-imp1\",\"content_hash\":null,\"title\":\"Imported Issue 1\",\"description\":null,\"design\":null,\"acceptance_criteria\":null,\"notes\":null,\"status\":\"open\",\"priority\":2,\"issue_type\":\"task\",\"assignee\":null,\"owner\":null,\"created_at\":\"2024-01-29T10:00:00Z\",\"created_by\":null,\"updated_at\":\"2024-01-29T10:00:00Z\",\"closed_at\":null,\"close_reason\":null,\"due_at\":null,\"defer_until\":null,\"estimated_minutes\":null,\"external_ref\":null,\"source_system\":null,\"pinned\":false,\"is_template\":false,\"labels\":[],\"dependencies\":[],\"comments\":[]}\n";
        const issue2 = "{\"id\":\"bd-imp2\",\"content_hash\":null,\"title\":\"Imported Issue 2\",\"description\":null,\"design\":null,\"acceptance_criteria\":null,\"notes\":null,\"status\":\"open\",\"priority\":2,\"issue_type\":\"task\",\"assignee\":null,\"owner\":null,\"created_at\":\"2024-01-29T10:00:00Z\",\"created_by\":null,\"updated_at\":\"2024-01-29T10:00:00Z\",\"closed_at\":null,\"close_reason\":null,\"due_at\":null,\"defer_until\":null,\"estimated_minutes\":null,\"external_ref\":null,\"source_system\":null,\"pinned\":false,\"is_template\":false,\"labels\":[],\"dependencies\":[],\"comments\":[]}\n";
        try import_file.writeAll(issue1);
        try import_file.writeAll(issue2);
        import_file.close();
    }

    const import_args = args.ImportArgs{ .file = import_path };
    const global = args.GlobalOptions{ .silent = true, .data_path = data_path };

    try runImport(import_args, global, allocator);

    // Verify issues were imported
    var store = IssueStore.init(allocator, issues_path);
    defer store.deinit();
    try store.loadFromFile();

    try std.testing.expectEqual(@as(usize, 2), store.issues.items.len);
    try std.testing.expect(try store.exists("bd-imp1"));
    try std.testing.expect(try store.exists("bd-imp2"));
}
