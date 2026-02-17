#!/usr/bin/env bash
# Spec Management - Import and track spec-kit specifications
#
# Maps external spec.md files to the Lore intent layer (goals),
# tracks assignment to sessions, and captures outcomes.

set -euo pipefail

# Handle both direct execution and sourcing
if [[ -n "${BASH_SOURCE[0]:-}" ]]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
else
    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
fi
LORE_DIR="${LORE_DIR:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
DATA_DIR="${SCRIPT_DIR}/../data"
GOALS_DIR="${DATA_DIR}/goals"
SESSIONS_DIR="${LORE_DIR}/transfer/data/sessions"
CURRENT_SESSION_FILE="${LORE_DIR}/transfer/data/.current_session"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# Valid phases for spec lifecycle
VALID_PHASES="specify plan tasks implement complete"
VALID_CRITERION_STATUSES="pending in_progress completed"
VALID_OUTCOME_STATUSES="completed failed abandoned"

# Ensure data directories exist
init_spec() {
    mkdir -p "$GOALS_DIR"
}

# Check if yq is available
check_yq() {
    if ! command -v yq &>/dev/null; then
        echo -e "${RED}Error: yq is required but not installed${NC}" >&2
        return 1
    fi
}

# Check if jq is available
check_jq() {
    if ! command -v jq &>/dev/null; then
        echo -e "${RED}Error: jq is required but not installed${NC}" >&2
        return 1
    fi
}

# Generate unique ID
generate_id() {
    local prefix="${1:-id}"
    local random_hex
    if command -v xxd &>/dev/null; then
        random_hex=$(head -c 4 /dev/urandom | xxd -p)
    else
        random_hex=$(head -c 4 /dev/urandom | od -An -tx1 | tr -d ' \n')
    fi
    echo "${prefix}-$(date +%s)-${random_hex}"
}

# Get current timestamp in ISO format
timestamp() {
    date -Iseconds
}

# Get current session ID
get_current_session_id() {
    if [[ -f "$CURRENT_SESSION_FILE" ]]; then
        cat "$CURRENT_SESSION_FILE"
    else
        echo ""
    fi
}

# Get session file path
get_session_file() {
    local session_id="$1"
    echo "${SESSIONS_DIR}/${session_id}.json"
}

# Get goal file path
get_goal_file() {
    local goal_id="$1"
    echo "${GOALS_DIR}/${goal_id}.yaml"
}

# ============================================
# Spec Parsing Functions
# ============================================

