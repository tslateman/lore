#!/usr/bin/env bash
# Relationship building for decisions - links decisions to files and each other
# Writes to the main knowledge graph (graph/data/graph.json) via the graph library.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/store.sh"

# Source the main graph library
_LORE_ROOT="${SCRIPT_DIR}/../.."
export GRAPH_DIR="${_LORE_ROOT}/graph"
export GRAPH_FILE="${GRAPH_DIR}/data/graph.json"
# edges.sh sources nodes.sh internally
source "${_LORE_ROOT}/graph/lib/edges.sh"

# Map journal relationship names to valid graph edge types
_map_edge_type() {
    local rel="$1"
    case "$rel" in
        related|shared_entity) echo "relates_to" ;;
        supersedes)            echo "supersedes" ;;
        contradicts)           echo "contradicts" ;;
        depends_on)            echo "depends_on" ;;
        *)                     echo "relates_to" ;;
    esac
}

# Ensure a decision node exists in the main graph.
# Uses the journal decision ID as the node name so lookups stay deterministic.
# Returns the graph node ID on stdout.
_ensure_decision_node() {
    local decision_id="$1"

    local decision_text=""
    local dec_record
    dec_record=$(get_decision "$decision_id" 2>/dev/null || true)
    if [[ -n "$dec_record" ]]; then
        decision_text=$(echo "$dec_record" | jq -r '.decision // ""')
    fi

    local node_data
    node_data=$(jq -n --arg jid "$decision_id" --arg text "$decision_text" \
        '{journal_id: $jid, decision: $text}')

    # add_node prints "Created node: <id>" or "Merged node: <id>" then the id
    local output
    output=$(add_node "decision" "$decision_id" "$node_data" 2>/dev/null) || return 1
    # The last line of output is the node ID
    echo "$output" | tail -1
}

# Ensure a file node exists in the main graph. Returns the graph node ID.
_ensure_file_node() {
    local filepath="$1"

    local basename
    basename=$(basename "$filepath")
    local ext="${basename##*.}"
    local node_data
    node_data=$(jq -n --arg path "$filepath" --arg ext "$ext" \
        '{path: $path, language: $ext}')

    local output
    output=$(add_node "file" "$filepath" "$node_data" 2>/dev/null) || return 1
    echo "$output" | tail -1
}

# Link a decision to specific files
link_to_files() {
    local decision_id="$1"
    shift
    local files=("$@")

    local dec_node_id
    dec_node_id=$(_ensure_decision_node "$decision_id") || true

    if [[ -z "${dec_node_id:-}" ]]; then
        return 1
    fi

    for file in "${files[@]}"; do
        local normalized
        normalized=$(realpath -m "$file" 2>/dev/null || echo "$file")

        local file_node_id
        file_node_id=$(_ensure_file_node "$normalized") || true

        if [[ -n "${file_node_id:-}" ]]; then
            add_edge "$dec_node_id" "$file_node_id" "references" 2>/dev/null || true
        fi

        # Keep decision entities in sync
        update_decision "$decision_id" "entities" \
            "$(get_decision "$decision_id" | jq --arg file "$normalized" '.entities + [$file] | unique')" \
            2>/dev/null || true
    done
}

# Link two decisions as related
link_decisions() {
    local decision_id1="$1"
    local decision_id2="$2"
    local relationship="${3:-related}"

    local node_id1 node_id2
    node_id1=$(_ensure_decision_node "$decision_id1") || true
    node_id2=$(_ensure_decision_node "$decision_id2") || true

    if [[ -n "${node_id1:-}" && -n "${node_id2:-}" ]]; then
        local edge_type
        edge_type=$(_map_edge_type "$relationship")
        add_edge "$node_id1" "$node_id2" "$edge_type" "1.0" "true" 2>/dev/null || true
    fi

    # Update related_decisions in both journal records
    local current1 current2
    current1=$(get_decision "$decision_id1" 2>/dev/null || true)
    current2=$(get_decision "$decision_id2" 2>/dev/null || true)

    if [[ -n "$current1" ]]; then
        update_decision "$decision_id1" "related_decisions" \
            "$(echo "$current1" | jq --arg id "$decision_id2" '.related_decisions + [$id] | unique')" \
            2>/dev/null || true
    fi

    if [[ -n "$current2" ]]; then
        update_decision "$decision_id2" "related_decisions" \
            "$(echo "$current2" | jq --arg id "$decision_id1" '.related_decisions + [$id] | unique')" \
            2>/dev/null || true
    fi
}

