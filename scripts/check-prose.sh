#!/usr/bin/env bash
# check-prose.sh - Fail on emdashes in tracked markdown
#
# CONTRIBUTING.md: "Emdashes: Never. Use double hyphens (--) instead."
#
# Usage: scripts/check-prose.sh [file...]
#   With no arguments, checks every tracked *.md file.

set -euo pipefail

LORE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$LORE_DIR"

EMDASH=$(printf '\xe2\x80\x94')

files=()
if [[ $# -gt 0 ]]; then
    files=("$@")
else
    while IFS= read -r -d '' f; do
        files+=("$f")
    done < <(git ls-files -z '*.md')
fi

if [[ ${#files[@]} -eq 0 ]]; then
    echo "check-prose: no markdown files to check" >&2
    exit 1
fi

set +e
hits=$(grep -n -F -- "$EMDASH" "${files[@]}")
status=$?
set -e

if [[ $status -gt 1 ]]; then
    echo "check-prose: grep failed with status $status" >&2
    exit 2
fi

if [[ $status -eq 1 ]]; then
    echo "check-prose: ${#files[@]} files clean of emdashes"
    exit 0
fi

echo "$hits"
echo
echo "check-prose: $(printf '%s\n' "$hits" | wc -l | tr -d ' ') emdashes in $(printf '%s\n' "$hits" | cut -d: -f1 | sort -u | wc -l | tr -d ' ') files."
echo "check-prose: CONTRIBUTING.md forbids emdashes. Use -- instead."
exit 1
