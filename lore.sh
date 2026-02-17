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

# Infer capture type from command-line flags
# Returns: "decision", "pattern", or "failure"
infer_capture_type() {
    local has_decision_flags=false
    local has_pattern_flags=false
    local has_failure_flags=false
    local explicit_type=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            # Explicit type overrides
            --decision) explicit_type="decision"; shift ;;
            --pattern) explicit_type="pattern"; shift ;;
            --failure) explicit_type="failure"; shift ;;

            # Decision-specific flags
            --rationale|-r|--alternatives|-a|--outcome|--type|-f|--files)
                has_decision_flags=true
                shift 2 ;;

            # Pattern-specific flags
            --solution|--problem|--context|--category|--confidence|--origin)
                has_pattern_flags=true
                shift 2 ;;

            # Failure-specific flags
            --error-type|--tool|--mission|--step)
                has_failure_flags=true
                shift 2 ;;

            # Skip other args
            *) shift ;;
        esac
    done

    # Explicit type wins
    [[ -n "$explicit_type" ]] && { echo "$explicit_type"; return; }

    # Infer from flags (failure > pattern > decision default)
    if [[ "$has_failure_flags" == true ]]; then
        echo "failure"
    elif [[ "$has_pattern_flags" == true ]]; then
        echo "pattern"
    else
        echo "decision"
    fi
}

# Minimal help - fits on one screen
show_help() {
    cat << 'EOF'
Lore - Memory That Compounds

Usage: lore <command> [options]

Session:
  resume              Load context from previous session
  handoff <message>   Capture context for next session
  status              Show current session state
  entire-resume <br>  Resume Entire branch with Lore context

Capture:
  remember <text>     Record a decision (--rationale "why")
  learn <text>        Capture a pattern (--context "when")
  fail <type> <msg>   Log a failure (Timeout, ToolError, etc.)

Query:
  search <query>      Search all components (--smart for semantic)

Run 'lore help' for all commands.
Run 'lore help <topic>' for: capture, search, intent, registry, components
EOF
}

# Full help - all commands
show_help_full() {
    cat << 'EOF'
Lore - Memory That Compounds

Usage: lore <command> [options]

SESSION LIFECYCLE
  resume [session]        Load context from previous session (forks new session)
  handoff <message>       Capture context for next session
  status                  Show current session state
  entire-resume <branch>  Resume Entire branch with Lore context injection

CAPTURE
  remember <text>         Record a decision with rationale
    --rationale, -r       Why this decision was made
    --alternatives, -a    Other options considered
    --tags, -t            Tags for categorization
  learn <text>            Capture a pattern or lesson
    --context             When this pattern applies
    --solution            The approach or fix
    --category            Pattern category
  fail <type> <message>   Log a failure for pattern detection
    Types: Timeout, NonZeroExit, UserDeny, ToolError, LogicError
  observe <text>          Capture raw observation to inbox
  capture <text>          Universal capture (infers type from flags)

QUERY
  search <query>          Search across all components
    --smart               Auto-select semantic if Ollama available
    --semantic            Force semantic search (requires Ollama)
    --hybrid              Combine keyword + semantic
    --graph-depth N       Follow graph edges (0-3)
  context <project>       Gather full context for a project
  suggest <context>       Suggest relevant patterns
  failures [--type T]     List failures
  triggers                Show recurring failures (Rule of Three)

INTENT (Goals, Missions & Tasks)
  goal create <name>      Create a goal
  goal list [--status S]  List goals
  goal show <id>          Show goal details
  mission generate <id>   Generate missions from goal
  mission list            List missions
  task create <title>     Create delegated task
  task list [--status S]  List tasks
  task claim <id>         Claim task for work
  task complete <id>      Complete a task

REGISTRY
  registry show <proj>    Show project details
  registry list           List all projects
  registry validate       Check consistency

MAINTENANCE
  index                   Build/rebuild search index
  validate                Run comprehensive checks
  ingest <p> <t> <file>   Bulk import from external formats

COMPONENTS (direct access)
  journal <cmd>           Decision journal
  patterns <cmd>          Patterns and anti-patterns
  graph <cmd>             Knowledge graph
  transfer <cmd>          Session management
  inbox <cmd>             Observation staging
  intent <cmd>            Goals and missions

Run 'lore help <topic>' for detailed help on:
  capture, search, intent, registry, components
EOF
}

