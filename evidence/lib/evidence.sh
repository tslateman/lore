#!/usr/bin/env bash
# Evidence store - append-only factual evidence with confidence tracking
# Part of the Lore memory system for AI agents

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../lib/paths.sh"
DATA_DIR="${LORE_EVIDENCE_DATA}"
EVIDENCE_FILE="${LORE_EVIDENCE_FILE}"

# Ensure data directory exists
init_evidence() {
    mkdir -p "$DATA_DIR"
    touch "$EVIDENCE_FILE"
}

# Generate unique evidence ID (evi- prefix + 8 hex chars)
generate_evidence_id() {
    echo "evi-$(od -An -tx1 -N4 /dev/urandom | tr -d ' \n')"
}

# Append evidence to the store
# Args: content source [tags] [confidence] [provenance]
# Rejects empty content. Injects timestamp automatically.
evidence_append() {
    local content="$1"
    local source="${2:-manual}"
    local tags="${3:-}"
    local confidence="${4:-preliminary}"
    local provenance="${5:-}"

    if [[ -z "$content" ]]; then
        echo "Error: Evidence content required" >&2
        return 1
    fi

    # Validate confidence level
    case "$confidence" in
        preliminary|confirmed|contested|superseded) ;;
        *)
            echo "Error: Invalid confidence level '$confidence' (preliminary|confirmed|contested|superseded)" >&2
            return 1
            ;;
    esac

    init_evidence

    local id
    id=$(generate_evidence_id)

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
        --arg confidence "$confidence" \
        --argjson tags "$tags_array" \
        --argjson cited_by '[]' \
        --arg provenance "$provenance" \
        '{
            id: $id,
            timestamp: $timestamp,
            source: $source,
            content: $content,
            confidence: $confidence,
            tags: $tags,
            cited_by: $cited_by,
            provenance: $provenance
        }')

    # Atomic append (single echo >> call)
    echo "$record" >> "$EVIDENCE_FILE"

    echo "$id"
}

# List evidence, optionally filtered by confidence
# Args: [confidence]
evidence_list() {
    local filter_confidence="${1:-}"

    init_evidence

    if [[ ! -s "$EVIDENCE_FILE" ]]; then
        echo "[]"
        return 0
    fi

    if [[ -n "$filter_confidence" ]]; then
        jq -s --arg c "$filter_confidence" \
            'group_by(.id) | map(.[-1]) | [.[] | select(.confidence == $c)] | sort_by(.timestamp) | reverse' \
            "$EVIDENCE_FILE"
    else
        jq -s 'group_by(.id) | map(.[-1]) | sort_by(.timestamp) | reverse' "$EVIDENCE_FILE"
    fi
}

# Get a single evidence record by ID (latest version)
evidence_get() {
    local evi_id="$1"

    init_evidence

    jq -c --arg id "$evi_id" 'select(.id == $id)' "$EVIDENCE_FILE" 2>/dev/null | tail -1
}

# Update the confidence level of an evidence record
# Appends a new version (append-only; latest version wins on read)
# Args: evidence_id new_confidence
evidence_update_confidence() {
    local evi_id="$1"
    local new_confidence="$2"

    # Validate confidence level
    case "$new_confidence" in
        preliminary|confirmed|contested|superseded) ;;
        *)
            echo "Error: Invalid confidence level '$new_confidence' (preliminary|confirmed|contested|superseded)" >&2
            return 1
            ;;
    esac

    init_evidence

    local existing
    existing=$(jq -c --arg id "$evi_id" 'select(.id == $id)' "$EVIDENCE_FILE" 2>/dev/null | tail -1)

    if [[ -z "$existing" ]]; then
        echo "Error: Evidence $evi_id not found" >&2
        return 1
    fi

    local updated_at
    updated_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    local updated
    updated=$(echo "$existing" | jq -c \
        --arg confidence "$new_confidence" \
        --arg updated_at "$updated_at" \
        '. + {confidence: $confidence, updated_at: $updated_at}')

    echo "$updated" >> "$EVIDENCE_FILE"

    echo "$evi_id"
}

# Count evidence by confidence level
evidence_stats() {
    init_evidence

    if [[ ! -s "$EVIDENCE_FILE" ]]; then
        echo '{"total":0,"preliminary":0,"confirmed":0,"contested":0,"superseded":0}'
        return 0
    fi

    jq -s '
        group_by(.id) | map(.[-1]) |
        {
            total: length,
            preliminary: [.[] | select(.confidence == "preliminary")] | length,
            confirmed: [.[] | select(.confidence == "confirmed")] | length,
            contested: [.[] | select(.confidence == "contested")] | length,
            superseded: [.[] | select(.confidence == "superseded")] | length
        }
    ' "$EVIDENCE_FILE"
}
