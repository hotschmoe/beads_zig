//! Sync command for beads_zig.
//!
//! `bz sync` - Bidirectional sync with JSONL file
//! `bz sync --flush-only` - Export to JSONL only
//! `bz sync --import-only` - Import from JSONL only
//! `bz sync --merge` - 3-way merge of local DB and remote JSONL
//!
//! Handles synchronization between in-memory state and JSONL file.

const std = @import("std");
const models = @import("../models/mod.zig");
const storage = @import("../storage/mod.zig");
const common = @import("common.zig");
const args = @import("args.zig");
const test_util = @import("../test_util.zig");

const Issue = models.Issue;
const IssueStore = common.IssueStore;
const CommandContext = common.CommandContext;

pub const SyncError = error{
    WorkspaceNotInitialized,
    MergeConflictDetected,
    ImportError,
    ExportError,
    OutOfMemory,
};

pub const SyncResult = struct {
    success: bool,
    action: ?[]const u8 = null,
    issues_exported: ?usize = null,
    issues_imported: ?usize = null,
    issues_updated: ?usize = null,
    issues_added: ?usize = null,
    issues_skipped: ?usize = null,
    issues_renamed: ?usize = null,
    orphans_created: ?usize = null,
    errors: ?usize = null,
    message: ?[]const u8 = null,
    // Status-specific fields
    db_count: ?usize = null,
    jsonl_count: ?usize = null,
    pending_export: ?usize = null,
    // Manifest-specific fields
    manifest_path: ?[]const u8 = null,
};

pub fn run(
    sync_args: args.SyncArgs,
    global: args.GlobalOptions,
    allocator: std.mem.Allocator,
) !void {
    var ctx = (try CommandContext.init(allocator, global)) orelse {
        return SyncError.WorkspaceNotInitialized;
    };
    defer ctx.deinit();

    const structured_output = global.isStructuredOutput();

    if (sync_args.status) {
        try runStatus(&ctx, structured_output, global.quiet, allocator);
    } else if (sync_args.flush_only) {
        try runFlush(&ctx, structured_output, global.quiet, sync_args.manifest, sync_args.error_policy, allocator);
    } else if (sync_args.import_only) {
        try runImport(&ctx, structured_output, global.quiet, sync_args.orphan_policy, sync_args.rename_prefix, allocator);
    } else if (sync_args.merge) {
        try runMerge(&ctx, structured_output, global.quiet, sync_args.orphan_policy, sync_args.rename_prefix, allocator);
    } else {
        try runBidirectional(&ctx, structured_output, global.quiet, allocator);
    }
}

fn runFlush(ctx: *CommandContext, structured_output: bool, quiet: bool, write_manifest: bool, error_policy: args.ErrorPolicy, allocator: std.mem.Allocator) !void {
    const count = ctx.store.issues.items.len;
    var errors: usize = 0;

    ctx.store.saveToFile() catch |err| {
        switch (error_policy) {
            .strict => {
                try common.outputErrorTyped(SyncResult, &ctx.output, structured_output, "failed to export issues");
                return SyncError.ExportError;
            },
            .best_effort => {
                errors += 1;
                if (!quiet and !structured_output) {
                    try ctx.output.warn("Export error (continuing): {}", .{err});
                }
            },
            .partial => {
                errors += 1;
                // Silent skip
            },
        }
    };

    // Write manifest if requested
    var manifest_path: ?[]const u8 = null;
    if (write_manifest) {
        manifest_path = try writeManifest(ctx, count, allocator);
    }
    defer if (manifest_path) |path| allocator.free(path);

    if (structured_output) {
        try ctx.output.printJson(SyncResult{
            .success = errors == 0,
            .action = "flush",
            .issues_exported = count,
            .errors = if (errors > 0) errors else null,
            .manifest_path = manifest_path,
        });
    } else if (!quiet) {
        if (errors > 0) {
            try ctx.output.warn("Exported {d} issue(s) to JSONL with {d} error(s)", .{ count, errors });
        } else {
            try ctx.output.success("Exported {d} issue(s) to JSONL", .{count});
        }
        if (manifest_path) |path| {
            try ctx.output.info("Manifest written to {s}", .{path});
        }
    }
}

