# Concurrent Write Handling in beads_zig

## The Problem You Just Hit

```
Database lock on a retry...
Database lock from concurrent access...
All these failed retries are expected noise from parallel agent execution
```

Five agents hammering SQLite simultaneously = lock contention hell. SQLite's locking is designed for "occasional concurrent writes," not "five processes racing to INSERT at the same moment."

**This document specifies how beads_zig handles concurrent writes without SQLite, using file-based primitives that actually work under heavy parallel load.**

---

## Table of Contents

1. [Why SQLite Locking Fails Here](#why-sqlite-locking-fails-here)
2. [Design Goals](#design-goals)
3. [Architecture: Lock + Append + Compact](#architecture-lock--append--compact)
4. [Implementation](#implementation)
5. [Retry Strategy](#retry-strategy)
6. [Alternative Approaches Considered](#alternative-approaches-considered)
7. [Testing Concurrent Writes](#testing-concurrent-writes)
8. [Agent Guidelines](#agent-guidelines)

---

## Why SQLite Locking Fails Here

SQLite uses file-level locking with multiple states:

```
UNLOCKED → SHARED → RESERVED → PENDING → EXCLUSIVE
```

The problem: **RESERVED → EXCLUSIVE promotion fails under contention.**

When Agent A has RESERVED (preparing to write) and Agent B has SHARED (reading), Agent A must wait for B to release. If B then tries to get RESERVED, you get:

```
Agent A: RESERVED, waiting for B's SHARED to release
Agent B: SHARED, trying to get RESERVED, blocked by A
Result: SQLITE_BUSY after timeout
```

WAL mode helps but doesn't eliminate it. With 5 agents doing rapid writes:

```
Agent 1: write → retry → write → success
Agent 2: write → BUSY → retry → BUSY → retry → success  
Agent 3: write → BUSY → BUSY → BUSY → BUSY → success
Agent 4: write → BUSY → BUSY → BUSY → BUSY → BUSY → success
Agent 5: write → BUSY → BUSY → BUSY → BUSY → BUSY → BUSY → give up
```

The retry storms compound. Each retry holds locks longer, making other retries more likely.

---

## Design Goals

1. **Zero lock contention on reads** — Reading never blocks, ever
2. **Serialized writes** — Only one writer at a time, but waiting is bounded  
3. **No busy-wait retry loops** — Block on lock, don't spin
4. **Atomic visibility** — Readers see complete state or previous state, never partial
5. **Crash safety** — Process death never corrupts data
6. **Simple implementation** — No daemon, no IPC, just files

---

## Architecture: Lock + Append + Compact

### Core Insight

Separate the **write path** from the **read path**:

```
Write path:
  acquire lock → append to WAL → release lock
  
Read path (no lock needed):
  read main file + read WAL → merge in memory

Compaction (periodic):
  acquire lock → merge WAL into main → truncate WAL → release lock
```

### File Structure

```
.beads/
  beads.jsonl       # Main file (compacted state)
  beads.wal         # Write-ahead log (recent appends)  
  beads.lock        # Lock file (flock target)
```

### Write Flow

```
Agent wants to add issue:

1. Open .beads/beads.lock (create if missing)
2. flock(LOCK_EX) — blocks until lock acquired
3. Append to .beads/beads.wal:
   {"op":"add","ts":1706540000,"data":{...issue...}}
4. fsync .beads/beads.wal
5. flock(LOCK_UN)
6. Close lock file

Total lock hold time: ~1ms (just an append + fsync)
```

### Read Flow

```
Agent wants to list issues:

1. Read .beads/beads.jsonl (main file)
2. Read .beads/beads.wal (if exists)
3. Replay WAL operations on top of main file state
4. Return merged result

No locks acquired. Atomic because:
- Main file only changes during compaction (atomic rename)
- WAL is append-only, partial reads just miss recent ops
```

### Compaction Flow

```
Triggered when: WAL > 100 ops OR WAL > 100KB OR explicit `bz compact`

1. flock(LOCK_EX) on beads.lock
2. Read beads.jsonl into memory
3. Replay beads.wal operations  
4. Write merged state to beads.jsonl.tmp
5. fsync beads.jsonl.tmp
6. rename(beads.jsonl.tmp, beads.jsonl)  — atomic
7. truncate beads.wal to 0
8. flock(LOCK_UN)

Lock hold time: ~10-50ms for typical repos
```

---

## Implementation

### Lock File Operations

```zig
const std = @import("std");
const posix = std.posix;

pub const BeadsLock = struct {
    file: std.fs.File,
    
    const lock_path = ".beads/beads.lock";
    
    /// Acquire exclusive lock. Blocks until available.
    pub fn acquire() !BeadsLock {
        // Create .beads directory if needed
        std.fs.cwd().makeDir(".beads") catch |err| {
            if (err != error.PathAlreadyExists) return err;
        };
        
        // Open or create lock file
        const file = try std.fs.cwd().createFile(lock_path, .{
            .read = true,
            .truncate = false,  // Don't truncate existing
        });
        
        // Block until we get exclusive lock
        // This is the key difference from SQLite's approach:
        // We BLOCK, not BUSY-RETRY
        try posix.flock(file.handle, posix.LOCK.EX);
        
        return .{ .file = file };
    }
    
    /// Try to acquire lock without blocking.
    /// Returns null if lock is held by another process.
    pub fn tryAcquire() !?BeadsLock {
        const file = std.fs.cwd().createFile(lock_path, .{
            .read = true,
            .truncate = false,
        }) catch |err| {
            return err;
        };
        
        posix.flock(file.handle, posix.LOCK.EX | posix.LOCK.NB) catch |err| {
            if (err == error.WouldBlock) {
                file.close();
                return null;
            }
            return err;
        };
        
        return .{ .file = file };
    }
    
    /// Acquire with timeout (in milliseconds).
    pub fn acquireTimeout(timeout_ms: u64) !?BeadsLock {
        const deadline = std.time.milliTimestamp() + @as(i64, @intCast(timeout_ms));
        
        while (std.time.milliTimestamp() < deadline) {
            if (try tryAcquire()) |lock| {
                return lock;
            }
            // Sleep 10ms between attempts
            std.time.sleep(10 * std.time.ns_per_ms);
        }
        
        return null;  // Timeout
    }
    
    /// Release lock. Called automatically if BeadsLock goes out of scope via defer.
    pub fn release(self: *BeadsLock) void {
        posix.flock(self.file.handle, posix.LOCK.UN) catch {};
        self.file.close();
    }
};

/// Execute a function while holding the beads lock.
pub fn withLock(comptime f: fn () anyerror!void) !void {
    var lock = try BeadsLock.acquire();
    defer lock.release();
    try f();
}
```

### WAL Entry Format

```zig
const WalOp = enum {
    add,
    update,
    close,
    reopen,
    delete,
    set_blocked,
    unset_blocked,
};

const WalEntry = struct {
    op: WalOp,
    ts: i64,           // Unix timestamp (for ordering)
    id: []const u8,    // Issue ID
    data: ?Issue,      // Full issue for add/update, null for others
    
    pub fn serialize(self: WalEntry, writer: anytype) !void {
        try std.json.stringify(self, .{}, writer);
        try writer.writeByte('\n');
    }
    
    pub fn parse(line: []const u8) !WalEntry {
        return try std.json.parseFromSlice(WalEntry, allocator, line, .{});
    }
};
```

### Append to WAL

```zig
pub fn appendWalEntry(entry: WalEntry) !void {
    var lock = try BeadsLock.acquire();
    defer lock.release();
    
    const wal_path = ".beads/beads.wal";
    
    // Open for append, create if missing
    const file = try std.fs.cwd().createFile(wal_path, .{
        .read = false,
        .truncate = false,
    });
    defer file.close();
    
    // Seek to end
    try file.seekFromEnd(0);
    
    // Write entry
    var writer = file.writer();
    try entry.serialize(writer);
    
    // Ensure durability
    try file.sync();
}

// Convenience wrappers
pub fn addIssue(issue: Issue) !void {
    try appendWalEntry(.{
        .op = .add,
        .ts = std.time.timestamp(),
        .id = issue.id,
        .data = issue,
    });
}

pub fn closeIssue(id: []const u8) !void {
    try appendWalEntry(.{
        .op = .close,
        .ts = std.time.timestamp(),
        .id = id,
        .data = null,
    });
}

pub fn updateIssue(issue: Issue) !void {
    try appendWalEntry(.{
        .op = .update,
        .ts = std.time.timestamp(),
        .id = issue.id,
        .data = issue,
    });
}
```

### Read with WAL Replay

```zig
pub const IssueStore = struct {
    allocator: Allocator,
    issues: std.StringHashMap(Issue),
    
    pub fn load(allocator: Allocator) !IssueStore {
        var store = IssueStore{
            .allocator = allocator,
            .issues = std.StringHashMap(Issue).init(allocator),
        };
        
        // Load main file
        if (std.fs.cwd().openFile(".beads/beads.jsonl", .{})) |file| {
            defer file.close();
            try store.loadJsonl(file);
        } else |_| {
            // No main file yet, that's OK
        }
        
        // Replay WAL
        if (std.fs.cwd().openFile(".beads/beads.wal", .{})) |file| {
            defer file.close();
            try store.replayWal(file);
        } else |_| {
            // No WAL yet, that's OK  
        }
        
        return store;
    }
    
    fn loadJsonl(self: *IssueStore, file: std.fs.File) !void {
        var reader = file.reader();
        var buf: [1024 * 1024]u8 = undefined;  // 1MB line buffer
        
        while (reader.readUntilDelimiter(&buf, '\n')) |line| {
            const issue = try std.json.parseFromSlice(Issue, self.allocator, line, .{});
            try self.issues.put(issue.id, issue);
        } else |err| {
            if (err != error.EndOfStream) return err;
        }
    }
    
    fn replayWal(self: *IssueStore, file: std.fs.File) !void {
        var reader = file.reader();
        var buf: [1024 * 1024]u8 = undefined;
        
        while (reader.readUntilDelimiter(&buf, '\n')) |line| {
            const entry = try WalEntry.parse(line);
            try self.applyWalEntry(entry);
        } else |err| {
            if (err != error.EndOfStream) return err;
        }
    }
    
    fn applyWalEntry(self: *IssueStore, entry: WalEntry) !void {
        switch (entry.op) {
            .add, .update => {
                if (entry.data) |issue| {
                    try self.issues.put(issue.id, issue);
                }
            },
            .close => {
                if (self.issues.getPtr(entry.id)) |issue| {
                    issue.status = .closed;
                    issue.updated_at = entry.ts;
                }
            },
            .reopen => {
                if (self.issues.getPtr(entry.id)) |issue| {
                    issue.status = .open;
                    issue.updated_at = entry.ts;
                }
            },
            .delete => {
                _ = self.issues.remove(entry.id);
            },
            .set_blocked => {
                if (self.issues.getPtr(entry.id)) |issue| {
                    issue.status = .blocked;
                    issue.updated_at = entry.ts;
                }
            },
            .unset_blocked => {
                if (self.issues.getPtr(entry.id)) |issue| {
                    if (issue.status == .blocked) {
                        issue.status = .open;
                    }
                    issue.updated_at = entry.ts;
                }
            },
        }
    }
};
```

### Compaction

```zig
pub fn compact() !void {
    var lock = try BeadsLock.acquire();
    defer lock.release();
    
    const main_path = ".beads/beads.jsonl";
    const wal_path = ".beads/beads.wal";
    const tmp_path = ".beads/beads.jsonl.tmp";
    
    // Load current state (main + WAL)
    var store = try IssueStore.load(allocator);
    defer store.deinit();
    
    // Write merged state to temp file
    const tmp_file = try std.fs.cwd().createFile(tmp_path, .{});
    defer tmp_file.close();
    
    var writer = tmp_file.writer();
    var iter = store.issues.iterator();
    while (iter.next()) |entry| {
        try std.json.stringify(entry.value_ptr.*, .{}, writer);
        try writer.writeByte('\n');
    }
    
    try tmp_file.sync();
    
    // Atomic replace
    try std.fs.cwd().rename(tmp_path, main_path);
    
    // Truncate WAL
    const wal_file = try std.fs.cwd().createFile(wal_path, .{
        .truncate = true,
    });
    wal_file.close();
}

pub fn maybeCompact() !void {
    // Check if compaction needed
    const stat = std.fs.cwd().statFile(".beads/beads.wal") catch return;
    
    // Compact if WAL > 100KB
    if (stat.size > 100 * 1024) {
        try compact();
    }
}
```

---

## Retry Strategy

Even with flock, we need graceful handling of edge cases:

### Bounded Wait with Backoff

```zig
pub const RetryConfig = struct {
    max_attempts: u32 = 5,
    initial_delay_ms: u64 = 10,
    max_delay_ms: u64 = 1000,
    jitter: bool = true,
};

pub fn withRetry(
    config: RetryConfig,
    comptime f: fn () anyerror!void,
) !void {
    var attempt: u32 = 0;
    var delay_ms = config.initial_delay_ms;
    var rng = std.rand.DefaultPrng.init(@intCast(std.time.timestamp()));
    
    while (attempt < config.max_attempts) : (attempt += 1) {
        f() catch |err| {
            if (err == error.WouldBlock or err == error.LockBusy) {
                // Add jitter to prevent thundering herd
                var actual_delay = delay_ms;
                if (config.jitter) {
                    actual_delay += rng.random().intRangeAtMost(u64, 0, delay_ms / 2);
                }
                
                std.time.sleep(actual_delay * std.time.ns_per_ms);
                
                // Exponential backoff with cap
                delay_ms = @min(delay_ms * 2, config.max_delay_ms);
                continue;
            }
            return err;
        };
        return;  // Success
    }
    
    return error.MaxRetriesExceeded;
}
```

### Jittered Exponential Backoff

Why jitter matters with 5 agents:

```
Without jitter:
  Agent 1: wait 10ms → retry
  Agent 2: wait 10ms → retry  
  Agent 3: wait 10ms → retry
  Agent 4: wait 10ms → retry
  Agent 5: wait 10ms → retry
  → All 5 wake up simultaneously, 4 fail again

With jitter:
  Agent 1: wait 12ms → retry
  Agent 2: wait 8ms → retry → SUCCESS
  Agent 3: wait 15ms → retry
  Agent 4: wait 11ms → retry  
  Agent 5: wait 9ms → retry → SUCCESS
  → Spread out, less contention
```

### Timeout Wrapper for CLI

```zig
pub fn runWithTimeout(comptime f: fn () anyerror!void, timeout_ms: u64) !void {
    const start = std.time.milliTimestamp();
    
    while (true) {
        const elapsed = std.time.milliTimestamp() - start;
        if (elapsed >= timeout_ms) {
            return error.OperationTimeout;
        }
        
        f() catch |err| {
            if (err == error.WouldBlock) {
                std.time.sleep(10 * std.time.ns_per_ms);
                continue;
            }
            return err;
        };
        return;
    }
}
```

---

## Alternative Approaches Considered

### 1. Pure flock on JSONL (No WAL)

```
Write: flock → read all → append/modify → write all → unlock
```

**Problem:** Lock hold time scales with file size. 1000 issues = ~100ms lock hold = high contention.

**Verdict:** Rejected. WAL keeps lock time constant (~1ms).

### 2. Lockfile with PID

```
Write: create .beads.lock with PID → check for stale → write → delete lock
```

**Problem:** Stale lock detection is racy. If process A checks, then process B checks, then A writes PID, then B writes PID... both think they have the lock.

**Verdict:** Rejected. flock is atomic and kernel-managed.

### 3. Per-Issue Files

```
.beads/
  issues/
    AUTH-001.json
    AUTH-002.json
    ...
```

**Problem:** 
- Listing issues = readdir + N file reads
- Atomic multi-issue operations (update + close) require coordination
- Git diffs become noisy (one file per change)

**Verdict:** Rejected. Overhead not worth the benefit.

### 4. Named Semaphores (POSIX)

```zig
const sem = try std.posix.sem_open("/beads_lock", ...);
```

**Problem:**
- Semaphores persist beyond process lifetime
- Cleanup on crash is complex
- Not available on all platforms

**Verdict:** Rejected. flock auto-releases on process death.

### 5. Advisory Record Locking (fcntl)

```zig
try std.posix.fcntl(file.handle, F_SETLKW, &lock_struct);
```

**Problem:**
- More complex API
- Platform-specific behavior differences
- No clear advantage over flock for our use case

**Verdict:** Rejected. flock is simpler and sufficient.

### 6. Append-Only Log (No Compaction)

```
Every operation appends, never rewrite.
Read = replay entire log.
```

**Problem:**
- Read time grows unbounded
- File size grows unbounded
- 100 adds + 100 closes = 200 entries for 0 active issues

**Verdict:** Rejected. Need compaction for long-running projects.

### 7. SQLite WAL Mode with Busy Timeout

```sql
PRAGMA journal_mode=WAL;
PRAGMA busy_timeout=5000;
```

**Problem:** This is what beads_rust presumably does, and you still hit issues. The fundamental problem is SQLite's locking granularity—it locks at page/table level, not row level. Concurrent INSERTs to the same table still contend.

**Verdict:** Rejected. We're removing SQLite entirely.

---

## Testing Concurrent Writes

### Stress Test Script

```bash
#!/bin/bash
# stress_test.sh - Spawn N agents writing simultaneously

N=${1:-5}
ITERATIONS=${2:-20}

# Clean slate
rm -rf .beads
mkdir -p .beads

# Spawn agents
for i in $(seq 1 $N); do
    (
        for j in $(seq 1 $ITERATIONS); do
            bz add "Agent $i Issue $j" --priority $((j % 5)) 2>&1 | grep -i "error" &
        done
        wait
    ) &
done

wait

# Verify
EXPECTED=$((N * ITERATIONS))
ACTUAL=$(bz list --json | jq '.issues | length')

echo "Expected: $EXPECTED issues"
echo "Actual:   $ACTUAL issues"

if [ "$EXPECTED" -eq "$ACTUAL" ]; then
    echo "✓ PASS: All issues created"
    exit 0
else
    echo "✗ FAIL: Missing issues"
    exit 1
fi
```

### Zig Test

```zig
const std = @import("std");
const beads = @import("beads");

test "concurrent writes" {
    // Clean slate
    std.fs.cwd().deleteTree(".beads") catch {};
    
    const num_threads = 5;
    const writes_per_thread = 20;
    
    var threads: [num_threads]std.Thread = undefined;
    
    for (0..num_threads) |i| {
        threads[i] = try std.Thread.spawn(.{}, writeIssues, .{ i, writes_per_thread });
    }
    
    for (&threads) |*t| {
        t.join();
    }
    
    // Verify
    const store = try beads.IssueStore.load(std.testing.allocator);
    defer store.deinit();
    
    const expected = num_threads * writes_per_thread;
    try std.testing.expectEqual(expected, store.issues.count());
}

fn writeIssues(thread_id: usize, count: usize) void {
    for (0..count) |i| {
        const title = std.fmt.allocPrint(
            std.heap.page_allocator,
            "Thread {d} Issue {d}",
            .{ thread_id, i },
        ) catch continue;
        
        beads.addIssue(.{
            .id = generateId(),
            .title = title,
            .status = .open,
            .priority = @intCast(i % 5),
        }) catch |err| {
            std.debug.print("Thread {d}: {}\n", .{ thread_id, err });
        };
    }
}
```

### Chaos Test

```zig
test "chaos: concurrent writes with random crashes" {
    // Simulate process crashes mid-write
    // Verify data integrity after
    
    for (0..100) |iteration| {
        var threads: [10]std.Thread = undefined;
        
        for (0..10) |i| {
            threads[i] = try std.Thread.spawn(.{}, chaosWrite, .{i});
        }
        
        // Kill random threads after random delay
        std.time.sleep(std.rand.int(u64) % 10 * std.time.ns_per_ms);
        for (0..3) |_| {
            const victim = std.rand.int(usize) % 10;
            threads[victim].detach();  // Simulate crash
        }
        
        // Wait for survivors
        for (&threads) |*t| {
            t.join() catch continue;
        }
        
        // Verify: no corruption, all committed writes visible
        const store = try beads.IssueStore.load(std.testing.allocator);
        defer store.deinit();
        
        // Each issue should have valid data
        var iter = store.issues.iterator();
        while (iter.next()) |entry| {
            try std.testing.expect(entry.value_ptr.title.len > 0);
            try std.testing.expect(entry.value_ptr.id.len > 0);
        }
    }
}
```

---

## Agent Guidelines

### For Agent Developers

Include this in your agent's system prompt or AGENTS.md:

```markdown
## beads_zig Concurrent Write Guidelines

beads_zig uses file locking for concurrent access. Follow these rules:

### DO:
- Use `bz add`, `bz close`, `bz update` normally
- Operations automatically acquire/release locks
- Failed operations are safe to retry immediately

### DON'T:
- Don't spawn more than 10 parallel agents per repo
- Don't implement your own retry loops (bz handles this)
- Don't manually edit beads.jsonl while agents are running
- Don't delete .beads/beads.lock

### If you see "lock busy" errors:
1. It's temporary, operation will auto-retry
2. If persistent (>5s), another agent may be stuck
3. Check for zombie agent processes: `ps aux | grep bz`
4. As last resort: `rm .beads/beads.lock` (only if no agents running!)

### Recommended parallel agent pattern:
```bash
# Each agent works on independent tasks
agent1: bz add "Task 1" && work && bz close TASK-1
agent2: bz add "Task 2" && work && bz close TASK-2
# Agents naturally serialize on writes, parallel on work
```

### Anti-pattern (causes contention):
```bash
# All agents writing rapidly
for i in {1..100}; do bz add "Task $i"; done &
for i in {1..100}; do bz add "Task $i"; done &
for i in {1..100}; do bz add "Task $i"; done &
# This creates lock storms
```

### Optimal pattern for bulk operations:
```bash
# Collect all issues, single write
bz add-batch << EOF
Task 1
Task 2
Task 3
EOF
# Or: prepare JSON, single atomic import
bz import tasks.json
```
```

### CLI Feedback for Lock Waits

When the CLI has to wait for a lock, provide feedback:

```zig
pub fn addIssueWithFeedback(issue: Issue) !void {
    const lock = BeadsLock.tryAcquire() catch |err| return err;
    
    if (lock) |l| {
        defer l.release();
        try appendIssue(issue);
        return;
    }
    
    // Lock busy, show waiting message
    std.debug.print("⏳ Waiting for lock (another agent is writing)...\n", .{});
    
    var actual_lock = try BeadsLock.acquireTimeout(5000);
    defer actual_lock.release();
    
    std.debug.print("✓ Lock acquired\n", .{});
    try appendIssue(issue);
}
```

### JSON Output for Lock Status

```json
{
  "status": "waiting",
  "reason": "lock_busy",
  "waited_ms": 234,
  "message": "Another process holds the lock"
}
```

```json
{
  "status": "success",
  "waited_ms": 234,
  "id": "AUTH-001"
}
```

```json
{
  "status": "error",
  "reason": "lock_timeout",
  "waited_ms": 5000,
  "message": "Could not acquire lock after 5000ms"
}
```

---

## Appendix: Lock Behavior Reference

### flock Guarantees

| Scenario | Behavior |
|----------|----------|
| Process A holds LOCK_EX, Process B calls LOCK_EX | B blocks until A releases |
| Process A holds LOCK_EX, Process B calls LOCK_EX\|LOCK_NB | B gets EWOULDBLOCK immediately |
| Process A crashes while holding lock | Lock automatically released by kernel |
| Process A holds lock, forks to B | Both A and B share the lock |
| File deleted while locked | Lock remains valid until all handles closed |

### Platform Notes

| Platform | flock Support | Notes |
|----------|---------------|-------|
| Linux | ✓ Native | Works across NFS with NFSv4 |
| macOS | ✓ Native | Full support |
| Windows | ✗ | Use LockFileEx instead |
| FreeBSD | ✓ Native | Full support |

### Windows Compatibility

```zig
const builtin = @import("builtin");

pub fn acquireLock(file: std.fs.File) !void {
    if (builtin.os.tag == .windows) {
        // Windows uses LockFileEx
        const windows = std.os.windows;
        var overlapped = std.mem.zeroes(windows.OVERLAPPED);
        
        const result = windows.kernel32.LockFileEx(
            file.handle,
            windows.LOCKFILE_EXCLUSIVE_LOCK,
            0,
            std.math.maxInt(u32),
            std.math.maxInt(u32),
            &overlapped,
        );
        
        if (result == 0) {
            return error.LockFailed;
        }
    } else {
        try std.posix.flock(file.handle, std.posix.LOCK.EX);
    }
}
```

---

## Summary

The Lock + WAL + Compact architecture provides:

1. **Constant-time writes** (~1ms lock hold) regardless of file size
2. **Lock-free reads** (no contention for list/show/status)
3. **Automatic crash recovery** (flock released by kernel)
4. **Bounded file growth** (periodic compaction)
5. **Atomic visibility** (readers see consistent state)

This is simpler and more robust than SQLite for our workload of rapid concurrent appends from multiple agents. The key insight is separating the write path (append to WAL) from the read path (merge main + WAL), keeping lock hold times minimal.

**Expected result:** 5 agents, 20 writes each, <1 second total, zero retries, zero errors.
