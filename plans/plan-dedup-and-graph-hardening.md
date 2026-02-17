# Plan: Journal Dedup Completion and Graph Sync Hardening

Status: Active (2026-02-16)

## Context

Session 2026-02-16 shipped two features: a write-time Jaccard dedup guard
in `journal/lib/store.sh` and a `lore graph sync` command in
`graph/sync.sh`. Both work but leave four loose ends.

## 1. Wire `lore journal compact` CLI command

`store.sh:compact_decisions()` exists but has no CLI entry point. The
journal has ~18 duplicate lines from `session-20260216-200709-9699bd22`.

### Changes

- `journal/journal.sh`: Add `compact` to the case dispatch, calling
  `compact_decisions` from `store.sh`
- `lore.sh`: Add `lore journal compact` to the `journal)` dispatch and
  help text
- Run once to clean `decisions.jsonl`, then `lore graph sync` to
  re-verify node count

### Acceptance

- `lore journal compact` reduces 69 lines to ~54 unique decisions
- Indexes rebuilt (function already handles this)
- Idempotent: running twice produces same line count

## 2. Single-pass jq in graph sync

`graph/sync.sh` calls jq 3-6 times per decision inside a bash loop.
At 50 decisions this takes ~3s; at 500 it becomes a bottleneck.

### Changes

- Replace the bash loop (lines 98-218) with a single jq invocation that:
  1. Reads `decisions.jsonl` as input
  2. Reads `graph.json` as slurp argument
  3. Deduplicates decisions by ID (keep last)
  4. Filters out decisions already in graph (by `data.journal_id`)
  5. Emits the complete additions JSON (nodes + edges) in one pass
- Keep the bash wrapper for argument parsing, dependency checks, and
  the final merge step
- The associative-array dedup (lines 60-66) and per-entity jq calls
  are the main cost; both move into the jq script

### Acceptance

- Same output as current implementation (verify with diff)
- Runs in <1s for 100 decisions
- Idempotency preserved

## 3. Verify `entire-yeoman.sh` with dedup guard

`scripts/entire-yeoman.sh` calls `lore remember` without `--force`. The
new 80% Jaccard guard may block checkpoint entries with similar summaries
(e.g., two checkpoints on `main` with overlapping file lists).

### Changes

- Read `entire-yeoman.sh` summary format: `"Entire checkpoint <id>: N
  session(s) on <branch>, files: <list>"`. The checkpoint ID varies per
  entry, so Jaccard similarity between two checkpoints should be low
  unless file lists are identical.
- Test: create two mock checkpoint summaries with overlapping file lists
  and verify Jaccard score. If >= 80%, add `--force` to the
  `entire-yeoman.sh` call (it has its own marker-based dedup).
- If < 80%, no change needed. Document the finding.

### Acceptance

- `make sync-entire` still syncs new checkpoints after dedup guard ships
- Either `--force` added or test proves it unnecessary

## 4. Edge dedup against existing graph edges

`graph/sync.sh` deduplicates edges within a single sync run (line 223)
but not against edges already in `graph.json`. Running sync, manually
adding an edge, then syncing again can produce duplicates.

### Changes

- In the merge step (lines 231-236), after concatenating edges, add a
  dedup pass: group by `from + to + relation`, keep the first occurrence
- This is a one-line jq addition to the merge filter:
  
  ```
  .edges = [.edges | group_by(.from + .to + .relation) | .[] | .[0]]
  ```

### Acceptance

- Manual test: add a duplicate edge to `graph.json`, run sync, verify
  it collapses to one
- No edge count inflation on repeated syncs

## Priority Order

1. **Compact** (immediate, cleans existing data)
2. **Edge dedup** (one-line fix, prevents data corruption)
3. **Yeoman verification** (test-only, no code change likely)
4. **Single-pass jq** (optimization, current perf is acceptable)
