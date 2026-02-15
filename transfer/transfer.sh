#!/usr/bin/env bash
#
# Context Transfer - Enable succession between sessions
#
# Usage:
#   transfer.sh snapshot              - Capture current session state
#   transfer.sh resume <session-id>   - Load context from previous session
#   transfer.sh handoff <message>      - Create explicit handoff note
#   transfer.sh status                 - Show what context is loaded
#   transfer.sh diff <s1> <s2>        - Compare sessions
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TRANSFER_ROOT="${LORE_TRANSFER_ROOT:-$SCRIPT_DIR}"
DATA_DIR="${TRANSFER_ROOT}/data"
SESSIONS_DIR="${DATA_DIR}/sessions"
CURRENT_SESSION_FILE="${DATA_DIR}/.current_session"

# Source library functions
source "${SCRIPT_DIR}/lib/snapshot.sh"
source "${SCRIPT_DIR}/lib/resume.sh"
source "${SCRIPT_DIR}/lib/handoff.sh"
source "${SCRIPT_DIR}/lib/compress.sh"

# Ensure data directories exist
mkdir -p "${SESSIONS_DIR}"

#######################################
# Display usage information
#######################################
usage() {
    cat << 'EOF'
Context Transfer - Enable succession between sessions

USAGE:
    transfer.sh <command> [options]

COMMANDS:
    snapshot                    Capture current session state
    resume <session-id>         Load context from previous session
    handoff <message>           Create explicit handoff note for successor
    status                      Show what context is loaded
    diff <session1> <session2>  Compare what changed between sessions
    list                        List all saved sessions
    init                        Initialize a new session

OPTIONS:
    -h, --help                  Show this help message
    -v, --verbose               Enable verbose output
    --json                      Output in JSON format

EXAMPLES:
    # Start a new session
    transfer.sh init

    # Capture current state
    transfer.sh snapshot

    # See what sessions exist
    transfer.sh list

    # Resume from a previous session
    transfer.sh resume session-abc123

    # Create handoff note before ending
    transfer.sh handoff "Finished API, need to add tests"

    # Compare two sessions
    transfer.sh diff session-abc123 session-def456
EOF
}

#######################################
# Initialize a new session
#######################################
cmd_init() {
    local session_id="session-$(date +%Y%m%d-%H%M%S)-$(openssl rand -hex 4 2>/dev/null || echo $$)"
    local session_file="${SESSIONS_DIR}/${session_id}.json"

    # Create initial session structure
    cat > "${session_file}" << EOF
{
  "id": "${session_id}",
  "started_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "ended_at": null,
  "summary": "",
  "goals_addressed": [],
  "decisions_made": [],
  "patterns_learned": [],
  "open_threads": [],
  "handoff": {
    "next_steps": [],
    "blockers": [],
    "questions": []
  },
  "git_state": {
    "branch": "",
    "commits": [],
    "uncommitted": []
  },
  "context": {
    "active_files": [],
    "recent_commands": [],
    "environment": {}
  }
}
EOF

    # Set as current session
    echo "${session_id}" > "${CURRENT_SESSION_FILE}"

    echo "Initialized new session: ${session_id}"
    echo "Session file: ${session_file}"
}

