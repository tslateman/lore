#!/usr/bin/env bash
# Tests for `transfer.sh prune` — archiving empty sessions.
#
# Verifies: dry-run moves nothing, backup tar.gz creation, empty+old
# sessions move to archive/, signal and recent sessions stay, and the
# current session is never pruned.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TRANSFER="$SCRIPT_DIR/../transfer/transfer.sh"

PASS=0
FAIL=0
TMPDIR=""

setup() {
    TMPDIR=$(mktemp -d)
    mkdir -p "$TMPDIR/transfer/data/sessions"
    unset _LORE_PATHS_LOADED
    export LORE_DATA_DIR="$TMPDIR"
    export LORE_TRANSFER_ROOT="$TMPDIR/transfer"
}

teardown() {
    [[ -n "$TMPDIR" && -d "$TMPDIR" ]] && rm -rf "$TMPDIR"
}

assert_true() {
    local desc="$1"
    shift
    if "$@" >/dev/null 2>&1; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc"
        FAIL=$((FAIL + 1))
    fi
}

assert_false() {
    local desc="$1"
    shift
    if "$@" >/dev/null 2>&1; then
        echo "  FAIL: $desc"
        FAIL=$((FAIL + 1))
    else
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    fi
}

# Create a session file. Args: id, summary ("" = empty), age_days
create_session() {
    local id="$1"
    local summary="$2"
    local age_days="$3"
    local file="$TMPDIR/transfer/data/sessions/${id}.json"

    jq -n --arg id "$id" --arg summary "$summary" '{
        id: $id,
        started_at: "2026-01-01T00:00:00Z",
        ended_at: null,
        summary: $summary,
        goals_addressed: [],
        decisions_made: [],
        patterns_learned: [],
        open_threads: [],
        handoff: { message: "", next_steps: [], blockers: [], questions: [] },
        git_state: { branch: "", commits: [], uncommitted: [] },
        context: { project: "", active_files: [], recent_commands: [], environment: {} }
    }' > "$file"

    if [[ "$age_days" -gt 0 ]]; then
        local ts
        ts=$(date -v "-${age_days}d" +%Y%m%d%H%M 2>/dev/null \
            || date -d "${age_days} days ago" +%Y%m%d%H%M)
        touch -t "$ts" "$file"
    fi
}

test_prune() {
    echo "Test: prune archives only old, empty, non-current sessions"
    setup

    create_session "session-old-empty" "" 10
    create_session "session-old-signal" "Did real work" 10
    create_session "session-recent-empty" "" 0
    create_session "session-old-current" "" 10
    echo "session-old-current" > "$TMPDIR/transfer/data/.current_session"

    local sessions="$TMPDIR/transfer/data/sessions"

    # Dry run: reports but moves nothing
    local output
    output=$("$TRANSFER" prune --dry-run 2>&1)
    assert_true "dry-run lists old empty session" \
        grep -q "Would archive: session-old-empty" <<< "$output"
    assert_true "dry-run reports one candidate" \
        grep -q "1 of 4 sessions would be archived" <<< "$output"
    assert_true "dry-run leaves file in place" test -f "$sessions/session-old-empty.json"
    assert_false "dry-run creates no archive dir" test -d "$sessions/archive"
    assert_false "dry-run creates no backup" \
        bash -c "ls '$TMPDIR/transfer/data/'sessions-backup-*.tar.gz"

    # Real prune
    output=$("$TRANSFER" prune 2>&1)
    assert_true "backup tar.gz created" \
        bash -c "ls '$TMPDIR/transfer/data/'sessions-backup-*.tar.gz"
    assert_true "old empty session archived" \
        test -f "$sessions/archive/session-old-empty.json"
    assert_false "old empty session removed from sessions/" \
        test -f "$sessions/session-old-empty.json"
    assert_true "old signal session kept" test -f "$sessions/session-old-signal.json"
    assert_true "recent empty session kept" test -f "$sessions/session-recent-empty.json"
    assert_true "current session kept" test -f "$sessions/session-old-current.json"
    assert_true "report shows archive count" \
        grep -q "Archived 1 of 4 sessions" <<< "$output"

    # Backup contains all four sessions
    local backup
    backup=$(ls "$TMPDIR/transfer/data/"sessions-backup-*.tar.gz | head -1)
    local backed_up
    backed_up=$(tar -tzf "$backup" | grep -c 'session-.*\.json' || true)
    if [[ "$backed_up" -eq 4 ]]; then
        echo "  PASS: backup contains all 4 sessions"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: backup contains $backed_up sessions (expected 4)"
        FAIL=$((FAIL + 1))
    fi

    teardown
}

test_prune_days_flag() {
    echo "Test: prune --days widens or narrows the window"
    setup

    create_session "session-five-days" "" 5

    local sessions="$TMPDIR/transfer/data/sessions"

    # Default window (7 days): 5-day-old session survives
    "$TRANSFER" prune >/dev/null 2>&1
    assert_true "5-day-old session survives default window" \
        test -f "$sessions/session-five-days.json"

    # Narrow window (3 days): 5-day-old session archived
    "$TRANSFER" prune --days 3 >/dev/null 2>&1
    assert_true "5-day-old session archived with --days 3" \
        test -f "$sessions/archive/session-five-days.json"

    teardown
}

test_prune_invalid_days() {
    echo "Test: prune rejects a non-numeric --days value"
    setup

    assert_false "prune --days abc fails" "$TRANSFER" prune --days abc

    teardown
}

echo "=== Transfer Prune Tests ==="
echo ""

test_prune
echo ""
test_prune_days_flag
echo ""
test_prune_invalid_days
echo ""

echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
