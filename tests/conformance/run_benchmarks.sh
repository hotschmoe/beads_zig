#!/usr/bin/env bash
#
# Benchmark suite: compares beads_rust (br) vs beads_zig (bz) performance.
#
# Measures wall-clock time for common operations using both binaries.
#
# Usage: ./run_benchmarks.sh

set -euo pipefail

# --- Configuration -----------------------------------------------------------

BR="${BR:-/home/hotschmoe/.local/bin/br}"
BZ="${BZ:-/home/hotschmoe/beads_zig/zig-out/bin/bz}"

BR_FLAGS="--no-color --allow-stale --no-auto-flush --no-auto-import"

BR_DIR=""
BZ_DIR=""

BULK_COUNT=50

declare -a BENCH_RESULTS=()

# --- Cleanup -----------------------------------------------------------------

cleanup() {
    if [[ -n "$BR_DIR" && -d "$BR_DIR" ]]; then rm -rf "$BR_DIR"; fi
    if [[ -n "$BZ_DIR" && -d "$BZ_DIR" ]]; then rm -rf "$BZ_DIR"; fi
}
trap cleanup EXIT

# --- Helpers -----------------------------------------------------------------

# Time a command, return milliseconds.
# Usage: ms=$(time_ms "command")
time_ms() {
    local cmd="$1"
    local start end elapsed_ms
    start=$(date +%s%N)
    eval "$cmd" >/dev/null 2>&1 || true
    end=$(date +%s%N)
    elapsed_ms=$(( (end - start) / 1000000 ))
    echo "$elapsed_ms"
}

# Run a benchmark N times and report average.
# Usage: bench "name" "br_cmd" "bz_cmd" [iterations]
bench() {
    local name="$1"
    local br_cmd="$2"
    local bz_cmd="$3"
    local iters="${4:-5}"

    local br_total=0 bz_total=0
    local br_ms bz_ms

    for ((i=1; i<=iters; i++)); do
        br_ms=$(time_ms "cd $BR_DIR && $br_cmd")
        bz_ms=$(time_ms "cd $BZ_DIR && $bz_cmd")
        br_total=$((br_total + br_ms))
        bz_total=$((bz_total + bz_ms))
    done

    local br_avg=$((br_total / iters))
    local bz_avg=$((bz_total / iters))

    local ratio speedup
    if [[ "$br_avg" -gt 0 ]]; then
        # ratio = bz/br * 100 (percentage)
        ratio=$(( (bz_avg * 100) / br_avg ))
        if [[ "$bz_avg" -lt "$br_avg" ]]; then
            speedup="bz ${ratio}% of br (faster)"
        elif [[ "$bz_avg" -gt "$br_avg" ]]; then
            speedup="bz ${ratio}% of br (slower)"
        else
            speedup="equal"
        fi
    else
        ratio="N/A"
        speedup="br too fast to measure"
    fi

    printf "  %-30s  br: %6d ms  bz: %6d ms  (%s)\n" "$name" "$br_avg" "$bz_avg" "$speedup"
    BENCH_RESULTS+=("${name}|${br_avg}|${bz_avg}|${ratio}|${speedup}")
}

# --- Setup -------------------------------------------------------------------

echo "========================================"
echo "  Benchmark Suite: br vs bz"
echo "========================================"
echo ""

echo "br: $($BR version 2>/dev/null || echo 'unknown')"
echo "bz: $($BZ version 2>/dev/null || echo 'unknown')"
echo "Bulk count: $BULK_COUNT issues"
echo ""

# --- Benchmark 1: Init -------------------------------------------------------

echo "--- Benchmark 1: Init Speed ---"

# Measure init (need fresh dirs each time)
br_init_total=0
bz_init_total=0
INIT_ITERS=5

for ((i=1; i<=INIT_ITERS; i++)); do
    tmpbr=$(mktemp -d /tmp/bench_br_XXXXXX)
    tmpbz=$(mktemp -d /tmp/bench_bz_XXXXXX)

    br_ms=$(time_ms "cd $tmpbr && $BR init $BR_FLAGS")
    bz_ms=$(time_ms "cd $tmpbz && $BZ init")

    br_init_total=$((br_init_total + br_ms))
    bz_init_total=$((bz_init_total + bz_ms))

    rm -rf "$tmpbr" "$tmpbz"
done

br_init_avg=$((br_init_total / INIT_ITERS))
bz_init_avg=$((bz_init_total / INIT_ITERS))

if [[ "$br_init_avg" -gt 0 ]]; then
    init_ratio=$(( (bz_init_avg * 100) / br_init_avg ))
else
    init_ratio="N/A"
fi

printf "  %-30s  br: %6d ms  bz: %6d ms  (bz %s%% of br)\n" "init" "$br_init_avg" "$bz_init_avg" "$init_ratio"
BENCH_RESULTS+=("init|${br_init_avg}|${bz_init_avg}|${init_ratio}|bz ${init_ratio}% of br")
echo ""

# --- Setup workspaces for remaining benchmarks --------------------------------

BR_DIR=$(mktemp -d /tmp/bench_br_XXXXXX)
BZ_DIR=$(mktemp -d /tmp/bench_bz_XXXXXX)

cd "$BR_DIR" && $BR init $BR_FLAGS >/dev/null 2>&1
cd "$BZ_DIR" && $BZ init >/dev/null 2>&1

