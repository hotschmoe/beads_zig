//! WAL Compaction for beads_zig.
//!
//! Merges WAL entries into the main JSONL file when the WAL exceeds thresholds.
//! This consolidates state and keeps the WAL small for fast reads.
//!
//! Compaction flow (with generation-based safety):
//! 1. Acquire BeadsLock (exclusive)
//! 2. Load beads.jsonl into memory
//! 3. Replay current generation's WAL operations
//! 4. Write merged state to beads.jsonl.tmp
//! 5. fsync for durability
//! 6. Atomic rename over beads.jsonl
//! 7. Rotate to new generation (increment beads.generation, new beads.wal.N)
//! 8. Clean up old generation WAL files
//! 9. Release lock
//!
//! Generation-based rotation prevents reader/compactor races:
//! - Old WAL file remains readable during compaction
//! - New generation number signals readers to refresh
//! - Readers retry if generation changed during read

const std = @import("std");
const builtin = @import("builtin");
const fs = std.fs;
const BeadsLock = @import("lock.zig").BeadsLock;
const Wal = @import("wal.zig").Wal;
const JsonlFile = @import("jsonl.zig").JsonlFile;
const IssueStore = @import("store.zig").IssueStore;
const Generation = @import("generation.zig").Generation;
const walstate = @import("walstate.zig");
const test_util = @import("../test_util.zig");

/// Fsync a directory file descriptor for durability.
/// Unlike std.posix.fsync, this handles EINVAL gracefully since some filesystems
/// don't support fsync on directories. This is a best-effort operation.
fn fsyncDir(fd: std.posix.fd_t) void {
    if (builtin.os.tag == .windows) {
        // Windows: FlushFileBuffers doesn't work on directories
        return;
    }
    // Call fsync directly via the system interface, ignoring errors.
    // Some filesystems (e.g., btrfs with certain configs, NFS) may return EINVAL.
    // This is a best-effort durability enhancement.
    switch (builtin.os.tag) {
        .linux => {
            _ = std.os.linux.fsync(fd);
        },
        .macos, .ios, .tvos, .watchos, .visionos => {
            _ = std.c.fsync(fd);
        },
        .freebsd, .openbsd, .netbsd, .dragonfly => {
            _ = std.c.fsync(fd);
        },
        else => {
            // Unsupported platform, skip
        },
    }
}

/// Copy a file if it exists. Silently skip if source doesn't exist.
fn copyFileIfExists(dir: fs.Dir, src_path: []const u8, dst_path: []const u8) void {
    const src_file = dir.openFile(src_path, .{}) catch return;
    defer src_file.close();

    const dst_file = dir.createFile(dst_path, .{}) catch return;
    defer dst_file.close();

    // Read and write in chunks
    var buf: [8192]u8 = undefined;
    while (true) {
        const bytes_read = src_file.read(&buf) catch return;
        if (bytes_read == 0) break;
        dst_file.writeAll(buf[0..bytes_read]) catch return;
    }

    dst_file.sync() catch {};
}

pub const CompactError = error{
    LockFailed,
    CompactionFailed,
    WriteError,
    AtomicRenameFailed,
    OutOfMemory,
    WritersActive,
};

/// Thresholds for automatic compaction.
pub const CompactionThresholds = struct {
    /// Maximum number of WAL entries before compaction.
    max_entries: usize = 100,
    /// Maximum WAL file size in bytes before compaction.
    max_bytes: u64 = 100 * 1024, // 100KB
};

/// Configuration for pre-compaction backups.
pub const BackupConfig = struct {
    /// Whether to create backups before compaction.
    enabled: bool = true,
    /// Maximum number of backups to retain.
    max_backups: u8 = 5,
};

/// Statistics about the WAL for monitoring.
pub const WalStats = struct {
    entry_count: usize,
    file_size: u64,
    needs_compaction: bool,
};

