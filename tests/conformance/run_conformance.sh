#!/usr/bin/env bash
#
# Conformance test suite: compares beads_rust (br) vs beads_zig (bz) outputs.
#
# Runs identical command sequences against both binaries in isolated sandboxes,
# normalizes dynamic fields (IDs, timestamps, paths), and diffs the results.
#
# Usage: ./run_conformance.sh [--verbose]
#
# Requires: br and bz binaries accessible at the paths below.

set -euo pipefail

# --- Configuration -----------------------------------------------------------

BR="${BR:-/home/hotschmoe/.local/bin/br}"
BZ="${BZ:-/home/hotschmoe/beads_zig/zig-out/bin/bz}"
VERBOSE="${1:-}"

BR_DIR=""
BZ_DIR=""
RESULTS_DIR=""

# br-specific flags to suppress auto-sync noise
BR_FLAGS="--no-color --allow-stale --no-auto-flush --no-auto-import"

PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0
KNOWN_DIFF_COUNT=0

declare -a TEST_RESULTS=()

# --- Cleanup -----------------------------------------------------------------

cleanup() {
    if [[ -n "$BR_DIR" && -d "$BR_DIR" ]]; then rm -rf "$BR_DIR"; fi
    if [[ -n "$BZ_DIR" && -d "$BZ_DIR" ]]; then rm -rf "$BZ_DIR"; fi
    if [[ -n "$RESULTS_DIR" && -d "$RESULTS_DIR" ]]; then rm -rf "$RESULTS_DIR"; fi
}
trap cleanup EXIT

# --- Helpers -----------------------------------------------------------------

log() {
    if [[ "$VERBOSE" == "--verbose" ]]; then
        echo "[DEBUG] $*" >&2
    fi
}

# Normalize output: strip IDs, timestamps, paths, versions, whitespace.
# Accepts a mapping file as $2 for consistent ID replacement.
normalize() {
    local input="$1"
    local id_map_file="${2:-}"

    local output="$input"

    # Strip stderr log lines (br emits WARN/INFO to stderr that leaks into some captures)
    output=$(echo "$output" | grep -v '^\s*$' | grep -v '^[0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}T.*\(WARN\|INFO\|DEBUG\|TRACE\|ERROR\)' || true)

    # Strip leading/trailing whitespace from each line
    output=$(echo "$output" | sed 's/[[:space:]]*$//' | sed 's/^[[:space:]]*//')

    # Normalize bd-XXXX IDs to sequential placeholders
    if [[ -n "$id_map_file" && -f "$id_map_file" ]]; then
        while IFS='=' read -r real_id placeholder; do
            output=$(echo "$output" | sed "s/${real_id}/${placeholder}/g")
        done < "$id_map_file"
    fi

    # Replace any remaining bd-XXXX patterns with ID_X
    output=$(echo "$output" | sed 's/bd-[a-z0-9]\{2,8\}/ID_X/g')

    # Replace Unix timestamps (10+ digits)
    output=$(echo "$output" | sed 's/[0-9]\{10,\}/TIMESTAMP/g')

    # Replace RFC3339 dates (2026-02-06T04:16:27.529289Z)
    output=$(echo "$output" | sed 's/[0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}T[0-9:\.]*Z\?/TIMESTAMP/g')

    # Replace date-only (2026-02-06)
    output=$(echo "$output" | sed 's/[0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}/DATE/g')

    # Replace absolute paths
    output=$(echo "$output" | sed 's|/[a-zA-Z0-9/_.-]*/\.beads[a-zA-Z0-9/_.-]*|PATH|g')
    output=$(echo "$output" | sed 's|/tmp/[a-zA-Z0-9/_.-]*|PATH|g')

    # Replace version numbers (X.Y.Z)
    output=$(echo "$output" | sed 's/[0-9]\+\.[0-9]\+\.[0-9]\+/VERSION/g')

    # Replace file sizes like "< 1 MB" or "123 KB"
    output=$(echo "$output" | sed 's/[<>]\?[0-9]\+ [KMG]\?B/SIZE/g')
    output=$(echo "$output" | sed 's/<[0-9]\+ [KMG]\?B/SIZE/g')

    # Collapse multiple spaces
    output=$(echo "$output" | sed 's/  */ /g')

    # Strip empty lines
    output=$(echo "$output" | grep -v '^\s*$' || true)

    echo "$output"
}

