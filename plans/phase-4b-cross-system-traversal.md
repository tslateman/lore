# Phase 4b: Cross-System Graph Traversal

Extend `lore recall --graph-depth N` to follow edges from Lore into Engram, enabling unified knowledge graph traversal across both systems.

## Context

**Current state:**

- `lore recall --graph-depth N` traverses Lore's graph via `search.db:graph_edges`
- Python BFS in `lib/search-index.sh:graph_traverse()` (lines 551-630)
- Returns nodes within N hops, scored by distance decay
- No awareness of Engram edges or cross-system relationships

**Phase 4a completed:**

- Lore graph edges projected to Engram `Edge` table (28 edges in production)
- Shadows have both Lore ID (`[lore:dec-abc123]`) and Engram Memory.id
- Relation mapping: `learned_from→derived_from`, `references→relates_to`

**Existing provenance system:**

- `lib/recall-router.sh` marks results `(lore)` or `(mem)` in compact mode
- `routed_recall()` queries both systems and deduplicates

**Graph databases:**

- Lore: `search.db` with `graph_edges(from_id, to_id, relation, weight)`
- Engram: `~/.claude/memory.sqlite` with `Edge(sourceId, targetId, relation, createdAt)`

**Test infrastructure:**

- `tests/test-graph-edge-projection.sh` (12 tests)
- `tests/test-recall-router.sh` (33 tests)
- Total: 200 tests passing

## What to Do

### 1. Add cross-system traversal function to `lib/recall-router.sh`

After line 235 (end of `routed_recall`), add:

