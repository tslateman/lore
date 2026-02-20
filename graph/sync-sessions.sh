#!/usr/bin/env bash
# Sync sessions to the knowledge graph
#
# Reads session JSON files from transfer/data/sessions/ and creates
# missing nodes in graph/data/graph.json. Also creates edges to
# decisions and patterns referenced in the session.
#
# Idempotent: running twice produces the same result. Existing nodes
# matched by data.session_id are skipped.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LORE_DIR="${LORE_DIR:-$(dirname "$SCRIPT_DIR")}"
source "${LORE_DIR}/lib/paths.sh"
GRAPH_FILE="${LORE_GRAPH_FILE}"
SESSIONS_DIR="${LORE_TRANSFER_DATA}/sessions"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
DIM='\033[2m'
NC='\033[0m'

# Check dependencies
command -v jq &>/dev/null || { echo -e "${RED}jq required${NC}"; exit 1; }

if [[ ! -d "$SESSIONS_DIR" ]]; then
    echo -e "${YELLOW}No sessions directory found at ${SESSIONS_DIR}${NC}"
    exit 0
fi

# Collect session files (skip compressed/example files)
session_files=()
for f in "$SESSIONS_DIR"/session-*.json; do
    [[ -f "$f" ]] || continue
    [[ "$f" == *.compressed.json ]] && continue
    [[ "$f" == *example* ]] && continue
    session_files+=("$f")
done

if [[ ${#session_files[@]} -eq 0 ]]; then
    echo -e "${YELLOW}No session files found${NC}"
    exit 0
fi

if [[ ! -f "$GRAPH_FILE" ]]; then
    echo -e "${RED}Graph file not found at ${GRAPH_FILE}${NC}"
    exit 1
fi

now="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

# Existing session_ids in graph
existing_session_ids=$(jq -r '[.nodes | to_entries[] | .value.data.session_id // empty] | .[]' "$GRAPH_FILE")

new_session_nodes=0
new_edges=0

for session_file in "${session_files[@]}"; do
    session_id=$(jq -r '.id // empty' "$session_file")
    [[ -z "$session_id" ]] && continue

    # Skip if already in graph
    if echo "$existing_session_ids" | grep -qxF "$session_id"; then
        continue
    fi

    # Compute node key
    node_key="session-$(echo -n "$session_id" | md5sum | cut -c1-8)"

    summary=$(jq -r '(.handoff.message // .summary // "")[0:120]' "$session_file")
    started_at=$(jq -r '.started_at // empty' "$session_file")

    # Build node JSON
    node_json=$(jq -n \
        --arg type "session" \
        --arg name "$session_id" \
        --arg session_id "$session_id" \
        --arg summary "$summary" \
        --arg started_at "${started_at:-$now}" \
        --arg created "${started_at:-$now}" \
        --arg updated "$now" \
        '{
            type: $type,
            name: $name,
            data: {
                session_id: $session_id,
                summary: $summary,
                started_at: $started_at
            },
            created_at: $created,
            updated_at: $updated
        }')

    # Build edges for decisions_made and patterns_learned
    edge_json="[]"

    decisions_made=$(jq -r '.decisions_made // [] | .[]' "$session_file" 2>/dev/null) || true
    for dec_id in $decisions_made; do
        [[ -z "$dec_id" ]] && continue
        dec_key="decision-$(echo -n "$dec_id" | md5sum | cut -c1-8)"
        edge_json=$(echo "$edge_json" | jq \
            --arg from "$node_key" \
            --arg to "$dec_key" \
            --arg created "${started_at:-$now}" \
            '. += [{from: $from, to: $to, relation: "produces", weight: 1.0, bidirectional: false, created_at: $created}]')
        new_edges=$((new_edges + 1))
    done

    patterns_learned=$(jq -r '.patterns_learned // [] | .[]' "$session_file" 2>/dev/null) || true
    for pat_id in $patterns_learned; do
        [[ -z "$pat_id" ]] && continue
        pat_key="pattern-$(echo -n "$pat_id" | md5sum | cut -c1-8)"
        edge_json=$(echo "$edge_json" | jq \
            --arg from "$node_key" \
            --arg to "$pat_key" \
            --arg created "${started_at:-$now}" \
            '. += [{from: $from, to: $to, relation: "produces", weight: 1.0, bidirectional: false, created_at: $created}]')
        new_edges=$((new_edges + 1))
    done

    # Merge into graph
    jq --arg key "$node_key" \
       --argjson node "$node_json" \
       --argjson edges "$edge_json" \
       '.nodes[$key] = $node | .edges = (.edges + $edges)' \
       "$GRAPH_FILE" > "${GRAPH_FILE}.tmp" && mv "${GRAPH_FILE}.tmp" "$GRAPH_FILE"

    new_session_nodes=$((new_session_nodes + 1))
done

total_sessions=${#session_files[@]}
existing_session_nodes=$(jq '[.nodes | to_entries[] | select(.value.data.session_id)] | length' "$GRAPH_FILE")

echo -e "${DIM}Found ${total_sessions} session files${NC}"
echo -e "${DIM}Found ${existing_session_nodes} session nodes in graph (after sync)${NC}"
echo -e "${GREEN}Synced ${new_session_nodes} new session nodes, ${new_edges} new edges${NC}"
