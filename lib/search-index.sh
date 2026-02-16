#!/usr/bin/env bash
# search-index.sh - Build and query the FTS5 search index
#
# Creates ~/.lore/search.db with full-text search across decisions,
# patterns, and transfers. Supports reinforcement scoring via access
# tracking and multi-signal ranking.

set -euo pipefail

LORE_DIR="${LORE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
DB_DIR="${HOME}/.lore"
DB="${DB_DIR}/search.db"

# Data sources
DECISIONS_FILE="${LORE_DIR}/journal/data/decisions.jsonl"
PATTERNS_FILE="${LORE_DIR}/patterns/data/patterns.yaml"
SESSIONS_DIR="${LORE_DIR}/transfer/data/sessions"

# --- Schema ---

create_schema() {
    mkdir -p "$DB_DIR"
    sqlite3 "$DB" <<'SQL'
-- FTS5 tables
CREATE VIRTUAL TABLE IF NOT EXISTS decisions USING fts5(
    id UNINDEXED,
    decision,
    rationale,
    tags,
    timestamp UNINDEXED,
    project UNINDEXED,
    importance UNINDEXED
);

CREATE VIRTUAL TABLE IF NOT EXISTS patterns USING fts5(
    id UNINDEXED,
    name,
    context,
    problem,
    solution,
    confidence UNINDEXED,
    timestamp UNINDEXED
);

CREATE VIRTUAL TABLE IF NOT EXISTS transfers USING fts5(
    session_id UNINDEXED,
    project UNINDEXED,
    handoff,
    timestamp UNINDEXED
);

-- Access log for reinforcement scoring
CREATE TABLE IF NOT EXISTS access_log (
    record_type TEXT NOT NULL,
    record_id TEXT NOT NULL,
    accessed_at TEXT NOT NULL,
    PRIMARY KEY (record_type, record_id, accessed_at)
);

-- Similarity cache for conflict detection
CREATE TABLE IF NOT EXISTS similarity_cache (
    record_type TEXT NOT NULL,
    record_id TEXT PRIMARY KEY,
    content_hash TEXT NOT NULL,
    created_at TEXT NOT NULL
);

-- Phase 2: Vector embeddings for semantic search
-- Stores 768-dimensional embeddings from nomic-embed-text
CREATE TABLE IF NOT EXISTS embeddings (
    record_type TEXT NOT NULL,
    record_id TEXT NOT NULL,
    content_text TEXT NOT NULL,
    embedding TEXT NOT NULL,  -- JSON array of 768 floats
    created_at TEXT NOT NULL,
    PRIMARY KEY (record_type, record_id)
);
SQL
}

# --- Data Loading ---

