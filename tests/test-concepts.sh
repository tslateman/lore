#!/usr/bin/env bash
# Integration tests for concept promotion and consolidation
#
# Tests concept lifecycle: manual creation, consolidate --promote,
# concept ID format, and YAML persistence.
# Uses a temporary directory so production data is untouched.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LORE="$SCRIPT_DIR/../lore.sh"

# --- Test harness ---

PASS=0
FAIL=0
TMPDIR=""

setup() {
    TMPDIR=$(mktemp -d)

    # Mirror the directory structure lore.sh expects
    mkdir -p "$TMPDIR/journal/data" "$TMPDIR/journal/lib"
    mkdir -p "$TMPDIR/patterns/data" "$TMPDIR/patterns/lib"
    mkdir -p "$TMPDIR/failures/data" "$TMPDIR/failures/lib"
    mkdir -p "$TMPDIR/transfer" "$TMPDIR/inbox/lib"
    mkdir -p "$TMPDIR/graph/data" "$TMPDIR/lib"
    mkdir -p "$TMPDIR/intent/data/goals" "$TMPDIR/intent/lib"

    # Copy component scripts and libraries
    cp -R "$SCRIPT_DIR/../journal/"* "$TMPDIR/journal/"
    cp -R "$SCRIPT_DIR/../patterns/"* "$TMPDIR/patterns/"
    cp -R "$SCRIPT_DIR/../failures/"* "$TMPDIR/failures/"
    cp -R "$SCRIPT_DIR/../transfer/"* "$TMPDIR/transfer/"
    cp -R "$SCRIPT_DIR/../inbox/"* "$TMPDIR/inbox/"
    cp -R "$SCRIPT_DIR/../graph/"* "$TMPDIR/graph/"
    cp -R "$SCRIPT_DIR/../lib/"* "$TMPDIR/lib/"
    cp -R "$SCRIPT_DIR/../intent/"* "$TMPDIR/intent/"

    # Copy lore.sh into the temp dir so LORE_DIR self-derives correctly
    cp "$LORE" "$TMPDIR/lore.sh"
    chmod +x "$TMPDIR/lore.sh"

    # Initialize empty data files
    : > "$TMPDIR/journal/data/decisions.jsonl"
    cat > "$TMPDIR/patterns/data/patterns.yaml" <<'YAML'
# Pattern Learner Database
patterns: []

anti_patterns: []
YAML
    : > "$TMPDIR/failures/data/failures.jsonl"

    # Seed empty concepts file
    echo "concepts: []" > "$TMPDIR/patterns/data/concepts.yaml"

    # Initialize empty graph
    echo '{"nodes":{},"edges":[]}' > "$TMPDIR/graph/data/graph.json"

    unset _LORE_PATHS_LOADED
    export LORE_DIR="$TMPDIR"
    export LORE_DATA_DIR="$TMPDIR"
}

