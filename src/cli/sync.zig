//! Sync command for beads_zig.
//!
//! `bz sync` - Bidirectional sync with JSONL file
//! `bz sync --flush-only` - Export to JSONL only
//! `bz sync --import-only` - Import from JSONL only
//!
//! Handles synchronization between in-memory state and JSONL file.

const std = @import("std");
const models = @import("../models/mod.zig");
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
    message: ?[]const u8 = null,
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

    if (sync_args.flush_only) {
        try runFlush(&ctx, structured_output, global.quiet);
    } else if (sync_args.import_only) {
        try runImport(&ctx, structured_output, global.quiet, allocator);
    } else {
        try runBidirectional(&ctx, structured_output, global.quiet, allocator);
    }
}

fn runFlush(ctx: *CommandContext, structured_output: bool, quiet: bool) !void {
    const count = ctx.store.issues.items.len;

    ctx.store.saveToFile() catch {
        try common.outputErrorTyped(SyncResult, &ctx.output, structured_output, "failed to export issues");
        return SyncError.ExportError;
    };

    if (structured_output) {
        try ctx.output.printJson(SyncResult{
            .success = true,
            .action = "flush",
            .issues_exported = count,
        });
    } else if (!quiet) {
        try ctx.output.success("Exported {d} issue(s) to JSONL", .{count});
    }
}

fn runImport(ctx: *CommandContext, structured_output: bool, quiet: bool, allocator: std.mem.Allocator) !void {
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

    const new_count = ctx.store.issues.items.len;

    if (structured_output) {
        try ctx.output.printJson(SyncResult{
            .success = true,
            .action = "import",
            .issues_imported = new_count,
        });
    } else if (!quiet) {
        if (new_count > old_count) {
            try ctx.output.success("Imported {d} issue(s) from JSONL (+{d})", .{ new_count, new_count - old_count });
        } else if (new_count < old_count) {
            try ctx.output.success("Imported {d} issue(s) from JSONL (-{d})", .{ new_count, old_count - new_count });
        } else {
            try ctx.output.success("Imported {d} issue(s) from JSONL (no change)", .{new_count});
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
