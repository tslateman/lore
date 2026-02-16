#!/usr/bin/env bash
# graph-traverse.sh - Graph-enhanced recall for search results
#
# Traverses graph edges from a starting node to surface related knowledge.
# Uses a single jq BFS call for performance (no per-node subprocess).
# Output format: [type] Name → relation → [type] Name

set -euo pipefail

LORE_DIR="${LORE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
GRAPH_FILE="${LORE_DIR}/graph/data/graph.json"

# Traverse graph edges from a starting node via BFS.
# Usage: graph_traverse <node_id_or_name> [depth]
# Depth 0 = no traversal, 1-3 = follow edges that many hops.
graph_traverse() {
    local start="$1"
    local depth="${2:-1}"

    [[ "$depth" -lt 1 || "$depth" -gt 3 ]] && return 0
    [[ ! -f "$GRAPH_FILE" ]] && return 0

    # Single jq call: resolve start node, then BFS up to depth
    jq -r --arg start "$start" --argjson max_depth "$depth" '
        . as $root |
        # Resolve start: try direct ID, then case-insensitive name match
        (.nodes[$start] // null) as $direct |
        (if $direct != null then $start
         else
            [.nodes | to_entries[]
             | select(.value.name | ascii_downcase
                      | contains($start | ascii_downcase))
             | .key][0] // null
         end) as $start_id |

        if $start_id == null then empty
        else
            # BFS collecting edges with annotations
            {
                visited: {($start_id): true},
                queue: [[$start_id, 0]],
                results: []
            } |
            until(.queue | length == 0;
                .queue[0] as [$node, $d] |
                .queue = .queue[1:] |
                if $d >= $max_depth then .
                else
                    # Collect outgoing edges
                    [$root.edges[] | select(.from == $node)] as $out |
                    reduce $out[] as $e (.;
                        if .visited[$e.to] then .
                        else
                            .visited[$e.to] = true |
                            .queue += [[$e.to, $d + 1]] |
                            .results += [{
                                depth: ($d + 1),
                                from_type: ($root.nodes[$e.from].type // "?"),
                                from_name: ($root.nodes[$e.from].name // $e.from),
                                relation: $e.relation,
                                to_type: ($root.nodes[$e.to].type // "?"),
                                to_name: ($root.nodes[$e.to].name // $e.to)
                            }]
                        end
                    ) |

                    # Collect incoming edges (reverse discovery)
                    [$root.edges[] | select(.to == $node)] as $inc |
                    reduce $inc[] as $e (.;
                        if .visited[$e.from] then .
                        else
                            .visited[$e.from] = true |
                            .queue += [[$e.from, $d + 1]] |
                            .results += [{
                                depth: ($d + 1),
                                from_type: ($root.nodes[$e.from].type // "?"),
                                from_name: ($root.nodes[$e.from].name // $e.from),
                                relation: $e.relation,
                                to_type: ($root.nodes[$e.to].type // "?"),
                                to_name: ($root.nodes[$e.to].name // $e.to)
                            }]
                        end
                    )
                end
            ) |
            .results[] |
            # Indent deeper hops
            ("  " * (.depth - 1)) +
            "[\(.from_type)] \(.from_name) \u2192 \(.relation) \u2192 [\(.to_type)] \(.to_name)"
        end
    ' "$GRAPH_FILE" 2>/dev/null || true
}

# Resolve a search result to a graph node ID.
# Tries: direct ID, project name, content-based name match.
# Usage: resolve_to_graph_id <type> <id> <content_snippet> [project]
resolve_to_graph_id() {
    local type="$1"
    local id="$2"
    local content="$3"
    local project="${4:-}"

    [[ ! -f "$GRAPH_FILE" ]] && return 0

    jq -r --arg id "$id" --arg type "$type" \
           --arg content "$content" --arg project "$project" '
        # 1. Direct ID match
        if .nodes[$id] then $id

        # 2. Project name match (search results tagged with project name)
        elif ($project != "") then
            [.nodes | to_entries[]
             | select(.value.type == "project")
             | select(.value.name | ascii_downcase == ($project | ascii_downcase))
             | .key][0] // (

            # 3. Content-based name match: extract name before ":"
            ($content | split(":")[0] | gsub("^\\s+|\\s+$";"") | .[0:60]) as $fragment |
            if ($fragment | length) > 3 then
                [.nodes | to_entries[]
                 | select(.value.name | ascii_downcase
                          | contains($fragment | ascii_downcase))
                 | .key][0] // empty
            else empty end
            )
        else
            # 3. Content-based name match without project
            ($content | split(":")[0] | gsub("^\\s+|\\s+$";"") | .[0:60]) as $fragment |
            if ($fragment | length) > 3 then
                [.nodes | to_entries[]
                 | select(.value.name | ascii_downcase
                          | contains($fragment | ascii_downcase))
                 | .key][0] // empty
            else empty end
        end
    ' "$GRAPH_FILE" 2>/dev/null || true
}

# --- Commands ---

cmd_traverse() {
    local node="${1:?Usage: graph-traverse.sh traverse <node_id_or_name> [--depth N]}"
    shift
    local depth=1

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --depth|-d) depth="$2"; shift 2 ;;
            *) shift ;;
        esac
    done

    graph_traverse "$node" "$depth"
}

# --- Main ---

main() {
    [[ $# -eq 0 ]] && {
        echo "Usage: graph-traverse.sh traverse <node_id_or_name> [--depth N]"
        exit 1
    }

    case "$1" in
        traverse) shift; cmd_traverse "$@" ;;
        *)
            echo "Unknown command: $1" >&2
            exit 1
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
