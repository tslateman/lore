#!/usr/bin/env bash
# Wire related_to edges between decision nodes and their project nodes
# based on shared project tags in the journal.
#
# For each decision in decisions.jsonl, extract project-like tags and
# connect the decision's graph node to the corresponding project node.
# Creates project nodes when none exist for a tag.
#
# One-time script to reduce orphan count.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LORE_DIR="${LORE_DIR:-$(dirname "$SCRIPT_DIR")}"
GRAPH_FILE="${LORE_DIR}/graph/data/graph.json"
DECISIONS_FILE="${LORE_DIR}/journal/data/decisions.jsonl"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
DIM='\033[2m'
NC='\033[0m'

# Check dependencies
command -v jq &>/dev/null || { echo -e "${RED}jq required${NC}"; exit 1; }

if [[ ! -f "$GRAPH_FILE" ]]; then
    echo -e "${RED}Graph file not found at ${GRAPH_FILE}${NC}"
    exit 1
fi

if [[ ! -f "$DECISIONS_FILE" ]]; then
    echo -e "${RED}Decisions file not found at ${DECISIONS_FILE}${NC}"
    exit 1
fi

# Back up graph.json
cp "$GRAPH_FILE" "${GRAPH_FILE}.bak"
echo -e "${DIM}Backed up graph.json to graph.json.bak${NC}"

now="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

# Tags that represent projects (match existing project node names or known project tags)
# We exclude meta-tags like "adr", "accepted", "revised", "architecture", etc.
# and focus on tags that name specific projects.

# Step 1: Count orphans before
orphans_before=$(jq '
    ([.edges[] | .from, .to] | unique) as $connected |
    [.nodes | keys[] | select(. as $k | $connected | index($k) | not)] | length
' "$GRAPH_FILE")

echo -e "${DIM}Orphan nodes before: ${orphans_before}${NC}"

# Step 2: Build a mapping of journal_id -> decision graph node key
# and extract project tags from decisions.jsonl, then wire edges
jq -n \
    --slurpfile graph "$GRAPH_FILE" \
    --slurpfile decisions <(jq -s 'group_by(.id) | map(.[-1])' "$DECISIONS_FILE") \
    --arg now "$now" '

    $graph[0] as $graph |
    $decisions[0] as $decisions |

    # Known project names that exist as project nodes in the graph
    [$graph.nodes | to_entries[] | select(.value.type == "project") | {key: .value.name, value: .key}] |
    from_entries as $project_lookup |

    # Map journal_id -> graph node key for decision nodes
    [$graph.nodes | to_entries[] | select(.value.type == "decision" and .value.data.journal_id) |
        {key: .value.data.journal_id, value: .key}] |
    from_entries as $decision_lookup |

    # Existing edges as a set for dedup
    [$graph.edges[] | (.from + "|" + .to + "|" + .relation)] | unique as $existing_edge_set |

    # Tags that represent actual projects (filter out meta-tags)
    # We accept tags that match an existing project node name,
    # plus known project tags not yet in the graph
    ["lore", "council", "neo", "oracle", "bach", "flow", "ralph", "lineage",
     "cli", "entire", "geordi", "praxis", "duet", "mirror", "tutor", "qin",
     "cq", "version", "shared", "dependencies", "integrations", "pattern_sharing"] as $project_tags |

    # For each decision, collect (decision_node_key, project_tag) pairs
    reduce $decisions[] as $dec (
        {new_nodes: {}, new_edges: [], project_lookup: $project_lookup};

        ($dec.id) as $journal_id |
        ($decision_lookup[$journal_id] // null) as $dec_node_key |

        if $dec_node_key == null then . else
            reduce (($dec.tags // [])[] | select(. as $t | $project_tags | index($t))) as $tag (
                .;

                # Find or create project node for this tag
                (.project_lookup[$tag] // null) as $proj_node_key |

                if $proj_node_key != null then
                    # Project node exists; add edge if not duplicate
                    (($dec_node_key + "|" + $proj_node_key + "|related_to") as $edge_key |
                     if ($existing_edge_set | index($edge_key)) or
                        ([.new_edges[] | (.from + "|" + .to + "|" + .relation)] | index($edge_key))
                     then .
                     else
                        .new_edges += [{
                            from: $dec_node_key,
                            to: $proj_node_key,
                            relation: "related_to",
                            weight: 0.8,
                            bidirectional: false,
                            created_at: $now
                        }]
                     end)
                else
                    # Create project node (md5 not available in jq, use tag name as hash source)
                    # Use a deterministic ID based on the tag
                    ("project-tag-" + $tag) as $new_proj_key |

                    # Add project node if not already created
                    (if .new_nodes[$new_proj_key] then . else
                        .new_nodes[$new_proj_key] = {
                            type: "project",
                            name: $tag,
                            data: {
                                source: "wire-project-edges",
                                description: ("Project node created from journal tag: " + $tag)
                            },
                            created_at: $now,
                            updated_at: $now
                        } |
                        .project_lookup[$tag] = $new_proj_key
                    end) |

                    # Add edge
                    (($dec_node_key + "|" + $new_proj_key + "|related_to") as $edge_key |
                     if ([.new_edges[] | (.from + "|" + .to + "|" + .relation)] | index($edge_key))
                     then .
                     else
                        .new_edges += [{
                            from: $dec_node_key,
                            to: $new_proj_key,
                            relation: "related_to",
                            weight: 0.8,
                            bidirectional: false,
                            created_at: $now
                        }]
                     end)
                end
            )
        end
    ) |

    {
        new_nodes: .new_nodes,
        new_edges: .new_edges,
        stats: {
            new_project_nodes: (.new_nodes | length),
            new_edges: (.new_edges | length)
        }
    }
' > /tmp/wire-project-additions.json

# Extract stats
new_project_nodes=$(jq '.stats.new_project_nodes' /tmp/wire-project-additions.json)
new_edges=$(jq '.stats.new_edges' /tmp/wire-project-additions.json)

echo -e "${DIM}New project nodes to create: ${new_project_nodes}${NC}"
echo -e "${DIM}New edges to add: ${new_edges}${NC}"

# Step 3: Merge into graph
if [[ "$new_edges" -gt 0 || "$new_project_nodes" -gt 0 ]]; then
    jq -s '
        .[0] as $graph | .[1] as $additions |
        $graph |
        .nodes = (.nodes + $additions.new_nodes) |
        .edges = (.edges + $additions.new_edges)
    ' "$GRAPH_FILE" /tmp/wire-project-additions.json > "${GRAPH_FILE}.tmp" && mv "${GRAPH_FILE}.tmp" "$GRAPH_FILE"
fi

# Step 4: Count orphans after
orphans_after=$(jq '
    ([.edges[] | .from, .to] | unique) as $connected |
    [.nodes | keys[] | select(. as $k | $connected | index($k) | not)] | length
' "$GRAPH_FILE")

echo -e "${GREEN}Added ${new_edges} edges, reduced orphans from ${orphans_before} to ${orphans_after}${NC}"

# Cleanup
rm -f /tmp/wire-project-additions.json
