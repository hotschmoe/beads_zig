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
- [x] SQLite integration option (system vs bundled)
- [ ] Add `rich_zig` dependency (terminal formatting)
- [ ] Verify cross-platform builds (Linux, macOS, Windows)

### Project Structure

```
src/
├── main.zig              # CLI entry point
├── root.zig              # Library exports
├── cli/                  # Command implementations
│   ├── mod.zig           # CLI module root
│   ├── init.zig
│   ├── create.zig
│   ├── list.zig
│   ├── show.zig
│   ├── update.zig
│   ├── close.zig
│   ├── reopen.zig
│   ├── delete.zig
│   ├── ready.zig
│   ├── blocked.zig
│   ├── search.zig
│   ├── sync.zig
│   ├── dep.zig
│   ├── label.zig
│   ├── comments.zig
│   ├── history.zig
│   └── ...
├── storage/              # Database layer
│   ├── mod.zig
│   ├── sqlite.zig        # SQLite operations
│   ├── schema.zig        # Schema definition
│   └── migrations.zig    # Schema versioning
├── models/               # Data structures
│   ├── mod.zig
│   ├── issue.zig
│   ├── status.zig
│   ├── priority.zig
│   ├── issue_type.zig
│   ├── dependency.zig
│   ├── comment.zig
│   └── event.zig
├── sync/                 # JSONL import/export
│   ├── mod.zig
│   ├── export.zig
│   └── import.zig
├── id/                   # ID generation
│   ├── mod.zig
│   ├── base36.zig
│   └── hash.zig
├── config/               # Configuration
│   ├── mod.zig
│   └── yaml.zig
└── output/               # Formatting
    ├── mod.zig
    ├── rich.zig
    ├── plain.zig
    └── json.zig
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

### SQLite Integration (`src/storage/`)

#### Core Database

- [ ] SQLite connection wrapper
- [ ] WAL mode configuration
- [ ] Busy timeout handling (default 5s)
- [ ] Transaction support (immediate mode)
- [ ] Prepared statement caching
- [ ] Connection pooling (optional)

#### Schema (`src/storage/schema.zig`)

- [ ] `issues` table:
  ```sql
  CREATE TABLE issues (
      id TEXT PRIMARY KEY,
      title TEXT NOT NULL,
      description TEXT,
      design TEXT,
      acceptance_criteria TEXT,
      notes TEXT,
      status TEXT NOT NULL DEFAULT 'open',
      priority INTEGER NOT NULL DEFAULT 2,
      issue_type TEXT NOT NULL DEFAULT 'task',
      assignee TEXT,
      owner TEXT,
      estimated_minutes INTEGER,
      created_at INTEGER NOT NULL,
      created_by TEXT,
      updated_at INTEGER NOT NULL,
      closed_at INTEGER,
      close_reason TEXT,
      due_at INTEGER,
      defer_until INTEGER,
      external_ref TEXT,
      source_system TEXT,
      pinned INTEGER NOT NULL DEFAULT 0,
      is_template INTEGER NOT NULL DEFAULT 0,
      content_hash TEXT
  );
  ```
- [ ] `labels` table
- [ ] `issue_labels` junction table
- [ ] `dependencies` table
- [ ] `comments` table
- [ ] `events` table (audit log)
- [ ] `dirty_issues` table (sync tracking)
- [ ] `blocked_cache` table (query optimization)
- [ ] FTS5 virtual table for full-text search
- [ ] Indexes for common queries

#### CRUD Operations

- [ ] `insertIssue(issue: Issue) !void`
- [ ] `getIssue(id: []const u8) !?Issue`
- [ ] `updateIssue(id: []const u8, updates: IssueUpdate) !void`
- [ ] `deleteIssue(id: []const u8) !void` (tombstone)
- [ ] `listIssues(filters: ListFilters) ![]Issue`
- [ ] `searchIssues(query: []const u8) ![]Issue`
- [ ] `countIssues(group_by: ?GroupBy) !CountResult`

#### Dependency Operations

- [ ] `addDependency(dep: Dependency) !void`
- [ ] `removeDependency(issue_id, depends_on_id) !void`
- [ ] `getDependencies(issue_id: []const u8) ![]Dependency`
- [ ] `getDependents(issue_id: []const u8) ![]Dependency`
- [ ] `detectCycles() !?[][]const u8`
- [ ] `getReadyIssues() ![]Issue` (open, not blocked, not deferred)
- [ ] `getBlockedIssues() ![]Issue`
- [ ] Blocked cache maintenance

#### Label Operations

- [ ] `addLabel(issue_id, label) !void`
- [ ] `removeLabel(issue_id, label) !void`
- [ ] `getLabels(issue_id) ![][]const u8`
- [ ] `getAllLabels() ![][]const u8`
- [ ] `getIssuesByLabel(label) ![]Issue`

#### Comment Operations

- [ ] `addComment(comment: Comment) !void`
- [ ] `getComments(issue_id) ![]Comment`

#### Event Operations

- [ ] `logEvent(event: Event) !void`
- [ ] `getHistory(issue_id) ![]Event`
- [ ] `getAuditLog(filters: AuditFilters) ![]Event`

#### Dirty Tracking

- [ ] `markDirty(issue_id) !void`
- [ ] `getDirtyIssues() ![][]const u8`
- [ ] `clearDirty(issue_ids: [][]const u8) !void`

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

### Export (`src/sync/export.zig`)

- [ ] Query dirty issues
- [ ] Validate issues and relations
- [ ] Compute content hashes
- [ ] Serialize to JSONL (one issue per line)
- [ ] Atomic write (temp file -> rename)
- [ ] Clear dirty flags on success
- [ ] Backup previous JSONL

### Import (`src/sync/import.zig`)

- [ ] Read JSONL line by line
- [ ] Parse JSON to Issue struct
- [ ] Detect ID collisions
- [ ] Validate prefix matches config
- [ ] Timestamp-based conflict resolution (newer wins)
- [ ] Upsert to database
- [ ] Rebuild blocked cache if deps changed

### Sync Commands

- [ ] `sync --flush-only` - Export dirty to JSONL
- [ ] `sync --import-only` - Import JSONL to database
- [ ] `sync --force` - Force even if stale
- [ ] Auto-flush after mutations (configurable)
- [ ] Auto-import on startup if JSONL newer

---

## Phase 5: CLI Framework

### Argument Parsing (`src/cli/`)

- [ ] Global flags:
  - [ ] `--json` - JSON output
  - [ ] `-v, -vv` - Verbosity levels
  - [ ] `--quiet` - Suppress output
  - [ ] `--no-color` - Disable colors
  - [ ] `--db <PATH>` - Override database path
  - [ ] `--actor <NAME>` - Set actor for audit
  - [ ] `--lock-timeout <MS>` - SQLite timeout
  - [ ] `--no-auto-flush` - Skip auto-export
  - [ ] `--no-auto-import` - Skip JSONL check
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
  - [ ] Create `beads.db` SQLite database
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

- [ ] `bz schema` - View database schema
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

- [ ] SQLite operations
- [ ] JSONL import/export roundtrip
- [ ] CLI command execution
- [ ] Ready/blocked query correctness

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
  lint           Validate database
  graph          Dependency graph
  sync           JSONL sync
  doctor         Run diagnostics
  stats/status   Project statistics
  info           Workspace info
  config         Configuration
  schema         View database schema
  agents         Manage agent instructions
  version        Show version
  completions    Shell completions
```

