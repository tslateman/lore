Status: Draft

# Plan: Wire FTS5 Ranked Search into Resume

## Context

`lore resume` surfaces parent session context and falls back to chronological
last-5-of-each-type when the session is sparse. The FTS5 6-factor ranking in
`lib/search-index.sh:292-393` (BM25, temporal decay, access frequency,
importance, recent access boost, project affinity) never runs during resume.

The context string already exists at `transfer/lib/resume.sh:690-706` --
project, summary, and open threads concatenated for pattern suggestion. This plan
wires that context string into the ranked search and logs access for every item
surfaced.

Council decision: `~/dev/council/wayfinder/adr-003-curated-resume.md`

## What to Do

### 1. Add `curate_for_context()` to `transfer/lib/resume.sh`

After `suggest_patterns_for_context` (line 706), add a function that calls
`search-index.sh search` with the assembled context string.

Reference: `search-index.sh` accepts CLI invocation at line 968:
`search-index.sh search <query> --project <P> --limit <N>`

```bash
curate_for_context() {
    local context_query="$1"
    local project="$2"
    local db="${LORE_SEARCH_DB}"

    # Require search index
    [[ ! -f "$db" ]] && return 0

    local results
    results=$(bash "${LORE_DIR}/lib/search-index.sh" search \
        "$context_query" --project "$project" --limit 10 2>/dev/null) || return 0

    [[ -z "$results" ]] && return 0

    echo -e "${CYAN}--- Relevant Context (ranked) ---${NC}"
    echo ""

    # Display results and log access
    echo "$results" | while IFS='|' read -r type id content rest; do
        [[ "$type" == "type" ]] && continue  # skip header
        echo "  [$type] $content"
        # Log access for reinforcement
        bash "${LORE_DIR}/lib/search-index.sh" log-access "$type" "$id" \
            2>/dev/null || true
    done
    echo ""
}
```

### 2. Call `curate_for_context` in `resume_session()`

At `transfer/lib/resume.sh:704-706`, after building `combined_context` and
calling `suggest_patterns_for_context`, add:

```bash
    # Ranked context retrieval (replaces sparse fallback when index exists)
    curate_for_context "${combined_context}" "${project}"
```

### 3. Replace sparse fallback with ranked query

In `reconstruct_context()` at `transfer/lib/resume.sh:213`, replace the
chronological last-5 retrievals (lines 251-290) with a ranked query when the
search index exists:

```bash
    # Ranked retrieval if index exists
    local db="${LORE_SEARCH_DB}"
    if [[ -f "$db" ]]; then
        local project_name
        project_name=$(basename "$(git rev-parse --show-toplevel 2>/dev/null || pwd)")
        curate_for_context "${project_name}" "${project_name}"
        return
    fi

    # Original chronological fallback below (when no index)
```

Keep the original chronological code as degraded-mode fallback for installations
without a search index.

### 4. Log access for items displayed in parent session

In the main `resume_session()` display path (around lines 580-676), after
displaying decisions_made and patterns_learned from the parent session, log
access for each item ID:

```bash
    # Log access for parent session items surfaced during resume
    if [[ -f "${LORE_SEARCH_DB}" ]]; then
        jq -r '.decisions_made[]?.id // empty' "$session_file" 2>/dev/null | \
            while IFS= read -r id; do
                bash "${LORE_DIR}/lib/search-index.sh" log-access "decision" "$id" \
                    2>/dev/null || true
            done
        jq -r '.patterns_learned[]?.id // empty' "$session_file" 2>/dev/null | \
            while IFS= read -r id; do
                bash "${LORE_DIR}/lib/search-index.sh" log-access "pattern" "$id" \
                    2>/dev/null || true
            done
    fi
```

## What NOT to Do

- Do not add a new verb, flag, or retrieval path. Curation is internal to
  `resume`, not a user-facing command.
- Do not modify `search-index.sh` or its scoring formula. The scorer is correct;
  the problem is that resume does not call it.
- Do not remove `suggest_patterns_for_context`. Keep it alongside ranked results
  until data proves one subsumes the other.
- Do not add a persistent salience table. Evaluate access data for 2-4 weeks
  first (per ADR-003 evaluate-before-extending gate).
- Do not remove the chronological fallback in `reconstruct_context`. It remains
  the degraded path when no search index exists.
- Do not add embedding, ML, or LLM-based ranking. Bash CLI constraint.

## Files to Modify

- `transfer/lib/resume.sh` -- add `curate_for_context()`, wire into
  `resume_session()` and `reconstruct_context()`, add access logging for parent
  session items

## Acceptance Criteria

- [ ] `lore resume` displays a "Relevant Context (ranked)" section with scored
      results from FTS5 when search.db exists
- [ ] Ranked results replace chronological fallback in sparse sessions
- [ ] Chronological fallback still works when search.db is absent
- [ ] Access log records entries for every item surfaced during resume
- [ ] No new files, tables, or dependencies introduced
- [ ] Existing resume behavior (parent session display, fork-on-resume, spec
      context, pattern suggestions) unchanged

## Testing

```bash
# Verify search index exists
ls -la ~/.lore/search.db

# Test ranked resume (rebuild index first)
bash lib/search-index.sh build
lore resume

# Verify "Relevant Context (ranked)" section appears
# Verify results are scored, not chronological

# Test access logging
sqlite3 ~/.lore/search.db "SELECT * FROM access_log ORDER BY accessed_at DESC LIMIT 10;"
# Should show entries with recent timestamps from resume

# Test degraded mode (no index)
mv ~/.lore/search.db ~/.lore/search.db.bak
lore resume
# Should fall back to chronological last-5-of-each-type
mv ~/.lore/search.db.bak ~/.lore/search.db

# Test sparse session
lore resume  # with a session that has <=1 populated field
# Should show ranked results instead of chronological fallback
```
