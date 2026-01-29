# beads_zig

A Zig port of [beads_rust](https://github.com/Dicklesworthstone/beads_rust) - a local-first issue tracker for git repositories.

> **Status**: Development blocked pending completion of [rich_zig](https://github.com/hotschmoe-zig/rich_zig) (terminal formatting library).

## Overview

beads_zig is a command-line issue tracker that lives in your git repository. No accounts, no internet required, no external dependencies. Your issues stay with your code.

```
.beads/
  beads.db      # SQLite for fast local queries
  issues.jsonl  # JSONL export for git-friendly diffs
```

## Features

- **Local-first**: All data lives in `.beads/` within your repo
- **Offline**: Works without internet connectivity
- **Git-friendly**: JSONL format for clean version control diffs
- **Non-invasive**: Never modifies source code or runs git commands automatically
- **Agent-first**: Machine-readable JSON output for AI tooling integration

### Issue Management

- Priority levels (0=critical through 4=backlog)
- Status tracking (open, in_progress, deferred, closed)
- Dependency tracking between issues
- Labels and type classification (bug/feature/task)
- Assignees

## Dependencies

- **[rich_zig](https://github.com/hotschmoe-zig/rich_zig)** - Terminal formatting (colors, tables, TTY detection)
- **SQLite** - System library or bundled

## Building

Requires Zig 0.15.2 or later.

```bash
# Build (links system SQLite)
zig build

# Build with bundled SQLite
zig build -Dbundle-sqlite=true

# Run
zig build run

# Run with arguments
zig build run -- <args>

# Run tests
zig build test

# Format source
zig build fmt
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
  main.zig    # CLI entry point and argument parsing
  root.zig    # Core library (can be imported by other Zig projects)
```

**Storage**:
- SQLite database for fast indexed queries
- JSONL export for git collaboration (explicit sync, no auto-commits)

**Design principles**:
- Explicit over implicit (no background daemons)
- User-triggered operations only
- Rich terminal output with TTY detection

## Why Zig?

- Single static binary with no runtime dependencies
- Compiles to native code for all major platforms
- C interop for SQLite without FFI overhead
- Memory safety without garbage collection

## License

MIT License - see [LICENSE](LICENSE)

## Acknowledgments

- Original [beads](https://github.com/steveyegge/beads) by Steve Yegge
- [beads_rust](https://github.com/Dicklesworthstone/beads_rust) by Jeffrey Emanuel
