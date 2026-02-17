#!/usr/bin/env bash
# Memory Graph - A searchable knowledge base for AI agents
# Connects concepts, files, decisions, and learnings

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export GRAPH_DIR="$SCRIPT_DIR"
export GRAPH_FILE="${GRAPH_DIR}/data/graph.json"

# Source library functions
source "${SCRIPT_DIR}/lib/nodes.sh"
source "${SCRIPT_DIR}/lib/edges.sh"
source "${SCRIPT_DIR}/lib/search.sh"
source "${SCRIPT_DIR}/lib/traverse.sh"
source "${SCRIPT_DIR}/lib/lookup.sh"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Print usage information
usage() {
    cat << EOF
Memory Graph - Searchable knowledge base for AI agents

USAGE:
    graph.sh <command> [options]

COMMANDS:
    add <type> <name> [--data '{}']     Add a node to the graph
    link <from> <to> --relation <type>  Create an edge between nodes
    connect <from> <to> <relation>      Connect nodes by name or ID
    disconnect <from> <to> [relation]   Remove edges between nodes
    query <search>                       Full-text search across nodes
    related <node> [--hops n]           Find related nodes
    path <from> <to>                    Find connection path between nodes
    visualize                           Output DOT format for graphviz

    list [type]                         List all nodes (optionally by type)
    get <node-id>                       Get details of a specific node
    lookup <node-id>                    Reverse-lookup: find source entry for a graph node
    delete <node-id>                    Delete a node and its edges

    orphans                             Find nodes with no connections
    hubs [limit]                        Find most connected nodes
    clusters                            Find clusters of related nodes
    stats                               Show graph statistics

    sync                                Sync journal decisions to graph nodes
    import <file>                       Import nodes/edges from JSON
    export [format]                     Export graph (json, dot, mermaid)

NODE TYPES:
    concept     Abstract ideas or topics
    file        Source files or documents
    pattern     Recurring patterns or practices
    lesson      Learned insights
    decision    Architectural or design decisions
    session     Work sessions or sprints
    project     Software projects in the ecosystem

EDGE TYPES:
    relates_to      General semantic relationship
    learned_from    Knowledge derived from experience
    affects         Has impact on
    supersedes      Newer decision replaces older one
    contradicts     Pattern/decision conflicts with another
    contains        Parent/child relationship
    references      Points to
    implements      Code realizes a concept
    depends_on      Requires
    produces        Generates output consumed by another
    consumes        Takes input produced by another
    derived_from    Pattern learned from a specific decision
    part_of         Component of a larger concept/initiative
    summarized_by   Consolidated into a higher-level summary

EXAMPLES:
    # Add a concept
    graph.sh add concept "authentication" --data '{"tags": ["security", "core"]}'

    # Link concepts
    graph.sh link concept-abc123 file-def456 --relation "implements"

    # Search for authentication-related knowledge
    graph.sh query "authentication" --type concept

    # Find what's related to a decision
    graph.sh related decision-xyz --hops 3

    # Reverse-lookup a decision node to its journal entry
    graph.sh lookup decision-d7f00cf3

    # Connect nodes by name (resolves to IDs automatically)
    graph.sh connect "authentication" "JWT tokens" relates_to

    # Disconnect nodes
    graph.sh disconnect "authentication" "JWT tokens" relates_to

    # Visualize the graph
    graph.sh visualize | dot -Tpng -o graph.png

EOF
}

# Add a node
cmd_add() {
    local type=""
    local name=""
    local data="{}"

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --data)
                data="$2"
                shift 2
                ;;
            *)
                if [[ -z "$type" ]]; then
                    type="$1"
                elif [[ -z "$name" ]]; then
                    name="$1"
                fi
                shift
                ;;
        esac
    done

    if [[ -z "$type" || -z "$name" ]]; then
        echo -e "${RED}Error: Both type and name are required${NC}" >&2
        echo "Usage: graph.sh add <type> <name> [--data '{}']"
        return 1
    fi

    # Validate JSON data
    if ! echo "$data" | jq . > /dev/null 2>&1; then
        echo -e "${RED}Error: Invalid JSON data${NC}" >&2
        return 1
    fi

    local result
    result=$(add_node "$type" "$name" "$data")
    local node_id
    node_id=$(echo "$result" | tail -1)

    echo -e "${GREEN}Node added:${NC} $node_id"
    echo -e "  Type: $type"
    echo -e "  Name: $name"
}

