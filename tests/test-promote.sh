#!/usr/bin/env bash
# Integration tests for the promotion pipeline (lib/promote.sh)
#
# Tests candidate queries, classification, promotion workflow, and Engram updates.
# Uses a temporary directory so production data is untouched.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LORE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Setup temp environment
TMPDIR=$(mktemp -d)
export LORE_DATA_DIR="$TMPDIR"
export LORE_DIR

# Override Engram DB location
export CLAUDE_MEMORY_DB="$TMPDIR/memory.sqlite"

# Source the code
source "$LORE_DIR/lib/promote.sh"
source "$LORE_DIR/lib/paths.sh"

# Test framework
TESTS_RUN=0
TESTS_PASSED=0

pass() {
    echo "✓ $1"
    TESTS_PASSED=$((TESTS_PASSED + 1))
}

fail() {
    echo "✗ $1"
}

setup() {
    # Reset temp dir
    rm -rf "$TMPDIR"
    mkdir -p "$TMPDIR"
    mkdir -p "$TMPDIR/journal/data"
    mkdir -p "$TMPDIR/patterns/data"
    mkdir -p "$TMPDIR/inbox/data"

    # Initialize Lore data files
    touch "$TMPDIR/journal/data/decisions.jsonl"
    echo "patterns: []" > "$TMPDIR/patterns/data/patterns.yaml"
    touch "$TMPDIR/inbox/data/observations.jsonl"

    # Create test Engram database
    sqlite3 "$TMPDIR/memory.sqlite" <<'SQL'
CREATE TABLE Memory(
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    importance INTEGER NOT NULL,
    accessCount INTEGER NOT NULL,
    createdAt REAL NOT NULL,
    lastAccessedAt REAL NOT NULL,
    project TEXT NOT NULL,
    embedding BLOB NOT NULL,
    source TEXT NOT NULL,
    topic TEXT NOT NULL,
    expiresAt REAL NOT NULL,
    content TEXT NOT NULL
);
SQL
}

teardown() {
    rm -rf "$TMPDIR"
}

# --- Test: count_promotion_candidates ---

test_count_no_db() {
    echo "Test: count returns 0 when DB missing"
    setup
    rm -f "$TMPDIR/memory.sqlite"

    local count
    count=$(count_promotion_candidates)

    [[ "$count" == "0" ]] && pass "Returns 0 when DB missing" || fail "Expected 0, got $count"
    teardown
}

test_count_empty_db() {
    echo "Test: count returns 0 for empty DB"
    setup

    local count
    count=$(count_promotion_candidates)

    [[ "$count" == "0" ]] && pass "Returns 0 for empty DB" || fail "Expected 0, got $count"
    teardown
}

test_count_with_candidates() {
    echo "Test: count finds high-value memories"
    setup

    # Insert high-importance memory
    sqlite3 "$TMPDIR/memory.sqlite" \
        "INSERT INTO Memory (importance, accessCount, createdAt, lastAccessedAt, project, embedding, source, topic, expiresAt, content) VALUES (5, 1, 1708000000, 1708000000, 'lore', zeroblob(0), 'user', 'architecture', 0, 'Use JSONL for storage');"

    # Insert high-access memory
    sqlite3 "$TMPDIR/memory.sqlite" \
        "INSERT INTO Memory (importance, accessCount, createdAt, lastAccessedAt, project, embedding, source, topic, expiresAt, content) VALUES (2, 5, 1708000000, 1708000000, 'lore', zeroblob(0), 'user', 'patterns', 0, 'Always validate input');"

    # Insert low-value memory (should be excluded)
    sqlite3 "$TMPDIR/memory.sqlite" \
        "INSERT INTO Memory (importance, accessCount, createdAt, lastAccessedAt, project, embedding, source, topic, expiresAt, content) VALUES (2, 1, 1708000000, 1708000000, 'lore', zeroblob(0), 'user', 'misc', 0, 'Some note');"

    local count
    count=$(count_promotion_candidates)

    [[ "$count" == "2" ]] && pass "Counts high-value memories" || fail "Expected 2, got $count"
    teardown
}

test_count_excludes_shadows() {
    echo "Test: count excludes Lore shadows"
    setup

    # Insert shadow memory (should be excluded)
    sqlite3 "$TMPDIR/memory.sqlite" \
        "INSERT INTO Memory (importance, accessCount, createdAt, lastAccessedAt, project, embedding, source, topic, expiresAt, content) VALUES (5, 10, 1708000000, 1708000000, 'lore', zeroblob(0), 'lore-bridge', 'lore-decisions', 0, '[lore:dec-abc123] Use JSONL for storage');"

    # Insert non-shadow (should be counted)
    sqlite3 "$TMPDIR/memory.sqlite" \
        "INSERT INTO Memory (importance, accessCount, createdAt, lastAccessedAt, project, embedding, source, topic, expiresAt, content) VALUES (5, 1, 1708000000, 1708000000, 'lore', zeroblob(0), 'user', 'architecture', 0, 'Use JSONL for storage');"

    local count
    count=$(count_promotion_candidates)

    [[ "$count" == "1" ]] && pass "Excludes shadows from count" || fail "Expected 1, got $count"
    teardown
}

