#!/usr/bin/env bash
# Graph traversal for Memory Graph
# BFS/DFS traversal, shortest path, cluster detection

set -euo pipefail

GRAPH_DIR="${GRAPH_DIR:-$(dirname "${BASH_SOURCE[0]}")/..}"
GRAPH_FILE="${GRAPH_DIR}/data/graph.json"

# Source dependencies
source "$(dirname "${BASH_SOURCE[0]}")/nodes.sh"
source "$(dirname "${BASH_SOURCE[0]}")/edges.sh"

# Breadth-First Search from a starting node
# Usage: bfs <start_node> [max_depth]
bfs() {
    local start="$1"
    local max_depth="${2:-10}"

    init_graph

    # Verify start node exists
    local start_node
    start_node=$(get_node "$start")
    if [[ -z "$start_node" ]]; then
        echo "Error: Start node '$start' not found" >&2
        return 1
    fi

    # Use jq for BFS traversal
    jq -r --arg start "$start" --argjson max_depth "$max_depth" '
        def bfs_traverse:
            {
                visited: {},
                queue: [[$start, 0]],
                result: []
            } |
            until(.queue | length == 0;
                .queue[0] as [$node, $depth] |
                .queue = .queue[1:] |
                if .visited[$node] or $depth > $max_depth then .
                else
                    .visited[$node] = true |
                    .result += [{node: $node, depth: $depth}] |
                    (.graph.edges | map(select(.from == $node)) | map(.to)) as $neighbors |
                    (.graph.edges | map(select(.to == $node and .bidirectional)) | map(.from)) as $reverse_neighbors |
                    reduce ($neighbors + $reverse_neighbors)[] as $neighbor (.;
                        if .visited[$neighbor] | not then
                            .queue += [[$neighbor, $depth + 1]]
                        else . end
                    )
                end
            ) |
            .result;

        {graph: .} | bfs_traverse
    ' "$GRAPH_FILE"
}

# Depth-First Search from a starting node
# Usage: dfs <start_node> [max_depth]
dfs() {
    local start="$1"
    local max_depth="${2:-10}"

    init_graph

    # Verify start node exists
    local start_node
    start_node=$(get_node "$start")
    if [[ -z "$start_node" ]]; then
        echo "Error: Start node '$start' not found" >&2
        return 1
    fi

    jq -r --arg start "$start" --argjson max_depth "$max_depth" '
        def dfs_traverse($node; $depth; $visited):
            if $visited[$node] or $depth > $max_depth then
                {visited: $visited, result: []}
            else
                ($visited + {($node): true}) as $new_visited |
                [{node: $node, depth: $depth}] as $current |
                (.edges | map(select(.from == $node)) | map(.to)) as $neighbors |
                reduce $neighbors[] as $neighbor (
                    {visited: $new_visited, result: $current};
                    if .visited[$neighbor] | not then
                        dfs_traverse($neighbor; $depth + 1; .visited) as $sub |
                        {visited: $sub.visited, result: (.result + $sub.result)}
                    else . end
                )
            end;

        dfs_traverse($start; 0; {}) | .result
    ' "$GRAPH_FILE"
}

# Find shortest path between two nodes using BFS
# Usage: shortest_path <from> <to>
shortest_path() {
    local from="$1"
    local to="$2"

    init_graph

    # Verify nodes exist
    if [[ -z "$(get_node "$from")" ]]; then
        echo "Error: Source node '$from' not found" >&2
        return 1
    fi
    if [[ -z "$(get_node "$to")" ]]; then
        echo "Error: Target node '$to' not found" >&2
        return 1
    fi

    if [[ "$from" == "$to" ]]; then
        echo "[$from]"
        return 0
    fi

    jq -r --arg from "$from" --arg to "$to" '
        . as $graph |
        {
            visited: {($from): true},
            queue: [[$from, [$from]]],
            found: null
        } |
        until(.found != null or (.queue | length == 0);
            .queue[0] as [$node, $path] |
            .queue = .queue[1:] |
            if $node == $to then
                .found = $path
            else
                ($graph.edges | map(select(.from == $node)) | map(.to)) as $out_neighbors |
                ($graph.edges | map(select(.to == $node)) | map(.from)) as $in_neighbors |
                ($out_neighbors + $in_neighbors) as $neighbors |
                reduce ($neighbors | unique)[] as $neighbor (.;
                    if .visited[$neighbor] | not then
                        .visited[$neighbor] = true |
                        .queue += [[$neighbor, $path + [$neighbor]]]
                    else . end
                )
            end
        ) |
        .found // []
    ' "$GRAPH_FILE"
}

