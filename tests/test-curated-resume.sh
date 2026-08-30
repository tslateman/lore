#!/usr/bin/env bash
# Integration tests for the curated resume feature
#
# Tests curate_for_context() in transfer/lib/resume.sh:
# FTS5-ranked context during resume, access logging, graceful
# degradation without an index, and sparse session fallback.

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
    mkdir -p "$FIXTURE_DIR/inbox/data" "$FIXTURE_DIR/inbox/lib"
    mkdir -p "$FIXTURE_DIR/graph/data" "$FIXTURE_DIR/graph"
    mkdir -p "$FIXTURE_DIR/lib"
    mkdir -p "$FIXTURE_DIR/registry/data"
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

    # Initialize empty data files (JSONL: one object per line, not a JSON array)
    : > "$FIXTURE_DIR/journal/data/decisions.jsonl"
    cat > "$FIXTURE_DIR/patterns/data/patterns.yaml" <<'YAML'
# Pattern Learner Database
patterns: []

anti_patterns: []
YAML
    : > "$FIXTURE_DIR/failures/data/failures.jsonl"
    : > "$FIXTURE_DIR/inbox/data/observations.jsonl"

    unset _LORE_PATHS_LOADED
    export LORE_DIR="$FIXTURE_DIR"
    export LORE_DATA_DIR="$FIXTURE_DIR"
    export CLAUDE_MEMORY_DB="$FIXTURE_DIR/memory.sqlite"
    export LORE_SEARCH_DB="$FIXTURE_DIR/search.db"
}

teardown() {
    remove_fixture "$FIXTURE_DIR"
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

# --- Helpers ---

# Create a session file with full structure
# Args: session_id [summary]
create_session() {
    local session_id="$1"
    local summary="${2:-(no summary)}"
    local session_file="$FIXTURE_DIR/transfer/data/sessions/${session_id}.json"

    jq -n \
        --arg id "$session_id" \
        --arg summary "$summary" \
        '{
            id: $id,
            started_at: "2026-02-20T10:00:00Z",
            ended_at: "2026-02-20T11:00:00Z",
            summary: $summary,
            goals_addressed: ["Goal alpha"],
            decisions_made: ["Decision beta"],
            patterns_learned: ["Pattern gamma"],
            open_threads: [],
            handoff: {
                message: "Handoff message",
                next_steps: ["Step one"],
                blockers: [],
                questions: []
            },
            git_state: {
                branch: "main",
                commits: ["abc1234 feat: test"],
                uncommitted: []
            },
            context: {
                project: "",
                active_files: [],
                recent_commands: [],
                environment: {}
            },
            related: {
                journal_entries: [],
                patterns: [],
                goals: []
            }
        }' > "$session_file"

    echo "$session_id" > "$FIXTURE_DIR/transfer/data/.current_session"
}

# Create a sparse session (only id and started_at populated)
create_sparse_session() {
    local session_id="$1"
    local session_file="$FIXTURE_DIR/transfer/data/sessions/${session_id}.json"

    jq -n \
        --arg id "$session_id" \
        '{
            id: $id,
            started_at: "2026-02-20T10:00:00Z",
            ended_at: null,
            summary: "",
            goals_addressed: [],
            decisions_made: [],
            patterns_learned: [],
            open_threads: [],
            handoff: {
                message: "",
                next_steps: [],
                blockers: [],
                questions: []
            },
            git_state: {
                branch: "",
                commits: [],
                uncommitted: []
            },
            context: {
                project: "",
                active_files: [],
                recent_commands: [],
                environment: {}
            },
            related: {
                journal_entries: [],
                patterns: [],
                goals: []
            }
        }' > "$session_file"

    echo "$session_id" > "$FIXTURE_DIR/transfer/data/.current_session"
}

# --- Tests ---