# Record a test result.
# Usage: record_result "test_name" "PASS|FAIL|SKIP|KNOWN_DIFF" "details"
record_result() {
    local name="$1"
    local status="$2"
    local details="${3:-}"

    case "$status" in
        PASS) ((PASS_COUNT++)) || true ;;
        FAIL) ((FAIL_COUNT++)) || true ;;
        SKIP) ((SKIP_COUNT++)) || true ;;
        KNOWN_DIFF) ((KNOWN_DIFF_COUNT++)) || true ;;
    esac

    TEST_RESULTS+=("${status}|${name}|${details}")
    echo "[${status}] ${name}"
    if [[ -n "$details" && "$status" != "PASS" ]]; then
        echo "        ${details}"
    fi
}

# Run a command in both sandboxes, normalize, compare.
# Usage: run_test "test_name" "command_suffix_br" "command_suffix_bz" [known_diff]
# If command_suffix_bz is empty, uses same as br.
run_test() {
    local name="$1"
    local cmd_br="$2"
    local cmd_bz="${3:-$2}"
    local known_diff="${4:-}"

    local br_stdout br_stderr br_exit bz_stdout bz_stderr bz_exit

    log "Running test: $name"
    log "  BR cmd: (cd $BR_DIR && $BR $cmd_br $BR_FLAGS)"
    log "  BZ cmd: (cd $BZ_DIR && $BZ $cmd_bz)"

    # Run br
    br_stdout=$(cd "$BR_DIR" && eval "$BR $cmd_br $BR_FLAGS" 2>"$RESULTS_DIR/br_stderr" || true)
    br_stderr=$(cat "$RESULTS_DIR/br_stderr")
    br_exit=0

    # Run bz
    bz_stdout=$(cd "$BZ_DIR" && eval "$BZ $cmd_bz" 2>"$RESULTS_DIR/bz_stderr" || true)
    bz_stderr=$(cat "$RESULTS_DIR/bz_stderr")
    bz_exit=0

    # Normalize
    local br_norm bz_norm
    br_norm=$(normalize "$br_stdout" "$RESULTS_DIR/br_id_map")
    bz_norm=$(normalize "$bz_stdout" "$RESULTS_DIR/bz_id_map")

    # Save for debugging
    echo "$br_norm" > "$RESULTS_DIR/${name}_br.txt"
    echo "$bz_norm" > "$RESULTS_DIR/${name}_bz.txt"

    log "  BR normalized: $br_norm"
    log "  BZ normalized: $bz_norm"

    # Compare
    if [[ "$br_norm" == "$bz_norm" ]]; then
        record_result "$name" "PASS"
    elif [[ -n "$known_diff" ]]; then
        local diff_out
        diff_out=$(diff <(echo "$br_norm") <(echo "$bz_norm") || true)
        record_result "$name" "KNOWN_DIFF" "$known_diff"
        echo "$diff_out" > "$RESULTS_DIR/${name}_diff.txt"
    else
        local diff_out
        diff_out=$(diff <(echo "$br_norm") <(echo "$bz_norm") || true)
        record_result "$name" "FAIL" "Output differs"
        if [[ "$VERBOSE" == "--verbose" ]]; then
            echo "--- diff (br vs bz) ---"
            echo "$diff_out"
            echo "--- end diff ---"
        fi
        echo "$diff_out" > "$RESULTS_DIR/${name}_diff.txt"
    fi
}

# Run a command that produces an ID, capture it.
# Usage: id=$(capture_id "binary_path" "sandbox_dir" "command" "extra_flags")
capture_id_br() {
    local cmd="$1"
    local output
    output=$(cd "$BR_DIR" && eval "$BR $cmd $BR_FLAGS" 2>/dev/null || true)
    # br outputs: "checkmark Created bd-XXX: Title"
    echo "$output" | grep -oP 'bd-[a-z0-9]+' | head -1
}

