# Plan: Phase 2 — Vector Embeddings

Status: Implemented
Completed: 2026-02-15

## Problem

FTS5 with BM25 ranking handles exact and stemmed matches. It fails on semantic similarity:

- "retry logic" won't find "exponential backoff"
- "authentication" won't find "login flow"
- "error handling" won't find "exception management"

When FTS5 demonstrably misses relevant results three times, this phase activates.

## Trigger Tracking

Before implementing, log FTS5 failures:

```bash
# lib/search-failures.sh
log_search_failure() {
    local query="$1"
    local expected="$2"  # What should have been found
    local actual="$3"    # What was found (or "nothing")

    echo "$(date -Iseconds)|${query}|${expected}|${actual}" \
        >> "${LORE_DIR}/failures/data/search-failures.log"
}

count_search_failures() {
    wc -l < "${LORE_DIR}/failures/data/search-failures.log" 2>/dev/null || echo 0
}
```

When `count_search_failures` reaches 3, proceed with this plan.

## Solution

Hybrid FTS5 + vector search. Generate embeddings at index time, query both FTS5 and vector similarity, merge results.

## Architecture

```
Query
  |
  +---> FTS5 (BM25)      ---> ranked results (lexical)
  |
  +---> Vector (cosine)  ---> ranked results (semantic)
  |
  v
Merge + Dedupe + Re-rank
  |
  v
Final results
```

## Implementation Options

### Option A: sqlite-vec (Preferred)

SQLite extension for vector similarity. Keeps everything in one database.

```sql
-- Add to search.db schema
CREATE VIRTUAL TABLE embeddings USING vec0(
    record_type TEXT,
    record_id TEXT,
    embedding FLOAT[384]  -- all-MiniLM-L6-v2 dimension
);
```

**Pros:** Single database, fast, no external services
**Cons:** Requires compiling sqlite-vec, embedding generation needs Python/JS

### Option B: Ollama local embeddings

Use local Ollama for embedding generation:

```bash
generate_embedding() {
    local text="$1"
    curl -s http://localhost:11434/api/embeddings \
        -d "{\"model\": \"nomic-embed-text\", \"prompt\": \"${text}\"}" \
        | jq -r '.embedding | @csv'
}
```

**Pros:** Local, private, no API costs
**Cons:** Requires Ollama running, slower than sqlite-vec native

### Option C: OpenAI embeddings (Fallback)

Use OpenAI's text-embedding-3-small if local options fail:

```bash
generate_embedding() {
    local text="$1"
    curl -s https://api.openai.com/v1/embeddings \
        -H "Authorization: Bearer ${OPENAI_API_KEY}" \
        -d "{\"model\": \"text-embedding-3-small\", \"input\": \"${text}\"}" \
        | jq -r '.data[0].embedding | @csv'
}
```

**Pros:** High quality, simple API
**Cons:** API costs, requires network, data leaves local machine

## Hybrid Search Query

```sql
WITH fts_results AS (
    SELECT
        'decision' as type,
        id,
        decision as content,
        rank * -1 as score,
        'fts' as source
    FROM decisions
    WHERE decisions MATCH ?
    LIMIT 20
),
vec_results AS (
    SELECT
        record_type as type,
        record_id as id,
        NULL as content,
        vec_distance_cosine(embedding, ?) as score,
        'vec' as source
    FROM embeddings
    ORDER BY score
    LIMIT 20
),
merged AS (
    SELECT * FROM fts_results
    UNION ALL
    SELECT * FROM vec_results
)
SELECT
    type,
    id,
    -- Reciprocal Rank Fusion
    SUM(1.0 / (60 + row_number)) as rrf_score
FROM (
    SELECT *, ROW_NUMBER() OVER (PARTITION BY source ORDER BY score) as row_number
    FROM merged
)
GROUP BY type, id
ORDER BY rrf_score DESC
LIMIT ?;
```

## Index Rebuild

Embedding generation runs during `lore search --rebuild`:

```bash
rebuild_index() {
    # ... existing FTS5 indexing ...

    # Phase 2: Generate embeddings
    if phase2_enabled; then
        echo "Generating embeddings..."
        while IFS= read -r record; do
            local id content embedding
            id=$(echo "${record}" | jq -r '.id')
            content=$(echo "${record}" | jq -r '.decision + " " + .rationale')
            embedding=$(generate_embedding "${content}")

            sqlite3 "${DB}" "INSERT INTO embeddings VALUES ('decision', '${id}', '${embedding}')"
        done < <(jq -c '.' "${LORE_DIR}/journal/data/decisions.jsonl")
    fi
}
```

## Verification

```bash
# Log a failure that FTS5 missed
lore search-failure "retry logic" "dec-abc123" "nothing"

# Check failure count
lore search-failures --count  # Returns 3+

# Rebuild with embeddings
lore search --rebuild --phase2

# Verify semantic search works
lore search "exponential backoff"  # Should now find retry-related decisions
```

## Rollback

If vector search degrades performance or quality:

```bash
# Disable phase 2
echo "phase2_enabled=false" >> "${LORE_DIR}/.config"

# Drop embeddings table
sqlite3 "${HOME}/.lore/search.db" "DROP TABLE IF EXISTS embeddings"
```

## Outcome

Implemented using Option B (Ollama local embeddings). `lib/search-index.sh` creates an `embeddings` table (768-dimensional, nomic-embed-text model) and the `load_embeddings()` function generates embeddings at index rebuild time. The trigger threshold (3 FTS5 failures) was not implemented as a gate; embeddings are generated whenever Ollama is available during `--rebuild`. The rollback mechanism via config flag was not implemented.
