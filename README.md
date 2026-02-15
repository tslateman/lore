# Lore

Explicit context management for multi-agent systems.

## Setup

```bash
export PATH="$HOME/dev/lore:$PATH"
```

## Usage

```bash
lore remember "Use JSONL for storage" \
  --rationale "Simpler than SQLite, append-only matches our use case"

lore learn "Safe bash arithmetic" \
  --context "Incrementing variables with set -e" \
  --solution "Use x=\$((x + 1)) instead of ((x++))"

lore handoff "Auth implementation 80% complete, need OAuth integration"

lore resume

lore search "authentication"
```

See `lore --help` for the full command list.

## Why Lore

MEMORY.md gives each agent implicit context -- loaded into the prompt, hoped to
be relevant. Lore gives explicit context -- structured writes, typed queries,
cross-project assembly. The difference matters when multiple agents need the
same context, when context exceeds what fits in a system prompt, or when you
need to query across time.

**Registry** is the proven core. It maps 24 projects with roles, contracts,
cluster membership, and dependencies. `lore registry context neo` assembles an
onboarding bundle no agent could build from scratch.

**Transfer** provides session continuity. `lore resume` at session start loads
the previous session's state -- what was done, what's next, what's blocked.

**Journal, patterns, inbox, intent, and graph** provide structured storage for
decisions, lessons, observations, goals, and relationships. These components
earn their keep at scale -- when the flat-file approach stops fitting in a
prompt.

## Components

| Component     | Purpose               | Key Question                           |
| ------------- | --------------------- | -------------------------------------- |
| **registry/** | Project metadata      | "What exists and how does it connect?" |
| **transfer/** | Session succession    | "What's next?"                         |
| **journal/**  | Decision capture      | "Why did we choose this?"              |
| **patterns/** | Lessons learned       | "What did we learn?"                   |
| **inbox/**    | Raw observations      | "What did we notice?"                  |
| **intent/**   | Goals and missions    | "What are we trying to achieve?"       |
| **graph/**    | Knowledge connections | "What relates to this?"                |

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

## Integration

Other projects integrate via `lib/lore-client-base.sh` -- fail-silent wrappers
that record decisions, patterns, and observations without blocking if lore is
unavailable. See `LORE_CONTRACT.md` for the full write/read interface.
