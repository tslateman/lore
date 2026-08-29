#!/usr/bin/env bash
# Standards -- normative clauses addressable at clause granularity
# Part of the Lore memory system for AI agents

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../lib/paths.sh"
source "${SCRIPT_DIR}/../../lib/lock.sh"

DATA_DIR="${LORE_STANDARDS_DATA}"
STANDARDS_FILE="${LORE_STANDARDS_FILE}"
CLAUSES_FILE="${LORE_CLAUSES_FILE}"

VALID_LEVELS="MUST MUST_NOT SHOULD SHOULD_NOT MAY"
VALID_ENFORCEMENT="advisory blocking"

init_standards() {
    mkdir -p "$DATA_DIR"
    touch "$STANDARDS_FILE" "$CLAUSES_FILE"
}

normalize_level() {
    echo "$1" | tr '[:lower:] ' '[:upper:]_'
}

validate_level() {
    local level="$1"
    for valid in $VALID_LEVELS; do
        [[ "$level" == "$valid" ]] && return 0
    done
    echo "Error: Unknown level '$level'" >&2
    echo "Valid levels: $VALID_LEVELS" >&2
    return 1
}

validate_enforcement() {
    local enforcement="$1"
    for valid in $VALID_ENFORCEMENT; do
        [[ "$enforcement" == "$valid" ]] && return 0
    done
    echo "Error: Unknown enforcement '$enforcement'" >&2
    echo "Valid enforcement: $VALID_ENFORCEMENT" >&2
    return 1
}

latest_records() {
    local file="$1"
    if [[ ! -s "$file" ]]; then
        echo "[]"
        return 0
    fi
    jq -s 'group_by(.id) | map(.[-1])' "$file"
}

next_standard_id() {
    local highest
    highest=$(latest_records "$STANDARDS_FILE" \
        | jq -r 'map(.id | ltrimstr("STD-") | tonumber) | max // 0')
    printf "STD-%04d" "$((highest + 1))"
}

next_clause_id() {
    local standard_id="$1"
    local highest
    highest=$(latest_records "$CLAUSES_FILE" \
        | jq -r --arg s "$standard_id" \
            '[.[] | select(.standard_id == $s) | .id | split(".")[1] | tonumber] | max // 0')
    echo "${standard_id}.$((highest + 1))"
}

standards_new() {
    local title="$1"; shift
    local applies_to="" owner=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --applies-to) applies_to="$2"; shift 2 ;;
            --owner) owner="$2"; shift 2 ;;
            *) echo "Error: Unknown option: $1" >&2; return 1 ;;
        esac
    done

    if [[ -z "$title" ]]; then
        echo "Error: title required" >&2
        return 1
    fi

    init_standards

    local id timestamp record
    id=$(next_standard_id)
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    record=$(jq -c -n \
        --arg id "$id" \
        --arg title "$title" \
        --arg owner "$owner" \
        --arg timestamp "$timestamp" \
        --arg applies_to "$applies_to" \
        '{
            id: $id,
            title: $title,
            applies_to: ($applies_to | split(",") | map(select(. != ""))),
            owner: $owner,
            status: "active",
            created_at: $timestamp
        }')

    lore_locked_append "$STANDARDS_FILE" "$record"
    echo "$id"
}

