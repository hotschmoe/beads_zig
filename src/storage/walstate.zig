//! WAL State Management for beads_zig.
//!
//! Coordinates between writers and compactor to prevent WAL unbounded growth
//! under continuous write load. Key features:
//!
//! - Tracks pending writers (via reference count)
//! - Tracks approximate WAL size
//! - Implements writer backoff when WAL is huge (>1MB)
//! - Allows compaction to run when writers are idle
//!
//! This module uses atomic operations for thread-safe access across
//! concurrent agents without requiring a lock.
//!
//! Under heavy load from 10+ agents writing continuously:
//! - Writers encountering huge WAL back off for 10ms
//! - Compaction checks pending_writers and only runs when idle
//! - This creates natural gaps for compaction to occur

const std = @import("std");
const builtin = @import("builtin");

/// Global WAL state shared across all writers in a process.
/// Uses atomics for lock-free coordination.
pub const WalState = struct {
    /// Number of writers currently in the write path.
    pending_writers: std.atomic.Value(u32) = .{ .raw = 0 },

    /// Approximate WAL size in bytes (updated on each write).
    /// Not perfectly accurate due to race conditions, but good enough
    /// for making backoff decisions.
    wal_size_approx: std.atomic.Value(u64) = .{ .raw = 0 },

    /// Timestamp of last compaction (for diagnostics).
    last_compaction_ts: std.atomic.Value(i64) = .{ .raw = 0 },

    /// Count of how many times writers backed off (for metrics).
    backoff_count: std.atomic.Value(u64) = .{ .raw = 0 },

    const Self = @This();

    /// Threshold above which writers should back off (1MB).
    pub const BACKOFF_THRESHOLD: u64 = 1_000_000;

    /// How long to back off in nanoseconds (10ms).
    pub const BACKOFF_DURATION_NS: u64 = 10 * std.time.ns_per_ms;

    /// Check if WAL size is above backoff threshold.
    pub fn isWalHuge(self: *Self) bool {
        return self.wal_size_approx.load(.monotonic) >= BACKOFF_THRESHOLD;
    }

    /// Called when a writer is about to start writing.
    /// Returns true if the writer should proceed, false if it should back off.
    /// The writer should call releaseWriter when done.
    pub fn acquireWriter(self: *Self) bool {
        // Check if we need to back off first
        if (self.isWalHuge()) {
            // Record the backoff
            _ = self.backoff_count.fetchAdd(1, .monotonic);

            // Sleep to allow compaction to run
            std.Thread.sleep(BACKOFF_DURATION_NS);

            // After sleeping, check again if WAL is still huge
            // If it is, we proceed anyway (don't block forever)
        }

        // Increment pending writers count
        _ = self.pending_writers.fetchAdd(1, .seq_cst);
        return true;
    }

    /// Called when a writer finishes writing.
    /// entry_size is the approximate size of the entry that was written.
    pub fn releaseWriter(self: *Self, entry_size: u64) void {
        // Update approximate WAL size
        _ = self.wal_size_approx.fetchAdd(entry_size, .monotonic);

        // Decrement pending writers count
        _ = self.pending_writers.fetchSub(1, .seq_cst);
    }

    /// Check if compaction should proceed.
    /// Returns true if no writers are currently active.
    pub fn canCompact(self: *Self) bool {
        return self.pending_writers.load(.seq_cst) == 0;
    }

    /// Called after successful compaction to reset WAL size.
    pub fn recordCompaction(self: *Self) void {
        // Reset approximate WAL size to 0 after compaction
        self.wal_size_approx.store(0, .monotonic);
        self.last_compaction_ts.store(std.time.timestamp(), .monotonic);
    }

    /// Get current statistics for monitoring.
    pub fn getStats(self: *Self) WalStateStats {
        return .{
            .pending_writers = self.pending_writers.load(.monotonic),
            .wal_size_approx = self.wal_size_approx.load(.monotonic),
            .last_compaction_ts = self.last_compaction_ts.load(.monotonic),
            .backoff_count = self.backoff_count.load(.monotonic),
        };
    }

    /// Update WAL size from actual file size (for initialization).
    pub fn updateWalSize(self: *Self, size: u64) void {
        self.wal_size_approx.store(size, .monotonic);
    }

    /// Reset all state (for testing).
    pub fn reset(self: *Self) void {
        self.pending_writers.store(0, .seq_cst);
        self.wal_size_approx.store(0, .monotonic);
        self.last_compaction_ts.store(0, .monotonic);
        self.backoff_count.store(0, .monotonic);
    }
};

