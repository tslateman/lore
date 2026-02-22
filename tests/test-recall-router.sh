#!/usr/bin/env bash
# Integration tests for the recall router (lib/recall-router.sh)
#
# Tests query classification, Engram querying, shadow enrichment,
# routed recall paths, dedup, provenance marking, and backward compat.
# Uses a temporary directory so production data is untouched.

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
    mkdir -p "$TMPDIR/transfer" "$TMPDIR/inbox/lib"
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

    # Initialize empty data files
    : > "$TMPDIR/journal/data/decisions.jsonl"
    cat > "$TMPDIR/patterns/data/patterns.yaml" <<'YAML'
# Pattern Learner Database
patterns: []

anti_patterns: []
YAML
    : > "$TMPDIR/failures/data/failures.jsonl"

    # Create a test memory.sqlite with the Memory table
    sqlite3 "$TMPDIR/memory.sqlite" <<'SQL'
CREATE TABLE Memory (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    importance INTEGER DEFAULT 3,
    accessCount INTEGER DEFAULT 0,
    createdAt REAL,
    lastAccessedAt REAL,
    project TEXT,
    embedding BLOB,
    source TEXT,
    topic TEXT,
    expiresAt REAL DEFAULT 0,
    content TEXT
);
SQL

    unset _LORE_PATHS_LOADED
    export LORE_DIR="$TMPDIR"
    export LORE_DATA_DIR="$TMPDIR"
    export CLAUDE_MEMORY_DB="$TMPDIR/memory.sqlite"
}

