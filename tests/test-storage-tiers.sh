#!/usr/bin/env bash
# Storage tier contract tests
#
# Tests the three-tier storage architecture:
# - Event tier (JSONL append-only)
# - Reference tier (YAML/JSON curated)
# - Derived tier (SQLite rebuilt from sources, with access_log preservation)

set -euo pipefail

# Hermetic: no live model calls from tests
export LORE_RERANK=0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/fixture.sh"
LORE="$SCRIPT_DIR/../lore.sh"

# --- Test harness ---

PASS=0
FAIL=0
FIXTURE_DIR=""

setup() {
    FIXTURE_DIR=$(mktemp -d)

    # Mirror the directory structure lore.sh expects
    mkdir -p "$FIXTURE_DIR/journal/data" "$FIXTURE_DIR/journal/lib"
    mkdir -p "$FIXTURE_DIR/patterns/data" "$FIXTURE_DIR/patterns/lib"
    mkdir -p "$FIXTURE_DIR/failures/data" "$FIXTURE_DIR/failures/lib"
    mkdir -p "$FIXTURE_DIR/transfer/data/sessions" "$FIXTURE_DIR/transfer/lib"
    mkdir -p "$FIXTURE_DIR/inbox/data" "$FIXTURE_DIR/inbox/lib"
    mkdir -p "$FIXTURE_DIR/graph" "$FIXTURE_DIR/lib"
    mkdir -p "$FIXTURE_DIR/intent/data/goals" "$FIXTURE_DIR/intent/lib"

    # Copy component scripts and libraries
    cp -R "$SCRIPT_DIR/../journal/"* "$FIXTURE_DIR/journal/"
    cp -R "$SCRIPT_DIR/../patterns/"* "$FIXTURE_DIR/patterns/"
    cp -R "$SCRIPT_DIR/../failures/"* "$FIXTURE_DIR/failures/"
    cp -R "$SCRIPT_DIR/../transfer/"* "$FIXTURE_DIR/transfer/"
    cp -R "$SCRIPT_DIR/../inbox/"* "$FIXTURE_DIR/inbox/"
    cp -R "$SCRIPT_DIR/../graph/"* "$FIXTURE_DIR/graph/"
    cp -R "$SCRIPT_DIR/../lib/"* "$FIXTURE_DIR/lib/"
    cp -R "$SCRIPT_DIR/../intent/"* "$FIXTURE_DIR/intent/"

    # Copy lore.sh into the temp dir so LORE_DIR self-derives correctly
    cp "$LORE" "$FIXTURE_DIR/lore.sh"
    chmod +x "$FIXTURE_DIR/lore.sh"

    # Initialize empty data files (Event tier - JSONL)
    : > "$FIXTURE_DIR/journal/data/decisions.jsonl"
    : > "$FIXTURE_DIR/failures/data/failures.jsonl"
    : > "$FIXTURE_DIR/inbox/data/signals.jsonl"

    # Reference tier - YAML/JSON
    cat > "$FIXTURE_DIR/patterns/data/patterns.yaml" <<'YAML'
# Pattern Learner Database
patterns: []

anti_patterns: []
YAML

    cat > "$FIXTURE_DIR/patterns/data/concepts.yaml" <<'YAML'
# Concepts database
concepts: []
YAML

    unset _LORE_PATHS_LOADED
    export LORE_DIR="$FIXTURE_DIR"
    export LORE_DATA_DIR="$FIXTURE_DIR"
    export CLAUDE_MEMORY_DB="$FIXTURE_DIR/memory.sqlite"
    export LORE_SEARCH_DB="$FIXTURE_DIR/search.db"
}

teardown() {
    remove_fixture "$FIXTURE_DIR"
    FIXTURE_DIR=""
    return 0
}

assert_eq() {
    local desc="$1"
    local expected="$2"
    local actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc (expected '$expected', got '$actual')"
        FAIL=$((FAIL + 1))
    fi
}

assert_ok() {
    local desc="$1"
    shift
    if "$@" >/dev/null 2>&1; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc (exit code $?)"
        FAIL=$((FAIL + 1))
    fi
}

