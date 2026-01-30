# SQLite Removal: Actionable Cleanup Checklist

This document provides concrete, file-by-file steps for removing SQLite from beads_zig.
It complements `remove_sqlite.md` (architecture rationale) with implementation specifics.

---

## Table of Contents

1. [Overview](#overview)
2. [Phase 1: Build System Cleanup](#phase-1-build-system-cleanup)
3. [Phase 2: Storage Layer Replacement](#phase-2-storage-layer-replacement)
4. [Phase 3: Documentation Updates](#phase-3-documentation-updates)
5. [Phase 4: beads_rust Reference Cleanup](#phase-4-beads_rust-reference-cleanup)
6. [Phase 5: File Inventory](#phase-5-file-inventory)
7. [Verification Checklist](#verification-checklist)

---

## Overview

### Current State
- SQLite is encapsulated in `src/storage/` (3,225 lines across 4 files)
- Vendor directory: Does not exist (downloaded on-demand via scripts/setup-vendor.sh)
- Sync layer: Empty stub (15 lines) - JSONL sync not implemented
- Models: Already designed for JSON serialization

### Target State
- Pure JSONL storage with in-memory indexes
- No C dependencies, no libc linking
- Single source of truth (`.beads/beads.jsonl`)
- Binary size: ~50KB (down from ~2MB release)

---

## Phase 1: Build System Cleanup

### 1.1 `build.zig` - Remove SQLite Configuration

**Lines to remove/modify:**

```
REMOVE lines 7-12:
    const bundle_sqlite = b.option(
        bool,
        "bundle-sqlite",
        "Bundle SQLite instead of linking system library",
    ) orelse false;

REMOVE lines 33-55:
    // Link SQLite
    if (bundle_sqlite) {
        exe.addCSourceFile(.{
            .file = b.path("vendor/sqlite3.c"),
            ...
        });
        exe.addIncludePath(b.path("vendor"));
    } else {
        exe.linkSystemLibrary("sqlite3");
    }
    exe.linkLibC();

REMOVE lines 94-119:
    // Link SQLite for tests (duplicate block)
    if (bundle_sqlite) { ... }
    mod_tests.linkLibC();
    exe_tests.linkLibC();
```

**After cleanup, build.zig should be ~50 lines (down from 131).**

### 1.2 `build.zig.zon` - No Changes Needed

Already has empty `.dependencies = .{}`. No SQLite packages to remove.

### 1.3 `scripts/setup-vendor.sh` - Archive

Move to `.archive/scripts/setup-vendor.sh` with note:
```
# Archived: SQLite vendor setup no longer needed after JSONL migration
```

### 1.4 `vendor/` Directory

If it exists (may have been created locally):
- Move entire `vendor/` directory to `.archive/vendor/`

---

## Phase 2: Storage Layer Replacement

### 2.1 Files to ARCHIVE (move to `.archive/src/storage/`)

| File | Lines | Purpose | Replacement |
|------|-------|---------|-------------|
| `src/storage/sqlite.zig` | 406 | SQLite C FFI wrapper | Not needed |
| `src/storage/schema.zig` | 509 | SQL table definitions | Not needed |

### 2.2 Files to REWRITE

| File | Lines | Current Purpose | New Purpose |
|------|-------|-----------------|-------------|
| `src/storage/mod.zig` | 37 | SQLite exports | JsonlStorage exports |
| `src/storage/issues.zig` | 1282 | SQLite CRUD | In-memory + JSONL |
| `src/storage/dependencies.zig` | 991 | SQLite graph ops | In-memory graph |

### 2.3 Files to CREATE

| File | Purpose |
|------|---------|
| `src/storage/jsonl.zig` | JSONL file I/O (read, write, atomic save) |
| `src/storage/store.zig` | In-memory IssueStore with indexes |

### 2.4 Implementation Strategy

**Step 1: Create JsonlStorage interface**
```zig
// src/storage/jsonl.zig
pub const JsonlStorage = struct {
    allocator: std.mem.Allocator,
    path: []const u8,

    pub fn load(self: *JsonlStorage) ![]Issue { ... }
    pub fn save(self: *JsonlStorage, issues: []const Issue) !void { ... }
    pub fn atomicWrite(self: *JsonlStorage, issues: []const Issue) !void { ... }
};
```

**Step 2: Create in-memory store**
```zig
// src/storage/store.zig
pub const IssueStore = struct {
    arena: std.heap.ArenaAllocator,
    issues: std.ArrayList(Issue),
    id_index: std.StringHashMap(usize),

    pub fn init(allocator: std.mem.Allocator) IssueStore { ... }
    pub fn loadFromJsonl(self: *IssueStore, path: []const u8) !void { ... }
    pub fn getById(self: *IssueStore, id: []const u8) ?*Issue { ... }
    pub fn insert(self: *IssueStore, issue: Issue) !void { ... }
    // ... other CRUD
};
```

**Step 3: Migrate issues.zig**
- Replace `db: *sqlite.Database` with `store: *IssueStore`
- Replace SQL queries with in-memory operations
- Keep same public API

**Step 4: Migrate dependencies.zig**
- Graph algorithms (cycle detection, etc.) stay largely the same
- Replace SQLite queries with store lookups

### 2.5 Sync Layer (`src/sync/mod.zig`)

Currently a 15-line stub. Expand to:
```zig
pub const Sync = struct {
    pub fn flush(store: *IssueStore, path: []const u8) !void { ... }
    pub fn reload(store: *IssueStore, path: []const u8) !void { ... }
};
```

---

## Phase 3: Documentation Updates

### 3.1 `FEATURE_PARITY.md` - Major Revision

**Sections to update:**

1. **Phase 0: Foundation** - Remove SQLite references
   - Line 25-26: Remove `- [x] SQLite integration option (system vs bundled)`
   - Add: `- [x] JSONL-only storage (no external dependencies)`

2. **Phase 2: Storage Layer** - Complete rewrite
   - Remove entire "SQLite Integration" section (lines 226-326)
   - Replace with "JSONL Storage" section:
   ```markdown
   ### JSONL Storage (`src/storage/`)

   #### Core Storage
   - [ ] JsonlStorage struct (file I/O)
   - [ ] In-memory IssueStore with indexes
   - [ ] Atomic write (temp file -> rename)
   - [ ] Arena allocator for issue lifetime

   #### Issue Operations
   - [ ] insert, getById, update, delete
   - [ ] list with filters
   - [ ] search (in-memory substring/regex)

   #### Dependency Operations
   - [ ] add, remove dependencies
   - [ ] cycle detection (DFS)
   - [ ] ready/blocked queries
   - [ ] No blocked_cache table needed (in-memory is fast)
   ```

3. **Appendix B: Data Format Compatibility**
   - Remove "SQLite Schema Compatibility" section (lines 773-779)
   - Keep "JSONL Format" section

### 3.2 `docs/architecture.md` - Update Storage Section

Remove dual-storage diagram. Replace with:
```
.beads/
  beads.jsonl   # Single source of truth

Runtime:
  JSONL File -> In-memory IssueStore -> CLI Commands
                     |
              Atomic write on mutation
```

### 3.3 `SPEC.md` - Remove SQLite References

Search and update:
- Remove FTS5 references (use in-memory search instead)
- Remove "SQLite schema" mentions
- Update storage architecture description

### 3.4 `README.md` - Update Build Instructions

Remove:
```
-Dbundle-sqlite=true
```

Highlight:
```
# Pure Zig, no dependencies
zig build
```

### 3.5 `TESTING.md` - Update Storage Tests

Remove SQLite-specific test notes. Add JSONL test patterns.

---

## Phase 4: beads_rust Reference Cleanup

### 4.1 References to KEEP (JSONL compatibility)

These are valid - beads_zig should remain JSONL-compatible for data portability:

| File | Reference | Action |
|------|-----------|--------|
| `src/models/issue.zig` | "fields align with beads_rust for JSONL" | KEEP |
| `src/models/priority.zig` | "Serializes as integer for beads_rust" | KEEP |
| `src/models/timestamp.zig` | "RFC3339 for beads_rust compatibility" | KEEP |
| `SPEC.md` | JSONL format compatibility | KEEP |

### 4.2 References to UPDATE

| File | Current | New |
|------|---------|-----|
| `FEATURE_PARITY.md` | "beads_zig vs beads_rust" | Keep title, update to reflect divergence |
| `README.md` | "port of beads_rust" | "inspired by beads_rust, diverged architecture" |
| `VISION.md` | "Reference implementation" | "Original inspiration" |

### 4.3 References to REMOVE

| File | Reference | Reason |
|------|-----------|--------|
| `TESTING.md` | "corrupt beads_rust data" | No longer sharing SQLite |
| `docs/architecture.md` | beads_rust porting guide | Outdated after divergence |

### 4.4 AGENTS.md Skill Reference

The skill `bd-to-br-migration` in the system prompt suggests tooling for beads migration.
Consider if this is still relevant or if it should be updated/removed.

---

## Phase 5: File Inventory

### Files to ARCHIVE

Move to `.archive/` with commit message explaining deprecation:

```
.archive/
  src/storage/
    sqlite.zig       # SQLite C FFI - no longer needed
    schema.zig       # SQL schema - replaced by JSONL
  scripts/
    setup-vendor.sh  # SQLite download script
  vendor/            # SQLite amalgamation (if exists)
```

### Files to MODIFY

| File | Changes |
|------|---------|
| `build.zig` | Remove SQLite compilation, libc linking |
| `src/storage/mod.zig` | Export new JsonlStorage/IssueStore |
| `src/storage/issues.zig` | Rewrite: SQL -> in-memory |
| `src/storage/dependencies.zig` | Rewrite: SQL -> in-memory |
| `src/sync/mod.zig` | Implement actual JSONL sync |
| `FEATURE_PARITY.md` | Remove SQLite sections |
| `SPEC.md` | Update storage architecture |
| `README.md` | Update build/architecture |
| `docs/architecture.md` | Update storage diagrams |

### Files to CREATE

| File | Purpose |
|------|---------|
| `src/storage/jsonl.zig` | JSONL file operations |
| `src/storage/store.zig` | In-memory issue store |

### Files to INVESTIGATE

| File | Question |
|------|----------|
| `src/main.zig` | How does CLI currently init storage? |
| `src/cli/mod.zig` | Empty - will need storage integration |
| `src/config/mod.zig` | Empty - may need config for JSONL path |

---

## Verification Checklist

### Build Verification
- [ ] `zig build` succeeds without `-Dbundle-sqlite`
- [ ] `zig build` succeeds without system SQLite installed
- [ ] `zig build -Dtarget=aarch64-linux-gnu` cross-compiles
- [ ] `zig build -Dtarget=x86_64-windows-gnu` cross-compiles
- [ ] Binary size < 100KB (ReleaseSmall)

### Functionality Verification
- [ ] Create issue -> appears in beads.jsonl
- [ ] Edit beads.jsonl manually -> changes visible in `bz list`
- [ ] Atomic write: power failure during save doesn't corrupt
- [ ] Ready/blocked queries work correctly
- [ ] Cycle detection works

### Performance Verification
- [ ] Load 1000 issues: < 50ms
- [ ] Filter by status (1000 issues): < 5ms
- [ ] Get by ID: < 1ms
- [ ] Save 1000 issues: < 100ms

### Compatibility Verification
- [ ] Can import beads_rust JSONL exports
- [ ] Exported JSONL is valid JSON (one object per line)
- [ ] RFC3339 timestamps preserved
- [ ] All issue fields preserved on roundtrip

---

## Implementation Order

Recommended sequence for minimal disruption:

1. **Create new files first** (jsonl.zig, store.zig) - no breaking changes
2. **Implement and test new storage** - parallel to SQLite
3. **Update issues.zig/dependencies.zig** to use new storage
4. **Archive SQLite files** (sqlite.zig, schema.zig)
5. **Update build.zig** - remove C compilation
6. **Update documentation** - last step

This allows testing the new implementation before removing the old one.

---

## Notes

- The `sqlite_shelved` branch preserves the SQLite implementation
- All archived files go to `.archive/` per CLAUDE.md rules
- No files are deleted - only archived
- Keep beads_rust JSONL compatibility for data portability