---

## Appendix B: Data Format Compatibility

### JSONL Format

beads_zig MUST produce JSONL compatible with beads_rust:

```json
{"id":"bd-abc123","title":"Fix login bug","description":null,"status":"open","priority":1,"issue_type":"bug","assignee":"alice","created_at":"2024-01-29T15:30:00Z","updated_at":"2024-01-29T15:30:00Z"}
```

Key requirements:
- One JSON object per line
- RFC3339 timestamps
- Null for missing optional fields
- UTF-8 encoding
- No trailing newline on last line (debatable, verify)

### SQLite Schema Compatibility

Tables must be compatible for potential migration:
- Same column names and types
- Same index structure
- WAL mode enabled

---

## Appendix C: Priority Order

Recommended implementation order for efficient development:

1. **Models** - Foundation for everything
2. **Storage/SQLite** - Core persistence
3. **ID Generation** - Required for create
4. **Basic CLI** (init, create, show, list) - Usable MVP
5. **JSONL Sync** - Collaboration feature
6. **Dependencies** - Key differentiator
7. **Labels/Comments** - Secondary features
8. **Advanced Commands** - Nice to have
9. **Polish** - Error handling, docs, perf

---

## Notes

- `rich_zig` is expected to be available soon for terminal formatting
- Prioritize correctness over performance initially
- Follow CLAUDE.md guidelines (no emojis, no legacy code, archive don't delete)
- Tests are diagnostic, not verdicts - focus on behavior not coverage
