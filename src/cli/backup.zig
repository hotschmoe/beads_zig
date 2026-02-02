//! Backup command for beads_zig.
//!
//! `bz backup` - Manage JSONL backup files
//! `bz backup list` - List available backups
//! `bz backup diff <file>` - Show diff between backup and current
//! `bz backup restore <file>` - Restore from backup
//! `bz backup prune` - Remove old backups keeping N most recent
//! `bz backup create` - Create a new backup

const std = @import("std");
const common = @import("common.zig");
const args = @import("args.zig");

const CommandContext = common.CommandContext;

pub const BackupError = error{
    WorkspaceNotInitialized,
    BackupNotFound,
    RestoreFailed,
    CreateFailed,
    OutOfMemory,
};

pub const BackupInfo = struct {
    filename: []const u8,
    size: u64,
    modified: i64,
};

pub const BackupResult = struct {
    success: bool,
    action: ?[]const u8 = null,
    backups: ?[]const BackupInfo = null,
    backup_count: ?usize = null,
    diff_added: ?usize = null,
    diff_removed: ?usize = null,
    diff_modified: ?usize = null,
    restored_count: ?usize = null,
    pruned_count: ?usize = null,
    created_path: ?[]const u8 = null,
    message: ?[]const u8 = null,
};

pub fn run(
    backup_args: args.BackupArgs,
    global: args.GlobalOptions,
    allocator: std.mem.Allocator,
) !void {
    var ctx = (try CommandContext.init(allocator, global)) orelse {
        return BackupError.WorkspaceNotInitialized;
    };
    defer ctx.deinit();

    const structured_output = global.isStructuredOutput();

    switch (backup_args.subcommand) {
        .list => try runList(&ctx, structured_output, global.quiet, allocator),
        .diff => |d| try runDiff(&ctx, d.file, structured_output, global.quiet, allocator),
        .restore => |r| try runRestore(&ctx, r.file, r.dry_run, structured_output, global.quiet, allocator),
        .prune => |p| try runPrune(&ctx, p.keep, p.dry_run, structured_output, global.quiet, allocator),
        .create => try runCreate(&ctx, structured_output, global.quiet, allocator),
    }
}

fn runList(ctx: *CommandContext, structured_output: bool, quiet: bool, allocator: std.mem.Allocator) !void {
    const beads_dir = std.fs.path.dirname(ctx.store.jsonl_path) orelse ".beads";

    var backups: std.ArrayListUnmanaged(BackupInfo) = .{};
    defer {
        for (backups.items) |b| allocator.free(b.filename);
        backups.deinit(allocator);
    }

    // Open the .beads directory and look for backup files
    var dir = std.fs.cwd().openDir(beads_dir, .{ .iterate = true }) catch |err| {
        if (err == error.FileNotFound) {
            if (structured_output) {
                try ctx.output.printJson(BackupResult{
                    .success = true,
                    .action = "list",
                    .backup_count = 0,
                    .message = "no backups found",
                });
            } else if (!quiet) {
                try ctx.output.info("No backups found", .{});
            }
            return;
        }
        return err;
    };
    defer dir.close();

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        // Look for backup files matching pattern: issues.jsonl.bak.* or issues.*.jsonl
        if (std.mem.startsWith(u8, entry.name, "issues.jsonl.bak") or
            (std.mem.startsWith(u8, entry.name, "issues.") and
            std.mem.endsWith(u8, entry.name, ".jsonl") and
            !std.mem.eql(u8, entry.name, "issues.jsonl")))
        {
            const stat = dir.statFile(entry.name) catch continue;
            try backups.append(allocator, .{
                .filename = try allocator.dupe(u8, entry.name),
                .size = stat.size,
                .modified = @intCast(@divFloor(stat.mtime, std.time.ns_per_s)),
            });
        }
    }

    // Sort by modified time (newest first)
    std.mem.sortUnstable(BackupInfo, backups.items, {}, struct {
        fn lessThan(_: void, a: BackupInfo, b: BackupInfo) bool {
            return a.modified > b.modified;
        }
    }.lessThan);

    if (structured_output) {
        try ctx.output.printJson(BackupResult{
            .success = true,
            .action = "list",
            .backup_count = backups.items.len,
            .backups = backups.items,
        });
    } else if (!quiet) {
        if (backups.items.len == 0) {
            try ctx.output.info("No backups found", .{});
        } else {
            try ctx.output.println("Available backups:", .{});
            for (backups.items) |b| {
                try ctx.output.print("  {s} ({d} bytes)\n", .{ b.filename, b.size });
            }
        }
    }
}

