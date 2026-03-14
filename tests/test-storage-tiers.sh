#!/usr/bin/env bash
# Storage tier contract tests
#
# Tests the three-tier storage architecture:
# - Event tier (JSONL append-only)
# - Reference tier (YAML/JSON curated)
# - Derived tier (SQLite rebuilt from sources, with access_log preservation)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LORE="$SCRIPT_DIR/../lore.sh"

# --- Test harness ---

PASS=0
FAIL=0
TMPDIR=""

setup() {
    TMPDIR=$(mktemp -d)

    # Mirror the directory structure lore.sh expects
    mkdir -p "$TMPDIR/journal/data" "$TMPDIR/journal/lib"
    mkdir -p "$TMPDIR/patterns/data" "$TMPDIR/patterns/lib"
    mkdir -p "$TMPDIR/failures/data" "$TMPDIR/failures/lib"
    mkdir -p "$TMPDIR/transfer/data/sessions" "$TMPDIR/transfer/lib"
    mkdir -p "$TMPDIR/inbox/data" "$TMPDIR/inbox/lib"
    mkdir -p "$TMPDIR/graph" "$TMPDIR/lib"
    mkdir -p "$TMPDIR/intent/data/goals" "$TMPDIR/intent/lib"

    # Copy component scripts and libraries
    cp -R "$SCRIPT_DIR/../journal/"* "$TMPDIR/journal/"
    cp -R "$SCRIPT_DIR/../patterns/"* "$TMPDIR/patterns/"
    cp -R "$SCRIPT_DIR/../failures/"* "$TMPDIR/failures/"
    cp -R "$SCRIPT_DIR/../transfer/"* "$TMPDIR/transfer/"
    cp -R "$SCRIPT_DIR/../inbox/"* "$TMPDIR/inbox/"
    cp -R "$SCRIPT_DIR/../graph/"* "$TMPDIR/graph/"
    cp -R "$SCRIPT_DIR/../lib/"* "$TMPDIR/lib/"
    cp -R "$SCRIPT_DIR/../intent/"* "$TMPDIR/intent/"

    # Copy lore.sh into the temp dir so LORE_DIR self-derives correctly
    cp "$LORE" "$TMPDIR/lore.sh"
    chmod +x "$TMPDIR/lore.sh"

    # Initialize empty data files (Event tier - JSONL)
    : > "$TMPDIR/journal/data/decisions.jsonl"
    : > "$TMPDIR/failures/data/failures.jsonl"
    : > "$TMPDIR/inbox/data/signals.jsonl"

    # Reference tier - YAML/JSON
    cat > "$TMPDIR/patterns/data/patterns.yaml" <<'YAML'
# Pattern Learner Database
patterns: []

anti_patterns: []
YAML

    cat > "$TMPDIR/patterns/data/concepts.yaml" <<'YAML'
# Concepts database
concepts: []
YAML

    unset _LORE_PATHS_LOADED
    export LORE_DIR="$TMPDIR"
    export LORE_DATA_DIR="$TMPDIR"
}

teardown() {
    [[ -n "$TMPDIR" && -d "$TMPDIR" ]] && rm -rf "$TMPDIR"
    TMPDIR=""
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
    "$TMPDIR/lore.sh" remember "Test decision" --rationale "testing" --force >/dev/null 2>&1
    "$TMPDIR/lore.sh" fail ToolError "Test error" >/dev/null 2>&1
    "$TMPDIR/lore.sh" capture "Test observation" >/dev/null 2>&1

    # Verify JSONL files can be parsed by jq
    assert_ok "decisions.jsonl is valid JSONL" jq -e '.' "$TMPDIR/journal/data/decisions.jsonl"
    assert_ok "failures.jsonl is valid JSONL" jq -e '.' "$TMPDIR/failures/data/failures.jsonl"
    assert_ok "signals.jsonl is valid JSONL" jq -e '.' "$TMPDIR/inbox/data/signals.jsonl"

    teardown
}

