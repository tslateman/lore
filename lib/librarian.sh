#!/usr/bin/env bash
# librarian.sh - Curation loop driver
#
# The librarian turns Lore's manual judgment tasks into a scheduled loop.
# `librarian manifest` emits a deterministic JSON worklist of pending
# curation (raw inbox entries, stale pending decisions, untyped failures,
# graph orphans). `librarian run` pipes that manifest to `claude -p` for
# judgment and executes the returned actions through existing CLI verbs --
# inbox promote/discard, review resolution, graph edge add. Default is
# dry-run; --apply writes.
#
# Unlike agents/lore-resolver.md and agents/lore-cartographer.md (post-hoc
# audits), the librarian drives curation on a schedule.

set -euo pipefail

LORE_DIR="${LORE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "${LORE_DIR}/lib/paths.sh"
source "${LORE_DIR}/lib/lock.sh"

# Colors (inherit from caller if set)
RED="${RED:-\033[0;31m}"
GREEN="${GREEN:-\033[0;32m}"
YELLOW="${YELLOW:-\033[1;33m}"
CYAN="${CYAN:-\033[0;36m}"
BOLD="${BOLD:-\033[1m}"
DIM="${DIM:-\033[2m}"
NC="${NC:-\033[0m}"
if [[ ! -t 1 ]]; then
    RED='' GREEN='' YELLOW='' CYAN='' BOLD='' DIM='' NC=''
fi

LIBRARIAN_MODEL="${LORE_LIBRARIAN_MODEL:-claude-sonnet-5}"
LIBRARIAN_TIMEOUT="${LORE_LIBRARIAN_TIMEOUT:-120}"
LIBRARIAN_OBSERVATIONS_FILE="${LORE_INBOX_DATA}/observations.jsonl"

# jq expression: dedup append-only JSONL by id, latest version wins
_JQ_LATEST='group_by(.id) | map(.[-1])'

# jq expression: age in whole days from an ISO8601 timestamp field
_JQ_AGE='(((now - ((.timestamp // "1970-01-01T00:00:00Z")
    | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601)) / 86400) | floor)'

# --- Manifest sections ---