fn runDiff(ctx: *CommandContext, file: []const u8, structured_output: bool, quiet: bool, allocator: std.mem.Allocator) !void {
    const beads_dir = std.fs.path.dirname(ctx.store.jsonl_path) orelse ".beads";
    const backup_path = try std.fs.path.join(allocator, &.{ beads_dir, file });
    defer allocator.free(backup_path);

    // Check if backup file exists
    std.fs.cwd().access(backup_path, .{}) catch {
        if (structured_output) {
            try ctx.output.printJson(BackupResult{
                .success = false,
                .action = "diff",
                .message = "backup file not found",
            });
        } else {
            try ctx.output.err("Backup file not found: {s}", .{file});
        }
        return BackupError.BackupNotFound;
    };

    // Load backup issues
    const storage = @import("../storage/mod.zig");
    var backup_store = storage.IssueStore.init(allocator, backup_path);
    defer backup_store.deinit();
    backup_store.loadFromFile() catch {
        if (structured_output) {
            try ctx.output.printJson(BackupResult{
                .success = false,
                .action = "diff",
                .message = "failed to load backup file",
            });
        } else {
            try ctx.output.err("Failed to load backup file", .{});
        }
        return BackupError.BackupNotFound;
    };

    // Compare: count added, removed, modified
    var added: usize = 0;
    var removed: usize = 0;
    var modified: usize = 0;

    // Check current issues against backup
    for (ctx.store.issues.items) |current| {
        if (backup_store.getRef(current.id)) |backup| {
            // Issue exists in both - check if modified
            if (current.updated_at.value != backup.updated_at.value) {
                modified += 1;
            }
        } else {
            // Issue only in current
            added += 1;
        }
    }

    // Check backup issues not in current
    for (backup_store.issues.items) |backup| {
        if (ctx.store.getRef(backup.id) == null) {
            removed += 1;
        }
    }

    if (structured_output) {
        try ctx.output.printJson(BackupResult{
            .success = true,
            .action = "diff",
            .diff_added = added,
            .diff_removed = removed,
            .diff_modified = modified,
        });
    } else if (!quiet) {
        try ctx.output.println("Diff: current vs {s}", .{file});
        try ctx.output.print("  Added:    {d}\n", .{added});
        try ctx.output.print("  Removed:  {d}\n", .{removed});
        try ctx.output.print("  Modified: {d}\n", .{modified});
        if (added == 0 and removed == 0 and modified == 0) {
            try ctx.output.info("No differences found", .{});
        }
    }
}

