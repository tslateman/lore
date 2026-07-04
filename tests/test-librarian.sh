#!/usr/bin/env bash
# Tests for the librarian curation loop (lib/librarian.sh)
#
# Covers manifest generation against a temp LORE_DATA_DIR fixture and
# dry-run/apply action handling with a fake `claude` PATH shim.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LORE="$SCRIPT_DIR/../lore.sh"

PASS=0
FAIL=0
TMPDIR=""

setup() {
    TMPDIR=$(mktemp -d)

    mkdir -p "$TMPDIR/inbox/data" "$TMPDIR/journal/data" \
        "$TMPDIR/failures/data" "$TMPDIR/graph/data" \
        "$TMPDIR/patterns/data" "$TMPDIR/transfer/data" \
        "$TMPDIR/evidence/data" "$TMPDIR/intent/data" "$TMPDIR/bin"

    # Raw observation (legacy obs- file) and raw signal
    cat > "$TMPDIR/inbox/data/observations.jsonl" <<'JSONL'
{"id":"obs-aaaa0001","timestamp":"2026-01-01T00:00:00Z","source":"test","content":"Users retry after timeout","status":"raw","tags":["ux"]}
{"id":"obs-aaaa0002","timestamp":"2026-01-02T00:00:00Z","source":"test","content":"Already handled","status":"raw","tags":[]}
{"id":"obs-aaaa0002","timestamp":"2026-01-02T00:00:00Z","source":"test","content":"Already handled","status":"discarded","tags":[],"discard_reason":"dup","discarded_at":"2026-01-03T00:00:00Z"}
JSONL
    cat > "$TMPDIR/inbox/data/signals.jsonl" <<'JSONL'
{"id":"sig-bbbb0001","timestamp":"2026-02-01T00:00:00Z","source":"manual","content":"Prefer jq over sed for JSON","status":"raw","tags":["tooling"]}
JSONL

    # Stale pending decision (old) + fresh pending decision (recent)
    local now
    now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    cat > "$TMPDIR/journal/data/decisions.jsonl" <<JSONL
{"id":"dec-cccc0001","timestamp":"2026-01-01T00:00:00Z","decision":"Build the widget","rationale":"Needed","outcome":"pending","status":"active","type":"implementation","tags":[]}
{"id":"dec-cccc0002","timestamp":"${now}","decision":"Fresh decision","rationale":"New","outcome":"pending","status":"active","type":"implementation","tags":[]}
{"id":"dec-cccc0003","timestamp":"2026-01-01T00:00:00Z","decision":"Resolved already","rationale":"Done","outcome":"successful","status":"active","type":"implementation","tags":[]}
JSONL

    # One untyped failure, one typed
    cat > "$TMPDIR/failures/data/failures.jsonl" <<'JSONL'
{"id":"fail-dddd0001","timestamp":"2026-01-05T00:00:00Z","error_type":"unknown","error_message":"boom","tool":"widget"}
{"id":"fail-dddd0002","timestamp":"2026-01-06T00:00:00Z","error_type":"Timeout","error_message":"slow"}
JSONL

    # Graph: one orphan, one connected pair
    cat > "$TMPDIR/graph/data/graph.json" <<'JSON'
{
  "nodes": {
    "decision-orphan1": {"type": "decision", "name": "dec-cccc0001", "data": {"decision": "Build the widget"}, "created_at": "2026-01-01T00:00:00Z"},
    "pattern-node1": {"type": "pattern", "name": "pat-1111", "data": {}, "created_at": "2026-01-01T00:00:00Z"},
    "pattern-node2": {"type": "pattern", "name": "pat-2222", "data": {}, "created_at": "2026-01-01T00:00:00Z"}
  },
  "edges": [
    {"from": "pattern-node1", "to": "pattern-node2", "relation": "relates_to", "weight": 1.0, "bidirectional": false, "created_at": "2026-01-01T00:00:00Z"}
  ]
}
JSON

    cat > "$TMPDIR/patterns/data/patterns.yaml" <<'YAML'
patterns: []
anti_patterns: []
YAML
    : > "$TMPDIR/evidence/data/evidence.jsonl"

    unset _LORE_PATHS_LOADED
    export LORE_DATA_DIR="$TMPDIR"
    export LORE_SEARCH_DB="$TMPDIR/search.db"
}

