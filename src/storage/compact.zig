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
const fs = std.fs;
const BeadsLock = @import("lock.zig").BeadsLock;
const Wal = @import("wal.zig").Wal;
const JsonlFile = @import("jsonl.zig").JsonlFile;
const IssueStore = @import("store.zig").IssueStore;
const Generation = @import("generation.zig").Generation;
const test_util = @import("../test_util.zig");

pub const CompactError = error{
    LockFailed,
    CompactionFailed,
    WriteError,
    AtomicRenameFailed,
    OutOfMemory,
};

/// Thresholds for automatic compaction.
pub const CompactionThresholds = struct {
    /// Maximum number of WAL entries before compaction.
    max_entries: usize = 100,
    /// Maximum WAL file size in bytes before compaction.
    max_bytes: u64 = 100 * 1024, // 100KB
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

    const Self = @This();

    pub fn init(beads_dir: []const u8, allocator: std.mem.Allocator) Self {
        return .{
            .beads_dir = beads_dir,
            .allocator = allocator,
            .thresholds = .{},
        };
    }

    pub fn initWithThresholds(beads_dir: []const u8, allocator: std.mem.Allocator, thresholds: CompactionThresholds) Self {
        return .{
            .beads_dir = beads_dir,
            .allocator = allocator,
            .thresholds = thresholds,
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

    /// Trigger compaction if WAL exceeds threshold.
    /// Returns true if compaction was performed.
    pub fn maybeCompact(self: *Self) !bool {
        const stats = try self.walStats();
        if (stats.needs_compaction) {
            try self.compact();
            return true;
        }
        return false;
    }

    /// Compact WAL into main file with generation-based safety.
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
    }

    /// Delete old generation's WAL file.
    fn deleteOldWal(self: *Self, old_gen: u64) void {
        var gen = Generation.init(self.beads_dir, self.allocator);
        const old_wal_path = gen.walPath(old_gen) catch return;
        defer self.allocator.free(old_wal_path);

        fs.cwd().deleteFile(old_wal_path) catch {};
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
        var wal = try Wal.init(test_dir, allocator);
        defer wal.deinit();

        const count = try wal.entryCount();
        try std.testing.expectEqual(@as(usize, 0), count);
    }
}
