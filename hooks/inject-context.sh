#!/usr/bin/env bash
set -euo pipefail
trap 'exit 0' ERR

# Auto-inject lore context into Claude Code sessions (UserPromptSubmit hook).
#
# Improvements over naive grep:
# - Project scoping via git remote or .claude/project.yaml (not path manipulation)
# - Score-based ranking (confidence * temporal decay), then budget-cap
# - Transparent injection (stderr log + metadata in output)

LORE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PATTERNS_FILE="$LORE_ROOT/patterns/data/patterns.yaml"
JOURNAL_FILE="$LORE_ROOT/journal/data/decisions.jsonl"
SESSIONS_DIR="$LORE_ROOT/transfer/data/sessions"
BUDGET=1500

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

# --- Scored Matches Collection ---
# Arrays to hold matches with scores for later sorting
declare -a match_entries=()
declare -a match_scores=()
match_count=0

# Calculate score: base * confidence * temporal_decay
# Returns integer score (0-1000 scale)
calc_score() {
    local confidence="${1:-0.5}"
    local timestamp="${2:-}"
    local base=100
    
    # Confidence factor (0.5 to 1.0 maps to 50-100)
    local conf_factor
    conf_factor=$(awk -v c="$confidence" 'BEGIN {printf "%.0f", c * 100}')
    
    # Temporal decay: 1/(1 + days_old/30), scaled to 0-100
    local decay=100
    if [[ -n "$timestamp" && "$timestamp" != "null" ]]; then
        local ts_epoch now_epoch days_old
        # Extract just the date part (YYYY-MM-DD) to avoid time parsing issues
        local date_part="${timestamp%%T*}"
        ts_epoch=$(date -j -f "%Y-%m-%d" "$date_part" +%s 2>/dev/null) || ts_epoch=0
        now_epoch=$(date +%s)
        if [[ $ts_epoch -gt 0 ]]; then
            days_old=$(( (now_epoch - ts_epoch) / 86400 ))
            decay=$(awk -v d="$days_old" 'BEGIN {printf "%.0f", 100 / (1 + d / 30)}')
        fi
    fi
    
    # Combined score
    echo $(( base * conf_factor * decay / 10000 ))
}

add_match() {
    local entry="$1"
    local score="$2"
    match_entries+=("$entry")
    match_scores+=("$score")
    match_count=$((match_count + 1))
}

# --- Query Functions ---

query_patterns() {
    [[ ! -f "$PATTERNS_FILE" ]] && return 0
    local pjson
    pjson=$(yq -o=json '.patterns // []' "$PATTERNS_FILE" 2>/dev/null) || return 0
    local plen
    plen=$(echo "$pjson" | jq 'length') || return 0

    local i=0
    while (( i < plen )); do
        # Extract fields individually to handle multi-line content
        local name ctx problem solution confidence timestamp
        name=$(echo "$pjson" | jq -r ".[$i].name // \"\"") || { i=$((i+1)); continue; }
        ctx=$(echo "$pjson" | jq -r ".[$i].context // \"\"") || ctx=""
        problem=$(echo "$pjson" | jq -r ".[$i].problem // \"\"") || problem=""
        solution=$(echo "$pjson" | jq -r ".[$i].solution // \"\"") || solution=""
        confidence=$(echo "$pjson" | jq -r ".[$i].confidence // 0.5") || confidence="0.5"
        timestamp=$(echo "$pjson" | jq -r ".[$i].created_at // \"\"") || timestamp=""
        
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
            local score
            score=$(calc_score "$confidence" "$timestamp")
            add_match "$entry" "$score"
        fi
        i=$((i+1))
    done
}

query_journal() {
    [[ ! -f "$JOURNAL_FILE" ]] && return 0
    
    # Get recent decisions matching project (last 10, then filter)
    local matches
    matches=$(grep -i "$project" "$JOURNAL_FILE" 2>/dev/null | tail -10) || return 0
    [[ -z "$matches" ]] && return 0

    while IFS= read -r line; do
        local fields
        fields=$(echo "$line" | jq -r '[.id//"", .timestamp//"", .decision//"", .rationale//""] | @tsv') || continue
        IFS=$'\t' read -r id timestamp decision rationale <<< "$fields"
        [[ -z "$decision" ]] && continue
        
        local ts_display="${timestamp%%T*}"
        local entry=$'\n'"[decision] $id ($ts_display)"$'\n'"  $decision"
        [[ -n "$rationale" && "$rationale" != "null" ]] && entry+=" -- $rationale"
        entry+=$'\n'
        
        # Decisions have base confidence 0.7
        local score
        score=$(calc_score "0.7" "$timestamp")
        add_match "$entry" "$score"
    done <<< "$matches"
}

query_transfer() {
    [[ ! -d "$SESSIONS_DIR" ]] && return 0
    local latest
    latest=$(ls -t "$SESSIONS_DIR"/*.json 2>/dev/null | grep -v compressed | grep -v example | head -1) || return 0
    [[ -z "$latest" ]] && return 0
    local handoff
    handoff=$(jq -r '.handoff.message // ""' "$latest" 2>/dev/null) || return 0
    [[ -z "$handoff" ]] && return 0
    
    # Check if handoff mentions project or keywords
    local searchable
    searchable=$(echo "$handoff" | tr '[:upper:]' '[:lower:]')
    local matched=false
    echo "$searchable" | grep -qi "$project" 2>/dev/null && matched=true
    if ! $matched; then
        for kw in "${keywords[@]+"${keywords[@]}"}"; do
            echo "$searchable" | grep -qi "$kw" 2>/dev/null && { matched=true; break; }
        done
    fi
    [[ "$matched" == false ]] && return 0

    local fields timestamp
    fields=$(jq -r '[.id//"unknown", .ended_at//""] | @tsv' "$latest" 2>/dev/null) || return 0
    IFS=$'\t' read -r session_id timestamp <<< "$fields"
    local ts_display="${timestamp%%T*}"
    local entry=$'\n'"[handoff] $session_id ($ts_display)"$'\n'"  $handoff"$'\n'
    
    # Handoffs have high relevance (confidence 0.9) since they're session context
    local score
    score=$(calc_score "0.9" "$timestamp")
    add_match "$entry" "$score"
}

# --- Collect All Matches ---
query_patterns
query_journal
query_transfer

[[ $match_count -eq 0 ]] && exit 0

# --- Sort by Score and Budget-Cap ---
results=""
used=0
injected=0

# Create sorted index array (descending by score)
sorted_indices=()
for i in "${!match_scores[@]}"; do
    sorted_indices+=("${match_scores[$i]}:$i")
done
IFS=$'\n' sorted_indices=($(sort -t: -k1 -rn <<< "${sorted_indices[*]}")); unset IFS

# Add matches in score order until budget exhausted
for item in "${sorted_indices[@]}"; do
    idx="${item#*:}"
    entry="${match_entries[$idx]}"
    len=${#entry}
    
    if (( used + len <= BUDGET )); then
        results+="$entry"
        used=$((used + len))
        injected=$((injected + 1))
    fi
done

[[ -z "$results" ]] && exit 0

# --- Transparent Output ---
# Log to stderr so user can see what was injected
echo "lore: injected $injected items ($used/$BUDGET chars) for project '$project'" >&2

output="--- lore context (auto-injected, $injected items) ---"$'\n'"$results"$'\n'"--- end lore context ---"

# Include metadata in hook output
jq -n \
    --arg ctx "$output" \
    --argjson injected "$injected" \
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
                project: $project
            }
        }
    }'
