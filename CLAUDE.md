<!-- BEGIN:header -->
# CLAUDE.md

we love you, Claude! do your best today
<!-- END:header -->

<!-- BEGIN:rule-1-no-delete -->
## RULE 1 - NO DELETIONS (ARCHIVE INSTEAD)

You may NOT delete any file or directory. Instead, move deprecated files to `.archive/`.

**When you identify files that should be removed:**
1. Create `.archive/` directory if it doesn't exist
2. Move the file: `mv path/to/file .archive/`
3. Notify me: "Moved `path/to/file` to `.archive/` - deprecated because [reason]"

**Rules:**
- This applies to ALL files, including ones you just created (tests, tmp files, scripts, etc.)
- You do not get to decide that something is "safe" to delete
- The `.archive/` directory is gitignored - I will review and permanently delete when ready
- If `.archive/` doesn't exist and you can't create it, ask me before proceeding

**Only I can run actual delete commands** (`rm`, `git clean`, etc.) after reviewing `.archive/`.
<!-- END:rule-1-no-delete -->

<!-- BEGIN:irreversible-actions -->
### IRREVERSIBLE GIT & FILESYSTEM ACTIONS

Absolutely forbidden unless I give the **exact command and explicit approval** in the same message:

- `git reset --hard`
- `git clean -fd`
- `rm -rf`
- Any command that can delete or overwrite code/data

Rules:

1. If you are not 100% sure what a command will delete, do not propose or run it. Ask first.
2. Prefer safe tools: `git status`, `git diff`, `git stash`, copying to backups, etc.
3. After approval, restate the command verbatim, list what it will affect, and wait for confirmation.
4. When a destructive command is run, record in your response:
   - The exact user text authorizing it
   - The command run
   - When you ran it

If that audit trail is missing, then you must act as if the operation never happened.
<!-- END:irreversible-actions -->

<!-- BEGIN:code-discipline -->
### Code Editing Discipline

- Do **not** run scripts that bulk-modify code (codemods, invented one-off scripts, giant `sed`/regex refactors).
- Large mechanical changes: break into smaller, explicit edits and review diffs.
- Subtle/complex changes: edit by hand, file-by-file, with careful reasoning.
- **NO EMOJIS** - do not use emojis or non-textual characters.
- ASCII diagrams are encouraged for visualizing flows.
- Keep in-line comments to a minimum. Use external documentation for complex logic.
- In-line commentary should be value-add, concise, and focused on info not easily gleaned from the code.
<!-- END:code-discipline -->

<!-- BEGIN:no-legacy -->
### No Legacy Code - Full Migrations Only

We optimize for clean architecture, not backwards compatibility. **When we refactor, we fully migrate.**

- No "compat shims", "v2" file clones, or deprecation wrappers
- When changing behavior, migrate ALL callers and remove old code **in the same commit**
- No `_legacy` suffixes, no `_old` prefixes, no "will remove later" comments
- New files are only for genuinely new domains that don't fit existing modules
- The bar for adding files is very high

**Rationale**: Legacy compatibility code creates technical debt that compounds. A clean break is always better than a gradual migration that never completes.
<!-- END:no-legacy -->

<!-- BEGIN:dev-philosophy -->
## Development Philosophy

**Make it work, make it right, make it fast** - in that order.

**This codebase will outlive you** - every shortcut becomes someone else's burden. Patterns you establish will be copied. Corners you cut will be cut again.

**Fight entropy** - leave the codebase better than you found it.

**Inspiration vs. Recreation** - take the opportunity to explore unconventional or new ways to accomplish tasks. Do not be afraid to challenge assumptions or propose new ideas. BUT we also do not want to reinvent the wheel for the sake of it. If there is a well-established pattern or library take inspiration from it and make it your own. (or suggest it for inclusion in the codebase)
<!-- END:dev-philosophy -->

<!-- BEGIN:testing-philosophy -->
## Testing Philosophy: Diagnostics, Not Verdicts