/// Compactor handles WAL compaction operations.
pub const Compactor = struct {
    beads_dir: []const u8,
    allocator: std.mem.Allocator,
    thresholds: CompactionThresholds,
    backup_config: BackupConfig,

    const Self = @This();

    pub fn init(beads_dir: []const u8, allocator: std.mem.Allocator) Self {
        return .{
            .beads_dir = beads_dir,
            .allocator = allocator,
            .thresholds = .{},
            .backup_config = .{},
        };
    }

    pub fn initWithThresholds(beads_dir: []const u8, allocator: std.mem.Allocator, thresholds: CompactionThresholds) Self {
        return .{
            .beads_dir = beads_dir,
            .allocator = allocator,
            .thresholds = thresholds,
            .backup_config = .{},
        };
    }

    pub fn initWithConfig(beads_dir: []const u8, allocator: std.mem.Allocator, thresholds: CompactionThresholds, backup_config: BackupConfig) Self {
        return .{
            .beads_dir = beads_dir,
            .allocator = allocator,
            .thresholds = thresholds,
            .backup_config = backup_config,
        };
    }

    /// Get current WAL statistics.
    pub fn walStats(self: *Self) !WalStats {
        var wal = try Wal.init(self.beads_dir, self.allocator);
        defer wal.deinit();

        const entry_count = try wal.entryCount();
        const file_size = try wal.fileSize();

        return .{
            .entry_count = entry_count,
            .file_size = file_size,
            .needs_compaction = entry_count >= self.thresholds.max_entries or
                file_size >= self.thresholds.max_bytes,
        };
    }

    /// Trigger compaction if WAL exceeds threshold and no writers are active.
    /// Returns true if compaction was performed.
    /// Returns false if compaction not needed or writers are active.
    pub fn maybeCompact(self: *Self) !bool {
        const stats = try self.walStats();
        if (!stats.needs_compaction) {
            return false;
        }

        // Check if writers are active - don't compact if they are
        // This prevents compaction from starving under continuous load
        const state = walstate.getGlobalState();
        if (!state.canCompact()) {
            return false;
        }

        try self.compact();
        return true;
    }

    /// Trigger compaction if WAL exceeds threshold, waiting for writers to finish.
    /// Unlike maybeCompact, this will wait briefly for writers to clear.
    /// Returns true if compaction was performed.
    pub fn maybeCompactWithWait(self: *Self) !bool {
        const stats = try self.walStats();
        if (!stats.needs_compaction) {
            return false;
        }

        // Wait briefly for writers to finish (up to 100ms)
        const state = walstate.getGlobalState();
        var attempts: u32 = 0;
        while (attempts < 10) : (attempts += 1) {
            if (state.canCompact()) {
                try self.compact();
                return true;
            }
            std.Thread.sleep(10 * std.time.ns_per_ms);
        }

        // Writers still active after waiting
        return false;
    }

    /// Compact WAL into main file with generation-based safety.
    /// 0. Backup current state (if enabled)
    /// 1. Acquire BeadsLock (exclusive)
    /// 2. Load beads.jsonl into memory
    /// 3. Replay current generation's WAL operations
    /// 4. Write merged state to beads.jsonl.tmp
    /// 5. fsync for durability
    /// 6. Atomic rename over beads.jsonl
    /// 7. Rotate to new generation (creates new WAL file)
    /// 8. Clean up old WAL files
    /// 9. Release lock
    pub fn compact(self: *Self) !void {
        const lock_path = try std.fs.path.join(self.allocator, &.{ self.beads_dir, "beads.lock" });
        defer self.allocator.free(lock_path);

        const jsonl_path = try std.fs.path.join(self.allocator, &.{ self.beads_dir, "beads.jsonl" });
        defer self.allocator.free(jsonl_path);

        // 1. Acquire exclusive lock
        var lock = BeadsLock.acquire(lock_path) catch return CompactError.LockFailed;
        defer lock.release();

        // 0. Backup current state before destructive compaction
        // This enables recovery from compaction bugs.
        // See: concurrency_critique.md "Backup Before Destructive Operations"
        if (self.backup_config.enabled) {
            self.createBackup() catch {
                // Backup failure is non-fatal - log and continue
                // In production, you might want to make this configurable
            };
        }

        // 2. Load main file into memory
        var store = IssueStore.init(self.allocator, jsonl_path);
        defer store.deinit();

        store.loadFromFile() catch |err| switch (err) {
            error.FileNotFound => {}, // Empty main file is OK
            else => return CompactError.CompactionFailed,
        };

        // 3. Replay WAL operations (using current generation)
        var wal = try Wal.init(self.beads_dir, self.allocator);
        defer wal.deinit();

        const old_generation = wal.getGeneration();

        var replay_stats = wal.replay(&store) catch return CompactError.CompactionFailed;
        defer replay_stats.deinit(self.allocator);
        // Note: During compaction we proceed even if some replays failed,
        // since the remaining operations should still be compacted.

        // 4-6. Write merged state atomically
        try self.writeAtomically(jsonl_path, store.issues.items);

        // 7. Rotate to new generation (creates fresh WAL file, cleans up old ones)
        // This is the key change: instead of truncating the old WAL (which races
        // with readers), we rotate to a new generation. Readers will detect the
        // generation change and retry with the new WAL file.
        _ = wal.rotateGeneration() catch {
            // If rotation fails, fall back to traditional truncation
            // This maintains backwards compatibility but loses race safety
            wal.truncate() catch return CompactError.CompactionFailed;
            return;
        };

        // 8. Delete old generation's WAL file (safe now since generation incremented)
        // Readers that were mid-read will retry with new generation
        self.deleteOldWal(old_generation);

        // 9. Record compaction in global state to reset WAL size tracking
        const state = walstate.getGlobalState();
        state.recordCompaction();
    }

    /// Delete old generation's WAL file.
    fn deleteOldWal(self: *Self, old_gen: u64) void {
        var gen = Generation.init(self.beads_dir, self.allocator);
        const old_wal_path = gen.walPath(old_gen) catch return;
        defer self.allocator.free(old_wal_path);

        fs.cwd().deleteFile(old_wal_path) catch {};
    }

    /// Create a backup of current state before compaction.
    /// Backups are stored in .beads/backups/<timestamp>/
    /// This enables recovery from compaction bugs or data corruption.
    fn createBackup(self: *Self) !void {
        const dir = fs.cwd();

        // Create backups directory if it doesn't exist
        const backups_dir = try std.fs.path.join(self.allocator, &.{ self.beads_dir, "backups" });
        defer self.allocator.free(backups_dir);

        dir.makePath(backups_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };

        // Create timestamped backup directory
        const timestamp = std.time.timestamp();
        var backup_name_buf: [64]u8 = undefined;
        const backup_name = std.fmt.bufPrint(&backup_name_buf, "{d}", .{timestamp}) catch return;

        const backup_path = try std.fs.path.join(self.allocator, &.{ backups_dir, backup_name });
        defer self.allocator.free(backup_path);

        dir.makeDir(backup_path) catch |err| switch (err) {
            error.PathAlreadyExists => {}, // Timestamp collision (rare), just overwrite
            else => return err,
        };

        // Backup the main JSONL file
        const jsonl_path = try std.fs.path.join(self.allocator, &.{ self.beads_dir, "beads.jsonl" });
        defer self.allocator.free(jsonl_path);

        const backup_jsonl = try std.fs.path.join(self.allocator, &.{ backup_path, "beads.jsonl" });
        defer self.allocator.free(backup_jsonl);

        copyFileIfExists(dir, jsonl_path, backup_jsonl);

        // Backup the current WAL file
        var gen = Generation.init(self.beads_dir, self.allocator);
        const current_gen = gen.read() catch 1;
        const wal_path = try gen.walPath(current_gen);
        defer self.allocator.free(wal_path);

        var wal_filename_buf: [64]u8 = undefined;
        const wal_filename = std.fmt.bufPrint(&wal_filename_buf, "beads.wal.{d}", .{current_gen}) catch return;

        const backup_wal = try std.fs.path.join(self.allocator, &.{ backup_path, wal_filename });
        defer self.allocator.free(backup_wal);

        copyFileIfExists(dir, wal_path, backup_wal);

        // Prune old backups to keep only max_backups
        self.pruneBackups(backups_dir);
    }

    /// Prune old backups, keeping only the most recent max_backups.
    fn pruneBackups(self: *Self, backups_dir: []const u8) void {
        var dir_handle = fs.cwd().openDir(backups_dir, .{ .iterate = true }) catch return;
        defer dir_handle.close();

        // Collect all backup directory names (they are timestamps)
        var backups: std.ArrayListUnmanaged([]const u8) = .{};
        defer {
            for (backups.items) |name| {
                self.allocator.free(name);
            }
            backups.deinit(self.allocator);
        }

        var iter = dir_handle.iterate();
        while (iter.next() catch null) |entry| {
            if (entry.kind == .directory) {
                // Parse as timestamp to verify it's a backup dir
                _ = std.fmt.parseInt(i64, entry.name, 10) catch continue;
                const name_copy = self.allocator.dupe(u8, entry.name) catch continue;
                backups.append(self.allocator, name_copy) catch {
                    self.allocator.free(name_copy);
                    continue;
                };
            }
        }

        // Sort by timestamp (ascending)
        std.mem.sortUnstable([]const u8, backups.items, {}, struct {
            fn lessThan(_: void, a: []const u8, b: []const u8) bool {
                const ts_a = std.fmt.parseInt(i64, a, 10) catch return false;
                const ts_b = std.fmt.parseInt(i64, b, 10) catch return true;
                return ts_a < ts_b;
            }
        }.lessThan);

        // Remove oldest backups if we have too many
        const max_backups: usize = @intCast(self.backup_config.max_backups);
        if (backups.items.len > max_backups) {
            const to_remove = backups.items.len - max_backups;
            for (backups.items[0..to_remove]) |name| {
                const path = std.fs.path.join(self.allocator, &.{ backups_dir, name }) catch continue;
                defer self.allocator.free(path);

                // Delete all files in the backup directory first
                var backup_dir = fs.cwd().openDir(path, .{ .iterate = true }) catch continue;
                defer backup_dir.close();

                var file_iter = backup_dir.iterate();
                while (file_iter.next() catch null) |file_entry| {
                    backup_dir.deleteFile(file_entry.name) catch {};
                }

                // Then delete the directory itself
                fs.cwd().deleteDir(path) catch {};
            }
        }
    }

    /// Write issues to file atomically (temp file + fsync + rename).
    fn writeAtomically(self: *Self, target_path: []const u8, issues: []const @import("../models/issue.zig").Issue) !void {
        const dir = fs.cwd();

        // Create temp file path
        var tmp_path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const tmp_path = std.fmt.bufPrint(&tmp_path_buf, "{s}.tmp.{d}", .{
            target_path,
            std.time.milliTimestamp(),
        }) catch return CompactError.WriteError;

        // Write to temp file
        const tmp_file = dir.createFile(tmp_path, .{}) catch return CompactError.WriteError;
        errdefer {
            tmp_file.close();
            dir.deleteFile(tmp_path) catch {};
        }

        // Serialize and write each issue
        for (issues) |issue| {
            const json_bytes = std.json.Stringify.valueAlloc(self.allocator, issue, .{}) catch return CompactError.WriteError;
            defer self.allocator.free(json_bytes);

            tmp_file.writeAll(json_bytes) catch return CompactError.WriteError;
            tmp_file.writeAll("\n") catch return CompactError.WriteError;
        }

        // 5. fsync for durability
        tmp_file.sync() catch return CompactError.WriteError;
        tmp_file.close();

        // 6. Atomic rename
        dir.rename(tmp_path, target_path) catch return CompactError.AtomicRenameFailed;

        // 7. Fsync directory to ensure rename is durable
        // This ensures the file's new name survives an immediate system crash.
        if (std.fs.path.dirname(target_path)) |parent| {
            if (dir.openDir(parent, .{})) |parent_dir_handle| {
                var parent_dir = parent_dir_handle;
                defer parent_dir.close();
                fsyncDir(parent_dir.fd);
            } else |_| {}
        }
    }

    /// Force compaction regardless of thresholds.
    /// Use this for explicit sync operations.
    pub fn forceCompact(self: *Self) !void {
        try self.compact();
    }
};

