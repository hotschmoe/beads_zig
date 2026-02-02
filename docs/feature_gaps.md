# Feature Gaps: bz (beads_zig) vs br (beads_rust)

This document tracks feature parity between bz and the reference implementation br.
Each gap has an associated bead for tracking implementation.

---

## Commands Missing in bz

### 1. `query` - Saved Queries
**Bead:** `bd-258`

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
**Bead:** `bd-274`

br can upgrade itself:
```bash
br upgrade           # Upgrade to latest
br upgrade --check   # Check only
br upgrade --version 0.2.0  # Specific version
```

**Implementation:** Download release binary from GitHub releases, replace current binary.

---

### 3. `where` - Show Active Directory
**Bead:** `bd-1ec`

Simple utility to show the resolved .beads directory path:
```bash
br where
# /home/user/project/.beads
```

Useful when .beads redirects are in play.

---

## Missing Fields on Issues

### 4. Issue Model Fields (CONSOLIDATED)
**Bead:** `bd-2oo`

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
**Bead:** `bd-1h1`

Mark issues as non-exported (not written to JSONL):
```bash
br create "Temp task" --ephemeral
```

Useful for local-only tracking that shouldn't be committed.

**Model change:** Add `ephemeral: bool` to Issue struct, skip in JSONL export.

---

### 6. `--claim` Flag
**Bead:** `bd-kqn`

Atomic operation: set assignee to actor AND status to in_progress:
```bash
br update BD-1 --claim  # Sets assignee=$ACTOR, status=in_progress
```

**Implementation:** Add `--claim` flag to update command, performs both operations atomically.

---

### 7. `--session` Tracking
**Bead:** `bd-2zk`

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
**Bead:** `bd-1xy`

br supports both AND and OR logic for label filters:
```bash
br list -l bug -l urgent        # AND: must have BOTH labels
br list --label-any bug --label-any urgent  # OR: has EITHER label
```

bz currently only supports AND logic.

**Implementation:** Add `--label-any` flag with OR semantics.

---

### 9. `--priority-min` / `--priority-max`
**Bead:** `bd-2sa`

Filter by priority range:
```bash
br list --priority-min 1 --priority-max 3  # P1, P2, or P3
```

**Implementation:** Add range filter flags to list/ready/blocked commands.

---

### 10. `--title-contains` / `--desc-contains` / `--notes-contains`
**Bead:** `bd-3gs`

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
**Bead:** `bd-1px`

Filter for issues past their due date:
```bash
br list --overdue
br ready --overdue  # Ready AND overdue
```

**Implementation:** Compare `due_date` against current time.

---

### 12. `--deferred` Include Flag
**Bead:** `bd-3hb`

Include deferred issues in list output:
```bash
br list --deferred  # Include deferred in results
br ready --include-deferred
```

bz may already filter these out by default.

---

### 13. `--parent` / `--recursive` Filters
**Bead:** `bd-3ui`

Filter to children of a parent issue:
```bash
br ready --parent BD-1           # Direct children only
br ready --parent BD-1 --recursive  # All descendants
```

**Implementation:** Walk dependency graph for parent-child relationships.

---

## Missing Output Options

### 14. CSV Output Format
**Bead:** `bd-3k1`

Export as CSV:
```bash
br list --format csv
br list --format csv --fields id,title,status,priority
```

**Implementation:** Add CSV formatter to output module.

---

### 15. JSON Output Field Completeness
**Bead:** `bd-175`

The `--json` output for ready/blocked/list is too minimal for agent consumption:

| Field | bz ready | Agents need for |
|-------|----------|-----------------|
| id | Yes | Task identification |
| title | Yes | Display |
| priority | Yes | Sorting |
| description | No | Display, context |
| labels/tags | No | Grouping related tasks |
| created_at | No | Priority tie-breaking (FIFO) |
| blocks | No | Dependency chain analysis |
| status | No | Filtering (defaults to open) |

**Impact:** Agent functions like `getRelatedBeads()` fail because they can't group by tags or analyze dependency chains.

**Solution:** Add `--full` flag or enrich default output to include commonly-needed fields.

---

### 16. `--wrap` Long Lines
**Bead:** `bd-1jh`

Wrap long text in terminal output:
```bash
br list --wrap
br show BD-1 --wrap
```

**Implementation:** Add text wrapping to plain text formatter.

---

### 17. `--stats` Token Savings
**Bead:** `bd-16g`

Show TOON format token savings:
```bash
br list --toon --stats
# ... output ...
# Token savings: 45% (1234 -> 678 tokens)
```

**Implementation:** Calculate and display compression ratio.

---

### 18. `--robot` Machine Output
**Bead:** `bd-jup`