fn runImport(ctx: *CommandContext, structured_output: bool, quiet: bool, orphan_policy: args.OrphanPolicy, rename_prefix: bool, allocator: std.mem.Allocator) !void {
    // Check for merge conflict markers in the JSONL file
    if (try hasMergeConflicts(ctx.store.jsonl_path, allocator)) {
        try common.outputErrorTyped(SyncResult, &ctx.output, structured_output, "JSONL file contains merge conflict markers - resolve conflicts first");
        return SyncError.MergeConflictDetected;
    }

    // Reload from file (this replaces in-memory state)
    const old_count = ctx.store.issues.items.len;

    // Deinit existing issues
    for (ctx.store.issues.items) |*issue| {
        issue.deinit(allocator);
    }
    ctx.store.issues.clearRetainingCapacity();

    // Clear and rebuild index
    var id_it = ctx.store.id_index.keyIterator();
    while (id_it.next()) |key| {
        allocator.free(key.*);
    }
    ctx.store.id_index.clearRetainingCapacity();

    // Reload from file
    ctx.store.loadFromFile() catch {
        try common.outputErrorTyped(SyncResult, &ctx.output, structured_output, "failed to import from JSONL");
        return SyncError.ImportError;
    };

    var orphans_created: usize = 0;
    var issues_skipped: usize = 0;
    var issues_renamed: usize = 0;

    // Get the expected prefix from config (default to "bd")
    const expected_prefix = ctx.store.getPrefix();

    // Process orphans and prefix renaming
    var issues_to_remove: std.ArrayListUnmanaged(usize) = .{};
    defer issues_to_remove.deinit(allocator);

    var orphan_ids: std.ArrayListUnmanaged([]const u8) = .{};
    defer {
        for (orphan_ids.items) |id| allocator.free(id);
        orphan_ids.deinit(allocator);
    }

    for (ctx.store.issues.items, 0..) |*issue, idx| {
        // Check for wrong prefix and rename if requested
        if (rename_prefix) {
            if (issue.id.len >= 3) {
                const dash_pos = std.mem.indexOf(u8, issue.id, "-");
                if (dash_pos) |pos| {
                    const current_prefix = issue.id[0..pos];
                    if (!std.mem.eql(u8, current_prefix, expected_prefix)) {
                        // Create new ID with correct prefix
                        const suffix = issue.id[pos..];
                        const new_id = try std.fmt.allocPrint(allocator, "{s}{s}", .{ expected_prefix, suffix });

                        // Update the issue's ID (need to free old and set new)
                        allocator.free(issue.id);
                        issue.id = new_id;
                        issues_renamed += 1;
                    }
                }
            }
        }

        // Check for orphaned parent references (hierarchical IDs like bd-abc.1)
        if (std.mem.indexOf(u8, issue.id, ".")) |dot_pos| {
            const parent_id = issue.id[0..dot_pos];
            const parent_exists = ctx.store.id_index.contains(parent_id);

            if (!parent_exists) {
                switch (orphan_policy) {
                    .strict => {
                        try common.outputErrorTyped(SyncResult, &ctx.output, structured_output, "orphan detected: parent not found for hierarchical ID");
                        return SyncError.ImportError;
                    },
                    .resurrect => {
                        // Create a placeholder parent issue
                        const parent_id_copy = try allocator.dupe(u8, parent_id);
                        try orphan_ids.append(allocator, parent_id_copy);
                        orphans_created += 1;
                    },
                    .skip => {
                        try issues_to_remove.append(allocator, idx);
                        issues_skipped += 1;
                    },
                }
            }
        }
    }

    // Remove skipped issues (in reverse order to maintain indices)
    var i = issues_to_remove.items.len;
    while (i > 0) {
        i -= 1;
        const idx = issues_to_remove.items[i];
        var removed = ctx.store.issues.orderedRemove(idx);
        removed.deinit(allocator);
    }

    // Create placeholder parents for orphans (resurrect policy)
    for (orphan_ids.items) |parent_id| {
        if (!ctx.store.id_index.contains(parent_id)) {
            const placeholder_title = try std.fmt.allocPrint(allocator, "[Placeholder] Parent of orphaned issue(s)", .{});
            defer allocator.free(placeholder_title);

            var placeholder = Issue.init(parent_id, placeholder_title, std.time.timestamp());
            placeholder.id = try allocator.dupe(u8, parent_id);
            placeholder.title = try allocator.dupe(u8, placeholder_title);
            try ctx.store.insert(placeholder);
        }
    }

    // Rebuild index after modifications
    ctx.store.rebuildIndex() catch {};

    // Mark dirty if we made changes
    if (issues_renamed > 0 or orphans_created > 0) {
        ctx.store.dirty = true;
    }

    const new_count = ctx.store.issues.items.len;

    if (structured_output) {
        try ctx.output.printJson(SyncResult{
            .success = true,
            .action = "import",
            .issues_imported = new_count,
            .issues_skipped = if (issues_skipped > 0) issues_skipped else null,
            .issues_renamed = if (issues_renamed > 0) issues_renamed else null,
            .orphans_created = if (orphans_created > 0) orphans_created else null,
        });
    } else if (!quiet) {
        if (new_count > old_count) {
            try ctx.output.success("Imported {d} issue(s) from JSONL (+{d})", .{ new_count, new_count - old_count });
        } else if (new_count < old_count) {
            try ctx.output.success("Imported {d} issue(s) from JSONL (-{d})", .{ new_count, old_count - new_count });
        } else {
            try ctx.output.success("Imported {d} issue(s) from JSONL (no change)", .{new_count});
        }
        if (issues_renamed > 0) {
            try ctx.output.info("Renamed {d} issue(s) with wrong prefix", .{issues_renamed});
        }
        if (orphans_created > 0) {
            try ctx.output.info("Created {d} placeholder parent(s) for orphans", .{orphans_created});
        }
        if (issues_skipped > 0) {
            try ctx.output.info("Skipped {d} orphaned issue(s)", .{issues_skipped});
        }
    }
}

