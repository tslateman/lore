# Lore

Explicit context management for multi-agent systems.

## Ecosystem

> **You are here: Lore** -- Data pillar

| Project  | Pillar   | Role                     |
| -------- | -------- | ------------------------ |
| **Lore** | Data     | Memory, registry, intent |
| Council  | Advisory | Cross-project decisions  |

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
lore recall "authentication" --rerank                                      # → model-judged reranking (haiku)
lore recall --project council                                              # → project context
lore recall --patterns "API design"                                        # → pattern suggestions
lore recall --failures --type Timeout                                      # → filtered failures
lore recall --triggers                                                     # → recurring failure analysis
lore recall --brief "graph"                                                # → topic briefing
```

`lore resume` reranks its "Relevant Context (ranked)" block with a fast model
by default; `LORE_RERANK=0` disables reranking everywhere (env vars documented
in `lib/rerank.sh`).

## Components

Nine components, one CLI. See `SYSTEM.md` for architecture, data flow, and the component table.

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
| **evidence/** | "What supports this?"            |

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

## Entire CLI

This repo uses [Entire CLI](https://github.com/entireio/cli) for checkpoint/rollback. `git push` triggers Entire to push session logs alongside your code. `make sync-entire` writes those checkpoints to the Lore journal.

## Known Patterns

- Scripts derive `WORKSPACE_ROOT` from their own location -- do not hardcode paths
- `lore-client.sh` uses `WORKSPACE_ROOT="${WORKSPACE_ROOT:-$(derived)}"` for reuse across consumers
- Append `|| true` to `grep` commands under `set -e` to prevent pipeline failure on no-match
- Use `git grep` not `grep -r` to avoid `.entire/` checkpoint pollution
- Dedup uses Jaccard word-similarity at 80% threshold
- Journal dedup happens at write time via `lib/conflict.sh`
- Registry data is untracked -- `LORE_REGISTRY_DATA` points to `${LORE_DATA_DIR}/registry/data`
- Command is `lore index build` not `rebuild` -- check dispatch table in `lore.sh`

## Platform Workarounds

- macOS bash 3.2 lacks `${VAR,,}`, `mapfile`, `xargs -r` -- use POSIX alternatives

<!-- gitnexus:start -->
# GitNexus — Code Intelligence

This project is indexed by GitNexus as **lore** (1570 symbols, 1550 relationships, 0 execution flows). Use the GitNexus MCP tools to understand code, assess impact, and navigate safely.

> Index stale? Run `node .gitnexus/run.cjs analyze` from the project root — it auto-selects an available runner. No `.gitnexus/run.cjs` yet? `npx gitnexus analyze` (npm 11 crash → `npm i -g gitnexus`; #1939).

## Always Do

- **MUST run impact analysis before editing any symbol.** Before modifying a function, class, or method, run `impact({target: "symbolName", direction: "upstream"})` and report the blast radius (direct callers, affected processes, risk level) to the user.
- **MUST run `detect_changes()` before committing** to verify your changes only affect expected symbols and execution flows. For regression review, compare against the default branch: `detect_changes({scope: "compare", base_ref: "main"})`.
- **MUST warn the user** if impact analysis returns HIGH or CRITICAL risk before proceeding with edits.
- When exploring unfamiliar code, use `query({search_query: "concept"})` to find execution flows instead of grepping. It returns process-grouped results ranked by relevance.
- When you need full context on a specific symbol — callers, callees, which execution flows it participates in — use `context({name: "symbolName"})`.
- For security review, `explain({target: "fileOrSymbol"})` lists taint findings (source→sink flows; needs `analyze --pdg`).

## Never Do

- NEVER edit a function, class, or method without first running `impact` on it.
- NEVER ignore HIGH or CRITICAL risk warnings from impact analysis.
- NEVER rename symbols with find-and-replace — use `rename` which understands the call graph.
- NEVER commit changes without running `detect_changes()` to check affected scope.

## Resources

| Resource | Use for |
|----------|---------|
| `gitnexus://repo/lore/context` | Codebase overview, check index freshness |
| `gitnexus://repo/lore/clusters` | All functional areas |
| `gitnexus://repo/lore/processes` | All execution flows |
| `gitnexus://repo/lore/process/{name}` | Step-by-step execution trace |

## CLI

| Task | Read this skill file |
|------|---------------------|
| Understand architecture / "How does X work?" | `.claude/skills/gitnexus/gitnexus-exploring/SKILL.md` |
| Blast radius / "What breaks if I change X?" | `.claude/skills/gitnexus/gitnexus-impact-analysis/SKILL.md` |
| Trace bugs / "Why is X failing?" | `.claude/skills/gitnexus/gitnexus-debugging/SKILL.md` |
| Rename / extract / split / refactor | `.claude/skills/gitnexus/gitnexus-refactoring/SKILL.md` |
| Tools, resources, schema reference | `.claude/skills/gitnexus/gitnexus-guide/SKILL.md` |
| Index, status, clean, wiki CLI commands | `.claude/skills/gitnexus/gitnexus-cli/SKILL.md` |

<!-- gitnexus:end -->
