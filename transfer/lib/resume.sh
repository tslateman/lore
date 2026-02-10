#!/usr/bin/env bash
#
# Resume - Load context from previous session
#
# Loads previous session snapshot
# Summarizes what happened in that session
# Highlights unfinished work and open questions
# Surfaces relevant patterns learned
#

#######################################
# Load a previous session and display context
#######################################
resume_session() {
    local session_id="$1"
    local json_output="${2:-false}"

    local session_file="${SESSIONS_DIR}/${session_id}.json"

    if [[ ! -f "${session_file}" ]]; then
        echo "Session not found: ${session_id}"
        echo "Available sessions:"
        ls -1 "${SESSIONS_DIR}"/*.json 2>/dev/null | xargs -I{} basename {} .json
        return 1
    fi

    if [[ "${json_output}" == "true" ]]; then
        # Output raw session data for machine consumption
        cat "${session_file}"
        return 0
    fi

    echo "=============================================="
    echo "  RESUMING SESSION: ${session_id}"
    echo "=============================================="
    echo ""

    # Session metadata
    local started ended summary
    started=$(jq -r '.started_at // "unknown"' "${session_file}")
    ended=$(jq -r '.ended_at // "still active"' "${session_file}")
    summary=$(jq -r '.summary // "(no summary)"' "${session_file}")

    echo "Started: ${started}"
    echo "Ended: ${ended}"
    echo ""
    echo "Summary: ${summary}"
    echo ""

    # What was accomplished
    echo "--- What Was Accomplished ---"
    local goals_count
    goals_count=$(jq '.goals_addressed | length' "${session_file}")
    if [[ "${goals_count}" -gt 0 ]]; then
        echo "Goals addressed (${goals_count}):"
        jq -r '.goals_addressed[]' "${session_file}" | while read -r goal; do
            echo "  [x] ${goal}"
        done
    else
        echo "  (no goals recorded)"
    fi
    echo ""

    # Decisions made
    local decisions_count
    decisions_count=$(jq '.decisions_made | length' "${session_file}")
    if [[ "${decisions_count}" -gt 0 ]]; then
        echo "Decisions made (${decisions_count}):"
        jq -r '.decisions_made[]' "${session_file}" | while read -r decision; do
            echo "  * ${decision}"
        done
    else
        echo "  (no decisions recorded)"
    fi
    echo ""

    # Patterns learned - these are valuable!
    local patterns_count
    patterns_count=$(jq '.patterns_learned | length' "${session_file}")
    if [[ "${patterns_count}" -gt 0 ]]; then
        echo "--- Patterns Learned (Important!) ---"
        jq -r '.patterns_learned[]' "${session_file}" | while read -r pattern; do
            echo "  ! ${pattern}"
        done
        echo ""
    fi

    # Open threads - what needs attention
    echo "--- Open Threads (Needs Attention) ---"
    local threads_count
    threads_count=$(jq '.open_threads | length' "${session_file}")
    if [[ "${threads_count}" -gt 0 ]]; then
        jq -r '.open_threads[]' "${session_file}" | while read -r thread; do
            echo "  [ ] ${thread}"
        done
    else
        echo "  (no open threads)"
    fi
    echo ""

    # Handoff notes
    echo "--- Handoff Notes ---"

    echo "Next Steps (prioritized):"
    local next_steps_count
    next_steps_count=$(jq '.handoff.next_steps | length' "${session_file}")
    if [[ "${next_steps_count}" -gt 0 ]]; then
        local i=1
        jq -r '.handoff.next_steps[]' "${session_file}" | while read -r step; do
            echo "  ${i}. ${step}"
            ((i++))
        done
    else
        echo "  (none specified)"
    fi
    echo ""

    echo "Blockers:"
    local blockers_count
    blockers_count=$(jq '.handoff.blockers | length' "${session_file}")
    if [[ "${blockers_count}" -gt 0 ]]; then
        jq -r '.handoff.blockers[]' "${session_file}" | while read -r blocker; do
            echo "  [BLOCKED] ${blocker}"
        done
    else
        echo "  (none)"
    fi
    echo ""

    echo "Open Questions:"
    local questions_count
    questions_count=$(jq '.handoff.questions | length' "${session_file}")
    if [[ "${questions_count}" -gt 0 ]]; then
        jq -r '.handoff.questions[]' "${session_file}" | while read -r question; do
            echo "  ? ${question}"
        done
    else
        echo "  (none)"
    fi
    echo ""

    # Git state
    echo "--- Git State at Session End ---"
    local branch uncommitted_count
    branch=$(jq -r '.git_state.branch // "unknown"' "${session_file}")
    uncommitted_count=$(jq '.git_state.uncommitted | length' "${session_file}")

    echo "Branch: ${branch}"

    if [[ "${uncommitted_count}" -gt 0 ]]; then
        echo "Uncommitted files (${uncommitted_count}):"
        jq -r '.git_state.uncommitted[]' "${session_file}" | while read -r file; do
            echo "  M ${file}"
        done
    fi

    echo ""
    echo "Recent commits:"
    jq -r '.git_state.commits[]' "${session_file}" 2>/dev/null | head -5 | while read -r commit; do
        echo "  ${commit}"
    done
    echo ""

    # Related entries from other lineage components
    if jq -e '.related' "${session_file}" &>/dev/null; then
        echo "--- Related Lineage Entries ---"

        local journal_count pattern_count goal_count
        journal_count=$(jq '.related.journal_entries | length' "${session_file}" 2>/dev/null || echo 0)
        pattern_count=$(jq '.related.patterns | length' "${session_file}" 2>/dev/null || echo 0)
        goal_count=$(jq '.related.goals | length' "${session_file}" 2>/dev/null || echo 0)

        echo "  Journal entries: ${journal_count}"
        echo "  Patterns: ${pattern_count}"
        echo "  Active goals: ${goal_count}"
        echo ""
    fi

    # Set as current session for continuation
    echo "${session_id}" > "${CURRENT_SESSION_FILE}"

    echo "=============================================="
    echo "  Session loaded. You can continue working."
    echo "  Use 'transfer.sh snapshot' to save progress."
    echo "=============================================="
}

#######################################
# Get a brief summary for quick context
#######################################
get_session_brief() {
    local session_id="$1"
    local session_file="${SESSIONS_DIR}/${session_id}.json"

    if [[ ! -f "${session_file}" ]]; then
        echo "Session not found: ${session_id}"
        return 1
    fi

    local summary goals_count threads_count
    summary=$(jq -r '.summary // "(no summary)"' "${session_file}")
    goals_count=$(jq '.goals_addressed | length' "${session_file}")
    threads_count=$(jq '.open_threads | length' "${session_file}")

    echo "Session: ${session_id}"
    echo "Summary: ${summary}"
    echo "Goals completed: ${goals_count}"
    echo "Open threads: ${threads_count}"

    # Show top 3 next steps if any
    local next_steps
    next_steps=$(jq -r '.handoff.next_steps[:3][]' "${session_file}" 2>/dev/null)
    if [[ -n "${next_steps}" ]]; then
        echo "Top next steps:"
        echo "${next_steps}" | while read -r step; do
            echo "  - ${step}"
        done
    fi
}

#######################################
# Find the most recent session
#######################################
find_latest_session() {
    if [[ ! -d "${SESSIONS_DIR}" ]]; then
        return 1
    fi

    # Find the most recently modified session file
    local latest
    latest=$(ls -t "${SESSIONS_DIR}"/*.json 2>/dev/null | head -1)

    if [[ -n "${latest}" ]]; then
        basename "${latest}" .json
    else
        return 1
    fi
}

#######################################
# Resume from the most recent session
#######################################
resume_latest() {
    local latest
    latest=$(find_latest_session)

    if [[ -z "${latest}" ]]; then
        echo "No sessions found."
        return 1
    fi

    echo "Resuming most recent session: ${latest}"
    resume_session "${latest}"
}
