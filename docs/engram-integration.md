# Engram Integration

Lore stores durable knowledge: decisions, patterns, failures, session handoffs. Engram (Claude Code's memory system) stores working knowledge: preferences, debugging context, session observations. The bridge connects them so recall draws from both without manual context injection.

## Architecture

Three operations move knowledge between systems:

| Command                | Direction      | Purpose                            |
| ---------------------- | -------------- | ---------------------------------- |
| `lore sync`            | Lore -> Engram | Project Lore records as shadows    |
| `lore promote`         | Engram -> Lore | Promote high-value Engram memories |
| `lore recall --routed` | Both           | Query-routed recall across systems |

Shadow memories use a `[lore:{id}]` prefix for dedup and traceability. A decision `dec-abc123` becomes `[lore:dec-abc123] Use PostgreSQL. Why: ACID transactions needed` in Engram. The prefix prevents duplicates on re-sync and lets the router enrich shadows with full Lore records.

## Sync: Lore to Engram

`lore sync` projects Lore records into Engram as shadow memories. Claude's built-in recall then surfaces Lore knowledge automatically.

```bash
# Sync records from the last 8 hours (default)
lore sync

# Sync from a specific window
lore sync --since 24h
lore sync --since 7d
lore sync --since 2026-02-01

# Sync only one type
lore sync --type decisions
lore sync --type patterns

# Preview without writing
lore sync --dry-run
```

What gets synced:

- **Decisions** from the journal (JSONL). Content includes decision text and rationale.
- **Patterns** from the pattern store (YAML). Content includes name, problem, and solution.
- **Failure triggers** from the failure journal. Only recurring triggers (Rule of Three).
- **Session handoffs** from the transfer system. Content includes accomplishments and next steps.
- **Graph edges** between synced records. Lore graph relationships become Engram edges between shadow memories.

Sync is idempotent. Each shadow carries a content hash (`<!-- hash:abc123 -->`). Re-running `lore sync` skips unchanged records, updates modified ones, and sets importance to 0 for retracted or abandoned decisions.

### Trigger surgery

Engram's SQLite database uses custom-function triggers for vector embeddings. These triggers fail when writing from bash (no custom functions loaded). The bridge captures trigger DDL, drops problematic triggers before writes, then recreates them after. A trap ensures triggers restore even on error.

## Promote: Engram to Lore

`lore promote` finds high-value Engram memories and promotes them to the durable record. This is the reverse flow: working memory that proved valuable graduates to the written record.

```bash
# Show promotion candidates
lore promote

# Limit results
lore promote --limit 5
```

Promotion criteria: importance >= 4 **or** accessCount >= 3, excluding shadow memories (already in Lore) and expired memories. Candidates are sorted by priority score (importance \* accessCount).

Each candidate is classified as decision, pattern, or observation based on content shape. The command presents candidates for review; promotion happens via `lore-scribe` or manual curation, not automatically.

After promotion, the original Engram memory gets a `[lore:{id}]` prefix and becomes a shadow of the promoted record.

## Routed Recall

`lore recall --routed` classifies queries and routes them to the right system.

```bash
# Routed recall (the default in inject-context.sh)
lore recall --routed "authentication decisions"

# Compact output (one line per result, with provenance markers)
lore recall --routed "authentication" --compact

# With graph traversal depth
lore recall --routed "authentication" --graph-depth 1
```

### Query classification

The router inspects query keywords to choose a strategy:

| Route          | Keywords                                                     | Behavior                           |
| -------------- | ------------------------------------------------------------ | ---------------------------------- |
| `lore-first`   | decision, rationale, pattern, failure, trigger, architecture | Search Lore, then fill from Engram |
| `memory-first` | working on, recent, session, preference, debugging, episode  | Search Engram, then fill from Lore |
| `both`         | Everything else                                              | Search both, interleave results    |

Results carry provenance markers: `(lore)` or `(mem)` in compact mode. Shadow memories found in Engram are enriched with full Lore record data (rationale, alternatives, tags for decisions; context, problem, solution for patterns).

### Cross-system graph traversal

When `--graph-depth` is set, the router follows edges across both systems. Starting from a Lore record, it traverses Lore graph edges, then crosses into Engram via shadow memories to follow Engram-only edges. This surfaces connections that exist only in one system.

The traversal uses BFS with depth limiting (1-3 hops). Results include the traversal depth and source system for each node.

## Setup

The bridge requires:

- `sqlite3` (ships with macOS)
- `jq` for JSON processing
- `yq` for YAML pattern reading
- Engram database at `~/.claude/memory.sqlite` (created by Claude Code's memory MCP server)

No configuration needed beyond a working Lore installation and an active Claude Code memory database. If the Engram database does not exist, sync and promote commands exit cleanly with a message.

## Troubleshooting

### Sync reports "No problematic triggers found"

The Engram database schema may have changed. The bridge looks for triggers containing `sync_disabled` or `embedding_vec`. If Claude Code updates its schema, this warning is informational; sync still works.

### Routed recall returns no Engram results

Check that `~/.claude/memory.sqlite` exists and contains memories:

```bash
sqlite3 ~/.claude/memory.sqlite "SELECT COUNT(*) FROM Memory;"
```

If the count is zero, Claude Code has not stored any memories yet. Use the memory MCP tools to create some, then re-run.

### Promotion finds no candidates

Memories need importance >= 4 or accessCount >= 3 to qualify. New memories start at importance 0 with accessCount 0. As Claude accesses and rates memories, candidates emerge naturally.

### Shadow content looks garbled

Shadows include a hash suffix (`<!-- hash:abc123 -->`) for change detection. This is normal. The router strips it from display output. If you see raw hashes in recall results, ensure you are using `lore recall --routed` rather than querying Engram directly.