// --- Tests ---

test "Compactor.init" {
    const allocator = std.testing.allocator;

    const compactor = Compactor.init(".beads", allocator);

    // Verify default thresholds
    try std.testing.expectEqual(@as(usize, 100), compactor.thresholds.max_entries);
    try std.testing.expectEqual(@as(u64, 100 * 1024), compactor.thresholds.max_bytes);
}

test "Compactor.initWithThresholds" {
    const allocator = std.testing.allocator;

    const compactor = Compactor.initWithThresholds(".beads", allocator, .{
        .max_entries = 50,
        .max_bytes = 50 * 1024,
    });

    try std.testing.expectEqual(@as(usize, 50), compactor.thresholds.max_entries);
    try std.testing.expectEqual(@as(u64, 50 * 1024), compactor.thresholds.max_bytes);
}

test "Compactor.walStats returns stats for empty WAL" {
    const allocator = std.testing.allocator;
    const test_dir = try test_util.createTestDir(allocator, "compact_stats_empty");
    defer allocator.free(test_dir);
    defer test_util.cleanupTestDir(test_dir);

    var compactor = Compactor.init(test_dir, allocator);
    const stats = try compactor.walStats();

    try std.testing.expectEqual(@as(usize, 0), stats.entry_count);
    try std.testing.expectEqual(@as(u64, 0), stats.file_size);
    try std.testing.expect(!stats.needs_compaction);
}

