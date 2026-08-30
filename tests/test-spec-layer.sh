#!/usr/bin/env bash
# Integration tests for the specification layer
#
# Tests: spec quality scoring, lore review, lore brief, active subtraction

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
    mkdir -p "$FIXTURE_DIR/inbox/lib"
    mkdir -p "$FIXTURE_DIR/graph/data" "$FIXTURE_DIR/graph/lib"
    mkdir -p "$FIXTURE_DIR/lib"

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
    : > "$FIXTURE_DIR/journal/data/decisions.jsonl"
    cat > "$FIXTURE_DIR/patterns/data/patterns.yaml" <<'YAML'
# Pattern Learner Database
patterns: []

anti_patterns: []
YAML
    : > "$FIXTURE_DIR/failures/data/failures.jsonl"

    # Initialize graph
    echo '{"nodes":{},"edges":[]}' > "$FIXTURE_DIR/graph/data/graph.json"

    export LORE_DIR="$FIXTURE_DIR"
    export LORE_DATA_DIR="$FIXTURE_DIR"
    export CLAUDE_MEMORY_DB="$FIXTURE_DIR/memory.sqlite"
    export LORE_SEARCH_DB="$FIXTURE_DIR/search.db"
    # Reset paths.sh idempotency guard so it re-sources with new LORE_DIR
    unset _LORE_PATHS_LOADED
}

teardown() {
    remove_fixture "$FIXTURE_DIR"
}

assert_pass() {
    local desc="$1"
    echo "  PASS: $desc"
    PASS=$((PASS + 1))
}

assert_fail() {
    local desc="$1"
    echo "  FAIL: $desc"
    FAIL=$((FAIL + 1))
}

assert_output_contains() {
    local desc="$1"
    local output="$2"
    local pattern="$3"
    if echo "$output" | grep -q "$pattern" 2>/dev/null; then
        assert_pass "$desc"
    else
        assert_fail "$desc (pattern '$pattern' not in output)"
    fi
}

assert_output_not_contains() {
    local desc="$1"
    local output="$2"
    local pattern="$3"
    if echo "$output" | grep -q "$pattern" 2>/dev/null; then
        assert_fail "$desc (pattern '$pattern' found in output, expected absent)"
    else
        assert_pass "$desc"
    fi
}

# --- Tests ---

test_spec_quality_decision() {
    echo "Test: Decision spec quality is computed and stored"
    setup

    # Record a well-specified decision
    local output
    output=$("$FIXTURE_DIR/lore.sh" remember "Use PostgreSQL for data storage" \
        --rationale "Need ACID guarantees and the team has experience with it" \
        --tags "database,architecture" \
        -f "data-layer" 2>&1) || true

    # Check that spec quality appears in output
    assert_output_contains "spec quality printed" "$output" "Spec quality"

    # Check that spec_quality field exists in the JSONL
    local sq
    sq=$(jq -r '.spec_quality // empty' "$FIXTURE_DIR/journal/data/decisions.jsonl" 2>/dev/null | head -1) || true
    if [[ -n "$sq" && "$sq" != "null" ]]; then
        assert_pass "spec_quality stored in decision record ($sq)"
    else
        assert_fail "spec_quality not found in decision record"
    fi

    teardown
}

test_spec_quality_missing_fields() {
    echo "Test: Decision with minimal fields gets low spec quality"
    setup

    # Record a minimal decision (no rationale, no tags, no entities)
    "$FIXTURE_DIR/lore.sh" remember "Do something" 2>&1 || true

    local sq
    sq=$(jq -r '.spec_quality // 0' "$FIXTURE_DIR/journal/data/decisions.jsonl" 2>/dev/null | head -1) || true

    # Should have base score only (0.2)
    if awk "BEGIN { exit ($sq <= 0.3) ? 0 : 1 }" 2>/dev/null; then
        assert_pass "minimal decision gets low spec quality ($sq)"
    else
        assert_fail "minimal decision got unexpectedly high spec quality ($sq)"
    fi

    teardown
}

test_spec_quality_pattern() {
    echo "Test: Pattern spec quality is computed and stored"
    setup

    local output
    output=$("$FIXTURE_DIR/lore.sh" learn "Quote shell variables" \
        --context "Bash scripts with set -e" \
        --solution 'Always use "$var" not $var' \
        --problem "Word splitting causes subtle bugs" \
        --category bash 2>&1) || true

    assert_output_contains "pattern spec quality printed" "$output" "[Ss]pec quality"

    # Check patterns.yaml for spec_quality field
    if grep -q "spec_quality:" "$FIXTURE_DIR/patterns/data/patterns.yaml" 2>/dev/null; then
        assert_pass "spec_quality stored in pattern YAML"
    else
        assert_fail "spec_quality not found in pattern YAML"
    fi

    teardown
}

test_review_list_pending() {
    echo "Test: lore review finds pending decisions"
    setup

    # Record a decision (defaults to outcome: pending)
    "$FIXTURE_DIR/lore.sh" remember "Use Redis for caching" \
        --rationale "Fast in-memory store" \
        --tags "caching" 2>&1 >/dev/null || true

    local output
    output=$("$FIXTURE_DIR/lore.sh" review --days 0 2>&1) || true

    # Should recognize the pending decision (either listed or counted)
    assert_output_contains "review finds pending" "$output" "pending"

    teardown
}