# Parse spec.md and extract structured data
# Returns JSON with title, summary, user_stories
parse_spec_md() {
    local spec_file="$1"

    if [[ ! -f "$spec_file" ]]; then
        echo -e "${RED}Error: Spec file not found: $spec_file${NC}" >&2
        return 1
    fi

    local content
    content=$(cat "$spec_file")

    # Extract title from first H1
    local title=""
    title=$(echo "$content" | grep -m1 "^# " | sed 's/^# //' | sed 's/^Feature Specification: //' || true)
    if [[ -z "$title" ]]; then
        title=$(basename "$spec_file" .md)
    fi

    # Extract branch from **Feature Branch**: `xxx`
    local branch=""
    branch=$(echo "$content" | grep -i "Feature Branch" | sed -n 's/.*`\([^`]*\)`.*/\1/p' | head -1 || true)

    # If no branch in file, try to detect from git
    if [[ -z "$branch" ]]; then
        local spec_dir
        spec_dir=$(dirname "$spec_file")
        if git -C "$spec_dir" rev-parse --git-dir &>/dev/null 2>&1; then
            branch=$(git -C "$spec_dir" branch --show-current 2>/dev/null || true)
        fi
    fi

    # Extract summary (first paragraph after title, before ## sections)
    local summary=""
    summary=$(echo "$content" | sed -n '/^# /,/^## /p' | grep -v "^#" | grep -v "^\*\*" | head -5 | tr '\n' ' ' | sed 's/  */ /g' | head -c 500 || true)

    # Parse user stories
    local user_stories="[]"
    local in_user_stories=false
    local current_story_title=""
    local current_story_priority=""
    local current_story_id=""
    local current_acceptance=()
    local story_count=0

    while IFS= read -r line; do
        # Detect User Scenarios section
        if [[ "$line" =~ ^##.*[Uu]ser\ [Ss]cenarios ]]; then
            in_user_stories=true
            continue
        fi

        # Exit on next major section (## that's not a User Story)
        if [[ "$in_user_stories" == true && "$line" =~ ^##[^#] ]]; then
            if [[ ! "$line" =~ [Uu]ser\ [Ss]tory ]]; then
                # Save current story before exiting
                if [[ -n "$current_story_title" ]]; then
                    local acc_json="[]"
                    if [[ ${#current_acceptance[@]} -gt 0 ]]; then
                        acc_json=$(printf '%s\n' "${current_acceptance[@]}" | jq -R . | jq -s .)
                    fi
                    user_stories=$(echo "$user_stories" | jq --arg id "$current_story_id" --arg title "$current_story_title" --arg priority "$current_story_priority" --argjson acc "$acc_json" '. + [{id: $id, title: $title, priority: $priority, acceptance: $acc}]')
                    current_story_title=""  # Clear to prevent double-save
                fi
                break
            fi
        fi

        if [[ "$in_user_stories" == true ]]; then
            # Try to match User Story header with priority: ### User Story 1 - Title (Priority: P1)
            local matched=false
            local match_num="" match_title="" match_priority=""

            # Extract story number
            if [[ "$line" =~ ^###.*[Uu]ser\ [Ss]tory\ ([0-9]+) ]]; then
                match_num="${BASH_REMATCH[1]:-}"
                
                # Extract title (text after the dash)
                # Use sed to extract since bash regex with negated parenthesis is tricky
                match_title=$(echo "$line" | sed -n 's/.*- *\([^(]*\).*/\1/p' | sed 's/[[:space:]]*$//')
                if [[ -z "$match_title" ]]; then
                    # Fallback: just get everything after the dash
                    match_title=$(echo "$line" | sed -n 's/.*- *\(.*\)/\1/p' | sed 's/[[:space:]]*$//' | sed 's/ *(.*$//')
                fi
                
                # Extract priority if present
                if [[ "$line" =~ \([Pp]riority:\ *([Pp][0-9])\) ]]; then
                    match_priority="${BASH_REMATCH[1]:-P2}"
                    match_priority=$(echo "$match_priority" | tr '[:lower:]' '[:upper:]')
                else
                    match_priority="P2"
                fi
                
                matched=true
            fi

            if [[ "$matched" == true && -n "$match_title" ]]; then
                # Save previous story before starting new one
                if [[ -n "$current_story_title" ]]; then
                    local acc_json="[]"
                    if [[ ${#current_acceptance[@]} -gt 0 ]]; then
                        acc_json=$(printf '%s\n' "${current_acceptance[@]}" | jq -R . | jq -s .)
                    fi
                    user_stories=$(echo "$user_stories" | jq --arg id "$current_story_id" --arg title "$current_story_title" --arg priority "$current_story_priority" --argjson acc "$acc_json" '. + [{id: $id, title: $title, priority: $priority, acceptance: $acc}]')
                fi
                
                ((story_count++)) || true
                current_story_id="US${story_count}"
                current_story_title="$match_title"
                current_story_priority="$match_priority"
                current_acceptance=()
                continue
            fi

            # Match acceptance criteria (numbered lines with Given/When/Then)
            if [[ "$line" =~ ^[0-9]+\..*(Given|When|Then) ]]; then
                local criterion
                criterion=$(echo "$line" | sed 's/^[0-9]*\. *//')
                current_acceptance+=("$criterion")
            fi
        fi
    done < "$spec_file"

    # Save last story if we didn't hit another section
    if [[ -n "$current_story_title" ]]; then
        local acc_json="[]"
        if [[ ${#current_acceptance[@]} -gt 0 ]]; then
            acc_json=$(printf '%s\n' "${current_acceptance[@]}" | jq -R . | jq -s .)
        fi
        user_stories=$(echo "$user_stories" | jq --arg id "$current_story_id" --arg title "$current_story_title" --arg priority "$current_story_priority" --argjson acc "$acc_json" '. + [{id: $id, title: $title, priority: $priority, acceptance: $acc}]')
    fi

    # Build result JSON
    jq -n \
        --arg title "$title" \
        --arg summary "$summary" \
        --arg branch "$branch" \
        --argjson user_stories "$user_stories" \
        '{title: $title, summary: $summary, branch: $branch, user_stories: $user_stories}'
}

# Parse plan.md for technical decisions
parse_plan_md() {
    local plan_file="$1"

    if [[ ! -f "$plan_file" ]]; then
        echo "[]"
        return 0
    fi

    local decisions="[]"
    local in_decision_section=false
    local current_decision=""
    local current_rationale=""

    while IFS= read -r line; do
        # Look for sections that typically contain decisions
        if [[ "$line" =~ ^##.*(Decision|Choice|Architecture|Technology|Approach|Design) ]]; then
            in_decision_section=true
            continue
        fi

        # Exit on unrelated section
        if [[ "$in_decision_section" == true && "$line" =~ ^##[^#] && ! "$line" =~ (Decision|Choice|Architecture|Technology|Approach|Design) ]]; then
            in_decision_section=false
            continue
        fi

        if [[ "$in_decision_section" == true ]]; then
            # Match decision patterns like "**Decision**: Use X" or "- Decision: Use X"
            if [[ "$line" =~ \*\*[Dd]ecision\*\*:\ *(.+) ]]; then
                current_decision="${BASH_REMATCH[1]}"
            elif [[ "$line" =~ ^-\ *[Dd]ecision:\ *(.+) ]]; then
                current_decision="${BASH_REMATCH[1]}"
            elif [[ "$line" =~ ^-\ *[Ww]e\ (chose|decided|will\ use|selected)\ (.+) ]]; then
                current_decision="${BASH_REMATCH[2]}"
            fi

            # Match rationale
            if [[ "$line" =~ \*\*[Rr]ationale\*\*:\ *(.+) ]]; then
                current_rationale="${BASH_REMATCH[1]}"
            elif [[ "$line" =~ ^-\ *[Rr]ationale:\ *(.+) ]]; then
                current_rationale="${BASH_REMATCH[1]}"
            elif [[ "$line" =~ ^-\ *[Bb]ecause\ (.+) ]]; then
                current_rationale="${BASH_REMATCH[1]}"
            fi

            # Save decision when we have both
            if [[ -n "$current_decision" ]]; then
                decisions=$(echo "$decisions" | jq --arg dec "$current_decision" --arg rat "$current_rationale" '. + [{decision: $dec, rationale: $rat}]')
                current_decision=""
                current_rationale=""
            fi
        fi

        # Also look for inline decisions anywhere: "Use X (not Y) - reason"
        if [[ "$line" =~ Use\ ([^(]+)\ \(not\ ([^)]+)\)\ *[-—]\ *(.+) ]]; then
            local dec="Use ${BASH_REMATCH[1]} (not ${BASH_REMATCH[2]})"
            local rat="${BASH_REMATCH[3]}"
            decisions=$(echo "$decisions" | jq --arg dec "$dec" --arg rat "$rat" '. + [{decision: $dec, rationale: $rat}]')
        fi
    done < "$plan_file"

    echo "$decisions"
}

# ============================================
# Main Spec Functions
# ============================================

# Import a spec.md (or spec directory) as a goal
spec_import() {
    local spec_path=""
    local force=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --force|-f)
                force=true
                shift
                ;;
            -*)
                echo -e "${RED}Error: Unknown option: $1${NC}" >&2
                return 1
                ;;
            *)
                spec_path="$1"
                shift
                ;;
        esac
    done

    if [[ -z "$spec_path" ]]; then
        echo -e "${RED}Error: Spec path required${NC}" >&2
        echo "Usage: lore spec import <spec.md|spec-dir> [--force]" >&2
        return 1
    fi

    check_yq
    check_jq
    init_spec

    local spec_file=""
    local plan_file=""
    local tasks_file=""

    # Determine if path is file or directory
    if [[ -d "$spec_path" ]]; then
        spec_file="${spec_path}/spec.md"
        plan_file="${spec_path}/plan.md"
        tasks_file="${spec_path}/tasks.md"
        if [[ ! -f "$spec_file" ]]; then
            echo -e "${RED}Error: spec.md not found in directory: $spec_path${NC}" >&2
            return 1
        fi
    elif [[ -f "$spec_path" ]]; then
        spec_file="$spec_path"
        local spec_dir
        spec_dir=$(dirname "$spec_path")
        plan_file="${spec_dir}/plan.md"
        tasks_file="${spec_dir}/tasks.md"
    else
        echo -e "${RED}Error: Path not found: $spec_path${NC}" >&2
        return 1
    fi

    # Parse spec.md
    local parsed
    parsed=$(parse_spec_md "$spec_file")
    if [[ -z "$parsed" || "$parsed" == "null" ]]; then
        echo -e "${RED}Error: Failed to parse spec.md${NC}" >&2
        return 1
    fi

    local title summary branch user_stories
    title=$(echo "$parsed" | jq -r '.title')
    summary=$(echo "$parsed" | jq -r '.summary')
    branch=$(echo "$parsed" | jq -r '.branch')
    user_stories=$(echo "$parsed" | jq '.user_stories')

    # Detect branch from path or git if not in file
    if [[ -z "$branch" || "$branch" == "null" ]]; then
        # Try to extract from path (e.g., specs/003-chat/spec.md -> 003-chat)
        local path_branch
        path_branch=$(echo "$spec_path" | grep -oE '[0-9]+-[a-z0-9-]+' | head -1 || true)
        if [[ -n "$path_branch" ]]; then
            branch="$path_branch"
        fi
    fi

    # Generate goal ID
    local goal_id
    goal_id=$(generate_id "goal")
    local goal_file
    goal_file=$(get_goal_file "$goal_id")

    local ts
    ts=$(timestamp)
    local user="${USER:-unknown}"

    # Determine initial phase
    local phase="specify"
    if [[ -f "$tasks_file" ]]; then
        phase="tasks"
    elif [[ -f "$plan_file" ]]; then
        phase="plan"
    fi

    # Build success_criteria from user stories
    local success_criteria=""
    local story_count
    story_count=$(echo "$user_stories" | jq 'length')

    for ((i=0; i<story_count; i++)); do
        local story_title story_priority story_acceptance
        story_title=$(echo "$user_stories" | jq -r ".[$i].title")
        story_priority=$(echo "$user_stories" | jq -r ".[$i].priority")
        story_acceptance=$(echo "$user_stories" | jq ".[$i].acceptance")

        # Build acceptance YAML list
        local acceptance_yaml=""
        local acc_count
        acc_count=$(echo "$story_acceptance" | jq 'length')
        for ((j=0; j<acc_count; j++)); do
            local acc
            acc=$(echo "$story_acceptance" | jq -r ".[$j]" | sed 's/"/\\"/g')
            acceptance_yaml="${acceptance_yaml}      - \"${acc}\"\n"
        done

        success_criteria="${success_criteria}  - description: \"${story_title}\"\n    priority: ${story_priority}\n    status: pending\n"
        if [[ -n "$acceptance_yaml" ]]; then
            success_criteria="${success_criteria}    acceptance:\n${acceptance_yaml}"
        fi
    done

    # Build snapshot YAML for user_stories
    local snapshot_stories_yaml=""
    for ((i=0; i<story_count; i++)); do
        local s_id s_title s_priority s_acc
        s_id=$(echo "$user_stories" | jq -r ".[$i].id")
        s_title=$(echo "$user_stories" | jq -r ".[$i].title" | sed 's/"/\\"/g')
        s_priority=$(echo "$user_stories" | jq -r ".[$i].priority")
        s_acc=$(echo "$user_stories" | jq ".[$i].acceptance")

        snapshot_stories_yaml="${snapshot_stories_yaml}      - id: \"${s_id}\"\n        title: \"${s_title}\"\n        priority: ${s_priority}\n"

        local acc_count
        acc_count=$(echo "$s_acc" | jq 'length')
        if [[ "$acc_count" -gt 0 ]]; then
            snapshot_stories_yaml="${snapshot_stories_yaml}        acceptance:\n"
            for ((j=0; j<acc_count; j++)); do
                local acc
                acc=$(echo "$s_acc" | jq -r ".[$j]" | sed 's/"/\\"/g')
                snapshot_stories_yaml="${snapshot_stories_yaml}          - \"${acc}\"\n"
            done
        fi
    done

    # Clean summary for YAML
    local clean_summary
    clean_summary=$(echo "$summary" | tr '\n' ' ' | sed 's/  */ /g' | sed 's/"/\\"/g')

    # Write goal file
    cat > "$goal_file" << EOF
id: $goal_id
name: "Feature: $title"
description: |
  $clean_summary

created_at: "$ts"
created_by: "$user"

status: active
priority: medium
deadline: null

success_criteria:
$(echo -e "$success_criteria" | sed '/^$/d')

depends_on: []
projects: []
tags:
  - spec-kit

source:
  type: "spec-kit"
  path: "$spec_file"
  branch: "$branch"
  imported_at: "$ts"
  snapshot:
    title: "$title"
    summary: "$clean_summary"
    user_stories:
$(echo -e "$snapshot_stories_yaml" | sed '/^$/d')

lifecycle:
  phase: "$phase"
  assigned_session: null
  assigned_at: null
  plan_decisions: []

outcome:
  status: null
  completed_at: null
  session_id: null
  journal_entry: null

EOF

    echo -e "${GREEN}Imported spec as goal:${NC} $goal_id"
    echo -e "  ${CYAN}Name:${NC} Feature: $title"
    echo -e "  ${CYAN}Branch:${NC} ${branch:-"(not detected)"}"
    echo -e "  ${CYAN}Phase:${NC} $phase"
    echo -e "  ${CYAN}User Stories:${NC} $story_count"
    echo -e "${DIM}File: $goal_file${NC}"

    # If plan.md exists, capture decisions
    if [[ -f "$plan_file" ]]; then
        echo ""
        spec_capture_decisions "$plan_file" "$goal_id"
    fi

    echo "$goal_id"
}

# Assign a spec/goal to a session
spec_assign() {
    local goal_id=""
    local session_id=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --session|-s)
                session_id="$2"
                shift 2
                ;;
            -*)
                echo -e "${RED}Error: Unknown option: $1${NC}" >&2
                return 1
                ;;
            *)
                goal_id="$1"
                shift
                ;;
        esac
    done

    if [[ -z "$goal_id" ]]; then
        echo -e "${RED}Error: Goal ID required${NC}" >&2
        echo "Usage: lore spec assign <goal-id> [--session <session-id>]" >&2
        return 1
    fi

    check_yq
    check_jq

    local goal_file
    goal_file=$(get_goal_file "$goal_id")

    if [[ ! -f "$goal_file" ]]; then
        echo -e "${RED}Error: Goal not found: $goal_id${NC}" >&2
        return 1
    fi

    # Use current session if not specified
    if [[ -z "$session_id" ]]; then
        session_id=$(get_current_session_id)
        if [[ -z "$session_id" ]]; then
            echo -e "${RED}Error: No current session. Run 'lore transfer init' or specify --session${NC}" >&2
            return 1
        fi
    fi

    local session_file
    session_file=$(get_session_file "$session_id")

    if [[ ! -f "$session_file" ]]; then
        echo -e "${RED}Error: Session not found: $session_id${NC}" >&2
        return 1
    fi

    # Check if already assigned to different session
    local current_assigned
    current_assigned=$(yq -r '.lifecycle.assigned_session // ""' "$goal_file")

    if [[ -n "$current_assigned" && "$current_assigned" != "null" && "$current_assigned" != "$session_id" ]]; then
        echo -e "${YELLOW}Warning: Goal already assigned to session: $current_assigned${NC}"
        echo -e "${YELLOW}Reassigning to: $session_id${NC}"
    fi

    local ts
    ts=$(timestamp)

    # Get current phase
    local current_phase
    current_phase=$(yq -r '.lifecycle.phase // "specify"' "$goal_file")

    # Update goal
    yq -i ".lifecycle.assigned_session = \"$session_id\"" "$goal_file"
    yq -i ".lifecycle.assigned_at = \"$ts\"" "$goal_file"

    # If still in specify/plan phase, advance to implement
    if [[ "$current_phase" == "specify" || "$current_phase" == "plan" ]]; then
        yq -i ".lifecycle.phase = \"implement\"" "$goal_file"
        current_phase="implement"
    fi

    # Update session with spec context
    local goal_name branch
    goal_name=$(yq -r '.name' "$goal_file")
    branch=$(yq -r '.source.branch // ""' "$goal_file")

    local spec_context
    spec_context=$(jq -n \
        --arg goal_id "$goal_id" \
        --arg name "$goal_name" \
        --arg branch "$branch" \
        --arg phase "$current_phase" \
        '{goal_id: $goal_id, name: $name, branch: $branch, phase: $phase, current_task: null}')

    # Update session JSON
    local tmp_session
    tmp_session=$(mktemp)
    jq --argjson spec "$spec_context" '.context.spec = $spec' "$session_file" > "$tmp_session"
    mv "$tmp_session" "$session_file"

    echo -e "${GREEN}Assigned goal to session:${NC}"
    echo -e "  ${CYAN}Goal:${NC} $goal_id"
    echo -e "  ${CYAN}Session:${NC} $session_id"
    echo -e "  ${CYAN}Phase:${NC} $current_phase"
}

# Update progress on a spec
spec_progress() {
    local goal_id=""
    local phase=""
    local task=""
    local criterion_index=""
    local criterion_status=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --phase|-p)
                phase="$2"
                shift 2
                ;;
            --task|-t)
                task="$2"
                shift 2
                ;;
            --criterion|-c)
                criterion_index="$2"
                shift 2
                ;;
            --status|-s)
                criterion_status="$2"
                shift 2
                ;;
            -*)
                echo -e "${RED}Error: Unknown option: $1${NC}" >&2
                return 1
                ;;
            *)
                goal_id="$1"
                shift
                ;;
        esac
    done

    if [[ -z "$goal_id" ]]; then
        echo -e "${RED}Error: Goal ID required${NC}" >&2
        echo "Usage: lore spec progress <goal-id> [--phase <phase>] [--task <task-id>] [--criterion <index> --status <status>]" >&2
        return 1
    fi

    check_yq
    check_jq

    local goal_file
    goal_file=$(get_goal_file "$goal_id")

    if [[ ! -f "$goal_file" ]]; then
        echo -e "${RED}Error: Goal not found: $goal_id${NC}" >&2
        return 1
    fi

    local updated=false

    # Update phase
    if [[ -n "$phase" ]]; then
        if [[ ! " $VALID_PHASES " =~ " $phase " ]]; then
            echo -e "${RED}Error: Invalid phase '$phase'${NC}" >&2
            echo "Valid phases: $VALID_PHASES" >&2
            return 1
        fi
        yq -i ".lifecycle.phase = \"$phase\"" "$goal_file"
        echo -e "${GREEN}Updated phase:${NC} $phase"
        updated=true

        # Also update session if assigned
        local session_id
        session_id=$(yq -r '.lifecycle.assigned_session // ""' "$goal_file")
        if [[ -n "$session_id" && "$session_id" != "null" ]]; then
            local session_file
            session_file=$(get_session_file "$session_id")
            if [[ -f "$session_file" ]]; then
                local tmp_session
                tmp_session=$(mktemp)
                jq --arg phase "$phase" '.context.spec.phase = $phase' "$session_file" > "$tmp_session"
                mv "$tmp_session" "$session_file"
            fi
        fi
    fi

    # Update current task
    if [[ -n "$task" ]]; then
        local session_id
        session_id=$(yq -r '.lifecycle.assigned_session // ""' "$goal_file")
        if [[ -n "$session_id" && "$session_id" != "null" ]]; then
            local session_file
            session_file=$(get_session_file "$session_id")
            if [[ -f "$session_file" ]]; then
                local tmp_session
                tmp_session=$(mktemp)
                jq --arg task "$task" '.context.spec.current_task = $task' "$session_file" > "$tmp_session"
                mv "$tmp_session" "$session_file"
                echo -e "${GREEN}Updated current task:${NC} $task"
                updated=true
            fi
        else
            echo -e "${YELLOW}Warning: Goal not assigned to session, cannot update task${NC}"
        fi
    fi

    # Update criterion status
    if [[ -n "$criterion_index" ]]; then
        if [[ -z "$criterion_status" ]]; then
            echo -e "${RED}Error: --status required with --criterion${NC}" >&2
            return 1
        fi
        if [[ ! " $VALID_CRITERION_STATUSES " =~ " $criterion_status " ]]; then
            echo -e "${RED}Error: Invalid criterion status '$criterion_status'${NC}" >&2
            echo "Valid statuses: $VALID_CRITERION_STATUSES" >&2
            return 1
        fi

        # yq uses 0-based indexing
        local idx=$((criterion_index))
        yq -i ".success_criteria[$idx].status = \"$criterion_status\"" "$goal_file"
        echo -e "${GREEN}Updated criterion $criterion_index:${NC} $criterion_status"
        updated=true
    fi

    if [[ "$updated" == false ]]; then
        echo -e "${YELLOW}No updates specified${NC}"
        echo "Usage: lore spec progress <goal-id> [--phase <phase>] [--task <task-id>] [--criterion <index> --status <status>]"
    fi
}

# Record outcome and close the loop
spec_complete() {
    local goal_id=""
    local status="completed"
    local notes=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --status|-s)
                status="$2"
                shift 2
                ;;
            --notes|-n)
                notes="$2"
                shift 2
                ;;
            -*)
                echo -e "${RED}Error: Unknown option: $1${NC}" >&2
                return 1
                ;;
            *)
                goal_id="$1"
                shift
                ;;
        esac
    done

    if [[ -z "$goal_id" ]]; then
        echo -e "${RED}Error: Goal ID required${NC}" >&2
        echo "Usage: lore spec complete <goal-id> [--status <completed|failed|abandoned>] [--notes \"...\"]" >&2
        return 1
    fi

    if [[ ! " $VALID_OUTCOME_STATUSES " =~ " $status " ]]; then
        echo -e "${RED}Error: Invalid status '$status'${NC}" >&2
        echo "Valid statuses: $VALID_OUTCOME_STATUSES" >&2
        return 1
    fi

    check_yq
    check_jq

    local goal_file
    goal_file=$(get_goal_file "$goal_id")

    if [[ ! -f "$goal_file" ]]; then
        echo -e "${RED}Error: Goal not found: $goal_id${NC}" >&2
        return 1
    fi

    local ts
    ts=$(timestamp)

    local session_id
    session_id=$(yq -r '.lifecycle.assigned_session // ""' "$goal_file")

    local goal_name
    goal_name=$(yq -r '.name' "$goal_file")

    # Update goal outcome
    yq -i ".outcome.status = \"$status\"" "$goal_file"
    yq -i ".outcome.completed_at = \"$ts\"" "$goal_file"
    yq -i ".lifecycle.phase = \"complete\"" "$goal_file"

    if [[ -n "$session_id" && "$session_id" != "null" ]]; then
        yq -i ".outcome.session_id = \"$session_id\"" "$goal_file"
    fi

    # Update goal status
    case "$status" in
        completed) yq -i ".status = \"completed\"" "$goal_file" ;;
        failed)    yq -i ".status = \"blocked\"" "$goal_file" ;;
        abandoned) yq -i ".status = \"cancelled\"" "$goal_file" ;;
    esac

    # Write journal entry
    local decision_text="Spec $status: $goal_name"
    if [[ -n "$notes" ]]; then
        decision_text="$decision_text - $notes"
    fi

    local journal_id=""
    if [[ -x "$LORE_DIR/lore.sh" ]]; then
        journal_id=$("$LORE_DIR/lore.sh" remember "$decision_text" \
            --rationale "Outcome of spec-driven development" \
            --tags "spec:$goal_id,spec-outcome" \
            --force 2>/dev/null | grep -oE "dec-[a-z0-9-]+" || true)

        if [[ -n "$journal_id" ]]; then
            yq -i ".outcome.journal_entry = \"$journal_id\"" "$goal_file"
        fi
    fi

    # Clear spec context from session
    if [[ -n "$session_id" && "$session_id" != "null" ]]; then
        local session_file
        session_file=$(get_session_file "$session_id")
        if [[ -f "$session_file" ]]; then
            local tmp_session
            tmp_session=$(mktemp)
            jq 'del(.context.spec)' "$session_file" > "$tmp_session"
            mv "$tmp_session" "$session_file"
        fi
    fi

    echo -e "${GREEN}Completed spec:${NC} $goal_id"
    echo -e "  ${CYAN}Status:${NC} $status"
    echo -e "  ${CYAN}Name:${NC} $goal_name"
    if [[ -n "$notes" ]]; then
        echo -e "  ${CYAN}Notes:${NC} $notes"
    fi
    if [[ -n "$journal_id" ]]; then
        echo -e "  ${CYAN}Journal:${NC} $journal_id"
    fi
}

