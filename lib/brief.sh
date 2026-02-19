#!/usr/bin/env bash
# brief.sh - Topic-scoped context assembly for pre-execution briefing

set -euo pipefail

LORE_DIR="${LORE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "${LORE_DIR}/lib/paths.sh"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

[[ ! -t 1 ]] && RED='' GREEN='' YELLOW='' BLUE='' CYAN='' BOLD='' DIM='' NC=''

cmd_brief() {
    local topic="${1:-}"
    if [[ -z "$topic" ]]; then
        echo -e "${RED}Error: Topic required${NC}" >&2
        echo "Usage: lore brief <topic>" >&2
        return 1
    fi

    echo -e "${BOLD}# Brief: ${topic}${NC}"
    echo ""

    _brief_decisions "$topic"
    _brief_patterns "$topic"
    _brief_failures "$topic"
    _brief_graph "$topic"
}

# --- Decisions section ---

_brief_decisions() {
    local topic="$1"
    local decisions_file="${LORE_DECISIONS_FILE}"

    if [[ ! -f "$decisions_file" ]]; then
        echo -e "${BLUE}## Decisions (0)${NC}"
        echo -e "  ${DIM}No decisions file found${NC}"
        echo ""
        return
    fi

    local topic_lower
    topic_lower=$(echo "$topic" | tr '[:upper:]' '[:lower:]')

    # Deduplicate by ID (latest version), filter active, search topic across fields
    local matches
    matches=$(jq -s --arg topic "$topic_lower" '
        group_by(.id) | map(.[-1])[]
        | select((.status // "active") == "active")
        | select(
            ((.decision // "") | ascii_downcase | contains($topic)) or
            ((.rationale // "") | ascii_downcase | contains($topic)) or
            ((.entities // []) | map(ascii_downcase) | any(contains($topic))) or
            ((.tags // []) | map(ascii_downcase) | any(contains($topic)))
        )
    ' -c "$decisions_file" 2>/dev/null) || true

    if [[ -z "$matches" ]]; then
        echo -e "${BLUE}## Decisions (0)${NC}"
        echo -e "  ${DIM}No decisions match \"${topic}\"${NC}"
        echo ""
        return
    fi

    local count
    count=$(echo "$matches" | wc -l | tr -d ' ')
    echo -e "${BLUE}## Decisions (${count})${NC}"

    local now_epoch
    now_epoch=$(date +%s)

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local id outcome spec_quality timestamp decision
        id=$(echo "$line" | jq -r '.id')
        outcome=$(echo "$line" | jq -r '.outcome // "pending"')
        spec_quality=$(echo "$line" | jq -r '.spec_quality // empty')
        timestamp=$(echo "$line" | jq -r '.timestamp // empty')
        decision=$(echo "$line" | jq -r '.decision')

        local age_str=""
        if [[ -n "$timestamp" ]]; then
            local dec_epoch
            dec_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$timestamp" +%s 2>/dev/null || date -d "$timestamp" +%s 2>/dev/null || echo "")
            if [[ -n "$dec_epoch" ]]; then
                local age_days=$(( (now_epoch - dec_epoch) / 86400 ))
                age_str=", ${age_days}d old"
            fi
        fi

        local meta_parts=()
        [[ -n "$spec_quality" ]] && meta_parts+=("spec: ${spec_quality}")
        if [[ -n "$timestamp" && -n "${age_str}" ]]; then
            meta_parts+=("${age_str#, }")
        fi
        local meta=""
        if [[ ${#meta_parts[@]} -gt 0 ]]; then
            local IFS=', '
            meta=" (${meta_parts[*]})"
        fi

        echo -e "  ${CYAN}[${outcome}]${NC} ${BOLD}${id}${NC}${DIM}${meta}${NC}"
        echo -e "    ${decision}"
    done <<< "$matches"

    # Detect contradictions among matched decisions
    _brief_detect_contradictions "$matches"

    echo ""
}

_brief_detect_contradictions() {
    local matches="$1"

    local count
    count=$(echo "$matches" | wc -l | tr -d ' ')
    [[ "$count" -lt 2 ]] && return

    source "${LORE_DIR}/lib/conflict.sh"

    # conflict.sh uses ${VAR:-default} which overrides our empty-string colors.
    # Re-apply terminal detection.
    if [[ ! -t 1 ]]; then
        RED='' GREEN='' YELLOW='' BLUE='' CYAN='' BOLD='' DIM='' NC=''
    fi

    local ids=()
    local texts=()
    local entity_lists=()

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local id text entities
        id=$(echo "$line" | jq -r '.id')
        text=$(echo "$line" | jq -r '(.decision // "") + " " + (.rationale // "")')
        entities=$(_extract_entities_for_conflict "$text")
        ids+=("$id")
        texts+=("$text")
        entity_lists+=("$entities")
    done <<< "$matches"

    local found_contradiction=false
    local i j
    for (( i=0; i<${#ids[@]}; i++ )); do
        for (( j=i+1; j<${#ids[@]}; j++ )); do
            local overlap
            overlap=$(_entity_overlap_count "${entity_lists[$i]}" "${entity_lists[$j]}")
            [[ "$overlap" -lt 2 ]] && continue

            local sim
            sim=$(_jaccard_similarity "${texts[$i]}" "${texts[$j]}")
            [[ "$sim" -ge 30 ]] && continue

            if [[ "$found_contradiction" == false ]]; then
                found_contradiction=true
            fi
            echo -e "  ${YELLOW}Warning: Contradiction: ${ids[$i]} vs ${ids[$j]} share ${overlap} entities but ${sim}% text similarity${NC}"
        done
    done
}

# --- Patterns section ---

_brief_patterns() {
    local topic="$1"
    local patterns_file="${LORE_PATTERNS_FILE}"

    if [[ ! -f "$patterns_file" ]]; then
        echo -e "${BLUE}## Patterns (0)${NC}"
        echo -e "  ${DIM}No patterns file found${NC}"
        echo ""
        return
    fi

    local topic_lower
    topic_lower=$(echo "$topic" | tr '[:upper:]' '[:lower:]')

    # Parse patterns with awk, search case-insensitively
    local matches
    matches=$(awk -v topic="$topic_lower" '
        BEGIN { in_patterns = 0; in_anti = 0 }
        /^patterns:/ { in_patterns = 1; in_anti = 0; next }
        /^anti_patterns:/ { in_patterns = 0; in_anti = 1; next }
        in_patterns && /- id:/ {
            gsub(/.*id: "/, ""); gsub(/".*/, "")
            id = $0; name = ""; context = ""; solution = ""; problem = ""
            confidence = ""; validations = ""
            spec_quality = ""
        }
        in_patterns && /name:/ {
            gsub(/.*name: "/, ""); gsub(/".*/, "")
            name = $0
        }
        in_patterns && /context:/ {
            gsub(/.*context: "/, ""); gsub(/".*/, "")
            context = $0
        }
        in_patterns && /solution:/ {
            gsub(/.*solution: "/, ""); gsub(/".*/, "")
            solution = $0
        }
        in_patterns && /problem:/ {
            gsub(/.*problem: "/, ""); gsub(/".*/, "")
            problem = $0
        }
        in_patterns && /confidence:/ {
            gsub(/.*confidence: /, "")
            confidence = $0 + 0
        }
        in_patterns && /validations:/ {
            gsub(/.*validations: /, "")
            validations = $0 + 0
        }
        in_patterns && /spec_quality:/ {
            gsub(/.*spec_quality: /, "")
            spec_quality = $0 + 0
        }
        in_patterns && /created_at:/ && id != "" {
            # Check if topic matches any searchable field
            n = tolower(name); c = tolower(context); s = tolower(solution); p = tolower(problem)
            if (index(n, topic) > 0 || index(c, topic) > 0 || index(s, topic) > 0 || index(p, topic) > 0) {
                printf "%s\t%s\t%.2f\t%d\t%s\n", id, name, confidence, validations, spec_quality
            }
            id = ""
        }
    ' "$patterns_file" 2>/dev/null) || true

    if [[ -z "$matches" ]]; then
        echo -e "${BLUE}## Patterns (0)${NC}"
        echo -e "  ${DIM}No patterns match \"${topic}\"${NC}"
        echo ""
        return
    fi

    local count
    count=$(echo "$matches" | wc -l | tr -d ' ')
    echo -e "${BLUE}## Patterns (${count})${NC}"

    while IFS=$'\t' read -r id name confidence validations spec_quality; do
        [[ -z "$id" ]] && continue

        local stale_flag=""
        # Flag stale: confidence < 0.3 or validations == 0
        if awk "BEGIN { exit ($confidence < 0.3) ? 0 : 1 }" 2>/dev/null; then
            stale_flag=" ${YELLOW}(stale: low confidence)${NC}"
        elif [[ "$validations" -eq 0 ]]; then
            stale_flag=" ${YELLOW}(stale: 0 validations)${NC}"
        fi

        local spec_str=""
        [[ -n "$spec_quality" && "$spec_quality" != "0" ]] && spec_str=" spec: ${spec_quality},"

        echo -e "  ${CYAN}[${confidence}]${NC} ${BOLD}${id}${NC} - ${name} ${DIM}(${spec_str}${validations} validations)${NC}${stale_flag}"
    done <<< "$matches"

    echo ""
}

# --- Failures section ---

_brief_failures() {
    local topic="$1"
    local failures_file="${LORE_FAILURES_DATA}/failures.jsonl"

    if [[ ! -f "$failures_file" ]]; then
        echo -e "${BLUE}## Failures (0)${NC}"
        echo -e "  ${DIM}No failures file found${NC}"
        echo ""
        return
    fi

    local matching_lines
    matching_lines=$(grep -i "$topic" "$failures_file" 2>/dev/null || true)

    if [[ -z "$matching_lines" ]]; then
        echo -e "${BLUE}## Failures (0)${NC}"
        echo -e "  ${DIM}No failures match \"${topic}\"${NC}"
        echo ""
        return
    fi

    # Group by error_type, show count and sample message
    local grouped
    grouped=$(echo "$matching_lines" | jq -s '
        group_by(.error_type)
        | map({
            error_type: .[0].error_type,
            count: length,
            sample: .[0].error_message
        })
    ' 2>/dev/null) || true

    if [[ -z "$grouped" || "$grouped" == "[]" ]]; then
        echo -e "${BLUE}## Failures (0)${NC}"
        echo ""
        return
    fi

    local total
    total=$(echo "$grouped" | jq 'length' 2>/dev/null || echo 0)
    echo -e "${BLUE}## Failures (${total} types)${NC}"

    local patterns_file="${LORE_PATTERNS_FILE}"

    echo "$grouped" | jq -c '.[]' | while IFS= read -r entry; do
        local error_type count sample
        error_type=$(echo "$entry" | jq -r '.error_type')
        count=$(echo "$entry" | jq -r '.count')
        sample=$(echo "$entry" | jq -r '.sample')

        echo -e "  ${RED}[${error_type}]${NC} ${count} occurrences - \"${sample}\""

        # Check if promoted to anti-pattern
        if [[ -f "$patterns_file" ]]; then
            local promoted
            promoted=$(grep -i "PITFALL.*${error_type}" "$patterns_file" 2>/dev/null || true)
            if [[ -n "$promoted" ]]; then
                echo -e "    ${GREEN}-> Promoted to anti-pattern: PITFALL: ${error_type}${NC}"
            fi
        fi
    done

    echo ""
}

# --- Graph section ---

_brief_graph() {
    local topic="$1"
    local graph_file="${LORE_GRAPH_FILE}"

    if [[ ! -f "$graph_file" ]]; then
        echo -e "${BLUE}## Graph (0 nodes)${NC}"
        echo -e "  ${DIM}No graph file found${NC}"
        echo ""
        return
    fi

    local topic_lower
    topic_lower=$(echo "$topic" | tr '[:upper:]' '[:lower:]')

    # Find matching nodes and their 1-hop neighbors
    local result
    result=$(jq --arg topic "$topic_lower" '
        # Find nodes matching the topic
        .nodes as $nodes |
        .edges as $edges |
        [
            $nodes | to_entries[]
            | select(
                ((.value.name // "") | ascii_downcase | contains($topic)) or
                ((.value.type // "") | ascii_downcase | contains($topic)) or
                ((.value.data.tags // []) | map(ascii_downcase) | any(contains($topic)))
            )
            | .key
        ] as $matching_ids |

        # For each matching node, find edges
        {
            matching_nodes: [
                $matching_ids[] as $id |
                {
                    id: $id,
                    label: ($nodes[$id].name // $nodes[$id].type // $id),
                    type: $nodes[$id].type
                }
            ],
            edges: [
                $edges[] |
                select(
                    (.from as $f | $matching_ids | index($f)) or
                    (.to as $t | $matching_ids | index($t))
                ) |
                {
                    from: .from,
                    from_label: ($nodes[.from].name // .from),
                    to: .to,
                    to_label: ($nodes[.to].name // .to),
                    relation: .relation
                }
            ]
        }
    ' "$graph_file" 2>/dev/null) || true

    if [[ -z "$result" ]]; then
        echo -e "${BLUE}## Graph (0 nodes)${NC}"
        echo ""
        return
    fi

    local node_count
    node_count=$(echo "$result" | jq '.matching_nodes | length' 2>/dev/null || echo 0)

    echo -e "${BLUE}## Graph (${node_count} nodes)${NC}"

    if [[ "$node_count" -eq 0 ]]; then
        echo -e "  ${DIM}No graph nodes match \"${topic}\"${NC}"
        echo ""
        return
    fi

    # Show matching nodes
    echo "$result" | jq -r '.matching_nodes[] | "  \(.id) \"\(.label)\" (\(.type))"' 2>/dev/null || true

    # Show edges
    local edge_count
    edge_count=$(echo "$result" | jq '.edges | length' 2>/dev/null || echo 0)

    if [[ "$edge_count" -gt 0 ]]; then
        echo ""
        echo -e "  ${DIM}Connections:${NC}"
        echo "$result" | jq -r '.edges[] | "  \(.from_label) -> \(.relation) -> \(.to_label)"' 2>/dev/null || true
    fi

    echo ""
}
