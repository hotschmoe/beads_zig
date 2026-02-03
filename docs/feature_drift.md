# Feature Drift: beads_rust (br) vs beads_zig (bz)

This document tracks the feature differences between br and bz implementations.

Last updated: 2026-02-02

## Issue/Bead Field Comparison

### Core Fields

| Field | br | bz | LLM Utility | Notes |
|-------|:--:|:--:|-------------|-------|
| `id` | Y | Y | Essential | Issue identifier |
| `title` | Y | Y | Essential | Issue summary |
| `description` | Y | Y | Essential | Detailed context |
| `status` | Y | Y | Essential | Workflow state |
| `priority` | Y | Y | High | Triage decisions |
| `issue_type` | Y | Y | High | task/bug/feature/epic |
| `created_at` | Y | Y | Medium | Ordering, staleness |
| `updated_at` | Y | Y | Medium | Activity tracking |
| `created_by` | Y | Y | Medium | Attribution |

### Rich Content Fields

| Field | br | bz | LLM Utility | Notes |
|-------|:--:|:--:|-------------|-------|
| `design` | Y | Y | High | Implementation approach |
| `acceptance_criteria` | Y | Y | High | Definition of done |
| `notes` | Y | Y | Medium | Additional context |

### Assignment & Ownership

| Field | br | bz | LLM Utility | Notes |
|-------|:--:|:--:|-------------|-------|
| `assignee` | Y | Y | High | Who's working on it |
| `owner` | Y | Y | Medium | Responsible party |

### Lifecycle Fields

| Field | br | bz | LLM Utility | Notes |
|-------|:--:|:--:|-------------|-------|
| `closed_at` | Y | Y | Medium | Completion timestamp |
| `close_reason` | Y | Y | High | Why it was closed |
| `closed_by_session` | Y | Y | Low | Session tracking |
| `deleted_at` | Y | - | Low | Soft delete timestamp |
| `deleted_by` | Y | - | Low | Who deleted |
| `delete_reason` | Y | - | Low | Why deleted |

### Scheduling Fields

| Field | br | bz | LLM Utility | Notes |
|-------|:--:|:--:|-------------|-------|
| `due_at` | Y | Y | High | Deadline |
| `defer_until` | Y | Y | High | When to resurface |
| `estimated_minutes` | Y | Y | Medium | Time estimate |

### Organization Fields

| Field | br | bz | LLM Utility | Notes |
|-------|:--:|:--:|-------------|-------|
| `labels` | Y | Y | High | Categorization |
| `dependencies` | Y | Y | Essential | Blockers/relationships |
| `comments` | Y | Y | High | Discussion history |

### Special Flags

| Field | br | bz | LLM Utility | Notes |
|-------|:--:|:--:|-------------|-------|
| `pinned` | Y | Y | Medium | High-visibility flag |
| `is_template` | Y | Y | Low | Template creation |
| `ephemeral` | Y | Y | Medium | Skip JSONL export |

### External Integration

| Field | br | bz | LLM Utility | Notes |
|-------|:--:|:--:|-------------|-------|
| `external_ref` | Y | Y | Medium | Link to external tracker |
| `source_system` | Y | Y | Low | Import source |

### Deduplication & Sync

| Field | br | bz | LLM Utility | Notes |
|-------|:--:|:--:|-------------|-------|
| `content_hash` | - | Y | Low | SHA256 for dedup |
| `version` | - | Y | Low | Optimistic locking |
| `source_repo` | Y | - | Low | Git repo origin |
| `original_size` | Y | - | Low | Pre-compaction size |
| `original_type` | Y | - | Low | Pre-migration type |
| `compaction_level` | Y | - | Low | Sync metadata |
| `compacted_at` | Y | - | Low | Last compaction time |
| `compacted_at_commit` | Y | - | Low | Git commit at compaction |
| `sender` | Y | - | Low | Message sender (email import) |

### Summary

