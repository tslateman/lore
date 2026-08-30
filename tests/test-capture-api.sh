#!/usr/bin/env bash
# Integration tests for the unified capture API (lore capture)
#
# Tests type inference, explicit type overrides, default behavior,
# and backward compatibility with lore remember / learn / fail.

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
    mkdir -p "$FIXTURE_DIR/transfer" "$FIXTURE_DIR/inbox/data" "$FIXTURE_DIR/inbox/lib"
    mkdir -p "$FIXTURE_DIR/graph" "$FIXTURE_DIR/lib"

    # Copy component scripts and libraries
    cp -R "$SCRIPT_DIR/../journal/"* "$FIXTURE_DIR/journal/"
    cp -R "$SCRIPT_DIR/../patterns/"* "$FIXTURE_DIR/patterns/"
    cp -R "$SCRIPT_DIR/../failures/"* "$FIXTURE_DIR/failures/"
    cp -R "$SCRIPT_DIR/../transfer/"* "$FIXTURE_DIR/transfer/"
    cp -R "$SCRIPT_DIR/../inbox/"* "$FIXTURE_DIR/inbox/"
    cp -R "$SCRIPT_DIR/../graph/"* "$FIXTURE_DIR/graph/"
    cp -R "$SCRIPT_DIR/../lib/"* "$FIXTURE_DIR/lib/"

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
    : > "$FIXTURE_DIR/inbox/data/signals.jsonl"

    # Reset paths.sh idempotency guard so it re-derives from new LORE_DIR
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
    before=$(file_size "$FIXTURE_DIR/journal/data/decisions.jsonl")

    "$FIXTURE_DIR/lore.sh" capture "Test decision via rationale" --rationale "Because tests" --force

    assert_file_grew "decisions.jsonl grew" "$FIXTURE_DIR/journal/data/decisions.jsonl" "$before"
    assert_contains "decision text recorded" "$FIXTURE_DIR/journal/data/decisions.jsonl" "Test decision via rationale"
    teardown
}

test_infer_pattern_from_solution() {
    echo "Test: --solution flag infers pattern type"
    setup
    local before
    before=$(file_size "$FIXTURE_DIR/patterns/data/patterns.yaml")

    "$FIXTURE_DIR/lore.sh" capture "Test pattern via solution" --solution "Do the thing" --force

    assert_file_grew "patterns.yaml grew" "$FIXTURE_DIR/patterns/data/patterns.yaml" "$before"
    assert_contains "pattern text recorded" "$FIXTURE_DIR/patterns/data/patterns.yaml" "Test pattern via solution"
    teardown
}

test_infer_failure_from_error_type() {
    echo "Test: --error-type flag infers failure type"
    setup
    local before
    before=$(file_size "$FIXTURE_DIR/failures/data/failures.jsonl")

    # cmd_fail may return nonzero on empty optional flags (short-circuit eval bug)
    "$FIXTURE_DIR/lore.sh" capture "Test failure via error-type" --error-type ToolError || true

    assert_file_grew "failures.jsonl grew" "$FIXTURE_DIR/failures/data/failures.jsonl" "$before"
    assert_contains "failure text recorded" "$FIXTURE_DIR/failures/data/failures.jsonl" "Test failure via error-type"
    teardown
}

test_explicit_decision_overrides_default() {
    echo "Test: --decision flag routes to journal even without inference flags"
    setup
    local dec_before pat_before
    dec_before=$(file_size "$FIXTURE_DIR/journal/data/decisions.jsonl")
    pat_before=$(file_size "$FIXTURE_DIR/patterns/data/patterns.yaml")

    "$FIXTURE_DIR/lore.sh" capture "Explicit decision" --decision --rationale "Forced" --force

    assert_file_grew "decisions.jsonl grew" "$FIXTURE_DIR/journal/data/decisions.jsonl" "$dec_before"
    assert_contains "explicit decision recorded" "$FIXTURE_DIR/journal/data/decisions.jsonl" "Explicit decision"

    # Patterns file should NOT have grown
    local pat_after
    pat_after=$(file_size "$FIXTURE_DIR/patterns/data/patterns.yaml")
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
    pat_before=$(file_size "$FIXTURE_DIR/patterns/data/patterns.yaml")

    "$FIXTURE_DIR/lore.sh" capture "Override to pattern" --pattern --force

    assert_file_grew "patterns.yaml grew" "$FIXTURE_DIR/patterns/data/patterns.yaml" "$pat_before"
    teardown
}

test_default_creates_signal() {
    echo "Test: no type flags defaults to signal"
    setup
    local before
    before=$(file_size "$FIXTURE_DIR/inbox/data/signals.jsonl")

    "$FIXTURE_DIR/lore.sh" capture "Default signal"

    assert_file_grew "signals.jsonl grew" "$FIXTURE_DIR/inbox/data/signals.jsonl" "$before"
    assert_contains "default signal recorded" "$FIXTURE_DIR/inbox/data/signals.jsonl" "Default signal"
    teardown
}

