//! Write-Ahead Log (WAL) for beads_zig.
//!
//! Provides constant-time concurrent writes by appending operations to a WAL file
//! rather than rewriting the entire main JSONL file. Operations are:
//! - Serialized via flock before append
//! - fsync'd before lock release for durability
//! - Replayed on read to reconstruct current state
//!
//! WAL entry format (binary framed):
//!   [magic:u32][crc:u32][len:u32][json_payload][newline]
//!
//! - magic: 0xB3AD5 - enables quick validation of WAL integrity
//! - crc: CRC32 checksum of the JSON payload (detects corruption)
//! - len: length of JSON payload (enables skipping without parsing)
//! - json_payload: the actual WAL entry as JSON
//! - newline: \n for human readability when inspecting
//!
//! Legacy format (plain JSON lines) is also supported for reading:
//! {"op":"add","ts":1706540000,"id":"bd-abc123","data":{...}}
//!
//! Generation numbers prevent read/compact races:
//! - Each compaction rotates to a new generation (beads.wal.N -> beads.wal.N+1)
//! - Readers check generation before/after read and retry if changed
//! - Old WAL files cleaned up after successful compaction

const std = @import("std");
const fs = std.fs;
const Issue = @import("../models/issue.zig").Issue;
const BeadsLock = @import("lock.zig").BeadsLock;
const IssueStore = @import("store.zig").IssueStore;
const Generation = @import("generation.zig").Generation;
const walstate = @import("walstate.zig");
const test_util = @import("../test_util.zig");

/// Magic bytes to identify framed WAL entries: 0x000B3AD5 ("BEADS" in hex-ish)
pub const WAL_MAGIC: u32 = 0x000B3AD5;

/// Size of the binary frame header (magic + crc + len)
pub const FRAME_HEADER_SIZE: usize = 12;

pub const WalError = error{
    WalCorrupted,
    WriteError,
    LockFailed,
    InvalidOperation,
    ParseError,
    OutOfMemory,
    ReplayPartialFailure,
    ChecksumMismatch,
};

/// Statistics from WAL replay operations.
pub const ReplayStats = struct {
    applied: usize = 0,
    skipped: usize = 0,
    failed: usize = 0,
    failure_ids: []const []const u8 = &.{},

    pub fn deinit(self: *ReplayStats, allocator: std.mem.Allocator) void {
        for (self.failure_ids) |id| {
            allocator.free(id);
        }
        if (self.failure_ids.len > 0) {
            allocator.free(self.failure_ids);
        }
    }

    pub fn hasFailures(self: ReplayStats) bool {
        return self.failed > 0;
    }
};

/// WAL operation types.
pub const WalOp = enum {
    add,
    update,
    close,
    reopen,
    delete,
    set_blocked,
    unset_blocked,

    pub fn toString(self: WalOp) []const u8 {
        return switch (self) {
            .add => "add",
            .update => "update",
            .close => "close",
            .reopen => "reopen",
            .delete => "delete",
            .set_blocked => "set_blocked",
            .unset_blocked => "unset_blocked",
        };
    }

    pub fn fromString(s: []const u8) ?WalOp {
        if (std.mem.eql(u8, s, "add")) return .add;
        if (std.mem.eql(u8, s, "update")) return .update;
        if (std.mem.eql(u8, s, "close")) return .close;
        if (std.mem.eql(u8, s, "reopen")) return .reopen;
        if (std.mem.eql(u8, s, "delete")) return .delete;
        if (std.mem.eql(u8, s, "set_blocked")) return .set_blocked;
        if (std.mem.eql(u8, s, "unset_blocked")) return .unset_blocked;
        return null;
    }
};

/// A single WAL entry representing one operation.
pub const WalEntry = struct {
    op: WalOp,
    ts: i64, // Unix timestamp for ordering
    seq: u64 = 0, // Monotonic sequence number for deterministic ordering within same timestamp
    id: []const u8, // Issue ID
    data: ?Issue, // Full issue for add/update, null for status-only ops

    const Self = @This();

    /// Custom JSON serialization for WalEntry.
    pub fn jsonStringify(self: Self, jws: anytype) !void {
        try jws.beginObject();

        try jws.objectField("op");
        try jws.write(self.op.toString());

        try jws.objectField("ts");
        try jws.write(self.ts);

        try jws.objectField("seq");
        try jws.write(self.seq);

        try jws.objectField("id");
        try jws.write(self.id);

        try jws.objectField("data");
        if (self.data) |issue| {
            try jws.write(issue);
        } else {
            try jws.write(null);
        }

        try jws.endObject();
    }
};