# Topic-specific help
show_help_capture() {
    cat << 'EOF'
CAPTURE COMMANDS

Record decisions, patterns, and failures for future retrieval.

DECISIONS (remember)
  lore remember "Use PostgreSQL" --rationale "Need ACID, team knows it"
  lore remember "REST over GraphQL" -r "Simpler" -a "GraphQL, gRPC"

  Options:
    --rationale, -r <why>       Why this decision was made
    --alternatives, -a <list>   Comma-separated alternatives considered
    --tags, -t <list>           Comma-separated tags
    --type <type>               architecture, implementation, naming, etc.
    --files, -f <list>          Files affected
    --force                     Skip duplicate check

PATTERNS (learn)
  lore learn "Retry with backoff" --context "External APIs" --solution "100ms * 2^n"

  Options:
    --context <when>            When this pattern applies
    --solution <what>           The approach or technique
    --problem <what>            What problem this solves
    --category <cat>            Category (or "anti-pattern")
    --confidence <0-1>          How confident in this pattern

FAILURES (fail)
  lore fail ToolError "Permission denied on /etc/hosts"
  lore fail Timeout "API call exceeded 30s"

  Error types:
    Timeout       Operation exceeded time limit
    NonZeroExit   Command returned non-zero
    UserDeny      User rejected proposed action
    ToolError     Tool execution failed
    LogicError    Logical/validation error

  Options:
    --tool <name>               Tool that failed
    --mission <id>              Related mission ID
    --step <desc>               Step in workflow

OBSERVATIONS (observe)
  lore observe "Users frequently ask about retry logic"

  Raw observations go to inbox for later triage.
EOF
}

show_help_search() {
    cat << 'EOF'
SEARCH COMMANDS

Find knowledge across all Lore components.

BASIC SEARCH
  lore search "authentication"
  lore search "retry logic"

  Searches: journal, patterns, sessions, graph, inbox

SEARCH MODES
  --smart             Auto-select best mode (semantic if Ollama running)
  --semantic          Force semantic search (requires Ollama + nomic-embed-text)
  --hybrid            Combine keyword + semantic with rank fusion

  lore search "error handling" --smart
  lore search "retry logic" --semantic

GRAPH TRAVERSAL
  --graph-depth N     Follow knowledge graph edges (0-3, default 0)

  lore search "auth" --graph-depth 2

  Depth 0: Direct matches only
  Depth 1: Include directly connected concepts
  Depth 2: Two hops from matches
  Depth 3: Maximum traversal

OTHER QUERIES
  lore context <project>    Assemble full context for a project
  lore suggest <text>       Get pattern suggestions for context
  lore failures             List recorded failures
  lore triggers             Show recurring failure patterns (3+ occurrences)

BUILDING THE INDEX
  lore index                Build/rebuild FTS5 search index

  Run after bulk imports or if search seems stale.
EOF
}

