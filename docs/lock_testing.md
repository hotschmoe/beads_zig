# Concurrent Write Stress Test Implementation Plan

## Goal

Add tests to verify that beads_zig's WAL-based storage layer handles concurrent writes correctly:
- No data loss (all writes recorded)
- No corruption (all entries valid JSON)
- No hangs (completes within timeout)
- Proper lock serialization (only one writer at a time)

Target from docs: 5 agents, 20 writes each, <1 second total, zero errors.

---

## Implementation

### Location

Add tests to **`src/storage/wal.zig`** as inline test blocks at the end of the file.

Rationale:
- Tests exercise WAL layer directly
- Keeps related tests with implementation
- Follows existing pattern (lock.zig has inline tests)

---

### Tests to Add

#### Test 1: `test "Wal concurrent writes - no data loss"`

Spawns 5 threads, each doing 20 WAL appends. Verifies all 100 entries are present.

```
Structure:
1. Create temp directory via test_util.createTestDir()
2. Spawn 5 threads with std.Thread.spawn()
3. Each thread: init Wal, append 20 entries with unique IDs
4. Join all threads
5. Read WAL entries, verify count == 100
6. Verify all entries are valid (has id, parseable)
```

#### Test 2: `test "Wal concurrent writes - lock serialization"`

Verifies lock correctly serializes - only one writer active at a time.

```
Structure:
1. Create temp directory
2. Spawn 3 threads, each acquiring lock 10 times
3. Track active_writers with atomic counter
4. Verify max_concurrent never exceeds 1
```

#### Test 3: `test "Wal concurrent writes - performance"`

Verifies performance target from docs.

```
Structure:
1. Create temp directory
2. Record start time
3. Spawn 5 threads, 20 writes each
4. Join threads
5. Verify elapsed < 2000ms (2x margin for CI variance)
```

---

### Thread Worker Pattern

```zig
const ThreadContext = struct {
    thread_id: usize,
    beads_dir: []const u8,
    writes: usize,
    errors: *std.atomic.Value(u32),
    completed: *std.atomic.Value(u32),
};

fn writeWorker(ctx: *const ThreadContext) void {
    // Use page_allocator (thread-safe, unlike testing.allocator)
    const allocator = std.heap.page_allocator;

    var wal = Wal.init(ctx.beads_dir, allocator) catch {
        _ = ctx.errors.fetchAdd(1, .seq_cst);
        return;
    };
    defer wal.deinit();

    for (0..ctx.writes) |i| {
        // Generate unique ID: "bd-t{thread_id}w{write_num}"
        var id_buf: [32]u8 = undefined;
        const id = std.fmt.bufPrint(&id_buf, "bd-t{d}w{d}", .{ctx.thread_id, i})
            catch unreachable;

        const ts = std.time.timestamp();
        const issue = Issue.init(id, id, ts);  // Use id as title

        wal.appendEntry(.{
            .op = .add,
            .ts = ts,
            .id = id,
            .data = issue,
        }) catch {
            _ = ctx.errors.fetchAdd(1, .seq_cst);
            return;
        };
    }

    _ = ctx.completed.fetchAdd(1, .seq_cst);
}
```

---

### Key Implementation Notes

1. **Allocator**: Use `std.heap.page_allocator` in worker threads (thread-safe), not `std.testing.allocator`

2. **Issue Creation**: Use `Issue.init(id, title, timestamp)` from models/issue.zig

3. **Unique IDs**: Format `"bd-t{thread_id}w{write_num}"` ensures no collisions

4. **Atomics**: Use `std.atomic.Value(u32)` for error/completion tracking

5. **Cleanup**: Always defer `wal.deinit()`, `allocator.free()`, `cleanupTestDir()`

---

## Critical Files

| File | Changes |
|------|---------|
| `src/storage/wal.zig` | Add 3 test blocks at end of file |

---

## Verification

After implementation:

```bash
# Run all tests
zig build test

# Expected output for concurrent tests:
# - All 3 tests pass
# - Performance test prints timing info
# - No hangs (tests complete within Zig's default timeout)
```

Manual verification:
1. Run tests multiple times to catch race conditions
2. Check that .test_tmp/ directories are cleaned up
3. Verify no zombie lock files left behind

---

## Related Beads

- `bd-1pz` - Add concurrent write stress tests (P2)
- `bd-fw7` - Implement BeadsLock (completed)
- `bd-1sd` - Implement WAL operations (completed)
