# Bridge: Lore → ClaudeMemory

One-way projection of Lore records into ClaudeMemory so the advise hook
surfaces them automatically.

## Architecture

Two databases, zero overlap today:

- **ClaudeMemory**: `~/.claude/memory.sqlite` — working memory (semantic
  recall, graph, episodes)
- **Lore**: `~/.local/share/lore/` — written record (decisions, patterns,
  failures, sessions)

The advise hook fires before every turn and queries only ClaudeMemory. Lore
data is invisible to it. The bridge fixes this by projecting Lore records as
shadow memories into ClaudeMemory.

## Shadow Memories

Each shadow carries a `[lore:{id}]` prefix for deduplication and traceability.

| Lore source         | Shadow content                                     | Topic            |
| ------------------- | -------------------------------------------------- | ---------------- |
| `decisions.jsonl`   | `[lore:dec-{id}] {decision}. Why: {rationale}`     | `lore-decisions` |
| `patterns.yaml`     | `[lore:pat-{id}] {name}: {problem} → {solution}`   | `lore-patterns`  |
| `failures.jsonl` 3+ | `[lore:trigger-{type}] {type} x{count}`            | `lore-failures`  |
| `sessions/*.json`   | `[lore:sess-{id}] {handoff message}. Next: {next}` | `lore-sessions`  |

Not bridged: individual failures, raw observations, Lore graph edges.

Shadows get `zeroblob(0)` for embeddings — FTS5-searchable, not
vector-searchable. Acceptable because shadow content is keyword-rich and the
`[lore:{id}]` prefix enables exact lookups.

## What Gets Built

### 1. `lib/bridge.sh` (new file)

```
sync_to_claude_memory [--since TIMESPEC] [--dry-run] [--type TYPE]
```

Logic:

1. Read recent records from each Lore source (filtered by timestamp)
2. For each record, query `memory.sqlite` FTS5 for existing `[lore:{id}]`
3. If missing, INSERT into Memory table + FTS5 index
4. If found, UPDATE content if Lore record changed
5. If Lore record superseded/retracted, set shadow importance to 0

SQL for insert:

```sql
INSERT INTO Memory (importance, accessCount, createdAt, lastAccessedAt,
                    project, embedding, source, topic, expiresAt, content)
VALUES (?, 0, ?, ?, ?, zeroblob(0), ?, ?, 0, ?);
```

Also insert into `_Memory_content_fts` for FTS5 discoverability.

### 2. `lore sync` subcommand (edit lore.sh)

Route `lore sync` to `sync_to_claude_memory` in `lib/bridge.sh`.

```bash
lore sync                        # sync last 8 hours
lore sync --since "2h ago"       # custom window
lore sync --since "2024-01-01"   # backfill
lore sync --dry-run              # preview without writing
lore sync --type decisions       # single source type
```

### 3. SessionEnd hook (edit settings.json)

```json
{
  "type": "command",
  "command": "lore sync --since '8h ago' 2>/dev/null",
  "timeout": 5
}
```

Runs automatically when a Claude Code session ends.

## Files Touched

| File                       | Change | Risk |
| -------------------------- | ------ | ---- |
| `~/dev/lore/lib/bridge.sh` | Create | Low  |
| `~/dev/lore/lore.sh`       | Edit   | Low  |
| `~/.claude/settings.json`  | Edit   | Low  |

## What Does NOT Change

- ClaudeMemory binary (`~/.claude/bin/memory`) — black box consumer
- Lore MCP server (`mcp/src/index.ts`) — no changes
- Existing Lore write paths (journal, patterns, failures, transfer)
- Advise hook — shadows discovered through existing recall pipeline
- `lore resume` — still works for full session context (git state, blockers)

## Dependencies

- `sqlite3` — ships with macOS
- `jq` — JSONL parsing
- `yq` (Go version) — YAML parsing; verify with `yq --version`

## Deduplication

The `[lore:{id}]` prefix anchors each shadow:

- Before insert: FTS5 query for prefix → skip if found
- On update: match by prefix → UPDATE content
- On supersede: match by prefix → SET importance = 0
- On retract: match by prefix → DELETE

## Migration

One-time backfill of existing Lore records:

```bash
lore sync --since "2024-01-01" --dry-run   # preview
lore sync --since "2024-01-01"              # execute
```

## Open Questions

1. **FTS5 trigger maintenance**: Does inserting directly into the Memory table
   auto-update `_Memory_content_fts`? Need to check if it's a content-sync
   FTS5 table or requires manual INSERT. The schema shows
   `content='Memory', content_rowid='id'` — this is a content-sync table, so
   manual INSERT into the FTS5 table is required after each Memory INSERT.

2. **AuditLog triggers**: The Memory table has INSERT/UPDATE/DELETE triggers
   that write to AuditLog. Direct SQLite writes will fire these triggers.
   Verify this doesn't cause issues with sync state (`isSynchronized`,
   `isFromRemote` fields).

3. **globalId generation**: Each Memory row gets a UUID via DEFAULT expression.
   Direct INSERT should auto-generate this. Verify.
