# Plan: Add Inbox Staging to Lineage

## Context

Lineage has four components (journal, graph, patterns, transfer) but no staging
area for raw observations. Content arrives pre-classified -- you `remember` a
decision or `learn` a pattern. There is no place for "I noticed something but
don't know what it is yet."

The Praxis prototype (`~/dev/praxis/store.py`) implements an `inbox/` directory
with JSONL append for raw observations and a promotion workflow that converts
them into formal intent or pattern entries. The Feedback Loop initiative needs
exactly this: Mirror captures raw observations, but Lineage has no landing zone.

**Source:** Council review of Project Praxis, 2026-02-14.
See `~/dev/praxis/store.py` lines 130-136 for inbox implementation.
See `~/dev/council/initiatives/feedback-loop.md` for the parent initiative.

## What to Do

### 1. Create the inbox directory structure

```text
lineage/
  inbox/
    data/
      observations.jsonl   # Append-only raw observations
    lib/
      inbox.sh             # Inbox operations
```

Follow the existing component structure (journal/data/, patterns/data/, etc.).

### 2. Write `inbox/lib/inbox.sh`

Three functions, matching the patterns in `journal/lib/journal.sh`:

- `inbox_append` -- Append a raw observation to `observations.jsonl`. Schema:
  ```json
  {
    "id": "obs-<8 hex chars>",
    "timestamp": "ISO8601",
    "source": "string (filename, agent-id, or 'manual')",
    "content": "string (raw text)",
    "status": "raw|promoted|discarded",
    "tags": ["optional", "tags"]
  }
  ```
- `inbox_list` -- List observations, optionally filtered by status
- `inbox_promote` -- Mark an observation as promoted (sets status, records which
  target it was promoted to). Does NOT create the target entry -- that remains a
  `lineage remember` or `lineage learn` call.

Use `fcntl` file locking if bash supports it, or use the lockfile pattern from
the Praxis prototype (`~/dev/praxis/store.py` lines 49-57) adapted to shell. At
minimum, use atomic append (single `echo >>` call per entry).

### 3. Wire inbox into lineage.sh

Add two quick commands:

- `lineage observe "<text>"` -- Append to inbox. Analogous to `remember` but
  without requiring rationale or classification.
- `lineage inbox [--status raw]` -- List inbox contents, default to raw.

Add `inbox` to the Components section of `show_help()`.

### 4. Update LINEAGE_CONTRACT.md

Add inbox to the Components table:

| Component | Accepts          | Returns             | Storage                         |
| --------- | ---------------- | ------------------- | ------------------------------- |
| inbox     | raw observations | observation records | `inbox/data/observations.jsonl` |

Add the Write Interface section for `lineage observe`.

### 5. Validate against Praxis store.py

The Praxis prototype's `append_inbox()` and `read_inbox()` functions
(`~/dev/praxis/store.py` lines 130-180) provide a reference implementation.
Verify the shell version handles:

- Timestamp injection when not provided
- Empty content rejection
- JSONL format (one JSON object per line, newline-terminated)

## What NOT to Do

- Do not add `intent/` to Lineage -- intent/goals stay in Oracle. The inbox
  stages observations, not missions.
- Do not add Python to Lineage -- keep the bash CLI. The Praxis Python store is
  a reference, not a dependency.
- Do not build auto-promotion -- promotion requires human or agent judgment.
  `inbox_promote` marks status; it does not decide what to promote.
- Do not modify Mirror -- Mirror's capture pipeline is separate. Neo's future
  `sync` command bridges Mirror to inbox. This plan only builds the inbox side.
- Do not change the existing `remember` or `learn` commands -- inbox supplements,
  it does not replace.

## Files to Create/Modify

| File                  | Change                             |
| --------------------- | ---------------------------------- |
| `inbox/data/.gitkeep` | Create directory                   |
| `inbox/lib/inbox.sh`  | New: inbox operations              |
| `lineage.sh`          | Add `observe` and `inbox` commands |
| `LINEAGE_CONTRACT.md` | Add inbox to components table      |

## Acceptance Criteria

- [ ] `lineage observe "something interesting"` appends to
      `inbox/data/observations.jsonl`
- [ ] `lineage inbox` lists raw observations with timestamps
- [ ] `lineage inbox --status promoted` filters by status
- [ ] Observations have unique IDs (`obs-` prefix + 8 hex chars)
- [ ] JSONL format: one valid JSON object per line
- [ ] Empty content is rejected with an error message
- [ ] LINEAGE_CONTRACT.md documents the inbox component
- [ ] Existing commands (`remember`, `learn`, `search`) are unchanged

## Testing

```bash
# Basic observe
./lineage.sh observe "Vector search fails on large datasets"
./lineage.sh inbox

# Verify JSONL format
cat inbox/data/observations.jsonl | python3 -c "import sys,json; [json.loads(l) for l in sys.stdin]"

# Verify empty rejection
./lineage.sh observe "" 2>&1 | grep -i error

# Verify existing commands unaffected
./lineage.sh remember "Test decision" --rationale "Testing"
./lineage.sh search "Test"
```