assert_file_exists() {
    local desc="$1"
    local file="$2"
    if [[ -f "$file" ]]; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc (file not found: $file)"
        FAIL=$((FAIL + 1))
    fi
}

# --- Tests ---

test_event_tier_jsonl_valid() {
    echo "Test: Event tier files are valid JSONL"
    setup

    # Seed data
    "$FIXTURE_DIR/lore.sh" remember "Test decision" --rationale "testing" --force >/dev/null 2>&1
    "$FIXTURE_DIR/lore.sh" fail ToolError "Test error" >/dev/null 2>&1
    "$FIXTURE_DIR/lore.sh" capture "Test observation" >/dev/null 2>&1

    # Verify JSONL files can be parsed by jq
    assert_ok "decisions.jsonl is valid JSONL" jq -e '.' "$FIXTURE_DIR/journal/data/decisions.jsonl"
    assert_ok "failures.jsonl is valid JSONL" jq -e '.' "$FIXTURE_DIR/failures/data/failures.jsonl"
    assert_ok "signals.jsonl is valid JSONL" jq -e '.' "$FIXTURE_DIR/inbox/data/signals.jsonl"

    teardown
}

test_build_preserves_access_log() {
    echo "Test: search-index.sh build preserves access_log row count"
    setup

    # Seed a decision so we have data to index
    "$FIXTURE_DIR/lore.sh" remember "Test decision" --rationale "testing" --force >/dev/null 2>&1

    # Build index first time
    bash "$FIXTURE_DIR/lib/search-index.sh" build >/dev/null 2>&1

    # Get DB path from paths.sh
    source "$FIXTURE_DIR/lib/paths.sh"
    local db="$LORE_SEARCH_DB"

    # Insert test access records
    sqlite3 "$db" "INSERT INTO access_log(record_type, record_id, accessed_at)
        VALUES ('decision', 'test-1', datetime('now'));" 2>/dev/null
    sqlite3 "$db" "INSERT INTO access_log(record_type, record_id, accessed_at)
        VALUES ('pattern', 'test-2', datetime('now'));" 2>/dev/null

    local count_before
    count_before=$(sqlite3 "$db" "SELECT COUNT(*) FROM access_log;" 2>/dev/null)

    # Rebuild index
    bash "$FIXTURE_DIR/lib/search-index.sh" build >/dev/null 2>&1

    local count_after
    count_after=$(sqlite3 "$db" "SELECT COUNT(*) FROM access_log;" 2>/dev/null)

    assert_eq "access_log count preserved after rebuild" "$count_before" "$count_after"

    teardown
}

test_export_import_cycle() {
    echo "Test: Export/import cycle restores access_log"
    setup

    # Seed a decision so we have data to index
    "$FIXTURE_DIR/lore.sh" remember "Test decision" --rationale "testing" --force >/dev/null 2>&1

    # Build index
    bash "$FIXTURE_DIR/lib/search-index.sh" build >/dev/null 2>&1

    source "$FIXTURE_DIR/lib/paths.sh"
    local db="$LORE_SEARCH_DB"

    # Insert test access records
    sqlite3 "$db" "INSERT INTO access_log(record_type, record_id, accessed_at)
        VALUES ('decision', 'test-1', datetime('now'));" 2>/dev/null
    sqlite3 "$db" "INSERT INTO access_log(record_type, record_id, accessed_at)
        VALUES ('pattern', 'test-2', datetime('now'));" 2>/dev/null
    sqlite3 "$db" "INSERT INTO access_log(record_type, record_id, accessed_at)
        VALUES ('transfer', 'test-3', datetime('now'));" 2>/dev/null

    local count_original
    count_original=$(sqlite3 "$db" "SELECT COUNT(*) FROM access_log;" 2>/dev/null)

    # Export
    bash "$FIXTURE_DIR/lib/search-index.sh" export-access "$FIXTURE_DIR/test_access_log.jsonl" >/dev/null 2>&1

    # Delete DB and rebuild (simulates fresh build)
    rm "$db"
    bash "$FIXTURE_DIR/lib/search-index.sh" build >/dev/null 2>&1

    local count_after_rebuild
    count_after_rebuild=$(sqlite3 "$db" "SELECT COUNT(*) FROM access_log;" 2>/dev/null)

    # Import
    bash "$FIXTURE_DIR/lib/search-index.sh" import-access "$FIXTURE_DIR/test_access_log.jsonl" >/dev/null 2>&1

    local count_after_import
    count_after_import=$(sqlite3 "$db" "SELECT COUNT(*) FROM access_log;" 2>/dev/null)

    assert_eq "access_log empty after fresh rebuild" "0" "$count_after_rebuild"
    assert_eq "access_log restored after import" "$count_original" "$count_after_import"

    teardown
}