/// Parsed WAL entry for replay.
pub const ParsedWalEntry = struct {
    op: WalOp,
    ts: i64,
    seq: u64 = 0, // Sequence number (0 for legacy entries)
    id: []const u8,
    data: ?Issue,

    pub fn deinit(self: *ParsedWalEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        if (self.data) |*issue| {
            var i = issue.*;
            i.deinit(allocator);
        }
    }
};

/// WAL file manager for reading and writing operations.
/// Supports generation-based file rotation for read/compact race safety.
pub const Wal = struct {
    beads_dir: []const u8,
    wal_path: []const u8,
    lock_path: []const u8,
    allocator: std.mem.Allocator,
    next_seq: u64 = 1, // Next sequence number to assign
    generation: u64 = 1, // Current generation number
    owns_wal_path: bool = true, // Whether we allocated wal_path

    const Self = @This();

    /// Initialize WAL with generation-aware path.
    /// Reads current generation from disk and uses appropriate WAL file.
    pub fn init(beads_dir: []const u8, allocator: std.mem.Allocator) !Self {
        // Read current generation
        var gen = Generation.init(beads_dir, allocator);
        const current_gen = gen.read() catch 1;

        // Build generation-aware WAL path
        const wal_path = try gen.walPath(current_gen);
        errdefer allocator.free(wal_path);

        const lock_path = try std.fs.path.join(allocator, &.{ beads_dir, "beads.lock" });
        errdefer allocator.free(lock_path);

        const beads_dir_copy = try allocator.dupe(u8, beads_dir);

        return Self{
            .beads_dir = beads_dir_copy,
            .wal_path = wal_path,
            .lock_path = lock_path,
            .allocator = allocator,
            .next_seq = 1,
            .generation = current_gen,
            .owns_wal_path = true,
        };
    }

    /// Initialize WAL with a specific path (for testing or direct path usage).
    /// Does not use generation-aware paths.
    pub fn initWithPath(wal_path: []const u8, lock_path: []const u8, allocator: std.mem.Allocator) Self {
        return Self{
            .beads_dir = "",
            .wal_path = wal_path,
            .lock_path = lock_path,
            .allocator = allocator,
            .next_seq = 1,
            .generation = 1,
            .owns_wal_path = false,
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.owns_wal_path) {
            self.allocator.free(self.wal_path);
        }
        self.allocator.free(self.lock_path);
        if (self.beads_dir.len > 0) {
            self.allocator.free(self.beads_dir);
        }
    }

    /// Get current generation number.
    pub fn getGeneration(self: *Self) u64 {
        return self.generation;
    }

    /// Refresh generation from disk and update WAL path if changed.
    /// Call this before reading to ensure we're using the latest generation.
    pub fn refreshGeneration(self: *Self) !bool {
        if (self.beads_dir.len == 0) return false; // Not using generation-aware paths

        var gen = Generation.init(self.beads_dir, self.allocator);
        const current_gen = gen.read() catch return false;

        if (current_gen != self.generation) {
            // Generation changed - update WAL path
            const new_wal_path = try gen.walPath(current_gen);

            if (self.owns_wal_path) {
                self.allocator.free(self.wal_path);
            }
            self.wal_path = new_wal_path;
            self.owns_wal_path = true;
            self.generation = current_gen;
            return true;
        }
        return false;
    }

    /// Rotate to a new generation (used by compactor).
    /// Creates a new WAL file and returns the new generation number.
    /// IMPORTANT: Caller must already hold the exclusive lock.
    pub fn rotateGeneration(self: *Self) !u64 {
        if (self.beads_dir.len == 0) return self.generation;

        var gen = Generation.init(self.beads_dir, self.allocator);
        // Use incrementUnlocked since caller (compact) already holds the lock
        const new_gen = try gen.incrementUnlocked();

        // Update our WAL path to the new generation
        const new_wal_path = try gen.walPath(new_gen);

        if (self.owns_wal_path) {
            self.allocator.free(self.wal_path);
        }
        self.wal_path = new_wal_path;
        self.owns_wal_path = true;
        self.generation = new_gen;

        // Clean up old generations (keep current and previous)
        gen.cleanupOldGenerations(new_gen);

        return new_gen;
    }

    /// Load the next sequence number from existing WAL entries.
    /// Call this after init to ensure sequence numbers are unique.
    pub fn loadNextSeq(self: *Self) !void {
        const entries = self.readEntries() catch return;
        defer {
            for (entries) |*e| {
                var entry = e.*;
                entry.deinit(self.allocator);
            }
            self.allocator.free(entries);
        }

        var max_seq: u64 = 0;
        for (entries) |e| {
            if (e.seq > max_seq) max_seq = e.seq;
        }
        self.next_seq = max_seq + 1;
    }

    /// Append an entry to the WAL under exclusive lock.
    /// Ensures durability via fsync before releasing lock.
    /// Assigns a monotonic sequence number to the entry.
    /// Implements writer backoff when WAL is huge (>1MB) to allow compaction.
    pub fn appendEntry(self: *Self, entry: WalEntry) !void {
        // Coordinate with global WAL state for backoff under heavy load
        const state = walstate.getGlobalState();
        _ = state.acquireWriter(); // May sleep if WAL is huge

        var lock = BeadsLock.acquire(self.lock_path) catch {
            state.releaseWriter(0); // Release without size update on failure
            return WalError.LockFailed;
        };
        defer lock.release();

        // Assign sequence number under lock
        var entry_with_seq = entry;
        entry_with_seq.seq = self.next_seq;
        self.next_seq += 1;

        // Write the entry
        self.appendEntryUnlocked(entry_with_seq) catch |err| {
            state.releaseWriter(0);
            return err;
        };

        // Update state with approximate entry size
        // Frame header (12) + JSON + newline (1)
        const entry_size: u64 = FRAME_HEADER_SIZE + self.estimateEntrySize(entry_with_seq) + 1;
        state.releaseWriter(entry_size);
    }

    /// Estimate the size of a WAL entry for state tracking.
    fn estimateEntrySize(self: *Self, entry: WalEntry) u64 {
        _ = self;
        // Rough estimate: base JSON overhead + issue data
        // This doesn't need to be exact, just approximate for backoff decisions
        var size: u64 = 100; // Base JSON structure
        size += entry.id.len;
        if (entry.data) |issue| {
            size += issue.title.len;
            if (issue.description) |d| size += d.len;
            if (issue.design) |d| size += d.len;
            if (issue.notes) |n| size += n.len;
        }
        return size;
    }

    /// Append entry without acquiring lock (caller must hold lock).
    fn appendEntryUnlocked(self: *Self, entry: WalEntry) !void {
        const dir = fs.cwd();

        // Ensure parent directory exists
        if (std.fs.path.dirname(self.wal_path)) |parent| {
            dir.makePath(parent) catch |err| switch (err) {
                error.PathAlreadyExists => {},
                else => return err,
            };
        }

        // Open or create WAL file in append mode
        const file = dir.createFile(self.wal_path, .{
            .truncate = false,
        }) catch return WalError.WriteError;
        defer file.close();

        // Seek to end
        file.seekFromEnd(0) catch return WalError.WriteError;

        // Serialize entry to JSON
        const json_bytes = std.json.Stringify.valueAlloc(self.allocator, entry, .{}) catch return WalError.WriteError;
        defer self.allocator.free(json_bytes);

        // Compute CRC32 checksum of the JSON payload
        const crc = std.hash.Crc32.hash(json_bytes);

        // Write binary frame header: [magic:u32][crc:u32][len:u32]
        const len: u32 = @intCast(json_bytes.len);
        var header: [FRAME_HEADER_SIZE]u8 = undefined;
        std.mem.writeInt(u32, header[0..4], WAL_MAGIC, .little);
        std.mem.writeInt(u32, header[4..8], crc, .little);
        std.mem.writeInt(u32, header[8..12], len, .little);

        file.writeAll(&header) catch return WalError.WriteError;
        file.writeAll(json_bytes) catch return WalError.WriteError;
        file.writeAll("\n") catch return WalError.WriteError;

        // fsync for durability
        file.sync() catch return WalError.WriteError;
    }

    /// Read all WAL entries with generation-aware consistency checking.
    /// Supports both framed format (with CRC32) and legacy plain JSON lines.
    /// If generation changes during read (compaction occurred), retries with new generation.
    pub fn readEntries(self: *Self) ![]ParsedWalEntry {
        // If using generation-aware paths, check for consistency
        if (self.beads_dir.len > 0) {
            return self.readEntriesWithGenerationCheck();
        }
        return self.readEntriesFromPath(self.wal_path);
    }

    /// Read entries with generation consistency checking.
    /// Retries up to 3 times if generation changes during read.
    fn readEntriesWithGenerationCheck(self: *Self) ![]ParsedWalEntry {
        var gen = Generation.init(self.beads_dir, self.allocator);
        const max_retries: u32 = 3;
        var attempts: u32 = 0;

        while (attempts < max_retries) : (attempts += 1) {
            // Read generation before loading
            const gen_before = gen.read() catch self.generation;

            // Get WAL path for this generation
            const wal_path = try gen.walPath(gen_before);
            defer self.allocator.free(wal_path);

            // Read entries
            const entries = try self.readEntriesFromPath(wal_path);

            // Read generation after loading
            const gen_after = gen.read() catch gen_before;

            if (gen_before == gen_after) {
                // Generation stable - return consistent state
                // Update our cached generation
                if (gen_before != self.generation) {
                    if (self.owns_wal_path) {
                        self.allocator.free(self.wal_path);
                    }
                    self.wal_path = try gen.walPath(gen_before);
                    self.owns_wal_path = true;
                    self.generation = gen_before;
                }
                return entries;
            }

            // Generation changed during read - free entries and retry
            for (entries) |*e| {
                var entry = e.*;
                entry.deinit(self.allocator);
            }
            self.allocator.free(entries);
        }

        // Max retries exceeded - return latest generation's entries
        const final_gen = gen.read() catch self.generation;
        const final_path = try gen.walPath(final_gen);
        defer self.allocator.free(final_path);
        return self.readEntriesFromPath(final_path);
    }

    /// Read entries from a specific WAL file path.
    fn readEntriesFromPath(self: *Self, path: []const u8) ![]ParsedWalEntry {
        const file = fs.cwd().openFile(path, .{}) catch |err| switch (err) {
            error.FileNotFound => return &[_]ParsedWalEntry{},
            else => return err,
        };
        defer file.close();

        const content = file.readToEndAlloc(self.allocator, 100 * 1024 * 1024) catch return WalError.ParseError;
        defer self.allocator.free(content);

        var entries: std.ArrayListUnmanaged(ParsedWalEntry) = .{};
        errdefer {
            for (entries.items) |*e| {
                e.deinit(self.allocator);
            }
            entries.deinit(self.allocator);
        }

        var pos: usize = 0;
        while (pos < content.len) {
            // Try to parse as framed entry first (check for magic bytes)
            if (pos + FRAME_HEADER_SIZE <= content.len) {
                const magic = std.mem.readInt(u32, content[pos..][0..4], .little);
                if (magic == WAL_MAGIC) {
                    // Framed format: [magic:u32][crc:u32][len:u32][json][newline]
                    const stored_crc = std.mem.readInt(u32, content[pos + 4 ..][0..4], .little);
                    const len = std.mem.readInt(u32, content[pos + 8 ..][0..4], .little);

                    const payload_start = pos + FRAME_HEADER_SIZE;
                    const payload_end = payload_start + len;

                    // Check for truncation
                    if (payload_end > content.len) {
                        // Truncated entry - skip to end (partial write from crash)
                        break;
                    }

                    const json_payload = content[payload_start..payload_end];

                    // Verify CRC32
                    const computed_crc = std.hash.Crc32.hash(json_payload);
                    if (computed_crc != stored_crc) {
                        // CRC mismatch - corrupted entry, skip it
                        // Try to find next entry by looking for next magic or newline
                        pos = payload_end;
                        if (pos < content.len and content[pos] == '\n') {
                            pos += 1;
                        }
                        continue;
                    }

                    // Parse the JSON payload
                    if (self.parseEntry(json_payload)) |entry| {
                        try entries.append(self.allocator, entry);
                    } else |_| {
                        // JSON parse error - skip
                    }

                    // Move past the entry (json + newline)
                    pos = payload_end;
                    if (pos < content.len and content[pos] == '\n') {
                        pos += 1;
                    }
                    continue;
                }
            }

            // Fall back to legacy plain JSON line format
            // Find the next newline
            var line_end = pos;
            while (line_end < content.len and content[line_end] != '\n') {
                line_end += 1;
            }

            if (line_end > pos) {
                const line = content[pos..line_end];
                if (self.parseEntry(line)) |entry| {
                    try entries.append(self.allocator, entry);
                } else |_| {
                    // Skip malformed entries (graceful degradation)
                }
            }

            pos = line_end;
            if (pos < content.len and content[pos] == '\n') {
                pos += 1;
            }
        }

        return entries.toOwnedSlice(self.allocator);
    }

    /// Parse a single WAL entry line.
    fn parseEntry(self: *Self, line: []const u8) !ParsedWalEntry {
        const parsed = std.json.parseFromSlice(
            struct {
                op: []const u8,
                ts: i64,
                seq: u64 = 0, // Default to 0 for legacy entries without seq
                id: []const u8,
                data: ?Issue,
            },
            self.allocator,
            line,
            .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
        ) catch return WalError.ParseError;
        defer parsed.deinit();

        const op = WalOp.fromString(parsed.value.op) orelse return WalError.InvalidOperation;

        // Clone strings since parsed will be freed
        const id = try self.allocator.dupe(u8, parsed.value.id);
        errdefer self.allocator.free(id);

        var data: ?Issue = null;
        if (parsed.value.data) |issue| {
            data = try issue.clone(self.allocator);
        }

        return ParsedWalEntry{
            .op = op,
            .ts = parsed.value.ts,
            .seq = parsed.value.seq,
            .id = id,
            .data = data,
        };
    }

    /// Replay WAL entries onto an IssueStore.
    /// Applies operations in timestamp/sequence order.
    /// Returns statistics about the replay including any failures.
    pub fn replay(self: *Self, store: *IssueStore) !ReplayStats {
        const entries = try self.readEntries();
        defer {
            for (entries) |*e| {
                var entry = e.*;
                entry.deinit(self.allocator);
            }
            self.allocator.free(entries);
        }

        // Sort by timestamp, then by sequence number for deterministic ordering
        // when multiple entries have the same timestamp
        std.mem.sortUnstable(ParsedWalEntry, @constCast(entries), {}, struct {
            fn lessThan(_: void, a: ParsedWalEntry, b: ParsedWalEntry) bool {
                if (a.ts != b.ts) return a.ts < b.ts;
                return a.seq < b.seq;
            }
        }.lessThan);

        // Track replay results
        var stats = ReplayStats{};
        var failure_ids: std.ArrayListUnmanaged([]const u8) = .{};
        errdefer {
            for (failure_ids.items) |id| {
                self.allocator.free(id);
            }
            failure_ids.deinit(self.allocator);
        }

        // Apply each operation
        for (entries) |entry| {
            const result = self.applyEntry(store, entry);
            switch (result) {
                .applied => stats.applied += 1,
                .skipped => stats.skipped += 1,
                .failed => {
                    stats.failed += 1;
                    const id_copy = self.allocator.dupe(u8, entry.id) catch continue;
                    failure_ids.append(self.allocator, id_copy) catch {
                        self.allocator.free(id_copy);
                    };
                },
            }
        }

        stats.failure_ids = failure_ids.toOwnedSlice(self.allocator) catch &.{};
        return stats;
    }

    /// Result of applying a single WAL entry.
    const ApplyResult = enum {
        applied,
        skipped,
        failed,
    };

    /// Apply a single WAL entry to the store.
    /// Returns the result of the operation.
    fn applyEntry(self: *Self, store: *IssueStore, entry: ParsedWalEntry) ApplyResult {
        _ = self;
        switch (entry.op) {
            .add => {
                if (entry.data) |issue| {
                    // Only insert if not already present
                    if (!store.id_index.contains(issue.id)) {
                        store.insert(issue) catch |err| switch (err) {
                            error.DuplicateId => return .skipped, // Already exists
                            else => return .failed,
                        };
                        return .applied;
                    }
                    return .skipped; // Already exists
                }
                return .skipped; // No data for add op
            },
            .update => {
                if (entry.data) |issue| {
                    // Update or insert
                    if (store.id_index.contains(issue.id)) {
                        // Full replacement for simplicity
                        const idx = store.id_index.get(issue.id).?;
                        var old = &store.issues.items[idx];
                        old.deinit(store.allocator);
                        store.issues.items[idx] = issue.clone(store.allocator) catch return .failed;
                        return .applied;
                    } else {
                        store.insert(issue) catch return .failed;
                        return .applied;
                    }
                }
                return .skipped; // No data for update op
            },
            .close => {
                store.update(entry.id, .{
                    .status = .closed,
                    .closed_at = std.time.timestamp(),
                }, entry.ts) catch |err| switch (err) {
                    error.IssueNotFound => return .skipped,
                    else => return .failed,
                };
                return .applied;
            },
            .reopen => {
                store.update(entry.id, .{
                    .status = .open,
                }, entry.ts) catch |err| switch (err) {
                    error.IssueNotFound => return .skipped,
                    else => return .failed,
                };
                return .applied;
            },
            .delete => {
                store.delete(entry.id, entry.ts) catch |err| switch (err) {
                    error.IssueNotFound => return .skipped,
                    else => return .failed,
                };
                return .applied;
            },
            .set_blocked => {
                store.update(entry.id, .{ .status = .blocked }, entry.ts) catch |err| switch (err) {
                    error.IssueNotFound => return .skipped,
                    else => return .failed,
                };
                return .applied;
            },
            .unset_blocked => {
                store.update(entry.id, .{ .status = .open }, entry.ts) catch |err| switch (err) {
                    error.IssueNotFound => return .skipped,
                    else => return .failed,
                };
                return .applied;
            },
        }
    }

    /// Get the number of entries in the WAL.
    pub fn entryCount(self: *Self) !usize {
        const entries = try self.readEntries();
        defer {
            for (entries) |*e| {
                e.deinit(self.allocator);
            }
            self.allocator.free(entries);
        }
        return entries.len;
    }

    /// Get the size of the WAL file in bytes.
    pub fn fileSize(self: *Self) !u64 {
        const file = fs.cwd().openFile(self.wal_path, .{}) catch |err| switch (err) {
            error.FileNotFound => return 0,
            else => return err,
        };
        defer file.close();

        const stat = try file.stat();
        return stat.size;
    }

    /// Truncate the WAL file (used after compaction).
    pub fn truncate(self: *Self) !void {
        const dir = fs.cwd();
        dir.deleteFile(self.wal_path) catch |err| switch (err) {
            error.FileNotFound => {}, // Already empty
            else => return err,
        };
    }

    // Convenience methods for common operations

    /// Add a new issue to the WAL.
    pub fn addIssue(self: *Self, issue: Issue) !void {
        try self.appendEntry(.{
            .op = .add,
            .ts = std.time.timestamp(),
            .id = issue.id,
            .data = issue,
        });
    }

    /// Close an issue in the WAL.
    pub fn closeIssue(self: *Self, id: []const u8) !void {
        try self.appendEntry(.{
            .op = .close,
            .ts = std.time.timestamp(),
            .id = id,
            .data = null,
        });
    }

    /// Reopen an issue in the WAL.
    pub fn reopenIssue(self: *Self, id: []const u8) !void {
        try self.appendEntry(.{
            .op = .reopen,
            .ts = std.time.timestamp(),
            .id = id,
            .data = null,
        });
    }

    /// Update an issue in the WAL.
    pub fn updateIssue(self: *Self, issue: Issue) !void {
        try self.appendEntry(.{
            .op = .update,
            .ts = std.time.timestamp(),
            .id = issue.id,
            .data = issue,
        });
    }

    /// Delete an issue in the WAL (tombstone).
    pub fn deleteIssue(self: *Self, id: []const u8) !void {
        try self.appendEntry(.{
            .op = .delete,
            .ts = std.time.timestamp(),
            .id = id,
            .data = null,
        });
    }

    /// Set an issue as blocked in the WAL.
    pub fn setBlocked(self: *Self, id: []const u8) !void {
        try self.appendEntry(.{
            .op = .set_blocked,
            .ts = std.time.timestamp(),
            .id = id,
            .data = null,
        });
    }

    /// Unset blocked status in the WAL.
    pub fn unsetBlocked(self: *Self, id: []const u8) !void {
        try self.appendEntry(.{
            .op = .unset_blocked,
            .ts = std.time.timestamp(),
            .id = id,
            .data = null,
        });
    }
};

