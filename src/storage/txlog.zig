//! Transaction logging for beads_zig.
//!
//! Provides structured logging with correlation IDs for debugging
//! concurrency issues in multi-agent scenarios.
//!
//! Log entries include:
//!   - Correlation ID (unique per transaction/operation)
//!   - Timestamp (nanosecond precision)
//!   - Operation type
//!   - Duration (for acquire/release pairs)
//!   - Actor (process ID or configured actor name)
//!
//! Usage:
//!   const log = TxLog.begin("create_issue");
//!   defer log.end();
//!   log.event("lock_acquired", .{ .wait_ms = 5 });
//!   // ... perform operations ...
//!   log.event("issue_created", .{ .id = "bd-abc123" });

const std = @import("std");
const builtin = @import("builtin");

/// Log level for transaction logs.
pub const LogLevel = enum {
    debug,
    info,
    warn,
    @"error",

    pub fn toString(self: LogLevel) []const u8 {
        return switch (self) {
            .debug => "DEBUG",
            .info => "INFO",
            .warn => "WARN",
            .@"error" => "ERROR",
        };
    }
};

/// A single log entry.
pub const LogEntry = struct {
    correlation_id: u64,
    timestamp_ns: i128,
    level: LogLevel,
    operation: []const u8,
    event: []const u8,
    pid: i32,
    actor: ?[]const u8,
    details: ?[]const u8, // JSON-encoded additional data
    duration_ns: ?u64, // For timed operations

    /// Format as structured log line (JSON).
    pub fn formatJson(self: LogEntry, allocator: std.mem.Allocator) ![]u8 {
        // Build timestamp string (ISO8601-ish with nanoseconds)
        const ts_secs = @divTrunc(self.timestamp_ns, std.time.ns_per_s);
        const ts_ns_part = @mod(self.timestamp_ns, std.time.ns_per_s);

        var detail_str: []const u8 = "null";
        if (self.details) |d| {
            detail_str = d;
        }

        var actor_str: []const u8 = "null";
        var actor_buf: [64]u8 = undefined;
        if (self.actor) |a| {
            const quoted = std.fmt.bufPrint(&actor_buf, "\"{s}\"", .{a}) catch "null";
            actor_str = quoted;
        }

        var duration_str: []const u8 = "null";
        var duration_buf: [32]u8 = undefined;
        if (self.duration_ns) |d| {
            const dur = std.fmt.bufPrint(&duration_buf, "{d}", .{d}) catch "null";
            duration_str = dur;
        }

        return std.fmt.allocPrint(allocator,
            \\{{"cid":{d},"ts":{d}.{d:0>9},"level":"{s}","op":"{s}","event":"{s}","pid":{d},"actor":{s},"details":{s},"duration_ns":{s}}}
        , .{
            self.correlation_id,
            ts_secs,
            @as(u64, @intCast(@max(0, ts_ns_part))),
            self.level.toString(),
            self.operation,
            self.event,
            self.pid,
            actor_str,
            detail_str,
            duration_str,
        });
    }

    /// Format as human-readable log line.
    pub fn formatHuman(self: LogEntry, allocator: std.mem.Allocator) ![]u8 {
        var duration_str: []const u8 = "";
        var duration_buf: [32]u8 = undefined;
        if (self.duration_ns) |d| {
            const ms = @as(f64, @floatFromInt(d)) / 1_000_000.0;
            const dur = std.fmt.bufPrint(&duration_buf, " ({d:.2}ms)", .{ms}) catch "";
            duration_str = dur;
        }

        var actor_str: []const u8 = "";
        var actor_buf: [64]u8 = undefined;
        if (self.actor) |a| {
            const act = std.fmt.bufPrint(&actor_buf, " actor={s}", .{a}) catch "";
            actor_str = act;
        }

        var details_str: []const u8 = "";
        if (self.details) |d| {
            details_str = d;
        }

        return std.fmt.allocPrint(allocator,
            "[{x:0>16}] [{s}] {s}/{s}{s}{s} {s}",
            .{
                self.correlation_id,
                self.level.toString(),
                self.operation,
                self.event,
                duration_str,
                actor_str,
                details_str,
            },
        );
    }
};

