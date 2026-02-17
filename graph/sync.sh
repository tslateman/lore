#!/usr/bin/env bash
# Sync journal decisions to the knowledge graph
#
# Reads all decisions from journal/data/decisions.jsonl and creates
# missing nodes in graph/data/graph.json. Also creates file nodes
# for entities and edges for relationships.
#
# Idempotent: running twice produces the same result. Existing nodes
# matched by data.journal_id are skipped.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LORE_DIR="${LORE_DIR:-$(dirname "$SCRIPT_DIR")}"
GRAPH_FILE="${SCRIPT_DIR}/data/graph.json"
DECISIONS_FILE="${LORE_DIR}/journal/data/decisions.jsonl"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
DIM='\033[2m'
NC='\033[0m'

# Check dependencies
command -v jq &>/dev/null || { echo -e "${RED}jq required${NC}"; exit 1; }

if [[ ! -f "$DECISIONS_FILE" ]]; then
    echo -e "${YELLOW}No decisions file found at ${DECISIONS_FILE}${NC}"
    exit 0
fi

if [[ ! -f "$GRAPH_FILE" ]]; then
    echo -e "${RED}Graph file not found at ${GRAPH_FILE}${NC}"
    exit 1
fi

now="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

# --- Step 1: Extract all names that need md5 hashing ---
# jq can't compute md5, so pre-compute in bash and pass as a lookup table.
names_to_hash=$(jq -rs '
    group_by(.id) | map(.[-1]) |
    (map("decision\t" + .id)) +
    ([.[].entities[]? // empty] | unique | map("file\t" + .)) +
    ([.[].related_decisions[]? // empty] | unique | map("decision\t" + .))
    | unique | .[]
' "$DECISIONS_FILE") || true

# Build JSON hash lookup: {"decision:dec-xxx": "decision-ab12cd34", "file:foo.sh": "file-ef56gh78"}
hash_entries=()
while IFS=$'\t' read -r type name; do
    [[ -z "$name" ]] && continue
    hash=$(echo -n "$name" | md5sum | cut -c1-8)
    # Escape for JSON
    escaped_name=$(printf '%s' "$name" | sed 's/\\/\\\\/g; s/"/\\"/g')
    hash_entries+=("\"${type}:${escaped_name}\":\"${type}-${hash}\"")
done <<< "$names_to_hash"

hash_json="{$(IFS=,; echo "${hash_entries[*]}")}"

# --- Step 2: Single jq pass — deduplicate, diff against graph, build additions ---
additions_file="$(mktemp)"
trap 'rm -f "$additions_file"' EXIT

jq -n \
    --slurpfile graph "$GRAPH_FILE" \
    --argjson hashes "$hash_json" \
    --arg now "$now" \
    --rawfile decisions_raw "$DECISIONS_FILE" '

    # Parse JSONL and deduplicate by .id (keep last occurrence)
    def dedup_decisions:
        [splits("\n") | select(length > 0) | fromjson] |
        group_by(.id) | map(.[-1]);

    # Lookup pre-computed node ID
    def node_id(type; name): $hashes[(type + ":" + name)] // (type + "-unknown");

    ($decisions_raw | dedup_decisions) as $decisions |
    $graph[0] as $graph |

    # Existing journal_ids in graph
    [$graph.nodes | to_entries[] | .value.data.journal_id // empty] as $existing_ids |

    # Existing file node keys in graph
    [$graph.nodes | keys[]] as $existing_node_keys |

    # Filter to new decisions only
    [$decisions[] | select(.id as $id | $existing_ids | index($id) | not)] as $new_decisions |

    # Build additions
    reduce $new_decisions[] as $dec (
        {nodes: {}, edges: [], file_nodes_created: {}};

        ($dec.id) as $dec_id |
        node_id("decision"; $dec_id) as $node_key |
        ($dec.timestamp // $now) as $created |
        ($dec.decision // "")[0:120] as $truncated |

        # Add decision node
        .nodes[$node_key] = {
            type: "decision",
            name: $dec_id,
            data: { journal_id: $dec_id, decision: $truncated },
            created_at: $created,
            updated_at: $now
        } |

        # Add file nodes and reference edges for entities
        reduce ($dec.entities // [])[] as $entity (
            .;
            node_id("file"; $entity) as $file_key |
            ($entity | split(".") | last) as $ext |

            # Create file node if not in graph or already created
            (if ($existing_node_keys | index($file_key) | not) and (.file_nodes_created[$file_key] | not) then
                .nodes[$file_key] = {
                    type: "file",
                    name: $entity,
                    data: { path: $entity, language: $ext },
                    created_at: $created,
                    updated_at: $now
                } |
                .file_nodes_created[$file_key] = true
            else . end) |

            # Add reference edge
            .edges += [{
                from: $node_key,
                to: $file_key,
                relation: "references",
                weight: 1.0,
                bidirectional: false,
                created_at: $created
            }]
        ) |

        # Add relates_to edges for related_decisions
        reduce ($dec.related_decisions // [])[] as $related_id (
            .;
            node_id("decision"; $related_id) as $related_key |
            .edges += [{
                from: $node_key,
                to: $related_key,
                relation: "relates_to",
                weight: 1.0,
                bidirectional: true,
                created_at: $created
            }]
        )
    ) |

    # Deduplicate edges (same from/to/relation)
    .edges = [.edges | group_by(.from + .to + .relation) | .[] | .[0]] |

    # Count results
    {
        nodes: .nodes,
        edges: .edges,
        stats: {
            new_decision_nodes: ([.nodes | to_entries[] | select(.value.type == "decision")] | length),
            new_file_nodes: ([.nodes | to_entries[] | select(.value.type == "file")] | length),
            new_edges: (.edges | length)
        }
    }
' > "$additions_file"

# Extract stats
new_decision_nodes=$(jq '.stats.new_decision_nodes' "$additions_file")
new_file_nodes=$(jq '.stats.new_file_nodes' "$additions_file")
new_edges=$(jq '.stats.new_edges' "$additions_file")

unique_decisions=$(jq -s 'group_by(.id) | length' "$DECISIONS_FILE")
existing_nodes=$(jq '[.nodes | to_entries[] | select(.value.data.journal_id)] | length' "$GRAPH_FILE")

echo -e "${DIM}Found ${unique_decisions} unique decisions in journal${NC}"
echo -e "${DIM}Found ${existing_nodes} decision nodes already in graph${NC}"

# --- Step 3: Merge additions into graph ---
if [[ "$new_decision_nodes" -gt 0 || "$new_file_nodes" -gt 0 ]]; then
    jq -s '
        .[0] as $graph | .[1] as $additions |
        $graph |
        .nodes = (.nodes + $additions.nodes) |
        .edges = (.edges + $additions.edges)
    ' "$GRAPH_FILE" <(jq '{nodes, edges}' "$additions_file") > "${GRAPH_FILE}.tmp" && mv "${GRAPH_FILE}.tmp" "$GRAPH_FILE"
fi

# --- Step 4: Dedup edges in graph (catches pre-existing duplicates) ---
before_edges=$(jq '.edges | length' "$GRAPH_FILE")
jq '.edges = [.edges | group_by(.from + .to + .relation) | .[] | .[0]]' \
    "$GRAPH_FILE" > "${GRAPH_FILE}.tmp" && mv "${GRAPH_FILE}.tmp" "$GRAPH_FILE"
after_edges=$(jq '.edges | length' "$GRAPH_FILE")
deduped_edges=$((before_edges - after_edges))

echo -e "${GREEN}Synced ${new_decision_nodes} new decision nodes, ${new_file_nodes} new file nodes, ${new_edges} new edges${NC}"
if [[ "$deduped_edges" -gt 0 ]]; then
    echo -e "${YELLOW}Removed ${deduped_edges} duplicate edge(s)${NC}"
fi