**Tests are diagnostic tools, not success criteria.** A passing test suite does not mean the code is good. A failing test does not mean the code is wrong.

**When a test fails, ask three questions in order:**
1. Is the test itself correct and valuable?
2. Does the test align with our current design vision?
3. Is the code actually broken?

Only if all three answers are "yes" should you fix the code.

**Why this matters:**
- Tests encode assumptions. Assumptions can be wrong or outdated.
- Changing code to pass a bad test makes the codebase worse, not better.
- Evolving projects explore new territory - legacy testing assumptions don't always apply.

**What tests ARE good for:**
- **Regression detection**: Did a refactor break dependent modules? Did API changes break integrations?
- **Sanity checks**: Does initialization complete? Do core operations succeed? Does the happy path work?
- **Behavior documentation**: Tests show what the code currently does, not necessarily what it should do.

**What tests are NOT:**
- A definition of correctness
- A measure of code quality
- Something to "make pass" at all costs
- A specification to code against

**The real success metric**: Does the code further our project's vision and goals?

### Running Tests Safely

**Use `zig test` directly** (not `zig build test`):

```bash
# Run all tests (recommended)
zig test src/root.zig

# Run specific module tests
zig test src/storage/store.zig
zig test src/models/issue.zig
```

**Why not `zig build test`?**

The build system test runner hangs after all tests pass due to a Zig 0.15.x issue. All 344 tests complete successfully, but the process never exits. This is a build system issue, not a code problem - the production binary works fine.

If you must use `zig build test`, use a timeout:
```bash
timeout 60 zig build test 2>&1
```

If tests hang, kill with: `pkill -9 -f "zig.*test"` (Linux/macOS) or Task Manager (Windows).

**Manual CLI testing** is preferred for CLI commands - test in `sandbox/` directory.
<!-- END:testing-philosophy -->

<!-- BEGIN:footer -->
---

we love you, Claude! do your best today
<!-- END:footer -->


---

## Project-Specific Content

### beads_zig Architecture Overview

**beads_zig is a Zig port of beads_rust with key architectural differences:**

1. **No SQLite** - Pure Zig storage layer with JSONL + WAL
2. **Lock + WAL + Compact** - Custom concurrent write handling
3. **No C dependencies** - Single static binary (~12KB)

### Storage Layer

```
.beads/
  beads.jsonl   # Main file (compacted state, git-tracked)
  beads.wal     # Write-ahead log (gitignored)
  beads.lock    # flock target (gitignored)
```

**Write path**: `flock(LOCK_EX) -> append WAL -> fsync -> flock(LOCK_UN)` (~1ms)
**Read path**: `load main + replay WAL` (no lock)
**Compaction**: Merge WAL into main when threshold exceeded

### Key Differences from beads_rust

| Aspect | beads_rust | beads_zig |
|--------|------------|-----------|
| Storage | SQLite + WAL mode | JSONL + custom WAL |
| Concurrency | SQLite locking (contention under load) | flock + append-only WAL |
| Dependencies | SQLite C library | None (pure Zig) |
| Binary size | ~5-8MB | ~12KB |
| Lock behavior | SQLITE_BUSY retry storms | Blocking flock (no spinning) |

### Why This Matters for Agents

When 5+ agents write simultaneously:
- SQLite: Retry storms, exponential backoff, potential timeouts
- beads_zig: Sequential flock acquisition, ~1ms per write, no retries

### Build and Test

```bash
zig build                  # Build
zig build run              # Run CLI
zig test src/root.zig      # Run tests (recommended)

# Cross-compile
zig build -Dtarget=aarch64-linux-gnu
zig build -Dtarget=x86_64-windows-gnu
```

### Sandbox Testing

Always test in `sandbox/` directory, not project root:

```bash
cd sandbox
../zig-out/bin/bz init
../zig-out/bin/bz add "Test issue"
```

The project root may have a `.beads/` for beads_rust tracking.

