# beads_zig

A local-first issue tracker for git repositories -- an aligned Zig port of [beads_rust](https://github.com/Dicklesworthstone/beads_rust).

> **Status**: Drop-in replacement for `br`. Same commands, same arguments, same outputs. SQLite storage with bundled amalgamation.

## Overview

beads_zig (`bz`) is a command-line issue tracker that lives in your git repository. No accounts, no internet required. Your issues stay with your code.

`bz` is designed to be fully command-compatible with `br` (beads_rust) -- same CLI interface, same SQLite schema, same JSONL sync format. You can switch between them seamlessly.

```
.beads/
  beads.db        # SQLite database (primary storage, gitignored)
  issues.jsonl    # Git-tracked JSONL export (for sync/collaboration)
  config.yaml     # Project configuration
```

## Features

- **br-compatible**: Drop-in replacement for beads_rust -- identical CLI and schema
- **SQLite storage**: Bundled SQLite 3.49.1 amalgamation, WAL mode, FTS5 full-text search
- **Local-first**: All data lives in `.beads/` within your repo
- **Offline**: Works without internet connectivity
- **Git-friendly**: JSONL sync export for clean version control diffs
- **Cross-platform**: Compiles to Linux, macOS, Windows, ARM64
- **Non-invasive**: Never modifies source code or runs git commands automatically
- **Agent-first**: Machine-readable JSON/TOON output for AI tooling integration
- **Concurrent-safe**: SQLite WAL mode handles parallel reads and writes

### Issue Management

- Priority levels (0=critical through 4=backlog)
- Status tracking (open, in_progress, blocked, deferred, closed, tombstone)
- Dependency tracking with automatic cycle detection
- Labels and type classification (bug/feature/task/epic/chore/docs/question)
- Assignees and owners
- Deferral with date-based scheduling
- Full audit trail (history command)

## Dependencies

- **[rich_zig](https://github.com/hotschmoe-zig/rich_zig)** - Terminal formatting (colors, TTY detection)
- **[toon_zig](https://github.com/hotschmoe-zig/toon_zig)** - LLM-optimized output format
- **SQLite** 3.49.1 - Bundled amalgamation (vendor/sqlite3.c), no system install needed

## Installation

### Download Pre-built Binary

Download the latest release for your platform from [GitHub Releases](https://github.com/hotschmoe/beads_zig/releases).

**Linux (x86_64)**:
```bash
curl -L https://github.com/hotschmoe/beads_zig/releases/latest/download/bz-linux-x86_64 -o bz
chmod +x bz
sudo mv bz /usr/local/bin/
```

**Linux (ARM64)**:
```bash
curl -L https://github.com/hotschmoe/beads_zig/releases/latest/download/bz-linux-aarch64 -o bz
chmod +x bz
sudo mv bz /usr/local/bin/
```

**macOS (Apple Silicon)**:
```bash
curl -L https://github.com/hotschmoe/beads_zig/releases/latest/download/bz-macos-aarch64 -o bz
chmod +x bz
sudo mv bz /usr/local/bin/
```

**macOS (Intel)**:
```bash
curl -L https://github.com/hotschmoe/beads_zig/releases/latest/download/bz-macos-x86_64 -o bz
chmod +x bz
sudo mv bz /usr/local/bin/
```

**Windows (x86_64)**:
```powershell
# Download bz.exe from releases page and add to PATH
# Or using PowerShell:
Invoke-WebRequest -Uri "https://github.com/hotschmoe/beads_zig/releases/latest/download/bz-windows-x86_64.exe" -OutFile "bz.exe"
# Move to a directory in your PATH, e.g.:
Move-Item bz.exe C:\Windows\System32\
```

### Build from Source

Requires Zig 0.15.2 or later. See [Building](#building) below.

## Building

Requires Zig 0.15.2 or later.

```bash
# Setup vendor (downloads SQLite amalgamation, first time only)
./scripts/setup-vendor.sh

# Build (bundles SQLite by default)
zig build

# Run
zig build run

# Run with arguments
zig build run -- <args>

# Run tests
zig build test

# Use system SQLite instead of bundled
zig build -Dsystem-sqlite=true

# Cross-compile (SQLite bundled via Zig's C cross-compiler)
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
  root.zig           # Library exports + test runner
  cli/               # Command implementation files
    args.zig         # Argument parsing (34 commands + subcommands)
    common.zig       # CommandContext (SQLite DB + stores)
  storage/
    sqlite.zig      # SQLite C bindings wrapper
    schema.zig      # Database schema (11 tables, 29+ indexes, FTS5)
    issues.zig      # Issue CRUD via SQLite
    dependencies.zig # Dependency management via SQLite
    events.zig      # Event/audit trail via SQLite
    labels.zig      # Label management via SQLite
    comments.zig    # Comment management via SQLite
    jsonl.zig       # JSONL file I/O (for sync export/import)
  models/            # Data structures (Issue, Status, Priority, etc.)
  id/                # Hash-based ID generation (base36)
  config/            # YAML configuration
  output/            # Formatting (plain, rich, json, toon, quiet)
  errors.zig         # Structured error handling
```

**Storage** (SQLite with WAL mode):
```
.beads/
  beads.db          # SQLite database (primary storage, gitignored)
  beads.db-wal      # SQLite WAL (auto-managed, gitignored)
  issues.jsonl      # Git-tracked JSONL export (for sync/collaboration)
  config.yaml       # Project configuration
```

- **Writes**: SQLite INSERT/UPDATE with WAL mode (~1ms, auto-persisted)
- **Reads**: SQLite SELECT (no replay needed, WAL mode handles concurrency)
- **Sync**: `bz sync --flush` exports DB -> JSONL; `bz sync --import` imports JSONL -> DB
- **Schema**: 11 tables matching br exactly, 29+ indexes, FTS5 full-text search

**Design principles**:
- Explicit over implicit (no background daemons)
- User-triggered operations only
- Rich terminal output with TTY detection
- Hash-based IDs prevent merge conflicts
- SQLite schema identical to br for cross-compatibility

## Performance

Both `bz` and `br` now use SQLite with WAL mode, so performance characteristics are comparable. Zig's advantage is in startup time (no runtime, static binary) and cross-compilation.

## Global Options

```
--json              Machine-readable JSON output
--toon              LLM-optimized TOON format
-q, --quiet         Suppress non-essential output
-v, --verbose       Increase verbosity (-vv for debug)
--no-color          Disable ANSI colors (respects NO_COLOR env)
--data <path>       Override .beads/ directory
--actor <name>      Set actor for audit trail
--lock-timeout <ms> SQLite busy timeout (default 5000)
--no-auto-flush     Skip automatic JSONL export after writes
--no-auto-import    Skip automatic JSONL import on reads
```

## Why Zig?

- Single static binary (SQLite bundled as C amalgamation)
- Compiles to native code for all major platforms
- Cross-compilation works out of the box (Zig bundles a C cross-compiler)
- Memory safety without garbage collection
- Fast compilation

## Inspiration

- Original [beads](https://github.com/steveyegge/beads) by Steve Yegge
- [beads_rust](https://github.com/Dicklesworthstone/beads_rust) by Jeffrey Emanuel

## License

MIT License - see [LICENSE](LICENSE)
