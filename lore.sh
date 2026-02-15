#!/usr/bin/env bash
# lore.sh - Memory that compounds
#
# A system for AI agents to build persistent, searchable memory across sessions.

set -euo pipefail

LORE_DIR="${LORE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

show_help() {
    echo "Lore - Memory That Compounds"
    echo ""
    echo "Usage: lore <component> <command> [options]"
    echo ""
    echo "Components:"
    echo "  journal   Decision capture with rationale and outcomes"
    echo "  graph     Searchable knowledge graph of concepts and relationships"
    echo "  patterns  Learned patterns and anti-patterns"
    echo "  transfer  Session context and succession"
    echo "  inbox     Raw observation staging area"
    echo "  intent    Goals and missions (from Telos/Oracle)"
    echo "  registry  Project metadata and context"
    echo ""
    echo "Quick Commands:"
    echo "  lore remember <text>     Quick capture to journal"
    echo "  lore learn <pattern>     Quick pattern capture"
    echo "  lore handoff <message>   Create handoff for next session"
    echo "  lore resume [session]    Resume from previous session"
    echo "  lore search <query>      Search across all components"
    echo "  lore context <project>   Gather full context for a project"
    echo "  lore suggest <context>   Suggest relevant patterns"
    echo "  lore status              Show current session state"
    echo "  lore observe <text>     Capture a raw observation to inbox"
    echo "  lore inbox [--status S] List inbox observations"
    echo "  lore fail <type> <msg>  Log a failure report"
    echo "  lore failures [opts]    List failures (--type, --mission)"
    echo "  lore triggers           Show recurring failure types (Rule of Three)"
    echo "  lore ingest <proj> <type> <file>  Bulk import from external formats"
    echo ""
    echo "Intent (Goals & Missions):"
    echo "  lore goal create <name>           Create a goal"
    echo "  lore goal list [--status S]       List goals"
    echo "  lore goal show <goal-id>          Show goal details"
    echo "  lore mission generate <goal-id>   Generate missions from goal"
    echo "  lore mission list                 List missions"
    echo ""
    echo "Registry (Project Metadata):"
    echo "  lore registry show <project>      Show enriched project details"
    echo "  lore registry list                List all projects"
    echo "  lore registry context <project>   Assemble context for onboarding"
    echo "  lore registry validate            Check registry consistency"
    echo ""
    echo "Philosophy:"
    echo "  - Decisions have rationale, not just outcomes"
    echo "  - Patterns learned are never lost"
    echo "  - Context transfers between sessions"
    echo "  - Memory compounds over time"
}

# Quick commands that span components
cmd_remember() {
    "$LORE_DIR/journal/journal.sh" record "$@"
}

cmd_learn() {
    "$LORE_DIR/patterns/patterns.sh" capture "$@"
}

cmd_handoff() {
    "$LORE_DIR/transfer/transfer.sh" handoff "$@"
}

cmd_resume() {
    "$LORE_DIR/transfer/transfer.sh" resume "$@"
}

