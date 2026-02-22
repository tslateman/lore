# Initiative: Lore + ClaudeMemory Integration

Lore is the ledger. ClaudeMemory is the cache. Both serve as MCPs for their
respective use cases.

## Architecture

```text
              writes                    reads (semantic, fast)
         ┌──────────┐              ┌──────────────┐
         ▼          │              ▼              │
     +--------+  +------+  sync  +-------------+  │
     |  agent |  | Lore |──────▶| ClaudeMemory |  │
     | (write)|  | MCP  |       |     MCP      |──┘
     +--------+  +------+       +-------------+
                    │              ▲         │
                    │   promote    │         │
                    │   (curated)  │         │
                    └──────────────┘         │
                                     advise hook
                                        │
                                        ▼
                                    context injected
                                    before each turn
```

**Lore** owns the written record: append-only decisions, curated patterns,
failure analysis, session handoffs. Structured data (JSONL/YAML/JSON) with
FTS5 index. Source of truth.

**ClaudeMemory** owns working memory: semantic recall, graph traversal,
episodic grouping. SQLite with FTS5 + vector embedding infrastructure.
Disposable view -- rebuildable from Lore at any time.

**Design principles:**

1. Lore is the source of truth. If they disagree, Lore wins.
2. Projection is deterministic and idempotent.
3. Promotion is curated, never automatic.
4. Session boundaries are natural consistency points.
5. Fail toward the ledger.

## Current State

**Phase 1 (complete):** Write-through sync, invalidation, health check, content
hashing. New captures sync immediately via `_bridge_sync_last_decision()` and
`_bridge_sync_last_pattern()`. Abandoned/revised decisions retract shadows via
`retract_shadow()`. `lore resume` reports shadow drift. Content hashes detect
edits without formal revision.

**Phase 2 (complete):** Query routing via `lib/recall-router.sh`.
`lore recall --routed` classifies queries by keyword shape and routes to
Lore-first, Engram-first, or both. Shadow memories enriched with full
Lore records (rationale, alternatives, tags). Dedup prevents duplicate display.
Provenance markers `(lore)` / `(mem)` on all results. MCP tool `lore_recall`
exposes routing to agents. `inject-context.sh` uses routed recall.

**Phase 3 (complete):** Promotion pipeline via `lib/promote.sh`.
`lore promote` queries Engram for high-value non-shadow memories (importance ≥ 4
or accessCount ≥ 3), presents them for curation, and promotes approved
candidates to Lore. Original Engram memories updated with `[lore:{id}]` prefix
to become shadows. Classification (decision/pattern/observation) inferred from
content. 15 integration tests. Phase 3c (reinforcement signal) deferred—requires
cross-MCP communication.

**Phase 4a (complete):** Graph edge projection via `lib/bridge.sh`.
`lore sync` projects Lore graph edges between shadow memories into Engram Edge
table. Maps Lore relations to Engram relations (learned_from→derived_from,
references→relates_to, etc.). Handles bidirectional edges, deduplication, and
trigger management. 12 integration tests. Real-world sync projected 28 edges
across 14 decision/pattern relationships.

**Remaining:**

- Phase 3c: Reinforcement signal (log when Lore shadows accessed via Engram)
- Phase 4b: Cross-system graph traversal
- Phase 4c: Concept promotion from Engram clusters

## Phase 1: Tighten the Bridge

**Goal:** Make the existing sync reliable, timely, and self-healing.

### 1a. Write-through sync on capture

When `lore capture` writes a decision or pattern, immediately create the
shadow memory in ClaudeMemory. No waiting for SessionEnd.

```text
lore capture "Use JSONL" --rationale "Append-only"
  → appends to decisions.jsonl
  → immediately creates [lore:dec-{id}] shadow in ClaudeMemory
```

**Implementation:** Add a `_sync_single_shadow()` function to `bridge.sh`.
Call it from `lore.sh` after each successful capture. Fail-silent -- if
ClaudeMemory is unreachable, the record still lands in Lore.

### 1b. Invalidation on revision and abandonment

When a decision is revised or abandoned via `lore review`, update its shadow:

- **Revised:** Update shadow content, prepend `[REVISED]`
- **Abandoned:** Set shadow importance to 0 (suppresses recall without
  deleting the record)

**Implementation:** Hook into `lore review --resolve` and
`lore review --abandon` to call `_update_shadow()` or `_retract_shadow()`.

