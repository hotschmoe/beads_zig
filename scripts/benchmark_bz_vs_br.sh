#!/bin/bash
# Benchmark script: bz (Zig) vs br (Rust)
# Tests realistic multi-agent scenarios
#
# Usage: ./scripts/benchmark_bz_vs_br.sh
#
# Requirements:
# - bz binary at zig-out/bin/bz (run: zig build)
# - br binary in PATH (or adjust BR_PATH below)

set -e

BZ_PATH="${BZ_PATH:-./zig-out/bin/bz}"
BR_PATH="${BR_PATH:-br}"
BENCHMARK_DIR="${BENCHMARK_DIR:-/tmp/beads_benchmark}"

# Check binaries exist
if [[ ! -x "$BZ_PATH" ]]; then
    echo "Error: bz binary not found at $BZ_PATH"
    echo "Run: zig build"
    exit 1
fi

if ! command -v "$BR_PATH" &> /dev/null; then
    echo "Warning: br binary not found, will only benchmark bz"
    BR_AVAILABLE=false
else
    BR_AVAILABLE=true
fi

cleanup() {
    rm -rf "$BENCHMARK_DIR"
}
trap cleanup EXIT

echo "=== Beads Benchmark: bz (Zig) vs br (Rust) ==="
echo ""

# Test 1: Single agent creating 10 issues sequentially
run_sequential_test() {
    local bin="$1"
    local name="$2"
    local dir="$BENCHMARK_DIR/$name/seq"

    rm -rf "$dir"
    mkdir -p "$dir"

    (
        cd "$dir"
        "$bin" init > /dev/null 2>&1

        local start=$(date +%s.%N)
        for i in $(seq 1 10); do
            "$bin" q "SeqIssue$i" --quiet > /dev/null 2>&1
        done
        local end=$(date +%s.%N)

        echo "$end - $start" | bc
    )
}

echo "Test 1: Single agent, 10 sequential writes"
echo "-------------------------------------------"

bz_time=$(run_sequential_test "$BZ_PATH" "bz")
echo "bz: ${bz_time}s"

if $BR_AVAILABLE; then
    br_time=$(run_sequential_test "$BR_PATH" "br")
    echo "br: ${br_time}s"
fi
echo ""

# Test 2: 10 agents each creating 1 issue (serialized, not concurrent)
run_multi_agent_serial_test() {
    local bin="$1"
    local name="$2"
    local dir="$BENCHMARK_DIR/$name/multi_serial"

    rm -rf "$dir"
    mkdir -p "$dir"

    (
        cd "$dir"
        "$bin" init > /dev/null 2>&1

        local start=$(date +%s.%N)
        for i in $(seq 1 10); do
            "$bin" q "Agent${i}Issue" --quiet > /dev/null 2>&1
        done
        local end=$(date +%s.%N)

        echo "$end - $start" | bc
    )
}

echo "Test 2: 10 agents, 1 write each (serialized)"
echo "---------------------------------------------"

bz_time=$(run_multi_agent_serial_test "$BZ_PATH" "bz")
echo "bz: ${bz_time}s"

if $BR_AVAILABLE; then
    br_time=$(run_multi_agent_serial_test "$BR_PATH" "br")
    echo "br: ${br_time}s"
fi
echo ""

# Test 3: 10 agents writing concurrently (tests lock contention)
run_concurrent_test() {
    local bin="$1"
    local name="$2"
    local dir="$BENCHMARK_DIR/$name/concurrent"

    rm -rf "$dir"
    mkdir -p "$dir"

    (
        cd "$dir"
        "$bin" init > /dev/null 2>&1

        local start=$(date +%s.%N)

        # Spawn 10 processes in parallel
        for i in $(seq 1 10); do
            "$bin" q "ConcAgent${i}" --quiet > /dev/null 2>&1 &
        done
        wait

        local end=$(date +%s.%N)
        local elapsed=$(echo "$end - $start" | bc)

        # Count actual issues created (some may be lost due to concurrent race)
        local count=$("$bin" list --all 2>/dev/null | wc -l)

        echo "$elapsed $count"
    )
}

echo "Test 3: 10 agents writing concurrently"
echo "---------------------------------------"
echo "(Note: without locking, some writes may be lost)"

result=$(run_concurrent_test "$BZ_PATH" "bz")
bz_time=$(echo "$result" | cut -d' ' -f1)
bz_count=$(echo "$result" | cut -d' ' -f2)
echo "bz: ${bz_time}s (${bz_count}/10 issues persisted)"

if $BR_AVAILABLE; then
    result=$(run_concurrent_test "$BR_PATH" "br")
    br_time=$(echo "$result" | cut -d' ' -f1)
    br_count=$(echo "$result" | cut -d' ' -f2)
    echo "br: ${br_time}s (${br_count}/10 issues persisted)"
fi
echo ""

# Test 4: Read performance - list 100 issues
run_read_test() {
    local bin="$1"
    local name="$2"
    local dir="$BENCHMARK_DIR/$name/read"

    rm -rf "$dir"
    mkdir -p "$dir"

    (
        cd "$dir"
        "$bin" init > /dev/null 2>&1

        # Create 100 issues first
        for i in $(seq 1 100); do
            "$bin" q "ReadTest$i" --quiet > /dev/null 2>&1
        done

        # Time list command
        local start=$(date +%s.%N)
        "$bin" list --all > /dev/null 2>&1
        local end=$(date +%s.%N)

        echo "$end - $start" | bc
    )
}

echo "Test 4: List 100 issues"
echo "-----------------------"

bz_time=$(run_read_test "$BZ_PATH" "bz")
echo "bz: ${bz_time}s"

if $BR_AVAILABLE; then
    br_time=$(run_read_test "$BR_PATH" "br")
    echo "br: ${br_time}s"
fi
echo ""

echo "=== Benchmark Complete ==="
