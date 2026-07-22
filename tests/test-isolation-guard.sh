#!/usr/bin/env bash
# Isolation guard: every suite that sandboxes LORE_DATA_DIR must also pin
# LORE_SEARCH_DB.
#
# Why: when a test copies lore.sh into its tmpdir, LORE_DIR self-derives
# to the tmpdir and equals LORE_DATA_DIR, so lib/paths.sh falls back to
# the legacy ~/.lore/search.db — a real database. Suites then share one
# live DB and fail intermittently at whichever assertion collides with a
# concurrent writer. This bug shipped twice (2026-03-21, 2026-07-04)
# because the fix was applied per-suite; this guard makes the omission a
# loud failure instead of a flaky one.

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
        echo "        Add: export LORE_SEARCH_DB=\"\$TMPDIR/search.db\" beside it,"
        echo "        or the suite reads and writes the real search database."
        FAIL=$((FAIL + 1))
    else
        PASS=$((PASS + 1))
    fi
done

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