load_decisions() {
    [[ -f "$DECISIONS_FILE" ]] || return 0

    local count=0
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local id decision rationale tags timestamp project importance

        id=$(echo "$line" | jq -r '.id // ""')
        decision=$(echo "$line" | jq -r '.decision // ""')
        rationale=$(echo "$line" | jq -r '.rationale // ""')
        tags=$(echo "$line" | jq -r '(.tags // []) | join(", ")')
        timestamp=$(echo "$line" | jq -r '.timestamp // ""')
        # Extract project from tags or entities
        project=$(echo "$line" | jq -r '
            (.tags // [])[] | select(. != null)
        ' | head -1)
        [[ -z "$project" ]] && project="lore"
        # Importance: 3 (default medium) unless lesson_learned is set (4)
        local has_lesson
        has_lesson=$(echo "$line" | jq -r '.lesson_learned // ""')
        if [[ -n "$has_lesson" ]]; then
            importance=4
        else
            importance=3
        fi

        sqlite3 "$DB" "INSERT INTO decisions(id, decision, rationale, tags, timestamp, project, importance)
            VALUES ($(sql_quote "$id"), $(sql_quote "$decision"), $(sql_quote "$rationale"),
                    $(sql_quote "$tags"), $(sql_quote "$timestamp"), $(sql_quote "$project"),
                    $importance);"
        count=$((count + 1))
    done < "$DECISIONS_FILE"
    echo "  Loaded $count decisions"
}

load_patterns() {
    [[ -f "$PATTERNS_FILE" ]] || return 0

    local count=0
    # Use process substitution to avoid subshell count loss
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local id name context problem solution confidence timestamp

        id=$(echo "$line" | jq -r '.id // ""')
        name=$(echo "$line" | jq -r '.name // ""')
        context=$(echo "$line" | jq -r '.context // ""')
        problem=$(echo "$line" | jq -r '.problem // ""')
        solution=$(echo "$line" | jq -r '.solution // ""')
        confidence=$(echo "$line" | jq -r '.confidence // 0.5')
        timestamp=$(echo "$line" | jq -r '.created_at // ""')

        sqlite3 "$DB" "INSERT INTO patterns(id, name, context, problem, solution, confidence, timestamp)
            VALUES ($(sql_quote "$id"), $(sql_quote "$name"), $(sql_quote "$context"),
                    $(sql_quote "$problem"), $(sql_quote "$solution"),
                    '$confidence', $(sql_quote "$timestamp"));"
        count=$((count + 1))
    done < <(yq -o=json '.patterns[]' "$PATTERNS_FILE" 2>/dev/null | jq -c '.')
    echo "  Loaded $count patterns"

    # Also load anti-patterns
    local anti_count=0
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local id name context problem solution timestamp

        id=$(echo "$line" | jq -r '.id // ""')
        name=$(echo "$line" | jq -r '"ANTI: " + (.name // "")')
        context=$(echo "$line" | jq -r '.symptom // ""')
        problem=$(echo "$line" | jq -r '.risk // ""')
        solution=$(echo "$line" | jq -r '.fix // ""')
        timestamp=$(echo "$line" | jq -r '.created_at // ""')

        sqlite3 "$DB" "INSERT INTO patterns(id, name, context, problem, solution, confidence, timestamp)
            VALUES ($(sql_quote "$id"), $(sql_quote "$name"), $(sql_quote "$context"),
                    $(sql_quote "$problem"), $(sql_quote "$solution"),
                    '0.5', $(sql_quote "$timestamp"));"
        anti_count=$((anti_count + 1))
    done < <(yq -o=json '.anti_patterns[]' "$PATTERNS_FILE" 2>/dev/null | jq -c '.')
    echo "  Loaded $anti_count anti-patterns"
}

load_transfers() {
    [[ -d "$SESSIONS_DIR" ]] || return 0

    local count=0
    for session_file in "$SESSIONS_DIR"/session-*.json; do
        [[ -f "$session_file" ]] || continue
        # Skip compressed and example files
        [[ "$session_file" == *".compressed."* ]] && continue
        [[ "$session_file" == *"example"* ]] && continue

        local session_id project handoff timestamp
        session_id=$(jq -r '.id // ""' "$session_file")
        project=$(jq -r '.context.environment.pwd // "unknown"' "$session_file" | xargs basename 2>/dev/null || echo "unknown")
        handoff=$(jq -r '.handoff.message // ""' "$session_file")
        timestamp=$(jq -r '.ended_at // .started_at // ""' "$session_file")

        [[ -z "$handoff" ]] && continue

        sqlite3 "$DB" "INSERT INTO transfers(session_id, project, handoff, timestamp)
            VALUES ($(sql_quote "$session_id"), $(sql_quote "$project"),
                    $(sql_quote "$handoff"), $(sql_quote "$timestamp"));"
        count=$((count + 1))
    done
    echo "  Loaded $count transfers"
}

# --- Querying ---

search_query() {
    local query="$1"
    local project="${2:-}"
    local limit="${3:-10}"

    # Escape FTS5 query: double-quote terms for phrase matching safety
    local fts_query
    fts_query=$(echo "$query" | sed 's/"/""/g')

    local project_param
    project_param="${project:-__none__}"

    sqlite3 -header -separator '|' "$DB" <<SQL
WITH ranked AS (
    SELECT
        'decision' as type,
        id,
        decision as content,
        project,
        timestamp,
        CAST(importance AS REAL) as importance,
        rank * -1 as bm25_score
    FROM decisions WHERE decisions MATCH '${fts_query}'
    UNION ALL
    SELECT
        'pattern' as type,
        id,
        name || ': ' || solution as content,
        'lore' as project,
        timestamp,
        CAST(CAST(confidence AS REAL) * 5 AS REAL) as importance,
        rank * -1 as bm25_score
    FROM patterns WHERE patterns MATCH '${fts_query}'
    UNION ALL
    SELECT
        'transfer' as type,
        session_id as id,
        handoff as content,
        project,
        timestamp,
        3.0 as importance,
        rank * -1 as bm25_score
    FROM transfers WHERE transfers MATCH '${fts_query}'
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
    r.id,
    SUBSTR(r.content, 1, 120) as content,
    r.project,
    r.timestamp,
    ROUND(
        r.bm25_score
        * (1.0 / (1 + (julianday('now') - julianday(r.timestamp)) / 30))
        * COALESCE(1.0 + (LN(1 + f.access_count) * 0.15), 1.0)
        * (1.0 + (r.importance / 5.0 * 0.2))
        * COALESCE(1.0 + (0.1 * EXP(-(julianday('now') - julianday(f.last_access)) / 30)), 1.0)
        * CASE WHEN r.project = '${project_param}' THEN 1.5 ELSE 1.0 END
    , 4) as score
FROM ranked r
LEFT JOIN frequency f ON r.type = f.record_type AND r.id = f.record_id
ORDER BY score DESC
LIMIT ${limit};
SQL
}

# --- Access Logging ---

log_access() {
    local type="$1"
    local id="$2"
    sqlite3 "$DB" "INSERT OR IGNORE INTO access_log(record_type, record_id, accessed_at)
        VALUES ('$type', '$id', datetime('now'));"
}

# --- Utilities ---

sql_quote() {
    local val="$1"
    # Escape single quotes for SQLite
    val="${val//\'/\'\'}"
    echo "'$val'"
}

index_stats() {
    echo "Index statistics:"
    echo -n "  Decisions: "
    sqlite3 "$DB" "SELECT COUNT(*) FROM decisions;"
    echo -n "  Patterns:  "
    sqlite3 "$DB" "SELECT COUNT(*) FROM patterns;"
    echo -n "  Transfers: "
    sqlite3 "$DB" "SELECT COUNT(*) FROM transfers;"
    echo -n "  Embeddings: "
    sqlite3 "$DB" "SELECT COUNT(*) FROM embeddings;" 2>/dev/null || echo "0"
    echo -n "  Access log entries: "
    sqlite3 "$DB" "SELECT COUNT(*) FROM access_log;"
    echo -n "  Database size: "
    du -h "$DB" | cut -f1
}

# --- Phase 2: Vector Embeddings ---

OLLAMA_URL="${OLLAMA_URL:-http://localhost:11434}"
EMBEDDING_MODEL="${EMBEDDING_MODEL:-nomic-embed-text}"

# Check if Ollama is available
ollama_available() {
    curl -s --max-time 2 "${OLLAMA_URL}/api/tags" >/dev/null 2>&1
}

# Generate embedding using Ollama
# Returns JSON array of 768 floats
generate_embedding() {
    local text="$1"
    
    # Truncate to ~8000 chars (nomic-embed-text context limit)
    text="${text:0:8000}"
    
    # Escape for JSON
    local json_text
    json_text=$(printf '%s' "$text" | jq -Rs '.')
    
    local response
    response=$(curl -s --max-time 30 "${OLLAMA_URL}/api/embeddings" \
        -H "Content-Type: application/json" \
        -d "{\"model\": \"${EMBEDDING_MODEL}\", \"prompt\": ${json_text}}")
    
    echo "$response" | jq -c '.embedding // empty'
}

# Compute cosine similarity between two embedding JSON arrays
# Uses Python for reliable float math on 768 dimensions
cosine_similarity() {
    local emb1="$1"
    local emb2="$2"
    
    python3 -c "
import json
import math

a = json.loads('''${emb1}''')
b = json.loads('''${emb2}''')

dot = sum(x*y for x, y in zip(a, b))
norm_a = math.sqrt(sum(x*x for x in a))
norm_b = math.sqrt(sum(x*x for x in b))

if norm_a == 0 or norm_b == 0:
    print(0.0)
else:
    print(dot / (norm_a * norm_b))
"
}

# Load embeddings for all indexed records
load_embeddings() {
    if ! ollama_available; then
        echo "  Skipping embeddings (Ollama not available at ${OLLAMA_URL})"
        return 0
    fi
    
    echo "  Generating embeddings (this may take a while)..."
    local count=0
    
    # Embed decisions
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local id decision rationale content embedding
        
        id=$(echo "$line" | jq -r '.id // ""')
        [[ -z "$id" ]] && continue
        
        # Check if embedding already exists
        local exists
        exists=$(sqlite3 "$DB" "SELECT 1 FROM embeddings WHERE record_type='decision' AND record_id='${id}' LIMIT 1;" 2>/dev/null || echo "")
        [[ -n "$exists" ]] && continue
        
        decision=$(echo "$line" | jq -r '.decision // ""')
        rationale=$(echo "$line" | jq -r '.rationale // ""')
        content="${decision} ${rationale}"
        
        embedding=$(generate_embedding "$content")
        [[ -z "$embedding" ]] && continue
        
        sqlite3 "$DB" "INSERT OR REPLACE INTO embeddings(record_type, record_id, content_text, embedding, created_at)
            VALUES ('decision', $(sql_quote "$id"), $(sql_quote "$content"), $(sql_quote "$embedding"), datetime('now'));"
        count=$((count + 1))
        
        # Progress indicator
        [[ $((count % 10)) -eq 0 ]] && echo "    Embedded ${count} records..."
    done < "$DECISIONS_FILE"
    
    # Embed patterns
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local id name problem solution content embedding
        
        id=$(echo "$line" | jq -r '.id // ""')
        [[ -z "$id" ]] && continue
        
        # Check if embedding already exists
        local exists
        exists=$(sqlite3 "$DB" "SELECT 1 FROM embeddings WHERE record_type='pattern' AND record_id='${id}' LIMIT 1;" 2>/dev/null || echo "")
        [[ -n "$exists" ]] && continue
        
        name=$(echo "$line" | jq -r '.name // ""')
        problem=$(echo "$line" | jq -r '.problem // ""')
        solution=$(echo "$line" | jq -r '.solution // ""')
        content="${name}: ${problem} ${solution}"
        
        embedding=$(generate_embedding "$content")
        [[ -z "$embedding" ]] && continue
        
        sqlite3 "$DB" "INSERT OR REPLACE INTO embeddings(record_type, record_id, content_text, embedding, created_at)
            VALUES ('pattern', $(sql_quote "$id"), $(sql_quote "$content"), $(sql_quote "$embedding"), datetime('now'));"
        count=$((count + 1))
    done < <(yq -o=json '.patterns[]' "$PATTERNS_FILE" 2>/dev/null | jq -c '.')
    
    # Embed transfers
    for session_file in "$SESSIONS_DIR"/session-*.json; do
        [[ -f "$session_file" ]] || continue
        [[ "$session_file" == *".compressed."* ]] && continue
        [[ "$session_file" == *"example"* ]] && continue
        
        local session_id handoff embedding
        session_id=$(jq -r '.id // ""' "$session_file")
        [[ -z "$session_id" ]] && continue
        
        # Check if embedding already exists
        local exists
        exists=$(sqlite3 "$DB" "SELECT 1 FROM embeddings WHERE record_type='transfer' AND record_id='${session_id}' LIMIT 1;" 2>/dev/null || echo "")
        [[ -n "$exists" ]] && continue
        
        handoff=$(jq -r '.handoff.message // ""' "$session_file")
        [[ -z "$handoff" ]] && continue
        
        embedding=$(generate_embedding "$handoff")
        [[ -z "$embedding" ]] && continue
        
        sqlite3 "$DB" "INSERT OR REPLACE INTO embeddings(record_type, record_id, content_text, embedding, created_at)
            VALUES ('transfer', $(sql_quote "$session_id"), $(sql_quote "$handoff"), $(sql_quote "$embedding"), datetime('now'));"
        count=$((count + 1))
    done
    
    echo "  Generated ${count} new embeddings"
}

# --- Commands ---

cmd_build() {
    local skip_embeddings=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --no-embeddings) skip_embeddings=true; shift ;;
            *) shift ;;
        esac
    done

    echo "Building search index at $DB ..."

    # Drop existing FTS tables for clean rebuild
    if [[ -f "$DB" ]]; then
        sqlite3 "$DB" <<'SQL'
DROP TABLE IF EXISTS decisions;
DROP TABLE IF EXISTS patterns;
DROP TABLE IF EXISTS transfers;
SQL
    fi

    create_schema
    load_decisions
    load_patterns
    load_transfers
    
    # Phase 2: Generate embeddings
    if [[ "$skip_embeddings" != "true" ]]; then
        load_embeddings
    fi
    
    echo "Done."
    index_stats
}

# Semantic search using vector similarity
# Finds semantically similar records even without keyword matches
semantic_search() {
    local query="$1"
    local limit="${2:-10}"
    
    if ! ollama_available; then
        echo "Error: Ollama not available for semantic search" >&2
        return 1
    fi
    
    # Generate query embedding
    local query_embedding
    query_embedding=$(generate_embedding "$query")
    
    if [[ -z "$query_embedding" ]]; then
        echo "Error: Failed to generate query embedding" >&2
        return 1
    fi
    
    # Compute similarity for all embeddings using Python
    # This is O(n) but acceptable for small datasets
    python3 - "$query_embedding" "$DB" "$limit" <<'PYTHON'
import sys
import json
import sqlite3
import math

def cosine_similarity(a, b):
    dot = sum(x*y for x, y in zip(a, b))
    norm_a = math.sqrt(sum(x*x for x in a))
    norm_b = math.sqrt(sum(x*x for x in b))
    if norm_a == 0 or norm_b == 0:
        return 0.0
    return dot / (norm_a * norm_b)

query_embedding = json.loads(sys.argv[1])
db_path = sys.argv[2]
limit = int(sys.argv[3])

conn = sqlite3.connect(db_path)
cursor = conn.cursor()

results = []
cursor.execute("SELECT record_type, record_id, content_text, embedding FROM embeddings")
for row in cursor.fetchall():
    record_type, record_id, content_text, embedding_json = row
    try:
        embedding = json.loads(embedding_json)
        similarity = cosine_similarity(query_embedding, embedding)
        results.append((record_type, record_id, content_text[:120], similarity))
    except (json.JSONDecodeError, TypeError):
        continue

conn.close()

# Sort by similarity descending
results.sort(key=lambda x: x[3], reverse=True)

# Print header
print("type|id|content|similarity")

# Print top results
for record_type, record_id, content, similarity in results[:limit]:
    content = content.replace('\n', ' ').replace('|', ' ')
    print(f"{record_type}|{record_id}|{content}|{similarity:.4f}")
PYTHON
}

# Hybrid search: combines FTS5 BM25 with vector similarity
# Uses Reciprocal Rank Fusion to merge results
hybrid_search() {
    local query="$1"
    local project="${2:-}"
    local limit="${3:-10}"
    
    # Get FTS5 results
    local fts_results
    fts_results=$(search_query "$query" "$project" 20 2>/dev/null || echo "")
    
    # Get semantic results if Ollama available
    local semantic_results=""
    if ollama_available; then
        semantic_results=$(semantic_search "$query" 20 2>/dev/null | tail -n +2 || echo "")
    fi
    
    # Merge using Reciprocal Rank Fusion
    python3 - "$fts_results" "$semantic_results" "$limit" <<'PYTHON'
import sys
from collections import defaultdict

fts_raw = sys.argv[1]
semantic_raw = sys.argv[2]
limit = int(sys.argv[3])

# Parse FTS results (skip header)
fts_ranks = {}
for i, line in enumerate(fts_raw.strip().split('\n')[1:], 1):
    if not line or '|' not in line:
        continue
    parts = line.split('|')
    if len(parts) >= 2:
        key = (parts[0], parts[1])  # (type, id)
        fts_ranks[key] = i

# Parse semantic results
semantic_ranks = {}
for i, line in enumerate(semantic_raw.strip().split('\n'), 1):
    if not line or '|' not in line:
        continue
    parts = line.split('|')
    if len(parts) >= 2:
        key = (parts[0], parts[1])
        semantic_ranks[key] = i

# Reciprocal Rank Fusion
# RRF score = sum(1 / (k + rank)) where k=60 is a constant
K = 60
scores = defaultdict(float)
content_map = {}

# Score from FTS
for i, line in enumerate(fts_raw.strip().split('\n')[1:], 1):
    if not line or '|' not in line:
        continue
    parts = line.split('|')
    if len(parts) >= 3:
        key = (parts[0], parts[1])
        scores[key] += 1.0 / (K + i)
        if key not in content_map:
            content_map[key] = parts[2][:100] if len(parts) > 2 else ""

# Score from semantic
for i, line in enumerate(semantic_raw.strip().split('\n'), 1):
    if not line or '|' not in line:
        continue
    parts = line.split('|')
    if len(parts) >= 3:
        key = (parts[0], parts[1])
        scores[key] += 1.0 / (K + i)
        if key not in content_map:
            content_map[key] = parts[2][:100] if len(parts) > 2 else ""

# Sort by RRF score
ranked = sorted(scores.items(), key=lambda x: x[1], reverse=True)

# Output
print("type|id|content|rrf_score")
for (record_type, record_id), score in ranked[:limit]:
    content = content_map.get((record_type, record_id), "").replace('\n', ' ').replace('|', ' ')
    print(f"{record_type}|{record_id}|{content}|{score:.4f}")
PYTHON
}

cmd_search() {
    if [[ ! -f "$DB" ]]; then
        echo "Index not found. Building..." >&2
        cmd_build >&2
    fi

    local query="${1:?Usage: search-index.sh search <query> [--project P] [--limit N] [--mode fts|semantic|hybrid]}"
    shift
    local project="" limit="10" mode="fts"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --project|-p) project="$2"; shift 2 ;;
            --limit|-n)   limit="$2"; shift 2 ;;
            --mode|-m)    mode="$2"; shift 2 ;;
            --semantic)   mode="semantic"; shift ;;
            --hybrid)     mode="hybrid"; shift ;;
            *) shift ;;
        esac
    done

    case "$mode" in
        fts)      search_query "$query" "$project" "$limit" ;;
        semantic) semantic_search "$query" "$limit" ;;
        hybrid)   hybrid_search "$query" "$project" "$limit" ;;
        *)        echo "Unknown mode: $mode" >&2; return 1 ;;
    esac
}

