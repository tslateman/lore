#!/usr/bin/env bash
# Decision Journal - Capture and query decisions with rationale and outcomes
# Part of the Lore memory system for AI agents

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/lib"

# Source library files
source "${LIB_DIR}/capture.sh"
source "${LIB_DIR}/store.sh"
source "${LIB_DIR}/relate.sh"

# Colors for output
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

usage() {
    cat <<EOF
${BOLD}Decision Journal${NC} - Capture and query decisions with context

${BOLD}USAGE:${NC}
    journal.sh <command> [options]

${BOLD}COMMANDS:${NC}
    record <decision>     Record a new decision
    query <search>        Search past decisions
    context <file|topic>  Get decisions related to a file or topic
    learn <decision-id>   Add a lesson learned to a decision
    update <decision-id>  Update a decision's outcome or details
    list                  List decisions
    link <id1> <id2>      Link two related decisions
    stats                 Show decision statistics
    compact               Remove duplicate entries (keep latest)
    export                Export decisions or graph

${BOLD}RECORD OPTIONS:${NC}
    --rationale, -r "why"     Why this approach was chosen
    --alternatives, -a "x,y"  Other options considered (comma-separated)
    --tags, -t "tag1,tag2"    Tags for categorization
    --type TYPE               Decision type (architecture, implementation, etc.)
    --files, -f "f1,f2"       Files affected by this decision
    --force                   Skip duplicate check

${BOLD}LIST OPTIONS:${NC}
    --recent N                Show N most recent decisions (default: 10)
    --type TYPE               Filter by decision type
    --outcome STATUS          Filter by outcome (pending, successful, revised, abandoned)
    --tag TAG                 Filter by tag
    --project NAME            Filter by project tag
    --session                 Show decisions from current session

${BOLD}EXPORT OPTIONS:${NC}
    --format FORMAT           Output format: json, markdown, dot, mermaid
    --session SESSION_ID      Export specific session

${BOLD}QUERY OPTIONS:${NC}
    --project, -p NAME        Filter by project tag
    --tag TAG                 Filter by tag

${BOLD}EXAMPLES:${NC}
    # Record a decision with rationale
    journal.sh record "Use JSONL for storage" -r "Simpler than SQLite, append-only is sufficient"

    # Record with alternatives considered
    journal.sh record "Choose Rust for CLI" -r "Performance critical" -a "Go,Python"

    # Inline format (alternative syntax)
    journal.sh record "Use monorepo [because: easier dependency management] [vs: polyrepo]"

    # Search decisions
    journal.sh query "storage format"

    # Search with tag filter
    journal.sh query "storage" --tag telos

    # Get context for a file
    journal.sh context src/store.sh

    # Mark a lesson learned
    journal.sh learn dec-abc123 "JSONL works great for this scale but needs periodic compaction"

    # Update outcome
    journal.sh update dec-abc123 --outcome successful

    # Link related decisions
    journal.sh link dec-abc123 dec-def456

EOF
}