# Extract decisions from plan.md and journal them
spec_capture_decisions() {
    local plan_file=""
    local goal_id=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -*)
                echo -e "${RED}Error: Unknown option: $1${NC}" >&2
                return 1
                ;;
            *)
                if [[ -z "$plan_file" ]]; then
                    plan_file="$1"
                elif [[ -z "$goal_id" ]]; then
                    goal_id="$1"
                fi
                shift
                ;;
        esac
    done

    if [[ -z "$plan_file" || -z "$goal_id" ]]; then
        echo -e "${RED}Error: Plan file and goal ID required${NC}" >&2
        echo "Usage: lore spec capture-decisions <plan.md> <goal-id>" >&2
        return 1
    fi

    if [[ ! -f "$plan_file" ]]; then
        echo -e "${YELLOW}Plan file not found: $plan_file${NC}"
        return 0
    fi

    check_yq
    check_jq

    local goal_file
    goal_file=$(get_goal_file "$goal_id")

    if [[ ! -f "$goal_file" ]]; then
        echo -e "${RED}Error: Goal not found: $goal_id${NC}" >&2
        return 1
    fi

    local decisions
    decisions=$(parse_plan_md "$plan_file")

    local count
    count=$(echo "$decisions" | jq 'length')

    if [[ "$count" -eq 0 ]]; then
        echo -e "${DIM}No decisions found in plan.md${NC}"
        return 0
    fi

    echo -e "${BLUE}Capturing $count decision(s) from plan.md...${NC}"

    local captured_ids=()

    for ((i=0; i<count; i++)); do
        local dec rat
        dec=$(echo "$decisions" | jq -r ".[$i].decision")
        rat=$(echo "$decisions" | jq -r ".[$i].rationale")

        if [[ -z "$dec" || "$dec" == "null" ]]; then
            continue
        fi

        local journal_id=""
        if [[ -x "$LORE_DIR/lore.sh" ]]; then
            local rationale_arg=""
            if [[ -n "$rat" && "$rat" != "null" ]]; then
                rationale_arg="--rationale"
            fi

            journal_id=$("$LORE_DIR/lore.sh" remember "$dec" \
                ${rationale_arg:+"$rationale_arg" "$rat"} \
                --tags "spec:$goal_id,plan-decision" \
                --force 2>/dev/null | grep -oE "dec-[a-z0-9-]+" || true)

            if [[ -n "$journal_id" ]]; then
                captured_ids+=("$journal_id")
                echo -e "  ${GREEN}[+]${NC} $dec"
            fi
        fi
    done

    # Update goal with decision references
    if [[ ${#captured_ids[@]} -gt 0 ]]; then
        for jid in "${captured_ids[@]}"; do
            yq -i ".lifecycle.plan_decisions += [\"$jid\"]" "$goal_file"
        done
        echo -e "${GREEN}Captured ${#captured_ids[@]} decision(s)${NC}"
    fi
}

# List specs by status
spec_list() {
    local filter=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --filter|-f)
                filter="$2"
                shift 2
                ;;
            active|assigned|unassigned|completed)
                filter="$1"
                shift
                ;;
            -*)
                echo -e "${RED}Error: Unknown option: $1${NC}" >&2
                return 1
                ;;
            *)
                filter="$1"
                shift
                ;;
        esac
    done

    check_yq
    init_spec

    local goal_files
    goal_files=$(find "$GOALS_DIR" -name "*.yaml" -type f 2>/dev/null | sort)

    if [[ -z "$goal_files" ]]; then
        echo -e "${YELLOW}No specs/goals found${NC}"
        return 0
    fi

    echo -e "${BOLD}Specs${NC}"
    printf '%*s\n' "${COLUMNS:-80}" '' | tr ' ' '-'
    printf "%-28s %-30s %-10s %-12s %-10s\n" "ID" "NAME" "PHASE" "STATUS" "SESSION"
    printf '%*s\n' "${COLUMNS:-80}" '' | tr ' ' '-'

    local count=0
    while IFS= read -r goal_file; do
        [[ -z "$goal_file" ]] && continue

        # Only show spec-kit imports
        local source_type
        source_type=$(yq -r '.source.type // ""' "$goal_file" 2>/dev/null)
        if [[ "$source_type" != "spec-kit" ]]; then
            continue
        fi

        local id name phase status session
        id=$(yq -r '.id // "unknown"' "$goal_file")
        name=$(yq -r '.name // "Untitled"' "$goal_file")
        phase=$(yq -r '.lifecycle.phase // "unknown"' "$goal_file")
        status=$(yq -r '.status // "unknown"' "$goal_file")
        session=$(yq -r '.lifecycle.assigned_session // ""' "$goal_file")
        [[ "$session" == "null" ]] && session=""

        # Apply filter
        case "$filter" in
            active)
                [[ "$status" != "active" ]] && continue
                ;;
            assigned)
                [[ -z "$session" ]] && continue
                ;;
            unassigned)
                [[ -n "$session" ]] && continue
                ;;
            completed)
                [[ "$phase" != "complete" ]] && continue
                ;;
        esac

        # Truncate long names
        if [[ ${#name} -gt 28 ]]; then
            name="${name:0:25}..."
        fi

        local short_id="${id:0:26}"
        [[ ${#id} -gt 26 ]] && short_id="${short_id}.."

        local session_display=""
        if [[ -n "$session" ]]; then
            session_display="${session:0:10}"
        else
            session_display="--"
        fi

        printf "%-28s %-30s %-10s %-12s %-10s\n" \
            "$short_id" "$name" "$phase" "$status" "$session_display"

        ((count++)) || true
    done <<< "$goal_files"

    printf '%*s\n' "${COLUMNS:-80}" '' | tr ' ' '-'
    echo -e "${DIM}Total: ${count} spec(s)${NC}"
}

# Show details of a spec/goal
spec_show() {
    local goal_id=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -*)
                echo -e "${RED}Error: Unknown option: $1${NC}" >&2
                return 1
                ;;
            *)
                goal_id="$1"
                shift
                ;;
        esac
    done

    if [[ -z "$goal_id" ]]; then
        echo -e "${RED}Error: Goal ID required${NC}" >&2
        echo "Usage: lore spec show <goal-id>" >&2
        return 1
    fi

    check_yq

    local goal_file
    goal_file=$(get_goal_file "$goal_id")

    if [[ ! -f "$goal_file" ]]; then
        echo -e "${RED}Error: Goal not found: $goal_id${NC}" >&2
        return 1
    fi

    local name status phase branch session imported_at
    name=$(yq -r '.name // "Untitled"' "$goal_file")
    status=$(yq -r '.status // "unknown"' "$goal_file")
    phase=$(yq -r '.lifecycle.phase // "unknown"' "$goal_file")
    branch=$(yq -r '.source.branch // ""' "$goal_file")
    session=$(yq -r '.lifecycle.assigned_session // ""' "$goal_file")
    imported_at=$(yq -r '.source.imported_at // ""' "$goal_file")

    [[ "$branch" == "null" ]] && branch=""
    [[ "$session" == "null" ]] && session=""

    echo -e "${BOLD}${name}${NC}"
    printf '%*s\n' "${COLUMNS:-80}" '' | tr ' ' '-'

    local description
    description=$(yq -r '.description // ""' "$goal_file")
    if [[ -n "$description" && "$description" != "null" ]]; then
        echo -e "${DIM}${description}${NC}"
        echo ""
    fi

    echo -e "  ${CYAN}ID:${NC}       $goal_id"
    echo -e "  ${CYAN}Status:${NC}   $status"
    echo -e "  ${CYAN}Phase:${NC}    $phase"
    echo -e "  ${CYAN}Branch:${NC}   ${branch:-"(not set)"}"
    echo -e "  ${CYAN}Session:${NC}  ${session:-"(unassigned)"}"
    echo -e "  ${CYAN}Imported:${NC} ${imported_at:0:19}"

    # Show success criteria
    local criteria_count
    criteria_count=$(yq -r '.success_criteria | length' "$goal_file" 2>/dev/null || echo "0")

    if [[ "$criteria_count" -gt 0 ]]; then
        echo ""
        echo -e "${BOLD}Success Criteria${NC}"
        for ((i=0; i<criteria_count; i++)); do
            local sc_desc sc_status sc_priority
            sc_desc=$(yq -r ".success_criteria[$i].description" "$goal_file")
            sc_status=$(yq -r ".success_criteria[$i].status // \"pending\"" "$goal_file")
            sc_priority=$(yq -r ".success_criteria[$i].priority // \"P2\"" "$goal_file")

            local status_icon
            case "$sc_status" in
                completed)   status_icon="${GREEN}[x]${NC}" ;;
                in_progress) status_icon="${YELLOW}[~]${NC}" ;;
                *)           status_icon="${RED}[ ]${NC}" ;;
            esac

            echo -e "  ${status_icon} ${sc_desc} ${DIM}(${sc_priority})${NC}"
        done
    fi

    # Show outcome if complete
    local outcome_status
    outcome_status=$(yq -r '.outcome.status // ""' "$goal_file")
    if [[ -n "$outcome_status" && "$outcome_status" != "null" ]]; then
        echo ""
        echo -e "${BOLD}Outcome${NC}"
        echo -e "  ${CYAN}Status:${NC} $outcome_status"
        local completed_at
        completed_at=$(yq -r '.outcome.completed_at // ""' "$goal_file")
        echo -e "  ${CYAN}Completed:${NC} ${completed_at:0:19}"
        local journal_entry
        journal_entry=$(yq -r '.outcome.journal_entry // ""' "$goal_file")
        if [[ -n "$journal_entry" && "$journal_entry" != "null" ]]; then
            echo -e "  ${CYAN}Journal:${NC} $journal_entry"
        fi
    fi

    # Show plan decisions
    local decisions_count
    decisions_count=$(yq -r '.lifecycle.plan_decisions | length' "$goal_file" 2>/dev/null || echo "0")
    if [[ "$decisions_count" -gt 0 ]]; then
        echo ""
        echo -e "${BOLD}Plan Decisions${NC}"
        for ((i=0; i<decisions_count; i++)); do
            local dec_id
            dec_id=$(yq -r ".lifecycle.plan_decisions[$i]" "$goal_file")
            echo -e "  - $dec_id"
        done
    fi

    printf '%*s\n' "${COLUMNS:-80}" '' | tr ' ' '-'
    echo -e "${DIM}File: $goal_file${NC}"
}

