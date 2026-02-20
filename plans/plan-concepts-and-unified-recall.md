Status: Draft

# Plan: Concept Promotion and Unified Recall

Two connected improvements. Concepts fill the gap at the top of the knowledge
hierarchy. Unified recall fills the gap at the bottom of the read path.

## Context

The CLI now has three universal verbs: capture (write), recall (read), review
(evaluate). Capture routes all writes through one verb with flag inference.
Recall routes all reads -- but only as a dispatcher. Each `--flag` delegates to
a separate `cmd_*` function with its own data access pattern (jq on JSONL, yq
on YAML, grep, FTS5). No unified ranking, no cross-component results.

Meanwhile, the graph's type hierarchy has `concept` above `pattern`, but nothing
creates concepts. `consolidate` clusters similar decisions and creates summary
records -- but those summaries are just more decisions, not concepts.

Related decisions: dec-98d545ba (three universal verbs), dec-59685846 (CLI
redesign).

## Part 1: Concept Promotion

### What a concept is

A concept is a named abstraction that multiple decisions and patterns reference.
Examples: "fail-silent wrappers", "append-only storage", "flag-based inference."
Today these exist implicitly -- as tags that appear across records. Promotion
makes them explicit graph nodes with a definition and lineage.

### 1a. Add `concepts.yaml` to patterns/

```yaml
concepts:
  - id: concept-abc123
    name: "Fail-silent wrappers"
    definition: "Library calls that catch errors and return defaults"
    grounded_by: # patterns that implement this concept
      - pat-123456
      - pat-789abc
    informed_by: # decisions that led to this concept
      - dec-aabbcc
      - dec-ddeeff
    created_at: "2026-02-20T..."
    source: consolidation # or "manual"
```

File: `patterns/data/concepts.yaml`

Concepts live alongside patterns because they're the semantic layer: patterns
are specific (do X when Y), concepts are general (the principle behind X).

### 1b. Add `--promote` flag to `lore consolidate`

When `consolidate --write --promote` creates a cluster summary, also:

1. Generate a concept record from the cluster's shared vocabulary
2. Write it to `concepts.yaml`
3. Create `grounded_by` edges from the cluster's patterns (if any match)
4. Create `informed_by` edges from the clustered decisions
5. Sync the concept node to the graph

The concept name comes from the cluster's most frequent non-stopword terms.
The definition comes from the shortest decision text (already used for summary).

### 1c. Add `lore capture --concept` explicit path

For manual concept creation outside consolidation:

```bash
lore capture "Fail-silent wrappers" --concept \
  --definition "Library calls that catch errors and return defaults"
```

Routes to a new `cmd_concept()` that writes to `concepts.yaml` and syncs to
graph. Keep it minimal -- most concepts should emerge from consolidation, not
manual entry.

### 1d. Wire concepts into resume and recall

- `lore resume`: After showing patterns, show concepts relevant to the current
  project (matched by `grounded_by` pattern tags)
- `lore recall --concepts [query]`: Search concepts by name/definition
- `lore brief`: Include concepts section in topic briefings

## Part 2: Unified Recall

### The problem

`recall` delegates to five separate functions, each with different data access:

| Flag         | Function       | Access pattern           |
| ------------ | -------------- | ------------------------ |
| (default)    | `cmd_search`   | FTS5 on search.db        |
| `--project`  | `cmd_context`  | jq + yq + graph.sh       |
| `--patterns` | `cmd_suggest`  | yq on patterns.yaml      |
| `--failures` | `cmd_failures` | jq on failures.jsonl     |
| `--triggers` | `cmd_triggers` | jq aggregate on failures |

No unified ranking. No cross-component results for filtered queries. Search
finds decisions and patterns but not failures or observations.

### 2a. Extend FTS5 index to cover all components

Add three new FTS5 tables to `search-index.sh`:

```sql
CREATE VIRTUAL TABLE IF NOT EXISTS failures USING fts5(
    id UNINDEXED,
    error_type,
    error_message,
    tool,
    timestamp UNINDEXED
);

CREATE VIRTUAL TABLE IF NOT EXISTS observations USING fts5(
    id UNINDEXED,
    content,
    tags,
    timestamp UNINDEXED
);

CREATE VIRTUAL TABLE IF NOT EXISTS concepts USING fts5(
    id UNINDEXED,
    name,
    definition,
    timestamp UNINDEXED
);
```

Add `load_failures()`, `load_observations()`, `load_concepts()` functions.

### 2b. Add filtered search to `_search_fts5`

Currently `_search_fts5` queries decisions, patterns, and transfers, unions the
results, and ranks them. Extend it:

- Accept optional `--type` filter parameter (decision, pattern, failure,
  observation, concept, transfer)
