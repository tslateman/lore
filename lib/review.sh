#!/usr/bin/env bash
# review.sh - Decision outcome review loop
#
# Lists pending decisions, resolves outcomes, and propagates effects
# (pattern confidence boosts, failure recording, lesson capture).

set -euo pipefail

LORE_DIR="${LORE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "${LORE_DIR}/lib/paths.sh"
source "${LORE_DIR}/journal/lib/store.sh"

# Colors (inherit from caller if set)
RED="${RED:-\033[0;31m}"
GREEN="${GREEN:-\033[0;32m}"
YELLOW="${YELLOW:-\033[1;33m}"
BLUE="${BLUE:-\033[0;34m}"
CYAN="${CYAN:-\033[0;36m}"
BOLD="${BOLD:-\033[1m}"
DIM="${DIM:-\033[2m}"
NC="${NC:-\033[0m}"

# Disable colors when not a terminal
if [[ ! -t 1 ]]; then
    RED='' GREEN='' YELLOW='' BLUE='' CYAN='' BOLD='' DIM='' NC=''
fi

PATTERNS_FILE="${LORE_PATTERNS_FILE}"

# Find pattern IDs whose name/context/solution mention any of the given entities.
# Args: entity1 entity2 ...
# Prints one pattern ID per line.
_find_patterns_by_entities() {
    local entities=("$@")
    [[ ${#entities[@]} -eq 0 ]] && return 0
    [[ -f "$PATTERNS_FILE" ]] || return 0

    # Build a case-insensitive alternation regex from entities
    local regex=""
    for entity in "${entities[@]}"; do
        # Escape regex-special chars in the entity
        local escaped
        escaped=$(printf '%s' "$entity" | sed 's/[.[\*^$()+?{|]/\\&/g')
        if [[ -z "$regex" ]]; then
            regex="$escaped"
        else
            regex="${regex}|${escaped}"
        fi
    done

    # Search pattern name/context/solution fields for entity mentions
    awk -v re="$regex" '
        BEGIN { IGNORECASE = 1; in_patterns = 0 }
        /^patterns:/ { in_patterns = 1; next }
        /^anti_patterns:/ { in_patterns = 0 }
        in_patterns && /- id:/ {
            gsub(/.*id: "/, ""); gsub(/".*/, "")
            id = $0; matched = 0
        }
        in_patterns && /name:/ {
            if (match($0, re)) matched = 1
        }
        in_patterns && /context:/ {
            if (match($0, re)) matched = 1
        }
        in_patterns && /solution:/ {
            if (match($0, re)) matched = 1
            if (matched && id != "") print id
        }
    ' "$PATTERNS_FILE"
}

# Main review command.
# Usage:
#   cmd_review                              # list pending decisions
#   cmd_review --auto                       # brief count for automated use
#   cmd_review --days 7                     # set age threshold
#   cmd_review --resolve <id> --outcome <o> [--lesson "text"]
cmd_review() {
    local auto=false
    local days=3
    local resolve_id=""
    local outcome=""
    local lesson=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --auto)    auto=true; days=7; shift ;;
            --days)    days="$2"; shift 2 ;;
            --resolve) resolve_id="$2"; shift 2 ;;
            --outcome) outcome="$2"; shift 2 ;;
            --lesson)  lesson="$2"; shift 2 ;;
            *)         echo "Unknown option: $1" >&2; return 1 ;;
        esac
    done

    # Resolve mode
    if [[ -n "$resolve_id" ]]; then
        _resolve_decision "$resolve_id" "$outcome" "$lesson"
        return $?
    fi

    # List mode
    _list_pending "$auto" "$days"
}

