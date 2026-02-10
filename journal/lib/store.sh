#!/usr/bin/env bash
# Storage layer for decisions - JSONL-based with indexing

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA_DIR="${SCRIPT_DIR}/../data"
DECISIONS_FILE="${DATA_DIR}/decisions.jsonl"
INDEX_DIR="${DATA_DIR}/index"

# Ensure data directories exist
init_store() {
    mkdir -p "$DATA_DIR" "$INDEX_DIR"
    touch "$DECISIONS_FILE"
}

# Append a decision to the store
store_decision() {
    local decision_json="$1"
    init_store

    # Append to JSONL file
    echo "$decision_json" >> "$DECISIONS_FILE"

    # Update indexes
    local id timestamp type
    id=$(echo "$decision_json" | jq -r '.id')
    timestamp=$(echo "$decision_json" | jq -r '.timestamp')
    type=$(echo "$decision_json" | jq -r '.type // "other"')

    # Date index (YYYY-MM-DD -> list of decision IDs)
    local date_key
    date_key=$(echo "$timestamp" | cut -d'T' -f1)
    echo "$id" >> "${INDEX_DIR}/date_${date_key}.idx"

    # Type index
    echo "$id" >> "${INDEX_DIR}/type_${type}.idx"

    # Entity index
    local entity
    while IFS= read -r entity; do
        [[ -z "$entity" ]] && continue
        local safe_entity
        safe_entity=$(echo "$entity" | sed 's/[^a-zA-Z0-9._-]/_/g')
        [[ -n "$safe_entity" ]] && echo "$id" >> "${INDEX_DIR}/entity_${safe_entity}.idx"
    done < <(echo "$decision_json" | jq -r '.entities[]?' 2>/dev/null || true)

    # Tag index
    local tag
    while IFS= read -r tag; do
        [[ -z "$tag" ]] && continue
        local safe_tag
        safe_tag=$(echo "$tag" | sed 's/[^a-zA-Z0-9._-]/_/g')
        [[ -n "$safe_tag" ]] && echo "$id" >> "${INDEX_DIR}/tag_${safe_tag}.idx"
    done < <(echo "$decision_json" | jq -r '.tags[]?' 2>/dev/null || true)

    echo "$id"
}

# Get a decision by ID
get_decision() {
    local id="$1"
    # Parse JSONL and find matching record
    jq -c --arg id "$id" 'select(.id == $id)' "$DECISIONS_FILE" 2>/dev/null | tail -1
}

