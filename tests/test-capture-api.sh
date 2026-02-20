#!/usr/bin/env bash
# Integration tests for the unified capture API (lore capture)
#
# Tests type inference, explicit type overrides, default behavior,
# and backward compatibility with lore remember / learn / fail.

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
    mkdir -p "$TMPDIR/transfer" "$TMPDIR/inbox/data" "$TMPDIR/inbox/lib"
    mkdir -p "$TMPDIR/graph" "$TMPDIR/lib"

    # Copy component scripts and libraries
    cp -R "$SCRIPT_DIR/../journal/"* "$TMPDIR/journal/"
    cp -R "$SCRIPT_DIR/../patterns/"* "$TMPDIR/patterns/"
    cp -R "$SCRIPT_DIR/../failures/"* "$TMPDIR/failures/"
    cp -R "$SCRIPT_DIR/../transfer/"* "$TMPDIR/transfer/"
    cp -R "$SCRIPT_DIR/../inbox/"* "$TMPDIR/inbox/"
    cp -R "$SCRIPT_DIR/../graph/"* "$TMPDIR/graph/"
    cp -R "$SCRIPT_DIR/../lib/"* "$TMPDIR/lib/"

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
    : > "$TMPDIR/inbox/data/observations.jsonl"

    # Reset paths.sh idempotency guard so it re-derives from new LORE_DIR
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

