#!/usr/bin/env bash
# Intent layer - Goals and missions management
# Absorbed from Oracle (Telos) into Lore

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA_DIR="${SCRIPT_DIR}/../data"
GOALS_DIR="${DATA_DIR}/goals"
MISSIONS_DIR="${DATA_DIR}/missions"
TASKS_DIR="${DATA_DIR}/tasks"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# Valid status values
VALID_GOAL_STATUSES="draft active blocked completed cancelled"
VALID_GOAL_PRIORITIES="critical high medium low"
VALID_MISSION_STATUSES="pending assigned in_progress blocked completed failed"
VALID_TASK_STATUSES="pending claimed completed cancelled"
VALID_TASK_PRIORITIES="critical high medium low"

# Ensure data directories exist
init_intent() {
    mkdir -p "$GOALS_DIR" "$MISSIONS_DIR" "$TASKS_DIR"
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

# Check if yq is available
check_yq() {
    if ! command -v yq &>/dev/null; then
        echo -e "${RED}Error: yq is required but not installed${NC}" >&2
        return 1
    fi
}

# Status color
status_color() {
    local status="$1"
    case "$status" in
        active|in_progress) echo -e "${GREEN}" ;;
        completed|done) echo -e "${GREEN}${BOLD}" ;;
        blocked|failed) echo -e "${RED}" ;;
        pending|draft) echo -e "${YELLOW}" ;;
        cancelled) echo -e "${DIM}" ;;
        *) echo -e "${NC}" ;;
    esac
}

# Priority color
priority_color() {
    local priority="$1"
    case "$priority" in
        critical) echo -e "${RED}${BOLD}" ;;
        high) echo -e "${RED}" ;;
        medium) echo -e "${YELLOW}" ;;
        low) echo -e "${DIM}" ;;
        *) echo -e "${NC}" ;;
    esac
}

# Print horizontal separator
print_separator() {
    printf '%*s\n' "${COLUMNS:-80}" '' | tr ' ' '-'
}

# Get goal file path
get_goal_file() {
    local goal_id="$1"
    echo "${GOALS_DIR}/${goal_id}.yaml"
}

# Get mission file path
get_mission_file() {
    local mission_id="$1"
    echo "${MISSIONS_DIR}/${mission_id}.yaml"
}

# List all goal files
list_goal_files() {
    find "$GOALS_DIR" -name "*.yaml" -type f 2>/dev/null | sort
}

# List all mission files
list_mission_files() {
    find "$MISSIONS_DIR" -name "*.yaml" -type f 2>/dev/null | sort
}

# ============================================
# Goal Functions
# ============================================

create_goal() {
    local goal_name=""
    local priority="medium"
    local deadline=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --priority)
                priority="$2"
                shift 2
                ;;
            --deadline)
                deadline="$2"
                shift 2
                ;;
            -*)
                echo -e "${RED}Error: Unknown option: $1${NC}" >&2
                return 1
                ;;
            *)
                if [[ -z "$goal_name" ]]; then
                    goal_name="$1"
                else
                    echo -e "${RED}Error: Unexpected argument: $1${NC}" >&2
                    return 1
                fi
                shift
                ;;
        esac
    done

    if [[ -z "$goal_name" ]]; then
        echo -e "${RED}Error: Goal name required${NC}" >&2
        echo "Usage: lore goal create <name> [--priority <p>] [--deadline <date>]" >&2
        return 1
    fi

    if [[ ! " $VALID_GOAL_PRIORITIES " =~ " $priority " ]]; then
        echo -e "${RED}Error: Invalid priority '$priority'${NC}" >&2
        echo "Valid priorities: $VALID_GOAL_PRIORITIES" >&2
        return 1
    fi

    check_yq
    init_intent

    local goal_id
    goal_id=$(generate_id "goal")

    local goal_file
    goal_file=$(get_goal_file "$goal_id")

    local ts
    ts=$(timestamp)
    local user
    user="${USER:-unknown}"

    local deadline_value="null"
    if [[ -n "$deadline" ]]; then
        deadline_value="\"$deadline\""
    fi

    cat > "$goal_file" << EOF
id: $goal_id
name: "$goal_name"
description: ""

created_at: "$ts"
created_by: "$user"

status: draft
priority: $priority
deadline: $deadline_value

success_criteria: []
depends_on: []
projects: []
tags: []
metrics: {}
notes: ""

mission_hints:
  max_parallel: 3
  preferred_team_size: 2
  decomposition_strategy: sequential
