Status: Draft

# Plan: Name and Protect the Storage Architecture

## Context

Lore's storage evolved organically into three tiers that map to event sourcing
principles. The design is sound but undocumented -- agents and contributors treat
all stores as equivalent when they follow different rules. This plan names the
tiers, documents the contracts each tier enforces, and fixes the one structural
gap the audit revealed.

Council validation: `~/dev/council/docs/adr/adr-003-curated-resume.md` (curated
resume depends on access_log integrity). Storage audit conducted during council
deliberation on the curation gap.

Related: `plans/plan-curated-resume.md` (downstream consumer of this work).

## The Three Tiers

### Event tier (JSONL) -- append-only, versioned, immutable

| Store        | File                            | Versioned | Compactable |
| ------------ | ------------------------------- | --------- | ----------- |
| Decisions    | `journal/data/decisions.jsonl`  | Yes       | Yes         |
| Failures     | `failures/data/failures.jsonl`  | No        | No          |
| Observations | `inbox/data/observations.jsonl` | Yes       | Yes         |
| Flags        | `patterns/data/flags.jsonl`     | No        | No          |

**Contract:** Records append. Updates create new records with the same ID and a
newer timestamp. Reads reconcile via `group_by(.id) | map(.[-1])`. Source files
are never edited in place. Compaction consolidates versions but preserves the
latest.

**Event sourcing parallel:** These are the event logs. They capture what happened.

### Reference tier (YAML/JSON files) -- mutable, curated, human-editable

| Store    | File                            | Mutable     | Versioned |
| -------- | ------------------------------- | ----------- | --------- |
| Patterns | `patterns/data/patterns.yaml`   | In-place    | No        |
| Concepts | `patterns/data/concepts.yaml`   | In-place    | No        |
| Goals    | `intent/data/goals/goal-*.yaml` | In-place    | No        |
| Sessions | `transfer/data/sessions/*.json` | Until close | No        |

**Contract:** Records are created and then edited directly. No append-only
guarantee. Human curation is the primary write path. Sessions are a special
case -- mutable during the active session, immutable after `ended_at` is set.

**Event sourcing parallel:** These are projections that can be independently
edited. Patterns emerge from decisions through explicit promotion
(review/consolidation), not automatic materialization. The mutability is
intentional -- curated knowledge evolves as understanding changes.

### Derived tier (computed, rebuildable from sources)

| Store      | File                         | Rebuilt by              | Persistent state                 |
| ---------- | ---------------------------- | ----------------------- | -------------------------------- |
| FTS5 index | `search.db` (FTS5 tables)    | `search-index.sh build` | None (dropped on rebuild)        |
| Graph      | `graph/data/graph.json`      | `graph/sync.sh`         | None (reconciled from sources)   |
| access_log | `search.db` (regular table)  | Never rebuilt           | **Yes -- survives FTS5 rebuild** |
| similarity | `search.db` (regular table)  | Never rebuilt           | Yes -- dedup cache               |
| graph SQL  | `search.db` (regular tables) | `search-index.sh build` | None (loaded from graph.json)    |

**Contract:** FTS5 tables are volatile caches rebuilt from event and reference
tier sources. `cmd_build()` at `lib/search-index.sh:740` drops only FTS5 virtual
tables (lines 754-759), preserving `access_log` and `similarity_cache`.

**Structural note:** `access_log` is the only persistent state in the derived
tier. It accumulates reinforcement signal (which records get accessed during
recall and resume) and feeds back into the FTS5 ranking formula at
`lib/search-index.sh:384`. It survives index rebuilds but would be lost if
`search.db` is deleted.

## What to Do

### 1. Document the tier architecture in Lore's CLAUDE.md

Add a "Storage Architecture" section to `~/dev/lore/CLAUDE.md` that names the
three tiers, their contracts, and which stores belong to each. This makes the
implicit design legible to agents.

```markdown
## Storage Architecture

Three tiers with different write contracts:

| Tier      | Format    | Write rule           | Examples                   |
| --------- | --------- | -------------------- | -------------------------- |
| Event     | JSONL     | Append-only          | Decisions, failures, inbox |
| Reference | YAML/JSON | Mutable, curated     | Patterns, goals, sessions  |
| Derived   | SQLite    | Rebuilt from sources | FTS5 index, graph SQL      |

Event tier stores never edit in place. Updates append new versions; reads
take the latest. Reference tier stores are human-editable projections.
Derived tier stores are caches rebuilt by `search-index.sh build` and
`graph/sync.sh`.

The `access_log` table in `search.db` is the exception: persistent state
in the derived tier. It accumulates reinforcement signal and survives FTS5
rebuilds. Do not delete `search.db` without backing up `access_log`.
```

