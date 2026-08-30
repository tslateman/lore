#!/usr/bin/env bash
# check-shell.sh - Run shellcheck over every tracked shell script
#
# Gates at SEVERITY (default error). Raise it as the backlog clears:
#   SEVERITY=warning scripts/check-shell.sh
#
# Usage: scripts/check-shell.sh [--backlog]
#   --backlog  Report counts at every severity instead of gating.

set -euo pipefail

SEVERITY="${SEVERITY:-error}"
JOBS="${JOBS:-8}"

LORE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$LORE_DIR"

if ! command -v shellcheck >/dev/null 2>&1; then
    echo "check-shell: shellcheck is not on PATH." >&2
    echo "check-shell: install it (brew install shellcheck / apt-get install shellcheck)." >&2
    exit 1
fi

tracked_scripts() {
    git ls-files -z '*.sh'
    printf '%s\0' lore
}

run_at() {
    tracked_scripts | xargs -0 -P "$JOBS" -n 8 shellcheck -s bash -S "$1" -f gcc || true
}

if [[ "${1:-}" == "--backlog" ]]; then
    for level in error warning info style; do
        printf '%-8s %s\n' "$level" "$(run_at "$level" | grep -c . || true)"
    done
    exit 0
fi

echo "check-shell: shellcheck --severity=$SEVERITY over $(tracked_scripts | tr -dc '\0' | wc -c | tr -d ' ') scripts"

findings=$(run_at "$SEVERITY")

if [[ -z "$findings" ]]; then
    echo "check-shell: clean at severity $SEVERITY"
    exit 0
fi

echo "$findings"
echo
echo "check-shell: $(printf '%s\n' "$findings" | grep -c .) findings at severity $SEVERITY or above."
exit 1
