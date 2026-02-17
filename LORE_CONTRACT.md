# Lore Integration Contract

Version: 1.0

Lore is the shared memory backbone for the orchestration stack. It accepts structured writes from any project and exposes queryable reads. Integration is optional -- projects work without Lore but lose cross-session memory.

## Components

| Component | Accepts                   | Returns                              | Storage                         |
| --------- | ------------------------- | ------------------------------------ | ------------------------------- |
| journal   | decisions with rationale  | decision records, related decisions  | `journal/data/decisions.jsonl`  |
| graph     | nodes and edges           | subgraphs, traversals                | `graph/data/graph.json`         |
| patterns  | lessons and anti-patterns | matched patterns, suggestions        | `patterns/data/patterns.yaml`   |
| transfer  | session snapshots         | session state, handoff notes         | `transfer/data/sessions/`       |
| inbox     | raw observations          | observation records                  | `inbox/data/observations.jsonl` |
| intent    | goals with criteria       | goal records                         | `intent/data/goals/`            |
| registry  | project metadata          | project details, context bundles     | `registry/data/*.yaml`          |
| failures  | failure reports (JSONL)   | failure records, triggers, timelines | `failures/data/failures.jsonl`  |

## Write Interface

### Record a Decision (journal)

```bash
lore remember "<decision>" \
  --rationale "<why>" \
  --tags "<project>,<category>" \
  --entities "<affected files or concepts>"
```

Or via journal directly:

```bash
lore journal record "<decision>" \
  --rationale "<why>" \
  --type architecture|implementation|naming|tooling|process|bugfix|refactor \
  --alternatives "<option A>" --alternatives "<option B>" \
  --entities "file.py" --entities "concept-name" \
  --tags "myproject,team-management"
```

**Decision schema** (JSON):

```json
{
  "id": "dec-<8 hex chars>",
  "timestamp": "ISO8601",
  "session_id": "session-<8 hex chars>|null",
  "decision": "string (required)",
  "rationale": "string|null",
  "alternatives": ["string"],
  "outcome": "pending|successful|revised|abandoned",
  "type": "architecture|implementation|naming|tooling|process|bugfix|refactor|other",
  "entities": ["string"],
  "tags": ["string"],
  "lesson_learned": "string|null",
  "related_decisions": ["dec-id"],
  "git_commit": "sha|null"
}
```

### Capture a Pattern (patterns)

```bash
lore learn "<pattern name>" \
  --context "<when this applies>" \
  --solution "<what to do>" \
  --category bash|architecture|security|testing
```

**Pattern schema** (YAML):

```yaml
id: "pat-<6 digits>-<origin>"
name: "string"
context: "when this applies"
problem: "what goes wrong without it"
solution: "what to do"
category: "string"
origin: "session-<date> or <project-name>"
confidence: 0.0-1.0
validations: integer
examples:
  - bad: "what not to do"
  - good: "what to do"
```

### Add to Knowledge Graph (graph)

```bash
lore graph add-node "<name>" --type concept|file|decision|lesson|session \
  --data '{"key": "value"}'

lore graph add-edge "<from-id>" "<to-id>" \
  --relation relates_to|implements|learned_from|affects|depends_on
```

**Node types**: concept, file, decision, lesson, session
**Edge relations**: relates_to, implements, learned_from, affects, depends_on

### Capture an Observation (inbox)

```bash
lore observe "<raw observation>" \
  --source "<filename, agent-id, or 'manual'>" \
  --tags "<tag1>,<tag2>"
```

Observations land as raw entries in the inbox staging area. They require no classification or rationale -- use `observe` when you notice something but don't yet know what it means. Promote observations to formal entries via `lore remember` or `lore learn` after triage.

**Observation schema** (JSON):

```json
{
  "id": "obs-<8 hex chars>",
  "timestamp": "ISO8601",
  "source": "string (filename, agent-id, or 'manual')",
  "content": "string (raw text)",
  "status": "raw|promoted|discarded",
  "tags": ["optional", "tags"]
}
```

### Create Session Handoff (transfer)

```bash
lore handoff "<summary message>"
```

This captures current git state, active files, open threads, and creates a resumable snapshot.

### Create a Goal (intent)