EOF

    echo -e "${GREEN}Created goal:${NC} $goal_id"
    echo -e "${DIM}File: $goal_file${NC}"
}

list_goals() {
    local filter_status=""
    local filter_priority=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --status)
                filter_status="$2"
                shift 2
                ;;
            --priority)
                filter_priority="$2"
                shift 2
                ;;
            -*)
                echo -e "${RED}Error: Unknown option: $1${NC}" >&2
                return 1
                ;;
            *)
                echo -e "${RED}Error: Unexpected argument: $1${NC}" >&2
                return 1
                ;;
        esac
    done

    check_yq
    init_intent

    local goal_files
    goal_files=$(list_goal_files)

    if [[ -z "$goal_files" ]]; then
        echo -e "${YELLOW}No goals found${NC}"
        return 0
    fi

    echo -e "${BOLD}Goals${NC}"
    print_separator
    printf "%-22s %-30s %-12s %-10s %-12s\n" "ID" "NAME" "STATUS" "PRIORITY" "DEADLINE"
    print_separator

    local count=0
    while IFS= read -r goal_file; do
        [[ -z "$goal_file" ]] && continue

        local id name status priority deadline
        id=$(yq -r '.id // "unknown"' "$goal_file")
        name=$(yq -r '.name // "Untitled"' "$goal_file")
        status=$(yq -r '.status // "unknown"' "$goal_file")
        priority=$(yq -r '.priority // "medium"' "$goal_file")
        deadline=$(yq -r '.deadline // "--"' "$goal_file")
        [[ "$deadline" == "null" ]] && deadline="--"

        if [[ -n "$filter_status" && "$status" != "$filter_status" ]]; then
            continue
        fi
        if [[ -n "$filter_priority" && "$priority" != "$filter_priority" ]]; then
            continue
        fi

        if [[ ${#name} -gt 28 ]]; then
            name="${name:0:25}..."
        fi

        local short_id="${id:0:20}"
        [[ ${#id} -gt 20 ]] && short_id="${short_id}..."

        local status_c priority_c
        status_c=$(status_color "$status")
        priority_c=$(priority_color "$priority")

        printf "%-22s %-30s ${status_c}%-12s${NC} ${priority_c}%-10s${NC} %-12s\n" \
            "$short_id" "$name" "$status" "$priority" "$deadline"

        ((count++)) || true
    done <<< "$goal_files"

    print_separator
    echo -e "${DIM}Total: ${count} goal(s)${NC}"
}

get_goal() {
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
        echo "Usage: lore goal show <goal-id>" >&2
        return 1
    fi

    check_yq

    local goal_file
    goal_file=$(get_goal_file "$goal_id")

    if [[ ! -f "$goal_file" ]]; then
        echo -e "${RED}Error: Goal not found: $goal_id${NC}" >&2
        return 1
    fi

    local name status priority deadline description created_at
    name=$(yq -r '.name // "Untitled"' "$goal_file")
    status=$(yq -r '.status // "unknown"' "$goal_file")
    priority=$(yq -r '.priority // "medium"' "$goal_file")
    deadline=$(yq -r '.deadline // "none"' "$goal_file")
    description=$(yq -r '.description // ""' "$goal_file")
    created_at=$(yq -r '.created_at // "unknown"' "$goal_file")
    [[ "$deadline" == "null" ]] && deadline="none"

    echo -e "${BOLD}${name}${NC}"
    print_separator
    if [[ -n "$description" && "$description" != "null" ]]; then
        echo -e "${DIM}${description}${NC}"
        echo ""
    fi

    echo -e "  ID:       ${goal_id}"
    echo -e "  Status:   ${status}"
    echo -e "  Priority: ${priority}"
    echo -e "  Deadline: ${deadline}"
    echo -e "  Created:  ${created_at}"

    local criteria_count
    criteria_count=$(yq -r '.success_criteria | length' "$goal_file" 2>/dev/null || echo "0")
    if [[ "$criteria_count" -gt 0 ]]; then
        echo ""
        echo -e "${BOLD}Success Criteria${NC}"
        for ((i=0; i<criteria_count; i++)); do
            local sc_desc sc_met
            sc_desc=$(yq -r ".success_criteria[$i].description" "$goal_file")
            sc_met=$(yq -r ".success_criteria[$i].met // false" "$goal_file")
            if [[ "$sc_met" == "true" ]]; then
                echo -e "  ${GREEN}[x]${NC} ${sc_desc}"
            else
                echo -e "  ${RED}[ ]${NC} ${sc_desc}"
            fi
        done
    fi

    print_separator
    echo -e "${DIM}File: $goal_file${NC}"
}

# ============================================
# Mission Functions
# ============================================

create_mission() {
    local goal_id=""
    local mission_name=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --name)
                mission_name="$2"
                shift 2
                ;;
            -*)
                echo -e "${RED}Error: Unknown option: $1${NC}" >&2
                return 1
                ;;
            *)
                if [[ -z "$goal_id" ]]; then
                    goal_id="$1"
                else
                    echo -e "${RED}Error: Unexpected argument: $1${NC}" >&2
                    return 1
                fi
                shift
                ;;
        esac
    done

    if [[ -z "$goal_id" ]]; then
        echo -e "${RED}Error: Goal ID required${NC}" >&2
        echo "Usage: lore mission generate <goal-id>" >&2
        return 1
    fi

    check_yq
    init_intent

    local goal_file
    goal_file=$(get_goal_file "$goal_id")

    if [[ ! -f "$goal_file" ]]; then
        echo -e "${RED}Error: Goal not found: $goal_id${NC}" >&2
        return 1
    fi

    local goal_name goal_priority goal_deadline
    goal_name=$(yq -r '.name' "$goal_file")
    goal_priority=$(yq -r '.priority // "medium"' "$goal_file")
    goal_deadline=$(yq -r '.deadline // "null"' "$goal_file")

    local criteria_count
    criteria_count=$(yq -r '.success_criteria | length' "$goal_file")

    if [[ "$criteria_count" -eq 0 ]]; then
        echo -e "${YELLOW}No success criteria defined for goal${NC}"
        return 0
    fi

    echo -e "${BLUE}Generating missions for goal: $goal_id${NC}"

    local created_count=0
    local prev_mission_id=""

    for ((i=0; i<criteria_count; i++)); do
        local sc_id sc_desc
        sc_id=$(yq -r ".success_criteria[$i].id" "$goal_file")
        sc_desc=$(yq -r ".success_criteria[$i].description" "$goal_file")

        local mission_id
        mission_id=$(generate_id "mission")

        local name="$goal_name - $sc_desc"
        if [[ ${#name} -gt 80 ]]; then
            name="${name:0:77}..."
        fi

        local depends_on="[]"
        if [[ -n "$prev_mission_id" ]]; then
            depends_on="[\"$prev_mission_id\"]"
        fi

        local ts
        ts=$(timestamp)

        local mission_file
        mission_file=$(get_mission_file "$mission_id")

        cat > "$mission_file" << EOF
id: $mission_id
name: "$name"
description: |
  Mission derived from goal success criterion.
  Criterion: $sc_desc

goal_id: $goal_id
status: pending
created_at: "$ts"
priority: $goal_priority
deadline: $goal_deadline
depends_on: $depends_on

work_items:
  - id: wi-1
    description: "$sc_desc"
    completed: false

addresses_criteria:
  - $sc_id
EOF

        echo -e "  ${CYAN}$mission_id${NC}: $name"
        prev_mission_id="$mission_id"
        ((created_count++)) || true
    done

    echo -e "${GREEN}Created $created_count mission(s)${NC}"
}

list_missions() {
    local filter_goal=""
    local filter_status=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --goal)
                filter_goal="$2"
                shift 2
                ;;
            --status)
                filter_status="$2"
                shift 2
                ;;
            -*)
                echo -e "${RED}Error: Unknown option: $1${NC}" >&2
                return 1
                ;;
            *)
                shift
                ;;
        esac
    done

    check_yq
    init_intent

    local mission_files
    mission_files=$(list_mission_files)

    if [[ -z "$mission_files" ]]; then
        echo -e "${YELLOW}No missions found${NC}"
        return 0
    fi

    printf "${BOLD}%-28s %-35s %-12s %-12s${NC}\n" "ID" "NAME" "STATUS" "GOAL"
    print_separator

    while IFS= read -r mission_file; do
        [[ -z "$mission_file" ]] && continue

        local id name goal_id status
        id=$(yq -r '.id' "$mission_file")
        name=$(yq -r '.name' "$mission_file")
        goal_id=$(yq -r '.goal_id' "$mission_file")
        status=$(yq -r '.status' "$mission_file")

        if [[ -n "$filter_goal" && "$goal_id" != "$filter_goal" ]]; then
            continue
        fi
        if [[ -n "$filter_status" && "$status" != "$filter_status" ]]; then
            continue
        fi

        if [[ ${#name} -gt 33 ]]; then
            name="${name:0:30}..."
        fi

        local goal_display="${goal_id:0:11}"
        [[ ${#goal_id} -gt 11 ]] && goal_display="${goal_display}.."

        local status_c
        status_c=$(status_color "$status")

        printf "%-28s %-35s ${status_c}%-12s${NC} %-12s\n" \
            "$id" "$name" "$status" "$goal_display"
    done <<< "$mission_files"
}

# ============================================
# Task Functions (for agent delegation)
# ============================================

# Get task file path
get_task_file() {
    local task_id="$1"
    echo "${TASKS_DIR}/${task_id}.yaml"
}

# List all task files
list_task_files() {
    find "$TASKS_DIR" -name "*.yaml" -type f 2>/dev/null | sort
}

# Create a delegated task
# Tasks differ from missions: standalone, queryable by other agents, can be claimed
create_task() {
    local title=""
    local description=""
    local priority="medium"
    local context=""
    local goal_id=""
    local tags=""
    local for_agent=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --description)
                description="$2"
                shift 2
                ;;
            --priority)
                priority="$2"
                shift 2
                ;;
            --context)
                context="$2"
                shift 2
                ;;
            --goal)
                goal_id="$2"
                shift 2
                ;;
            --tags)
                tags="$2"
                shift 2
                ;;
            --for)
                for_agent="$2"
                shift 2
                ;;
            -*)
                echo -e "${RED}Error: Unknown option: $1${NC}" >&2
                return 1
                ;;
            *)
                if [[ -z "$title" ]]; then
                    title="$1"
                else
                    echo -e "${RED}Error: Unexpected argument: $1${NC}" >&2
                    return 1
                fi
                shift
                ;;
        esac
    done

    if [[ -z "$title" ]]; then
        echo -e "${RED}Error: Task title required${NC}" >&2
        echo "Usage: lore task create <title> [--description <d>] [--priority <p>] [--context <c>] [--goal <id>] [--for <agent>]" >&2
        return 1
    fi

    if [[ ! " $VALID_TASK_PRIORITIES " =~ " $priority " ]]; then
        echo -e "${RED}Error: Invalid priority '$priority'${NC}" >&2
        echo "Valid priorities: $VALID_TASK_PRIORITIES" >&2
        return 1
    fi

    check_yq
    init_intent

    local task_id
    task_id=$(generate_id "task")

    local task_file
    task_file=$(get_task_file "$task_id")

    local ts
    ts=$(timestamp)
    local creator
    creator="${USER:-unknown}"
    local session_id
    session_id="${LORE_SESSION_ID:-unknown}"

    # Build tags array
    local tags_yaml="[]"
    if [[ -n "$tags" ]]; then
        tags_yaml=$(echo "$tags" | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | while read -r t; do echo "  - \"$t\""; done)
        tags_yaml=$'\n'"$tags_yaml"
    fi

    local goal_yaml="null"
    [[ -n "$goal_id" ]] && goal_yaml="\"$goal_id\""

    local for_yaml="null"
    [[ -n "$for_agent" ]] && for_yaml="\"$for_agent\""

    cat > "$task_file" << EOF
