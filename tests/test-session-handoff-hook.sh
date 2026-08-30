#!/usr/bin/env bash
# Tests for scripts/hooks/session-handoff.sh — the auto-handoff hook.
#
# The hook's contract is fail-silence: exit 0 on any missing input,
# malformed JSON, absent transcript, or undersized transcript, and
# write nothing. These tests never reach the claude CLI call.

set -euo pipefail

# Hermetic: no live model calls from tests
export LORE_RERANK=0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/fixture.sh"
HOOK="$SCRIPT_DIR/../scripts/hooks/session-handoff.sh"

PASS=0
FAIL=0
FIXTURE_DIR=$(mktemp -d)
trap 'remove_fixture "$FIXTURE_DIR"' EXIT

# Isolate any writes the hook might attempt
export LORE_DATA_DIR="$FIXTURE_DIR/lore-data"
export LORE_SEARCH_DB="$FIXTURE_DIR/lore-data/search.db"
mkdir -p "$LORE_DATA_DIR/transfer/data/sessions"

assert_exit_zero() {
    local desc="$1"
    local stdin_data="$2"
    if printf '%s' "$stdin_data" | bash "$HOOK" >/dev/null 2>&1; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc (non-zero exit)"
        FAIL=$((FAIL + 1))
    fi
}

echo "=== Session Handoff Hook Tests ==="
echo ""

echo "Test: hook is fail-silent on bad input"
assert_exit_zero "empty stdin exits 0" ""
assert_exit_zero "garbage stdin exits 0" "not json at all"
assert_exit_zero "JSON without transcript_path exits 0" '{"cwd": "/tmp"}'
assert_exit_zero "missing transcript file exits 0" \
    '{"transcript_path": "/nonexistent/t.jsonl", "cwd": "/tmp"}'

echo ""
echo "Test: tiny transcript is skipped without writing"

tiny="$FIXTURE_DIR/tiny.jsonl"
{
    printf '%s\n' '{"type":"user","message":{"role":"user","content":"hi"}}'
    printf '%s\n' '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"hello"}]}}'
} > "$tiny"

assert_exit_zero "tiny transcript exits 0" \
    "{\"transcript_path\": \"$tiny\", \"cwd\": \"$FIXTURE_DIR\"}"

session_count=$(ls -1 "$LORE_DATA_DIR/transfer/data/sessions" 2>/dev/null | wc -l | tr -d ' ')
if [[ "$session_count" -eq 0 ]]; then
    echo "  PASS: no session file written"
    PASS=$((PASS + 1))
else
    echo "  FAIL: $session_count session files written for tiny transcript"
    FAIL=$((FAIL + 1))
fi

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
