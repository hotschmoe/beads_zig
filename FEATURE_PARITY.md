# FEATURE_PARITY.md - beads_zig vs beads_rust

This document tracks feature implementation for `beads_zig`, a standalone Zig implementation of a local-first issue tracker.

**Inspiration**: https://github.com/Dicklesworthstone/beads_rust
**Target**: Full CLI and library implementation with idiomatic Zig

**Note**: beads_zig (`bz`) is an independent project. It draws inspiration from beads_rust but is not a migration target or compatibility layer. The two can coexist but do not interoperate.

---

## Status Legend

- [ ] Not started
- [~] In progress
- [x] Complete
- [!] Blocked / Needs decision

---

## Phase 0: Foundation (Prerequisites)

### Build System & Dependencies

- [x] `build.zig` - Build configuration
- [x] `build.zig.zon` - Package manifest
- [x] Pure Zig storage (no C dependencies)
- [x] Cross-platform builds verified (Linux, macOS, Windows, ARM64)
- [ ] Add `rich_zig` dependency (terminal formatting)

### Project Structure

```
src/
├── main.zig              # CLI entry point
├── root.zig              # Library exports
├── cli/                  # Command implementations
│   ├── mod.zig           # CLI module root
│   └── ...               # Individual command files
├── storage/              # Storage layer (JSONL + in-memory)
│   ├── mod.zig           # Module exports
│   ├── jsonl.zig         # JSONL file I/O (atomic writes)
│   ├── store.zig         # In-memory IssueStore
│   ├── graph.zig         # Dependency graph + cycle detection
│   ├── issues.zig        # IssueStore re-export
│   └── dependencies.zig  # DependencyGraph re-export
├── models/               # Data structures
│   ├── mod.zig
│   ├── issue.zig
│   ├── status.zig
│   ├── priority.zig
│   ├── issue_type.zig
│   ├── dependency.zig
│   ├── comment.zig
│   └── event.zig
├── sync/                 # JSONL sync operations
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

## Phase 1: Core Data Model

### Models (`src/models/`)

#### Issue Model (bd-19r - DONE)

- [x] `Issue` struct with all fields:
  - [x] `id: []const u8` - Unique ID (bd-abc123)
  - [x] `title: []const u8` - 1-500 chars
  - [x] `description: ?[]const u8`
  - [x] `design: ?[]const u8`
  - [x] `acceptance_criteria: ?[]const u8`
  - [x] `notes: ?[]const u8`
  - [x] `status: Status`
  - [x] `priority: Priority` (0-4)
  - [x] `issue_type: IssueType`
  - [x] `assignee: ?[]const u8`
  - [x] `owner: ?[]const u8`
  - [x] `estimated_minutes: ?i32`
  - [x] `created_at: i64` (Unix timestamp)
  - [x] `created_by: ?[]const u8`
  - [x] `updated_at: i64`
  - [x] `closed_at: ?i64`
  - [x] `close_reason: ?[]const u8`
  - [x] `due_at: ?i64`
  - [x] `defer_until: ?i64`
  - [x] `external_ref: ?[]const u8`
  - [x] `source_system: ?[]const u8`
  - [x] `pinned: bool`
  - [x] `is_template: bool`
- [x] Issue validation (title length, field constraints)
- [x] Issue JSON serialization
- [x] Issue equality and hashing

#### Status Enum (bd-8ev - DONE)

- [x] `Status` enum:
  - [x] `open`
  - [x] `in_progress`
  - [x] `blocked`
  - [x] `deferred`
  - [x] `closed`
  - [x] `tombstone` (soft deleted)
  - [x] `pinned`
  - [x] `custom` (with string payload)
- [x] Status string parsing
- [x] Status serialization

#### Priority (bd-3t8 - DONE)

- [x] `Priority` struct (0-4, lower is higher priority):
  - [x] 0 = Critical
  - [x] 1 = High
  - [x] 2 = Medium
  - [x] 3 = Low
  - [x] 4 = Backlog
- [x] Priority parsing from int/string
- [x] Priority comparison

#### Issue Type Enum (bd-4y7 - DONE)

- [x] `IssueType` enum:
  - [x] `task`
  - [x] `bug`
  - [x] `feature`
  - [x] `epic`
  - [x] `chore`
  - [x] `docs`
  - [x] `question`
  - [x] `custom` (with string payload)
- [x] Type string parsing
- [x] Type serialization

#### Dependency Model (bd-2fo - DONE)

- [x] `Dependency` struct:
  - [x] `issue_id: []const u8`
  - [x] `depends_on_id: []const u8`
  - [x] `dep_type: DependencyType`
  - [x] `created_at: i64`
  - [x] `created_by: ?[]const u8`
  - [x] `metadata: ?[]const u8`
  - [x] `thread_id: ?[]const u8`
- [x] `DependencyType` enum:
  - [x] `blocks`
  - [x] `parent_child`
  - [x] `conditional_blocks`
  - [x] `waits_for`
  - [x] `related`
  - [x] `discovered_from`
  - [x] `replies_to`
  - [x] `relates_to`
  - [x] `duplicates`
  - [x] `supersedes`
  - [x] `caused_by`
  - [x] `custom`

#### Comment Model (bd-nwm - DONE)

- [x] `Comment` struct:
  - [x] `id: i64`
  - [x] `issue_id: []const u8`
  - [x] `author: []const u8`
  - [x] `body: []const u8`
  - [x] `created_at: i64`
- [x] Comment validation
- [x] Comment serialization

#### Event Model (Audit Log) (bd-sbg - DONE)

- [x] `Event` struct:
  - [x] `id: i64`
  - [x] `issue_id: []const u8`
  - [x] `event_type: EventType`
  - [x] `actor: []const u8`
  - [x] `old_value: ?[]const u8`
  - [x] `new_value: ?[]const u8`
  - [x] `created_at: i64`
- [x] `EventType` enum:
  - [x] `created`
  - [x] `updated`
  - [x] `status_changed`
  - [x] `priority_changed`
  - [x] `assignee_changed`
  - [x] `commented`
  - [x] `closed`
  - [x] `reopened`
  - [x] `dependency_added`
  - [x] `dependency_removed`
  - [x] `label_added`
  - [x] `label_removed`
  - [x] `compacted`
  - [x] `deleted`
  - [x] `restored`
  - [x] `custom`

---

## Phase 2: Storage Layer

### JSONL + WAL + In-Memory Storage (`src/storage/`)

beads_zig uses pure Zig storage: JSONL files with a Write-Ahead Log (WAL) for concurrent access, and in-memory indexing for fast queries. No SQLite, no C dependencies.

**Architecture Note**: Unlike SQLite-based approaches, beads_zig uses a custom Lock + WAL + Compact architecture that:
- Eliminates SQLite's lock contention issues under heavy parallel agent load
- Provides constant-time writes (~1ms) regardless of database size
- Allows lock-free reads (no contention for list/show/status)
- Auto-releases locks on process crash (kernel-managed flock)

See `docs/concurrent_writes.md` for detailed design rationale.

#### File Structure

```
.beads/
  issues.jsonl      # Main file (compacted state)
  issues.wal        # Write-ahead log (recent appends)
  .beads.lock       # Lock file (flock target)