id: $task_id
title: "$title"
description: |
  $description

created_at: "$ts"
created_by: "$creator"
created_session: "$session_id"

status: pending
priority: $priority

goal_id: $goal_yaml
for_agent: $for_yaml
context: |
  $context

claimed_by: null
claimed_at: null
completed_at: null
outcome: null

tags: $tags_yaml
EOF

    echo -e "${GREEN}Created task:${NC} $task_id"
    echo -e "${DIM}Title: $title${NC}"
    echo -e "${DIM}File: $task_file${NC}"
}

# List tasks, optionally filtered
list_tasks() {
    local filter_status=""
    local filter_priority=""
    local filter_for=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --status)
                filter_status="$2"
                shift 2
                ;;
            --priority)
                filter_priority="$2"
                shift 2
                ;;
            --for)
                filter_for="$2"
                shift 2
                ;;
            -*)
                echo -e "${RED}Error: Unknown option: $1${NC}" >&2
                return 1
                ;;
            *)
                shift
                ;;
        esac
    done

    check_yq
    init_intent

    local task_files
    task_files=$(list_task_files)

    if [[ -z "$task_files" ]]; then
        echo -e "${YELLOW}No tasks found${NC}"
        return 0
    fi

    echo -e "${BOLD}Tasks${NC}"
    print_separator
    printf "%-26s %-35s %-10s %-10s %-10s\n" "ID" "TITLE" "STATUS" "PRIORITY" "FOR"
    print_separator

    local count=0
    while IFS= read -r task_file; do
        [[ -z "$task_file" ]] && continue

        local id title status priority for_agent
        id=$(yq -r '.id // "unknown"' "$task_file")
        title=$(yq -r '.title // "Untitled"' "$task_file")
        status=$(yq -r '.status // "pending"' "$task_file")
        priority=$(yq -r '.priority // "medium"' "$task_file")
        for_agent=$(yq -r '.for_agent // "--"' "$task_file")
        [[ "$for_agent" == "null" ]] && for_agent="--"

        if [[ -n "$filter_status" && "$status" != "$filter_status" ]]; then
            continue
        fi
        if [[ -n "$filter_priority" && "$priority" != "$filter_priority" ]]; then
            continue
        fi
        if [[ -n "$filter_for" && "$for_agent" != "$filter_for" ]]; then
            continue
        fi

        if [[ ${#title} -gt 33 ]]; then
            title="${title:0:30}..."
        fi

        local short_id="${id:0:24}"
        [[ ${#id} -gt 24 ]] && short_id="${short_id}.."

        local status_c priority_c
        status_c=$(status_color "$status")
        priority_c=$(priority_color "$priority")

        printf "%-26s %-35s ${status_c}%-10s${NC} ${priority_c}%-10s${NC} %-10s\n" \
            "$short_id" "$title" "$status" "$priority" "$for_agent"

        ((count++)) || true
    done <<< "$task_files"

    print_separator
    echo -e "${DIM}Total: ${count} task(s)${NC}"
}

# Show a specific task
get_task() {
    local task_id=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -*)
                echo -e "${RED}Error: Unknown option: $1${NC}" >&2
                return 1
                ;;
            *)
                task_id="$1"
                shift
                ;;
        esac
    done

    if [[ -z "$task_id" ]]; then
        echo -e "${RED}Error: Task ID required${NC}" >&2
        echo "Usage: lore task show <task-id>" >&2
        return 1
    fi

    check_yq

    local task_file
    task_file=$(get_task_file "$task_id")

    if [[ ! -f "$task_file" ]]; then
        echo -e "${RED}Error: Task not found: $task_id${NC}" >&2
        return 1
    fi

    local title status priority description context for_agent created_at claimed_by
    title=$(yq -r '.title // "Untitled"' "$task_file")
    status=$(yq -r '.status // "pending"' "$task_file")
    priority=$(yq -r '.priority // "medium"' "$task_file")
    description=$(yq -r '.description // ""' "$task_file")
    context=$(yq -r '.context // ""' "$task_file")
    for_agent=$(yq -r '.for_agent // "any"' "$task_file")
    created_at=$(yq -r '.created_at // "unknown"' "$task_file")
    claimed_by=$(yq -r '.claimed_by // "unclaimed"' "$task_file")
    [[ "$for_agent" == "null" ]] && for_agent="any"
    [[ "$claimed_by" == "null" ]] && claimed_by="unclaimed"

    echo -e "${BOLD}${title}${NC}"
    print_separator

    echo -e "  ID:       ${task_id}"
    echo -e "  Status:   ${status}"
    echo -e "  Priority: ${priority}"
    echo -e "  For:      ${for_agent}"
    echo -e "  Created:  ${created_at}"
    echo -e "  Claimed:  ${claimed_by}"

    if [[ -n "$description" && "$description" != "null" ]]; then
        echo ""
        echo -e "${BOLD}Description${NC}"
        echo "$description" | sed 's/^/  /'
    fi

    if [[ -n "$context" && "$context" != "null" ]]; then
        echo ""
        echo -e "${BOLD}Context${NC}"
        echo "$context" | sed 's/^/  /'
    fi

    print_separator
    echo -e "${DIM}File: $task_file${NC}"
}

# Claim a task (mark as being worked on)
claim_task() {
    local task_id=""
    local agent="${USER:-unknown}"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --agent)
                agent="$2"
                shift 2
                ;;
            -*)
                echo -e "${RED}Error: Unknown option: $1${NC}" >&2
                return 1
                ;;
            *)
                task_id="$1"
                shift
                ;;
        esac
    done

    if [[ -z "$task_id" ]]; then
        echo -e "${RED}Error: Task ID required${NC}" >&2
        echo "Usage: lore task claim <task-id> [--agent <name>]" >&2
        return 1
    fi

    check_yq

    local task_file
    task_file=$(get_task_file "$task_id")

    if [[ ! -f "$task_file" ]]; then
        echo -e "${RED}Error: Task not found: $task_id${NC}" >&2
        return 1
    fi

    local current_status
    current_status=$(yq -r '.status' "$task_file")

    if [[ "$current_status" != "pending" ]]; then
        echo -e "${RED}Error: Task is not pending (status: $current_status)${NC}" >&2
        return 1
    fi

    local ts
    ts=$(timestamp)
    local session_id
    session_id="${LORE_SESSION_ID:-unknown}"

    yq -i ".status = \"claimed\" | .claimed_by = \"$agent\" | .claimed_at = \"$ts\" | .claimed_session = \"$session_id\"" "$task_file"

    echo -e "${GREEN}Claimed task:${NC} $task_id"
    echo -e "${DIM}Claimed by: $agent${NC}"
}

