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
    echo -n "  Access log entries: "
    sqlite3 "$DB" "SELECT COUNT(*) FROM access_log;"
    echo -n "  Database size: "
    du -h "$DB" | cut -f1
}

# --- Commands ---

cmd_build() {
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
    echo "Done."
    index_stats
}

cmd_search() {
    if [[ ! -f "$DB" ]]; then
        echo "Index not found. Building..." >&2
        cmd_build >&2
    fi

    local query="${1:?Usage: search-index.sh search <query> [--project P] [--limit N]}"
    shift
    local project="" limit="10"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --project|-p) project="$2"; shift 2 ;;
            --limit|-n)   limit="$2"; shift 2 ;;
            *) shift ;;
        esac
    done

    search_query "$query" "$project" "$limit"
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
        echo "Usage: search-index.sh <build|search|log-access|stats>"
        exit 1
    }

    case "$1" in
        build)      shift; cmd_build "$@" ;;
        search)     shift; cmd_search "$@" ;;
        log-access) shift; cmd_log_access "$@" ;;
        stats)      shift; cmd_stats "$@" ;;
        *)
            echo "Unknown command: $1" >&2
            echo "Usage: search-index.sh <build|search|log-access|stats>"
            exit 1
            ;;
    esac
}

# Only run main if executed directly (not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