cmd_semantic() {
    if [[ ! -f "$DB" ]]; then
        echo "Index not found. Building..." >&2
        cmd_build >&2
    fi

    local query="${1:?Usage: search-index.sh semantic <query> [--limit N]}"
    shift
    local limit="10"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --limit|-n) limit="$2"; shift 2 ;;
            *) shift ;;
        esac
    done

    semantic_search "$query" "$limit"
}

cmd_hybrid() {
    if [[ ! -f "$DB" ]]; then
        echo "Index not found. Building..." >&2
        cmd_build >&2
    fi

    local query="${1:?Usage: search-index.sh hybrid <query> [--project P] [--limit N]}"
    shift
    local project="" limit="10"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --project|-p) project="$2"; shift 2 ;;
            --limit|-n)   limit="$2"; shift 2 ;;
            *) shift ;;
        esac
    done

    hybrid_search "$query" "$project" "$limit"
}

cmd_log_access() {
    local type="${1:?Usage: search-index.sh log-access <type> <id>}"
    local id="${2:?Usage: search-index.sh log-access <type> <id>}"
    log_access "$type" "$id"
}

cmd_stats() {
    if [[ ! -f "$DB" ]]; then
        echo "No index found at $DB" >&2
        return 1
    fi
    index_stats
}

# --- Main ---

