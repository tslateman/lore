# Plan: Retrieval Layer for Lore

Status: Revised (2026-02-15)

## Current State

`hooks/inject-context.sh` handles auto-context injection via
`UserPromptSubmit`. It greps patterns, journal, and transfer data, scoped by
project (from `cwd`) and prompt keywords. Runs in ~220ms, budget-capped at
1,500 chars. Registered in `~/.claude/settings.json`.

This plan covers **ranked search** for `lore search`.

## Problem

Lore's `lore search` is keyword grep over flat files. Two failure modes as
the corpus grows:

1. **Missed relevance.** "retry logic" won't find "error handling."
2. **Noise at scale.** Broad queries return too many results with no ranking.

## mnemo Evaluation (2026-02-15)

Tested [mnemo](https://github.com/Pilan-AI/mnemo) as a ready-made solution.

**What works:**

- BM25 ranking + temporal decay
- Fast FTS5 indexing
- Cross-platform Go binary

**What doesn't:**

- No custom path indexing (only hardcoded AI tool locations)
- Indexes first message per session only (not full conversation)
- Synthetic session workaround (convert Lore data to fake Claude Code JSONL)
  indexes successfully but search only finds first record per file

**Verdict:** mnemo's ideas are sound but the implementation doesn't fit Lore's
use case. Adapt the ranking/indexing concepts, skip the tool.

## ClaudeMemory Inspiration

Borrow these concepts from [ClaudeMemory](https://github.com/jsflax/ClaudeMemory):

- **Hybrid FTS5 + vector search** — Phase 1 uses FTS5 (BM25), Phase 2 adds
  vector embeddings when FTS5 demonstrably fails (Rule of Three)
- **Reinforcement scoring** — Blend frequency, importance, and recency
  signals with BM25 base score
- **Project scoping** — Soft ranking boost for same-project results, but
  cross-project results still surface if relevant
- **Conflict detection** — Block near-duplicate patterns/decisions with
  similarity check before write
- **Knowledge graph integration** — Lore's `graph/` component already has
  typed edges (`relates_to`, `depends_on`, `implements`, etc.). Extend with
  ClaudeMemory's semantic edge types (`contradicts`, `supersedes`,
  `derived_from`, `part_of`, `summarized_by`)

## Decision: Native hybrid search for Lore

Build SQLite + FTS5 index with vector embeddings when needed. Leverage Lore's
existing graph for relationship queries.

```
Phase 1: FTS5 + reinforcement scoring (implement now)
  Full-text index with BM25 ranking, temporal decay, project boosting.
  Track access frequency for reinforcement.
  Conflict detection for duplicate prevention.

Phase 2: Add vector embeddings (implement when FTS5 fails 3x)
  Hybrid FTS5 + cosine similarity search.
  Use sqlite-vec or ClaudeMemory's CoreML embeddings.

Phase 3: Graph-enhanced recall (implement after Phase 2)
  Follow graph edges during search (depth 1-3).
  Surface related decisions/patterns via typed relationships.
```

## Architecture

```
Lore data files (source of truth)
+------------------------+
| journal/decisions.jsonl|--+
| patterns/patterns.yaml |--+
| transfer/sessions/     |--+
| graph/data/graph.json  |--+
+------------------------+
          |
          | lib/search-index.sh (build)
          v
  +----------------------+
  | ~/.lore/search.db    |
  | Tables:              |
  |  - decisions (FTS5)  |
  |  - patterns (FTS5)   |
  |  - transfers (FTS5)  |
  |  - access_log        |  # For reinforcement scoring
  |  - embeddings (vec)  |  # Phase 2
  +----------------------+
          |
          | lore search (query)
          v
  1. FTS5 match (BM25)
  2. Project boost
  3. Reinforcement (frequency + recency)
  4. Graph traversal (Phase 3)
          |
          v
     ranked results

Auto-context injection (separate concern):
  UserPromptSubmit --> hooks/inject-context.sh
  Uses grep, not FTS5. Fast, simple, project-scoped.
```

## Implementation

### Phase 1: FTS5 + Reinforcement Scoring

**File:** `lib/search-index.sh`

Creates `~/.lore/search.db` with FTS5 tables and access tracking:

```sql
-- FTS5 tables (same as before)
CREATE VIRTUAL TABLE decisions USING fts5(
    id UNINDEXED,
    decision,
    rationale,
    tags,
    timestamp UNINDEXED,
    project UNINDEXED,
    importance UNINDEXED  -- 1-5 scale from pattern confidence or explicit
);

CREATE VIRTUAL TABLE patterns USING fts5(
    id UNINDEXED,
    name,
    context,
    problem,
    solution,
    confidence UNINDEXED,
    timestamp UNINDEXED
);

CREATE VIRTUAL TABLE transfers USING fts5(
    session_id UNINDEXED,
    project UNINDEXED,
    handoff,
    timestamp UNINDEXED
);

-- Access log for reinforcement scoring
CREATE TABLE access_log (
    record_type TEXT NOT NULL,  -- 'decision', 'pattern', 'transfer'
    record_id TEXT NOT NULL,
    accessed_at TEXT NOT NULL,
    PRIMARY KEY (record_type, record_id, accessed_at)
);

-- Similarity cache for conflict detection
CREATE TABLE similarity_cache (
    record_type TEXT NOT NULL,
    record_id TEXT PRIMARY KEY,
    content_hash TEXT NOT NULL,
    created_at TEXT NOT NULL
);
```

**Ranking query with reinforcement:**

```sql
WITH ranked AS (
    SELECT
        'decision' as type,
        id,
        decision as content,
        project,
        timestamp,
        importance,
        rank * -1 as bm25_score
    FROM decisions WHERE decisions MATCH ?
    UNION ALL
    SELECT
        'pattern' as type,
        id,
        name || ': ' || solution as content,
        'lore' as project,
        timestamp,
        CAST(confidence * 5 AS INT) as importance,  -- Map 0-1 to 1-5
        rank * -1 as bm25_score
    FROM patterns WHERE patterns MATCH ?
    UNION ALL
    SELECT
        'transfer' as type,
        session_id as id,
        handoff as content,
        project,
        timestamp,
        3 as importance,  -- Default medium importance
        rank * -1 as bm25_score
    FROM transfers WHERE transfers MATCH ?
),
frequency AS (
    SELECT
        record_type,
        record_id,
        COUNT(*) as access_count,
        MAX(accessed_at) as last_access
    FROM access_log
    GROUP BY record_type, record_id
)
SELECT
    r.type,
    r.content,
    r.project,
    r.timestamp,
    -- Temporal decay
    (julianday('now') - julianday(r.timestamp)) as days_old,
    -- Frequency boost (log-scaled, up to 15%)
    COALESCE(1.0 + (LOG(1 + f.access_count) * 0.15), 1.0) as freq_boost,
    -- Importance boost (up to 20%)
    1.0 + (r.importance / 5.0 * 0.2) as importance_boost,
    -- Recency boost (exponential decay from last access, up to 10%)
    COALESCE(1.0 + (0.1 * EXP(-(julianday('now') - julianday(f.last_access)) / 30)), 1.0) as recency_boost,
    -- Project boost (same-project = 1.5x, else 1.0x)
    CASE WHEN r.project = ? THEN 1.5 ELSE 1.0 END as project_boost,
    -- Final score
    r.bm25_score
        * (1.0 / (1 + days_old / 30))  -- Temporal decay
        * COALESCE(1.0 + (LOG(1 + f.access_count) * 0.15), 1.0)  -- Frequency
        * (1.0 + (r.importance / 5.0 * 0.2))  -- Importance
        * COALESCE(1.0 + (0.1 * EXP(-(julianday('now') - julianday(f.last_access)) / 30)), 1.0)  -- Recency
        * CASE WHEN r.project = ? THEN 1.5 ELSE 1.0 END  -- Project
        as final_score
FROM ranked r
LEFT JOIN frequency f ON r.type = f.record_type AND r.id = f.record_id
ORDER BY final_score DESC
LIMIT 10;
```

**Conflict detection:**

Before writing a new pattern or decision, check for near-duplicates:

```bash
lore_check_duplicate() {
    local type="$1"
    local content="$2"
    local threshold=0.8  # 80% similarity = likely duplicate

    # Simple word-based Jaccard similarity
    sqlite3 "$DB" <<SQL
SELECT id, content
FROM (
    SELECT id, decision as content FROM decisions WHERE type = 'decision'
    UNION ALL
    SELECT id, name || ' ' || solution as content FROM patterns WHERE type = 'pattern'
)
WHERE type = '$type'
  AND (LENGTH(content) - LENGTH(REPLACE(LOWER(content), LOWER('$content'), '')))
      / CAST(LENGTH(content) AS FLOAT) > $threshold;
SQL
}
```

If a duplicate is found, warn and require `--force` to proceed.

**Access logging:**

After `lore search` returns results, log the IDs:

```bash
log_access() {
    local type="$1"
    local id="$2"
    sqlite3 "$DB" "INSERT INTO access_log VALUES ('$type', '$id', datetime('now'))"
}
```

### Phase 2: Add Vector Embeddings

**Trigger:** Three logged semantic search failures in
`failures/data/search-failures.jsonl` with `failure_type: semantic_miss`.

**Options:**

1. **sqlite-vec** (cross-platform, BYO embeddings via Anthropic API)
2. **ClaudeMemory** (macOS-only, CoreML MiniLM-L6 embeddings)

**Implementation:**

```sql
-- Add to search.db
CREATE VIRTUAL TABLE IF NOT EXISTS embeddings USING vec0(
    record_type TEXT,
    record_id TEXT,
    embedding FLOAT[384]  -- MiniLM-L6 dimension
);
```

Hybrid query becomes FTS5 UNION vector cosine similarity, sorted by blended
score.

### Phase 3: Graph-Enhanced Recall

**File:** `lib/graph-traverse.sh`

After FTS5/vector results, optionally traverse graph edges to surface related
knowledge:

```bash
lore_graph_traverse() {
    local result_id="$1"
    local depth="${2:-1}"
    local max_depth=3

    [[ $depth -gt $max_depth ]] && return

    # Query graph.json for edges from this result
    jq -r --arg id "$result_id" \
        '.edges[] | select(.from == $id) | .to + " " + .relation' \
        graph/data/graph.json | \
    while read -r to_id relation; do
        # Fetch content of related node
        # Recurse if depth allows
        lore_graph_traverse "$to_id" $((depth + 1))
    done
}
```

Results include graph context: `[pattern] X → contradicts → [decision] Y`.

**Extend graph edge types:**

Add ClaudeMemory's semantic edges to Lore's graph:

| Edge Type       | Meaning                                  |
| --------------- | ---------------------------------------- |
| `contradicts`   | Pattern/decision conflicts with another  |
| `supersedes`    | Newer decision replaces older one        |
| `derived_from`  | Pattern learned from a specific decision |
| `part_of`       | Component of a larger concept/initiative |
| `summarized_by` | Consolidated into a higher-level summary |
| `relates_to`    | (existing) General semantic relationship |
| `depends_on`    | (existing) Project dependency            |
| `implements`    | (existing) Code implements concept       |
| `learned_from`  | (existing) Lesson from session           |
| `affects`       | (existing) Decision impacts concept      |
| `produces`      | (existing) Project produces output       |

Write helpers: `lore graph connect <from> <to> <relation>`,
`lore graph disconnect <from> <to>`.

## Complexity Budget

- **Phase 1**: ~250 lines
  - search-index.sh: ~120 lines (FTS5 + access_log + similarity_cache)
  - search query: ~80 lines (reinforcement scoring)
  - conflict detection: ~50 lines
- **Phase 2**: ~100 lines (vector table + hybrid query)
- **Phase 3**: ~80 lines (graph traversal)
- **Total**: ~430 lines (Phase 1 only: ~250 lines)

## What NOT to Build

- **mnemo integration.** Tested, doesn't fit. Move on.
- **Real-time index updates.** Rebuild on-demand or before search.
- **Background indexing daemon.** On-demand is fine.
- **Episodic memory.** Lore's `transfer/` handles session continuity differently.
- **Task continuity.** Lore's `intent/` owns goals/missions, not the search layer.
- **Clustering/consolidation.** Defer until pattern corpus grows large enough to need it.

## Verification

```bash
# Phase 1: Build index
bash lib/search-index.sh

# Test basic search
lore search "bash arithmetic"
# Should return:
# [pattern] Safe bash arithmetic (score: 12.4, proj: lore, 2026-02-10)

# Test project boosting
cd ~/dev/flow && lore search "state machine"
# flow-tagged decisions should rank higher

# Test conflict detection
lore learn "Safe bash arithmetic" --solution "Use x=\$((x + 1))"
# Should warn: "Similar pattern exists (id: pat-123). Use --force to override."

# Test reinforcement
lore search "JSONL" && lore search "JSONL"
# Second search should rank frequently accessed results higher

# Phase 2: Vector search (after trigger)
lore search "error handling"
# Should find "retry logic" pattern via cosine similarity

# Phase 3: Graph traversal
lore search "authentication" --graph-depth 2
# Should surface JWT concept → implements → auth.py file
```

## Risks

| Risk                            | Likelihood | Mitigation                            |
| ------------------------------- | ---------- | ------------------------------------- |
| FTS5 ranking insufficient       | Low        | Phase 2 adds vector search            |
| Reinforcement scoring too noisy | Medium     | Tune weights; log boosts for analysis |
| Index rebuild too slow          | Low        | Current: 47 decisions, 13 patterns    |
| Conflict detection false pos    | Medium     | Adjustable threshold + `--force` flag |
| Graph traversal too expensive   | Low        | Limit depth to 3, cache results       |
| Adding Phase 2/3 prematurely    | High       | Rule of Three enforced for each phase |

---

## Appendix A: Edge Type Guidelines

When creating graph edges:

- **contradicts** — Use when a pattern says "don't X" and a decision says "we
  chose X." Flag for review.
- **supersedes** — Mark older decisions as superseded when new ones override
  them. Old decision stays in journal but ranks lower.
- **derived_from** — Link patterns back to the decision/session where they
  were learned.
- **part_of** — Group related patterns under a hub concept (e.g., "bash safety").
- **summarized_by** — When consolidating patterns, link originals to summary
  with this edge. Original patterns drop to importance=1.

---

## Appendix B: Agentic RAG (Future Phase)

**Context:** Current hook (`inject-context.sh`) auto-injects on every prompt.
This works for project-scoped context but has limitations:

- No agent control over retrieval depth
- Fixed budget (1,500 chars) regardless of need
- Passive context (agent can't query explicitly)

**Alternative approaches** (defer until auto-injection proves insufficient):

### Option 1: Pure Agentic Retrieval

Remove auto-injection entirely. Expose `lore search` as an MCP tool.

```json
{
  "name": "lore_search",
  "description": "Search Lore's knowledge base (decisions, patterns, transfers) with ranked results",
  "inputSchema": {
    "type": "object",
    "properties": {
      "query": { "type": "string" },
      "project": { "type": "string", "description": "Optional project filter" },
      "type": {
        "type": "string",
        "enum": ["decision", "pattern", "transfer", "all"]
      },
      "limit": { "type": "integer", "default": 10 },
      "graph_depth": {
        "type": "integer",
        "default": 0,
        "description": "Follow graph edges (0-3)"
      }
    },
    "required": ["query"]
  }
}
```

**Pros:**

- Agent queries only when needed
- Dynamic depth/budget per query
- Multi-turn retrieval (agent can refine query based on results)

**Cons:**

- Requires agent to know when to search
- Extra API round-trip for retrieval
- No context unless agent asks

**Best for:** Complex research tasks where agent needs to explore knowledge iteratively.

### Option 2: Hybrid Auto-Inject + Tool

Keep `inject-context.sh` for high-confidence, project-scoped context.
Add MCP tool for ad-hoc queries.

**Auto-injection criteria:**

- Project match (cwd → project tag)
- High confidence (pattern confidence > 0.8, recent decisions < 30 days)
- Compact (top 3 results only)

**Tool for:**

- Cross-project queries
- Deep dives (graph traversal, semantic search)
- Refinement queries ("show me more like this")

**Pros:**

- Best of both: passive context + active retrieval
- Auto-injection stays fast (small budget)
- Agent has escape hatch for complex queries

**Cons:**

- Two code paths to maintain
- Potential duplication if agent searches for already-injected context

**Best for:** Current workflow with occasional deep research needs.

### Option 3: Agentic RAG (Multi-Step Retrieval)

Inspired by [Agentic RAG patterns](https://docs.kanaries.net/articles/agentic-rag):

1. **Query planning** — Agent decomposes user question into sub-queries
2. **Iterative retrieval** — Agent searches, evaluates results, refines query
3. **Synthesis** — Agent combines retrieved knowledge into answer

**Example flow:**

```
User: "Why did we choose JSONL over SQLite for storage?"

Agent plan:
  1. Search decisions for "JSONL" → finds dec-abc123
  2. Search decisions for "SQLite" → finds dec-def456
  3. Graph traverse from dec-abc123 (depth 1) → finds related patterns
  4. Synthesize: "Decision dec-abc123 chose JSONL because..."
```

**Implementation:**

- Expose `lore search`, `lore graph traverse`, `lore show <id>` as MCP tools
- Agent uses tools in sequence
- No auto-injection (agent controls retrieval entirely)

**Pros:**

- Agent adapts retrieval strategy to question complexity
- Multi-hop reasoning (follow graph edges, compare alternatives)
- Transparent retrieval (tool calls visible in transcript)

**Cons:**

- Expensive (multiple API round-trips)
- Requires sophisticated agent prompting
- Overkill for simple "remind me about X" queries

**Best for:** Complex analytical questions ("compare our auth decisions over time").

## Recommendation

Start with **Option 2 (Hybrid)** when current auto-injection proves limiting:

- Keep `inject-context.sh` for 90% of prompts (fast, passive, project-scoped)
- Add MCP tool for 10% edge cases (cross-project, deep research)
- Defer **Option 3 (Agentic RAG)** until we observe agents repeatedly doing multi-turn retrieval manually

**Trigger for migration:** Track how often agents need context that auto-injection missed. If `> 20%` of sessions include phrases like "search for...", "find the decision about...", "what patterns relate to...", then auto-injection budget is too small → migrate to hybrid.

**Phase 4 stub:**

```
Phase 4: Hybrid Retrieval (implement when auto-injection proves insufficient)
  Keep inject-context.sh for passive, project-scoped context (top 3, high-confidence).
  Add MCP tool for explicit queries (cross-project, graph traversal, semantic search).
  Track tool usage vs auto-injection to tune budget split.
```
