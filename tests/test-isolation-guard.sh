#!/usr/bin/env bash
# Isolation guard: every suite that sandboxes LORE_DATA_DIR must also pin
# LORE_SEARCH_DB, and every suite that captures must also pin
# CLAUDE_MEMORY_DB.
#
# Why: when a test copies lore.sh into its tmpdir, LORE_DIR self-derives
# to the tmpdir and equals LORE_DATA_DIR, so lib/paths.sh falls back to
# the legacy ~/.lore/search.db — a real database. Suites then share one
# live DB and fail intermittently at whichever assertion collides with a
# concurrent writer. This bug shipped twice (2026-03-21, 2026-07-04)
# because the fix was applied per-suite; this guard makes the omission a
# loud failure instead of a flaky one.
#
# CLAUDE_MEMORY_DB has the same shape: lib/bridge.sh derives it from $HOME
# rather than from LORE_DATA_DIR, so cmd_remember and cmd_learn write their
# shadow through to the real Engram store no matter where a suite points its
# data directory. That leaked 165 test fixtures before anyone noticed.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PASS=0
FAIL=0

echo "Test: suites that set LORE_DATA_DIR also pin LORE_SEARCH_DB"
for suite in "$SCRIPT_DIR"/test*.sh "$SCRIPT_DIR"/verify*.sh; do
    name="$(basename "$suite")"
    [[ "$name" == "test-isolation-guard.sh" ]] && continue

    data_dir_count=$(grep -c 'LORE_DATA_DIR=' "$suite" || true)
    search_db_count=$(grep -c 'LORE_SEARCH_DB=' "$suite" || true)

    if [[ "$data_dir_count" -gt 0 && "$search_db_count" -eq 0 ]]; then
        echo "  FAIL: $name sets LORE_DATA_DIR without LORE_SEARCH_DB"
        echo "        Add: export LORE_SEARCH_DB=\"\$FIXTURE_DIR/search.db\" beside it,"
        echo "        or the suite reads and writes the real search database."
        FAIL=$((FAIL + 1))
    else
        PASS=$((PASS + 1))
    fi
done

echo ""
echo "Test: suites that capture through lore.sh also pin CLAUDE_MEMORY_DB"
for suite in "$SCRIPT_DIR"/test*.sh "$SCRIPT_DIR"/verify*.sh; do
    name="$(basename "$suite")"
    [[ "$name" == "test-isolation-guard.sh" ]] && continue

    capture_count=$(grep -cE 'lore\.sh"? (remember|learn|capture)' "$suite" || true)
    memory_db_count=$(grep -c 'CLAUDE_MEMORY_DB=' "$suite" || true)

    if [[ "$capture_count" -gt 0 && "$memory_db_count" -eq 0 ]]; then
        echo "  FAIL: $name captures without pinning CLAUDE_MEMORY_DB"
        echo "        Add: export CLAUDE_MEMORY_DB=\"\$FIXTURE_DIR/memory.sqlite\" beside it,"
        echo "        or the suite writes test fixtures into the real Engram store."
        FAIL=$((FAIL + 1))
    else
        PASS=$((PASS + 1))
    fi
done

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
