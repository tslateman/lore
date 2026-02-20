#!/usr/bin/env bash
# Sync patterns to the knowledge graph
#
# Reads patterns from patterns/data/patterns.yaml and creates
# missing nodes in graph/data/graph.json.
#
# Idempotent: running twice produces the same result. Existing nodes
# matched by data.pattern_id are skipped.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LORE_DIR="${LORE_DIR:-$(dirname "$SCRIPT_DIR")}"
source "${LORE_DIR}/lib/paths.sh"
GRAPH_FILE="${LORE_GRAPH_FILE}"
PATTERNS_FILE="${LORE_PATTERNS_FILE}"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
DIM='\033[2m'
NC='\033[0m'

# Check dependencies
command -v jq &>/dev/null || { echo -e "${RED}jq required${NC}"; exit 1; }
command -v yq &>/dev/null || { echo -e "${RED}yq required${NC}"; exit 1; }

if [[ ! -f "$PATTERNS_FILE" ]]; then
    echo -e "${YELLOW}No patterns file found at ${PATTERNS_FILE}${NC}"
    exit 0
fi

if [[ ! -f "$GRAPH_FILE" ]]; then
    echo -e "${RED}Graph file not found at ${GRAPH_FILE}${NC}"
    exit 1
fi

now="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

# Extract patterns as JSON array, skip deprecated
patterns_json=$(yq -o=json '.patterns // []' "$PATTERNS_FILE" | \
    jq '[.[] | select(.name | test("DEPRECATED"; "i") | not)]')

pattern_count=$(echo "$patterns_json" | jq 'length')

if [[ "$pattern_count" -eq 0 ]]; then
    echo -e "${DIM}No active patterns to sync${NC}"
    exit 0
fi

# Existing pattern_ids in graph
existing_ids=$(jq -r '[.nodes | to_entries[] | .value.data.pattern_id // empty] | .[]' "$GRAPH_FILE")

# Build additions
additions_file="$(mktemp)"
trap 'rm -f "$additions_file"' EXIT

# Pre-compute hashes for pattern IDs
hash_entries=()
while IFS= read -r pid; do
    [[ -z "$pid" ]] && continue
    hash=$(echo -n "$pid" | md5sum | cut -c1-8)
    escaped_pid=$(printf '%s' "$pid" | sed 's/\\/\\\\/g; s/"/\\"/g')
    hash_entries+=("\"${escaped_pid}\":\"pattern-${hash}\"")
done < <(echo "$patterns_json" | jq -r '.[].id')

hash_json="{$(IFS=,; echo "${hash_entries[*]}")}"

# Single jq pass: diff against graph, build additions
jq -n \
    --argjson patterns "$patterns_json" \
    --slurpfile graph "$GRAPH_FILE" \
    --argjson hashes "$hash_json" \
    --arg now "$now" '

    $graph[0] as $graph |

    # Existing pattern_ids in graph
    [$graph.nodes | to_entries[] | .value.data.pattern_id // empty] as $existing_ids |

    # Filter to new patterns only
    [$patterns[] | select(.id as $id | $existing_ids | index($id) | not)] as $new_patterns |

    reduce $new_patterns[] as $pat (
        {nodes: {}, edges: []};

        ($pat.id) as $pat_id |
        $hashes[$pat_id] as $node_key |
        ($pat.created_at // $now) as $created |

        # Add pattern node
        .nodes[$node_key] = {
            type: "pattern",
            name: $pat_id,
            data: {
                pattern_id: $pat_id,
                name: $pat.name,
                category: ($pat.category // "general"),
                confidence: ($pat.confidence // 0.5)
            },
            created_at: $created,
            updated_at: $now
        } |

        # Add learned_from edge to origin session if present
        if ($pat.origin // "" | test("^session-")) then
            ($pat.origin) as $session_name |
            ("session-" + ($session_name | ltrimstr("session-") | .[0:8] | if . == "" then "unknown" else . end)) as $session_key_attempt |
            # Use the same md5 hashing scheme for session node
            ("session-" + ($session_name | @text | explode | map(. + 0) | add | tostring | .[0:8])) as $_unused |
            .edges += [{
                from: $node_key,
                to: ("session-" + ($session_name | @uri)),
                relation: "learned_from",
                weight: 1.0,
                bidirectional: false,
                created_at: $created
            }]
        else . end
    ) |

    {
        nodes: .nodes,
        edges: .edges,
        stats: {
            new_pattern_nodes: ([.nodes | to_entries[]] | length),
            new_edges: (.edges | length)
        }
    }
' > "$additions_file"

# Extract stats
new_pattern_nodes=$(jq '.stats.new_pattern_nodes' "$additions_file")
new_edges=$(jq '.stats.new_edges' "$additions_file")

echo -e "${DIM}Found ${pattern_count} active patterns in patterns.yaml${NC}"

existing_pattern_nodes=$(jq '[.nodes | to_entries[] | select(.value.data.pattern_id)] | length' "$GRAPH_FILE")
echo -e "${DIM}Found ${existing_pattern_nodes} pattern nodes already in graph${NC}"

# Merge additions into graph
if [[ "$new_pattern_nodes" -gt 0 ]]; then
    jq -s '
        .[0] as $graph | .[1] as $additions |
        $graph |
        .nodes = (.nodes + $additions.nodes) |
        .edges = (.edges + $additions.edges)
    ' "$GRAPH_FILE" <(jq '{nodes, edges}' "$additions_file") > "${GRAPH_FILE}.tmp" && mv "${GRAPH_FILE}.tmp" "$GRAPH_FILE"
fi

echo -e "${GREEN}Synced ${new_pattern_nodes} new pattern nodes, ${new_edges} new edges${NC}"