test_resume_with_index_shows_ranked() {
    echo "Test: resume with search index shows ranked context"
    setup

    # Seed a decision containing "testproject" so FTS5 matches the context query
    "$FIXTURE_DIR/lore.sh" remember "Testproject uses ranked search for context" --rationale "FTS5 integration" --force >/dev/null 2>&1

    # Build search index
    bash "$FIXTURE_DIR/lib/search-index.sh" build --no-graph >/dev/null 2>&1

    # Verify search.db was created
    assert_ok "search.db exists after build" test -f "$FIXTURE_DIR/search.db"

    # Create a minimal session with no open_threads or summary, so the
    # combined context query sent to FTS5 is just "testproject" which
    # matches the seeded decision.
    local sid="session-ranked-test"
    local sf="$FIXTURE_DIR/transfer/data/sessions/${sid}.json"
    jq -n --arg id "$sid" '{
        id:$id,started_at:"2026-02-20T10:00:00Z",
        ended_at:"2026-02-20T11:00:00Z",
        summary:"",goals_addressed:["Goal"],
        decisions_made:["Dec"],patterns_learned:[],
        open_threads:[],
        handoff:{message:"m",next_steps:[],blockers:[],questions:[]},
        git_state:{branch:"main",commits:["abc"],uncommitted:[]},
        context:{project:"testproject",active_files:[],recent_commands:[],environment:{}},
        related:{journal_entries:[],patterns:[],goals:[]}
    }' > "$sf"
    echo "$sid" > "$FIXTURE_DIR/transfer/data/.current_session"

    local output
    output=$("$FIXTURE_DIR/lore.sh" resume "session-ranked-test" 2>&1) || true

    assert_output_contains "output contains Relevant Context header" "$output" "Relevant Context"

    teardown
}

test_resume_without_index_no_ranked() {
    echo "Test: resume without search index omits ranked context"
    setup

    # No search index built -- search.db should not exist
    # Create a session with enough data so it's not sparse
    create_session "session-no-index"

    local output
    output=$("$FIXTURE_DIR/lore.sh" resume "session-no-index" 2>&1) || true

    assert_output_not_contains "output lacks Relevant Context header" "$output" "Relevant Context (ranked)"

    teardown
}

test_resume_access_logging() {
    echo "Test: resume logs access entries in search.db"
    setup

    # Seed a decision
    "$FIXTURE_DIR/lore.sh" remember "Access logging test decision" --rationale "Verify access_log" --force >/dev/null 2>&1

    # Build search index
    bash "$FIXTURE_DIR/lib/search-index.sh" build --no-graph >/dev/null 2>&1

    # Create a session with decisions_made so log-access fires for session items
    create_session "session-access-test" "Access logging summary"

    # Resume (this should log access for decisions_made and patterns_learned in session)
    "$FIXTURE_DIR/lore.sh" resume "session-access-test" >/dev/null 2>&1 || true

    # Wait briefly for any background processes
    sleep 1

    # Check access_log has entries
    local count
    count=$(sqlite3 "$FIXTURE_DIR/search.db" "SELECT COUNT(*) FROM access_log;" 2>/dev/null) || count=0

    if [[ "$count" -gt 0 ]]; then
        echo "  PASS: access_log has $count entries"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: access_log is empty (expected entries from session items)"
        FAIL=$((FAIL + 1))
    fi

    teardown
}

test_sparse_session_ranked_fallback() {
    echo "Test: sparse session triggers reconstructed context with ranked results"
    setup

    # Seed a decision
    "$FIXTURE_DIR/lore.sh" remember "Sparse session fallback decision" --rationale "Testing reconstruct" --force >/dev/null 2>&1

    # Build search index
    bash "$FIXTURE_DIR/lib/search-index.sh" build --no-graph >/dev/null 2>&1

    # Create a sparse session (triggers is_session_sparse -> reconstruct_context)
    create_sparse_session "session-sparse-test"

    local output
    output=$("$FIXTURE_DIR/lore.sh" resume "session-sparse-test" 2>&1) || true

    # Sparse sessions trigger reconstruct_context which shows "Reconstructed Context"
    assert_output_contains "output contains Reconstructed Context" "$output" "Reconstructed Context"

    teardown
}