fn runBidirectional(ctx: *CommandContext, structured_output: bool, quiet: bool, allocator: std.mem.Allocator) !void {
    // Check for merge conflict markers
    if (try hasMergeConflicts(ctx.store.jsonl_path, allocator)) {
        try common.outputErrorTyped(SyncResult, &ctx.output, structured_output, "JSONL file contains merge conflict markers - resolve conflicts first");
        return SyncError.MergeConflictDetected;
    }

    // For bidirectional sync, we export the current state
    // A full bidirectional merge would require content hashing which is complex
    const count = ctx.store.issues.items.len;

    if (ctx.store.dirty) {
        ctx.store.saveToFile() catch {
            try common.outputErrorTyped(SyncResult, &ctx.output, structured_output, "failed to sync issues");
            return SyncError.ExportError;
        };

        if (structured_output) {
            try ctx.output.printJson(SyncResult{
                .success = true,
                .action = "sync",
                .issues_exported = count,
            });
        } else if (!quiet) {
            try ctx.output.success("Synced {d} issue(s)", .{count});
        }
    } else {
        if (structured_output) {
            try ctx.output.printJson(SyncResult{
                .success = true,
                .action = "sync",
                .message = "no changes to sync",
            });
        } else if (!quiet) {
            try ctx.output.info("No changes to sync", .{});
        }
    }
}

/// Perform 3-way merge of local DB and remote JSONL.
/// For each issue:
/// - If only in local: keep
/// - If only in remote: add
/// - If in both: keep the one with newer updated_at timestamp
fn runMerge(ctx: *CommandContext, structured_output: bool, quiet: bool, orphan_policy: args.OrphanPolicy, rename_prefix: bool, allocator: std.mem.Allocator) !void {
    _ = orphan_policy; // TODO: implement orphan handling for merge
    _ = rename_prefix; // TODO: implement prefix renaming for merge
    // Check for merge conflict markers
    if (try hasMergeConflicts(ctx.store.jsonl_path, allocator)) {
        try common.outputErrorTyped(SyncResult, &ctx.output, structured_output, "JSONL file contains merge conflict markers - resolve conflicts first");
        return SyncError.MergeConflictDetected;
    }

    // Load remote issues from JSONL file directly (without replacing store)
    var remote_store = storage.IssueStore.init(allocator, ctx.store.jsonl_path);
    defer remote_store.deinit();

    remote_store.loadFromFile() catch |err| {
        if (err != error.FileNotFound) {
            try common.outputErrorTyped(SyncResult, &ctx.output, structured_output, "failed to load remote JSONL");
            return SyncError.ImportError;
        }
    };

    var added: usize = 0;
    var updated: usize = 0;

    // Iterate through remote issues and merge into local store
    for (remote_store.issues.items) |remote_issue| {
        if (ctx.store.getRef(remote_issue.id)) |local_issue| {
            // Issue exists in both - compare updated_at timestamps
            const local_ts = local_issue.updated_at.value;
            const remote_ts = remote_issue.updated_at.value;

            if (remote_ts > local_ts) {
                // Remote is newer - update local with remote data
                // We need to copy the remote issue's data
                const update = storage.IssueStore.IssueUpdate{
                    .title = remote_issue.title,
                    .description = remote_issue.description,
                    .design = remote_issue.design,
                    .acceptance_criteria = remote_issue.acceptance_criteria,
                    .notes = remote_issue.notes,
                    .status = remote_issue.status,
                    .priority = remote_issue.priority,
                    .issue_type = remote_issue.issue_type,
                    .assignee = remote_issue.assignee,
                    .owner = remote_issue.owner,
                    .estimated_minutes = remote_issue.estimated_minutes,
                    .closed_at = remote_issue.closed_at.value,
                    .close_reason = remote_issue.close_reason,
                    .due_at = remote_issue.due_at.value,
                    .defer_until = remote_issue.defer_until.value,
                    .external_ref = remote_issue.external_ref,
                    .source_system = remote_issue.source_system,
                    .pinned = remote_issue.pinned,
                    .is_template = remote_issue.is_template,
                };

                ctx.store.update(remote_issue.id, update, remote_ts) catch continue;
                updated += 1;
            }
            // If local is newer or equal, keep local (no action needed)
        } else {
            // Issue only in remote - add to local
            // Clone the remote issue for insertion
            var cloned = try remote_issue.clone(allocator);
            ctx.store.insert(cloned) catch {
                cloned.deinit(allocator);
                continue;
            };
            added += 1;
        }
    }

    // Save merged state if any changes were made
    if (added > 0 or updated > 0 or ctx.store.dirty) {
        ctx.store.saveToFile() catch {
            try common.outputErrorTyped(SyncResult, &ctx.output, structured_output, "failed to save merged issues");
            return SyncError.ExportError;
        };
    }

    const total = ctx.store.issues.items.len;

    if (structured_output) {
        try ctx.output.printJson(SyncResult{
            .success = true,
            .action = "merge",
            .issues_added = added,
            .issues_updated = updated,
            .issues_exported = total,
        });
    } else if (!quiet) {
        if (added == 0 and updated == 0) {
            try ctx.output.info("No changes to merge", .{});
        } else {
            try ctx.output.success("Merged: {d} added, {d} updated ({d} total)", .{ added, updated, total });
        }
    }
}

