# Remove SQLite: Migration to Pure JSONL Architecture

## Executive Summary

This document outlines the migration of beads_zig from a dual SQLite+JSONL architecture to a pure JSONL-only design. The primary motivations are binary size reduction (~10MB → ~50KB), build simplicity, and leveraging Zig's systems programming strengths for a use case that doesn't benefit from SQLite's capabilities.

---

## Table of Contents

1. [Current State Analysis](#current-state-analysis)
2. [Benefits of Removal](#benefits-of-removal)
3. [What We Lose (And Why It Doesn't Matter)](#what-we-lose-and-why-it-doesnt-matter)
4. [Implementation Plan](#implementation-plan)
5. [Zig-Native Optimizations](#zig-native-optimizations)
6. [Concurrency & Safety](#concurrency--safety)
7. [Future Extensibility](#future-extensibility)
8. [Migration Checklist](#migration-checklist)

---

## Current State Analysis

### Current Architecture
```
.beads/
  beads.db      # SQLite - fast indexed queries
  issues.jsonl  # JSONL - git-friendly, human-readable
```

### The Problem
- **Binary bloat**: SQLite amalgamation compiles to ~1-2MB optimized, ~10MB with debug info
- **Dual source of truth**: Sync logic between SQLite and JSONL adds complexity and bug surface
- **Build complexity**: Requires C toolchain for cross-compilation
- **Overkill**: SQLite's strengths (ACID, complex joins, millions of rows) are unused for our scale

### Our Actual Scale
- Typical repo: 10-500 issues
- Maximum realistic: ~2,000 issues
- Operations: Filter by status/priority/labels, dependency traversal
- Write pattern: Single agent per repo (no concurrent writes)

---

## Benefits of Removal

### 1. Binary Size
| Build Mode | With SQLite | Without SQLite |
|------------|-------------|----------------|
| Debug | ~10MB | ~100KB |
| ReleaseSafe | ~2MB | ~60KB |
| ReleaseSmall | ~1.5MB | ~50KB |

### 2. Build Simplicity
```bash
# Before: Need C toolchain, conditional compilation
zig build -Dbundle-sqlite=true  # Or link system SQLite

# After: Pure Zig, works everywhere
zig build
```

Cross-compilation becomes trivial:
```bash
zig build -Dtarget=aarch64-linux-gnu      # ARM Linux
zig build -Dtarget=x86_64-windows-gnu     # Windows
zig build -Dtarget=aarch64-macos          # Apple Silicon
```

### 3. Single Source of Truth
```
Before:
  User modifies JSONL manually → Must rebuild SQLite index
  SQLite write succeeds, JSONL write fails → Inconsistent state
  Schema change → Migration needed for both

After:
  JSONL is the only state
  What you see in git diff is what you get
  No migration logic ever
```

### 4. Debuggability
```bash
# Inspect state
cat .beads/beads.jsonl | jq '.status'

# See what changed
git diff .beads/beads.jsonl

# Manual fix
vim .beads/beads.jsonl  # Just edit JSON

# Merge conflicts
git merge  # Standard text merge, no binary blob issues
```

### 5. Simpler Codebase
**Removed:**
- SQL query string construction
- Result set iteration/parsing
- Connection pool management
- Schema definitions
- Migration logic
- Error handling for SQL-specific failures

**Lines of code estimate:** -500 to -1000 LOC

### 6. Faster Compile Times
SQLite amalgamation is a single 250KB C file that takes significant time to compile. Removing it cuts build time noticeably, especially in debug builds.

---

## What We Lose (And Why It Doesn't Matter)

### Complex Queries
**SQLite gives you:**
```sql
SELECT * FROM issues 
WHERE status = 'open' 
  AND priority < 2 
  AND 'frontend' IN labels
ORDER BY created_at DESC
LIMIT 10;
```

**In-memory equivalent:**
```zig
var results = std.ArrayList(Issue).init(allocator);
for (issues) |issue| {
    if (issue.status == .open and 
        issue.priority < 2 and 
        std.mem.indexOf(u8, issue.labels, "frontend") != null) {
        try results.append(issue);
    }
}
std.sort.sort(Issue, results.items, {}, byCreatedDesc);
return results.items[0..@min(10, results.items.len)];
```

**Performance at our scale:** Both are <1ms for 1000 issues. The in-memory scan is often faster because there's no query parsing, no B-tree traversal, and everything is in L1/L2 cache.

### Indexed Lookups
**SQLite:** O(log n) B-tree lookup by ID

**In-memory HashMap:** O(1) lookup
```zig
const id_index = std.StringHashMap(*Issue).init(allocator);
// Build once on load, O(1) lookups forever
```

### ACID Transactions
**SQLite:** Guarantees atomicity, consistency, isolation, durability

**Our reality:** Single writer, append-mostly workload. Atomic file rename gives us all the durability we need:
```zig
// Write to temp, atomic rename
try file.writeAll(data);
try std.fs.rename(".beads/beads.jsonl.tmp", ".beads/beads.jsonl");
```

### Concurrent Writes
**SQLite:** File-level locking handles multiple writers

**Our reality:** Single agent per repo by design. If needed later, flock() provides equivalent protection.

---

## Implementation Plan

### Phase 1: Abstract Storage Layer
Create an interface that both implementations can satisfy:
```zig
const Storage = struct {
    const Self = @This();
    
    loadAllFn: *const fn (*Self) anyerror![]Issue,
    saveAllFn: *const fn (*Self, []const Issue) anyerror!void,
    getByIdFn: *const fn (*Self, []const u8) ?*Issue,
    
    pub fn loadAll(self: *Self) ![]Issue {
        return self.loadAllFn(self);
    }
    // ...
};
```

### Phase 2: Implement JSONL-Only Backend
```zig
const JsonlStorage = struct {
    allocator: std.mem.Allocator,
    issues: std.ArrayList(Issue),
    id_index: std.StringHashMap(*Issue),
    path: []const u8,
    
    pub fn init(allocator: std.mem.Allocator, path: []const u8) !JsonlStorage {
        // ...
    }
    
    pub fn load(self: *JsonlStorage) !void {
        const file = try std.fs.cwd().openFile(self.path, .{});
        defer file.close();
        // Parse JSONL, build indexes
    }
    
    pub fn save(self: *JsonlStorage) !void {
        // Atomic write pattern
    }
};
```

### Phase 3: Remove SQLite Code
- Delete `sqlite.zig` / SQLite wrapper
- Remove `build.zig` SQLite compilation
- Remove `build.zig.zon` SQLite dependency
- Delete migration/schema code
- Update tests

### Phase 4: Optimize
Apply Zig-native optimizations (see next section).

---

## Zig-Native Optimizations

### 1. Memory-Mapped File Reading (Zero-Copy)
```zig
const MappedJsonl = struct {
    data: []align(std.mem.page_size) const u8,
    file: std.fs.File,
    
    pub fn init(path: []const u8) !MappedJsonl {
        const file = try std.fs.cwd().openFile(path, .{});
        const stat = try file.stat();
        
        const data = try std.posix.mmap(
            null,
            stat.size,
            std.posix.PROT.READ,
            .{ .TYPE = .PRIVATE },
            file.handle,
            0,
        );
        
        return .{ .data = data, .file = file };
    }
    
    pub fn deinit(self: *MappedJsonl) void {
        std.posix.munmap(self.data);
        self.file.close();
    }
};
```

**Benefits:**
- OS handles caching, paging, read-ahead
- No allocation for file contents
- String slices point directly into mapped memory
- Lazy loading: pages only faulted in when accessed

### 2. Arena Allocator for Issue Lifetime
```zig
pub const IssueStore = struct {
    arena: std.heap.ArenaAllocator,
    issues: std.ArrayList(Issue),
    
    pub fn init() IssueStore {
        return .{
            .arena = std.heap.ArenaAllocator.init(std.heap.page_allocator),
            .issues = undefined,
        };
    }
    
    pub fn load(self: *IssueStore, jsonl_data: []const u8) !void {
        const alloc = self.arena.allocator();
        self.issues = std.ArrayList(Issue).init(alloc);
        
        // All strings, arrays allocated from arena
        // Zero fragmentation, one free at the end
    }
    
    pub fn deinit(self: *IssueStore) void {
        // Single call frees everything
        self.arena.deinit();
    }
    
    pub fn reload(self: *IssueStore, jsonl_data: []const u8) !void {
        // Fast reload: reset arena, reparse
        _ = self.arena.reset(.retain_capacity);
        try self.load(jsonl_data);
    }
};
```

**Benefits:**
- All allocations are bump-pointer (fastest possible)
- No per-object free tracking
- Reload is instant: reset + reparse
- Memory locality: all issue data contiguous

### 3. Struct-of-Arrays Layout (Cache-Friendly Filtering)
```zig
// Traditional: Array of Structs (AoS)
const Issue = struct {
    id: []const u8,
    status: Status,
    priority: u8,
    title: []const u8,
    // ... more fields
};
var issues: []Issue;

// Optimized: Struct of Arrays (SoA)
const IssueStore = struct {
    len: usize,
    
    // Hot data: frequently filtered/sorted
    statuses: []Status,      // 1 byte each, packed
    priorities: []u8,        // 1 byte each, packed
    
    // Warm data: accessed after filtering
    ids: [][]const u8,
    titles: [][]const u8,
    
    // Cold data: rarely accessed
    descriptions: [][]const u8,
    created_ats: []i64,
    
    // Filtering scans only the hot arrays
    pub fn countByStatus(self: *IssueStore, target: Status) usize {
        var count: usize = 0;
        // Tight loop over contiguous memory
        // Likely fits in L1 cache for 1000 issues (1KB)
        for (self.statuses) |s| {
            count += @intFromBool(s == target);
        }
        return count;
    }
    
    pub fn filterByPriority(self: *IssueStore, max_priority: u8) []usize {
        // Return indices, avoid copying cold data
        var indices = std.ArrayList(usize).init(allocator);
        for (self.priorities, 0..) |p, i| {
            if (p <= max_priority) try indices.append(i);
        }
        return indices.items;
    }
};
```

**Benefits:**
- Filter operations touch minimal memory
- CPU prefetcher works effectively
- Cache lines aren't wasted on unused fields
- SIMD-friendly for future optimization

### 4. Comptime String Interning for JSON Keys
```zig
const FieldTag = enum {
    id,
    status,
    priority,
    title,
    description,
    blocks,
    blocked_by,
    labels,
    assignee,
    created_at,
    updated_at,
    unknown,
};

// Perfect hash at compile time
const field_map = std.ComptimeStringMap(FieldTag, .{
    .{ "id", .id },
    .{ "status", .status },
    .{ "priority", .priority },
    .{ "title", .title },
    .{ "description", .description },
    .{ "blocks", .blocks },
    .{ "blocked_by", .blocked_by },
    .{ "labels", .labels },
    .{ "assignee", .assignee },
    .{ "created_at", .created_at },
    .{ "updated_at", .updated_at },
});

fn parseField(key: []const u8) FieldTag {
    return field_map.get(key) orelse .unknown;
}
```

**Benefits:**
- Zero runtime cost for field lookup
- No hash table allocation
- Branch prediction friendly (switch on enum)

### 5. SIMD Text Search (Future)
```zig
const Vec32 = @Vector(32, u8);

fn containsNeedle(haystack: []const u8, needle: u8) bool {
    const splat: Vec32 = @splat(needle);
    
    var i: usize = 0;
    while (i + 32 <= haystack.len) : (i += 32) {
        const chunk: Vec32 = haystack[i..][0..32].*;
        const matches = chunk == splat;
        if (@reduce(.Or, matches)) return true;
    }
    
    // Handle remainder with scalar code
    for (haystack[i..]) |c| {
        if (c == needle) return true;
    }
    return false;
}
```

**Use cases:**
- Fast title/description substring search
- Label matching
- Full-text search without external dependencies

### 6. Lazy Parsing with Streaming JSON
```zig
const LazyIssue = struct {
    raw_json: []const u8,  // Slice into mmap'd file
    
    // Only parsed when accessed
    cached_status: ?Status = null,
    cached_priority: ?u8 = null,
    
    pub fn getStatus(self: *LazyIssue) Status {
        if (self.cached_status) |s| return s;
        self.cached_status = self.parseField("status", Status);
        return self.cached_status.?;
    }
    
    pub fn getRawDescription(self: *LazyIssue) []const u8 {
        // Return slice, never copy
        return self.extractField("description");
    }
};
```

**Benefits:**
- Startup is instant: just mmap + line split
- Fields parsed on-demand
- Descriptions (largest field) never parsed unless viewed

---

## Concurrency & Safety

### Current Requirement: Single Agent Per Repo
No concurrency handling needed for MVP. Simplest possible implementation.

### Future-Proofing: Atomic Writes
```zig
pub fn atomicSave(issues: []const Issue, path: []const u8) !void {
    const dir = std.fs.cwd();
    const tmp_path = try std.fmt.allocPrint(allocator, "{s}.tmp.{d}", .{ 
        path, 
        std.time.timestamp(),
    });
    defer allocator.free(tmp_path);
    
    // Write complete file to temp location
    const tmp_file = try dir.createFile(tmp_path, .{});
    defer tmp_file.close();
    
    var writer = tmp_file.writer();
    for (issues) |issue| {
        try std.json.stringify(issue, .{}, writer);
        try writer.writeByte('\n');
    }
    
    // Atomic rename (POSIX guarantees)
    try dir.rename(tmp_path, path);
}
```

**Guarantees:**
- Readers never see partial writes
- Power failure leaves either old or new file (never corrupt)
- No locking required for single-writer

### Future Option: Advisory File Locking
```zig
pub const FileLock = struct {
    file: std.fs.File,
    
    pub fn acquire(path: []const u8) !FileLock {
        const file = try std.fs.cwd().openFile(path, .{ .lock = .exclusive });
        return .{ .file = file };
    }
    
    pub fn acquireNonBlocking(path: []const u8) !?FileLock {
        const file = std.fs.cwd().openFile(path, .{ 
            .lock = .exclusive,
            .lock_nonblocking = true,
        }) catch |err| {
            if (err == error.WouldBlock) return null;
            return err;
        };
        return .{ .file = file };
    }
    
    pub fn release(self: *FileLock) void {
        self.file.close();  // Releases lock automatically
    }
};

// Usage
pub fn withLock(path: []const u8, comptime f: fn () anyerror!void) !void {
    var lock = try FileLock.acquire(path);
    defer lock.release();
    try f();
}
```

**When to add:**
- Multiple agents need to write to same repo
- User manually edits while agent runs
- Add as opt-in flag: `--enable-locking`

---

## Future Extensibility

### 1. Watch Mode with inotify/kqueue
```zig
const Watcher = struct {
    fd: std.posix.fd_t,
    
    pub fn init(path: []const u8) !Watcher {
        const fd = try std.posix.inotify_init1(.{ .NONBLOCK = true });
        _ = try std.posix.inotify_add_watch(fd, path, .{ .MODIFY = true });
        return .{ .fd = fd };
    }
    
    pub fn poll(self: *Watcher) !bool {
        var buf: [4096]u8 = undefined;
        const n = std.posix.read(self.fd, &buf) catch |err| {
            if (err == error.WouldBlock) return false;
            return err;
        };
        return n > 0;
    }
};
```

**Use case:** `beads_zig watch` command that reloads on external changes.

### 2. Embedded Full-Text Search
Build a simple inverted index at load time:
```zig
const SearchIndex = struct {
    // word -> list of (issue_index, field, position)
    index: std.StringHashMap(std.ArrayList(Hit)),
    
    pub fn build(issues: []const Issue) !SearchIndex {
        var self = SearchIndex{};
        for (issues, 0..) |issue, i| {
            try self.indexText(issue.title, i, .title);
            try self.indexText(issue.description, i, .description);
        }
        return self;
    }
    
    pub fn search(self: *SearchIndex, query: []const u8) []usize {
        // Simple AND of terms, ranked by hit count
    }
};
```

### 3. Binary Index File (Optional Acceleration)
For very large repos (>5000 issues), add optional pre-computed index:
```
.beads/
  beads.jsonl        # Source of truth
  beads.idx          # Optional: pre-computed indexes, rebuild if stale
```

```zig
const IndexFile = struct {
    magic: [4]u8 = "BEAD",
    version: u32 = 1,
    jsonl_hash: [32]u8,  // SHA256 of jsonl file
    
    // Pre-sorted arrays
    by_priority: []u32,  // Issue indices sorted by priority
    by_created: []u32,   // Issue indices sorted by created_at
    by_updated: []u32,   // Issue indices sorted by updated_at
    
    // Pre-computed
    id_offsets: []u64,   // Byte offset of each issue in jsonl
};
```

**Behavior:**
- Check `jsonl_hash` on startup
- If matches, use pre-computed indexes
- If stale or missing, rebuild in background
- Never required, purely opportunistic

### 4. Plugin System for Custom Fields
```zig
const FieldPlugin = struct {
    name: []const u8,
    parse: *const fn (json_value: std.json.Value) anyerror!FieldValue,
    format: *const fn (FieldValue) []const u8,
    compare: *const fn (FieldValue, FieldValue) std.math.Order,
};

// Register custom fields
try store.registerField(.{
    .name = "story_points",
    .parse = parseStoryPoints,
    .format = formatStoryPoints,
    .compare = compareStoryPoints,
});
```

### 5. Export Formats
Pure Zig makes it easy to add export targets:
```zig
const Exporter = union(enum) {
    json,
    csv,
    markdown,
    html,
    
    pub fn export(self: Exporter, issues: []const Issue, writer: anytype) !void {
        switch (self) {
            .json => try exportJson(issues, writer),
            .csv => try exportCsv(issues, writer),
            .markdown => try exportMarkdown(issues, writer),
            .html => try exportHtml(issues, writer),
        }
    }
};
```

---

## Migration Checklist

### Pre-Migration
- [ ] Document current SQLite-dependent features
- [ ] Write comprehensive tests for current behavior
- [ ] Benchmark current performance as baseline

### Phase 1: Abstraction
- [ ] Create `Storage` interface
- [ ] Wrap existing SQLite code behind interface
- [ ] Verify all tests pass

### Phase 2: JSONL Implementation
- [ ] Implement `JsonlStorage` 
- [ ] Add in-memory indexes (id, status, priority)
- [ ] Implement atomic write
- [ ] Add feature flag: `--storage=jsonl`
- [ ] Verify all tests pass with both backends

### Phase 3: Optimization
- [ ] Add memory-mapped file reading
- [ ] Switch to arena allocator
- [ ] Benchmark vs SQLite
- [ ] Profile and optimize hot paths

### Phase 4: SQLite Removal
- [ ] Make JSONL the default
- [ ] Remove SQLite from build.zig
- [ ] Remove SQLite wrapper code
- [ ] Remove SQLite-specific tests
- [ ] Update documentation

### Phase 5: Polish
- [ ] Add struct-of-arrays for hot paths (if benchmarks warrant)
- [ ] Add comptime field map
- [ ] Final benchmark comparison
- [ ] Update README

### Validation
- [ ] Binary size meets target (<100KB release)
- [ ] Cross-compilation works without C toolchain
- [ ] beads_viewer compatibility verified
- [ ] Performance equal or better than SQLite version

---

## Appendix: Benchmark Targets

| Operation | SQLite Baseline | JSONL Target | Notes |
|-----------|-----------------|--------------|-------|
| Cold start (100 issues) | ~50ms | <10ms | mmap + lazy parse |
| Cold start (1000 issues) | ~100ms | <30ms | |
| Filter by status | <1ms | <1ms | Both trivial at this scale |
| Get by ID | <1ms | <1ms | HashMap lookup |
| Full save | ~20ms | <10ms | Atomic write |
| Memory (1000 issues) | ~5MB | <2MB | Arena + slices |

---

## Conclusion

Removing SQLite aligns beads_zig with its actual requirements: a fast, single-user, git-friendly issue tracker. The migration unlocks:

1. **50x smaller binaries** → easier distribution
2. **Simpler builds** → better cross-platform support
3. **Zig-native optimizations** → potentially faster than SQLite for our workload
4. **Single source of truth** → fewer bugs, better debuggability
5. **Extensibility** → custom fields, export formats, watch mode without external dependencies

The JSONL-only architecture isn't a compromise—it's the right tool for the job.
