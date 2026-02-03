# TESTING.md - beads_zig Testing Strategy

## Philosophy

> **Tests are diagnostic tools, not success criteria.**

A passing test suite does not mean the code is good. A failing test does not mean the code is wrong.

### When a Test Fails

Ask three questions in order:

1. **Is the test itself correct and valuable?**
2. **Does the test align with our current design vision?**
3. **Is the code actually broken?**

Only if all three answers are "yes" should you fix the code.

### Why This Matters

- Tests encode assumptions. Assumptions can be wrong or outdated.
- Changing code to pass a bad test makes the codebase worse, not better.
- Evolving projects explore new territory - legacy testing assumptions do not always apply.

---

## Test Isolation

### Manual Testing

Use the `sandbox/` directory for interactive testing:

```bash
cd sandbox
../zig-out/bin/bz init
../zig-out/bin/bz create "Test issue"
../zig-out/bin/bz list
```

**IMPORTANT**: Never run `bz` directly in the project root during development.
The project root may contain a `.beads/` directory for tracking development
with beads_rust. Running `bz` there could corrupt that data.

### Automated Tests

All filesystem tests MUST use isolated temporary directories:

```zig
test "example filesystem test" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // All operations within tmp.dir
}
```

### CI Safety

CI runs in fresh checkouts with no persistent state. Each test run starts clean.

---

## Test Categories

### Unit Tests

**Purpose**: Verify isolated behavior of individual functions and data structures.

**Characteristics**:
- No I/O (disk, network)
- No external dependencies
- Fast (<5ms per test)
- Deterministic

**Target areas**:
- Model serialization/deserialization (Issue, Dependency, Comment, Event)
- ID generation (determinism, format, collision resistance)
- Base36 encoding/decoding
- Content hashing (SHA256, field ordering, null handling)
- Status/Priority/IssueType parsing
- Argument parsing

**Location**: Inline `test` blocks in each module.

### Integration Tests

**Purpose**: Verify components work together correctly.

**Characteristics**:
- May use temporary files/databases
- Tests Lock + WAL + Compact operations
- Tests JSONL import/export roundtrips
- Moderate speed (<100ms per test)

**Target areas**:
- WAL append and replay operations
- Compaction correctness (main + WAL merge)
- JSONL export -> import roundtrip preserves data
- Dependency cycle detection
- Ready/blocked query correctness
- Dirty tracking and sync coordination
- Lock acquisition and release

**Location**: `src/tests/` directory or dedicated test modules.

### CLI Tests

**Purpose**: Verify end-to-end command behavior.

**Characteristics**:
- Spawns actual `bz` process via `std.process.Child`
- Uses temporary `.beads/` directories
- Tests argument parsing, output format, exit codes
- Slower (<1s per test)

**Target areas**:
- `bz init` creates correct directory structure
- `bz create` returns valid ID
- `bz list --json` produces valid JSON
- `bz ready` excludes blocked issues
- `bz sync` maintains data integrity
- Error messages are helpful

**Location**: `src/tests/cli_test.zig` - Integration tests that spawn the actual binary.

### Fuzz Tests (Planned)

**Purpose**: Discover edge cases through random input generation.

**Characteristics**:
- Uses Zig's built-in fuzzing (`std.testing.fuzz`)
- Time-boxed execution (CI: 60s, local: unbounded)
- Finds crashes, hangs, and assertion failures

**Target areas**:
- ID generation with random inputs
- JSONL parsing with malformed input
- WAL parsing with truncated/malformed entries
- Base36 decoding with invalid characters
- Argument parsing with adversarial input

**Location**: Inline fuzz tests or `src/tests/fuzz/` (not yet implemented).

---

## What Tests Are Good For

- **Regression detection**: Did a refactor break dependent modules? Did API changes break integrations?
- **Sanity checks**: Does initialization complete? Do core operations succeed? Does the happy path work?
- **Behavior documentation**: Tests show what the code currently does, not necessarily what it should do.

## What Tests Are Not

- A definition of correctness
- A measure of code quality
- Something to "make pass" at all costs
- A specification to code against

---

## Critical Paths (High Priority Testing)

These areas have high blast radius if they fail:

### 1. Data Integrity

- JSONL export never produces invalid JSON
- JSONL import never silently drops issues
- Content hash computation is deterministic
- WAL operations are atomic (write + fsync before lock release)
- Compaction preserves all committed data

### 2. Sync Safety

- Export does not overwrite JSONL with empty data
- Import detects and rejects merge conflict markers
- Atomic file writes prevent corruption on crash
- Dirty tracking accurately identifies modified issues

### 3. ID Generation

- IDs are unique within reasonable probability bounds
- ID format is valid (`prefix-hash`)
- Collision detection works when hash is too short
- Child IDs maintain hierarchy (`bd-abc.1.2`)

### 4. Dependency Logic

