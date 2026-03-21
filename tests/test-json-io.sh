#!/usr/bin/env bash
# Integration tests for JSON I/O mode (lore capture --json)
#
# Tests structured input, structured output, dedup, type inference,
# rich content round-trip, and backward compatibility.

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
    mkdir -p "$TMPDIR/evidence/data" "$TMPDIR/evidence/lib"

    # Copy component scripts and libraries
    cp -R "$SCRIPT_DIR/../journal/"* "$TMPDIR/journal/"
    cp -R "$SCRIPT_DIR/../patterns/"* "$TMPDIR/patterns/"
    cp -R "$SCRIPT_DIR/../failures/"* "$TMPDIR/failures/"
    cp -R "$SCRIPT_DIR/../transfer/"* "$TMPDIR/transfer/"
    cp -R "$SCRIPT_DIR/../inbox/"* "$TMPDIR/inbox/"
    cp -R "$SCRIPT_DIR/../graph/"* "$TMPDIR/graph/"
    cp -R "$SCRIPT_DIR/../lib/"* "$TMPDIR/lib/"
    cp -R "$SCRIPT_DIR/../evidence/"* "$TMPDIR/evidence/"

    # Copy lore.sh into the temp dir so LORE_DIR self-derives correctly
    cp "$LORE" "$TMPDIR/lore.sh"
    chmod +x "$TMPDIR/lore.sh"

    # Initialize empty data files (JSONL = empty file, not JSON array)
    : > "$TMPDIR/journal/data/decisions.jsonl"
    cat > "$TMPDIR/patterns/data/patterns.yaml" <<'YAML'
# Pattern Learner Database
patterns: []

anti_patterns: []
YAML
    : > "$TMPDIR/failures/data/failures.jsonl"
    : > "$TMPDIR/inbox/data/signals.jsonl"
    : > "$TMPDIR/evidence/data/evidence.jsonl"

    # Reset paths.sh idempotency guard so it re-derives from new LORE_DIR
    unset _LORE_PATHS_LOADED
    export LORE_DIR="$TMPDIR"
    export LORE_DATA_DIR="$TMPDIR"
    export LORE_SEARCH_DB="$TMPDIR/search.db"
}

teardown() {
    [[ -n "$TMPDIR" && -d "$TMPDIR" ]] && rm -rf "$TMPDIR"
}

assert_json_field() {
    local desc="$1"
    local json="$2"
    local field="$3"
    local expected="$4"
    local actual
    actual=$(echo "$json" | jq -r ".$field" 2>/dev/null)
    if [[ "$actual" == "$expected" ]]; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc (expected $field=$expected, got $actual)"
        FAIL=$((FAIL + 1))
    fi
}

