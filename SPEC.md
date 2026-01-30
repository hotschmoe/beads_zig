# SPEC.md - beads_zig Technical Specification

**Version**: 0.1.0-draft
**Status**: Draft - Pending Review
**Compatibility Target**: beads_rust JSONL import (can read beads_rust exports; output format may differ)

---

## Table of Contents

1. [Overview](#overview)
2. [Data Models](#data-models)
3. [Storage Layer](#storage-layer)
4. [ID Generation](#id-generation)
5. [JSONL Format](#jsonl-format)
6. [Sync Semantics](#sync-semantics)
7. [CLI Interface](#cli-interface)
8. [Configuration](#configuration)
9. [Error Handling](#error-handling)
10. [Open Questions](#open-questions)

---

## Overview

### Directory Structure

```
.beads/
  issues.jsonl    # JSONL storage (git tracked)
  config.yaml     # Project configuration (git tracked)
  metadata.json   # System metadata (gitignored)
```

### Binary Name

The compiled binary is `bz` (beads-zig).

### Zig Version

Minimum supported: Zig 0.15.2

---

## Data Models

### Issue

The primary entity. All fields align with beads_rust for JSONL compatibility.

```zig
pub const Issue = struct {
    // Identity
    id: []const u8,                    // "bd-abc123" format
    content_hash: ?[]const u8,         // SHA256 for deduplication

    // Content
    title: []const u8,                 // Required, 1-500 characters
    description: ?[]const u8,
    design: ?[]const u8,
    acceptance_criteria: ?[]const u8,
    notes: ?[]const u8,

    // Classification
    status: Status,
    priority: Priority,
    issue_type: IssueType,

    // Assignment
    assignee: ?[]const u8,
    owner: ?[]const u8,

    // Timestamps (Unix epoch seconds)
    created_at: i64,
    created_by: ?[]const u8,
    updated_at: i64,
    closed_at: ?i64,
    close_reason: ?[]const u8,

    // Scheduling
    due_at: ?i64,
    defer_until: ?i64,
    estimated_minutes: ?i32,

    // External references
    external_ref: ?[]const u8,         // Link to external tracker
    source_system: ?[]const u8,        // Where imported from

    // Flags
    pinned: bool,                      // High-priority display
    is_template: bool,                 // Template for new issues

    // Embedded relations (populated on read, not stored in issues table)
    labels: []const []const u8,
    dependencies: []const Dependency,
    comments: []const Comment,
};
```

### Status

Issue lifecycle states.

```zig
pub const Status = union(enum) {
    open,
    in_progress,
    blocked,
    deferred,
    closed,
    tombstone,      // Soft deleted
    pinned,
    custom: []const u8,

    pub fn toString(self: Status) []const u8 {
        return switch (self) {
            .open => "open",
            .in_progress => "in_progress",
            .blocked => "blocked",
            .deferred => "deferred",
            .closed => "closed",
            .tombstone => "tombstone",
            .pinned => "pinned",
            .custom => |s| s,
        };
    }

    pub fn fromString(s: []const u8) Status {
        // Case-insensitive matching
        // Returns .custom for unknown values
    }
};
```

### Priority

Lower number = higher priority. Range: 0-4.

```zig
pub const Priority = struct {
    value: u3,  // 0-4

    pub const CRITICAL = Priority{ .value = 0 };
    pub const HIGH = Priority{ .value = 1 };
    pub const MEDIUM = Priority{ .value = 2 };
    pub const LOW = Priority{ .value = 3 };
    pub const BACKLOG = Priority{ .value = 4 };

    pub fn fromInt(n: anytype) !Priority {
        if (n < 0 or n > 4) return error.InvalidPriority;
        return Priority{ .value = @intCast(n) };
    }

    pub fn toString(self: Priority) []const u8 {
        return switch (self.value) {
            0 => "critical",
            1 => "high",
            2 => "medium",
            3 => "low",
            4 => "backlog",
            else => unreachable,
        };
    }
};
```

### IssueType

```zig
pub const IssueType = union(enum) {
    task,
    bug,
    feature,
    epic,
    chore,
    docs,
    question,
    custom: []const u8,

    pub fn toString(self: IssueType) []const u8;
    pub fn fromString(s: []const u8) IssueType;
};
```

### Dependency

Relationships between issues.

```zig
pub const Dependency = struct {
    issue_id: []const u8,         // Dependent issue
    depends_on_id: []const u8,    // Blocker issue
    dep_type: DependencyType,
    created_at: i64,
    created_by: ?[]const u8,
    metadata: ?[]const u8,        // JSON blob
    thread_id: ?[]const u8,
};

pub const DependencyType = union(enum) {
    blocks,
    parent_child,
    conditional_blocks,
    waits_for,
    related,
    discovered_from,
    replies_to,
    relates_to,
    duplicates,
    supersedes,
    caused_by,
    custom: []const u8,
};
```

### Comment

```zig
pub const Comment = struct {
    id: i64,                      // Auto-increment
    issue_id: []const u8,
    author: []const u8,
    body: []const u8,
    created_at: i64,
};
```

### Event (Audit Log)

```zig
pub const Event = struct {
    id: i64,                      // Auto-increment
    issue_id: []const u8,
    event_type: EventType,
    actor: []const u8,
    old_value: ?[]const u8,       // JSON
    new_value: ?[]const u8,       // JSON
    created_at: i64,
};

pub const EventType = enum {
    created,
    updated,
    status_changed,
    priority_changed,
    assignee_changed,
    commented,
    closed,
    reopened,
    dependency_added,
    dependency_removed,
    label_added,
    label_removed,
    compacted,
    deleted,
    restored,
};
```

---

## Storage Layer

### Architecture

beads_zig uses a pure Zig storage layer with no external dependencies:

```
┌─────────────────────────────────────────────────────────────┐
│                      IssueStore                              │
│  ┌─────────────────┐    ┌─────────────────────────────────┐ │
│  │ ArrayList(Issue)│    │ StringHashMap(usize) - ID index │ │
│  └────────┬────────┘    └─────────────────────────────────┘ │
│           │                                                  │
│           ▼                                                  │
│  ┌─────────────────────────────────────────────────────────┐ │
│  │                    JsonlFile                             │ │
│  │  - readAll() - parse JSONL to Issue structs              │ │
│  │  - writeAll() - atomic write (temp + fsync + rename)     │ │
│  └─────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
                    .beads/issues.jsonl
```

### In-Memory Storage (`store.zig`)

```zig
pub const IssueStore = struct {
    allocator: std.mem.Allocator,
    issues: std.ArrayListUnmanaged(Issue),     // All issues
    id_index: std.StringHashMapUnmanaged(usize), // ID -> index lookup
    dirty_ids: std.StringHashMapUnmanaged(void), // Modified issue IDs
    path: []const u8,                           // JSONL file path
};
```

**Operations**:
- `insert(issue)` - Add new issue, update index
- `get(id)` - O(1) lookup via hash map
- `update(id, updates)` - Modify in place
- `delete(id)` - Remove from list and index
- `list(filters)` - Linear scan with filtering
- `loadFromFile()` - Parse JSONL into memory
- `saveToFile()` - Atomic write all issues

### Dependency Graph (`graph.zig`)

```zig
pub const DependencyGraph = struct {
    store: *IssueStore,
    allocator: std.mem.Allocator,
};
```

**Operations**:
- `addDependency(dep)` - With cycle detection
- `removeDependency(issue_id, depends_on_id)`
- `getDependencies(issue_id)` - What this issue depends on
- `getDependents(issue_id)` - What depends on this issue
- `wouldCreateCycle(from, to)` - DFS reachability check
- `detectCycles()` - Find all cycles in graph
- `getReadyIssues()` - Open, unblocked, not deferred
- `getBlockedIssues()` - Open with unresolved dependencies

### JSONL File I/O (`jsonl.zig`)

```zig
pub const JsonlFile = struct {
    path: []const u8,
    allocator: std.mem.Allocator,
};
```

**Atomic Write Protocol**:
1. Write to temp file (`{path}.tmp.{timestamp}`)
2. fsync for durability
3. Rename over target (atomic on POSIX)

**Read Protocol**:
1. Read entire file into memory
2. Split by newlines
3. Parse each line as JSON Issue
4. Skip malformed lines (graceful degradation)

### Search

Full-text search is performed via linear scan with substring matching.
Future enhancement: inverted index for faster search.

---

## ID Generation

### Format

```
<prefix>-<hash>
```

- **prefix**: Configurable, default `bd`
- **hash**: Base36 encoded (0-9, a-z), 3-8 characters

### Algorithm

1. Generate 16 random bytes
2. Mix with current nanosecond timestamp
3. SHA256 hash the combined data
4. Take first N bytes (adaptive based on DB size)
5. Encode as Base36
6. Prepend prefix

### Adaptive Length

| Issue Count | Hash Length | Collision Probability |
|-------------|-------------|----------------------|
| < 1,000 | 3 chars | ~0.01% |
| < 50,000 | 4 chars | ~0.01% |
| < 1,000,000 | 5 chars | ~0.01% |
| > 1,000,000 | 6+ chars | ~0.01% |

### Hierarchical IDs

Child issues use dot notation (maximum 3 levels):
- Parent: `bd-abc123`
- Child: `bd-abc123.1`
- Grandchild: `bd-abc123.1.2` (maximum depth)

Attempting to create deeper hierarchies returns `error.MaxHierarchyDepthExceeded`.

### Content Hash

SHA256 of concatenated fields (null byte separator):

```
title + \0 + description + \0 + status + \0 + priority + \0 + ...
```

Used for deduplication during import.

---

## JSONL Format

### Specification

- One complete JSON object per line
- UTF-8 encoding
- No trailing newline after last line
- Fields match Issue struct exactly
- Timestamps in RFC3339 format for JSON (e.g., `"2024-01-29T15:30:00Z"`)
- Null for missing optional fields

### Example

```json
{"id":"bd-abc123","content_hash":"a1b2c3...","title":"Fix login bug","description":"OAuth fails for Google accounts","status":"open","priority":1,"issue_type":"bug","assignee":"alice@example.com","owner":null,"created_at":"2024-01-29T10:00:00Z","created_by":"bob@example.com","updated_at":"2024-01-29T15:30:00Z","closed_at":null,"close_reason":null,"due_at":null,"defer_until":null,"estimated_minutes":60,"external_ref":null,"source_system":null,"pinned":false,"is_template":false,"labels":["urgent","backend"],"dependencies":[{"issue_id":"bd-abc123","depends_on_id":"bd-def456","dep_type":"blocks","created_at":"2024-01-29T10:00:00Z","created_by":"bob@example.com","metadata":null,"thread_id":null}],"comments":[]}
{"id":"bd-def456","content_hash":"d4e5f6...","title":"Set up OAuth provider","description":null,"status":"in_progress","priority":1,"issue_type":"task","assignee":"alice@example.com",...}
```

### Ordering

Issues sorted by ID for deterministic output.

---

## Sync Semantics

### Export (flush)

1. Get all non-tombstone issues from in-memory store
2. Serialize each issue as JSON line
3. Write to temporary file (`issues.jsonl.tmp.{timestamp}`)
4. fsync for durability
5. Atomic rename to `issues.jsonl`
6. Clear dirty flags

### Import

1. Validate path is within `.beads/`
2. Check for merge conflict markers (`<<<<<<<`, `=======`, `>>>>>>>`)
3. Parse JSONL line by line
4. Four-phase collision detection:
   - Phase 1: Match by external_ref
   - Phase 2: Match by content_hash
   - Phase 3: Match by ID
   - Phase 4: New issue (no match)
5. Upsert to in-memory store
6. Save to JSONL file

### Safety Guarantees

1. **No Git Operations**: Never execute git commands
2. **Path Confinement**: All I/O within `.beads/` unless explicitly overridden
3. **Atomic Writes**: Temp file + rename pattern
4. **Merge Conflict Rejection**: Refuse import if conflict markers present
5. **Empty Database Protection**: Refuse to export empty DB over non-empty JSONL

### Dirty Tracking

Issues marked dirty when:
- Created
- Updated (any field change)
- Label added/removed
- Dependency added/removed
- Comment added

Dirty flag cleared after successful export.

---

## CLI Interface

### Global Flags

| Flag | Short | Description |
|------|-------|-------------|
| `--json` | | Machine-readable JSON output |
| `--quiet` | `-q` | Suppress non-essential output |
| `--verbose` | `-v` | Increase verbosity (use twice for debug) |
| `--no-color` | | Disable ANSI colors |
| `--data <PATH>` | | Override `.beads/` directory path |
| `--actor <NAME>` | | Override actor name for audit |
| `--no-auto-flush` | | Skip automatic JSONL export |
| `--no-auto-import` | | Skip JSONL freshness check |

### Commands

#### Workspace

| Command | Description |
|---------|-------------|
| `bz init` | Initialize `.beads/` directory |
| `bz info` | Show workspace information |
| `bz stats` | Show project statistics |
| `bz doctor` | Run diagnostic checks |
| `bz config` | Manage configuration |

#### Issue CRUD

| Command | Description |
|---------|-------------|
| `bz create <title>` | Create new issue |
| `bz q <title>` | Quick capture (create + print ID only) |
| `bz show <id>` | Display issue details |
| `bz update <id>` | Update issue fields |
| `bz close <id>` | Close issue |
| `bz reopen <id>` | Reopen closed issue |
| `bz delete <id>` | Soft delete (tombstone) |

#### Query

| Command | Description |
|---------|-------------|
| `bz list` | List issues with filters |
| `bz ready` | Show actionable (unblocked) issues |
| `bz blocked` | Show blocked issues |
| `bz search <query>` | Full-text search |
| `bz stale` | Find issues not updated recently |
| `bz count` | Count issues by group |

#### Dependencies

| Command | Description |
|---------|-------------|
| `bz dep add <child> <parent>` | Add dependency |
| `bz dep remove <child> <parent>` | Remove dependency |
| `bz dep list <id>` | List dependencies for issue |
| `bz dep tree <id>` | Show dependency tree |
| `bz dep cycles` | Detect circular dependencies |

#### Labels

| Command | Description |
|---------|-------------|
| `bz label add <id> <labels...>` | Add labels |
| `bz label remove <id> <labels...>` | Remove labels |
| `bz label list <id>` | List labels on issue |
| `bz label list-all` | List all labels in project |

#### Comments

| Command | Description |
|---------|-------------|
| `bz comments add <id> <text>` | Add comment |
| `bz comments list <id>` | List comments |

#### Audit

| Command | Description |
|---------|-------------|
| `bz history <id>` | Show issue history |
| `bz audit` | Project-wide audit log |

#### Sync

| Command | Description |
|---------|-------------|
| `bz sync` | Bidirectional sync |
| `bz sync --flush-only` | Export to JSONL |
| `bz sync --import-only` | Import from JSONL |

#### System

| Command | Description |
|---------|-------------|
| `bz version` | Show version |
| `bz schema` | Show database schema |
| `bz completions <shell>` | Generate shell completions (bash, zsh, fish, powershell) |

---

## Configuration

### Precedence (highest to lowest)

1. CLI flags
2. Environment variables (`BEADS_*`)
3. Project config (`.beads/config.yaml`)
4. User config (`~/.config/beads/config.yaml`)
5. Built-in defaults

### Environment Variables

| Variable | Description |
|----------|-------------|
| `BEADS_DIR` | Override `.beads/` location |
| `BEADS_PREFIX` | Issue ID prefix |
| `BEADS_ACTOR` | Default actor name |
| `NO_COLOR` | Disable colors (any value) |

### Config File Format

```yaml
# .beads/config.yaml
id:
  prefix: "bd"
  min_hash_length: 3
  max_hash_length: 8

defaults:
  priority: 2
  issue_type: "task"

sync:
  auto_flush: true
  auto_import: true

output:
  color: true
```

### Config Keys

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `id.prefix` | string | `"bd"` | Issue ID prefix |
| `id.min_hash_length` | int | `3` | Minimum hash length |
| `id.max_hash_length` | int | `8` | Maximum hash length |
| `defaults.priority` | int | `2` | Default priority (medium) |
| `defaults.issue_type` | string | `"task"` | Default issue type |
| `sync.auto_flush` | bool | `true` | Auto-export after mutations |
| `sync.auto_import` | bool | `true` | Auto-import on read commands |
| `output.color` | bool | auto | Use ANSI colors |
| `actor` | string | `$USER` | Actor name for audit trail |

---

## Error Handling

### Exit Codes

| Code | Meaning |
|------|---------|
| 0 | Success |
| 1 | User error (invalid input, missing issue, etc.) |
| 2 | System error (database failure, I/O error, etc.) |

### Error Categories

```zig
pub const BeadsError = error{
    // Workspace
    NotInitialized,
    AlreadyInitialized,

    // Issues
    IssueNotFound,
    InvalidIssueId,
    TitleTooLong,
    InvalidPriority,
    InvalidStatus,

    // Dependencies
    CycleDetected,
    SelfDependency,
    DependencyNotFound,
    MaxHierarchyDepthExceeded,

    // Sync
    MergeConflictDetected,
    JsonlParseError,
    ExternalPathNotAllowed,
    WouldOverwriteData,

    // I/O
    FileNotFound,
    PermissionDenied,
    WriteError,
    AtomicRenameFailed,
};
```

### Error Messages

All errors should include:
- What failed
- Why it failed (if determinable)
- How to fix it (if applicable)

Example:
```
error: Issue 'bd-xyz' not found

Did you mean one of these?
  bd-xyz123  "Fix login timeout"
  bd-xyz456  "Update OAuth flow"
```

---

## Design Decisions

Resolved decisions for this implementation:

### Configuration Format

**Decision**: YAML (for now)

Rationale: Maintains compatibility with beads_rust configuration files, allowing users to share config between implementations. Requires implementing or importing a YAML parser.

**Future**: May migrate to a more performant format (JSON, TOML, or custom) once we establish our own patterns. Keeping beads_rust compatibility is valuable during early development but not a permanent constraint.

### Terminal Output

**Decision**: Colors optional (plain text default)

- Plain text output works without dependencies
- Colors enabled when `rich_zig` is available OR via inline ANSI codes
- Respects `NO_COLOR` environment variable
- `--no-color` flag always forces plain output

### JSONL Compatibility

**Decision**: Import-only compatible with beads_rust

- Can read and import JSONL files produced by beads_rust
- Output format may differ in field ordering, whitespace, or optional fields
- Content hash and ID formats remain compatible for deduplication

### Performance Targets

**Decision**: Correctness first, optimize later

No specific performance targets at this time. Focus on correct behavior. Benchmarks will be established once core functionality is complete.

### Shell Completions

**Decision**: Support all major shells

- bash
- zsh
- fish
- powershell

### Hierarchical ID Depth

**Decision**: Maximum 3 levels

- Parent: `bd-abc123`
- Child: `bd-abc123.1`
- Grandchild: `bd-abc123.1.2`

Deeper hierarchies are rejected. Use labels or dependencies for complex organization.

### Timestamp Format

**Decision**: Unix epoch internally, RFC3339 in JSONL

- In-memory storage uses `i64` Unix timestamps (seconds since epoch)
- JSONL serialization uses RFC3339 format (e.g., `"2024-01-29T15:30:00Z"`)
- This matches beads_rust behavior

---

## Revision History

| Version | Date | Changes |
|---------|------|---------|
| 0.1.0-draft | 2026-01-30 | Initial draft |
| 0.1.1-draft | 2026-01-30 | Resolved open questions: YAML config, optional colors, import-only JSONL compat, all shell completions, 3-level hierarchy limit |
