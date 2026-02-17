Status: Draft

# Plan: Progressive Disclosure in Context Injection Hook

## Context

The `hooks/inject-context.sh` hook injects full decision text, pattern
solutions, and handoff messages into every Claude Code prompt. Each match
consumes 100-300 chars of a 1500-char budget, yielding 5-8 items at best.
Agents receive verbose context they may not need, while the budget caps out
before less-relevant items surface.

claude-mem solved this with a two-tier pattern: a compact index (~50
tokens/result) at injection time, then full details fetched on demand via MCP.
This yields 10x more items in the same token budget, and agents only pay for
details they actually use.

Lore already has the fetch tier -- `lore_search` and `lore_context` MCP tools
return full details. The hook just needs to emit a compact index instead of
full text.

## What to Do

### 1. Add a `--compact` flag to `_search_fts5()` in `lore.sh`

The FTS5 query at `lore.sh:568-627` already returns six columns:
`type`, `id`, `content` (truncated to 120 chars), `project`, `date`, `score`.

Add a `--compact` output mode that emits a tighter format: one line per
result, no content body, just enough to identify and rank.

Compact line format:

```
[type] id | title (≤40 chars) | project | date | score
```

Example:

```
[decision] dec-a1b2c3d4 | Use SQLite FTS5 for search ranking | lore | 2026-02-14 | 3.72
[pattern]  pat-000003   | Safe bash arithmetic                | lore | 2026-02-10 | 2.41
[transfer] session-2026 | Wire spec lifecycle to MCP server   | lore | 2026-02-16 | 1.98
```

Implementation in `lore.sh` at line 641 -- add a branch before the existing
`while` loop:

```bash
if [[ "${compact:-false}" == true ]]; then
    while IFS=$'\t' read -r type id content proj date score; do
        local title="${content:0:40}"
        printf "  [%-8s] %-16s | %-40s | %-8s | %s | %s\n" \
            "$type" "$id" "$title" "$proj" "$date" "$score"
        _log_access "$SEARCH_DB" "$type" "$id"
    done <<< "$results"
    return
fi
```

### 2. Add `lore search --compact` CLI entry point

In `lore.sh` `cmd_search()` (line 728), add `--compact` flag parsing alongside
existing `--graph-depth` and `--mode` flags. Pass it through to `_search_fts5`.

### 3. Rewrite `hooks/inject-context.sh` to use compact FTS5 output

Replace the three query functions (`query_patterns`, `query_journal`,
`query_transfer`) and the score-sort-budget loop with a single call:

```bash
compact_results=$("$LORE_ROOT/lore.sh" search "$keywords_joined" \
    --compact --project "$project" 2>/dev/null) || true
```

This delegates scoring, ranking, and budget to the existing FTS5 engine
instead of reimplementing it in the hook. The hook becomes a thin wrapper:

1. Detect project (keep existing `derive_project`)
2. Extract keywords (keep existing keyword extraction)
3. Call `lore search --compact` with keywords joined by OR
4. Prepend a header explaining the format and how to fetch details
5. Emit JSON with `additionalContext`

The header tells Claude how to use the index:

```
--- lore context (compact index, N items) ---
Use lore_search or lore_context MCP tools to fetch full details for any ID.

[type]     ID               | Title                                    | Project  | Date       | Score
[decision] dec-a1b2c3d4     | Use SQLite FTS5 for search ranking       | lore     | 2026-02-14 | 3.72
...
--- end lore context ---
```

### 4. Increase effective budget

With compact format, each line is ~90 chars instead of 150-300. The same
1500-char budget now fits ~16 items instead of 5-8. Consider raising to 2000
chars (~22 items) since token cost per item dropped.

Set `BUDGET=2000` in the hook. The compact format keeps total token cost below
the old budget's token cost despite more items.

### 5. Add `--compact` to MCP `lore_search` tool

In `mcp/src/index.ts` at the `lore_search` tool definition (line 66), add an
optional `compact` boolean parameter:

```typescript
compact: z.boolean().optional().describe(
    "Return compact index (ID + title + score) instead of full content"
),
```

Pass `--compact` to the `lore.sh search` args when set. This lets agents
choose between compact discovery and full retrieval within the MCP interface.

## What NOT to Do

- **Do not remove the existing full-text output.** `--compact` is additive.
  `lore search` without the flag returns the current verbose output. CLI users
  and the grep fallback are unchanged.
- **Do not touch the FTS5 scoring formula.** The six-signal ranking
  (`lore.sh:615-622`) stays exactly as-is. Compact mode changes output format,
  not ranking.
- **Do not add a new search endpoint or tool.** Reuse `lore_search` with a
  flag. No new MCP tools.
- **Do not remove `query_patterns`, `query_journal`, `query_transfer` from the
  hook yet.** Keep them as a fallback path when `SEARCH_DB` doesn't exist
  (FTS5 index not built). Gate the compact path on `[[ -f "$SEARCH_DB" ]]`.
- **Do not change the hook's project detection or keyword extraction.** Those
  work correctly.
- **Do not change the grep fallback search.** `_search_grep` is the no-SQLite
  fallback and stays verbose.

## Files to Modify

| File                         | Change                                                        |
| ---------------------------- | ------------------------------------------------------------- |
| `lore.sh` (line 558)         | Add `compact` local var and format branch to `_search_fts5()` |
| `lore.sh` (line 728)         | Add `--compact` flag parsing to `cmd_search()`                |
| `hooks/inject-context.sh`    | Replace query functions with `lore search --compact` call     |
| `mcp/src/index.ts` (line 66) | Add `compact` param to `lore_search` tool schema              |

## Acceptance Criteria

- [ ] `lore search "FTS5" --compact` outputs one-line-per-result table format
- [ ] `lore search "FTS5"` (without flag) outputs unchanged verbose format
- [ ] Hook injects compact index with header explaining how to fetch details
- [ ] Hook injects 12+ items within budget (up from 5-8)
- [ ] MCP `lore_search` accepts `compact: true` and returns compact format
- [ ] Hook falls back to existing query functions when `SEARCH_DB` absent
- [ ] `lore search --compact` logs access for each result (reinforcement loop)
- [ ] No changes to FTS5 scoring formula

## Testing

```bash
# Build search index first
lore index

# Verify compact output format
lore search "architecture" --compact
# Expected: one-line table rows, no multi-line content

# Verify verbose output unchanged
lore search "architecture"
# Expected: same as before this change

# Verify hook output (simulate UserPromptSubmit)
echo '{"cwd": "/Users/tslater/dev/lore", "prompt": "search architecture"}' \
    | bash hooks/inject-context.sh
# Expected: compact index with header, more items than before

# Verify MCP compact flag
echo '{"query": "architecture", "compact": true}' | \
    LORE_DIR=~/dev/lore node mcp/build/index.js  # (or test via Claude Code)

# Verify fallback when no search.db
mv ~/.lore/search.db ~/.lore/search.db.bak
echo '{"cwd": "/Users/tslater/dev/lore", "prompt": "search architecture"}' \
    | bash hooks/inject-context.sh
# Expected: old-style verbose output from query_patterns/query_journal/query_transfer
mv ~/.lore/search.db.bak ~/.lore/search.db

# Count items injected (should be 12+ vs old 5-8)
echo '{"cwd": "/Users/tslater/dev/lore", "prompt": "review all decisions"}' \
    | bash hooks/inject-context.sh 2>&1 | grep "injected"
# Expected: "lore: injected 12+ items ..."
```
