#!/usr/bin/env bash
# Integration tests for the evidence component (library + CLI)
#
# Tests evidence_append, evidence_list, evidence_get,
# evidence_update_confidence, evidence_stats, and the
# CLI integration via lore capture --evidence and lore evidence.

set -euo pipefail

# Hermetic: no live model calls from tests
export LORE_RERANK=0

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$TEST_DIR/fixture.sh"
LORE="$TEST_DIR/../lore.sh"

# --- Test harness ---

PASS=0
FAIL=0
FIXTURE_DIR=""

setup() {
    FIXTURE_DIR=$(mktemp -d)

    # Mirror the directory structure lore.sh expects
    mkdir -p "$FIXTURE_DIR/journal/data" "$FIXTURE_DIR/journal/lib"
    mkdir -p "$FIXTURE_DIR/patterns/data" "$FIXTURE_DIR/patterns/lib"
    mkdir -p "$FIXTURE_DIR/failures/data" "$FIXTURE_DIR/failures/lib"
    mkdir -p "$FIXTURE_DIR/transfer" "$FIXTURE_DIR/inbox/data" "$FIXTURE_DIR/inbox/lib"
    mkdir -p "$FIXTURE_DIR/graph" "$FIXTURE_DIR/lib"
    mkdir -p "$FIXTURE_DIR/evidence/data" "$FIXTURE_DIR/evidence/lib"

    # Copy component scripts and libraries
    cp -R "$TEST_DIR/../journal/"* "$FIXTURE_DIR/journal/"
    cp -R "$TEST_DIR/../patterns/"* "$FIXTURE_DIR/patterns/"
    cp -R "$TEST_DIR/../failures/"* "$FIXTURE_DIR/failures/"
    cp -R "$TEST_DIR/../transfer/"* "$FIXTURE_DIR/transfer/"
    cp -R "$TEST_DIR/../inbox/"* "$FIXTURE_DIR/inbox/"
    cp -R "$TEST_DIR/../graph/"* "$FIXTURE_DIR/graph/"
    cp -R "$TEST_DIR/../lib/"* "$FIXTURE_DIR/lib/"
    cp -R "$TEST_DIR/../evidence/"* "$FIXTURE_DIR/evidence/"

    # Copy lore.sh into the temp dir so LORE_DIR self-derives correctly
    cp "$LORE" "$FIXTURE_DIR/lore.sh"
    chmod +x "$FIXTURE_DIR/lore.sh"

    # Initialize empty data files
    echo '[]' > "$FIXTURE_DIR/journal/data/decisions.jsonl"
    cat > "$FIXTURE_DIR/patterns/data/patterns.yaml" <<'YAML'
# Pattern Learner Database
patterns: []

anti_patterns: []
YAML
    : > "$FIXTURE_DIR/failures/data/failures.jsonl"
    : > "$FIXTURE_DIR/inbox/data/signals.jsonl"
    : > "$FIXTURE_DIR/evidence/data/evidence.jsonl"

    # Reset paths.sh idempotency guard so it re-derives from new LORE_DIR
    unset _LORE_PATHS_LOADED
    export LORE_DIR="$FIXTURE_DIR"
    export LORE_DATA_DIR="$FIXTURE_DIR"
    export CLAUDE_MEMORY_DB="$FIXTURE_DIR/memory.sqlite"
    export LORE_SEARCH_DB="$FIXTURE_DIR/search.db"
}

teardown() {
    remove_fixture "$FIXTURE_DIR"
}

assert_ok() {
    local desc="$1"
    shift
    if "$@" >/dev/null 2>&1; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc (exit code $?)"
        FAIL=$((FAIL + 1))
    fi
}

assert_fail() {
    local desc="$1"
    shift
    if "$@" >/dev/null 2>&1; then
        echo "  FAIL: $desc (expected failure, got success)"
        FAIL=$((FAIL + 1))
    else
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    fi
}

assert_contains() {
    local desc="$1"
    local expected="$2"
    local actual="$3"
    if echo "$actual" | grep -q "$expected"; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc (expected to contain '$expected')"
        FAIL=$((FAIL + 1))
    fi
}