test_build_preserves_access_log() {
    echo "Test: search-index.sh build preserves access_log row count"
    setup

    # Seed a decision so we have data to index
    "$TMPDIR/lore.sh" remember "Test decision" --rationale "testing" --force >/dev/null 2>&1

    # Build index first time
    bash "$TMPDIR/lib/search-index.sh" build >/dev/null 2>&1

    # Get DB path from paths.sh
    source "$TMPDIR/lib/paths.sh"
    local db="$LORE_SEARCH_DB"

    # Insert test access records
    sqlite3 "$db" "INSERT INTO access_log(record_type, record_id, accessed_at)
        VALUES ('decision', 'test-1', datetime('now'));" 2>/dev/null
    sqlite3 "$db" "INSERT INTO access_log(record_type, record_id, accessed_at)
        VALUES ('pattern', 'test-2', datetime('now'));" 2>/dev/null

    local count_before
    count_before=$(sqlite3 "$db" "SELECT COUNT(*) FROM access_log;" 2>/dev/null)

    # Rebuild index
    bash "$TMPDIR/lib/search-index.sh" build >/dev/null 2>&1

    local count_after
    count_after=$(sqlite3 "$db" "SELECT COUNT(*) FROM access_log;" 2>/dev/null)

    assert_eq "access_log count preserved after rebuild" "$count_before" "$count_after"

    teardown
}

test_export_import_cycle() {
    echo "Test: Export/import cycle restores access_log"
    setup

    # Seed a decision so we have data to index
    "$TMPDIR/lore.sh" remember "Test decision" --rationale "testing" --force >/dev/null 2>&1

    # Build index
    bash "$TMPDIR/lib/search-index.sh" build >/dev/null 2>&1

    source "$TMPDIR/lib/paths.sh"
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
    bash "$TMPDIR/lib/search-index.sh" export-access "$TMPDIR/test_access_log.jsonl" >/dev/null 2>&1

    # Delete DB and rebuild (simulates fresh build)
    rm "$db"
    bash "$TMPDIR/lib/search-index.sh" build >/dev/null 2>&1

    local count_after_rebuild
    count_after_rebuild=$(sqlite3 "$db" "SELECT COUNT(*) FROM access_log;" 2>/dev/null)

    # Import
    bash "$TMPDIR/lib/search-index.sh" import-access "$TMPDIR/test_access_log.jsonl" >/dev/null 2>&1

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
    "$TMPDIR/lore.sh" remember "Decision 1" --rationale "reason 1" --force >/dev/null 2>&1
    "$TMPDIR/lore.sh" remember "Decision 2" --rationale "reason 2" --force >/dev/null 2>&1
    "$TMPDIR/lore.sh" fail ToolError "Error message" >/dev/null 2>&1

    # Build index first time
    bash "$TMPDIR/lib/search-index.sh" build >/dev/null 2>&1

    source "$TMPDIR/lib/paths.sh"
    local db="$LORE_SEARCH_DB"

    # Get initial counts
    local decisions_before
    decisions_before=$(sqlite3 "$db" "SELECT COUNT(*) FROM decisions;" 2>/dev/null)
    local failures_before
    failures_before=$(sqlite3 "$db" "SELECT COUNT(*) FROM failures;" 2>/dev/null)

    # Delete database
    rm "$db"

    # Rebuild from sources
    bash "$TMPDIR/lib/search-index.sh" build >/dev/null 2>&1

    # Get counts after rebuild
    local decisions_after
    decisions_after=$(sqlite3 "$db" "SELECT COUNT(*) FROM decisions;" 2>/dev/null)
    local failures_after
    failures_after=$(sqlite3 "$db" "SELECT COUNT(*) FROM failures;" 2>/dev/null)

    assert_eq "decisions count restored" "$decisions_before" "$decisions_after"
    assert_eq "failures count restored" "$failures_before" "$failures_after"

    # Verify source files still exist
    assert_file_exists "source decisions.jsonl still exists" "$TMPDIR/journal/data/decisions.jsonl"
    assert_file_exists "source failures.jsonl still exists" "$TMPDIR/failures/data/failures.jsonl"

    teardown
}

test_reference_tier_yaml_parseable() {
    echo "Test: Reference tier YAML files exist and are parseable"
    setup

    # Verify initial patterns.yaml is valid YAML
    assert_ok "initial patterns.yaml is valid YAML" yq -e '.' "$TMPDIR/patterns/data/patterns.yaml"

    # Verify concepts.yaml is valid YAML
    assert_ok "initial concepts.yaml is valid YAML" yq -e '.' "$TMPDIR/patterns/data/concepts.yaml"

    teardown
}

test_export_access_default_path() {
    echo "Test: export-access uses default path when no argument provided"
    setup

    # Seed and build
    "$TMPDIR/lore.sh" remember "Test decision" --rationale "testing" --force >/dev/null 2>&1
    bash "$TMPDIR/lib/search-index.sh" build >/dev/null 2>&1

    # Export without specifying path (uses default)
    bash "$TMPDIR/lib/search-index.sh" export-access >/dev/null 2>&1

    # Verify default path exists
    assert_file_exists "default export file created" "$TMPDIR/access_log.jsonl"

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
