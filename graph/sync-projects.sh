#!/usr/bin/env bash
# Sync projects from mani.yaml to the knowledge graph
#
# Reads all projects from ~/dev/mani.yaml and creates missing project
# nodes in graph/data/graph.json. Creates edges:
#   - hosts: project -> session (matched by context.project in session files)
#   - part_of: file -> project (matched by file path prefix)
#
# Idempotent: running twice produces the same result. Existing nodes
# matched by data.project_name are skipped.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LORE_DIR="${LORE_DIR:-$(dirname "$SCRIPT_DIR")}"
source "${LORE_DIR}/lib/paths.sh"
GRAPH_FILE="${LORE_GRAPH_FILE}"
WORKSPACE_ROOT="${WORKSPACE_ROOT:-$(dirname "$LORE_DIR")}"
MANI_FILE="${MANI_FILE:-${WORKSPACE_ROOT}/mani.yaml}"
# Session files may live in the external data dir or the repo dir
SESSIONS_DIR="${LORE_TRANSFER_DATA}/sessions"
REPO_SESSIONS_DIR="${LORE_DIR}/transfer/data/sessions"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
DIM='\033[2m'
NC='\033[0m'

# Check dependencies
command -v jq &>/dev/null || { echo -e "${RED}jq required${NC}"; exit 1; }
command -v yq &>/dev/null || { echo -e "${RED}yq required${NC}"; exit 1; }

if [[ ! -f "$MANI_FILE" ]]; then
    echo -e "${YELLOW}No mani.yaml found at ${MANI_FILE}${NC}"
    exit 0
fi

if [[ ! -f "$GRAPH_FILE" ]]; then
    echo -e "${RED}Graph file not found at ${GRAPH_FILE}${NC}"
    exit 1
fi

now="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

# --- Step 1: Extract projects from mani.yaml as JSON ---
projects_json=$(yq -o=json '.projects // {}' "$MANI_FILE")
project_count=$(echo "$projects_json" | jq 'keys | length')

if [[ "$project_count" -eq 0 ]]; then
    echo -e "${DIM}No projects found in mani.yaml${NC}"
    exit 0
fi

# --- Step 2: Build session-to-project mapping from session files ---
# Read context.project from each session file to build a lookup.
# Check both the external data dir and the repo dir for session files.
session_project_map="{}"
_scan_sessions() {
    local dir="$1"
    [[ -d "$dir" ]] || return 0
    for session_file in "$dir"/session-*.json; do
        [[ -f "$session_file" ]] || continue
        session_id=$(jq -r '.id // empty' "$session_file" 2>/dev/null) || continue
        project=$(jq -r '.context.project // empty' "$session_file" 2>/dev/null) || continue
        [[ -z "$session_id" || -z "$project" ]] && continue
        session_project_map=$(echo "$session_project_map" | jq \
            --arg sid "$session_id" --arg proj "$project" \
            '. + {($sid): $proj}')
    done
}
_scan_sessions "$SESSIONS_DIR"
if [[ "$SESSIONS_DIR" != "$REPO_SESSIONS_DIR" ]]; then
    _scan_sessions "$REPO_SESSIONS_DIR"
fi

# --- Step 3: Pre-compute hashes for project names ---
hash_entries=()
while IFS= read -r pname; do
    [[ -z "$pname" ]] && continue
    hash=$(echo -n "$pname" | md5sum | cut -c1-8)
    escaped_name=$(printf '%s' "$pname" | sed 's/\\/\\\\/g; s/"/\\"/g')
    hash_entries+=("\"${escaped_name}\":\"project-${hash}\"")
done < <(echo "$projects_json" | jq -r 'keys[]')

hash_json="{$(IFS=,; echo "${hash_entries[*]}")}"

# --- Step 4: Single jq pass — diff against graph, build additions ---
additions_file="$(mktemp)"
trap 'rm -f "$additions_file"' EXIT

