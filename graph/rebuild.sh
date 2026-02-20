#!/usr/bin/env bash
# Rebuild graph from all flat-file sources.
#
# Destructive: replaces graph.json entirely. The graph is a derived
# projection — flat files (journal, patterns, failures, sessions,
# projects, goals, observations) are the source of truth.
#
# Usage: graph/rebuild.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LORE_DIR="${LORE_DIR:-$(dirname "$SCRIPT_DIR")}"
source "${LORE_DIR}/lib/paths.sh"
GRAPH_FILE="${LORE_GRAPH_FILE}"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

command -v jq &>/dev/null || { echo -e "${RED}jq required${NC}"; exit 1; }

echo -e "${BOLD}Rebuilding graph from flat-file sources...${NC}"
echo ""

# Back up current graph
if [[ -f "$GRAPH_FILE" ]]; then
    cp "$GRAPH_FILE" "${GRAPH_FILE}.bak"
    echo -e "${DIM}Backed up existing graph to graph.json.bak${NC}"
fi

# Reset graph to empty
mkdir -p "$(dirname "$GRAPH_FILE")"
echo '{"nodes":{},"edges":[]}' > "$GRAPH_FILE"

# Track sources processed
sources=0

# 1. Sync decisions
echo -e "${BOLD}[1/7] Decisions${NC}"
if bash "${SCRIPT_DIR}/sync.sh"; then
    sources=$((sources + 1))
fi
echo ""

# 2. Sync patterns
echo -e "${BOLD}[2/7] Patterns${NC}"
if bash "${SCRIPT_DIR}/sync-patterns.sh"; then
    sources=$((sources + 1))
fi
echo ""

# 3. Sync failures
echo -e "${BOLD}[3/7] Failures${NC}"
if bash "${SCRIPT_DIR}/sync-failures.sh"; then
    sources=$((sources + 1))
fi
echo ""

# 4. Sync sessions
echo -e "${BOLD}[4/7] Sessions${NC}"
if bash "${SCRIPT_DIR}/sync-sessions.sh"; then
    sources=$((sources + 1))
fi
echo ""

# 5. Sync projects
echo -e "${BOLD}[5/7] Projects${NC}"
if bash "${SCRIPT_DIR}/sync-projects.sh"; then
    sources=$((sources + 1))
fi
echo ""

# 6. Sync goals
echo -e "${BOLD}[6/7] Goals${NC}"
if bash "${SCRIPT_DIR}/sync-goals.sh"; then
    sources=$((sources + 1))
fi
echo ""

# 7. Sync observations
echo -e "${BOLD}[7/7] Observations${NC}"
if bash "${SCRIPT_DIR}/sync-observations.sh"; then
    sources=$((sources + 1))
fi
echo ""

# Normalize edge spelling: related_to -> relates_to
related_to_count=$(jq '[.edges[] | select(.relation == "related_to")] | length' "$GRAPH_FILE")
if [[ "$related_to_count" -gt 0 ]]; then
    jq '.edges |= map(if .relation == "related_to" then .relation = "relates_to" else . end)' \
        "$GRAPH_FILE" > "${GRAPH_FILE}.tmp" && mv "${GRAPH_FILE}.tmp" "$GRAPH_FILE"
    echo -e "${YELLOW}Normalized ${related_to_count} 'related_to' edges to 'relates_to'${NC}"
fi

# Deduplicate edges
dup_count=$(jq '[.edges | group_by(.from + .to + .relation) | .[] | select(length > 1)] | length' "$GRAPH_FILE")
if [[ "$dup_count" -gt 0 ]]; then
    before_edges=$(jq '.edges | length' "$GRAPH_FILE")
    jq '.edges = [.edges | group_by(.from + .to + .relation) | .[] | .[0]]' \
        "$GRAPH_FILE" > "${GRAPH_FILE}.tmp" && mv "${GRAPH_FILE}.tmp" "$GRAPH_FILE"
    after_edges=$(jq '.edges | length' "$GRAPH_FILE")
    echo -e "${YELLOW}Removed $((before_edges - after_edges)) duplicate edges${NC}"
fi

# Report
node_count=$(jq '.nodes | length' "$GRAPH_FILE")
edge_count=$(jq '.edges | length' "$GRAPH_FILE")

echo -e "${GREEN}${BOLD}Rebuilt graph: ${node_count} nodes, ${edge_count} edges from ${sources} sources${NC}"
