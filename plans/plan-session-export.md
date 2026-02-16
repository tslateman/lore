# Plan: Export Sessions to Markdown

Status: Draft

## Problem

Sessions are JSON — great for machines, awkward for humans. Sharing session history, reviewing past work, or including session context in documentation requires manual extraction. Journal already has `export --format markdown`; transfer should match.

## Solution

Add `transfer.sh export <session-id> [--format markdown|json]` that renders sessions as readable markdown. Default to markdown for human use; JSON for machine piping.

## Implementation

### 1. Add export command

```bash
# transfer/transfer.sh
case "$1" in
    # ... existing commands ...
    export)
        shift
        export_session "$@"
        ;;
esac
```

### 2. Export function

```bash
# transfer/lib/export.sh
export_session() {
    local session_id="${1:-}"
    local format="${2:-markdown}"
    
    local session_file
    session_file=$(find_session "${session_id}")
    
    if [[ -z "${session_file}" ]]; then
        echo "Session not found: ${session_id}" >&2
        return 1
    fi
    
    case "${format}" in
        markdown|md) export_markdown "${session_file}" ;;
        json)        cat "${session_file}" ;;
        *)           echo "Unknown format: ${format}" >&2; return 1 ;;
    esac
}
```

### 3. Markdown template

```bash
export_markdown() {
    local file="$1"
    
    local id summary started ended
    id=$(jq -r '.id' "${file}")
    summary=$(jq -r '.summary // "No summary"' "${file}")
    started=$(jq -r '.started_at' "${file}")
    ended=$(jq -r '.ended_at // "In progress"' "${file}")
    
    cat <<EOF
# Session: ${id}

**Started:** ${started}
**Ended:** ${ended}

## Summary

${summary}

## Goals Addressed

$(jq -r '.goals_addressed[]? | "- " + .' "${file}")

## Decisions Made

$(jq -r '.decisions_made[]? | "- " + .' "${file}")

## Patterns Learned

$(jq -r '.patterns_learned[]? | "- " + .' "${file}")

## Open Threads

$(jq -r '.open_threads[]? | "- [ ] " + .' "${file}")

## Handoff

$(jq -r '.handoff.message // "No handoff note"' "${file}")

### Next Steps

$(jq -r '.handoff.next_steps[]? | "1. " + .' "${file}")

### Blockers

$(jq -r '.handoff.blockers[]? | "- " + .' "${file}" | grep -v '^$' || echo "None")

### Open Questions

$(jq -r '.handoff.questions[]? | "- " + .' "${file}")

## Git State

- **Branch:** $(jq -r '.git_state.branch // "unknown"' "${file}")
- **Uncommitted files:** $(jq -r '.git_state.uncommitted | length' "${file}")

EOF
}
```

### 4. Export all sessions

```bash
export_all() {
    local output_dir="${1:-.}"
    local sessions_dir="${LORE_DIR}/transfer/data/sessions"
    
    for file in "${sessions_dir}"/*.json; do
        local id
        id=$(jq -r '.id' "${file}")
        export_markdown "${file}" > "${output_dir}/${id}.md"
    done
}
```

## Usage

```bash
# Export single session to stdout
transfer.sh export session-20260215-143022

# Export to file
transfer.sh export session-20260215-143022 > session-report.md

# Export as JSON (passthrough)
transfer.sh export session-20260215-143022 --format json

# Export all sessions to directory
transfer.sh export --all --output ./session-exports/
```

## Verification

```bash
# Export current session
transfer.sh export "$(cat ~/.lore/.current_session)"

# Verify markdown renders correctly
transfer.sh export session-example | head -50
```