test "Compactor.walStats detects when compaction needed" {
    const allocator = std.testing.allocator;
    const test_dir = try test_util.createTestDir(allocator, "compact_stats_needed");
    defer allocator.free(test_dir);
    defer test_util.cleanupTestDir(test_dir);

    // Create WAL with some entries
    var wal = try Wal.init(test_dir, allocator);
    defer wal.deinit();

    const Issue = @import("../models/issue.zig").Issue;
    const issue = Issue.init("bd-test1", "Test Issue", 1706540000);

    // Add entries up to threshold
    for (0..5) |i| {
        try wal.appendEntry(.{
            .op = .add,
            .ts = 1706540000 + @as(i64, @intCast(i)),
            .id = "bd-test1",
            .data = issue,
        });
    }

    // Test with low threshold
    var compactor = Compactor.initWithThresholds(test_dir, allocator, .{
        .max_entries = 3,
        .max_bytes = 100 * 1024,
    });

    const stats = try compactor.walStats();
    try std.testing.expectEqual(@as(usize, 5), stats.entry_count);
    try std.testing.expect(stats.needs_compaction);
}

test "Compactor.maybeCompact skips when below threshold" {
    const allocator = std.testing.allocator;
    const test_dir = try test_util.createTestDir(allocator, "compact_skip");
    defer allocator.free(test_dir);
    defer test_util.cleanupTestDir(test_dir);

    var compactor = Compactor.init(test_dir, allocator);
    const compacted = try compactor.maybeCompact();

    try std.testing.expect(!compacted);
}