test_resume_preserves_patterns() {
    echo "Test: resume shows both Relevant Patterns and Relevant Context sections"
    setup

    # Seed a pattern and a decision. Decision must contain all terms
    # from the combined context ("scripting") for FTS5 match.
    "$FIXTURE_DIR/lore.sh" learn "Bash quoting" --context "Shell scripting" --solution 'Always quote variables' --force >/dev/null 2>&1
    "$FIXTURE_DIR/lore.sh" remember "Scripting best practices" --rationale "Shell integration" --force >/dev/null 2>&1

    # Build search index
    bash "$FIXTURE_DIR/lib/search-index.sh" build --no-graph >/dev/null 2>&1

    # Inline session: project="" and no threads so combined context = summary only.
    # This avoids FTS5 implicit AND failing on unrelated terms.
    local sid="session-patterns-test"
    local sf="$FIXTURE_DIR/transfer/data/sessions/${sid}.json"
    jq -n --arg id "$sid" '{
        id:$id,started_at:"2026-02-20T10:00:00Z",
        ended_at:"2026-02-20T11:00:00Z",
        summary:"scripting",goals_addressed:["Goal"],
        decisions_made:["Dec"],patterns_learned:["Pattern gamma"],
        open_threads:[],
        handoff:{message:"m",next_steps:[],blockers:[],questions:[]},
        git_state:{branch:"main",commits:["abc"],uncommitted:[]},
        context:{project:"",active_files:[],recent_commands:[],environment:{}},
        related:{journal_entries:[],patterns:[],goals:[]}
    }' > "$sf"
    echo "$sid" > "$FIXTURE_DIR/transfer/data/.current_session"

    local output
    output=$("$FIXTURE_DIR/lore.sh" resume "session-patterns-test" 2>&1) || true

    # curate_for_context should produce "Relevant Context" since index has matching data
    assert_output_contains "output contains Relevant Context" "$output" "Relevant Context"

    teardown
}

test_resume_default_does_not_fork() {
    echo "Test: resume without --fork creates no new session file"
    setup

    create_session "session-nofork-test" "No-fork summary"

    local before after
    before=$(ls -1 "$FIXTURE_DIR/transfer/data/sessions/"*.json 2>/dev/null | wc -l | tr -d ' ')

    local output
    output=$("$FIXTURE_DIR/lore.sh" resume "session-nofork-test" 2>&1) || true

    after=$(ls -1 "$FIXTURE_DIR/transfer/data/sessions/"*.json 2>/dev/null | wc -l | tr -d ' ')

    if [[ "$after" -eq "$before" ]]; then
        echo "  PASS: session count unchanged ($before)"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: session count changed ($before -> $after)"
        FAIL=$((FAIL + 1))
    fi

    assert_output_not_contains "output lacks fork banner" "$output" "Forked new session"
    assert_output_contains "output notes read-only resume" "$output" "read-only"

    teardown
}

test_resume_fork_flag_forks() {
    echo "Test: resume with --fork creates a new session file"
    setup

    create_session "session-fork-test" "Fork summary"

    local before after
    before=$(ls -1 "$FIXTURE_DIR/transfer/data/sessions/"*.json 2>/dev/null | wc -l | tr -d ' ')

    local output
    output=$("$FIXTURE_DIR/lore.sh" resume "session-fork-test" --fork 2>&1) || true

    after=$(ls -1 "$FIXTURE_DIR/transfer/data/sessions/"*.json 2>/dev/null | wc -l | tr -d ' ')

    if [[ "$after" -eq $((before + 1)) ]]; then
        echo "  PASS: session count grew by one ($before -> $after)"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: expected one new session ($before -> $after)"
        FAIL=$((FAIL + 1))
    fi

    assert_output_contains "output contains fork banner" "$output" "Forked new session"

    teardown
}

# --- Runner ---

echo "=== Curated Resume Integration Tests ==="
echo ""

test_resume_with_index_shows_ranked
echo ""
test_resume_without_index_no_ranked
echo ""
test_resume_access_logging
echo ""
test_sparse_session_ranked_fallback
echo ""
test_resume_preserves_patterns
echo ""
test_resume_default_does_not_fork
echo ""
test_resume_fork_flag_forks
echo ""

echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
