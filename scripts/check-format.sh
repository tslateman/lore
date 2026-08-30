#!/usr/bin/env bash
# check-format.sh - Fail on unformatted tracked markdown
#
# Uses a local prettier when one is installed, otherwise fetches the pinned
# version through npx. Missing prettier fails the gate; it never skips.
#
# Usage: scripts/check-format.sh [--write]

set -euo pipefail

PRETTIER_VERSION=3.9.6

LORE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$LORE_DIR"

mode=--check
if [[ "${1:-}" == "--write" ]]; then
    mode=--write
fi

prettier=()
if command -v prettier >/dev/null 2>&1; then
    prettier=(prettier)
elif command -v npx >/dev/null 2>&1; then
    prettier=(npx --yes "prettier@${PRETTIER_VERSION}")
else
    echo "check-format: neither prettier nor npx is on PATH." >&2
    echo "check-format: install Node.js, or 'npm install -g prettier'." >&2
    exit 1
fi

echo "check-format: ${prettier[*]} $mode over tracked markdown"
git ls-files -z '*.md' | xargs -0 "${prettier[@]}" "$mode"