```

#### JsonlFile (`src/storage/jsonl.zig`)

- [x] `JsonlFile` struct with path and allocator
- [x] `readAll()` - Parse JSONL file to `[]Issue`
- [x] `writeAll(issues)` - Atomic write (temp + fsync + rename)
- [x] `append(issue)` - Append single issue (for quick capture)
- [x] Handle missing file gracefully (return empty)
- [x] Unknown field preservation (forward compatibility)

#### Concurrent Write Handling (`src/storage/lock.zig`) (bd-fw7 - DONE)

- [x] `BeadsLock` struct with flock-based locking
- [x] `acquire()` - Blocking exclusive lock (LOCK_EX)
- [x] `tryAcquire()` - Non-blocking lock attempt (LOCK_NB)
- [x] `acquireTimeout(ms)` - Lock with timeout
- [x] `release()` - Release lock (LOCK_UN)
- [x] `withLock(fn)` - RAII-style lock wrapper
- [x] Windows compatibility (LockFileEx)

#### WAL Operations (`src/storage/wal.zig`) (bd-1sd - DONE)

- [x] `WalEntry` struct (op, timestamp, id, data)
- [x] `WalOp` enum (add, update, close, reopen, delete, set_blocked, unset_blocked)
- [x] `appendWalEntry(entry)` - Append to WAL under lock
- [x] `replayWal(file)` - Apply WAL entries to in-memory state
- [x] WAL entry serialization (JSON lines)

#### Compaction (`src/storage/compact.zig`) (bd-1lc - DONE)

- [x] `compact()` - Merge WAL into main file atomically
- [x] `maybeCompact()` - Trigger compaction when WAL > threshold
- [x] Compaction threshold: 100 ops OR 100KB
- [x] Atomic main file replacement (temp + fsync + rename)

#### IssueStore (`src/storage/store.zig`)

- [x] `IssueStore` struct with ArrayList + StringHashMap
- [x] `init/deinit` - Memory management
- [x] `loadFromFile()` - Parse JSONL into memory
- [x] `saveToFile()` - Atomic write to JSONL
- [x] `insert(issue)` - Add with index update
- [x] `get(id)` - O(1) lookup via hash map
- [x] `getRef(id)` - Get mutable reference
- [x] `update(id, updates)` - Modify in place
- [x] `delete(id)` - Remove from store
- [x] `list(filters)` - Linear scan with filtering
- [x] `count()` - Total issue count
- [x] `exists(id)` - Check if issue exists
- [x] `markDirty(id)` - Track modified issues
- [x] `getDirtyIds()` - Get modified issue IDs
- [ ] `addLabel(issue_id, label)` - Add label to issue
- [ ] `removeLabel(issue_id, label)` - Remove label from issue
- [ ] `addComment(issue_id, comment)` - Add comment to issue

#### DependencyGraph (`src/storage/graph.zig`)

- [x] `DependencyGraph` struct wrapping IssueStore
- [x] `addDependency(dep)` - With automatic cycle detection
- [x] `removeDependency(issue_id, depends_on_id)` - Remove dependency
- [x] `getDependencies(issue_id)` - What this issue depends on
- [x] `getDependents(issue_id)` - What depends on this issue
- [x] `wouldCreateCycle(from, to)` - DFS reachability check
- [x] `detectCycles()` - Find all cycles in graph
- [x] `getReadyIssues()` - Open, unblocked, not deferred
- [x] `getBlockedIssues()` - Open with unresolved blockers
- [x] `getBlockers(issue_id)` - Get blocking issues
- [x] Self-dependency rejection
- [x] Cycle detection on add

#### Search (bd-39h - DONE)

- [x] Linear scan substring matching (basic)
- [ ] Inverted index for full-text search (advanced)

---

## Phase 3: ID Generation

### Base36 Encoding (`src/id/`) (bd-15t - DONE)

- [x] Base36 character set (0-9, a-z)
- [x] `encodeBase36(value: u64) []const u8`
- [x] `decodeBase36(str: []const u8) !u64`

### Content Hashing (bd-qhg - DONE)

- [x] SHA256 content hash function
- [x] Fields included: title, description, design, acceptance_criteria, notes, status, priority, issue_type, assignee, owner, created_by, external_ref, source_system, pinned, is_template
- [x] Null byte separator for stability
- [x] 64-character hex output

### ID Generation (bd-2sy - DONE)

- [x] `generateId(title, description, creator, timestamp, nonce) []const u8`
- [x] SHA256 of metadata -> first 8 bytes -> u64 -> Base36
- [x] Adaptive hash length (3-8 chars based on DB size)
- [x] Birthday problem collision avoidance
- [x] Configurable prefix (default "bd")
- [x] Hierarchical child IDs (bd-abc123.1.2)

### ID Parsing (bd-2sy - DONE)

- [x] `parseId(id: []const u8) !ParsedId`
- [x] Prefix extraction
- [x] Hash extraction
- [x] Child path parsing
- [x] Validation

---

## Phase 4: JSONL Sync

### Core Operations

With JSONL as the primary storage, sync is simplified:

- [x] `IssueStore.loadFromFile()` - Load JSONL into memory
- [x] `IssueStore.saveToFile()` - Save memory to JSONL (atomic)
- [x] Atomic writes (temp file + fsync + rename)
- [x] Dirty tracking for modified issues

### Sync Commands (bd-10o - DONE)

- [x] `sync --flush-only` - Force save to JSONL
- [x] `sync --import-only` - Force reload from JSONL
- [x] `sync --force` - Force even if data loss possible
- [x] Auto-save after mutations (configurable)
- [x] Auto-load on startup

---

## Phase 5: CLI Framework

### Argument Parsing (`src/cli/`) (bd-1ld - DONE)

- [x] Global flags:
  - [x] `--json` - JSON output
  - [x] `-v, -vv` - Verbosity levels
  - [x] `--quiet` - Suppress output
  - [x] `--no-color` - Disable colors
  - [x] `--data <PATH>` - Override `.beads/` directory
  - [x] `--actor <NAME>` - Set actor for audit
  - [x] `--no-auto-flush` - Skip auto-save
  - [x] `--no-auto-import` - Skip auto-load
- [x] Subcommand dispatch
- [x] Help text generation
- [x] Error formatting

### Output Formatting (`src/output/`) (bd-5hg - DONE)

- [x] Rich mode (TTY with colors via rich_zig)
- [x] Plain mode (no colors, piped output)
- [x] JSON mode (structured output)
- [x] Quiet mode (minimal output)
- [x] Automatic mode detection (isatty)

---

## Phase 6: CLI Commands

### Workspace Commands

- [x] `bz init` - Initialize workspace
  - [x] Create `.beads/` directory
  - [x] Create `issues.jsonl` (empty)
  - [x] Create `config.yaml`
  - [x] Create `metadata.json`
  - [x] `--prefix` option for issue ID prefix
  - [x] `--json` output format
  - [x] `.gitignore` for WAL/lock files
- [x] `bz config` - Manage configuration (bd-12h - DONE)
  - [x] `--list` - Show all settings
  - [x] `--get <key>` - Get specific value
  - [x] `--set <key>=<value>` - Set value
- [x] `bz info` - Show workspace info (bd-2lr - DONE)
- [x] `bz stats` / `bz status` - Project statistics (bd-2lr - DONE)
- [x] `bz doctor` - Run diagnostics (bd-2lr - DONE)

### Issue CRUD Commands

- [x] `bz create <title>` - Create issue
  - [x] `--type` (bug/feature/task/epic/chore/docs/question)
  - [x] `--priority` (0-4 or critical/high/medium/low/backlog)
  - [x] `--description`
  - [x] `--assignee`
  - [x] `--labels` (multiple)
  - [ ] `--deps` (multiple dependency IDs)
  - [x] `--due` (date)
  - [x] `--estimate` (minutes)
  - [x] Return created ID
  - [x] `--json` output format
- [x] `bz q <title>` - Quick capture (create + print ID only)
- [x] `bz show <id>` - Display issue details (bd-2e8 - DONE)
  - [x] Full metadata
  - [x] Labels
  - [x] Dependencies
  - [x] Recent comments
  - [x] `--json` support
- [x] `bz update <id>` - Update issue (bd-26k - DONE)
  - [x] `--status`
  - [x] `--priority`
  - [x] `--title`
  - [x] `--description`
  - [x] `--assignee`
  - [x] `--type`
  - [~] Audit trail event (synthetic only)
- [x] `bz close <id>` - Close issue (bd-2sz - DONE)
  - [x] `--reason`
  - [x] Set `closed_at` timestamp
  - [~] Audit event (synthetic only)
- [x] `bz reopen <id>` - Reopen closed issue (bd-2sz - DONE)
  - [x] Clear `closed_at`
  - [~] Audit event (synthetic only)
- [x] `bz delete <id>` - Soft delete (tombstone) (bd-2hi - DONE)
  - [x] `--reason`
  - [x] Set status to tombstone
  - [~] Audit event (synthetic only)

### Query Commands

- [x] `bz list` - List issues (bd-2bv - DONE)
  - [x] `--status` filter
  - [x] `--priority` filter
  - [x] `--type` filter
  - [x] `--assignee` filter
  - [x] `--label` filter (multiple)
  - [x] `--limit` and `--offset`
  - [ ] `--sort` (created, updated, priority)
  - [x] `--json` output
- [x] `bz ready` - Show actionable issues (bd-ke1 - DONE)
  - [x] Open status
  - [x] Not blocked by dependencies
  - [x] Not deferred (or defer_until passed)
  - [x] `--limit`
  - [x] `--json`
- [x] `bz blocked` - Show blocked issues (bd-ke1 - DONE)
  - [x] Has blocking dependencies
  - [x] Show what blocks each
  - [x] `--json`
- [x] `bz search <query>` - Full-text search (bd-2ui - DONE)
  - [x] Search title, description, notes
  - [~] FTS5 ranking (uses linear scan, not FTS5)
  - [x] `--json`
- [x] `bz stale` - Find stale issues (bd-2f0 - DONE)
  - [x] `--days` (default 30)
  - [x] Not updated in N days
  - [x] `--json`
- [x] `bz count` - Count issues (bd-2f0 - DONE)
  - [x] `--by` (status/priority/type/assignee)
  - [x] Grouped counts
  - [x] `--json`

### Dependency Commands (bd-177 - DONE)

- [x] `bz dep add <child> <parent>` - Add dependency
  - [x] `--type` (blocks/parent-child/waits-for/related/etc.)
  - [x] Cycle detection
  - [~] Audit event (synthetic only)
- [x] `bz dep remove <child> <parent>` - Remove dependency
  - [~] Audit event (synthetic only)
- [x] `bz dep list <id>` - List dependencies
  - [x] Show what this issue depends on
  - [x] Show what depends on this issue
  - [x] `--json`
- [ ] `bz dep tree <id>` - Show dependency tree
  - [ ] ASCII tree visualization
  - [ ] `--json` (adjacency list)
- [x] `bz dep cycles` - Detect circular dependencies
  - [x] List all cycles found
  - [x] `--json`

### Label Commands (bd-2n2 - DONE)

- [x] `bz label add <id> <labels...>` - Add labels
  - [x] Multiple labels
  - [~] Audit events (synthetic only)
- [x] `bz label remove <id> <labels...>` - Remove labels
  - [x] Multiple labels
  - [~] Audit events (synthetic only)
- [x] `bz label list <id>` - List labels on issue
- [x] `bz label list-all` - List all labels in project

### Comment Commands (bd-2u2 - DONE)

- [x] `bz comments add <id> <text>` - Add comment
  - [x] Auto-detect actor
  - [~] Audit event (synthetic only)
- [x] `bz comments list <id>` - Show comments
  - [x] Chronological order
  - [x] `--json`

### Audit Commands (bd-1bf - PARTIAL)

- [x] `bz history <id>` - Show issue history
  - [~] All events for issue (synthetic from timestamps)
  - [x] Chronological
  - [x] `--json`
- [x] `bz audit` - Deep audit analysis
  - [~] All events in project (synthetic from timestamps)
  - [ ] Filters by date/actor/type
  - [x] `--json`

### Advanced Commands

- [ ] `bz epic` - Manage epics (bd-xjc - NOT IMPLEMENTED)
  - [ ] Create epic
  - [ ] Add issues to epic
  - [ ] List epic contents
- [x] `bz defer <id> --until <date>` - Defer issue (bd-2rh - DONE)
  - [x] Set `defer_until`
  - [x] Excluded from ready
- [x] `bz undefer <id>` - Remove deferral (bd-2rh - DONE)
- [ ] `bz orphans` - Find orphaned issues (bd-2q5 - NOT IMPLEMENTED)
  - [ ] Issues with missing parent refs
- [ ] `bz changelog` - Generate changelog (bd-116 - NOT IMPLEMENTED)
  - [ ] `--since` date
  - [ ] `--until` date
  - [ ] Grouped by type
  - [ ] Markdown output
- [ ] `bz lint` - Validate database (bd-2q5 - NOT IMPLEMENTED)
  - [ ] Check consistency
  - [ ] Find invalid refs
  - [ ] `--json`
- [x] `bz graph` - Dependency graph (bd-sso - DONE)
  - [x] ASCII visualization
  - [x] DOT format export

### Sync Commands (bd-10o - DONE)

- [x] `bz sync --flush-only` - Export to JSONL
- [x] `bz sync --import-only` - Import from JSONL
- [x] `bz sync --force` - Force sync

### System Commands

- [x] `bz version` - Show version info (bd-2a4 - DONE)
- [x] `bz completions <shell>` - Generate shell completions (bd-1o5 - DONE)
  - [x] bash
  - [x] zsh
  - [x] fish
- [ ] `bz agents` - Manage agent instructions (if applicable)

---

## Phase 7: Configuration

### Config System (`src/config/`) (bd-2dd - DONE)

- [x] YAML parser/writer
- [ ] User config (`~/.config/beads/config.yaml`)
- [x] Project config (`.beads/config.yaml`)
- [ ] Config merging (project overrides user)
- [x] Config keys:
  - [x] `issue_prefix` (default "bd")
  - [ ] `default_assignee`
  - [x] `auto_flush` (bool)
  - [x] `auto_import` (bool)
  - [x] `lock_timeout_ms`
  - [ ] `actor_name`

### Metadata

- [ ] `.beads/metadata.json`:
  - [ ] Schema version
  - [ ] Created timestamp
  - [ ] Last sync timestamp
  - [ ] Issue count cache

---

## Phase 8: Testing

### Unit Tests (bd-2uu - DONE)

- [x] Model serialization/deserialization
- [x] ID generation (determinism, uniqueness)
- [x] Base36 encoding/decoding
- [x] Content hashing
- [x] Status/Priority/Type parsing
- [x] Dependency cycle detection

### Integration Tests

- [x] JSONL read/write roundtrip
- [x] IssueStore operations
- [x] DependencyGraph cycle detection
- [x] Ready/blocked query correctness
- [x] CLI command execution (bd-31b - DONE)

### Fuzz Tests

- [ ] ID generation with random inputs
- [ ] JSONL parsing with malformed input
- [ ] Search query parsing

### Benchmarks

- [ ] Create issue: < 1ms
- [ ] List 1k issues: < 10ms
- [ ] List 10k issues: < 100ms
- [ ] Ready query (1k issues, 2k deps): < 5ms
- [ ] Ready query (10k issues, 20k deps): < 50ms
- [ ] Export 10k issues: < 500ms
- [ ] Import 10k issues: < 1s

---

## Phase 9: Polish

### Error Handling (bd-236 - DONE)

- [x] Structured error types
- [x] User-friendly error messages
- [ ] Suggestions for common mistakes
- [x] Exit codes (0 success, 1 user error, 2 system error)

### Documentation

- [x] README with usage examples
- [ ] Man page (if desired)
- [x] `--help` for all commands
- [x] Architecture docs (update existing)

### Performance

- [~] Prepared statement caching (N/A - no SQL)
- [x] Lazy initialization
- [x] Blocked cache invalidation
- [ ] Memory pool for allocations

### Cross-Platform (bd-kl5 - DONE)

- [x] Linux support
- [x] macOS support
- [x] Windows support
- [x] Path handling (std.fs.path)

---

## Appendix A: CLI Command Reference

Target command set for beads_zig (inspired by beads_rust):

```
COMMANDS:
  init           Initialize workspace
  create         Create new issue
  q              Quick capture (create + print ID)
  show           Display issue details
  update         Update issue fields
  close          Close issue
  reopen         Reopen closed issue
  delete         Soft delete (tombstone)
  list           List issues with filters
  ready          Show actionable issues
  blocked        Show blocked issues
  search         Full-text search
  stale          Find stale issues
  count          Count issues
  dep            Dependency management
    add          Add dependency
    remove       Remove dependency
    list         List dependencies
    tree         Show dependency tree
    cycles       Detect cycles
  label          Label management
    add          Add labels
    remove       Remove labels
    list         List labels on issue
    list-all     List all labels
  comments       Comment management
    add          Add comment
    list         List comments
  history        Show issue history
  audit          Deep audit analysis
  epic           Epic management
  defer          Defer issue
  undefer        Remove deferral
  orphans        Find orphaned issues
  changelog      Generate changelog
  lint           Validate data integrity
  graph          Dependency graph
  sync           Save/load JSONL
  doctor         Run diagnostics
  stats/status   Project statistics
  info           Workspace info
  config         Configuration
  agents         Manage agent instructions
  version        Show version
  completions    Shell completions