# Create a link/edge
cmd_link() {
    local from=""
    local to=""
    local relation=""
    local weight="1.0"
    local bidirectional="false"

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --relation)
                relation="$2"
                shift 2
                ;;
            --weight)
                weight="$2"
                shift 2
                ;;
            --bidirectional)
                bidirectional="true"
                shift
                ;;
            *)
                if [[ -z "$from" ]]; then
                    from="$1"
                elif [[ -z "$to" ]]; then
                    to="$1"
                fi
                shift
                ;;
        esac
    done

    if [[ -z "$from" || -z "$to" || -z "$relation" ]]; then
        echo -e "${RED}Error: from, to, and --relation are required${NC}" >&2
        echo "Usage: graph.sh link <from> <to> --relation <type>"
        return 1
    fi

    add_edge "$from" "$to" "$relation" "$weight" "$bidirectional"
    echo -e "${GREEN}Edge created:${NC} $from -> $to [$relation]"
}

# Search/query the graph
cmd_query() {
    if [[ $# -lt 1 ]]; then
        echo -e "${RED}Error: Search query required${NC}" >&2
        echo "Usage: graph.sh query <search> [--type type] [--fuzzy] [--limit n]"
        return 1
    fi

    local results
    results=$(search "$@")

    if [[ -z "$results" ]]; then
        echo -e "${YELLOW}No results found${NC}"
        return 0
    fi

    echo -e "${CYAN}Search Results:${NC}"
    echo "$results" | jq -r '"  \(.id) [\(.type)] \(.name) (score: \(.score))"'
}

# Find related nodes
cmd_related() {
    local node=""
    local hops="2"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --hops)
                hops="$2"
                shift 2
                ;;
            *)
                node="$1"
                shift
                ;;
        esac
    done

    if [[ -z "$node" ]]; then
        echo -e "${RED}Error: Node ID required${NC}" >&2
        echo "Usage: graph.sh related <node> [--hops n]"
        return 1
    fi

    local results
    results=$(find_related "$node" "$hops")

    if [[ -z "$results" || "$results" == "[]" ]]; then
        echo -e "${YELLOW}No related nodes found${NC}"
        return 0
    fi

    echo -e "${CYAN}Related Nodes (within $hops hops):${NC}"
    echo "$results" | jq -r '.[] | "  \(.hops) hop(s): \(.id) [\(.node.type)] \(.node.name)"'
}