# --- Library-level tests ---

load_evidence_lib() {
    unset _LORE_PATHS_LOADED
    export LORE_DIR="$FIXTURE_DIR"
    export LORE_DATA_DIR="$FIXTURE_DIR"
    export LORE_SEARCH_DB="$FIXTURE_DIR/search.db"
    source "$FIXTURE_DIR/lib/paths.sh"
    source "$FIXTURE_DIR/evidence/lib/evidence.sh"
}

test_append_creates_record() {
    echo "Test: evidence_append creates a record with correct fields"
    setup
    load_evidence_lib

    local id
    id=$(evidence_append "Login fails after token expiry" "council" "auth,security" "confirmed" "session-42")

    assert_contains "returns evi- prefixed ID" "^evi-" "$id"

    local record
    record=$(tail -1 "$FIXTURE_DIR/evidence/data/evidence.jsonl")
    assert_contains "record has content" "Login fails after token expiry" "$record"
    assert_contains "record has source" "council" "$record"
    assert_contains "record has confidence" "confirmed" "$record"
    assert_contains "record has provenance" "session-42" "$record"
    assert_contains "record has auth tag" "auth" "$record"
    assert_contains "record has security tag" "security" "$record"
    teardown
}

test_append_rejects_empty_content() {
    echo "Test: evidence_append rejects empty content"
    setup
    load_evidence_lib

    assert_fail "empty content rejected" evidence_append ""
    teardown
}

test_append_validates_confidence() {
    echo "Test: evidence_append validates confidence levels"
    setup
    load_evidence_lib

    assert_fail "invalid confidence rejected" evidence_append "some text" "manual" "" "bogus"
    assert_ok "preliminary accepted" evidence_append "text" "manual" "" "preliminary"
    assert_ok "confirmed accepted" evidence_append "text" "manual" "" "confirmed"
    assert_ok "contested accepted" evidence_append "text" "manual" "" "contested"
    assert_ok "superseded accepted" evidence_append "text" "manual" "" "superseded"
    teardown
}

test_list_empty() {
    echo "Test: evidence_list returns empty array when no evidence"
    setup
    load_evidence_lib

    local result
    result=$(evidence_list)
    assert_contains "returns empty JSON array" "\\[\\]" "$result"
    teardown
}

test_list_returns_records() {
    echo "Test: evidence_list returns records after append"
    setup
    load_evidence_lib

    evidence_append "First evidence" "manual" "" "preliminary" >/dev/null
    evidence_append "Second evidence" "manual" "" "confirmed" >/dev/null

    local result
    result=$(evidence_list)
    assert_contains "contains first record" "First evidence" "$result"
    assert_contains "contains second record" "Second evidence" "$result"
    teardown
}

test_list_filters_by_confidence() {
    echo "Test: evidence_list filters by confidence"
    setup
    load_evidence_lib

    evidence_append "Preliminary item" "manual" "" "preliminary" >/dev/null
    evidence_append "Confirmed item" "manual" "" "confirmed" >/dev/null

    local result
    result=$(evidence_list "confirmed")
    assert_contains "contains confirmed record" "Confirmed item" "$result"

    # Preliminary item should not appear in confirmed filter
    if echo "$result" | grep -q "Preliminary item"; then
        echo "  FAIL: confirmed filter includes preliminary record"
        FAIL=$((FAIL + 1))
    else
        echo "  PASS: confirmed filter excludes preliminary record"
        PASS=$((PASS + 1))
    fi
    teardown
}