cmd_record() {
    local decision=""
    local rationale=""
    local alternatives=""
    local tags=""
    local explicit_type=""
    local files=""
    local force=false
    local valid_at=""

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -r|--rationale)
                rationale="$2"
                shift 2
                ;;
            -a|--alternatives)
                alternatives="$2"
                shift 2
                ;;
            -t|--tags)
                tags="$2"
                shift 2
                ;;
            --type)
                explicit_type="$2"
                shift 2
                ;;
            -f|--files)
                files="$2"
                shift 2
                ;;
            --valid-at)
                valid_at="$2"
                shift 2
                ;;
            --force)
                force=true
                shift
                ;;
            -*)
                echo -e "${RED}Unknown option: $1${NC}" >&2
                return 1
                ;;
            *)
                if [[ -z "$decision" ]]; then
                    decision="$1"
                else
                    decision="$decision $1"
                fi
                shift
                ;;
        esac
    done

    if [[ -z "$decision" ]]; then
        echo -e "${RED}Error: Decision text required${NC}" >&2
        echo "Usage: journal.sh record <decision> [options]" >&2
        return 1
    fi

    # Dedup guard: check for near-duplicate decisions (fail-open if conflict.sh unavailable)
    if [[ "$force" == false ]]; then
        local _conflict_lib="${SCRIPT_DIR}/../lib/conflict.sh"
        if [[ -f "$_conflict_lib" ]]; then
            local _check_text="$decision"
            [[ -n "$rationale" ]] && _check_text="${_check_text} ${rationale}"
            if source "$_conflict_lib" 2>/dev/null; then
                if ! lore_check_duplicate "decision" "$_check_text"; then
                    return 1
                fi
            fi
        fi
    fi

    # Contradiction check: warn if new decision conflicts with existing active decisions
    if [[ "$force" == false ]]; then
        local _conflict_lib="${SCRIPT_DIR}/../lib/conflict.sh"
        if [[ -f "$_conflict_lib" ]]; then
            local _contra_text="$decision"
            [[ -n "$rationale" ]] && _contra_text="${_contra_text} ${rationale}"
            if source "$_conflict_lib" 2>/dev/null; then
                lore_check_contradiction "$_contra_text" || true
            fi
        fi
    fi

    # Check for inline format
    if [[ "$decision" =~ \[because: ]] || [[ "$decision" =~ \[vs: ]]; then
        local parsed
        parsed=$(parse_inline_decision "$decision")
        decision=$(echo "$parsed" | sed -n '1p')
        [[ -z "$rationale" ]] && rationale=$(echo "$parsed" | sed -n '2p')
        [[ -z "$alternatives" ]] && alternatives=$(echo "$parsed" | sed -n '3p')
    fi

    # Create the decision record
    local record
    record=$(create_decision_record "$decision" "$rationale" "$alternatives" "$tags" "$explicit_type" "$valid_at")

    # Store it (pass --force to bypass deduplication guard)
    local id
    if [[ "$force" == true ]]; then
        id=$(store_decision "$record" --force)
    else
        id=$(store_decision "$record")
    fi

    # Link to files if specified
    if [[ -n "$files" ]]; then
        IFS=',' read -ra file_array <<< "$files"
        link_to_files "$id" "${file_array[@]}"
    fi

    # Auto-link to related decisions
    auto_link_by_entities "$id" 2>/dev/null || true

    # Output confirmation
    echo -e "${GREEN}Recorded decision:${NC} ${BOLD}$id${NC}"
    echo -e "  ${CYAN}Decision:${NC} $decision"
    [[ -n "$rationale" ]] && echo -e "  ${CYAN}Rationale:${NC} $rationale"
    [[ -n "$alternatives" ]] && echo -e "  ${CYAN}Alternatives:${NC} $alternatives"

    local type
    type=$(echo "$record" | jq -r '.type')
    echo -e "  ${CYAN}Type:${NC} $type"

    local entities
    entities=$(echo "$record" | jq -r '.entities | join(", ")')
    if [[ -n "$entities" && "$entities" != "" ]]; then
        echo -e "  ${CYAN}Entities:${NC} $entities"
    fi
}

cmd_query() {
    local query=""
    local project=""
    local tag=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --project|-p)
                project="$2"
                shift 2
                ;;
            --tag)
                tag="$2"
                shift 2
                ;;
            *)
                query="${query:+$query }$1"
                shift
                ;;
        esac
    done

    if [[ -z "$query" ]]; then
        echo -e "${RED}Error: Search query required${NC}" >&2
        return 1
    fi

    local results
    results=$(search_decisions "$query")

    # Filter by project tag if specified
    if [[ -n "$project" ]]; then
        results=$(echo "$results" | jq --arg p "$project" \
            '[.[] | select(.tags | any(. == $p or startswith($p + ":") or startswith($p + ",")))]')
    fi

    # Filter by tag if specified
    if [[ -n "$tag" ]]; then
        results=$(echo "$results" | jq --arg t "$tag" \
            '[.[] | select(.tags | any(. == $t))]')
    fi

    local count
    count=$(echo "$results" | jq 'length')

    if [[ "$count" -eq 0 ]]; then
        echo -e "${YELLOW}No decisions found matching: $query${NC}"
        return 0
    fi

    echo -e "${GREEN}Found $count decision(s):${NC}"
    echo

    echo "$results" | jq -r '.[] | "  \(.id) [\(.type)] \(.outcome)\n    \(.decision)\n    Rationale: \(.rationale // "n/a")\n"'
}

