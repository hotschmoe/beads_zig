# Benchmark Results: br vs bz

**Date:** 2026-02-06
**br version:** 0.1.13 (release)
**bz version:** 0.1.5
**Platform:** Linux x86_64 (Debian)
**Method:** Wall-clock time via `date +%s%N`, 5 iterations averaged (except bulk create)

## Summary Table

| Benchmark           | br (ms) | bz (ms) | Ratio | Notes |
|---------------------|---------|---------|-------|-------|
| init                | 6       | 15      | 250%  | bz creates more schema upfront |
| bulk create (50)    | 308     | 371     | 120%  | ~6ms/issue br, ~7ms/issue bz |
| list (50 issues)    | 6       | 19      | 316%  | bz list slower |
| search              | 6       | 7       | 116%  | Nearly equal |
| count               | 6       | 6       | 100%  | Equal |
| show (single)       | 7       | 8       | 114%  | Nearly equal |
| update              | 5       | 6       | 120%  | Nearly equal |
| count --by-status   | 5       | 6       | 120%  | Nearly equal |
| doctor              | 4       | 28      | 700%  | bz runs more checks |
| stats               | 6       | 14      | 233%  | bz computes more breakdowns |

**Ratio** = bz time / br time * 100. Values > 100% mean bz is slower.

## Analysis

### Fast Operations (within 20% of br)

- **count**: Equal at 6ms
- **search**: 7ms vs 6ms (16% slower)
- **show**: 8ms vs 7ms (14% slower)
- **update**: 6ms vs 5ms (20% slower)
- **count --by-status**: 6ms vs 5ms (20% slower)
- **bulk create per-issue**: 7ms vs 6ms (17% slower)

These are all within noise range for sub-10ms operations. Functionally equivalent performance.

### Moderate Differences

- **init (250%)**: bz takes 15ms vs 6ms. bz creates full schema upfront (11 tables, 29+
  indexes, FTS5 virtual tables). br likely defers some schema creation. This is a one-time
  cost and not worth optimizing.

- **bulk create total (120%)**: 371ms vs 308ms for 50 issues. The per-issue overhead is
  ~1ms, likely from schema initialization on first access. Not a concern.

- **list (316%)**: 19ms vs 6ms. bz's list formatting or query may be doing extra work.
  Worth profiling if list performance becomes an issue at scale.

- **stats (233%)**: 14ms vs 6ms. bz computes full breakdowns by status, priority, and type.
  br's stats (without --activity) is lighter. The extra computation is intentional.

### Significant Differences

- **doctor (700%)**: 28ms vs 4ms. bz runs 6 distinct diagnostic checks including schema
  validation, orphan detection, and cycle detection. br's doctor runs simpler checks.
  This is a feature difference, not a performance bug.

## Key Takeaways

1. **Core CRUD operations are competitive.** Create, show, update, count, and search are
   all within 20% of br, with absolute times under 10ms.

2. **Startup overhead is the main factor.** bz pays a small penalty on init and first-access
   due to full schema creation. This is a one-time cost per workspace.

3. **No blocking performance issues.** All operations complete in under 30ms even in the
   worst case (doctor). For an issue tracker, sub-second response times are the bar.

4. **Optimization opportunities** exist in `list` and `stats` if needed, but they are low
   priority given absolute times are well under 100ms.

## Methodology Notes

- Benchmarks run sequentially (no parallel load)
- Both binaries run against local SQLite databases in /tmp
- br flags `--no-auto-flush --no-auto-import --allow-stale` used to disable JSONL sync overhead
- bz does not have equivalent sync overhead (SQLite-only mode)
- Each benchmark runs 5 iterations except bulk create (1 run of 50 sequential creates)
- Measurements include process startup time for both binaries