# Find path between nodes
cmd_path() {
    if [[ $# -lt 2 ]]; then
        echo -e "${RED}Error: Both from and to nodes required${NC}" >&2
        echo "Usage: graph.sh path <from> <to>"
        return 1
    fi

    local from="$1"
    local to="$2"

    local path
    path=$(shortest_path "$from" "$to")

    if [[ -z "$path" || "$path" == "[]" ]]; then
        echo -e "${YELLOW}No path found between $from and $to${NC}"
        return 0
    fi

    echo -e "${CYAN}Path from $from to $to:${NC}"

    # Display path nodes
    local path_length
    path_length=$(echo "$path" | jq 'length')

    echo "$path" | jq -r '
        . as $nodes |
        range(length) |
        if . == 0 then "  \($nodes[.])"
        else "  -> \($nodes[.])"
        end
    '
}

# Visualize graph in DOT format
cmd_visualize() {
    init_graph

    echo "digraph MemoryGraph {"
    echo "  rankdir=LR;"
    echo "  node [shape=box, style=filled];"
    echo ""

    # Define node colors by type
    echo "  // Node type colors"
    echo "  node [fillcolor=\"#e3f2fd\"] // default"

    # Output nodes with type-specific styling
    jq -r '
        .nodes | to_entries[] |
        "  \"\(.key)\" [label=\"\(.value.name)\", tooltip=\"\(.value.type)\", fillcolor=\"" +
        (if .value.type == "concept" then "#bbdefb"
         elif .value.type == "file" then "#c8e6c9"
         elif .value.type == "pattern" then "#fff9c4"
         elif .value.type == "lesson" then "#f8bbd0"
         elif .value.type == "decision" then "#d1c4e9"
         elif .value.type == "session" then "#ffccbc"
         elif .value.type == "project" then "#b2dfdb"
         else "#e0e0e0" end) +
        "\"];"
    ' "$GRAPH_FILE"

    echo ""

    # Output edges
    jq -r '
        .edges[] |
        "  \"\(.from)\" -> \"\(.to)\" [label=\"\(.relation)\", weight=\(.weight // 1)];"
    ' "$GRAPH_FILE"

    echo "}"
}

# List nodes
cmd_list() {
    local type="${1:-}"

    local nodes
    nodes=$(list_nodes "$type")

    if [[ -z "$nodes" ]]; then
        echo -e "${YELLOW}No nodes found${NC}"
        return 0
    fi

    echo -e "${CYAN}Nodes:${NC}"
    echo "$nodes" | while IFS=$'\t' read -r id type name; do
        echo -e "  ${BLUE}$id${NC} [$type] $name"
    done
}

# Get node details
cmd_get() {
    if [[ $# -lt 1 ]]; then
        echo -e "${RED}Error: Node ID required${NC}" >&2
        return 1
    fi

    local node
    node=$(get_node "$1")

    if [[ -z "$node" ]]; then
        echo -e "${RED}Node not found: $1${NC}" >&2
        return 1
    fi

    echo -e "${CYAN}Node: $1${NC}"
    echo "$node" | jq .
}

# Reverse-lookup a graph node to its source entry
cmd_lookup() {
    local node_id=""
    local json_flag=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --json)
                json_flag="--json"
                shift
                ;;
            *)
                node_id="$1"
                shift
                ;;
        esac
    done

    if [[ -z "$node_id" ]]; then
        echo -e "${RED}Error: Node ID required${NC}" >&2
        echo "Usage: graph.sh lookup <node-id> [--json]"
        return 1
    fi

    local result
    result=$(lookup_node "$node_id" "$json_flag")

    if [[ -z "$result" ]]; then
        echo -e "${RED}No source entry found for: $node_id${NC}" >&2
        return 1
    fi

    echo -e "${CYAN}Lookup: $node_id${NC}"
    echo "$result" | jq .
}

# Connect two nodes by name or ID (convenience wrapper)
# Usage: lore graph connect <from> <to> <relation> [--weight N]
cmd_connect() {
    local from=""
    local to=""
    local relation=""
    local weight="1.0"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --weight)
                weight="$2"
                shift 2
                ;;
            *)
                if [[ -z "$from" ]]; then
                    from="$1"
                elif [[ -z "$to" ]]; then
                    to="$1"
                elif [[ -z "$relation" ]]; then
                    relation="$1"
                fi
                shift
                ;;
        esac
    done

    if [[ -z "$from" || -z "$to" || -z "$relation" ]]; then
        echo -e "${RED}Error: from, to, and relation are required${NC}" >&2
        echo "Usage: lore graph connect <from> <to> <relation> [--weight N]"
        echo ""
        echo "Arguments can be node IDs (e.g., concept-abc123) or node names."
        echo "If a name matches multiple nodes, the first match is used."
        return 1
    fi

    # Resolve names to IDs if needed
    local from_id to_id
    from_id=$(resolve_node_ref "$from")
    to_id=$(resolve_node_ref "$to")

    if [[ -z "$from_id" ]]; then
        echo -e "${RED}Error: Node not found: $from${NC}" >&2
        return 1
    fi
    if [[ -z "$to_id" ]]; then
        echo -e "${RED}Error: Node not found: $to${NC}" >&2
        return 1
    fi

    add_edge "$from_id" "$to_id" "$relation" "$weight" "false"
    echo -e "${GREEN}Connected:${NC} $from_id -> $to_id [$relation]"
}

