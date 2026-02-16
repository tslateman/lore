#!/usr/bin/env bash
set -euo pipefail

# Export Lore data as synthetic Claude Code sessions for mnemo indexing.
#
# Creates ~/.claude/projects/-lore-knowledge/ with JSONL files that mnemo
# can index. Each Lore data type (journal, patterns, etc.) becomes a session.

LORE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SYNTHETIC_PROJECT="$HOME/.claude/projects/-lore-knowledge"
SESSION_BASE_UUID="00000000-0000-0000-0000"

# Clean and recreate synthetic project directory
rm -rf "$SYNTHETIC_PROJECT"
mkdir -p "$SYNTHETIC_PROJECT"

# Generate session UUID (deterministic per source file)
session_uuid() {
    local source="$1"
    local hash
    hash=$(echo "$source" | md5 | cut -c1-12)
    echo "${SESSION_BASE_UUID}-${hash}"
}

# Generate message UUID (deterministic per line number)
msg_uuid() {
    local session_uuid="$1"
    local line_num="$2"
    printf "%s-%04d" "${session_uuid:0:32}" "$line_num"
}

# Write JSONL message with Claude Code format
write_message() {
    local session_uuid="$1"
    local msg_uuid="$2"
    local role="$3"
    local content="$4"
    local timestamp="$5"

    jq -nc \
        --arg sid "$session_uuid" \
        --arg uuid "$msg_uuid" \
        --arg role "$role" \
        --arg content "$content" \
        --arg ts "$timestamp" \
        '{
            sessionId: $sid,
            uuid: $uuid,
            timestamp: $ts,
            type: (if $role == "user" then "user" else "assistant" end),
            message: {
                role: $role,
                content: $content
            },
            cwd: "/Users/tslater/dev/lore",
            version: "synthetic",
            isSidechain: false
        }'
}

# Export journal (decisions.jsonl)
export_journal() {
    local journal_file="$LORE_ROOT/journal/data/decisions.jsonl"
    [[ ! -f "$journal_file" ]] && return 0

    local session_uuid
    session_uuid=$(session_uuid "journal")
    local output_file="$SYNTHETIC_PROJECT/${session_uuid}.jsonl"

    local line_num=0
    while IFS= read -r line; do
        line_num=$((line_num + 1))

        local decision rationale timestamp tags id
        decision=$(echo "$line" | jq -r '.decision // ""')
        rationale=$(echo "$line" | jq -r '.rationale // ""')
        timestamp=$(echo "$line" | jq -r '.timestamp // ""')
        tags=$(echo "$line" | jq -r '.tags // [] | join(", ")')
        id=$(echo "$line" | jq -r '.id // ""')

        [[ -z "$decision" ]] && continue

        # User message: the decision
        local user_content="[decision] $decision"
        [[ -n "$tags" ]] && user_content+=" (tags: $tags)"
        write_message "$session_uuid" "$(msg_uuid "$session_uuid" $((line_num * 2 - 1)))" "user" "$user_content" "$timestamp" >> "$output_file"

        # Assistant message: the rationale
        if [[ -n "$rationale" && "$rationale" != "null" ]]; then
            local asst_content="Rationale: $rationale"
            [[ -n "$id" ]] && asst_content+=" (ID: $id)"
            write_message "$session_uuid" "$(msg_uuid "$session_uuid" $((line_num * 2)))" "assistant" "$asst_content" "$timestamp" >> "$output_file"
        fi
    done < "$journal_file"

    echo "Exported $(wc -l < "$output_file") journal messages to $output_file"
}

# Export patterns (patterns.yaml)
export_patterns() {
    local patterns_file="$LORE_ROOT/patterns/data/patterns.yaml"
    [[ ! -f "$patterns_file" ]] && return 0

    local session_uuid
    session_uuid=$(session_uuid "patterns")
    local output_file="$SYNTHETIC_PROJECT/${session_uuid}.jsonl"

    local pjson
    pjson=$(yq -o=json '.patterns // []' "$patterns_file" 2>/dev/null) || return 0
    local plen
    plen=$(echo "$pjson" | jq 'length')

    local i=0
    while (( i < plen )); do
        local name context problem solution confidence
        name=$(echo "$pjson" | jq -r ".[$i].name // \"\"")
        context=$(echo "$pjson" | jq -r ".[$i].context // \"\"")
        problem=$(echo "$pjson" | jq -r ".[$i].problem // \"\"")
        solution=$(echo "$pjson" | jq -r ".[$i].solution // \"\"")
        confidence=$(echo "$pjson" | jq -r ".[$i].confidence // 0")

        [[ -z "$solution" ]] && { i=$((i+1)); continue; }

        local timestamp
        timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

        # User message: problem/context
        local user_content="[pattern] $name"
        [[ -n "$context" ]] && user_content+=$'\n'"Context: $context"
        [[ -n "$problem" ]] && user_content+=$'\n'"Problem: $problem"
        write_message "$session_uuid" "$(msg_uuid "$session_uuid" $((i * 2 + 1)))" "user" "$user_content" "$timestamp" >> "$output_file"

        # Assistant message: solution
        local asst_content="Solution: $solution (confidence: $confidence)"
        write_message "$session_uuid" "$(msg_uuid "$session_uuid" $((i * 2 + 2)))" "assistant" "$asst_content" "$timestamp" >> "$output_file"

        i=$((i+1))
    done

    echo "Exported $(wc -l < "$output_file") pattern messages to $output_file"
}

# Export transfer sessions
export_transfer() {
    local sessions_dir="$LORE_ROOT/transfer/data/sessions"
    [[ ! -d "$sessions_dir" ]] && return 0

    local session_uuid
    session_uuid=$(session_uuid "transfer")
    local output_file="$SYNTHETIC_PROJECT/${session_uuid}.jsonl"

    local count=0
    for session_file in "$sessions_dir"/*.json; do
        [[ ! -f "$session_file" ]] && continue

        local handoff timestamp session_id project
        handoff=$(jq -r '.handoff.message // ""' "$session_file")
        timestamp=$(jq -r '.ended_at // ""' "$session_file")
        session_id=$(jq -r '.id // "unknown"' "$session_file")
        project=$(jq -r '.project // ""' "$session_file")

        [[ -z "$handoff" ]] && continue

        count=$((count + 1))

        # User message: session info
        local user_content="[handoff] $session_id"
        [[ -n "$project" ]] && user_content+=" (project: $project)"
        write_message "$session_uuid" "$(msg_uuid "$session_uuid" $((count * 2 - 1)))" "user" "$user_content" "$timestamp" >> "$output_file"

        # Assistant message: handoff note
        write_message "$session_uuid" "$(msg_uuid "$session_uuid" $((count * 2)))" "assistant" "$handoff" "$timestamp" >> "$output_file"
    done

    [[ -f "$output_file" ]] && echo "Exported $(wc -l < "$output_file") transfer messages to $output_file"
}

# Main
echo "Exporting Lore data to $SYNTHETIC_PROJECT"
export_journal
export_patterns
export_transfer

echo "Done. Run 'mnemo index' to index the synthetic sessions."