// --- Tests ---

test "WalOp.toString and fromString roundtrip" {
    const ops = [_]WalOp{ .add, .update, .close, .reopen, .delete, .set_blocked, .unset_blocked };
    for (ops) |op| {
        const str = op.toString();
        const parsed = WalOp.fromString(str);
        try std.testing.expect(parsed != null);
        try std.testing.expectEqual(op, parsed.?);
    }
}

test "WalOp.fromString returns null for unknown" {
    try std.testing.expect(WalOp.fromString("unknown") == null);
    try std.testing.expect(WalOp.fromString("") == null);
}

test "Wal.init and deinit" {
    const allocator = std.testing.allocator;
    const test_dir = try test_util.createTestDir(allocator, "wal_init");
    defer allocator.free(test_dir);
    defer test_util.cleanupTestDir(test_dir);

    var wal = try Wal.init(test_dir, allocator);
    defer wal.deinit();

    // Generation-aware path (generation 1 by default)
    try std.testing.expect(std.mem.endsWith(u8, wal.wal_path, "/beads.wal.1"));
    try std.testing.expect(std.mem.endsWith(u8, wal.lock_path, "/beads.lock"));
    try std.testing.expectEqual(@as(u64, 1), wal.generation);
}

test "Wal.rotateGeneration creates new generation" {
    const allocator = std.testing.allocator;
    const test_dir = try test_util.createTestDir(allocator, "wal_rotate");
    defer allocator.free(test_dir);
    defer test_util.cleanupTestDir(test_dir);

    var wal = try Wal.init(test_dir, allocator);
    defer wal.deinit();

    // Initial generation is 1
    try std.testing.expectEqual(@as(u64, 1), wal.getGeneration());

    // rotateGeneration must be called with lock held (simulates compactor behavior)
    // Acquire lock before rotating
    var lock = BeadsLock.acquire(wal.lock_path) catch unreachable;

    // Rotate to new generation
    const new_gen = try wal.rotateGeneration();
    try std.testing.expectEqual(@as(u64, 2), new_gen);
    try std.testing.expectEqual(@as(u64, 2), wal.getGeneration());
    try std.testing.expect(std.mem.endsWith(u8, wal.wal_path, "/beads.wal.2"));

    // Rotate again
    const newer_gen = try wal.rotateGeneration();
    try std.testing.expectEqual(@as(u64, 3), newer_gen);
    try std.testing.expect(std.mem.endsWith(u8, wal.wal_path, "/beads.wal.3"));

    lock.release();
}

