#!/usr/bin/env bash
# Conflict detection for lore learn/remember commands
# Checks for near-duplicate patterns and decisions before writing.
# Uses FTS5 search.db when available, falls back to flat-file grep.

set -euo pipefail

LORE_DIR="${LORE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
SEARCH_DB="${SEARCH_DB:-$HOME/.lore/search.db}"

# Colors (inherit from caller if set)
RED="${RED:-\033[0;31m}"
YELLOW="${YELLOW:-\033[1;33m}"
CYAN="${CYAN:-\033[0;36m}"
BOLD="${BOLD:-\033[1m}"
DIM="${DIM:-\033[2m}"
NC="${NC:-\033[0m}"

# Compute Jaccard similarity between two word sets.
# Returns a value 0-100 (integer percentage).
_jaccard_similarity() {
    local text_a="$1"
    local text_b="$2"

    # Normalize: lowercase, strip punctuation, split to sorted unique words
    local words_a words_b
    words_a=$(echo "$text_a" | tr '[:upper:]' '[:lower:]' | tr -cs '[:alnum:]' '\n' | sort -u)
    words_b=$(echo "$text_b" | tr '[:upper:]' '[:lower:]' | tr -cs '[:alnum:]' '\n' | sort -u)

    # Count intersection and union
    local intersection union
    intersection=$(comm -12 <(echo "$words_a") <(echo "$words_b") | wc -l | tr -d ' ')
    union=$(comm <(echo "$words_a") <(echo "$words_b") | sort -u | wc -l | tr -d ' ')

    if [[ "$union" -eq 0 ]]; then
        echo 0
        return
    fi

    # Integer percentage: (intersection * 100) / union
    echo $(( intersection * 100 / union ))
}

# Check for near-duplicate decisions in flat files.
# Returns matching lines as "id|similarity|content" (one per line), empty if none.
_check_decisions_flat() {
    local content="$1"
    local threshold="$2"
    local decisions_file="$LORE_DIR/journal/data/decisions.jsonl"

    [[ -f "$decisions_file" ]] || return 0

    # Deduplicate decisions (latest version of each ID)
    local unique_decisions
    unique_decisions=$(jq -s 'group_by(.id) | map(.[-1])[] | {id, decision, rationale}' -c "$decisions_file" 2>/dev/null) || return 0

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local id existing_text
        id=$(echo "$line" | jq -r '.id')
        existing_text=$(echo "$line" | jq -r '(.decision // "") + " " + (.rationale // "")')

        local sim
        sim=$(_jaccard_similarity "$content" "$existing_text")

        if [[ "$sim" -ge "$threshold" ]]; then
            local short_text
            short_text=$(echo "$line" | jq -r '.decision[0:80]')
            echo "${id}|${sim}|${short_text}"
        fi
    done <<< "$unique_decisions"
}

# Check for near-duplicate patterns in flat files.
_check_patterns_flat() {
    local content="$1"
    local threshold="$2"
    local patterns_file="$LORE_DIR/patterns/data/patterns.yaml"

    [[ -f "$patterns_file" ]] || return 0

    # Extract pattern names+solutions via awk (avoid yq dependency)
    local entries
    entries=$(awk '
        BEGIN { in_patterns = 0 }
        /^patterns:/ { in_patterns = 1; next }
        /^anti_patterns:/ { in_patterns = 0 }
        in_patterns && /- id:/ {
            gsub(/.*id: "/, ""); gsub(/".*/, "")
            id = $0
        }
        in_patterns && /name:/ {
            gsub(/.*name: "/, ""); gsub(/".*/, "")
            name = $0
        }
        in_patterns && /solution:/ {
            gsub(/.*solution: "/, ""); gsub(/".*/, "")
            solution = $0
            print id "|" name " " solution
        }
    ' "$patterns_file" 2>/dev/null) || return 0

    while IFS='|' read -r id existing_text; do
        [[ -z "$id" ]] && continue

        local sim
        sim=$(_jaccard_similarity "$content" "$existing_text")

        if [[ "$sim" -ge "$threshold" ]]; then
            local short_text="${existing_text:0:80}"
            echo "${id}|${sim}|${short_text}"
        fi
    done <<< "$entries"
}

# Check for near-duplicate via FTS5 search.db (faster, ranked).
_check_fts5() {
    local type="$1"   # "decision" or "pattern"
    local content="$2"
    local threshold="$3"

    [[ -f "$SEARCH_DB" ]] || return 1

    # Extract keywords for FTS5 query (top words, skip short ones)
    local keywords
    keywords=$(echo "$content" | tr '[:upper:]' '[:lower:]' | tr -cs '[:alnum:]' '\n' \
        | awk 'length >= 3' | sort | uniq -c | sort -rn | head -5 \
        | awk '{print $2}' | paste -sd' ' -)

    [[ -z "$keywords" ]] && return 1

    local fts_query
    fts_query=$(echo "$keywords" | sed 's/ / OR /g')

    local results
    if [[ "$type" == "decision" ]]; then
        results=$(sqlite3 -separator $'\t' "$SEARCH_DB" "SELECT id, decision FROM decisions WHERE decisions MATCH '$fts_query' LIMIT 20;" 2>/dev/null) || return 1
    else
        results=$(sqlite3 -separator $'\t' "$SEARCH_DB" "SELECT id, name || ' ' || solution FROM patterns WHERE patterns MATCH '$fts_query' LIMIT 20;" 2>/dev/null) || return 1
    fi

    [[ -z "$results" ]] && return 0

    while IFS=$'\t' read -r id existing_text; do
        [[ -z "$id" ]] && continue

        local sim
        sim=$(_jaccard_similarity "$content" "$existing_text")

        if [[ "$sim" -ge "$threshold" ]]; then
            local short_text="${existing_text:0:80}"
            echo "${id}|${sim}|${short_text}"
        fi
    done <<< "$results"
}

# Main entry point: check for duplicates before writing.
# Usage: lore_check_duplicate <type> <content>
#   type: "decision" or "pattern"
#   content: the text to check
# Returns 0 if no duplicates found, 1 if duplicates found (prints warnings).
lore_check_duplicate() {
    local type="$1"
    local content="$2"
    local threshold=70  # 70% Jaccard similarity

    local matches=""

    # Try FTS5 first (faster, pre-filtered)
    if [[ -f "$SEARCH_DB" ]]; then
        matches=$(_check_fts5 "$type" "$content" "$threshold" 2>/dev/null) || true
    fi

    # Fall back to flat-file scan if FTS5 unavailable or returned nothing
    if [[ -z "$matches" ]]; then
        if [[ "$type" == "decision" ]]; then
            matches=$(_check_decisions_flat "$content" "$threshold" 2>/dev/null) || true
        else
            matches=$(_check_patterns_flat "$content" "$threshold" 2>/dev/null) || true
        fi
    fi

    if [[ -z "$matches" ]]; then
        return 0  # No duplicates
    fi

    # Print warnings
    echo -e "${YELLOW}Possible duplicate(s) found:${NC}" >&2
    while IFS='|' read -r id sim text; do
        [[ -z "$id" ]] && continue
        echo -e "  ${BOLD}${id}${NC} ${DIM}(${sim}% similar)${NC}" >&2
        echo -e "  ${CYAN}${text}${NC}" >&2
        echo "" >&2
    done <<< "$matches"
    echo -e "${YELLOW}Use --force to write anyway.${NC}" >&2

    return 1  # Duplicates found
}