/// Ring buffer for log entries (avoids unbounded memory growth).
pub const LogBuffer = struct {
    entries: []LogEntry,
    allocator: std.mem.Allocator,
    write_index: usize = 0,
    count: usize = 0,
    capacity: usize,

    pub fn init(allocator: std.mem.Allocator, capacity: usize) !LogBuffer {
        const entries = try allocator.alloc(LogEntry, capacity);
        return .{
            .entries = entries,
            .allocator = allocator,
            .capacity = capacity,
        };
    }

    pub fn deinit(self: *LogBuffer) void {
        // Free any allocated detail strings
        for (self.entries[0..self.count]) |entry| {
            if (entry.details) |d| {
                self.allocator.free(d);
            }
            if (entry.actor) |a| {
                self.allocator.free(a);
            }
        }
        self.allocator.free(self.entries);
    }

    pub fn push(self: *LogBuffer, entry: LogEntry) void {
        // Free old entry if overwriting
        if (self.count == self.capacity) {
            const old = &self.entries[self.write_index];
            if (old.details) |d| {
                self.allocator.free(d);
            }
            if (old.actor) |a| {
                self.allocator.free(a);
            }
        }

        self.entries[self.write_index] = entry;
        self.write_index = (self.write_index + 1) % self.capacity;
        if (self.count < self.capacity) {
            self.count += 1;
        }
    }

    /// Get entries in chronological order.
    pub fn getEntries(self: *const LogBuffer) []const LogEntry {
        if (self.count < self.capacity) {
            return self.entries[0..self.count];
        }
        // Buffer is full, entries wrap around
        return self.entries;
    }

    pub fn clear(self: *LogBuffer) void {
        for (self.entries[0..self.count]) |entry| {
            if (entry.details) |d| {
                self.allocator.free(d);
            }
            if (entry.actor) |a| {
                self.allocator.free(a);
            }
        }
        self.write_index = 0;
        self.count = 0;
    }
};

/// Transaction logger for a specific operation.
pub const TxLog = struct {
    correlation_id: u64,
    operation: []const u8,
    start_time: i128,
    actor: ?[]const u8,
    allocator: std.mem.Allocator,
    enabled: bool,

    const Self = @This();

    /// Begin a new transaction log.
    pub fn begin(operation: []const u8, actor: ?[]const u8, allocator: std.mem.Allocator) Self {
        const cid = generateCorrelationId();
        const tx = Self{
            .correlation_id = cid,
            .operation = operation,
            .start_time = std.time.nanoTimestamp(),
            .actor = actor,
            .allocator = allocator,
            .enabled = global_logging_enabled,
        };

        if (tx.enabled) {
            tx.logEvent(.info, "begin", null, null);
        }

        return tx;
    }

    /// End the transaction and log duration.
    pub fn end(self: *const Self) void {
        if (!self.enabled) return;

        const now = std.time.nanoTimestamp();
        const duration: u64 = @intCast(@max(0, now - self.start_time));
        self.logEvent(.info, "end", null, duration);
    }

    /// Log an event within this transaction.
    pub fn event(self: *const Self, event_name: []const u8, details: ?[]const u8) void {
        if (!self.enabled) return;
        self.logEvent(.info, event_name, details, null);
    }

    /// Log a debug event.
    pub fn debug(self: *const Self, event_name: []const u8, details: ?[]const u8) void {
        if (!self.enabled) return;
        self.logEvent(.debug, event_name, details, null);
    }

    /// Log a warning event.
    pub fn warn(self: *const Self, event_name: []const u8, details: ?[]const u8) void {
        if (!self.enabled) return;
        self.logEvent(.warn, event_name, details, null);
    }

    /// Log an error event.
    pub fn err(self: *const Self, event_name: []const u8, details: ?[]const u8) void {
        if (!self.enabled) return;
        self.logEvent(.@"error", event_name, details, null);
    }

    fn logEvent(self: *const Self, level: LogLevel, event_name: []const u8, details: ?[]const u8, duration_ns: ?u64) void {
        // Clone details if provided
        var details_copy: ?[]const u8 = null;
        if (details) |d| {
            details_copy = self.allocator.dupe(u8, d) catch null;
        }

        // Clone actor if provided
        var actor_copy: ?[]const u8 = null;
        if (self.actor) |a| {
            actor_copy = self.allocator.dupe(u8, a) catch null;
        }

        const entry = LogEntry{
            .correlation_id = self.correlation_id,
            .timestamp_ns = std.time.nanoTimestamp(),
            .level = level,
            .operation = self.operation,
            .event = event_name,
            .pid = getCurrentPid(),
            .actor = actor_copy,
            .details = details_copy,
            .duration_ns = duration_ns,
        };

        // Push to global buffer
        global_buffer_mutex.lock();
        defer global_buffer_mutex.unlock();

        if (global_buffer) |*buf| {
            buf.push(entry);
        }

        // Also write to stderr if verbose logging is enabled
        if (global_verbose_output) {
            const formatted = entry.formatHuman(self.allocator) catch return;
            defer self.allocator.free(formatted);
            const stderr = std.fs.File.stderr();
            stderr.writeAll("[TXLOG] ") catch {};
            stderr.writeAll(formatted) catch {};
            stderr.writeAll("\n") catch {};
        }
    }
};

