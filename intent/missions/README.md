# Missions

Structured work packages that the prompt compiler transforms into agent prompts.

## Schema

Each mission is a YAML file in `intent/missions/`.

```yaml
id: string              # unique identifier, matches filename
title: string           # human-readable name
objective: string       # ≤2 sentences. What does "done" look like?
project: string         # registered project name from mani.yaml
domain: string          # topic area for Lore queries (e.g., "search", "auth")
constraints:
  - string              # hard requirements the agent must respect
success_criteria:
  - criterion: string   # what to check
    verification: string # how to check it (command, test, manual step)
context_hints:
  patterns: string[]    # explicit pattern IDs to include (optional override)
  journal_types: string[] # which journal types to query (default: [decision])
  graph_entities: string[] # graph entities to pull relationships for
priority: "urgent" | "high" | "normal" | "low"
status: "draft" | "ready" | "active" | "complete"
created: ISO-8601
```

## Status Lifecycle

```
draft → ready → active → complete
```

- **draft** -- work in progress, not yet actionable
- **ready** -- fully specified, waiting for assignment
- **active** -- an agent is working on it
- **complete** -- all success criteria met and verified

## How Missions Feed the Compiler

The compiler reads a mission YAML and queries Lore for context:

1. Validate `project` against the registry
2. Query patterns by `domain`, journal entries by `journal_types`, graph by `graph_entities`
3. Budget the context window (constraints > patterns > decisions > graph)
4. Assemble the compiled prompt with role, mission, context, criteria, and closeout sections

See `flywheel-spec.md` for the full compilation process and prompt template.

## Naming Convention

Files use the mission ID as filename: `{id}.yaml` (e.g., `mission-graph-orphans.yaml`).
