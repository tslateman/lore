#!/usr/bin/env bash
# Regression test for the observations.jsonl vs signals.jsonl docs mismatch.
#
# LORE_CONTRACT.md documents the inbox component's storage path and the
# `lore observe` schema. This asserts the file lore.sh actually writes to,
# and the id prefix it actually generates, match what LORE_CONTRACT.md
# (and README.md, inbox/README.md) say.

set -euo pipefail

export LORE_RERANK=0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LORE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/fixture.sh"
LORE="$LORE_ROOT/lore.sh"

PASS=0
FAIL=0
FIXTURE_DIR=""

setup() {
    FIXTURE_DIR=$(mktemp -d)

    mkdir -p "$FIXTURE_DIR/journal/data" "$FIXTURE_DIR/journal/lib"
    mkdir -p "$FIXTURE_DIR/patterns/data" "$FIXTURE_DIR/patterns/lib"
    mkdir -p "$FIXTURE_DIR/failures/data" "$FIXTURE_DIR/failures/lib"
    mkdir -p "$FIXTURE_DIR/transfer" "$FIXTURE_DIR/inbox/data" "$FIXTURE_DIR/inbox/lib"
    mkdir -p "$FIXTURE_DIR/graph" "$FIXTURE_DIR/lib"

    cp -R "$LORE_ROOT/journal/"* "$FIXTURE_DIR/journal/"
    cp -R "$LORE_ROOT/patterns/"* "$FIXTURE_DIR/patterns/"
    cp -R "$LORE_ROOT/failures/"* "$FIXTURE_DIR/failures/"
    cp -R "$LORE_ROOT/transfer/"* "$FIXTURE_DIR/transfer/"
    cp -R "$LORE_ROOT/inbox/"* "$FIXTURE_DIR/inbox/"
    cp -R "$LORE_ROOT/graph/"* "$FIXTURE_DIR/graph/"
    cp -R "$LORE_ROOT/lib/"* "$FIXTURE_DIR/lib/"

    cp "$LORE" "$FIXTURE_DIR/lore.sh"
    chmod +x "$FIXTURE_DIR/lore.sh"

    echo '[]' > "$FIXTURE_DIR/journal/data/decisions.jsonl"
    cat > "$FIXTURE_DIR/patterns/data/patterns.yaml" <<'YAML'
patterns: []

anti_patterns: []
YAML
    : > "$FIXTURE_DIR/failures/data/failures.jsonl"
    : > "$FIXTURE_DIR/inbox/data/signals.jsonl"
    : > "$FIXTURE_DIR/inbox/data/observations.jsonl"

    unset _LORE_PATHS_LOADED
    export LORE_DIR="$FIXTURE_DIR"
    export LORE_DATA_DIR="$FIXTURE_DIR"
    export CLAUDE_MEMORY_DB="$FIXTURE_DIR/memory.sqlite"
    export LORE_SEARCH_DB="$FIXTURE_DIR/search.db"
}

teardown() {
    remove_fixture "$FIXTURE_DIR"
}

assert_contains() {
    local desc="$1"
    local file="$2"
    local pattern="$3"
    if grep -q "$pattern" "$file" 2>/dev/null; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc (pattern '$pattern' not found in $file)"
        FAIL=$((FAIL + 1))
    fi
}

assert_empty() {
    local desc="$1"
    local file="$2"
    if [[ ! -s "$file" ]]; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc ($file is not empty)"
        FAIL=$((FAIL + 1))
    fi
}

test_contract_storage_path_matches_actual_write_target() {
    echo "Test: LORE_CONTRACT.md's documented inbox storage path is the file lore observe writes to"
    setup

    "$FIXTURE_DIR/lore.sh" observe "Config reload takes 3s" --source council --tags performance >/dev/null

    local documented_path
    documented_path=$(grep -oE 'inbox/data/[a-z]+\.jsonl' "$LORE_ROOT/LORE_CONTRACT.md" | head -1)
    local documented_file="${documented_path#inbox/data/}"

    assert_contains "documented file ($documented_path) received the record" \
        "$FIXTURE_DIR/inbox/data/$documented_file" "Config reload takes 3s"

    teardown
}

test_contract_id_prefix_matches_actual_id() {
    echo "Test: LORE_CONTRACT.md's signal schema id prefix matches the id lore observe generates"
    setup

    local id_prefix documented_prefix
    "$FIXTURE_DIR/lore.sh" observe "Prefix check" --source council >/dev/null
    id_prefix=$(jq -r '.id' "$FIXTURE_DIR/inbox/data/signals.jsonl" | tail -1 | cut -d- -f1)

    documented_prefix=$(sed -n '/[Ss]ignal schema/,/^```$/p' "$LORE_ROOT/LORE_CONTRACT.md" \
        | grep -oE '"id": "[a-z]+-' | head -1 | sed -E 's/"id": "([a-z]+)-/\1/')

    if [[ "$id_prefix" == "$documented_prefix" ]]; then
        echo "  PASS: generated id prefix ($id_prefix-) matches documented prefix ($documented_prefix-)"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: generated id prefix ($id_prefix-) does not match documented prefix ($documented_prefix-)"
        FAIL=$((FAIL + 1))
    fi

    teardown
}

test_inbox_readme_storage_path_matches_actual_write_target() {
    echo "Test: inbox/README.md's documented storage path is the file lore observe writes to"
    setup

    "$FIXTURE_DIR/lore.sh" observe "Documented via inbox readme" --source council >/dev/null

    local documented_path
    documented_path=$(grep -oE 'data/[a-z]+\.jsonl' "$LORE_ROOT/inbox/README.md" | head -1)
    local documented_file="${documented_path#data/}"

    assert_contains "documented file ($documented_path) received the record" \
        "$FIXTURE_DIR/inbox/data/$documented_file" "Documented via inbox readme"

    teardown
}

echo "=== Observations vs Signals File Regression Tests ==="
echo ""
test_contract_storage_path_matches_actual_write_target
echo ""
test_contract_id_prefix_matches_actual_id
echo ""
test_inbox_readme_storage_path_matches_actual_write_target
echo ""

echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
