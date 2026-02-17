# Plan: Transfer-Journal Integration

Status: Implemented
Completed: 2026-02-15

## Problem

Transfer and journal operate independently. Transfer captures `decisions_made` as plain text strings that never reach the journal. Journal entries have a `session_id` field, but it's generated independently from transfer's session IDs. Resume shows decision counts, not content. The two components that should share a session concept don't.

**Result:** Decisions recorded during a session exist in two places with no link between them. Knowledge fragments instead of compounds.

## Solution

Unify session identity. When transfer creates a session, journal entries created during that session inherit the same ID. Decisions flow from transfer to journal as proper entries with rationale and linking. Resume surfaces full decision context, not just counts.

## Changes

### 1. Shared session ID

When `transfer.sh init` starts a session, export `LORE_SESSION_ID` and write it to a shared location that journal reads.

```bash
# transfer/lib/init.sh
export LORE_SESSION_ID="${session_id}"
echo "${session_id}" > "${LORE_DIR}/.current_session"
```

```bash
# journal/lib/store.sh (modified)
get_session_id() {
    if [[ -n "${LORE_SESSION_ID:-}" ]]; then
        echo "${LORE_SESSION_ID}"
    elif [[ -f "${LORE_DIR}/.current_session" ]]; then
        cat "${LORE_DIR}/.current_session"
    else
        echo "session-$(date +%Y%m%d)-$(openssl rand -hex 4)"
    fi
}
```

### 2. Decision sync on snapshot

When `add_decision()` is called, also create a journal entry. Store the decision ID in the session, not plain text.

```bash
# transfer/lib/snapshot.sh (modified)
add_decision() {
    local decision="$1"
    local rationale="${2:-}"

    # Create journal entry
    local dec_id
    dec_id=$("${LORE_DIR}/journal/journal.sh" record "${decision}" \
        --rationale "${rationale}" \
        --session "${SESSION_ID}" \
        --quiet)

    # Store ID in session (not plain text)
    jq --arg id "${dec_id}" '.related.journal_entries += [$id]' \
        "${SESSION_FILE}" > "${SESSION_FILE}.tmp" \
        && mv "${SESSION_FILE}.tmp" "${SESSION_FILE}"
}
```

### 3. Richer resume output

When resuming, fetch and display full decision content from journal.

```bash
# transfer/lib/resume.sh (modified)
show_decisions() {
    local session_id="$1"
    local entries
    entries=$(jq -r '.related.journal_entries[]' "${SESSION_FILE}")

    if [[ -n "${entries}" ]]; then
        echo "--- Decisions Made ---"
        for dec_id in ${entries}; do
            "${LORE_DIR}/journal/journal.sh" show "${dec_id}" --brief
        done
    fi
}
```

### 4. Handoff creates journal entries

Key decisions from handoff become journal entries with `type: handoff`.

```bash
# transfer/lib/handoff.sh (modified)
create_handoff() {
    # ... existing logic ...

    # Record handoff as a journal entry
    "${LORE_DIR}/journal/journal.sh" record \
        "Session handoff: ${message}" \
        --type "handoff" \
        --rationale "Next steps: ${next_steps[*]}" \
        --session "${SESSION_ID}"
}
```

## Migration

Existing sessions keep their plain-text `decisions_made` arrays. New sessions use `related.journal_entries` with decision IDs. Resume handles both formats.

## Verification

```bash
# Start session
transfer.sh init

# Record a decision (should appear in both places)
transfer.sh snapshot "Implemented X" --decision "Use Y for Z" --rationale "Because..."

# Check journal has the entry
journal.sh list --session "$(cat ~/.lore/.current_session)"

# Resume should show full decision content
transfer.sh resume
```

## Outcome

Implemented as planned. `transfer/lib/snapshot.sh`'s `add_decision()` calls `journal.sh record` and stores the resulting decision ID in `related.journal_entries`. The session file at `~/.lore/.current_session` provides the shared session ID that journal entries inherit. `transfer/lib/resume.sh` shows related journal entries on resume. The handoff-to-journal step was partially implemented: `add_decision()` journals decisions on snapshot, but the standalone `handoff` command does not create a separate journal entry.
