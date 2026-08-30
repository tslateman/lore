#!/usr/bin/env bash
# run-tests.sh - Run every test suite and summarise
#
# Discovers suites from git rather than a hand-kept list, so a new file in
# tests/ is never orphaned. A suite is a tracked tests/test*.sh or
# tests/verify*.sh; anything else in tests/ is reported as skipped, so a
# misnamed suite is visible instead of silently dropped.
#
# Runs every suite even after one fails, then exits non-zero if any did: a
# suite that halts the run hides every suite behind it.
#
# Usage: scripts/run-tests.sh [suite...]

set -uo pipefail

LORE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$LORE_DIR" || exit 1

GUARD="tests/test-isolation-guard.sh"

suites=()
skipped=()
if [[ $# -gt 0 ]]; then
    suites=("$@")
else
    while IFS= read -r -d '' f; do
        case "${f#tests/}" in
            test*.sh|verify*.sh) ;;
            *) skipped+=("$f"); continue ;;
        esac
        [[ "$f" == "$GUARD" ]] && continue
        suites+=("$f")
    done < <(git ls-files -z 'tests/*.sh' | sort -z)
    [[ -f "$GUARD" ]] && suites=("$GUARD" "${suites[@]}")
fi

if [[ ${#suites[@]} -eq 0 ]]; then
    echo "run-tests: no test suites found" >&2
    exit 1
fi

echo "run-tests: ${#suites[@]} suites"
if [[ ${#skipped[@]} -gt 0 ]]; then
    echo "run-tests: not a suite by name, skipped: ${skipped[*]}"
fi

passed=()
failed=()

for suite in "${suites[@]}"; do
    echo
    echo "=============================================================="
    echo "  $suite"
    echo "=============================================================="
    start=$SECONDS
    if bash "$suite"; then
        passed+=("$suite")
        printf 'PASS  %s (%ss)\n' "$suite" "$((SECONDS - start))"
    else
        status=$?
        failed+=("$suite:$status")
        printf 'FAIL  %s (exit %s, %ss)\n' "$suite" "$status" "$((SECONDS - start))"
    fi
done

echo
echo "=============================================================="
echo "  Summary: ${#passed[@]} passed, ${#failed[@]} failed, ${#suites[@]} total"
echo "=============================================================="

if [[ ${#failed[@]} -gt 0 ]]; then
    for entry in "${failed[@]}"; do
        printf '  FAILED  %s (exit %s)\n' "${entry%:*}" "${entry##*:}"
    done
    exit 1
fi

echo "  All suites passed."
