#!/usr/bin/env bash
# Inbox staging area - append-only raw observations
# Part of the Lineage memory system for AI agents

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA_DIR="${SCRIPT_DIR}/../data"
OBSERVATIONS_FILE="${DATA_DIR}/observations.jsonl"

# Ensure data directory exists
init_inbox() {
    mkdir -p "$DATA_DIR"
    touch "$OBSERVATIONS_FILE"
}

# Generate unique observation ID (obs- prefix + 8 hex chars)
generate_observation_id() {
    echo "obs-$(od -An -tx1 -N4 /dev/urandom | tr -d ' \n')"
}

# Append a raw observation to the inbox
# Args: content source [tags]
# Rejects empty content. Injects timestamp automatically.
inbox_append() {
    local content="$1"
    local source="${2:-manual}"
    local tags="${3:-}"

    if [[ -z "$content" ]]; then
        echo "Error: Observation content required" >&2
        return 1
    fi

    init_inbox

    local id
    id=$(generate_observation_id)

    local timestamp
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    # Parse tags into JSON array
    local tags_array="[]"
    if [[ -n "$tags" ]]; then
        tags_array=$(echo "$tags" | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | jq -R . | jq -s .)
    fi

    # Build JSON record (compact for JSONL)
    local record
    record=$(jq -c -n \
        --arg id "$id" \
        --arg timestamp "$timestamp" \
        --arg source "$source" \
        --arg content "$content" \
        --arg status "raw" \
        --argjson tags "$tags_array" \
        '{
            id: $id,
            timestamp: $timestamp,
            source: $source,
            content: $content,
            status: $status,
            tags: $tags
        }')

    # Atomic append (single echo >> call)
    echo "$record" >> "$OBSERVATIONS_FILE"

    echo "$id"
}

# List observations, optionally filtered by status
# Args: [status]
inbox_list() {
    local filter_status="${1:-}"

    init_inbox

    if [[ ! -s "$OBSERVATIONS_FILE" ]]; then
        echo "[]"
        return 0
    fi

    if [[ -n "$filter_status" ]]; then
        jq -s --arg s "$filter_status" \
            '[.[] | select(.status == $s)] | sort_by(.timestamp) | reverse' \
            "$OBSERVATIONS_FILE"
    else
        jq -s 'sort_by(.timestamp) | reverse' "$OBSERVATIONS_FILE"
    fi
}

# Mark an observation as promoted
# Args: observation_id target_description
# Sets status to "promoted" and records the promotion target.
# Does NOT create the target entry -- use lineage remember or lineage learn.
inbox_promote() {
    local obs_id="$1"
    local target="${2:-}"

    if [[ -z "$obs_id" ]]; then
        echo "Error: Observation ID required" >&2
        return 1
    fi

    init_inbox

    # Verify the observation exists
    local existing
    existing=$(jq -c --arg id "$obs_id" 'select(.id == $id)' "$OBSERVATIONS_FILE" 2>/dev/null | tail -1)

    if [[ -z "$existing" ]]; then
        echo "Error: Observation $obs_id not found" >&2
        return 1
    fi

    local current_status
    current_status=$(echo "$existing" | jq -r '.status')

    if [[ "$current_status" != "raw" ]]; then
        echo "Error: Observation $obs_id already has status '$current_status'" >&2
        return 1
    fi

    # Build updated record with promoted status
    local promoted_at
    promoted_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    local updated
    updated=$(echo "$existing" | jq -c \
        --arg status "promoted" \
        --arg target "$target" \
        --arg promoted_at "$promoted_at" \
        '. + {status: $status, promoted_to: $target, promoted_at: $promoted_at}')

    # Append updated version (append-only; latest version wins on read)
    echo "$updated" >> "$OBSERVATIONS_FILE"

    echo "$obs_id"
}

# Mark an observation as discarded
# Args: observation_id [reason]
inbox_discard() {
    local obs_id="$1"
    local reason="${2:-}"

    if [[ -z "$obs_id" ]]; then
        echo "Error: Observation ID required" >&2
        return 1
    fi

    init_inbox

    local existing
    existing=$(jq -c --arg id "$obs_id" 'select(.id == $id)' "$OBSERVATIONS_FILE" 2>/dev/null | tail -1)

    if [[ -z "$existing" ]]; then
        echo "Error: Observation $obs_id not found" >&2
        return 1
    fi

    local current_status
    current_status=$(echo "$existing" | jq -r '.status')

    if [[ "$current_status" != "raw" ]]; then
        echo "Error: Observation $obs_id already has status '$current_status'" >&2
        return 1
    fi

    local discarded_at
    discarded_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    local updated
    updated=$(echo "$existing" | jq -c \
        --arg status "discarded" \
        --arg reason "$reason" \
        --arg discarded_at "$discarded_at" \
        '. + {status: $status, discard_reason: $reason, discarded_at: $discarded_at}')

    echo "$updated" >> "$OBSERVATIONS_FILE"

    echo "$obs_id"
}

# Get a single observation by ID (latest version)
inbox_get() {
    local obs_id="$1"

    init_inbox

    jq -c --arg id "$obs_id" 'select(.id == $id)' "$OBSERVATIONS_FILE" 2>/dev/null | tail -1
}

# Count observations by status
inbox_stats() {
    init_inbox

    if [[ ! -s "$OBSERVATIONS_FILE" ]]; then
        echo '{"total":0,"raw":0,"promoted":0,"discarded":0}'
        return 0
    fi

    jq -s '
        group_by(.id) | map(.[-1]) |
        {
            total: length,
            raw: [.[] | select(.status == "raw")] | length,
            promoted: [.[] | select(.status == "promoted")] | length,
            discarded: [.[] | select(.status == "discarded")] | length
        }
    ' "$OBSERVATIONS_FILE"
}