- **br-only fields (9)**: `deleted_at`, `deleted_by`, `delete_reason`, `source_repo`, `original_size`, `original_type`, `compaction_level`, `compacted_at`, `compacted_at_commit`, `sender`
- **bz-only fields (2)**: `content_hash`, `version`
- **Shared fields (27)**: All core functionality

---

## Command Comparison

### Workspace Commands

| Command | br | bz | Notes |
|---------|:--:|:--:|-------|
| `init` | Y | Y | Initialize workspace |
| `info` | Y | Y | Show workspace info |
| `stats` | Y | Y | Project statistics |
| `status` | Y | - | Alias for stats in br |
| `doctor` | Y | Y | Diagnostic checks |
| `config` | Y | Y | Manage configuration |
| `sync` | Y | Y | JSONL sync |
| `where` | Y | - | Show .beads directory |
| `upgrade` | Y | - | Self-upgrade br binary |

### Issue Management

| Command | br | bz | Notes |
|---------|:--:|:--:|-------|
| `create` | Y | Y | Create issue |
| `q` | Y | Y | Quick capture |
| `show` | Y | Y | Show issue details |
| `update` | Y | Y | Update issue |
| `close` | Y | Y | Close issue |
| `reopen` | Y | Y | Reopen issue |
| `delete` | Y | Y | Soft delete (tombstone) |
| `defer` | Y | Y | Defer issue |
| `undefer` | Y | Y | Remove deferral |

### Batch Operations

| Command | br | bz | Notes |
|---------|:--:|:--:|-------|
| `add-batch` | - | Y | Bulk create from stdin |
| `import` | - | Y | Import from JSONL |

### Queries

| Command | br | bz | Notes |
|---------|:--:|:--:|-------|
| `list` | Y | Y | List issues |
| `ready` | Y | Y | Unblocked issues |
| `blocked` | Y | Y | Blocked issues |
| `search` | Y | Y | Full-text search |
| `stale` | Y | Y | Stale issues |
| `count` | Y | Y | Count with grouping |
| `orphans` | Y | Y | Missing parent refs |
| `lint` | Y | Y | Consistency checks |

### Dependencies

| Subcommand | br | bz | Notes |
|------------|:--:|:--:|-------|
| `dep add` | Y | Y | Add dependency |
| `dep remove` | Y | Y | Remove dependency |
| `dep list` | Y | Y | List dependencies |
| `dep tree` | Y | Y | Show dep tree |
| `dep cycles` | Y | Y | Detect cycles |
| `graph` | Y | Y | Visualize deps (top-level in bz) |

### Epics

| Subcommand | br | bz | Notes |
|------------|:--:|:--:|-------|
| `epic create` | - | Y | Create epic |
| `epic add` | - | Y | Add issue to epic |
| `epic remove` | - | Y | Remove from epic |
| `epic list` | - | Y | List epic issues |
| `epic status` | Y | - | Show epic progress |
| `epic close-eligible` | Y | - | Auto-close complete epics |

### Labels

| Subcommand | br | bz | Notes |
|------------|:--:|:--:|-------|
| `label add` | Y | Y | Add labels |
| `label remove` | Y | Y | Remove labels |
| `label list` | Y | Y | List issue labels |
| `label list-all` | Y | Y | All project labels |
| `label rename` | Y | - | Rename across all issues |

### Comments

| Subcommand | br | bz | Notes |
|------------|:--:|:--:|-------|
| `comments add` | Y | Y | Add comment |
| `comments list` | Y | Y | List comments |

### Audit & History

| Command | br | bz | Notes |
|---------|:--:|:--:|-------|
| `history <id>` | - | Y | Issue history (top-level) |
| `audit` | Y | Y | Project audit log |
| `changelog` | Y | Y | Generate changelog |
| `history list` | Y | - | List backups (subcommand) |
| `history diff` | Y | - | Diff backup |
| `history restore` | Y | - | Restore from backup |
| `history prune` | Y | - | Prune old backups |

### Backup (bz-specific)