```

---

## Appendix B: Data Format

### JSONL Format

beads_zig uses JSONL (JSON Lines) as its storage format:

```json
{"id":"bd-abc123","title":"Fix login bug","description":null,"status":"open","priority":1,"issue_type":"bug","assignee":"alice","created_at":"2024-01-29T15:30:00Z","updated_at":"2024-01-29T15:30:00Z"}
```

Key requirements:
- One JSON object per line
- RFC3339 timestamps
- Null for missing optional fields
- UTF-8 encoding

### Storage Architecture

beads_zig uses Lock + WAL + Compact (no SQLite):

```
.beads/
  issues.jsonl    # Main file (compacted state, git-tracked)
  issues.wal      # Write-ahead log (gitignored)
  .beads.lock     # flock target (gitignored)
```

**Architecture comparison (for reference):**
| Aspect | SQLite approach | beads_zig |
|--------|-----------------|-----------|
| Storage | SQLite + WAL mode | JSONL + custom WAL |
| Concurrency | SQLite locking | flock + append WAL |
| Binary size | ~5-8MB | ~12KB |
| Write time | Variable (lock contention) | Constant ~1ms |
| Read time | O(1) with indexes | O(n) linear scan |

**Trade-offs:**
- beads_zig sacrifices read performance (linear scan vs indexes)
- beads_zig gains concurrent write performance (no lock contention)
- For typical workloads (<10k issues), linear scan is fast enough

---

## Appendix C: Priority Order

Recommended implementation order for efficient development:

1. **Models** - Foundation for everything [DONE]
2. **Storage** - JSONL + in-memory store [DONE]
3. **ID Generation** - Required for create [DONE]
4. **Dependencies** - Cycle detection, ready/blocked [DONE]
5. **Basic CLI** (init, create, show, list) - Usable MVP
6. **Labels/Comments** - Secondary features
7. **Advanced Commands** - Nice to have
8. **Polish** - Error handling, docs, perf

---

## Notes

- `rich_zig` is expected to be available soon for terminal formatting
- Prioritize correctness over performance initially
- Follow CLAUDE.md guidelines (no emojis, no legacy code, archive don't delete)
- Tests are diagnostic, not verdicts - focus on behavior not coverage