test_count_excludes_expired() {
    echo "Test: count excludes expired memories"
    setup

    # Insert expired memory (expiresAt in the past)
    sqlite3 "$TMPDIR/memory.sqlite" \
        "INSERT INTO Memory (importance, accessCount, createdAt, lastAccessedAt, project, embedding, source, topic, expiresAt, content) VALUES (5, 10, 1708000000, 1708000000, 'lore', zeroblob(0), 'user', 'temp', 1000000, 'Temporary note');"

    # Insert non-expired (should be counted)
    sqlite3 "$TMPDIR/memory.sqlite" \
        "INSERT INTO Memory (importance, accessCount, createdAt, lastAccessedAt, project, embedding, source, topic, expiresAt, content) VALUES (5, 1, 1708000000, 1708000000, 'lore', zeroblob(0), 'user', 'architecture', 0, 'Use JSONL for storage');"

    local count
    count=$(count_promotion_candidates)

    [[ "$count" == "1" ]] && pass "Excludes expired memories" || fail "Expected 1, got $count"
    teardown
}

# --- Test: query_promotion_candidates ---

test_query_returns_json() {
    echo "Test: query returns JSON array"
    setup

    sqlite3 "$TMPDIR/memory.sqlite" \
        "INSERT INTO Memory (importance, accessCount, createdAt, lastAccessedAt, project, embedding, source, topic, expiresAt, content) VALUES (5, 3, 1708000000, 1708000000, 'lore', zeroblob(0), 'user', 'architecture', 0, 'Use JSONL for storage');"

    local result
    result=$(query_promotion_candidates 10)

    # Should be valid JSON with 7 fields
    echo "$result" | jq -e '.[0] | has("id") and has("content") and has("topic")' >/dev/null 2>&1 && \
        pass "Returns JSON with expected fields" || fail "Invalid JSON structure"
    teardown
}

test_query_sorts_by_priority() {
    echo "Test: query sorts by importance * accessCount DESC"
    setup

    # Insert memories with different priority scores
    sqlite3 "$TMPDIR/memory.sqlite" \
        "INSERT INTO Memory (importance, accessCount, createdAt, lastAccessedAt, project, embedding, source, topic, expiresAt, content) VALUES (4, 2, 1708000000, 1708000000, 'lore', zeroblob(0), 'user', 'topic1', 0, 'Memory A');" # score: 8

    sqlite3 "$TMPDIR/memory.sqlite" \
        "INSERT INTO Memory (importance, accessCount, createdAt, lastAccessedAt, project, embedding, source, topic, expiresAt, content) VALUES (5, 5, 1708000000, 1708000000, 'lore', zeroblob(0), 'user', 'topic2', 0, 'Memory B');" # score: 25

    sqlite3 "$TMPDIR/memory.sqlite" \
        "INSERT INTO Memory (importance, accessCount, createdAt, lastAccessedAt, project, embedding, source, topic, expiresAt, content) VALUES (3, 4, 1708000000, 1708000000, 'lore', zeroblob(0), 'user', 'topic3', 0, 'Memory C');" # score: 12

    local results
    results=$(query_promotion_candidates 10)

    # First result should be Memory B (highest score)
    local first_content
    first_content=$(echo "$results" | jq -r '.[0].content')

    [[ "$first_content" == "Memory B" ]] && pass "Sorts by priority score" || fail "Expected 'Memory B', got '$first_content'"
    teardown
}

test_query_respects_limit() {
    echo "Test: query respects limit parameter"
    setup

    # Insert 5 memories
    for i in {1..5}; do
        sqlite3 "$TMPDIR/memory.sqlite" \
            "INSERT INTO Memory (importance, accessCount, createdAt, lastAccessedAt, project, embedding, source, topic, expiresAt, content) VALUES (5, 1, 1708000000, 1708000000, 'lore', zeroblob(0), 'user', 'topic', 0, 'Memory $i');"
    done

    local results
    results=$(query_promotion_candidates 3)

    local count
    count=$(echo "$results" | jq 'length')

    [[ "$count" == "3" ]] && pass "Respects limit parameter" || fail "Expected 3 results, got $count"
    teardown
}

# --- Test: classify_candidate ---

test_classify_decision() {
    echo "Test: classify detects decision indicators"
    setup

    local type
    type=$(classify_candidate "We decided to use PostgreSQL for the database")

    [[ "$type" == "decision" ]] && pass "Detects decision from 'decided'" || fail "Expected 'decision', got '$type'"
    teardown
}

test_classify_pattern() {
    echo "Test: classify detects pattern indicators"
    setup

    local type
    type=$(classify_candidate "Always validate input before processing")

    [[ "$type" == "pattern" ]] && pass "Detects pattern from 'always'" || fail "Expected 'pattern', got '$type'"
    teardown
}

