# FEATURE_PARITY.md - beads_zig vs beads_rust

This document tracks feature parity between `beads_zig` and `beads_rust`. The goal is a complete Zig port of the local-first issue tracker.

**Reference Implementation**: https://github.com/Dicklesworthstone/beads_rust
**Target**: Full CLI and library parity with idiomatic Zig implementation

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

#### Issue Model

- [ ] `Issue` struct with all fields:
  - [ ] `id: []const u8` - Unique ID (bd-abc123)
  - [ ] `title: []const u8` - 1-500 chars
  - [ ] `description: ?[]const u8`
  - [ ] `design: ?[]const u8`
  - [ ] `acceptance_criteria: ?[]const u8`
  - [ ] `notes: ?[]const u8`
  - [ ] `status: Status`
  - [ ] `priority: Priority` (0-4)
  - [ ] `issue_type: IssueType`
  - [ ] `assignee: ?[]const u8`
  - [ ] `owner: ?[]const u8`
  - [ ] `estimated_minutes: ?i32`
  - [ ] `created_at: i64` (Unix timestamp)
  - [ ] `created_by: ?[]const u8`
  - [ ] `updated_at: i64`
  - [ ] `closed_at: ?i64`
  - [ ] `close_reason: ?[]const u8`
  - [ ] `due_at: ?i64`
  - [ ] `defer_until: ?i64`
  - [ ] `external_ref: ?[]const u8`
  - [ ] `source_system: ?[]const u8`
  - [ ] `pinned: bool`
  - [ ] `is_template: bool`
- [ ] Issue validation (title length, field constraints)
- [ ] Issue JSON serialization
- [ ] Issue equality and hashing

#### Status Enum

- [ ] `Status` enum:
  - [ ] `open`
  - [ ] `in_progress`
  - [ ] `blocked`
  - [ ] `deferred`
  - [ ] `closed`
  - [ ] `tombstone` (soft deleted)
  - [ ] `pinned`
  - [ ] `custom` (with string payload)
- [ ] Status string parsing
- [ ] Status serialization

#### Priority

- [ ] `Priority` struct (0-4, lower is higher priority):
  - [ ] 0 = Critical
  - [ ] 1 = High
  - [ ] 2 = Medium
  - [ ] 3 = Low
  - [ ] 4 = Backlog
- [ ] Priority parsing from int/string
- [ ] Priority comparison

#### Issue Type Enum

- [ ] `IssueType` enum:
  - [ ] `task`
  - [ ] `bug`
  - [ ] `feature`
  - [ ] `epic`
  - [ ] `chore`
  - [ ] `docs`
  - [ ] `question`
  - [ ] `custom` (with string payload)
- [ ] Type string parsing
- [ ] Type serialization

#### Dependency Model

- [ ] `Dependency` struct:
  - [ ] `issue_id: []const u8`
  - [ ] `depends_on_id: []const u8`
  - [ ] `dep_type: DependencyType`
  - [ ] `created_at: i64`
  - [ ] `created_by: ?[]const u8`
  - [ ] `metadata: ?[]const u8`
  - [ ] `thread_id: ?[]const u8`
- [ ] `DependencyType` enum:
  - [ ] `blocks`
  - [ ] `parent_child`
  - [ ] `conditional_blocks`
  - [ ] `waits_for`
  - [ ] `related`
  - [ ] `discovered_from`
  - [ ] `replies_to`
  - [ ] `relates_to`
  - [ ] `duplicates`
  - [ ] `supersedes`
  - [ ] `caused_by`
  - [ ] `custom`

#### Comment Model

- [ ] `Comment` struct:
  - [ ] `id: i64`
  - [ ] `issue_id: []const u8`
  - [ ] `author: []const u8`
  - [ ] `body: []const u8`
  - [ ] `created_at: i64`
- [ ] Comment validation
- [ ] Comment serialization

#### Event Model (Audit Log)

