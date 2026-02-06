//! Sync command for beads_zig.
//!
//! `bz sync` - Bidirectional sync with JSONL file
//! `bz sync --flush-only` - Export DB to JSONL
//! `bz sync --import-only` - Import from JSONL into DB
//! `bz sync --merge` - 3-way merge of local DB and remote JSONL
//! `bz sync --status` - Show sync status

const std = @import("std");
const json = std.json;
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
    db_count: ?usize = null,
    jsonl_count: ?usize = null,
    pending_export: ?usize = null,
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

    // Note: orphan_policy and rename_prefix from sync_args are not yet implemented for SQLite backend
    _ = sync_args.orphan_policy;
    _ = sync_args.rename_prefix;
    _ = sync_args.error_policy;

    if (sync_args.status) {
        try runStatus(&ctx, structured_output, global.quiet, allocator);
    } else if (sync_args.flush_only) {
        try runFlush(&ctx, structured_output, global.quiet, sync_args.manifest, allocator);
    } else if (sync_args.import_only) {
        try runImport(&ctx, structured_output, global.quiet, allocator);
    } else if (sync_args.merge) {
        try runMerge(&ctx, structured_output, global.quiet, allocator);
    } else {
        try runBidirectional(&ctx, structured_output, global.quiet, allocator);
    }
}

fn getJsonlPath(ctx: *CommandContext, allocator: std.mem.Allocator) ![]const u8 {
    return std.fs.path.join(allocator, &.{ ctx.beads_dir, "issues.jsonl" });
}

fn runFlush(ctx: *CommandContext, structured_output: bool, quiet: bool, write_manifest: bool, allocator: std.mem.Allocator) !void {
    const all_issues = try ctx.issue_store.list(.{ .include_tombstones = true });
    defer ctx.issue_store.freeIssues(all_issues);

    const jsonl_path = try getJsonlPath(ctx, allocator);
    defer allocator.free(jsonl_path);

    exportToJsonl(all_issues, jsonl_path, allocator) catch {
        try common.outputErrorTyped(SyncResult, &ctx.output, structured_output, "failed to export issues to JSONL");
        return SyncError.ExportError;
    };

    // Clear dirty flags after successful export
    for (all_issues) |issue| {
        ctx.issue_store.clearDirty(issue.id) catch {};
    }

    var manifest_path: ?[]const u8 = null;
    if (write_manifest) {
        manifest_path = try writeManifest(ctx, all_issues.len, allocator);
    }
    defer if (manifest_path) |path| allocator.free(path);

    if (structured_output) {
        try ctx.output.printJson(SyncResult{
            .success = true,
            .action = "flush",
            .issues_exported = all_issues.len,
            .manifest_path = manifest_path,
        });
    } else if (!quiet) {
        try ctx.output.success("Exported {d} issue(s) to JSONL", .{all_issues.len});
        if (manifest_path) |path| {
            try ctx.output.info("Manifest written to {s}", .{path});
        }
    }
}

fn runImport(ctx: *CommandContext, structured_output: bool, quiet: bool, allocator: std.mem.Allocator) !void {
    // Note: orphan_policy and rename_prefix parameters removed - not yet implemented for SQLite backend
    // TODO: implement orphan detection and prefix renaming
    const jsonl_path = try getJsonlPath(ctx, allocator);
    defer allocator.free(jsonl_path);

    if (try hasMergeConflicts(jsonl_path, allocator)) {
        try common.outputErrorTyped(SyncResult, &ctx.output, structured_output, "JSONL file contains merge conflict markers - resolve conflicts first");
        return SyncError.MergeConflictDetected;
    }

    const remote_issues = loadJsonlIssues(jsonl_path, allocator) catch {
        try common.outputErrorTyped(SyncResult, &ctx.output, structured_output, "failed to import from JSONL");
        return SyncError.ImportError;
    };
    defer {
        for (remote_issues) |*issue| {
            var i = issue.*;
            i.deinit(allocator);
        }
        allocator.free(remote_issues);
    }

    var added: usize = 0;
    var updated: usize = 0;

    for (remote_issues) |remote_issue| {
        if (try ctx.issue_store.exists(remote_issue.id)) {
            // Update existing
            const local_issue = (try ctx.issue_store.get(remote_issue.id)) orelse continue;
            defer {
                var li = local_issue;
                li.deinit(allocator);
            }

            if (remote_issue.updated_at.value > local_issue.updated_at.value) {
                try ctx.issue_store.update(remote_issue.id, .{
                    .title = remote_issue.title,
                    .description = remote_issue.description,
                    .status = remote_issue.status,
                    .priority = remote_issue.priority,
                    .issue_type = remote_issue.issue_type,
                    .assignee = remote_issue.assignee,
                    .owner = remote_issue.owner,
                    .notes = remote_issue.notes,
                    .close_reason = remote_issue.close_reason,
                    .pinned = remote_issue.pinned,
                    .is_template = remote_issue.is_template,
                }, remote_issue.updated_at.value);
                updated += 1;
            }
        } else {
            // Insert new - clone the issue since insert takes ownership
            var cloned = try remote_issue.clone(allocator);
            ctx.issue_store.insert(cloned) catch {
                cloned.deinit(allocator);
                continue;
            };
            added += 1;
        }
    }

    if (structured_output) {
        try ctx.output.printJson(SyncResult{
            .success = true,
            .action = "import",
            .issues_imported = remote_issues.len,
            .issues_added = if (added > 0) added else null,
            .issues_updated = if (updated > 0) updated else null,
        });
    } else if (!quiet) {
        try ctx.output.success("Imported: {d} added, {d} updated from JSONL", .{ added, updated });
    }
}

