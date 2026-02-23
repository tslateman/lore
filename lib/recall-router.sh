#!/usr/bin/env bash
# recall-router.sh - Tiered query routing across Lore and Engram
#
# Routes queries to the right system based on query shape, enriches shadow
# memories with full Lore records, and marks provenance on all results.
#
# Public API:
#   classify_query "$query"              → lore-first | memory-first | both
#   query_claude_memory "$query" [limit] → tab-separated results
#   enrich_lore_shadow "$content"        → enrichment lines
#   routed_recall "$query" [compact] [limit]

set -euo pipefail

LORE_DIR="${LORE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "${LORE_DIR}/lib/paths.sh"

CLAUDE_MEMORY_DB="${CLAUDE_MEMORY_DB:-${HOME}/.claude/memory.sqlite}"

# --- classify_query ---
# Keyword-based routing heuristic.
# Returns: lore-first | memory-first | both
classify_query() {
    local q
    q=$(echo "$1" | tr '[:upper:]' '[:lower:]')

    # Structural/archival knowledge → lore-first
    if echo "$q" | grep -qE '(decision|rationale|why did|why we|pattern|anti.pattern|failure|trigger|error.type|alternative|architecture)'; then
        echo "lore-first"
        return
    fi

    # Temporal/working knowledge → memory-first
    if echo "$q" | grep -qE '(working on|recent|session|connect|remember|preference|convention|what was i|currently|debugging|episode)'; then
        echo "memory-first"
        return
    fi

    echo "both"
}

# --- query_claude_memory ---
# LIKE query against Engram's memory.sqlite.
# Outputs tab-separated: id, snippet, topic, source, importance.
# Returns 0 if DB missing or query fails.
query_claude_memory() {
    local query="$1"
    local limit="${2:-10}"
    local db="$CLAUDE_MEMORY_DB"

    [[ ! -f "$db" ]] && return 0

    # Build WHERE clause: require each word (>= 3 chars) to appear
    local where_parts=""
    for word in $query; do
        [[ ${#word} -lt 3 ]] && continue
        local safe_word="${word//\'/\'\'}"
        [[ -n "$where_parts" ]] && where_parts+=" AND "
        where_parts+="content LIKE '%${safe_word}%'"
    done
    [[ -z "$where_parts" ]] && {
        local safe_q="${query//\'/\'\'}"
        where_parts="content LIKE '%${safe_q}%'"
    }

    sqlite3 -separator $'\t' "$db" \
        "SELECT id, SUBSTR(content, 1, 120), COALESCE(topic, ''), COALESCE(source, ''), importance
         FROM Memory
         WHERE (${where_parts}) AND importance > 0
         ORDER BY importance DESC, lastAccessedAt DESC
         LIMIT ${limit};" \
        2>/dev/null || true
}

# --- enrich_lore_shadow ---
# Follow [lore:{id}] prefix in shadow content to full Lore record.
# Prints enrichment lines (rationale, tags, context, etc.).
enrich_lore_shadow() {
    local content="$1"
    local lore_id=""

    if [[ "$content" =~ \[lore:([^\]]+)\] ]]; then
        lore_id="${BASH_REMATCH[1]}"
    fi
    [[ -z "$lore_id" ]] && return 0

    _enrich_by_id "$lore_id"
}

# Internal: enrich by Lore record ID (dec-*, pat-*, trigger-*, sess-*)
_enrich_by_id() {
    local lore_id="$1"

    case "$lore_id" in
        dec-*)
            [[ ! -f "$LORE_DECISIONS_FILE" ]] && return 0
            local record
            record=$(jq -sc --arg id "$lore_id" \
                'map(select(.id == $id)) | last' \
                "$LORE_DECISIONS_FILE" 2>/dev/null) || return 0
            [[ -z "$record" || "$record" == "null" ]] && return 0

            local rationale alternatives tags
            rationale=$(echo "$record" | jq -r '.rationale // ""') || true
            alternatives=$(echo "$record" | jq -r '(.alternatives // []) | join(", ")') || true
            tags=$(echo "$record" | jq -r '(.tags // []) | join(", ")') || true
            [[ -n "$rationale" ]] && echo "    Rationale: ${rationale}"
            [[ -n "$alternatives" ]] && echo "    Alternatives: ${alternatives}"
            [[ -n "$tags" ]] && echo "    Tags: ${tags}"
            ;;
        pat-*)
            [[ ! -f "$LORE_PATTERNS_FILE" ]] && return 0
            command -v yq &>/dev/null || return 0

            export LORE_MATCH_ID="$lore_id"
            local ctx prob sol
            ctx=$(yq -r '.patterns[] | select(.id == strenv(LORE_MATCH_ID)) | .context // ""' "$LORE_PATTERNS_FILE" 2>/dev/null) || true
            prob=$(yq -r '.patterns[] | select(.id == strenv(LORE_MATCH_ID)) | .problem // ""' "$LORE_PATTERNS_FILE" 2>/dev/null) || true
            sol=$(yq -r '.patterns[] | select(.id == strenv(LORE_MATCH_ID)) | .solution // ""' "$LORE_PATTERNS_FILE" 2>/dev/null) || true
            unset LORE_MATCH_ID
            [[ -n "$ctx" ]] && echo "    Context: ${ctx}"
            [[ -n "$prob" ]] && echo "    Problem: ${prob}"
            [[ -n "$sol" ]] && echo "    Solution: ${sol}"
            ;;
        trigger-*)
            echo "    (failure trigger summary)"
            ;;
        sess-*)
            echo "    (session handoff)"
            ;;
    esac
}

