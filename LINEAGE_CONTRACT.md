# Lineage Integration Contract

Version: 1.0

Lineage is the shared memory backbone for the orchestration stack. It accepts structured writes from any project and exposes queryable reads. Integration is optional -- projects work without Lineage but lose cross-session memory.

## Components

| Component | Accepts                   | Returns                             | Storage                        |
| --------- | ------------------------- | ----------------------------------- | ------------------------------ |
| journal   | decisions with rationale  | decision records, related decisions | `journal/data/decisions.jsonl` |
| graph     | nodes and edges           | subgraphs, traversals               | `graph/data/graph.json`        |
| patterns  | lessons and anti-patterns | matched patterns, suggestions       | `patterns/data/patterns.yaml`  |
| transfer  | session snapshots         | session state, handoff notes        | `transfer/data/sessions/`      |

## Write Interface

### Record a Decision (journal)

```bash
lineage remember "<decision>" \
  --rationale "<why>" \
  --tags "<project>,<category>" \
  --entities "<affected files or concepts>"
```

Or via journal directly:

```bash
lineage journal record "<decision>" \
  --rationale "<why>" \
  --type architecture|implementation|naming|tooling|process|bugfix|refactor \
  --alternatives "<option A>" --alternatives "<option B>" \
  --entities "file.py" --entities "concept-name" \
  --tags "neo,team-management"
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
lineage learn "<pattern name>" \
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
lineage graph add-node "<name>" --type concept|file|decision|lesson|session \
  --data '{"key": "value"}'

lineage graph add-edge "<from-id>" "<to-id>" \
  --relation relates_to|implements|learned_from|affects|depends_on
```

**Node types**: concept, file, decision, lesson, session
**Edge relations**: relates_to, implements, learned_from, affects, depends_on

### Create Session Handoff (transfer)

```bash
lineage handoff "<summary message>"
```

This captures current git state, active files, open threads, and creates a resumable snapshot.

## Read Interface

### Query Decisions

```bash
lineage journal query "<search term>"
lineage journal list --recent 10
lineage journal show <dec-id>
```

### Query Patterns

```bash
lineage patterns list
lineage patterns match "<situation description>"
lineage search "<term>"
```

### Query Graph

```bash
lineage graph query "<concept>"
lineage graph neighbors "<node-id>"
```

### Resume Session

```bash
lineage resume              # latest session
lineage resume <session-id> # specific session
```

## Integration by Project

### Neo (team decisions)

When a team completes a mission or makes a significant decision:

```bash
lineage remember "Team alpha chose Redis over Memcached for session cache" \
  --rationale "Need pub/sub for invalidation, Redis supports it natively" \
  --tags "neo,team-alpha,caching" \
  --type implementation
```

When spawning a team, check for relevant patterns:

```bash
lineage patterns match "team coordination"
lineage search "caching"
```

### Oracle (goal outcomes)

When a goal succeeds or fails:

```bash
lineage remember "Goal 'improve API latency' achieved - p95 dropped from 800ms to 200ms" \
  --rationale "Connection pooling and query optimization were the key wins" \
  --tags "oracle,performance,goal-outcome" \
  --type implementation

lineage journal update <dec-id> --outcome successful \
  --lesson "Connection pooling alone gave 60% of the improvement"
```

### Council (governance decisions)

When charter decisions are made or revised:

```bash
lineage remember "Critic seat gets veto power on security-related changes" \
  --rationale "Security review must not be overridden by velocity pressure" \
  --tags "council,governance,security" \
  --type process
```

### Monarch (cross-project patterns)

When a pattern emerges across projects:

```bash
lineage learn "Contract-first interfaces" \
  --context "Multi-project systems with independent evolution" \
  --solution "Define markdown contracts at boundaries before implementing" \
  --category architecture
```

## Conventions

- **Tags always include the source project name** (e.g., `neo`, `oracle`, `council`)
- **Decisions use the project's own terminology** in the decision text
- **Patterns include origin** so you can trace where a lesson came from
- **Session handoffs belong to the project that creates them** -- use `--tags` to namespace
- **Graph nodes can reference entities across projects** -- use full paths (e.g., `neo/state/agents/`)

## Data Locations

All data lives under `~/dev/lineage/`:

```
journal/data/decisions.jsonl   # Append-only decision log
graph/data/graph.json          # Knowledge graph (nodes + edges)
patterns/data/patterns.yaml    # Pattern and anti-pattern library
transfer/data/sessions/        # Session snapshots (one JSON per session)
```

## Non-Goals

- Lineage does not replace project-specific state (Neo's agent JSON, Oracle's goal YAML)
- Lineage does not enforce writes -- integration is opt-in
- Lineage does not provide real-time pub/sub -- it is a structured log, not a message bus
