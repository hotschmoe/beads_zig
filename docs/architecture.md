# beads_zig Architecture

## Overview

beads_zig is a pure Zig implementation of a local-first issue tracker. It uses a Lock + WAL + Compact architecture for concurrent-safe persistence with in-memory indexing for fast queries.

**Key Difference from beads_rust**: beads_rust uses SQLite with WAL mode. beads_zig uses a custom file-based locking system that eliminates SQLite's lock contention under heavy parallel agent load.

```
┌────────────────────────────────────────────────────────────────┐
│                          CLI Layer                             │
│   Commands: init, create, list, ready, close, sync, etc.       │
│   Output: Text (default) | JSON (--json flag)                  │
└─────────────────────────────┬──────────────────────────────────┘
                              │
┌─────────────────────────────▼──────────────────────────────────┐
│                       Business Logic                           │
│   - Issue lifecycle (create, update, close, reopen)            │
│   - Dependency graph (add, remove, cycle detection)            │
│   - Labels, comments, events                                   │
│   - Ready work calculation (unblocked issues)                  │
│   - Statistics and reporting                                   │
└─────────────────────────────┬──────────────────────────────────┘
                              │
┌─────────────────────────────▼──────────────────────────────────┐
│                       Storage Layer                            │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │                    IssueStore                            │   │
│  │  - ArrayList(Issue) for storage                          │   │
│  │  - StringHashMap for O(1) ID lookup                      │   │
│  │  - Dirty tracking for sync                               │   │
│  └──────────────────────┬──────────────────────────────────┘   │
│                         │                                      │
│  ┌──────────────────────▼──────────────────────────────────┐   │
│  │                  DependencyGraph                         │   │
│  │  - Cycle detection (DFS)                                 │   │
│  │  - Ready/blocked issue queries                           │   │
│  │  - Dependency tree traversal                             │   │
│  └──────────────────────┬──────────────────────────────────┘   │
│                         │                                      │
│  ┌──────────────────────▼──────────────────────────────────┐   │
│  │              Lock + WAL + Compact                        │   │
│  │  - flock-based exclusive locking                         │   │
│  │  - Write-ahead log for constant-time writes              │   │
│  │  - Periodic compaction into main file                    │   │
│  └──────────────────────┬──────────────────────────────────┘   │
└─────────────────────────│──────────────────────────────────────┘
                          ▼
              .beads/beads.jsonl  (main)
              .beads/beads.wal    (write-ahead log)
              .beads/beads.lock   (flock target)
```

---

## Module Structure

```
src/
├── main.zig              # CLI entry point
├── root.zig              # Library exports
├── cli/                  # Command implementations
│   ├── mod.zig
│   └── ...
├── storage/              # Persistence layer
│   ├── mod.zig           # Module exports
│   ├── jsonl.zig         # JSONL file I/O
│   ├── store.zig         # In-memory IssueStore
│   ├── graph.zig         # Dependency graph
│   ├── issues.zig        # IssueStore re-export
│   └── dependencies.zig  # DependencyGraph re-export
├── models/               # Data structures
│   ├── mod.zig
│   ├── issue.zig
│   ├── status.zig
│   ├── priority.zig
│   ├── issue_type.zig
│   ├── dependency.zig
│   └── comment.zig
├── sync/                 # Import/export operations
│   └── mod.zig
├── id/                   # ID generation
│   ├── mod.zig
│   └── generator.zig
├── config/               # Configuration
│   └── mod.zig
└── output/               # Formatting
    └── mod.zig
```

---

## Storage Layer

### IssueStore (`store.zig`)

In-memory issue storage with fast ID-based lookup.

```zig
pub const IssueStore = struct {
    allocator: std.mem.Allocator,
    issues: std.ArrayListUnmanaged(Issue),
    id_index: std.StringHashMapUnmanaged(usize),
    dirty_ids: std.StringHashMapUnmanaged(void),
    path: []const u8,
};
```

**Key Operations**:
- `insert(issue)` - O(1) amortized
- `get(id)` - O(1) via hash map
- `update(id, updates)` - O(1)
- `delete(id)` - O(n) for array compaction
- `list(filters)` - O(n) linear scan
- `loadFromFile()` - Read JSONL into memory
- `saveToFile()` - Atomic write to JSONL

### DependencyGraph (`graph.zig`)

Manages issue dependencies with cycle detection.

```zig
pub const DependencyGraph = struct {
    store: *IssueStore,
    allocator: std.mem.Allocator,
};
```

**Key Operations**:
- `addDependency(dep)` - With automatic cycle detection
- `removeDependency(issue_id, depends_on_id)`
- `getDependencies(issue_id)` - Returns blocking issues
- `getDependents(issue_id)` - Returns dependent issues
- `wouldCreateCycle(from, to)` - DFS reachability check
- `detectCycles()` - Find all cycles in graph
- `getReadyIssues()` - Open, unblocked, not deferred
- `getBlockedIssues()` - Open with unresolved blockers

### JsonlFile (`jsonl.zig`)

JSONL file operations with crash-safe atomic writes.

```zig
pub const JsonlFile = struct {
    path: []const u8,
    allocator: std.mem.Allocator,
};
```

**Atomic Write Protocol**:
1. Create temp file: `{path}.tmp.{timestamp}`
2. Write all issues as JSON lines
3. fsync() for durability
4. Atomic rename over target