test "Compactor.compact merges WAL into main file" {
    const allocator = std.testing.allocator;
    const test_dir = try test_util.createTestDir(allocator, "compact_merge");
    defer allocator.free(test_dir);
    defer test_util.cleanupTestDir(test_dir);

    const jsonl_path = try std.fs.path.join(allocator, &.{ test_dir, "beads.jsonl" });
    defer allocator.free(jsonl_path);

    const Issue = @import("../models/issue.zig").Issue;

    // Create initial main file with one issue
    {
        var jsonl = JsonlFile.init(jsonl_path, allocator);
        const initial_issues = [_]Issue{
            Issue.init("bd-main1", "Main Issue", 1706540000),
        };
        try jsonl.writeAll(&initial_issues);
    }

    // Add entries to WAL
    {
        var wal = try Wal.init(test_dir, allocator);
        defer wal.deinit();

        const new_issue = Issue.init("bd-wal1", "WAL Issue", 1706540100);
        try wal.appendEntry(.{
            .op = .add,
            .ts = 1706540100,
            .id = "bd-wal1",
            .data = new_issue,
        });
    }

    // Compact
    {
        var compactor = Compactor.init(test_dir, allocator);
        try compactor.compact();
    }

    // Verify merged result
    {
        var jsonl = JsonlFile.init(jsonl_path, allocator);
        const issues = try jsonl.readAll();
        defer {
            for (issues) |*issue| {
                issue.deinit(allocator);
            }
            allocator.free(issues);
        }

        try std.testing.expectEqual(@as(usize, 2), issues.len);

        // Check both issues exist (order may vary)
        var found_main = false;
        var found_wal = false;
        for (issues) |issue| {
            if (std.mem.eql(u8, issue.id, "bd-main1")) found_main = true;
            if (std.mem.eql(u8, issue.id, "bd-wal1")) found_wal = true;
        }
        try std.testing.expect(found_main);
        try std.testing.expect(found_wal);
    }

    // Verify WAL was truncated
    {
        var wal = try Wal.init(test_dir, allocator);
        defer wal.deinit();

        const count = try wal.entryCount();
        try std.testing.expectEqual(@as(usize, 0), count);
    }
}