# ============================================
# Main dispatch
# ============================================

spec_help() {
    echo "Spec Management - Import and track spec-kit specifications"
    echo ""
    echo "Usage:"
    echo "  lore spec import <spec.md|spec-dir>           Import spec as goal"
    echo "  lore spec assign <goal-id> [--session <id>]   Assign spec to session"
    echo "  lore spec progress <goal-id> [options]        Update progress"
    echo "    --phase <specify|plan|tasks|implement>      Advance phase"
    echo "    --task <task-id>                            Track current task"
    echo "    --criterion <index> --status <status>       Update criterion"
    echo "  lore spec complete <goal-id> [--status S]     Record outcome"
    echo "    --status <completed|failed|abandoned>"
    echo "    --notes \"...\""
    echo "  lore spec capture-decisions <plan.md> <goal>  Extract plan decisions"
    echo "  lore spec list [filter]                       List specs"
    echo "    active | assigned | unassigned | completed"
    echo "  lore spec show <goal-id>                      Show spec details"
}

spec_main() {
    if [[ $# -eq 0 ]]; then
        spec_help
        return 0
    fi

    local command="$1"
    shift

    case "$command" in
        import)           spec_import "$@" ;;
        assign)           spec_assign "$@" ;;
        progress)         spec_progress "$@" ;;
        complete)         spec_complete "$@" ;;
        capture-decisions) spec_capture_decisions "$@" ;;
        list)             spec_list "$@" ;;
        show)             spec_show "$@" ;;
        -h|--help|help)   spec_help ;;
        *)
            echo -e "${RED}Unknown spec command: $command${NC}" >&2
            spec_help >&2
            return 1
            ;;
    esac
}
