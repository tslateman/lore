#!/usr/bin/env bash
set -euo pipefail
trap 'exit 0' ERR

# Auto-inject lore context into Claude Code sessions (UserPromptSubmit hook).
#
# Queries the FTS5 search index for project-relevant context.
# Requires search.db — run 'lore index build' to create it.

LORE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LORE_DIR="${LORE_ROOT}"
source "${LORE_ROOT}/lib/paths.sh"
BUDGET=2000
SEARCH_DB="${LORE_SEARCH_DB}"

input=$(cat)
cwd=$(echo "$input" | jq -r '.cwd // ""')
prompt=$(echo "$input" | jq -r '.prompt // ""')
[[ -z "$cwd" ]] && exit 0

# --- Project Detection ---
# Try .claude/project.yaml, then git remote, then path-based fallback
derive_project() {
    local dir="$1"
    
    # Method 1: .claude/project.yaml
    if [[ -f "$dir/.claude/project.yaml" ]]; then
        local name
        name=$(yq -r '.project.name // ""' "$dir/.claude/project.yaml" 2>/dev/null) || true
        [[ -n "$name" ]] && { echo "$name"; return; }
    fi
    
    # Method 2: git remote
    if git -C "$dir" rev-parse --git-dir >/dev/null 2>&1; then
        local remote
        remote=$(git -C "$dir" remote get-url origin 2>/dev/null) || true
        if [[ -n "$remote" ]]; then
            echo "$(basename "${remote%.git}")"
            return
        fi
    fi
    
    # Method 3: directory name fallback
    basename "$dir"
}

project=$(derive_project "$cwd")
[[ -z "$project" ]] && exit 0

# --- Keyword Extraction ---
stopwords=" a the is to in for of on it do be has was are with that this from not but what why how can should would does i my we our you your "
keywords=()
kw_count=0
for word in $(echo "$prompt" | tr '[:upper:]' '[:lower:]' | tr -cs '[:alnum:]' ' '); do
    [[ ${#word} -lt 3 ]] && continue
    [[ "$stopwords" == *" $word "* ]] && continue
    keywords+=("$word")
    kw_count=$((kw_count + 1))
    [[ $kw_count -ge 8 ]] && break
done

# --- Compact FTS5 Path (progressive disclosure) ---
# When search.db exists, use compact one-line-per-result format.
# Agents fetch full details on demand via lore_search / lore_context MCP tools.
if [[ -f "$SEARCH_DB" ]] && [[ ${#keywords[@]} -gt 0 ]]; then
    keywords_joined=""
    for kw in "${keywords[@]}"; do
        [[ -n "$keywords_joined" ]] && keywords_joined+=" OR "
        keywords_joined+="$kw"
    done

    compact_results=$("$LORE_ROOT/lore.sh" search "$keywords_joined" \
        --compact 2>/dev/null) || true

    if [[ -n "$compact_results" ]]; then
        item_count=$(echo "$compact_results" | wc -l | tr -d ' ')

        output="--- lore context (compact index, $item_count items) ---"$'\n'
        output+="Use lore_search or lore_context MCP tools to fetch full details for any ID."$'\n'
        output+=$'\n'
        output+="$compact_results"$'\n'
        output+="--- end lore context ---"

        used=${#output}
        echo "lore: injected $item_count items ($used chars, compact) for project '$project'" >&2

        jq -n \
            --arg ctx "$output" \
            --argjson injected "$item_count" \
            --argjson used "$used" \
            --argjson budget "$BUDGET" \
            --arg project "$project" \
            '{
                hookSpecificOutput: {
                    additionalContext: $ctx,
                    metadata: {
                        source: "lore",
                        items_injected: $injected,
                        budget_used: $used,
                        budget_total: $budget,
                        project: $project,
                        mode: "compact"
                    }
                }
            }'
        exit 0
    fi
fi

# No search index available
echo "lore: search.db not found. Run 'lore index build' to enable context injection." >&2
exit 0
