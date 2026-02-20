#!/usr/bin/env bash
# Sync goals to the knowledge graph
#
# Reads goal YAML files from intent/data/goals/ and creates
# missing nodes in graph/data/graph.json. Also creates edges
# to project nodes and tag-matched decision nodes.
#
# Idempotent: running twice produces the same result. Existing nodes
# matched by data.goal_id are skipped.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LORE_DIR="${LORE_DIR:-$(dirname "$SCRIPT_DIR")}"
source "${LORE_DIR}/lib/paths.sh"
GRAPH_FILE="${LORE_GRAPH_FILE}"
GOALS_DIR="${LORE_INTENT_DATA}/goals"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
DIM='\033[2m'
NC='\033[0m'

# Check dependencies
command -v jq &>/dev/null || { echo -e "${RED}jq required${NC}"; exit 1; }
command -v yq &>/dev/null || { echo -e "${RED}yq required${NC}"; exit 1; }

if [[ ! -d "$GOALS_DIR" ]]; then
    echo -e "${YELLOW}No goals directory found at ${GOALS_DIR}${NC}"
    exit 0
fi

goal_files=("$GOALS_DIR"/*.yaml)
if [[ ! -f "${goal_files[0]}" ]]; then
    echo -e "${YELLOW}No goal files found in ${GOALS_DIR}${NC}"
    exit 0
fi

if [[ ! -f "$GRAPH_FILE" ]]; then
    echo -e "${RED}Graph file not found at ${GRAPH_FILE}${NC}"
    exit 1
fi

now="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

# --- Step 1: Read all goal files into a JSON array ---
goals_json="[]"
for goal_file in "${goal_files[@]}"; do
    [[ ! -f "$goal_file" ]] && continue
    goal=$(yq -o=json '.' "$goal_file")
    goals_json=$(echo "$goals_json" | jq --argjson g "$goal" '. += [$g]')
done

goal_count=$(echo "$goals_json" | jq 'length')

if [[ "$goal_count" -eq 0 ]]; then
    echo -e "${DIM}No goals to sync${NC}"
    exit 0
fi

# --- Step 2: Pre-compute md5 hashes ---
# Hash goal names for node IDs
hash_entries=()
while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    hash=$(echo -n "$name" | md5sum | cut -c1-8)
    escaped_name=$(printf '%s' "$name" | sed 's/\\/\\\\/g; s/"/\\"/g')
    hash_entries+=("\"goal:${escaped_name}\":\"goal-${hash}\"")
done < <(echo "$goals_json" | jq -r '.[].name')

# Hash project names for project node lookups
while IFS= read -r proj; do
    [[ -z "$proj" ]] && continue
    hash=$(echo -n "$proj" | md5sum | cut -c1-8)
    escaped_proj=$(printf '%s' "$proj" | sed 's/\\/\\\\/g; s/"/\\"/g')
    hash_entries+=("\"project:${escaped_proj}\":\"project-${hash}\"")
done < <(echo "$goals_json" | jq -r '[.[].projects[]?] | unique | .[]' 2>/dev/null || true)

hash_json="{$(IFS=,; echo "${hash_entries[*]}")}"

# --- Step 3: Single jq pass — diff against graph, build additions ---
additions_file="$(mktemp)"
trap 'rm -f "$additions_file"' EXIT

jq -n \
    --argjson goals "$goals_json" \
    --slurpfile graph "$GRAPH_FILE" \
    --argjson hashes "$hash_json" \
    --arg now "$now" '

    def node_id(type; name): $hashes[(type + ":" + name)] // (type + "-unknown");

    $graph[0] as $graph |

    # Existing goal_ids in graph
    [$graph.nodes | to_entries[] | .value.data.goal_id // empty] as $existing_ids |

    # Existing node keys in graph (for project/decision lookups)
    [$graph.nodes | keys[]] as $existing_node_keys |

    # Decision nodes with their tags (for tag-based edge creation)
    [$graph.nodes | to_entries[] | select(.value.type == "decision") |
        {key: .key, tags: [.value.data.tags[]? // empty]}
    ] as $decision_nodes |

    # Filter to new goals only
    [$goals[] | select(.id as $id | $existing_ids | index($id) | not)] as $new_goals |

    reduce $new_goals[] as $goal (
        {nodes: {}, edges: []};

        ($goal.name) as $goal_name |
        node_id("goal"; $goal_name) as $node_key |
        ($goal.created_at // $now) as $created |

        # Add goal node
        .nodes[$node_key] = {
            type: "goal",
            name: $goal_name,
            data: {
                goal_id: $goal.id,
                status: ($goal.status // "unknown"),
                priority: ($goal.priority // "medium"),
                deadline: ($goal.deadline // null)
            },
            created_at: $created,
            updated_at: $now
        } |

        # Add relates_to edges to project nodes (if they exist in graph)
        reduce ($goal.projects // [])[] as $proj (
            .;
            node_id("project"; $proj) as $proj_key |
            if ($existing_node_keys | index($proj_key)) then
                .edges += [{
                    from: $node_key,
                    to: $proj_key,
                    relation: "relates_to",
                    weight: 1.0,
                    bidirectional: false,
                    status: "active",
                    created_at: $created
                }]
            else . end
        ) |

        # Add relates_to edges to decision nodes with matching tags
        if (($goal.tags // []) | length) > 0 then
            reduce $decision_nodes[] as $dec (
                .;
                ($dec.tags) as $dec_tags |
                if ($dec_tags | length) > 0 and
                   ([$goal.tags[] | . as $tag | $dec_tags | index($tag) | . != null] | any) then
                    .edges += [{
                        from: $node_key,
                        to: $dec.key,
                        relation: "relates_to",
                        weight: 0.8,
                        bidirectional: false,
                        status: "active",
                        created_at: $created
                    }]
                else . end
            )
        else . end
    ) |

    # Deduplicate edges
    .edges = [.edges | group_by(.from + .to + .relation) | .[] | .[0]] |

    {
        nodes: .nodes,
        edges: .edges,
        stats: {
            new_goal_nodes: ([.nodes | to_entries[]] | length),
            new_edges: (.edges | length)
        }
    }
' > "$additions_file"

# Extract stats
new_goal_nodes=$(jq '.stats.new_goal_nodes' "$additions_file")
new_edges=$(jq '.stats.new_edges' "$additions_file")

echo -e "${DIM}Found ${goal_count} goals in ${GOALS_DIR}${NC}"

existing_goal_nodes=$(jq '[.nodes | to_entries[] | select(.value.data.goal_id)] | length' "$GRAPH_FILE")
echo -e "${DIM}Found ${existing_goal_nodes} goal nodes already in graph${NC}"

# Merge additions into graph
if [[ "$new_goal_nodes" -gt 0 ]]; then
    jq -s '
        .[0] as $graph | .[1] as $additions |
        $graph |
        .nodes = (.nodes + $additions.nodes) |
        .edges = (.edges + $additions.edges)
    ' "$GRAPH_FILE" <(jq '{nodes, edges}' "$additions_file") > "${GRAPH_FILE}.tmp" && mv "${GRAPH_FILE}.tmp" "$GRAPH_FILE"
fi

echo -e "${GREEN}Synced ${new_goal_nodes} new goal nodes, ${new_edges} new edges${NC}"