test_classify_observation() {
    echo "Test: classify defaults to observation"
    setup

    local type
    type=$(classify_candidate "The API endpoint is slow")

    [[ "$type" == "observation" ]] && pass "Defaults to observation" || fail "Expected 'observation', got '$type'"
    teardown
}

# --- Test: get_candidate ---

test_get_candidate_returns_json() {
    echo "Test: get_candidate returns JSON"
    setup

    sqlite3 "$TMPDIR/memory.sqlite" \
        "INSERT INTO Memory (importance, accessCount, createdAt, lastAccessedAt, project, embedding, source, topic, expiresAt, content) VALUES (5, 3, 1708000000, 1708000000, 'lore', zeroblob(0), 'user', 'architecture', 0, 'Use JSONL for storage');"

    local result
    result=$(get_candidate 1)

    # Check if valid JSON
    echo "$result" | jq -e '.[0].content' >/dev/null 2>&1 && pass "Returns valid JSON" || fail "Invalid JSON"
    teardown
}

test_get_candidate_missing_id() {
    echo "Test: get_candidate returns empty for missing ID"
    setup

    local result
    result=$(get_candidate 999 2>/dev/null || echo "")

    [[ -z "$result" || "$result" == "[]" ]] && pass "Returns empty for missing ID" || fail "Expected empty, got '$result'"
    teardown
}

# --- Test: mark_as_promoted ---

test_mark_as_promoted_updates_content() {
    echo "Test: mark_as_promoted updates content with [lore:id] prefix"
    setup

    sqlite3 "$TMPDIR/memory.sqlite" \
        "INSERT INTO Memory (importance, accessCount, createdAt, lastAccessedAt, project, embedding, source, topic, expiresAt, content) VALUES (5, 3, 1708000000, 1708000000, 'lore', zeroblob(0), 'user', 'architecture', 0, 'Use JSONL for storage');"

    mark_as_promoted 1 "dec-abc123"

    local updated_content
    updated_content=$(sqlite3 "$TMPDIR/memory.sqlite" "SELECT content FROM Memory WHERE id = 1;")

    [[ "$updated_content" == "[lore:dec-abc123] Use JSONL for storage" ]] && pass "Adds [lore:id] prefix" || fail "Expected prefix, got '$updated_content'"
    teardown
}

test_mark_as_promoted_updates_source() {
    echo "Test: mark_as_promoted updates source to 'lore-promoted'"
    setup

    sqlite3 "$TMPDIR/memory.sqlite" \
        "INSERT INTO Memory (importance, accessCount, createdAt, lastAccessedAt, project, embedding, source, topic, expiresAt, content) VALUES (5, 3, 1708000000, 1708000000, 'lore', zeroblob(0), 'user', 'architecture', 0, 'Use JSONL for storage');"

    mark_as_promoted 1 "dec-abc123"

    local updated_source
    updated_source=$(sqlite3 "$TMPDIR/memory.sqlite" "SELECT source FROM Memory WHERE id = 1;")

    [[ "$updated_source" == "lore-promoted" ]] && pass "Updates source to 'lore-promoted'" || fail "Expected 'lore-promoted', got '$updated_source'"
    teardown
}

# --- Run all tests ---

TESTS_RUN=$((TESTS_RUN + 1)); test_count_no_db
TESTS_RUN=$((TESTS_RUN + 1)); test_count_empty_db
TESTS_RUN=$((TESTS_RUN + 1)); test_count_with_candidates
TESTS_RUN=$((TESTS_RUN + 1)); test_count_excludes_shadows
TESTS_RUN=$((TESTS_RUN + 1)); test_count_excludes_expired
TESTS_RUN=$((TESTS_RUN + 1)); test_query_returns_json
TESTS_RUN=$((TESTS_RUN + 1)); test_query_sorts_by_priority
TESTS_RUN=$((TESTS_RUN + 1)); test_query_respects_limit
TESTS_RUN=$((TESTS_RUN + 1)); test_classify_decision
TESTS_RUN=$((TESTS_RUN + 1)); test_classify_pattern
TESTS_RUN=$((TESTS_RUN + 1)); test_classify_observation
TESTS_RUN=$((TESTS_RUN + 1)); test_get_candidate_returns_json
TESTS_RUN=$((TESTS_RUN + 1)); test_get_candidate_missing_id
TESTS_RUN=$((TESTS_RUN + 1)); test_mark_as_promoted_updates_content
TESTS_RUN=$((TESTS_RUN + 1)); test_mark_as_promoted_updates_source

echo ""
echo "Tests run: $TESTS_RUN"
echo "Tests passed: $TESTS_PASSED"

if [[ "$TESTS_PASSED" -eq "$TESTS_RUN" ]]; then
    echo "All tests passed!"
    exit 0
else
    echo "Some tests failed."
    exit 1
fi
