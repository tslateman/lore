#!/usr/bin/env bash
# Sync Entire CLI checkpoints to Lore journal
#
# Entire stores checkpoints on the entire/checkpoints/v1 branch with structure:
#   <prefix>/<checkpoint_id>/metadata.json     - checkpoint-level metadata
#   <prefix>/<checkpoint_id>/N/metadata.json   - session-level metadata
#
# This script reads checkpoint metadata and writes decisions to Lore's journal.
# A marker file tracks the last synced checkpoint to prevent duplicates.

set -euo pipefail

LORE_DIR="${LORE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
MARKER_FILE="${LORE_DIR}/.entire-sync-marker"
BRANCH="entire/checkpoints/v1"

# Check dependencies
command -v git &>/dev/null || { echo "git required"; exit 1; }
command -v jq &>/dev/null || { echo "jq required"; exit 1; }
[[ -x "${LORE_DIR}/lore.sh" ]] || { echo "Lore not found at ${LORE_DIR}"; exit 1; }

# Check if entire/checkpoints/v1 branch exists
if ! git show-ref --verify --quiet "refs/heads/${BRANCH}" 2>/dev/null; then
    echo "No Entire checkpoints branch found"
    exit 0
fi

# Read last synced checkpoint
last_synced=""
[[ -f "${MARKER_FILE}" ]] && last_synced=$(cat "${MARKER_FILE}")

# Find all checkpoint directories
# Structure: <2-char prefix>/<checkpoint_id>/metadata.json
checkpoint_dirs=$(git ls-tree -d -r --name-only "${BRANCH}" | grep -E '^[0-9a-f]{2}/[0-9a-f]+$' | sort)

if [[ -z "${checkpoint_dirs}" ]]; then
    echo "No checkpoints found"
    exit 0
fi

synced=0
skipped=0
last_processed=""

while IFS= read -r checkpoint_path; do
    checkpoint_id=$(basename "${checkpoint_path}")
    
    # Skip if already synced
    if [[ -n "${last_synced}" && "${checkpoint_id}" == "${last_synced}" ]]; then
        skipped=$((skipped + 1))
        continue
    fi
    if [[ -n "${last_synced}" && "${checkpoint_id}" < "${last_synced}" ]]; then
        skipped=$((skipped + 1))
        continue
    fi
    
    # Read checkpoint metadata
    metadata_file="${checkpoint_path}/metadata.json"
    metadata=$(git show "${BRANCH}:${metadata_file}" 2>/dev/null) || continue
    
    # Extract fields
    created_at=$(echo "${metadata}" | jq -r '.created_at // ""' 2>/dev/null || true)
    files_touched=$(echo "${metadata}" | jq -r '.files_touched // [] | join(", ")' 2>/dev/null || echo "")
    branch=$(echo "${metadata}" | jq -r '.branch // "unknown"' 2>/dev/null || echo "unknown")
    session_count=$(echo "${metadata}" | jq -r '.sessions // [] | length' 2>/dev/null || echo "0")
    
    # Token usage for rationale
    input_tokens=$(echo "${metadata}" | jq -r '.token_usage.input_tokens // 0' 2>/dev/null || echo "0")
    output_tokens=$(echo "${metadata}" | jq -r '.token_usage.output_tokens // 0' 2>/dev/null || echo "0")
    
    # Build summary
    summary="Entire checkpoint ${checkpoint_id}: ${session_count} session(s) on ${branch}"
    [[ -n "${files_touched}" ]] && summary="${summary}, files: ${files_touched}"
    
    # Build rationale
    rationale="Tokens: ${input_tokens} in / ${output_tokens} out"
    [[ -n "${created_at}" ]] && rationale="${rationale}. Created: ${created_at}"
    
    # Build tags
    tags="entire,checkpoint:${checkpoint_id},branch:${branch}"
    
    # Sync to Lore journal
    if "${LORE_DIR}/lore.sh" remember "${summary}" \
        --rationale "${rationale}" \
        --tags "${tags}" \
        --type "other" 2>/dev/null; then
        echo "Synced: ${checkpoint_id}"
        synced=$((synced + 1))
        last_processed="${checkpoint_id}"
    else
        echo "Warning: Failed to sync checkpoint ${checkpoint_id}, continuing..."
    fi
    
done <<< "${checkpoint_dirs}"

# Write marker outside the loop to avoid subshell issues
if [[ -n "${last_processed}" ]]; then
    echo "${last_processed}" > "${MARKER_FILE}"
fi

echo "Synced ${synced} checkpoint(s), skipped ${skipped} already-synced."