cmd_context() {
    local target="$1"

    if [[ -z "$target" ]]; then
        echo -e "${RED}Error: File or topic required${NC}" >&2
        return 1
    fi

    local results

    # Check if it's a file
    if [[ -f "$target" ]]; then
        echo -e "${CYAN}Decisions related to file:${NC} $target"
        results=$(get_decisions_for_file "$target")
    else
        echo -e "${CYAN}Decisions related to topic:${NC} $target"
        results=$(get_topic_context "$target")
    fi

    local count
    count=$(echo "$results" | jq 'length')

    if [[ "$count" -eq 0 ]]; then
        echo -e "${YELLOW}No related decisions found${NC}"
        return 0
    fi

    echo -e "${GREEN}Found $count related decision(s):${NC}"
    echo

    echo "$results" | jq -r '.[] | "  \(.id) [\(.type)] - \(.timestamp[0:10])\n    \(.decision)\n    Entities: \(.entities | join(", "))\n"'
}

cmd_learn() {
    local decision_id="$1"
    shift
    local lesson="$*"

    if [[ -z "$decision_id" ]]; then
        echo -e "${RED}Error: Decision ID required${NC}" >&2
        return 1
    fi

    if [[ -z "$lesson" ]]; then
        echo -e "${RED}Error: Lesson text required${NC}" >&2
        echo "Usage: journal.sh learn <decision-id> <lesson learned>" >&2
        return 1
    fi

    local current
    current=$(get_decision "$decision_id")

    if [[ -z "$current" ]]; then
        echo -e "${RED}Error: Decision $decision_id not found${NC}" >&2
        return 1
    fi

    update_decision "$decision_id" "lesson_learned" "$lesson"

    echo -e "${GREEN}Lesson recorded for $decision_id:${NC}"
    echo -e "  ${CYAN}Lesson:${NC} $lesson"
    echo
    echo -e "  ${CYAN}Original decision:${NC} $(echo "$current" | jq -r '.decision')"
}

cmd_update() {
    local decision_id="$1"
    shift

    if [[ -z "$decision_id" ]]; then
        echo -e "${RED}Error: Decision ID required${NC}" >&2
        return 1
    fi

    local outcome=""
    local rationale=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --outcome|-o)
                outcome="$2"
                shift 2
                ;;
            --rationale|-r)
                rationale="$2"
                shift 2
                ;;
            *)
                echo -e "${RED}Unknown option: $1${NC}" >&2
                return 1
                ;;
        esac
    done

    local current
    current=$(get_decision "$decision_id")

    if [[ -z "$current" ]]; then
        echo -e "${RED}Error: Decision $decision_id not found${NC}" >&2
        return 1
    fi

    if [[ -n "$outcome" ]]; then
        if [[ ! "$outcome" =~ ^(pending|successful|revised|abandoned)$ ]]; then
            echo -e "${RED}Error: Invalid outcome. Must be: pending, successful, revised, or abandoned${NC}" >&2
            return 1
        fi
        update_decision "$decision_id" "outcome" "$outcome"
        echo -e "${GREEN}Updated outcome to:${NC} $outcome"
    fi

    if [[ -n "$rationale" ]]; then
        update_decision "$decision_id" "rationale" "$rationale"
        echo -e "${GREEN}Updated rationale${NC}"
    fi
}

cmd_list() {
    local count=10
    local filter_type=""
    local filter_outcome=""
    local filter_tag=""
    local filter_project=""
    local session_only=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --recent|-n)
                count="$2"
                shift 2
                ;;
            --type)
                filter_type="$2"
                shift 2
                ;;
            --outcome)
                filter_outcome="$2"
                shift 2
                ;;
            --tag)
                filter_tag="$2"
                shift 2
                ;;
            --project|-p)
                filter_project="$2"
                shift 2
                ;;
            --session)
                session_only=true
                shift
                ;;
            *)
                echo -e "${RED}Unknown option: $1${NC}" >&2
                return 1
                ;;
        esac
    done

    local results

    if [[ "$session_only" == true ]]; then
        local session_id
        session_id=$(get_session_id)
        results=$(export_session "$session_id")
    elif [[ -n "$filter_project" ]]; then
        results=$(get_by_project "$filter_project")
    elif [[ -n "$filter_type" ]]; then
        results=$(get_by_type "$filter_type")
    elif [[ -n "$filter_outcome" ]]; then
        results=$(get_by_outcome "$filter_outcome")
    elif [[ -n "$filter_tag" ]]; then
        results=$(get_by_tag "$filter_tag")
    else
        results=$(list_recent "$count")
    fi

    local total
    total=$(echo "$results" | jq 'length')

    if [[ "$total" -eq 0 ]]; then
        echo -e "${YELLOW}No decisions found${NC}"
        return 0
    fi

    echo -e "${GREEN}Decisions (showing up to $count):${NC}"
    echo

    echo "$results" | jq -r --argjson max "$count" '
        .[0:$max][] |
        "  \(.id) [\(.type)] \(.outcome | if . == "pending" then "..." elif . == "successful" then "OK" elif . == "revised" then "REV" else "X" end)\n    \(.decision[0:70])\(.decision | if length > 70 then "..." else "" end)\n    \(.timestamp[0:10]) | \(.entities | if length > 0 then join(", ")[0:40] else "no entities" end)\n"
    '
}

