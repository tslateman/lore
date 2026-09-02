#!/usr/bin/env bash
# Tests for the single-record write-through path
#
# `index-one` and the full build index the same records by different code.
# Each divergence between them shows up as a record that searches wrong, or
# not at all, until the next rebuild hides the evidence. These tests exercise
# write-through alone: build an empty index, index one record of each type
# through index-one, and read the stored columns back.
#
# Uses a temporary directory so production data is untouched.

set -euo pipefail

export LORE_RERANK=0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/fixture.sh"

PASS=0
FAIL=0
FIXTURE_DIR=""
INDEX=""

setup() {
    FIXTURE_DIR=$(mktemp -d)
    mkdir -p "$FIXTURE_DIR/journal/data" "$FIXTURE_DIR/patterns/data"
    mkdir -p "$FIXTURE_DIR/failures/data" "$FIXTURE_DIR/inbox/data"
    mkdir -p "$FIXTURE_DIR/lib"

    cp -R "$SCRIPT_DIR/../lib/"* "$FIXTURE_DIR/lib/"

    : > "$FIXTURE_DIR/journal/data/decisions.jsonl"
    : > "$FIXTURE_DIR/failures/data/failures.jsonl"
    : > "$FIXTURE_DIR/inbox/data/observations.jsonl"
    printf 'patterns: []\n\nanti_patterns: []\n' > "$FIXTURE_DIR/patterns/data/patterns.yaml"
    echo "concepts: []" > "$FIXTURE_DIR/patterns/data/concepts.yaml"

    unset _LORE_PATHS_LOADED
    export LORE_DIR="$FIXTURE_DIR"
    export LORE_DATA_DIR="$FIXTURE_DIR"
    export LORE_SEARCH_DB="$FIXTURE_DIR/search.db"

    INDEX="$FIXTURE_DIR/lib/search-index.sh"
    chmod +x "$INDEX"
    "$INDEX" build >/dev/null 2>&1
}

teardown() {
    remove_fixture "$FIXTURE_DIR"
}

index_one() {
    local type="$1" json="$2"
    if ! "$INDEX" index-one "$type" "$json" 2>"$FIXTURE_DIR/err.txt"; then
        echo "  index-one $type failed: $(cat "$FIXTURE_DIR/err.txt")"
        return 1
    fi
    if [[ -s "$FIXTURE_DIR/err.txt" ]]; then
        echo "  index-one $type wrote to stderr: $(cat "$FIXTURE_DIR/err.txt")"
        return 1
    fi
    return 0
}

assert_column() {
    local desc="$1" table="$2" column="$3" id="$4" want="$5"
    local got
    got=$(sqlite3 "$LORE_SEARCH_DB" \
        "SELECT $column FROM $table WHERE id = '$id';" 2>/dev/null || echo "<query failed>")
    if [[ "$got" == "$want" ]]; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc — $table.$column was '$got', expected '$want'"
        FAIL=$((FAIL + 1))
    fi
}

test_decision_write_through() {
    echo "TEST: a decision indexes into the columns the build uses"
    local json='{"id":"dec-wt-1","decision":"Adopt zorblatt","rationale":"It scales","tags":["alpha","beta"],"timestamp":"2026-09-01T00:00:00Z"}'
    if index_one decision "$json"; then
        assert_column "decision text stored" decisions decision dec-wt-1 "Adopt zorblatt"
        assert_column "rationale stored" decisions rationale dec-wt-1 "It scales"
        assert_column "tags joined" decisions tags dec-wt-1 "alpha, beta"
        assert_column "project from first tag" decisions project dec-wt-1 "alpha"
    else
        FAIL=$((FAIL + 1))
    fi
}

test_pattern_write_through() {
    echo "TEST: a pattern indexes into the columns the build uses"
    local json='{"id":"pat-wt-1","name":"Zorblatt guard","context":"ctx","problem":"prob","solution":"sol","created_at":"2026-09-01T00:00:00Z","project":"spec-trace"}'
    if index_one pattern "$json"; then
        assert_column "name stored" patterns name pat-wt-1 "Zorblatt guard"
        assert_column "created_at as timestamp" patterns timestamp pat-wt-1 "2026-09-01T00:00:00Z"
        assert_column "project stored" patterns project pat-wt-1 "spec-trace"
        assert_column "confidence defaults numeric" patterns confidence pat-wt-1 "0.5"
    else
        FAIL=$((FAIL + 1))
    fi
}

test_failure_write_through() {
    echo "TEST: a failure indexes into the columns the build uses"
    local json='{"id":"fail-wt-1","error_type":"OperationalError","error_message":"no such column","tool":"sqlite3","timestamp":"2026-09-01T00:00:00Z"}'
    if index_one failure "$json"; then
        assert_column "error_type stored" failures error_type fail-wt-1 "OperationalError"
        assert_column "error_message stored" failures error_message fail-wt-1 "no such column"
        assert_column "tool stored" failures tool fail-wt-1 "sqlite3"
    else
        FAIL=$((FAIL + 1))
    fi
}

test_signal_write_through() {
    echo "TEST: a signal indexes into the columns the build uses"
    local json='{"id":"obs-wt-1","content":"Zorblatt observed","tags":["gamma","delta"],"timestamp":"2026-09-01T00:00:00Z"}'
    if index_one signal "$json"; then
        assert_column "content stored" observations content obs-wt-1 "Zorblatt observed"
        assert_column "tags joined" observations tags obs-wt-1 "gamma, delta"
    else
        FAIL=$((FAIL + 1))
    fi
}

test_concept_write_through() {
    echo "TEST: a concept indexes into the columns the build uses"
    local json='{"id":"con-wt-1","name":"Zorblatt","definition":"A test token","created_at":"2026-09-01T00:00:00Z"}'
    if index_one concept "$json"; then
        assert_column "name stored" concepts name con-wt-1 "Zorblatt"
        assert_column "definition stored" concepts definition con-wt-1 "A test token"
        assert_column "created_at as timestamp" concepts timestamp con-wt-1 "2026-09-01T00:00:00Z"
    else
        FAIL=$((FAIL + 1))
    fi
}

trap teardown EXIT
setup

echo "=== Write-through index tests ==="
echo ""
test_decision_write_through
echo ""
test_pattern_write_through
echo ""
test_failure_write_through
echo ""
test_signal_write_through
echo ""
test_concept_write_through
echo ""

echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
