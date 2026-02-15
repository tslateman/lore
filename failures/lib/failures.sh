#!/usr/bin/env bash
# Failure journals -- append-only structured failure reports
# Part of the Lore memory system for AI agents

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA_DIR="${SCRIPT_DIR}/../data"
FAILURES_FILE="${DATA_DIR}/failures.jsonl"

VALID_ERROR_TYPES="UserDeny HardDeny NonZeroExit Timeout ToolError LogicError"

# Ensure data directory exists
init_failures() {
    mkdir -p "$DATA_DIR"
    touch "$FAILURES_FILE"
}

# Generate unique failure ID (fail- prefix + 8 hex chars)
generate_failure_id() {
    echo "fail-$(od -An -tx1 -N4 /dev/urandom | tr -d ' \n')"
}

# Validate error type against known vocabulary
validate_error_type() {
    local error_type="$1"
    for valid in $VALID_ERROR_TYPES; do
        [[ "$error_type" == "$valid" ]] && return 0
    done
    echo "Error: Unknown error_type '$error_type'" >&2
    echo "Valid types: $VALID_ERROR_TYPES" >&2
    return 1
}

# Append a failure report to the journal
# Args: error_type message [tool] [mission] [step]
failures_append() {
    local error_type="$1"
    local message="$2"
    local tool="${3:-}"
    local mission="${4:-}"
    local step="${5:-}"

    if [[ -z "$error_type" || -z "$message" ]]; then
        echo "Error: error_type and message required" >&2
        return 1
    fi

    validate_error_type "$error_type" || return 1

    init_failures

    local id
    id=$(generate_failure_id)

    local timestamp
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    local record
    record=$(jq -c -n \
        --arg id "$id" \
        --arg timestamp "$timestamp" \
        --arg error_type "$error_type" \
        --arg error_message "$message" \
        --arg tool "$tool" \
        --arg mission "$mission" \
        --arg step "$step" \
        '{
            id: $id,
            timestamp: $timestamp,
            error_type: $error_type,
            error_message: $error_message
        }
        + (if $tool != "" then {tool: $tool} else {} end)
        + (if $mission != "" then {mission: $mission} else {} end)
        + (if $step != "" then {step: ($step | tonumber? // $step)} else {} end)')

    echo "$record" >> "$FAILURES_FILE"

    echo "$id"
}

# List failures, optionally filtered by error_type or mission
# Args: [error_type] [mission]
failures_list() {
    local filter_type="${1:-}"
    local filter_mission="${2:-}"

    init_failures

    if [[ ! -s "$FAILURES_FILE" ]]; then
        echo "[]"
        return 0
    fi

    local filter='.'
    if [[ -n "$filter_type" ]]; then
        filter="select(.error_type == \"$filter_type\")"
    fi
    if [[ -n "$filter_mission" ]]; then
        if [[ "$filter" == "." ]]; then
            filter="select(.mission == \"$filter_mission\")"
        else
            filter="$filter | select(.mission == \"$filter_mission\")"
        fi
    fi

    jq -s "[.[] | $filter] | sort_by(.timestamp) | reverse" "$FAILURES_FILE"
}

# Return error types that recur >= threshold times (Rule of Three)
# Args: [threshold]
failures_triggers() {
    local threshold="${1:-3}"

    init_failures

    if [[ ! -s "$FAILURES_FILE" ]]; then
        echo "[]"
        return 0
    fi

    jq -s --argjson t "$threshold" '
        group_by(.error_type)
        | map({
            error_type: .[0].error_type,
            count: length,
            latest: (sort_by(.timestamp) | last .timestamp),
            sample_message: (sort_by(.timestamp) | last .error_message)
        })
        | map(select(.count >= $t))
        | sort_by(.count) | reverse
    ' "$FAILURES_FILE"
}

# Show failure timeline for a mission
# Args: mission
failures_timeline() {
    local mission="$1"

    if [[ -z "$mission" ]]; then
        echo "Error: Mission ID required" >&2
        return 1
    fi

    init_failures

    if [[ ! -s "$FAILURES_FILE" ]]; then
        echo "[]"
        return 0
    fi

    jq -s --arg m "$mission" '
        [.[] | select(.mission == $m)]
        | sort_by(.timestamp)
    ' "$FAILURES_FILE"
}

# Count failures by error type
failures_stats() {
    init_failures

    if [[ ! -s "$FAILURES_FILE" ]]; then
        echo '{"total":0}'
        return 0
    fi

    jq -s '
        {
            total: length,
            by_type: (group_by(.error_type) | map({
                key: .[0].error_type,
                value: length
            }) | from_entries)
        }
    ' "$FAILURES_FILE"
}
