#!/usr/bin/env bash
# Tests for lib/rerank.sh (model-judged reranking)
#
# Uses a PATH shim: a fake `claude` executable returns canned output so
# no real model call happens. Verifies reordering, hallucinated-id
# filtering, omission handling, timeout and missing-CLI fallback, and
# the LORE_RERANK=0 kill switch.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RERANK_LIB="$SCRIPT_DIR/../lib/rerank.sh"

# --- Test harness ---

PASS=0
FAIL=0
TMPDIR=""
SHIM_DIR=""
ORIG_PATH="$PATH"

setup() {
    TMPDIR=$(mktemp -d)
    SHIM_DIR="$TMPDIR/bin"
    mkdir -p "$SHIM_DIR"
    unset LORE_RERANK LORE_RERANK_FILTER LORE_RERANK_TIMEOUT 2>/dev/null || true
}

teardown() {
    PATH="$ORIG_PATH"
    [[ -n "$TMPDIR" && -d "$TMPDIR" ]] && rm -rf "$TMPDIR"
    unset LORE_RERANK LORE_RERANK_FILTER LORE_RERANK_TIMEOUT 2>/dev/null || true
}

# Install a fake claude that consumes stdin and prints canned output
install_fake_claude() {
    local canned="$1"
    cat > "$SHIM_DIR/claude" <<EOF
#!/usr/bin/env bash
cat >/dev/null
printf '%s\n' '$canned'
EOF
    chmod +x "$SHIM_DIR/claude"
    PATH="$SHIM_DIR:$ORIG_PATH"
}

assert_equals() {
    local desc="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc"
        echo "    expected: $(printf '%s' "$expected" | tr '\n' ';')"
        echo "    actual:   $(printf '%s' "$actual" | tr '\n' ';')"
        FAIL=$((FAIL + 1))
    fi
}

# Candidate fixture: three tab-separated rows (type, id, content, project, date, score)
candidates() {
    printf 'decision\tdec-1\tUse JSONL storage\tlore\t2026-01-01\t3.2\n'
    printf 'pattern\tpat-2\tSafe bash arithmetic\tlore\t2026-02-01\t2.1\n'
    printf 'decision\tdec-3\tCrucible retry policy\tcrucible\t2026-03-01\t1.4\n'
}

ids_of() {
    awk -F'\t' '{print $2}'
}

# --- Tests ---

test_reorder() {
    echo "Test: model ordering reorders results, omitted ids appended"
    setup
    install_fake_claude '["dec-3","dec-1"]'
    source "$RERANK_LIB"

    local out
    out=$(candidates | rerank_results "retry" "ctx" | ids_of)
    assert_equals "dec-3 first, dec-1 second, omitted pat-2 appended" \
        "$(printf 'dec-3\ndec-1\npat-2')" "$out"

    teardown
}

test_filter_mode() {
    echo "Test: LORE_RERANK_FILTER=1 drops omitted candidates"
    setup
    install_fake_claude '["dec-3","dec-1"]'
    source "$RERANK_LIB"

    local out
    out=$(candidates | LORE_RERANK_FILTER=1 rerank_results "retry" "" | ids_of)
    assert_equals "only ranked ids survive" "$(printf 'dec-3\ndec-1')" "$out"

    teardown
}

test_hallucinated_ids() {
    echo "Test: hallucinated ids are ignored, valid ones applied"
    setup
    install_fake_claude '["dec-999","pat-2","bogus"]'
    source "$RERANK_LIB"

    local out
    out=$(candidates | rerank_results "bash" "" | ids_of)
    assert_equals "valid pat-2 first, rest in original order" \
        "$(printf 'pat-2\ndec-1\ndec-3')" "$out"

    teardown
}

test_all_hallucinated() {
    echo "Test: all-hallucinated id set falls back to original order"
    setup
    install_fake_claude '["nope-1","nope-2"]'
    source "$RERANK_LIB"

    local out
    out=$(candidates | rerank_results "query" "" | ids_of)
    assert_equals "original order preserved" \
        "$(printf 'dec-1\npat-2\ndec-3')" "$out"

    teardown
}

test_unparseable_output() {
    echo "Test: unparseable model output falls back to original order"
    setup
    install_fake_claude 'I cannot rank these, sorry.'
    source "$RERANK_LIB"

    local out
    out=$(candidates | rerank_results "query" "" | ids_of)
    assert_equals "original order preserved" \
        "$(printf 'dec-1\npat-2\ndec-3')" "$out"

    teardown
}

