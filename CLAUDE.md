# Lore

Explicit context management for multi-agent systems.

## Quick Start

See the [tutorial](docs/tutorial.md) for a hands-on walkthrough. The essentials:

```bash
# Record decisions, patterns, and failures with one command
lore capture "Use JSONL for storage" --rationale "Append-only, simple"
lore capture "Safe bash arithmetic" --solution 'Use x=$((x+1))' --context "set -e scripts"
lore capture "Permission denied" --error-type ToolError

# Or use shortcuts
lore remember "Use JSONL for storage" --rationale "Append-only, simple"
lore learn "Safe bash arithmetic" --solution 'Use x=$((x+1))'
lore fail ToolError "Permission denied"

# End a session (capture context for next time)
lore handoff "Finished X, next steps: Y, blocked on Z"

# Resume previous session
lore resume

# Search everything
lore search "authentication"
```

## Components

Eight components, one CLI. See `SYSTEM.md` for architecture, data flow, and the component table.

| Component     | Key Question                     |
| ------------- | -------------------------------- |
| **registry/** | "What exists and how connected?" |
| **transfer/** | "What's next?"                   |
| **journal/**  | "Why did we choose this?"        |
| **patterns/** | "What did we learn?"             |
| **failures/** | "What went wrong?"               |
| **inbox/**    | "What did we notice?"            |
| **intent/**   | "What are we trying to achieve?" |
| **graph/**    | "What relates to this?"          |

**Append-only.** Decisions and patterns are never deleted, only marked revised or abandoned.

**Patterns are never compressed.** When compressing sessions, lessons learned survive.

## Integration Contract

See `LORE_CONTRACT.md` for how other projects write to and read from Lore. Tags always include the source project name.

## History

Lore consolidated functionality from earlier projects:

- **intent/** — Absorbed from Oracle (goal/mission tracking)
- **transfer/** — Absorbed from Lineage (session handoff)

These origins appear in component READMEs but are implementation history, not integration points.

## Data Formats

- Decisions: JSON (see `journal/data/schema.json`)
- Graph: JSON (nodes keyed by ID, edges as array)
- Patterns: YAML (patterns and anti_patterns lists)
- Sessions: JSON (one file per session in `transfer/data/sessions/`)
- Goals: YAML (one file per goal in `intent/data/goals/`)
- Missions: YAML (one file per mission in `intent/data/missions/`)
- Failures: JSONL (append-only in `failures/data/`)
- Registry: YAML (`registry/data/metadata.yaml`, `clusters.yaml`, `relationships.yaml`, `contracts.yaml`)

## Coding Conventions

- Shell scripts use `set -euo pipefail`
- Quote all variable expansions
- Use `trap` for cleanup
- Conventional commits with Strunk's-style body (see ~/.claude/CLAUDE.md)

## Integration

Other projects integrate via `lib/lore-client-base.sh` -- fail-silent wrappers that record decisions, patterns, and observations without blocking if lore is unavailable. See `LORE_CONTRACT.md` for the full write/read interface.

## Syncing External Sources

```bash
# Sync Entire CLI checkpoints to journal
make sync-entire

# Sync all external sources
make sync-all
```

The `scripts/entire-yeoman.sh` script reads from the `entire/checkpoints/v1` branch and writes checkpoint metadata to the journal. A marker file prevents duplicate syncs.
