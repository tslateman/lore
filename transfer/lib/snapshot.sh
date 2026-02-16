#!/usr/bin/env bash
#
# Session Snapshot - Capture current session state
#
# Captures: current goals, open threads, recent decisions, active files
# Includes: git state (branch, uncommitted changes, recent commits)
# Links: relevant journal entries and patterns
#

#######################################
# Capture git state for the current directory
# Returns JSON object with git information
#######################################
capture_git_state() {
    local git_dir="${1:-.}"

    # Check if we're in a git repo
    if ! git -C "${git_dir}" rev-parse --git-dir &>/dev/null; then
        echo '{"branch": "", "commits": [], "uncommitted": [], "stash_count": 0}'
        return 0
    fi

    local branch commits uncommitted stash_count

    # Get current branch
    branch=$(git -C "${git_dir}" branch --show-current 2>/dev/null || echo "")
    if [[ -z "${branch}" ]]; then
        branch=$(git -C "${git_dir}" rev-parse --short HEAD 2>/dev/null || echo "detached")
    fi

    # Get recent commits (last 10)
    commits=$(git -C "${git_dir}" log --oneline -10 2>/dev/null | jq -R -s 'split("\n") | map(select(length > 0))' || echo '[]')

    # Get uncommitted files
    uncommitted=$(git -C "${git_dir}" status --porcelain 2>/dev/null | awk '{print $2}' | jq -R -s 'split("\n") | map(select(length > 0))' || echo '[]')

    # Get stash count
    stash_count=$(git -C "${git_dir}" stash list 2>/dev/null | wc -l | tr -d ' ')

    cat << EOF
{
  "branch": "${branch}",
  "commits": ${commits},
  "uncommitted": ${uncommitted},
  "stash_count": ${stash_count}
}
EOF
}

#######################################
# Capture active files (recently modified)
#######################################
capture_active_files() {
    local search_dir="${1:-.}"
    local max_files="${2:-20}"

    # Find files modified in the last 24 hours, excluding common noise
    find "${search_dir}" -type f -mtime -1 \
        ! -path '*/.git/*' \
        ! -path '*/node_modules/*' \
        ! -path '*/target/*' \
        ! -path '*/__pycache__/*' \
        ! -path '*/.venv/*' \
        ! -name '*.pyc' \
        ! -name '*.log' \
        2>/dev/null | \
        head -n "${max_files}" | \
        jq -R -s 'split("\n") | map(select(length > 0))'
}

#######################################
# Capture environment context
#######################################
capture_environment() {
    local pwd_value="${PWD}"
    local user_value="${USER:-unknown}"
    local hostname_value="${HOSTNAME:-$(hostname 2>/dev/null || echo 'unknown')}"

    cat << EOF
{
  "pwd": "${pwd_value}",
  "user": "${user_value}",
  "hostname": "${hostname_value}",
  "shell": "${SHELL:-unknown}",
  "term": "${TERM:-unknown}"
}
EOF
}

#######################################
# Detect project name from git or directory
#######################################
detect_project() {
    if git rev-parse --git-dir &>/dev/null; then
        basename "$(git rev-parse --show-toplevel)"
    else
        basename "$PWD"
    fi
}

