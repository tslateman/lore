---
description: Infer and record decisions, patterns, and failures from the current session
allowed-tools: [Bash, Read, Grep]
---

Review this session and capture knowledge to Lore. Do not ask clarifying questions — infer from context.

## Step 1: Scan the Conversation

Identify captures in three categories:

**Decisions** — architectural or design choices with alternatives considered:

- "We chose X over Y because Z"
- "Let's use X for this"
- Technology, pattern, or approach selections

**Patterns** — reusable lessons learned:

- Techniques that worked well
- Gotchas or surprises worth remembering
- Workarounds for specific tools or environments

**Failures** — errors encountered and how they were resolved:

- Tool errors, build failures, test failures
- The root cause and fix (not just the symptom)

Skip anything already captured in a previous `/capture` or `/handoff` in this session. Skip trivial observations — only record what a future session would benefit from.

## Step 2: Present the Capture Plan

List what you intend to record in a brief summary:

```
Capturing to Lore:
  Decisions: [count]
    - [title 1]
    - [title 2]
  Patterns: [count]
    - [title 1]
  Failures: [count]
    - [title 1]
```

## Step 3: Execute

Run the appropriate commands for each item:

**Decisions:**

```bash
${CLAUDE_PLUGIN_ROOT}/lore.sh remember "<decision text>" \
  --rationale "<why>" \
  --alternatives "<what else was considered>" \
  --tags "<project>,<topic>" \
  --type <architecture|implementation|tooling|process>
```

**Patterns:**

```bash
${CLAUDE_PLUGIN_ROOT}/lore.sh learn "<pattern name>" \
  --context "<when this applies>" \
  --solution "<what to do>" \
  --problem "<what goes wrong without this>" \
  --category <bash|git|testing|architecture|general>
```

**Failures:**

```bash
${CLAUDE_PLUGIN_ROOT}/lore.sh fail "<ErrorType>" "<what happened and how it was fixed>"
```

## Step 4: Confirm

Output a count of what was recorded. Keep it to one line per item.

## Rules

- Be specific in titles — "Use full node path for nvm in non-interactive shells" not "Node.js issue"
- Rationale and context fields must be intelligible to someone with no session context
- One command per distinct insight — don't bundle unrelated items
- If nothing worth capturing happened, say so and stop
