#!/usr/bin/env bash
#
# Handoff - Explicit succession notes
#
# Creates structured handoff notes for successor sessions
# Includes: what was done, what's left, gotchas encountered
# Priority ordering for next session
# Questions that need answering
#

#######################################
# Create a structured handoff note
#######################################
create_handoff() {
    local message="$1"

    if [[ ! -f "${CURRENT_SESSION_FILE}" ]]; then
        echo "No active session. Run 'transfer.sh init' first."
        return 1
    fi

    local session_id
    session_id=$(cat "${CURRENT_SESSION_FILE}")
    local session_file="${SESSIONS_DIR}/${session_id}.json"

    if [[ ! -f "${session_file}" ]]; then
        echo "Session file not found: ${session_file}"
        return 1
    fi

    echo "Creating handoff for session: ${session_id}"
    echo ""

    # Parse the message for structured content
    # Support formats like:
    #   "Did X, Y, Z. Need to do A, B. Blocked by C. Question: D?"

    local tmp_file
    tmp_file=$(mktemp)

    # Add the raw handoff message
    jq --arg msg "${message}" \
       --arg time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
       '
       .handoff.message = $msg |
       .handoff.created_at = $time |
       .ended_at = $time
       ' "${session_file}" > "${tmp_file}"

    mv "${tmp_file}" "${session_file}"

    echo "Handoff note created."
    echo ""
    echo "Message: ${message}"
    echo ""
    echo "To add structured information, use:"
    echo "  transfer.sh handoff:next <step>      - Add next step"
    echo "  transfer.sh handoff:blocker <issue>  - Add blocker"
    echo "  transfer.sh handoff:question <q>     - Add question"
    echo ""
    echo "Or edit the session file directly: ${session_file}"
}

#######################################
# Add a next step to the handoff
#######################################
add_next_step() {
    local step="$1"
    local priority="${2:-0}"  # 0 = append, n = insert at position n

    if [[ ! -f "${CURRENT_SESSION_FILE}" ]]; then
        echo "No active session."
        return 1
    fi

    local session_id
    session_id=$(cat "${CURRENT_SESSION_FILE}")
    local session_file="${SESSIONS_DIR}/${session_id}.json"

    local tmp_file
    tmp_file=$(mktemp)

    if [[ "${priority}" -eq 0 ]]; then
        # Append to end
        jq --arg step "${step}" '.handoff.next_steps += [$step]' "${session_file}" > "${tmp_file}"
    else
        # Insert at specific position
        jq --arg step "${step}" --argjson pos "${priority}" \
           '.handoff.next_steps = (.handoff.next_steps[:$pos] + [$step] + .handoff.next_steps[$pos:])' \
           "${session_file}" > "${tmp_file}"
    fi

    mv "${tmp_file}" "${session_file}"
    echo "Added next step: ${step}"
}

#######################################
# Add a blocker to the handoff
#######################################
add_blocker() {
    local blocker="$1"

    if [[ ! -f "${CURRENT_SESSION_FILE}" ]]; then
        echo "No active session."
        return 1
    fi

    local session_id
    session_id=$(cat "${CURRENT_SESSION_FILE}")
    local session_file="${SESSIONS_DIR}/${session_id}.json"

    local tmp_file
    tmp_file=$(mktemp)

    jq --arg blocker "${blocker}" '.handoff.blockers += [$blocker]' "${session_file}" > "${tmp_file}"
    mv "${tmp_file}" "${session_file}"

    echo "Added blocker: ${blocker}"
}

#######################################
# Add a question to the handoff
#######################################
add_question() {
    local question="$1"

    if [[ ! -f "${CURRENT_SESSION_FILE}" ]]; then
        echo "No active session."
        return 1
    fi

    local session_id
    session_id=$(cat "${CURRENT_SESSION_FILE}")
    local session_file="${SESSIONS_DIR}/${session_id}.json"

    local tmp_file
    tmp_file=$(mktemp)

    jq --arg question "${question}" '.handoff.questions += [$question]' "${session_file}" > "${tmp_file}"
    mv "${tmp_file}" "${session_file}"

    echo "Added question: ${question}"
}

