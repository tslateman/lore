#!/usr/bin/env bash
# Pattern Learner - Capture lessons learned, anti-patterns, and reusable solutions
# Part of the Lore memory system for AI agents

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/lib"
DATA_DIR="$SCRIPT_DIR/data"
PATTERNS_FILE="$DATA_DIR/patterns.yaml"

# Source library functions
source "$LIB_DIR/capture.sh"
source "$LIB_DIR/match.sh"
source "$LIB_DIR/suggest.sh"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

usage() {
    cat <<EOF
Pattern Learner - Memory system for AI agent patterns

Usage: patterns.sh <command> [options]

Commands:
  capture <pattern>    Record a pattern
    --context "when"   Context when pattern applies
    --solution "how"   How to apply the pattern
    --category <cat>   Category: bash, git, testing, architecture, naming, security
    --origin <session> Origin session/decision that taught this
    --example-bad      Bad example code
    --example-good     Good example code

  warn <anti-pattern>  Record an anti-pattern
    --symptom "what"   What symptom indicates this anti-pattern
    --fix "how"        How to fix it
    --risk "why"       Why this is risky
    --severity <sev>   Severity: low, medium, high, critical
    --category <cat>   Category (same as capture)

  check <file|code>    Check if any known patterns/anti-patterns apply
    --verbose          Show detailed explanations

  suggest <context>    Suggest relevant patterns for a situation
    --limit <n>        Maximum suggestions (default: 5)

  list                 List known patterns
    --type <type>      Filter: patterns, anti-patterns, all (default: all)
    --category <cat>   Filter by category
    --format <fmt>     Output format: table, yaml, json (default: table)

  show <id>            Show details for a specific pattern/anti-pattern

  validate <id>        Mark a pattern as validated (increases confidence)

  init                 Initialize patterns database

Examples:
  patterns.sh capture "Safe bash arithmetic" \\
    --context "Incrementing variables in bash with set -e" \\
    --solution "Use x=\$((x + 1)) instead of ((x++))" \\
    --category bash \\
    --example-bad "((count++))" \\
    --example-good "count=\$((count + 1))"

  patterns.sh warn "Baked-in credentials" \\
    --symptom "Credentials stored in container image or code" \\
    --risk "Credential exfiltration by compromised agent" \\
    --fix "Use credential broker with scoped tokens" \\
    --category security \\
    --severity critical

  patterns.sh check src/deploy.sh
  patterns.sh suggest "writing bash script with counters"
  patterns.sh list --type anti-patterns --category security
EOF
}

# Initialize patterns database if it doesn't exist
init_database() {
    if [[ ! -f "$PATTERNS_FILE" ]]; then
        mkdir -p "$DATA_DIR"
        cat > "$PATTERNS_FILE" <<'YAML'
# Pattern Learner Database
# Captures lessons learned, anti-patterns, and reusable solutions

patterns: []

anti_patterns: []
YAML
        echo -e "${GREEN}Initialized patterns database at $PATTERNS_FILE${NC}"
    fi
}

# Command: capture
cmd_capture() {
    local name=""
    local context=""
    local solution=""
    local category="general"
    local origin=""
    local example_bad=""
    local example_good=""
    local problem=""

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --context)
                context="$2"
                shift 2
                ;;
            --solution)
                solution="$2"
                shift 2
                ;;
            --problem)
                problem="$2"
                shift 2
                ;;
            --category)
                category="$2"
                shift 2
                ;;
            --origin)
                origin="$2"
                shift 2
                ;;
            --example-bad)
                example_bad="$2"
                shift 2
                ;;
            --example-good)
                example_good="$2"
                shift 2
                ;;
            -*)
                echo -e "${RED}Unknown option: $1${NC}" >&2
                return 1
                ;;
            *)
                if [[ -z "$name" ]]; then
                    name="$1"
                fi
                shift
                ;;
        esac
    done

    if [[ -z "$name" ]]; then
        echo -e "${RED}Error: Pattern name is required${NC}" >&2
        return 1
    fi

    capture_pattern "$name" "$context" "$solution" "$problem" "$category" "$origin" "$example_bad" "$example_good"
}

