---
description: Record session handoff to Lore with structured context for the next session
allowed-tools: [Bash, Read, Grep]
---

Summarize this session's work into a single `lore handoff` command. Do not ask clarifying questions — infer from context.

## Step 1: Gather Context

Review the conversation to identify:

- **What was accomplished** (commits, features, fixes, decisions)
- **Next steps** (what should happen next, in priority order)
- **Blockers** (anything preventing progress, or "none")

## Step 2: Compose Handoff Message

Write a single dense paragraph covering all three areas. Follow Strunk's style:

- Active voice, positive form
- Omit needless words
- Be definite, specific, concrete
- Name files, commands, and components — not vague summaries

## Step 3: Run the Command

```bash
./lore.sh handoff "<message>"
```

## Step 4: Confirm

Output a brief confirmation showing what was recorded.
