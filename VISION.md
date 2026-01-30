# VISION.md - beads_zig

## One-Line Summary

**beads_zig is a local-first, offline-capable issue tracker that lives in your git repository.**

---

## The Problem

Traditional issue trackers are:

1. **External** - Require internet, accounts, and synchronization
2. **Disconnected from code** - Issues live in a separate system from the code they describe
3. **Agent-hostile** - No machine-readable output, no dependency tracking for automated tooling
4. **Merge-unfriendly** - Sequential IDs cause conflicts when multiple contributors create issues

---

## The Solution

Issues live in `.beads/` within your repository:

```
.beads/
  beads.jsonl   # Main storage - git-friendly diffs (tracked)
  beads.wal     # Write-ahead log for concurrent writes (gitignored)
  beads.lock    # Lock file for process coordination (gitignored)
```

**Git is the infrastructure.** No servers, no accounts, no external dependencies. Issues travel with your code through normal push/pull operations.

---

## Core Principles

### 1. Local-First, Offline-Capable

All data lives on your machine. No internet required. No accounts. No synchronization with external services. Your issues are always accessible.

### 2. Git-Native Collaboration

JSONL format (one JSON object per line) enables:
- Clean diffs in pull requests
- Three-way merges that git understands
- Branching and merging of issue state alongside code

### 3. Hash-Based Collision Prevention

Issue IDs like `bd-a3f8` are derived from random data, not sequential counters. Multiple contributors can create issues on different branches without ID conflicts.

### 4. Agent-First Design

Every command supports `--json` output. Structured data for AI coding assistants, scripts, and tooling. The `ready` command returns actionable work with no blocked dependencies.

### 5. Explicit Over Implicit

- No background daemons
- No automatic git commits
- No surprise modifications to your repository
- User-triggered operations only

### 6. Non-Invasive

beads_zig never:
- Modifies source code
- Executes git commands automatically
- Creates files outside `.beads/`
- Requires changes to your workflow

---

## What beads_zig Is

- A CLI tool (`bz`) for managing local issues
- A library that can be imported by other Zig projects
- A companion to AI coding assistants needing persistent task tracking
- A lightweight alternative to external issue trackers

## What beads_zig Is Not

- A replacement for GitHub Issues, Jira, or Linear (though it can coexist)
- A project management tool with roadmaps and sprints
- A synchronization service
- A collaboration platform (git handles collaboration)

---

## Target Users

1. **Solo developers** wanting lightweight issue tracking without external services
2. **AI coding assistants** needing structured task memory across sessions
3. **Open source maintainers** wanting issues that travel with forks
4. **Teams** preferring code-adjacent issue tracking with git-based workflows
5. **Offline workers** who need issue tracking without internet

---

## Why Zig?

- **Single static binary** - No runtime dependencies, drop into any system
- **Small footprint** - Target: ~12KB release (vs 5-8MB for Rust version with SQLite)
- **Fast compilation** - Seconds, not minutes
- **No C dependencies** - Pure Zig storage layer (no SQLite, no libc on many targets)
- **Memory safety** - Explicit allocation without garbage collection
- **Cross-platform** - Compile for any target from any host
- **Native concurrency** - Leverage kernel-managed flock for concurrent agent access

---

## Success Criteria

beads_zig succeeds when:

1. Users can track issues without leaving their terminal
2. Issues merge cleanly alongside code changes
3. AI agents can query and update issues programmatically
4. The tool remains invisible until needed
5. Data is never lost, always recoverable

---

## Acknowledgments

- **[beads](https://github.com/steveyegge/beads)** by Steve Yegge - Original vision
- **[beads_rust](https://github.com/Dicklesworthstone/beads_rust)** by Jeffrey Emanuel - Reference implementation
