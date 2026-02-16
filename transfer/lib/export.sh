#!/usr/bin/env bash
#
# Session Export - Render sessions to various formats
#
# Supports: markdown (default), json
#

#######################################
# Export session as markdown
#######################################
export_markdown() {
    local file="$1"

    local id summary started ended
    id=$(jq -r '.id' "${file}")
    summary=$(jq -r '.summary // "No summary"' "${file}")
    started=$(jq -r '.started_at' "${file}")
    ended=$(jq -r '.ended_at // "In progress"' "${file}")

    cat <<EOF
# Session: ${id}

**Started:** ${started}  
**Ended:** ${ended}

## Summary

${summary}

## Goals Addressed

$(jq -r '.goals_addressed[]? // empty | "- " + .' "${file}" | grep -v '^$' || echo "_None_")

## Decisions Made

$(jq -r '.decisions_made[]? // empty | "- " + .' "${file}" | grep -v '^$' || echo "_None_")

## Patterns Learned

$(jq -r '.patterns_learned[]? // empty | "- " + .' "${file}" | grep -v '^$' || echo "_None_")

## Open Threads

$(jq -r '.open_threads[]? // empty | "- [ ] " + .' "${file}" | grep -v '^$' || echo "_None_")

## Handoff

$(jq -r '.handoff.message // "No handoff note"' "${file}")

### Next Steps

$(jq -r '.handoff.next_steps[]? // empty | "1. " + .' "${file}" | grep -v '^$' || echo "_None_")

### Blockers

$(jq -r '.handoff.blockers[]? // empty | "- " + .' "${file}" | grep -v '^$' || echo "_None_")

### Open Questions

$(jq -r '.handoff.questions[]? // empty | "- " + .' "${file}" | grep -v '^$' || echo "_None_")

## Git State

- **Branch:** $(jq -r '.git_state.branch // "unknown"' "${file}")
- **Uncommitted files:** $(jq -r '.git_state.uncommitted | length' "${file}")

### Recent Commits

$(jq -r '.git_state.commits[]? // empty | "- " + .' "${file}" | head -5 | grep -v '^$' || echo "_None_")

## Related Entries

- **Journal entries:** $(jq -r '.related.journal_entries | length // 0' "${file}")
- **Patterns:** $(jq -r '.related.patterns | length // 0' "${file}")
EOF
}

#######################################
# Find session file by ID (supports partial match)
#######################################
find_session_file() {
    local session_id="$1"

    # Exact match first
    if [[ -f "${SESSIONS_DIR}/${session_id}.json" ]]; then
        echo "${SESSIONS_DIR}/${session_id}.json"
        return 0
    fi

    # Partial match
    local matches
    matches=$(find "${SESSIONS_DIR}" -name "${session_id}*.json" 2>/dev/null | head -1)
    
    if [[ -n "${matches}" ]]; then
        echo "${matches}"
        return 0
    fi

    return 1
}

#######################################
# Export a session to specified format
#######################################
export_session() {
    local session_id=""
    local format="markdown"
    local all_sessions=false
    local output_dir=""

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --format|-f)
                format="$2"
                shift 2
                ;;
            --all|-a)
                all_sessions=true
                shift
                ;;
            --output|-o)
                output_dir="$2"
                shift 2
                ;;
            -*)
                echo "Unknown option: $1" >&2
                echo "Usage: transfer.sh export [session-id] [--format markdown|json] [--all] [--output dir]" >&2
                return 1
                ;;
            *)
                session_id="$1"
                shift
                ;;
        esac
    done

    # Export all sessions
    if [[ "${all_sessions}" == true ]]; then
        export_all_sessions "${format}" "${output_dir}"
        return $?
    fi

    # Use current session if none specified
    if [[ -z "${session_id}" ]]; then
        if [[ -f "${CURRENT_SESSION_FILE}" ]]; then
            session_id=$(cat "${CURRENT_SESSION_FILE}")
        else
            echo "No session specified and no active session." >&2
            echo "Usage: transfer.sh export <session-id> [--format markdown|json]" >&2
            return 1
        fi
    fi

    # Find the session file
    local session_file
    session_file=$(find_session_file "${session_id}") || {
        echo "Session not found: ${session_id}" >&2
        return 1
    }

    # Export in requested format
    case "${format}" in
        markdown|md)
            export_markdown "${session_file}"
            ;;
        json)
            cat "${session_file}"
            ;;
        *)
            echo "Unknown format: ${format}" >&2
            echo "Supported formats: markdown, json" >&2
            return 1
            ;;
    esac
}

#######################################
# Export all sessions to a directory
#######################################
export_all_sessions() {
    local format="${1:-markdown}"
    local output_dir="${2:-.}"

    mkdir -p "${output_dir}"

    local count=0
    for session_file in "${SESSIONS_DIR}"/*.json; do
        [[ -f "${session_file}" ]] || continue

        local id
        id=$(jq -r '.id' "${session_file}")

        case "${format}" in
            markdown|md)
                export_markdown "${session_file}" > "${output_dir}/${id}.md"
                ;;
            json)
                cp "${session_file}" "${output_dir}/${id}.json"
                ;;
        esac

        ((count++))
    done

    echo "Exported ${count} sessions to ${output_dir}/"
}
