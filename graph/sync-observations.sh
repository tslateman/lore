#!/usr/bin/env bash
# Sync observations to the knowledge graph
#
# Reads promoted observations from inbox/data/observations.jsonl and
# creates missing nodes in graph/data/graph.json.
#
# Only observations with status "promoted" are synced. Raw and discarded
# observations are skipped. Promoted observations represent validated
# knowledge worth tracking in the graph.
#
# Idempotent: running twice produces the same result. Existing nodes
# matched by data.observation_id are skipped.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LORE_DIR="${LORE_DIR:-$(dirname "$SCRIPT_DIR")}"
source "${LORE_DIR}/lib/paths.sh"
GRAPH_FILE="${LORE_GRAPH_FILE}"
OBSERVATIONS_FILE="${LORE_INBOX_DATA}/observations.jsonl"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
DIM='\033[2m'
NC='\033[0m'

# Check dependencies
command -v jq &>/dev/null || { echo -e "${RED}jq required${NC}"; exit 1; }

if [[ ! -f "$OBSERVATIONS_FILE" ]] || [[ ! -s "$OBSERVATIONS_FILE" ]]; then
    echo -e "${YELLOW}No observations file found at ${OBSERVATIONS_FILE}${NC}"
    exit 0
fi

if [[ ! -f "$GRAPH_FILE" ]]; then
    echo -e "${RED}Graph file not found at ${GRAPH_FILE}${NC}"
    exit 1
fi

now="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

# --- Step 1: Extract promoted observations ---
promoted_json=$(jq -s '[.[] | select(.status == "promoted")]' "$OBSERVATIONS_FILE")
promoted_count=$(echo "$promoted_json" | jq 'length')

total_observations=$(jq -s 'length' "$OBSERVATIONS_FILE")

if [[ "$promoted_count" -eq 0 ]]; then
    echo -e "${DIM}Found ${total_observations} observations, 0 promoted -- nothing to sync${NC}"
    exit 0
fi

# --- Step 2: Pre-compute md5 hashes ---
hash_entries=()

# Hash observation content (truncated to 80 chars) for node IDs
while IFS= read -r content; do
    [[ -z "$content" ]] && continue
    hash=$(echo -n "$content" | md5sum | cut -c1-8)
    escaped_content=$(printf '%s' "$content" | sed 's/\\/\\\\/g; s/"/\\"/g')
    hash_entries+=("\"observation:${escaped_content}\":\"observation-${hash}\"")
done < <(echo "$promoted_json" | jq -r '.[].content[0:80]')

# Hash promoted_to IDs for edge targets (if they look like specific IDs)
while IFS= read -r promoted_to; do
    [[ -z "$promoted_to" ]] && continue
    # Detect type: if it contains a dash and isn't a bare type name, it's an ID
    case "$promoted_to" in
        decision|pattern|failure|session) continue ;;  # bare type, skip
    esac
    # Determine node type from ID prefix
    local_type="decision"
    case "$promoted_to" in
        pat-*|pattern-*) local_type="pattern" ;;
        dec-*|decision-*) local_type="decision" ;;
    esac
    hash=$(echo -n "$promoted_to" | md5sum | cut -c1-8)
    escaped_id=$(printf '%s' "$promoted_to" | sed 's/\\/\\\\/g; s/"/\\"/g')
    hash_entries+=("\"${local_type}:${escaped_id}\":\"${local_type}-${hash}\"")
done < <(echo "$promoted_json" | jq -r '.[].promoted_to // empty')

hash_json="{$(IFS=,; echo "${hash_entries[*]}")}"

# --- Step 3: Single jq pass — diff against graph, build additions ---
additions_file="$(mktemp)"
trap 'rm -f "$additions_file"' EXIT

jq -n \
    --argjson observations "$promoted_json" \
    --slurpfile graph "$GRAPH_FILE" \
    --argjson hashes "$hash_json" \
    --arg now "$now" '

    def node_id(type; name): $hashes[(type + ":" + name)] // null;

    $graph[0] as $graph |

    # Existing observation_ids in graph
    [$graph.nodes | to_entries[] | .value.data.observation_id // empty] as $existing_ids |

    # Existing node keys in graph (for promoted_to lookups)
    [$graph.nodes | keys[]] as $existing_node_keys |

    # Filter to new observations only
    [$observations[] | select(.id as $id | $existing_ids | index($id) | not)] as $new_obs |

    reduce $new_obs[] as $obs (
        {nodes: {}, edges: []};

        ($obs.content[0:80]) as $truncated |
        node_id("observation"; $truncated) as $node_key |
        ($obs.timestamp // $now) as $created |

        if $node_key == null then . else

        # Add observation node
        .nodes[$node_key] = {
            type: "observation",
            name: $truncated,
            data: {
                observation_id: $obs.id,
                source: ($obs.source // "unknown"),
                status: $obs.status,
                tags: ($obs.tags // [])
            },
            created_at: $created,
            updated_at: $now
        } |

        # Add derived_from edge if promoted_to contains a specific ID
        if ($obs.promoted_to // "" | length) > 0 then
            ($obs.promoted_to) as $target_ref |
            # Skip bare type names (decision, pattern, etc.)
            if ($target_ref | test("^(decision|pattern|failure|session)$")) then .
            else
                # Determine target node type from ID prefix
                (if ($target_ref | test("^pat-|^pattern-")) then "pattern"
                 else "decision" end) as $target_type |
                node_id($target_type; $target_ref) as $target_key |
                if $target_key != null and ($existing_node_keys | index($target_key)) then
                    .edges += [{
                        from: $target_key,
                        to: $node_key,
                        relation: "derived_from",
                        weight: 1.0,
                        bidirectional: false,
                        status: "active",
                        created_at: $created
                    }]
                else . end
            end
        else . end

        end
    ) |

    {
        nodes: .nodes,
        edges: .edges,
        stats: {
            new_observation_nodes: ([.nodes | to_entries[]] | length),
            new_edges: (.edges | length)
        }
    }
' > "$additions_file"

# Extract stats
new_obs_nodes=$(jq '.stats.new_observation_nodes' "$additions_file")
new_edges=$(jq '.stats.new_edges' "$additions_file")

echo -e "${DIM}Found ${total_observations} observations, ${promoted_count} promoted${NC}"

existing_obs_nodes=$(jq '[.nodes | to_entries[] | select(.value.data.observation_id)] | length' "$GRAPH_FILE")
echo -e "${DIM}Found ${existing_obs_nodes} observation nodes already in graph${NC}"

# Merge additions into graph
if [[ "$new_obs_nodes" -gt 0 ]]; then
    jq -s '
        .[0] as $graph | .[1] as $additions |
        $graph |
        .nodes = (.nodes + $additions.nodes) |
        .edges = (.edges + $additions.edges)
    ' "$GRAPH_FILE" <(jq '{nodes, edges}' "$additions_file") > "${GRAPH_FILE}.tmp" && mv "${GRAPH_FILE}.tmp" "$GRAPH_FILE"
fi

echo -e "${GREEN}Synced ${new_obs_nodes} new observation nodes, ${new_edges} new edges${NC}"