# Disconnect two nodes
# Usage: lore graph disconnect <from> <to> [relation]
cmd_disconnect() {
    local from=""
    local to=""
    local relation=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            *)
                if [[ -z "$from" ]]; then
                    from="$1"
                elif [[ -z "$to" ]]; then
                    to="$1"
                elif [[ -z "$relation" ]]; then
                    relation="$1"
                fi
                shift
                ;;
        esac
    done

    if [[ -z "$from" || -z "$to" ]]; then
        echo -e "${RED}Error: from and to are required${NC}" >&2
        echo "Usage: lore graph disconnect <from> <to> [relation]"
        echo ""
        echo "If relation is omitted, all edges between the two nodes are removed."
        return 1
    fi

    # Resolve names to IDs if needed
    local from_id to_id
    from_id=$(resolve_node_ref "$from")
    to_id=$(resolve_node_ref "$to")

    if [[ -z "$from_id" ]]; then
        echo -e "${RED}Error: Node not found: $from${NC}" >&2
        return 1
    fi
    if [[ -z "$to_id" ]]; then
        echo -e "${RED}Error: Node not found: $to${NC}" >&2
        return 1
    fi

    delete_edge "$from_id" "$to_id" "$relation"
    echo -e "${GREEN}Disconnected:${NC} $from_id -> $to_id${relation:+ [$relation]}"
}

# Resolve a node reference: if it looks like an ID (contains a dash with hex suffix), use it;
# otherwise treat it as a name and find the first matching node.
resolve_node_ref() {
    local ref="$1"
    init_graph

    # Check if ref is an existing node ID
    local existing
    existing=$(jq -r --arg id "$ref" '.nodes[$id] // empty' "$GRAPH_FILE")
    if [[ -n "$existing" ]]; then
        echo "$ref"
        return
    fi

    # Try to find by name
    local found
    found=$(jq -r --arg name "$ref" \
        '.nodes | to_entries[] | select(.value.name == $name) | .key' \
        "$GRAPH_FILE" | head -1)

    if [[ -n "$found" ]]; then
        echo "$found"
        return
    fi

    # Try case-insensitive match
    found=$(jq -r --arg name "$ref" \
        '.nodes | to_entries[] | select(.value.name | ascii_downcase == ($name | ascii_downcase)) | .key' \
        "$GRAPH_FILE" | head -1)

    echo "$found"
}

