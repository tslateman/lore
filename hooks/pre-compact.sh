#!/usr/bin/env bash
set -euo pipefail
trap 'exit 0' ERR

LORE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TRANSFER_ROOT="$LORE_ROOT/transfer"
SESSIONS_DIR="$TRANSFER_ROOT/data/sessions"
CURRENT_SESSION_FILE="$TRANSFER_ROOT/data/.current_session"

# Source snapshot utilities
source "$TRANSFER_ROOT/lib/snapshot.sh"

# Read hook input
input=$(cat)
cwd=$(echo "$input" | jq -r '.cwd // ""')

BUDGET=3000
output=""

# --- Gather signals ---

# Git state
git_branch=""
git_commits=""
git_uncommitted=""
if [[ -n "$cwd" ]] && git -C "$cwd" rev-parse --git-dir &>/dev/null; then
    git_branch=$(git -C "$cwd" branch --show-current 2>/dev/null || echo "")
    git_commits=$(git -C "$cwd" log --oneline -5 2>/dev/null || true)
    git_uncommitted=$(git -C "$cwd" status --porcelain 2>/dev/null | awk '{print $2}' | head -10 | tr '\n' ',' | sed 's/,$//' || true)
fi

# Current session
session_id=""
session_summary=""
open_threads=""
handoff_msg=""
session_file=""
if [[ -f "$CURRENT_SESSION_FILE" ]]; then
    session_id=$(cat "$CURRENT_SESSION_FILE")
    session_file="$SESSIONS_DIR/${session_id}.json"
    if [[ -f "$session_file" ]]; then
        session_summary=$(jq -r '.summary // ""' "$session_file" 2>/dev/null)
        open_threads=$(jq -r '.open_threads[]? // empty' "$session_file" 2>/dev/null | head -5)
        handoff_msg=$(jq -r '.handoff.message // ""' "$session_file" 2>/dev/null)
    fi
fi

# Recent active decisions (last 5)
decisions=""
decisions_file="$LORE_ROOT/journal/data/decisions.jsonl"
if [[ -f "$decisions_file" ]]; then
    decisions=$(jq -s '
        group_by(.id) | map(.[-1])
        | map(select((.status // "active") == "active"))
        | sort_by(.timestamp) | reverse | .[0:5]
        | .[] | "\(.id): \(.decision[0:70])"
    ' "$decisions_file" 2>/dev/null || true)
fi

# Recent patterns (last 3 names)
patterns=""
patterns_file="$LORE_ROOT/patterns/data/patterns.yaml"
if [[ -f "$patterns_file" ]] && command -v yq &>/dev/null; then
    patterns=$(yq -o=json '.patterns' "$patterns_file" 2>/dev/null \
        | jq -r 'sort_by(.created_at) | reverse | .[0:3] | .[].name' 2>/dev/null || true)
fi

# --- Write auto-snapshot to session (side effect) ---
if [[ -n "$session_id" && -n "$session_file" && -f "$session_file" ]]; then
    git_state_json=$(capture_git_state "${cwd:-.}")
    tmp_file=$(mktemp)
    jq --argjson git "$git_state_json" \
       --arg time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
       '
       .pre_compact_snapshot = { git_state: $git, captured_at: $time } |
       if (.handoff.message // "") == "" then
           .handoff.message = "Auto-captured before context compression" |
           .handoff.created_at = $time
       else . end
       ' "$session_file" > "$tmp_file"
    mv "$tmp_file" "$session_file"
fi

# --- Build compact output ---
output="--- lore pre-compact context ---"
[[ -n "$session_id" ]] && output+=$'\n'"Session: $session_id"
[[ -n "$git_branch" ]] && output+=$'\n'"Branch: $git_branch"
[[ -n "$git_uncommitted" ]] && output+=$'\n'"Uncommitted: $git_uncommitted"

if [[ -n "$git_commits" ]]; then
    output+=$'\n\n'"Recent commits:"
    while IFS= read -r line; do
        output+=$'\n'"  $line"
    done <<< "$git_commits"
fi

if [[ -n "$decisions" ]]; then
    output+=$'\n\n'"Active decisions:"
    while IFS= read -r line; do
        [[ -n "$line" ]] && output+=$'\n'"  - $line"
    done <<< "$decisions"
fi

if [[ -n "$patterns" ]]; then
    output+=$'\n\n'"Recent patterns:"
    while IFS= read -r line; do
        [[ -n "$line" ]] && output+=$'\n'"  - $line"
    done <<< "$patterns"
fi

if [[ -n "$open_threads" ]]; then
    output+=$'\n\n'"Open threads:"
    while IFS= read -r line; do
        [[ -n "$line" ]] && output+=$'\n'"  - $line"
    done <<< "$open_threads"
fi

[[ -n "$handoff_msg" ]] && output+=$'\n\n'"Handoff: $handoff_msg"
[[ -n "$session_summary" ]] && output+=$'\n'"Summary: $session_summary"

output+=$'\n'"--- end lore pre-compact context ---"

# Truncate to budget
output="${output:0:$BUDGET}"

used=${#output}
echo "lore: pre-compact captured ($used chars)" >&2

jq -n \
    --arg ctx "$output" \
    --argjson used "$used" \
    --argjson budget "$BUDGET" \
    --arg session "$session_id" \
    '{
        hookSpecificOutput: {
            additionalContext: $ctx,
            metadata: {
                source: "lore",
                hook: "pre-compact",
                budget_used: $used,
                budget_total: $budget,
                session: $session
            }
        }
    }'