#######################################
# Create an interactive handoff wizard
#######################################
interactive_handoff() {
    if [[ ! -f "${CURRENT_SESSION_FILE}" ]]; then
        echo "No active session. Run 'transfer.sh init' first."
        return 1
    fi

    local session_id
    session_id=$(cat "${CURRENT_SESSION_FILE}")

    echo "=== Handoff Wizard for ${session_id} ==="
    echo ""

    # Summary
    echo "What did you accomplish in this session?"
    echo "(One line summary)"
    read -r summary
    if [[ -n "${summary}" ]]; then
        local session_file="${SESSIONS_DIR}/${session_id}.json"
        local tmp_file
        tmp_file=$(mktemp)
        jq --arg summary "${summary}" '.summary = $summary' "${session_file}" > "${tmp_file}"
        mv "${tmp_file}" "${session_file}"
    fi
    echo ""

    # Next steps
    echo "What are the next steps? (Enter each on a line, empty line to finish)"
    while true; do
        read -r step
        [[ -z "${step}" ]] && break
        add_next_step "${step}"
    done
    echo ""

    # Blockers
    echo "Any blockers? (Enter each on a line, empty line to finish)"
    while true; do
        read -r blocker
        [[ -z "${blocker}" ]] && break
        add_blocker "${blocker}"
    done
    echo ""

    # Questions
    echo "Any open questions? (Enter each on a line, empty line to finish)"
    while true; do
        read -r question
        [[ -z "${question}" ]] && break
        add_question "${question}"
    done
    echo ""

    # Finalize
    local session_file="${SESSIONS_DIR}/${session_id}.json"
    local tmp_file
    tmp_file=$(mktemp)
    jq --arg time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '.ended_at = $time' "${session_file}" > "${tmp_file}"
    mv "${tmp_file}" "${session_file}"

    echo "=== Handoff Complete ==="
    echo "Session ${session_id} is ready for succession."
}

#######################################
# Generate a handoff summary for display
#######################################
format_handoff() {
    local session_id="$1"
    local session_file="${SESSIONS_DIR}/${session_id}.json"

    if [[ ! -f "${session_file}" ]]; then
        echo "Session not found: ${session_id}"
        return 1
    fi

    echo "=== HANDOFF: ${session_id} ==="
    echo ""

    local summary
    summary=$(jq -r '.summary // "(no summary)"' "${session_file}")
    echo "Summary: ${summary}"
    echo ""

    local handoff_msg
    handoff_msg=$(jq -r '.handoff.message // ""' "${session_file}")
    if [[ -n "${handoff_msg}" ]]; then
        echo "Handoff Message:"
        echo "  ${handoff_msg}"
        echo ""
    fi

    echo "NEXT STEPS (in priority order):"
    local i=1
    jq -r '.handoff.next_steps[]' "${session_file}" 2>/dev/null | while read -r step; do
        echo "  ${i}. ${step}"
        ((i++))
    done
    echo ""

    local blockers_count
    blockers_count=$(jq '.handoff.blockers | length' "${session_file}")
    if [[ "${blockers_count}" -gt 0 ]]; then
        echo "BLOCKERS (must resolve):"
        jq -r '.handoff.blockers[]' "${session_file}" | while read -r blocker; do
            echo "  [!] ${blocker}"
        done
        echo ""
    fi

    local questions_count
    questions_count=$(jq '.handoff.questions | length' "${session_file}")
    if [[ "${questions_count}" -gt 0 ]]; then
        echo "QUESTIONS (need answers):"
        jq -r '.handoff.questions[]' "${session_file}" | while read -r question; do
            echo "  ? ${question}"
        done
        echo ""
    fi

    # Gotchas/patterns learned
    local patterns_count
    patterns_count=$(jq '.patterns_learned | length' "${session_file}")
    if [[ "${patterns_count}" -gt 0 ]]; then
        echo "GOTCHAS/LESSONS LEARNED:"
        jq -r '.patterns_learned[]' "${session_file}" | while read -r pattern; do
            echo "  * ${pattern}"
        done
        echo ""
    fi

    echo "==========================="
}
