#!/usr/bin/env bash
# Sync concepts from patterns/data/concepts.yaml to knowledge graph
#
# Creates concept nodes and part_of edges (member -> concept) for each
# concept's grounded_by list. Idempotent: existing nodes and edges are
# skipped; missing edges are healed on re-run.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LORE_DIR="${LORE_DIR:-$(dirname "$SCRIPT_DIR")}"
source "${LORE_DIR}/lib/paths.sh"
GRAPH_FILE="${LORE_GRAPH_FILE}"
CONCEPTS_FILE="${LORE_CONCEPTS_FILE}"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
DIM='\033[2m'
NC='\033[0m'

# Check dependencies
command -v jq &>/dev/null || { echo -e "${RED}jq required${NC}"; exit 1; }
command -v yq &>/dev/null || { echo -e "${RED}yq required${NC}"; exit 1; }

if [[ ! -f "$CONCEPTS_FILE" ]]; then
    echo -e "${YELLOW}No concepts file found at ${CONCEPTS_FILE}${NC}"
    exit 0
fi

if [[ ! -f "$GRAPH_FILE" ]]; then
    echo -e "${RED}Graph file not found at ${GRAPH_FILE}${NC}"
    exit 1
fi

now="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
concepts_created=0
edges_created=0

concept_count=$(yq '.concepts | length' "$CONCEPTS_FILE" 2>/dev/null || echo 0)
echo -e "${DIM}Found ${concept_count} concepts in ${CONCEPTS_FILE}${NC}"

# Iterate concepts from YAML
while IFS=$'\t' read -r cid cname; do
    [[ -z "$cid" ]] && continue

    # Deterministic node key from concept ID
    node_key="concept-$(echo -n "$cid" | md5sum | cut -c1-8)"

    # Create node only if missing; edges are always (re)checked below
    existing=$(jq -r --arg id "$node_key" '.nodes[$id] // empty' "$GRAPH_FILE")
    if [[ -z "$existing" ]]; then
        # Get definition from YAML
        definition=$(yq -r ".concepts[] | select(.id == \"$cid\") | .definition // \"\"" "$CONCEPTS_FILE")

        # Create concept node
        jq --arg key "$node_key" \
           --arg name "$cname" \
           --arg cid "$cid" \
           --arg def "$definition" \
           --arg created "$now" \
           '.nodes[$key] = {
                type: "concept",
                name: $name,
                data: { concept_id: $cid, definition: $def },
                created_at: $created,
                updated_at: $created
            }' "$GRAPH_FILE" > "${GRAPH_FILE}.tmp" && mv "${GRAPH_FILE}.tmp" "$GRAPH_FILE"

        concepts_created=$((concepts_created + 1))
    fi

    # Create part_of edges from grounded_by entries (member -> concept)
    while IFS= read -r gid; do
        [[ -z "$gid" ]] && continue
        # Resolve member node key from ID prefix
        case "$gid" in
            pat-*) g_node="pattern-$(echo -n "$gid" | md5sum | cut -c1-8)" ;;
            dec-*) g_node="decision-$(echo -n "$gid" | md5sum | cut -c1-8)" ;;
            obs-*|sig-*)
                # Observation nodes are keyed by content hash; look up by data.observation_id
                g_node=$(jq -r --arg oid "$gid" \
                    '.nodes | to_entries[] | select(.value.data.observation_id == $oid) | .key' \
                    "$GRAPH_FILE" | head -1)
                ;;
            *) g_node="" ;;
        esac
        [[ -z "$g_node" ]] && continue

        # Check target exists in graph
        g_exists=$(jq -r --arg id "$g_node" '.nodes[$id] // empty' "$GRAPH_FILE")
        [[ -z "$g_exists" ]] && continue

        # Check edge doesn't already exist
        edge_exists=$(jq -r --arg from "$g_node" --arg to "$node_key" \
            '[.edges[] | select(.from == $from and .to == $to and .relation == "part_of")] | length' \
            "$GRAPH_FILE")
        [[ "$edge_exists" -gt 0 ]] && continue

        jq --arg from "$g_node" --arg to "$node_key" --arg created "$now" \
           '.edges += [{from: $from, to: $to, relation: "part_of", weight: 1.0, bidirectional: false, created_at: $created}]' \
           "$GRAPH_FILE" > "${GRAPH_FILE}.tmp" && mv "${GRAPH_FILE}.tmp" "$GRAPH_FILE"

        edges_created=$((edges_created + 1))
    done < <(yq -r ".concepts[] | select(.id == \"$cid\") | .grounded_by[]?" "$CONCEPTS_FILE")
done < <(yq -r '.concepts[] | [.id, .name] | @tsv' "$CONCEPTS_FILE" 2>/dev/null || true)

existing_concept_nodes=$(jq '[.nodes | to_entries[] | select(.value.data.concept_id)] | length' "$GRAPH_FILE")
echo -e "${DIM}Found ${existing_concept_nodes} concept nodes already in graph${NC}"
echo -e "${GREEN}Synced ${concepts_created} new concept nodes, ${edges_created} part_of edges${NC}"
