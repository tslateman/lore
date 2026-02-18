#!/usr/bin/env bash
# Node management for Memory Graph
# Node types: concept, file, pattern, lesson, decision, session

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/../../lib/paths.sh"
GRAPH_DIR="${GRAPH_DIR:-$(dirname "${BASH_SOURCE[0]}")/..}"
GRAPH_FILE="${LORE_GRAPH_FILE}"

# Ensure graph file exists
init_graph() {
    mkdir -p "$(dirname "$GRAPH_FILE")"
    if [[ ! -f "$GRAPH_FILE" ]]; then
        echo '{"nodes":{},"edges":[]}' > "$GRAPH_FILE"
    fi
}

# Generate a unique node ID
generate_node_id() {
    local name="$1"
    local type="$2"
    # Create deterministic ID from type and name for deduplication
    echo "${type}-$(echo -n "${name}" | md5sum | cut -c1-8)"
}

# Valid node types
VALID_NODE_TYPES=("concept" "file" "pattern" "lesson" "decision" "session" "project")

validate_node_type() {
    local type="$1"
    for valid in "${VALID_NODE_TYPES[@]}"; do
        if [[ "$type" == "$valid" ]]; then
            return 0
        fi
    done
    return 1
}

# Add a node to the graph
# Usage: add_node <type> <name> [data_json]
add_node() {
    local type="$1"
    local name="$2"
    local data="${3:-"{}"}"

    if ! validate_node_type "$type"; then
        echo "Error: Invalid node type '$type'. Valid types: ${VALID_NODE_TYPES[*]}" >&2
        return 1
    fi

    init_graph

    local id
    id=$(generate_node_id "$name" "$type")
    local timestamp
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    # Check if node exists for merging
    local existing
    existing=$(jq -r --arg id "$id" '.nodes[$id] // empty' "$GRAPH_FILE")

    if [[ -n "$existing" ]]; then
        # Compare: only write if data or name actually changed
        local changed
        changed=$(jq --arg id "$id" \
           --arg name "$name" \
           --argjson new_data "$data" \
           'if .nodes[$id].name == $name and .nodes[$id].data == (.nodes[$id].data * $new_data) then "no" else "yes" end' \
           "$GRAPH_FILE")

        if [[ "$changed" == '"yes"' ]]; then
            jq --arg id "$id" \
               --arg name "$name" \
               --argjson new_data "$data" \
               --arg updated "$timestamp" \
               '.nodes[$id].data = (.nodes[$id].data * $new_data) | .nodes[$id].name = $name | .nodes[$id].updated_at = $updated' \
               "$GRAPH_FILE" > "${GRAPH_FILE}.tmp" && mv "${GRAPH_FILE}.tmp" "$GRAPH_FILE"

            echo "Merged node: $id"
        else
            echo "Unchanged node: $id"
        fi
    else
        # Create new node
        jq --arg id "$id" \
           --arg name "$name" \
           --arg type "$type" \
           --argjson data "$data" \
           --arg created "$timestamp" \
           '.nodes[$id] = {type: $type, name: $name, data: $data, created_at: $created, updated_at: $created}' \
           "$GRAPH_FILE" > "${GRAPH_FILE}.tmp" && mv "${GRAPH_FILE}.tmp" "$GRAPH_FILE"

        echo "Created node: $id"
    fi

    echo "$id"
}

# Get a node by ID
get_node() {
    local id="$1"
    init_graph
    jq -r --arg id "$id" '.nodes[$id] // empty' "$GRAPH_FILE"
}

# Get a node by name and optional type
find_node() {
    local name="$1"
    local type="${2:-}"

    init_graph

    if [[ -n "$type" ]]; then
        jq -r --arg name "$name" --arg type "$type" \
           'to_entries[] | select(.value.name == $name and .value.type == $type) | .key' \
           <<< "$(jq '.nodes' "$GRAPH_FILE")"
    else
        jq -r --arg name "$name" \
           'to_entries[] | select(.value.name == $name) | .key' \
           <<< "$(jq '.nodes' "$GRAPH_FILE")"
    fi
}

# Delete a node and its edges
delete_node() {
    local id="$1"
    init_graph

    # Remove node and all edges referencing it
    jq --arg id "$id" \
       'del(.nodes[$id]) | .edges = [.edges[] | select(.from != $id and .to != $id)]' \
       "$GRAPH_FILE" > "${GRAPH_FILE}.tmp" && mv "${GRAPH_FILE}.tmp" "$GRAPH_FILE"

    echo "Deleted node: $id"
}

# List all nodes, optionally filtered by type
list_nodes() {
    local type="${1:-}"
    init_graph

    if [[ -n "$type" ]]; then
        jq -r --arg type "$type" \
           '.nodes | to_entries[] | select(.value.type == $type) | "\(.key)\t\(.value.type)\t\(.value.name)"' \
           "$GRAPH_FILE"
    else
        jq -r '.nodes | to_entries[] | "\(.key)\t\(.value.type)\t\(.value.name)"' "$GRAPH_FILE"
    fi
}

# Update node data
update_node() {
    local id="$1"
    local data="$2"

    init_graph

    local timestamp
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    local changed
    changed=$(jq --arg id "$id" \
       --argjson data "$data" \
       'if .nodes[$id] and .nodes[$id].data == (.nodes[$id].data * $data) then "no" else "yes" end' \
       "$GRAPH_FILE")

    if [[ "$changed" == '"yes"' ]]; then
        jq --arg id "$id" \
           --argjson data "$data" \
           --arg updated "$timestamp" \
           'if .nodes[$id] then .nodes[$id].data = (.nodes[$id].data * $data) | .nodes[$id].updated_at = $updated else . end' \
           "$GRAPH_FILE" > "${GRAPH_FILE}.tmp" && mv "${GRAPH_FILE}.tmp" "$GRAPH_FILE"

        echo "Updated node: $id"
    else
        echo "Unchanged node: $id"
    fi
}

# Get node count
node_count() {
    init_graph
    jq '.nodes | length' "$GRAPH_FILE"
}

# Export for use in other scripts
export -f init_graph generate_node_id validate_node_type add_node get_node find_node delete_node list_nodes update_node node_count