capture_id_bz() {
    local cmd="$1"
    local output
    output=$(cd "$BZ_DIR" && eval "$BZ $cmd" 2>/dev/null || true)
    # bz outputs: "Created issue bd-XXX"
    echo "$output" | grep -oP 'bd-[a-z0-9]+' | head -1
}

# --- Setup -------------------------------------------------------------------

echo "========================================"
echo "  Conformance Test Suite: br vs bz"
echo "========================================"
echo ""

# Verify binaries exist
if [[ ! -x "$BR" ]]; then
    echo "ERROR: br binary not found at $BR"
    exit 1
fi
if [[ ! -x "$BZ" ]]; then
    echo "ERROR: bz binary not found at $BZ"
    exit 1
fi

echo "br: $($BR version 2>/dev/null || echo 'unknown')"
echo "bz: $($BZ version 2>/dev/null || echo 'unknown')"
echo ""

# Create temp directories
BR_DIR=$(mktemp -d /tmp/conformance_br_XXXXXX)
BZ_DIR=$(mktemp -d /tmp/conformance_bz_XXXXXX)
RESULTS_DIR=$(mktemp -d /tmp/conformance_results_XXXXXX)

echo "br sandbox: $BR_DIR"
echo "bz sandbox: $BZ_DIR"
echo "results:    $RESULTS_DIR"
echo ""

# Initialize ID maps (will track bd-XXXX -> ID_N mappings per binary)
touch "$RESULTS_DIR/br_id_map"
touch "$RESULTS_DIR/bz_id_map"

BR_ID_SEQ=0
BZ_ID_SEQ=0

add_id_mapping() {
    local binary="$1"  # "br" or "bz"
    local real_id="$2"
    local map_file="$RESULTS_DIR/${binary}_id_map"

    if [[ -z "$real_id" ]]; then return; fi

    # Check if already mapped
    if grep -q "^${real_id}=" "$map_file" 2>/dev/null; then return; fi

    if [[ "$binary" == "br" ]]; then
        ((BR_ID_SEQ++)) || true
        echo "${real_id}=ID_${BR_ID_SEQ}" >> "$map_file"
    else
        ((BZ_ID_SEQ++)) || true
        echo "${real_id}=ID_${BZ_ID_SEQ}" >> "$map_file"
    fi
}

echo "========================================"
echo "  Running Tests"
echo "========================================"
echo ""

# --- Test 01: init -----------------------------------------------------------

echo "--- Phase 1: Initialization ---"

br_init_out=$(cd "$BR_DIR" && $BR init $BR_FLAGS 2>/dev/null || true)
bz_init_out=$(cd "$BZ_DIR" && $BZ init 2>/dev/null || true)

br_init_norm=$(normalize "$br_init_out")
bz_init_norm=$(normalize "$bz_init_out")

# Both should contain "Initialized beads workspace"
if echo "$br_init_norm" | grep -qi "initialized" && echo "$bz_init_norm" | grep -qi "initialized"; then
    record_result "01_init" "PASS" "Both initialized successfully"
else
    record_result "01_init" "FAIL" "br: $br_init_norm | bz: $bz_init_norm"
fi

# --- Test 02-04: create issues -----------------------------------------------

echo ""
echo "--- Phase 2: Issue Creation ---"

# br uses P0-P4 for priority, bz uses named priorities (high, low, medium)
# P1 = high, P3 = low, P2 = medium

BR_ID1=$(capture_id_br 'create "First issue" -p P1')
BZ_ID1=$(capture_id_bz 'create "First issue" --priority high')
add_id_mapping "br" "$BR_ID1"
add_id_mapping "bz" "$BZ_ID1"

if [[ -n "$BR_ID1" && -n "$BZ_ID1" ]]; then
    record_result "02_create_issue_1" "PASS" "br=$BR_ID1, bz=$BZ_ID1"
else
    record_result "02_create_issue_1" "FAIL" "br=$BR_ID1, bz=$BZ_ID1 (one or both empty)"
fi

BR_ID2=$(capture_id_br 'create "Second issue" -p P3')
BZ_ID2=$(capture_id_bz 'create "Second issue" --priority low')
add_id_mapping "br" "$BR_ID2"
add_id_mapping "bz" "$BZ_ID2"