test_db_rebuild_from_sources() {
    echo "Test: search.db can be deleted and rebuilt without losing source data"
    setup

    # Seed data in event tier
    "$FIXTURE_DIR/lore.sh" remember "Decision 1" --rationale "reason 1" --force >/dev/null 2>&1
    "$FIXTURE_DIR/lore.sh" remember "Decision 2" --rationale "reason 2" --force >/dev/null 2>&1
    "$FIXTURE_DIR/lore.sh" fail ToolError "Error message" >/dev/null 2>&1

    # Build index first time
    bash "$FIXTURE_DIR/lib/search-index.sh" build >/dev/null 2>&1

    source "$FIXTURE_DIR/lib/paths.sh"
    local db="$LORE_SEARCH_DB"

    # Get initial counts
    local decisions_before
    decisions_before=$(sqlite3 "$db" "SELECT COUNT(*) FROM decisions;" 2>/dev/null)
    local failures_before
    failures_before=$(sqlite3 "$db" "SELECT COUNT(*) FROM failures;" 2>/dev/null)

    # Delete database
    rm "$db"

    # Rebuild from sources
    bash "$FIXTURE_DIR/lib/search-index.sh" build >/dev/null 2>&1

    # Get counts after rebuild
    local decisions_after
    decisions_after=$(sqlite3 "$db" "SELECT COUNT(*) FROM decisions;" 2>/dev/null)
    local failures_after
    failures_after=$(sqlite3 "$db" "SELECT COUNT(*) FROM failures;" 2>/dev/null)

    assert_eq "decisions count restored" "$decisions_before" "$decisions_after"
    assert_eq "failures count restored" "$failures_before" "$failures_after"

    # Verify source files still exist
    assert_file_exists "source decisions.jsonl still exists" "$FIXTURE_DIR/journal/data/decisions.jsonl"
    assert_file_exists "source failures.jsonl still exists" "$FIXTURE_DIR/failures/data/failures.jsonl"

    teardown
}

test_reference_tier_yaml_parseable() {
    echo "Test: Reference tier YAML files exist and are parseable"
    setup

    # Verify initial patterns.yaml is valid YAML
    assert_ok "initial patterns.yaml is valid YAML" yq -e '.' "$FIXTURE_DIR/patterns/data/patterns.yaml"

    # Verify concepts.yaml is valid YAML
    assert_ok "initial concepts.yaml is valid YAML" yq -e '.' "$FIXTURE_DIR/patterns/data/concepts.yaml"

    teardown
}

test_export_access_default_path() {
    echo "Test: export-access uses default path when no argument provided"
    setup

    # Seed and build
    "$FIXTURE_DIR/lore.sh" remember "Test decision" --rationale "testing" --force >/dev/null 2>&1
    bash "$FIXTURE_DIR/lib/search-index.sh" build >/dev/null 2>&1

    # Export without specifying path (uses default)
    bash "$FIXTURE_DIR/lib/search-index.sh" export-access >/dev/null 2>&1

    # Verify default path exists
    assert_file_exists "default export file created" "$FIXTURE_DIR/access_log.jsonl"

    teardown
}

# --- Runner ---

trap teardown EXIT

echo "=== Storage Tier Contract Tests ==="
echo ""

test_event_tier_jsonl_valid
echo ""
test_build_preserves_access_log
echo ""
test_export_import_cycle
echo ""
test_db_rebuild_from_sources
echo ""
test_reference_tier_yaml_parseable
echo ""
test_export_access_default_path
echo ""

echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