Consistent machine-readable output mode:
```bash
br close BD-1 --robot
br ready --robot
```

Different from `--json` - simpler, line-oriented format.

---

## Missing Delete Options (CONSOLIDATED)

### 19. Delete Command Enhancements
**Bead:** `bd-18y`

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

### 20. Dependency Command Enhancements
**Bead:** `bd-1y3`

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

### 21. `label rename` Subcommand
**Bead:** `bd-82t`

Rename a label across all issues:
```bash
br label rename old-name new-name
```

**Implementation:** Scan all issues, replace label in-place.

---

## Missing Epic Features (CONSOLIDATED)

### 22. Epic Management Enhancements
**Bead:** `bd-1rb`

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

### 23. `--merge` 3-Way Merge
**Bead:** `bd-199`

Perform 3-way merge of local DB and remote JSONL:
```bash
br sync --merge
```

Handles concurrent edits from multiple sources.

---

### 24. `--status` Sync Status
**Bead:** `bd-35a`

Show sync status without making changes:
```bash
br sync --status
# DB: 45 issues, JSONL: 43 issues
# 2 issues pending export
```

---

### 25. `--manifest` Write Manifest
**Bead:** `bd-267`

Write manifest file with export summary:
```bash
br sync --flush-only --manifest
# Creates .beads/manifest.json with export metadata
```

---

### 26. Sync Policy Options (CONSOLIDATED)
**Bead:** `bd-14z`

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

### 27. History Backup Management
**Bead:** `bd-17x`

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

### 28. Audit Command
**Bead:** `bd-nks`

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

### 29. `--activity` Git-Based Stats
**Bead:** `bd-3el`

Show git-based activity statistics:
```bash
br stats --activity
br stats --activity-hours 48  # Last 48 hours
```

Correlates issue activity with git commits.

---

## Missing Changelog Features

### 30. `--since-tag` / `--since-commit`
**Bead:** `bd-3uk`

Git-aware date references for changelog:
```bash
br changelog --since-tag v1.0.0
br changelog --since-commit abc123
```

---

## Missing Graph Features (CONSOLIDATED)

### 31. Graph Command Enhancements
**Bead:** `bd-24r`

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

### 32. `--dry-run` on Create
**Bead:** `bd-1wk`

Preview issue creation:
```bash
br create "New feature" --type feature --dry-run
# Would create: BD-42 "New feature" (feature, P2)
```

---

## Bug Fixes

### 33. Global Flags Before Subcommand
**Bead:** `bd-2bq`

Global flags like `--json` only work after the subcommand, not before:

```bash
bz ready --json    # Works (correct)
bz --json ready    # Fails (wrong)
```

**Expected:** Both orderings should work, matching CLI conventions (git, docker, etc.).

**Affected flags:** `--json`, `--toon`, `--quiet`, `--format`

**Files:** `src/cli/args.zig`

---

## Release & Distribution Infrastructure

These are bz-specific infrastructure tasks (not feature gaps vs br).

### 34. GitHub Actions Release Workflow
**Bead:** `bd-2y0`

Add automated workflow for cross-platform binary releases:
```yaml
# .github/workflows/release.yml
# Triggers on tag push, builds for:
# - Linux x86_64, ARM64
# - macOS Intel, Silicon
# - Windows x86_64
# Uploads tarballs + SHA256 checksums to GitHub releases
```

---

### 35. Installer Script
**Bead:** `bd-21u`

Create one-liner installer script with platform detection:
```bash
curl -fsSL https://raw.githubusercontent.com/.../install.sh | bash
# Detects: Linux x86_64/ARM64, macOS Intel/Silicon
# Downloads appropriate binary, installs to ~/.local/bin or /usr/local/bin
```

---

### 36. Build Release Script
**Bead:** `bd-jx2`

Create `scripts/build-release.sh` for local cross-compilation testing:
```bash
./scripts/build-release.sh
# Builds all targets locally for testing before CI release
```

---

### 37. Rich Installer Output
**Bead:** `bd-11l`

Add rich terminal output to install.sh:
- Colors for success/warning/error
- Progress spinners during download
- Progress bars for large downloads

---

### 38. Easy Mode for Installer
**Bead:** `bd-56p`

Add `--easy-mode` flag to install.sh:
```bash
curl -fsSL .../install.sh | bash -s -- --easy-mode
# Auto-adds binary to PATH (modifies .bashrc/.zshrc)
```

---

### 39. Checksum Verification
**Bead:** `bd-b6w`

Add SHA256 checksum verification to install.sh and `bz update`:
```bash
# Installer verifies downloaded binary against .sha256 file
# bz update --verify (default: on)
```

---