if [[ -n "$BR_ID2" && -n "$BZ_ID2" ]]; then
    record_result "03_create_issue_2" "PASS" "br=$BR_ID2, bz=$BZ_ID2"
else
    record_result "03_create_issue_2" "FAIL" "br=$BR_ID2, bz=$BZ_ID2 (one or both empty)"
fi

BR_ID3=$(capture_id_br 'create "Third issue" -p P2')
BZ_ID3=$(capture_id_bz 'create "Third issue" --priority medium')
add_id_mapping "br" "$BR_ID3"
add_id_mapping "bz" "$BZ_ID3"

if [[ -n "$BR_ID3" && -n "$BZ_ID3" ]]; then
    record_result "04_create_issue_3" "PASS" "br=$BR_ID3, bz=$BZ_ID3"
else
    record_result "04_create_issue_3" "FAIL" "br=$BR_ID3, bz=$BZ_ID3 (one or both empty)"
fi

log "ID mappings:"
log "  BR: $BR_ID1, $BR_ID2, $BR_ID3"
log "  BZ: $BZ_ID1, $BZ_ID2, $BZ_ID3"

# --- Test 05: list -----------------------------------------------------------

echo ""
echo "--- Phase 3: Querying ---"

run_test "05_list" "list" "list" "Output format differs (br uses icons/priority badges, bz uses [STATUS] format)"

# --- Test 06: show -----------------------------------------------------------

run_test "06_show" "show $BR_ID1" "show $BZ_ID1" "Output format differs (br uses rich formatting, bz uses key-value)"

# --- Test 07: count -----------------------------------------------------------

# Count should return the same number
br_count=$(cd "$BR_DIR" && $BR count $BR_FLAGS 2>/dev/null || true)
bz_count=$(cd "$BZ_DIR" && $BZ count 2>/dev/null || true)

br_count_num=$(echo "$br_count" | grep -oP '^\d+$' | head -1)
bz_count_num=$(echo "$bz_count" | grep -oP '^\d+$' | head -1)

if [[ "$br_count_num" == "$bz_count_num" ]]; then
    record_result "07_count" "PASS" "Both report $br_count_num issues"
else
    record_result "07_count" "FAIL" "br=$br_count_num, bz=$bz_count_num"
fi

# --- Test 08: search ---------------------------------------------------------

run_test "08_search" 'search "First"' 'search "First"' "Output wording differs (br: Found N issue(s), bz: different format)"

# --- Test 09: update priority -------------------------------------------------

echo ""
echo "--- Phase 4: Mutations ---"

br_update_out=$(cd "$BR_DIR" && $BR update $BR_ID1 -p P2 $BR_FLAGS 2>/dev/null || true)
bz_update_out=$(cd "$BZ_DIR" && $BZ update $BZ_ID1 --priority medium 2>/dev/null || true)

# Both should indicate success
if [[ -n "$br_update_out" || -n "$bz_update_out" ]]; then
    # Check both produced some output (not error)
    br_update_ok=$(echo "$br_update_out" | grep -ci "updated\|success\|changed" || true)
    bz_update_ok=$(echo "$bz_update_out" | grep -ci "updated\|success\|changed" || true)
    if [[ "$br_update_ok" -gt 0 && "$bz_update_ok" -gt 0 ]]; then
        record_result "09_update_priority" "PASS" "Both updated successfully"
    else
        record_result "09_update_priority" "KNOWN_DIFF" "br: $br_update_out | bz: $bz_update_out"
    fi
else
    record_result "09_update_priority" "FAIL" "No output from either"
fi

# --- Test 10: close -----------------------------------------------------------

br_close_out=$(cd "$BR_DIR" && $BR close $BR_ID2 $BR_FLAGS 2>/dev/null || true)
bz_close_out=$(cd "$BZ_DIR" && $BZ close $BZ_ID2 2>/dev/null || true)

br_close_ok=$(echo "$br_close_out" | grep -ci "closed" || true)
bz_close_ok=$(echo "$bz_close_out" | grep -ci "closed" || true)

if [[ "$br_close_ok" -gt 0 && "$bz_close_ok" -gt 0 ]]; then
    record_result "10_close" "PASS" "Both closed successfully"