assert_json_truthy() {
    local desc="$1"
    local json="$2"
    local field="$3"
    local actual
    actual=$(echo "$json" | jq -r ".$field // empty" 2>/dev/null)
    if [[ -n "$actual" && "$actual" != "null" && "$actual" != "false" ]]; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc ($field is empty/null/false)"
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

test_decision_json() {
    echo "Test: Decision via --json"
    setup

    local output
    output=$(echo '{"decision":"Use JSON for agent I/O","rationale":"Shell escaping breaks rich text","tags":"architecture,testing"}' \
        | "$TMPDIR/lore.sh" capture --json 2>/dev/null)

    assert_json_field "ok is true" "$output" "ok" "true"
    assert_json_field "type is decision" "$output" "type" "decision"
    assert_json_truthy "id is present" "$output" "id"
    assert_json_truthy "timestamp is present" "$output" "timestamp"

    # Verify ID matches what's in the JSONL file
    local file_id
    file_id=$(tail -1 "$TMPDIR/journal/data/decisions.jsonl" | jq -r '.id')
    local json_id
    json_id=$(echo "$output" | jq -r '.id')
    if [[ "$file_id" == "$json_id" ]]; then
        echo "  PASS: returned ID matches stored ID"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: returned ID ($json_id) != stored ID ($file_id)"
        FAIL=$((FAIL + 1))
    fi

    assert_contains "decision text in file" "$TMPDIR/journal/data/decisions.jsonl" "Use JSON for agent I/O"

    teardown
}

test_pattern_json() {
    echo "Test: Pattern via --json"
    setup

    local output
    output=$(echo '{"name":"JSON piping for CLI","solution":"Pipe JSON on stdin, parse with jq","problem":"Shell escaping","category":"tooling"}' \
        | "$TMPDIR/lore.sh" capture --json 2>/dev/null)

    assert_json_field "ok is true" "$output" "ok" "true"
    assert_json_field "type is pattern" "$output" "type" "pattern"
    assert_json_truthy "id is present" "$output" "id"

    # Verify the pattern landed in the YAML file
    local pat_name
    pat_name=$(yq -r '.patterns[-1].name' "$TMPDIR/patterns/data/patterns.yaml" 2>/dev/null)
    if [[ "$pat_name" == "JSON piping for CLI" ]]; then
        echo "  PASS: pattern name in YAML"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: pattern name not found in YAML (got: $pat_name)"
        FAIL=$((FAIL + 1))
    fi

    teardown
}

test_failure_json() {
    echo "Test: Failure via --json"
    setup

    local output
    output=$(echo '{"error_type":"ToolError","message":"jq parse failed on malformed input","tool":"Bash"}' \
        | "$TMPDIR/lore.sh" capture --json 2>/dev/null)

    assert_json_field "ok is true" "$output" "ok" "true"
    assert_json_field "type is failure" "$output" "type" "failure"
    assert_json_truthy "id is present" "$output" "id"

    # Verify ID matches stored record
    local file_id
    file_id=$(tail -1 "$TMPDIR/failures/data/failures.jsonl" | jq -r '.id')
    local json_id
    json_id=$(echo "$output" | jq -r '.id')
    if [[ "$file_id" == "$json_id" ]]; then
        echo "  PASS: returned ID matches stored ID"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: returned ID ($json_id) != stored ID ($file_id)"
        FAIL=$((FAIL + 1))
    fi

    teardown
}

test_signal_json() {
    echo "Test: Signal via --json"
    setup

    local output
    output=$(echo '{"content":"Users report intermittent timeouts","source":"support-channel","tags":"observability"}' \
        | "$TMPDIR/lore.sh" capture --json 2>/dev/null)

    assert_json_field "ok is true" "$output" "ok" "true"
    assert_json_field "type is signal" "$output" "type" "signal"
    assert_json_truthy "id is present" "$output" "id"

    # Verify content in signals file
    assert_contains "signal content in file" "$TMPDIR/inbox/data/signals.jsonl" "intermittent timeouts"

    teardown
}

test_rich_content_roundtrip() {
    echo "Test: Rich content survives round-trip"
    setup

    # Content with quotes, newlines, backticks, and markdown
    local payload
    payload=$(jq -c -n '{
        decision: "Handle \"edge cases\" in `parser.sh`\nIncluding multi-line\ncontent with *markdown*",
        rationale: "Content from narrations contains arbitrary prose"
    }')

    local output
    output=$(echo "$payload" | "$TMPDIR/lore.sh" capture --json 2>/dev/null)

    assert_json_field "ok is true" "$output" "ok" "true"

    # Verify the stored content matches (check key substring)
    local stored
    stored=$(tail -1 "$TMPDIR/journal/data/decisions.jsonl" | jq -r '.decision')
    if echo "$stored" | grep -q 'edge cases'; then
        echo "  PASS: quotes survived round-trip"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: quotes lost in round-trip (stored: $stored)"
        FAIL=$((FAIL + 1))
    fi

    if echo "$stored" | grep -q 'parser.sh'; then
        echo "  PASS: backticks survived round-trip"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: backticks lost in round-trip"
        FAIL=$((FAIL + 1))
    fi

    teardown
}

test_dedup_returns_error() {
    echo "Test: Dedup returns structured error"
    setup

    # Write first entry
    echo '{"decision":"Dedup test entry","rationale":"First write"}' \
        | "$TMPDIR/lore.sh" capture --json >/dev/null 2>&1

    # Write duplicate — should fail with existing_id
    local output
    output=$(echo '{"decision":"Dedup test entry","rationale":"Duplicate write"}' \
        | "$TMPDIR/lore.sh" capture --json 2>/dev/null) || true

    assert_json_field "ok is false" "$output" "ok" "false"
    assert_json_truthy "existing_id present" "$output" "existing_id"

    teardown
}

test_type_inference_from_keys() {
    echo "Test: Type inferred from JSON keys"
    setup

    # No explicit type — should infer "decision" from "rationale" key
    local output
    output=$(echo '{"decision":"Inferred decision","rationale":"Has rationale key"}' \
        | "$TMPDIR/lore.sh" capture --json 2>/dev/null)
    assert_json_field "infers decision" "$output" "type" "decision"

    teardown
    setup

    # Should infer "pattern" from "solution" key
    output=$(echo '{"name":"Inferred pattern","solution":"Has solution key"}' \
        | "$TMPDIR/lore.sh" capture --json 2>/dev/null)
    assert_json_field "infers pattern" "$output" "type" "pattern"

    teardown
    setup

    # Should infer "failure" from "error_type" key
    output=$(echo '{"error_type":"ToolError","message":"Inferred failure"}' \
        | "$TMPDIR/lore.sh" capture --json 2>/dev/null)
    assert_json_field "infers failure" "$output" "type" "failure"

    teardown
}

test_explicit_type_overrides() {
    echo "Test: Explicit type field overrides key inference"
    setup

    # Has "solution" key (would infer pattern) but explicit type says decision
    local output
    output=$(echo '{"type":"decision","decision":"Override test","solution":"This key would infer pattern"}' \
        | "$TMPDIR/lore.sh" capture --json 2>/dev/null)
    assert_json_field "explicit type wins" "$output" "type" "decision"

    assert_contains "stored as decision" "$TMPDIR/journal/data/decisions.jsonl" "Override test"

    teardown
}

test_json_out_with_flags() {
    echo "Test: --json-out with traditional flag input"
    setup

    local output
    output=$("$TMPDIR/lore.sh" capture "Flag-based with JSON output" --rationale "Testing hybrid mode" --force --json-out 2>/dev/null)

    assert_json_field "ok is true" "$output" "ok" "true"
    assert_json_field "type is decision" "$output" "type" "decision"
    assert_json_truthy "id is present" "$output" "id"

    assert_contains "decision text in file" "$TMPDIR/journal/data/decisions.jsonl" "Flag-based with JSON output"

    teardown
}

test_json_in_without_json_out() {
    echo "Test: --json-in without --json-out preserves human output"
    setup

    local output
    output=$(echo '{"decision":"JSON input human output","rationale":"Testing json-in only"}' \
        | "$TMPDIR/lore.sh" capture --json-in --force 2>/dev/null)

    # Should have human-readable output (color codes or text), not JSON
    if echo "$output" | jq empty 2>/dev/null; then
        echo "  FAIL: got JSON output without --json-out"
        FAIL=$((FAIL + 1))
    else
        echo "  PASS: human-readable output preserved"
        PASS=$((PASS + 1))
    fi

    # But the entry should still be written
    assert_contains "decision written" "$TMPDIR/journal/data/decisions.jsonl" "JSON input human output"

    teardown
}

test_regression_flag_capture() {
    echo "Test: Regression — flag-based capture unchanged"
    setup

    # Decision via flags (no JSON)
    assert_ok "flag-based decision" \
        "$TMPDIR/lore.sh" capture "Regression test decision" --rationale "Flag mode" --force
    assert_contains "decision recorded" "$TMPDIR/journal/data/decisions.jsonl" "Regression test decision"

    # Pattern via flags
    assert_ok "flag-based pattern" \
        "$TMPDIR/lore.sh" capture "Regression test pattern" --solution "Flag solution" --force
    local pat_name
    pat_name=$(yq -r '.patterns[-1].name' "$TMPDIR/patterns/data/patterns.yaml" 2>/dev/null)
    if [[ "$pat_name" == "Regression test pattern" ]]; then
        echo "  PASS: pattern recorded via flags"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: pattern not found (got: $pat_name)"
        FAIL=$((FAIL + 1))
    fi

    # Failure via flags (no --force: failures have no dedup)
    assert_ok "flag-based failure" \
        "$TMPDIR/lore.sh" capture "Regression failure" --error-type ToolError
    assert_contains "failure recorded" "$TMPDIR/failures/data/failures.jsonl" "Regression failure"

    # Signal via flags
    assert_ok "flag-based signal" \
        "$TMPDIR/lore.sh" capture "Regression signal" --signal
    assert_contains "signal recorded" "$TMPDIR/inbox/data/signals.jsonl" "Regression signal"

    teardown
}

# --- Run all tests ---

echo "=== JSON I/O Mode Tests ==="
echo ""

test_decision_json
test_pattern_json
test_failure_json
test_signal_json
test_rich_content_roundtrip
test_dedup_returns_error
test_type_inference_from_keys
test_explicit_type_overrides
test_json_out_with_flags
test_json_in_without_json_out
test_regression_flag_capture

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="

if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