# Raw inbox entries from both inbox files (obs- legacy + sig- current).
_manifest_inbox() {
    local files=()
    [[ -s "$LIBRARIAN_OBSERVATIONS_FILE" ]] && files+=("$LIBRARIAN_OBSERVATIONS_FILE")
    [[ -s "$LORE_SIGNALS_FILE" ]] && files+=("$LORE_SIGNALS_FILE")
    [[ ${#files[@]} -eq 0 ]] && { echo "[]"; return 0; }
    cat "${files[@]}" | jq -s "
        ${_JQ_LATEST}
        | map(select(.status == \"raw\"))
        | sort_by(.timestamp)
        | map({id, text: .content, tags: (.tags // []),
               source: (.source // \"\"), age_days: ${_JQ_AGE}})
    " 2>/dev/null || echo "[]"
}

# Active decisions with outcome=pending older than N days.
_manifest_stale_decisions() {
    local days="$1"
    [[ -s "$LORE_DECISIONS_FILE" ]] || { echo "[]"; return 0; }
    jq -s --argjson days "$days" "
        ${_JQ_LATEST}
        | map(select((.status // \"active\") == \"active\"
                     and (.outcome // \"pending\") == \"pending\"))
        | map(. + {age_days: ${_JQ_AGE}})
        | map(select(.age_days >= \$days))
        | sort_by(.timestamp)
        | map({id, decision, rationale: (.rationale // \"\"),
               project: (.project // \"\"), type: (.type // \"\"), age_days})
    " "$LORE_DECISIONS_FILE" 2>/dev/null || echo "[]"
}

# Failures with missing or unknown error_type.
_manifest_untyped_failures() {
    local failures_file="${LORE_FAILURES_DATA}/failures.jsonl"
    [[ -s "$failures_file" ]] || { echo "[]"; return 0; }
    jq -s "
        ${_JQ_LATEST}
        | map(select(((.error_type // \"\") | ascii_downcase) as \$t
                     | \$t == \"\" or \$t == \"unknown\"))
        | map({id, description: (.error_message // \"\"),
               context: {tool: (.tool // \"\"), step: (.step // \"\" | tostring)}})
    " "$failures_file" 2>/dev/null || echo "[]"
}

# Graph nodes with no edges, plus a content snippet for judgment.
_manifest_orphans() {
    [[ -s "$LORE_GRAPH_FILE" ]] || { echo "[]"; return 0; }
    jq '
        (.edges | map(.from, .to) | unique) as $connected
        | .nodes | to_entries
        | map(select(.key as $id | ($connected | index($id)) | not))
        | map({id: .key, type: .value.type, label: (.value.name // ""),
               snippet: (((.value.data // {}) | tojson) | .[0:160])})
    ' "$LORE_GRAPH_FILE" 2>/dev/null || echo "[]"
}

# Top-3 FTS5 matches for an orphan, as candidate neighbors.
# Args: orphan JSON object. Prints a JSON array (may be empty).
# Fail-silent: no index or no sqlite3 yields [].
_orphan_candidates() {
    local orphan="$1"
    command -v sqlite3 >/dev/null 2>&1 || { echo "[]"; return 0; }
    [[ -f "$LORE_SEARCH_DB" ]] || { echo "[]"; return 0; }

    local label snippet self_name query
    label=$(echo "$orphan" | jq -r '.label // ""')
    snippet=$(echo "$orphan" | jq -r '.snippet // ""')
    self_name="$label"

    # Build a plain-word query from label + snippet (FTS operators stripped)
    query=$(printf '%s %s' "$label" "$snippet" \
        | tr -cs '[:alnum:]' ' ' | awk '{ for (i=1; i<=NF && i<=8; i++) printf "%s ", $i }')
    query=$(echo "$query" | sed 's/[[:space:]]*$//')
    [[ -z "$query" ]] && { echo "[]"; return 0; }

    # search output: type|id|content|project|timestamp|score (header first)
    local results
    results=$(bash "$LORE_DIR/lib/search-index.sh" search "$query" --limit 6 2>/dev/null) || \
        { echo "[]"; return 0; }

    echo "$results" | awk -F'|' -v self="$self_name" '
        NR > 1 && NF >= 3 && $2 != self && $2 != "" {
            printf "%s\t%s\t%s\n", $1, $2, $3
        }
    ' | head -3 | jq -R -s '
        split("\n") | map(select(length > 0) | split("\t")
        | {type: .[0], id: .[1], snippet: (.[2] // "")[0:120]})
    ' 2>/dev/null || echo "[]"
}

# Emit the full manifest as JSON.
# Usage: librarian_manifest [--days N] [--limit N]
librarian_manifest() {
    local days=30 limit=25 with_candidates=true

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --days)  days="$2"; shift 2 ;;
            --limit) limit="$2"; shift 2 ;;
            --no-candidates) with_candidates=false; shift ;;
            *) echo "Unknown option: $1" >&2; return 1 ;;
        esac
    done

    local inbox stale failures orphans
    inbox=$(_manifest_inbox)
    stale=$(_manifest_stale_decisions "$days")
    failures=$(_manifest_untyped_failures)
    orphans=$(_manifest_orphans)

    # Attach FTS candidates to the included slice of orphans
    local orphans_included="[]"
    if [[ "$(echo "$orphans" | jq 'length')" -gt 0 ]]; then
        local enriched=""
        while IFS= read -r orphan; do
            [[ -z "$orphan" ]] && continue
            local candidates="[]"
            [[ "$with_candidates" == true ]] && candidates=$(_orphan_candidates "$orphan")
            enriched="${enriched}$(echo "$orphan" | jq -c --argjson c "$candidates" '. + {candidates: $c}')
"
        done < <(echo "$orphans" | jq -c --argjson limit "$limit" '.[0:$limit][]')
        orphans_included=$(echo "$enriched" | jq -s '.')
    fi

    jq -n \
        --arg generated_at "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
        --argjson days "$days" \
        --argjson limit "$limit" \
        --argjson inbox "$inbox" \
        --argjson stale "$stale" \
        --argjson failures "$failures" \
        --argjson orphans_total "$(echo "$orphans" | jq 'length')" \
        --argjson orphans "$orphans_included" \
        '{
            generated_at: $generated_at,
            thresholds: {stale_days: $days, limit: $limit},
            inbox: {total: ($inbox | length),
                    included: ($inbox[0:$limit] | length),
                    items: $inbox[0:$limit]},
            stale_decisions: {total: ($stale | length),
                              included: ($stale[0:$limit] | length),
                              items: $stale[0:$limit]},
            untyped_failures: {total: ($failures | length),
                               included: ($failures[0:$limit] | length),
                               items: $failures[0:$limit]},
            orphans: {total: $orphans_total,
                      included: ($orphans | length),
                      items: $orphans}
        }'
}

# --- Target validation ---

# Latest version of an inbox record (obs- or sig-), empty if absent.
_librarian_inbox_record() {
    local id="$1" file=""
    case "$id" in
        obs-*) file="$LIBRARIAN_OBSERVATIONS_FILE" ;;
        sig-*) file="$LORE_SIGNALS_FILE" ;;
        *) return 0 ;;
    esac
    [[ -f "$file" ]] || return 0
    jq -c --arg id "$id" 'select(.id == $id)' "$file" 2>/dev/null | tail -1 || true
}

_librarian_decision_exists() {
    local id="$1"
    [[ -s "$LORE_DECISIONS_FILE" ]] || return 1
    jq -e --arg id "$id" -s 'map(select(.id == $id)) | length > 0' \
        "$LORE_DECISIONS_FILE" >/dev/null 2>&1
}

_librarian_failure_record() {
    local id="$1"
    local failures_file="${LORE_FAILURES_DATA}/failures.jsonl"
    [[ -f "$failures_file" ]] || return 0
    jq -c --arg id "$id" 'select(.id == $id)' "$failures_file" 2>/dev/null | tail -1 || true
}

# Node exists by id or name.
_librarian_node_exists() {
    local ref="$1"
    [[ -s "$LORE_GRAPH_FILE" ]] || return 1
    jq -e --arg ref "$ref" \
        '(.nodes[$ref] != null) or ([.nodes | to_entries[] | select(.value.name == $ref)] | length > 0)' \
        "$LORE_GRAPH_FILE" >/dev/null 2>&1
}

# --- Write helpers (append-only, latest version wins) ---

# Mark an inbox record promoted or discarded. Generalizes
# inbox/lib/inbox.sh signal_promote/signal_discard to both inbox files
# and pattern targets. Same record shape, same locked append.
# Usage: _librarian_inbox_mark <id> promoted <target> <target_type>
#        _librarian_inbox_mark <id> discarded "" "" <reason>
_librarian_inbox_mark() {
    local id="$1" status="$2" target="${3:-}" target_type="${4:-}" reason="${5:-}"
    local file
    case "$id" in
        obs-*) file="$LIBRARIAN_OBSERVATIONS_FILE" ;;
        sig-*) file="$LORE_SIGNALS_FILE" ;;
        *) echo "Error: Unknown inbox id format: $id" >&2; return 1 ;;
    esac

    local existing
    existing=$(_librarian_inbox_record "$id")
    [[ -z "$existing" ]] && { echo "Error: $id not found" >&2; return 1; }

    local current
    current=$(echo "$existing" | jq -r '.status')
    [[ "$current" != "raw" ]] && \
        { echo "Error: $id already has status '$current'" >&2; return 1; }

    local ts updated
    ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    if [[ "$status" == "promoted" ]]; then
        updated=$(echo "$existing" | jq -c \
            --arg target "$target" --arg tt "$target_type" --arg ts "$ts" \
            '. + {status: "promoted", promoted_to: $tt, promoted_target: $target, promoted_at: $ts}')
    else
        updated=$(echo "$existing" | jq -c \
            --arg reason "$reason" --arg ts "$ts" \
            '. + {status: "discarded", discard_reason: $reason, discarded_at: $ts}')
    fi
    lore_locked_append "$file" "$updated"
}

# Retype a failure: append a new version with the corrected error_type.
_librarian_retype_failure() {
    local id="$1" new_type="$2" reason="${3:-}"
    local failures_file="${LORE_FAILURES_DATA}/failures.jsonl"

    source "${LORE_DIR}/failures/lib/failures.sh"
    validate_error_type "$new_type" || return 1

    local existing
    existing=$(_librarian_failure_record "$id")
    [[ -z "$existing" ]] && { echo "Error: $id not found" >&2; return 1; }

    local ts updated
    ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    updated=$(echo "$existing" | jq -c \
        --arg t "$new_type" --arg ts "$ts" --arg reason "$reason" \
        '. + {error_type: $t, retyped_at: $ts}
         + (if $reason != "" then {retype_reason: $reason} else {} end)')
    lore_locked_append "$failures_file" "$updated"
}

# Create the promotion target via JSON I/O, then mark the inbox record.
# On duplicate, marks the record promoted to the existing entry.
# Args: action JSON. Prints the target id.
_librarian_apply_promote() {
    local action="$1"
    local id target_type
    id=$(echo "$action" | jq -r '.id')
    target_type=$(echo "$action" | jq -r '.target_type // "decision"')

    local payload
    case "$target_type" in
        decision)
            payload=$(echo "$action" | jq -c \
                '{decision: (.text // .title // ""), rationale: (.rationale // .reason // ""),
                  tags: (.tags // "librarian")}')
            ;;
        pattern)
            payload=$(echo "$action" | jq -c \
                '{name: (.name // .title // ""), solution: (.solution // .text // ""),
                  context: (.context // ""), problem: (.problem // "")}
                 | with_entries(select(.value != ""))')
            ;;
        *)
            echo "Error: target_type must be decision or pattern" >&2
            return 1
            ;;
    esac

    local resp target_id
    resp=$(echo "$payload" | "$LORE_DIR/lore.sh" capture --json 2>/dev/null) || true
    if [[ -z "$resp" ]]; then
        echo "Error: capture returned no response" >&2
        return 1
    fi

    if [[ "$(echo "$resp" | jq -r '.ok')" == "true" ]]; then
        target_id=$(echo "$resp" | jq -r '.id')
    else
        # Duplicate: promote to the existing entry instead
        target_id=$(echo "$resp" | jq -r '.existing_id // ""')
        if [[ -z "$target_id" ]]; then
            echo "Error: capture failed: $(echo "$resp" | jq -r '.error // "unknown"')" >&2
            return 1
        fi
    fi

    _librarian_inbox_mark "$id" promoted "$target_id" "$target_type"
    echo "$target_id"
}

# --- Action processing ---

# Validate and (dry-run print | apply) a single action.
# Returns 0 = handled, 1 = skipped as invalid.
_librarian_handle_action() {
    local action="$1" apply="$2"
    local act id reason
    act=$(echo "$action" | jq -r '.action // ""')
    id=$(echo "$action" | jq -r '.id // ""')
    reason=$(echo "$action" | jq -r '.reason // ""')

    case "$act" in
        promote_observation)
            local rec
            rec=$(_librarian_inbox_record "$id")
            if [[ -z "$rec" || "$(echo "$rec" | jq -r '.status')" != "raw" ]]; then
                echo -e "  ${YELLOW}skip${NC} promote_observation ${id}: not found or not raw"
                return 1
            fi
            local tt
            tt=$(echo "$action" | jq -r '.target_type // "decision"')
            if [[ "$apply" == true ]]; then
                local target_id
                if target_id=$(_librarian_apply_promote "$action"); then
                    echo -e "  ${GREEN}promoted${NC} ${id} -> ${tt} ${target_id} ${DIM}(${reason})${NC}"
                else
                    echo -e "  ${YELLOW}skip${NC} promote_observation ${id}: capture failed"
                    return 1
                fi
            else
                echo -e "  ${CYAN}would promote${NC} ${id} -> ${tt} ${DIM}(${reason})${NC}"
            fi
            ;;
        discard_observation)
            local rec
            rec=$(_librarian_inbox_record "$id")
            if [[ -z "$rec" || "$(echo "$rec" | jq -r '.status')" != "raw" ]]; then
                echo -e "  ${YELLOW}skip${NC} discard_observation ${id}: not found or not raw"
                return 1
            fi
            if [[ "$apply" == true ]]; then
                _librarian_inbox_mark "$id" discarded "" "" "$reason" >/dev/null
                echo -e "  ${GREEN}discarded${NC} ${id} ${DIM}(${reason})${NC}"
            else
                echo -e "  ${CYAN}would discard${NC} ${id} ${DIM}(${reason})${NC}"
            fi
            ;;
        set_failure_type)
            local new_type rec
            new_type=$(echo "$action" | jq -r '.error_type // ""')
            rec=$(_librarian_failure_record "$id")
            if [[ -z "$rec" ]]; then
                echo -e "  ${YELLOW}skip${NC} set_failure_type ${id}: not found"
                return 1
            fi
            if [[ "$apply" == true ]]; then
                if _librarian_retype_failure "$id" "$new_type" "$reason" 2>/dev/null; then
                    echo -e "  ${GREEN}retyped${NC} ${id} -> ${new_type} ${DIM}(${reason})${NC}"
                else
                    echo -e "  ${YELLOW}skip${NC} set_failure_type ${id}: invalid type '${new_type}'"
                    return 1
                fi
            else
                echo -e "  ${CYAN}would retype${NC} ${id} -> ${new_type} ${DIM}(${reason})${NC}"
            fi
            ;;
        resolve_decision)
            local outcome lesson
            outcome=$(echo "$action" | jq -r '.outcome // ""')
            lesson=$(echo "$action" | jq -r '.lesson // ""')
            if ! _librarian_decision_exists "$id"; then
                echo -e "  ${YELLOW}skip${NC} resolve_decision ${id}: not found"
                return 1
            fi
            case "$outcome" in
                successful|revised|abandoned) ;;
                *)
                    echo -e "  ${YELLOW}skip${NC} resolve_decision ${id}: invalid outcome '${outcome}'"
                    return 1
                    ;;
            esac
            if [[ "$apply" == true ]]; then
                local resolve_args=(review --resolve "$id" --outcome "$outcome")
                [[ -n "$lesson" ]] && resolve_args+=(--lesson "$lesson")
                if "$LORE_DIR/lore.sh" "${resolve_args[@]}" >/dev/null 2>&1; then
                    echo -e "  ${GREEN}resolved${NC} ${id} -> ${outcome} ${DIM}(${reason})${NC}"
                else
                    echo -e "  ${YELLOW}skip${NC} resolve_decision ${id}: resolution failed"
                    return 1
                fi
            else
                echo -e "  ${CYAN}would resolve${NC} ${id} -> ${outcome} ${DIM}(${reason})${NC}"
            fi
            ;;
        add_edge)
            local from to relation
            from=$(echo "$action" | jq -r '.from // ""')
            to=$(echo "$action" | jq -r '.to // ""')
            relation=$(echo "$action" | jq -r '.relation // .type // "relates_to"')
            if ! _librarian_node_exists "$from"; then
                echo -e "  ${YELLOW}skip${NC} add_edge: node not found '${from}'"
                return 1
            fi
            if ! _librarian_node_exists "$to"; then
                echo -e "  ${YELLOW}skip${NC} add_edge: node not found '${to}'"
                return 1
            fi
            if [[ "$apply" == true ]]; then
                if "$LORE_DIR/graph/graph.sh" connect "$from" "$to" "$relation" >/dev/null 2>&1; then
                    echo -e "  ${GREEN}connected${NC} ${from} -> ${to} [${relation}] ${DIM}(${reason})${NC}"
                else
                    echo -e "  ${YELLOW}skip${NC} add_edge ${from} -> ${to}: connect failed"
                    return 1
                fi
            else
                echo -e "  ${CYAN}would connect${NC} ${from} -> ${to} [${relation}] ${DIM}(${reason})${NC}"
            fi
            ;;
        *)
            echo -e "  ${YELLOW}skip${NC} unknown action '${act}'"
            return 1
            ;;
    esac
    return 0
}

# Process a JSON array of actions.
# Args: actions-json apply(true|false)
_librarian_process_actions() {
    local actions="$1" apply="$2"
    local total handled=0 skipped=0

    total=$(echo "$actions" | jq 'length' 2>/dev/null) || total=0
    if [[ "$total" -eq 0 ]]; then
        echo -e "${DIM}No actions proposed.${NC}"
        return 0
    fi

    local mode="Proposed actions (dry-run)"
    [[ "$apply" == true ]] && mode="Applying actions"
    echo -e "${BOLD}${mode}:${NC}"

    while IFS= read -r action; do
        [[ -z "$action" ]] && continue
        if _librarian_handle_action "$action" "$apply"; then
            handled=$((handled + 1))
        else
            skipped=$((skipped + 1))
        fi
    done < <(echo "$actions" | jq -c '.[]')

    echo ""
    if [[ "$apply" == true ]]; then
        echo -e "Applied: ${BOLD}${handled}${NC}  Skipped: ${skipped}"
        echo -e "${DIM}Run \`lore index build\` to refresh the search index.${NC}"
    else
        echo -e "Valid: ${BOLD}${handled}${NC}  Invalid: ${skipped}"
        echo -e "${DIM}Re-run with --apply to execute.${NC}"
    fi
}

# The strict prompt sent to the model along with the manifest.
_librarian_prompt() {
    cat <<'PROMPT'
You are the Lore librarian. Below is a JSON manifest of pending curation
work. Respond with ONLY a JSON array of actions -- no prose, no markdown
fences. Each element must be one of:

{"action":"promote_observation","id":"<obs-/sig- id>","target_type":"decision","text":"...","rationale":"...","tags":"a,b","reason":"..."}
{"action":"promote_observation","id":"<obs-/sig- id>","target_type":"pattern","name":"...","solution":"...","context":"...","reason":"..."}
{"action":"discard_observation","id":"<obs-/sig- id>","reason":"..."}
{"action":"set_failure_type","id":"<fail- id>","error_type":"ToolError|Timeout|PermissionError|LogicError|EnvironmentError|UserError|NonZeroExit|UserDeny|HardDeny","reason":"..."}
{"action":"resolve_decision","id":"<dec- id>","outcome":"successful|revised|abandoned","lesson":"...","reason":"..."}
{"action":"add_edge","from":"<node id>","to":"<node id>","relation":"relates_to|part_of|supersedes|derived_from|references|contradicts","reason":"..."}

Triage rules:
- Promote observations that state a durable decision, pattern, or failure.
- Discard ephemera, test noise, and duplicates.
- Type failures from the message and tool context.
- Resolve decisions only when the manifest text makes the outcome clear.
- Add edges only where a real semantic relationship exists between the
  orphan and a candidate. Never force edges. When unsure, omit the item.

Manifest:
PROMPT
}

# Ask claude for actions, with a hard timeout. Prints raw model output.
_librarian_ask_claude() {
    local manifest="$1"
    printf '%s\n%s\n' "$(_librarian_prompt)" "$manifest" \
        | perl -e "alarm ${LIBRARIAN_TIMEOUT}; exec @ARGV" \
            claude -p --model "$LIBRARIAN_MODEL" 2>/dev/null
}

# Extract a JSON array from model output (tolerates markdown fences).
_librarian_extract_actions() {
    local raw="$1"
    local stripped
    stripped=$(printf '%s\n' "$raw" | sed '/^```/d')
    if echo "$stripped" | jq -e 'type == "array"' >/dev/null 2>&1; then
        echo "$stripped" | jq -c '.'
        return 0
    fi
    return 1
}

# Run one curation cycle: manifest -> claude -> actions.
# Usage: librarian_run [--apply] [--days N] [--limit N]
librarian_run() {
    local apply=false days=30 limit=25

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --apply) apply=true; shift ;;
            --days)  days="$2"; shift 2 ;;
            --limit) limit="$2"; shift 2 ;;
            *) echo "Unknown option: $1" >&2; return 1 ;;
        esac
    done

    local manifest
    manifest=$(librarian_manifest --days "$days" --limit "$limit")

    local pending
    pending=$(echo "$manifest" | jq \
        '.inbox.total + .stale_decisions.total + .untyped_failures.total + .orphans.total')
    if [[ "$pending" -eq 0 ]]; then
        echo -e "${GREEN}Nothing to curate.${NC}"
        return 0
    fi

    if ! command -v claude >/dev/null 2>&1; then
        echo -e "${YELLOW}claude CLI not found -- printing manifest for a manual pass.${NC}" >&2
        echo "$manifest"
        echo -e "${DIM}Apply judgments via: lore capture / lore review --resolve / lore graph connect${NC}" >&2
        return 0
    fi

    local raw
    if ! raw=$(_librarian_ask_claude "$manifest"); then
        echo -e "${YELLOW}claude call failed or timed out -- printing manifest for a manual pass.${NC}" >&2
        echo "$manifest"
        return 0
    fi

    local actions
    if ! actions=$(_librarian_extract_actions "$raw"); then
        echo -e "${YELLOW}Model returned no parseable action list -- printing manifest.${NC}" >&2
        echo "$manifest"
        return 0
    fi

    _librarian_process_actions "$actions" "$apply"
}

librarian_usage() {
    cat <<'EOF'
Usage: lore librarian <command> [options]

Commands:
  manifest [--days N] [--limit N]   Emit JSON worklist of pending curation
  run [--apply] [--days N] [--limit N]
                                    Triage via claude -p (dry-run by default)

Options:
  --days N    Stale-decision age threshold in days (default 30)
  --limit N   Max items per manifest section (default 25)
  --apply     Execute proposed actions (run only)

Environment:
  LORE_LIBRARIAN_MODEL    Model for `run` (default claude-sonnet-5)
  LORE_LIBRARIAN_TIMEOUT  Seconds before the claude call is killed (default 120)
EOF
}

librarian_main() {
    local sub="${1:-manifest}"
    shift 2>/dev/null || true
    case "$sub" in
        manifest)      librarian_manifest "$@" ;;
        run)           librarian_run "$@" ;;
        help|-h|--help) librarian_usage ;;
        *)
            echo -e "${RED}Unknown librarian command: ${sub}${NC}" >&2
            librarian_usage >&2
            return 1
            ;;
    esac
}
