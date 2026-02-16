# Plan: Phase 3 — Graph-Enhanced Recall

Status: Draft
Trigger: Implement after Phase 2 is stable

## Problem

Search returns isolated results. A query for "authentication" returns decisions about auth, but not the patterns derived from those decisions, the files that implement them, or the lessons learned when things went wrong. Related knowledge exists in the graph but doesn't surface.

## Solution

Extend search to follow graph edges. After FTS5/vector search returns initial results, traverse the graph to surface related nodes. Depth is configurable (1-3 hops). Edge types filter relevance.

## Architecture

```
Query
  |
  v
Phase 1+2: FTS5 + Vector Search
  |
  v
Initial Results (10-20 nodes)
  |
  +---> For each result, traverse graph (depth 1-3)
  |
  v
Expanded Results
  |
  +---> Filter by edge type relevance
  +---> Decay score by hop distance
  +---> Deduplicate
  |
  v
Final Ranked Results
```

## Implementation

### 1. Graph traversal during search

```bash
# lib/search-graph.sh
expand_with_graph() {
    local result_ids="$1"
    local depth="${2:-1}"
    local edge_filter="${3:-all}"
    
    local expanded=()
    
    for id in ${result_ids}; do
        # Get related nodes from graph
        local related
        related=$("${LORE_DIR}/graph/graph.sh" related "${id}" --hops "${depth}" --json)
        
        # Filter by edge type if specified
        if [[ "${edge_filter}" != "all" ]]; then
            related=$(echo "${related}" | jq --arg filter "${edge_filter}" \
                '[.[] | select(.edge_type | test($filter))]')
        fi
        
        expanded+=("${related}")
    done
    
    echo "${expanded[@]}" | jq -s 'add | unique_by(.id)'
}
```

### 2. Score decay by hop distance

Nodes found via graph traversal score lower than direct matches:

```sql
-- In the ranking query
SELECT
    id,
    base_score * POWER(0.7, hop_distance) as decayed_score
FROM expanded_results
ORDER BY decayed_score DESC;
```

| Hops | Decay Factor | Example Score |
| ---- | ------------ | ------------- |
| 0    | 1.0          | 10.0          |
| 1    | 0.7          | 7.0           |
| 2    | 0.49         | 4.9           |
| 3    | 0.343        | 3.43          |

### 3. Edge type relevance weights

Not all edges are equally relevant. Weight by edge type:

```bash
declare -A EDGE_WEIGHTS=(
    ["implements"]=1.0      # Code implementing concept = highly relevant
    ["derived_from"]=0.9    # Pattern from decision = very relevant
    ["relates_to"]=0.7      # General relation = relevant
    ["depends_on"]=0.6      # Dependency = somewhat relevant
    ["supersedes"]=0.5      # Old decision = less relevant
    ["contradicts"]=0.8     # Conflict = important to surface
    ["part_of"]=0.6         # Parent concept = context
    ["summarized_by"]=0.4   # Summary = already captured
)
```

### 4. Search command with graph depth

```bash
# lore.sh search (modified)
search() {
    local query="$1"
    local graph_depth="${GRAPH_DEPTH:-0}"  # Default: no graph expansion
    
    # Phase 1+2: FTS5 + vector search
    local initial_results
    initial_results=$(search_ranked "${query}")
    
    if [[ "${graph_depth}" -gt 0 ]]; then
        # Phase 3: Graph expansion
        local result_ids
        result_ids=$(echo "${initial_results}" | jq -r '.[].id')
        
        local expanded
        expanded=$(expand_with_graph "${result_ids}" "${graph_depth}")
        
        # Merge and re-rank
        initial_results=$(merge_results "${initial_results}" "${expanded}")
    fi
    
    echo "${initial_results}"
}
```

### 5. CLI interface

```bash
# Search with graph expansion
lore search "authentication" --graph-depth 2

# Search with edge type filter
lore search "authentication" --graph-depth 1 --edges "implements,derived_from"

# Default (no expansion)
lore search "authentication"
```

## Example Expansion

Query: "JWT tokens"

**Direct matches (depth 0):**
- `decision-abc`: "Use JWT for stateless auth"

**Depth 1 expansion:**
- `pattern-def`: "Validate JWT signature before claims" (derived_from decision-abc)
- `file-auth.py`: implements decision-abc
- `lesson-ghi`: "JWT expiry must be short" (learned_from decision-abc)

**Depth 2 expansion:**
- `concept-auth`: authentication (file-auth.py implements this)
- `session-xyz`: where lesson-ghi was learned

## Performance Considerations

1. **Cache graph traversals** — Same node traversed multiple times should hit cache
2. **Limit expansion** — Cap at 50 expanded nodes regardless of depth
3. **Lazy loading** — Only fetch full node content for top-N results
4. **Index graph edges** — Add SQLite index on edges for fast traversal

```sql
-- Add to search.db
CREATE TABLE graph_edges (
    from_id TEXT,
    to_id TEXT,
    relation TEXT,
    weight REAL,
    PRIMARY KEY (from_id, to_id, relation)
);
CREATE INDEX idx_edges_from ON graph_edges(from_id);
CREATE INDEX idx_edges_to ON graph_edges(to_id);
```

## Verification

```bash
# Ensure graph has edges
graph.sh stats

# Search without expansion
lore search "authentication"

# Search with 1-hop expansion
lore search "authentication" --graph-depth 1

# Compare result counts
lore search "authentication" | jq 'length'
lore search "authentication" --graph-depth 2 | jq 'length'
```

## Rollback

```bash
# Disable graph expansion
export LORE_GRAPH_DEPTH=0

# Or in config
echo "graph_depth=0" >> "${LORE_DIR}/.config"
```
