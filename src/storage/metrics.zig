//! Lock contention and transaction metrics for beads_zig.
//!
//! Tracks lock acquisition statistics for debugging concurrency issues
//! in multi-agent scenarios. Metrics are process-local (not persisted).
//!
//! Usage:
//!   - Metrics are accumulated in a global atomic struct
//!   - Use getMetrics() to read current values
//!   - Use resetMetrics() to clear counters
//!   - The `bz metrics` command reports these statistics

const std = @import("std");

/// Lock contention metrics.
/// All fields are atomic for safe concurrent access.
pub const LockMetrics = struct {
    /// Total number of lock acquisitions (successful).
    lock_acquisitions: u64 = 0,
    /// Total nanoseconds spent waiting for locks.
    lock_wait_total_ns: u64 = 0,
    /// Total nanoseconds locks were held.
    lock_hold_total_ns: u64 = 0,
    /// Number of times lock acquisition had to wait (contention).
    lock_contentions: u64 = 0,
    /// Maximum wait time observed (nanoseconds).
    max_wait_ns: u64 = 0,
    /// Maximum hold time observed (nanoseconds).
    max_hold_ns: u64 = 0,
    /// Number of lock timeouts.
    lock_timeouts: u64 = 0,
    /// Number of stale locks broken.
    stale_locks_broken: u64 = 0,

    /// Calculate average wait time in nanoseconds.
    pub fn avgWaitNs(self: LockMetrics) u64 {
        if (self.lock_acquisitions == 0) return 0;
        return self.lock_wait_total_ns / self.lock_acquisitions;
    }

    /// Calculate average hold time in nanoseconds.
    pub fn avgHoldNs(self: LockMetrics) u64 {
        if (self.lock_acquisitions == 0) return 0;
        return self.lock_hold_total_ns / self.lock_acquisitions;
    }

    /// Calculate contention rate as percentage (0-100).
    pub fn contentionRate(self: LockMetrics) f64 {
        if (self.lock_acquisitions == 0) return 0.0;
        return (@as(f64, @floatFromInt(self.lock_contentions)) / @as(f64, @floatFromInt(self.lock_acquisitions))) * 100.0;
    }

    /// Convert nanoseconds to milliseconds (floating point).
    pub fn nsToMs(ns: u64) f64 {
        return @as(f64, @floatFromInt(ns)) / 1_000_000.0;
    }

    /// Format metrics as human-readable string.
    pub fn format(self: LockMetrics, allocator: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(allocator,
            \\Lock Contention Metrics
            \\-----------------------
            \\Acquisitions:     {d}
            \\Contentions:      {d} ({d:.1}%)
            \\Timeouts:         {d}
            \\Stale locks:      {d}
            \\
            \\Wait time (total): {d:.2} ms
            \\Wait time (avg):   {d:.3} ms
            \\Wait time (max):   {d:.3} ms
            \\
            \\Hold time (total): {d:.2} ms
            \\Hold time (avg):   {d:.3} ms
            \\Hold time (max):   {d:.3} ms
        , .{
            self.lock_acquisitions,
            self.lock_contentions,
            self.contentionRate(),
            self.lock_timeouts,
            self.stale_locks_broken,
            nsToMs(self.lock_wait_total_ns),
            nsToMs(self.avgWaitNs()),
            nsToMs(self.max_wait_ns),
            nsToMs(self.lock_hold_total_ns),
            nsToMs(self.avgHoldNs()),
            nsToMs(self.max_hold_ns),
        });
    }

    /// Convert to JSON-serializable struct.
    pub fn toJson(self: LockMetrics) JsonMetrics {
        return .{
            .lock_acquisitions = self.lock_acquisitions,
            .lock_contentions = self.lock_contentions,
            .lock_timeouts = self.lock_timeouts,
            .stale_locks_broken = self.stale_locks_broken,
            .lock_wait_total_ms = nsToMs(self.lock_wait_total_ns),
            .lock_wait_avg_ms = nsToMs(self.avgWaitNs()),
            .lock_wait_max_ms = nsToMs(self.max_wait_ns),
            .lock_hold_total_ms = nsToMs(self.lock_hold_total_ns),
            .lock_hold_avg_ms = nsToMs(self.avgHoldNs()),
            .lock_hold_max_ms = nsToMs(self.max_hold_ns),
            .contention_rate_percent = self.contentionRate(),
        };
    }
};

