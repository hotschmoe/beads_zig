# Feature Gaps: bz (beads_zig) vs br (beads_rust)

This document tracks feature parity between bz and the reference implementation br.
Each gap has an associated bead for tracking implementation.

---

## Commands Missing in bz

### 1. `query` - Saved Queries
**Bead:** `bd-34z`

br supports saving, running, listing, and deleting named queries:
```bash
br query save my-bugs --status open --type bug
br query run my-bugs
br query list
br query delete my-bugs
```

**Subcommands needed:**
- `save <NAME>` - Save current filter set as named query
- `run <NAME>` - Run a saved query
- `list` - List all saved queries
- `delete <NAME>` - Delete a saved query

**Storage:** Could use `.beads/queries.json` or add to config.

---

### 2. `upgrade` - Self-Upgrade
**Bead:** `bd-idb`

br can upgrade itself:
```bash
br upgrade           # Upgrade to latest
br upgrade --check   # Check only
br upgrade --version 0.2.0  # Specific version
```

**Implementation:** Download release binary from GitHub releases, replace current binary.

---

### 3. `where` - Show Active Directory
**Bead:** `bd-moo`

Simple utility to show the resolved .beads directory path:
```bash
br where
# /home/user/project/.beads
```

Useful when .beads redirects are in play.

---

## Missing Fields on Issues

### 4. Issue Model Fields (CONSOLIDATED)
**Bead:** `bd-20s` (consolidated from bd-20s, bd-p51, bd-7qo, bd-nf7)

Add missing optional string fields to Issue model:

| Field | CLI Flag | Purpose |
|-------|----------|---------|
| `owner` | `--owner` | Who's responsible (vs assignee who's working) |
| `design` | `--design` | Dedicated field for design notes |
| `acceptance_criteria` | `--acceptance-criteria` | Acceptance criteria checklist |
| `external_ref` | `--external-ref` | Link to external systems (GitHub, Jira) |

```bash
br create "Task" --owner alice@example.com --assignee bob
br create "Feature" --design "Use adapter pattern..."
br create "Feature" --acceptance-criteria "- [ ] Unit tests pass"
br create "Bug" --external-ref "https://github.com/org/repo/issues/123"
```

**Model change:** Add four `?[]const u8` fields to Issue struct.

---

### 5. `ephemeral` Flag
**Bead:** `bd-ph2`

Mark issues as non-exported (not written to JSONL):
```bash
br create "Temp task" --ephemeral
```

Useful for local-only tracking that shouldn't be committed.

**Model change:** Add `ephemeral: bool` to Issue struct, skip in JSONL export.

---

### 6. `--claim` Flag
**Bead:** `bd-1yr`

Atomic operation: set assignee to actor AND status to in_progress:
```bash
br update BD-1 --claim  # Sets assignee=$ACTOR, status=in_progress
```

**Implementation:** Add `--claim` flag to update command, performs both operations atomically.

---

### 7. `--session` Tracking
**Bead:** `bd-gyy`

Track which session closed an issue:
```bash
br close BD-1 --session "session-abc123"
br update BD-1 --session "session-xyz"
```

Useful for agent/automation tracking.

**Model change:** Add `closed_by_session: ?[]const u8` to Issue struct.

---

## Missing Filter Options

### 8. `--label-any` (OR Logic)
**Bead:** `bd-1n0`

br supports both AND and OR logic for label filters:
```bash
br list -l bug -l urgent        # AND: must have BOTH labels
br list --label-any bug --label-any urgent  # OR: has EITHER label
```

bz currently only supports AND logic.

**Implementation:** Add `--label-any` flag with OR semantics.

---

### 9. `--priority-min` / `--priority-max`
**Bead:** `bd-2y0`

Filter by priority range:
```bash
br list --priority-min 1 --priority-max 3  # P1, P2, or P3
```

**Implementation:** Add range filter flags to list/ready/blocked commands.

---

### 10. `--title-contains` / `--desc-contains` / `--notes-contains`
**Bead:** `bd-1no`

Substring filters for specific fields:
```bash
br list --title-contains "auth"
br list --desc-contains "security"
br list --notes-contains "TODO"
```

More targeted than full-text search.

**Implementation:** Add substring filter flags to list command.

---

### 11. `--overdue` Filter
**Bead:** `bd-uxk`

Filter for issues past their due date:
```bash
br list --overdue
br ready --overdue  # Ready AND overdue
```

**Implementation:** Compare `due_date` against current time.

---

### 12. `--deferred` Include Flag
**Bead:** `bd-2zh`

Include deferred issues in list output:
```bash
br list --deferred  # Include deferred in results
br ready --include-deferred
```

bz may already filter these out by default.

---

### 13. `--parent` / `--recursive` Filters
**Bead:** `bd-hbc`

Filter to children of a parent issue:
```bash
br ready --parent BD-1           # Direct children only
br ready --parent BD-1 --recursive  # All descendants
```

**Implementation:** Walk dependency graph for parent-child relationships.

---

## Missing Output Options

### 14. CSV Output Format
**Bead:** `bd-225`