# Find decisions related to a file
get_decisions_for_file() {
    local file="$1"
    local normalized
    normalized=$(realpath -m "$file" 2>/dev/null || echo "$file")

    # Look up the file node in the main graph
    local file_node_id
    file_node_id=$(generate_node_id "$normalized" "file")

    local neighbor_ids
    neighbor_ids=$(get_neighbors "$file_node_id" 2>/dev/null || true)

    if [[ -n "$neighbor_ids" ]]; then
        # Resolve neighbor decision nodes back to journal IDs
        local decision_ids=()
        while read -r nid; do
            [[ -z "$nid" ]] && continue
            local node_data
            node_data=$(get_node "$nid" 2>/dev/null || true)
            if [[ -n "$node_data" ]]; then
                local ntype
                ntype=$(echo "$node_data" | jq -r '.type // ""')
                if [[ "$ntype" == "decision" ]]; then
                    local journal_id
                    journal_id=$(echo "$node_data" | jq -r '.data.journal_id // .name')
                    [[ -n "$journal_id" ]] && decision_ids+=("$journal_id")
                fi
            fi
        done <<< "$neighbor_ids"

        if [[ ${#decision_ids[@]} -gt 0 ]]; then
            local results=()
            for did in "${decision_ids[@]}"; do
                local dec
                dec=$(get_decision "$did" 2>/dev/null || true)
                [[ -n "$dec" ]] && results+=("$dec")
            done
            if [[ ${#results[@]} -gt 0 ]]; then
                printf '%s\n' "${results[@]}" | jq -s 'unique_by(.id)'
                return 0
            fi
        fi
    fi

    # Fall back to searching by entity in the journal store
    get_by_entity "$normalized"
}

# Find related decisions (graph traversal)
get_related_decisions() {
    local decision_id="$1"
    local depth="${2:-1}"

    local decision
    decision=$(get_decision "$decision_id" 2>/dev/null || true)

    if [[ -z "$decision" ]]; then
        echo "[]"
        return
    fi

    # Look up decision node in the main graph and traverse
    local dec_node_id
    dec_node_id=$(generate_node_id "$decision_id" "decision")

    local neighbor_ids
    neighbor_ids=$(get_neighbors "$dec_node_id" 2>/dev/null || true)

    if [[ -n "$neighbor_ids" ]]; then
        local results=()
        while read -r nid; do
            [[ -z "$nid" ]] && continue
            local node_data
            node_data=$(get_node "$nid" 2>/dev/null || true)
            if [[ -n "$node_data" ]]; then
                local ntype
                ntype=$(echo "$node_data" | jq -r '.type // ""')
                if [[ "$ntype" == "decision" ]]; then
                    local journal_id
                    journal_id=$(echo "$node_data" | jq -r '.data.journal_id // .name')
                    if [[ -n "$journal_id" && "$journal_id" != "$decision_id" ]]; then
                        local dec
                        dec=$(get_decision "$journal_id" 2>/dev/null || true)
                        [[ -n "$dec" ]] && results+=("$dec")
                    fi
                fi
            fi
        done <<< "$neighbor_ids"

        if [[ ${#results[@]} -gt 0 ]]; then
            printf '%s\n' "${results[@]}" | jq -s '.'
            return 0
        fi
    fi

    # Fall back to related_decisions field from journal records
    local related_ids
    related_ids=$(echo "$decision" | jq -r '.related_decisions[]?')

    if [[ -z "$related_ids" ]]; then
        echo "[]"
        return
    fi

    local results=()
    while read -r id; do
        [[ -n "$id" ]] && results+=("$(get_decision "$id")")
    done <<< "$related_ids"

    printf '%s\n' "${results[@]}" | jq -s '.'
}

# Auto-link decisions based on shared entities
auto_link_by_entities() {
    local decision_id="$1"

    local decision
    decision=$(get_decision "$decision_id" 2>/dev/null || true)

    if [[ -z "$decision" ]]; then
        return
    fi

    local entities
    entities=$(echo "$decision" | jq -r '.entities[]?')

    while read -r entity; do
        [[ -z "$entity" ]] && continue

        # Find other decisions with this entity
        get_by_entity "$entity" | jq -r '.[].id' | while read -r other_id; do
            if [[ "$other_id" != "$decision_id" ]]; then
                link_decisions "$decision_id" "$other_id" "shared_entity"
            fi
        done
    done <<< "$entities"
}

# Find decision chains (sequences of related decisions)
find_decision_chains() {
    local start_id="$1"
    local max_depth="${2:-5}"

    local visited=()
    local chain=()

    _traverse() {
        local current="$1"
        local depth="$2"

        [[ $depth -gt $max_depth ]] && return

        # Check if visited
        for v in "${visited[@]}"; do
            [[ "$v" == "$current" ]] && return
        done

        visited+=("$current")
        chain+=("$current")

        # Get related decisions
        local related
        related=$(get_decision "$current" | jq -r '.related_decisions[]?' 2>/dev/null)

        while read -r next; do
            [[ -n "$next" ]] && _traverse "$next" $((depth + 1))
        done <<< "$related"
    }

    _traverse "$start_id" 0

    # Output chain with full decision data
    for id in "${chain[@]}"; do
        get_decision "$id"
    done | jq -s '.'
}

# Get decision context for a topic (combines search and relations)
get_topic_context() {
    local topic="$1"
    local max_results="${2:-10}"

    # Search for directly matching decisions
    local direct_matches
    direct_matches=$(search_decisions "$topic")

    # Get related decisions for top matches
    local all_decisions
    all_decisions=$(echo "$direct_matches" | jq -r '.[0:3] | .[].id' | while read -r id; do
        [[ -n "$id" ]] && get_related_decisions "$id"
    done | jq -s 'add // []')

    # Combine and deduplicate
    echo "$direct_matches" "$all_decisions" | jq -s '
        add | unique_by(.id) | sort_by(.timestamp) | reverse | .[0:'"$max_results"']
    '
}

# Build a summary of the decision graph
get_graph_summary() {
    local decisions_data
    decisions_data=$(jq -s 'group_by(.id) | map(.[0])' "$DECISIONS_FILE")

    jq -n --slurpfile graph "$GRAPH_FILE" --argjson decisions "$decisions_data" '
        ($graph[0]) as $g |
        {
            total_decisions: ($decisions | length),
            total_edges: ($g.edges | length),
            files_tracked: ([$g.nodes | to_entries[] | select(.value.type == "file")] | length),
            relationship_types: (
                $g.edges |
                group_by(.relation) |
                map({key: .[0].relation, count: length}) |
                from_entries
            ),
            most_connected: (
                $decisions |
                sort_by(.related_decisions | length) |
                reverse |
                .[0:5] |
                map({id: .id, decision: .decision[0:50], connections: (.related_decisions | length)})
            )
        }
    '
}

# Export decision graph for visualization
export_graph() {
    local format="${1:-json}"

    case "$format" in
        json)
            # Filter main graph to decision-related nodes and edges
            jq '{
                nodes: (.nodes | to_entries | map(select(.value.type == "decision" or .value.type == "file")) | from_entries),
                edges: [.edges[] | select(
                    . as $e |
                    any(keys[]; . == "from") and
                    any(keys[]; . == "to")
                )]
            }' "$GRAPH_FILE"
            ;;
        dot)
            echo "digraph decisions {"
            echo "  rankdir=LR;"
            jq -r '.nodes | to_entries[] | "  \"\(.key)\" [label=\"\(.value.name)\"];"' "$GRAPH_FILE"
            jq -r '.edges[] | "  \"\(.from)\" -> \"\(.to)\" [label=\"\(.relation)\"];"' "$GRAPH_FILE"
            echo "}"
            ;;
        mermaid)
            echo "graph LR"
            jq -r '.nodes | to_entries[] | "  \(.key)[\"\(.value.name)\"]"' "$GRAPH_FILE"
            jq -r '.edges[] | "  \(.from) -->|\(.relation)| \(.to)"' "$GRAPH_FILE"
            ;;
        *)
            echo "Unknown format: $format" >&2
            return 1
            ;;
    esac
}
