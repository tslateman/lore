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
lore recall --project council                                              # → project context
lore recall --patterns "API design"                                        # → pattern suggestions
lore recall --failures --type Timeout                                      # → filtered failures
lore recall --triggers                                                     # → recurring failure analysis
lore recall --brief "graph"                                                # → topic briefing
```

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

- nvm lazy-loading breaks Bash tool -- use full path: `/Users/tslater/.nvm/versions/node/v24.1.0/bin/npm`
- macOS bash 3.2 lacks `${VAR,,}`, `mapfile`, `xargs -r` -- use POSIX alternatives

<!-- gitnexus:start -->

# GitNexus — Code Intelligence

This project is indexed by GitNexus as **lore** (174 symbols, 149 relationships, 0 execution flows). Use the GitNexus MCP tools to understand code, assess impact, and navigate safely.

> If any GitNexus tool warns the index is stale, run `npx gitnexus analyze` in terminal first.

## Always Do

- **MUST run impact analysis before editing any symbol.** Before modifying a function, class, or method, run `gitnexus_impact({target: "symbolName", direction: "upstream"})` and report the blast radius (direct callers, affected processes, risk level) to the user.
- **MUST run `gitnexus_detect_changes()` before committing** to verify your changes only affect expected symbols and execution flows.
- **MUST warn the user** if impact analysis returns HIGH or CRITICAL risk before proceeding with edits.
- When exploring unfamiliar code, use `gitnexus_query({query: "concept"})` to find execution flows instead of grepping. It returns process-grouped results ranked by relevance.
- When you need full context on a specific symbol — callers, callees, which execution flows it participates in — use `gitnexus_context({name: "symbolName"})`.

## When Debugging

1. `gitnexus_query({query: "<error or symptom>"})` — find execution flows related to the issue
2. `gitnexus_context({name: "<suspect function>"})` — see all callers, callees, and process participation
3. `READ gitnexus://repo/lore/process/{processName}` — trace the full execution flow step by step
4. For regressions: `gitnexus_detect_changes({scope: "compare", base_ref: "main"})` — see what your branch changed

## When Refactoring

- **Renaming**: MUST use `gitnexus_rename({symbol_name: "old", new_name: "new", dry_run: true})` first. Review the preview — graph edits are safe, text_search edits need manual review. Then run with `dry_run: false`.
- **Extracting/Splitting**: MUST run `gitnexus_context({name: "target"})` to see all incoming/outgoing refs, then `gitnexus_impact({target: "target", direction: "upstream"})` to find all external callers before moving code.
- After any refactor: run `gitnexus_detect_changes({scope: "all"})` to verify only expected files changed.

## Never Do

- NEVER edit a function, class, or method without first running `gitnexus_impact` on it.
- NEVER ignore HIGH or CRITICAL risk warnings from impact analysis.
- NEVER rename symbols with find-and-replace — use `gitnexus_rename` which understands the call graph.
- NEVER commit changes without running `gitnexus_detect_changes()` to check affected scope.

## Tools Quick Reference

| Tool             | When to use                   | Command                                                                 |
| ---------------- | ----------------------------- | ----------------------------------------------------------------------- |
| `query`          | Find code by concept          | `gitnexus_query({query: "auth validation"})`                            |
| `context`        | 360-degree view of one symbol | `gitnexus_context({name: "validateUser"})`                              |
| `impact`         | Blast radius before editing   | `gitnexus_impact({target: "X", direction: "upstream"})`                 |
| `detect_changes` | Pre-commit scope check        | `gitnexus_detect_changes({scope: "staged"})`                            |
| `rename`         | Safe multi-file rename        | `gitnexus_rename({symbol_name: "old", new_name: "new", dry_run: true})` |
| `cypher`         | Custom graph queries          | `gitnexus_cypher({query: "MATCH ..."})`                                 |

## Impact Risk Levels

| Depth | Meaning                               | Action                |
| ----- | ------------------------------------- | --------------------- |
| d=1   | WILL BREAK — direct callers/importers | MUST update these     |
| d=2   | LIKELY AFFECTED — indirect deps       | Should test           |
| d=3   | MAY NEED TESTING — transitive         | Test if critical path |

## Resources

| Resource                              | Use for                                  |
| ------------------------------------- | ---------------------------------------- |
| `gitnexus://repo/lore/context`        | Codebase overview, check index freshness |
| `gitnexus://repo/lore/clusters`       | All functional areas                     |
| `gitnexus://repo/lore/processes`      | All execution flows                      |
| `gitnexus://repo/lore/process/{name}` | Step-by-step execution trace             |

## Self-Check Before Finishing

Before completing any code modification task, verify:

1. `gitnexus_impact` was run for all modified symbols
2. No HIGH/CRITICAL risk warnings were ignored
3. `gitnexus_detect_changes()` confirms changes match expected scope
4. All d=1 (WILL BREAK) dependents were updated

## Keeping the Index Fresh

After committing code changes, the GitNexus index becomes stale. Re-run analyze to update it:

```bash
npx gitnexus analyze
```

If the index previously included embeddings, preserve them by adding `--embeddings`:

```bash
npx gitnexus analyze --embeddings
```

To check whether embeddings exist, inspect `.gitnexus/meta.json` — the `stats.embeddings` field shows the count (0 means no embeddings). **Running analyze without `--embeddings` will delete any previously generated embeddings.**

> Claude Code users: A PostToolUse hook handles this automatically after `git commit` and `git merge`.

## CLI

| Task                                         | Read this skill file                                 |
| -------------------------------------------- | ---------------------------------------------------- |
| Understand architecture / "How does X work?" | `~/.claude/skills/gitnexus-exploring/SKILL.md`       |
| Blast radius / "What breaks if I change X?"  | `~/.claude/skills/gitnexus-impact-analysis/SKILL.md` |
| Trace bugs / "Why is X failing?"             | `~/.claude/skills/gitnexus-debugging/SKILL.md`       |
| Rename / extract / split / refactor          | `~/.claude/skills/gitnexus-refactoring/SKILL.md`     |
| Tools, resources, schema reference           | `~/.claude/skills/gitnexus-guide/SKILL.md`           |
| Index, status, clean, wiki CLI commands      | `~/.claude/skills/gitnexus-cli/SKILL.md`             |

<!-- gitnexus:end -->