fn runRestore(ctx: *CommandContext, file: []const u8, dry_run: bool, structured_output: bool, quiet: bool, allocator: std.mem.Allocator) !void {
    const beads_dir = std.fs.path.dirname(ctx.store.jsonl_path) orelse ".beads";
    const backup_path = try std.fs.path.join(allocator, &.{ beads_dir, file });
    defer allocator.free(backup_path);

    // Check if backup file exists
    std.fs.cwd().access(backup_path, .{}) catch {
        if (structured_output) {
            try ctx.output.printJson(BackupResult{
                .success = false,
                .action = "restore",
                .message = "backup file not found",
            });
        } else {
            try ctx.output.err("Backup file not found: {s}", .{file});
        }
        return BackupError.BackupNotFound;
    };

    // Load backup to count issues
    const storage = @import("../storage/mod.zig");
    var backup_store = storage.IssueStore.init(allocator, backup_path);
    defer backup_store.deinit();
    backup_store.loadFromFile() catch {
        if (structured_output) {
            try ctx.output.printJson(BackupResult{
                .success = false,
                .action = "restore",
                .message = "failed to load backup file",
            });
        } else {
            try ctx.output.err("Failed to load backup file", .{});
        }
        return BackupError.RestoreFailed;
    };

    const issue_count = backup_store.issues.items.len;

    if (dry_run) {
        if (structured_output) {
            try ctx.output.printJson(BackupResult{
                .success = true,
                .action = "restore",
                .restored_count = issue_count,
                .message = "dry run - no changes made",
            });
        } else if (!quiet) {
            try ctx.output.info("Would restore {d} issue(s) from {s}", .{ issue_count, file });
        }
        return;
    }

    // Perform the restore by copying backup over current
    const backup_content = std.fs.cwd().readFileAlloc(allocator, backup_path, 1024 * 1024 * 100) catch {
        if (structured_output) {
            try ctx.output.printJson(BackupResult{
                .success = false,
                .action = "restore",
                .message = "failed to read backup file",
            });
        } else {
            try ctx.output.err("Failed to read backup file", .{});
        }
        return BackupError.RestoreFailed;
    };
    defer allocator.free(backup_content);

    // Create backup of current before restoring
    const timestamp = std.time.timestamp();
    const pre_restore_backup = try std.fmt.allocPrint(allocator, "{s}.pre-restore.{d}", .{ ctx.store.jsonl_path, timestamp });
    defer allocator.free(pre_restore_backup);

    std.fs.cwd().copyFile(ctx.store.jsonl_path, std.fs.cwd(), pre_restore_backup, .{}) catch {};

    // Write backup content to current file
    const current_file = std.fs.cwd().createFile(ctx.store.jsonl_path, .{}) catch {
        if (structured_output) {
            try ctx.output.printJson(BackupResult{
                .success = false,
                .action = "restore",
                .message = "failed to write to current file",
            });
        } else {
            try ctx.output.err("Failed to write to current file", .{});
        }
        return BackupError.RestoreFailed;
    };
    defer current_file.close();
    current_file.writeAll(backup_content) catch {
        if (structured_output) {
            try ctx.output.printJson(BackupResult{
                .success = false,
                .action = "restore",
                .message = "failed to write backup content",
            });
        } else {
            try ctx.output.err("Failed to write backup content", .{});
        }
        return BackupError.RestoreFailed;
    };

    if (structured_output) {
        try ctx.output.printJson(BackupResult{
            .success = true,
            .action = "restore",
            .restored_count = issue_count,
        });
    } else if (!quiet) {
        try ctx.output.success("Restored {d} issue(s) from {s}", .{ issue_count, file });
    }
}