---

## Concurrent Write Architecture

beads_zig handles concurrent writes from multiple agents using a Lock + WAL + Compact pattern. This replaces SQLite's locking which suffers from contention under heavy parallel load.

### Why Not SQLite?

SQLite with WAL mode still experiences lock contention when multiple processes write simultaneously:

```
Agent 1: write -> retry -> write -> success
Agent 2: write -> BUSY -> retry -> BUSY -> retry -> success
Agent 3: write -> BUSY -> BUSY -> BUSY -> BUSY -> success
...
```

The retry storms compound. Each retry holds locks longer, making other retries more likely.

### Lock + WAL + Compact Design

```
Write path (serialized, ~1ms):
  acquire flock -> append to WAL -> fsync -> release flock

Read path (no lock):
  read main file + read WAL -> merge in memory

Compaction (periodic, ~10-50ms):
  acquire flock -> merge WAL into main -> atomic rename -> truncate WAL -> release
```

**Key Properties**:
- Writes are constant-time (~1ms) regardless of database size
- Reads never block (lock-free)
- Process crash auto-releases lock (kernel-managed flock)
- Atomic visibility (readers see complete state or previous state)

### File Structure

```
.beads/
  beads.jsonl       # Main file (compacted state)
  beads.wal         # Write-ahead log (recent appends)
  beads.lock        # Lock file (flock target)
```

### WAL Entry Format

Each WAL entry is a JSON line with operation metadata:

```json
{"op":"add","ts":1706540000,"id":"bd-abc123","data":{...issue...}}
{"op":"close","ts":1706540001,"id":"bd-abc123","data":null}
```

Operations: `add`, `update`, `close`, `reopen`, `delete`, `set_blocked`, `unset_blocked`

### Compaction

Triggered when WAL exceeds threshold (100 ops or 100KB):
1. Acquire exclusive lock
2. Load main file + replay WAL into memory
3. Write merged state to temp file
4. fsync for durability
5. Atomic rename over main file
6. Truncate WAL
7. Release lock

### Platform Support

| Platform | Locking Mechanism |
|----------|-------------------|
| Linux    | flock (POSIX)     |
| macOS    | flock (POSIX)     |
| FreeBSD  | flock (POSIX)     |
| Windows  | LockFileEx        |

---

## Data Flow

### Read Path

```
CLI command
    │
    ▼
IssueStore.loadFromFile()
    │
    ▼
JsonlFile.readAll()
    │
    ├─► Read file contents
    ├─► Split by newlines
    ├─► Parse each line as JSON
    └─► Return []Issue
    │
    ▼
IssueStore
    │
    ├─► Store in ArrayList
    └─► Build ID index
```

### Write Path

```
CLI mutation (create/update/delete)
    │
    ▼
IssueStore.{insert,update,delete}()
    │
    ├─► Modify ArrayList
    ├─► Update ID index
    └─► Mark dirty
    │
    ▼
IssueStore.saveToFile()
    │
    ▼
JsonlFile.writeAll()
    │
    ├─► Create temp file
    ├─► Write all issues as JSON lines
    ├─► fsync()
    └─► Atomic rename
```

---

## Design Decisions

### Why JSONL Instead of SQLite?

1. **No C dependencies** - Pure Zig, single static binary
2. **Tiny binaries** - 12KB vs 2MB+ with SQLite
3. **Cross-compilation** - Works out of the box for all targets
4. **Git-friendly** - Human-readable diffs
5. **beads_rust compatible** - Same JSONL format

### Why In-Memory Storage?

1. **Simplicity** - No query language, no schema migrations
2. **Speed** - All data in memory, O(1) lookups
3. **Correctness** - Easy to reason about, fewer bugs
4. **Sufficient** - Issue trackers rarely exceed 10K issues

### Trade-offs

| Aspect | JSONL + Memory | SQLite |
|--------|----------------|--------|
| Query speed | O(n) linear scan | O(log n) with indexes |
| Startup time | Slower (parse all) | Faster (lazy load) |
| Memory usage | All in RAM | Paged from disk |
| Concurrent access | Single process | Multi-process |
| Binary size | 12 KB | 2+ MB |
| Dependencies | None | C library |

For typical issue tracker workloads (< 10K issues), in-memory storage is fast enough.

---

## JSONL Format

### Main File (`beads.jsonl`)

One JSON object per line, import-compatible with beads_rust:

```json
{"id":"bd-abc123","title":"Fix bug","status":"open","priority":2,"created_at":"2026-01-30T10:00:00Z",...}
{"id":"bd-def456","title":"Add feature","status":"closed","priority":1,"created_at":"2026-01-29T09:00:00Z",...}
```

### WAL File (`beads.wal`)

Operation log entries, one per line:

```json
{"op":"add","ts":1706540000,"id":"bd-abc123","data":{...issue...}}
{"op":"close","ts":1706540001,"id":"bd-abc123","data":null}
{"op":"update","ts":1706540002,"id":"bd-abc123","data":{...updated issue...}}
```

**Key Properties**:
- RFC3339 timestamps in issue data
- Unix timestamps for WAL entry ordering
- Null for missing optional fields
- UTF-8 encoding
- Unknown fields preserved (forward compatibility)