/// Show sync status without making changes.
/// Reports: DB issue count, JSONL issue count, pending export count.
fn runStatus(ctx: *CommandContext, structured_output: bool, quiet: bool, allocator: std.mem.Allocator) !void {
    const db_count = ctx.store.issues.items.len;

    // Count issues in JSONL file (without loading into store)
    const jsonl_count = countJsonlIssues(ctx.store.jsonl_path, allocator) catch |err| switch (err) {
        error.FileNotFound => 0,
        else => return err,
    };

    // Count pending exports (dirty issues)
    const pending_export = ctx.store.dirty_ids.count();

    if (structured_output) {
        try ctx.output.printJson(SyncResult{
            .success = true,
            .action = "status",
            .db_count = db_count,
            .jsonl_count = jsonl_count,
            .pending_export = pending_export,
        });
    } else if (!quiet) {
        try ctx.output.print("DB: {d} issues, JSONL: {d} issues\n", .{ db_count, jsonl_count });
        if (pending_export > 0) {
            try ctx.output.print("{d} issues pending export\n", .{pending_export});
        } else {
            try ctx.output.info("No pending changes", .{});
        }
    }
}

/// Count the number of issues in a JSONL file without fully parsing them.
fn countJsonlIssues(path: []const u8, allocator: std.mem.Allocator) !usize {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 1024 * 1024 * 50); // 50MB max
    defer allocator.free(content);

    var count: usize = 0;
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len > 0 and trimmed[0] == '{') {
            count += 1;
        }
    }
    return count;
}

/// Write a manifest file with export metadata.
fn writeManifest(ctx: *CommandContext, issue_count: usize, allocator: std.mem.Allocator) ![]const u8 {
    // Derive manifest path from jsonl_path
    const dir_path = std.fs.path.dirname(ctx.store.jsonl_path) orelse ".beads";
    const manifest_path = try std.fs.path.join(allocator, &.{ dir_path, "manifest.json" });
    errdefer allocator.free(manifest_path);

    const timestamp = std.time.timestamp();

    // Build manifest JSON
    var json_buf: std.ArrayListUnmanaged(u8) = .{};
    defer json_buf.deinit(allocator);

    const writer = json_buf.writer(allocator);
    try writer.writeAll("{\n");
    try writer.print("  \"exported_at\": {d},\n", .{timestamp});
    try writer.print("  \"issue_count\": {d},\n", .{issue_count});
    try writer.print("  \"jsonl_path\": \"{s}\",\n", .{ctx.store.jsonl_path});
    try writer.print("  \"version\": \"0.1.0\"\n", .{});
    try writer.writeAll("}\n");

    // Write to file
    const file = try std.fs.cwd().createFile(manifest_path, .{});
    defer file.close();
    try file.writeAll(json_buf.items);

    return manifest_path;
}

