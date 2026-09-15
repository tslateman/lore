#!/usr/bin/env bash
set -euo pipefail

LORE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$LORE_DIR" || exit 1

PASS=0
FAIL=0

check() {
    local desc="$1" cond="$2"
    if [[ "$cond" == "0" ]]; then
        echo "PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "FAIL: $desc"
        FAIL=$((FAIL + 1))
    fi
}

claim_line=$(grep -n 'Registry data is untracked' CLAUDE.md || true)
[[ -n "$claim_line" ]] || { echo "FAIL: CLAUDE.md no longer documents the registry data claim"; exit 1; }

claim_num="${claim_line%%:*}"
claim_text=$(sed -n "${claim_num}p" CLAUDE.md)

tracked_yaml=$(git ls-files 'registry/data/*.yaml')

if [[ -z "$tracked_yaml" ]]; then
    check "no tracked registry/data/*.yaml files (claim holds as-is)" 0
else
    while IFS= read -r f; do
        [[ -n "$f" ]] || continue
        name="$(basename "$f")"
        if grep -q "$name" <<<"$claim_text"; then
            check "$f is documented as a tracked exception" 0
        else
            check "$f is documented as a tracked exception" 1
        fi
    done <<<"$tracked_yaml"
fi

echo
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