show_help_intent() {
    cat << 'EOF'
INTENT COMMANDS

Goals define what you're trying to achieve. Missions break goals into steps.
Tasks enable delegation between agents.

GOALS
  lore goal create "Implement user authentication"
  lore goal list
  lore goal list --status active
  lore goal show <goal-id>

  Status values: draft, active, blocked, completed, cancelled

MISSIONS
  lore mission generate <goal-id>   Generate missions from a goal
  lore mission list

TASKS (Delegation)
  lore task create "Fix auth bug" --description "..." --for backend-agent
  lore task list [--status pending] [--for agent]
  lore task show <task-id>
  lore task claim <task-id>         Mark task as being worked on
  lore task complete <task-id>      Complete with outcome

  Status values: pending, claimed, completed, cancelled

  Tasks differ from missions:
  - Standalone (no required parent goal)
  - Can be claimed by any agent
  - Optimized for agent-to-agent delegation

SPEC MANAGEMENT (SDD Integration)
  lore spec list                    List specs by status
  lore spec context <goal-id>       Full context for a spec
  lore spec assign <goal-id>        Assign spec to current session
  lore spec progress <goal-id>      Update phase (specify/plan/tasks/implement)
  lore spec complete <goal-id>      Mark spec complete with outcome

Specs track work through the specify → plan → tasks → implement lifecycle.
Lore captures the durable knowledge; specs are ephemeral in feature branches.
EOF
}

show_help_registry() {
    cat << 'EOF'
REGISTRY COMMANDS

Project metadata and cross-project relationships.

QUERY
  lore registry list                List all registered projects
  lore registry show <project>      Show project details with context
  lore registry context <project>   Alias for 'show' (deprecated)

VALIDATION
  lore registry validate            Check registry consistency
  lore validate                     Comprehensive validation (all components)

DIRECT ACCESS
  lore registry <subcommand>        Pass through to registry.sh

Registry data lives in:
  registry/data/metadata.yaml       Project metadata
  registry/data/clusters.yaml       Project groupings
  registry/data/relationships.yaml  Cross-project dependencies
  registry/data/contracts.yaml      Interface contracts
EOF
}

show_help_components() {
    cat << 'EOF'
COMPONENTS

Lore has eight components. Each answers one question.

  journal/    "Why did we choose this?"     Decision capture with rationale
  patterns/   "What did we learn?"          Patterns and anti-patterns
  transfer/   "What's next?"                Session handoff and resume
  graph/      "What relates to this?"       Knowledge graph
  inbox/      "What did we notice?"         Raw observation staging
  intent/     "What are we trying to do?"   Goals and missions
  failures/   "What went wrong?"            Failure reports
  registry/   "What exists?"                Project metadata

DIRECT ACCESS
  lore journal <command>            Decision journal commands
  lore patterns <command>           Pattern commands
  lore transfer <command>           Session management
  lore graph <command>              Knowledge graph
  lore inbox <command>              Inbox management
  lore intent <command>             Goals and missions

Run 'lore <component> --help' for component-specific help.

DATA FORMATS
  JSONL    journal, inbox, failures (append-only logs)
  JSON     graph, sessions (structured documents)
  YAML     patterns, goals, missions, registry (human-editable)
EOF
}

# Help command router
cmd_help() {
    local topic="${1:-}"

    case "$topic" in
        "")
            show_help_full
            ;;
        capture|remember|learn|fail|observe)
            show_help_capture
            ;;
        search|query|find)
            show_help_search
            ;;
        intent|goal|goals|mission|missions|spec|task|tasks)
            show_help_intent
            ;;
        registry|project|projects)
            show_help_registry
            ;;
        components|component|journal|patterns|graph|transfer|inbox|failures)
            show_help_components
            ;;
        *)
            echo "Unknown help topic: $topic"
            echo ""
            echo "Available topics:"
            echo "  capture     Decisions, patterns, failures, observations"
            echo "  search      Search modes and options"
            echo "  intent      Goals, missions, specs"
            echo "  registry    Project metadata"
            echo "  components  Direct component access"
            return 1
            ;;
    esac
}

