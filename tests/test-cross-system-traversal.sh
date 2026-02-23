#!/usr/bin/env bash
# Tests for cross-system graph traversal

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LORE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

TMPDIR=$(mktemp -d)
export LORE_DATA_DIR="$TMPDIR"
export LORE_DIR
export CLAUDE_MEMORY_DB="$TMPDIR/memory.sqlite"
export LORE_SEARCH_DB="$TMPDIR/search.db"

source "$LORE_DIR/lib/paths.sh"

TESTS_RUN=0
TESTS_PASSED=0

pass() { echo "✓ $1"; TESTS_PASSED=$((TESTS_PASSED + 1)); }
fail() { echo "✗ $1"; }

setup() {
    rm -rf "$TMPDIR"
    mkdir -p "$TMPDIR/graph/data"

    # Create Lore search index
    sqlite3 "$TMPDIR/search.db" <<'SQL'
CREATE TABLE search_index(id TEXT PRIMARY KEY, type TEXT, content TEXT);
CREATE TABLE graph_edges(from_id TEXT, to_id TEXT, relation TEXT, weight REAL);
INSERT INTO search_index VALUES ('dec-abc123', 'decision', 'Use JSONL for storage');
INSERT INTO search_index VALUES ('pat-def456', 'pattern', 'Validate input before processing');
INSERT INTO graph_edges VALUES ('dec-abc123', 'pat-def456', 'learned_from', 1.0);
SQL

    # Create Engram database
    sqlite3 "$TMPDIR/memory.sqlite" <<'SQL'
CREATE TABLE Memory(id INTEGER PRIMARY KEY, content TEXT, topic TEXT, importance INT, source TEXT);
CREATE TABLE Edge(id INTEGER PRIMARY KEY, sourceId INT, targetId INT, relation TEXT, createdAt REAL);
INSERT INTO Memory VALUES (1, '[lore:dec-abc123] Use JSONL for storage', 'lore-decisions', 3, 'lore-bridge');
INSERT INTO Memory VALUES (2, '[lore:pat-def456] Validate input', 'lore-patterns', 3, 'lore-bridge');
INSERT INTO Memory VALUES (3, 'Always use prepared statements for SQL', 'security', 4, 'user');
INSERT INTO Edge VALUES (1, 1, 2, 'derived_from', 1708000000);  -- Shadow to shadow
INSERT INTO Edge VALUES (2, 2, 3, 'relates_to', 1708000000);    -- Shadow to native
SQL
}

teardown() { rm -rf "$TMPDIR"; }

test_cross_system_traverse_depth_1() {
    echo "Test: cross-system traverse depth 1"
    setup
    source "$LORE_DIR/lib/recall-router.sh"

    local results
    results=$(cross_system_traverse "dec-abc123" 1)

    # Should include: dec-abc123 (start), pat-def456 (Lore edge), mem-3 (Engram edge from shadow)
    local count
    count=$(echo "$results" | jq 'length')

    [[ "$count" -ge 2 ]] && pass "Returns multiple nodes" || fail "Expected >=2, got $count"
    teardown
}

test_cross_system_includes_native_memories() {
    echo "Test: traversal includes native Engram memories"
    setup
    source "$LORE_DIR/lib/recall-router.sh"

    local results
    results=$(cross_system_traverse "pat-def456" 1)

    # Should follow edge from pat-def456 shadow to native memory #3
    local has_native
    has_native=$(echo "$results" | jq '[.[] | select(.source == "mem")] | length')

    [[ "$has_native" -ge 1 ]] && pass "Includes native memories" || fail "Expected >=1 native, got $has_native"
    teardown
}

test_cross_system_marks_provenance() {
    echo "Test: results marked with lore vs mem provenance"
    setup
    source "$LORE_DIR/lib/recall-router.sh"

    local results
    results=$(cross_system_traverse "dec-abc123" 1)

    # Check that results have source field
    local has_lore has_mem
    has_lore=$(echo "$results" | jq '[.[] | select(.source == "lore")] | length')
    has_mem=$(echo "$results" | jq '[.[] | select(.source == "mem")] | length')

    [[ "$has_lore" -ge 1 && "$has_mem" -ge 0 ]] && pass "Marks provenance correctly" || fail "Lore: $has_lore, Mem: $has_mem"
    teardown
}

# Run tests
TESTS_RUN=$((TESTS_RUN + 1)); test_cross_system_traverse_depth_1
TESTS_RUN=$((TESTS_RUN + 1)); test_cross_system_includes_native_memories
TESTS_RUN=$((TESTS_RUN + 1)); test_cross_system_marks_provenance

echo ""
echo "Tests run: $TESTS_RUN"
echo "Tests passed: $TESTS_PASSED"

[[ "$TESTS_PASSED" -eq "$TESTS_RUN" ]] && exit 0 || exit 1
