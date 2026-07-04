#!/usr/bin/env bash
# concepts.sh - Concept promotion: cluster detection and concept lifecycle
#
# Provides `lore concepts propose|promote|list`. Concepts are named
# abstractions that group related decisions, patterns, and observations.
# Propose detects candidate clusters with Jaccard word-similarity (the
# same greedy seed-linkage machinery consolidate uses, at a lower
# threshold); promote writes the curated concept to concepts.yaml,
# projects it into the graph with part_of edges, and indexes it in FTS5.
#
# Sourced by lore.sh, which supplies write_concept and
# generate_concept_id. Standalone fallbacks are defined below so the
# library also works when sourced directly (e.g. from tests).

LORE_DIR="${LORE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "${LORE_DIR}/lib/paths.sh"

# Colors (inherit from caller if set)
RED="${RED:-\033[0;31m}"
GREEN="${GREEN:-\033[0;32m}"
YELLOW="${YELLOW:-\033[1;33m}"
CYAN="${CYAN:-\033[0;36m}"
BOLD="${BOLD:-\033[1m}"
DIM="${DIM:-\033[2m}"
NC="${NC:-\033[0m}"

# Stopwords excluded from clustering and name suggestion (mirrors
# cmd_consolidate's list, plus corpus-generic terms).
_CONCEPTS_STOPWORDS='the|and|for|with|that|this|from|are|was|were|been|being|have|has|had|does|did|will|would|could|should|may|might|shall|can|into|through|during|before|after|above|below|between|out|down|off|over|under|again|further|then|once|but|nor|not|yet|both|either|neither|each|every|all|any|few|more|most|other|some|such|only|own|same|than|too|very|just|because|use|used|using|when|where|which|who|whom|why|how|via|per|not|new|now|also|instead|about|its'

# --- Corpus assembly ---