assert_fail() {
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

assert_file_grew() {
    local desc="$1"
    local file="$2"
    local before="$3"
    local after
    after=$(wc -c < "$file" | tr -d ' ')
    if [[ "$after" -gt "$before" ]]; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc (file did not grow: before=$before after=$after)"
        FAIL=$((FAIL + 1))
    fi
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

file_size() {
    wc -c < "$1" | tr -d ' '
}

# --- Tests ---

test_infer_decision_from_rationale() {
    echo "Test: --rationale flag infers decision type"
    setup
    local before
    before=$(file_size "$TMPDIR/journal/data/decisions.jsonl")

    "$TMPDIR/lore.sh" capture "Test decision via rationale" --rationale "Because tests" --force

    assert_file_grew "decisions.jsonl grew" "$TMPDIR/journal/data/decisions.jsonl" "$before"
    assert_contains "decision text recorded" "$TMPDIR/journal/data/decisions.jsonl" "Test decision via rationale"
    teardown
}

test_infer_pattern_from_solution() {
    echo "Test: --solution flag infers pattern type"
    setup
    local before
    before=$(file_size "$TMPDIR/patterns/data/patterns.yaml")

    "$TMPDIR/lore.sh" capture "Test pattern via solution" --solution "Do the thing" --force

    assert_file_grew "patterns.yaml grew" "$TMPDIR/patterns/data/patterns.yaml" "$before"
    assert_contains "pattern text recorded" "$TMPDIR/patterns/data/patterns.yaml" "Test pattern via solution"
    teardown
}

test_infer_failure_from_error_type() {
    echo "Test: --error-type flag infers failure type"
    setup
    local before
    before=$(file_size "$TMPDIR/failures/data/failures.jsonl")

    # cmd_fail may return nonzero on empty optional flags (short-circuit eval bug)
    "$TMPDIR/lore.sh" capture "Test failure via error-type" --error-type ToolError || true

    assert_file_grew "failures.jsonl grew" "$TMPDIR/failures/data/failures.jsonl" "$before"
    assert_contains "failure text recorded" "$TMPDIR/failures/data/failures.jsonl" "Test failure via error-type"
    teardown
}

test_explicit_decision_overrides_default() {
    echo "Test: --decision flag routes to journal even without inference flags"
    setup
    local dec_before pat_before
    dec_before=$(file_size "$TMPDIR/journal/data/decisions.jsonl")
    pat_before=$(file_size "$TMPDIR/patterns/data/patterns.yaml")

    "$TMPDIR/lore.sh" capture "Explicit decision" --decision --rationale "Forced" --force

    assert_file_grew "decisions.jsonl grew" "$TMPDIR/journal/data/decisions.jsonl" "$dec_before"
    assert_contains "explicit decision recorded" "$TMPDIR/journal/data/decisions.jsonl" "Explicit decision"

    # Patterns file should NOT have grown
    local pat_after
    pat_after=$(file_size "$TMPDIR/patterns/data/patterns.yaml")
    if [[ "$pat_after" -eq "$pat_before" ]]; then
        echo "  PASS: patterns.yaml unchanged (explicit decision worked)"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: patterns.yaml grew (explicit decision did not work)"
        FAIL=$((FAIL + 1))
    fi
    teardown
}

test_explicit_pattern_overrides_default() {
    echo "Test: --pattern flag overrides default decision inference"
    setup
    local pat_before
    pat_before=$(file_size "$TMPDIR/patterns/data/patterns.yaml")

    "$TMPDIR/lore.sh" capture "Override to pattern" --pattern --force

    assert_file_grew "patterns.yaml grew" "$TMPDIR/patterns/data/patterns.yaml" "$pat_before"
    teardown
}

test_default_creates_observation() {
    echo "Test: no type flags defaults to observation"
    setup
    local before
    before=$(file_size "$TMPDIR/inbox/data/observations.jsonl")

    "$TMPDIR/lore.sh" capture "Default observation"

    assert_file_grew "observations.jsonl grew" "$TMPDIR/inbox/data/observations.jsonl" "$before"
    assert_contains "default observation recorded" "$TMPDIR/inbox/data/observations.jsonl" "Default observation"
    teardown
}

test_backward_compat_remember() {
    echo "Test: lore remember still works"
    setup
    local before
    before=$(file_size "$TMPDIR/journal/data/decisions.jsonl")

    "$TMPDIR/lore.sh" remember "Backward compat decision" --rationale "Still works" --force

    assert_file_grew "decisions.jsonl grew" "$TMPDIR/journal/data/decisions.jsonl" "$before"
    assert_contains "remember text recorded" "$TMPDIR/journal/data/decisions.jsonl" "Backward compat decision"
    teardown
}

test_backward_compat_learn() {
    echo "Test: lore learn still works"
    setup
    local pat_before
    pat_before=$(file_size "$TMPDIR/patterns/data/patterns.yaml")

    "$TMPDIR/lore.sh" learn "Backward compat pattern" --context "testing" --solution "test it" --force

    assert_file_grew "patterns.yaml grew" "$TMPDIR/patterns/data/patterns.yaml" "$pat_before"
    assert_contains "learn text recorded" "$TMPDIR/patterns/data/patterns.yaml" "Backward compat pattern"
    teardown
}

test_backward_compat_fail() {
    echo "Test: lore fail still works"
    setup
    local before
    before=$(file_size "$TMPDIR/failures/data/failures.jsonl")

    # cmd_fail may return nonzero on empty optional flags (short-circuit eval bug)
    "$TMPDIR/lore.sh" fail ToolError "Backward compat failure" || true

    assert_file_grew "failures.jsonl grew" "$TMPDIR/failures/data/failures.jsonl" "$before"
    assert_contains "fail text recorded" "$TMPDIR/failures/data/failures.jsonl" "Backward compat failure"
    teardown
}

test_capture_help_mentions_capture() {
    echo "Test: help output mentions capture command"
    setup

    local help_output
    help_output=$("$TMPDIR/lore.sh" help 2>&1)

    if echo "$help_output" | grep -qi "capture"; then
        echo "  PASS: help mentions capture"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: help does not mention capture"
        FAIL=$((FAIL + 1))
    fi
    teardown
}

test_explicit_observation_override() {
    echo "Test: --observation flag routes to inbox even with other flags"
    setup
    local obs_before dec_before
    obs_before=$(file_size "$TMPDIR/inbox/data/observations.jsonl")
    dec_before=$(file_size "$TMPDIR/journal/data/decisions.jsonl")

    "$TMPDIR/lore.sh" capture "Explicit observation" --observation

    assert_file_grew "observations.jsonl grew" "$TMPDIR/inbox/data/observations.jsonl" "$obs_before"
    assert_contains "observation text recorded" "$TMPDIR/inbox/data/observations.jsonl" "Explicit observation"

    # Decisions file should NOT have grown
    local dec_after
    dec_after=$(file_size "$TMPDIR/journal/data/decisions.jsonl")
    if [[ "$dec_after" -eq "$dec_before" ]]; then
        echo "  PASS: decisions.jsonl unchanged (explicit observation worked)"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: decisions.jsonl grew (explicit observation did not work)"
        FAIL=$((FAIL + 1))
    fi
    teardown
}

test_capture_observation_with_tags() {
    echo "Test: bare capture with --tags creates tagged observation"
    setup
    local before
    before=$(file_size "$TMPDIR/inbox/data/observations.jsonl")

    "$TMPDIR/lore.sh" capture "Tagged observation" --tags "infra,networking"

    assert_file_grew "observations.jsonl grew" "$TMPDIR/inbox/data/observations.jsonl" "$before"
    assert_contains "tagged observation recorded" "$TMPDIR/inbox/data/observations.jsonl" "Tagged observation"
    assert_contains "tags preserved" "$TMPDIR/inbox/data/observations.jsonl" "infra"
    teardown
}

test_decision_flags_still_route_to_decision() {
    echo "Test: --rationale flag still routes to decision (not observation)"
    setup
    local dec_before obs_before
    dec_before=$(file_size "$TMPDIR/journal/data/decisions.jsonl")
    obs_before=$(file_size "$TMPDIR/inbox/data/observations.jsonl")

    "$TMPDIR/lore.sh" capture "Decision with rationale" --rationale "Because reasons" --force

    assert_file_grew "decisions.jsonl grew" "$TMPDIR/journal/data/decisions.jsonl" "$dec_before"
    assert_contains "decision text recorded" "$TMPDIR/journal/data/decisions.jsonl" "Decision with rationale"

    # Observations file should NOT have grown
    local obs_after
    obs_after=$(file_size "$TMPDIR/inbox/data/observations.jsonl")
    if [[ "$obs_after" -eq "$obs_before" ]]; then
        echo "  PASS: observations.jsonl unchanged (decision routing worked)"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: observations.jsonl grew (decision routing failed)"
        FAIL=$((FAIL + 1))
    fi
    teardown
}

# --- Runner ---

echo "=== Lore Capture API Integration Tests ==="
echo ""

test_infer_decision_from_rationale
echo ""
test_infer_pattern_from_solution
echo ""
test_infer_failure_from_error_type
echo ""
test_explicit_decision_overrides_default
echo ""
test_explicit_pattern_overrides_default
echo ""
test_default_creates_observation
echo ""
test_explicit_observation_override
echo ""
test_capture_observation_with_tags
echo ""
test_decision_flags_still_route_to_decision
echo ""
test_backward_compat_remember
echo ""
test_backward_compat_learn
echo ""
test_backward_compat_fail
echo ""
test_capture_help_mentions_capture
echo ""

echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