test "Wal.refreshGeneration detects external changes" {
    const allocator = std.testing.allocator;
    const test_dir = try test_util.createTestDir(allocator, "wal_refresh");
    defer allocator.free(test_dir);
    defer test_util.cleanupTestDir(test_dir);

    var wal = try Wal.init(test_dir, allocator);
    defer wal.deinit();

    // Initially generation 1
    try std.testing.expectEqual(@as(u64, 1), wal.getGeneration());

    // Externally update generation (simulates another process doing compaction)
    var gen = Generation.init(test_dir, allocator);
    try gen.write(5);

    // Refresh should detect the change
    const changed = try wal.refreshGeneration();
    try std.testing.expect(changed);
    try std.testing.expectEqual(@as(u64, 5), wal.getGeneration());
    try std.testing.expect(std.mem.endsWith(u8, wal.wal_path, "/beads.wal.5"));
}

test "Wal.readEntries returns empty for missing file" {
    const allocator = std.testing.allocator;
    const test_dir = try test_util.createTestDir(allocator, "wal_missing");
    defer allocator.free(test_dir);
    defer test_util.cleanupTestDir(test_dir);

    var wal = try Wal.init(test_dir, allocator);
    defer wal.deinit();

    const entries = try wal.readEntries();
    defer allocator.free(entries);

    try std.testing.expectEqual(@as(usize, 0), entries.len);
}