teardown() {
    [[ -n "$TMPDIR" && -d "$TMPDIR" ]] && rm -rf "$TMPDIR"
}

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc (expected '$expected', got '$actual')"
        FAIL=$((FAIL + 1))
    fi
}

assert_contains() {
    local desc="$1" haystack="$2" needle="$3"
    if echo "$haystack" | grep -qF "$needle"; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc (missing '$needle')"
        FAIL=$((FAIL + 1))
    fi
}

# Fake claude shim: ignores input, prints canned actions including one
# invalid-id action that must be skipped.
install_claude_shim() {
    cat > "$TMPDIR/bin/claude" <<'SHIM'
#!/usr/bin/env bash
cat > /dev/null
cat <<'ACTIONS'
[
  {"action":"discard_observation","id":"obs-aaaa0001","reason":"ephemeral note"},
  {"action":"promote_observation","id":"sig-bbbb0001","target_type":"decision","text":"Prefer jq over sed for JSON","rationale":"Structured parsing beats regex","reason":"durable tooling decision"},
  {"action":"set_failure_type","id":"fail-dddd0001","error_type":"ToolError","reason":"widget tool crashed"},
  {"action":"resolve_decision","id":"dec-cccc0001","outcome":"successful","lesson":"Widget shipped","reason":"widget exists"},
  {"action":"add_edge","from":"decision-orphan1","to":"pattern-node1","relation":"relates_to","reason":"widget uses pattern"},
  {"action":"discard_observation","id":"obs-nonexistent","reason":"bogus id"}
]
ACTIONS
SHIM
    chmod +x "$TMPDIR/bin/claude"
    export PATH="$TMPDIR/bin:$PATH"
}

test_manifest() {
    echo "Test: manifest generation"

    local manifest
    manifest=$("$LORE" librarian manifest --days 30 --limit 25)

    assert_eq "inbox lists 2 raw entries (obs + sig, discarded excluded)" \
        "2" "$(echo "$manifest" | jq '.inbox.total')"
    assert_contains "inbox includes legacy observation" \
        "$(echo "$manifest" | jq -r '.inbox.items[].id')" "obs-aaaa0001"
    assert_contains "inbox includes signal" \
        "$(echo "$manifest" | jq -r '.inbox.items[].id')" "sig-bbbb0001"

    assert_eq "stale_decisions lists only the old pending decision" \
        "1" "$(echo "$manifest" | jq '.stale_decisions.total')"
    assert_eq "stale decision id" \
        "dec-cccc0001" "$(echo "$manifest" | jq -r '.stale_decisions.items[0].id')"

    assert_eq "untyped_failures lists only the unknown-typed failure" \
        "1" "$(echo "$manifest" | jq '.untyped_failures.total')"
    assert_eq "untyped failure id" \
        "fail-dddd0001" "$(echo "$manifest" | jq -r '.untyped_failures.items[0].id')"

    assert_eq "orphans lists the edgeless node" \
        "1" "$(echo "$manifest" | jq '.orphans.total')"
    assert_eq "orphan id" \
        "decision-orphan1" "$(echo "$manifest" | jq -r '.orphans.items[0].id')"
    assert_eq "orphan candidates key present (empty without index)" \
        "0" "$(echo "$manifest" | jq '.orphans.items[0].candidates | length')"

    local limited
    limited=$("$LORE" librarian manifest --limit 1)
    assert_eq "limit caps inbox items" \
        "1" "$(echo "$limited" | jq '.inbox.included')"
    assert_eq "limit preserves totals" \
        "2" "$(echo "$limited" | jq '.inbox.total')"
}