/// Check if the JSONL file contains git merge conflict markers
fn hasMergeConflicts(path: []const u8, allocator: std.mem.Allocator) !bool {
    const file = std.fs.cwd().openFile(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 1024 * 1024 * 10);
    defer allocator.free(content);

    // Check for common merge conflict markers
    if (std.mem.indexOf(u8, content, "<<<<<<<") != null) return true;
    if (std.mem.indexOf(u8, content, "=======") != null) return true;
    if (std.mem.indexOf(u8, content, ">>>>>>>") != null) return true;

    return false;
}

// --- Tests ---

test "SyncError enum exists" {
    const err: SyncError = SyncError.MergeConflictDetected;
    try std.testing.expect(err == SyncError.MergeConflictDetected);
}

test "SyncResult struct works" {
    const result = SyncResult{
        .success = true,
        .action = "flush",
        .issues_exported = 5,
    };
    try std.testing.expect(result.success);
    try std.testing.expectEqualStrings("flush", result.action.?);
    try std.testing.expectEqual(@as(usize, 5), result.issues_exported.?);
}

test "run detects uninitialized workspace" {
    const allocator = std.testing.allocator;

    const sync_args = args.SyncArgs{};
    const global = args.GlobalOptions{ .silent = true, .data_path = "/nonexistent/path" };

    const result = run(sync_args, global, allocator);
    try std.testing.expectError(SyncError.WorkspaceNotInitialized, result);
}

test "hasMergeConflicts returns false for clean file" {
    const allocator = std.testing.allocator;
    const test_dir = try test_util.createTestDir(allocator, "sync_clean");
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
    const test_dir = try test_util.createTestDir(allocator, "sync_conflict");
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

test "hasMergeConflicts returns false for missing file" {
    const has_conflicts = try hasMergeConflicts("/nonexistent/path.jsonl", std.testing.allocator);
    try std.testing.expect(!has_conflicts);
}

test "countJsonlIssues counts valid JSON lines" {
    const allocator = std.testing.allocator;
    const test_dir = try test_util.createTestDir(allocator, "sync_count");
    defer allocator.free(test_dir);
    defer test_util.cleanupTestDir(test_dir);

    const test_path = try std.fs.path.join(allocator, &.{ test_dir, "count.jsonl" });
    defer allocator.free(test_path);

    const file = try std.fs.cwd().createFile(test_path, .{});
    try file.writeAll("{\"id\":\"bd-1\"}\n{\"id\":\"bd-2\"}\n{\"id\":\"bd-3\"}\n");
    file.close();

    const count = try countJsonlIssues(test_path, allocator);
    try std.testing.expectEqual(@as(usize, 3), count);
}

test "countJsonlIssues handles empty lines" {
    const allocator = std.testing.allocator;
    const test_dir = try test_util.createTestDir(allocator, "sync_count_empty");
    defer allocator.free(test_dir);
    defer test_util.cleanupTestDir(test_dir);

    const test_path = try std.fs.path.join(allocator, &.{ test_dir, "count_empty.jsonl" });
    defer allocator.free(test_path);

    const file = try std.fs.cwd().createFile(test_path, .{});
    try file.writeAll("{\"id\":\"bd-1\"}\n\n{\"id\":\"bd-2\"}\n  \n{\"id\":\"bd-3\"}\n");
    file.close();

    const count = try countJsonlIssues(test_path, allocator);
    try std.testing.expectEqual(@as(usize, 3), count);
}

test "SyncResult with status fields" {
    const result = SyncResult{
        .success = true,
        .action = "status",
        .db_count = 45,
        .jsonl_count = 43,
        .pending_export = 2,
    };
    try std.testing.expect(result.success);
    try std.testing.expectEqualStrings("status", result.action.?);
    try std.testing.expectEqual(@as(usize, 45), result.db_count.?);
    try std.testing.expectEqual(@as(usize, 43), result.jsonl_count.?);
    try std.testing.expectEqual(@as(usize, 2), result.pending_export.?);
}

test "SyncArgs parses status flag" {
    const sync_args = args.SyncArgs{ .status = true };
    try std.testing.expect(sync_args.status);
    try std.testing.expect(!sync_args.flush_only);
}

test "SyncArgs parses manifest flag" {
    const sync_args = args.SyncArgs{ .manifest = true, .flush_only = true };
    try std.testing.expect(sync_args.manifest);
    try std.testing.expect(sync_args.flush_only);
}