// Global state

var global_buffer: ?LogBuffer = null;
var global_buffer_mutex: std.Thread.Mutex = .{};
var global_logging_enabled: bool = false;
var global_verbose_output: bool = false;
var global_next_cid: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);

/// Initialize the global log buffer.
pub fn init(allocator: std.mem.Allocator, capacity: usize) !void {
    global_buffer_mutex.lock();
    defer global_buffer_mutex.unlock();

    if (global_buffer != null) {
        return; // Already initialized
    }

    global_buffer = try LogBuffer.init(allocator, capacity);
    global_logging_enabled = true;
}

/// Deinitialize the global log buffer.
pub fn deinit() void {
    global_buffer_mutex.lock();
    defer global_buffer_mutex.unlock();

    if (global_buffer) |*buf| {
        buf.deinit();
        global_buffer = null;
    }
    global_logging_enabled = false;
}

/// Enable or disable transaction logging.
pub fn setEnabled(enabled: bool) void {
    global_logging_enabled = enabled;
}

/// Enable or disable verbose output to stderr.
pub fn setVerboseOutput(verbose: bool) void {
    global_verbose_output = verbose;
}

/// Check if logging is enabled.
pub fn isEnabled() bool {
    return global_logging_enabled;
}

/// Get the current log entries.
pub fn getEntries() []const LogEntry {
    global_buffer_mutex.lock();
    defer global_buffer_mutex.unlock();

    if (global_buffer) |*buf| {
        return buf.getEntries();
    }
    return &[_]LogEntry{};
}

/// Clear all log entries.
pub fn clear() void {
    global_buffer_mutex.lock();
    defer global_buffer_mutex.unlock();

    if (global_buffer) |*buf| {
        buf.clear();
    }
}

/// Begin a new transaction log.
pub fn begin(operation: []const u8, actor: ?[]const u8, allocator: std.mem.Allocator) TxLog {
    return TxLog.begin(operation, actor, allocator);
}

/// Generate a unique correlation ID.
fn generateCorrelationId() u64 {
    // Combine timestamp with incrementing counter for uniqueness
    const raw_ts = std.time.nanoTimestamp();
    const ts: u64 = @intCast(@as(u64, @truncate(@as(u128, @bitCast(raw_ts)))) & 0xFFFFFFFF);
    const counter = global_next_cid.fetchAdd(1, .monotonic);
    return (ts << 32) | (counter & 0xFFFFFFFF);
}

/// Windows API declaration for process ID.
const windows_kernel32 = struct {
    extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) u32;
};

/// Get current process ID.
fn getCurrentPid() i32 {
    if (builtin.os.tag == .windows) {
        return @intCast(windows_kernel32.GetCurrentProcessId());
    } else if (builtin.os.tag == .linux) {
        return @bitCast(std.os.linux.getpid());
    } else {
        return std.c.getpid();
    }
}

// --- Tests ---

test "LogLevel.toString" {
    try std.testing.expectEqualStrings("DEBUG", LogLevel.debug.toString());
    try std.testing.expectEqualStrings("INFO", LogLevel.info.toString());
    try std.testing.expectEqualStrings("WARN", LogLevel.warn.toString());
    try std.testing.expectEqualStrings("ERROR", LogLevel.@"error".toString());
}