# Update a decision (append new version, mark old as superseded)
update_decision() {
    local id="$1"
    local field="$2"
    local value="$3"

    local current
    current=$(get_decision "$id")

    if [[ -z "$current" ]]; then
        echo "Error: Decision $id not found" >&2
        return 1
    fi

    # Create updated record (compact for JSONL)
    local updated
    if [[ "$value" =~ ^\[ ]] || [[ "$value" =~ ^\{ ]]; then
        # JSON value
        updated=$(echo "$current" | jq -c --argjson val "$value" ".$field = \$val")
    else
        # String value
        updated=$(echo "$current" | jq -c --arg val "$value" ".$field = \$val")
    fi

    # Append updated version
    echo "$updated" >> "$DECISIONS_FILE"
}

# List recent decisions
list_recent() {
    local count="${1:-10}"
    init_store

    # Get unique decisions (latest version of each)
    tail -r "$DECISIONS_FILE" 2>/dev/null | \
        jq -s 'group_by(.id) | map(.[-1])' | \
        jq ".[0:$count]"
}

# List decisions by date range
list_by_date() {
    local start_date="$1"
    local end_date="${2:-$start_date}"

    jq -s --arg start "$start_date" --arg end "$end_date" '
        [.[] | select(.timestamp >= $start and .timestamp <= ($end + "T23:59:59Z"))]
        | group_by(.id) | map(.[-1])
        | sort_by(.timestamp) | reverse
    ' "$DECISIONS_FILE"
}

# Search decisions by text (full-text search)
search_decisions() {
    local query="$1"
    local query_lower
    query_lower=$(echo "$query" | tr '[:upper:]' '[:lower:]')

    jq -s --arg q "$query_lower" '
        [.[] | select(
            (.decision | ascii_downcase | contains($q)) or
            (.rationale // "" | ascii_downcase | contains($q)) or
            (.lesson_learned // "" | ascii_downcase | contains($q)) or
            (.alternatives | map(ascii_downcase) | any(contains($q))) or
            (.entities | map(ascii_downcase) | any(contains($q))) or
            (.tags | map(ascii_downcase) | any(contains($q)))
        )]
        | group_by(.id) | map(.[-1])
        | sort_by(.timestamp) | reverse
    ' "$DECISIONS_FILE"
}

# Get decisions by entity (file, function, concept)
get_by_entity() {
    local entity="$1"
    local safe_entity
    safe_entity=$(echo "$entity" | sed 's/[^a-zA-Z0-9._-]/_/g')

    local index_file="${INDEX_DIR}/entity_${safe_entity}.idx"

    if [[ -f "$index_file" ]]; then
        local ids
        ids=$(sort -u "$index_file" | paste -sd'|' -)
        grep -E "\"id\":\"(${ids})\"" "$DECISIONS_FILE" | \
            jq -s 'group_by(.id) | map(.[-1]) | sort_by(.timestamp) | reverse'
    else
        # Fallback to full search if no index
        jq -s --arg e "$entity" '
            [.[] | select(.entities | map(ascii_downcase) | any(contains($e | ascii_downcase)))]
            | group_by(.id) | map(.[-1])
            | sort_by(.timestamp) | reverse
        ' "$DECISIONS_FILE"
    fi
}

# Get decisions by type
get_by_type() {
    local type="$1"

    jq -s --arg t "$type" '
        [.[] | select(.type == $t)]
        | group_by(.id) | map(.[-1])
        | sort_by(.timestamp) | reverse
    ' "$DECISIONS_FILE"
}

# Get decisions by tag
get_by_tag() {
    local tag="$1"

    jq -s --arg t "$tag" '
        [.[] | select(.tags | any(. == $t))]
        | group_by(.id) | map(.[-1])
        | sort_by(.timestamp) | reverse
    ' "$DECISIONS_FILE"
}

# Get decisions by project (matches tag prefix "project:")
get_by_project() {
    local project="$1"

    jq -s --arg p "$project" '
        [.[] | select(.tags | any(. == $p or startswith($p + ":") or startswith($p + ",")))]
        | group_by(.id) | map(.[-1])
        | sort_by(.timestamp) | reverse
    ' "$DECISIONS_FILE"
}

# Get decisions by outcome
get_by_outcome() {
    local outcome="$1"

    jq -s --arg o "$outcome" '
        [.[] | select(.outcome == $o)]
        | group_by(.id) | map(.[-1])
        | sort_by(.timestamp) | reverse
    ' "$DECISIONS_FILE"
}

# Count decisions by various dimensions
get_stats() {
    jq -s '
        group_by(.id) | map(.[-1]) |
        {
            total: length,
            by_type: (group_by(.type) | map({key: .[0].type, value: length}) | from_entries),
            by_outcome: (group_by(.outcome) | map({key: .[0].outcome, value: length}) | from_entries),
            with_lessons: [.[] | select(.lesson_learned != null)] | length,
            by_month: (group_by(.timestamp[0:7]) | map({key: .[0].timestamp[0:7], value: length}) | from_entries)
        }
    ' "$DECISIONS_FILE"
}

# Export decisions for a session
export_session() {
    local session_id="$1"

    jq -s --arg s "$session_id" '
        [.[] | select(.session_id == $s)]
        | group_by(.id) | map(.[-1])
        | sort_by(.timestamp)
    ' "$DECISIONS_FILE"
}

# Compact the JSONL file (keep only latest version of each decision)
compact_decisions() {
    init_store

    local temp_file
    temp_file=$(mktemp)

    # Keep only the last occurrence of each decision ID
    jq -s 'group_by(.id) | map(.[-1]) | sort_by(.timestamp) | .[]' -c "$DECISIONS_FILE" > "$temp_file"

    local before after
    before=$(wc -l < "$DECISIONS_FILE" | tr -d ' ')
    after=$(wc -l < "$temp_file" | tr -d ' ')

    mv "$temp_file" "$DECISIONS_FILE"

    echo "Compacted: $before -> $after records (removed $((before - after)) duplicates)"

    # Rebuild indexes after compaction
    rebuild_indexes
}

# Rebuild all indexes from scratch
rebuild_indexes() {
    rm -rf "$INDEX_DIR"
    mkdir -p "$INDEX_DIR"

    while IFS= read -r line; do
        local id timestamp type
        id=$(echo "$line" | jq -r '.id')
        timestamp=$(echo "$line" | jq -r '.timestamp')
        type=$(echo "$line" | jq -r '.type // "other"')

        # Date index
        local date_key
        date_key=$(echo "$timestamp" | cut -d'T' -f1)
        echo "$id" >> "${INDEX_DIR}/date_${date_key}.idx"

        # Type index
        echo "$id" >> "${INDEX_DIR}/type_${type}.idx"

        # Entity index
        echo "$line" | jq -r '.entities[]?' | while read -r entity; do
            local safe_entity
            safe_entity=$(echo "$entity" | sed 's/[^a-zA-Z0-9._-]/_/g')
            echo "$id" >> "${INDEX_DIR}/entity_${safe_entity}.idx"
        done

        # Tag index
        echo "$line" | jq -r '.tags[]?' | while read -r tag; do
            local safe_tag
            safe_tag=$(echo "$tag" | sed 's/[^a-zA-Z0-9._-]/_/g')
            echo "$id" >> "${INDEX_DIR}/tag_${safe_tag}.idx"
        done
    done < "$DECISIONS_FILE"

    echo "Indexes rebuilt"
}