fn runBidirectional(ctx: *CommandContext, structured_output: bool, quiet: bool, allocator: std.mem.Allocator) !void {
    const jsonl_path = try getJsonlPath(ctx, allocator);
    defer allocator.free(jsonl_path);

    if (try hasMergeConflicts(jsonl_path, allocator)) {
        try common.outputErrorTyped(SyncResult, &ctx.output, structured_output, "JSONL file contains merge conflict markers - resolve conflicts first");
        return SyncError.MergeConflictDetected;
    }

    // Check for dirty issues that need export
    const dirty_ids = try ctx.issue_store.getDirtyIds();
    defer {
        for (dirty_ids) |id| allocator.free(id);
        allocator.free(dirty_ids);
    }

    if (dirty_ids.len > 0) {
        // Export all issues to JSONL (including tombstones for full export)
        const all_issues = try ctx.issue_store.list(.{ .include_tombstones = true });
        defer ctx.issue_store.freeIssues(all_issues);

        exportToJsonl(all_issues, jsonl_path, allocator) catch {
            try common.outputErrorTyped(SyncResult, &ctx.output, structured_output, "failed to sync issues");
            return SyncError.ExportError;
        };

        for (dirty_ids) |id| {
            ctx.issue_store.clearDirty(id) catch {};
        }

        if (structured_output) {
            try ctx.output.printJson(SyncResult{
                .success = true,
                .action = "sync",
                .issues_exported = all_issues.len,
            });
        } else if (!quiet) {
            try ctx.output.success("Synced {d} issue(s)", .{all_issues.len});
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

fn runMerge(ctx: *CommandContext, structured_output: bool, quiet: bool, allocator: std.mem.Allocator) !void {
    // Note: orphan_policy and rename_prefix parameters removed - not yet implemented for SQLite backend
    // TODO: implement orphan detection and prefix renaming
    const jsonl_path = try getJsonlPath(ctx, allocator);
    defer allocator.free(jsonl_path);

    if (try hasMergeConflicts(jsonl_path, allocator)) {
        try common.outputErrorTyped(SyncResult, &ctx.output, structured_output, "JSONL file contains merge conflict markers - resolve conflicts first");
        return SyncError.MergeConflictDetected;
    }

    // Load remote issues from JSONL
    const remote_issues = loadJsonlIssues(jsonl_path, allocator) catch |err| {
        if (err != error.FileNotFound) {
            try common.outputErrorTyped(SyncResult, &ctx.output, structured_output, "failed to load remote JSONL");
            return SyncError.ImportError;
        }
        return;
    };
    defer {
        for (remote_issues) |*issue| {
            var i = issue.*;
            i.deinit(allocator);
        }
        allocator.free(remote_issues);
    }

    var added: usize = 0;
    var updated: usize = 0;

    for (remote_issues) |remote_issue| {
        if (try ctx.issue_store.exists(remote_issue.id)) {
            const local_issue = (try ctx.issue_store.get(remote_issue.id)) orelse continue;
            defer {
                var li = local_issue;
                li.deinit(allocator);
            }

            if (remote_issue.updated_at.value > local_issue.updated_at.value) {
                try ctx.issue_store.update(remote_issue.id, .{
                    .title = remote_issue.title,
                    .description = remote_issue.description,
                    .status = remote_issue.status,
                    .priority = remote_issue.priority,
                    .issue_type = remote_issue.issue_type,
                    .assignee = remote_issue.assignee,
                    .owner = remote_issue.owner,
                    .notes = remote_issue.notes,
                    .close_reason = remote_issue.close_reason,
                    .pinned = remote_issue.pinned,
                    .is_template = remote_issue.is_template,
                }, remote_issue.updated_at.value);
                updated += 1;
            }
        } else {
            // Insert new - clone the issue since insert takes ownership
            var cloned = try remote_issue.clone(allocator);
            ctx.issue_store.insert(cloned) catch {
                cloned.deinit(allocator);
                continue;
            };
            added += 1;
        }
    }

    // Re-export merged state (including tombstones for full export)
    if (added > 0 or updated > 0) {
        const all_issues = try ctx.issue_store.list(.{ .include_tombstones = true });
        defer ctx.issue_store.freeIssues(all_issues);
        exportToJsonl(all_issues, jsonl_path, allocator) catch {};
    }

    const total = try ctx.issue_store.countTotal();

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

fn runStatus(ctx: *CommandContext, structured_output: bool, quiet: bool, allocator: std.mem.Allocator) !void {
    const db_count = try ctx.issue_store.countTotal();

    const jsonl_path = try getJsonlPath(ctx, allocator);
    defer allocator.free(jsonl_path);

    const jsonl_count = countJsonlIssues(jsonl_path, allocator) catch |err| switch (err) {
        error.FileNotFound => @as(usize, 0),
        else => return err,
    };

    const dirty_ids = try ctx.issue_store.getDirtyIds();
    defer {
        for (dirty_ids) |id| allocator.free(id);
        allocator.free(dirty_ids);
    }
    const pending_export = dirty_ids.len;

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

// -- Helpers --

fn exportToJsonl(issues: []const Issue, path: []const u8, allocator: std.mem.Allocator) !void {
    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();

    for (issues) |issue| {
        const line = json.Stringify.valueAlloc(allocator, issue, .{}) catch continue;
        defer allocator.free(line);
        try file.writeAll(line);
        try file.writeAll("\n");
    }
}

fn loadJsonlIssues(path: []const u8, allocator: std.mem.Allocator) ![]Issue {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 1024 * 1024 * 50);
    defer allocator.free(content);

    var issues: std.ArrayListUnmanaged(Issue) = .{};
    errdefer {
        for (issues.items) |*issue| {
            issue.deinit(allocator);
        }
        issues.deinit(allocator);
    }

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0 or trimmed[0] != '{') continue;

        const parsed = json.parseFromSlice(Issue, allocator, trimmed, .{
            .allocate = .alloc_always,
            .ignore_unknown_fields = true,
        }) catch continue;

        try issues.append(allocator, parsed.value);
    }

    return issues.toOwnedSlice(allocator);
}

fn countJsonlIssues(path: []const u8, allocator: std.mem.Allocator) !usize {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 1024 * 1024 * 50);
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

fn writeManifest(ctx: *CommandContext, issue_count: usize, allocator: std.mem.Allocator) ![]const u8 {
    const manifest_path = try std.fs.path.join(allocator, &.{ ctx.beads_dir, "manifest.json" });
    errdefer allocator.free(manifest_path);

    const ts = std.time.timestamp();

    var json_buf: std.ArrayListUnmanaged(u8) = .{};
    defer json_buf.deinit(allocator);

    const writer = json_buf.writer(allocator);
    try writer.writeAll("{\n");
    try writer.print("  \"exported_at\": {d},\n", .{ts});
    try writer.print("  \"issue_count\": {d},\n", .{issue_count});
    try writer.print("  \"version\": \"0.1.0\"\n", .{});
    try writer.writeAll("}\n");

    const file = try std.fs.cwd().createFile(manifest_path, .{});
    defer file.close();
    try file.writeAll(json_buf.items);

    return manifest_path;
}

fn hasMergeConflicts(path: []const u8, allocator: std.mem.Allocator) !bool {
    const file = std.fs.cwd().openFile(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 1024 * 1024 * 10);
    defer allocator.free(content);

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
