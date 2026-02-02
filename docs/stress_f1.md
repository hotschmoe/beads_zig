# Stress Test Performance Analysis

**Date**: 2026-02-01
**Status**: Investigation Complete

---

## Summary

The test suite (653 tests) times out during stress tests due to:
1. **VM disk I/O latency** - fsync averaging 120ms per call
2. **Multiple fsyncs per operation** - Each `bz q` does 3 fsyncs
3. **Subprocess spawning overhead** - Each test invocation spawns a new process

---

## Test Suite Breakdown

| Test Range | Count | Type | Time |
|------------|-------|------|------|
| 1-647 | 647 | Unit + CLI | ~2 seconds |
| 648-653 | 6 | Stress (subprocess) | >5 minutes (timeout) |

The first 647 tests pass quickly. The stress tests in `src/tests/stress_test.zig` cause timeouts.

---

## Root Cause: I/O Latency

Measured via `iostat -x`:
```
Device   w_await   f_await   %util
vda      48.95ms   120.52ms  13.17%
```

Each `bz q` command performs 3 fsyncs (verified via strace):
```
% time     seconds  usecs/call     calls    errors syscall
 87.24    0.019650          15      1292           process_vm_readv
  1.61    0.000362         120         3         1 fsync
  0.13    0.000030          15         2           flock
```

**Wall-clock time per `bz q`**: 0.04s to 3.09s (highly variable due to I/O queuing)

---

## Stress Tests Analysis

### Test 648: `concurrent writes: 10 agents, 1 write each, serialized`
- Spawns 10 sequential subprocess invocations
- Each runs `bz q "AgentNIssue0" --quiet`
- Expected time: 10 x ~1s = ~10s (best case)
- Observed: Variable, can exceed 30s

### Test 649: `batch writes: 1 agent, 10 issues, zero corruption`
- Similar to above, 10 sequential subprocess invocations
- Expected time: ~10s

### Test 650: `chaos: concurrent writes with interrupts`
- Spawns 5 shell processes
- Each runs: `for j in $(seq 0 49); do bz q ... --quiet; sleep 0.01; done`
- 5 agents x 50 writes = 250 subprocess invocations
- Expected time: 50 x ~1s = ~50s (parallel, so ~50s total)
- Observed: Often exceeds timeout

### Tests 651-653: In-process tests
- `sequential writes: single thread baseline` - WAL internals, fast
- `lock cycling: rapid acquire/release` - flock only, fast
- `WAL durability` - WAL internals, fast

---

## Timing Measurements

Consecutive `bz q` invocations:
```
3.09 seconds
0.84 seconds
1.08 seconds
1.49 seconds
0.04 seconds
```

The variance is due to:
1. fsync waiting for VM disk I/O
2. I/O queue depth fluctuations
3. Possible other VM tenants competing for disk

---

## No External Dependencies

Verified: Tests do NOT use `br` or `bd` for verification.
- Tests only spawn `bz` binary
- The `"bd-"` prefix in assertions is beads_zig's own ID format
- Benchmark scripts (`scripts/benchmark_bz_vs_br.sh`) exist but are not part of test suite

---

## Recommendations

### Option A: Reduce fsync calls (improves real-world performance)
- Currently: 3 fsyncs per `bz q`
- Could batch/defer fsyncs for non-critical paths
- Risk: Data loss on crash

### Option B: Skip subprocess stress tests in CI
- Add `--skip-stress` flag or environment variable
- Run stress tests only on fast disk environments

### Option C: Reduce stress test intensity
- Current: 10 agents, 50 writes each in chaos test
- Could reduce to: 3 agents, 5 writes each
- Maintains coverage with faster execution

### Option D: Use in-process tests for concurrency
- Replace subprocess spawning with thread-based tests
- Test WAL/lock internals directly without CLI overhead
- Already implemented: `sequential writes: single thread baseline`

---

## Current Test Configuration

From `src/tests/stress_test.zig`:
```zig
const STRESS_NUM_AGENTS = 10;
const STRESS_WRITES_PER_AGENT = 1;
const TOTAL_EXPECTED_WRITES = STRESS_NUM_AGENTS * STRESS_WRITES_PER_AGENT;
```

Chaos test:
```zig
const num_agents = 5;
// Each runs: for j in $(seq 0 49); do bz q ... --quiet; sleep 0.01; done
```

---

## Files Involved

- `src/tests/stress_test.zig` - Stress test definitions
- `src/tests/cli_test.zig` - CLI integration tests (fast)
- `src/storage/jsonl.zig` - Contains fsync calls
- `src/storage/wal.zig` - WAL operations with fsync
- `scripts/benchmark_bz.sh` - bz-only benchmark
- `scripts/benchmark_bz_vs_br.sh` - Comparison benchmark (not a test)