test_code_fenced_output() {
    echo "Test: code-fenced JSON array is still parsed"
    setup
    install_fake_claude '```json ["pat-2","dec-3","dec-1"] ```'
    source "$RERANK_LIB"

    local out
    out=$(candidates | rerank_results "query" "" | ids_of)
    assert_equals "fenced array applied" \
        "$(printf 'pat-2\ndec-3\ndec-1')" "$out"

    teardown
}

test_missing_cli() {
    echo "Test: missing claude CLI passes input through unchanged"
    setup
    # PATH without claude (shim dir is empty)
    PATH="$SHIM_DIR:/usr/bin:/bin"
    source "$RERANK_LIB"

    local out
    out=$(candidates | rerank_results "query" "" | ids_of)
    assert_equals "passthrough without claude" \
        "$(printf 'dec-1\npat-2\ndec-3')" "$out"

    teardown
}

test_timeout() {
    echo "Test: slow model call times out and passes input through"
    setup
    cat > "$SHIM_DIR/claude" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
sleep 5
printf '%s\n' '["dec-3"]'
EOF
    chmod +x "$SHIM_DIR/claude"
    PATH="$SHIM_DIR:$ORIG_PATH"
    source "$RERANK_LIB"

    local out
    out=$(candidates | LORE_RERANK_TIMEOUT=1 rerank_results "query" "" | ids_of)
    assert_equals "passthrough after timeout" \
        "$(printf 'dec-1\npat-2\ndec-3')" "$out"

    teardown
}

test_kill_switch() {
    echo "Test: LORE_RERANK=0 disables reranking"
    setup
    install_fake_claude '["dec-3","pat-2","dec-1"]'
    source "$RERANK_LIB"

    local out
    out=$(candidates | LORE_RERANK=0 rerank_results "query" "" | ids_of)
    assert_equals "kill switch preserves original order" \
        "$(printf 'dec-1\npat-2\ndec-3')" "$out"

    teardown
}

test_pipe_separator() {
    echo "Test: pipe-separated rows (search-index.sh shape) rerank correctly"
    setup
    install_fake_claude '["pat-2"]'
    source "$RERANK_LIB"

    local out
    out=$(printf 'decision|dec-1|Use JSONL|lore|2026-01-01|3.2\npattern|pat-2|Safe bash|lore|2026-02-01|2.1\n' \
        | rerank_results "bash" "" '|' 2 | awk -F'|' '{print $2}')
    assert_equals "pat-2 promoted, dec-1 appended" \
        "$(printf 'pat-2\ndec-1')" "$out"

    teardown
}

test_empty_input() {
    echo "Test: empty input yields empty output, exit 0"
    setup
    install_fake_claude '["dec-1"]'
    source "$RERANK_LIB"

    local out
    out=$(printf '' | rerank_results "query" "")
    assert_equals "empty in, empty out" "" "$out"

    teardown
}

test_search_flag_parses() {
    echo "Test: lore search --rerank flag is accepted (no unknown-option error)"
    setup

    local tmp_lore="$TMPDIR/lore-env"
    mkdir -p "$tmp_lore"
    local output
    output=$(cd "$tmp_lore" && LORE_DATA_DIR="$tmp_lore" \
        "$SCRIPT_DIR/../lore.sh" search "nothing-matches-this" --rerank 2>&1) || true
    if echo "$output" | grep -q "Unknown option"; then
        echo "  FAIL: --rerank rejected by cmd_search"
        FAIL=$((FAIL + 1))
    else
        echo "  PASS: --rerank accepted by cmd_search"
        PASS=$((PASS + 1))
    fi

    teardown
}

# --- Runner ---

echo "=== Lore Rerank Tests ==="
echo ""

test_reorder
echo ""
test_filter_mode
echo ""
test_hallucinated_ids
echo ""
test_all_hallucinated
echo ""
test_unparseable_output
echo ""
test_code_fenced_output
echo ""
test_missing_cli
echo ""
test_timeout
echo ""
test_kill_switch
echo ""
test_pipe_separator
echo ""
test_empty_input
echo ""
test_search_flag_parses
echo ""

echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
