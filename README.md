# beads_zig

A local-first issue tracker for git repositories, written in pure Zig.

> **Status**: Feature-complete CLI with 34 commands. Production-ready.

## Overview

beads_zig (`bz`) is a command-line issue tracker that lives in your git repository. No accounts, no internet required, no external dependencies. Your issues stay with your code.

```
.beads/
  issues.jsonl    # Main storage - git-friendly, human-readable
  issues.wal      # Write-ahead log for concurrent writes
  .beads.lock     # Lock file for process coordination
  config.yaml     # Project configuration
```

## Features

- **Pure Zig**: No C dependencies, single static binary
- **Local-first**: All data lives in `.beads/` within your repo
- **Offline**: Works without internet connectivity
- **Git-friendly**: JSONL format for clean version control diffs
- **Cross-platform**: Compiles to Linux, macOS, Windows, ARM64
- **Non-invasive**: Never modifies source code or runs git commands automatically
- **Agent-first**: Machine-readable JSON/TOON output for AI tooling integration
- **Concurrent-safe**: Lock + WAL architecture handles parallel agent writes without contention

### Issue Management

- Priority levels (0=critical through 4=backlog)
- Status tracking (open, in_progress, blocked, deferred, closed, tombstone)
- Dependency tracking with automatic cycle detection
- Labels and type classification (bug/feature/task/epic/chore/docs/question)
- Assignees and owners
- Deferral with date-based scheduling
- Full audit trail (history command)

## Dependencies

- **[rich_zig](https://github.com/hotschmoe-zig/rich_zig)** v1.1.1 - Terminal formatting (colors, TTY detection)
- **[toon_zig](https://github.com/hotschmoe-zig/toon_zig)** v0.1.5 - LLM-optimized output format

No C dependencies. No SQLite. Pure Zig.

## Building

Requires Zig 0.15.2 or later.

```bash
# Build
zig build

# Run
zig build run

# Run with arguments
zig build run -- <args>

# Run tests
zig test src/root.zig

# Format source
zig build fmt

# Cross-compile
zig build -Dtarget=aarch64-linux-gnu      # Linux ARM64
zig build -Dtarget=x86_64-windows-gnu     # Windows
zig build -Dtarget=aarch64-macos          # macOS Apple Silicon
```

## Usage

```bash
# Initialize beads in current repo
bz init

# Create an issue
bz create "Fix login bug" --type bug --priority 1

# Quick capture (print ID only)
bz q "Todo item"

# List issues
bz list
bz list --status open --priority 1

# Show issue details
bz show <id>

# Update issue
bz update <id> --status in_progress --assignee alice

# Close/reopen
bz close <id> --reason "Fixed in commit abc123"
bz reopen <id>

# Dependencies
bz dep add <child-id> <blocker-id>
bz dep list <id>
bz ready          # Show unblocked issues
bz blocked        # Show blocked issues

# Labels
bz label add <id> urgent backend
bz label list <id>

# Comments
bz comments add <id> "Investigation notes..."
bz comments list <id>

# Defer until later
bz defer <id> --until 2024-02-15
bz defer <id> --until +7d    # Relative date

# Search
bz search "login"

# Dependency graph
bz graph --format dot > deps.dot

# JSON output for scripting/AI agents
bz list --json
bz show <id> --toon    # LLM-optimized format
```

## Commands

**Workspace**: `init`, `info`, `stats`, `doctor`, `config`

**Issue CRUD**: `create` (add, new), `q` (quick), `show` (get, view), `update` (edit), `close` (done), `reopen`, `delete` (rm)

**Queries**: `list` (ls), `ready`, `blocked`, `search` (find), `stale`, `count`

**Dependencies**: `dep add`, `dep remove`, `dep list`, `dep tree`, `dep cycles`, `graph`

**Labels**: `label add`, `label remove`, `label list`, `label list-all`

**Comments**: `comments add`, `comments list`

**Scheduling**: `defer`, `undefer`

**Audit**: `history` (log), `audit`

**Sync**: `sync` (flush, export) with `--flush-only` and `--import-only`

**System**: `version`, `schema`, `completions`, `help`

## Architecture

```
src/
  main.zig           # CLI entry point
  root.zig           # Library exports
  cli/               # 26 command implementations
    args.zig         # Argument parsing (34 commands + subcommands)
    common.zig       # Shared context and output helpers
  storage/
    jsonl.zig        # JSONL file I/O (atomic writes)
    store.zig        # In-memory IssueStore with indexing
    graph.zig        # Dependency graph with cycle detection
    lock.zig         # flock-based concurrent write locking
    wal.zig          # Write-ahead log operations
    compact.zig      # WAL compaction into main file
  models/            # Data structures (Issue, Status, Priority, etc.)
  id/                # Hash-based ID generation (base36)
  config/            # YAML configuration
  output/            # Formatting (plain, rich, json, toon, quiet)
  errors.zig         # Structured error handling
```

**Storage** (Lock + WAL + Compact):
```
.beads/
  issues.jsonl      # Main file (compacted state, git-tracked)
  issues.wal        # Write-ahead log (gitignored)
  .beads.lock       # Lock file for flock (gitignored)
```

- **Writes**: Acquire flock -> append to WAL -> fsync -> release (~1ms)
- **Reads**: Load main + replay WAL in memory (lock-free)
- **Compaction**: Merge WAL into main when threshold exceeded (100 entries or 100KB)
- Crash-safe: flock auto-releases on process termination, atomic file operations

**Design principles**:
- Explicit over implicit (no background daemons)
- User-triggered operations only
- Rich terminal output with TTY detection
- Hash-based IDs prevent merge conflicts

## Global Options

```
--json              Machine-readable JSON output
--toon              LLM-optimized TOON format
-q, --quiet         Suppress non-essential output
-v, --verbose       Increase verbosity (-vv for debug)
--no-color          Disable ANSI colors (respects NO_COLOR env)
--data <path>       Override .beads/ directory
--actor <name>      Set actor for audit trail
--lock-timeout <ms> Lock timeout (default 5000)
--no-auto-flush     Skip automatic WAL flush
--no-auto-import    Skip automatic import on read
```

## Why Zig?

- Single static binary with no runtime dependencies
- Compiles to native code for all major platforms
- No C dependencies - pure Zig implementation
- Memory safety without garbage collection
- Fast compilation (~2-5s debug builds)

## Inspiration

- Original [beads](https://github.com/steveyegge/beads) by Steve Yegge
- [beads_rust](https://github.com/Dicklesworthstone/beads_rust) by Jeffrey Emanuel

## License

MIT License - see [LICENSE](LICENSE)
