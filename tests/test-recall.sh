#!/usr/bin/env bash
# Integration tests for the recall API (lore recall)
#
# Tests the unified recall interface: search, failures, triggers,
# patterns, project context, brief, and backward compatibility.
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
    echo '[]' > "$TMPDIR/journal/data/decisions.jsonl"
    cat > "$TMPDIR/patterns/data/patterns.yaml" <<'YAML'
# Pattern Learner Database
patterns: []

anti_patterns: []
YAML
    : > "$TMPDIR/failures/data/failures.jsonl"

    unset _LORE_PATHS_LOADED
    export LORE_DIR="$TMPDIR"
    export LORE_DATA_DIR="$TMPDIR"
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
    "$TMPDIR/lore.sh" remember "Test decision alpha" --rationale "testing" --force >/dev/null 2>&1

    # recall with a query delegates to search; no FTS5 index so grep fallback
    local output
    output=$("$TMPDIR/lore.sh" recall "test" 2>&1) || true

    # Verify the command ran (no "Unknown command" error)
    assert_output_not_contains "no unknown command error" "$output" "Unknown command"

    teardown
}

test_recall_no_args_shows_error() {
    echo "Test: lore recall with no args shows usage error"
    setup

    local output
    output=$("$TMPDIR/lore.sh" recall 2>&1) || true

    assert_output_contains "shows error on empty args" "$output" "Error"
    assert_output_contains "shows usage hint" "$output" "Usage"

    teardown
}

test_recall_failures() {
    echo "Test: lore recall --failures shows seeded failures"
    setup

    # Seed a failure
    "$TMPDIR/lore.sh" fail ToolError "Test failure message" >/dev/null 2>&1

    local output
    output=$("$TMPDIR/lore.sh" recall --failures 2>&1)

    assert_output_contains "output contains failure type" "$output" "ToolError"
    assert_output_contains "output contains failure message" "$output" "Test failure message"

    teardown
}

test_recall_failures_type_filter() {
    echo "Test: lore recall --failures --type filters by type"
    setup

    # Seed two different failure types
    "$TMPDIR/lore.sh" fail ToolError "Tool broke" >/dev/null 2>&1
    "$TMPDIR/lore.sh" fail Timeout "Request timed out" >/dev/null 2>&1

    local output
    output=$("$TMPDIR/lore.sh" recall --failures --type ToolError 2>&1)

    assert_output_contains "filtered output shows ToolError" "$output" "ToolError"
    assert_output_not_contains "filtered output excludes Timeout" "$output" "Request timed out"

    teardown
}

test_recall_triggers_no_recurring() {
    echo "Test: lore recall --triggers with few failures shows no recurring"
    setup

    # Seed fewer than 3 failures of one type
    "$TMPDIR/lore.sh" fail ToolError "Single occurrence" >/dev/null 2>&1

    local output
    output=$("$TMPDIR/lore.sh" recall --triggers 2>&1)

    assert_output_contains "reports no recurring types" "$output" "No recurring"

    teardown
}

test_recall_triggers_with_recurring() {
    echo "Test: lore recall --triggers shows recurring failure types"
    setup

    # Seed 3+ failures of the same type
    "$TMPDIR/lore.sh" fail ToolError "First occurrence" >/dev/null 2>&1
    "$TMPDIR/lore.sh" fail ToolError "Second occurrence" >/dev/null 2>&1
    "$TMPDIR/lore.sh" fail ToolError "Third occurrence" >/dev/null 2>&1

    local output
    output=$("$TMPDIR/lore.sh" recall --triggers 2>&1)

    assert_output_contains "shows recurring ToolError" "$output" "ToolError"
    assert_output_contains "shows occurrence count" "$output" "3"

    teardown
}

test_recall_patterns() {
    echo "Test: lore recall --patterns delegates to suggest"
    setup

    # With context — exits cleanly (no patterns to match, but no crash)
    assert_ok "patterns mode with context exits cleanly" "$TMPDIR/lore.sh" recall --patterns "bash scripting"

    # Without context — cmd_suggest requires context, so should fail with error
    local output
    output=$("$TMPDIR/lore.sh" recall --patterns 2>&1) || true
    assert_output_contains "patterns without context shows error" "$output" "Error"

    teardown
}

test_recall_project() {
    echo "Test: lore recall --project runs and produces output"
    setup

    local output
    output=$("$TMPDIR/lore.sh" recall --project testproject 2>&1)

    # cmd_context outputs section headers even with no data
    assert_output_contains "output contains project name or section" "$output" "testproject\|Decisions\|Patterns"

    teardown
}

test_recall_brief() {
    echo "Test: lore recall --brief runs without unknown command error"
    setup

    local output
    output=$("$TMPDIR/lore.sh" recall --brief "test" 2>&1) || true

    assert_output_not_contains "no unknown command error" "$output" "Unknown command"

    teardown
}

test_backward_compat_search() {
    echo "Test: lore search still works as a direct command"
    setup

    "$TMPDIR/lore.sh" remember "Compat search decision" --rationale "testing" --force >/dev/null 2>&1

    local output
    output=$("$TMPDIR/lore.sh" search "compat" 2>&1) || true

    assert_output_not_contains "no unknown command error" "$output" "Unknown command"

    teardown
}

test_backward_compat_failures() {
    echo "Test: lore failures still works as a direct command"
    setup

    "$TMPDIR/lore.sh" fail ToolError "Compat failure" >/dev/null 2>&1

    local output
    output=$("$TMPDIR/lore.sh" failures 2>&1)

    assert_output_contains "direct failures command works" "$output" "ToolError"

    teardown
}

test_backward_compat_triggers() {
    echo "Test: lore triggers still works as a direct command"
    setup

    local output
    output=$("$TMPDIR/lore.sh" triggers 2>&1)

    assert_output_contains "direct triggers command shows no recurring" "$output" "No recurring"

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

echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