# --- Main entry point ---

routed_recall() {
    local query="$1"
    local compact="${2:-false}"
    local limit="${3:-10}"
    local graph_depth="${4:-0}"

    local route
    route=$(classify_query "$query")

    case "$route" in
        lore-first)   _route_lore_first "$query" "$compact" "$limit" "$graph_depth" ;;
        memory-first) _route_memory_first "$query" "$compact" "$limit" "$graph_depth" ;;
        both)         _route_both "$query" "$compact" "$limit" "$graph_depth" ;;
    esac
}

# --- Internal routing ---

# Query Lore search (compact), returns result lines
_query_lore() {
    "$LORE_DIR/lore.sh" search "$1" --compact 2>/dev/null || true
}

# Extract Lore record ID from a compact search result line.
# Format: "  [type    ] id               | content..."
_extract_id_from_line() {
    echo "$1" | awk -F'[]|]' '{gsub(/^ +| +$/, "", $2); print $2}'
}

# Format a Lore compact line with (lore) provenance
_emit_lore_line() {
    local line="$1" compact="$2"

    if [[ "$compact" == true ]]; then
        echo "  (lore) ${line#  }"
    else
        local record_id content type
        record_id=$(_extract_id_from_line "$line")
        content=$(echo "$line" | awk -F'|' '{gsub(/^ +| +$/, "", $2); print $2}')
        type=$(echo "$line" | grep -oE '\[[a-z_]+' | tr -d '[') || type="unknown"

        echo "  [${type}] ${record_id}: ${content} (source: lore)"
        [[ -n "$record_id" ]] && _enrich_by_id "$record_id"
        echo ""
    fi
}

# Format a Engram result with provenance
_emit_mem_line() {
    local id="$1" snippet="$2" topic="$3" source="$4" importance="$5" compact="$6"

    local is_shadow=false
    local lore_id=""
    if [[ "$snippet" =~ \[lore:([^\]]+)\] ]]; then
        is_shadow=true
        lore_id="${BASH_REMATCH[1]}"
    fi

    # Strip shadow prefix and hash suffix for clean display
    local clean
    clean=$(echo "$snippet" | sed 's/\[lore:[^]]*\] //' | sed 's/ <!-- hash:[a-f0-9]* -->//')

    if [[ "$compact" == true ]]; then
        local title="${clean:0:40}"
        if [[ "$is_shadow" == true ]]; then
            printf "  (lore) [%-10s] %-16s | %-40s | %-8s | %s | %s\n" \
                "${topic}" "$lore_id" "$title" "" "" "$importance"
        else
            printf "  (mem)  [%-10s] %-16s | %-40s | %-8s | %s | %s\n" \
                "${topic}" "--" "$title" "" "" "$importance"
        fi
    else
        if [[ "$is_shadow" == true ]]; then
            echo "  [${topic}] ${lore_id}: ${clean} (source: lore)"
            _enrich_by_id "$lore_id"
        else
            echo "  [${topic}] id:${id}: ${clean} (source: memory)"
        fi
        echo ""
    fi
}