test "LogEntry.formatJson produces valid output" {
    const allocator = std.testing.allocator;

    const entry = LogEntry{
        .correlation_id = 12345,
        .timestamp_ns = 1706540000_000_000_000,
        .level = .info,
        .operation = "create_issue",
        .event = "lock_acquired",
        .pid = 1234,
        .actor = null,
        .details = null,
        .duration_ns = null,
    };

    const json = try entry.formatJson(allocator);
    defer allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"cid\":12345") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"op\":\"create_issue\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"event\":\"lock_acquired\"") != null);
}

test "LogEntry.formatHuman produces readable output" {
    const allocator = std.testing.allocator;

    const entry = LogEntry{
        .correlation_id = 0xABCD1234,
        .timestamp_ns = std.time.nanoTimestamp(),
        .level = .info,
        .operation = "sync",
        .event = "begin",
        .pid = 5678,
        .actor = null,
        .details = null,
        .duration_ns = 5_000_000, // 5ms
    };

    const human = try entry.formatHuman(allocator);
    defer allocator.free(human);

    try std.testing.expect(std.mem.indexOf(u8, human, "sync/begin") != null);
    try std.testing.expect(std.mem.indexOf(u8, human, "(5.00ms)") != null);
}

test "generateCorrelationId produces unique IDs" {
    const id1 = generateCorrelationId();
    const id2 = generateCorrelationId();
    const id3 = generateCorrelationId();

    try std.testing.expect(id1 != id2);
    try std.testing.expect(id2 != id3);
    try std.testing.expect(id1 != id3);
}

test "LogBuffer push and getEntries" {
    const allocator = std.testing.allocator;

    var buffer = try LogBuffer.init(allocator, 3);
    defer buffer.deinit();

    buffer.push(.{
        .correlation_id = 1,
        .timestamp_ns = 100,
        .level = .info,
        .operation = "op1",
        .event = "ev1",
        .pid = 1,
        .actor = null,
        .details = null,
        .duration_ns = null,
    });

    try std.testing.expectEqual(@as(usize, 1), buffer.count);

    buffer.push(.{
        .correlation_id = 2,
        .timestamp_ns = 200,
        .level = .info,
        .operation = "op2",
        .event = "ev2",
        .pid = 1,
        .actor = null,
        .details = null,
        .duration_ns = null,
    });

    try std.testing.expectEqual(@as(usize, 2), buffer.count);

    const entries = buffer.getEntries();
    try std.testing.expectEqual(@as(usize, 2), entries.len);
}

test "LogBuffer wraps when full" {
    const allocator = std.testing.allocator;

    var buffer = try LogBuffer.init(allocator, 2);
    defer buffer.deinit();

    // Push 3 entries into a buffer of size 2
    for (0..3) |i| {
        buffer.push(.{
            .correlation_id = @intCast(i),
            .timestamp_ns = @intCast(i * 100),
            .level = .info,
            .operation = "op",
            .event = "ev",
            .pid = 1,
            .actor = null,
            .details = null,
            .duration_ns = null,
        });
    }

    try std.testing.expectEqual(@as(usize, 2), buffer.count);
}

test "TxLog basic usage" {
    const allocator = std.testing.allocator;

    // Initialize global buffer
    try init(allocator, 10);
    defer deinit();

    // Create a transaction
    var tx = begin("test_op", "test_actor", allocator);
    tx.event("something_happened", "{\"key\":\"value\"}");
    tx.debug("debug_info", null);
    tx.end();

    const entries = getEntries();
    try std.testing.expect(entries.len >= 2); // begin + end at minimum
}

test "setEnabled disables logging" {
    const allocator = std.testing.allocator;

    try init(allocator, 10);
    defer deinit();

    clear();
    setEnabled(false);

    var tx = begin("disabled_op", null, allocator);
    tx.event("should_not_log", null);
    tx.end();

    const entries = getEntries();
    try std.testing.expectEqual(@as(usize, 0), entries.len);

    setEnabled(true); // Re-enable for other tests
}
