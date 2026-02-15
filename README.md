# bz -- Local-First Issue Tracker

A command-line issue tracker that lives in your git repository. No accounts, no internet, no setup beyond `bz init`.

```bash
bz init                              # Initialize in your repo
bz create "Fix login timeout" -p 1   # Create high-priority issue
bz ready                             # See what's actionable
bz close bd-abc123                   # Close when done
```

## Why bz?

| Feature | bz | GitHub Issues | Jira | TODO comments |
|---------|-----|---------------|------|---------------|
| Works offline | **Yes** | No | No | Yes |
| Lives in repo | **Yes** | No | No | Yes |
| Tracks dependencies | **Yes** | Limited | Yes | No |
| Zero cost | **Yes** | Free tier | No | Yes |
| No account required | **Yes** | No | No | Yes |
| Machine-readable | **Yes** (`--json`) | API only | API only | No |
| Git-friendly sync | **Yes** (JSONL) | N/A | N/A | N/A |
| Non-invasive | **Yes** | N/A | N/A | Yes |
| AI agent integration | **Yes** | Limited | Limited | No |
| Single static binary | **Yes** | N/A | N/A | N/A |

## Features

- **SQLite storage**: WAL mode, FTS5 full-text search, 11 tables, 29+ indexes
- **Local-first**: All data lives in `.beads/` within your repo
- **Offline**: Works without internet connectivity
- **Git-friendly**: JSONL sync export for clean version control diffs
- **Cross-platform**: Compiles to Linux, macOS, Windows, ARM64
- **Non-invasive**: Never modifies source code or runs git commands automatically
- **Agent-first**: Machine-readable JSON/TOON output for AI tooling integration
- **Concurrent-safe**: SQLite WAL mode handles parallel reads and writes
- **Self-updating**: Built-in `bz upgrade` pulls latest release from GitHub
- **br-compatible**: Same 38 commands and SQLite schema as [beads_rust](https://github.com/Dicklesworthstone/beads_rust)

### Issue Management

- Priority levels (0=critical through 4=backlog)
- Status tracking (open, in_progress, blocked, deferred, closed, tombstone)
- Dependency tracking with automatic cycle detection
- Labels and type classification (bug/feature/task/epic/chore/docs/question)
- Assignees and owners
- Deferral with date-based scheduling
- Full audit trail (history command)

## Installation

### Quick Install (Recommended)

**Linux / macOS:**

```bash
curl -fsSL https://raw.githubusercontent.com/hotschmoe/beads_zig/master/install.sh | bash
```

**Windows (PowerShell):**

```powershell
irm https://raw.githubusercontent.com/hotschmoe/beads_zig/master/install.ps1 | iex
```

Both installers auto-detect your platform, download the right binary, verify checksums,
and configure PATH. Options:

```bash
# Linux/macOS options
curl -fsSL .../install.sh | bash -s -- --easy-mode     # Auto-configure PATH
curl -fsSL .../install.sh | sudo bash -s -- --system   # Install to /usr/local/bin
curl -fsSL .../install.sh | bash -s -- --version v0.1.7
curl -fsSL .../install.sh | bash -s -- --verify
curl -fsSL .../install.sh | bash -s -- --uninstall
```

```powershell
# Windows options (save script first, then run with params)
.\install.ps1 -Version v0.1.7
.\install.ps1 -Verify
.\install.ps1 -NoPath           # Skip PATH configuration
.\install.ps1 -Uninstall
```

### Download Pre-built Binary

Download the latest release for your platform from [GitHub Releases](https://github.com/hotschmoe/beads_zig/releases).

**Linux (x86_64)**:
```bash
curl -fsSL https://github.com/hotschmoe/beads_zig/releases/latest/download/bz-linux-x86_64 -o bz
chmod +x bz
sudo mv bz /usr/local/bin/
```

**Linux (ARM64)**:
```bash
curl -fsSL https://github.com/hotschmoe/beads_zig/releases/latest/download/bz-linux-aarch64 -o bz
chmod +x bz
sudo mv bz /usr/local/bin/
```

**macOS (Apple Silicon)**:
```bash
curl -fsSL https://github.com/hotschmoe/beads_zig/releases/latest/download/bz-macos-aarch64 -o bz
chmod +x bz
sudo mv bz /usr/local/bin/
```

**macOS (Intel)**:
```bash
curl -fsSL https://github.com/hotschmoe/beads_zig/releases/latest/download/bz-macos-x86_64 -o bz
chmod +x bz
sudo mv bz /usr/local/bin/
```

**Windows (x86_64)**:
```powershell
# Recommended: use the installer (see Quick Install above)
# Manual download:
Invoke-WebRequest -Uri "https://github.com/hotschmoe/beads_zig/releases/latest/download/bz-windows-x86_64.exe" -OutFile "bz.exe"
# Move to a directory in your PATH, e.g.:
Move-Item bz.exe "$env:LOCALAPPDATA\bz\"
```

### Build from Source

Requires Zig 0.15.2 or later. SQLite is provided automatically via the zqlite package dependency -- no vendor setup or system install needed.

```bash
git clone https://github.com/hotschmoe/beads_zig.git
cd beads_zig
zig build
sudo cp zig-out/bin/bz /usr/local/bin/
```

```bash
# Run directly without installing
zig build run -- <args>

# Run tests (633 tests)
zig build test

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
bz defer <id> --until 2026-03-15
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

**Workspace**: `init`, `info`, `stats`, `doctor`, `config`, `where`

**Issue CRUD**: `create` (add, new), `q` (quick), `show` (get, view), `update` (edit), `close` (done), `reopen`, `delete` (rm)

**Queries**: `list` (ls), `ready`, `blocked`, `search` (find), `stale`, `count`

**Dependencies**: `dep add`, `dep remove`, `dep list`, `dep tree`, `dep cycles`, `graph`

**Labels**: `label add`, `label remove`, `label list`, `label list-all`

**Comments**: `comments add`, `comments list`

**Scheduling**: `defer`, `undefer`

**Audit**: `history`, `audit`

**Sync**: `sync` (flush, export) with `--flush-only` and `--import-only`

**Advanced**: `epic`, `query`, `agents`, `upgrade`, `orphans`, `lint`, `changelog`

**System**: `version`, `schema`, `completions`, `help`

## Updating

bz has a built-in self-update command that downloads the latest release from GitHub:

```bash
# Check if an update is available
bz upgrade --check

# Upgrade to latest version
bz upgrade

# Upgrade to a specific version
bz upgrade --version 0.2.0

# Preview what would happen without installing
bz upgrade --dry-run

# Force reinstall current version
bz upgrade --force

# Skip checksum verification (not recommended)
bz upgrade --no-verify
```

New releases are automatically built for all platforms when changes are merged to master.
The upgrade replaces the running binary in-place (atomic rename). On permission errors,
try running with `sudo` or move `bz` to a user-writable directory like `~/.local/bin/`.

You can also re-run the installer to update:

```bash
# Linux/macOS
curl -fsSL https://raw.githubusercontent.com/hotschmoe/beads_zig/master/install.sh | bash

# Windows
irm https://raw.githubusercontent.com/hotschmoe/beads_zig/master/install.ps1 | iex
```

## Uninstalling

### Via installer

```bash
# Linux/macOS
curl -fsSL https://raw.githubusercontent.com/hotschmoe/beads_zig/master/install.sh | bash -s -- --uninstall
```

```powershell
# Windows
.\install.ps1 -Uninstall
# Or if you didn't save the script:
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/hotschmoe/beads_zig/master/install.ps1))) -Uninstall
```

This removes the `bz` binary and cleans up PATH modifications.

### If installed manually

Remove the binary from wherever you placed it:

```bash
# Linux/macOS
sudo rm /usr/local/bin/bz          # System install
rm ~/.local/bin/bz                  # User install
```

```powershell
# Windows
Remove-Item "$env:LOCALAPPDATA\bz\bz.exe"
```

### Cleaning up project data

bz stores all data in `.beads/` within each project where you ran `bz init`.
To remove bz from a project:

```bash
rm -rf .beads/
```

No global state, config files, or background processes to clean up.

## Parity Status

bz aims to match br's CLI interface and output. Current state:

**633/633 unit tests pass, 30/30 conformance tests pass.**

### Full parity (output matches br)

create, list, show, update, close, reopen, delete, q, search, count,
dep (add/remove/list/tree/cycles), label (add/remove/list/list-all),
comments (add/list), defer, undefer, doctor (text), ready (JSON), blocked (JSON)

### Partial parity (functional but output differs from br)

| Command | Difference |
|---------|-----------|
| `stats` | Missing padding alignment and "Recent Activity" section; JSON schema differs |
| `info` | Missing daemon detail indentation; JSON missing fields (mode, jsonl_path) |
| `version` | Multi-line format (bz/zig/platform) vs br's single-line format |
| `where` | Shows 1 line (path) vs br's 3 lines (path, prefix, database) |
| `ready` | Uses list format vs br's numbered format |
| `blocked` | Plain text vs br's header format |
| `stale` | Different empty-state message |
| `init` | Prints 4 lines vs br's 1 line |

### Different behavior (same command name, different semantics)

| Command | br behavior | bz behavior |
|---------|-------------|-------------|
| `history` | Backup management (list/diff/restore/prune) | Per-issue event viewer |
| `schema` | JSON Schema (draft-07) for output types | Markdown storage format description |
| `lint` | Template section checker | Database consistency checker |
| `audit` | Agent interaction recorder (subcommands) | Event log dump |
| `config` | Requires subcommand (list/get/set/delete) | Dumps config directly |

### Known gaps

- `--file` flag in create is a stub (prints "not yet implemented")
- `doctor --json` missing details objects (schema.tables, jsonl.parse)
- `history` has different semantics (event viewer vs backup manager)
- Some minor field naming differences in JSON output

## Architecture

```
src/
  main.zig           # CLI entry point + dispatch
  root.zig           # Library exports + test runner
  cli/               # Command implementation files (38 commands)
    args.zig         # Argument parsing
    common.zig       # CommandContext (SQLite DB + stores)
  storage/
    sqlite.zig      # SQLite C bindings wrapper (via zqlite)
    schema.zig      # Database schema (11 tables, 29+ indexes, FTS5)
    issues.zig      # Issue CRUD + labels + comments via SQLite
    dependencies.zig # Dependency management via SQLite
    events.zig      # Event/audit trail via SQLite
    jsonl.zig       # JSONL file I/O (for sync export/import)
    mod.zig         # Storage module re-exports
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
- **Auto-flush**: Mutations automatically flush to JSONL (disable with `--no-auto-flush`)
- **Schema**: 11 tables matching br exactly, 29+ indexes, FTS5 full-text search

**Design principles**:
- Explicit over implicit (no background daemons)
- User-triggered operations only
- Rich terminal output with TTY detection
- Hash-based IDs prevent merge conflicts
- SQLite schema identical to br for cross-compatibility

## Global Options

```
--json              Machine-readable JSON output
--toon              LLM-optimized TOON format
-q, --quiet         Suppress non-essential output
-v, --verbose       Increase verbosity
--no-color          Disable ANSI colors (respects NO_COLOR env)
--data <path>       Override .beads/ directory
--no-auto-flush     Disable automatic JSONL flush after mutations
--actor <name>      Set actor name for audit trail
```

## Dependencies

- **[rich_zig](https://github.com/hotschmoe/rich_zig)** - Terminal formatting (colors, TTY detection)
- **[toon_zig](https://github.com/hotschmoe/toon_zig)** - LLM-optimized output format
- **[zqlite](https://github.com/hotschmoe/zqlite)** - SQLite package (bundles amalgamation + FTS5/JSON1 flags)

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