# Complete a task with outcome
complete_task() {
    local task_id=""
    local outcome=""
    local status="completed"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --outcome)
                outcome="$2"
                shift 2
                ;;
            --status)
                status="$2"
                shift 2
                ;;
            -*)
                echo -e "${RED}Error: Unknown option: $1${NC}" >&2
                return 1
                ;;
            *)
                task_id="$1"
                shift
                ;;
        esac
    done

    if [[ -z "$task_id" ]]; then
        echo -e "${RED}Error: Task ID required${NC}" >&2
        echo "Usage: lore task complete <task-id> [--outcome <text>] [--status completed|cancelled]" >&2
        return 1
    fi

    if [[ "$status" != "completed" && "$status" != "cancelled" ]]; then
        echo -e "${RED}Error: Invalid status '$status'. Use 'completed' or 'cancelled'${NC}" >&2
        return 1
    fi

    check_yq

    local task_file
    task_file=$(get_task_file "$task_id")

    if [[ ! -f "$task_file" ]]; then
        echo -e "${RED}Error: Task not found: $task_id${NC}" >&2
        return 1
    fi

    local current_status
    current_status=$(yq -r '.status' "$task_file")

    if [[ "$current_status" != "claimed" && "$current_status" != "pending" ]]; then
        echo -e "${RED}Error: Task cannot be completed (status: $current_status)${NC}" >&2
        return 1
    fi

    local ts
    ts=$(timestamp)

    # Escape outcome for YAML
    local outcome_yaml="null"
    if [[ -n "$outcome" ]]; then
        outcome_yaml="\"$outcome\""
    fi

    yq -i ".status = \"$status\" | .completed_at = \"$ts\" | .outcome = $outcome_yaml" "$task_file"

    echo -e "${GREEN}Task $status:${NC} $task_id"
    [[ -n "$outcome" ]] && echo -e "${DIM}Outcome: $outcome${NC}"
}