### 1c. Sync health check in `lore resume`

At session start, verify shadow count matches expected Lore record count.
Report discrepancies:

```text
lore resume
  ...
  shadows: 126/130 synced (4 missing, run `lore sync` to fix)
```

**Implementation:** Count `[lore:*]` rows in ClaudeMemory, compare against
Lore record counts. Report delta. Do not auto-fix -- keep `lore resume` fast.

### 1d. Content hash for change detection

Store a content hash alongside each shadow. On sync, compare hashes to detect
records that changed without a formal revision (e.g., pattern edits).

```text
Shadow metadata:
  lore_id: dec-42
  content_hash: sha256("Use JSONL|Append-only, simple")
  synced_at: 2026-02-21T10:00:00Z
```

**Implementation:** Add hash to shadow content as a trailing comment or to a
separate tracking table/file. `lore sync` compares hashes to skip unchanged
records.

**Deliverables:** Write-through capture, invalidation hooks, health check,
content hashing. Sync becomes timely and self-healing.

---

## Phase 2: Query Routing

**Goal:** Agents query the right system automatically, with clear provenance.

### 2a. Tiered recall

Replace independent queries with a tiered strategy:

```text
1. Query ClaudeMemory (fast, semantic, <50ms)
   → returns memories, some tagged [lore:*], some native

2. If query needs authoritative detail (rationale, alternatives):
   → follow [lore:{id}] to Lore for full record

3. If ClaudeMemory returns nothing useful:
   → fall back to lore recall (FTS5 on structured data)
```

**Implementation:** Add a `lore recall --semantic` flag that queries
ClaudeMemory via its MCP tools, then enriches `[lore:*]` results with full
Lore records. The Lore MCP server gains a `lore_semantic_recall` tool that
orchestrates this.

### 2b. Provenance marking in advise hook

The advise hook already injects ClaudeMemory results before each turn. Mark
`[lore:*]` results distinctly so agents know the authoritative source:

```text
[id:42] [lore/lore-decisions] Decision: Use JSONL for storage. (source: lore)
[id:99] [global/debugging] npm fails in non-interactive shells. (source: memory)
```

**Implementation:** The advise hook already returns memories. Add a source
indicator when content starts with `[lore:`.

### 2c. Routing heuristic

Encode query routing as a simple decision table:

| Query shape              | Primary      | Fallback     |
| ------------------------ | ------------ | ------------ |
| "Why did we decide X?"   | Lore         | ClaudeMemory |
| "What patterns for X?"   | Lore         | ClaudeMemory |
| "What failed with X?"    | Lore         | ClaudeMemory |
| "What do we know about?" | ClaudeMemory | Lore         |
| "What was I working on?" | ClaudeMemory | --           |
| "What connects X to Y?"  | ClaudeMemory | Lore graph   |
| "What should I do next?" | Both (merge) | --           |

**Implementation:** The `lore recall` unified verb already handles structured
queries. Add a `--auto` mode that picks the right source based on query shape
(keyword detection: "why" → Lore, "relate" → ClaudeMemory graph, etc.).

**Deliverables:** Tiered recall, provenance marking, routing heuristic. Agents
get the right answer from the right system without thinking about it.

---

## Phase 3: Promotion Pipeline

**Goal:** Durable observations in ClaudeMemory flow to Lore through curated
promotion, not automatic sync.

### 3a. Promotion candidates

ClaudeMemory accumulates observations that may deserve permanence. Detection:

- **Rule of Three:** An observation recalled 3+ times across sessions →
  pattern candidate
- **High importance:** Memories manually set to importance 4-5 by the agent →
  decision candidate
- **Cluster consensus:** `find_clusters` reveals 3+ memories about the same
  topic → consolidation + Lore candidate

**Implementation:** `lore-scribe` gains a `--from-memory` mode that queries
ClaudeMemory for promotion candidates, presents them for curation, and writes
accepted candidates to Lore.

### 3b. Promotion workflow

```text
lore-scribe --from-memory
  1. Query ClaudeMemory for high-value non-shadow memories
  2. Filter: importance >= 4, accessCount >= 3, not [lore:*]
  3. Present candidates with context
  4. Agent/human approves, edits, or rejects each
  5. Approved candidates → lore capture (decision or pattern)
  6. Shadow created via write-through (Phase 1a)
  7. Original ClaudeMemory record gets [lore:{id}] prefix
     (becomes a shadow of the record it spawned)
```