# Quick commands that span components
cmd_remember() {
    local force=false
    local args=()
    local check_text=""
    local skip_next=false
    local pending_flag=""

    for arg in "$@"; do
        if [[ "$skip_next" == true ]]; then
            skip_next=false
            args+=("$arg")
            # Include rationale in similarity check
            [[ "$pending_flag" == "rationale" ]] && check_text="${check_text:+$check_text }$arg"
            pending_flag=""
            continue
        fi
        if [[ "$arg" == "--force" ]]; then
            force=true
        elif [[ "$arg" == "-r" || "$arg" == "--rationale" ]]; then
            args+=("$arg")
            skip_next=true
            pending_flag="rationale"
        elif [[ "$arg" =~ ^(-a|--alternatives|-t|--tags|--type|-f|--files)$ ]]; then
            args+=("$arg")
            skip_next=true
            pending_flag=""
        elif [[ "$arg" == -* ]]; then
            args+=("$arg")
        else
            args+=("$arg")
            check_text="${check_text:+$check_text }$arg"
        fi
    done

    if [[ "$force" == false && -n "$check_text" ]]; then
        source "$LORE_DIR/lib/conflict.sh"
        if ! lore_check_duplicate "decision" "$check_text"; then
            return 1
        fi
    fi

    # Pass --force through to journal.sh so store-level guard is also bypassed
    if [[ "$force" == true ]]; then
        "$LORE_DIR/journal/journal.sh" record "${args[@]}" --force
    else
        "$LORE_DIR/journal/journal.sh" record "${args[@]}"
    fi
}

cmd_learn() {
    local force=false
    local args=()
    local check_text=""
    local skip_next=false
    local pending_flag=""

    for arg in "$@"; do
        if [[ "$skip_next" == true ]]; then
            skip_next=false
            args+=("$arg")
            # Include context and solution in similarity check
            if [[ "$pending_flag" == "context" || "$pending_flag" == "solution" ]]; then
                check_text="${check_text:+$check_text }$arg"
            fi
            pending_flag=""
            continue
        fi
        if [[ "$arg" == "--force" ]]; then
            force=true
        elif [[ "$arg" == "--context" || "$arg" == "--solution" ]]; then
            args+=("$arg")
            skip_next=true
            pending_flag="${arg#--}"
        elif [[ "$arg" =~ ^(--problem|--category|--origin|--example-bad|--example-good)$ ]]; then
            args+=("$arg")
            skip_next=true
            pending_flag=""
        elif [[ "$arg" == -* ]]; then
            args+=("$arg")
        else
            args+=("$arg")
            check_text="${check_text:+$check_text }$arg"
        fi
    done

    if [[ "$force" == false && -n "$check_text" ]]; then
        source "$LORE_DIR/lib/conflict.sh"
        if ! lore_check_duplicate "pattern" "$check_text"; then
            return 1
        fi
    fi

    "$LORE_DIR/patterns/patterns.sh" capture "${args[@]}"
}

# Unified capture command — routes to remember/learn/fail based on flags
cmd_capture() {
    local capture_type
    capture_type=$(infer_capture_type "$@")

    # Strip explicit type flags, pass everything else through
    local args=()
    for arg in "$@"; do
        case "$arg" in
            --decision|--pattern|--failure) continue ;;
            *) args+=("$arg") ;;
        esac
    done

    case "$capture_type" in
        decision)
            cmd_remember "${args[@]}"
            ;;
        pattern)
            cmd_learn "${args[@]}"
            ;;
        failure)
            # cmd_fail expects: <error_type> <message> [--tool T] [--mission M] [--step S]
            # capture uses --error-type <type> as a named flag, so convert it to positional
            local fail_args=()
            local error_type=""
            local skip_next=false
            for arg in "${args[@]}"; do
                if [[ "$skip_next" == true ]]; then
                    skip_next=false
                    error_type="$arg"
                    continue
                fi
                if [[ "$arg" == "--error-type" ]]; then
                    skip_next=true
                    continue
                fi
                fail_args+=("$arg")
            done
            # Prepend error_type as first positional arg (cmd_fail expects it there)
            if [[ -n "$error_type" ]]; then
                cmd_fail "$error_type" "${fail_args[@]}"
            else
                cmd_fail "${fail_args[@]}"
            fi
            ;;
        *)
            echo -e "${RED}Error: Unknown capture type: $capture_type${NC}" >&2
            return 1
            ;;
    esac
}