# List pending decisions older than N days.
_list_pending() {
    local auto="$1"
    local days="$2"

    [[ -f "$LORE_DECISIONS_FILE" ]] || { echo "No decisions found."; return 0; }
    [[ -s "$LORE_DECISIONS_FILE" ]] || { echo "No decisions found."; return 0; }

    local now_epoch
    now_epoch=$(date +%s)
    local threshold_seconds=$(( days * 86400 ))

    # Get unique active decisions with pending outcome
    local pending_json
    pending_json=$(jq -s '
        group_by(.id) | map(.[-1])
        | map(select((.status // "active") == "active" and (.outcome // "pending") == "pending"))
        | sort_by(.timestamp)
    ' "$LORE_DECISIONS_FILE" 2>/dev/null) || { echo "No decisions found."; return 0; }

    local total
    total=$(echo "$pending_json" | jq 'length')
    [[ "$total" -eq 0 ]] && { echo "No pending decisions."; return 0; }

    # Filter by age
    local old_count=0
    local oldest_days=0
    local old_entries=""

    while IFS= read -r entry; do
        [[ -z "$entry" ]] && continue

        local ts
        ts=$(echo "$entry" | jq -r '.timestamp')

        # Parse ISO8601 to epoch (portable: strip fractional seconds and Z)
        local ts_clean
        ts_clean=$(echo "$ts" | sed 's/\.[0-9]*Z$/Z/' | sed 's/Z$//')
        local entry_epoch
        entry_epoch=$(date -jf "%Y-%m-%dT%H:%M:%S" "$ts_clean" +%s 2>/dev/null) || \
            entry_epoch=$(date -d "$ts_clean" +%s 2>/dev/null) || continue

        local age_seconds=$(( now_epoch - entry_epoch ))
        local age_days=$(( age_seconds / 86400 ))

        if [[ "$age_seconds" -ge "$threshold_seconds" ]]; then
            old_count=$((old_count + 1))
            if [[ "$age_days" -gt "$oldest_days" ]]; then
                oldest_days=$age_days
            fi
            old_entries="${old_entries}${entry}
"
        fi
    done < <(echo "$pending_json" | jq -c '.[]')

    # Auto mode: brief summary
    if [[ "$auto" == "true" ]]; then
        if [[ "$old_count" -gt 0 ]]; then
            local noun="decision"
            [[ "$old_count" -gt 1 ]] && noun="decisions"
            echo -e "${YELLOW}⚠ ${old_count} ${noun} still pending (oldest: ${oldest_days} days). Run \`lore review\` to resolve.${NC}"
        fi
        return 0
    fi

    # Interactive mode: list each pending decision
    if [[ "$old_count" -eq 0 ]]; then
        echo -e "${GREEN}No pending decisions older than ${days} days.${NC}"
        echo -e "${DIM}Total pending: ${total}${NC}"
        return 0
    fi

    local noun="decision"
    [[ "$old_count" -gt 1 ]] && noun="decisions"
    echo -e "${BOLD}Pending ${noun} (${old_count} older than ${days} days):${NC}"
    echo ""

    while IFS= read -r entry; do
        [[ -z "$entry" ]] && continue

        local id type decision rationale ts
        id=$(echo "$entry" | jq -r '.id')
        type=$(echo "$entry" | jq -r '.type // "other"')
        decision=$(echo "$entry" | jq -r '.decision')
        rationale=$(echo "$entry" | jq -r '.rationale // ""')
        ts=$(echo "$entry" | jq -r '.timestamp')

        local ts_clean
        ts_clean=$(echo "$ts" | sed 's/\.[0-9]*Z$/Z/' | sed 's/Z$//')
        local entry_epoch
        entry_epoch=$(date -jf "%Y-%m-%dT%H:%M:%S" "$ts_clean" +%s 2>/dev/null) || \
            entry_epoch=$(date -d "$ts_clean" +%s 2>/dev/null) || continue
        local age_days=$(( (now_epoch - entry_epoch) / 86400 ))

        echo -e "  ${CYAN}${id}${NC} ${DIM}[${type}]${NC} ${YELLOW}${age_days} days old${NC}"
        echo -e "    ${decision}"
        if [[ -n "$rationale" && "$rationale" != "null" ]]; then
            echo -e "    ${DIM}Rationale: ${rationale}${NC}"
        fi
        echo ""
    done <<< "$old_entries"

    echo -e "${DIM}Run: lore review --resolve <id> --outcome successful|revised|abandoned${NC}"
}

# Resolve a decision's outcome.
_resolve_decision() {
    local id="$1"
    local outcome="$2"
    local lesson="$3"

    if [[ -z "$outcome" ]]; then
        echo -e "${RED}Error: --outcome required (successful|revised|abandoned)${NC}" >&2
        return 1
    fi

    # Validate outcome
    case "$outcome" in
        successful|revised|abandoned) ;;
        *)
            echo -e "${RED}Error: Invalid outcome '${outcome}'. Use: successful|revised|abandoned${NC}" >&2
            return 1
            ;;
    esac

    # Update the decision outcome
    if ! journal_update_outcome "$id" "$outcome" "$lesson"; then
        return 1
    fi

    echo -e "${GREEN}Resolved ${id} as ${outcome}${NC}"

    # Side effects based on outcome
    case "$outcome" in
        successful)
            _boost_related_patterns "$id"
            ;;
        abandoned)
            _record_abandoned_failure "$id"
            ;;
    esac

    # Update lesson if provided (handled in journal_update_outcome already)
    if [[ -n "$lesson" ]]; then
        echo -e "${CYAN}Lesson recorded.${NC}"
    fi
}

# Boost confidence of patterns sharing entities with a successful decision.
_boost_related_patterns() {
    local id="$1"

    local decision_json
    decision_json=$(get_decision "$id")
    [[ -z "$decision_json" ]] && return 0

    # Extract entity list from the decision
    local entities_json
    entities_json=$(echo "$decision_json" | jq -r '.entities[]?' 2>/dev/null) || true
    [[ -z "$entities_json" ]] && return 0

    local entities=()
    while IFS= read -r e; do
        [[ -n "$e" ]] && entities+=("$e")
    done <<< "$entities_json"
    [[ ${#entities[@]} -eq 0 ]] && return 0

    [[ -f "$PATTERNS_FILE" ]] || return 0

    # Source pattern capture for validate_pattern
    source "${LORE_DIR}/patterns/lib/capture.sh"

    local pattern_ids
    pattern_ids=$(_find_patterns_by_entities "${entities[@]}") || true
    [[ -z "$pattern_ids" ]] && return 0

    local boosted=0
    while IFS= read -r pat_id; do
        [[ -z "$pat_id" ]] && continue
        if validate_pattern "$pat_id" 2>/dev/null; then
            boosted=$((boosted + 1))
        fi
    done <<< "$pattern_ids"

    if [[ "$boosted" -gt 0 ]]; then
        local noun="pattern"
        [[ "$boosted" -gt 1 ]] && noun="patterns"
        echo -e "${DIM}Boosted confidence on ${boosted} related ${noun}.${NC}"
    fi
}

# Record an abandoned decision as a failure.
_record_abandoned_failure() {
    local id="$1"

    local decision_json
    decision_json=$(get_decision "$id")
    [[ -z "$decision_json" ]] && return 0

    local decision_text
    decision_text=$(echo "$decision_json" | jq -r '.decision')

    source "${LORE_DIR}/failures/lib/failures.sh"
    local fail_id
    fail_id=$(failures_append "LogicError" "Abandoned decision: ${decision_text}" "" "") || true

    if [[ -n "$fail_id" ]]; then
        echo -e "${DIM}Recorded failure ${fail_id} for abandoned decision.${NC}"
    fi
}
