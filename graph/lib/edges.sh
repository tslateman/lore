#!/usr/bin/env bash
# Edge management for Memory Graph
# Edge types: relates_to, learned_from, affects, supersedes, contradicts,
#   yields, informs, grounds, hosts (and others — see VALID_EDGE_TYPES)

set -euo pipefail

GRAPH_DIR="${GRAPH_DIR:-$(dirname "${BASH_SOURCE[0]}")/..}"
GRAPH_FILE="${GRAPH_DIR}/data/graph.json"

# Source nodes.sh for init_graph
source "$(dirname "${BASH_SOURCE[0]}")/nodes.sh"

# Valid edge types
VALID_EDGE_TYPES=("relates_to" "learned_from" "affects" "supersedes" "contradicts" "contains" "references" "implements" "depends_on" "produces" "consumes" "derived_from" "part_of" "summarized_by" "yields" "informs" "grounds" "hosts")

validate_edge_type() {
    local type="$1"
    for valid in "${VALID_EDGE_TYPES[@]}"; do
        if [[ "$type" == "$valid" ]]; then
            return 0
        fi
    done
    return 1
}

# Add an edge between nodes
# Usage: add_edge <from_id> <to_id> <relation> [weight] [bidirectional]
add_edge() {
    local from="$1"
    local to="$2"
    local relation="$3"
    local weight="${4:-1.0}"
    local bidirectional="${5:-false}"

    if ! validate_edge_type "$relation"; then
        echo "Error: Invalid edge type '$relation'. Valid types: ${VALID_EDGE_TYPES[*]}" >&2
        return 1
    fi

    init_graph

    # Verify nodes exist
    local from_node to_node
    from_node=$(jq -r --arg id "$from" '.nodes[$id] // empty' "$GRAPH_FILE")
    to_node=$(jq -r --arg id "$to" '.nodes[$id] // empty' "$GRAPH_FILE")

    if [[ -z "$from_node" ]]; then
        echo "Error: Source node '$from' not found" >&2
        return 1
    fi

    if [[ -z "$to_node" ]]; then
        echo "Error: Target node '$to' not found" >&2
        return 1
    fi

    local timestamp
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    # Check if edge already exists
    local existing
    existing=$(jq -r --arg from "$from" --arg to "$to" --arg rel "$relation" \
        '.edges[] | select(.from == $from and .to == $to and .relation == $rel) | .from' \
        "$GRAPH_FILE")

    if [[ -n "$existing" ]]; then
        # Update weight of existing edge
        jq --arg from "$from" --arg to "$to" --arg rel "$relation" \
           --argjson weight "$weight" --arg updated "$timestamp" \
           '.edges = [.edges[] | if (.from == $from and .to == $to and .relation == $rel) then .weight = $weight | .updated_at = $updated else . end]' \
           "$GRAPH_FILE" > "${GRAPH_FILE}.tmp" && mv "${GRAPH_FILE}.tmp" "$GRAPH_FILE"
        echo "Updated edge: $from -> $to ($relation)"
    else
        # Add new edge
        jq --arg from "$from" --arg to "$to" --arg rel "$relation" \
           --argjson weight "$weight" --arg created "$timestamp" \
           --argjson bidir "$bidirectional" \
           '.edges += [{from: $from, to: $to, relation: $rel, weight: $weight, bidirectional: $bidir, status: "active", created_at: $created}]' \
           "$GRAPH_FILE" > "${GRAPH_FILE}.tmp" && mv "${GRAPH_FILE}.tmp" "$GRAPH_FILE"
        echo "Created edge: $from -> $to ($relation)"
    fi

    # Add reverse edge if bidirectional
    if [[ "$bidirectional" == "true" ]]; then
        local reverse_existing
        reverse_existing=$(jq -r --arg from "$to" --arg to "$from" --arg rel "$relation" \
            '.edges[] | select(.from == $from and .to == $to and .relation == $rel) | .from' \
            "$GRAPH_FILE")

        if [[ -z "$reverse_existing" ]]; then
            jq --arg from "$to" --arg to "$from" --arg rel "$relation" \
               --argjson weight "$weight" --arg created "$timestamp" \
               '.edges += [{from: $from, to: $to, relation: $rel, weight: $weight, bidirectional: true, status: "active", created_at: $created}]' \
               "$GRAPH_FILE" > "${GRAPH_FILE}.tmp" && mv "${GRAPH_FILE}.tmp" "$GRAPH_FILE"
        fi
    fi

    # Enforce edge semantics for supersedes and contradicts
    if [[ "$relation" == "supersedes" ]]; then
        # Look up the target node's journal_id
        local target_journal_id
        target_journal_id=$(jq -r --arg id "$to" '.nodes[$id].data.journal_id // empty' "$GRAPH_FILE")

        if [[ -n "$target_journal_id" ]]; then
            # Source journal store (guarded to prevent circular imports)
            if [[ -z "${_EDGES_STORE_LOADED:-}" ]]; then
                _EDGES_STORE_LOADED=1
                source "${LORE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}/journal/lib/store.sh"
            fi

            # Look up the source node's journal_id for the superseded_by field
            local source_journal_id
            source_journal_id=$(jq -r --arg id "$from" '.nodes[$id].data.journal_id // empty' "$GRAPH_FILE")

            update_decision "$target_journal_id" "status" "superseded"
            if [[ -n "$source_journal_id" ]]; then
                update_decision "$target_journal_id" "superseded_by" "$source_journal_id"
            fi
            echo "Marked decision ${target_journal_id} as superseded by ${source_journal_id:-$from}"
        fi
    elif [[ "$relation" == "contradicts" ]]; then
        echo "Contradiction registered between ${from} and ${to}. Review with \`lore graph related ${from}\`"
    fi
}