test "Wal.appendEntry and readEntries roundtrip" {
    const allocator = std.testing.allocator;
    const test_dir = try test_util.createTestDir(allocator, "wal_roundtrip");
    defer allocator.free(test_dir);
    defer test_util.cleanupTestDir(test_dir);

    var wal = try Wal.init(test_dir, allocator);
    defer wal.deinit();

    const issue = Issue.init("bd-test1", "Test Issue", 1706540000);

    try wal.appendEntry(.{
        .op = .add,
        .ts = 1706540000,
        .id = "bd-test1",
        .data = issue,
    });

    try wal.appendEntry(.{
        .op = .close,
        .ts = 1706540001,
        .id = "bd-test1",
        .data = null,
    });

    const entries = try wal.readEntries();
    defer {
        for (entries) |*e| {
            var entry = e.*;
            entry.deinit(allocator);
        }
        allocator.free(entries);
    }

    try std.testing.expectEqual(@as(usize, 2), entries.len);
    try std.testing.expectEqual(WalOp.add, entries[0].op);
    try std.testing.expectEqual(WalOp.close, entries[1].op);
    try std.testing.expectEqualStrings("bd-test1", entries[0].id);
    try std.testing.expectEqualStrings("bd-test1", entries[1].id);
    try std.testing.expect(entries[0].data != null);
    try std.testing.expect(entries[1].data == null);
}

