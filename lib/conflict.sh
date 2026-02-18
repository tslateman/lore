#!/usr/bin/env bash
# Conflict detection for lore learn/remember commands
# Checks for near-duplicate patterns and decisions before writing.
# Uses FTS5 search.db when available, falls back to flat-file grep.

set -euo pipefail

LORE_DIR="${LORE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "${LORE_DIR}/lib/paths.sh"
SEARCH_DB="${LORE_SEARCH_DB}"

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
    local decisions_file="${LORE_DECISIONS_FILE}"

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
    local patterns_file="${LORE_PATTERNS_FILE}"

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

# Extract entities from text (file paths, function names, backtick-quoted terms).
# Reuses capture.sh logic but works standalone for conflict checking.
_extract_entities_for_conflict() {
    local text="$1"
    local entities=()

    # File paths (e.g., src/main.rs, lib/utils.py)
    while IFS= read -r match; do
        [[ -n "$match" ]] && entities+=("$match")
    done < <(echo "$text" | grep -oE '[a-zA-Z0-9_/-]+\.[a-zA-Z]{1,4}' 2>/dev/null | sort -u || true)

    # Function/method names (e.g., parse_config(), handleEvent)
    while IFS= read -r match; do
        [[ -n "$match" ]] && entities+=("$match")
    done < <(echo "$text" | grep -oE '[a-z_][a-zA-Z0-9_]*\(\)' 2>/dev/null | sed 's/()$//' | sort -u || true)

    # Backtick-quoted terms
    while IFS= read -r match; do
        [[ -n "$match" ]] && entities+=("$match")
    done < <(echo "$text" | grep -oE '`[^`]+`' 2>/dev/null | sed 's/`//g' | sort -u || true)

    # Significant capitalized terms (proper nouns, tool names — 3+ chars)
    while IFS= read -r match; do
        [[ -n "$match" ]] && entities+=("$match")
    done < <(echo "$text" | grep -oE '\b[A-Z][a-zA-Z]{2,}\b' 2>/dev/null | sort -u || true)

    printf '%s\n' "${entities[@]}" 2>/dev/null | grep -v '^$' | sort -u || true
}

# Count entity overlap between two newline-separated entity lists.
_entity_overlap_count() {
    local entities_a="$1"
    local entities_b="$2"

    [[ -z "$entities_a" || -z "$entities_b" ]] && { echo 0; return; }

    local count
    count=$(comm -12 <(echo "$entities_a" | sort -u) <(echo "$entities_b" | sort -u) | wc -l | tr -d ' ')
    echo "$count"
}

# Check for contradictions: decisions that share entities but say different things.
# Returns 0 always (warn only, never block). Prints warnings to stderr.
# Usage: lore_check_contradiction <new_decision_text> [new_decision_id]
lore_check_contradiction() {
    local content="$1"
    local new_id="${2:-}"
    local decisions_file="${LORE_DECISIONS_FILE}"

    [[ -f "$decisions_file" ]] || return 0

    # Extract entities from the new decision
    local new_entities
    new_entities=$(_extract_entities_for_conflict "$content")

    # Need at least 1 entity to check for contradictions
    local entity_count
    entity_count=$(echo "$new_entities" | grep -c . 2>/dev/null || true)
    [[ "$entity_count" -lt 1 ]] && return 0

    # Get unique active decisions (latest version of each ID, exclude retracted/superseded)
    local unique_decisions
    unique_decisions=$(jq -s '
        group_by(.id) | map(.[-1])[]
        | select((.status // "active") == "active")
        | {id, decision, rationale, entities}
    ' -c "$decisions_file" 2>/dev/null) || return 0

    [[ -z "$unique_decisions" ]] && return 0

    local contradictions=""

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue

        local existing_id existing_text existing_entities_json
        existing_id=$(echo "$line" | jq -r '.id')

        # Skip self-comparison
        [[ -n "$new_id" && "$existing_id" == "$new_id" ]] && continue

        existing_text=$(echo "$line" | jq -r '(.decision // "") + " " + (.rationale // "")')

        # Extract entities from existing decision
        local existing_entities
        existing_entities=$(_extract_entities_for_conflict "$existing_text")

        # Count shared entities
        local overlap
        overlap=$(_entity_overlap_count "$new_entities" "$existing_entities")

        # Need 2+ shared entities for a contradiction candidate
        [[ "$overlap" -lt 2 ]] && continue

        # Check text similarity — contradictions have LOW similarity (same topic, different conclusion)
        local sim
        sim=$(_jaccard_similarity "$content" "$existing_text")

        # High similarity = duplicate (handled by dedup). Low similarity with shared entities = contradiction.
        # Skip if too similar (>= 50% = likely same conclusion) or moderately similar (30-50% = probably related)
        [[ "$sim" -ge 30 ]] && continue

        local short_text
        short_text=$(echo "$line" | jq -r '.decision[0:80]')
        contradictions="${contradictions}${existing_id}|${overlap}|${sim}|${short_text}\n"

        # Create graph edge if both nodes exist
        if [[ -n "$new_id" ]]; then
            _try_add_contradiction_edge "$new_id" "$existing_id" 2>/dev/null || true
        fi
    done <<< "$unique_decisions"

    if [[ -n "$contradictions" ]]; then
        echo -e "${YELLOW}Potential contradiction(s) detected:${NC}" >&2
        echo -e "$contradictions" | while IFS='|' read -r cid overlap sim text; do
            [[ -z "$cid" ]] && continue
            echo -e "  ${BOLD}${cid}${NC} ${DIM}(${overlap} shared entities, ${sim}% text similarity)${NC}" >&2
            echo -e "  ${CYAN}${text}${NC}" >&2
            echo "" >&2
        done
        echo -e "${DIM}These decisions share entities but reach different conclusions.${NC}" >&2
        echo -e "${DIM}Review and resolve with: journal.sh retract <id> or journal.sh supersede <id> --by <new-id>${NC}" >&2
    fi

    return 0  # Always allow write
}

# Try to add a contradicts edge in the graph (best-effort).
_try_add_contradiction_edge() {
    local from_id="$1"
    local to_id="$2"
    local graph_file="${LORE_GRAPH_FILE}"

    [[ -f "$graph_file" ]] || return 0

    # Check both nodes exist in graph
    local from_exists to_exists
    from_exists=$(jq -r --arg id "$from_id" '.nodes[$id] // empty' "$graph_file" 2>/dev/null) || return 0
    to_exists=$(jq -r --arg id "$to_id" '.nodes[$id] // empty' "$graph_file" 2>/dev/null) || return 0

    [[ -z "$from_exists" || -z "$to_exists" ]] && return 0

    # Check if edge already exists
    local existing
    existing=$(jq -r --arg from "$from_id" --arg to "$to_id" \
        '.edges[] | select(.from == $from and .to == $to and .relation == "contradicts") | .from' \
        "$graph_file" 2>/dev/null) || return 0

    [[ -n "$existing" ]] && return 0

    # Add contradicts edge
    local timestamp
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    jq --arg from "$from_id" --arg to "$to_id" --arg created "$timestamp" \
        '.edges += [{from: $from, to: $to, relation: "contradicts", weight: 1.0, bidirectional: true, status: "active", created_at: $created}]' \
        "$graph_file" > "${graph_file}.tmp" && mv "${graph_file}.tmp" "$graph_file"
}