#######################################
# List all sessions
#######################################
cmd_list() {
    local json_output="${1:-false}"

    if [[ ! -d "${SESSIONS_DIR}" ]] || [[ -z "$(ls -A "${SESSIONS_DIR}" 2>/dev/null)" ]]; then
        echo "No sessions found."
        return 0
    fi

    if [[ "${json_output}" == "true" ]]; then
        echo "["
        local first=true
        for session_file in "${SESSIONS_DIR}"/*.json; do
            [[ -f "${session_file}" ]] || continue
            if [[ "${first}" == "true" ]]; then
                first=false
            else
                echo ","
            fi
            cat "${session_file}"
        done
        echo "]"
    else
        local current_session=""
        [[ -f "${CURRENT_SESSION_FILE}" ]] && current_session=$(cat "${CURRENT_SESSION_FILE}")

        printf "%-40s %-20s %-20s %s\n" "SESSION ID" "STARTED" "ENDED" "SUMMARY"
        printf "%s\n" "$(printf '=%.0s' {1..100})"

        for session_file in "${SESSIONS_DIR}"/*.json; do
            [[ -f "${session_file}" ]] || continue

            local id started ended summary marker=""
            id=$(jq -r '.id // "unknown"' "${session_file}")
            started=$(jq -r '.started_at // "unknown"' "${session_file}" | cut -c1-19)
            ended=$(jq -r '.ended_at // "active"' "${session_file}" | cut -c1-19)
            summary=$(jq -r '.summary // ""' "${session_file}" | head -c 40)

            [[ "${id}" == "${current_session}" ]] && marker=" *"

            printf "%-40s %-20s %-20s %s%s\n" "${id}" "${started}" "${ended}" "${summary}" "${marker}"
        done

        echo ""
        echo "* = current session"
    fi
}

#######################################
# Show current status
#######################################
cmd_status() {
    local json_output="${1:-false}"

    if [[ ! -f "${CURRENT_SESSION_FILE}" ]]; then
        echo "No active session. Run 'transfer.sh init' to start one."
        return 1
    fi

    local current_session
    current_session=$(cat "${CURRENT_SESSION_FILE}")
    local session_file="${SESSIONS_DIR}/${current_session}.json"

    if [[ ! -f "${session_file}" ]]; then
        echo "Current session file not found: ${session_file}"
        return 1
    fi

    if [[ "${json_output}" == "true" ]]; then
        cat "${session_file}"
    else
        echo "=== Current Session Status ==="
        echo ""
        echo "Session ID: ${current_session}"
        echo "Started: $(jq -r '.started_at' "${session_file}")"
        echo ""

        local summary
        summary=$(jq -r '.summary // ""' "${session_file}")
        if [[ -n "${summary}" ]]; then
            echo "Summary: ${summary}"
            echo ""
        fi

        echo "--- Goals Addressed ---"
        jq -r '.goals_addressed[]? // empty' "${session_file}" | while read -r goal; do
            echo "  - ${goal}"
        done

        echo ""
        echo "--- Decisions Made ---"
        jq -r '.decisions_made[]? // empty' "${session_file}" | while read -r decision; do
            echo "  - ${decision}"
        done

        echo ""
        echo "--- Open Threads ---"
        jq -r '.open_threads[]? // empty' "${session_file}" | while read -r thread; do
            echo "  - ${thread}"
        done

        echo ""
        echo "--- Handoff Notes ---"
        echo "Next Steps:"
        jq -r '.handoff.next_steps[]? // empty' "${session_file}" | while read -r step; do
            echo "  - ${step}"
        done
        echo "Blockers:"
        jq -r '.handoff.blockers[]? // empty' "${session_file}" | while read -r blocker; do
            echo "  - ${blocker}"
        done
        echo "Questions:"
        jq -r '.handoff.questions[]? // empty' "${session_file}" | while read -r question; do
            echo "  ? ${question}"
        done

        echo ""
        echo "--- Git State ---"
        local branch
        branch=$(jq -r '.git_state.branch // "unknown"' "${session_file}")
        echo "Branch: ${branch}"
        echo "Recent commits:"
        jq -r '.git_state.commits[]? // empty' "${session_file}" | head -5 | while read -r commit; do
            echo "  - ${commit}"
        done
        echo "Uncommitted files:"
        jq -r '.git_state.uncommitted[]? // empty' "${session_file}" | while read -r file; do
            echo "  - ${file}"
        done
    fi
}

#######################################
# Compare two sessions
#######################################
cmd_diff() {
    local session1="$1"
    local session2="$2"

    local file1="${SESSIONS_DIR}/${session1}.json"
    local file2="${SESSIONS_DIR}/${session2}.json"

    if [[ ! -f "${file1}" ]]; then
        echo "Session not found: ${session1}"
        return 1
    fi

    if [[ ! -f "${file2}" ]]; then
        echo "Session not found: ${session2}"
        return 1
    fi

    echo "=== Session Comparison ==="
    echo ""
    echo "Session 1: ${session1}"
    echo "  Started: $(jq -r '.started_at' "${file1}")"
    echo "  Summary: $(jq -r '.summary // "(none)"' "${file1}")"
    echo ""
    echo "Session 2: ${session2}"
    echo "  Started: $(jq -r '.started_at' "${file2}")"
    echo "  Summary: $(jq -r '.summary // "(none)"' "${file2}")"
    echo ""

    # Compare goals
    echo "--- Goals Addressed ---"
    echo "Only in ${session1}:"
    comm -23 <(jq -r '.goals_addressed[]?' "${file1}" 2>/dev/null | sort) \
             <(jq -r '.goals_addressed[]?' "${file2}" 2>/dev/null | sort) | \
        while read -r g; do echo "  - ${g}"; done
    echo "Only in ${session2}:"
    comm -13 <(jq -r '.goals_addressed[]?' "${file1}" 2>/dev/null | sort) \
             <(jq -r '.goals_addressed[]?' "${file2}" 2>/dev/null | sort) | \
        while read -r g; do echo "  + ${g}"; done
    echo ""

    # Compare decisions
    echo "--- Decisions Made ---"
    echo "Only in ${session1}:"
    comm -23 <(jq -r '.decisions_made[]?' "${file1}" 2>/dev/null | sort) \
             <(jq -r '.decisions_made[]?' "${file2}" 2>/dev/null | sort) | \
        while read -r d; do echo "  - ${d}"; done
    echo "Only in ${session2}:"
    comm -13 <(jq -r '.decisions_made[]?' "${file1}" 2>/dev/null | sort) \
             <(jq -r '.decisions_made[]?' "${file2}" 2>/dev/null | sort) | \
        while read -r d; do echo "  + ${d}"; done
    echo ""

    # Compare patterns learned
    echo "--- Patterns Learned ---"
    echo "Only in ${session1}:"
    comm -23 <(jq -r '.patterns_learned[]?' "${file1}" 2>/dev/null | sort) \
             <(jq -r '.patterns_learned[]?' "${file2}" 2>/dev/null | sort) | \
        while read -r p; do echo "  - ${p}"; done
    echo "Only in ${session2}:"
    comm -13 <(jq -r '.patterns_learned[]?' "${file1}" 2>/dev/null | sort) \
             <(jq -r '.patterns_learned[]?' "${file2}" 2>/dev/null | sort) | \
        while read -r p; do echo "  + ${p}"; done
    echo ""

    # Git state comparison
    echo "--- Git State ---"
    local branch1 branch2
    branch1=$(jq -r '.git_state.branch // "unknown"' "${file1}")
    branch2=$(jq -r '.git_state.branch // "unknown"' "${file2}")
    echo "Branch: ${branch1} -> ${branch2}"

    local commits1 commits2
    commits1=$(jq -r '.git_state.commits | length' "${file1}")
    commits2=$(jq -r '.git_state.commits | length' "${file2}")
    echo "Commits tracked: ${commits1} -> ${commits2}"
}

#######################################
# Main entry point
#######################################
main() {
    local command="${1:-}"
    local json_output=false
    local verbose=false

    # Parse global options
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                usage
                exit 0
                ;;
            -v|--verbose)
                verbose=true
                shift
                ;;
            --json)
                json_output=true
                shift
                ;;
            *)
                break
                ;;
        esac
    done

    command="${1:-}"
    shift || true

    case "${command}" in
        init)
            cmd_init
            ;;
        snapshot)
            snapshot_session "$@"
            ;;
        resume)
            if [[ $# -lt 1 ]]; then
                resume_latest
            else
                resume_session "$1" "${json_output}"
            fi
            ;;
        handoff)
            if [[ $# -lt 1 ]]; then
                echo "Usage: transfer.sh handoff <message>"
                exit 1
            fi
            create_handoff "$*"
            ;;
        status)
            cmd_status "${json_output}"
            ;;
        diff)
            if [[ $# -lt 2 ]]; then
                echo "Usage: transfer.sh diff <session1> <session2>"
                exit 1
            fi
            cmd_diff "$1" "$2"
            ;;
        list)
            cmd_list "${json_output}"
            ;;
        compress)
            if [[ $# -lt 1 ]]; then
                echo "Usage: transfer.sh compress <session-id>"
                exit 1
            fi
            compress_session "$1"
            ;;
        ""|help)
            usage
            ;;
        *)
            echo "Unknown command: ${command}"
            echo "Run 'transfer.sh --help' for usage."
            exit 1
            ;;
    esac
}

main "$@"