test "Wal.replay applies operations to store" {
    const allocator = std.testing.allocator;
    const test_dir = try test_util.createTestDir(allocator, "wal_replay");
    defer allocator.free(test_dir);
    defer test_util.cleanupTestDir(test_dir);

    // Create WAL with operations
    var wal = try Wal.init(test_dir, allocator);
    defer wal.deinit();

    const issue = Issue.init("bd-replay1", "Replay Test", 1706540000);

    try wal.appendEntry(.{
        .op = .add,
        .ts = 1706540000,
        .id = "bd-replay1",
        .data = issue,
    });

    // Create store and replay
    const jsonl_path = try std.fs.path.join(allocator, &.{ test_dir, "issues.jsonl" });
    defer allocator.free(jsonl_path);

    var store = IssueStore.init(allocator, jsonl_path);
    defer store.deinit();

    var stats = try wal.replay(&store);
    defer stats.deinit(allocator);

    // Verify replay succeeded
    try std.testing.expectEqual(@as(usize, 1), stats.applied);
    try std.testing.expectEqual(@as(usize, 0), stats.failed);

    // Verify issue was added
    try std.testing.expect(try store.exists("bd-replay1"));
    const retrieved = try store.get("bd-replay1");
    try std.testing.expect(retrieved != null);
    var r = retrieved.?;
    defer r.deinit(allocator);
    try std.testing.expectEqualStrings("Replay Test", r.title);
}