test "Compactor.compact handles close operations" {
    const allocator = std.testing.allocator;
    const test_dir = try test_util.createTestDir(allocator, "compact_close");
    defer allocator.free(test_dir);
    defer test_util.cleanupTestDir(test_dir);

    const jsonl_path = try std.fs.path.join(allocator, &.{ test_dir, "beads.jsonl" });
    defer allocator.free(jsonl_path);

    const Issue = @import("../models/issue.zig").Issue;

    // Create main file with open issue
    {
        var jsonl = JsonlFile.init(jsonl_path, allocator);
        const issues = [_]Issue{
            Issue.init("bd-close1", "To Close", 1706540000),
        };
        try jsonl.writeAll(&issues);
    }

    // Add close operation to WAL
    {
        var wal = try Wal.init(test_dir, allocator);
        defer wal.deinit();

        try wal.appendEntry(.{
            .op = .close,
            .ts = 1706540100,
            .id = "bd-close1",
            .data = null,
        });
    }

    // Compact
    {
        var compactor = Compactor.init(test_dir, allocator);
        try compactor.compact();
    }

    // Verify issue was closed
    {
        var jsonl = JsonlFile.init(jsonl_path, allocator);
        const issues = try jsonl.readAll();
        defer {
            for (issues) |*issue| {
                issue.deinit(allocator);
            }
            allocator.free(issues);
        }

        try std.testing.expectEqual(@as(usize, 1), issues.len);

        const Status = @import("../models/status.zig").Status;
        const issue_status: Status = issues[0].status;
        try std.testing.expect(issue_status == .closed);
    }
}

test "Compactor.compact handles empty main file" {
    const allocator = std.testing.allocator;
    const test_dir = try test_util.createTestDir(allocator, "compact_empty_main");
    defer allocator.free(test_dir);
    defer test_util.cleanupTestDir(test_dir);

    const jsonl_path = try std.fs.path.join(allocator, &.{ test_dir, "beads.jsonl" });
    defer allocator.free(jsonl_path);

    const Issue = @import("../models/issue.zig").Issue;

    // Add entry to WAL (no main file)
    {
        var wal = try Wal.init(test_dir, allocator);
        defer wal.deinit();

        const issue = Issue.init("bd-new1", "New Issue", 1706540000);
        try wal.appendEntry(.{
            .op = .add,
            .ts = 1706540000,
            .id = "bd-new1",
            .data = issue,
        });
    }

    // Compact
    {
        var compactor = Compactor.init(test_dir, allocator);
        try compactor.compact();
    }

    // Verify main file was created with WAL content
    {
        var jsonl = JsonlFile.init(jsonl_path, allocator);
        const issues = try jsonl.readAll();
        defer {
            for (issues) |*issue| {
                issue.deinit(allocator);
            }
            allocator.free(issues);
        }

        try std.testing.expectEqual(@as(usize, 1), issues.len);
        try std.testing.expectEqualStrings("bd-new1", issues[0].id);
    }
}

test "Compactor.maybeCompact triggers at threshold" {
    const allocator = std.testing.allocator;
    const test_dir = try test_util.createTestDir(allocator, "compact_threshold");
    defer allocator.free(test_dir);
    defer test_util.cleanupTestDir(test_dir);

    const Issue = @import("../models/issue.zig").Issue;

    // Add entries to WAL
    {
        var wal = try Wal.init(test_dir, allocator);
        defer wal.deinit();

        for (0..5) |i| {
            var id_buf: [32]u8 = undefined;
            const id = std.fmt.bufPrint(&id_buf, "bd-test{d}", .{i}) catch unreachable;

            const issue = Issue.init(id, "Test Issue", 1706540000 + @as(i64, @intCast(i)));
            try wal.appendEntry(.{
                .op = .add,
                .ts = 1706540000 + @as(i64, @intCast(i)),
                .id = id,
                .data = issue,
            });
        }
    }

    // Test with low threshold that should trigger
    var compactor = Compactor.initWithThresholds(test_dir, allocator, .{
        .max_entries = 3,
        .max_bytes = 100 * 1024,
    });

    const compacted = try compactor.maybeCompact();
    try std.testing.expect(compacted);

    // Verify WAL was truncated
    {
        var wal_check = try Wal.init(test_dir, allocator);
        defer wal_check.deinit();

        const count = try wal_check.entryCount();
        try std.testing.expectEqual(@as(usize, 0), count);
    }
}