standards_add() {
    local standard_id="$1"; shift
    local level; level=$(normalize_level "$1"); shift
    local text="$1"; shift
    local applies_to="" supersedes="" enforcement="advisory" pattern=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --applies-to) applies_to="$2"; shift 2 ;;
            --supersedes) supersedes="$2"; shift 2 ;;
            --enforcement) enforcement="$2"; shift 2 ;;
            --pattern) pattern="$2"; shift 2 ;;
            *) echo "Error: Unknown option: $1" >&2; return 1 ;;
        esac
    done

    if [[ -z "$standard_id" || -z "$text" ]]; then
        echo "Error: standard id and clause text required" >&2
        return 1
    fi

    validate_level "$level" || return 1
    validate_enforcement "$enforcement" || return 1

    if [[ -n "$pattern" ]]; then
        local grep_status=0
        printf '' | grep -qE -- "$pattern" >/dev/null 2>&1 || grep_status=$?
        if [[ "$grep_status" -gt 1 ]]; then
            echo "Error: --pattern is not a valid extended regular expression" >&2
            return 1
        fi
    fi

    init_standards

    local parent
    parent=$(latest_records "$STANDARDS_FILE" | jq -c --arg s "$standard_id" '.[] | select(.id == $s)')
    if [[ -z "$parent" ]]; then
        echo "Error: No such standard: $standard_id" >&2
        return 1
    fi

    if [[ -z "$applies_to" ]]; then
        applies_to=$(echo "$parent" | jq -r '.applies_to | join(",")')
    fi

    local id timestamp record
    id=$(next_clause_id "$standard_id")
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    record=$(jq -c -n \
        --arg id "$id" \
        --arg standard_id "$standard_id" \
        --arg standard_title "$(echo "$parent" | jq -r .title)" \
        --arg level "$level" \
        --arg text "$text" \
        --arg applies_to "$applies_to" \
        --arg supersedes "$supersedes" \
        --arg enforcement "$enforcement" \
        --arg pattern "$pattern" \
        --arg timestamp "$timestamp" \
        '{
            id: $id,
            standard_id: $standard_id,
            standard_title: $standard_title,
            level: $level,
            text: $text,
            applies_to: ($applies_to | split(",") | map(select(. != ""))),
            status: "active",
            enforcement: $enforcement,
            pattern: (if $pattern == "" then null else $pattern end),
            supersedes: (if $supersedes == "" then null else $supersedes end),
            superseded_by: null,
            created_at: $timestamp
        }')

    lore_locked_append "$CLAUSES_FILE" "$record"

    if [[ -n "$supersedes" ]]; then
        mark_superseded "$supersedes" "$id"
    fi

    echo "$id"
}

mark_superseded() {
    local old_id="$1"
    local new_id="$2"
    local current timestamp updated

    current=$(latest_records "$CLAUSES_FILE" | jq -c --arg c "$old_id" '.[] | select(.id == $c)')
    if [[ -z "$current" ]]; then
        echo "Error: No such clause: $old_id" >&2
        return 1
    fi

    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    updated=$(echo "$current" | jq -c --arg by "$new_id" --arg ts "$timestamp" \
        '. + {status: "superseded", superseded_by: $by, status_changed_at: $ts}')
    lore_locked_append "$CLAUSES_FILE" "$updated"
}

standards_enforce() {
    local clause_id="${1:-}"
    local enforcement="${2:-}"
    local current timestamp updated

    if [[ -z "$clause_id" || -z "$enforcement" ]]; then
        echo "Error: clause id and enforcement level required" >&2
        echo "Usage: lore standards enforce <clause-id> <advisory|blocking>" >&2
        return 1
    fi

    validate_enforcement "$enforcement" || return 1
    init_standards

    current=$(latest_records "$CLAUSES_FILE" | jq -c --arg c "$clause_id" '.[] | select(.id == $c)')
    if [[ -z "$current" ]]; then
        echo "Error: No such clause: $clause_id" >&2
        return 1
    fi

    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    updated=$(echo "$current" | jq -c --arg e "$enforcement" --arg ts "$timestamp" \
        '. + {enforcement: $e, enforcement_changed_at: $ts}')
    lore_locked_append "$CLAUSES_FILE" "$updated"
    echo "$clause_id is now $enforcement"
}

standards_retire() {
    local clause_id="$1"
    local current timestamp updated

    init_standards
    current=$(latest_records "$CLAUSES_FILE" | jq -c --arg c "$clause_id" '.[] | select(.id == $c)')
    if [[ -z "$current" ]]; then
        echo "Error: No such clause: $clause_id" >&2
        return 1
    fi

    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    updated=$(echo "$current" | jq -c --arg ts "$timestamp" \
        '. + {status: "retired", status_changed_at: $ts}')
    lore_locked_append "$CLAUSES_FILE" "$updated"
    echo "Retired: $clause_id"
}

standards_list() {
    local filter_tag="" filter_level="" filter_status="active"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --applies-to) filter_tag="$2"; shift 2 ;;
            --level) filter_level=$(normalize_level "$2"); shift 2 ;;
            --status) filter_status="$2"; shift 2 ;;
            --all) filter_status=""; shift ;;
            *) echo "Error: Unknown option: $1" >&2; return 1 ;;
        esac
    done

    init_standards
    latest_records "$CLAUSES_FILE" | jq --arg tag "$filter_tag" --arg level "$filter_level" --arg status "$filter_status" '
        map(select($status == "" or .status == $status))
        | map(select($level == "" or .level == $level))
        | map(select($tag == "" or (.applies_to | index($tag))))
        | sort_by(.id)
    '
}

