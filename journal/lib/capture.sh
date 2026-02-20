#!/usr/bin/env bash
# Decision capture library - parses and enriches decision data

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../lib/paths.sh"

# Generate unique decision ID
generate_decision_id() {
    echo "dec-$(od -An -tx1 -N4 /dev/urandom | tr -d ' \n')"
}

# Generate session ID if not set
# Checks: 1) LORE_SESSION_ID env, 2) transfer's current session, 3) journal's local session
get_session_id() {
    if [[ -n "${LORE_SESSION_ID:-}" ]]; then
        echo "$LORE_SESSION_ID"
    elif [[ -f "${LORE_TRANSFER_DATA}/.current_session" ]]; then
        # Use transfer's active session for unified session IDs
        cat "${LORE_TRANSFER_DATA}/.current_session"
    elif [[ -f "${LORE_JOURNAL_DATA}/.current_session" ]]; then
        cat "${LORE_JOURNAL_DATA}/.current_session"
    else
        local session_id="session-$(od -An -tx1 -N4 /dev/urandom | tr -d ' \n')"
        mkdir -p "${LORE_JOURNAL_DATA}"
        echo "$session_id" > "${LORE_JOURNAL_DATA}/.current_session"
        echo "$session_id"
    fi
}

# Extract entities from decision text
# Looks for file paths, function names, and quoted terms
extract_entities() {
    local text="$1"
    local entities=()

    # Extract file paths (e.g., src/main.rs, lib/utils.py)
    while IFS= read -r match; do
        [[ -n "$match" ]] && entities+=("$match")
    done < <(echo "$text" | grep -oE '[a-zA-Z0-9_/-]+\.[a-zA-Z]{1,4}' 2>/dev/null | sort -u || true)

    # Extract function/method names (e.g., parse_config(), handleEvent)
    while IFS= read -r match; do
        [[ -n "$match" ]] && entities+=("$match")
    done < <(echo "$text" | grep -oE '[a-z_][a-zA-Z0-9_]*\(\)' 2>/dev/null | sed 's/()$//' | sort -u || true)

    # Extract backtick-quoted terms
    while IFS= read -r match; do
        [[ -n "$match" ]] && entities+=("$match")
    done < <(echo "$text" | grep -oE '`[^`]+`' 2>/dev/null | sed 's/`//g' | sort -u || true)

    # Output as JSON array (filter empty strings)
    if [[ ${#entities[@]} -eq 0 ]]; then
        echo "[]"
    else
        printf '%s\n' "${entities[@]}" | grep -v '^$' | jq -R . | jq -s '.'
    fi
}

# Auto-detect decision type based on keywords
detect_decision_type() {
    local text="$1"
    local lower_text
    lower_text=$(echo "$text" | tr '[:upper:]' '[:lower:]')

    # Architecture patterns
    if echo "$lower_text" | grep -qE '(architecture|structure|design|pattern|layer|module|component|system)'; then
        echo "architecture"
        return
    fi

    # Tooling patterns
    if echo "$lower_text" | grep -qE '(tool|library|dependency|package|framework|cli|command)'; then
        echo "tooling"
        return
    fi

    # Naming patterns
    if echo "$lower_text" | grep -qE '(name|naming|rename|call|term|convention)'; then
        echo "naming"
        return
    fi

    # Bugfix patterns
    if echo "$lower_text" | grep -qE '(fix|bug|issue|error|crash|broken|regression)'; then
        echo "bugfix"
        return
    fi

    # Refactor patterns
    if echo "$lower_text" | grep -qE '(refactor|cleanup|simplify|extract|inline|reorganize)'; then
        echo "refactor"
        return
    fi

    # Process patterns
    if echo "$lower_text" | grep -qE '(process|workflow|procedure|policy|guideline)'; then
        echo "process"
        return
    fi

    # Default to implementation
    echo "implementation"
}

# Get current git commit if in a repo
get_git_commit() {
    if git rev-parse --git-dir >/dev/null 2>&1; then
        git rev-parse HEAD 2>/dev/null || echo ""
    else
        echo ""
    fi
}

# Create a full decision record
create_decision_record() {
    local decision="$1"
    local rationale="${2:-}"
    local alternatives="${3:-}"
    local tags="${4:-}"
    local explicit_type="${5:-}"
    local valid_at="${6:-}"

    local id
    id=$(generate_decision_id)

    local timestamp
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    local session_id
    session_id=$(get_session_id)

    local entities
    entities=$(extract_entities "$decision $rationale")

    local decision_type
    if [[ -n "$explicit_type" ]]; then
        decision_type="$explicit_type"
    else
        decision_type=$(detect_decision_type "$decision $rationale")
    fi

    local git_commit
    git_commit=$(get_git_commit)

    # Parse alternatives into array
    local alt_array="[]"
    if [[ -n "$alternatives" ]]; then
        alt_array=$(echo "$alternatives" | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | jq -R . | jq -s .)
    fi

    # Parse tags into array
    local tags_array="[]"
    if [[ -n "$tags" ]]; then
        tags_array=$(echo "$tags" | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | jq -R . | jq -s .)
    fi

    # Compute spec quality score (0.0-1.0) based on field completeness
    local spec_quality
    spec_quality=$(awk \
        -v rat="$rationale" \
        -v alts="$alternatives" \
        -v ents="$(echo "$entities" | jq 'length')" \
        -v tgs="$(echo "$tags_array" | jq 'length')" \
        'BEGIN {
            s = 0.2  # base: decision text always present
            if (length(rat) > 0) s += 0.3
            if (length(alts) > 0) s += 0.2
            if (ents + 0 > 0) s += 0.15
            if (tgs + 0 > 0) s += 0.15
            printf "%.2f", s
        }')

    # Build JSON record (compact for JSONL format)
    jq -c -n \
        --arg id "$id" \
        --arg timestamp "$timestamp" \
        --arg session_id "$session_id" \
        --arg decision "$decision" \
        --arg rationale "$rationale" \
        --argjson alternatives "$alt_array" \
        --arg outcome "pending" \
        --arg type "$decision_type" \
        --argjson entities "$entities" \
        --argjson tags "$tags_array" \
        --arg git_commit "$git_commit" \
        --arg valid_at "$valid_at" \
        --argjson spec_quality "$spec_quality" \
        '{
            id: $id,
            timestamp: $timestamp,
            session_id: $session_id,
            decision: $decision,
            rationale: (if $rationale == "" then null else $rationale end),
            alternatives: $alternatives,
            outcome: $outcome,
            type: $type,
            entities: $entities,
            tags: $tags,
            lesson_learned: null,
            related_decisions: [],
            git_commit: (if $git_commit == "" then null else $git_commit end),
            valid_at: (if $valid_at == "" then null else $valid_at end),
            spec_quality: $spec_quality
        }'
}

# Parse decision text that may include inline rationale
# Format: "decision text [because: rationale] [vs: alt1, alt2]"
parse_inline_decision() {
    local text="$1"

    local decision rationale alternatives

    # Extract rationale if present
    if [[ "$text" =~ \[because:[[:space:]]*([^\]]+)\] ]]; then
        rationale="${BASH_REMATCH[1]}"
        text="${text/\[because: $rationale\]/}"
        text="${text/\[because:$rationale\]/}"
    else
        rationale=""
    fi

    # Extract alternatives if present
    if [[ "$text" =~ \[vs:[[:space:]]*([^\]]+)\] ]]; then
        alternatives="${BASH_REMATCH[1]}"
        text="${text/\[vs: $alternatives\]/}"
        text="${text/\[vs:$alternatives\]/}"
    else
        alternatives=""
    fi

    # Clean up decision text
    decision=$(echo "$text" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

    echo "$decision"
    echo "$rationale"
    echo "$alternatives"
}
