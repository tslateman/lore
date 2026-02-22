#!/usr/bin/env bash
# promote.sh - Promotion pipeline from Engram to Lore
#
# Queries Engram for high-value non-shadow memories (importance >= 4 or
# accessCount >= 3), presents them for curation, and promotes approved
# candidates to Lore. Original Engram memories are updated with [lore:{id}]
# prefix to become shadows of the promoted records.
#
# Usage:
#   source lib/promote.sh
#   query_promotion_candidates [limit]
#   present_candidate <engram_id>
#   promote_to_lore <engram_id> <type> [edited_content]
#   mark_as_promoted <engram_id> <lore_id>

set -euo pipefail

LORE_DIR="${LORE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "${LORE_DIR}/lib/paths.sh"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

CLAUDE_MEMORY_DB="${CLAUDE_MEMORY_DB:-${HOME}/.claude/memory.sqlite}"

# --- Query promotion candidates ---
# Returns JSON array of candidates
# Filters: not a shadow, high importance or access count, not expired
# Sorted by priority score (importance * accessCount)
query_promotion_candidates() {
    local limit="${1:-50}"

    [[ ! -f "$CLAUDE_MEMORY_DB" ]] && echo "[]" && return 0

    sqlite3 -json "$CLAUDE_MEMORY_DB" <<SQL
SELECT id, content, topic, source, importance, accessCount, project
FROM Memory
WHERE content NOT LIKE '[lore:%'
  AND (importance >= 4 OR accessCount >= 3)
  AND (expiresAt = 0 OR expiresAt > unixepoch())
ORDER BY (importance * accessCount) DESC
LIMIT $limit;
SQL
}

# --- Get full candidate details ---
# Returns JSON with all fields for a single candidate
get_candidate() {
    local engram_id="$1"

    [[ ! -f "$CLAUDE_MEMORY_DB" ]] && return 1

    sqlite3 -json "$CLAUDE_MEMORY_DB" <<SQL
SELECT id, content, topic, source, importance, accessCount, project,
       datetime(createdAt, 'unixepoch') as created,
       datetime(lastAccessedAt, 'unixepoch') as lastAccessed
FROM Memory
WHERE id = $engram_id;
SQL
}

# --- Present a candidate for review ---
# Shows formatted output with all context
present_candidate() {
    local engram_id="$1"

    local candidate
    candidate=$(get_candidate "$engram_id")
    [[ -z "$candidate" ]] && return 1

    local content topic source importance access_count project created last_accessed
    content=$(echo "$candidate" | jq -r '.[0].content')
    topic=$(echo "$candidate" | jq -r '.[0].topic')
    source=$(echo "$candidate" | jq -r '.[0].source')
    importance=$(echo "$candidate" | jq -r '.[0].importance')
    access_count=$(echo "$candidate" | jq -r '.[0].accessCount')
    project=$(echo "$candidate" | jq -r '.[0].project')
    created=$(echo "$candidate" | jq -r '.[0].created')
    last_accessed=$(echo "$candidate" | jq -r '.[0].lastAccessed')

    echo -e "${BOLD}Candidate #${engram_id}${NC}"
    echo -e "${CYAN}Content:${NC} $content"
    echo -e "${DIM}Topic:${NC} $topic  ${DIM}Project:${NC} $project  ${DIM}Source:${NC} $source"
    echo -e "${DIM}Importance:${NC} $importance  ${DIM}Access count:${NC} $access_count"
    echo -e "${DIM}Created:${NC} $created  ${DIM}Last accessed:${NC} $last_accessed"
}

# --- Classify candidate type ---
# Infers decision vs pattern vs observation from content shape
classify_candidate() {
    local content="$1"

    # Decision indicators: "decided", "chose", "use X for Y", "rejected"
    if echo "$content" | grep -qiE '\b(decided|chose|chosen|use .+ for|rejected|selected|picked)\b'; then
        echo "decision"
        return 0
    fi

    # Pattern indicators: "pattern", "approach", "technique", "always", "never", "when X, do Y"
    if echo "$content" | grep -qiE '\b(pattern|approach|technique|strategy|always|never|should|avoid|prefer|when .+ (do|use))\b'; then
        echo "pattern"
        return 0
    fi

    # Default to observation
    echo "observation"
}

# --- Promote candidate to Lore ---
# Calls appropriate lore command (remember/learn/capture) based on type
# Returns the Lore ID on success
promote_to_lore() {
    local engram_id="$1"
    local type="$2"
    local edited_content="${3:-}"

    local candidate
    candidate=$(get_candidate "$engram_id")
    [[ -z "$candidate" ]] && return 1

    local content topic project
    content=$(echo "$candidate" | jq -r '.[0].content')
    topic=$(echo "$candidate" | jq -r '.[0].topic')
    project=$(echo "$candidate" | jq -r '.[0].project')

    # Use edited content if provided
    [[ -n "$edited_content" ]] && content="$edited_content"

    local tags="$project"
    [[ "$topic" != "null" && "$topic" != "$project" ]] && tags="$project,$topic"

    case "$type" in
        decision)
            # Call lore remember (decision requires --rationale, but we'll use a default)
            "$LORE_DIR/lore.sh" remember "$content" \
                --rationale "Promoted from Engram (high-value observation)" \
                --tags "$tags" \
                --type "architecture" 2>&1 | grep -oE 'dec-[a-f0-9]+' | head -1
            ;;
        pattern)
            # Call lore learn (extract name from first few words)
            local pattern_name
            pattern_name=$(echo "$content" | head -c 80 | sed 's/[^a-zA-Z0-9 ]//g' | awk '{print $1, $2, $3}')
            "$LORE_DIR/lore.sh" learn "$pattern_name" \
                --solution "$content" \
                --context "Promoted from Engram" \
                --category "general" 2>&1 | grep -oE 'pat-[a-f0-9]+' | head -1
            ;;
        observation)
            # Call lore capture
            "$LORE_DIR/lore.sh" capture "$content" \
                --tags "$tags" 2>&1 | grep -oE 'obs-[a-f0-9]+' | head -1
            ;;
        *)
            echo -e "${RED}Unknown type: $type${NC}" >&2
            return 1
            ;;
    esac
}

# --- Mark Engram memory as promoted ---
# Updates the content to include [lore:{id}] prefix and changes source
mark_as_promoted() {
    local engram_id="$1"
    local lore_id="$2"

    [[ ! -f "$CLAUDE_MEMORY_DB" ]] && return 1

    # Get current content
    local content
    content=$(sqlite3 "$CLAUDE_MEMORY_DB" "SELECT content FROM Memory WHERE id = $engram_id;")

    # Prepend [lore:{id}]
    local new_content="[lore:${lore_id}] $content"

    # Update the memory
    sqlite3 "$CLAUDE_MEMORY_DB" <<SQL
UPDATE Memory
SET content = '${new_content//\'/\'\'}',
    source = 'lore-promoted'
WHERE id = $engram_id;
SQL
}

# --- Count promotion candidates ---
count_promotion_candidates() {
    [[ ! -f "$CLAUDE_MEMORY_DB" ]] && echo "0" && return 0

    sqlite3 "$CLAUDE_MEMORY_DB" <<SQL
SELECT COUNT(*)
FROM Memory
WHERE content NOT LIKE '[lore:%'
  AND (importance >= 4 OR accessCount >= 3)
  AND (expiresAt = 0 OR expiresAt > unixepoch());
SQL
}
