# Tutorial: Your First Lore Session

This tutorial walks through one complete session cycle: resuming context, capturing knowledge, and handing off to the next session. By the end, you'll have working muscle memory of the core lifecycle.

**Time:** 15 minutes

## Prerequisites

Verify Lore is installed:

```bash
lore --help
```

You should see the command list. If not, see the [README](../README.md) for installation.

## Start a Session

Every session begins with `resume`. This loads context from the previous session—what was done, what's next, what's blocked.

```bash
lore resume
```

If this is your first session, you'll see minimal output. That's fine—there's no history yet.

If there's prior history, you'll see:

- **What was accomplished** — goals addressed, decisions made
- **Patterns learned** — lessons captured from previous work
- **Handoff notes** — next steps, blockers, open questions
- **Forked session ID** — your new session that inherits this context

**Key point:** Resume creates a *new* session. The parent session stays immutable. Your work writes to the forked session, not the historical record.

## Capture a Decision

You've made a technical decision. Record it with rationale so future sessions know *why*, not just *what*.

```bash
lore remember "Use PostgreSQL for user data" --rationale "Need ACID transactions, team has Postgres experience"
```

The decision goes into the journal. Later, `lore search "database"` will find it.

**With alternatives:**

```bash
lore remember "Use REST over GraphQL" \
  --rationale "Simpler caching, team unfamiliar with GraphQL" \
  --alternatives "GraphQL (rejected: learning curve), gRPC (rejected: browser support)"
```

Recording rejected alternatives prevents revisiting settled decisions.

## Capture a Pattern

You've learned something reusable—a technique, a gotcha, a best practice. Capture it as a pattern.

```bash
lore learn "Retry with exponential backoff" \
  --context "Calling external APIs that rate-limit" \
  --solution "Base delay 100ms, multiply by 2 each retry, max 5 retries"
```

Patterns surface during future `resume` calls when the context matches.

**Anti-patterns work too:**

```bash
lore learn "Don't catch generic exceptions" \
  --context "Error handling in Python" \
  --solution "Catch specific exception types; generic catches hide bugs" \
  --category anti-pattern
```

## Log a Failure

Something went wrong. Record it so recurring failures surface patterns.

```bash
lore fail ToolError "Permission denied writing to /etc/hosts"
```

Error types: `Timeout`, `NonZeroExit`, `UserDeny`, `ToolError`, `LogicError`

When the same error type recurs three times, `lore triggers` surfaces it—the Rule of Three. Recurring failures become patterns worth solving.

## Search Your Knowledge

Find what you've captured:

```bash
lore search "database"
```

This searches across all components—journal, patterns, sessions, graph.

**Smart search** (auto-selects semantic when Ollama is available):

```bash
lore search "retry logic" --smart
```

Semantic search finds conceptually related content even without keyword matches.

## End the Session

Before ending, capture handoff notes for the next session:

```bash
lore handoff "Implemented user auth, need to add OAuth integration next. Blocked on API credentials from infra team."
```

Or capture structured handoff:

```bash
lore transfer handoff "Auth 80% complete" \
  --next "Add OAuth integration" \
  --next "Write auth tests" \
  --blocker "Waiting on API credentials" \
  --question "Should we support SAML?"
```

The handoff becomes the starting context for whoever resumes next.

## Resume Later

Next session, run `resume` again:

```bash
lore resume
```

You'll see:

- The parent session's summary and accomplishments
- Inherited handoff notes (next steps, blockers, questions)
- Relevant patterns matched to the context
- Your new forked session ID

The cycle continues. Context compounds instead of evaporating.

## The Lifecycle

```
┌─────────────────────────────────────────────────┐
│                                                 │
│  ┌──────────┐                                   │
│  │  resume  │ ◄─── Load context from parent     │
│  └────┬─────┘                                   │
│       │                                         │
│       ▼                                         │
│  ┌──────────┐                                   │
│  │   work   │ ◄─── Your actual task             │
│  └────┬─────┘                                   │
│       │                                         │
│       ▼                                         │
│  ┌──────────┐                                   │
│  │ capture  │ ◄─── remember, learn, fail        │
│  └────┬─────┘                                   │
│       │                                         │
│       ▼                                         │
│  ┌──────────┐                                   │
│  │ handoff  │ ◄─── Context for next session     │
│  └────┬─────┘                                   │
│       │                                         │
│       └─────────────────────────────────────────┘
```

Every session follows this pattern. The specific work varies; the lifecycle stays constant.

## Next Steps

- **Full command reference:** Run `lore --help` or see [README.md](../README.md)
- **Architecture overview:** See [SYSTEM.md](../SYSTEM.md) for how components connect
- **MCP integration:** See [README.md MCP section](../README.md#mcp-server) for AI agent setup
- **Advanced search:** Try `--graph-depth 2` to follow knowledge graph relationships
