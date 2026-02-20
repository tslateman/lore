# System Architecture

Lore is the data layer. Everything the stack remembers passes through here.

## The Stack

```text
              reads            writes
         ┌──────────┐    ┌──────────┐
         ▼          │    ▼          │
     +--------+  +--------+  +--------+
     |consumer|  |  Lore  |  |consumer|
     | (read) |  | (data) |  | (write)|
     +--------+  +--------+  +--------+
                  ▲      ▲
                  │      │
              +--------+--------+
              |consumer|consumer|
              | (both) | (both) |
              +--------+--------+
```

Lore sits at the center -- projects read from it and write to it. Integration is
opt-in via CLI or client library. Any project that calls `lore capture` becomes
a writer. Any project that calls `lore resume` or `lore search` becomes a reader.
Lore neither knows nor cares who its consumers are.

## Data Flow

### Session Lifecycle

```text
1. lore resume          Load context from last session
2. lore goal list       See active goals
3. Work happens         Agents read patterns, make decisions
4. lore capture         Record knowledge (type inferred from flags)
5. lore handoff         Snapshot state for next session
```

### The Compounding Loop

Operational data becomes architectural decisions:

```text
failures/ ──→ triggers (Rule of Three) ──→ patterns/ ──→ sessions
    ↑                                           │
    └───────── work produces failures ──────────┘
```

When an error type recurs three times, failure analysis surfaces it. The pattern
gets recorded. Future sessions receive that pattern at resume. The system learns.

### Type-Level Graph

The graph's node types and edge types encode three cycles:

```text
         ┌──────── informs ────────┐
         ▼                         │
     decision ───yields──▶ pattern ┘
         │                    │
    references           implements
         │                    │
         ▼                    ▼
       file              concept
         │                    │
      part_of             grounds
         │                    │
         ▼        hosts       ▼
      project ──────────▶ session
                             │
                          produces
                             │
                             ▼
                          decision
```

**Learning loop:** decision → pattern → decision. Choices reveal patterns;
patterns inform future choices.

**Abstraction loop:** decision → pattern → concept → decision. Choices become
patterns, patterns crystallize into concepts, concepts frame future choices.

**Work loop:** project → session → decision → file → project. Projects host
sessions, sessions produce decisions, decisions change files, files belong to
projects.

`lesson` is a waypoint on the session → pattern edge -- a learned insight that
hasn't generalized into a reusable pattern yet.

`concept` has no write command. `remember` writes decisions, `learn` writes
patterns, but nothing promotes a pattern to a concept. Concepts enter the graph
only through manual `graph add concept`.

`goal` and `observation` sit outside the three core cycles. Goals connect to
projects via `relates_to` edges. Observations connect to decisions and patterns
they reference. Both sync to the graph on write.

## Memory Taxonomy

The graph's node types encode a memory taxonomy drawn from cognitive science.

| Memory Layer   | Node Types                         | Components                     | Coverage                     |
| -------------- | ---------------------------------- | ------------------------------ | ---------------------------- |
| **Episodic**   | decision, session, failure, lesson | journal/, transfer/, failures/ | What happened                |
| **Semantic**   | pattern, concept                   | patterns/                      | What we learned              |
| **Strategic**  | goal                               | intent/                        | What we're trying to achieve |
| **Structural** | project, file                      | registry/                      | What exists                  |
| **Staging**    | observation                        | inbox/                         | What we noticed              |

Infrastructure components (graph/, registry/) provide projection and metadata
but are not memory stores.

`concept` nodes require manual creation via `graph add concept`. They represent
higher-order abstractions that need human judgment to identify.

`lesson` nodes are created automatically when decisions have `lesson_learned`
fields. They are waypoints between episodic events and semantic patterns.

## Eight Components

Each component answers one question. Together they form institutional memory.

| Component   | Question                  | Format | Writers                      |
| ----------- | ------------------------- | ------ | ---------------------------- |
| `journal/`  | Why did we choose this?   | JSONL  | Any project via CLI          |
| `graph/`    | What relates to this?     | JSON   | Derived (rebuildable)        |
| `patterns/` | What did we learn?        | YAML   | Any project via CLI          |
| `transfer/` | What's next?              | JSON   | Session handoff              |
| `inbox/`    | What did we notice?       | JSONL  | Observations from any source |
| `intent/`   | What are we trying to do? | YAML   | Goals, specs                 |
| `failures/` | What went wrong?          | JSONL  | Any project via CLI          |
| `registry/` | What exists?              | YAML   | Project metadata             |

### Storage Conventions

All data lives under `data/` within each component. All logic lives under
`lib/`. Component shell scripts sit at the component root.

```text
component/
  component.sh       # CLI entry point (optional)
  lib/
    component.sh     # Functions
  data/
    *.jsonl          # Append-only logs
    *.json           # Structured documents
    *.yaml           # Registries and config
```

JSONL for append-only logs (journal, inbox, failures). JSON for structured
documents (graph, sessions). YAML for human-maintained registries (patterns,
goals, metadata).

### Graph as Derived Projection

The graph is not a primary data store. It is a projection derived from journal
decisions, patterns, failures, sessions, projects, goals, and observations. Flat
files are the source of truth.
The graph can be rebuilt from scratch at any time:

```bash
lore graph rebuild
```

Each write command (`remember`, `learn`, `fail`, `handoff`, `goal create`,
`observe`) syncs its record type to the graph in the background. `rebuild` runs
all seven syncs (decisions, patterns, failures, sessions, projects, goals,
observations) against an empty graph, normalizes edge spelling, and deduplicates
edges.

When `LORE_DATA_DIR` is set (default after `install.sh`: `~/.local/share/lore`), component `data/` directories live at that external path instead of inside the repo. Path resolution is centralized in `lib/paths.sh`.

## Contracts

Lore exposes one contract: `LORE_CONTRACT.md`.

| Interface | Example                             | Effect                             |
| --------- | ----------------------------------- | ---------------------------------- |
| Write     | `lore remember "X" --rationale "Y"` | Appends to journal                 |
| Write     | `lore learn "X" --context "Y"`      | Appends to patterns                |
| Write     | `lore fail NonZeroExit "msg"`       | Appends to failures                |
| Write     | `lore observe "X"`                  | Appends to inbox                   |
| Write     | `lore goal create "X"`              | Creates goal YAML                  |
| Read      | `lore search "X"`                   | Searches all components            |
| Read      | `lore resume`                       | Loads last session context         |
| Read      | `lore failures --type X`            | Queries failure reports            |
| Read      | `lore triggers`                     | Recurring failures (Rule of Three) |
| Read      | `lore registry context <project>`   | Assembles project context          |

Tags always include the source project name. Decisions from a team orchestrator
include its project tag. Governance decisions include theirs. This makes
cross-project queries possible: search by tag to see all decisions a project
contributed.

## Session Entry

```bash
lore resume
```

This is the first command in every session. It loads:

1. The last session's handoff notes (what was in progress, what's next)
2. Recent decisions (last 10)
3. Relevant patterns (matched to current project)
4. Open goals and their completion status

An agent that skips `lore resume` starts cold. An agent that runs it inherits
the full context of previous work.

## What Lore Is Not

Lore is not a runtime. It does not execute work, manage teams, or dispatch
tasks. Other projects handle control and execution. Lore holds the memory that
makes their work compound instead of repeat.

Lore is not a message bus. Writes are synchronous CLI calls. There is no pub/sub,
no event stream, no real-time notification. Projects write when they have
something to record and read when they need context.

---

_"Runtimes remember state. Lore remembers lessons."_
