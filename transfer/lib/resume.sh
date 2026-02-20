#!/usr/bin/env bash
#
# Resume - Load context from previous session
#
# Fork-on-resume: Creates a NEW session inheriting context from the old one.
# Historical sessions are never modified after handoff.
#
# Behavior:
# 1. Display context from the parent session (read-only)
# 2. Create new session with parent_session link
# 3. Inherit: open_threads, handoff.next_steps → initial context
# 4. Set .current_session to the NEW session
#

# Resolve LORE_DIR for cross-component calls
LORE_DIR="${LORE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
source "${LORE_DIR}/lib/paths.sh"

# Colors for output (match journal conventions)
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color
BOLD='\033[1m'

# Disable colors if not a terminal
if [[ ! -t 1 ]]; then
    RED='' GREEN='' YELLOW='' BLUE='' CYAN='' NC='' BOLD=''
fi

#######################################
# Suggest pattern creation from clustered lessons
# Scans decisions with lesson_learned, groups by similarity,
# suggests pattern creation when 3+ decisions share a lesson.
#######################################
suggest_promotions() {
    local decisions_file="${LORE_DECISIONS_FILE}"
    [[ -f "$decisions_file" ]] || return 0

    # Get active decisions with lesson_learned
    local lessons
    lessons=$(jq -s '
        group_by(.id) | map(.[-1])
        | map(select((.status // "active") == "active" and .lesson_learned != null and .lesson_learned != ""))
        | map({id, lesson: .lesson_learned, decision: .decision[0:80]})
    ' "$decisions_file" 2>/dev/null) || return 0

    local count
    count=$(echo "$lessons" | jq 'length' 2>/dev/null) || return 0
    [[ "$count" -lt 3 ]] && return 0

    # Compare lessons pairwise, cluster by similarity
    # Build clusters: group lessons with 40%+ word overlap
    local clusters=""
    local assigned=()

    for ((i=0; i<count; i++)); do
        # Skip if already assigned to a cluster
        local skip=false
        for a in "${assigned[@]+"${assigned[@]}"}"; do
            [[ "$a" == "$i" ]] && { skip=true; break; }
        done
        [[ "$skip" == true ]] && continue

        local cluster_members=("$i")
        local lesson_i
        lesson_i=$(echo "$lessons" | jq -r ".[$i].lesson")

        local words_i
        words_i=$(echo "$lesson_i" | tr '[:upper:]' '[:lower:]' | tr -cs '[:alnum:]' '\n' | sort -u)

        for ((j=i+1; j<count; j++)); do
            skip=false
            for a in "${assigned[@]+"${assigned[@]}"}"; do
                [[ "$a" == "$j" ]] && { skip=true; break; }
            done
            [[ "$skip" == true ]] && continue

            local lesson_j
            lesson_j=$(echo "$lessons" | jq -r ".[$j].lesson")

            local words_j
            words_j=$(echo "$lesson_j" | tr '[:upper:]' '[:lower:]' | tr -cs '[:alnum:]' '\n' | sort -u)

            local intersection union
            intersection=$(comm -12 <(echo "$words_i") <(echo "$words_j") | wc -l | tr -d ' ')
            union=$(comm <(echo "$words_i") <(echo "$words_j") | sort -u | wc -l | tr -d ' ')

            if [[ "$union" -gt 0 ]]; then
                local sim=$(( intersection * 100 / union ))
                if [[ "$sim" -ge 40 ]]; then
                    cluster_members+=("$j")
                    assigned+=("$j")
                fi
            fi
        done

        assigned+=("$i")

        if [[ ${#cluster_members[@]} -ge 3 ]]; then
            # Found a promotable cluster
            local representative_lesson
            representative_lesson=$(echo "$lessons" | jq -r ".[${cluster_members[0]}].lesson")
            local member_count=${#cluster_members[@]}

            local decision_ids=""
            for idx in "${cluster_members[@]}"; do
                local did
                did=$(echo "$lessons" | jq -r ".[$idx].id")
                decision_ids="${decision_ids}${decision_ids:+, }${did}"
            done

            clusters="${clusters}${member_count}|${representative_lesson}|${decision_ids}\n"
        fi
    done

    [[ -z "$clusters" ]] && return 0

    echo "--- Promote Lessons to Patterns ---"
    echo ""
    echo -e "${YELLOW}These lessons appear in 3+ decisions and could become patterns:${NC}"
    echo ""

    echo -e "$clusters" | while IFS='|' read -r member_count lesson ids; do
        [[ -z "$member_count" ]] && continue
        echo -e "  ${BOLD}${member_count} decisions${NC} share this lesson:"
        echo -e "    ${CYAN}${lesson:0:120}${NC}"
        echo -e "    ${DIM}IDs: ${ids}${NC}"
        echo -e "    Run: ${GREEN}lore learn \"${lesson:0:60}...\" --context \"<when>\" --solution \"<what>\"${NC}"
        echo ""
    done
}

#######################################
# Suggest relevant patterns for a context string
# Outputs nothing if no patterns match (fail-silent)
#######################################
suggest_patterns_for_context() {
    local context="$1"
    local limit="${2:-5}"

    [[ -z "${context}" ]] && return 0

    local output
    output=$("${LORE_DIR}/patterns/patterns.sh" suggest "${context}" --limit "${limit}" 2>/dev/null) || return 0

    # Only display if the suggest command found actual matches
    # Strip ANSI color codes before checking for numbered pattern entries
    if echo "${output}" | sed 's/\x1b\[[0-9;]*m//g' | grep -qE '^\s*[0-9]+\.' ; then
        echo "--- Relevant Patterns ---"
        echo "${output}"
        echo ""
    fi
}

#######################################
# Check if a session file has sparse/minimal content
# Returns 0 (true) if <= 1 field is populated
# Args: session_file path
#######################################
is_session_sparse() {
    local session_file="$1"

    [[ ! -f "${session_file}" ]] && return 0

    local populated=0

    # Check summary (non-empty, not the default placeholder)
    local summary
    summary=$(jq -r '.summary // ""' "${session_file}" 2>/dev/null)
    if [[ -n "${summary}" && "${summary}" != "(no summary)" ]]; then
        populated=$((populated + 1))
    fi

    # Check handoff message
    local handoff_msg
    handoff_msg=$(jq -r '.handoff.message // ""' "${session_file}" 2>/dev/null)
    if [[ -n "${handoff_msg}" ]]; then
        populated=$((populated + 1))
    fi

    # Check goals_addressed
    local goals_len
    goals_len=$(jq '.goals_addressed | length' "${session_file}" 2>/dev/null || echo 0)
    if [[ "${goals_len}" -gt 0 ]]; then
        populated=$((populated + 1))
    fi

    # Check decisions_made
    local decisions_len
    decisions_len=$(jq '.decisions_made | length' "${session_file}" 2>/dev/null || echo 0)
    if [[ "${decisions_len}" -gt 0 ]]; then
        populated=$((populated + 1))
    fi

    # Check open_threads
    local threads_len
    threads_len=$(jq '.open_threads | length' "${session_file}" 2>/dev/null || echo 0)
    if [[ "${threads_len}" -gt 0 ]]; then
        populated=$((populated + 1))
    fi

    # Sparse if <= 1 field populated
    [[ "${populated}" -le 1 ]]
}

#######################################
# Reconstruct context from data layer when no handoff exists
# Gathers recent git, journal, patterns, and failures
#######################################
reconstruct_context() {
    echo -e "${YELLOW}--- Reconstructed Context (no handoff found) ---${NC}"
    echo ""

    # Recent git activity
    echo -e "${CYAN}Recent Git:${NC}"
    local branch
    branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)
    if [[ -n "${branch}" ]]; then
        echo "  Branch: ${branch}"
        echo ""

        echo "  Last 10 commits:"
        git log --oneline -10 2>/dev/null | while IFS= read -r line; do
            echo "    ${line}"
        done || true
        echo ""

        local uncommitted
        uncommitted=$(git status --porcelain 2>/dev/null || true)
        if [[ -n "${uncommitted}" ]]; then
            echo "  Uncommitted files:"
            echo "${uncommitted}" | while IFS= read -r line; do
                echo "    ${line}"
            done
            echo ""
        fi

        echo "  Diff stat (last 5 commits):"
        git diff --stat HEAD~5..HEAD 2>/dev/null | while IFS= read -r line; do
            echo "    ${line}"
        done || true
        echo ""
    else
        echo "  (not a git repository)"
        echo ""
    fi

    # Recent journal decisions
    local journal_data="${LORE_DECISIONS_FILE}"
    if [[ -f "${journal_data}" ]]; then
        echo -e "${CYAN}Recent Decisions:${NC}"
        local decisions
        decisions=$(jq -s 'group_by(.id) | map(.[-1]) | sort_by(.timestamp) | reverse | .[0:5]' "${journal_data}" 2>/dev/null || true)
        if [[ -n "${decisions}" && "${decisions}" != "[]" && "${decisions}" != "null" ]]; then
            echo "${decisions}" | jq -r '.[] | "  - \(.decision[0:80])\(if (.decision | length) > 80 then "..." else "" end)"' 2>/dev/null || true
        else
            echo "  (no decisions recorded)"
        fi
        echo ""
    fi

    # Recent patterns
    local patterns_data="${LORE_PATTERNS_FILE}"
    if [[ -f "${patterns_data}" ]] && command -v yq &>/dev/null; then
        echo -e "${CYAN}Recent Patterns:${NC}"
        local patterns
        patterns=$(yq -o=json '.patterns' "${patterns_data}" 2>/dev/null | jq 'sort_by(.created_at) | reverse | .[0:5]' 2>/dev/null || true)
        if [[ -n "${patterns}" && "${patterns}" != "[]" && "${patterns}" != "null" ]]; then
            echo "${patterns}" | jq -r '.[] | "  - \((.name // .pattern // "(unnamed)")[0:60])"' 2>/dev/null || true
        else
            echo "  (no patterns recorded)"
        fi
        echo ""
    fi

    # Recent failures
    local failures_data="${LORE_FAILURES_DATA}/failures.jsonl"
    if [[ -f "${failures_data}" ]]; then
        echo -e "${CYAN}Recent Failures:${NC}"
        local failures
        failures=$(tail -5 "${failures_data}" 2>/dev/null || true)
        if [[ -n "${failures}" ]]; then
            echo "${failures}" | while IFS= read -r line; do
                local err_type err_msg
                err_type=$(echo "${line}" | jq -r '.error_type // .type // "unknown"' 2>/dev/null || true)
                err_msg=$(echo "${line}" | jq -r '.message // .error // "(no message)"' 2>/dev/null || true)
                [[ ${#err_msg} -gt 60 ]] && err_msg="${err_msg:0:57}..."
                echo "  - [${err_type}] ${err_msg}"
            done
        else
            echo "  (no failures recorded)"
        fi
        echo ""
    fi

    echo -e "${YELLOW}--- End Reconstructed Context ---${NC}"
    echo ""
}

#######################################
# Fork a new session from a parent session
# Creates new session inheriting context, sets as current
# Args: parent_session_id
# Returns: new session ID (also sets CURRENT_SESSION_FILE)
#######################################
fork_session_from_parent() {
    local parent_id="$1"
    local parent_file="${SESSIONS_DIR}/${parent_id}.json"

    if [[ ! -f "${parent_file}" ]]; then
        echo "Parent session not found: ${parent_id}" >&2
        return 1
    fi

    # Generate new session ID
    local new_id="session-$(date +%Y%m%d-%H%M%S)-$(openssl rand -hex 4 2>/dev/null || echo $$)"
    local new_file="${SESSIONS_DIR}/${new_id}.json"

    # Detect project name
    local project_name=""
    if git rev-parse --git-dir &>/dev/null; then
        project_name=$(basename "$(git rev-parse --show-toplevel)")
    else
        project_name=$(basename "$PWD")
    fi

    # Extract inherited context from parent
    local open_threads next_steps blockers questions
    open_threads=$(jq -c '.open_threads // []' "${parent_file}")
    next_steps=$(jq -c '.handoff.next_steps // []' "${parent_file}")
    blockers=$(jq -c '.handoff.blockers // []' "${parent_file}")
    questions=$(jq -c '.handoff.questions // []' "${parent_file}")

    # Create new session with inherited context
    jq -n \
        --arg id "${new_id}" \
        --arg started "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --arg parent "${parent_id}" \
        --arg project "${project_name}" \
        --argjson open_threads "${open_threads}" \
        --argjson next_steps "${next_steps}" \
        --argjson blockers "${blockers}" \
        --argjson questions "${questions}" \
        '{
            id: $id,
            started_at: $started,
            ended_at: null,
            parent_session: $parent,
            summary: "",
            goals_addressed: [],
            decisions_made: [],
            patterns_learned: [],
            open_threads: $open_threads,
            handoff: {
                next_steps: [],
                blockers: [],
                questions: []
            },
            inherited: {
                next_steps: $next_steps,
                blockers: $blockers,
                questions: $questions
            },
            git_state: {
                branch: "",
                commits: [],
                uncommitted: []
            },
            context: {
                project: $project,
                active_files: [],
                recent_commands: [],
                environment: {}
            },
            related: {
                journal_entries: [],
                patterns: [],
                goals: []
            }
        }' > "${new_file}"

    # Set as current session
    echo "${new_id}" > "${CURRENT_SESSION_FILE}"

    # Return the new session ID
    echo "${new_id}"
}

#######################################
# Display active spec context if present
# Args: session_file path
#######################################
display_spec_context() {
    local session_file="$1"
    local goals_dir="${LORE_INTENT_DATA}/goals"
    local journal_data="${LORE_DECISIONS_FILE}"

    # Check for spec context in session
    local goal_id
    goal_id=$(jq -r '.context.spec.goal_id // empty' "${session_file}" 2>/dev/null)
    [[ -z "${goal_id}" ]] && return 0

    # Load goal file
    local goal_file="${goals_dir}/${goal_id}.yaml"
    if [[ ! -f "${goal_file}" ]]; then
        echo -e "${YELLOW}--- Active Spec (Warning) ---${NC}"
        echo -e "  Goal ${CYAN}${goal_id}${NC} referenced but file not found"
        echo -e "  (spec may have been deleted or moved)"
        echo ""
        return 0
    fi

    # Check for yq
    if ! command -v yq &>/dev/null; then
        echo -e "${YELLOW}--- Active Spec ---${NC}"
        echo -e "  Goal: ${goal_id}"
        echo -e "  (install yq for full spec details)"
        echo ""
        return 0
    fi

    # Extract spec info from session and goal file
    local spec_name spec_branch spec_phase current_task
    spec_name=$(jq -r '.context.spec.name // empty' "${session_file}" 2>/dev/null)
    spec_branch=$(jq -r '.context.spec.branch // empty' "${session_file}" 2>/dev/null)
    spec_phase=$(jq -r '.context.spec.phase // empty' "${session_file}" 2>/dev/null)
    current_task=$(jq -r '.context.spec.current_task // empty' "${session_file}" 2>/dev/null)

    # Fallback to goal file if session context is sparse
    [[ -z "${spec_name}" ]] && spec_name=$(yq -r '.name // ""' "${goal_file}" 2>/dev/null)
    [[ -z "${spec_phase}" ]] && spec_phase=$(yq -r '.lifecycle.phase // "unknown"' "${goal_file}" 2>/dev/null)
    [[ -z "${spec_branch}" ]] && spec_branch=$(yq -r '.source.branch // ""' "${goal_file}" 2>/dev/null)

    echo -e "${GREEN}--- Active Spec ---${NC}"
    echo -e "  ${CYAN}Goal:${NC} ${goal_id}"
    [[ -n "${spec_name}" ]] && echo -e "  ${CYAN}Name:${NC} ${spec_name}"
    [[ -n "${spec_branch}" ]] && echo -e "  ${CYAN}Branch:${NC} ${spec_branch}"
    [[ -n "${spec_phase}" ]] && echo -e "  ${CYAN}Phase:${NC} ${spec_phase}"
    [[ -n "${current_task}" ]] && echo -e "  ${CYAN}Current Task:${NC} ${current_task}"
    echo ""

    # Display success criteria with status
    local criteria_count
    criteria_count=$(yq -r '.success_criteria | length' "${goal_file}" 2>/dev/null || echo 0)
    if [[ "${criteria_count}" -gt 0 ]]; then
        echo -e "  ${CYAN}Success Criteria:${NC}"

        # Check for snapshot user_stories (SDD-style)
        local has_snapshot
        has_snapshot=$(yq -r '.source.snapshot.user_stories // null' "${goal_file}" 2>/dev/null)

        if [[ "${has_snapshot}" != "null" && -n "${has_snapshot}" ]]; then
            # SDD-style with user story IDs - convert to JSON for jq parsing
            local stories_json
            stories_json=$(yq -o=json '.source.snapshot.user_stories' "${goal_file}" 2>/dev/null)
            echo "${stories_json}" | jq -r '.[] | "\(.id)|\(.title)|\(.priority // "")|\(.status // "pending")"' 2>/dev/null | \
            while IFS='|' read -r us_id us_title us_priority us_status; do
                local check_mark=" "
                [[ "${us_status}" == "completed" ]] && check_mark="${GREEN}✓${NC}"
                [[ "${us_status}" == "in_progress" ]] && check_mark="${YELLOW}→${NC}"
                local priority_str=""
                [[ -n "${us_priority}" ]] && priority_str=" (${us_priority})"
                echo -e "    [${check_mark}] ${us_id}: ${us_title}${priority_str}"
            done
        else
            # Standard success_criteria list (handles both string and object formats)
            local criteria_json
            criteria_json=$(yq -o=json '.success_criteria' "${goal_file}" 2>/dev/null)
            echo "${criteria_json}" | jq -r '.[] | if type == "object" then "\(.description // .text // "unknown")||\(.status // "pending")" else "\(.)||pending" end' 2>/dev/null | \
            while IFS='|' read -r criterion _ status; do
                local check_mark=" "
                [[ "${status}" == "completed" ]] && check_mark="${GREEN}✓${NC}"
                [[ "${status}" == "in_progress" ]] && check_mark="${YELLOW}→${NC}"
                # Truncate long criteria
                [[ ${#criterion} -gt 60 ]] && criterion="${criterion:0:57}..."
                echo -e "    [${check_mark}] ${criterion}"
            done
        fi
        echo ""
    fi

    # Query journal for decisions tagged with this spec
    if [[ -f "${journal_data}" ]]; then
        local spec_tag="spec:${goal_id}"
        local decisions
        decisions=$(jq -s --arg tag "${spec_tag}" '
            [.[] | select(.tags | any(. == $tag or startswith($tag)))]
            | group_by(.id) | map(.[-1])
            | sort_by(.timestamp) | reverse
            | .[0:5]
        ' "${journal_data}" 2>/dev/null)

        local decision_count
        decision_count=$(echo "${decisions}" | jq 'length' 2>/dev/null || echo 0)

        if [[ "${decision_count}" -gt 0 ]]; then
            echo -e "${GREEN}--- Decisions for This Spec ---${NC}"
            echo "${decisions}" | jq -r '.[] | "  - \(.decision[0:60])\(if (.decision | length) > 60 then "..." else "" end)\(if .rationale then " — \(.rationale[0:40])\(if (.rationale | length) > 40 then "..." else "" end)" else "" end)"' 2>/dev/null
            echo ""
        fi
    fi
}

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

    # Show active spec context if present
    display_spec_context "${session_file}"

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

    # Related entries from other lore components
    if jq -e '.related' "${session_file}" &>/dev/null; then
        echo "--- Related Lore Entries ---"

        local journal_count pattern_count goal_count
        journal_count=$(jq '.related.journal_entries | length' "${session_file}" 2>/dev/null || echo 0)
        pattern_count=$(jq '.related.patterns | length' "${session_file}" 2>/dev/null || echo 0)
        goal_count=$(jq '.related.goals | length' "${session_file}" 2>/dev/null || echo 0)

        echo "  Journal entries: ${journal_count}"
        echo "  Patterns: ${pattern_count}"
        echo "  Active goals: ${goal_count}"
        echo ""
    fi

    # If session is sparse, reconstruct context from data layer
    if is_session_sparse "${session_file}"; then
        reconstruct_context
    fi

    # Suggest relevant patterns based on session context
    # Try multiple sources: project, summary, open threads
    local project summary
    project=$(jq -r '.context.project // ""' "${session_file}" 2>/dev/null)
    summary=$(jq -r '.summary // ""' "${session_file}" 2>/dev/null)

    # Build context string from available session data
    local context_parts=()
    [[ -n "${project}" ]] && context_parts+=("${project}")
    [[ -n "${summary}" ]] && context_parts+=("${summary}")

    # Add open threads to context
    local threads
    threads=$(jq -r '.open_threads[]?' "${session_file}" 2>/dev/null | head -3)
    if [[ -n "${threads}" ]]; then
        while IFS= read -r thread; do
            [[ -n "${thread}" ]] && context_parts+=("${thread}")
        done <<< "${threads}"
    fi

    # Query patterns with combined context
    if [[ ${#context_parts[@]} -gt 0 ]]; then
        local combined_context="${context_parts[*]}"
        suggest_patterns_for_context "${combined_context}" 5
    fi

    # Suggest promoting recurring lessons to patterns
    suggest_promotions 2>/dev/null || true

    # Fork: create new session inheriting from this one
    local new_session_id
    new_session_id=$(fork_session_from_parent "${session_id}")

    echo "=============================================="
    echo "  Forked new session: ${new_session_id}"
    echo "  Parent: ${session_id}"
    echo ""
    echo "  Inherited ${threads_count} open threads."
    echo "  Use 'lore snapshot' to save progress."
    echo "=============================================="

    # Rebuild search index in background (fail-silent)
    bash "${LORE_DIR}/lib/search-index.sh" &>/dev/null &
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
    latest=$(find_latest_session) || true

    if [[ -z "${latest}" ]]; then
        echo "No previous sessions found."
        echo ""
        # Reconstruct context from data layer
        reconstruct_context
        # Also suggest patterns for the current project
        local project_name
        project_name=$(basename "$(git rev-parse --show-toplevel 2>/dev/null || pwd)")
        suggest_patterns_for_context "${project_name}"

        # Rebuild search index in background even with no session (fail-silent)
        bash "${LORE_DIR}/lib/search-index.sh" &>/dev/null &
        return 0
    fi

    # Warn if multiple sessions arrived since last resume
    if [[ -f "${CURRENT_SESSION_FILE}" ]]; then
        local prev_id prev_file
        prev_id=$(cat "${CURRENT_SESSION_FILE}")
        prev_file="${SESSIONS_DIR}/${prev_id}.json"
        if [[ -f "${prev_file}" ]]; then
            local newer_count
            newer_count=$(find "${SESSIONS_DIR}" -name '*.json' -newer "${prev_file}" | wc -l | tr -d ' ')
            if [[ "${newer_count}" -gt 1 ]]; then
                echo -e "${YELLOW}Note: ${newer_count} sessions since last resume. Showing latest (${latest}). Run 'lore resume --list' for all.${NC}" >&2
            fi
        fi
    fi

    echo "Resuming most recent session: ${latest}"
    resume_session "${latest}"
}