cmd_handoff() {
    "$LORE_DIR/transfer/transfer.sh" handoff "$@"
}

cmd_resume() {
    "$LORE_DIR/transfer/transfer.sh" resume "$@"
}

SEARCH_DB="${LORE_SEARCH_DB:-$HOME/.lore/search.db}"

# Derive current project from cwd
_derive_project() {
    local workspace_root
    workspace_root="$(dirname "$LORE_DIR")"
    local cwd
    cwd="$(pwd)"
    local project="${cwd#"$workspace_root/"}"
    [[ "$project" == "$cwd" ]] && { echo ""; return; }
    project="${project%%/*}"
    echo "$project"
}

# Log access for reinforcement scoring
_log_access() {
    local db="$1" type="$2" id="$3"
    sqlite3 "$db" \
        "INSERT OR IGNORE INTO access_log (record_type, record_id, accessed_at) VALUES ('$(echo "$type" | sed "s/'/''/g")', '$(echo "$id" | sed "s/'/''/g")', datetime('now'));" \
        2>/dev/null || true
}

# FTS5-based ranked search
_search_fts5() {
    local query="$1"
    local project="$2"
    local limit="${3:-10}"

    # Escape single quotes for SQL
    local safe_query="${query//\'/\'\'}"
    local safe_project="${project//\'/\'\'}"

    local results
    results=$(sqlite3 -separator $'\t' "$SEARCH_DB" <<SQL 2>/dev/null
WITH ranked AS (
    SELECT
        'decision' as type,
        id,
        decision as content,
        project,
        timestamp,
        importance,
        rank * -1 as bm25_score
    FROM decisions WHERE decisions MATCH '${safe_query}'
    UNION ALL
    SELECT
        'pattern' as type,
        id,
        name || ': ' || solution as content,
        'lore' as project,
        timestamp,
        CAST(confidence * 5 AS INT) as importance,
        rank * -1 as bm25_score
    FROM patterns WHERE patterns MATCH '${safe_query}'
    UNION ALL
    SELECT
        'transfer' as type,
        session_id as id,
        handoff as content,
        project,
        timestamp,
        3 as importance,
        rank * -1 as bm25_score
    FROM transfers WHERE transfers MATCH '${safe_query}'
),
frequency AS (
    SELECT
        record_type,
        record_id,
        COUNT(*) as access_count,
        MAX(accessed_at) as last_access
    FROM access_log
    GROUP BY record_type, record_id
)
SELECT
    r.type,
    r.id,
    SUBSTR(r.content, 1, 120),
    r.project,
    SUBSTR(r.timestamp, 1, 10),
    ROUND(
        r.bm25_score
        * (1.0 / (1 + (julianday('now') - julianday(r.timestamp)) / 30))
        * COALESCE(1.0 + (LOG(1 + f.access_count) * 0.15), 1.0)
        * (1.0 + (r.importance / 5.0 * 0.2))
        * COALESCE(1.0 + (0.1 * EXP(-(julianday('now') - julianday(f.last_access)) / 30)), 1.0)
        * CASE WHEN r.project = '${safe_project}' THEN 1.5 ELSE 1.0 END
    , 2) as final_score
FROM ranked r
LEFT JOIN frequency f ON r.type = f.record_type AND r.id = f.record_id
ORDER BY final_score DESC
LIMIT ${limit};
SQL
    ) || true

    if [[ -z "$results" ]]; then
        echo -e "  ${DIM}(no results)${NC}"
        return
    fi

    local graph_depth="${4:-0}"

    if [[ "$graph_depth" -ge 1 ]]; then
        source "$LORE_DIR/lib/graph-traverse.sh"
    fi

    while IFS=$'\t' read -r type id content proj date score; do
        echo -e "  ${GREEN}[${type}]${NC} ${DIM}${id}:${NC} ${content} ${DIM}(score: ${score}, proj: ${proj}, date: ${date})${NC}"
        _log_access "$SEARCH_DB" "$type" "$id"

        # Graph traversal for this result
        if [[ "$graph_depth" -ge 1 ]]; then
            local node_id
            node_id=$(resolve_to_graph_id "$type" "$id" "$content" "$proj") || true
            if [[ -n "$node_id" ]]; then
                local graph_output
                graph_output=$(graph_traverse "$node_id" "$graph_depth") || true
                if [[ -n "$graph_output" ]]; then
                    echo -e "    ${DIM}Graph:${NC}"
                    while IFS= read -r gline; do
                        echo -e "      ${CYAN}${gline}${NC}"
                    done <<< "$graph_output"
                fi
            fi
        fi
    done <<< "$results"
}