# --- Benchmark 2: Bulk Create ------------------------------------------------

echo "--- Benchmark 2: Bulk Create ($BULK_COUNT issues) ---"

br_create_start=$(date +%s%N)
for ((i=1; i<=BULK_COUNT; i++)); do
    (cd "$BR_DIR" && $BR create "Benchmark issue $i" -p P2 $BR_FLAGS >/dev/null 2>&1) || true
done
br_create_end=$(date +%s%N)
br_create_ms=$(( (br_create_end - br_create_start) / 1000000 ))

bz_create_start=$(date +%s%N)
for ((i=1; i<=BULK_COUNT; i++)); do
    (cd "$BZ_DIR" && $BZ create "Benchmark issue $i" --priority medium >/dev/null 2>&1) || true
done
bz_create_end=$(date +%s%N)
bz_create_ms=$(( (bz_create_end - bz_create_start) / 1000000 ))

br_per_issue=$((br_create_ms / BULK_COUNT))
bz_per_issue=$((bz_create_ms / BULK_COUNT))

if [[ "$br_create_ms" -gt 0 ]]; then
    create_ratio=$(( (bz_create_ms * 100) / br_create_ms ))
else
    create_ratio="N/A"
fi

printf "  %-30s  br: %6d ms  bz: %6d ms  (bz %s%% of br)\n" "bulk create (total)" "$br_create_ms" "$bz_create_ms" "$create_ratio"
printf "  %-30s  br: %6d ms  bz: %6d ms\n" "per issue" "$br_per_issue" "$bz_per_issue"
BENCH_RESULTS+=("bulk_create_${BULK_COUNT}|${br_create_ms}|${bz_create_ms}|${create_ratio}|bz ${create_ratio}% of br")
echo ""

# --- Benchmark 3: List All Issues ---------------------------------------------

echo "--- Benchmark 3: List All Issues ---"
bench "list (all $BULK_COUNT)" "$BR list $BR_FLAGS" "$BZ list"
echo ""

# --- Benchmark 4: Search -----------------------------------------------------

echo "--- Benchmark 4: Search ---"
bench "search 'issue 25'" "$BR search 'issue 25' $BR_FLAGS" "$BZ search 'issue 25'"
echo ""

# --- Benchmark 5: Count ------------------------------------------------------

echo "--- Benchmark 5: Count ---"
bench "count" "$BR count $BR_FLAGS" "$BZ count"
echo ""

# --- Benchmark 6: Show -------------------------------------------------------

echo "--- Benchmark 6: Show (single issue) ---"

# Get first issue ID from each
BR_FIRST_ID=$(cd "$BR_DIR" && $BR list --json $BR_FLAGS 2>/dev/null | grep -oP '"id"\s*:\s*"bd-[a-z0-9]+"' | head -1 | grep -oP 'bd-[a-z0-9]+')
BZ_FIRST_ID=$(cd "$BZ_DIR" && $BZ list --json 2>/dev/null | grep -oP '"id"\s*:\s*"bd-[a-z0-9]+"' | head -1 | grep -oP 'bd-[a-z0-9]+')

if [[ -n "$BR_FIRST_ID" && -n "$BZ_FIRST_ID" ]]; then
    bench "show (single)" "$BR show $BR_FIRST_ID $BR_FLAGS" "$BZ show $BZ_FIRST_ID"
else
    echo "  SKIP: Could not determine issue IDs"
fi
echo ""

# --- Benchmark 7: Update -----------------------------------------------------

echo "--- Benchmark 7: Update ---"
if [[ -n "$BR_FIRST_ID" && -n "$BZ_FIRST_ID" ]]; then
    bench "update priority" "$BR update $BR_FIRST_ID -p P1 $BR_FLAGS" "$BZ update $BZ_FIRST_ID --priority high"
else
    echo "  SKIP: Could not determine issue IDs"
fi
echo ""

# --- Benchmark 8: Count by status --------------------------------------------

echo "--- Benchmark 8: Count by Status ---"
bench "count --by-status" "$BR count --by-status $BR_FLAGS" "$BZ count --by-status" 2>/dev/null || true
echo ""

# --- Benchmark 9: Doctor -----------------------------------------------------

echo "--- Benchmark 9: Doctor ---"
bench "doctor" "$BR doctor $BR_FLAGS" "$BZ doctor"
echo ""

# --- Benchmark 10: Stats -----------------------------------------------------

echo "--- Benchmark 10: Stats ---"
bench "stats" "$BR stats --no-activity $BR_FLAGS" "$BZ stats"
echo ""

# =============================================================================
#  Summary
# =============================================================================

echo "========================================"
echo "  Summary"
echo "========================================"
echo ""
printf "%-32s  %8s  %8s  %8s  %s\n" "BENCHMARK" "BR (ms)" "BZ (ms)" "RATIO" "NOTES"
echo "--------------------------------------------------------------------------------"
for result in "${BENCH_RESULTS[@]}"; do
    IFS='|' read -r name br_ms bz_ms ratio notes <<< "$result"
    printf "%-32s  %8s  %8s  %7s%%  %s\n" "$name" "$br_ms" "$bz_ms" "$ratio" "$notes"
done
echo "--------------------------------------------------------------------------------"
echo ""
echo "Ratio = bz time / br time * 100"
echo "< 100% means bz is faster, > 100% means br is faster"
