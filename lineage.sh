#!/usr/bin/env bash
# lineage.sh - Memory that compounds
#
# A system for AI agents to build persistent, searchable memory across sessions.

set -euo pipefail

LINEAGE_DIR="${LINEAGE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"

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
    echo "Lineage - Memory That Compounds"
    echo ""
    echo "Usage: lineage <component> <command> [options]"
    echo ""
    echo "Components:"
    echo "  journal   Decision capture with rationale and outcomes"
    echo "  graph     Searchable knowledge graph of concepts and relationships"
    echo "  patterns  Learned patterns and anti-patterns"
    echo "  transfer  Session context and succession"
    echo ""
    echo "Quick Commands:"
    echo "  lineage remember <text>     Quick capture to journal"
    echo "  lineage learn <pattern>     Quick pattern capture"
    echo "  lineage handoff <message>   Create handoff for next session"
    echo "  lineage resume [session]    Resume from previous session"
    echo "  lineage search <query>      Search across all components"
    echo "  lineage context <project>   Gather full context for a project"
    echo "  lineage suggest <context>   Suggest relevant patterns"
    echo "  lineage status              Show current session state"
    echo "  lineage ingest <proj> <type> <file>  Bulk import from external formats"
    echo ""
    echo "Philosophy:"
    echo "  - Decisions have rationale, not just outcomes"
    echo "  - Patterns learned are never lost"
    echo "  - Context transfers between sessions"
    echo "  - Memory compounds over time"
}

# Quick commands that span components
cmd_remember() {
    "$LINEAGE_DIR/journal/journal.sh" record "$@"
}

cmd_learn() {
    "$LINEAGE_DIR/patterns/patterns.sh" capture "$@"
}

cmd_handoff() {
    "$LINEAGE_DIR/transfer/transfer.sh" handoff "$@"
}

cmd_resume() {
    "$LINEAGE_DIR/transfer/transfer.sh" resume "$@"
}

cmd_search() {
    local query="$1"
    echo -e "${BOLD}Searching across Lineage...${NC}"
    echo ""
    
    echo -e "${CYAN}Journal:${NC}"
    "$LINEAGE_DIR/journal/journal.sh" query "$query" 2>/dev/null || echo "  (no results)"
    echo ""
    
    echo -e "${CYAN}Graph:${NC}"
    "$LINEAGE_DIR/graph/graph.sh" query "$query" 2>/dev/null || echo "  (no results)"
    echo ""
    
    echo -e "${CYAN}Patterns:${NC}"
    "$LINEAGE_DIR/patterns/patterns.sh" list 2>/dev/null | grep -i "$query" || echo "  (no results)"
}

cmd_status() {
    "$LINEAGE_DIR/transfer/transfer.sh" status
}

cmd_suggest() {
    "$LINEAGE_DIR/patterns/patterns.sh" suggest "$@"
}

cmd_context() {
    local project="${1:-}"

    if [[ -z "$project" ]]; then
        echo -e "${RED}Error: Project name required${NC}" >&2
        echo "Usage: lineage context <project>" >&2
        return 1
    fi

    echo -e "${BOLD}Context for project: ${CYAN}${project}${NC}"
    echo ""

    echo -e "${BOLD}Decisions:${NC}"
    "$LINEAGE_DIR/journal/journal.sh" query "$project" --project "$project" 2>/dev/null || echo "  (no decisions)"
    echo ""

    echo -e "${BOLD}Patterns:${NC}"
    "$LINEAGE_DIR/patterns/patterns.sh" suggest "$project" 2>/dev/null || echo "  (no patterns)"
    echo ""

    echo -e "${BOLD}Graph:${NC}"
    local node_id
    node_id=$("$LINEAGE_DIR/graph/graph.sh" list project 2>/dev/null \
        | awk -v p="$project" '{gsub(/\033\[[0-9;]*m/,"")} tolower($3) == tolower(p) { print $1 }')

    if [[ -n "$node_id" ]]; then
        "$LINEAGE_DIR/graph/graph.sh" related "$node_id" --hops 2 2>/dev/null || echo "  (no neighbors)"
    else
        echo "  (project not in graph)"
    fi
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
        
        # Ingest command
        ingest)     shift; source "$LINEAGE_DIR/lib/ingest.sh"; cmd_ingest "$@" ;;

        # Component dispatch
        journal)    shift; "$LINEAGE_DIR/journal/journal.sh" "$@" ;;
        graph)      shift; "$LINEAGE_DIR/graph/graph.sh" "$@" ;;
        patterns)   shift; "$LINEAGE_DIR/patterns/patterns.sh" "$@" ;;
        transfer)   shift; "$LINEAGE_DIR/transfer/transfer.sh" "$@" ;;
        
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