#######################################
# Link to related lore components
#######################################
find_related_entries() {
    local lore_root="${LORE_ROOT:-$(dirname "${TRANSFER_ROOT}")}"

    local journal_entries='[]'
    local pattern_entries='[]'
    local goal_entries='[]'

    # Find recent journal entries (last 7 days) from JSONL store
    local decisions_file="${lore_root}/journal/data/decisions.jsonl"
    if [[ -f "${decisions_file}" ]]; then
        local cutoff_date
        # macOS BSD date uses -v flag; GNU date uses -d flag
        cutoff_date=$(date -v-7d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null) || \
            cutoff_date=$(date -d '7 days ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null) || \
            cutoff_date="1970-01-01T00:00:00Z"

        journal_entries=$(jq -r --arg cutoff "${cutoff_date}" \
            'select(.timestamp >= $cutoff) | .id // empty' \
            "${decisions_file}" 2>/dev/null | \
            jq -R -s 'split("\n") | map(select(length > 0))') || journal_entries='[]'
    fi

    # Find active patterns from YAML store
    local patterns_file="${lore_root}/patterns/data/patterns.yaml"
    if [[ -f "${patterns_file}" ]]; then
        pattern_entries=$(grep -E '^\s+- id:\s*"' "${patterns_file}" 2>/dev/null | \
            sed 's/.*id:[[:space:]]*"\([^"]*\)".*/\1/' | \
            jq -R -s 'split("\n") | map(select(length > 0))') || pattern_entries='[]'
    fi

    # Goals live in Telos, not Lore -- always empty
    goal_entries='[]'

    cat << EOF
{
  "journal_entries": ${journal_entries},
  "patterns": ${pattern_entries},
  "goals": ${goal_entries}
}
EOF
}

#######################################
# Main snapshot function
# Creates a point-in-time capture of the current session
#######################################
snapshot_session() {
    local summary="${1:-}"

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

    echo "Capturing snapshot for session: ${session_id}"

    # Capture current state
    local git_state active_files environment related project
    git_state=$(capture_git_state)
    active_files=$(capture_active_files)
    environment=$(capture_environment)
    related=$(find_related_entries)
    project=$(detect_project)

    # Update session file with captured state
    local tmp_file
    tmp_file=$(mktemp)

    jq --argjson git "${git_state}" \
       --argjson files "${active_files}" \
       --argjson env "${environment}" \
       --argjson related "${related}" \
       --arg project "${project}" \
       --arg summary "${summary}" \
       --arg snapshot_time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
       '
       .git_state = $git |
       .context.active_files = $files |
       .context.environment = $env |
       .context.project = $project |
       .related = $related |
       .last_snapshot = $snapshot_time |
       if $summary != "" then .summary = $summary else . end
       ' "${session_file}" > "${tmp_file}"

    mv "${tmp_file}" "${session_file}"

    echo "Snapshot captured at $(date)"
    echo "  Git branch: $(echo "${git_state}" | jq -r '.branch')"
    echo "  Active files: $(echo "${active_files}" | jq 'length')"
    echo "  Related entries: $(echo "${related}" | jq '[.journal_entries, .patterns, .goals] | map(length) | add')"
}

#######################################
# Add a goal to the current session
#######################################
add_goal() {
    local goal="$1"

    if [[ ! -f "${CURRENT_SESSION_FILE}" ]]; then
        echo "No active session."
        return 1
    fi

    local session_id
    session_id=$(cat "${CURRENT_SESSION_FILE}")
    local session_file="${SESSIONS_DIR}/${session_id}.json"

    local tmp_file
    tmp_file=$(mktemp)

    jq --arg goal "${goal}" '.goals_addressed += [$goal]' "${session_file}" > "${tmp_file}"
    mv "${tmp_file}" "${session_file}"

    echo "Added goal: ${goal}"
}

#######################################
# Add a decision to the current session
# Also creates a journal entry for unified tracking
#######################################
add_decision() {
    local decision="$1"
    local rationale="${2:-}"

    if [[ ! -f "${CURRENT_SESSION_FILE}" ]]; then
        echo "No active session."
        return 1
    fi

    local session_id
    session_id=$(cat "${CURRENT_SESSION_FILE}")
    local session_file="${SESSIONS_DIR}/${session_id}.json"

    # Create journal entry with session tag for unified tracking
    local lore_root="${LORE_ROOT:-$(dirname "$(dirname "${TRANSFER_ROOT}")")}"
    local journal_sh="${lore_root}/journal/journal.sh"
    local dec_id=""
    
    if [[ -x "${journal_sh}" ]]; then
        # Record in journal, capture the decision ID
        local journal_output
        journal_output=$("${journal_sh}" record "${decision}" \
            ${rationale:+--rationale "${rationale}"} \
            --tags "session:${session_id}" 2>/dev/null) || true
        
        # Extract decision ID from output (format: "Recorded decision: dec-xxxxxxxx")
        dec_id=$(echo "${journal_output}" | grep -o 'dec-[a-f0-9]*' | head -1) || true
    fi

    local tmp_file
    tmp_file=$(mktemp)

    # Store both plain text (backward compat) and journal entry ID reference
    if [[ -n "${dec_id}" ]]; then
        jq --arg decision "${decision}" --arg dec_id "${dec_id}" \
            '.decisions_made += [$decision] | .related.journal_entries += [$dec_id]' \
            "${session_file}" > "${tmp_file}"
    else
        jq --arg decision "${decision}" '.decisions_made += [$decision]' \
            "${session_file}" > "${tmp_file}"
    fi
    mv "${tmp_file}" "${session_file}"

    echo "Added decision: ${decision}"
    [[ -n "${dec_id}" ]] && echo "  Journal entry: ${dec_id}"
}

#######################################
# Add an open thread to the current session
#######################################
add_thread() {
    local thread="$1"

    if [[ ! -f "${CURRENT_SESSION_FILE}" ]]; then
        echo "No active session."
        return 1
    fi

    local session_id
    session_id=$(cat "${CURRENT_SESSION_FILE}")
    local session_file="${SESSIONS_DIR}/${session_id}.json"

    local tmp_file
    tmp_file=$(mktemp)

    jq --arg thread "${thread}" '.open_threads += [$thread]' "${session_file}" > "${tmp_file}"
    mv "${tmp_file}" "${session_file}"

    echo "Added open thread: ${thread}"
}

#######################################
# Add a pattern learned to the current session
#######################################
add_pattern() {
    local pattern="$1"

    if [[ ! -f "${CURRENT_SESSION_FILE}" ]]; then
        echo "No active session."
        return 1
    fi

    local session_id
    session_id=$(cat "${CURRENT_SESSION_FILE}")
    local session_file="${SESSIONS_DIR}/${session_id}.json"

    local tmp_file
    tmp_file=$(mktemp)

    jq --arg pattern "${pattern}" '.patterns_learned += [$pattern]' "${session_file}" > "${tmp_file}"
    mv "${tmp_file}" "${session_file}"

    echo "Added pattern: ${pattern}"
}