# --- Route: lore-first ---
_route_lore_first() {
    local query="$1" compact="$2" limit="$3" graph_depth="${4:-0}"

    [[ "$compact" != true ]] && echo "Routed recall (lore-first):" >&2

    local lore_output seen_ids=() lore_count=0
    lore_output=$(_query_lore "$query")

    if [[ -n "$lore_output" ]]; then
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            _emit_lore_line "$line" "$compact"
            local rid
            rid=$(_extract_id_from_line "$line") || true
            [[ -n "$rid" ]] && seen_ids+=("$rid")
            lore_count=$((lore_count + 1))
        done <<< "$lore_output"
    fi

    # If graph traversal requested and we have results, expand
    if [[ "$graph_depth" -gt 0 && -n "$lore_output" ]]; then
        # Extract Lore IDs from results
        local lore_ids
        lore_ids=$(echo "$lore_output" | grep -oE '(dec|pat|obs|trigger|sess)-[a-f0-9]+' | head -5 | tr '\n' ',' | sed 's/,$//')

        if [[ -n "$lore_ids" ]]; then
            # Cross-system traverse
            local expanded
            expanded=$(cross_system_traverse "$lore_ids" "$graph_depth" 2>/dev/null)

            if [[ -n "$expanded" ]]; then
                # Format and emit Lore results
                echo "$expanded" | jq -r '.[] | select(.source == "lore") | "\(.id): \(.content)"' 2>/dev/null | while read -r line; do
                    [[ -z "$line" ]] && continue
                    if [[ "$compact" == true ]]; then
                        echo "  (lore) $line"
                    else
                        echo "  $line (source: lore)"
                    fi
                done

                # Format and emit Engram results
                echo "$expanded" | jq -r '.[] | select(.source == "mem") | "\(.id): \(.content)"' 2>/dev/null | while read -r line; do
                    [[ -z "$line" ]] && continue
                    if [[ "$compact" == true ]]; then
                        echo "  (mem)  $line"
                    else
                        echo "  $line (source: memory)"
                    fi
                done
            fi
            return 0
        fi
    fi

    [[ "$lore_count" -ge "$limit" ]] && return 0

    # Fallback to Engram
    local mem_results
    mem_results=$(query_claude_memory "$query" "$limit")
    [[ -z "$mem_results" ]] && return 0

    while IFS=$'\t' read -r mid msnip mtop msrc mimp; do
        [[ -z "$mid" ]] && continue
        # Dedup shadows already in Lore results
        if [[ "$msnip" =~ \[lore:([^\]]+)\] ]]; then
            local lid="${BASH_REMATCH[1]}"
            local skip=false
            for sid in "${seen_ids[@]+"${seen_ids[@]}"}"; do
                [[ "$sid" == "$lid" ]] && { skip=true; break; }
            done
            [[ "$skip" == true ]] && continue
        fi
        _emit_mem_line "$mid" "$msnip" "$mtop" "$msrc" "$mimp" "$compact"
    done <<< "$mem_results"
}

