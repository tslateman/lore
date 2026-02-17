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

# Generate a node ID matching the existing pattern: type-<8char hash of name>
_node_id() {
    local type="$1"
    local name="$2"
    echo "${type}-$(echo -n "${name}" | md5sum | cut -c1-8)"
}

# Truncate text to N chars
_truncate() {
    local text="$1"
    local max="${2:-120}"
    if [[ "${#text}" -gt "$max" ]]; then
        echo "${text:0:$max}"
    else
        echo "$text"
    fi
}

now="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

# --- Step 1: Deduplicate decisions by ID (keep last occurrence, most complete) ---
# Build a map of unique decision IDs -> full JSON line
declare -A decision_map
while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    dec_id=$(echo "$line" | jq -r '.id // empty' 2>/dev/null) || continue
    [[ -z "$dec_id" ]] && continue
    decision_map["$dec_id"]="$line"
done < "$DECISIONS_FILE"

echo -e "${DIM}Found ${#decision_map[@]} unique decisions in journal${NC}"

# --- Step 2: Collect existing journal_id values from graph ---
existing_journal_ids=$(jq -r '
    [.nodes | to_entries[] | select(.value.data.journal_id != null) | .value.data.journal_id] | .[]
' "$GRAPH_FILE") || true

declare -A existing_ids
while IFS= read -r eid; do
    [[ -z "$eid" ]] && continue
    existing_ids["$eid"]=1
done <<< "$existing_journal_ids"

echo -e "${DIM}Found ${#existing_ids[@]} decision nodes already in graph${NC}"

# --- Step 3: Build new nodes and edges to merge ---
new_decision_nodes=0
new_file_nodes=0
new_edges=0

# We'll build a single jq filter that adds all new nodes and edges at once
# to avoid repeated file I/O. Collect additions as JSON.
additions_file="$(mktemp)"
trap 'rm -f "$additions_file"' EXIT

echo '{"nodes":{},"edges":[]}' > "$additions_file"

# Track file nodes we create in this run to avoid duplicates
declare -A created_file_nodes

for dec_id in "${!decision_map[@]}"; do
    # Skip if already in graph
    if [[ -n "${existing_ids[$dec_id]:-}" ]]; then
        continue
    fi

    line="${decision_map[$dec_id]}"

    # Extract fields
    decision_text=$(echo "$line" | jq -r '.decision // ""')
    timestamp=$(echo "$line" | jq -r '.timestamp // ""')
    entities_json=$(echo "$line" | jq -c '.entities // []')
    related_json=$(echo "$line" | jq -c '.related_decisions // []')

    truncated=$(_truncate "$decision_text" 120)

    # Node key: decision-<hash of dec_id>
    node_key=$(_node_id "decision" "$dec_id")

    # Use decision timestamp or now
    created="${timestamp:-$now}"

    # Add decision node
    jq --arg key "$node_key" \
       --arg name "$dec_id" \
       --arg journal_id "$dec_id" \
       --arg decision "$truncated" \
       --arg created "$created" \
       --arg updated "$now" \
       '.nodes[$key] = {
           type: "decision",
           name: $name,
           data: { journal_id: $journal_id, decision: $decision },
           created_at: $created,
           updated_at: $updated
       }' "$additions_file" > "${additions_file}.tmp" && mv "${additions_file}.tmp" "$additions_file"

    new_decision_nodes=$((new_decision_nodes + 1))

    # --- Create file nodes and reference edges for entities ---
    entity_count=$(echo "$entities_json" | jq 'length')
    if [[ "$entity_count" -gt 0 ]]; then
        for i in $(seq 0 $((entity_count - 1))); do
            entity=$(echo "$entities_json" | jq -r ".[$i]")
            [[ -z "$entity" || "$entity" == "null" ]] && continue

            file_key=$(_node_id "file" "$entity")

            # Create file node if not already created (this run or existing)
            existing_file_node=$(jq -r --arg key "$file_key" '.nodes[$key] // empty' "$GRAPH_FILE" 2>/dev/null) || true
            if [[ -z "$existing_file_node" && -z "${created_file_nodes[$file_key]:-}" ]]; then
                # Infer language from extension
                local_ext="${entity##*.}"
                if [[ "$local_ext" == "$entity" ]]; then
                    # No extension (likely a directory)
                    local_ext="${entity##*/}"
                fi

                jq --arg key "$file_key" \
                   --arg name "$entity" \
                   --arg path "$entity" \
                   --arg lang "$local_ext" \
                   --arg created "$created" \
                   --arg updated "$now" \
                   '.nodes[$key] = {
                       type: "file",
                       name: $name,
                       data: { path: $path, language: $lang },
                       created_at: $created,
                       updated_at: $updated
                   }' "$additions_file" > "${additions_file}.tmp" && mv "${additions_file}.tmp" "$additions_file"

                created_file_nodes["$file_key"]=1
                new_file_nodes=$((new_file_nodes + 1))
            fi

            # Add references edge: decision -> file
            jq --arg from "$node_key" \
               --arg to "$file_key" \
               --arg created "$created" \
               '.edges += [{
                   from: $from,
                   to: $to,
                   relation: "references",
                   weight: 1.0,
                   bidirectional: false,
                   created_at: $created
               }]' "$additions_file" > "${additions_file}.tmp" && mv "${additions_file}.tmp" "$additions_file"

            new_edges=$((new_edges + 1))
        done
    fi

    # --- Create related_to edges for related_decisions ---
    related_count=$(echo "$related_json" | jq 'length')
    if [[ "$related_count" -gt 0 ]]; then
        for i in $(seq 0 $((related_count - 1))); do
            related_id=$(echo "$related_json" | jq -r ".[$i]")
            [[ -z "$related_id" || "$related_id" == "null" ]] && continue

            related_key=$(_node_id "decision" "$related_id")

            # Add related_to edge (the target node may be created later in this run
            # or may already exist; we add the edge regardless and let the graph
            # handle dangling references gracefully)
            jq --arg from "$node_key" \
               --arg to "$related_key" \
               --arg created "$created" \
               '.edges += [{
                   from: $from,
                   to: $to,
                   relation: "relates_to",
                   weight: 1.0,
                   bidirectional: true,
                   created_at: $created
               }]' "$additions_file" > "${additions_file}.tmp" && mv "${additions_file}.tmp" "$additions_file"

            new_edges=$((new_edges + 1))
        done
    fi
done

# --- Step 4: Merge additions into graph ---
if [[ "$new_decision_nodes" -gt 0 || "$new_file_nodes" -gt 0 ]]; then
    # Deduplicate edges in additions (same from/to/relation)
    jq '.edges = [.edges | group_by(.from + .to + .relation) | .[] | .[0]]' \
        "$additions_file" > "${additions_file}.tmp" && mv "${additions_file}.tmp" "$additions_file"

    # Recount edges after dedup
    new_edges=$(jq '.edges | length' "$additions_file")

    # Also deduplicate file nodes that already exist in graph
    # (file nodes from additions whose key already exists in graph.json)
    jq -s '
        .[0] as $graph | .[1] as $additions |
        $graph |
        .nodes = (.nodes + $additions.nodes) |
        .edges = (.edges + $additions.edges)
    ' "$GRAPH_FILE" "$additions_file" > "${GRAPH_FILE}.tmp" && mv "${GRAPH_FILE}.tmp" "$GRAPH_FILE"
fi

echo -e "${GREEN}Synced ${new_decision_nodes} new decision nodes, ${new_file_nodes} new file nodes, ${new_edges} new edges${NC}"