test_review_resolve() {
    echo "Test: lore review --resolve updates outcome"
    setup

    # Record a decision
    "$FIXTURE_DIR/lore.sh" remember "Use JWT for auth" \
        --rationale "Stateless, scalable" \
        --tags "auth" 2>&1 >/dev/null || true

    # Get the decision ID
    local dec_id
    dec_id=$(jq -r '.id' "$FIXTURE_DIR/journal/data/decisions.jsonl" | head -1) || true

    # Resolve it
    "$FIXTURE_DIR/lore.sh" review --resolve "$dec_id" --outcome successful \
        --lesson "JWT worked well for our scale" 2>&1 >/dev/null || true

    # Check the latest version has updated outcome
    local outcome
    outcome=$(jq -r '.outcome' "$FIXTURE_DIR/journal/data/decisions.jsonl" | tail -1) || true

    if [[ "$outcome" == "successful" ]]; then
        assert_pass "decision resolved as successful"
    else
        assert_fail "decision outcome not updated (got: $outcome)"
    fi

    teardown
}

test_brief_decisions() {
    echo "Test: lore brief shows relevant decisions"
    setup

    # Record a decision about caching
    "$FIXTURE_DIR/lore.sh" remember "Use Redis for session caching" \
        --rationale "Need sub-ms reads" \
        --tags "caching,infrastructure" 2>&1 >/dev/null || true

    local output
    output=$("$FIXTURE_DIR/lore.sh" brief "caching" 2>&1) || true

    assert_output_contains "brief shows decision section" "$output" "Decisions"
    assert_output_contains "brief shows matching decision" "$output" "Redis"

    teardown
}

test_brief_no_match() {
    echo "Test: lore brief with no matches shows empty sections"
    setup

    local output
    output=$("$FIXTURE_DIR/lore.sh" brief "nonexistent-topic-xyz" 2>&1) || true

    assert_output_contains "brief shows topic header" "$output" "nonexistent-topic-xyz"
    assert_output_contains "brief shows decisions section" "$output" "Decisions (0)"

    teardown
}

test_brief_requires_topic() {
    echo "Test: lore brief without topic shows error"
    setup

    local output
    output=$("$FIXTURE_DIR/lore.sh" brief 2>&1) || true

    assert_output_contains "brief requires topic" "$output" "Topic required\|Usage"

    teardown
}

test_subtraction_stale_decisions() {
    echo "Test: subtraction_check flags stale pending decisions"
    setup

    # Inject a decision with a timestamp >14 days old
    local old_ts
    old_ts=$(date -j -v-20d -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u -d "20 days ago" +"%Y-%m-%dT%H:%M:%SZ")

    cat > "$FIXTURE_DIR/journal/data/decisions.jsonl" <<EOF
{"id":"dec-stale001","timestamp":"${old_ts}","decision":"Old pending decision","rationale":"test","outcome":"pending","type":"other","entities":[],"tags":[],"alternatives":[],"status":"active"}
EOF

    # Source and run subtraction_check
    source "$FIXTURE_DIR/lib/paths.sh"
    source "$FIXTURE_DIR/lib/subtraction.sh"
    local output
    output=$(subtraction_check 2>&1) || true

    assert_output_contains "flags stale decisions" "$output" "pending decision"

    teardown
}

test_subtraction_low_confidence() {
    echo "Test: subtraction_check flags low-confidence patterns"
    setup

    # Write a pattern with low confidence and 0 validations
    cat > "$FIXTURE_DIR/patterns/data/patterns.yaml" <<'YAML'
patterns:
  - id: "pat-000001-test"
    name: "Fragile pattern"
    context: "testing"
    problem: "unknown"
    solution: "unclear"
    category: "test"
    origin: "test"
    confidence: 0.1
    validations: 0
    created_at: "2025-01-01"

anti_patterns: []
YAML

    source "$FIXTURE_DIR/lib/paths.sh"
    source "$FIXTURE_DIR/lib/subtraction.sh"
    local output
    output=$(subtraction_check 2>&1) || true

    assert_output_contains "flags low-confidence patterns" "$output" "low-confidence"

    teardown
}

test_subtraction_clean() {
    echo "Test: subtraction_check produces no output when everything is healthy"
    setup

    source "$FIXTURE_DIR/lib/paths.sh"
    source "$FIXTURE_DIR/lib/subtraction.sh"
    local output
    output=$(subtraction_check 2>&1) || true

    if [[ -z "$output" ]]; then
        assert_pass "clean state produces no warnings"
    else
        assert_fail "clean state produced warnings: $output"
    fi

    teardown
}

# --- Run all tests ---

echo "=== Specification Layer Tests ==="
echo ""

test_spec_quality_decision
echo ""
test_spec_quality_missing_fields
echo ""
test_spec_quality_pattern
echo ""
test_review_list_pending
echo ""
test_review_resolve
echo ""
test_brief_decisions
echo ""
test_brief_no_match
echo ""
test_brief_requires_topic
echo ""
test_subtraction_stale_decisions
echo ""
test_subtraction_low_confidence
echo ""
test_subtraction_clean
echo ""

echo "=== Results: $PASS passed, $FAIL failed ==="

if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