# Grep-based fallback search (original behavior)
_search_grep() {
    local query="$1"

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

cmd_search() {
    local query=""
    local graph_depth=0
    local mode="fts"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --graph-depth)
                graph_depth="$2"
                if [[ "$graph_depth" -lt 0 || "$graph_depth" -gt 3 ]]; then
                    echo -e "${RED}Error: --graph-depth must be 0-3${NC}" >&2
                    return 1
                fi
                shift 2
                ;;
            --smart)
                mode="smart"
                shift
                ;;
            --semantic)
                mode="semantic"
                shift
                ;;
            --hybrid)
                mode="hybrid"
                shift
                ;;
            -*)
                echo -e "${RED}Unknown option: $1${NC}" >&2
                echo "Usage: lore search <query> [--smart|--semantic|--hybrid] [--graph-depth 0-3]" >&2
                return 1
                ;;
            *)
                query="$1"
                shift
                ;;
        esac
    done

    if [[ -z "$query" ]]; then
        echo -e "${RED}Error: Search query required${NC}" >&2
        echo "Usage: lore search <query> [--smart|--semantic|--hybrid] [--graph-depth 0-3]" >&2
        return 1
    fi

    local project
    project=$(_derive_project)

    # Smart mode: try hybrid if Ollama available, else fall back to FTS
    if [[ "$mode" == "smart" ]]; then
        if command -v ollama &>/dev/null && ollama list 2>/dev/null | grep -q nomic-embed; then
            mode="hybrid"
        else
            mode="fts"
        fi
    fi

    if [[ -f "$SEARCH_DB" ]]; then
        echo -e "${BOLD}Searching Lore (${mode})...${NC}"
        [[ -n "$project" ]] && echo -e "${DIM}Project boost: ${project}${NC}"
        [[ "$graph_depth" -ge 1 ]] && echo -e "${DIM}Graph depth: ${graph_depth}${NC}"
        echo ""

        if [[ "$mode" == "fts" ]]; then
            _search_fts5 "$query" "$project" 10 "$graph_depth"
        else
            "$LORE_DIR/lib/search-index.sh" search "$query" --mode "$mode" --project "$project" --limit 10
            # Graph expansion for non-FTS modes
            if [[ "$graph_depth" -ge 1 ]]; then
                echo ""
                echo -e "${BOLD}Graph expansion (depth ${graph_depth}):${NC}"
                "$LORE_DIR/lib/search-index.sh" graph "$query" --depth "$graph_depth" --limit 5 2>/dev/null || true
            fi
        fi
    else
        echo -e "${BOLD}Searching Lore (grep fallback — run 'lore index' to enable ranked search)...${NC}"
        echo ""
        _search_grep "$query"
    fi
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

    # Registry metadata (basics, deps, cluster, entry point)
    # Outputs markdown format; errors suppressed if project not in mani
    if "$LORE_DIR/registry/registry.sh" context "$project" 2>/dev/null; then
        echo ""
    else
        # Fallback header if registry unavailable
        echo -e "# ${project}"
        echo ""
    fi

    # Recent decisions
    echo "## Recent Decisions"
    echo ""
    local decisions
    decisions=$("$LORE_DIR/journal/journal.sh" query "$project" --project "$project" 2>/dev/null) || true
    if [[ -n "$decisions" ]]; then
        echo "$decisions"
    else
        echo "(none)"
    fi
    echo ""

    # Relevant patterns
    echo "## Patterns"
    echo ""
    local patterns
    patterns=$("$LORE_DIR/patterns/patterns.sh" suggest "$project" 2>/dev/null) || true
    if [[ -n "$patterns" ]]; then
        echo "$patterns"
    else
        echo "(none)"
    fi
    echo ""

    # Graph relationships
    echo "## Related Concepts"
    echo ""
    local node_id
    node_id=$("$LORE_DIR/graph/graph.sh" list project 2>/dev/null \
        | awk -v p="$project" '{gsub(/\033\[[0-9;]*m/,"")} tolower($3) == tolower(p) { print $1 }')

    if [[ -n "$node_id" ]]; then
        "$LORE_DIR/graph/graph.sh" related "$node_id" --hops 2 2>/dev/null || echo "(no neighbors)"
    else
        echo "(project not in graph)"
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
        capture)    shift; cmd_capture "$@" ;;
        remember)   shift; cmd_remember "$@" ;;
        learn)      shift; cmd_learn "$@" ;;
        handoff)    shift; cmd_handoff "$@" ;;
        resume)     shift; cmd_resume "$@" ;;
        entire-resume) shift; "$LORE_DIR/scripts/entire-resume-with-context.sh" "$@" ;;
        search)     shift; cmd_search "$@" ;;
        suggest)    shift; cmd_suggest "$@" ;;
        context)    shift; cmd_context "$@" ;;
        status)     shift; cmd_status "$@" ;;
        observe)    shift; cmd_observe "$@" ;;
        inbox)      shift; cmd_inbox "$@" ;;
        fail)       shift; cmd_fail "$@" ;;
        failures)   shift; cmd_failures "$@" ;;
        triggers)   shift; cmd_triggers "$@" ;;

        # Top-level commands
        validate)   shift; source "$LORE_DIR/lib/validate.sh"; cmd_validate "$@" ;;
        ingest)     shift; source "$LORE_DIR/lib/ingest.sh"; cmd_ingest "$@" ;;
        index)      shift; bash "$LORE_DIR/lib/search-index.sh" "$@" ;;

        # Component dispatch
        journal)    shift; "$LORE_DIR/journal/journal.sh" "$@" ;;
        graph)      shift; "$LORE_DIR/graph/graph.sh" "$@" ;;
        patterns)   shift; "$LORE_DIR/patterns/patterns.sh" "$@" ;;
        transfer)   shift; "$LORE_DIR/transfer/transfer.sh" "$@" ;;

        # Intent (goals, missions, tasks)
        goal)       shift; source "$LORE_DIR/intent/lib/intent.sh"; intent_goal_main "$@" ;;
        mission)    shift; source "$LORE_DIR/intent/lib/intent.sh"; intent_mission_main "$@" ;;
        task)       shift; source "$LORE_DIR/intent/lib/intent.sh"; intent_task_main "$@" ;;
        intent)     shift; source "$LORE_DIR/intent/lib/intent.sh"
                    case "${1:-}" in
                        export) shift; intent_export_main "$@" ;;
                        *)      echo -e "${RED}Unknown intent command: ${1:-}${NC}" >&2
                                echo "Usage: lore intent export <goal-id> [--format yaml|markdown]" >&2
                                exit 1 ;;
                    esac ;;

        # Spec management (SDD integration)
        spec)       shift; source "$LORE_DIR/intent/lib/spec.sh"; spec_main "$@" ;;

        # Registry (project metadata)
        registry)   shift; source "$LORE_DIR/registry/lib/registry.sh"; registry_main "$@" ;;

        # Help
        -h|--help)  show_help ;;
        help)       shift; cmd_help "$@" ;;

        *)
            echo -e "${RED}Unknown command: $1${NC}" >&2
            show_help >&2
            exit 1
            ;;
    esac
}

main "$@"
