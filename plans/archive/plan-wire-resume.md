Status: Superseded (Lineage absorbed into Lore; `lore.sh resume` replaces `lineage.sh resume`)

# Plan: Wire `lineage resume` with Pattern Suggestions

## Context

`lineage resume` exists and works. `lineage_suggest_patterns` exists and works.
Nobody calls either at session start. SYSTEM.md documents `lineage resume` as
the session entry point, but no project, hook, or convention triggers it.

This plan closes the read loop. Lineage becomes read-write instead of
write-only.

**Source:** Council Feedback Loop initiative, Phase 2a.
See `~/dev/council/initiatives/feedback-loop.md`.

## What to Do

### 1. Enhance `lineage resume` to include pattern suggestions

**File:** `transfer/lib/resume.sh`

In `resume_session()`, after the "Related Lineage Entries" section (~line 177),
add a "Relevant Patterns" section that calls `patterns/patterns.sh suggest` with
context derived from the session's project or tags.

```bash
# --- Relevant Patterns ---
echo "--- Relevant Patterns ---"
local project
project=$(jq -r '.context.project // ""' "${session_file}")
if [[ -n "${project}" ]]; then
    "$LINEAGE_DIR/patterns/patterns.sh" suggest "${project}" --limit 5 2>/dev/null
fi
# Also suggest based on open thread keywords
local threads
threads=$(jq -r '.open_threads[]' "${session_file}" 2>/dev/null | head -3)
if [[ -n "${threads}" ]]; then
    echo "${threads}" | while read -r thread; do
        "$LINEAGE_DIR/patterns/patterns.sh" suggest "${thread}" --limit 2 2>/dev/null
    done
fi
```

Also add pattern suggestions to `resume_latest()` for the no-argument case.

Filter by both recency and relevance (patterns with higher confidence and more
recent validations rank first). The suggest command already handles relevance
scoring -- verify it also considers recency.

### 2. Enhance `lineage resume` for the "no previous session" case

When no session exists, `lineage resume` should still output useful context:
suggest patterns for the current working directory's project name.

```bash
# In resume_latest(), when no sessions found:
echo "No previous sessions. Showing patterns for current project."
local project_name
project_name=$(basename "$(git rev-parse --show-toplevel 2>/dev/null || pwd)")
"$LINEAGE_DIR/patterns/patterns.sh" suggest "${project_name}" --limit 5 2>/dev/null
```

### 3. Add `lineage resume` to global CLAUDE.md

**File:** `~/.claude/CLAUDE.md`

Add to the top of the file, before other instructions:

```markdown
## Session Start

Run `~/dev/lineage/lineage.sh resume` at session start to inherit context and
patterns from previous work.
```

This makes the convention visible to every agent session until a hook automates
it.

## What NOT to Do

- Do not add a SessionStart hook yet -- convention first, automation later
- Do not modify `lineage-client-base.sh` -- resume is a CLI command, not a
  library function for other projects
- Do not add `--verbose` mode yet -- that's Phase 2b
- Do not integrate with Flow -- that's Phase 2c (deferred)

## Files to Modify

| File                     | Change                         |
| ------------------------ | ------------------------------ |
| `transfer/lib/resume.sh` | Add pattern suggestion section |
| `~/.claude/CLAUDE.md`    | Add session start convention   |

## Acceptance Criteria

- [ ] `lineage resume` outputs relevant patterns after session context
- [ ] Pattern output is concise (under 10 lines for typical projects)
- [ ] Projects with no matching patterns show nothing (no noise)
- [ ] `lineage resume` with no previous session still suggests patterns
- [ ] Pattern suggestions include confidence scores
- [ ] Running `lineage resume` from ~/dev/council shows council-relevant patterns

## Testing

```bash
# From lineage directory
./lineage.sh resume

# From a project directory with no session
cd ~/dev/council && ~/dev/lineage/lineage.sh resume

# Verify pattern output
./lineage.sh resume 2>&1 | grep -A5 "Relevant Patterns"
```