```bash
# --- Cross-system graph traversal ---

# Query Engram edges from a shadow Memory.id
# Returns tab-separated: target_id, relation, content_preview
query_engram_edges() {
    local memory_id="$1"

    [[ ! -f "$CLAUDE_MEMORY_DB" ]] && return 0

    sqlite3 -separator $'\t' "$CLAUDE_MEMORY_DB" <<SQL
SELECT e.targetId, e.relation, substr(m.content, 1, 80)
FROM Edge e
JOIN Memory m ON e.targetId = m.id
WHERE e.sourceId = $memory_id
  AND m.content NOT LIKE '[lore:%'  -- Only native Engram memories
LIMIT 20;
SQL
}

# Get Engram Memory.id for a Lore record ID
get_engram_memory_id() {
    local lore_id="$1"

    [[ ! -f "$CLAUDE_MEMORY_DB" ]] && return 0

    sqlite3 "$CLAUDE_MEMORY_DB" "SELECT id FROM Memory WHERE content LIKE '[lore:${lore_id}]%' LIMIT 1;" 2>/dev/null || echo ""
}

# Traverse graph across Lore and Engram
# Returns JSON array of nodes with provenance
cross_system_traverse() {
    local start_lore_ids="$1"  # Comma-separated Lore record IDs (dec-xxx, pat-xxx)
    local max_depth="${2:-1}"
    local db="${3:-$LORE_SEARCH_DB}"

    python3 - "$db" "$CLAUDE_MEMORY_DB" "$start_lore_ids" "$max_depth" <<'PYTHON'
import sys
import sqlite3
import json
from collections import deque

lore_db = sys.argv[1]
engram_db = sys.argv[2]
start_ids = sys.argv[3].split(',') if sys.argv[3] else []
max_depth = int(sys.argv[4]) if len(sys.argv) > 4 else 1

# Connect to both databases
lore_conn = sqlite3.connect(lore_db)
engram_conn = sqlite3.connect(engram_db)
lore_cur = lore_conn.cursor()
engram_cur = engram_conn.cursor()

# Track visited nodes: {id: (depth, source, type)}
visited = {}
queue = deque()

# Seed with start nodes
for start_id in start_ids:
    start_id = start_id.strip()
    if start_id:
        visited[start_id] = (0, 'lore', 'start')
        queue.append((start_id, 0, 'lore'))

results = []

while queue:
    current_id, current_depth, current_source = queue.popleft()

    if current_depth >= max_depth:
        continue

    # Get node data
    if current_source == 'lore':
        # Query Lore's search index for node
        lore_cur.execute("SELECT id, type, content FROM search_index WHERE id = ?", (current_id,))
        row = lore_cur.fetchone()
        if row:
            results.append({
                'id': row[0],
                'type': row[1],
                'content': row[2],
                'depth': current_depth,
                'source': 'lore'
            })

        # Find Lore edges
        lore_cur.execute("SELECT to_id, relation FROM graph_edges WHERE from_id = ?", (current_id,))
        for to_id, relation in lore_cur.fetchall():
            if to_id not in visited:
                visited[to_id] = (current_depth + 1, 'lore', relation)
                queue.append((to_id, current_depth + 1, 'lore'))

        # Check if this is a shadow - if so, follow into Engram
        # Convert Lore ID (e.g., "dec-abc123") to Engram Memory.id
        engram_cur.execute("SELECT id FROM Memory WHERE content LIKE ? LIMIT 1", (f'[lore:{current_id}]%',))
        shadow_row = engram_cur.fetchone()
        if shadow_row:
            shadow_mem_id = shadow_row[0]

            # Query Engram edges from this shadow
            engram_cur.execute("""
                SELECT e.targetId, e.relation, m.content, m.topic
                FROM Edge e
                JOIN Memory m ON e.targetId = m.id
                WHERE e.sourceId = ? AND m.content NOT LIKE '[lore:%'
                LIMIT 20
            """, (shadow_mem_id,))

            for target_id, relation, content, topic in engram_cur.fetchall():
                engram_key = f'mem-{target_id}'
                if engram_key not in visited:
                    visited[engram_key] = (current_depth + 1, 'mem', relation)
                    queue.append((engram_key, current_depth + 1, 'mem'))

    elif current_source == 'mem':
        # Extract Memory.id from key
        mem_id = int(current_id.split('-')[1])

        # Query Engram memory
        engram_cur.execute("SELECT content, topic, importance FROM Memory WHERE id = ?", (mem_id,))
        row = engram_cur.fetchone()
        if row:
            results.append({
                'id': current_id,
                'type': 'memory',
                'content': row[0][:200],  # Preview
                'topic': row[1],
                'importance': row[2],
                'depth': current_depth,
                'source': 'mem'
            })

        # Follow Engram edges (only to non-shadows)
        engram_cur.execute("""
            SELECT e.targetId, e.relation
            FROM Edge e
            JOIN Memory m ON e.targetId = m.id
            WHERE e.sourceId = ? AND m.content NOT LIKE '[lore:%'
            LIMIT 10
        """, (mem_id,))

        for target_id, relation in engram_cur.fetchall():
            engram_key = f'mem-{target_id}'
            if engram_key not in visited:
                visited[engram_key] = (current_depth + 1, 'mem', relation)
                queue.append((engram_key, current_depth + 1, 'mem'))

# Output as JSON
print(json.dumps(results, indent=2))

lore_conn.close()
engram_conn.close()
PYTHON
}
```

### 2. Extend `routed_recall` to support `--graph-depth`

In `lib/recall-router.sh`, modify `routed_recall` function (around line 169) to accept graph_depth parameter:

```bash
# Main entry point for routed recall
# Usage: routed_recall "$query" [compact] [limit] [graph_depth]
routed_recall() {
    local query="$1"
    local compact="${2:-false}"
    local limit="${3:-10}"
    local graph_depth="${4:-0}"  # NEW: graph traversal depth

    # ... existing classification logic ...

    case "$class" in
        lore-first)
            _route_lore_first "$query" "$compact" "$limit" "$graph_depth"  # Pass depth
            ;;
        memory-first)
            _route_memory_first "$query" "$compact" "$limit" "$graph_depth"  # Pass depth
            ;;
        both)
            _route_both "$query" "$compact" "$limit" "$graph_depth"  # Pass depth
            ;;
    esac
}
```

### 3. Update routing functions to handle graph traversal

Modify `_route_lore_first` (and similarly for `_route_memory_first` and `_route_both`):

