#!/usr/bin/env bash
# paths.sh - Central path resolution for Lore
#
# Sources once (idempotency guard). Exports LORE_DATA_DIR and
# per-component data directory variables. When LORE_DATA_DIR is unset,
# defaults to LORE_DIR (the repo itself) — zero behavior change.

[[ -n "${_LORE_PATHS_LOADED:-}" ]] && return 0
_LORE_PATHS_LOADED=1

LORE_DIR="${LORE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
export LORE_DATA_DIR="${LORE_DATA_DIR:-${LORE_DIR}}"

# Per-component data directories
export LORE_JOURNAL_DATA="${LORE_DATA_DIR}/journal/data"
export LORE_PATTERNS_DATA="${LORE_DATA_DIR}/patterns/data"
export LORE_FAILURES_DATA="${LORE_DATA_DIR}/failures/data"
export LORE_INBOX_DATA="${LORE_DATA_DIR}/inbox/data"
export LORE_INTENT_DATA="${LORE_DATA_DIR}/intent/data"
export LORE_GRAPH_DATA="${LORE_DATA_DIR}/graph/data"
export LORE_REGISTRY_DATA="${LORE_DIR}/registry/data"

# Transfer supports a more specific override via LORE_TRANSFER_ROOT
if [[ -n "${LORE_TRANSFER_ROOT:-}" ]]; then
    export LORE_TRANSFER_DATA="${LORE_TRANSFER_ROOT}/data"
else
    export LORE_TRANSFER_DATA="${LORE_DATA_DIR}/transfer/data"
fi

# Frequently cross-referenced files
export LORE_DECISIONS_FILE="${LORE_JOURNAL_DATA}/decisions.jsonl"
export LORE_PATTERNS_FILE="${LORE_PATTERNS_DATA}/patterns.yaml"
export LORE_GRAPH_FILE="${LORE_GRAPH_DATA}/graph.json"

# Search DB: under LORE_DATA_DIR when externalized, else legacy ~/.lore/
if [[ -n "${LORE_SEARCH_DB:-}" ]]; then
    export LORE_SEARCH_DB
elif [[ "${LORE_DATA_DIR}" != "${LORE_DIR}" ]]; then
    export LORE_SEARCH_DB="${LORE_DATA_DIR}/search.db"
else
    export LORE_SEARCH_DB="${HOME}/.lore/search.db"
fi
