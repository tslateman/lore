#!/usr/bin/env bash
# Reverse lookup: map graph node IDs back to source entries
# Bridges graph IDs (e.g. decision-d7f00cf3) to journal IDs (e.g. dec-5741815d)

set -euo pipefail

GRAPH_DIR="${GRAPH_DIR:-$(dirname "${BASH_SOURCE[0]}")/..}"
GRAPH_FILE="${GRAPH_DIR}/data/graph.json"
JOURNAL_DIR="${GRAPH_DIR}/../journal"
DECISIONS_FILE="${JOURNAL_DIR}/data/decisions.jsonl"
PATTERNS_FILE="${GRAPH_DIR}/../patterns/data/patterns.yaml"

# Source nodes.sh for get_node, init_graph
source "$(dirname "${BASH_SOURCE[0]}")/nodes.sh"

# Reverse-lookup a graph node ID to its source entry
# For decision nodes: returns the matching journal entry as JSON
# For other types: returns the graph node data
# Usage: lookup_node <node-id> [--json]
lookup_node() {
    local node_id="$1"
    local json_only="${2:-}"

    init_graph

    local node
    node=$(jq -c --arg id "$node_id" '.nodes[$id] // empty' "$GRAPH_FILE")

    if [[ -z "$node" ]]; then
        echo "Error: Node '$node_id' not found in graph" >&2
        return 1
    fi

    local node_type node_name
    node_type=$(echo "$node" | jq -r '.type')
    node_name=$(echo "$node" | jq -r '.name')

    case "$node_type" in
        decision)
            lookup_decision "$node_id" "$node_name" "$node" "$json_only"
            ;;
        pattern)
            lookup_pattern "$node_id" "$node_name" "$node" "$json_only"
            ;;
        *)
            # No external source — return the graph node itself
            if [[ "$json_only" == "--json" ]]; then
                echo "$node" | jq --arg id "$node_id" '{graph_id: $id} + .'
            else
                echo "$node" | jq --arg id "$node_id" '{graph_id: $id} + .'
            fi
            ;;
    esac
}

# Look up a decision node in the journal
lookup_decision() {
    local node_id="$1"
    local node_name="$2"
    local node_json="$3"
    local json_only="$4"

    if [[ ! -f "$DECISIONS_FILE" ]]; then
        echo "Error: Journal file not found at $DECISIONS_FILE" >&2
        return 1
    fi

    # Search decisions.jsonl for entries matching the node name
    local matches
    matches=$(jq -sc --arg name "$node_name" '
        [.[] | select(.decision == $name)]
        | group_by(.id) | map(.[-1])
        | sort_by(.timestamp) | reverse
    ' "$DECISIONS_FILE" 2>/dev/null)

    if [[ -z "$matches" || "$matches" == "[]" ]]; then
        # Try case-insensitive substring match as fallback
        matches=$(jq -sc --arg name "$node_name" '
            [.[] | select(.decision | ascii_downcase | contains($name | ascii_downcase))]
            | group_by(.id) | map(.[-1])
            | sort_by(.timestamp) | reverse
        ' "$DECISIONS_FILE" 2>/dev/null)
    fi

    if [[ -z "$matches" || "$matches" == "[]" ]]; then
        if [[ "$json_only" == "--json" ]]; then
            echo "$node_json" | jq --arg id "$node_id" '{graph_id: $id, source: "graph_only"} + .'
        else
            echo "$node_json" | jq --arg id "$node_id" '{graph_id: $id, source: "graph_only"} + .'
        fi
        return 0
    fi

    # Annotate results with graph_id
    echo "$matches" | jq --arg gid "$node_id" '[.[] | {graph_id: $gid} + .]'
}

# Look up a pattern node in patterns.yaml
lookup_pattern() {
    local node_id="$1"
    local node_name="$2"
    local node_json="$3"
    local json_only="$4"

    if [[ ! -f "$PATTERNS_FILE" ]]; then
        echo "$node_json" | jq --arg id "$node_id" '{graph_id: $id, source: "graph_only"} + .'
        return 0
    fi

    # Search patterns.yaml for matching name using grep+awk
    local name_lower
    name_lower=$(echo "$node_name" | tr '[:upper:]' '[:lower:]')

    local found="false"
    local in_block="false"
    local block=""

    while IFS= read -r line; do
        local line_lower
        line_lower=$(echo "$line" | tr '[:upper:]' '[:lower:]')

        if [[ "$line" =~ ^[[:space:]]*-[[:space:]]*name: ]]; then
            # Start of a new pattern block
            if [[ "$in_block" == "true" && -n "$block" ]]; then
                break
            fi
            local this_name
            this_name=$(echo "$line" | sed 's/^[[:space:]]*-[[:space:]]*name:[[:space:]]*//' | sed 's/^["'"'"']//' | sed 's/["'"'"']$//')
            local this_name_lower
            this_name_lower=$(echo "$this_name" | tr '[:upper:]' '[:lower:]')
            if [[ "$this_name_lower" == "$name_lower" ]]; then
                in_block="true"
                block="$line"
            fi
        elif [[ "$in_block" == "true" ]]; then
            if [[ "$line" =~ ^[[:space:]]*-[[:space:]]*name: ]]; then
                break
            fi
            block="$block"$'\n'"$line"
        fi
    done < "$PATTERNS_FILE"

    if [[ "$in_block" == "true" && -n "$block" ]]; then
        # Output as JSON with graph_id
        echo "$node_json" | jq --arg id "$node_id" --arg source "patterns.yaml" \
            '{graph_id: $id, source: $source} + .'
    else
        echo "$node_json" | jq --arg id "$node_id" --arg source "graph_only" \
            '{graph_id: $id, source: $source} + .'
    fi
}

export -f lookup_node lookup_decision lookup_pattern
