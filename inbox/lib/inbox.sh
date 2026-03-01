#!/usr/bin/env bash
# Inbox staging area - append-only raw signals
# Part of the Lore memory system for AI agents

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../lib/paths.sh"
DATA_DIR="${LORE_INBOX_DATA}"
SIGNALS_FILE="${LORE_SIGNALS_FILE}"

# Ensure data directory exists
init_inbox() {
    mkdir -p "$DATA_DIR"
    touch "$SIGNALS_FILE"
}

# Generate unique signal ID (sig- prefix + 8 hex chars)
generate_signal_id() {
    echo "sig-$(od -An -tx1 -N4 /dev/urandom | tr -d ' \n')"
}

# Append a raw signal to the inbox
# Args: content source [tags]
# Rejects empty content. Injects timestamp automatically.
signal_append() {
    local content="$1"
    local source="${2:-manual}"
    local tags="${3:-}"

    if [[ -z "$content" ]]; then
        echo "Error: Signal content required" >&2
        return 1
    fi

    init_inbox

    local id
    id=$(generate_signal_id)

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
    echo "$record" >> "$SIGNALS_FILE"

    echo "$id"
}

# List signals, optionally filtered by status
# Args: [status]
signal_list() {
    local filter_status="${1:-}"

    init_inbox

    if [[ ! -s "$SIGNALS_FILE" ]]; then
        echo "[]"
        return 0
    fi

    if [[ -n "$filter_status" ]]; then
        jq -s --arg s "$filter_status" \
            '[.[] | select(.status == $s)] | sort_by(.timestamp) | reverse' \
            "$SIGNALS_FILE"
    else
        jq -s 'sort_by(.timestamp) | reverse' "$SIGNALS_FILE"
    fi
}

# Mark a signal as promoted
# Args: signal_id target_description [target_type]
# target_type: "evidence" or "decision" (default: "decision")
# Sets status to "promoted" and records the promotion target.
# Does NOT create the target entry -- use lore remember or lore learn.
signal_promote() {
    local sig_id="$1"
    local target="${2:-}"
    local target_type="${3:-decision}"

    if [[ -z "$sig_id" ]]; then
        echo "Error: Signal ID required" >&2
        return 1
    fi

    if [[ "$target_type" != "evidence" && "$target_type" != "decision" ]]; then
        echo "Error: target_type must be 'evidence' or 'decision'" >&2
        return 1
    fi

    init_inbox

    # Verify the signal exists
    local existing
    existing=$(jq -c --arg id "$sig_id" 'select(.id == $id)' "$SIGNALS_FILE" 2>/dev/null | tail -1)

    if [[ -z "$existing" ]]; then
        echo "Error: Signal $sig_id not found" >&2
        return 1
    fi

    local current_status
    current_status=$(echo "$existing" | jq -r '.status')

    if [[ "$current_status" != "raw" ]]; then
        echo "Error: Signal $sig_id already has status '$current_status'" >&2
        return 1
    fi

    # Build updated record with promoted status
    local promoted_at
    promoted_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    local updated
    updated=$(echo "$existing" | jq -c \
        --arg status "promoted" \
        --arg target "$target" \
        --arg target_type "$target_type" \
        --arg promoted_at "$promoted_at" \
        '. + {status: $status, promoted_to: $target_type, promoted_target: $target, promoted_at: $promoted_at}')

    # Append updated version (append-only; latest version wins on read)
    echo "$updated" >> "$SIGNALS_FILE"

    echo "$sig_id"
}

# Mark a signal as discarded
# Args: signal_id [reason]
signal_discard() {
    local sig_id="$1"
    local reason="${2:-}"

    if [[ -z "$sig_id" ]]; then
        echo "Error: Signal ID required" >&2
        return 1
    fi

    init_inbox

    local existing
    existing=$(jq -c --arg id "$sig_id" 'select(.id == $id)' "$SIGNALS_FILE" 2>/dev/null | tail -1)

    if [[ -z "$existing" ]]; then
        echo "Error: Signal $sig_id not found" >&2
        return 1
    fi

    local current_status
    current_status=$(echo "$existing" | jq -r '.status')

    if [[ "$current_status" != "raw" ]]; then
        echo "Error: Signal $sig_id already has status '$current_status'" >&2
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

    echo "$updated" >> "$SIGNALS_FILE"

    echo "$sig_id"
}

# Get a single signal by ID (latest version)
signal_get() {
    local sig_id="$1"

    init_inbox

    jq -c --arg id "$sig_id" 'select(.id == $id)' "$SIGNALS_FILE" 2>/dev/null | tail -1
}

# Count signals by status
signal_stats() {
    init_inbox

    if [[ ! -s "$SIGNALS_FILE" ]]; then
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
    ' "$SIGNALS_FILE"
}