# Task dispatcher
intent_task_main() {
    if [[ $# -eq 0 ]]; then
        list_tasks
        return 0
    fi

    local command="$1"
    shift

    case "$command" in
        create)   create_task "$@" ;;
        list)     list_tasks "$@" ;;
        show)     get_task "$@" ;;
        claim)    claim_task "$@" ;;
        complete) complete_task "$@" ;;
        -h|--help|help) task_help ;;
        *)
            echo -e "${RED}Unknown task command: $command${NC}" >&2
            task_help >&2
            return 1
            ;;
    esac
}

task_help() {
    echo "Task - Agent delegation"
    echo ""
    echo "Usage:"
    echo "  lore task create <title> [--description <d>] [--priority <p>] [--context <c>] [--for <agent>]"
    echo "  lore task list [--status pending|claimed|completed|cancelled] [--priority <p>] [--for <agent>]"
    echo "  lore task show <task-id>"
    echo "  lore task claim <task-id> [--agent <name>]"
    echo "  lore task complete <task-id> [--outcome <text>] [--status completed|cancelled]"
    echo ""
    echo "Tasks enable structured delegation between agents."
}

# ============================================
# Main dispatch
# ============================================

intent_help() {
    echo "Intent - Goals, Missions, and Tasks"
    echo ""
    echo "Usage:"
    echo "  lore goal create <name> [--priority <p>] [--deadline <date>]"
    echo "  lore goal list [--status <s>] [--priority <p>]"
    echo "  lore goal show <goal-id>"
    echo ""
    echo "  lore mission generate <goal-id>"
    echo "  lore mission list [--goal <id>] [--status <s>]"
    echo ""
    echo "  lore task create <title> [--description <d>] [--priority <p>] [--context <c>] [--for <agent>]"
    echo "  lore task list [--status <s>] [--priority <p>] [--for <agent>]"
    echo "  lore task show <task-id>"
    echo "  lore task claim <task-id> [--agent <name>]"
    echo "  lore task complete <task-id> [--outcome <text>]"
    echo ""
    echo "  lore intent export <goal-id> [--format yaml|markdown]"
}