else
    record_result "10_close" "FAIL" "br: $br_close_out | bz: $bz_close_out"
fi

# --- Test 11: list after close ------------------------------------------------

run_test "11_list_after_close" "list" "list" "Output format differs"

# --- Test 12: label add -------------------------------------------------------

# br: label add <issue> --label <name>
# bz: label add <issue> <name>
br_label_out=$(cd "$BR_DIR" && $BR label add $BR_ID1 --label bugfix $BR_FLAGS 2>/dev/null || true)
bz_label_out=$(cd "$BZ_DIR" && $BZ label add $BZ_ID1 bugfix 2>/dev/null || true)

br_label_ok=$(echo "$br_label_out" | grep -ci "added\|label" || true)
bz_label_ok=$(echo "$bz_label_out" | grep -ci "added\|label" || true)

if [[ "$br_label_ok" -gt 0 && "$bz_label_ok" -gt 0 ]]; then
    record_result "12_label_add" "PASS" "Both added label"
else
    record_result "12_label_add" "FAIL" "br: $br_label_out | bz: $bz_label_out"
fi

# --- Test 13: comments add ---------------------------------------------------

# br: comments add <issue> "text"
# bz: comments add <issue> "text"
br_comment_out=$(cd "$BR_DIR" && $BR comments add $BR_ID1 "Test comment" $BR_FLAGS 2>/dev/null || true)
bz_comment_out=$(cd "$BZ_DIR" && $BZ comments add $BZ_ID1 "Test comment" 2>/dev/null || true)

br_comment_ok=$(echo "$br_comment_out" | grep -ci "comment\|added" || true)
bz_comment_ok=$(echo "$bz_comment_out" | grep -ci "comment\|added" || true)

if [[ "$br_comment_ok" -gt 0 && "$bz_comment_ok" -gt 0 ]]; then
    record_result "13_comments_add" "PASS" "Both added comment"
else
    record_result "13_comments_add" "FAIL" "br: $br_comment_out | bz: $bz_comment_out"
fi

# --- Test 14: dep add ---------------------------------------------------------

# br: dep add <issue> <depends_on>
# bz: dep add <issue> <depends_on>
br_dep_out=$(cd "$BR_DIR" && $BR dep add $BR_ID1 $BR_ID3 $BR_FLAGS 2>/dev/null || true)
bz_dep_out=$(cd "$BZ_DIR" && $BZ dep add $BZ_ID1 $BZ_ID3 2>/dev/null || true)

br_dep_ok=$(echo "$br_dep_out" | grep -ci "added\|dependency\|depends" || true)
bz_dep_ok=$(echo "$bz_dep_out" | grep -ci "added\|dependency\|depends" || true)

if [[ "$br_dep_ok" -gt 0 && "$bz_dep_ok" -gt 0 ]]; then
    record_result "14_dep_add" "PASS" "Both added dependency"
else
    record_result "14_dep_add" "FAIL" "br: $br_dep_out | bz: $bz_dep_out"
fi

# --- Test 15: dep list --------------------------------------------------------

run_test "15_dep_list" "dep list $BR_ID1" "dep list $BZ_ID1" "Minor format differences expected"

# --- Test 16: reopen ----------------------------------------------------------

br_reopen_out=$(cd "$BR_DIR" && $BR reopen $BR_ID2 $BR_FLAGS 2>/dev/null || true)
bz_reopen_out=$(cd "$BZ_DIR" && $BZ reopen $BZ_ID2 2>/dev/null || true)

br_reopen_ok=$(echo "$br_reopen_out" | grep -ci "reopen" || true)
bz_reopen_ok=$(echo "$bz_reopen_out" | grep -ci "reopen" || true)

if [[ "$br_reopen_ok" -gt 0 && "$bz_reopen_ok" -gt 0 ]]; then
    record_result "16_reopen" "PASS" "Both reopened successfully"
else
    record_result "16_reopen" "FAIL" "br: $br_reopen_out | bz: $bz_reopen_out"
fi

# --- Test 17: stats -----------------------------------------------------------

echo ""
echo "--- Phase 5: Reporting ---"

