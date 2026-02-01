#!/bin/bash
# Benchmark script: bz (Zig) vs br (Rust)
# Times init and bead creation in sandbox directories
#
# Usage: ./scripts/benchmark_bz_vs_br.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
SANDBOX_DIR="$PROJECT_DIR/sandbox"

BZ_PATH="${BZ_PATH:-$PROJECT_DIR/zig-out/bin/bz}"
BR_PATH="${BR_PATH:-br}"

BZ_TEMP="$SANDBOX_DIR/bz_temp"
BR_TEMP="$SANDBOX_DIR/br_temp"

# Check binaries exist
if [[ ! -x "$BZ_PATH" ]]; then
    echo "Error: bz binary not found at $BZ_PATH"
    echo "Run: zig build"
    exit 1
fi

if ! command -v "$BR_PATH" &> /dev/null; then
    echo "Error: br binary not found"
    exit 1
fi

# Cleanup function
cleanup() {
    rm -rf "$BZ_TEMP" "$BR_TEMP"
}

# Clean up any previous runs
cleanup

# Create sandbox directories
mkdir -p "$BZ_TEMP" "$BR_TEMP"

echo "=== Beads Benchmark: bz (Zig) vs br (Rust) ==="
echo ""
echo "Directories:"
echo "  bz: $BZ_TEMP"
echo "  br: $BR_TEMP"
echo ""

# Helper to time a command (returns milliseconds)
time_cmd() {
    local start=$(date +%s%N)
    "$@" > /dev/null 2>&1
    local end=$(date +%s%N)
    echo $(( (end - start) / 1000000 ))
}

# === Step 1: Init ===
echo "[1/4] Initializing repositories..."
echo -n "  bz init: "
cd "$BZ_TEMP"
bz_init_ms=$(time_cmd "$BZ_PATH" init)
echo "${bz_init_ms}ms"

echo -n "  br init: "
cd "$BR_TEMP"
br_init_ms=$(time_cmd "$BR_PATH" init)
echo "${br_init_ms}ms"

# === Step 2: Create 10 beads ===
echo "[2/4] Creating 10 beads (sequential)..."
echo -n "  bz create x10: "
cd "$BZ_TEMP"
bz_create_start=$(date +%s%N)
for i in $(seq 1 10); do
    "$BZ_PATH" q "TestBead$i" --quiet > /dev/null 2>&1
done
bz_create_end=$(date +%s%N)
bz_create_ms=$(( (bz_create_end - bz_create_start) / 1000000 ))
echo "${bz_create_ms}ms (avg: $((bz_create_ms / 10))ms per bead)"

echo -n "  br create x10: "
cd "$BR_TEMP"
br_create_start=$(date +%s%N)
for i in $(seq 1 10); do
    "$BR_PATH" q "TestBead$i" --quiet > /dev/null 2>&1
done
br_create_end=$(date +%s%N)
br_create_ms=$(( (br_create_end - br_create_start) / 1000000 ))
echo "${br_create_ms}ms (avg: $((br_create_ms / 10))ms per bead)"

# === Step 3: List all beads ===
echo "[3/4] Listing all beads..."
echo -n "  bz list: "
cd "$BZ_TEMP"
bz_list_ms=$(time_cmd "$BZ_PATH" list --all)
echo "${bz_list_ms}ms"

echo -n "  br list: "
cd "$BR_TEMP"
br_list_ms=$(time_cmd "$BR_PATH" list --all)
echo "${br_list_ms}ms"

# === Step 4: Cleanup ===
echo "[4/4] Cleaning up..."
rm -rf "$BZ_TEMP" "$BR_TEMP"
echo "  Removed $BZ_TEMP"
echo "  Removed $BR_TEMP"

# === Summary ===
echo ""
echo "=== Summary ==="
printf "%-20s %10s %10s\n" "Operation" "bz (Zig)" "br (Rust)"
printf "%-20s %10s %10s\n" "---------" "--------" "---------"
printf "%-20s %8dms %8dms\n" "init" "$bz_init_ms" "$br_init_ms"
printf "%-20s %8dms %8dms\n" "create x10" "$bz_create_ms" "$br_create_ms"
printf "%-20s %8dms %8dms\n" "list" "$bz_list_ms" "$br_list_ms"
echo ""
echo "Done."