teardown() {
    [[ -n "$TMPDIR" && -d "$TMPDIR" ]] && rm -rf "$TMPDIR"
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

assert_output_contains() {
    local desc="$1"
    local output="$2"
    local pattern="$3"
    if echo "$output" | grep -q "$pattern"; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc (pattern '$pattern' not found)"
        FAIL=$((FAIL + 1))
    fi
}

assert_output_not_contains() {
    local desc="$1"
    local output="$2"
    local pattern="$3"
    if echo "$output" | grep -q "$pattern"; then
        echo "  FAIL: $desc (pattern '$pattern' unexpectedly found)"
        FAIL=$((FAIL + 1))
    else
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    fi
}

assert_fails() {
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

# --- Tests ---

test_concept_id_format() {
    echo "Test: concept IDs match concept-[a-f0-9]+ pattern"
    setup

    local output
    output=$("$TMPDIR/lore.sh" capture "Format Test" --concept --definition "Testing ID format" 2>&1)

    local concept_id
    concept_id=$(echo "$output" | grep -oE 'concept-[a-f0-9]+' | head -1) || true

    if [[ -n "$concept_id" && "$concept_id" =~ ^concept-[a-f0-9]+$ ]]; then
        echo "  PASS: concept ID matches pattern ($concept_id)"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: concept ID does not match pattern (got: '$concept_id')"
        FAIL=$((FAIL + 1))
    fi

    teardown
}

test_concept_init_seeding() {
    echo "Test: concepts.yaml is created on first concept write"
    setup

    # Remove the seeded file
    rm -f "$TMPDIR/patterns/data/concepts.yaml"

    "$TMPDIR/lore.sh" capture "Auto Seed" --concept --definition "First concept" >/dev/null 2>&1

    local cf="$TMPDIR/patterns/data/concepts.yaml"
    if [[ -f "$cf" ]]; then
        echo "  PASS: concepts.yaml created on first write"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: concepts.yaml not created"
        FAIL=$((FAIL + 1))
    fi

    local content
    content=$(cat "$cf")
    assert_output_contains "contains the concept" "$content" "Auto Seed"

    teardown
}

test_consolidate_promote() {
    echo "Test: consolidate --write --promote creates concepts from clusters"
    setup

    # Seed 3+ similar decisions with high Jaccard overlap
    "$TMPDIR/lore.sh" remember "Use JSONL for append-only storage in journal data" \
        --rationale "Append-only JSONL is simple and reliable for journal storage" --force >/dev/null 2>&1
    "$TMPDIR/lore.sh" remember "Use JSONL format for append-only journal storage" \
        --rationale "JSONL append-only format keeps journal storage simple" --force >/dev/null 2>&1
    "$TMPDIR/lore.sh" remember "JSONL is the right format for append-only journal storage" \
        --rationale "Append-only JSONL storage keeps the journal simple and reliable" --force >/dev/null 2>&1

    local output
    output=$("$TMPDIR/lore.sh" consolidate --write --promote --threshold 40 2>&1) || true

    # Check that a concept was promoted
    assert_output_contains "consolidate reports concept promotion" "$output" "concept"

    # Check concepts.yaml has content
    local cf="$TMPDIR/patterns/data/concepts.yaml"
    if [[ -f "$cf" ]]; then
        local count
        count=$(yq '.concepts | length' "$cf" 2>/dev/null) || count=0
        if [[ "$count" -gt 0 ]]; then
            echo "  PASS: concepts.yaml has $count concept(s) after promotion"
            PASS=$((PASS + 1))
        else
            echo "  FAIL: concepts.yaml is empty after promotion"
            FAIL=$((FAIL + 1))
        fi
    else
        echo "  FAIL: concepts.yaml not found after promotion"
        FAIL=$((FAIL + 1))
    fi

    teardown
}

test_consolidate_too_few_decisions() {
    echo "Test: consolidate with fewer than 3 decisions exits cleanly"
    setup

    "$TMPDIR/lore.sh" remember "Single decision" --rationale "Testing" --force >/dev/null 2>&1

    local output
    output=$("$TMPDIR/lore.sh" consolidate 2>&1) || true

    assert_output_contains "reports too few decisions" "$output" "Fewer than 3"

    teardown
}

test_consolidate_no_promote() {
    echo "Test: consolidate --write without --promote leaves concepts empty"
    setup

    # Seed 3+ similar decisions with high Jaccard overlap
    "$TMPDIR/lore.sh" remember "Use JSONL for append-only storage in journal data" \
        --rationale "Append-only JSONL is simple and reliable for journal storage" --force >/dev/null 2>&1
    "$TMPDIR/lore.sh" remember "Use JSONL format for append-only journal storage" \
        --rationale "JSONL append-only format keeps journal storage simple" --force >/dev/null 2>&1
    "$TMPDIR/lore.sh" remember "JSONL is the right format for append-only journal storage" \
        --rationale "Append-only JSONL storage keeps the journal simple and reliable" --force >/dev/null 2>&1

    "$TMPDIR/lore.sh" consolidate --write --threshold 40 >/dev/null 2>&1

    local count
    count=$(yq '.concepts | length' "$TMPDIR/patterns/data/concepts.yaml" 2>/dev/null) || count=0

    if [[ "$count" -eq 0 ]]; then
        echo "  PASS: consolidate without --promote keeps concepts empty"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: consolidate without --promote created $count concept(s) (expected 0)"
        FAIL=$((FAIL + 1))
    fi

    teardown
}

test_capture_concept_no_name_fails() {
    echo "Test: capture --concept without name shows error"
    setup

    assert_fails "concept without name fails" "$TMPDIR/lore.sh" capture --concept

    teardown
}

test_fts5_searches_new_types() {
    echo "Test: FTS5 index includes failures in search results"
    setup

    # Seed a failure
    "$TMPDIR/lore.sh" fail ToolError "Permission denied on config file" >/dev/null 2>&1

    # Build the index (may fail if sqlite3 not available)
    if "$TMPDIR/lore.sh" index build >/dev/null 2>&1; then
        local output
        output=$("$TMPDIR/lore.sh" recall "permission" 2>&1)
        assert_output_contains "search finds failures" "$output" "ermission"
    else
        echo "  SKIP: sqlite3 not available for FTS5 test"
    fi

    teardown
}

# --- Runner ---

echo "=== Lore Concepts Integration Tests ==="
echo ""

test_concept_id_format
echo ""
test_concept_init_seeding
echo ""
test_consolidate_promote
echo ""
test_consolidate_too_few_decisions
echo ""
test_consolidate_no_promote
echo ""
test_capture_concept_no_name_fails
echo ""
test_fts5_searches_new_types
echo ""

echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
