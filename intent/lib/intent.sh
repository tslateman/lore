#!/usr/bin/env bash
# Intent layer - Goals management
# Absorbed from Oracle (Telos) into Lore

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../lib/paths.sh"
DATA_DIR="${LORE_INTENT_DATA}"
GOALS_DIR="${DATA_DIR}/goals"
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
# Ensure data directories exist
init_intent() {
    mkdir -p "$GOALS_DIR"
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

# List all goal files
list_goal_files() {
    find "$GOALS_DIR" -name "*.yaml" -type f 2>/dev/null | sort
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
# Main dispatch
# ============================================

intent_help() {
    echo "Intent - Goals"
    echo ""
    echo "Usage:"
    echo "  lore goal create <name> [--priority <p>] [--deadline <date>]"
    echo "  lore goal list [--status <s>] [--priority <p>]"
    echo "  lore goal show <goal-id>"
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