### 2. Add access_log export/import to search-index.sh

The access_log survives `cmd_build` but not file deletion. Add two commands
to `lib/search-index.sh` for backup and restore:

At the dispatch block (`lib/search-index.sh:968`), add:

```bash
export-access) shift; cmd_export_access "$@" ;;
import-access) shift; cmd_import_access "$@" ;;
```

The functions:

```bash
cmd_export_access() {
    local outfile="${1:-${LORE_DATA_DIR}/access_log.jsonl}"
    sqlite3 "$DB" -json "SELECT * FROM access_log ORDER BY accessed_at;" \
        | jq -c '.[]' > "$outfile"
    echo "Exported $(wc -l < "$outfile" | tr -d ' ') access records to $outfile"
}

cmd_import_access() {
    local infile="${1:-${LORE_DATA_DIR}/access_log.jsonl}"
    [[ -f "$infile" ]] || { echo "No access log backup at $infile"; return 1; }
    while IFS= read -r line; do
        local type id ts
        type=$(echo "$line" | jq -r '.record_type')
        id=$(echo "$line" | jq -r '.record_id')
        ts=$(echo "$line" | jq -r '.accessed_at')
        sqlite3 "$DB" "INSERT OR IGNORE INTO access_log(record_type, record_id, accessed_at)
            VALUES ('$type', '$id', '$ts');"
    done < "$infile"
    echo "Imported access log from $infile"
}
```

### 3. Export access_log before destructive operations

In `cmd_build()` at `lib/search-index.sh:749`, before dropping tables, export
the access_log as a safety net:

```bash
    # Backup access_log before rebuild (survives DROP but protects against
    # accidental file deletion)
    if [[ -f "$DB" ]]; then
        cmd_export_access "${LORE_DATA_DIR}/access_log.jsonl" 2>/dev/null || true
    fi
```

This creates a JSONL backup in the event tier's format (append-only, portable).
The backup lives alongside the source-of-truth files, not inside the derived
cache.

### 4. Add architecture validation to `make check`

Add a test to `tests/` that verifies the tier contracts:

- Event tier files are valid JSONL (parseable by jq)
- `cmd_build` preserves `access_log` row count (before and after rebuild)
- `search.db` can be deleted and rebuilt without losing source data

## What NOT to Do

- Do not replace JSONL/YAML with a unified event store. The format split reflects
  a real semantic boundary (events vs. curated references). Unifying adds
  complexity without benefit at current scale.
- Do not add versioning to patterns or goals. Their mutability is intentional --
  curated knowledge needs human editing, not append-only history.
- Do not move graph.json to a pure derived model. The direct-edit path (graph
  add/link) is used for manual knowledge graph curation alongside automated sync.
- Do not add a global event sequence number. Per-store timestamps are sufficient.
  Global ordering adds coordination overhead with no current consumer.
- Do not add event schema versioning. The JSONL records are simple enough that
  schema evolution happens through additive fields (new fields ignored by old
  readers).

## Files to Create/Modify

- `CLAUDE.md` -- add Storage Architecture section
- `lib/search-index.sh` -- add `export-access`/`import-access` commands, add
  pre-rebuild backup in `cmd_build()`
- `tests/test-storage-tiers.sh` -- new test for tier contract validation

## Acceptance Criteria

- [ ] CLAUDE.md documents the three storage tiers and their contracts
- [ ] `search-index.sh export-access` exports access_log to JSONL
- [ ] `search-index.sh import-access` restores access_log from JSONL
- [ ] `search-index.sh build` creates access_log backup before rebuild
- [ ] Deleting and rebuilding search.db preserves access_log data (via
      backup/restore cycle)
- [ ] Tier contract test passes in `make check`

## Testing

```bash
# Verify access_log survives rebuild
sqlite3 ~/.lore/search.db "SELECT COUNT(*) FROM access_log;"  # note count
bash lib/search-index.sh build
sqlite3 ~/.lore/search.db "SELECT COUNT(*) FROM access_log;"  # same count

# Test export/import cycle
bash lib/search-index.sh export-access /tmp/access_log.jsonl
wc -l /tmp/access_log.jsonl  # should match count
rm ~/.lore/search.db
bash lib/search-index.sh build
sqlite3 ~/.lore/search.db "SELECT COUNT(*) FROM access_log;"  # 0
bash lib/search-index.sh import-access /tmp/access_log.jsonl
sqlite3 ~/.lore/search.db "SELECT COUNT(*) FROM access_log;"  # restored

# Verify CLAUDE.md documents tiers
grep -q "Storage Architecture" CLAUDE.md
```
