#!/bin/bash
# Benchmark script: bz (Zig) workflow
# Times init, create, list, ready, and claim operations
#
# Usage: ./scripts/benchmark_bz.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
SANDBOX_DIR="$PROJECT_DIR/sandbox"

BZ_PATH="${BZ_PATH:-$PROJECT_DIR/zig-out/bin/bz}"
BZ_TEMP="$SANDBOX_DIR/bz_bench"

if [[ ! -x "$BZ_PATH" ]]; then
    echo "Error: bz binary not found at $BZ_PATH"
    echo "Run: zig build"
    exit 1
fi

cleanup() {
    rm -rf "$BZ_TEMP"
}

time_cmd() {
    local start=$(date +%s%N)
    "$@" > /dev/null 2>&1
    local end=$(date +%s%N)
    echo $(( (end - start) / 1000000 ))
}

time_loop() {
    local count=$1
    shift
    local start=$(date +%s%N)
    for _ in $(seq 1 "$count"); do
        "$@" > /dev/null 2>&1
    done
    local end=$(date +%s%N)
    echo $(( (end - start) / 1000000 ))
}

# Initialize
cleanup
mkdir -p "$BZ_TEMP"
cd "$BZ_TEMP"

echo "=== Beads Benchmark: bz (Zig) ==="
echo "Directory: $BZ_TEMP"
echo ""

# Step 1: Init
echo -n "[1/5] Init: "
init_ms=$(time_cmd "$BZ_PATH" init)
echo "${init_ms}ms"

# Step 2: Create 10 beads
echo -n "[2/5] Create 10 beads: "
create_ms=$(time_loop 10 "$BZ_PATH" q "TestBead" --quiet)
echo "${create_ms}ms (avg: $((create_ms / 10))ms per bead)"

# Step 3: List
echo -n "[3/5] List all: "
list_ms=$(time_cmd "$BZ_PATH" list --all)
echo "${list_ms}ms"

# Step 4: Ready (mark all as ready)
echo -n "[4/5] Ready 10 beads: "
ready_ms=$(time_loop 10 "$BZ_PATH" ready --next --quiet)
echo "${ready_ms}ms (avg: $((ready_ms / 10))ms per bead)"

# Step 5: Claim 10 beads
echo -n "[5/5] Claim 10 beads: "
claim_ms=$(time_loop 10 "$BZ_PATH" claim --quiet)
echo "${claim_ms}ms (avg: $((claim_ms / 10))ms per bead)"

# Cleanup
echo ""
echo "Cleaning up..."
cleanup
echo "Done"

# Summary
echo ""
echo "=== Summary ==="
printf "%-20s %10s\n" "Operation" "Time"
printf "%-20s %10s\n" "---------" "----"
printf "%-20s %8dms\n" "init" "$init_ms"
printf "%-20s %8dms\n" "create x10" "$create_ms"
printf "%-20s %8dms\n" "list" "$list_ms"
printf "%-20s %8dms\n" "ready x10" "$ready_ms"
printf "%-20s %8dms\n" "claim x10" "$claim_ms"
echo ""
