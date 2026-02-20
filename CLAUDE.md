# Lore

Explicit context management for multi-agent systems.

## Ecosystem

> **You are here: Lore** -- Data pillar

| Project  | Pillar   | Role                        |
| -------- | -------- | --------------------------- |
| **Lore** | Data     | Memory, registry, intent    |
| Mirror   | Data     | Judgment capture & patterns |
| Neo      | Control  | Teams, missions, delegation |
| Bach     | Action   | Stateless workers           |
| Council  | Advisory | Cross-project decisions     |

Full map: ~/dev/council/mainstay/ecosystem.md

## Onboarding

New to the stack? Start with
[Getting Started](~/dev/council/docs/getting-started.md) -- a 30-minute path
from zero to productive.

## Quick Start

See the [tutorial](docs/tutorial.md) for a hands-on walkthrough. The essentials:

```bash
# One verb, four destinations — flags determine type
lore capture "Users retry after timeout"                                    # → observation (inbox)
lore capture "Use JSONL for storage" --rationale "Append-only, simple"      # → decision (journal)
lore capture "Safe bash arithmetic" --solution 'Use x=$((x+1))'            # → pattern (patterns)
lore capture "Permission denied" --error-type ToolError                     # → failure (failures)

# Shortcuts still work
lore remember "Use JSONL for storage" --rationale "Append-only, simple"
lore learn "Safe bash arithmetic" --solution 'Use x=$((x+1))'
lore fail ToolError "Permission denied"

# End a session (capture context for next time)
lore handoff "Finished X, next steps: Y, blocked on Z"

# Resume previous session
lore resume

# One verb reads from all sources — flags select mode
lore recall "authentication"                                               # → search (default)
lore recall --project council                                              # → project context
lore recall --patterns "API design"                                        # → pattern suggestions
lore recall --failures --type Timeout                                      # → filtered failures
lore recall --triggers                                                     # → recurring failure analysis
lore recall --brief "graph"                                                # → topic briefing
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

Lore consolidated functionality from earlier projects (now deprecated/archived):

- **intent/** — Absorbed from Oracle (goal/task tracking)
- **transfer/** — Absorbed from prior session system (session handoff, now a Lore component)

These origins appear in component READMEs but are implementation history, not integration points.

## Data Formats

- Decisions: JSON (see `journal/data/schema.json`)
- Graph: JSON (nodes keyed by ID, edges as array)
- Patterns: YAML (patterns and anti_patterns lists)
- Sessions: JSON (one file per session in `transfer/data/sessions/`)
- Goals: YAML (one file per goal in `intent/data/goals/`)
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

## Entire CLI Integration

Lore integrates with [Entire CLI](https://docs.entire.io) for checkpoint/rollback capabilities:

```bash
# Resume a branch with Lore context injection
lore entire-resume feature/my-branch

# This:
# 1. Queries Lore for patterns relevant to the branch
# 2. Shows related decisions from the journal
# 3. Runs `entire resume` to restore checkpoint state
```

The integration loop:

1. **Capture**: `entire` checkpoints agent work on git push
2. **Sync**: `make sync-entire` writes checkpoints to Lore journal
3. **Resume**: `lore entire-resume <branch>` injects patterns before continuing
