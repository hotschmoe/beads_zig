# Concurrency Critique: beads_zig

## Executive Summary

The `concurrent_writes.md` document presents a solid foundation for handling concurrent agent writes. The Lock + WAL + Compact architecture is fundamentally sound and addresses the real failure modes you hit with SQLite.

This document identifies edge cases, gotchas, and additional features to make beads_zig production-ready for aggressive multi-agent workloads.

---

## Table of Contents

1. [What the Current Design Gets Right](#what-the-current-design-gets-right)
2. [Critical Gotchas & Edge Cases](#critical-gotchas--edge-cases)
3. [Missing Features for Production](#missing-features-for-production)
4. [Zig-Specific Optimizations](#zig-specific-optimizations)
5. [Robustness Enhancements](#robustness-enhancements)
6. [Testing Strategy](#testing-strategy)
7. [Implementation Priorities](#implementation-priorities)

---

## What the Current Design Gets Right

### 1. Blocking Instead of Busy-Retry

```zig
// Your design: kernel manages the queue
try posix.flock(file.handle, posix.LOCK.EX);

// SQLite's approach: userspace retry storms
while (sqlite3_step() == SQLITE_BUSY) {
    sleep(random_backoff);  // Causes thundering herd
}
```

This single decision eliminates the core problem. The kernel maintains a FIFO queue of waiters. No starvation, no thundering herd, predictable latency.

### 2. Separation of Read and Write Paths

Lock-free reads are the right call. Agents query status constantly (`bz ready`, `bz list`). Making these lock-free means:
- 10 agents can read simultaneously with zero contention
- A slow writer doesn't block status checks
- No reader-writer priority inversions

### 3. Minimal Lock Hold Time

```
SQLite write: 5-50ms (B-tree updates, page writes, checkpointing)
Your write: ~1ms (append + fsync)
```

Reducing the critical section to one append operation is optimal. You can't make it smaller without sacrificing durability.

### 4. Crash Safety by Construction

The kernel releases flocks on process death. No orphaned `-wal` or `-shm` files. No journal corruption. No "database is locked" zombies.

---

## Critical Gotchas & Edge Cases

### Gotcha 1: Timestamp Collisions in WAL

**Problem:** Two agents on the same machine can write within the same millisecond. Timestamp alone doesn't guarantee ordering.

```
Agent A writes at ts=1706540000123
Agent B writes at ts=1706540000123  // Same millisecond!

// During replay, which came first?
```

**Solution:** Add a monotonic sequence number:

```zig
const WalEntry = struct {
    op: WalOp,
    ts: i64,
    seq: u64,  // Monotonically increasing within this WAL
    id: []const u8,
    data: ?Issue,
};

pub fn appendWalEntry(entry: WalEntry) !void {
    var lock = try BeadsLock.acquire();
    defer lock.release();
    
    // Read current max seq from WAL (or 0 if empty)
    const current_seq = try getMaxSeq() orelse 0;
    
    var entry_with_seq = entry;
    entry_with_seq.seq = current_seq + 1;
    
    // ... append entry_with_seq
}
```

**Alternative:** Use a hybrid logical clock (HLC) that combines wall time with logical sequence:

```zig
const HLC = struct {
    wall_time: i64,
    logical: u32,
    
    pub fn tick(self: *HLC) HLC {
        const now = std.time.milliTimestamp();
        if (now > self.wall_time) {
            return .{ .wall_time = now, .logical = 0 };
        } else {
            return .{ .wall_time = self.wall_time, .logical = self.logical + 1 };
        }
    }
    
    pub fn compare(a: HLC, b: HLC) std.math.Order {
        if (a.wall_time != b.wall_time) return std.math.order(a.wall_time, b.wall_time);
        return std.math.order(a.logical, b.logical);
    }
};
```

---

### Gotcha 2: Partial WAL Read During Compaction

**Problem:** Reader and compactor race:

```
Time 0: Reader opens WAL, starts reading at position 0
Time 1: Reader has read entries 1-50
Time 2: Compactor acquires lock, truncates WAL
Time 3: Reader continues from position 50... but WAL is now empty or different!
```

**Solution A: Generation Numbers**

```
.beads/
  issues.wal.1      # Generation 1
  issues.wal.2      # Generation 2 (created during compaction)
  issues.generation # Contains "2"
```

Compaction creates a new WAL file. Readers track which generation they started with.

```zig
pub fn loadState(allocator: Allocator) !State {
    // Atomically read generation
    const gen = try readGeneration();
    
    // Read snapshot
    const snapshot = try readSnapshot(allocator);
    
    // Read WAL for this generation
    const wal_path = try std.fmt.allocPrint(allocator, ".beads/issues.wal.{d}", .{gen});
    const wal = try readWal(allocator, wal_path);
    
    // If generation changed during read, retry
    if (try readGeneration() != gen) {
        // Compaction happened mid-read, retry
        return loadState(allocator);
    }
    
    return applyWal(snapshot, wal);
}
```

**Solution B: Copy-on-Write Compaction**

Never truncate; always create new files atomically:

```zig
pub fn compact() !void {
    var lock = try BeadsLock.acquire();
    defer lock.release();
    
    // 1. Read current state
    const snapshot = try readSnapshot(allocator);
    const wal = try readWal(allocator);
    const merged = try applyWal(snapshot, wal);
    
    // 2. Write new snapshot
    try writeAtomic(".beads/issues.snapshot.tmp", merged);
    
    // 3. Atomic swap
    try std.fs.cwd().rename(".beads/issues.snapshot.tmp", ".beads/issues.snapshot");
    
    // 4. Create fresh WAL (don't truncate old one)
    try std.fs.cwd().rename(".beads/issues.wal", ".beads/issues.wal.old");
    _ = try std.fs.cwd().createFile(".beads/issues.wal", .{});
    try std.fs.cwd().deleteFile(".beads/issues.wal.old");
}
```

---

### Gotcha 3: NFS and Network Filesystems

**Problem:** `flock` behavior on NFS is... complicated.

| NFS Version | flock Behavior |
|-------------|----------------|
| NFSv2/v3    | Advisory only, may not work across clients |
| NFSv4       | Mandatory, but lease-based with timeouts |
| CIFS/SMB    | Works, but different semantics |

**Solution:** Document and detect:

```zig
pub fn checkFilesystemSafety(path: []const u8) !FilesystemCheck {
    // Get filesystem type
    var statfs_buf: std.c.Statfs = undefined;
    if (std.c.statfs(path, &statfs_buf) != 0) {
        return error.StatfsFailed;
    }
    
    const fs_type = statfs_buf.f_type;
    
    // Known problematic filesystems
    const NFS_MAGIC = 0x6969;
    const CIFS_MAGIC = 0xFF534D42;
    
    if (fs_type == NFS_MAGIC) {
        return .{ .safe = false, .reason = "NFS detected - flock may not work across clients" };
    }
    
    return .{ .safe = true, .reason = null };
}

// On init, warn user
pub fn init() !void {
    const check = try checkFilesystemSafety(".beads");
    if (!check.safe) {
        std.log.warn("⚠️  {s}", .{check.reason.?});
        std.log.warn("⚠️  Concurrent access from multiple machines may cause corruption", .{});
    }
}
```

---

### Gotcha 4: WAL File Growth Under Continuous Load

**Problem:** With 10 agents writing continuously, compaction may never get a chance to run:

```
Agent writes → WAL grows
Agent writes → WAL grows
Agent writes → WAL grows
Compaction triggered... but lock is always held by writers
WAL grows to 100MB
```

**Solution:** Priority compaction with write backoff:

```zig
const CompactionState = struct {
    wal_size: u64,
    last_compaction: i64,
    pending_writers: std.atomic.Value(u32),
};

pub fn appendWalEntry(state: *CompactionState, entry: WalEntry) !void {
    // If WAL is huge, yield to allow compaction
    if (state.wal_size > 1_000_000) {  // 1MB
        std.time.sleep(10 * std.time.ns_per_ms);  // Back off 10ms
    }
    
    _ = state.pending_writers.fetchAdd(1, .seq_cst);
    defer _ = state.pending_writers.fetchSub(1, .seq_cst);
    
    var lock = try BeadsLock.acquire();
    defer lock.release();
    
    // ... append
    state.wal_size += entry_size;
}

pub fn compactIfNeeded(state: *CompactionState) !void {
    // Only compact if WAL is large AND writers are idle
    if (state.wal_size < 100_000) return;  // <100KB, don't bother
    if (state.pending_writers.load(.seq_cst) > 0) return;  // Writers active
    
    // Proceed with compaction
    try compact();
    state.wal_size = 0;
    state.last_compaction = std.time.timestamp();
}
```

---

### Gotcha 5: Incomplete JSON Lines

**Problem:** Process crashes mid-write, leaving partial JSON:

```
{"op":"add","ts":1706540000,"id":"AUTH-001","data":{"title":"Fix bug
```

Next reader tries to parse this and explodes.

**Solution:** Length-prefix or checksum validation:

```zig
// Option A: Length prefix (simple)
pub fn appendEntry(file: std.fs.File, entry: WalEntry) !void {
    var buf: [65536]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    try std.json.stringify(entry, .{}, stream.writer());
    
    const json = stream.getWritten();
    
    // Write: [length:u32][json][newline]
    try file.writer().writeInt(u32, @intCast(json.len), .little);
    try file.writer().writeAll(json);
    try file.writer().writeByte('\n');
}

pub fn readEntries(data: []const u8) ![]WalEntry {
    var entries = std.ArrayList(WalEntry).init(allocator);
    var pos: usize = 0;
    
    while (pos + 4 < data.len) {
        const len = std.mem.readInt(u32, data[pos..][0..4], .little);
        pos += 4;
        
        if (pos + len > data.len) {
            // Incomplete entry, stop here (crash recovery)
            break;
        }
        
        const json = data[pos..][0..len];
        try entries.append(try std.json.parseFromSlice(WalEntry, allocator, json, .{}));
        pos += len + 1;  // +1 for newline
    }
    
    return entries.toOwnedSlice();
}
```

```zig
// Option B: CRC32 checksum (more robust)
pub fn appendEntry(file: std.fs.File, entry: WalEntry) !void {
    var buf: [65536]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    try std.json.stringify(entry, .{}, stream.writer());
    
    const json = stream.getWritten();
    const crc = std.hash.Crc32.hash(json);
    
    // Write: [crc:u32][json]\n
    try file.writer().writeInt(u32, crc, .little);
    try file.writer().writeAll(json);
    try file.writer().writeByte('\n');
}

pub fn readEntries(data: []const u8) ![]WalEntry {
    var entries = std.ArrayList(WalEntry).init(allocator);
    var lines = std.mem.splitScalar(u8, data, '\n');
    
    while (lines.next()) |line| {
        if (line.len < 4) continue;
        
        const stored_crc = std.mem.readInt(u32, line[0..4], .little);
        const json = line[4..];
        const computed_crc = std.hash.Crc32.hash(json);
        
        if (stored_crc != computed_crc) {
            std.log.warn("Corrupt WAL entry detected, skipping", .{});
            continue;
        }
        
        try entries.append(try std.json.parseFromSlice(WalEntry, allocator, json, .{}));
    }
    
    return entries.toOwnedSlice();
}
```

---

### Gotcha 6: Clock Skew in Distributed Scenarios

**Problem:** If timestamps are used for conflict resolution and clocks are skewed:

```
Machine A (clock ahead): creates issue at ts=1706540100
Machine B (clock behind): updates same issue at ts=1706540000

// On merge: B's update appears OLDER, gets discarded
// But B's update actually happened AFTER A's create!
```

**Solution:** Don't rely solely on wall clock. Use vector clocks or explicit ordering:

```zig
// Each machine has a unique ID
const MachineId = [16]u8;  // UUID

const VectorClock = struct {
    counts: std.AutoHashMap(MachineId, u64),
    
    pub fn increment(self: *VectorClock, machine: MachineId) void {
        const current = self.counts.get(machine) orelse 0;
        self.counts.put(machine, current + 1);
    }
    
    pub fn merge(self: *VectorClock, other: VectorClock) void {
        var iter = other.counts.iterator();
        while (iter.next()) |entry| {
            const current = self.counts.get(entry.key_ptr.*) orelse 0;
            self.counts.put(entry.key_ptr.*, @max(current, entry.value_ptr.*));
        }
    }
    
    pub fn happensBefore(a: VectorClock, b: VectorClock) bool {
        // a < b iff all(a[i] <= b[i]) and exists(a[j] < b[j])
        // ...
    }
};
```

For beads_zig's use case, this might be overkill. Document the limitation:

```markdown
## Known Limitations

- **Single machine assumed**: beads_zig assumes all agents run on the same machine
  or share a reliable time source. Cross-machine usage with clock skew may cause
  unexpected conflict resolution.
```

---

## Missing Features for Production

### Feature 1: Atomic Batch Operations

Your document mentions `bz add-batch` but it's not implemented. This is critical for:
- Importing issues from another system
- Creating multiple related issues atomically
- Reducing lock acquisitions

```zig
pub fn addBatch(issues: []const Issue) !void {
    var lock = try BeadsLock.acquire();
    defer lock.release();
    
    const file = try openWalAppend();
    defer file.close();
    
    const ts = std.time.timestamp();
    const base_seq = try getMaxSeq() orelse 0;
    
    for (issues, 0..) |issue, i| {
        const entry = WalEntry{
            .op = .add,
            .ts = ts,
            .seq = base_seq + i + 1,
            .id = issue.id,
            .data = issue,
        };
        try entry.serialize(file.writer());
    }
    
    try file.sync();  // One fsync for all entries
}
```

---

### Feature 2: Optimistic Locking for Updates

**Problem:** Two agents read issue state, both decide to update:

```
Agent A: reads issue (status=open), decides to claim
Agent B: reads issue (status=open), decides to claim
Agent A: writes update (status=in_progress, assignee=A)
Agent B: writes update (status=in_progress, assignee=B)  // Overwrites A!
```

**Solution:** Compare-and-swap with version numbers:

```zig
const Issue = struct {
    id: []const u8,
    version: u64,  // Incremented on every update
    // ... other fields
};

pub fn updateIssue(id: []const u8, expected_version: u64, updates: IssueUpdate) !void {
    var lock = try BeadsLock.acquire();
    defer lock.release();
    
    // Load current state
    const current = try loadIssue(id);
    
    if (current.version != expected_version) {
        return error.VersionMismatch;  // Caller should reload and retry
    }
    
    // Apply update with incremented version
    var updated = current;
    updated.version += 1;
    applyUpdates(&updated, updates);
    
    try appendWalEntry(.{
        .op = .update,
        .ts = std.time.timestamp(),
        .id = id,
        .data = updated,
    });
}
```

CLI integration:

```bash
# Claim with optimistic locking
$ bz claim AUTH-001
Error: Issue was modified by another agent. Current state:
  status: in_progress
  assignee: agent-2
  
Retry with --force to overwrite, or choose a different issue.
```

---

### Feature 3: Transaction Log for Debugging

**Problem:** When things go wrong, how do you debug?

**Solution:** Structured logging with correlation IDs:

```zig
const TxnLog = struct {
    pub fn logAcquire(lock_id: u64, waited_ns: u64) void {
        std.log.info("[txn:{d}] lock acquired after {d}ms", .{
            lock_id,
            waited_ns / std.time.ns_per_ms,
        });
    }
    
    pub fn logWrite(lock_id: u64, op: WalOp, issue_id: []const u8) void {
        std.log.info("[txn:{d}] {s} {s}", .{ lock_id, @tagName(op), issue_id });
    }
    
    pub fn logRelease(lock_id: u64, held_ns: u64) void {
        std.log.info("[txn:{d}] lock released after {d}ms", .{
            lock_id,
            held_ns / std.time.ns_per_ms,
        });
    }
};
```

Output:

```
[txn:12345] lock acquired after 23ms
[txn:12345] add AUTH-001
[txn:12345] add AUTH-002  
[txn:12345] lock released after 2ms
[txn:12346] lock acquired after 0ms
[txn:12346] close AUTH-001
[txn:12346] lock released after 1ms
```

---

### Feature 4: Health Check Command

```bash
$ bz doctor

beads_zig health check
======================

✓ Lock file:        .beads/issues.lock (not held)
✓ WAL size:         12.3 KB (47 entries)
✓ Snapshot size:    156.2 KB (1,234 issues)
✓ Last compaction:  2 minutes ago
✓ Filesystem:       ext4 (flock safe)

Issues detected:
  ⚠ WAL has 3 entries with CRC mismatch (will be skipped on read)
  
Recommendations:
  • Run `bz compact` to rebuild snapshot
```

---

### Feature 5: Lock Contention Metrics

```zig
const Metrics = struct {
    lock_acquisitions: std.atomic.Value(u64) = .{ .raw = 0 },
    lock_wait_total_ns: std.atomic.Value(u64) = .{ .raw = 0 },
    lock_hold_total_ns: std.atomic.Value(u64) = .{ .raw = 0 },
    lock_contentions: std.atomic.Value(u64) = .{ .raw = 0 },  // Times we had to wait
    
    pub fn report(self: *Metrics) void {
        const acquisitions = self.lock_acquisitions.load(.monotonic);
        const wait_total = self.lock_wait_total_ns.load(.monotonic);
        const hold_total = self.lock_hold_total_ns.load(.monotonic);
        const contentions = self.lock_contentions.load(.monotonic);
        
        std.debug.print(
            \\Lock Metrics:
            \\  Acquisitions:     {d}
            \\  Contentions:      {d} ({d:.1}%)
            \\  Avg wait time:    {d:.2}ms
            \\  Avg hold time:    {d:.2}ms
            \\
        , .{
            acquisitions,
            contentions,
            @as(f64, @floatFromInt(contentions)) / @as(f64, @floatFromInt(acquisitions)) * 100,
            @as(f64, @floatFromInt(wait_total)) / @as(f64, @floatFromInt(acquisitions)) / std.time.ns_per_ms,
            @as(f64, @floatFromInt(hold_total)) / @as(f64, @floatFromInt(acquisitions)) / std.time.ns_per_ms,
        });
    }
};
```

CLI:

```bash
$ bz metrics
Lock Metrics:
  Acquisitions:     1,234
  Contentions:      89 (7.2%)
  Avg wait time:    12.34ms
  Avg hold time:    1.02ms
```

---

## Zig-Specific Optimizations

### 1. Comptime JSON Schema Validation

```zig
// Generate optimized parser at compile time
const Issue = struct {
    id: []const u8,
    title: []const u8,
    status: Status,
    priority: u8,
    
    pub const jsonParse = std.json.innerParse;
    
    // Comptime validation of required fields
    comptime {
        const fields = @typeInfo(Issue).Struct.fields;
        for (fields) |field| {
            if (@typeInfo(field.type) == .Optional) continue;
            // Non-optional fields are required
        }
    }
};
```

### 2. Arena Allocator for Request Handling

```zig
pub fn handleCommand(gpa: Allocator, args: []const []const u8) !void {
    // Arena for all allocations in this request
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();  // Single free at end
    
    const allocator = arena.allocator();
    
    // All allocations in handleCommandInner use arena
    // No individual frees needed, no leaks possible
    try handleCommandInner(allocator, args);
}
```

### 3. Memory-Mapped File Reading

```zig
pub fn loadWalMmap(path: []const u8) ![]const u8 {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    
    const stat = try file.stat();
    if (stat.size == 0) return &[_]u8{};
    
    // Memory map instead of read
    const mapped = try std.posix.mmap(
        null,
        stat.size,
        std.posix.PROT.READ,
        std.posix.MAP{ .TYPE = .SHARED },
        file.handle,
        0,
    );
    
    return mapped[0..stat.size];
}
```

Benefits:
- Zero-copy: no allocation for file contents
- OS handles caching efficiently
- Large files don't exhaust memory

### 4. SIMD-Accelerated Newline Scanning

```zig
const std = @import("std");

pub fn findNewlines(data: []const u8) []usize {
    var positions = std.ArrayList(usize).init(allocator);
    
    // Use SIMD to scan 16 bytes at a time
    const needle: @Vector(16, u8) = @splat('\n');
    
    var i: usize = 0;
    while (i + 16 <= data.len) : (i += 16) {
        const chunk: @Vector(16, u8) = data[i..][0..16].*;
        const matches = chunk == needle;
        const mask = @as(u16, @bitCast(matches));
        
        // Process each match
        var m = mask;
        while (m != 0) {
            const bit = @ctz(m);
            try positions.append(i + bit);
            m &= m - 1;  // Clear lowest set bit
        }
    }
    
    // Handle remainder
    while (i < data.len) : (i += 1) {
        if (data[i] == '\n') try positions.append(i);
    }
    
    return positions.toOwnedSlice();
}
```

### 5. Compile-Time Operation Dispatch

```zig
pub fn executeOp(comptime op: WalOp) type {
    return struct {
        // Each operation gets its own specialized code path
        // No runtime dispatch overhead
        
        pub fn execute(store: *Store, entry: WalEntry) !void {
            switch (op) {
                .add => try store.issues.put(entry.id, entry.data.?),
                .close => {
                    if (store.issues.getPtr(entry.id)) |issue| {
                        issue.status = .closed;
                        issue.closed_at = entry.ts;
                    }
                },
                .update => {
                    if (store.issues.getPtr(entry.id)) |issue| {
                        applyDiff(issue, entry.data.?);
                    }
                },
                // ... other ops
            }
        }
    };
}

// Usage during WAL replay
inline for (std.enums.values(WalOp)) |op| {
    if (entry.op == op) {
        try executeOp(op).execute(store, entry);
        break;
    }
}
```

---

## Robustness Enhancements

### 1. Graceful Degradation on Corrupt Data

```zig
pub fn loadWithRecovery(allocator: Allocator) !Store {
    var store = Store.init(allocator);
    var corruption_count: usize = 0;
    
    // Load snapshot
    const snapshot_result = loadSnapshot(allocator);
    if (snapshot_result) |snapshot| {
        store.applySnapshot(snapshot);
    } else |err| {
        std.log.err("Snapshot corrupt: {}, starting fresh", .{err});
        corruption_count += 1;
    }
    
    // Load WAL
    const wal_data = try readFile(allocator, ".beads/issues.wal");
    var lines = std.mem.splitScalar(u8, wal_data, '\n');
    
    var line_num: usize = 0;
    while (lines.next()) |line| {
        line_num += 1;
        if (line.len == 0) continue;
        
        const entry = std.json.parseFromSlice(WalEntry, allocator, line, .{}) catch |err| {
            std.log.warn("WAL line {d} corrupt: {}, skipping", .{ line_num, err });
            corruption_count += 1;
            continue;
        };
        
        store.applyEntry(entry) catch |err| {
            std.log.warn("WAL entry {d} invalid: {}, skipping", .{ line_num, err });
            corruption_count += 1;
            continue;
        };
    }
    
    if (corruption_count > 0) {
        std.log.warn("Loaded with {d} corrupt entries skipped", .{corruption_count});
        std.log.warn("Run `bz doctor` for details, `bz compact` to rebuild", .{});
    }
    
    return store;
}
```

### 2. Backup Before Destructive Operations

```zig
pub fn compact() !void {
    var lock = try BeadsLock.acquire();
    defer lock.release();
    
    // Backup current state
    const timestamp = std.time.timestamp();
    const backup_dir = try std.fmt.allocPrint(
        allocator,
        ".beads/backups/{d}",
        .{timestamp},
    );
    try std.fs.cwd().makeDir(backup_dir);
    
    try copyFile(".beads/issues.snapshot", 
                 try std.fmt.allocPrint(allocator, "{s}/issues.snapshot", .{backup_dir}));
    try copyFile(".beads/issues.wal",
                 try std.fmt.allocPrint(allocator, "{s}/issues.wal", .{backup_dir}));
    
    // Proceed with compaction...
    
    // Keep last 5 backups
    try pruneBackups(5);
}
```

### 3. Stale Lock Detection

```zig
pub const BeadsLock = struct {
    file: std.fs.File,
    
    const LOCK_TIMEOUT_MS = 30_000;  // 30 seconds
    
    pub fn acquire() !BeadsLock {
        const file = try openLockFile();
        
        // Try non-blocking first
        if (tryFlock(file, .{ .exclusive = true, .nonblocking = true })) {
            return .{ .file = file };
        }
        
        // Lock is held, check if holder is alive
        const holder_pid = try readLockHolder(file);
        if (holder_pid) |pid| {
            if (!isProcessAlive(pid)) {
                std.log.warn("Stale lock from dead process {d}, breaking", .{pid});
                // Force acquire (safe because holder is dead)
                try posix.flock(file.handle, posix.LOCK.EX);
                try writeLockHolder(file, std.os.linux.getpid());
                return .{ .file = file };
            }
        }
        
        // Holder is alive, wait with timeout
        const start = std.time.milliTimestamp();
        while (std.time.milliTimestamp() - start < LOCK_TIMEOUT_MS) {
            if (tryFlock(file, .{ .exclusive = true, .nonblocking = true })) {
                try writeLockHolder(file, std.os.linux.getpid());
                return .{ .file = file };
            }
            std.time.sleep(10 * std.time.ns_per_ms);
        }
        
        return error.LockTimeout;
    }
};
```

### 4. Fsync Directory for Durability

```zig
pub fn appendWalEntry(entry: WalEntry) !void {
    var lock = try BeadsLock.acquire();
    defer lock.release();
    
    const file = try std.fs.cwd().openFile(".beads/issues.wal", .{ .mode = .write_only });
    defer file.close();
    
    try file.seekFromEnd(0);
    try entry.serialize(file.writer());
    try file.sync();
    
    // Also fsync the directory to ensure the file metadata is durable
    const dir = try std.fs.cwd().openDir(".beads", .{});
    defer dir.close();
    try dir.sync();
}
```

This ensures that even if the system crashes immediately after, the file's existence and size are durable.

---

## Testing Strategy

### Unit Tests

```zig
test "WAL append is atomic" {
    // Simulate crash at various points
    var crash_points = [_]CrashPoint{ .before_write, .during_write, .before_fsync, .after_fsync };
    
    for (crash_points) |crash_point| {
        var mock_fs = MockFilesystem.init();
        mock_fs.crash_at = crash_point;
        
        const result = appendWalEntry(&mock_fs, entry);
        
        // After recovery, WAL should be consistent
        const recovered = loadWal(&mock_fs);
        
        if (crash_point == .after_fsync) {
            try testing.expect(recovered.len == 1);  // Entry committed
        } else {
            try testing.expect(recovered.len == 0);  // Entry not committed
        }
    }
}
```

### Stress Tests

```zig
test "10 agents, 100 writes each, zero corruption" {
    const NUM_AGENTS = 10;
    const WRITES_PER_AGENT = 100;
    
    var threads: [NUM_AGENTS]std.Thread = undefined;
    
    for (0..NUM_AGENTS) |i| {
        threads[i] = try std.Thread.spawn(.{}, agentWorker, .{i});
    }
    
    for (&threads) |*t| {
        t.join();
    }
    
    // Verify
    const store = try Store.load(testing.allocator);
    try testing.expectEqual(NUM_AGENTS * WRITES_PER_AGENT, store.issues.count());
    
    // Verify no duplicate IDs
    var seen = std.StringHashMap(void).init(testing.allocator);
    var iter = store.issues.keyIterator();
    while (iter.next()) |key| {
        try testing.expect(!seen.contains(key.*));
        try seen.put(key.*, {});
    }
}
```

### Chaos Tests

```zig
test "random process kills during writes" {
    for (0..100) |_| {
        var threads: [10]std.Thread = undefined;
        
        for (0..10) |i| {
            threads[i] = try std.Thread.spawn(.{}, chaosWriter, .{});
        }
        
        // Kill random threads after random delay
        std.time.sleep(randomRange(1, 50) * std.time.ns_per_ms);
        for (0..3) |_| {
            threads[randomRange(0, 10)].detach();
        }
        
        // Wait for survivors
        for (&threads) |*t| {
            t.join() catch continue;
        }
        
        // Verify: no corruption
        const store = Store.load(testing.allocator) catch |err| {
            std.debug.panic("Store corrupt after chaos: {}", .{err});
        };
        
        // Every issue should be valid
        var iter = store.issues.valueIterator();
        while (iter.next()) |issue| {
            try testing.expect(issue.id.len > 0);
            try testing.expect(issue.title.len > 0);
        }
    }
}
```

---

## Implementation Priorities

### Phase 1: Core (Week 1)

1. ✅ flock-based locking (you have this)
2. ✅ WAL append (you have this)
3. ✅ Lock-free reads (you have this)
4. 🔲 CRC32 checksums on WAL entries
5. 🔲 Sequence numbers for ordering
6. 🔲 Basic compaction

### Phase 2: Robustness (Week 2)

1. 🔲 Graceful corruption recovery
2. 🔲 Stale lock detection
3. 🔲 Fsync directory
4. 🔲 Backup before compaction
5. 🔲 `bz doctor` command

### Phase 3: Features (Week 3)

1. 🔲 Batch operations (`bz add-batch`, `bz import`)
2. 🔲 Optimistic locking for updates
3. 🔲 Lock contention metrics
4. 🔲 Transaction logging

### Phase 4: Optimization (Week 4)

1. 🔲 Memory-mapped reads
2. 🔲 SIMD newline scanning
3. 🔲 Arena allocators
4. 🔲 Comptime dispatch

---

## Summary

Your concurrent_writes.md establishes the right foundation. The key additions needed are:

| Category | Addition | Priority |
|----------|----------|----------|
| **Correctness** | Sequence numbers for ordering | High |
| **Correctness** | CRC checksums for crash recovery | High |
| **Correctness** | Generation numbers for read/compact race | Medium |
| **Robustness** | Graceful corruption handling | High |
| **Robustness** | Stale lock detection | Medium |
| **Features** | Batch operations | High |
| **Features** | Optimistic locking | Medium |
| **Features** | `bz doctor` health check | Medium |
| **Performance** | Memory-mapped reads | Low |
| **Performance** | SIMD scanning | Low |

The architecture is sound. These additions make it production-ready for the aggressive multi-agent workloads you're targeting.