cmd_link() {
    local id1="$1"
    local id2="$2"
    local relationship="${3:-related}"

    if [[ -z "$id1" ]] || [[ -z "$id2" ]]; then
        echo -e "${RED}Error: Two decision IDs required${NC}" >&2
        echo "Usage: journal.sh link <id1> <id2> [relationship]" >&2
        return 1
    fi

    link_decisions "$id1" "$id2" "$relationship"

    echo -e "${GREEN}Linked decisions:${NC}"
    echo "  $id1 <-> $id2 ($relationship)"
}

cmd_stats() {
    local stats
    stats=$(get_stats)

    echo -e "${BOLD}Decision Journal Statistics${NC}"
    echo

    local total
    total=$(echo "$stats" | jq -r '.total')
    echo -e "  ${CYAN}Total decisions:${NC} $total"

    echo
    echo -e "  ${CYAN}By type:${NC}"
    echo "$stats" | jq -r '.by_type | to_entries[] | "    \(.key): \(.value)"'

    echo
    echo -e "  ${CYAN}By outcome:${NC}"
    echo "$stats" | jq -r '.by_outcome | to_entries[] | "    \(.key): \(.value)"'

    local lessons
    lessons=$(echo "$stats" | jq -r '.with_lessons')
    echo
    echo -e "  ${CYAN}Decisions with lessons:${NC} $lessons"

    local graph_summary
    graph_summary=$(get_graph_summary 2>/dev/null || echo '{}')

    local edges
    edges=$(echo "$graph_summary" | jq -r '.total_edges // 0')
    echo -e "  ${CYAN}Relationship links:${NC} $edges"
}

cmd_export() {
    local format="json"
    local session_id=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --format|-f)
                format="$2"
                shift 2
                ;;
            --session|-s)
                session_id="$2"
                shift 2
                ;;
            *)
                echo -e "${RED}Unknown option: $1${NC}" >&2
                return 1
                ;;
        esac
    done

    case "$format" in
        json)
            if [[ -n "$session_id" ]]; then
                export_session "$session_id"
            else
                list_recent 1000
            fi
            ;;
        markdown)
            local decisions
            if [[ -n "$session_id" ]]; then
                decisions=$(export_session "$session_id")
            else
                decisions=$(list_recent 1000)
            fi

            echo "# Decision Journal"
            echo
            echo "Generated: $(date -u +"%Y-%m-%d %H:%M:%S UTC")"
            echo

            echo "$decisions" | jq -r '.[] |
                "## \(.id) - \(.decision[0:60])\n\n" +
                "- **Date**: \(.timestamp[0:10])\n" +
                "- **Type**: \(.type)\n" +
                "- **Outcome**: \(.outcome)\n\n" +
                "### Decision\n\n\(.decision)\n\n" +
                (if .rationale then "### Rationale\n\n\(.rationale)\n\n" else "" end) +
                (if (.alternatives | length) > 0 then "### Alternatives Considered\n\n\(.alternatives | map("- \(.)") | join("\n"))\n\n" else "" end) +
                (if .lesson_learned then "### Lesson Learned\n\n\(.lesson_learned)\n\n" else "" end) +
                "---\n"
            '
            ;;
        dot|mermaid)
            export_graph "$format"
            ;;
        *)
            echo -e "${RED}Unknown format: $format${NC}" >&2
            echo "Supported formats: json, markdown, dot, mermaid" >&2
            return 1
            ;;
    esac
}