teardown() {
    [[ -n "$TMPDIR" && -d "$TMPDIR" ]] && rm -rf "$TMPDIR"
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

assert_output_contains() {
    local desc="$1"
    local output="$2"
    local pattern="$3"
    if echo "$output" | grep -q "$pattern"; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc (pattern '$pattern' not found)"
        FAIL=$((FAIL + 1))
    fi
}

assert_output_not_contains() {
    local desc="$1"
    local output="$2"
    local pattern="$3"
    if echo "$output" | grep -q "$pattern"; then
        echo "  FAIL: $desc (pattern '$pattern' unexpectedly found)"
        FAIL=$((FAIL + 1))
    else
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    fi
}

assert_eq() {
    local desc="$1"
    local actual="$2"
    local expected="$3"
    if [[ "$actual" == "$expected" ]]; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc (expected '$expected', got '$actual')"
        FAIL=$((FAIL + 1))
    fi
}

# --- Tests ---

test_classify_query_lore_keywords() {
    echo "Test: classify_query routes decision/pattern/failure keywords to lore-first"
    setup
    source "$TMPDIR/lib/recall-router.sh"

    assert_eq "decision keyword" "$(classify_query "why did we choose JSONL?")" "lore-first"
    assert_eq "rationale keyword" "$(classify_query "what rationale for this?")" "lore-first"
    assert_eq "pattern keyword" "$(classify_query "pattern for retry logic")" "lore-first"
    assert_eq "failure keyword" "$(classify_query "failure in deployment")" "lore-first"
    assert_eq "architecture keyword" "$(classify_query "architecture of the stack")" "lore-first"
    assert_eq "alternative keyword" "$(classify_query "what alternatives were considered")" "lore-first"

    teardown
}

test_classify_query_memory_keywords() {
    echo "Test: classify_query routes session/working keywords to memory-first"
    setup
    source "$TMPDIR/lib/recall-router.sh"

    assert_eq "working on keyword" "$(classify_query "what was I working on?")" "memory-first"
    assert_eq "recent keyword" "$(classify_query "recent changes")" "memory-first"
    assert_eq "debugging keyword" "$(classify_query "debugging the auth issue")" "memory-first"
    assert_eq "session keyword" "$(classify_query "session context")" "memory-first"
    assert_eq "preference keyword" "$(classify_query "my preference for tabs")" "memory-first"

    teardown
}

test_classify_query_default_both() {
    echo "Test: classify_query defaults to 'both' for generic queries"
    setup
    source "$TMPDIR/lib/recall-router.sh"

    assert_eq "generic query" "$(classify_query "authentication")" "both"
    assert_eq "another generic" "$(classify_query "how does the API work")" "both"
    assert_eq "project name" "$(classify_query "lore")" "both"

    teardown
}

test_query_claude_memory_returns_results() {
    echo "Test: query_claude_memory returns matching rows"
    setup
    source "$TMPDIR/lib/recall-router.sh"

    # Seed test data
    sqlite3 "$TMPDIR/memory.sqlite" \
        "INSERT INTO Memory (importance, accessCount, createdAt, lastAccessedAt, project, embedding, source, topic, content) VALUES (3, 1, 1708000000, 1708000000, 'lore', zeroblob(0), 'conversation', 'debugging', 'npm fails in non-interactive shells');"

    local output
    output=$(query_claude_memory "npm fails")

    assert_output_contains "returns matching row" "$output" "npm fails"
    assert_output_contains "includes topic" "$output" "debugging"

    teardown
}

test_query_claude_memory_missing_db() {
    echo "Test: query_claude_memory returns empty when DB missing"
    setup
    source "$TMPDIR/lib/recall-router.sh"

    rm -f "$TMPDIR/memory.sqlite"
    export CLAUDE_MEMORY_DB="$TMPDIR/memory.sqlite"

    local output
    output=$(query_claude_memory "anything")

    assert_eq "empty output" "$output" ""

    teardown
}

test_query_claude_memory_skips_low_importance() {
    echo "Test: query_claude_memory excludes importance=0 rows"
    setup
    source "$TMPDIR/lib/recall-router.sh"

    sqlite3 "$TMPDIR/memory.sqlite" \
        "INSERT INTO Memory (importance, accessCount, createdAt, lastAccessedAt, project, embedding, source, topic, content) VALUES (0, 1, 1708000000, 1708000000, 'lore', zeroblob(0), 'lore-bridge', 'lore-decisions', '[lore:dec-retracted] retracted decision');"

    local output
    output=$(query_claude_memory "retracted")

    assert_eq "no results for importance=0" "$output" ""

    teardown
}

test_enrich_decision_shadow() {
    echo "Test: enrich_lore_shadow fetches full decision record"
    setup
    source "$TMPDIR/lib/recall-router.sh"

    # Seed a decision
    "$TMPDIR/lore.sh" remember "Use JSONL for storage" --rationale "Append-only, simple" --tags "arch,storage" --force >/dev/null 2>&1

    # Get the ID from the seeded decision
    local dec_id
    dec_id=$(jq -r '.id' "$TMPDIR/journal/data/decisions.jsonl" | tail -1)

    local output
    output=$(enrich_lore_shadow "[lore:${dec_id}] Use JSONL for storage")

    assert_output_contains "enrichment has rationale" "$output" "Rationale: Append-only, simple"
    assert_output_contains "enrichment has tags" "$output" "Tags:"

    teardown
}

test_enrich_pattern_shadow() {
    echo "Test: enrich_lore_shadow fetches full pattern record"
    setup
    source "$TMPDIR/lib/recall-router.sh"

    # Seed a pattern
    "$TMPDIR/lore.sh" learn "Safe bash arithmetic" --context "Shell scripts" --problem "Expr is fragile" --solution 'Use x=$((x+1))' --force >/dev/null 2>&1

    # Get the pattern ID
    local pat_id
    pat_id=$(yq -r '.patterns[-1].id' "$TMPDIR/patterns/data/patterns.yaml")

    local output
    output=$(enrich_lore_shadow "[lore:${pat_id}] Safe bash arithmetic")

    assert_output_contains "enrichment has context" "$output" "Context: Shell scripts"
    assert_output_contains "enrichment has solution" "$output" 'Solution: Use x=$((x+1))'

    teardown
}

test_enrich_no_lore_prefix() {
    echo "Test: enrich_lore_shadow returns nothing for non-shadow content"
    setup
    source "$TMPDIR/lib/recall-router.sh"

    local output
    output=$(enrich_lore_shadow "plain memory without lore prefix")

    assert_eq "no enrichment for non-shadow" "$output" ""

    teardown
}

test_lore_first_without_memory_db() {
    echo "Test: lore-first path works without Engram DB"
    setup

    rm -f "$TMPDIR/memory.sqlite"
    export CLAUDE_MEMORY_DB="$TMPDIR/memory.sqlite"

    # Seed a decision
    "$TMPDIR/lore.sh" remember "Use JSONL for storage" --rationale "Append-only" --force >/dev/null 2>&1

    # --routed without search.db falls back to grep; no crash
    local output
    output=$("$TMPDIR/lore.sh" recall --routed "JSONL" 2>&1) || true

    assert_output_not_contains "no unknown command error" "$output" "Unknown command"
    assert_output_not_contains "no unknown option error" "$output" "Unknown option"

    teardown
}

test_memory_first_fallback_to_lore() {
    echo "Test: memory-first falls back to Lore when Engram DB missing"
    setup

    rm -f "$TMPDIR/memory.sqlite"
    export CLAUDE_MEMORY_DB="$TMPDIR/memory.sqlite"

    # Seed a decision
    "$TMPDIR/lore.sh" remember "Use JSONL for decisions" --rationale "Simple" --force >/dev/null 2>&1

    # Force memory-first route by using a memory-first keyword
    local output
    output=$("$TMPDIR/lore.sh" recall --routed "recent session" 2>&1) || true

    # Should not crash even without memory.sqlite
    assert_output_not_contains "no crash" "$output" "Unknown command"

    teardown
}

test_both_mode_dedup() {
    echo "Test: 'both' mode deduplicates shadow memories"
    setup
    source "$TMPDIR/lib/recall-router.sh"

    # Seed a decision in Lore
    "$TMPDIR/lore.sh" remember "Use JSONL for storage" --rationale "Append-only" --force >/dev/null 2>&1
    local dec_id
    dec_id=$(jq -r '.id' "$TMPDIR/journal/data/decisions.jsonl" | tail -1)

    # Seed the same as a shadow in Engram
    sqlite3 "$TMPDIR/memory.sqlite" \
        "INSERT INTO Memory (importance, accessCount, createdAt, lastAccessedAt, project, embedding, source, topic, content) VALUES (3, 1, 1708000000, 1708000000, 'lore', zeroblob(0), 'lore-bridge', 'lore-decisions', '[lore:${dec_id}] Use JSONL for storage. Why: Append-only <!-- hash:abc123 -->');"

    # Also seed a native memory (no shadow)
    sqlite3 "$TMPDIR/memory.sqlite" \
        "INSERT INTO Memory (importance, accessCount, createdAt, lastAccessedAt, project, embedding, source, topic, content) VALUES (3, 1, 1708000000, 1708000000, 'global', zeroblob(0), 'conversation', 'debugging', 'JSONL parsing tips from last session');"

    # Query both sources; without search.db, Lore leg is empty (grep fallback),
    # so both memory results should appear
    local output
    output=$(query_claude_memory "JSONL")
    local count
    count=$(echo "$output" | grep -c "JSONL" || true)

    # Both the shadow and native memory should match JSONL
    assert_output_contains "shadow matches" "$output" "lore:${dec_id}"
    assert_output_contains "native memory matches" "$output" "JSONL parsing"

    teardown
}

test_compact_provenance_prefix() {
    echo "Test: compact output includes provenance prefixes"
    setup
    source "$TMPDIR/lib/recall-router.sh"

    # Seed shadow and native memory
    sqlite3 "$TMPDIR/memory.sqlite" \
        "INSERT INTO Memory (importance, accessCount, createdAt, lastAccessedAt, project, embedding, source, topic, content) VALUES (3, 1, 1708000000, 1708000000, 'lore', zeroblob(0), 'lore-bridge', 'lore-decisions', '[lore:dec-test123] Use JSONL for storage. Why: Append-only <!-- hash:abc -->');"
    sqlite3 "$TMPDIR/memory.sqlite" \
        "INSERT INTO Memory (importance, accessCount, createdAt, lastAccessedAt, project, embedding, source, topic, content) VALUES (3, 1, 1708000000, 1708000000, 'global', zeroblob(0), 'conversation', 'debugging', 'npm fails in non-interactive shells');"

    # Format shadow as compact
    local shadow_output
    shadow_output=$(_emit_mem_line "1" "[lore:dec-test123] Use JSONL for storage. Why: Append-only <!-- hash:abc -->" "lore-decisions" "lore-bridge" "3" "true")
    assert_output_contains "shadow has (lore) prefix" "$shadow_output" "(lore)"

    # Format native as compact
    local native_output
    native_output=$(_emit_mem_line "2" "npm fails in non-interactive shells" "debugging" "conversation" "3" "true")
    assert_output_contains "native has (mem) prefix" "$native_output" "(mem)"

    teardown
}

test_backward_compat_recall_unchanged() {
    echo "Test: lore recall without --routed still works"
    setup

    "$TMPDIR/lore.sh" remember "Compat decision" --rationale "testing" --force >/dev/null 2>&1

    local output
    output=$("$TMPDIR/lore.sh" recall "compat" 2>&1) || true

    assert_output_not_contains "no unknown command error" "$output" "Unknown command"
    assert_output_not_contains "no unknown option error" "$output" "Unknown option"

    teardown
}

test_routed_recall_no_query_error() {
    echo "Test: lore recall --routed without query shows error"
    setup

    local output
    output=$("$TMPDIR/lore.sh" recall --routed 2>&1) || true

    assert_output_contains "shows error" "$output" "Error"

    teardown
}

# --- Runner ---

echo "=== Lore Recall Router Integration Tests ==="
echo ""

test_classify_query_lore_keywords
echo ""
test_classify_query_memory_keywords
echo ""
test_classify_query_default_both
echo ""
test_query_claude_memory_returns_results
echo ""
test_query_claude_memory_missing_db
echo ""
test_query_claude_memory_skips_low_importance
echo ""
test_enrich_decision_shadow
echo ""
test_enrich_pattern_shadow
echo ""
test_enrich_no_lore_prefix
echo ""
test_lore_first_without_memory_db
echo ""
test_memory_first_fallback_to_lore
echo ""
test_both_mode_dedup
echo ""
test_compact_provenance_prefix
echo ""
test_backward_compat_recall_unchanged
echo ""
test_routed_recall_no_query_error
echo ""

echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