# Collect id<TAB>snippet<TAB>filtered-words rows for all clusterable
# records: active decisions, patterns, promoted observations.
# Records listed in the exclude file (one id per line) are skipped.
# Usage: _concepts_corpus <out_file> <exclude_file>
_concepts_corpus() {
    local out="$1"
    local exclude_file="$2"
    local raw="${out}.raw"
    : > "$out"
    : > "$raw"

    # Decisions: latest version of each id, active only
    if [[ -f "$LORE_DECISIONS_FILE" ]]; then
        jq -rs '
            group_by(.id) | map(.[-1])
            | map(select((.status // "active") == "active"))
            | .[] | [.id, ((.decision // "") + " " + (.rationale // ""))] | @tsv
        ' "$LORE_DECISIONS_FILE" 2>/dev/null >> "$raw" || true
    fi

    # Patterns: name + problem + solution
    if [[ -f "$LORE_PATTERNS_FILE" ]] && command -v yq &>/dev/null; then
        yq -r '
            .patterns[]?
            | [.id, ((.name // "") + " " + (.problem // "") + " " + (.solution // ""))]
            | @tsv
        ' "$LORE_PATTERNS_FILE" 2>/dev/null >> "$raw" || true
    fi

    # Observations: promoted only (curated signal, cheap to include)
    local obs_file="${LORE_INBOX_DATA}/observations.jsonl"
    if [[ -f "$obs_file" ]]; then
        jq -rs '
            group_by(.id) | map(.[-1])
            | map(select(.status == "promoted"))
            | .[] | [.id, (.content // "")] | @tsv
        ' "$obs_file" 2>/dev/null >> "$raw" || true
    fi

    local id text snippet words
    while IFS=$'\t' read -r id text; do
        [[ -z "$id" || -z "$text" ]] && continue
        if [[ -s "$exclude_file" ]] && grep -qx "$id" "$exclude_file" 2>/dev/null; then
            continue
        fi
        snippet=$(printf '%s' "$text" | tr '\t\n' '  ' | cut -c1-80)
        words=$(printf '%s' "$text" | tr '[:upper:]' '[:lower:]' | tr -cs '[:alnum:]' '\n' \
            | awk 'length >= 3' \
            | grep -vE "^(${_CONCEPTS_STOPWORDS})$" \
            | sort -u | paste -s -d ' ' -) || true
        [[ -z "$words" ]] && continue
        printf '%s\t%s\t%s\n' "$id" "$snippet" "$words" >> "$out"
    done < "$raw"
    rm -f "$raw"
}

# Ids already members of a concept (union of grounded_by lists).
_concepts_member_ids() {
    [[ -f "$LORE_CONCEPTS_FILE" ]] || return 0
    command -v yq &>/dev/null || return 0
    yq -r '.concepts[]? | .grounded_by[]?' "$LORE_CONCEPTS_FILE" 2>/dev/null | sort -u || true
}

# --- propose ---

concepts_propose() {
    local min_members=3
    local limit=10
    local threshold=45

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --min-members) min_members="$2"; shift 2 ;;
            --limit)       limit="$2"; shift 2 ;;
            --threshold)   threshold="$2"; shift 2 ;;
            *)
                echo -e "${RED}Unknown option: $1${NC}" >&2
                echo "Usage: lore concepts propose [--min-members N] [--threshold N] [--limit N]" >&2
                return 1
                ;;
        esac
    done

    local tmpdir
    tmpdir=$(mktemp -d)
    # shellcheck disable=SC2064
    trap "rm -rf '$tmpdir'" RETURN

    _concepts_member_ids > "$tmpdir/exclude"
    _concepts_corpus "$tmpdir/corpus" "$tmpdir/exclude"

    local record_count
    record_count=$(wc -l < "$tmpdir/corpus" | tr -d ' ')
    if [[ "$record_count" -lt "$min_members" ]]; then
        echo -e "${YELLOW}Only ${record_count} clusterable records -- nothing to propose.${NC}" >&2
        echo "[]"
        return 0
    fi

    # Greedy seed-linkage clustering (consolidate's algorithm, computed
    # in one awk pass instead of per-pair comm subprocesses).
    # Output: cohesion<TAB>suggested-name<TAB>id1,id2,...
    awk -F'\t' -v T="$threshold" -v MINM="$min_members" '
    {
        n++
        id[n] = $1
        wl[n] = $3
        m = split($3, a, " ")
        for (i = 1; i <= m; i++) w[n, a[i]] = 1
        sz[n] = m
    }
    function jac(x, y,    k, a, i, inter, uni) {
        k = split(wl[x], a, " ")
        inter = 0
        for (i = 1; i <= k; i++) if ((y, a[i]) in w) inter++
        uni = sz[x] + sz[y] - inter
        if (uni == 0) return 0
        return int(inter * 100 / uni)
    }
    END {
        for (i = 1; i <= n; i++) {
            if (assigned[i]) continue
            cnt = 1; mem[1] = i
            for (j = i + 1; j <= n; j++) {
                if (assigned[j]) continue
                if (jac(i, j) >= T) { cnt++; mem[cnt] = j; assigned[j] = 1 }
            }
            assigned[i] = 1
            if (cnt < MINM) continue

            # Cohesion: average pairwise similarity across the cluster
            tot = 0; pairs = 0
            for (p = 1; p <= cnt; p++)
                for (q = p + 1; q <= cnt; q++) { tot += jac(mem[p], mem[q]); pairs++ }
            coh = (pairs > 0) ? int(tot / pairs) : 0

            # Suggested name: top 3 terms by document frequency, each
            # present in at least half the members
            delete df
            delete used
            for (p = 1; p <= cnt; p++) {
                k = split(wl[mem[p]], arr, " ")
                for (q = 1; q <= k; q++) df[arr[q]]++
            }
            name = ""
            for (k = 1; k <= 3; k++) {
                best = ""; bestdf = 0
                for (t in df) {
                    if (t in used) continue
                    if (df[t] > bestdf || (df[t] == bestdf && t < best)) {
                        best = t; bestdf = df[t]
                    }
                }
                if (best == "" || bestdf * 2 < cnt) break
                used[best] = 1
                name = (name == "") ? best : name "-" best
            }
            if (name == "") continue

            ids = id[mem[1]]
            for (p = 2; p <= cnt; p++) ids = ids "," id[mem[p]]
            printf "%d\t%s\t%s\n", coh, name, ids
        }
    }
    ' "$tmpdir/corpus" | sort -t$'\t' -k1,1nr | head -n "$limit" > "$tmpdir/clusters"

    if [[ ! -s "$tmpdir/clusters" ]]; then
        echo -e "${YELLOW}No candidate clusters at threshold ${threshold}% (${record_count} records).${NC}" >&2
        echo "[]"
        return 0
    fi

    # Assemble JSON with member snippets
    local json="[]"
    local cohesion name ids mid snippet members_json
    while IFS=$'\t' read -r cohesion name ids; do
        members_json="[]"
        local old_ifs="$IFS"
        IFS=','
        for mid in $ids; do
            IFS="$old_ifs"
            snippet=$(awk -F'\t' -v id="$mid" '$1 == id { print $2; exit }' "$tmpdir/corpus")
            members_json=$(echo "$members_json" | jq --arg id "$mid" --arg s "$snippet" \
                '. + [{id: $id, snippet: $s}]')
            IFS=','
        done
        IFS="$old_ifs"
        json=$(echo "$json" | jq --arg name "$name" --argjson coh "$cohesion" \
            --argjson members "$members_json" \
            '. + [{name: $name, cohesion: $coh, members: $members}]')
    done < "$tmpdir/clusters"

    # Human summary on stderr, JSON on stdout
    local cluster_count
    cluster_count=$(echo "$json" | jq 'length')
    echo -e "${BOLD}${cluster_count} candidate concept(s)${NC} ${DIM}(threshold ${threshold}%, ${record_count} records)${NC}" >&2
    echo "$json" | jq -r '.[] | "  \(.name)  [\(.members | length) members, cohesion \(.cohesion)%]"' >&2
    echo -e "${DIM}Promote with: lore concepts promote <name> --members id1,id2,...${NC}" >&2

    echo "$json"
}

# --- promote ---

# Validate a member id exists in its source store. Echoes the record
# text on success (used for the default definition), returns 1 if the
# id is unknown.
_concepts_member_text() {
    local mid="$1"
    # Guard: ids are safe to interpolate into query strings
    [[ "$mid" =~ ^[a-z]+-[A-Za-z0-9_-]+$ ]] || return 1
    case "$mid" in
        dec-*)
            [[ -f "$LORE_DECISIONS_FILE" ]] || return 1
            jq -rs --arg id "$mid" '
                map(select(.id == $id)) | if length > 0 then .[-1].decision else empty end
            ' "$LORE_DECISIONS_FILE" 2>/dev/null | grep . || return 1
            ;;
        pat-*)
            [[ -f "$LORE_PATTERNS_FILE" ]] || return 1
            command -v yq &>/dev/null || return 1
            yq -r "((.patterns // []) + (.anti_patterns // []))[] | select(.id == \"$mid\") | .name" \
                "$LORE_PATTERNS_FILE" 2>/dev/null | grep . || return 1
            ;;
        obs-*|sig-*)
            local src="${LORE_INBOX_DATA}/observations.jsonl"
            [[ "$mid" == sig-* ]] && src="${LORE_SIGNALS_FILE}"
            [[ -f "$src" ]] || return 1
            jq -rs --arg id "$mid" '
                map(select(.id == $id)) | if length > 0 then .[-1].content else empty end
            ' "$src" 2>/dev/null | grep . || return 1
            ;;
        *)
            return 1
            ;;
    esac
}

concepts_promote() {
    local name=""
    local members_csv=""
    local definition=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --members)    members_csv="$2"; shift 2 ;;
            --definition) definition="$2"; shift 2 ;;
            -*)
                echo -e "${RED}Unknown option: $1${NC}" >&2
                echo "Usage: lore concepts promote <name> --members id1,id2,... [--definition text]" >&2
                return 1
                ;;
            *)
                if [[ -z "$name" ]]; then
                    name="$1"
                else
                    echo -e "${RED}Unexpected argument: $1${NC}" >&2
                    return 1
                fi
                shift
                ;;
        esac
    done

    if [[ -z "$name" ]]; then
        echo -e "${RED}Error: Concept name required${NC}" >&2
        echo "Usage: lore concepts promote <name> --members id1,id2,... [--definition text]" >&2
        return 1
    fi
    if [[ -z "$members_csv" ]]; then
        echo -e "${RED}Error: --members is required (comma-separated record ids)${NC}" >&2
        return 1
    fi

    # Reject duplicate concept names (case-insensitive)
    if [[ -f "$LORE_CONCEPTS_FILE" ]] && command -v yq &>/dev/null; then
        local name_lower existing_lower
        name_lower=$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')
        existing_lower=$(yq -r '.concepts[]? | .name // ""' "$LORE_CONCEPTS_FILE" 2>/dev/null \
            | tr '[:upper:]' '[:lower:]') || true
        if printf '%s\n' "$existing_lower" | grep -qxF "$name_lower"; then
            echo -e "${RED}Error: Concept '${name}' already exists${NC}" >&2
            return 1
        fi
    fi

    # Split and validate member ids
    local member_arr=()
    local mid
    local old_ifs="$IFS"
    IFS=','
    for mid in $members_csv; do
        IFS="$old_ifs"
        mid=$(printf '%s' "$mid" | tr -d '[:space:]')
        [[ -z "$mid" ]] && { IFS=','; continue; }
        member_arr+=("$mid")
        IFS=','
    done
    IFS="$old_ifs"

    if [[ ${#member_arr[@]} -eq 0 ]]; then
        echo -e "${RED}Error: Member list is empty${NC}" >&2
        return 1
    fi

    local shortest_text=""
    local shortest_len=999999
    local mtext mlen
    for mid in "${member_arr[@]}"; do
        if ! mtext=$(_concepts_member_text "$mid"); then
            echo -e "${RED}Error: Unknown record id: ${mid}${NC}" >&2
            echo "Member ids must exist in journal (dec-*), patterns (pat-*), or inbox (obs-*, sig-*)." >&2
            return 1
        fi
        mlen=${#mtext}
        if [[ "$mlen" -lt "$shortest_len" ]]; then
            shortest_len="$mlen"
            shortest_text="$mtext"
        fi
    done

    [[ -z "$definition" ]] && definition="$shortest_text"
    # write_concept embeds values in a YAML heredoc -- strip double quotes
    name=$(printf '%s' "$name" | tr -d '"')
    definition=$(printf '%s' "$definition" | tr -d '"' | tr '\n' ' ')

    local concept_id
    concept_id=$(write_concept "$(generate_concept_id)" "$name" "$definition" "promotion" "${member_arr[@]}")

    # Project into graph: concept node + part_of edges (synchronous so
    # callers can verify immediately)
    local edge_report=""
    if [[ -x "$LORE_DIR/graph/sync-concepts.sh" || -f "$LORE_DIR/graph/sync-concepts.sh" ]]; then
        edge_report=$(bash "$LORE_DIR/graph/sync-concepts.sh" 2>/dev/null | grep -o '[0-9]* part_of edges' || true)
    fi

    # FTS5 write-through
    local concept_json
    concept_json=$(jq -n --arg id "$concept_id" --arg name "$name" --arg def "$definition" \
        --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
        '{id: $id, name: $name, definition: $def, created_at: $ts}')
    bash "$LORE_DIR/lib/search-index.sh" index-one concept "$concept_json" &>/dev/null || true

    echo -e "${GREEN}Concept created:${NC} ${BOLD}${concept_id}${NC} (${name})"
    echo -e "  Members: ${#member_arr[@]}"
    [[ -n "$edge_report" ]] && echo -e "  Graph: ${edge_report}"
    echo "$concept_id"
}

# --- list ---

concepts_list() {
    local cf="${LORE_CONCEPTS_FILE}"
    if [[ ! -f "$cf" ]] || ! command -v yq &>/dev/null; then
        echo -e "${YELLOW}No concepts recorded.${NC}"
        return 0
    fi

    local count
    count=$(yq '.concepts | length' "$cf" 2>/dev/null) || count=0
    if [[ "$count" -eq 0 ]]; then
        echo -e "${YELLOW}No concepts recorded.${NC}"
        return 0
    fi

    echo -e "${GREEN}Concepts (${count}):${NC}"
    echo ""
    yq -r '
        .concepts[]
        | "  " + .id + "  " + .name
          + "  [" + ((.grounded_by // []) | length | tostring) + " members]"
          + "\n    " + (.definition // "-")
    ' "$cf"
}

# --- dispatcher ---

cmd_concepts() {
    local subcmd="${1:-list}"
    shift || true

    case "$subcmd" in
        propose) concepts_propose "$@" ;;
        promote) concepts_promote "$@" ;;
        list)    concepts_list "$@" ;;
        -h|--help|help)
            cat <<'EOF'
Usage: lore concepts <propose|promote|list>

  propose                 Detect candidate concept clusters (JSON to stdout)
    --min-members N       Minimum cluster size (default: 3)
    --threshold N         Jaccard similarity %, stopwords removed (default: 45)
    --limit N             Max candidates (default: 10)
  promote <name>          Create a concept from existing records
    --members id1,id2,... Member record ids (dec-*, pat-*, obs-*, sig-*)
    --definition "text"   Concept definition (default: shortest member text)
  list                    List concepts with member counts
EOF
            ;;
        *)
            echo -e "${RED}Unknown concepts command: ${subcmd}${NC}" >&2
            echo "Usage: lore concepts <propose|promote|list>" >&2
            return 1
            ;;
    esac
}

# Fallbacks when sourced outside lore.sh
if ! declare -f generate_concept_id >/dev/null 2>&1; then
    generate_concept_id() {
        echo "concept-$(od -An -tx1 -N4 /dev/urandom | tr -d ' \n')"
    }
fi

if ! declare -f write_concept >/dev/null 2>&1; then
    write_concept() {
        local id="$1" name="$2" definition="$3" source="$4"
        shift 4
        local grounded_by=("$@")

        local concepts_file="${LORE_CONCEPTS_FILE}"
        if [[ ! -f "$concepts_file" ]]; then
            mkdir -p "$(dirname "$concepts_file")"
            echo "concepts: []" > "$concepts_file"
        fi

        local timestamp
        timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

        local tmp
        tmp=$(mktemp)
        cat > "$tmp" <<YAML
id: "$id"
name: "$name"
definition: "$definition"
grounded_by: []
created_at: "$timestamp"
source: "$source"
YAML
        local gid
        for gid in "${grounded_by[@]+"${grounded_by[@]}"}"; do
            yq -i ".grounded_by += [\"$gid\"]" "$tmp"
        done

        yq -i ".concepts += [load(\"$tmp\")]" "$concepts_file"
        rm -f "$tmp"

        echo "$id"
    }
fi
