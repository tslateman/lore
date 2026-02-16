Status: Superseded (Lineage absorbed into Lore; handoff paths now under `~/dev/lore/`)

# Plan: Wire `lineage handoff` into Session End

## Context

`lineage handoff` is implemented in `transfer/lib/handoff.sh`. The
`lineage_handoff()` function exists in `lineage-client-base.sh`. Neither is
called by any project. The Transfer component -- the Mentor's domain -- has zero
active callers.

Handoff captures what the next session needs: summary, next steps, blockers,
open questions. Without it, each session starts cold.

**Source:** Council Feedback Loop initiative, suggested step #2.
See `~/dev/council/initiatives/feedback-loop.md`.

## What to Do

### 1. Add handoff to Council's pre-commit hook

**File:** `~/dev/council/hooks/pre-commit`

Council's pre-commit hook already sources `lib/lineage-client.sh` and records
ADR/initiative changes. Extend it to create a handoff note summarizing what
changed in this commit.

The handoff should capture:

- Which seat directories were modified (from `git diff --cached --name-only`)
- Which initiatives were touched
- A one-line summary derived from the commit message (available via
  `git log -1 --format=%s` after commit, but pre-commit runs before -- use
  staged file names as summary instead)

```bash
# After existing ADR/initiative recording:
local changed_seats changed_initiatives
changed_seats=$(git diff --cached --name-only | grep -oE '^(critic|marshal|mainstay|ambassador|wayfinder|mentor)' | sort -u | paste -sd, -)
changed_initiatives=$(git diff --cached --name-only | grep '^initiatives/' | sed 's|initiatives/||;s|\.md||' | paste -sd, -)

if [[ -n "$changed_seats" || -n "$changed_initiatives" ]]; then
    local summary="Council changes: seats=[${changed_seats:-none}] initiatives=[${changed_initiatives:-none}]"
    lineage_handoff "$summary" 2>/dev/null || true
fi
```

### 2. Add handoff convenience to lineage-client-base.sh

The base library already has `lineage_handoff()`. Verify it works with a simple
message:

```bash
source ~/dev/lineage/lib/lineage-client-base.sh
lineage_handoff "Test handoff from council session"
```

### 3. Document the handoff convention

**File:** `~/dev/lineage/CLAUDE.md`

Add to the Quick Start section:

```bash
# End a session (capture context for next time)
./lineage.sh handoff "Finished X, next steps: Y, blocked on Z"
```

## What NOT to Do

- Do not add handoff to every project's pre-commit hook -- start with Council
  only, expand after validating value
- Do not build a SessionEnd hook yet -- pre-commit is the natural trigger for
  Council since work lands as commits
- Do not auto-generate handoff summaries from git diff -- keep it simple,
  use staged file names as context

## Files to Modify

| File                             | Change                               |
| -------------------------------- | ------------------------------------ |
| `~/dev/council/hooks/pre-commit` | Add handoff call after ADR recording |
| `~/dev/lineage/CLAUDE.md`        | Add handoff to Quick Start           |

## Acceptance Criteria

- [ ] Council commits generate handoff notes in Lineage
- [ ] `lineage resume` shows the handoff from the previous Council commit
- [ ] Handoff note includes which seats and initiatives were touched
- [ ] Handoff fails silently if Lineage is unavailable
- [ ] `lineage handoff` documented in CLAUDE.md Quick Start

## Testing

```bash
# From council directory, after staging changes:
cd ~/dev/council
# Simulate what the hook does:
source lib/lineage-client.sh
lineage_handoff "Test: seats=[critic,marshal] initiatives=[feedback-loop]"

# Verify it landed:
~/dev/lineage/lineage.sh resume
```
