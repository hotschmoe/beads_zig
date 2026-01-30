# beads_zig

A Zig port of [beads_rust](https://github.com/Dicklesworthstone/beads_rust) - a local-first issue tracker for git repositories.

> **Status**: Development blocked pending completion of [rich_zig](https://github.com/hotschmoe-zig/rich_zig) (terminal formatting library).

## Overview

beads_zig is a command-line issue tracker that lives in your git repository. No accounts, no internet required, no external dependencies. Your issues stay with your code.

```
.beads/
  beads.jsonl   # Main storage - git-friendly, human-readable
  beads.wal     # Write-ahead log for concurrent writes
  beads.lock    # Lock file for process coordination
  config.yaml   # Project configuration
```

## Features

- **Pure Zig**: No C dependencies, single static binary (~12KB release)
- **Local-first**: All data lives in `.beads/` within your repo
- **Offline**: Works without internet connectivity
- **Git-friendly**: JSONL format for clean version control diffs
- **Cross-platform**: Compiles to Linux, macOS, Windows, ARM64
- **Non-invasive**: Never modifies source code or runs git commands automatically
- **Agent-first**: Machine-readable JSON output for AI tooling integration
- **Concurrent-safe**: Lock + WAL architecture handles parallel agent writes without contention

### Issue Management

- Priority levels (0=critical through 4=backlog)
- Status tracking (open, in_progress, deferred, closed)
- Dependency tracking between issues with cycle detection
- Labels and type classification (bug/feature/task)
- Assignees

## Dependencies

- **[rich_zig](https://github.com/hotschmoe-zig/rich_zig)** - Terminal formatting (colors, tables, TTY detection) - optional

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

# Run tests (recommended)
zig test src/root.zig

# Alternative (may hang on some platforms due to Zig build system issue)
# zig build test

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
beads_zig init

# Create an issue
beads_zig add "Fix login bug" --type bug --priority 1

# List issues
beads_zig list

# Show issue details
beads_zig show <id>

# Update issue status
beads_zig update <id> --status in_progress

# JSON output for scripting/AI agents
beads_zig list --json
```

## Architecture

```
src/
  main.zig           # CLI entry point
  root.zig           # Library exports
  storage/
    jsonl.zig        # JSONL file I/O (atomic writes)
    store.zig        # In-memory IssueStore with indexing
    graph.zig        # Dependency graph with cycle detection
    lock.zig         # flock-based concurrent write locking
    wal.zig          # Write-ahead log operations
    compact.zig      # WAL compaction into main file
  models/            # Data structures (Issue, Status, Priority, etc.)
  cli/               # Command implementations
```

**Storage** (Lock + WAL + Compact):
```
.beads/
  beads.jsonl       # Main file (compacted state, git-tracked)
  beads.wal         # Write-ahead log (recent writes)
  beads.lock        # Lock file for flock
```

- **Writes**: Acquire flock -> append to WAL -> release (~1ms)
- **Reads**: Load main + replay WAL in memory (lock-free)
- **Compaction**: Merge WAL into main when threshold exceeded
- Crash-safe: flock auto-releases, atomic file operations
- beads_rust JSONL import compatible

**Design principles**:
- Explicit over implicit (no background daemons)
- User-triggered operations only
- Rich terminal output with TTY detection

## Why Zig?

- Single static binary with no runtime dependencies
- Compiles to native code for all major platforms
- No C dependencies - pure Zig implementation
- Memory safety without garbage collection
- Fast compilation (~2-5s debug builds)

## License

MIT License - see [LICENSE](LICENSE)

## Acknowledgments

- Original [beads](https://github.com/steveyegge/beads) by Steve Yegge
- [beads_rust](https://github.com/Dicklesworthstone/beads_rust) by Jeffrey Emanuel