# Delete a node
cmd_delete() {
    if [[ $# -lt 1 ]]; then
        echo -e "${RED}Error: Node ID required${NC}" >&2
        return 1
    fi

    delete_node "$1"
    echo -e "${GREEN}Deleted node: $1${NC}"
}

# Find orphaned nodes
cmd_orphans() {
    local orphans
    orphans=$(find_orphans)

    if [[ -z "$orphans" || "$orphans" == "[]" ]]; then
        echo -e "${GREEN}No orphaned nodes found${NC}"
        return 0
    fi

    echo -e "${YELLOW}Orphaned Nodes (no connections):${NC}"
    echo "$orphans" | jq -r '.[] | "  \(.id) [\(.type)] \(.name)"'
}

# Find hub nodes
cmd_hubs() {
    local limit="${1:-10}"

    local hubs
    hubs=$(find_hubs "$limit")

    if [[ -z "$hubs" || "$hubs" == "[]" ]]; then
        echo -e "${YELLOW}No hub nodes found${NC}"
        return 0
    fi

    echo -e "${CYAN}Most Connected Nodes:${NC}"
    echo "$hubs" | jq -r '.[] | "  \(.id): \(.degree) connections [\(.type)] \(.name)"'
}

# Find clusters
cmd_clusters() {
    local clusters
    clusters=$(find_clusters)

    if [[ -z "$clusters" || "$clusters" == "[]" ]]; then
        echo -e "${YELLOW}No clusters found${NC}"
        return 0
    fi

    echo -e "${CYAN}Node Clusters:${NC}"
    echo "$clusters" | jq -r 'to_entries[] | "  Cluster \(.key + 1): \(.value | length) nodes - \(.value | join(", "))"'
}

# Show graph statistics
cmd_stats() {
    init_graph

    local node_count edge_count
    node_count=$(jq '.nodes | length' "$GRAPH_FILE")
    edge_count=$(jq '.edges | length' "$GRAPH_FILE")

    echo -e "${CYAN}Graph Statistics:${NC}"
    echo "  Nodes: $node_count"
    echo "  Edges: $edge_count"
    echo ""

    echo "  Nodes by type:"
    jq -r '.nodes | group_by(.type) | map({type: .[0].type, count: length}) | .[] | "    \(.type): \(.count)"' "$GRAPH_FILE" 2>/dev/null || \
    jq -r '.nodes | to_entries | group_by(.value.type) | map({type: .[0].value.type, count: length}) | .[] | "    \(.type): \(.count)"' "$GRAPH_FILE"

    echo ""
    echo "  Edges by type:"
    jq -r '.edges | group_by(.relation) | map({relation: .[0].relation, count: length}) | .[] | "    \(.relation): \(.count)"' "$GRAPH_FILE"

    local orphan_count
    orphan_count=$(find_orphans | jq 'length')
    echo ""
    echo "  Orphaned nodes: $orphan_count"
}

# Import from JSON file
cmd_import() {
    if [[ $# -lt 1 ]]; then
        echo -e "${RED}Error: Import file required${NC}" >&2
        return 1
    fi

    local import_file="$1"

    if [[ ! -f "$import_file" ]]; then
        echo -e "${RED}Error: File not found: $import_file${NC}" >&2
        return 1
    fi

    # Validate JSON
    if ! jq . "$import_file" > /dev/null 2>&1; then
        echo -e "${RED}Error: Invalid JSON file${NC}" >&2
        return 1
    fi

    init_graph

    # Merge nodes and edges
    jq -s '.[0] * .[1] | .nodes = (.[0].nodes + .[1].nodes) | .edges = (.[0].edges + .[1].edges)' \
        "$GRAPH_FILE" "$import_file" > "${GRAPH_FILE}.tmp" && mv "${GRAPH_FILE}.tmp" "$GRAPH_FILE"

    echo -e "${GREEN}Imported from: $import_file${NC}"
    cmd_stats
}

# Export graph as JSON
cmd_export() {
    local format="${1:-json}"
    init_graph

    case "$format" in
        json)
            jq . "$GRAPH_FILE"
            ;;
        dot)
            echo "digraph knowledge {"
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
            echo "Unknown format: $format (use json, dot, or mermaid)" >&2
            return 1
            ;;
    esac
}

# Main command dispatcher
main() {
    if [[ $# -lt 1 ]]; then
        usage
        exit 0
    fi

    local command="$1"
    shift

    case "$command" in
        add)
            cmd_add "$@"
            ;;
        link)
            cmd_link "$@"
            ;;
        query|search)
            cmd_query "$@"
            ;;
        related)
            cmd_related "$@"
            ;;
        path)
            cmd_path "$@"
            ;;
        visualize|viz)
            cmd_visualize "$@"
            ;;
        list|ls)
            cmd_list "$@"
            ;;
        get)
            cmd_get "$@"
            ;;
        lookup)
            cmd_lookup "$@"
            ;;
        connect)
            cmd_connect "$@"
            ;;
        disconnect)
            cmd_disconnect "$@"
            ;;
        delete|rm)
            cmd_delete "$@"
            ;;
        orphans)
            cmd_orphans "$@"
            ;;
        hubs)
            cmd_hubs "$@"
            ;;
        clusters)
            cmd_clusters "$@"
            ;;
        stats)
            cmd_stats "$@"
            ;;
        import)
            cmd_import "$@"
            ;;
        export)
            cmd_export "$@"
            ;;
        sync)
            bash "${SCRIPT_DIR}/sync.sh" "$@"
            ;;
        help|--help|-h)
            usage
            ;;
        *)
            echo -e "${RED}Unknown command: $command${NC}" >&2
            echo "Run 'graph.sh help' for usage information"
            exit 1
            ;;
    esac
}

main "$@"