Export as CSV:
```bash
br list --format csv
br list --format csv --fields id,title,status,priority
```

**Implementation:** Add CSV formatter to output module.

---

### 15. `--wrap` Long Lines
**Bead:** `bd-2hx`

Wrap long text in terminal output:
```bash
br list --wrap
br show BD-1 --wrap
```

**Implementation:** Add text wrapping to plain text formatter.

---

### 16. `--stats` Token Savings
**Bead:** `bd-190`

Show TOON format token savings:
```bash
br list --toon --stats
# ... output ...
# Token savings: 45% (1234 -> 678 tokens)
```

**Implementation:** Calculate and display compression ratio.

---

### 17. `--robot` Machine Output
**Bead:** `bd-3q3`

Consistent machine-readable output mode:
```bash
br close BD-1 --robot
br ready --robot
```

Different from `--json` - simpler, line-oriented format.

---

## Missing Delete Options (CONSOLIDATED)

### 18. Delete Command Enhancements
**Bead:** `bd-3ps` (consolidated from bd-1jj, bd-3ps, bd-35o, bd-17w)

Add missing delete command options:

| Flag | Purpose |
|------|---------|
| `--from-file` | Delete multiple issues from a file (one ID per line) |
| `--cascade` | Delete issue and all its dependents recursively |
| `--hard` | Prune tombstones immediately (no sync marker) |
| `--dry-run` | Preview what would be deleted |

```bash
br delete --from-file ids-to-delete.txt
br delete BD-1 --cascade
br delete BD-1 --hard
br delete BD-1 --cascade --dry-run
# Would delete: BD-1, BD-2, BD-3
```

**Implementation:** Walk dependency graph for cascade, skip tombstone for hard.

---

## Missing Dependency Features (CONSOLIDATED)

### 19. Dependency Command Enhancements
**Bead:** `bd-1ww` (consolidated from bd-1ww, bd-6jr, bd-1be, bd-12v)

Enhance the `dep` command with additional features:

**Additional dependency types:**
- `conditional-blocks` - Blocks under certain conditions
- `waits-for` - Non-blocking wait
- `discovered-from` - Origin tracking
- `replies-to` - Comment threading
- `supersedes` - Replacement tracking
- `caused-by` - Root cause linking

bz currently has: blocks, relates_to, duplicates

**New flags:**
| Flag | Purpose |
|------|---------|
| `--metadata` | Attach JSON metadata to dependencies |
| `--direction` | Filter by direction (up/down/both) |
| `--format mermaid` | Export as Mermaid diagram |

```bash
br dep add BD-1 BD-2 --type blocks --metadata '{"reason": "needs API first"}'
br dep list BD-1 --direction down  # What BD-1 depends on
br dep list BD-1 --direction up    # What depends on BD-1
br dep tree BD-1 --format mermaid
```

---

## Missing Label Features

### 20. `label rename` Subcommand
**Bead:** `bd-99t`

Rename a label across all issues:
```bash
br label rename old-name new-name
```

**Implementation:** Scan all issues, replace label in-place.

---

## Missing Epic Features (CONSOLIDATED)

### 21. Epic Management Enhancements
**Bead:** `bd-z94` (consolidated from bd-z94, bd-1xc)

Add epic management subcommands:

| Subcommand | Purpose |
|------------|---------|
| `epic status` | Show status overview of all epics |
| `epic close-eligible` | Auto-close epics where all children are closed |

```bash
br epic status
# BD-EPIC-1: 3/5 complete (60%)
# BD-EPIC-2: 10/10 complete (100%) [eligible for close]

br epic close-eligible --dry-run
br epic close-eligible
```

---

## Missing Sync Features

### 22. `--merge` 3-Way Merge
**Bead:** `bd-2jl`

Perform 3-way merge of local DB and remote JSONL:
```bash
br sync --merge
```

Handles concurrent edits from multiple sources.

---

### 23. `--status` Sync Status
**Bead:** `bd-35p`

Show sync status without making changes:
```bash
br sync --status
# DB: 45 issues, JSONL: 43 issues
# 2 issues pending export
```

---

### 24. `--manifest` Write Manifest
**Bead:** `bd-148`

Write manifest file with export summary:
```bash
br sync --flush-only --manifest
# Creates .beads/manifest.json with export metadata
```

---

### 25. Sync Policy Options (CONSOLIDATED)
**Bead:** `bd-2m1` (consolidated from bd-2m1, bd-2sj, bd-60g)

Add policy flags for sync edge case handling:

| Flag | Purpose |
|------|---------|
| `--error-policy` | Control export error handling (strict/best-effort/partial) |
| `--orphans` | Control orphan handling on import (strict/resurrect/skip) |
| `--rename-prefix` | Fix issues with wrong prefix during import |

```bash
br sync --flush-only --error-policy strict
br sync --import-only --orphans resurrect
br sync --import-only --rename-prefix
```

---

## Missing History Features

### 26. History Backup Management
**Bead:** `bd-aqe`

br's `history` manages JSONL backups (bz uses it for issue events):
```bash
br history list              # List backups
br history diff <file>       # Diff backup vs current
br history restore <file>    # Restore from backup
br history prune --keep 10   # Keep only 10 backups
```