jq -n \
    --argjson projects "$projects_json" \
    --slurpfile graph "$GRAPH_FILE" \
    --argjson hashes "$hash_json" \
    --argjson session_map "$session_project_map" \
    --arg now "$now" '

    $graph[0] as $graph |

    # Existing project_names in graph
    [$graph.nodes | to_entries[] | .value.data.project_name // empty] as $existing_names |

    # All session nodes in graph (keyed by session_id)
    [$graph.nodes | to_entries[] | select(.value.type == "session") |
        {key: .key, session_id: .value.data.session_id}] as $session_nodes |

    # All file nodes in graph
    [$graph.nodes | to_entries[] | select(.value.type == "file") |
        {key: .key, name: .value.name, path: (.value.data.path // .value.name)}] as $file_nodes |

    # Process each project
    reduce ($projects | keys[]) as $pname (
        {nodes: {}, edges: []};

        # Skip if project node already exists
        if ($existing_names | index($pname)) then . else

        $hashes[$pname] as $node_key |
        $projects[$pname] as $proj |
        ($proj.desc // "") as $desc |
        ($proj.path // $pname) as $path |
        ($proj.tags // []) as $tags |

        # Add project node
        .nodes[$node_key] = {
            type: "project",
            name: $pname,
            data: {
                project_name: $pname,
                path: $path,
                description: $desc,
                tags: $tags
            },
            created_at: $now,
            updated_at: $now
        } |

        # Add hosts edges: project -> session nodes with matching context.project
        reduce $session_nodes[] as $sn (
            .;
            if ($session_map[$sn.session_id] // "") == $pname then
                .edges += [{
                    from: $node_key,
                    to: $sn.key,
                    relation: "hosts",
                    weight: 1.0,
                    bidirectional: false,
                    status: "active",
                    created_at: $now
                }]
            else . end
        ) |

        # Add part_of edges: file nodes -> project node
        # Match file paths that start with the project path
        reduce $file_nodes[] as $fn (
            .;
            if ($fn.path | startswith($path + "/")) or ($fn.path == $path) then
                .edges += [{
                    from: $fn.key,
                    to: $node_key,
                    relation: "part_of",
                    weight: 1.0,
                    bidirectional: false,
                    status: "active",
                    created_at: $now
                }]
            else . end
        )

        end
    ) |

    # Deduplicate edges (same from/to/relation)
    .edges = [.edges | group_by(.from + .to + .relation) | .[] | .[0]] |

    {
        nodes: .nodes,
        edges: .edges,
        stats: {
            new_project_nodes: ([.nodes | to_entries[]] | length),
            new_hosts_edges: ([.edges[] | select(.relation == "hosts")] | length),
            new_part_of_edges: ([.edges[] | select(.relation == "part_of")] | length),
            new_edges: (.edges | length)
        }
    }
' > "$additions_file"

# Extract stats
new_project_nodes=$(jq '.stats.new_project_nodes' "$additions_file")
new_hosts_edges=$(jq '.stats.new_hosts_edges' "$additions_file")
new_part_of_edges=$(jq '.stats.new_part_of_edges' "$additions_file")
new_edges=$(jq '.stats.new_edges' "$additions_file")

existing_project_nodes=$(jq '[.nodes | to_entries[] | select(.value.data.project_name)] | length' "$GRAPH_FILE")

echo -e "${DIM}Found ${project_count} projects in mani.yaml${NC}"
echo -e "${DIM}Found ${existing_project_nodes} project nodes already in graph${NC}"

# --- Step 5: Merge additions into graph ---
if [[ "$new_project_nodes" -gt 0 ]]; then
    jq -s '
        .[0] as $graph | .[1] as $additions |
        $graph |
        .nodes = (.nodes + $additions.nodes) |
        .edges = (.edges + $additions.edges)
    ' "$GRAPH_FILE" <(jq '{nodes, edges}' "$additions_file") > "${GRAPH_FILE}.tmp" && mv "${GRAPH_FILE}.tmp" "$GRAPH_FILE"
fi

# --- Step 6: Dedup edges in graph ---
dup_count=$(jq '[.edges | group_by(.from + .to + .relation) | .[] | select(length > 1)] | length' "$GRAPH_FILE")
deduped_edges=0
if [[ "$dup_count" -gt 0 ]]; then
    before_edges=$(jq '.edges | length' "$GRAPH_FILE")
    jq '.edges = [.edges | group_by(.from + .to + .relation) | .[] | .[0]]' \
        "$GRAPH_FILE" > "${GRAPH_FILE}.tmp" && mv "${GRAPH_FILE}.tmp" "$GRAPH_FILE"
    after_edges=$(jq '.edges | length' "$GRAPH_FILE")
    deduped_edges=$((before_edges - after_edges))
fi

echo -e "${GREEN}Synced ${new_project_nodes} new project nodes, ${new_hosts_edges} hosts edges, ${new_part_of_edges} part_of edges${NC}"
if [[ "$deduped_edges" -gt 0 ]]; then
    echo -e "${YELLOW}Removed ${deduped_edges} duplicate edge(s)${NC}"
fi