| Subcommand | br | bz | Notes |
|------------|:--:|:--:|-------|
| `backup list` | - | Y | List backups |
| `backup create` | - | Y | Create backup |
| `backup diff` | - | Y | Compare backup |
| `backup restore` | - | Y | Restore backup |
| `backup prune` | - | Y | Remove old backups |

### Saved Queries (br-specific)

| Subcommand | br | bz | Notes |
|------------|:--:|:--:|-------|
| `query save` | Y | - | Save filter set |
| `query run` | Y | - | Run saved query |
| `query list` | Y | - | List queries |
| `query delete` | Y | - | Delete query |

### System Commands

| Command | br | bz | Notes |
|---------|:--:|:--:|-------|
| `help` | Y | Y | Show help |
| `version` | Y | Y | Show version |
| `schema` | Y | Y | Show data schema |
| `completions` | Y | Y | Shell completions |
| `agents` | Y | - | Manage AGENTS.md |

### Global Options

| Option | br | bz | Notes |
|--------|:--:|:--:|-------|
| `--json` | Y | Y | JSON output |
| `--toon` | - | Y | TOON format (LLM-optimized) |
| `--quiet` | Y | Y | Suppress output |
| `--verbose` | Y | Y | Increase verbosity |
| `--no-color` | Y | Y | Disable colors |
| `--actor` | Y | Y | Override actor name |
| `--no-auto-flush` | Y | Y | Skip JSONL export |
| `--no-auto-import` | Y | Y | Skip freshness check |
| `--data` | - | Y | Override .beads/ path |
| `--db` | Y | - | Database path |
| `--no-db` | Y | - | JSONL-only mode |
| `--allow-stale` | Y | - | Bypass freshness warning |
| `--lock-timeout` | Y | - | SQLite busy timeout |
| `--no-daemon` | Y | - | Force direct mode |

---

## LLM Task Tracking Assessment

### Essential Fields (must have)

- `id` - Reference across sessions
- `title` - Quick identification
- `description` - Full context
- `status` - Workflow state
- `dependencies` - Blockers/relationships

### High Value Fields

- `priority` - Triage decisions
- `issue_type` - Categorization
- `design` - Implementation approach
- `acceptance_criteria` - Definition of done
- `assignee` - Who's working on it
- `labels` - Categorization
- `comments` - Discussion history
- `due_at` - Deadlines
- `defer_until` - Scheduled resurfacing
- `close_reason` - Learning from closures

### Medium Value Fields

- `created_at`, `updated_at` - Staleness detection
- `created_by` - Attribution
- `owner` - Responsibility
- `notes` - Additional context
- `estimated_minutes` - Planning
- `pinned` - Visibility
- `external_ref` - Cross-system links
- `ephemeral` - Temp issue marking

### Low Value for LLMs (internal/sync metadata)

- `content_hash`, `version` - Sync internals
- `source_repo`, `source_system` - Import tracking
- `compaction_level`, `compacted_at`, `original_size` - Storage internals
- `closed_by_session` - Session tracking
- `deleted_at`, `deleted_by`, `delete_reason` - Soft delete audit
- `is_template` - Template creation
- `sender`, `original_type` - Migration artifacts

### Recommendations

1. **JSONL export should include all High Value fields** - br's minimal export is missing critical context
2. **`--toon` output is valuable** - bz's LLM-optimized format should be adopted by br
3. **`design` and `acceptance_criteria` are underused** - These fields are ideal for LLM context
4. **`comments` are essential** - Multi-session LLMs need discussion history
5. **Sync metadata should stay internal** - Fields like `compaction_level` add noise

---

## Migration Priority

### br needs from bz

1. `--toon` output format
2. `add-batch` for bulk operations
3. `backup` command family
4. `epic create/add/remove/list` subcommands

### bz needs from br

1. `agents` command (AGENTS.md management)
2. `query` command family (saved queries)
3. `where` command
4. `upgrade` command (self-update)
5. `label rename` subcommand
6. `epic status` and `epic close-eligible`
7. Soft delete fields (`deleted_at`, `deleted_by`, `delete_reason`)