test "Wal.entryCount" {
    const allocator = std.testing.allocator;
    const test_dir = try test_util.createTestDir(allocator, "wal_count");
    defer allocator.free(test_dir);
    defer test_util.cleanupTestDir(test_dir);

    var wal = try Wal.init(test_dir, allocator);
    defer wal.deinit();

    try std.testing.expectEqual(@as(usize, 0), try wal.entryCount());

    const issue = Issue.init("bd-count1", "Count Test", 1706540000);
    try wal.appendEntry(.{ .op = .add, .ts = 1706540000, .id = "bd-count1", .data = issue });

    try std.testing.expectEqual(@as(usize, 1), try wal.entryCount());

    try wal.appendEntry(.{ .op = .close, .ts = 1706540001, .id = "bd-count1", .data = null });

    try std.testing.expectEqual(@as(usize, 2), try wal.entryCount());
}

test "Wal.truncate clears WAL" {
    const allocator = std.testing.allocator;
    const test_dir = try test_util.createTestDir(allocator, "wal_truncate");
    defer allocator.free(test_dir);
    defer test_util.cleanupTestDir(test_dir);

    var wal = try Wal.init(test_dir, allocator);
    defer wal.deinit();

    const issue = Issue.init("bd-trunc1", "Truncate Test", 1706540000);
    try wal.appendEntry(.{ .op = .add, .ts = 1706540000, .id = "bd-trunc1", .data = issue });

    try std.testing.expectEqual(@as(usize, 1), try wal.entryCount());

    try wal.truncate();

    try std.testing.expectEqual(@as(usize, 0), try wal.entryCount());
}

