#!/usr/bin/env bash
# Integration tests for graph edge projection (lib/bridge.sh)
#
# Tests edge mapping, shadow lookups, edge creation, and bidirectional handling.
# Uses a temporary directory and database so production data is untouched.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LORE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Setup temp environment
TMPDIR=$(mktemp -d)
export LORE_DATA_DIR="$TMPDIR"
export LORE_DIR
export CLAUDE_MEMORY_DB="$TMPDIR/memory.sqlite"

# Source the code
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
    rm -rf "$TMPDIR"
    mkdir -p "$TMPDIR/graph/data"

    # Create test Engram database with Memory and Edge tables
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

CREATE TABLE Edge(
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    createdAt REAL NOT NULL,
    relation TEXT NOT NULL,
    targetId INTEGER NOT NULL,
    sourceId INTEGER NOT NULL
);
SQL

    # Insert test shadow memories
    sqlite3 "$TMPDIR/memory.sqlite" <<'SQL'
INSERT INTO Memory (importance, accessCount, createdAt, lastAccessedAt, project, embedding, source, topic, expiresAt, content)
VALUES
    (3, 1, 1708000000, 1708000000, 'lore', zeroblob(0), 'lore-bridge', 'lore-decisions', 0, '[lore:dec-abc123] Test decision A'),
    (3, 1, 1708000000, 1708000000, 'lore', zeroblob(0), 'lore-bridge', 'lore-decisions', 0, '[lore:dec-def456] Test decision B'),
    (3, 1, 1708000000, 1708000000, 'lore', zeroblob(0), 'lore-bridge', 'lore-patterns', 0, '[lore:pat-ghi789] Test pattern C');
SQL

    # Create test graph with nodes and edges
    cat > "$TMPDIR/graph/data/graph.json" <<'JSON'
{
  "nodes": {
    "decision-001": {
      "type": "decision",
      "name": "dec-abc123",
      "data": {"journal_id": "dec-abc123"}
    },
    "decision-002": {
      "type": "decision",
      "name": "dec-def456",
      "data": {"journal_id": "dec-def456"}
    },
    "pattern-001": {
      "type": "pattern",
      "name": "pat-ghi789",
      "data": {"pattern_id": "pat-ghi789"}
    },
    "file-001": {
      "type": "file",
      "name": "file-test"
    }
  },
  "edges": [
    {
      "from": "decision-001",
      "to": "decision-002",
      "relation": "relates_to",
      "weight": 1.0,
      "bidirectional": true
    },
    {
      "from": "decision-001",
      "to": "pattern-001",
      "relation": "learned_from",
      "weight": 1.0,
      "bidirectional": false
    },
    {
      "from": "decision-002",
      "to": "file-001",
      "relation": "references",
      "weight": 1.0,
      "bidirectional": false
    }
  ]
}
JSON
}

teardown() {
    rm -rf "$TMPDIR"
}

# --- Test: _map_lore_relation_to_engram ---

test_map_relation_relates_to() {
    echo "Test: map relates_to"
    setup

    source "$LORE_DIR/lib/bridge.sh"
    local result
    result=$(_map_lore_relation_to_engram "relates_to")

    [[ "$result" == "relates_to" ]] && pass "Maps relates_to correctly" || fail "Expected 'relates_to', got '$result'"
    teardown
}

test_map_relation_learned_from() {
    echo "Test: map learned_from to derived_from"
    setup

    source "$LORE_DIR/lib/bridge.sh"
    local result
    result=$(_map_lore_relation_to_engram "learned_from")

    [[ "$result" == "derived_from" ]] && pass "Maps learned_from to derived_from" || fail "Expected 'derived_from', got '$result'"
    teardown
}

test_map_relation_references() {
    echo "Test: map references to relates_to"
    setup

    source "$LORE_DIR/lib/bridge.sh"
    local result
    result=$(_map_lore_relation_to_engram "references")

    [[ "$result" == "relates_to" ]] && pass "Maps references to relates_to" || fail "Expected 'relates_to', got '$result'"
    teardown
}

# --- Test: _get_shadow_memory_id ---

test_get_shadow_memory_id_found() {
    echo "Test: get_shadow_memory_id finds existing shadow"
    setup

    source "$LORE_DIR/lib/bridge.sh"
    local result
    result=$(_get_shadow_memory_id "$TMPDIR/memory.sqlite" "dec-abc123")

    [[ "$result" == "1" ]] && pass "Finds shadow by lore_id" || fail "Expected '1', got '$result'"
    teardown
}

test_get_shadow_memory_id_not_found() {
    echo "Test: get_shadow_memory_id returns empty for missing shadow"
    setup

    source "$LORE_DIR/lib/bridge.sh"
    local result
    result=$(_get_shadow_memory_id "$TMPDIR/memory.sqlite" "dec-notfound")

    [[ -z "$result" ]] && pass "Returns empty for missing shadow" || fail "Expected empty, got '$result'"
    teardown
}

# --- Test: _create_engram_edge ---

test_create_engram_edge_success() {
    echo "Test: create_engram_edge creates edge"
    setup

    source "$LORE_DIR/lib/bridge.sh"
    _create_engram_edge "$TMPDIR/memory.sqlite" 1 2 "relates_to" false

    local count
    count=$(sqlite3 "$TMPDIR/memory.sqlite" "SELECT COUNT(*) FROM Edge WHERE sourceId=1 AND targetId=2 AND relation='relates_to';")

    [[ "$count" == "1" ]] && pass "Creates edge successfully" || fail "Expected 1 edge, got $count"
    teardown
}