Consider adding as `backup` command to avoid conflict with bz's `history`.

---

## Missing Audit Features (CONSOLIDATED)

### 27. Audit Command
**Bead:** `bd-87v` (consolidated from bd-87v, bd-1wk, bd-2qc)

Add `audit` command for LLM/tool interaction tracking:

| Subcommand | Purpose |
|------------|---------|
| `audit record` | Record LLM/tool interactions for training data |
| `audit label` | Label audit entries for quality tracking |
| `audit log` | View audit log for specific issue |
| `audit summary` | Summary of audit data over time period |

```bash
br audit record --kind llm_call --model gpt-4 --prompt "..." --response "..."
br audit record --kind tool_call --tool-name grep --exit-code 0
br audit label <entry-id> --label good --reason "Correct approach"
br audit log BD-1
br audit summary --days 7
```

---

## Missing Stats Features

### 28. `--activity` Git-Based Stats
**Bead:** `bd-5nf`

Show git-based activity statistics:
```bash
br stats --activity
br stats --activity-hours 48  # Last 48 hours
```

Correlates issue activity with git commits.

---

## Missing Changelog Features

### 29. `--since-tag` / `--since-commit`
**Bead:** `bd-1qm`

Git-aware date references for changelog:
```bash
br changelog --since-tag v1.0.0
br changelog --since-commit abc123
```

---

## Missing Graph Features (CONSOLIDATED)

### 30. Graph Command Enhancements
**Bead:** `bd-2is` (consolidated from bd-2is, bd-1yt)

Add graph output options:

| Flag | Purpose |
|------|---------|
| `--all` | Show dependency graph for all open issues |
| `--compact` | Compact one-line-per-issue output |

```bash
br graph --all
br graph BD-1 --compact
```

---

## Missing Create Options

### 31. `--dry-run` on Create
**Bead:** `bd-1t4`

Preview issue creation:
```bash
br create "New feature" --type feature --dry-run
# Would create: BD-42 "New feature" (feature, P2)
```

---

## Summary

| Category | Count | Primary Bead |
|----------|-------|--------------|
| Missing Commands | 3 | bd-34z, bd-idb, bd-moo |
| Missing Fields | 4 | bd-20s (consolidated), bd-ph2, bd-1yr, bd-gyy |
| Missing Filters | 6 | bd-1n0, bd-2y0, bd-1no, bd-uxk, bd-2zh, bd-hbc |
| Missing Output Options | 4 | bd-225, bd-2hx, bd-190, bd-3q3 |
| Missing Delete Options | 1 | bd-3ps (consolidated) |
| Missing Dependency Features | 1 | bd-1ww (consolidated) |
| Missing Label Features | 1 | bd-99t |
| Missing Epic Features | 1 | bd-z94 (consolidated) |
| Missing Sync Features | 4 | bd-2jl, bd-35p, bd-148, bd-2m1 (consolidated) |
| Missing History Features | 1 | bd-aqe |
| Missing Audit Features | 1 | bd-87v (consolidated) |
| Missing Stats Features | 1 | bd-5nf |
| Missing Changelog Features | 1 | bd-1qm |
| Missing Graph Features | 1 | bd-2is (consolidated) |
| Missing Create Options | 1 | bd-1t4 |
| **Total** | **31** | (was 46, consolidated 15) |

---

## Consolidation Summary

The following beads were consolidated:

| Primary Bead | Absorbed Beads | Reason |
|--------------|----------------|--------|
| bd-20s | bd-p51, bd-7qo, bd-nf7 | All add optional string fields to Issue model |
| bd-3ps | bd-1jj, bd-35o, bd-17w | All delete command enhancements |
| bd-1ww | bd-6jr, bd-1be, bd-12v | All dependency command enhancements |
| bd-z94 | bd-1xc | Both epic subcommands |
| bd-2m1 | bd-2sj, bd-60g | All sync policy options |
| bd-87v | bd-1wk, bd-2qc | All audit command subcommands |
| bd-2is | bd-1yt | Both graph output enhancements |

**Beads to close:** bd-p51, bd-7qo, bd-nf7, bd-1jj, bd-35o, bd-17w, bd-6jr, bd-1be, bd-12v, bd-1xc, bd-2sj, bd-60g, bd-1wk, bd-2qc, bd-1yt

---

## Priority Guide

**P1 - High Value (implement first):**
- bd-1yr: `--claim` flag (atomic assignee + in_progress)
- bd-1n0: `--label-any` (OR logic)
- bd-99t: `label rename` subcommand
- bd-3ps: Delete enhancements (consolidated)
- bd-z94: Epic management (consolidated)

**P2 - Medium Value:**
- bd-34z: `query` saved queries
- bd-20s: Issue model fields (consolidated)
- bd-225: CSV output format
- bd-uxk: `--overdue` filter
- bd-87v: Audit command (consolidated)

**P3 - Lower Value:**
- bd-idb: `upgrade` command
- bd-moo: `where` command
- bd-1ww: Dependency enhancements (consolidated)
- bd-190: `--stats` token savings