```bash
lore goal create "<goal name>" \
  --priority critical|high|medium|low \
  --deadline "YYYY-MM-DD"
```

Goals are stored as individual YAML files in `intent/data/goals/`. Edit the YAML directly to add success criteria and tags.

**Goal schema** (YAML):

```yaml
id: "goal-<timestamp>-<hex>"
name: "string"
description: "string"
status: draft|active|blocked|completed|cancelled
priority: critical|high|medium|low
deadline: "YYYY-MM-DD"|null
success_criteria:
  - id: "sc-N"
    description: "string"
    type: manual|automated
    met: false
depends_on: []
projects: []
tags: []
```

## Read Interface

### Query Decisions

```bash
lore journal query "<search term>"
lore journal list --recent 10
lore journal show <dec-id>
```

### Query Patterns

```bash
lore patterns list
lore patterns match "<situation description>"
lore search "<term>"
```

### Query Graph

```bash
lore graph query "<concept>"
lore graph neighbors "<node-id>"
```

### List Observations (inbox)

```bash
lore inbox                    # all observations (default: raw)
lore inbox --status raw       # filter by status
lore inbox --status promoted  # show promoted observations
```

### Resume Session

```bash
lore resume              # latest session
lore resume <session-id> # specific session
```

### Query Goals (intent)

```bash
lore goal list [--status active] [--priority high]
lore goal show <goal-id>
```

### Query Registry (registry)

```bash
lore registry show <project>      # enriched project details
lore registry list                # list all projects
lore registry validate            # check registry consistency

# Full context (registry + decisions + patterns + graph)
lore context <project>
```

## Integration by Project

### Team Decisions

When a team makes a significant decision:

```bash
lore remember "Team alpha chose Redis over Memcached for session cache" \
  --rationale "Need pub/sub for invalidation, Redis supports it natively" \
  --tags "myproject,team-alpha,caching" \
  --type implementation
```

When spawning a team, check for relevant patterns:

```bash
lore patterns match "team coordination"
lore search "caching"
```

### Goal Outcomes (intent)

When a goal succeeds or fails:

```bash
lore remember "Goal 'improve API latency' achieved - p95 dropped from 800ms to 200ms" \
  --rationale "Connection pooling and query optimization were the key wins" \
  --tags "intent,performance,goal-outcome" \
  --type implementation

lore journal update <dec-id> --outcome successful \
  --lesson "Connection pooling alone gave 60% of the improvement"
```

### Governance Decisions

When charter decisions are made or revised:

```bash
lore remember "Critic seat gets veto power on security-related changes" \
  --rationale "Security review must not be overridden by velocity pressure" \
  --tags "myproject,governance,security" \
  --type process
```

### Cross-Project Patterns

When a pattern emerges across projects:

```bash
lore learn "Contract-first interfaces" \
  --context "Multi-project systems with independent evolution" \
  --solution "Define markdown contracts at boundaries before implementing" \
  --category architecture
```

## Conventions

- **Tags always include the source project name** (e.g., `teamctl`, `governance`, `analysis`)
- **Decisions use the project's own terminology** in the decision text
- **Patterns include origin** so you can trace where a lesson came from
- **Session handoffs belong to the project that creates them** -- use `--tags` to namespace
- **Graph nodes can reference entities across projects** -- use full paths (e.g., `myproject/state/agents/`)

## Data Locations

All data lives under `~/dev/lore/`:

```
journal/data/decisions.jsonl      # Append-only decision log
graph/data/graph.json             # Knowledge graph (nodes + edges)
patterns/data/patterns.yaml       # Pattern and anti-pattern library
transfer/data/sessions/           # Session snapshots (one JSON per session)
inbox/data/observations.jsonl     # Raw observation staging area
intent/data/goals/                # Goal YAML files (one per goal)
registry/data/metadata.yaml       # Project roles, contracts, components
registry/data/clusters.yaml       # Cluster definitions and data flow
registry/data/relationships.yaml  # Cross-project dependencies
registry/data/contracts.yaml      # Contract location tracking
failures/data/failures.jsonl     # Failure reports
```

## Non-Goals

- Lore does not enforce writes -- integration is opt-in
- Lore does not provide real-time pub/sub -- it is a structured log, not a message bus
