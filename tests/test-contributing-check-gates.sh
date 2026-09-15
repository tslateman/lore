#!/usr/bin/env bash
# Verifies CONTRIBUTING.md documents every gate `make check` runs.
#
# Reads the Makefile's CHECKS variable as ground truth and confirms the
# `make check` line in CONTRIBUTING.md names each one, so a gate added to
# the Makefile can't go undocumented.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LORE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$LORE_DIR" || exit 1

PASS=0
FAIL=0

checks_line=$(grep '^CHECKS = ' Makefile)
gates=$(echo "$checks_line" | sed 's/^CHECKS = //')

doc_line=$(grep -m1 'make check ' CONTRIBUTING.md)

for gate in $gates; do
    short="${gate#check-}"
    if echo "$doc_line" | grep -qw "$short"; then
        PASS=$((PASS + 1))
    else
        echo "FAIL: CONTRIBUTING.md's 'make check' line is missing gate '$gate' (documented line: $doc_line)"
        FAIL=$((FAIL + 1))
    fi
done

echo "test-contributing-check-gates: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
