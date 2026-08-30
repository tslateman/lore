#!/usr/bin/env bash
# Integration tests for the recall API (lore recall)
#
# Tests the unified recall interface: search, failures, triggers,
# patterns, project context, brief, and backward compatibility.
# Uses a temporary directory so production data is untouched.

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
    mkdir -p "$FIXTURE_DIR/transfer" "$FIXTURE_DIR/inbox/lib"
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

    # Initialize empty data files
    echo '[]' > "$FIXTURE_DIR/journal/data/decisions.jsonl"
    cat > "$FIXTURE_DIR/patterns/data/patterns.yaml" <<'YAML'
# Pattern Learner Database
patterns: []

anti_patterns: []
YAML
    : > "$FIXTURE_DIR/failures/data/failures.jsonl"

    unset _LORE_PATHS_LOADED
    export LORE_DIR="$FIXTURE_DIR"
    export LORE_DATA_DIR="$FIXTURE_DIR"
    export CLAUDE_MEMORY_DB="$FIXTURE_DIR/memory.sqlite"
    export LORE_SEARCH_DB="$FIXTURE_DIR/search.db"
}

teardown() {
    remove_fixture "$FIXTURE_DIR"
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

assert_fails() {
    local desc="$1"
    shift
    if "$@" >/dev/null 2>&1; then
        echo "  FAIL: $desc (expected failure, got success)"
        FAIL=$((FAIL + 1))
    else
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    fi
}

# --- Tests ---

test_recall_search_default() {
    echo "Test: lore recall <query> performs search"
    setup

    # Seed a decision so there's something to find
    "$FIXTURE_DIR/lore.sh" remember "Test decision alpha" --rationale "testing" --force >/dev/null 2>&1

    # recall with a query delegates to search; no FTS5 index so grep fallback
    local output
    output=$("$FIXTURE_DIR/lore.sh" recall "test" 2>&1) || true

    # Verify the command ran (no "Unknown command" error)
    assert_output_not_contains "no unknown command error" "$output" "Unknown command"

    teardown
}

test_recall_no_args_shows_error() {
    echo "Test: lore recall with no args shows usage error"
    setup

    local output
    output=$("$FIXTURE_DIR/lore.sh" recall 2>&1) || true

    assert_output_contains "shows error on empty args" "$output" "Error"
    assert_output_contains "shows usage hint" "$output" "Usage"

    teardown
}

test_recall_failures() {
    echo "Test: lore recall --failures shows seeded failures"
    setup

    # Seed a failure
    "$FIXTURE_DIR/lore.sh" fail ToolError "Test failure message" >/dev/null 2>&1

    local output
    output=$("$FIXTURE_DIR/lore.sh" recall --failures 2>&1)

    assert_output_contains "output contains failure type" "$output" "ToolError"
    assert_output_contains "output contains failure message" "$output" "Test failure message"

    teardown
}

test_recall_failures_type_filter() {
    echo "Test: lore recall --failures --type filters by type"
    setup

    # Seed two different failure types
    "$FIXTURE_DIR/lore.sh" fail ToolError "Tool broke" >/dev/null 2>&1
    "$FIXTURE_DIR/lore.sh" fail Timeout "Request timed out" >/dev/null 2>&1

    local output
    output=$("$FIXTURE_DIR/lore.sh" recall --failures --type ToolError 2>&1)

    assert_output_contains "filtered output shows ToolError" "$output" "ToolError"
    assert_output_not_contains "filtered output excludes Timeout" "$output" "Request timed out"

    teardown
}

test_recall_triggers_no_recurring() {
    echo "Test: lore recall --triggers with few failures shows no recurring"
    setup

    # Seed fewer than 3 failures of one type
    "$FIXTURE_DIR/lore.sh" fail ToolError "Single occurrence" >/dev/null 2>&1

    local output
    output=$("$FIXTURE_DIR/lore.sh" recall --triggers 2>&1)

    assert_output_contains "reports no recurring types" "$output" "No recurring"

    teardown
}

test_recall_triggers_with_recurring() {
    echo "Test: lore recall --triggers shows recurring failure types"
    setup

    # Seed 3+ failures of the same type
    "$FIXTURE_DIR/lore.sh" fail ToolError "First occurrence" >/dev/null 2>&1
    "$FIXTURE_DIR/lore.sh" fail ToolError "Second occurrence" >/dev/null 2>&1
    "$FIXTURE_DIR/lore.sh" fail ToolError "Third occurrence" >/dev/null 2>&1

    local output
    output=$("$FIXTURE_DIR/lore.sh" recall --triggers 2>&1)

    assert_output_contains "shows recurring ToolError" "$output" "ToolError"
    assert_output_contains "shows occurrence count" "$output" "3"

    teardown
}

test_recall_patterns() {
    echo "Test: lore recall --patterns delegates to suggest"
    setup

    # With context — exits cleanly (no patterns to match, but no crash)
    assert_ok "patterns mode with context exits cleanly" "$FIXTURE_DIR/lore.sh" recall --patterns "bash scripting"

    # Without context — cmd_suggest requires context, so should fail with error
    local output
    output=$("$FIXTURE_DIR/lore.sh" recall --patterns 2>&1) || true
    assert_output_contains "patterns without context shows error" "$output" "Error"

    teardown
}

test_recall_project() {
    echo "Test: lore recall --project runs and produces output"
    setup

    local output
    output=$("$FIXTURE_DIR/lore.sh" recall --project testproject 2>&1)

    # cmd_context outputs section headers even with no data
    assert_output_contains "output contains project name or section" "$output" "testproject\|Decisions\|Patterns"

    teardown
}

test_recall_brief() {
    echo "Test: lore recall --brief runs without unknown command error"
    setup

    local output
    output=$("$FIXTURE_DIR/lore.sh" recall --brief "test" 2>&1) || true

    assert_output_not_contains "no unknown command error" "$output" "Unknown command"

    teardown
}

test_backward_compat_search() {
    echo "Test: lore search still works as a direct command"
    setup

    "$FIXTURE_DIR/lore.sh" remember "Compat search decision" --rationale "testing" --force >/dev/null 2>&1

    local output
    output=$("$FIXTURE_DIR/lore.sh" search "compat" 2>&1) || true

    assert_output_not_contains "no unknown command error" "$output" "Unknown command"

    teardown
}

test_backward_compat_failures() {
    echo "Test: lore failures still works as a direct command"
    setup

    "$FIXTURE_DIR/lore.sh" fail ToolError "Compat failure" >/dev/null 2>&1

    local output
    output=$("$FIXTURE_DIR/lore.sh" failures 2>&1)

    assert_output_contains "direct failures command works" "$output" "ToolError"

    teardown
}

test_backward_compat_triggers() {
    echo "Test: lore triggers still works as a direct command"
    setup

    local output
    output=$("$FIXTURE_DIR/lore.sh" triggers 2>&1)

    assert_output_contains "direct triggers command shows no recurring" "$output" "No recurring"

    teardown
}

test_recall_concepts_fallback() {
    echo "Test: lore recall --concepts lists concepts from YAML when no search.db"
    setup

    # Seed a concept via capture
    "$FIXTURE_DIR/lore.sh" capture "Fail-silent wrappers" --concept --definition "Library calls that catch errors" >/dev/null 2>&1

    local output
    output=$("$FIXTURE_DIR/lore.sh" recall --concepts 2>&1)

    assert_output_contains "output contains concept name" "$output" "Fail-silent wrappers"
    assert_output_contains "output contains concept definition" "$output" "Library calls that catch errors"

    teardown
}

test_recall_concepts_empty() {
    echo "Test: lore recall --concepts shows message when no concepts exist"
    setup

    local output
    output=$("$FIXTURE_DIR/lore.sh" recall --concepts 2>&1)

    assert_output_contains "shows no concepts message" "$output" "No concepts"

    teardown
}

test_capture_concept() {
    echo "Test: lore capture --concept creates a concept"
    setup

    local output
    output=$("$FIXTURE_DIR/lore.sh" capture "Test Concept" --concept --definition "A test concept" 2>&1)

    assert_output_contains "output confirms creation" "$output" "Created concept"
    assert_output_contains "output shows concept name" "$output" "Test Concept"

    teardown
}

test_capture_concept_in_yaml() {
    echo "Test: capture --concept writes to concepts.yaml"
    setup

    "$FIXTURE_DIR/lore.sh" capture "YAML Concept" --concept --definition "Stored in YAML" >/dev/null 2>&1

    local cf="$FIXTURE_DIR/patterns/data/concepts.yaml"
    assert_ok "concepts.yaml exists" test -f "$cf"

    local content
    content=$(cat "$cf")
    assert_output_contains "YAML contains concept name" "$content" "YAML Concept"
    assert_output_contains "YAML contains definition" "$content" "Stored in YAML"

    teardown
}

# --- Runner ---

echo "=== Lore Recall Integration Tests ==="
echo ""

test_recall_search_default
echo ""
test_recall_no_args_shows_error
echo ""
test_recall_failures
echo ""
test_recall_failures_type_filter
echo ""
test_recall_triggers_no_recurring
echo ""
test_recall_triggers_with_recurring
echo ""
test_recall_patterns
echo ""
test_recall_project
echo ""
test_recall_brief
echo ""
test_backward_compat_search
echo ""
test_backward_compat_failures
echo ""
test_backward_compat_triggers
echo ""
test_recall_concepts_fallback
echo ""
test_recall_concepts_empty
echo ""
test_capture_concept
echo ""
test_capture_concept_in_yaml
echo ""

echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
