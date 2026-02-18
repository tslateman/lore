#!/usr/bin/env bash
# Test Anti-Pattern Inversion

set -e

LORE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export LORE_DIR
PATTERNS_SCRIPT="$LORE_DIR/patterns/patterns.sh"

echo "=== Testing Anti-Pattern Inversion ==="

# 1. Create a dummy pattern
echo "1. Creating dummy pattern..."
OUTPUT=$("$PATTERNS_SCRIPT" capture "Risky Business" --context "Always" --solution "Do it dangerous" --category "testing")
echo "$OUTPUT"
PATTERN_ID=$(echo "$OUTPUT" | grep "ID:" | awk '{print $2}' | tr -d '[:space:]')
echo "Created Pattern ID: $PATTERN_ID"

# 2. Flag it 3 times
echo "2. Flagging pattern as harmful (3 times)..."
"$PATTERNS_SCRIPT" flag "$PATTERN_ID" --reason "It causes explosions" --type "harmful"
"$PATTERNS_SCRIPT" flag "$PATTERN_ID" --reason "It causes fire" --type "harmful"
"$PATTERNS_SCRIPT" flag "$PATTERN_ID" --reason "It causes sadness" --type "harmful"

# 3. Verify it is deprecated
echo "3. Verifying deprecation..."
PATTERN_DETAILS=$("$PATTERNS_SCRIPT" show "$PATTERN_ID")
if echo "$PATTERN_DETAILS" | grep -q "\[DEPRECATED\]"; then
    echo "SUCCESS: Pattern is deprecated."
else
    echo "FAILURE: Pattern was not deprecated."
    echo "$PATTERN_DETAILS"
    exit 1
fi

# 4. Verify user was warned (Anti-Pattern created)
echo "4. Checking for Anti-Pattern..."
LIST_OUTPUT=$("$PATTERNS_SCRIPT" list --type anti-patterns)
if echo "$LIST_OUTPUT" | grep -q "Avoid: Risky Business"; then
    echo "SUCCESS: Anti-Pattern created."
else
    echo "FAILURE: Anti-Pattern not found."
    echo "$LIST_OUTPUT"
    exit 1
fi

echo "=== Test Passed ==="