/// JSON-friendly metrics structure for --json output.
pub const JsonMetrics = struct {
    lock_acquisitions: u64,
    lock_contentions: u64,
    lock_timeouts: u64,
    stale_locks_broken: u64,
    lock_wait_total_ms: f64,
    lock_wait_avg_ms: f64,
    lock_wait_max_ms: f64,
    lock_hold_total_ms: f64,
    lock_hold_avg_ms: f64,
    lock_hold_max_ms: f64,
    contention_rate_percent: f64,
};

/// Atomic metrics storage for thread-safe access.
pub const AtomicMetrics = struct {
    lock_acquisitions: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    lock_wait_total_ns: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    lock_hold_total_ns: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    lock_contentions: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    max_wait_ns: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    max_hold_ns: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    lock_timeouts: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    stale_locks_broken: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    /// Record a successful lock acquisition.
    pub fn recordAcquisition(self: *AtomicMetrics, wait_ns: u64, had_contention: bool) void {
        _ = self.lock_acquisitions.fetchAdd(1, .monotonic);
        _ = self.lock_wait_total_ns.fetchAdd(wait_ns, .monotonic);

        if (had_contention) {
            _ = self.lock_contentions.fetchAdd(1, .monotonic);
        }

        // Update max wait time (atomic compare-and-swap loop)
        var current_max = self.max_wait_ns.load(.monotonic);
        while (wait_ns > current_max) {
            const result = self.max_wait_ns.cmpxchgWeak(current_max, wait_ns, .monotonic, .monotonic);
            if (result) |old| {
                current_max = old;
            } else {
                break;
            }
        }
    }

    /// Record lock release with hold duration.
    pub fn recordRelease(self: *AtomicMetrics, hold_ns: u64) void {
        _ = self.lock_hold_total_ns.fetchAdd(hold_ns, .monotonic);

        // Update max hold time
        var current_max = self.max_hold_ns.load(.monotonic);
        while (hold_ns > current_max) {
            const result = self.max_hold_ns.cmpxchgWeak(current_max, hold_ns, .monotonic, .monotonic);
            if (result) |old| {
                current_max = old;
            } else {
                break;
            }
        }
    }

    /// Record a lock timeout.
    pub fn recordTimeout(self: *AtomicMetrics) void {
        _ = self.lock_timeouts.fetchAdd(1, .monotonic);
    }

    /// Record breaking a stale lock.
    pub fn recordStaleLockBroken(self: *AtomicMetrics) void {
        _ = self.stale_locks_broken.fetchAdd(1, .monotonic);
    }

    /// Get current metrics snapshot.
    pub fn snapshot(self: *AtomicMetrics) LockMetrics {
        return .{
            .lock_acquisitions = self.lock_acquisitions.load(.monotonic),
            .lock_wait_total_ns = self.lock_wait_total_ns.load(.monotonic),
            .lock_hold_total_ns = self.lock_hold_total_ns.load(.monotonic),
            .lock_contentions = self.lock_contentions.load(.monotonic),
            .max_wait_ns = self.max_wait_ns.load(.monotonic),
            .max_hold_ns = self.max_hold_ns.load(.monotonic),
            .lock_timeouts = self.lock_timeouts.load(.monotonic),
            .stale_locks_broken = self.stale_locks_broken.load(.monotonic),
        };
    }

    /// Reset all metrics to zero.
    pub fn reset(self: *AtomicMetrics) void {
        self.lock_acquisitions.store(0, .monotonic);
        self.lock_wait_total_ns.store(0, .monotonic);
        self.lock_hold_total_ns.store(0, .monotonic);
        self.lock_contentions.store(0, .monotonic);
        self.max_wait_ns.store(0, .monotonic);
        self.max_hold_ns.store(0, .monotonic);
        self.lock_timeouts.store(0, .monotonic);
        self.stale_locks_broken.store(0, .monotonic);
    }
};

/// Global metrics instance.
/// Process-local, not persisted across restarts.
pub var global_metrics: AtomicMetrics = .{};

/// Get current metrics snapshot.
pub fn getMetrics() LockMetrics {
    return global_metrics.snapshot();
}

/// Reset all metrics to zero.
pub fn resetMetrics() void {
    global_metrics.reset();
}

/// Record a successful lock acquisition.
pub fn recordAcquisition(wait_ns: u64, had_contention: bool) void {
    global_metrics.recordAcquisition(wait_ns, had_contention);
}

/// Record lock release.
pub fn recordRelease(hold_ns: u64) void {
    global_metrics.recordRelease(hold_ns);
}

/// Record a lock timeout.
pub fn recordTimeout() void {
    global_metrics.recordTimeout();
}

/// Record breaking a stale lock.
pub fn recordStaleLockBroken() void {
    global_metrics.recordStaleLockBroken();
}