- [ ] `Event` struct:
  - [ ] `id: i64`
  - [ ] `issue_id: []const u8`
  - [ ] `event_type: EventType`
  - [ ] `actor: []const u8`
  - [ ] `old_value: ?[]const u8`
  - [ ] `new_value: ?[]const u8`
  - [ ] `created_at: i64`
- [ ] `EventType` enum:
  - [ ] `created`
  - [ ] `updated`
  - [ ] `status_changed`
  - [ ] `priority_changed`
  - [ ] `assignee_changed`
  - [ ] `commented`
  - [ ] `closed`
  - [ ] `reopened`
  - [ ] `dependency_added`
  - [ ] `dependency_removed`
  - [ ] `label_added`
  - [ ] `label_removed`
  - [ ] `compacted`
  - [ ] `deleted`
  - [ ] `restored`
  - [ ] `custom`

---

## Phase 2: Storage Layer

### JSONL + WAL + In-Memory Storage (`src/storage/`)

beads_zig uses pure Zig storage: JSONL files with a Write-Ahead Log (WAL) for concurrent access, and in-memory indexing for fast queries. No SQLite, no C dependencies.

**Key Difference from beads_rust**: beads_rust uses SQLite with WAL mode. beads_zig uses a custom Lock + WAL + Compact architecture that:
- Eliminates SQLite's lock contention issues under heavy parallel agent load
- Provides constant-time writes (~1ms) regardless of database size
- Allows lock-free reads (no contention for list/show/status)
- Auto-releases locks on process crash (kernel-managed flock)

See `docs/concurrent_writes.md` for detailed design rationale.

#### File Structure

```
.beads/
  beads.jsonl       # Main file (compacted state)
  beads.wal         # Write-ahead log (recent appends)
  beads.lock        # Lock file (flock target)
```

#### JsonlFile (`src/storage/jsonl.zig`)

- [x] `JsonlFile` struct with path and allocator
- [x] `readAll()` - Parse JSONL file to `[]Issue`
- [x] `writeAll(issues)` - Atomic write (temp + fsync + rename)
- [x] `append(issue)` - Append single issue (for quick capture)
- [x] Handle missing file gracefully (return empty)
- [x] Unknown field preservation (beads_rust compatibility)

#### Concurrent Write Handling (`src/storage/lock.zig`)

- [ ] `BeadsLock` struct with flock-based locking
- [ ] `acquire()` - Blocking exclusive lock (LOCK_EX)
- [ ] `tryAcquire()` - Non-blocking lock attempt (LOCK_NB)
- [ ] `acquireTimeout(ms)` - Lock with timeout
- [ ] `release()` - Release lock (LOCK_UN)
- [ ] `withLock(fn)` - RAII-style lock wrapper
- [ ] Windows compatibility (LockFileEx)

#### WAL Operations (`src/storage/wal.zig`)

- [ ] `WalEntry` struct (op, timestamp, id, data)
- [ ] `WalOp` enum (add, update, close, reopen, delete, set_blocked, unset_blocked)
- [ ] `appendWalEntry(entry)` - Append to WAL under lock
- [ ] `replayWal(file)` - Apply WAL entries to in-memory state
- [ ] WAL entry serialization (JSON lines)

#### Compaction (`src/storage/compact.zig`)

- [ ] `compact()` - Merge WAL into main file atomically
- [ ] `maybeCompact()` - Trigger compaction when WAL > threshold
- [ ] Compaction threshold: 100 ops OR 100KB
- [ ] Atomic main file replacement (temp + fsync + rename)

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

#### Search (Future)

- [ ] Linear scan substring matching (basic)
- [ ] Inverted index for full-text search (advanced)

---

## Phase 3: ID Generation

### Base36 Encoding (`src/id/`)

- [ ] Base36 character set (0-9, a-z)
- [ ] `encodeBase36(value: u64) []const u8`
- [ ] `decodeBase36(str: []const u8) !u64`

### Content Hashing