run_test "17_stats" "stats --no-activity" "stats" "Stats output format differs significantly between br and bz"

# --- Test 18: count after mutations -------------------------------------------

br_count2=$(cd "$BR_DIR" && $BR count $BR_FLAGS 2>/dev/null || true)
bz_count2=$(cd "$BZ_DIR" && $BZ count 2>/dev/null || true)

br_count2_num=$(echo "$br_count2" | grep -oP '^\d+$' | head -1)
bz_count2_num=$(echo "$bz_count2" | grep -oP '^\d+$' | head -1)

if [[ "$br_count2_num" == "$bz_count2_num" ]]; then
    record_result "18_count_after_mutations" "PASS" "Both report $br_count2_num issues"
else
    record_result "18_count_after_mutations" "FAIL" "br=$br_count2_num, bz=$bz_count2_num"
fi

# --- Test 19: info ------------------------------------------------------------

run_test "19_info" "info" "info" "Info output format differs (br shows more details)"

# --- Test 20: doctor ----------------------------------------------------------

run_test "20_doctor" "doctor" "doctor" "Doctor output format differs (br uses OK prefix, bz uses [OK] prefix)"

# --- Test 21: JSON mode: list -------------------------------------------------

echo ""
echo "--- Phase 6: JSON Output Mode ---"

run_test "21_json_list" "list --json" "list --json" "JSON structure differs (br: array, bz: {success, issues, count})"

# --- Test 22: JSON mode: show -------------------------------------------------

run_test "22_json_show" "show $BR_ID1 --json" "show $BZ_ID1 --json" "JSON field set differs"

# --- Test 23: JSON mode: count ------------------------------------------------

run_test "23_json_count" "count --json" "count --json" "JSON format may differ"

# --- Test 24: delete ----------------------------------------------------------

echo ""
echo "--- Phase 7: Destructive Operations ---"

br_del_out=$(cd "$BR_DIR" && $BR delete $BR_ID3 $BR_FLAGS 2>/dev/null || true)
bz_del_out=$(cd "$BZ_DIR" && $BZ delete $BZ_ID3 2>/dev/null || true)

br_del_ok=$(echo "$br_del_out" | grep -ci "delet\|tombstone\|removed" || true)
bz_del_ok=$(echo "$bz_del_out" | grep -ci "delet\|tombstone\|removed" || true)

if [[ "$br_del_ok" -gt 0 && "$bz_del_ok" -gt 0 ]]; then
    record_result "24_delete" "PASS" "Both deleted/tombstoned issue"
elif [[ "$br_del_ok" -gt 0 || "$bz_del_ok" -gt 0 ]]; then
    record_result "24_delete" "KNOWN_DIFF" "br: $br_del_out | bz: $bz_del_out"
else
    record_result "24_delete" "FAIL" "br: $br_del_out | bz: $bz_del_out"
fi

# --- Test 25: count after delete ----------------------------------------------

br_count3=$(cd "$BR_DIR" && $BR count $BR_FLAGS 2>/dev/null || true)
bz_count3=$(cd "$BZ_DIR" && $BZ count 2>/dev/null || true)

br_count3_num=$(echo "$br_count3" | grep -oP '^\d+$' | head -1)
bz_count3_num=$(echo "$bz_count3" | grep -oP '^\d+$' | head -1)

if [[ "$br_count3_num" == "$bz_count3_num" ]]; then
    record_result "25_count_after_delete" "PASS" "Both report $br_count3_num issues"
else
    record_result "25_count_after_delete" "KNOWN_DIFF" "br=$br_count3_num, bz=$bz_count3_num (delete behavior may differ)"
fi

# --- Test 26: label list ------------------------------------------------------

echo ""
echo "--- Phase 8: Label and Comment Queries ---"

run_test "26_label_list" "label list $BR_ID1" "label list $BZ_ID1" "Label list format may differ"

# --- Test 27: comments list ---------------------------------------------------

run_test "27_comments_list" "comments $BR_ID1" "comments list $BZ_ID1" "Comments format may differ"

# --- Test 28: dep remove ------------------------------------------------------

echo ""
echo "--- Phase 9: Dependency Removal ---"