# Remove an edge
delete_edge() {
    local from="$1"
    local to="$2"
    local relation="${3:-}"

    init_graph

    if [[ -n "$relation" ]]; then
        jq --arg from "$from" --arg to "$to" --arg rel "$relation" \
           '.edges = [.edges[] | select(.from != $from or .to != $to or .relation != $rel)]' \
           "$GRAPH_FILE" > "${GRAPH_FILE}.tmp" && mv "${GRAPH_FILE}.tmp" "$GRAPH_FILE"
    else
        jq --arg from "$from" --arg to "$to" \
           '.edges = [.edges[] | select(.from != $from or .to != $to)]' \
           "$GRAPH_FILE" > "${GRAPH_FILE}.tmp" && mv "${GRAPH_FILE}.tmp" "$GRAPH_FILE"
    fi

    echo "Deleted edge: $from -> $to"
}

# Deprecate an edge (soft-delete via status field)
deprecate_edge() {
    local from="$1"
    local to="$2"
    local relation="${3:-}"

    init_graph

    local timestamp
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    if [[ -n "$relation" ]]; then
        jq --arg from "$from" --arg to "$to" --arg rel "$relation" --arg updated "$timestamp" \
           '.edges = [.edges[] | if (.from == $from and .to == $to and .relation == $rel) then .status = "deprecated" | .updated_at = $updated else . end]' \
           "$GRAPH_FILE" > "${GRAPH_FILE}.tmp" && mv "${GRAPH_FILE}.tmp" "$GRAPH_FILE"
    else
        jq --arg from "$from" --arg to "$to" --arg updated "$timestamp" \
           '.edges = [.edges[] | if (.from == $from and .to == $to) then .status = "deprecated" | .updated_at = $updated else . end]' \
           "$GRAPH_FILE" > "${GRAPH_FILE}.tmp" && mv "${GRAPH_FILE}.tmp" "$GRAPH_FILE"
    fi

    echo "Deprecated edge: $from -> $to${relation:+ ($relation)}"
}

# Get all edges from a node
get_outgoing_edges() {
    local from="$1"
    init_graph
    jq -r --arg from "$from" '.edges[] | select(.from == $from) | select((.status // "active") != "deprecated")' "$GRAPH_FILE"
}

# Get all edges to a node
get_incoming_edges() {
    local to="$1"
    init_graph
    jq -r --arg to "$to" '.edges[] | select(.to == $to) | select((.status // "active") != "deprecated")' "$GRAPH_FILE"
}

# Get all edges for a node (both directions)
get_all_edges() {
    local node="$1"
    init_graph
    jq -r --arg node "$node" '.edges[] | select(.from == $node or .to == $node) | select((.status // "active") != "deprecated")' "$GRAPH_FILE"
}

# List all edges
list_edges() {
    local relation="${1:-}"
    init_graph

    if [[ -n "$relation" ]]; then
        jq -r --arg rel "$relation" \
           '.edges[] | select(.relation == $rel) | select((.status // "active") != "deprecated") | "\(.from) -> \(.to) [\(.relation), weight: \(.weight)]"' \
           "$GRAPH_FILE"
    else
        jq -r '.edges[] | select((.status // "active") != "deprecated") | "\(.from) -> \(.to) [\(.relation), weight: \(.weight)]"' "$GRAPH_FILE"
    fi
}

# Update edge weight
update_edge_weight() {
    local from="$1"
    local to="$2"
    local relation="$3"
    local new_weight="$4"

    init_graph

    local timestamp
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    jq --arg from "$from" --arg to "$to" --arg rel "$relation" \
       --argjson weight "$new_weight" --arg updated "$timestamp" \
       '.edges = [.edges[] | if (.from == $from and .to == $to and .relation == $rel) then .weight = $weight | .updated_at = $updated else . end]' \
       "$GRAPH_FILE" > "${GRAPH_FILE}.tmp" && mv "${GRAPH_FILE}.tmp" "$GRAPH_FILE"

    echo "Updated weight: $from -> $to ($relation) = $new_weight"
}

# Get edge count
edge_count() {
    init_graph
    jq '.edges | length' "$GRAPH_FILE"
}

# Get neighbors of a node
get_neighbors() {
    local node="$1"
    init_graph

    # Get both outgoing and incoming neighbors
    jq -r --arg node "$node" '
        (.edges[] | select(.from == $node) | select((.status // "active") != "deprecated") | .to),
        (.edges[] | select(.to == $node) | select((.status // "active") != "deprecated") | .from)
    ' "$GRAPH_FILE" | sort -u
}

export -f validate_edge_type add_edge delete_edge deprecate_edge get_outgoing_edges get_incoming_edges get_all_edges list_edges update_edge_weight edge_count get_neighbors