fn runPrune(ctx: *CommandContext, keep: u32, dry_run: bool, structured_output: bool, quiet: bool, allocator: std.mem.Allocator) !void {
    const beads_dir = std.fs.path.dirname(ctx.store.jsonl_path) orelse ".beads";

    var backups: std.ArrayListUnmanaged(BackupInfo) = .{};
    defer {
        for (backups.items) |b| allocator.free(b.filename);
        backups.deinit(allocator);
    }

    // Collect backup files
    var dir = std.fs.cwd().openDir(beads_dir, .{ .iterate = true }) catch |err| {
        if (err == error.FileNotFound) {
            if (structured_output) {
                try ctx.output.printJson(BackupResult{
                    .success = true,
                    .action = "prune",
                    .pruned_count = 0,
                    .message = "no backups to prune",
                });
            } else if (!quiet) {
                try ctx.output.info("No backups to prune", .{});
            }
            return;
        }
        return err;
    };
    defer dir.close();

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (std.mem.startsWith(u8, entry.name, "issues.jsonl.bak") or
            (std.mem.startsWith(u8, entry.name, "issues.") and
            std.mem.endsWith(u8, entry.name, ".jsonl") and
            !std.mem.eql(u8, entry.name, "issues.jsonl")))
        {
            const stat = dir.statFile(entry.name) catch continue;
            try backups.append(allocator, .{
                .filename = try allocator.dupe(u8, entry.name),
                .size = stat.size,
                .modified = @intCast(@divFloor(stat.mtime, std.time.ns_per_s)),
            });
        }
    }

    if (backups.items.len <= keep) {
        if (structured_output) {
            try ctx.output.printJson(BackupResult{
                .success = true,
                .action = "prune",
                .pruned_count = 0,
                .message = "nothing to prune",
            });
        } else if (!quiet) {
            try ctx.output.info("Only {d} backup(s) found, keeping all (threshold: {d})", .{ backups.items.len, keep });
        }
        return;
    }

    // Sort by modified time (newest first)
    std.mem.sortUnstable(BackupInfo, backups.items, {}, struct {
        fn lessThan(_: void, a: BackupInfo, b: BackupInfo) bool {
            return a.modified > b.modified;
        }
    }.lessThan);

    const to_prune = backups.items.len - keep;

    if (dry_run) {
        if (structured_output) {
            try ctx.output.printJson(BackupResult{
                .success = true,
                .action = "prune",
                .pruned_count = to_prune,
                .message = "dry run - no changes made",
            });
        } else if (!quiet) {
            try ctx.output.info("Would prune {d} backup(s), keeping {d} most recent", .{ to_prune, keep });
            for (backups.items[keep..]) |b| {
                try ctx.output.print("  Would delete: {s}\n", .{b.filename});
            }
        }
        return;
    }

    // Delete oldest backups
    var pruned: usize = 0;
    for (backups.items[keep..]) |b| {
        const full_path = try std.fs.path.join(allocator, &.{ beads_dir, b.filename });
        defer allocator.free(full_path);
        std.fs.cwd().deleteFile(full_path) catch continue;
        pruned += 1;
    }

    if (structured_output) {
        try ctx.output.printJson(BackupResult{
            .success = true,
            .action = "prune",
            .pruned_count = pruned,
        });
    } else if (!quiet) {
        try ctx.output.success("Pruned {d} backup(s), kept {d} most recent", .{ pruned, keep });
    }
}

fn runCreate(ctx: *CommandContext, structured_output: bool, quiet: bool, allocator: std.mem.Allocator) !void {
    const timestamp = std.time.timestamp();
    const backup_path = try std.fmt.allocPrint(allocator, "{s}.bak.{d}", .{ ctx.store.jsonl_path, timestamp });
    defer allocator.free(backup_path);

    // Copy current file to backup
    std.fs.cwd().copyFile(ctx.store.jsonl_path, std.fs.cwd(), backup_path, .{}) catch {
        if (structured_output) {
            try ctx.output.printJson(BackupResult{
                .success = false,
                .action = "create",
                .message = "failed to create backup",
            });
        } else {
            try ctx.output.err("Failed to create backup", .{});
        }
        return BackupError.CreateFailed;
    };

    const basename = std.fs.path.basename(backup_path);

    if (structured_output) {
        try ctx.output.printJson(BackupResult{
            .success = true,
            .action = "create",
            .created_path = backup_path,
        });
    } else if (!quiet) {
        try ctx.output.success("Created backup: {s}", .{basename});
    }
}

// --- Tests ---

test "BackupError enum exists" {
    const err: BackupError = BackupError.BackupNotFound;
    try std.testing.expect(err == BackupError.BackupNotFound);
}

test "BackupResult struct works" {
    const result = BackupResult{
        .success = true,
        .action = "list",
        .backup_count = 3,
    };
    try std.testing.expect(result.success);
    try std.testing.expectEqualStrings("list", result.action.?);
    try std.testing.expectEqual(@as(usize, 3), result.backup_count.?);
}

test "run detects uninitialized workspace" {
    const allocator = std.testing.allocator;

    const backup_args = args.BackupArgs{ .subcommand = .{ .list = {} } };
    const global = args.GlobalOptions{ .silent = true, .data_path = "/nonexistent/path" };

    const result = run(backup_args, global, allocator);
    try std.testing.expectError(BackupError.WorkspaceNotInitialized, result);
}

test "BackupInfo struct works" {
    const info = BackupInfo{
        .filename = "issues.jsonl.bak.123",
        .size = 1024,
        .modified = 1706540000,
    };
    try std.testing.expectEqualStrings("issues.jsonl.bak.123", info.filename);
    try std.testing.expectEqual(@as(u64, 1024), info.size);
}