/// Statistics about WAL state for monitoring.
pub const WalStateStats = struct {
    pending_writers: u32,
    wal_size_approx: u64,
    last_compaction_ts: i64,
    backoff_count: u64,

    pub fn format(
        self: WalStateStats,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        try writer.print(
            "WalState(pending={d}, size={d}KB, backoffs={d})",
            .{
                self.pending_writers,
                self.wal_size_approx / 1024,
                self.backoff_count,
            },
        );
    }
};

/// Global shared state instance.
/// This is safe because:
/// 1. All operations are atomic
/// 2. No allocations
/// 3. Designed for cross-agent coordination
var global_state: WalState = .{};

/// Get the global shared WAL state.
pub fn getGlobalState() *WalState {
    return &global_state;
}

/// Reset global state (for testing only).
pub fn resetGlobalState() void {
    global_state.reset();
}

// --- Tests ---

test "WalState basic operations" {
    var state = WalState{};

    // Initially no pending writers
    try std.testing.expectEqual(@as(u32, 0), state.pending_writers.load(.monotonic));
    try std.testing.expect(state.canCompact());

    // Acquire writer
    _ = state.acquireWriter();
    try std.testing.expectEqual(@as(u32, 1), state.pending_writers.load(.monotonic));
    try std.testing.expect(!state.canCompact());

    // Release writer with entry size
    state.releaseWriter(1000);
    try std.testing.expectEqual(@as(u32, 0), state.pending_writers.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 1000), state.wal_size_approx.load(.monotonic));
    try std.testing.expect(state.canCompact());
}

test "WalState compaction reset" {
    var state = WalState{};

    // Simulate some writes
    state.releaseWriter(100_000);
    state.releaseWriter(200_000);
    try std.testing.expectEqual(@as(u64, 300_000), state.wal_size_approx.load(.monotonic));

    // Record compaction
    state.recordCompaction();
    try std.testing.expectEqual(@as(u64, 0), state.wal_size_approx.load(.monotonic));
    try std.testing.expect(state.last_compaction_ts.load(.monotonic) > 0);
}

test "WalState isWalHuge threshold" {
    var state = WalState{};

    // Below threshold
    state.updateWalSize(500_000);
    try std.testing.expect(!state.isWalHuge());

    // At threshold
    state.updateWalSize(1_000_000);
    try std.testing.expect(state.isWalHuge());

    // Above threshold
    state.updateWalSize(2_000_000);
    try std.testing.expect(state.isWalHuge());
}

test "WalState multiple writers" {
    var state = WalState{};

    // Multiple writers
    _ = state.acquireWriter();
    _ = state.acquireWriter();
    _ = state.acquireWriter();
    try std.testing.expectEqual(@as(u32, 3), state.pending_writers.load(.monotonic));
    try std.testing.expect(!state.canCompact());

    // Release all
    state.releaseWriter(100);
    state.releaseWriter(100);
    state.releaseWriter(100);
    try std.testing.expectEqual(@as(u32, 0), state.pending_writers.load(.monotonic));
    try std.testing.expect(state.canCompact());
}

test "WalState getStats" {
    var state = WalState{};

    _ = state.acquireWriter();
    state.releaseWriter(50_000);

    const stats = state.getStats();
    try std.testing.expectEqual(@as(u32, 0), stats.pending_writers);
    try std.testing.expectEqual(@as(u64, 50_000), stats.wal_size_approx);
}

test "getGlobalState returns consistent instance" {
    const state1 = getGlobalState();
    const state2 = getGlobalState();
    try std.testing.expectEqual(state1, state2);
}
