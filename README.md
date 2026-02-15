# Lore

Memory that compounds.

A system for AI agents to build persistent, searchable memory across sessions.

## Philosophy

> "The Mentor seat asks: Who will carry this forward?"

Right now, every session starts cold. Context is compacted, summarized, lost.
Lore changes that:

- **Decisions have rationale** - not just what was done, but _why_
- **Patterns are never lost** - lessons learned persist and prevent repeated mistakes
- **Context transfers** - another agent picks up exactly where you left off
- **Memory compounds** - knowledge builds over time, not reset each session

## Components

| Component     | Purpose               | Key Question                           |
| ------------- | --------------------- | -------------------------------------- |
| **journal/**  | Decision capture      | "Why did we choose this?"              |
| **graph/**    | Knowledge connections | "What relates to this?"                |
| **patterns/** | Lessons learned       | "What did we learn?"                   |
| **transfer/** | Session succession    | "What's next?"                         |
| **inbox/**    | Raw observations      | "What did we notice?"                  |
| **intent/**   | Goals and missions    | "What are we trying to achieve?"       |
| **registry/** | Project metadata      | "What exists and how does it connect?" |

## Quick Start

```bash
# Record a decision with rationale
./lore.sh remember "Use JSONL for storage" \
  --rationale "Simpler than SQLite, append-only matches our use case"

# Capture a pattern learned
./lore.sh learn "Safe bash arithmetic" \
  --context "Incrementing variables with set -e" \
  --solution "Use x=\$((x + 1)) instead of ((x++))"

# Create handoff for next session
./lore.sh handoff "Auth implementation 80% complete, need OAuth integration"

# Resume from previous session
./lore.sh resume

# Search across all components
./lore.sh search "authentication"
```

## Architecture

```
~/dev/mani.yaml              # Source of truth for projects, paths, tags
lore/
├── lore.sh                  # Main entry point
├── lib/                     # Shared libraries (ingest, client base)
├── failures/                # Failure tracking
│   └── data/
├── graph/                   # Memory Graph
│   ├── graph.sh
│   ├── lib/
│   └── data/                # graph.json
├── inbox/                   # Raw observations staging
│   ├── lib/
│   └── data/                # observations.jsonl
├── intent/                  # Goals and missions
│   ├── lib/
│   └── data/                # goals/, missions/
├── journal/                 # Decision Journal
│   ├── journal.sh
│   ├── lib/
│   └── data/                # decisions.jsonl
├── patterns/                # Pattern Learner
│   ├── patterns.sh
│   ├── lib/
│   └── data/                # patterns.yaml
├── registry/                # Project metadata and context
│   ├── lib/
│   └── data/                # metadata.yaml, clusters.yaml, etc.
└── transfer/                # Context Transfer
    ├── transfer.sh
    ├── lib/
    └── data/                # sessions/
```

## Integration with CLAUDE.md

Lore can export to CLAUDE.md format:

```bash
# Export recent decisions as markdown
./lore.sh journal export --format markdown --recent 10

# Export learned patterns
./lore.sh patterns list --format markdown

# Generate session retro
./lore.sh transfer handoff --format markdown
```

## The Golden Rule

**Patterns learned are never lost.**

When compressing context or archiving old sessions, lessons learned are always preserved.
This is memory that compounds.

## Origin

Built during the first orchestration session (2026-02-09) after asking:
"If you could build anything, what would it be?"

The answer: memory that persists across sessions, learns from mistakes,
and enables true succession between agents.
