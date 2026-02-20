#!/usr/bin/env bash
# Sync failures to the knowledge graph
#
# Reads all failures from failures/data/failures.jsonl and creates
# missing nodes in graph/data/graph.json.
#
# Idempotent: running twice produces the same result. Existing nodes
# matched by data.failure_id are skipped.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LORE_DIR="${LORE_DIR:-$(dirname "$SCRIPT_DIR")}"
source "${LORE_DIR}/lib/paths.sh"
GRAPH_FILE="${LORE_GRAPH_FILE}"
FAILURES_FILE="${LORE_FAILURES_DATA}/failures.jsonl"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
DIM='\033[2m'
NC='\033[0m'

# Check dependencies
command -v jq &>/dev/null || { echo -e "${RED}jq required${NC}"; exit 1; }

if [[ ! -f "$FAILURES_FILE" ]] || [[ ! -s "$FAILURES_FILE" ]]; then
    echo -e "${YELLOW}No failures file found at ${FAILURES_FILE}${NC}"
    exit 0
fi

if [[ ! -f "$GRAPH_FILE" ]]; then
    echo -e "${RED}Graph file not found at ${GRAPH_FILE}${NC}"
    exit 1
fi

now="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

# --- Step 1: Pre-compute hashes ---
names_to_hash=$(jq -rs '[.[].id] | unique | .[]' "$FAILURES_FILE") || true

hash_entries=()
while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    hash=$(echo -n "$name" | md5sum | cut -c1-8)
    escaped_name=$(printf '%s' "$name" | sed 's/\\/\\\\/g; s/"/\\"/g')
    hash_entries+=("\"${escaped_name}\":\"failure-${hash}\"")
done <<< "$names_to_hash"

hash_json="{$(IFS=,; echo "${hash_entries[*]}")}"

# --- Step 2: Single jq pass — diff against graph, build additions ---
additions_file="$(mktemp)"
trap 'rm -f "$additions_file"' EXIT

jq -n \
    --slurpfile graph "$GRAPH_FILE" \
    --slurpfile failures <(jq -s '.' "$FAILURES_FILE") \
    --argjson hashes "$hash_json" \
    --arg now "$now" '

    $failures[0] as $failures |
    $graph[0] as $graph |

    # Existing failure_ids in graph
    [$graph.nodes | to_entries[] | .value.data.failure_id // empty] as $existing_ids |

    # Filter to new failures only
    [$failures[] | select(.id as $id | $existing_ids | index($id) | not)] as $new_failures |

    reduce $new_failures[] as $fail (
        {nodes: {}, edges: []};

        ($fail.id) as $fail_id |
        $hashes[$fail_id] as $node_key |
        ($fail.timestamp // $now) as $created |

        # Add failure node
        .nodes[$node_key] = {
            type: "failure",
            name: $fail_id,
            data: {
                failure_id: $fail_id,
                error_type: ($fail.error_type // "unknown"),
                error_message: (($fail.error_message // "")[0:120])
            },
            created_at: $created,
            updated_at: $now
        }
    ) |

    {
        nodes: .nodes,
        edges: [],
        stats: {
            new_failure_nodes: ([.nodes | to_entries[]] | length)
        }
    }
' > "$additions_file"

# Extract stats
new_failure_nodes=$(jq '.stats.new_failure_nodes' "$additions_file")

total_failures=$(jq -s 'length' "$FAILURES_FILE")
existing_failure_nodes=$(jq '[.nodes | to_entries[] | select(.value.data.failure_id)] | length' "$GRAPH_FILE")

echo -e "${DIM}Found ${total_failures} failures in failures.jsonl${NC}"
echo -e "${DIM}Found ${existing_failure_nodes} failure nodes already in graph${NC}"

# Merge additions into graph
if [[ "$new_failure_nodes" -gt 0 ]]; then
    jq -s '
        .[0] as $graph | .[1] as $additions |
        $graph |
        .nodes = (.nodes + $additions.nodes) |
        .edges = (.edges + $additions.edges)
    ' "$GRAPH_FILE" <(jq '{nodes, edges}' "$additions_file") > "${GRAPH_FILE}.tmp" && mv "${GRAPH_FILE}.tmp" "$GRAPH_FILE"
fi

echo -e "${GREEN}Synced ${new_failure_nodes} new failure nodes${NC}"
