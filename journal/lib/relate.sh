#!/usr/bin/env bash
# Relationship building for decisions - links decisions to files and each other

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/store.sh"

DATA_DIR="${SCRIPT_DIR}/../data"
GRAPH_FILE="${DATA_DIR}/decision_graph.json"

# Initialize the graph file
init_graph() {
    if [[ ! -f "$GRAPH_FILE" ]]; then
        echo '{"nodes": {}, "edges": [], "file_links": {}}' > "$GRAPH_FILE"
    fi
}

# Link a decision to specific files
link_to_files() {
    local decision_id="$1"
    shift
    local files=("$@")

    init_graph

    local graph
    graph=$(cat "$GRAPH_FILE")

    for file in "${files[@]}"; do
        # Normalize file path
        local normalized
        normalized=$(realpath -m "$file" 2>/dev/null || echo "$file")

        # Add to file_links
        graph=$(echo "$graph" | jq --arg id "$decision_id" --arg file "$normalized" '
            .file_links[$file] = ((.file_links[$file] // []) + [$id] | unique)
        ')

        # Also add to decision entities
        update_decision "$decision_id" "entities" \
            "$(get_decision "$decision_id" | jq --arg file "$normalized" '.entities + [$file] | unique')"
    done

    echo "$graph" > "$GRAPH_FILE"
}

# Link two decisions as related
link_decisions() {
    local decision_id1="$1"
    local decision_id2="$2"
    local relationship="${3:-related}"

    init_graph

    # Add edge to graph
    local graph
    graph=$(cat "$GRAPH_FILE")
    graph=$(echo "$graph" | jq --arg id1 "$decision_id1" --arg id2 "$decision_id2" --arg rel "$relationship" '
        .edges += [{from: $id1, to: $id2, type: $rel}] | .edges |= unique
    ')
    echo "$graph" > "$GRAPH_FILE"

    # Update related_decisions in both records
    local current1 current2
    current1=$(get_decision "$decision_id1")
    current2=$(get_decision "$decision_id2")

    if [[ -n "$current1" ]]; then
        update_decision "$decision_id1" "related_decisions" \
            "$(echo "$current1" | jq --arg id "$decision_id2" '.related_decisions + [$id] | unique')"
    fi

    if [[ -n "$current2" ]]; then
        update_decision "$decision_id2" "related_decisions" \
            "$(echo "$current2" | jq --arg id "$decision_id1" '.related_decisions + [$id] | unique')"
    fi
}

# Find decisions related to a file
get_decisions_for_file() {
    local file="$1"
    local normalized
    normalized=$(realpath -m "$file" 2>/dev/null || echo "$file")

    init_graph

    # Check graph file_links
    local ids
    ids=$(jq -r --arg file "$normalized" '.file_links[$file] // [] | .[]' "$GRAPH_FILE" 2>/dev/null)

    # Also search by entity
    local entity_results
    entity_results=$(get_by_entity "$normalized")

    # Merge results
    if [[ -n "$ids" ]]; then
        echo "$ids" | while read -r id; do
            get_decision "$id"
        done | jq -s 'unique_by(.id)'
    else
        echo "$entity_results"
    fi
}

# Find related decisions (graph traversal)
get_related_decisions() {
    local decision_id="$1"
    local depth="${2:-1}"

    local decision
    decision=$(get_decision "$decision_id")

    if [[ -z "$decision" ]]; then
        echo "[]"
        return
    fi

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
    decision=$(get_decision "$decision_id")

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

    init_graph

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
    init_graph

    local graph
    graph=$(cat "$GRAPH_FILE")

    local decisions_data
    decisions_data=$(jq -s 'group_by(.id) | map(.[0])' "$DECISIONS_FILE")

    jq -n --argjson graph "$graph" --argjson decisions "$decisions_data" '
        {
            total_decisions: ($decisions | length),
            total_edges: ($graph.edges | length),
            files_tracked: ($graph.file_links | keys | length),
            relationship_types: ($graph.edges | group_by(.type) | map({key: .[0].type, count: length}) | from_entries),
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

    init_graph

    case "$format" in
        json)
            cat "$GRAPH_FILE"
            ;;
        dot)
            # Export as Graphviz DOT format
            echo "digraph decisions {"
            echo "  rankdir=LR;"
            jq -r '.edges[] | "  \"\(.from)\" -> \"\(.to)\" [label=\"\(.type)\"];"' "$GRAPH_FILE"
            echo "}"
            ;;
        mermaid)
            # Export as Mermaid diagram
            echo "graph LR"
            jq -r '.edges[] | "  \(.from) -->|\(.type)| \(.to)"' "$GRAPH_FILE"
            ;;
        *)
            echo "Unknown format: $format" >&2
            return 1
            ;;
    esac
}