standards_get() {
    local clause_id="$1"
    init_standards
    latest_records "$CLAUSES_FILE" | jq --arg c "$clause_id" '.[] | select(.id == $c)'
}

standards_lint() {
    init_standards

    local clauses problems
    clauses=$(latest_records "$CLAUSES_FILE")
    problems=$(echo "$clauses" | jq -c '
        (map({key: .id, value: .}) | from_entries) as $by_id
        | [
            (.[] | select(.supersedes != null)
                | select(($by_id[.supersedes] // null) == null)
                | {clause: .id, problem: "supersedes a clause that does not exist", target: .supersedes}),
            (.[] | select(.supersedes != null)
                | select(($by_id[.supersedes].status // "") != "superseded")
                | {clause: .id, problem: "supersedes target is not marked superseded", target: .supersedes}),
            (.[] | select(.superseded_by != null)
                | select(.status != "superseded")
                | {clause: .id, problem: "has superseded_by but status is not superseded", target: .superseded_by}),
            (.[] | select(.status == "superseded")
                | select(.superseded_by == null)
                | {clause: .id, problem: "marked superseded with no replacement", target: null})
          ]
    ')

    local standards_ids orphans
    standards_ids=$(latest_records "$STANDARDS_FILE" | jq -c '[.[].id]')
    orphans=$(echo "$clauses" | jq -c --argjson known "$standards_ids" '
        [.[] | . as $c
             | select(($known | index($c.standard_id)) == null)
             | {clause: $c.id, problem: "belongs to an unknown standard", target: $c.standard_id}]
    ')

    local all
    all=$(jq -c -n --argjson a "$problems" --argjson b "$orphans" '$a + $b')

    echo "$all" | jq .

    local count
    count=$(echo "$all" | jq 'length')
    [[ "$count" -eq 0 ]]
}

standards_stats() {
    init_standards
    jq -c -n \
        --argjson standards "$(latest_records "$STANDARDS_FILE")" \
        --argjson clauses "$(latest_records "$CLAUSES_FILE")" \
        '{
            standards: ($standards | length),
            clauses: ($clauses | length),
            by_level: ($clauses | group_by(.level) | map({key: .[0].level, value: length}) | from_entries),
            by_status: ($clauses | group_by(.status) | map({key: .[0].status, value: length}) | from_entries),
            by_enforcement: ($clauses | map(.enforcement // "advisory") | group_by(.) | map({key: .[0], value: length}) | from_entries),
            with_pattern: ([$clauses[] | select((.pattern // null) != null)] | length)
        }'
}

standards_main() {
    local cmd="${1:-list}"
    [[ $# -gt 0 ]] && shift

    case "$cmd" in
        new)        standards_new "$@" ;;
        add)        standards_add "$@" ;;
        list)       standards_list "$@" ;;
        get)        standards_get "$@" ;;
        enforce)    standards_enforce "$@" ;;
        retire)     standards_retire "$@" ;;
        lint)       standards_lint "$@" ;;
        stats)      standards_stats "$@" ;;
        standards)  init_standards; latest_records "$STANDARDS_FILE" ;;
        *)
            cat >&2 << 'USAGE'
Usage: lore standards <command>

  new "<title>" [--applies-to a,b] [--owner X]     Mint a standard, echo its id
  add <STD-id> <LEVEL> "<text>" [--applies-to a,b] [--supersedes <clause-id>]
                                [--enforcement advisory|blocking] [--pattern <ere>]
  list [--applies-to tag] [--level MUST] [--status active|--all]
  get <clause-id>
  enforce <clause-id> <advisory|blocking>          Set whether findings block
  retire <clause-id>
  lint                                             Exit 1 on corpus rot
  stats
  standards                                        List standard headers

Levels: MUST MUST_NOT SHOULD SHOULD_NOT MAY
Enforcement: advisory (default) | blocking

A --pattern is an extended regular expression that matches the violating form.
Clauses carrying one are decided by grep and never reach a model.
USAGE
            return 1
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    standards_main "$@"
fi
