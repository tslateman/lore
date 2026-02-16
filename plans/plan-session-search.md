# Plan: Session Search by Content

Status: Draft

## Problem

`transfer.sh list` shows session metadata (ID, date, summary) but no way to search session content. Finding "the session where we discussed retry logic" requires manually opening each file. As sessions accumulate, this becomes untenable.

## Solution

Add `transfer.sh search <query>` that searches session content via the FTS5 index. The retrieval layer already indexes transfers — this exposes that capability through the transfer CLI.

## Implementation

### 1. Add search command to transfer.sh

```bash
# transfer/transfer.sh
case "$1" in
    # ... existing commands ...
    search)
        shift
        search_sessions "$@"
        ;;
esac
```

### 2. Search function using FTS5 index

```bash
# transfer/lib/search.sh
search_sessions() {
    local query="$1"
    local limit="${2:-10}"
    
    if [[ ! -f "${HOME}/.lore/search.db" ]]; then
        echo "Search index not built. Run: lore search --rebuild" >&2
        return 1
    fi
    
    sqlite3 "${HOME}/.lore/search.db" <<EOF
SELECT 
    session_id,
    substr(handoff, 1, 100) || '...' as preview,
    timestamp,
    bm25(transfers) as score
FROM transfers 
WHERE transfers MATCH '${query}'
ORDER BY score
LIMIT ${limit};
EOF
}
```

### 3. Fallback grep for unindexed content

If FTS5 index is stale or missing, fall back to grep over session files:

```bash
search_sessions_fallback() {
    local query="$1"
    local sessions_dir="${LORE_DIR}/transfer/data/sessions"
    
    grep -l -i "${query}" "${sessions_dir}"/*.json 2>/dev/null | while read -r file; do
        local id summary
        id=$(jq -r '.id' "${file}")
        summary=$(jq -r '.summary // .handoff.message // "No summary"' "${file}")
        printf "%s\t%s\n" "${id}" "${summary}"
    done
}
```

### 4. Search output format

```
$ transfer.sh search "retry logic"
session-20260215-143022  Implemented retry with exponential backoff...  2026-02-15
session-20260210-091545  Discussed error handling patterns...           2026-02-10
```

## Integration with lore search

`lore search` already searches transfers. This plan adds the same capability to `transfer.sh` for users who think in terms of sessions rather than the unified search.

## Verification

```bash
# Index must exist
lore search --rebuild

# Search by content
transfer.sh search "authentication"

# Search with limit
transfer.sh search "refactor" 5
```