# --- Route: memory-first ---
_route_memory_first() {
    local query="$1" compact="$2" limit="$3" graph_depth="${4:-0}"

    [[ "$compact" != true ]] && echo "Routed recall (memory-first):" >&2

    local mem_results seen_lore_ids=() mem_count=0
    mem_results=$(query_claude_memory "$query" "$limit")

    if [[ -n "$mem_results" ]]; then
        while IFS=$'\t' read -r mid msnip mtop msrc mimp; do
            [[ -z "$mid" ]] && continue
            _emit_mem_line "$mid" "$msnip" "$mtop" "$msrc" "$mimp" "$compact"
            if [[ "$msnip" =~ \[lore:([^\]]+)\] ]]; then
                seen_lore_ids+=("${BASH_REMATCH[1]}")
            fi
            mem_count=$((mem_count + 1))
        done <<< "$mem_results"
    fi

    # If graph traversal requested and we have shadow results, expand
    if [[ "$graph_depth" -gt 0 && ${#seen_lore_ids[@]} -gt 0 ]]; then
        # Use shadow Lore IDs as starting points
        local lore_ids
        lore_ids=$(printf "%s," "${seen_lore_ids[@]}" | sed 's/,$//')

        if [[ -n "$lore_ids" ]]; then
            # Cross-system traverse
            local expanded
            expanded=$(cross_system_traverse "$lore_ids" "$graph_depth" 2>/dev/null)

            if [[ -n "$expanded" ]]; then
                # Format and emit results
                echo "$expanded" | jq -r '.[] | select(.source == "lore") | "\(.id): \(.content)"' 2>/dev/null | while read -r line; do
                    [[ -z "$line" ]] && continue
                    if [[ "$compact" == true ]]; then
                        echo "  (lore) $line"
                    else
                        echo "  $line (source: lore)"
                    fi
                done

                echo "$expanded" | jq -r '.[] | select(.source == "mem") | "\(.id): \(.content)"' 2>/dev/null | while read -r line; do
                    [[ -z "$line" ]] && continue
                    if [[ "$compact" == true ]]; then
                        echo "  (mem)  $line"
                    else
                        echo "  $line (source: memory)"
                    fi
                done
            fi
            return 0
        fi
    fi

    [[ "$mem_count" -ge "$limit" ]] && return 0

    # Fallback to Lore
    local lore_output
    lore_output=$(_query_lore "$query")
    [[ -z "$lore_output" ]] && return 0

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local rid
        rid=$(_extract_id_from_line "$line") || true
        local skip=false
        for sid in "${seen_lore_ids[@]+"${seen_lore_ids[@]}"}"; do
            [[ "$sid" == "$rid" ]] && { skip=true; break; }
        done
        [[ "$skip" == true ]] && continue
        _emit_lore_line "$line" "$compact"
    done <<< "$lore_output"
}

# --- Route: both ---
_route_both() {
    local query="$1" compact="$2" limit="$3" graph_depth="${4:-0}"

    [[ "$compact" != true ]] && echo "Routed recall (both):" >&2

    local lore_output mem_results
    lore_output=$(_query_lore "$query")
    mem_results=$(query_claude_memory "$query" "$limit") || true

    # Emit Lore results, track IDs for dedup
    local lore_ids=()
    if [[ -n "$lore_output" ]]; then
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            _emit_lore_line "$line" "$compact"
            local rid
            rid=$(_extract_id_from_line "$line") || true
            [[ -n "$rid" ]] && lore_ids+=("$rid")
        done <<< "$lore_output"
    fi

    # Emit Memory results, skip shadows already shown
    if [[ -n "$mem_results" ]]; then
        while IFS=$'\t' read -r mid msnip mtop msrc mimp; do
            [[ -z "$mid" ]] && continue
            if [[ "$msnip" =~ \[lore:([^\]]+)\] ]]; then
                local lid="${BASH_REMATCH[1]}"
                local skip=false
                for sid in "${lore_ids[@]+"${lore_ids[@]}"}"; do
                    [[ "$sid" == "$lid" ]] && { skip=true; break; }
                done
                [[ "$skip" == true ]] && continue
            fi
            _emit_mem_line "$mid" "$msnip" "$mtop" "$msrc" "$mimp" "$compact"
        done <<< "$mem_results"
    fi

    # If graph traversal requested and we have results, expand
    if [[ "$graph_depth" -gt 0 && ${#lore_ids[@]} -gt 0 ]]; then
        # Use all Lore IDs as starting points
        local ids_csv
        ids_csv=$(printf "%s," "${lore_ids[@]}" | sed 's/,$//')

        if [[ -n "$ids_csv" ]]; then
            # Cross-system traverse
            local expanded
            expanded=$(cross_system_traverse "$ids_csv" "$graph_depth" 2>/dev/null)

            if [[ -n "$expanded" ]]; then
                # Format and emit results
                echo "$expanded" | jq -r '.[] | select(.source == "lore") | "\(.id): \(.content)"' 2>/dev/null | while read -r line; do
                    [[ -z "$line" ]] && continue
                    if [[ "$compact" == true ]]; then
                        echo "  (lore) $line"
                    else
                        echo "  $line (source: lore)"
                    fi
                done

                echo "$expanded" | jq -r '.[] | select(.source == "mem") | "\(.id): \(.content)"' 2>/dev/null | while read -r line; do
                    [[ -z "$line" ]] && continue
                    if [[ "$compact" == true ]]; then
                        echo "  (mem)  $line"
                    else
                        echo "  $line (source: memory)"
                    fi
                done
            fi
            return 0
        fi
    fi

    if [[ -z "$lore_output" && -z "$mem_results" ]]; then
        [[ "$compact" != true ]] && echo "  (no results)"
    fi
}

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
  AND m.content NOT LIKE '[lore:%'
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

        # Only follow edges if we haven't reached max depth
        if current_depth < max_depth:
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

        # Only follow edges if we haven't reached max depth
        if current_depth < max_depth:
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