test "Compactor.compact creates backup before compaction" {
    const allocator = std.testing.allocator;
    const test_dir = try test_util.createTestDir(allocator, "compact_backup");
    defer allocator.free(test_dir);
    defer test_util.cleanupTestDir(test_dir);

    const jsonl_path = try std.fs.path.join(allocator, &.{ test_dir, "beads.jsonl" });
    defer allocator.free(jsonl_path);

    const Issue = @import("../models/issue.zig").Issue;

    // Create initial main file with one issue
    {
        var jsonl = JsonlFile.init(jsonl_path, allocator);
        const initial_issues = [_]Issue{
            Issue.init("bd-backup1", "Backup Test", 1706540000),
        };
        try jsonl.writeAll(&initial_issues);
    }

    // Add entries to WAL
    {
        var wal_inst = try Wal.init(test_dir, allocator);
        defer wal_inst.deinit();

        const new_issue = Issue.init("bd-backup2", "WAL Issue", 1706540100);
        try wal_inst.appendEntry(.{
            .op = .add,
            .ts = 1706540100,
            .id = "bd-backup2",
            .data = new_issue,
        });
    }

    // Compact with backup enabled (default)
    {
        var compactor = Compactor.init(test_dir, allocator);
        try compactor.compact();
    }

    // Verify backup directory was created
    const backups_path = try std.fs.path.join(allocator, &.{ test_dir, "backups" });
    defer allocator.free(backups_path);

    var backups_dir = try fs.cwd().openDir(backups_path, .{ .iterate = true });
    defer backups_dir.close();

    // Count backup directories
    var backup_count: usize = 0;
    var iter = backups_dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind == .directory) {
            backup_count += 1;
        }
    }

    // Should have exactly one backup
    try std.testing.expect(backup_count >= 1);
}

test "Compactor.compact skips backup when disabled" {
    const allocator = std.testing.allocator;
    const test_dir = try test_util.createTestDir(allocator, "compact_no_backup");
    defer allocator.free(test_dir);
    defer test_util.cleanupTestDir(test_dir);

    const jsonl_path = try std.fs.path.join(allocator, &.{ test_dir, "beads.jsonl" });
    defer allocator.free(jsonl_path);

    const Issue = @import("../models/issue.zig").Issue;

    // Create initial main file
    {
        var jsonl = JsonlFile.init(jsonl_path, allocator);
        const initial_issues = [_]Issue{
            Issue.init("bd-nobackup1", "No Backup Test", 1706540000),
        };
        try jsonl.writeAll(&initial_issues);
    }

    // Add entry to WAL
    {
        var wal_inst = try Wal.init(test_dir, allocator);
        defer wal_inst.deinit();

        const new_issue = Issue.init("bd-nobackup2", "WAL Issue", 1706540100);
        try wal_inst.appendEntry(.{
            .op = .add,
            .ts = 1706540100,
            .id = "bd-nobackup2",
            .data = new_issue,
        });
    }

    // Compact with backup disabled
    var compactor = Compactor.initWithConfig(test_dir, allocator, .{}, .{
        .enabled = false,
        .max_backups = 5,
    });
    try compactor.compact();

    // Verify backup directory was NOT created
    const backups_path = try std.fs.path.join(allocator, &.{ test_dir, "backups" });
    defer allocator.free(backups_path);

    const backups_exists = blk: {
        _ = fs.cwd().openDir(backups_path, .{}) catch break :blk false;
        break :blk true;
    };

    try std.testing.expect(!backups_exists);
}