## Self-Update Infrastructure

### 40. `bz update` Command
**Bead:** `bd-1nz`

Implement self-updating binary command:
```bash
bz update           # Update to latest release
bz update --version 0.3.0  # Specific version
```

Downloads from GitHub releases, replaces current binary.

---

### 41. Update Command Flags
**Bead:** `bd-3cy`

Add `--check` and `--dry-run` flags to `bz update`:
```bash
bz update --check    # Check for updates without installing
bz update --dry-run  # Show what would be updated
```

---

## Database Migration Infrastructure

### 42. Migration Engine
**Bead:** `bd-12y`

Implement migration engine for JSONL database upgrades between versions:
- Detect schema version on load
- Apply migrations sequentially
- Backup before migration
- Rollback on failure

---

### 43. Schema Versioning
**Bead:** `bd-29y`

Add JSONL schema versioning to metadata.json:
```json
{
  "schema_version": 1,
  "created_at": "...",
  "bz_version": "0.2.0"
}
```

Enables migration engine to know which migrations to apply.

---

## Maintenance Tasks

### 44. Document Cleanup
**Bead:** `bd-1nm`

Review, clean up, and archive floating documents:
- Identify outdated docs
- Consolidate overlapping content
- Archive deprecated files to `.archive/`

---

### 45. ID Generation Review
**Bead:** `bd-2xi`

Review bd ID generation algorithm:
- Current implementation may have over-simplified
- Evaluate collision probability
- Consider length vs. readability tradeoffs

---

## Summary

| Category | Count | Primary Bead |
|----------|-------|--------------|
| Missing Commands | 3 | bd-258, bd-274, bd-1ec |
| Missing Fields | 4 | bd-2oo (consolidated), bd-1h1, bd-kqn, bd-2zk |
| Missing Filters | 6 | bd-1xy, bd-2sa, bd-3gs, bd-1px, bd-3hb, bd-3ui |
| Missing Output Options | 5 | bd-3k1, bd-175, bd-1jh, bd-16g, bd-jup |
| Missing Delete Options | 1 | bd-18y (consolidated) |
| Missing Dependency Features | 1 | bd-1y3 (consolidated) |
| Missing Label Features | 1 | bd-82t |
| Missing Epic Features | 1 | bd-1rb (consolidated) |
| Missing Sync Features | 4 | bd-199, bd-35a, bd-267, bd-14z (consolidated) |
| Missing History Features | 1 | bd-17x |
| Missing Audit Features | 1 | bd-nks (consolidated) |
| Missing Stats Features | 1 | bd-3el |
| Missing Changelog Features | 1 | bd-3uk |
| Missing Graph Features | 1 | bd-24r (consolidated) |
| Missing Create Options | 1 | bd-1wk |
| Release & Distribution | 6 | bd-2y0, bd-21u, bd-jx2, bd-11l, bd-56p, bd-b6w |
| Self-Update Infrastructure | 2 | bd-1nz, bd-3cy |
| Database Migration | 2 | bd-12y, bd-29y |
| Maintenance Tasks | 2 | bd-1nm, bd-2xi |
| Bug Fixes | 1 | bd-2bq |
| **Total** | **45** | (32 feature gaps + 12 infrastructure + 1 bug) |

---

## Consolidation Notes

The following beads represent consolidated features (multiple related items combined into one bead):

| Bead | Consolidated Scope |
|------|-------------------|
| bd-2oo | Issue model fields: owner, design, acceptance_criteria, external_ref |
| bd-18y | Delete enhancements: --from-file, --cascade, --hard, --dry-run |
| bd-1y3 | Dependency enhancements: types, --metadata, --direction, mermaid |
| bd-1rb | Epic management: status, close-eligible |
| bd-14z | Sync policy: --error-policy, --orphans, --rename-prefix |
| bd-nks | Audit command: record, label, log, summary |
| bd-24r | Graph enhancements: --all, --compact |

---

## Priority Guide

**P1 - High Value (implement first):**
- bd-kqn: `--claim` flag (atomic assignee + in_progress)
- bd-1xy: `--label-any` (OR logic)
- bd-82t: `label rename` subcommand
- bd-18y: Delete enhancements (consolidated)
- bd-1rb: Epic management (consolidated)

**P2 - Medium Value:**
- bd-258: `query` saved queries
- bd-2oo: Issue model fields (consolidated)
- bd-3k1: CSV output format
- bd-1px: `--overdue` filter
- bd-nks: Audit command (consolidated)

**P3 - Lower Value:**
- bd-274: `upgrade` command
- bd-1ec: `where` command
- bd-1y3: Dependency enhancements (consolidated)
- bd-16g: `--stats` token savings