```bash
_route_lore_first() {
    local query="$1" compact="$2" limit="$3" graph_depth="${4:-0}"

    # Query Lore
    local lore_results
    lore_results=$("$LORE_DIR/lore.sh" search "$query" 2>/dev/null | head -"$limit") || true

    # If graph traversal requested and we have results, expand
    if [[ "$graph_depth" -gt 0 && -n "$lore_results" ]]; then
        # Extract Lore IDs from results
        local lore_ids
        lore_ids=$(echo "$lore_results" | grep -oE '(dec|pat|obs)-[a-f0-9]+' | head -5 | tr '\n' ',' | sed 's/,$//')

        if [[ -n "$lore_ids" ]]; then
            # Cross-system traverse
            local expanded
            expanded=$(cross_system_traverse "$lore_ids" "$graph_depth")

            # Format and emit results
            echo "$expanded" | jq -r '.[] | select(.source == "lore") | "\(.id): \(.content)"' | while read -r line; do
                _emit_lore_line "$line" "" "" "" "" "$compact"
            done

            echo "$expanded" | jq -r '.[] | select(.source == "mem") | "\(.id): \(.content)"' | while read -r line; do
                _emit_mem_line "$line" "" "" "" "" "$compact"
            done
            return 0
        fi
    fi

    # ... rest of existing logic ...
}
```

### 4. Wire `--graph-depth` through `lore recall --routed`

In `lore.sh`, modify `cmd_recall` routed case (around line 990):

```bash
routed)
    if [[ -z "$query" ]]; then
        echo -e "${RED}Error: Query required for --routed${NC}" >&2
        echo "Usage: lore recall --routed <query> [--compact] [--graph-depth N]" >&2
        return 1
    fi

    # Extract graph_depth from pass_through if present
    local graph_depth=0
    for i in "${!pass_through[@]}"; do
        if [[ "${pass_through[$i]}" == "--graph-depth" ]]; then
            graph_depth="${pass_through[$i+1]}"
            break
        fi
    done

    source "$LORE_DIR/lib/recall-router.sh"
    routed_recall "$query" "$compact" 10 "$graph_depth"
    ;;
```

### 5. Add tests for cross-system traversal

Create `tests/test-cross-system-traversal.sh`:

```bash
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
```

### 6. Add test to Makefile

After line 53 in `Makefile`:

```makefile
	@bash tests/test-graph-edge-projection.sh
	@bash tests/test-cross-system-traversal.sh
```

### 7. Update initiative document

In `plans/initiative-lore-claude-memory-integration.md`, update "Remaining" section:

```markdown
**Phase 4b (complete):** Cross-system graph traversal via `lib/recall-router.sh`.
`lore recall --routed --graph-depth N` follows edges from Lore into Engram.
When BFS reaches a shadow, continues into Engram's graph to native memories.
Python implementation handles two databases with unified BFS. Results marked
with `(lore)` or `(mem)` provenance. 3 integration tests.

**Remaining:**

- Phase 3c: Reinforcement signal (log when Lore shadows accessed via Engram)
- Phase 4c: Concept promotion from Engram clusters
```

## What NOT to Do

**Don't modify existing `graph_traverse` in `search-index.sh`:**

- That function serves `lore search --graph-depth` (Lore-only)
- Cross-system traversal is specific to `--routed` mode
- Keep concerns separated

**Don't query all Engram edges:**

- Limit to 10-20 edges per node to prevent explosion
- Only follow edges from shadows, not all Lore nodes

**Don't create a unified graph table:**

- Merging Edge tables would require ongoing sync
- Query-time join is simpler and more flexible

**Don't expose raw Engram Memory.ids to users:**

- Use `mem-{id}` keys internally for deduplication
- Display content and topic, not database IDs

**Don't traverse indefinitely:**

- Respect max_depth parameter strictly
- Engram graph can be densely connected

## Acceptance Criteria

- [ ] `lore recall --routed "query" --graph-depth 1` follows edges into Engram
- [ ] Results include both Lore nodes and native Engram memories
- [ ] Provenance marked: `(lore)` for Lore nodes, `(mem)` for Engram nodes
- [ ] Depth 0: No traversal (current behavior preserved)
- [ ] Depth 1: Direct neighbors from both graphs
- [ ] Depth 2: Two hops across both systems
- [ ] Shadow-to-shadow edges don't duplicate (edge between two Lore records only traverses Lore graph once)
- [ ] 3 tests in `test-cross-system-traversal.sh` pass
- [ ] All 203 tests pass (200 existing + 3 new)
- [ ] `lore search --graph-depth N` unchanged (Lore-only traversal still works)
- [ ] Initiative document updated with Phase 4b complete