main() {
    [[ $# -eq 0 ]] && {
        echo "Usage: search-index.sh <command> [options]"
        echo ""
        echo "Commands:"
        echo "  build [--no-embeddings]     Build/rebuild the search index"
        echo "  search <query>              Search (FTS5 by default)"
        echo "  semantic <query>            Semantic search using embeddings"
        echo "  hybrid <query>              Hybrid search (FTS5 + semantic)"
        echo "  log-access <type> <id>      Log access for reinforcement"
        echo "  stats                       Show index statistics"
        echo ""
        echo "Search options:"
        echo "  --project, -p <name>        Boost results from project"
        echo "  --limit, -n <num>           Max results (default 10)"
        echo "  --mode, -m <fts|semantic|hybrid>  Search mode"
        exit 1
    }

    case "$1" in
        build)      shift; cmd_build "$@" ;;
        search)     shift; cmd_search "$@" ;;
        semantic)   shift; cmd_semantic "$@" ;;
        hybrid)     shift; cmd_hybrid "$@" ;;
        log-access) shift; cmd_log_access "$@" ;;
        stats)      shift; cmd_stats "$@" ;;
        *)
            echo "Unknown command: $1" >&2
            echo "Usage: search-index.sh <build|search|semantic|hybrid|log-access|stats>"
            exit 1
            ;;
    esac
}

# Only run main if executed directly (not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
