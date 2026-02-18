---
description: Record a journal entry inferred from conversation context
allowed-tools: [Bash, Read, Grep]
---

Record a journal entry to Lore. Infer the entry details from conversation context. Do not ask clarifying questions unless the type is genuinely ambiguous.

## Step 1: Determine Entry Type

Scan recent conversation for the most significant unrecorded item:

- **decision** — a choice was made between alternatives
- **discovery** — something was learned that wasn't known before
- **incident** — something broke or a significant obstacle was hit

Pick one. If the user said `/journal` after discussing a specific topic, that topic is the entry.

## Step 2: Compose the Entry

Infer these fields from context:

- **type**: decision, discovery, or incident
- **project**: the project being discussed (check `~/dev/mani.yaml` for valid names)
- **title**: ≤120 chars, specific and actionable
- **body**: the substance — what happened, why it matters, alternatives if a decision
- **tags**: comma-separated, include project name and topic area

Follow Strunk's style in the body: active voice, omit needless words, be concrete. Write for a stranger who has no session context.

## Step 3: Execute

```bash
${CLAUDE_PLUGIN_ROOT}/lore.sh journal add \
  --type <type> \
  --project <project> \
  --title "<title>" \
  --body "<body>" \
  --tags "<tags>"
```

## Step 4: Confirm

Show what was recorded:

```
Recorded [type] to journal:
  [title]
  Project: [project]
  Tags: [tags]
```