# Find all related nodes within n hops
# Usage: find_related <node> [max_hops]
find_related() {
    local node="$1"
    local max_hops="${2:-2}"

    init_graph

    if [[ -z "$(get_node "$node")" ]]; then
        echo "Error: Node '$node' not found" >&2
        return 1
    fi

    jq -r --arg node "$node" --argjson max_hops "$max_hops" '
        . as $graph |
        {
            visited: {},
            queue: [[$node, 0]],
            result: []
        } |
        until(.queue | length == 0;
            .queue[0] as [$current, $depth] |
            .queue = .queue[1:] |
            if .visited[$current] or $depth > $max_hops then .
            else
                .visited[$current] = true |
                (if $current != $node then
                    .result += [{
                        id: $current,
                        hops: $depth,
                        node: $graph.nodes[$current]
                    }]
                else . end) |
                ($graph.edges | map(select(.from == $current)) | map(.to)) as $out |
                ($graph.edges | map(select(.to == $current)) | map(.from)) as $in |
                reduce (($out + $in) | unique)[] as $neighbor (.;
                    if .visited[$neighbor] | not then
                        .queue += [[$neighbor, $depth + 1]]
                    else . end
                )
            end
        ) |
        .result | sort_by(.hops)
    ' "$GRAPH_FILE"
}

# Find clusters of connected nodes
find_clusters() {
    init_graph

    jq -r '
        . as $graph |
        # Build adjacency list
        ($graph.edges | reduce .[] as $e ({};
            .[$e.from] += [$e.to] | .[$e.to] += [$e.from]
        )) as $adj |
        # Find connected components using iterative BFS
        reduce ($graph.nodes | keys)[] as $node (
            {visited: {}, clusters: []};
            if .visited[$node] then .
            else
                # BFS to find all nodes in this cluster
                (
                    {
                        visited: .visited,
                        queue: [$node],
                        cluster: []
                    } |
                    until(.queue | length == 0;
                        .queue[0] as $current |
                        .queue = .queue[1:] |
                        if .visited[$current] then .
                        else
                            .visited[$current] = true |
                            .cluster += [$current] |
                            reduce (($adj[$current] // []) | unique)[] as $neighbor (.;
                                if .visited[$neighbor] | not then
                                    .queue += [$neighbor]
                                else . end
                            )
                        end
                    )
                ) as $result |
                {
                    visited: $result.visited,
                    clusters: (if ($result.cluster | length) > 0 then .clusters + [$result.cluster] else .clusters end)
                }
            end
        ) |
        .clusters
    ' "$GRAPH_FILE"
}

# Find orphaned nodes (nodes with no edges)
find_orphans() {
    init_graph

    jq -r '
        (.edges | map(.from, .to) | unique) as $connected |
        .nodes | to_entries |
        map(select(.key as $id | $connected | contains([$id]) | not)) |
        map({id: .key, type: .value.type, name: .value.name})
    ' "$GRAPH_FILE"
}

# Get node degree (number of connections)
node_degree() {
    local node="$1"
    init_graph

    jq -r --arg node "$node" '
        {
            in: [.edges[] | select(.to == $node)] | length,
            out: [.edges[] | select(.from == $node)] | length
        } |
        {in, out, total: (.in + .out)}
    ' "$GRAPH_FILE"
}

# Find most connected nodes (hubs)
find_hubs() {
    local limit="${1:-10}"
    init_graph

    jq -r --argjson limit "$limit" '
        . as $graph |
        ($graph.nodes | keys) |
        map(. as $node | {
            id: $node,
            name: $graph.nodes[$node].name,
            type: $graph.nodes[$node].type,
            degree: ([$graph.edges[] | select(.from == $node or .to == $node)] | length)
        }) |
        sort_by(-.degree) |
        .[:$limit]
    ' "$GRAPH_FILE"
}

# Find path with edge details
path_with_edges() {
    local from="$1"
    local to="$2"

    local path
    path=$(shortest_path "$from" "$to")

    if [[ "$path" == "[]" || -z "$path" ]]; then
        echo "No path found between $from and $to"
        return 1
    fi

    init_graph

    # Get edges along the path
    echo "$path" | jq -r --slurpfile graph "$GRAPH_FILE" '
        . as $path |
        reduce range(0; ($path | length) - 1) as $i (
            [];
            . + [{
                from: $path[$i],
                to: $path[$i + 1],
                edge: ($graph[0].edges[] | select(
                    (.from == $path[$i] and .to == $path[$i + 1]) or
                    (.to == $path[$i] and .from == $path[$i + 1])
                ) | {relation, weight})
            }]
        )
    '
}

export -f bfs dfs shortest_path find_related find_clusters find_orphans node_degree find_hubs path_with_edges