- [ ] SHA256 content hash function
- [ ] Fields included: title, description, design, acceptance_criteria, notes, status, priority, issue_type, assignee, owner, created_by, external_ref, source_system, pinned, is_template
- [ ] Null byte separator for stability
- [ ] 64-character hex output

### ID Generation

- [ ] `generateId(title, description, creator, timestamp, nonce) []const u8`
- [ ] SHA256 of metadata -> first 8 bytes -> u64 -> Base36
- [ ] Adaptive hash length (3-8 chars based on DB size)
- [ ] Birthday problem collision avoidance
- [ ] Configurable prefix (default "bd")
- [ ] Hierarchical child IDs (bd-abc123.1.2)

### ID Parsing

- [ ] `parseId(id: []const u8) !ParsedId`
- [ ] Prefix extraction
- [ ] Hash extraction
- [ ] Child path parsing
- [ ] Validation

---

## Phase 4: JSONL Sync

### Core Operations

With JSONL as the primary storage, sync is simplified:

- [x] `IssueStore.loadFromFile()` - Load JSONL into memory
- [x] `IssueStore.saveToFile()` - Save memory to JSONL (atomic)
- [x] Atomic writes (temp file + fsync + rename)
- [x] Dirty tracking for modified issues

### Sync Commands

- [ ] `sync --flush-only` - Force save to JSONL
- [ ] `sync --import-only` - Force reload from JSONL
- [ ] `sync --force` - Force even if data loss possible
- [ ] Auto-save after mutations (configurable)
- [ ] Auto-load on startup

### Import/Export for Migration

- [ ] Import from beads_rust JSONL format
- [ ] Validate prefix matches config
- [ ] Timestamp-based conflict resolution (newer wins)
- [ ] Content hash deduplication

---

## Phase 5: CLI Framework

### Argument Parsing (`src/cli/`)

- [ ] Global flags:
  - [ ] `--json` - JSON output
  - [ ] `-v, -vv` - Verbosity levels
  - [ ] `--quiet` - Suppress output
  - [ ] `--no-color` - Disable colors
  - [ ] `--data <PATH>` - Override `.beads/` directory
  - [ ] `--actor <NAME>` - Set actor for audit
  - [ ] `--no-auto-flush` - Skip auto-save
  - [ ] `--no-auto-import` - Skip auto-load
- [ ] Subcommand dispatch
- [ ] Help text generation
- [ ] Error formatting

### Output Formatting (`src/output/`)

- [ ] Rich mode (TTY with colors via rich_zig)
- [ ] Plain mode (no colors, piped output)
- [ ] JSON mode (structured output)
- [ ] Quiet mode (minimal output)
- [ ] Automatic mode detection (isatty)

---

## Phase 6: CLI Commands

### Workspace Commands

- [ ] `bz init` - Initialize workspace
  - [ ] Create `.beads/` directory
  - [ ] Create `issues.jsonl` (empty)
  - [ ] Create `config.yaml`
  - [ ] Create `metadata.json`
  - [ ] `--prefix` option for issue ID prefix
- [ ] `bz config` - Manage configuration
  - [ ] `--list` - Show all settings
  - [ ] `--get <key>` - Get specific value
  - [ ] `--set <key>=<value>` - Set value
- [ ] `bz info` - Show workspace info
- [ ] `bz stats` / `bz status` - Project statistics
- [ ] `bz doctor` - Run diagnostics

### Issue CRUD Commands

- [ ] `bz create <title>` - Create issue
  - [ ] `--type` (bug/feature/task/epic/chore/docs/question)
  - [ ] `--priority` (0-4 or critical/high/medium/low/backlog)
  - [ ] `--description`
  - [ ] `--assignee`
  - [ ] `--labels` (multiple)
  - [ ] `--deps` (multiple dependency IDs)
  - [ ] `--due` (date)
  - [ ] `--estimate` (minutes)
  - [ ] Return created ID