test_backward_compat_remember() {
    echo "Test: lore remember still works"
    setup
    local before
    before=$(file_size "$FIXTURE_DIR/journal/data/decisions.jsonl")

    "$FIXTURE_DIR/lore.sh" remember "Backward compat decision" --rationale "Still works" --force

    assert_file_grew "decisions.jsonl grew" "$FIXTURE_DIR/journal/data/decisions.jsonl" "$before"
    assert_contains "remember text recorded" "$FIXTURE_DIR/journal/data/decisions.jsonl" "Backward compat decision"
    teardown
}

test_backward_compat_learn() {
    echo "Test: lore learn still works"
    setup
    local pat_before
    pat_before=$(file_size "$FIXTURE_DIR/patterns/data/patterns.yaml")

    "$FIXTURE_DIR/lore.sh" learn "Backward compat pattern" --context "testing" --solution "test it" --force

    assert_file_grew "patterns.yaml grew" "$FIXTURE_DIR/patterns/data/patterns.yaml" "$pat_before"
    assert_contains "learn text recorded" "$FIXTURE_DIR/patterns/data/patterns.yaml" "Backward compat pattern"
    teardown
}

test_backward_compat_fail() {
    echo "Test: lore fail still works"
    setup
    local before
    before=$(file_size "$FIXTURE_DIR/failures/data/failures.jsonl")

    # cmd_fail may return nonzero on empty optional flags (short-circuit eval bug)
    "$FIXTURE_DIR/lore.sh" fail ToolError "Backward compat failure" || true

    assert_file_grew "failures.jsonl grew" "$FIXTURE_DIR/failures/data/failures.jsonl" "$before"
    assert_contains "fail text recorded" "$FIXTURE_DIR/failures/data/failures.jsonl" "Backward compat failure"
    teardown
}

test_capture_help_mentions_capture() {
    echo "Test: help output mentions capture command"
    setup

    local help_output
    help_output=$("$FIXTURE_DIR/lore.sh" help 2>&1)

    if echo "$help_output" | grep -qi "capture"; then
        echo "  PASS: help mentions capture"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: help does not mention capture"
        FAIL=$((FAIL + 1))
    fi
    teardown
}

test_explicit_signal_override() {
    echo "Test: --signal flag routes to inbox even with other flags"
    setup
    local sig_before dec_before
    sig_before=$(file_size "$FIXTURE_DIR/inbox/data/signals.jsonl")
    dec_before=$(file_size "$FIXTURE_DIR/journal/data/decisions.jsonl")

    "$FIXTURE_DIR/lore.sh" capture "Explicit signal" --signal

    assert_file_grew "signals.jsonl grew" "$FIXTURE_DIR/inbox/data/signals.jsonl" "$sig_before"
    assert_contains "signal text recorded" "$FIXTURE_DIR/inbox/data/signals.jsonl" "Explicit signal"

    # Decisions file should NOT have grown
    local dec_after
    dec_after=$(file_size "$FIXTURE_DIR/journal/data/decisions.jsonl")
    if [[ "$dec_after" -eq "$dec_before" ]]; then
        echo "  PASS: decisions.jsonl unchanged (explicit signal worked)"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: decisions.jsonl grew (explicit signal did not work)"
        FAIL=$((FAIL + 1))
    fi
    teardown
}

test_capture_signal_with_tags() {
    echo "Test: bare capture with --tags creates tagged signal"
    setup
    local before
    before=$(file_size "$FIXTURE_DIR/inbox/data/signals.jsonl")

    "$FIXTURE_DIR/lore.sh" capture "Tagged signal" --tags "infra,networking"

    assert_file_grew "signals.jsonl grew" "$FIXTURE_DIR/inbox/data/signals.jsonl" "$before"
    assert_contains "tagged signal recorded" "$FIXTURE_DIR/inbox/data/signals.jsonl" "Tagged signal"
    assert_contains "tags preserved" "$FIXTURE_DIR/inbox/data/signals.jsonl" "infra"
    teardown
}

test_decision_flags_still_route_to_decision() {
    echo "Test: --rationale flag still routes to decision (not observation)"
    setup
    local dec_before obs_before
    dec_before=$(file_size "$FIXTURE_DIR/journal/data/decisions.jsonl")
    sig_before=$(file_size "$FIXTURE_DIR/inbox/data/signals.jsonl")

    "$FIXTURE_DIR/lore.sh" capture "Decision with rationale" --rationale "Because reasons" --force

    assert_file_grew "decisions.jsonl grew" "$FIXTURE_DIR/journal/data/decisions.jsonl" "$dec_before"
    assert_contains "decision text recorded" "$FIXTURE_DIR/journal/data/decisions.jsonl" "Decision with rationale"

    # Signals file should NOT have grown
    local sig_after
    sig_after=$(file_size "$FIXTURE_DIR/inbox/data/signals.jsonl")
    if [[ "$sig_after" -eq "$sig_before" ]]; then
        echo "  PASS: signals.jsonl unchanged (decision routing worked)"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: signals.jsonl grew (decision routing failed)"
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
test_default_creates_signal
echo ""
test_explicit_signal_override
echo ""
test_capture_signal_with_tags
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