cmd_search() {
    local query="$1"
    echo -e "${BOLD}Searching across Lore...${NC}"
    echo ""

    echo -e "${CYAN}Journal:${NC}"
    "$LORE_DIR/journal/journal.sh" query "$query" 2>/dev/null || echo "  (no results)"
    echo ""

    echo -e "${CYAN}Graph:${NC}"
    "$LORE_DIR/graph/graph.sh" query "$query" 2>/dev/null || echo "  (no results)"
    echo ""

    echo -e "${CYAN}Patterns:${NC}"
    "$LORE_DIR/patterns/patterns.sh" list 2>/dev/null | grep -i "$query" || echo "  (no results)"
    echo ""

    echo -e "${CYAN}Failures:${NC}"
    local failures_file="$LORE_DIR/failures/data/failures.jsonl"
    if [[ -f "$failures_file" ]]; then
        grep -i "$query" "$failures_file" 2>/dev/null \
            | jq -r '"  \(.id) [\(.error_type)] \(.error_message[0:80])"' 2>/dev/null \
            || echo "  (no results)"
    else
        echo "  (no results)"
    fi
    echo ""

    echo -e "${CYAN}Inbox:${NC}"
    local inbox_file="$LORE_DIR/inbox/data/observations.jsonl"
    if [[ -f "$inbox_file" ]]; then
        grep -i "$query" "$inbox_file" 2>/dev/null \
            | jq -r '"  \(.id) [\(.status)] \(.content[0:80])"' 2>/dev/null \
            || echo "  (no results)"
    else
        echo "  (no results)"
    fi
    echo ""

    echo -e "${CYAN}Goals:${NC}"
    local goals_dir="$LORE_DIR/intent/data/goals"
    if [[ -d "$goals_dir" ]] && ls "$goals_dir"/*.yaml &>/dev/null; then
        grep -li "$query" "$goals_dir"/*.yaml 2>/dev/null \
            | while read -r f; do
                local name
                name=$(basename "$f" .yaml)
                echo "  $name"
            done
        [[ ${PIPESTATUS[0]} -ne 0 ]] && echo "  (no results)"
    else
        echo "  (no results)"
    fi
    echo ""

    echo -e "${CYAN}Registry:${NC}"
    local found_registry=false
    for reg_file in "$LORE_DIR/registry/data"/*.yaml; do
        [[ -f "$reg_file" ]] || continue
        if grep -qi "$query" "$reg_file" 2>/dev/null; then
            echo "  $(basename "$reg_file"): $(grep -ci "$query" "$reg_file" 2>/dev/null) match(es)"
            found_registry=true
        fi
    done
    [[ "$found_registry" == false ]] && echo "  (no results)"
}

cmd_status() {
    "$LORE_DIR/transfer/transfer.sh" status
}

cmd_suggest() {
    "$LORE_DIR/patterns/patterns.sh" suggest "$@"
}

cmd_context() {
    local project="${1:-}"

    if [[ -z "$project" ]]; then
        echo -e "${RED}Error: Project name required${NC}" >&2
        echo "Usage: lore context <project>" >&2
        return 1
    fi

    echo -e "${BOLD}Context for project: ${CYAN}${project}${NC}"
    echo ""

    echo -e "${BOLD}Decisions:${NC}"
    "$LORE_DIR/journal/journal.sh" query "$project" --project "$project" 2>/dev/null || echo "  (no decisions)"
    echo ""

    echo -e "${BOLD}Patterns:${NC}"
    "$LORE_DIR/patterns/patterns.sh" suggest "$project" 2>/dev/null || echo "  (no patterns)"
    echo ""

    echo -e "${BOLD}Graph:${NC}"
    local node_id
    node_id=$("$LORE_DIR/graph/graph.sh" list project 2>/dev/null \
        | awk -v p="$project" '{gsub(/\033\[[0-9;]*m/,"")} tolower($3) == tolower(p) { print $1 }')

    if [[ -n "$node_id" ]]; then
        "$LORE_DIR/graph/graph.sh" related "$node_id" --hops 2 2>/dev/null || echo "  (no neighbors)"
    else
        echo "  (project not in graph)"
    fi
}

cmd_fail() {
    source "$LORE_DIR/failures/lib/failures.sh"

    local error_type=""
    local message=""
    local tool=""
    local mission=""
    local step=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --tool|-t)
                tool="$2"
                shift 2
                ;;
            --mission|-m)
                mission="$2"
                shift 2
                ;;
            --step|-s)
                step="$2"
                shift 2
                ;;
            -*)
                echo -e "${RED}Unknown option: $1${NC}" >&2
                return 1
                ;;
            *)
                if [[ -z "$error_type" ]]; then
                    error_type="$1"
                elif [[ -z "$message" ]]; then
                    message="$1"
                else
                    message="$message $1"
                fi
                shift
                ;;
        esac
    done

    if [[ -z "$error_type" || -z "$message" ]]; then
        echo -e "${RED}Error: error_type and message required${NC}" >&2
        echo "Usage: lore fail <error_type> <message> [--tool T] [--mission M] [--step S]" >&2
        echo "Types: UserDeny HardDeny NonZeroExit Timeout ToolError LogicError" >&2
        return 1
    fi

    local id
    id=$(failures_append "$error_type" "$message" "$tool" "$mission" "$step")

    echo -e "${GREEN}Logged:${NC} ${BOLD}$id${NC}"
    echo -e "  ${CYAN}Type:${NC} $error_type"
    echo -e "  ${CYAN}Message:${NC} $message"
    [[ -n "$tool" ]] && echo -e "  ${CYAN}Tool:${NC} $tool"
    [[ -n "$mission" ]] && echo -e "  ${CYAN}Mission:${NC} $mission"
}

cmd_failures() {
    source "$LORE_DIR/failures/lib/failures.sh"

    local filter_type=""
    local filter_mission=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --type)
                filter_type="$2"
                shift 2
                ;;
            --mission)
                filter_mission="$2"
                shift 2
                ;;
            -*)
                echo -e "${RED}Unknown option: $1${NC}" >&2
                return 1
                ;;
            *)
                echo -e "${RED}Unknown argument: $1${NC}" >&2
                return 1
                ;;
        esac
    done

    local results
    results=$(failures_list "$filter_type" "$filter_mission")

    local count
    count=$(echo "$results" | jq 'length')

    if [[ "$count" -eq 0 ]]; then
        echo -e "${YELLOW}No failures found${NC}"
        return 0
    fi

    echo -e "${GREEN}Failures ($count):${NC}"
    echo

    echo "$results" | jq -r '.[] | "  \(.id) [\(.error_type)] \(.timestamp[0:16])\n    \(.error_message[0:70])\(.error_message | if length > 70 then "..." else "" end)\n"'
}

cmd_triggers() {
    source "$LORE_DIR/failures/lib/failures.sh"

    local threshold="${1:-3}"

    local results
    results=$(failures_triggers "$threshold")

    local count
    count=$(echo "$results" | jq 'length')

    if [[ "$count" -eq 0 ]]; then
        echo -e "${YELLOW}No recurring failure types (threshold: ${threshold})${NC}"
        return 0
    fi

    echo -e "${GREEN}Recurring Failures (>= ${threshold} occurrences):${NC}"
    echo

    echo "$results" | jq -r '.[] | "  \(.error_type): \(.count) occurrences (latest: \(.latest[0:16]))\n    Sample: \(.sample_message[0:70])\n"'
}

cmd_observe() {
    source "$LORE_DIR/inbox/lib/inbox.sh"

    local content=""
    local source="manual"
    local tags=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --source|-s)
                source="$2"
                shift 2
                ;;
            --tags|-t)
                tags="$2"
                shift 2
                ;;
            -*)
                echo -e "${RED}Unknown option: $1${NC}" >&2
                return 1
                ;;
            *)
                if [[ -z "$content" ]]; then
                    content="$1"
                else
                    content="$content $1"
                fi
                shift
                ;;
        esac
    done

    if [[ -z "$content" ]]; then
        echo -e "${RED}Error: Observation text required${NC}" >&2
        echo "Usage: lore observe <text> [--source <source>] [--tags <tags>]" >&2
        return 1
    fi

    local id
    id=$(inbox_append "$content" "$source" "$tags")

    echo -e "${GREEN}Observed:${NC} ${BOLD}$id${NC}"
    echo -e "  ${CYAN}Content:${NC} $content"
    if [[ "$source" != "manual" ]]; then
        echo -e "  ${CYAN}Source:${NC} $source"
    fi
}

cmd_inbox() {
    source "$LORE_DIR/inbox/lib/inbox.sh"

    local filter_status=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --status)
                filter_status="$2"
                shift 2
                ;;
            -*)
                echo -e "${RED}Unknown option: $1${NC}" >&2
                return 1
                ;;
            *)
                echo -e "${RED}Unknown argument: $1${NC}" >&2
                return 1
                ;;
        esac
    done

    local results
    results=$(inbox_list "$filter_status")

    local count
    count=$(echo "$results" | jq 'length')

    if [[ "$count" -eq 0 ]]; then
        echo -e "${YELLOW}No observations found${NC}"
        return 0
    fi

    echo -e "${GREEN}Observations ($count):${NC}"
    echo

    echo "$results" | jq -r '.[] | "  \(.id) [\(.status)] \(.timestamp[0:16])\n    \(.content[0:70])\(.content | if length > 70 then "..." else "" end)\n"'
}

main() {
    [[ $# -eq 0 ]] && { show_help; exit 0; }

    case "$1" in
        # Quick commands
        remember)   shift; cmd_remember "$@" ;;
        learn)      shift; cmd_learn "$@" ;;
        handoff)    shift; cmd_handoff "$@" ;;
        resume)     shift; cmd_resume "$@" ;;
        search)     shift; cmd_search "$@" ;;
        suggest)    shift; cmd_suggest "$@" ;;
        context)    shift; cmd_context "$@" ;;
        status)     shift; cmd_status "$@" ;;
        observe)    shift; cmd_observe "$@" ;;
        inbox)      shift; cmd_inbox "$@" ;;
        fail)       shift; cmd_fail "$@" ;;
        failures)   shift; cmd_failures "$@" ;;
        triggers)   shift; cmd_triggers "$@" ;;

        # Ingest command
        ingest)     shift; source "$LORE_DIR/lib/ingest.sh"; cmd_ingest "$@" ;;

        # Component dispatch
        journal)    shift; "$LORE_DIR/journal/journal.sh" "$@" ;;
        graph)      shift; "$LORE_DIR/graph/graph.sh" "$@" ;;
        patterns)   shift; "$LORE_DIR/patterns/patterns.sh" "$@" ;;
        transfer)   shift; "$LORE_DIR/transfer/transfer.sh" "$@" ;;

        # Intent (goals and missions)
        goal)       shift; source "$LORE_DIR/intent/lib/intent.sh"; intent_goal_main "$@" ;;
        mission)    shift; source "$LORE_DIR/intent/lib/intent.sh"; intent_mission_main "$@" ;;

        # Registry (project metadata)
        registry)   shift; source "$LORE_DIR/registry/lib/registry.sh"; registry_main "$@" ;;

        # Help
        -h|--help|help) show_help ;;
        
        *)
            echo -e "${RED}Unknown command: $1${NC}" >&2
            show_help >&2
            exit 1
            ;;
    esac
}

main "$@"