- [ ] `bz q <title>` - Quick capture (create + print ID only)
- [ ] `bz show <id>` - Display issue details
  - [ ] Full metadata
  - [ ] Labels
  - [ ] Dependencies
  - [ ] Recent comments
  - [ ] `--json` support
- [ ] `bz update <id>` - Update issue
  - [ ] `--status`
  - [ ] `--priority`
  - [ ] `--title`
  - [ ] `--description`
  - [ ] `--assignee`
  - [ ] `--type`
  - [ ] Audit trail event
- [ ] `bz close <id>` - Close issue
  - [ ] `--reason`
  - [ ] Set `closed_at` timestamp
  - [ ] Audit event
- [ ] `bz reopen <id>` - Reopen closed issue
  - [ ] Clear `closed_at`
  - [ ] Audit event
- [ ] `bz delete <id>` - Soft delete (tombstone)
  - [ ] `--reason`
  - [ ] Set status to tombstone
  - [ ] Audit event

### Query Commands

- [ ] `bz list` - List issues
  - [ ] `--status` filter
  - [ ] `--priority` filter
  - [ ] `--type` filter
  - [ ] `--assignee` filter
  - [ ] `--label` filter (multiple)
  - [ ] `--limit` and `--offset`
  - [ ] `--sort` (created, updated, priority)
  - [ ] `--json` output
- [ ] `bz ready` - Show actionable issues
  - [ ] Open status
  - [ ] Not blocked by dependencies
  - [ ] Not deferred (or defer_until passed)
  - [ ] `--limit`
  - [ ] `--json`
- [ ] `bz blocked` - Show blocked issues
  - [ ] Has blocking dependencies
  - [ ] Show what blocks each
  - [ ] `--json`
- [ ] `bz search <query>` - Full-text search
  - [ ] Search title, description, notes
  - [ ] FTS5 ranking
  - [ ] `--json`
- [ ] `bz stale` - Find stale issues
  - [ ] `--days` (default 30)
  - [ ] Not updated in N days
  - [ ] `--json`
- [ ] `bz count` - Count issues
  - [ ] `--by` (status/priority/type/assignee)
  - [ ] Grouped counts
  - [ ] `--json`

### Dependency Commands

- [ ] `bz dep add <child> <parent>` - Add dependency
  - [ ] `--type` (blocks/parent-child/waits-for/related/etc.)
  - [ ] Cycle detection
  - [ ] Audit event
- [ ] `bz dep remove <child> <parent>` - Remove dependency
  - [ ] Audit event
- [ ] `bz dep list <id>` - List dependencies
  - [ ] Show what this issue depends on
  - [ ] Show what depends on this issue
  - [ ] `--json`
- [ ] `bz dep tree <id>` - Show dependency tree
  - [ ] ASCII tree visualization
  - [ ] `--json` (adjacency list)
- [ ] `bz dep cycles` - Detect circular dependencies
  - [ ] List all cycles found
  - [ ] `--json`

### Label Commands

- [ ] `bz label add <id> <labels...>` - Add labels
  - [ ] Multiple labels
  - [ ] Audit events
- [ ] `bz label remove <id> <labels...>` - Remove labels
  - [ ] Multiple labels
  - [ ] Audit events
- [ ] `bz label list <id>` - List labels on issue
- [ ] `bz label list-all` - List all labels in project

### Comment Commands

- [ ] `bz comments add <id> <text>` - Add comment
  - [ ] Auto-detect actor
  - [ ] Audit event
- [ ] `bz comments list <id>` - Show comments
  - [ ] Chronological order
  - [ ] `--json`

### Audit Commands

- [ ] `bz history <id>` - Show issue history
  - [ ] All events for issue
  - [ ] Chronological
  - [ ] `--json`
- [ ] `bz audit` - Deep audit analysis
  - [ ] All events in project
  - [ ] Filters by date/actor/type
  - [ ] `--json`

### Advanced Commands

- [ ] `bz epic` - Manage epics
  - [ ] Create epic
  - [ ] Add issues to epic
  - [ ] List epic contents