# Command: warn
cmd_warn() {
    local name=""
    local symptom=""
    local fix=""
    local risk=""
    local severity="medium"
    local category="general"

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --symptom)
                symptom="$2"
                shift 2
                ;;
            --fix)
                fix="$2"
                shift 2
                ;;
            --risk)
                risk="$2"
                shift 2
                ;;
            --severity)
                severity="$2"
                shift 2
                ;;
            --category)
                category="$2"
                shift 2
                ;;
            -*)
                echo -e "${RED}Unknown option: $1${NC}" >&2
                return 1
                ;;
            *)
                if [[ -z "$name" ]]; then
                    name="$1"
                fi
                shift
                ;;
        esac
    done

    if [[ -z "$name" ]]; then
        echo -e "${RED}Error: Anti-pattern name is required${NC}" >&2
        return 1
    fi

    capture_anti_pattern "$name" "$symptom" "$fix" "$risk" "$severity" "$category"
}

# Command: check
cmd_check() {
    local target=""
    local verbose=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --verbose|-v)
                verbose=true
                shift
                ;;
            -*)
                echo -e "${RED}Unknown option: $1${NC}" >&2
                return 1
                ;;
            *)
                target="$1"
                shift
                ;;
        esac
    done

    if [[ -z "$target" ]]; then
        echo -e "${RED}Error: File or code to check is required${NC}" >&2
        return 1
    fi

    check_patterns "$target" "$verbose"
}

# Command: suggest
cmd_suggest() {
    local context=""
    local limit=5

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --limit)
                limit="$2"
                shift 2
                ;;
            -*)
                echo -e "${RED}Unknown option: $1${NC}" >&2
                return 1
                ;;
            *)
                context="$context $1"
                shift
                ;;
        esac
    done

    context="${context# }"  # Trim leading space

    if [[ -z "$context" ]]; then
        echo -e "${RED}Error: Context is required${NC}" >&2
        return 1
    fi

    suggest_patterns "$context" "$limit"
}

# Command: list
cmd_list() {
    local type="all"
    local category=""
    local format="table"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --type)
                type="$2"
                shift 2
                ;;
            --category)
                category="$2"
                shift 2
                ;;
            --format)
                format="$2"
                shift 2
                ;;
            -*)
                echo -e "${RED}Unknown option: $1${NC}" >&2
                return 1
                ;;
            *)
                shift
                ;;
        esac
    done

    list_patterns "$type" "$category" "$format"
}

# Command: show
cmd_show() {
    local id="$1"

    if [[ -z "$id" ]]; then
        echo -e "${RED}Error: Pattern ID is required${NC}" >&2
        return 1
    fi

    show_pattern "$id"
}

# Command: validate
cmd_validate() {
    local id="$1"

    if [[ -z "$id" ]]; then
        echo -e "${RED}Error: Pattern ID is required${NC}" >&2
        return 1
    fi

    validate_pattern "$id"
}

# Main command dispatcher
main() {
    if [[ $# -eq 0 ]]; then
        usage
        exit 0
    fi

    local command="$1"
    shift

    # Ensure database exists for all commands except init
    if [[ "$command" != "init" && "$command" != "help" && "$command" != "--help" && "$command" != "-h" ]]; then
        if [[ ! -f "$PATTERNS_FILE" ]]; then
            init_database
        fi
    fi

    case "$command" in
        capture)
            cmd_capture "$@"
            ;;
        warn)
            cmd_warn "$@"
            ;;
        check)
            cmd_check "$@"
            ;;
        suggest)
            cmd_suggest "$@"
            ;;
        list)
            cmd_list "$@"
            ;;
        show)
            cmd_show "$@"
            ;;
        validate)
            cmd_validate "$@"
            ;;
        init)
            init_database
            ;;
        help|--help|-h)
            usage
            ;;
        *)
            echo -e "${RED}Unknown command: $command${NC}" >&2
            usage
            exit 1
            ;;
    esac
}

main "$@"