test_list_latest_version_per_id() {
    echo "Test: evidence_list returns latest version per ID (append-only dedup)"
    setup
    load_evidence_lib

    local id
    id=$(evidence_append "Original finding" "manual" "" "preliminary")

    # Update confidence (appends new version with same ID)
    evidence_update_confidence "$id" "confirmed" >/dev/null

    local result
    result=$(evidence_list)

    # Should contain only one record for this ID, with confirmed confidence
    local count
    count=$(echo "$result" | jq --arg id "$id" '[.[] | select(.id == $id)] | length')
    if [[ "$count" -eq 1 ]]; then
        echo "  PASS: single record per ID after update"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: expected 1 record per ID, got $count"
        FAIL=$((FAIL + 1))
    fi

    local confidence
    confidence=$(echo "$result" | jq -r --arg id "$id" '.[] | select(.id == $id) | .confidence')
    assert_contains "latest version has updated confidence" "confirmed" "$confidence"
    teardown
}

test_get_by_id() {
    echo "Test: evidence_get retrieves by ID"
    setup
    load_evidence_lib

    local id
    id=$(evidence_append "Retrievable evidence" "manual" "" "preliminary")

    local record
    record=$(evidence_get "$id")
    assert_contains "retrieved record has correct content" "Retrievable evidence" "$record"
    assert_contains "retrieved record has correct ID" "$id" "$record"
    teardown
}

test_get_nonexistent_id() {
    echo "Test: evidence_get returns empty for nonexistent ID"
    setup
    load_evidence_lib

    local record
    record=$(evidence_get "evi-00000000")
    if [[ -z "$record" ]]; then
        echo "  PASS: nonexistent ID returns empty"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: nonexistent ID returned data: $record"
        FAIL=$((FAIL + 1))
    fi
    teardown
}

test_update_confidence() {
    echo "Test: evidence_update_confidence changes confidence level"
    setup
    load_evidence_lib

    local id
    id=$(evidence_append "Mutable confidence" "manual" "" "preliminary")

    evidence_update_confidence "$id" "confirmed" >/dev/null

    local record
    record=$(evidence_get "$id")
    assert_contains "confidence updated to confirmed" "confirmed" "$record"
    teardown
}

test_update_confidence_rejects_invalid() {
    echo "Test: evidence_update_confidence rejects invalid confidence"
    setup
    load_evidence_lib

    local id
    id=$(evidence_append "Will not update" "manual" "" "preliminary")

    assert_fail "invalid confidence rejected" evidence_update_confidence "$id" "invalid_level"
    teardown
}

test_update_confidence_rejects_nonexistent_id() {
    echo "Test: evidence_update_confidence rejects nonexistent ID"
    setup
    load_evidence_lib

    assert_fail "nonexistent ID rejected" evidence_update_confidence "evi-00000000" "confirmed"
    teardown
}

test_stats_empty() {
    echo "Test: evidence_stats returns zero counts when empty"
    setup
    load_evidence_lib

    local result
    result=$(evidence_stats)
    assert_contains "total is 0" '"total":0' "$result"
    assert_contains "preliminary is 0" '"preliminary":0' "$result"
    assert_contains "confirmed is 0" '"confirmed":0' "$result"
    assert_contains "contested is 0" '"contested":0' "$result"
    assert_contains "superseded is 0" '"superseded":0' "$result"
    teardown
}

test_stats_counts_correctly() {
    echo "Test: evidence_stats counts correctly after appends"
    setup
    load_evidence_lib

    evidence_append "A" "manual" "" "preliminary" >/dev/null
    evidence_append "B" "manual" "" "preliminary" >/dev/null
    evidence_append "C" "manual" "" "confirmed" >/dev/null
    evidence_append "D" "manual" "" "contested" >/dev/null

    local result
    result=$(evidence_stats)

    local total
    total=$(echo "$result" | jq '.total')
    if [[ "$total" -eq 4 ]]; then
        echo "  PASS: total count is 4"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: expected total 4, got $total"
        FAIL=$((FAIL + 1))
    fi

    local prelim
    prelim=$(echo "$result" | jq '.preliminary')
    if [[ "$prelim" -eq 2 ]]; then
        echo "  PASS: preliminary count is 2"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: expected preliminary 2, got $prelim"
        FAIL=$((FAIL + 1))
    fi

    local confirmed
    confirmed=$(echo "$result" | jq '.confirmed')
    if [[ "$confirmed" -eq 1 ]]; then
        echo "  PASS: confirmed count is 1"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: expected confirmed 1, got $confirmed"
        FAIL=$((FAIL + 1))
    fi

    local contested
    contested=$(echo "$result" | jq '.contested')
    if [[ "$contested" -eq 1 ]]; then
        echo "  PASS: contested count is 1"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: expected contested 1, got $contested"
        FAIL=$((FAIL + 1))
    fi
    teardown
}

