#!/usr/bin/env bash
#
# Session Search - Search across session content
#
# Uses FTS5 index when available, falls back to grep otherwise.
#

#######################################
# Search sessions using FTS5 index
#######################################
search_sessions_fts5() {
    local query="$1"
    local limit="$2"
    local db="$3"

    # Escape single quotes for SQL
    local safe_query="${query//\'/\'\'}"

    local results
    results=$(sqlite3 -separator $'\t' "${db}" <<SQL 2>/dev/null
SELECT 
    session_id,
    SUBSTR(handoff, 1, 80) as preview,
    SUBSTR(timestamp, 1, 10) as date,
    ROUND(bm25(transfers) * -1, 2) as score
FROM transfers 
WHERE transfers MATCH '${safe_query}'
ORDER BY score DESC
LIMIT ${limit};
SQL
    ) || true

    if [[ -z "${results}" ]]; then
        echo "No sessions found matching: ${query}"
        return 0
    fi

    printf "%-45s %-12s %s\n" "SESSION ID" "DATE" "PREVIEW"
    printf "%s\n" "$(printf '=%.0s' {1..90})"

    while IFS=$'\t' read -r session_id preview date score; do
        printf "%-45s %-12s %s\n" "${session_id}" "${date}" "${preview:0:60}"
    done <<< "${results}"
}

#######################################
# Search sessions using grep fallback
#######################################
search_sessions_grep() {
    local query="$1"
    local limit="$2"

    local matches=0
    local results=""

    for session_file in "${SESSIONS_DIR}"/*.json; do
        [[ -f "${session_file}" ]] || continue

        if grep -qi "${query}" "${session_file}" 2>/dev/null; then
            local id date summary
            id=$(jq -r '.id' "${session_file}")
            date=$(jq -r '.started_at[0:10]' "${session_file}")
            summary=$(jq -r '.summary // .handoff.message // "No summary"' "${session_file}" | head -c 60)

            results="${results}${id}\t${date}\t${summary}\n"
            matches=$((matches + 1))

            [[ ${matches} -ge ${limit} ]] && break
        fi
    done

    if [[ ${matches} -eq 0 ]]; then
        echo "No sessions found matching: ${query}"
        return 0
    fi

    printf "%-45s %-12s %s\n" "SESSION ID" "DATE" "PREVIEW"
    printf "%s\n" "$(printf '=%.0s' {1..90})"

    echo -e "${results}" | while IFS=$'\t' read -r session_id date preview; do
        [[ -n "${session_id}" ]] && printf "%-45s %-12s %s\n" "${session_id}" "${date}" "${preview}"
    done
}

#######################################
# Main search function
# Uses FTS5 when available, grep otherwise
#######################################
search_sessions() {
    local query="${1:-}"
    local limit="${2:-10}"

    if [[ -z "${query}" ]]; then
        echo "Usage: transfer.sh search <query> [limit]"
        return 1
    fi

    local search_db="${LORE_SEARCH_DB:-$HOME/.lore/search.db}"

    echo "Searching sessions for: ${query}"
    echo ""

    if [[ -f "${search_db}" ]]; then
        search_sessions_fts5 "${query}" "${limit}" "${search_db}"
    else
        echo "(Using grep fallback - run 'lore index' for ranked search)"
        echo ""
        search_sessions_grep "${query}" "${limit}"
    fi
}
