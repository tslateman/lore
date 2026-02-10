# Lineage

Memory that compounds.

A system for AI agents to build persistent, searchable memory across sessions.

## Philosophy

> "The Mentor seat asks: Who will carry this forward?"

Right now, every session starts cold. Context is compacted, summarized, lost.
Lineage changes that:

- **Decisions have rationale** - not just what was done, but *why*
- **Patterns are never lost** - lessons learned persist and prevent repeated mistakes
- **Context transfers** - another agent picks up exactly where you left off
- **Memory compounds** - knowledge builds over time, not reset each session

## Components

| Component | Purpose | Key Question |
|-----------|---------|--------------|
| **journal/** | Decision capture | "Why did we choose this?" |
| **graph/** | Knowledge connections | "What relates to this?" |
| **patterns/** | Lessons learned | "What did we learn?" |
| **transfer/** | Session succession | "What's next?" |

## Quick Start

```bash
# Record a decision with rationale
./lineage.sh remember "Use JSONL for storage" \
  --rationale "Simpler than SQLite, append-only matches our use case"

# Capture a pattern learned
./lineage.sh learn "Safe bash arithmetic" \
  --context "Incrementing variables with set -e" \
  --solution "Use x=\$((x + 1)) instead of ((x++))"

# Create handoff for next session
./lineage.sh handoff "Auth implementation 80% complete, need OAuth integration"

# Resume from previous session
./lineage.sh resume

# Search across all components
./lineage.sh search "authentication"
```

## Architecture

```
lineage/
├── lineage.sh          # Main entry point
├── journal/            # Decision Journal
│   ├── journal.sh      # CLI
│   ├── lib/            # capture, store, relate
│   └── data/           # decisions.jsonl
├── graph/              # Memory Graph
│   ├── graph.sh        # CLI
│   ├── lib/            # nodes, edges, search, traverse
│   └── data/           # graph.json
├── patterns/           # Pattern Learner
│   ├── patterns.sh     # CLI
│   ├── lib/            # capture, match, suggest
│   └── data/           # patterns.yaml
└── transfer/           # Context Transfer
    ├── transfer.sh     # CLI
    ├── lib/            # snapshot, resume, handoff, compress
    └── data/           # sessions/
```

## Integration with CLAUDE.md

Lineage can export to CLAUDE.md format:

```bash
# Export recent decisions as markdown
./lineage.sh journal export --format markdown --recent 10

# Export learned patterns
./lineage.sh patterns list --format markdown

# Generate session retro
./lineage.sh transfer handoff --format markdown
```

## The Golden Rule

**Patterns learned are never lost.**

When compressing context or archiving old sessions, lessons learned are always preserved.
This is memory that compounds.

## Origin

Built during the Monarch/Neo/Oracle/Council session (2026-02-09) after asking:
"If you could build anything, what would it be?"

The answer: memory that persists across sessions, learns from mistakes,
and enables true succession between agents.