// --- Tests ---

test "LockMetrics.avgWaitNs handles zero acquisitions" {
    const metrics = LockMetrics{};
    try std.testing.expectEqual(@as(u64, 0), metrics.avgWaitNs());
}

test "LockMetrics.avgWaitNs calculates correctly" {
    const metrics = LockMetrics{
        .lock_acquisitions = 10,
        .lock_wait_total_ns = 1000,
    };
    try std.testing.expectEqual(@as(u64, 100), metrics.avgWaitNs());
}

test "LockMetrics.contentionRate calculates correctly" {
    const metrics = LockMetrics{
        .lock_acquisitions = 100,
        .lock_contentions = 25,
    };
    try std.testing.expectApproxEqAbs(@as(f64, 25.0), metrics.contentionRate(), 0.01);
}

test "LockMetrics.nsToMs converts correctly" {
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), LockMetrics.nsToMs(1_000_000), 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 0.001), LockMetrics.nsToMs(1000), 0.0001);
}

test "AtomicMetrics.recordAcquisition updates counters" {
    var metrics = AtomicMetrics{};

    metrics.recordAcquisition(1000, false);
    try std.testing.expectEqual(@as(u64, 1), metrics.lock_acquisitions.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 0), metrics.lock_contentions.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 1000), metrics.lock_wait_total_ns.load(.monotonic));

    metrics.recordAcquisition(2000, true);
    try std.testing.expectEqual(@as(u64, 2), metrics.lock_acquisitions.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 1), metrics.lock_contentions.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 3000), metrics.lock_wait_total_ns.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 2000), metrics.max_wait_ns.load(.monotonic));
}

test "AtomicMetrics.recordRelease updates hold time" {
    var metrics = AtomicMetrics{};

    metrics.recordRelease(5000);
    try std.testing.expectEqual(@as(u64, 5000), metrics.lock_hold_total_ns.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 5000), metrics.max_hold_ns.load(.monotonic));

    metrics.recordRelease(3000);
    try std.testing.expectEqual(@as(u64, 8000), metrics.lock_hold_total_ns.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 5000), metrics.max_hold_ns.load(.monotonic)); // max unchanged
}

test "AtomicMetrics.reset clears all counters" {
    var metrics = AtomicMetrics{};

    metrics.recordAcquisition(1000, true);
    metrics.recordRelease(2000);
    metrics.recordTimeout();
    metrics.recordStaleLockBroken();

    metrics.reset();

    const snapshot = metrics.snapshot();
    try std.testing.expectEqual(@as(u64, 0), snapshot.lock_acquisitions);
    try std.testing.expectEqual(@as(u64, 0), snapshot.lock_contentions);
    try std.testing.expectEqual(@as(u64, 0), snapshot.lock_timeouts);
    try std.testing.expectEqual(@as(u64, 0), snapshot.stale_locks_broken);
}

test "global_metrics functions work" {
    resetMetrics();

    recordAcquisition(500, false);
    recordRelease(1000);

    const m = getMetrics();
    try std.testing.expectEqual(@as(u64, 1), m.lock_acquisitions);
    try std.testing.expectEqual(@as(u64, 500), m.lock_wait_total_ns);
    try std.testing.expectEqual(@as(u64, 1000), m.lock_hold_total_ns);

    resetMetrics();
    const m2 = getMetrics();
    try std.testing.expectEqual(@as(u64, 0), m2.lock_acquisitions);
}

test "LockMetrics.format produces output" {
    const metrics = LockMetrics{
        .lock_acquisitions = 100,
        .lock_contentions = 10,
        .lock_wait_total_ns = 50_000_000, // 50ms
        .lock_hold_total_ns = 100_000_000, // 100ms
        .max_wait_ns = 5_000_000, // 5ms
        .max_hold_ns = 10_000_000, // 10ms
    };

    const allocator = std.testing.allocator;
    const output = try metrics.format(allocator);
    defer allocator.free(output);

    try std.testing.expect(std.mem.indexOf(u8, output, "Acquisitions:") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Contentions:") != null);
}

test "LockMetrics.toJson produces correct structure" {
    const metrics = LockMetrics{
        .lock_acquisitions = 50,
        .lock_contentions = 5,
        .lock_wait_total_ns = 10_000_000, // 10ms
    };

    const json = metrics.toJson();
    try std.testing.expectEqual(@as(u64, 50), json.lock_acquisitions);
    try std.testing.expectEqual(@as(u64, 5), json.lock_contentions);
    try std.testing.expectApproxEqAbs(@as(f64, 10.0), json.lock_wait_total_ms, 0.01);
}
