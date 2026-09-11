#!/usr/bin/env bash
# Regression test for concurrent `graph.sh add` corrupting graph.json
#
# graph/lib/nodes.sh's add_node() writes through a fixed, shared
# "${GRAPH_FILE}.tmp" path. Concurrent `graph.sh add` invocations can
# interleave on that shared tmp file: one writer's mv can rename away the
# tmp file another writer is about to jq into or mv from, truncating
# graph.json to zero bytes and destroying every prior node and edge.
#
# This spawns N concurrent `graph.sh add` processes against one graph.json
# and asserts the result is valid JSON containing exactly N nodes.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/fixture.sh"
LORE_DIR_SRC="$(cd "$SCRIPT_DIR/.." && pwd)"

PASS=0
FAIL=0
FIXTURE_DIR=""

pass() {
    echo "✓ $1"
    PASS=$((PASS + 1))
}

fail() {
    echo "✗ $1"
    FAIL=$((FAIL + 1))
}

setup() {
    FIXTURE_DIR=$(mktemp -d)
    mkdir -p "$FIXTURE_DIR/graph" "$FIXTURE_DIR/lib" "$FIXTURE_DIR/journal"

    cp -R "$LORE_DIR_SRC/graph/"* "$FIXTURE_DIR/graph/"
    cp -R "$LORE_DIR_SRC/lib/"* "$FIXTURE_DIR/lib/"
    cp -R "$LORE_DIR_SRC/journal/"* "$FIXTURE_DIR/journal/"

    mkdir -p "$FIXTURE_DIR/graph/data"
    echo '{"nodes":{},"edges":[]}' > "$FIXTURE_DIR/graph/data/graph.json"
}

teardown() {
    remove_fixture "$FIXTURE_DIR"
}

trap teardown EXIT

setup

export LORE_DIR="$FIXTURE_DIR"
export LORE_DATA_DIR="$FIXTURE_DIR"
export LORE_SEARCH_DB="$FIXTURE_DIR/search.db"

GRAPH_JSON="$FIXTURE_DIR/graph/data/graph.json"
N=40

echo "Test: $N concurrent 'graph.sh add' calls against one graph.json"

pids=()
for i in $(seq 1 "$N"); do
    "$FIXTURE_DIR/graph/graph.sh" add concept "race-node-$i" > /dev/null 2>>"$FIXTURE_DIR/add.err" &
    pids+=($!)
done

for pid in "${pids[@]}"; do
    wait "$pid" || true
done

if jq -e . "$GRAPH_JSON" > /dev/null 2>&1; then
    pass "graph.json is valid JSON after $N concurrent adds"
else
    fail "graph.json is not valid JSON after $N concurrent adds (size: $(wc -c < "$GRAPH_JSON" 2>/dev/null || echo '?'))"
fi

node_count=$(jq '.nodes | length' "$GRAPH_JSON" 2>/dev/null || echo 0)
if [[ "$node_count" -eq "$N" ]]; then
    pass "graph.json contains exactly $N nodes"
else
    fail "graph.json contains $node_count nodes, expected $N"
fi

echo
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
