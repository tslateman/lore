#!/usr/bin/env bash
# JSON I/O helpers for lore.sh
# Provides structured input/output so agents can write and read Lore
# without shell escaping issues and get entry IDs back.

set -euo pipefail

# Emit a success response to stdout.
# Usage: _json_response "$id" "$type" "$timestamp"
_json_response() {
    local id="$1" type="$2" timestamp="$3"
    jq -c -n \
        --arg id "$id" \
        --arg type "$type" \
        --arg timestamp "$timestamp" \
        '{ok: true, id: $id, type: $type, timestamp: $timestamp}'
}

# Emit an error response to stdout.
# Usage: _json_error "message" ["existing_id"]
_json_error() {
    local message="$1"
    local existing_id="${2:-}"
    if [[ -n "$existing_id" ]]; then
        jq -c -n \
            --arg error "$message" \
            --arg existing_id "$existing_id" \
            '{ok: false, error: $error, existing_id: $existing_id}'
    else
        jq -c -n \
            --arg error "$message" \
            '{ok: false, error: $error}'
    fi
}

# Extract a string field from JSON. Returns empty string if missing.
# Usage: val=$(_jq_str "$json" "field_name")
_jq_str() {
    echo "$1" | jq -r --arg k "$2" '.[$k] // empty' 2>/dev/null || true
}

# Extract an array-or-string field as comma-joined string.
# Usage: val=$(_jq_csv "$json" "field_name")
_jq_csv() {
    local json="$1" key="$2"
    local is_array
    is_array=$(echo "$json" | jq -r --arg k "$key" '.[$k] | if type == "array" then "yes" else "no" end' 2>/dev/null) || true
    if [[ "$is_array" == "yes" ]]; then
        echo "$json" | jq -r --arg k "$key" '.[$k] | join(",")' 2>/dev/null || true
    else
        echo "$json" | jq -r --arg k "$key" '.[$k] // empty' 2>/dev/null || true
    fi
}

# Infer capture type from JSON keys.
# Returns: "decision", "pattern", "failure", "evidence", "concept", or "signal"
_infer_type_from_json() {
    local json="$1"

    # Check for explicit type field first
    local explicit
    explicit=$(echo "$json" | jq -r '.type // empty' 2>/dev/null) || true
    if [[ -n "$explicit" ]]; then
        echo "$explicit"
        return
    fi

    # Infer from keys present (mirrors infer_capture_type priority)
    local has_key
    has_key=$(echo "$json" | jq -r 'keys[]' 2>/dev/null) || true

    if echo "$has_key" | grep -qx 'error_type'; then
        echo "failure"
    elif echo "$has_key" | grep -qxE 'solution|problem'; then
        echo "pattern"
    elif echo "$has_key" | grep -qxE 'decision|rationale'; then
        echo "decision"
    elif echo "$has_key" | grep -qx 'definition'; then
        echo "concept"
    elif echo "$has_key" | grep -qxE 'confidence|provenance' && ! echo "$has_key" | grep -qxE 'decision|rationale|solution|problem'; then
        echo "evidence"
    else
        echo "signal"
    fi
}
