//! Generation number management for read/compact race safety.
//!
//! Prevents race conditions where a reader opens the WAL file and a compactor
//! truncates it mid-read. Generation numbers ensure readers see consistent state:
//!
//! 1. Each compaction increments the generation number
//! 2. Readers check generation before and after reading
//! 3. If generation changed during read, retry with new generation
//!
//! File layout:
//!   .beads/beads.generation  - Contains current generation number (u64)
//!   .beads/beads.wal.N       - WAL file for generation N

const std = @import("std");
const fs = std.fs;
const BeadsLock = @import("lock.zig").BeadsLock;
const test_util = @import("../test_util.zig");

pub const GenerationError = error{
    ReadFailed,
    WriteFailed,
    InvalidFormat,
    LockFailed,
    OutOfMemory,
};

/// Manages generation numbers for WAL file rotation.
pub const Generation = struct {
    beads_dir: []const u8,
    allocator: std.mem.Allocator,

    const Self = @This();

    /// File name for the generation number file.
    const GENERATION_FILE = "beads.generation";

    /// Minimum generation number (starts at 1, never 0).
    const MIN_GENERATION: u64 = 1;

    pub fn init(beads_dir: []const u8, allocator: std.mem.Allocator) Self {
        return .{
            .beads_dir = beads_dir,
            .allocator = allocator,
        };
    }

    /// Read the current generation number.
    /// Returns MIN_GENERATION if file doesn't exist (fresh install).
    pub fn read(self: *Self) GenerationError!u64 {
        const gen_path = std.fs.path.join(self.allocator, &.{ self.beads_dir, GENERATION_FILE }) catch return GenerationError.OutOfMemory;
        defer self.allocator.free(gen_path);

        const file = fs.cwd().openFile(gen_path, .{}) catch |err| switch (err) {
            error.FileNotFound => return MIN_GENERATION,
            else => return GenerationError.ReadFailed,
        };
        defer file.close();

        var buf: [32]u8 = undefined;
        const bytes_read = file.readAll(&buf) catch return GenerationError.ReadFailed;
        if (bytes_read == 0) return MIN_GENERATION;

        // Trim whitespace/newlines
        const content = std.mem.trim(u8, buf[0..bytes_read], " \t\n\r");
        if (content.len == 0) return MIN_GENERATION;

        return std.fmt.parseInt(u64, content, 10) catch return GenerationError.InvalidFormat;
    }

    /// Write the generation number atomically.
    /// Uses temp file + rename pattern for crash safety.
    pub fn write(self: *Self, generation: u64) GenerationError!void {
        const gen_path = std.fs.path.join(self.allocator, &.{ self.beads_dir, GENERATION_FILE }) catch return GenerationError.OutOfMemory;
        defer self.allocator.free(gen_path);

        const dir = fs.cwd();

        // Ensure parent directory exists
        dir.makePath(self.beads_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return GenerationError.WriteFailed,
        };

        // Write to temp file first
        var tmp_path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const tmp_path = std.fmt.bufPrint(&tmp_path_buf, "{s}.tmp.{d}", .{
            gen_path,
            std.time.milliTimestamp(),
        }) catch return GenerationError.WriteFailed;

        const tmp_file = dir.createFile(tmp_path, .{}) catch return GenerationError.WriteFailed;
        errdefer {
            tmp_file.close();
            dir.deleteFile(tmp_path) catch {};
        }

        // Write generation number
        var num_buf: [20]u8 = undefined;
        const num_str = std.fmt.bufPrint(&num_buf, "{d}\n", .{generation}) catch return GenerationError.WriteFailed;
        tmp_file.writeAll(num_str) catch return GenerationError.WriteFailed;

        // fsync for durability
        tmp_file.sync() catch return GenerationError.WriteFailed;
        tmp_file.close();

        // Atomic rename
        dir.rename(tmp_path, gen_path) catch return GenerationError.WriteFailed;
    }

    /// Increment generation atomically (under lock).
    /// Returns the new generation number.
    /// WARNING: This acquires a lock - do not call if you already hold the lock.
    pub fn increment(self: *Self, lock_path: []const u8) GenerationError!u64 {
        var lock = BeadsLock.acquire(lock_path) catch return GenerationError.LockFailed;
        defer lock.release();

        return self.incrementUnlocked();
    }

    /// Increment generation without acquiring a lock.
    /// Caller must already hold the exclusive lock.
    pub fn incrementUnlocked(self: *Self) GenerationError!u64 {
        const current = try self.read();
        const next = current + 1;
        try self.write(next);
        return next;
    }

    /// Get the WAL file path for a specific generation.
    pub fn walPath(self: *Self, generation: u64) ![]const u8 {
        return std.fmt.allocPrint(self.allocator, "{s}/beads.wal.{d}", .{ self.beads_dir, generation });
    }

    /// Get the WAL file path for the current generation.
    pub fn currentWalPath(self: *Self) ![]const u8 {
        const gen = try self.read();
        return self.walPath(gen);
    }

    /// Clean up old WAL files (keep only current and previous generation).
    /// Should be called after successful compaction.
    pub fn cleanupOldGenerations(self: *Self, current_gen: u64) void {
        if (current_gen <= 2) return; // Nothing to clean up

        // Delete WAL files older than current - 1
        const cleanup_gen = current_gen - 2;
        const wal_path = self.walPath(cleanup_gen) catch return;
        defer self.allocator.free(wal_path);

        fs.cwd().deleteFile(wal_path) catch {};
    }
};

// --- Tests ---

test "Generation.read returns MIN_GENERATION for missing file" {
    const allocator = std.testing.allocator;
    const test_dir = try test_util.createTestDir(allocator, "gen_missing");
    defer allocator.free(test_dir);
    defer test_util.cleanupTestDir(test_dir);

    var gen = Generation.init(test_dir, allocator);
    const value = try gen.read();
    try std.testing.expectEqual(@as(u64, 1), value);
}

test "Generation.write and read roundtrip" {
    const allocator = std.testing.allocator;
    const test_dir = try test_util.createTestDir(allocator, "gen_roundtrip");
    defer allocator.free(test_dir);
    defer test_util.cleanupTestDir(test_dir);

    var gen = Generation.init(test_dir, allocator);

    try gen.write(42);
    const value = try gen.read();
    try std.testing.expectEqual(@as(u64, 42), value);

    try gen.write(123456789);
    const value2 = try gen.read();
    try std.testing.expectEqual(@as(u64, 123456789), value2);
}

test "Generation.walPath generates correct paths" {
    const allocator = std.testing.allocator;

    var gen = Generation.init(".beads", allocator);

    const path1 = try gen.walPath(1);
    defer allocator.free(path1);
    try std.testing.expectEqualStrings(".beads/beads.wal.1", path1);

    const path2 = try gen.walPath(42);
    defer allocator.free(path2);
    try std.testing.expectEqualStrings(".beads/beads.wal.42", path2);
}