test_create_engram_edge_duplicate() {
    echo "Test: create_engram_edge skips duplicate"
    setup

    source "$LORE_DIR/lib/bridge.sh"
    _create_engram_edge "$TMPDIR/memory.sqlite" 1 2 "relates_to" false
    _create_engram_edge "$TMPDIR/memory.sqlite" 1 2 "relates_to" false || true  # Returns 1 when skipping duplicate

    local count
    count=$(sqlite3 "$TMPDIR/memory.sqlite" "SELECT COUNT(*) FROM Edge WHERE sourceId=1 AND targetId=2 AND relation='relates_to';")

    [[ "$count" == "1" ]] && pass "Skips duplicate edge" || fail "Expected 1 edge, got $count"
    teardown
}

test_create_engram_edge_dry_run() {
    echo "Test: create_engram_edge dry-run mode"
    setup

    source "$LORE_DIR/lib/bridge.sh"
    _create_engram_edge "$TMPDIR/memory.sqlite" 1 2 "relates_to" true

    local count
    count=$(sqlite3 "$TMPDIR/memory.sqlite" "SELECT COUNT(*) FROM Edge;")

    [[ "$count" == "0" ]] && pass "Dry-run doesn't create edge" || fail "Expected 0 edges, got $count"
    teardown
}

# --- Test: _sync_graph_edges ---

test_sync_graph_edges_creates_edges() {
    echo "Test: sync_graph_edges creates edges from graph"
    setup

    source "$LORE_DIR/lib/bridge.sh"
    _sync_graph_edges "$TMPDIR/memory.sqlite" false

    local count
    count=$(sqlite3 "$TMPDIR/memory.sqlite" "SELECT COUNT(*) FROM Edge;")

    # Should create 3 edges: 2 from bidirectional relates_to + 1 from learned_from
    # (references edge skipped because target is a file node)
    [[ "$count" == "3" ]] && pass "Creates correct number of edges" || fail "Expected 3 edges, got $count"
    teardown
}

test_sync_graph_edges_skips_file_edges() {
    echo "Test: sync_graph_edges skips edges to file nodes"
    setup

    source "$LORE_DIR/lib/bridge.sh"
    _sync_graph_edges "$TMPDIR/memory.sqlite" false

    # Check that no edges have targetId pointing to a non-shadow memory
    local file_edges
    file_edges=$(sqlite3 "$TMPDIR/memory.sqlite" "SELECT COUNT(*) FROM Edge e WHERE NOT EXISTS (SELECT 1 FROM Memory m WHERE m.id = e.targetId AND m.source = 'lore-bridge');")

    [[ "$file_edges" == "0" ]] && pass "Skips edges to non-shadow nodes" || fail "Found $file_edges edges to non-shadows"
    teardown
}

test_sync_graph_edges_bidirectional() {
    echo "Test: sync_graph_edges creates both directions for bidirectional edges"
    setup

    source "$LORE_DIR/lib/bridge.sh"
    _sync_graph_edges "$TMPDIR/memory.sqlite" false

    # Check for bidirectional relates_to edges (1 <-> 2)
    local forward
    forward=$(sqlite3 "$TMPDIR/memory.sqlite" "SELECT COUNT(*) FROM Edge WHERE sourceId=1 AND targetId=2 AND relation='relates_to';")
    local reverse
    reverse=$(sqlite3 "$TMPDIR/memory.sqlite" "SELECT COUNT(*) FROM Edge WHERE sourceId=2 AND targetId=1 AND relation='relates_to';")

    [[ "$forward" == "1" && "$reverse" == "1" ]] && pass "Creates bidirectional edges" || fail "Expected 1 forward + 1 reverse, got $forward + $reverse"
    teardown
}

test_sync_graph_edges_maps_relations() {
    echo "Test: sync_graph_edges maps Lore relations to Engram relations"
    setup

    source "$LORE_DIR/lib/bridge.sh"
    _sync_graph_edges "$TMPDIR/memory.sqlite" false

    # Check that learned_from was mapped to derived_from
    local derived_count
    derived_count=$(sqlite3 "$TMPDIR/memory.sqlite" "SELECT COUNT(*) FROM Edge WHERE sourceId=1 AND targetId=3 AND relation='derived_from';")

    [[ "$derived_count" == "1" ]] && pass "Maps learned_from to derived_from" || fail "Expected 1 derived_from edge, got $derived_count"
    teardown
}

# --- Run all tests ---

TESTS_RUN=$((TESTS_RUN + 1)); test_map_relation_relates_to
TESTS_RUN=$((TESTS_RUN + 1)); test_map_relation_learned_from
TESTS_RUN=$((TESTS_RUN + 1)); test_map_relation_references
TESTS_RUN=$((TESTS_RUN + 1)); test_get_shadow_memory_id_found
TESTS_RUN=$((TESTS_RUN + 1)); test_get_shadow_memory_id_not_found
TESTS_RUN=$((TESTS_RUN + 1)); test_create_engram_edge_success
TESTS_RUN=$((TESTS_RUN + 1)); test_create_engram_edge_duplicate
TESTS_RUN=$((TESTS_RUN + 1)); test_create_engram_edge_dry_run
TESTS_RUN=$((TESTS_RUN + 1)); test_sync_graph_edges_creates_edges
TESTS_RUN=$((TESTS_RUN + 1)); test_sync_graph_edges_skips_file_edges
TESTS_RUN=$((TESTS_RUN + 1)); test_sync_graph_edges_bidirectional
TESTS_RUN=$((TESTS_RUN + 1)); test_sync_graph_edges_maps_relations

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
