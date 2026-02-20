# Troubleshooting

Common issues and fixes for Lore.

## Search returns no results

**Symptom:** `lore search "query"` prints `(no results)` even though data
exists.

**Cause:** The FTS5 index has not been built or is stale after bulk imports.
The index lives at `$LORE_DATA_DIR/search.db` when `LORE_DATA_DIR` is set, or
`~/.lore/search.db` as the legacy fallback (see `lib/paths.sh:35-42`).

**Fix:** Run `lore index` to build or rebuild the search index. Run it again
after `lore ingest` or manual edits to JSONL/YAML data files.

## Missing dependencies: jq, yq, or sqlite3

**Symptom:** Commands fail with `command not found`, or `lore index` silently
loads zero patterns.

**Cause:** Lore requires `jq` (JSON), `yq` (YAML), and `sqlite3` (FTS5
search). Without `yq`, pattern indexing fails silently
(`lib/search-index.sh:161`).

**Fix:** `brew install jq yq sqlite3` (macOS) or install each for your
platform. Get `yq` from <https://github.com/mikefarah/yq>.

## `lore resume` shows no previous sessions

**Symptom:** `lore resume` prints `No previous sessions found.`

**Cause:** No session files exist in `transfer/data/sessions/`. Sessions are
created by `lore handoff` or `transfer.sh init`.

**Fix:** Run `lore handoff "description of current work"` at the end of each
session. The next `lore resume` finds and forks from that session.

## Duplicate detection blocks writes

**Symptom:** `lore remember` or `lore learn` prints
`Possible duplicate(s) found` and refuses to write.

**Cause:** Jaccard similarity check (70% threshold) fires before writing
decisions or patterns (`lib/conflict.sh:162-197`).

**Fix:** Add `--force` to bypass:

```bash
lore remember "Use JSONL" --rationale "Different context" --force
```

## LORE_DIR not set correctly

**Symptom:** Commands fail with `No such file or directory` or client
libraries silently skip all calls.

**Cause:** `lore.sh` defaults `LORE_DIR` to its own directory (`lore.sh:8`).
Client libraries default to `$HOME/dev/lore`
(`lib/lore-client-base.sh:11`). If Lore lives elsewhere, both break.

**Fix:**

```bash
export LORE_DIR="$HOME/dev/lore"  # add to shell profile
```

## Registry validation fails on mani.yaml

**Symptom:** `lore validate` prints
`Error: mani.yaml not found at /path/to/mani.yaml`.

**Cause:** Validation expects `mani.yaml` one directory above `LORE_DIR`
(`lib/validate.sh:10-11`).

**Fix:**

```bash
WORKSPACE_ROOT="$HOME/dev" lore validate
```

## JSONL format errors

**Symptom:** `lore failures` or `lore search` returns jq parse errors.

**Cause:** A malformed line in a `.jsonl` file. Manual edits or interrupted
writes can corrupt a line.

**Fix:** Run `jq '.' failures/data/failures.jsonl > /dev/null` to find the bad
line number. Remove or fix it -- JSONL is append-only, so other lines are
unaffected.

## Invalid error type in `lore fail`

**Symptom:** `lore fail MyError "message"` prints
`Error: Unknown error_type 'MyError'`.

**Cause:** The failure journal validates against a fixed vocabulary
(`failures/lib/failures.sh:11`).

**Fix:** Use one of the valid types:
`UserDeny`, `HardDeny`, `NonZeroExit`, `Timeout`, `ToolError`, `LogicError`.
