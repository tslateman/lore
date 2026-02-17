# Plan: Spec-Driven Development Integration

Status: Implemented
Created: 2026-02-16
Completed: 2026-02-16
References: [github/spec-kit](https://github.com/github/spec-kit), [SDD methodology](https://github.com/github/spec-kit/blob/main/spec-driven.md)

## Context

GitHub's Spec Kit introduces **Spec-Driven Development (SDD)** — a four-phase
workflow where specifications become the source of truth:

```
/specify → /plan → /tasks → implement
```

Lore's role: **memory layer for SDD**. Not a replacement for spec-kit, but the
system that tracks _which specs are in flight, who's working on them, what they
decided, and what happened_. Specs are ephemeral artifacts in feature branches;
Lore captures the durable knowledge that survives after the branch merges.

### SDD Lifecycle vs Lore's Role

| SDD Phase     | Artifact            | Lore's Role                                     |
| ------------- | ------------------- | ----------------------------------------------- |
| **Specify**   | `spec.md`           | Import as goal, track in intent layer           |
| **Plan**      | `plan.md`           | Capture technical decisions to journal          |
| **Tasks**     | `tasks.md`          | Track assignment, progress via sessions         |
| **Implement** | Code                | Capture outcome when done                       |
| _Post-merge_  | _Artifacts deleted_ | **Lore retains**: decisions, patterns, failures |

### Gaps in Current Implementation

1. **No spec import** — Can't import external spec.md into Lore's intent layer
2. **No spec → session binding** — Can't track which session works which spec
3. **No plan decision capture** — Technical decisions in plan.md aren't journaled
4. **No outcome recording** — Completion/failure isn't written back to Lore
5. **No task progress tracking** — Session doesn't know current task context

## Design

### Spec Lifecycle in Lore

```
[External spec.md] ──import──→ [Goal] ──assign──→ [Session]
                                  │                    │
                                  │                 (work)
                                  │                    │
                                  ↓                    ↓
                           [Decisions]  ←──────── [Outcome]
                           [Patterns]              (journal)
                           [Failures]
```

**Key insight from SDD**: Specifications are the _stable what_, implementation
is the _flexible how_. Lore captures both:

- Intent layer: the stable _what_ (goals, success criteria)
- Journal: the _why_ behind technical choices (decisions from plan.md)
- Transfer: the _who_ and _when_ (session context, progress)

### Spec Storage: Snapshot, Not Reference

Spec-kit artifacts live in feature branches. When the branch merges or is
deleted, those files disappear. Lore must **snapshot key content at import
time** to preserve context for future sessions.

**What to store:**

- Structured data Lore needs (title, user stories, acceptance criteria)
- Original path as a hint (may not exist later)

**What NOT to store:**

- Full spec.md prose (too large, changes frequently)
- Implementation details from plan.md (captured as journal decisions instead)

This approach balances durability with avoiding duplication drift.

### Data Model Extensions

**Goal extension** (aligns with spec.md structure):

```yaml
id: goal-xxx
name: "Feature: Real-time chat"
description: |
  From spec.md summary section

# Map spec.md "User Scenarios" to success_criteria
success_criteria:
  - description: "User Story 1: Send messages"
    priority: P1
    status: pending # pending → in_progress → completed
    acceptance:
      - "Given connected, When send message, Then appears in 500ms"
  - description: "User Story 2: Message history"
    priority: P2
    status: pending

# SDD-specific fields
source:
  type: "spec-kit" # or "manual", "imported"
  path: "specs/003-chat/spec.md" # Original location (hint, may not exist)
  branch: "003-chat-system"
  imported_at: "2026-02-16T10:00:00Z"

  # Snapshot of key content at import time (survives branch deletion)
  snapshot:
    title: "Feature: Real-time chat"
    summary: "Real-time messaging with history and presence indicators"
    user_stories:
      - id: "US1"
        title: "Send messages"
        priority: P1
        acceptance:
          - "Given connected, When send, Then appears in 500ms"
      - id: "US2"
        title: "Message history"
        priority: P2
        acceptance:
          - "Given returning user, When open chat, Then see last 100 messages"

# Lifecycle tracking
lifecycle:
  phase: "specify" # specify → plan → tasks → implement → complete
  assigned_session: null
  assigned_at: null
  plan_decisions: [] # References to journal entries from plan.md

outcome:
  status: null # completed | failed | abandoned
  completed_at: null
  session_id: null
  journal_entry: null
```

**Session extension** (context for current work):

```json
{
  "context": {
    "spec": {
      "goal_id": "goal-xxx",
      "name": "Feature: Real-time chat",
      "branch": "003-chat-system",
      "phase": "tasks",
      "current_task": "T012"
    }
  }
}
```

## What to Do

### Phase 1: Core Lifecycle Commands

#### 1.1 `lore spec import <spec-file|spec-dir>`

Import spec.md (or full spec directory) as a goal.

```bash
# Import single spec
lore spec import specs/003-chat/spec.md

# Import full spec directory (spec.md + plan.md + tasks.md)
lore spec import specs/003-chat/
```

**Behavior:**

- Parse spec.md for title, user scenarios, acceptance criteria
- **Snapshot** structured data into `source.snapshot` (survives branch deletion)
- Map user scenarios to `success_criteria` with priorities
- Set `source.type = "spec-kit"`, `source.path`, `source.branch`, `source.imported_at`
- Set `lifecycle.phase = "specify"`
- If plan.md exists, extract key decisions → journal entries
- If tasks.md exists, set `lifecycle.phase = "tasks"`

#### 1.2 `lore spec assign <goal-id> [--session <id>]`

Bind a spec/goal to a session. Signals "I'm working on this."

```bash
lore spec assign goal-xxx
```

**Behavior:**

- Update goal: `lifecycle.assigned_session`, `lifecycle.assigned_at`
- Update goal: `lifecycle.phase = "implement"` (or current phase)
- Update session: add `context.spec` block
- If goal already assigned to different session, warn and confirm

#### 1.3 `lore spec progress <goal-id> [--phase <phase>] [--task <task-id>]`

Update progress on a spec.

```bash
# Advance phase
lore spec progress goal-xxx --phase tasks

# Track current task
lore spec progress goal-xxx --task T015

# Mark a success criterion complete
lore spec progress goal-xxx --criterion 1 --status completed
```

#### 1.4 `lore spec complete <goal-id> [--status <status>] [--notes "..."]`

Record outcome and close the loop.

```bash
lore spec complete goal-xxx --status completed --notes "PR #123 merged"
lore spec complete goal-xxx --status failed --notes "Blocked by dependency X"
```

**Behavior:**

- Update goal: `outcome.status`, `outcome.completed_at`, `outcome.session_id`
- Write journal entry with outcome, link to goal
- Update session: clear `context.spec`
- Optionally prompt to capture patterns learned

#### 1.5 `lore spec capture-decisions <plan-file> <goal-id>`

Extract technical decisions from plan.md and journal them.

```bash
lore spec capture-decisions specs/003-chat/plan.md goal-xxx
```

**Behavior:**

- Parse plan.md for key decisions (technology choices, architecture, tradeoffs)
- Write each as journal entry with `tags: spec:goal-xxx,plan-decision`
- Update goal: add references to `lifecycle.plan_decisions[]`

### Phase 2: Enhanced Resume

#### 2.1 Show active spec on resume

```bash
lore resume
# Output includes:
# --- Active Spec ---
# Goal: goal-xxx
# Branch: 003-chat-system
# Phase: tasks
# Current Task: T012 [US1] Create Message model
#
# Success Criteria:
#   [✓] US1: Send messages (P1)
#   [ ] US2: Message history (P2)
```

#### 2.2 Show spec decisions on resume

When resuming a session with an assigned spec, show related journal entries:

```bash
# --- Decisions for This Spec ---
# - Use WebSocket for real-time (not SSE) — lower latency requirement
# - PostgreSQL for history (not Redis) — need durability
```

### Phase 3: MCP Integration

#### 3.1 `lore_spec_list` — List specs in various states

```typescript
{
  name: "lore_spec_list",
  description: "List specs by phase or assignment status",
  inputSchema: {
    filter: {
      type: "string",
      enum: ["active", "assigned", "unassigned", "completed"],
      description: "Filter specs by status"
    }
  }
}
```

#### 3.2 `lore_spec_context` — Get full context for assigned spec

```typescript
{
  name: "lore_spec_context",
  description: "Get spec details, decisions, and progress for delegation",
  inputSchema: {
    goal_id: { type: "string", description: "Goal ID" }
  }
}
// Returns: spec details, related decisions, current phase/task, patterns
```

#### 3.3 `lore_spec_assign` — Assign spec to session

```typescript
{
  name: "lore_spec_assign",
  description: "Assign a spec/goal to the current session",
  inputSchema: {
    goal_id: { type: "string" }
  }
}
```

#### 3.4 `lore_spec_progress` — Update progress

```typescript
{
  name: "lore_spec_progress",
  description: "Update spec phase or current task",
  inputSchema: {
    goal_id: { type: "string" },
    phase: { type: "string", enum: ["specify", "plan", "tasks", "implement"] },
    task_id: { type: "string" }
  }
}
```

#### 3.5 `lore_spec_complete` — Record outcome

```typescript
{
  name: "lore_spec_complete",
  description: "Mark spec complete and record outcome",
  inputSchema: {
    goal_id: { type: "string" },
    status: { type: "string", enum: ["completed", "failed", "abandoned"] },
    notes: { type: "string" }
  }
}
```

## What NOT to Do

- **Don't replace spec-kit** — Lore is memory, not workflow
- **Don't store full spec.md prose** — Snapshot structured data only
- **Don't auto-advance phases** — Explicit is better than implicit
- **Don't enforce SDD** — Support it, but don't require it
- **Don't modify spec files** — Lore reads, it doesn't write to spec-kit artifacts
- **Don't rely on path existing** — Branch may be deleted after merge

## Files to Create/Modify

| File                     | Action | Change                          |
| ------------------------ | ------ | ------------------------------- |
| `intent/lib/spec.sh`     | Create | New spec subcommand library     |
| `intent/intent.sh`       | Modify | Wire `spec` subcommand          |
| `lore.sh`                | Modify | Add `lore spec` command routing |
| `transfer/lib/resume.sh` | Modify | Show active spec context        |
| `mcp/src/index.ts`       | Modify | Add 5 new MCP tools             |

## Acceptance Criteria

### Phase 1: Core Commands

- [ ] `lore spec import <spec.md>` creates goal with success_criteria mapped
- [ ] `lore spec import <spec-dir>` handles full spec directory
- [ ] `lore spec assign <goal-id>` binds to session, updates both
- [ ] `lore spec progress` updates phase and task tracking
- [ ] `lore spec complete` records outcome, writes journal entry
- [ ] `lore spec capture-decisions` extracts plan.md → journal

### Phase 2: Resume Enhancement

- [ ] `lore resume` shows active spec with phase and progress
- [ ] `lore resume` shows related decisions for active spec

### Phase 3: MCP Tools

- [ ] All 5 MCP tools functional
- [ ] Agent can list, assign, progress, complete specs via MCP

## Testing

```bash
# Phase 1: Core workflow
mkdir -p /tmp/test-spec && cat > /tmp/test-spec/spec.md << 'EOF'
# Feature Specification: Test Feature
**Feature Branch**: `001-test-feature`
**Status**: Draft

## User Scenarios & Testing

### User Story 1 - Basic Function (Priority: P1)
User can do the basic thing.

**Acceptance Scenarios**:
1. **Given** setup, **When** action, **Then** result
EOF

# Import
lore spec import /tmp/test-spec/spec.md
# → Creates goal-xxx

# Assign
lore spec assign goal-xxx
lore resume | grep "Active Spec"

# Progress
lore spec progress goal-xxx --phase tasks
lore spec progress goal-xxx --task T001

# Complete
lore spec complete goal-xxx --status completed --notes "Done"
lore search "goal-xxx"
```

## Dependencies

| Dependency          | Status   | Notes                        |
| ------------------- | -------- | ---------------------------- |
| Intent layer        | Complete | Goals, missions, export      |
| Transfer layer      | Complete | Sessions, resume             |
| MCP server          | Complete | lore_spec exists             |
| yq                  | Required | YAML processing              |
| spec-kit (optional) | External | Not required, but integrates |

## Future Work (Out of Scope)

1. **Webhook integration** — Auto-import on branch creation, outcome on PR merge (goal `goal-1771254688-cc3114e2`)
2. **Task file parsing** — Parse tasks.md and track individual task completion
3. **Multi-agent specs** — One spec decomposed across multiple sessions
4. **Spec templates** — `lore spec init` to create spec-kit structure
5. **Constitution support** — Store project constitution in Lore, reference in specs

## Outcome

Implemented in full across all three phases. `intent/lib/spec.sh` contains `spec_import`, `spec_assign`, `spec_progress`, and `spec_complete`. All five MCP tools (`lore_spec_list`, `lore_spec_context`, `lore_spec_assign`, `lore_spec_progress`, `lore_spec_complete`) exist in `mcp/src/index.ts`. The `lore resume` enhancement to show active spec context was also implemented. The `lore spec capture-decisions` command was not explicitly exposed in the CLI help, though the import flow captures plan decisions at import time.