# --- CLI-level tests ---

test_cli_capture_evidence() {
    echo "Test: lore capture --evidence works"
    setup

    assert_ok "capture --evidence succeeds" "$FIXTURE_DIR/lore.sh" capture "CLI evidence test" --evidence
    assert_contains "evidence.jsonl has content" "CLI evidence test" "$(cat "$FIXTURE_DIR/evidence/data/evidence.jsonl")"
    teardown
}

test_cli_capture_evidence_with_confidence() {
    echo "Test: lore capture --evidence --confidence confirmed works"
    setup

    assert_ok "capture with confidence succeeds" "$FIXTURE_DIR/lore.sh" capture "Confirmed CLI evidence" --evidence --confidence confirmed
    assert_contains "record has confirmed confidence" '"confidence":"confirmed"' "$(cat "$FIXTURE_DIR/evidence/data/evidence.jsonl")"
    teardown
}

test_cli_evidence_list() {
    echo "Test: lore evidence list succeeds"
    setup

    "$FIXTURE_DIR/lore.sh" capture "Listed evidence" --evidence >/dev/null 2>&1

    assert_ok "evidence list succeeds" "$FIXTURE_DIR/lore.sh" evidence list
    teardown
}

test_cli_evidence_get() {
    echo "Test: lore evidence get retrieves a captured record"
    setup

    local output
    output=$("$FIXTURE_DIR/lore.sh" capture "Gettable evidence" --evidence 2>&1)

    # Extract the evi-XXXXXXXX ID from the capture output
    local id
    id=$(echo "$output" | grep -o 'evi-[0-9a-f]*' | head -1)

    if [[ -z "$id" ]]; then
        echo "  FAIL: could not extract evidence ID from capture output"
        FAIL=$((FAIL + 1))
        teardown
        return
    fi

    local result
    result=$("$FIXTURE_DIR/lore.sh" evidence get "$id" 2>&1)
    assert_contains "get returns the record" "Gettable evidence" "$result"
    teardown
}

test_cli_evidence_stats() {
    echo "Test: lore evidence stats returns valid JSON"
    setup

    "$FIXTURE_DIR/lore.sh" capture "Stats evidence" --evidence >/dev/null 2>&1

    local result
    result=$("$FIXTURE_DIR/lore.sh" evidence stats 2>&1)

    # Verify it parses as valid JSON with expected keys
    if echo "$result" | jq '.total' >/dev/null 2>&1; then
        echo "  PASS: stats returns valid JSON with total key"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: stats output is not valid JSON"
        FAIL=$((FAIL + 1))
    fi
    teardown
}

# --- Runner ---

echo "=== Lore Evidence Integration Tests ==="
echo ""

echo "-- Library-level tests --"
echo ""
test_append_creates_record
echo ""
test_append_rejects_empty_content
echo ""
test_append_validates_confidence
echo ""
test_list_empty
echo ""
test_list_returns_records
echo ""
test_list_filters_by_confidence
echo ""
test_list_latest_version_per_id
echo ""
test_get_by_id
echo ""
test_get_nonexistent_id
echo ""
test_update_confidence
echo ""
test_update_confidence_rejects_invalid
echo ""
test_update_confidence_rejects_nonexistent_id
echo ""
test_stats_empty
echo ""
test_stats_counts_correctly
echo ""

echo "-- CLI-level tests --"
echo ""
test_cli_capture_evidence
echo ""
test_cli_capture_evidence_with_confidence
echo ""
test_cli_evidence_list
echo ""
test_cli_evidence_get
echo ""
test_cli_evidence_stats
echo ""

# --- Summary ---
echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
