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
opt-in via CLI or client library. Any project that calls `lore remember` or
`lore learn` becomes a writer. Any project that calls `lore resume` or
`lore search` becomes a reader. Lore neither knows nor cares who its consumers are.

## Data Flow

### Session Lifecycle

```text
1. lore resume          Load context from last session
2. lore goal list       See active goals
3. Work happens         Agents read patterns, make decisions
4. lore remember        Capture decisions with rationale
5. lore fail            Log failures with error type and context
6. lore learn           Capture patterns from experience
7. lore handoff         Snapshot state for next session
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

## Seven Components

Each component answers one question. Together they form institutional memory.

| Component   | Question                  | Format | Writers                      |
| ----------- | ------------------------- | ------ | ---------------------------- |
| `journal/`  | Why did we choose this?   | JSONL  | Any project via CLI          |
| `graph/`    | What relates to this?     | JSON   | Any project via CLI          |
| `patterns/` | What did we learn?        | YAML   | Any project via CLI          |
| `transfer/` | What's next?              | JSON   | Session handoff              |
| `inbox/`    | What did we notice?       | JSONL  | Observations from any source |
| `intent/`   | What are we trying to do? | YAML   | Goals, mission decomp        |
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
goals, missions, metadata).

## Contracts

Lore exposes one contract: `LORE_CONTRACT.md`.

| Interface | Example                             | Effect                             |
| --------- | ----------------------------------- | ---------------------------------- |
| Write     | `lore remember "X" --rationale "Y"` | Appends to journal                 |
| Write     | `lore learn "X" --context "Y"`      | Appends to patterns                |
| Write     | `lore observe "X"`                  | Appends to inbox                   |
| Write     | `lore fail NonZeroExit "msg"`       | Appends to failures                |
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