intent_goal_main() {
    if [[ $# -eq 0 ]]; then
        intent_help
        return 0
    fi

    local command="$1"
    shift

    case "$command" in
        create)   create_goal "$@" ;;
        list)     list_goals "$@" ;;
        show)     get_goal "$@" ;;
        -h|--help|help) intent_help ;;
        *)
            echo -e "${RED}Unknown goal command: $command${NC}" >&2
            intent_help >&2
            return 1
            ;;
    esac
}

intent_mission_main() {
    if [[ $# -eq 0 ]]; then
        intent_help
        return 0
    fi

    local command="$1"
    shift

    case "$command" in
        generate) create_mission "$@" ;;
        list)     list_missions "$@" ;;
        -h|--help|help) intent_help ;;
        *)
            echo -e "${RED}Unknown mission command: $command${NC}" >&2
            intent_help >&2
            return 1
            ;;
    esac
}

# ============================================
# Export Functions - Spec Generation
# ============================================

export_spec() {
    local goal_id=""
    local format="yaml"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --format)
                format="$2"
                shift 2
                ;;
            -*)
                echo -e "${RED}Error: Unknown option: $1${NC}" >&2
                return 1
                ;;
            *)
                if [[ -z "$goal_id" ]]; then
                    goal_id="$1"
                else
                    echo -e "${RED}Error: Unexpected argument: $1${NC}" >&2
                    return 1
                fi
                shift
                ;;
        esac
    done

    if [[ -z "$goal_id" ]]; then
        echo -e "${RED}Error: Goal ID required${NC}" >&2
        echo "Usage: lore intent export <goal-id> [--format yaml|markdown]" >&2
        return 1
    fi

    if [[ "$format" != "yaml" && "$format" != "markdown" ]]; then
        echo -e "${RED}Error: Invalid format '$format'. Use 'yaml' or 'markdown'${NC}" >&2
        return 1
    fi

    check_yq

    local goal_file
    goal_file=$(get_goal_file "$goal_id")

    if [[ ! -f "$goal_file" ]]; then
        echo -e "${RED}Error: Goal not found: $goal_id${NC}" >&2
        return 1
    fi

    # Extract goal data
    local name description status priority deadline
    name=$(yq -r '.name // "Untitled"' "$goal_file")
    description=$(yq -r '.description // ""' "$goal_file")
    status=$(yq -r '.status // "unknown"' "$goal_file")
    priority=$(yq -r '.priority // "medium"' "$goal_file")
    deadline=$(yq -r '.deadline // "none"' "$goal_file")
    [[ "$deadline" == "null" ]] && deadline=""

    # Build success criteria list
    local criteria_count
    criteria_count=$(yq -r '.success_criteria | length' "$goal_file" 2>/dev/null || echo "0")
    
    local success_criteria=""
    for ((i=0; i<criteria_count; i++)); do
        local sc_desc
        sc_desc=$(yq -r ".success_criteria[$i].description" "$goal_file")
        if [[ "$format" == "yaml" ]]; then
            success_criteria="${success_criteria}  - \"${sc_desc}\"\n"
        else
            success_criteria="${success_criteria}- ${sc_desc}\n"
        fi
    done

    # Get related missions
    local missions_info=""
    local mission_files
    mission_files=$(list_mission_files)
    
    if [[ -n "$mission_files" ]]; then
        while IFS= read -r mission_file; do
            [[ -z "$mission_file" ]] && continue
            local m_goal_id m_name m_status
            m_goal_id=$(yq -r '.goal_id' "$mission_file")
            if [[ "$m_goal_id" == "$goal_id" ]]; then
                m_name=$(yq -r '.name' "$mission_file")
                m_status=$(yq -r '.status' "$mission_file")
                if [[ "$format" == "yaml" ]]; then
                    missions_info="${missions_info}  - name: \"${m_name}\"\n    status: ${m_status}\n"
                else
                    missions_info="${missions_info}- [${m_status}] ${m_name}\n"
                fi
            fi
        done <<< "$mission_files"
    fi

    # Query Lore for related context (decisions, patterns, failures)
    local context_decisions=""
    local context_patterns=""
    local context_failures=""

    # Search for related decisions (suppress errors if empty)
    local decisions_raw
    decisions_raw=$("$LORE_DIR/lore.sh" search "$name" 2>/dev/null | grep -i "decision\|chose\|decided" | head -3 || true)
    if [[ -n "$decisions_raw" ]]; then
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            line=$(echo "$line" | sed 's/^[[:space:]]*//')
            if [[ "$format" == "yaml" ]]; then
                context_decisions="${context_decisions}    - \"${line}\"\n"
            else
                context_decisions="${context_decisions}  - ${line}\n"
            fi
        done <<< "$decisions_raw"
    fi

    # Get recent failures related to goal (strip ANSI codes)
    local failures_raw
    failures_raw=$("$LORE_DIR/lore.sh" failures 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' | head -5 || true)
    if [[ -n "$failures_raw" && "$failures_raw" != *"No failures"* ]]; then
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            [[ "$line" == "Failures"* ]] && continue
            line=$(echo "$line" | sed 's/^[[:space:]]*//')
            if [[ "$format" == "yaml" ]]; then
                context_failures="${context_failures}    - \"${line}\"\n"
            else
                context_failures="${context_failures}  - ${line}\n"
            fi
        done <<< "$failures_raw"
    fi

    # Output based on format
    if [[ "$format" == "yaml" ]]; then
        cat << EOF
# Spec: ${name}
# Generated from Lore intent layer
# Goal ID: ${goal_id}

goal: "${name}"
status: ${status}
priority: ${priority}
EOF
        [[ -n "$deadline" ]] && echo "deadline: \"${deadline}\""
        
        if [[ -n "$description" && "$description" != "null" ]]; then
            echo ""
            echo "description: |"
            echo "  ${description}"
        fi

        echo ""
        echo "success_criteria:"
        if [[ -n "$success_criteria" ]]; then
            echo -e "$success_criteria" | sed '/^$/d'
        else
            echo "  []"
        fi

        if [[ -n "$missions_info" ]]; then
            echo ""
            echo "missions:"
            echo -e "$missions_info" | sed '/^$/d'
        fi

        echo ""
        echo "context:"
        if [[ -n "$context_decisions" ]]; then
            echo "  decisions:"
            echo -e "$context_decisions" | sed '/^$/d'
        fi
        if [[ -n "$context_failures" ]]; then
            echo "  risks:"
            echo -e "$context_failures" | sed '/^$/d'
        fi

        echo ""
        echo "done_when:"
        echo "  - All success criteria met"
        echo "  - Tests pass"
        echo "  - No regressions introduced"

    else
        # Markdown format
        cat << EOF
# ${name}

> Spec generated from Lore intent layer  
> Goal ID: \`${goal_id}\`  
> Status: **${status}** | Priority: **${priority}**
EOF
        [[ -n "$deadline" ]] && echo "> Deadline: ${deadline}"

        if [[ -n "$description" && "$description" != "null" ]]; then
            echo ""
            echo "${description}"
        fi

        echo ""
        echo "## Success Criteria"
        echo ""
        if [[ -n "$success_criteria" ]]; then
            echo -e "$success_criteria" | sed '/^$/d'
        else
            echo "_No criteria defined_"
        fi

        if [[ -n "$missions_info" ]]; then
            echo ""
            echo "## Missions"
            echo ""
            echo -e "$missions_info" | sed '/^$/d'
        fi

        echo ""
        echo "## Context"
        echo ""
        if [[ -n "$context_decisions" ]]; then
            echo "### Related Decisions"
            echo ""
            echo -e "$context_decisions" | sed '/^$/d'
        fi
        if [[ -n "$context_failures" ]]; then
            echo ""
            echo "### Known Risks"
            echo ""
            echo -e "$context_failures" | sed '/^$/d'
        fi

        echo ""
        echo "## Done When"
        echo ""
        echo "- All success criteria met"
        echo "- Tests pass"
        echo "- No regressions introduced"
    fi
}

intent_export_main() {
    if [[ $# -eq 0 ]]; then
        echo -e "${RED}Error: Goal ID required${NC}" >&2
        echo "Usage: lore intent export <goal-id> [--format yaml|markdown]" >&2
        return 1
    fi

    export_spec "$@"
}