- [ ] `bz defer <id> --until <date>` - Defer issue
  - [ ] Set `defer_until`
  - [ ] Excluded from ready
- [ ] `bz undefer <id>` - Remove deferral
- [ ] `bz orphans` - Find orphaned issues
  - [ ] Issues with missing parent refs
- [ ] `bz changelog` - Generate changelog
  - [ ] `--since` date
  - [ ] `--until` date
  - [ ] Grouped by type
  - [ ] Markdown output
- [ ] `bz lint` - Validate database
  - [ ] Check consistency
  - [ ] Find invalid refs
  - [ ] `--json`
- [ ] `bz graph` - Dependency graph
  - [ ] ASCII visualization
  - [ ] DOT format export

### Sync Commands

- [ ] `bz sync --flush-only` - Export to JSONL
- [ ] `bz sync --import-only` - Import from JSONL
- [ ] `bz sync --force` - Force sync

### System Commands

- [ ] `bz version` - Show version info
- [ ] `bz completions <shell>` - Generate shell completions
  - [ ] bash
  - [ ] zsh
  - [ ] fish
- [ ] `bz agents` - Manage agent instructions (if applicable)

---

## Phase 7: Configuration

### Config System (`src/config/`)

- [ ] YAML parser/writer
- [ ] User config (`~/.config/beads/config.yaml`)
- [ ] Project config (`.beads/config.yaml`)
- [ ] Config merging (project overrides user)
- [ ] Config keys:
  - [ ] `issue_prefix` (default "bd")
  - [ ] `default_assignee`
  - [ ] `auto_flush` (bool)
  - [ ] `auto_import` (bool)
  - [ ] `lock_timeout_ms`
  - [ ] `actor_name`

### Metadata

- [ ] `.beads/metadata.json`:
  - [ ] Schema version
  - [ ] Created timestamp
  - [ ] Last sync timestamp
  - [ ] Issue count cache

---

## Phase 8: Testing

### Unit Tests

- [ ] Model serialization/deserialization
- [ ] ID generation (determinism, uniqueness)
- [ ] Base36 encoding/decoding
- [ ] Content hashing
- [ ] Status/Priority/Type parsing
- [ ] Dependency cycle detection

### Integration Tests

- [x] JSONL read/write roundtrip
- [x] IssueStore operations
- [x] DependencyGraph cycle detection
- [x] Ready/blocked query correctness
- [ ] CLI command execution

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

### Error Handling

- [ ] Structured error types
- [ ] User-friendly error messages
- [ ] Suggestions for common mistakes
- [ ] Exit codes (0 success, 1 user error, 2 system error)

### Documentation

- [ ] README with usage examples
- [ ] Man page (if desired)
- [ ] `--help` for all commands
- [ ] Architecture docs (update existing)

### Performance

- [ ] Prepared statement caching
- [ ] Lazy initialization
- [ ] Blocked cache invalidation
- [ ] Memory pool for allocations

### Cross-Platform

- [ ] Linux support
- [ ] macOS support
- [ ] Windows support
- [ ] Path handling (std.fs.path)

---

## Appendix A: beads_rust CLI Reference

Full command reference from beads_rust for parity verification:

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

## Appendix B: Data Format Compatibility

### JSONL Format

beads_zig can import JSONL files from beads_rust:

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
  beads.jsonl   # Main file (compacted state, git-tracked)
  beads.wal     # Write-ahead log (gitignored)
  beads.lock    # flock target (gitignored)
```

**Key differences from beads_rust:**
| Aspect | beads_rust | beads_zig |
|--------|------------|-----------|
| Storage | SQLite + WAL mode | JSONL + custom WAL |
| Concurrency | SQLite locking | flock + append WAL |
| Binary size | ~5-8MB | ~12KB |
| Write time | Variable (lock contention) | Constant ~1ms |
| Read time | O(1) with indexes | O(n) linear scan |

**Trade-offs:**
- beads_zig sacrifices read performance (linear scan vs SQLite indexes)
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