- When filtered, query only the matching FTS5 table
- When unfiltered, query all tables (current behavior + new ones)

### 2c. Route recall flags through FTS5

Replace delegation with filtered search:

| Flag         | Current               | New                                  |
| ------------ | --------------------- | ------------------------------------ |
| (default)    | `cmd_search` (FTS5)   | `_search_fts5 --type all` (same)     |
| `--patterns` | `cmd_suggest` (yq)    | `_search_fts5 --type pattern`        |
| `--failures` | `cmd_failures` (jq)   | `_search_fts5 --type failure`        |
| `--triggers` | `cmd_triggers` (jq)   | Keep as-is (aggregation, not search) |
| `--project`  | `cmd_context` (multi) | Keep as-is (assembly, not search)    |
| `--brief`    | `cmd_brief` (multi)   | Keep as-is (assembly, not search)    |

Key insight: **triggers, project, and brief are assembly operations, not
searches.** They combine data from multiple sources into a report. These stay
as-is. Only the search-like operations (patterns, failures, default) unify
through FTS5.

### 2d. Graceful degradation

When search.db doesn't exist, `recall` falls back to the current dispatcher
behavior (jq/yq on flat files). This preserves the no-index experience while
making `lore index build` the path to unified recall.

## What NOT to Do

- Don't auto-promote concepts without `--promote` flag. Concepts need curation.
- Don't remove `cmd_failures` or `cmd_suggest` -- they remain as direct-access
  shortcuts and as the fallback when search.db doesn't exist.
- Don't add vector embeddings. FTS5 is sufficient for the current data volume.
  Revisit when records exceed 1000.
- Don't change the consolidate clustering algorithm. It works. Just wire in
  concept creation as an output.
- Don't index goals. Goals are structured YAML with status tracking -- search
  isn't the right access pattern for them.

## Files to Create/Modify

- `patterns/data/concepts.yaml` -- new data file (seeded empty by init)
- `lib/search-index.sh` -- add failures, observations, concepts FTS5 tables
  and loaders; add `--type` filter to search
- `lore.sh:cmd_consolidate()` -- add `--promote` flag, concept creation
- `lore.sh:cmd_recall()` -- route `--patterns`/`--failures` through FTS5 when
  available
- `lore.sh:cmd_capture()` -- add `--concept` routing
- `lore.sh:show_help_*` -- update help text
- `lore.sh:cmd_init()` -- seed concepts.yaml
- `graph/sync.sh` -- add concept sync
- `lib/paths.sh` -- add `LORE_CONCEPTS_FILE`
- `tests/test-recall.sh` -- extend with FTS5-backed recall tests

## Sequencing

### Phase A: Concept promotion (standalone, no recall dependency)

1. Add concepts.yaml schema and paths.sh variable
2. Add `--promote` to consolidate
3. Add `--concept` to capture
4. Wire concepts into graph sync
5. Test: `lore consolidate --write --promote` creates concept records

### Phase B: Unified recall (depends on Phase A for concepts table)

1. Add failures, observations, concepts FTS5 tables to search-index.sh
2. Add `--type` filter to `_search_fts5`
3. Update `cmd_recall` to use FTS5 when available
4. Test: `lore recall --failures "timeout"` returns ranked results from FTS5

Phases are independent enough for parallel agents. Phase A touches lore.sh and
patterns/. Phase B touches lib/search-index.sh and lore.sh (different
functions). Merge point: Phase B's concepts table needs Phase A's
concepts.yaml and load_concepts().

## Acceptance Criteria

- [ ] `lore consolidate --write --promote` creates concept records in
      concepts.yaml and graph nodes
- [ ] `lore capture "X" --concept --definition "Y"` writes to concepts.yaml
- [ ] `lore recall "fail-silent"` finds concepts alongside decisions/patterns
- [ ] `lore recall --failures "timeout"` returns ranked FTS5 results (with
      index) or falls back to jq (without index)
- [ ] `lore recall --patterns "deployment"` returns ranked FTS5 results (with
      index) or falls back to yq (without index)
- [ ] `lore index build` indexes failures, observations, and concepts
- [ ] All existing tests still pass
- [ ] New tests cover concept creation, FTS5 filtering, and graceful fallback

## Testing

```bash
# Phase A
lore consolidate --write --promote    # verify concepts.yaml populated
lore capture "test concept" --concept --definition "a test"
cat patterns/data/concepts.yaml       # verify record exists
lore graph query "test concept"       # verify graph node

# Phase B
lore index build                      # verify no errors, new tables created
lore recall --failures "timeout"      # verify ranked results
lore recall --patterns "deployment"   # verify ranked results
lore recall "test concept"            # verify concepts appear in search
make test                             # verify nothing broke
```