### 3c. Reinforcement signal

When an agent recalls a Lore shadow and uses it (follows its guidance, cites
it, builds on it), record that access in Lore's `access_log`. This feeds
back into Lore's relevance ranking without mutating the ledger.

```text
Agent recalls [lore:dec-42] → access_log.update(id=42, hits++)
```

**Implementation:** The Lore MCP server's `lore_search` tool already logs
accesses to `search.db:access_log`. Extend to log accesses that originate
from ClaudeMemory shadow hits (pass through the `[lore:{id}]`).

**Deliverables:** Promotion pipeline, reinforcement signal. Working memory
insights earn their place in the ledger through repetition and judgment.

---

## Phase 4: Unified Graph

**Goal:** Connect Lore's knowledge graph and ClaudeMemory's memory graph into
a traversable whole.

### 4a. Project Lore graph edges into ClaudeMemory

Lore's graph has 13 edge types with weights. ClaudeMemory's graph has 6 edge
types. Project Lore edges as ClaudeMemory edges where types align:

| Lore edge type | ClaudeMemory edge type | Notes                |
| -------------- | ---------------------- | -------------------- |
| implements     | relates_to             | Lossy but functional |
| derived_from   | derived_from           | Direct match         |
| contradicts    | contradicts            | Direct match         |
| relates_to     | relates_to             | Direct match         |
| supersedes     | supersedes             | Direct match         |
| part_of        | part_of                | Direct match         |
| learned_from   | derived_from           | Close enough         |
| references     | relates_to             | Lossy                |

**Implementation:** Extend `lore sync` to project graph edges between shadow
memories. When shadow `[lore:dec-42]` and `[lore:pat-7]` have a Lore edge,
create a ClaudeMemory edge between them.

### 4b. Cross-system graph traversal

`lore recall --graph-depth 2` already does BFS in Lore's graph. Extend to
follow edges into ClaudeMemory's graph when a Lore node connects to a native
ClaudeMemory memory (via a shadow's edges).

```text
lore recall "auth" --graph-depth 2
  → FTS5 hit: [lore:dec-42] "Use JWT for auth"
  → Lore graph: dec-42 → pat-7 "Token refresh pattern"
  → ClaudeMemory graph: [lore:pat-7] → [id:99] "OAuth debugging notes"
  → Result includes all three, with provenance
```

**Implementation:** After Lore graph traversal, check if terminal nodes have
shadows in ClaudeMemory. If so, follow ClaudeMemory edges one more hop.
Requires querying ClaudeMemory MCP from within the Lore MCP server.

### 4c. Concept promotion

ClaudeMemory's `detect_communities` and `find_clusters` reveal natural
groupings. When a cluster of shadow memories forms around an unnamed concept,
surface it as a Lore concept candidate:

```text
Cluster detected: 5 memories about "append-only data patterns"
  → Candidate concept: "append-only-data"
  → Prompt: "Create Lore concept? (lore graph add concept 'append-only-data')"
```

**Implementation:** Periodic `detect_communities` on ClaudeMemory, filtered
to `[lore:*]` nodes. Clusters of 3+ shadows suggest a missing concept in
Lore's graph. Present via `lore-scribe` for curation.

**Deliverables:** Edge projection, cross-system traversal, concept promotion.
The two graphs become one navigable knowledge network.

---

## Sequencing

| Phase | Depends on | Effort | Value                            |
| ----- | ---------- | ------ | -------------------------------- |
| 1     | --         | Medium | Reliability, timeliness          |
| 2     | Phase 1    | Medium | Smarter retrieval, less manual   |
| 3     | Phase 2    | Small  | Knowledge compounds across tools |
| 4     | Phase 1    | Large  | Unified knowledge graph          |

Phases 2 and 4 can run in parallel after Phase 1. Phase 3 benefits from
Phase 2's routing but can start independently.

## Success Criteria

- **Phase 1:** Zero stale shadows after `lore resume`. New captures visible
  in ClaudeMemory within 1 second.
- **Phase 2:** Agent retrieves authoritative Lore record via ClaudeMemory
  recall without knowing which system to query.
- **Phase 3:** At least 5 ClaudeMemory observations promoted to Lore patterns
  via curated pipeline in first month.
- **Phase 4:** `lore recall --graph-depth 2` returns results from both
  systems with clear provenance.