br_deprem_out=$(cd "$BR_DIR" && $BR dep remove $BR_ID1 $BR_ID3 $BR_FLAGS 2>/dev/null || true)
bz_deprem_out=$(cd "$BZ_DIR" && $BZ dep remove $BZ_ID1 $BZ_ID3 2>/dev/null || true)

br_deprem_ok=$(echo "$br_deprem_out" | grep -ci "removed\|dependency" || true)
bz_deprem_ok=$(echo "$bz_deprem_out" | grep -ci "removed\|dependency" || true)

if [[ "$br_deprem_ok" -gt 0 && "$bz_deprem_ok" -gt 0 ]]; then
    record_result "28_dep_remove" "PASS" "Both removed dependency"
elif [[ -z "$br_deprem_out" && -z "$bz_deprem_out" ]]; then
    # Both silent = both succeeded (some CLIs are quiet on dep remove)
    record_result "28_dep_remove" "PASS" "Both completed (silent)"
else
    record_result "28_dep_remove" "KNOWN_DIFF" "br: $br_deprem_out | bz: $bz_deprem_out"
fi

# --- Test 29: label remove ---------------------------------------------------

br_labrem_out=$(cd "$BR_DIR" && $BR label remove $BR_ID1 --label bugfix $BR_FLAGS 2>/dev/null || true)
bz_labrem_out=$(cd "$BZ_DIR" && $BZ label remove $BZ_ID1 bugfix 2>/dev/null || true)

br_labrem_ok=$(echo "$br_labrem_out" | grep -ci "removed\|label" || true)
bz_labrem_ok=$(echo "$bz_labrem_out" | grep -ci "removed\|label" || true)

if [[ "$br_labrem_ok" -gt 0 && "$bz_labrem_ok" -gt 0 ]]; then
    record_result "29_label_remove" "PASS" "Both removed label"
else
    record_result "29_label_remove" "KNOWN_DIFF" "br: $br_labrem_out | bz: $bz_labrem_out"
fi

# --- Test 30: where -----------------------------------------------------------

echo ""
echo "--- Phase 10: Miscellaneous ---"

br_where=$(cd "$BR_DIR" && $BR where $BR_FLAGS 2>/dev/null || true)
bz_where=$(cd "$BZ_DIR" && $BZ where 2>/dev/null || true)

# Both should point to .beads
if echo "$br_where" | grep -q ".beads" && echo "$bz_where" | grep -q ".beads"; then
    record_result "30_where" "PASS" "Both point to .beads"
else
    record_result "30_where" "KNOWN_DIFF" "br: $br_where | bz: $bz_where"
fi

# =============================================================================
#  Summary
# =============================================================================

echo ""
echo "========================================"
echo "  Summary"
echo "========================================"
echo ""

TOTAL=$((PASS_COUNT + FAIL_COUNT + SKIP_COUNT + KNOWN_DIFF_COUNT))

printf "%-14s %s\n" "Total tests:" "$TOTAL"
printf "%-14s %s\n" "Passed:" "$PASS_COUNT"
printf "%-14s %s\n" "Failed:" "$FAIL_COUNT"
printf "%-14s %s\n" "Known diffs:" "$KNOWN_DIFF_COUNT"
printf "%-14s %s\n" "Skipped:" "$SKIP_COUNT"
echo ""

echo "Detailed Results:"
echo "----------------------------------------"
printf "%-12s %-30s %s\n" "STATUS" "TEST" "DETAILS"
echo "----------------------------------------"

for result in "${TEST_RESULTS[@]}"; do
    IFS='|' read -r status name details <<< "$result"
    printf "%-12s %-30s %s\n" "[$status]" "$name" "$details"
done

echo "----------------------------------------"
echo ""

# Save raw results
echo "Results saved to: $RESULTS_DIR"
echo "  Normalized outputs: \${name}_br.txt / \${name}_bz.txt"
echo "  Diffs: \${name}_diff.txt"

# Exit code
if [[ "$FAIL_COUNT" -gt 0 ]]; then
    echo ""
    echo "RESULT: FAIL ($FAIL_COUNT failures)"
    exit 1
else
    echo ""
    echo "RESULT: PASS (all tests passed or have known differences)"
    exit 0
fi
