#!/usr/bin/env bash
set -euo pipefail
trap 'exit 0' ERR

# Auto-inject lore context into Claude Code sessions (UserPromptSubmit hook).

LORE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKSPACE_ROOT="$(dirname "$LORE_ROOT")"
PATTERNS_FILE="$LORE_ROOT/patterns/data/patterns.yaml"
JOURNAL_FILE="$LORE_ROOT/journal/data/decisions.jsonl"
SESSIONS_DIR="$LORE_ROOT/transfer/data/sessions"
BUDGET=1500

input=$(cat)
cwd=$(echo "$input" | jq -r '.cwd // ""')
prompt=$(echo "$input" | jq -r '.prompt // ""')
[[ -z "$cwd" ]] && exit 0

# Derive project from cwd
project="${cwd#"$WORKSPACE_ROOT/"}"
[[ "$project" == "$cwd" ]] && exit 0
project="${project%%/*}"
[[ -z "$project" ]] && exit 0

# Extract keywords (drop stopwords, keep up to 8)
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

# Budget accumulator
results=""
used=0
count=0

try_add() {
  local len=${#1}
  (( used + len > BUDGET )) && return 1
  results+="$1"
  used=$((used + len))
  count=$((count + 1))
}

# --- Patterns ---
query_patterns() {
  [[ ! -f "$PATTERNS_FILE" ]] && return 0
  local pjson
  pjson=$(yq -o=json '.patterns // []' "$PATTERNS_FILE" 2>/dev/null) || return 0
  local plen
  plen=$(echo "$pjson" | jq 'length') || return 0

  local i=0
  while (( i < plen )); do
    local fields
    fields=$(echo "$pjson" | jq -r ".[$i] | [.name//.\"\",.context//.\"\",.problem//.\"\",.solution//.\"\",.confidence//0] | @tsv") || { i=$((i+1)); continue; }
    IFS=$'\t' read -r name ctx problem solution confidence <<< "$fields"
    [[ -z "$solution" ]] && { i=$((i+1)); continue; }

    local searchable
    searchable=$(echo "$name $ctx $problem $solution" | tr '[:upper:]' '[:lower:]')
    local matched=false
    echo "$searchable" | grep -qi "$project" 2>/dev/null && matched=true
    if ! $matched; then
      for kw in "${keywords[@]+"${keywords[@]}"}"; do
        echo "$searchable" | grep -qi "$kw" 2>/dev/null && { matched=true; break; }
      done
    fi

    if $matched; then
      local entry=$'\n'"[pattern] $name (confidence: $confidence)"
      [[ -n "$problem" ]] && entry+=$'\n'"  Problem: $problem"
      entry+=$'\n'"  Solution: $solution"$'\n'
      try_add "$entry" || return 0
    fi
    i=$((i+1))
  done
}

# --- Journal ---
query_journal() {
  [[ ! -f "$JOURNAL_FILE" ]] && return 0
  local matches
  matches=$(grep -i "$project" "$JOURNAL_FILE" 2>/dev/null | tail -3) || return 0
  [[ -z "$matches" ]] && return 0

  while IFS= read -r line; do
    local fields
    fields=$(echo "$line" | jq -r '[.id//"", (.timestamp//""|split("T")[0]), .decision//"", .rationale//""] | @tsv') || continue
    IFS=$'\t' read -r id ts decision rationale <<< "$fields"
    local entry=$'\n'"[decision] $id ($ts)"$'\n'"  $decision"
    [[ -n "$rationale" && "$rationale" != "null" ]] && entry+=" -- $rationale"
    entry+=$'\n'
    try_add "$entry" || return 0
  done <<< "$matches"
}

# --- Transfer ---
query_transfer() {
  [[ ! -d "$SESSIONS_DIR" ]] && return 0
  local latest
  latest=$(ls -t "$SESSIONS_DIR"/*.json 2>/dev/null | head -1) || return 0
  [[ -z "$latest" ]] && return 0
  local handoff
  handoff=$(jq -r '.handoff.message // ""' "$latest" 2>/dev/null) || return 0
  [[ -z "$handoff" ]] && return 0
  echo "$handoff" | grep -qi "$project" 2>/dev/null || return 0

  local fields
  fields=$(jq -r '[.id//"unknown", (.ended_at//""|split("T")[0])] | @tsv' "$latest" 2>/dev/null) || return 0
  IFS=$'\t' read -r session_id ts <<< "$fields"
  local entry=$'\n'"[handoff] $session_id ($ts)"$'\n'"  $handoff"$'\n'
  try_add "$entry" || return 0
}

query_patterns
query_journal
query_transfer

[[ -z "$results" ]] && exit 0

output="--- lore context (auto-injected, $count items) ---"$'\n'"$results"$'\n'"--- end lore context ---"
jq -n --arg ctx "$output" '{ hookSpecificOutput: { additionalContext: $ctx } }'
