#!/usr/bin/env bash
# Integration tests for the goals API (lore goal create/list/show)
#
# Tests goal lifecycle: create, list, show, and status update.
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

    # Clear any goal files copied from the source tree
    rm -f "$TMPDIR/intent/data/goals/"*.yaml

    export LORE_DIR="$TMPDIR"
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

# --- Helper ---

# Extract goal ID from create output (e.g., "Created goal: goal-1234567890-abcdef01")
extract_goal_id() {
    local output="$1"
    echo "$output" | sed 's/\x1b\[[0-9;]*m//g' | grep -o 'goal-[a-z0-9-]*' | head -1
}

# --- Tests ---

test_goal_create() {
    echo "Test: lore goal create produces a goal file"
    setup

    local output
    output=$("$TMPDIR/lore.sh" goal create "Test Goal Alpha" 2>&1)

    local goal_id
    goal_id=$(extract_goal_id "$output")

    # Verify command reported success
    assert_output_contains "create output mentions goal ID" "$output" "goal-"

    # Verify goal file exists
    local goal_file="$TMPDIR/intent/data/goals/${goal_id}.yaml"
    assert_file_exists "goal file created on disk" "$goal_file"

    # Verify file contains the goal name
    if [[ -f "$goal_file" ]]; then
        local file_content
        file_content=$(cat "$goal_file")
        assert_output_contains "goal file contains name" "$file_content" "Test Goal Alpha"
        assert_output_contains "goal file has draft status" "$file_content" "status: draft"
        assert_output_contains "goal file has medium priority" "$file_content" "priority: medium"
    fi

    teardown
}

test_goal_create_with_priority() {
    echo "Test: lore goal create respects --priority flag"
    setup

    local output
    output=$("$TMPDIR/lore.sh" goal create "High Priority Goal" --priority high 2>&1)

    local goal_id
    goal_id=$(extract_goal_id "$output")

    local goal_file="$TMPDIR/intent/data/goals/${goal_id}.yaml"
    if [[ -f "$goal_file" ]]; then
        local file_content
        file_content=$(cat "$goal_file")
        assert_output_contains "goal has high priority" "$file_content" "priority: high"
    else
        echo "  FAIL: goal file not found for priority test"
        FAIL=$((FAIL + 1))
    fi

    teardown
}

test_goal_list() {
    echo "Test: lore goal list shows created goals"
    setup

    # Create two goals
    "$TMPDIR/lore.sh" goal create "Goal One" >/dev/null 2>&1
    "$TMPDIR/lore.sh" goal create "Goal Two" >/dev/null 2>&1

    local output
    output=$("$TMPDIR/lore.sh" goal list 2>&1)

    assert_output_contains "list shows Goal One" "$output" "Goal One"
    assert_output_contains "list shows Goal Two" "$output" "Goal Two"
    assert_output_contains "list shows total count" "$output" "2 goal"

    teardown
}

test_goal_list_empty() {
    echo "Test: lore goal list handles empty state"
    setup

    local output
    output=$("$TMPDIR/lore.sh" goal list 2>&1)

    assert_output_contains "empty list shows no goals message" "$output" "No goals found"

    teardown
}

test_goal_show() {
    echo "Test: lore goal show displays goal details"
    setup

    local create_output
    create_output=$("$TMPDIR/lore.sh" goal create "Detailed Goal" --priority high 2>&1)

    local goal_id
    goal_id=$(extract_goal_id "$create_output")

    local output
    output=$("$TMPDIR/lore.sh" goal show "$goal_id" 2>&1)

    assert_output_contains "show displays goal name" "$output" "Detailed Goal"
    assert_output_contains "show displays ID" "$output" "$goal_id"
    assert_output_contains "show displays status" "$output" "draft"
    assert_output_contains "show displays priority" "$output" "high"

    teardown
}

test_goal_show_missing() {
    echo "Test: lore goal show rejects missing goal"
    setup

    local output
    if "$TMPDIR/lore.sh" goal show "goal-nonexistent" >/dev/null 2>&1; then
        echo "  FAIL: show should fail for missing goal (got success)"
        FAIL=$((FAIL + 1))
    else
        echo "  PASS: show rejects missing goal ID"
        PASS=$((PASS + 1))
    fi

    teardown
}

test_goal_complete() {
    echo "Test: goal status updates to completed via yq"
    setup

    local create_output
    create_output=$("$TMPDIR/lore.sh" goal create "Complete Me" 2>&1)

    local goal_id
    goal_id=$(extract_goal_id "$create_output")

    local goal_file="$TMPDIR/intent/data/goals/${goal_id}.yaml"

    # Update status to completed (no CLI command exists; yq is the mechanism)
    yq -i '.status = "completed"' "$goal_file"

    # Verify via lore goal show
    local output
    output=$("$TMPDIR/lore.sh" goal show "$goal_id" 2>&1)
    assert_output_contains "show reflects completed status" "$output" "completed"

    # Verify via lore goal list --status completed
    local list_output
    list_output=$("$TMPDIR/lore.sh" goal list --status completed 2>&1)
    assert_output_contains "list filters by completed status" "$list_output" "Complete Me"

    teardown
}

test_goal_cleanup() {
    echo "Test: goal files are cleaned up properly"
    setup

    local create_output
    create_output=$("$TMPDIR/lore.sh" goal create "Ephemeral Goal" 2>&1)

    local goal_id
    goal_id=$(extract_goal_id "$create_output")

    local goal_file="$TMPDIR/intent/data/goals/${goal_id}.yaml"
    assert_file_exists "goal file exists before cleanup" "$goal_file"

    # Remove the goal file (manual cleanup, as delete command does not exist)
    rm -f "$goal_file"

    local list_output
    list_output=$("$TMPDIR/lore.sh" goal list 2>&1)
    assert_output_contains "goal absent after removal" "$list_output" "No goals found"

    teardown
}

# --- Runner ---

echo "=== Lore Goals Integration Tests ==="
echo ""

test_goal_create
echo ""
test_goal_create_with_priority
echo ""
test_goal_list
echo ""
test_goal_list_empty
echo ""
test_goal_show
echo ""
test_goal_show_missing
echo ""
test_goal_complete
echo ""
test_goal_cleanup
echo ""

echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