test "Wal convenience methods" {
    const allocator = std.testing.allocator;
    const test_dir = try test_util.createTestDir(allocator, "wal_convenience");
    defer allocator.free(test_dir);
    defer test_util.cleanupTestDir(test_dir);

    var wal = try Wal.init(test_dir, allocator);
    defer wal.deinit();

    const issue = Issue.init("bd-conv1", "Convenience Test", 1706540000);
    try wal.addIssue(issue);
    try wal.closeIssue("bd-conv1");
    try wal.reopenIssue("bd-conv1");
    try wal.setBlocked("bd-conv1");
    try wal.unsetBlocked("bd-conv1");
    try wal.deleteIssue("bd-conv1");

    const entries = try wal.readEntries();
    defer {
        for (entries) |*e| {
            var entry = e.*;
            entry.deinit(allocator);
        }
        allocator.free(entries);
    }

    try std.testing.expectEqual(@as(usize, 6), entries.len);
}

test "WalEntry JSON serialization" {
    const allocator = std.testing.allocator;

    const issue = Issue.init("bd-json1", "JSON Test", 1706540000);
    const entry = WalEntry{
        .op = .add,
        .ts = 1706540000,
        .id = "bd-json1",
        .data = issue,
    };

    const json_bytes = try std.json.Stringify.valueAlloc(allocator, entry, .{});
    defer allocator.free(json_bytes);

    try std.testing.expect(std.mem.indexOf(u8, json_bytes, "\"op\":\"add\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json_bytes, "\"ts\":1706540000") != null);
    try std.testing.expect(std.mem.indexOf(u8, json_bytes, "\"id\":\"bd-json1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json_bytes, "\"data\":") != null);
}

test "WalEntry JSON serialization with null data" {
    const allocator = std.testing.allocator;

    const entry = WalEntry{
        .op = .close,
        .ts = 1706540000,
        .id = "bd-null1",
        .data = null,
    };

    const json_bytes = try std.json.Stringify.valueAlloc(allocator, entry, .{});
    defer allocator.free(json_bytes);

    try std.testing.expect(std.mem.indexOf(u8, json_bytes, "\"op\":\"close\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json_bytes, "\"data\":null") != null);
}