- Cycle detection prevents circular dependencies
- `ready` query correctly excludes blocked issues
- `blocked` query correctly includes only blocked issues
- Blocked cache stays synchronized with actual dependencies

### 5. Concurrent Write Safety

- Multiple processes can acquire lock sequentially without deadlock
- WAL entries are fully written before lock release
- Partial WAL reads don't corrupt state (just miss recent ops)
- Compaction preserves all committed data
- Process crash mid-write doesn't corrupt main file
- Lock auto-releases on process termination

---

## Concurrent Write Stress Testing

For testing the Lock + WAL + Compact architecture under heavy load:

### Multi-Process Stress Test

```bash
#!/bin/bash
# stress_test.sh - Spawn N agents writing simultaneously
N=${1:-5}
ITERATIONS=${2:-20}

rm -rf .beads
bz init

for i in $(seq 1 $N); do
    (
        for j in $(seq 1 $ITERATIONS); do
            bz create "Agent $i Issue $j" --priority $((j % 5)) 2>&1 | grep -i "error" &
        done
        wait
    ) &
done
wait

EXPECTED=$((N * ITERATIONS))
ACTUAL=$(bz list --json | jq '.issues | length')
[ "$EXPECTED" -eq "$ACTUAL" ] && echo "PASS" || echo "FAIL"
```

### Chaos Test (Process Crashes)

Simulate process crashes mid-write and verify data integrity:
- Spawn multiple threads
- Kill random threads after random delays
- Verify no corruption, all committed writes visible
- Each issue has valid data (non-empty title, valid ID)

---

## Performance Benchmarks

Run benchmarks with `zig build bench` (bz only) or `zig build bench-compare` (bz vs br).

### bz vs br (Rust/SQLite) Comparison

Benchmark on Linux x86_64 with 100 issues:

| Operation | bz (Zig) | br (Rust) | Winner |
|-----------|----------|-----------|--------|
| init | 1ms | 444ms | bz (444x) |
| create x10 | 100ms | 593ms | bz (6x) |
| bulk x90 | 812ms | 5135ms | bz (6x) |
| show | 52ms | 34ms | br (1.5x) |
| update | 70ms | 34ms | br (2x) |
| search | 74ms | 46ms | br (1.6x) |
| list | 94ms | 36ms | br (2.6x) |
| parallel read x5 | 118ms | 165ms | bz (1.4x) |
| parallel write x5 | 83ms | 269ms | bz (3x) |
| mixed r/w x5 | 102ms | 203ms | bz (2x) |

**Analysis:**
- bz dominates all write operations due to flock + WAL architecture
- bz wins concurrent operations (flock serializes cleanly, SQLite has BUSY retries)
- br wins single reads (SQLite connection stays warm, bz reloads JSONL + WAL each time)

### Performance Targets

| Operation | Target |
|-----------|--------|
| Create issue | < 15ms |
| List 100 issues | < 100ms |
| Ready query (100 issues) | < 100ms |
| Concurrent writes (5 parallel) | < 100ms total |

---

## Test Conventions

### Naming

```zig
test "Issue.toJson handles null description" {
    // ...
}

test "SqliteStorage.getReadyWork excludes blocked issues" {
    // ...
}

test "sync roundtrip preserves all fields" {
    // ...
}
```

### Allocation

All tests should use a test allocator and verify no leaks:

```zig
test "example" {
    const allocator = std.testing.allocator;
    // ... test code ...
    // allocator will fail test if memory leaks
}
```

### Temporary Files

Use `std.testing.tmpDir()` for filesystem tests:

```zig
test "init creates database" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // ... test in tmp.dir ...
}
```

### Error Cases

Test both success and failure paths:

```zig
test "addDependency rejects cycles" {
    // Setup: A -> B -> C
    // Act: try to add C -> A
    // Assert: returns error.CycleDetected
}
```

---

## Running Tests

```bash
# Run all tests (RECOMMENDED - sets up external dependencies)
zig build test

# Run tests for a specific module (only if module has no external deps)
zig test src/storage/store.zig
zig test src/models/issue.zig
```

**Note:** Use `zig build test` rather than `zig test src/root.zig` directly. The build system correctly configures external dependencies (rich_zig, toon_zig) which are required for the full test suite.

**Current test count:** 523 tests across all modules.

---

## CI Integration

The GitHub Actions workflow runs:

1. **Multi-platform tests**: Ubuntu, macOS, Windows
2. **Multi-optimization**: Debug, ReleaseSafe, ReleaseFast, ReleaseSmall
3. **Concurrent write stress tests**: Multi-process WAL contention
4. **Fuzz tests**: 60-second timeout
5. **Format check**: `zig fmt --check`

Tests must pass on all configurations before merge.

---

## The Real Success Metric

> Does the code further our project's vision and goals?

Tests help us detect regressions and document behavior, but they do not define correctness. The ultimate test is whether beads_zig fulfills its vision: a reliable, fast, local-first issue tracker that stays out of your way.