cmd_retract() {
    local id=""
    local reason=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --reason) reason="$2"; shift 2 ;;
            -*) echo -e "${RED}Unknown option: $1${NC}" >&2; return 1 ;;
            *) [[ -z "$id" ]] && id="$1"; shift ;;
        esac
    done

    if [[ -z "$id" ]]; then
        echo -e "${RED}Error: Decision ID required${NC}" >&2
        echo "Usage: journal.sh retract <id> --reason \"...\"" >&2
        return 1
    fi
    if [[ -z "$reason" ]]; then
        echo -e "${RED}Error: --reason required${NC}" >&2
        return 1
    fi

    local current
    current=$(get_decision "$id")
    if [[ -z "$current" ]]; then
        echo -e "${RED}Error: Decision $id not found${NC}" >&2
        return 1
    fi

    local current_status
    current_status=$(echo "$current" | jq -r '.status // "active"')
    if [[ "$current_status" == "retracted" ]]; then
        echo -e "${YELLOW}Decision $id is already retracted${NC}" >&2
        return 1
    fi

    # Append new JSONL line with retracted status
    local retracted
    retracted=$(echo "$current" | jq -c \
        --arg reason "$reason" \
        --arg changed "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '. + {status: "retracted", retracted_reason: $reason, status_changed_at: $changed}')

    echo "$retracted" >> "$DECISIONS_FILE"

    echo -e "${GREEN}Retracted:${NC} ${BOLD}$id${NC}"
    echo -e "  ${CYAN}Reason:${NC} $reason"
}

cmd_supersede() {
    local id=""
    local new_id=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --by) new_id="$2"; shift 2 ;;
            -*) echo -e "${RED}Unknown option: $1${NC}" >&2; return 1 ;;
            *) [[ -z "$id" ]] && id="$1"; shift ;;
        esac
    done

    if [[ -z "$id" ]]; then
        echo -e "${RED}Error: Decision ID required${NC}" >&2
        echo "Usage: journal.sh supersede <id> --by <new-id>" >&2
        return 1
    fi
    if [[ -z "$new_id" ]]; then
        echo -e "${RED}Error: --by <new-id> required${NC}" >&2
        return 1
    fi

    local current
    current=$(get_decision "$id")
    if [[ -z "$current" ]]; then
        echo -e "${RED}Error: Decision $id not found${NC}" >&2
        return 1
    fi

    local replacement
    replacement=$(get_decision "$new_id")
    if [[ -z "$replacement" ]]; then
        echo -e "${RED}Error: Replacement decision $new_id not found${NC}" >&2
        return 1
    fi

    # Append new JSONL line with superseded status
    local superseded
    superseded=$(echo "$current" | jq -c \
        --arg by "$new_id" \
        --arg changed "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '. + {status: "superseded", superseded_by: $by, status_changed_at: $changed}')

    echo "$superseded" >> "$DECISIONS_FILE"

    echo -e "${GREEN}Superseded:${NC} ${BOLD}$id${NC}"
    echo -e "  ${CYAN}Replaced by:${NC} $new_id"
}

# Main command dispatcher
main() {
    if [[ $# -eq 0 ]]; then
        usage
        exit 0
    fi

    local command="$1"
    shift

    case "$command" in
        record)
            cmd_record "$@"
            ;;
        query|search|find)
            cmd_query "$@"
            ;;
        context|ctx)
            cmd_context "$@"
            ;;
        learn|lesson)
            cmd_learn "$@"
            ;;
        update)
            cmd_update "$@"
            ;;
        list|ls)
            cmd_list "$@"
            ;;
        link)
            cmd_link "$@"
            ;;
        stats)
            cmd_stats
            ;;
        compact)
            compact_decisions
            ;;
        retract)
            cmd_retract "$@"
            ;;
        supersede)
            cmd_supersede "$@"
            ;;
        export)
            cmd_export "$@"
            ;;
        help|-h|--help)
            usage
            ;;
        *)
            echo -e "${RED}Unknown command: $command${NC}" >&2
            echo "Run 'journal.sh help' for usage" >&2
            exit 1
            ;;
    esac
}

main "$@"