test_dry_run() {
    echo "Test: run (dry-run) proposes without writing"

    local output
    output=$("$LORE" librarian run 2>/dev/null)

    assert_contains "proposes discard" "$output" "would discard obs-aaaa0001"
    assert_contains "proposes resolve" "$output" "would resolve dec-cccc0001 -> successful"
    assert_contains "proposes retype" "$output" "would retype fail-dddd0001 -> ToolError"
    assert_contains "proposes edge" "$output" "would connect decision-orphan1 -> pattern-node1"
    assert_contains "skips invalid id" "$output" "skip discard_observation obs-nonexistent"

    assert_eq "observation still raw after dry-run" "raw" \
        "$(jq -rs 'map(select(.id == "obs-aaaa0001")) | last | .status' "$TMPDIR/inbox/data/observations.jsonl")"
    assert_eq "decision still pending after dry-run" "pending" \
        "$(jq -rs 'map(select(.id == "dec-cccc0001")) | last | .outcome' "$TMPDIR/journal/data/decisions.jsonl")"
    assert_eq "no new edges after dry-run" "1" \
        "$(jq '.edges | length' "$TMPDIR/graph/data/graph.json")"
}

test_apply() {
    echo "Test: run --apply executes valid actions and skips invalid"

    local output
    output=$("$LORE" librarian run --apply 2>/dev/null)

    assert_contains "reports discard" "$output" "discarded obs-aaaa0001"
    assert_contains "reports skip of invalid id" "$output" "skip discard_observation obs-nonexistent"

    assert_eq "observation discarded (latest version)" "discarded" \
        "$(jq -rs 'map(select(.id == "obs-aaaa0001")) | last | .status' "$TMPDIR/inbox/data/observations.jsonl")"
    assert_eq "signal promoted (latest version)" "promoted" \
        "$(jq -rs 'map(select(.id == "sig-bbbb0001")) | last | .status' "$TMPDIR/inbox/data/signals.jsonl")"
    assert_contains "promotion created a decision" \
        "$(jq -rs 'map(.decision) | join("\n")' "$TMPDIR/journal/data/decisions.jsonl")" \
        "Prefer jq over sed for JSON"
    assert_eq "failure retyped (latest version)" "ToolError" \
        "$(jq -rs 'map(select(.id == "fail-dddd0001")) | last | .error_type' "$TMPDIR/failures/data/failures.jsonl")"
    assert_eq "decision resolved (latest version)" "successful" \
        "$(jq -rs 'map(select(.id == "dec-cccc0001")) | last | .outcome' "$TMPDIR/journal/data/decisions.jsonl")"
    assert_eq "edge added" "2" \
        "$(jq '.edges | length' "$TMPDIR/graph/data/graph.json")"

    # Append-only: originals still present as earlier versions
    assert_eq "observation update appended, not edited" "2" \
        "$(grep -c 'obs-aaaa0001' "$TMPDIR/inbox/data/observations.jsonl")"
    assert_eq "failure update appended, not edited" "2" \
        "$(grep -c 'fail-dddd0001' "$TMPDIR/failures/data/failures.jsonl")"

    # Applied items drain from the next manifest
    local manifest
    manifest=$("$LORE" librarian manifest)
    assert_eq "inbox drained" "0" "$(echo "$manifest" | jq '.inbox.total')"
    assert_eq "untyped failures drained" "0" "$(echo "$manifest" | jq '.untyped_failures.total')"
    assert_eq "stale decisions drained" "0" "$(echo "$manifest" | jq '.stale_decisions.total')"
    # Background graph syncs may add new nodes; assert the target orphan
    # itself is no longer edgeless rather than a global zero.
    local still_orphan
    still_orphan=$(echo "$manifest" | jq '[.orphans.items[] | select(.id == "decision-orphan1")] | length')
    assert_eq "orphan wired" "0" "$still_orphan"
}

test_claude_failure() {
    echo "Test: run falls back to manifest when claude fails"

    cat > "$TMPDIR/bin/claude" <<'SHIM'
#!/usr/bin/env bash
cat > /dev/null
exit 1
SHIM
    chmod +x "$TMPDIR/bin/claude"
    export PATH="$TMPDIR/bin:$PATH"

    local output
    output=$("$LORE" librarian run 2>/dev/null) || true
    assert_contains "falls back to manifest JSON" "$output" '"generated_at"'
}

main() {
    trap teardown EXIT

    setup
    test_manifest
    test_claude_failure
    install_claude_shim
    test_dry_run
    test_apply

    echo ""
    echo "Results: $PASS passed, $FAIL failed"
    [[ "$FAIL" -eq 0 ]]
}

main "$@"
