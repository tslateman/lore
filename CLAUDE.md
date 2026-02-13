# Lineage

Memory that compounds. Persistent, queryable knowledge across agent sessions.

## Quick Start

```bash
# Record a decision
./lineage.sh remember "Use JSONL for storage" --rationale "Append-only, simple"

# Capture a pattern
./lineage.sh learn "Safe bash arithmetic" --context "set -e scripts" --solution "Use x=\$((x+1))"

# Create handoff
./lineage.sh handoff "Auth 80% complete, need OAuth"

# Resume previous session
./lineage.sh resume

# Search everything
./lineage.sh search "authentication"
```

## Project Structure

- `lineage.sh`: Main entry point, dispatches to components
- `journal/`: Decision capture with rationale and outcome tracking
  - `journal.sh`, `lib/`, `data/decisions.jsonl`
- `graph/`: Knowledge graph connecting concepts, files, decisions, lessons
  - `graph.sh`, `lib/`, `data/graph.json`
- `patterns/`: Scored patterns and anti-patterns
  - `patterns.sh`, `lib/`, `data/patterns.yaml`
- `transfer/`: Session snapshots and handoff
  - `transfer.sh`, `lib/`, `data/sessions/`

## Key Concepts

**Four components, one CLI.** Each component handles a different aspect of memory:

- Journal answers "why did we choose this?"
- Graph answers "what relates to this?"
- Patterns answers "what did we learn?"
- Transfer answers "what's next?"

**Append-only.** Decisions and patterns are never deleted, only marked revised or abandoned.

**Patterns are never compressed.** When compressing sessions, lessons learned survive.

## Integration Contract

See `LINEAGE_CONTRACT.md` for how other projects (Neo, Oracle, Council) write to and read from Lineage. Tags always include the source project name.

## Data Formats

- Decisions: JSON (see `journal/data/schema.json`)
- Graph: JSON (nodes keyed by ID, edges as array)
- Patterns: YAML (patterns and anti_patterns lists)
- Sessions: JSON (one file per session in `transfer/data/sessions/`)

## Coding Conventions

- Shell scripts use `set -euo pipefail`
- Quote all variable expansions
- Use `trap` for cleanup
- Conventional commits with Strunk's-style body (see ~/.claude/CLAUDE.md)

## Part of Lore

Tracked in ~/dev/lore. Provides shared memory to: Neo, Oracle, Council, Lore.
Contract: `LINEAGE_CONTRACT.md`
