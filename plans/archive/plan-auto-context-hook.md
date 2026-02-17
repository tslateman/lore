# Plan: Auto-Context Injection Hook

Status: Implemented
Completed: 2026-02-13

## Problem

Agents start cold. CLAUDE.md loads, but no project-specific decisions,
patterns, or failures arrive unless the agent runs `lore resume`. Context
should inject automatically, scoped to where the user is working.

## Hook API

Claude Code's `UserPromptSubmit` hook fires after the user submits a prompt,
before Claude processes it. The script receives JSON on stdin:

```json
{
  "session_id": "abc123",
  "prompt": "Why does the deploy script fail on staging?",
  "cwd": "/Users/tslater/dev/flow",
  "hook_event_name": "UserPromptSubmit"
}
```

The script returns JSON on stdout:

```json
{
  "hookSpecificOutput": {
    "additionalContext": "--- lore context ---\n..."
  }
}
```

The `additionalContext` string injects silently into Claude's context window.
Exit 0 with no output means "allow, inject nothing."

`UserPromptSubmit` does not support matchers -- it fires on every prompt.

## Design

One script. Detect the project from `cwd`, grep lore's data files for
matches, format results, emit JSON. No ranking, no synonyms, no config files.
Prove the concept before adding machinery.

### Project Detection

Strip the workspace root from `cwd`, take the first path segment:

```bash
LORE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKSPACE_ROOT="$(dirname "$LORE_ROOT")"
project="${cwd#$WORKSPACE_ROOT/}"   # flow/src -> flow/src
project="${project%%/*}"             # flow/src -> flow
```

If `cwd` is outside the workspace, inject nothing.

### What to Query

Three sources, in order. Each adds lines until the budget fills.

| Source   | Query                                  | Why                                    |
| -------- | -------------------------------------- | -------------------------------------- |
| patterns | grep project name + prompt keywords    | Direct "do this / avoid that" guidance |
| journal  | grep project name in decisions.jsonl   | Rationale prevents re-litigating       |
| transfer | latest session handoff for the project | Picks up where the last session ended  |

Not queried: registry (CLAUDE.md already covers it), graph (too structural),
inbox (low signal), intent (noise unless goal-related).

### Keyword Extraction

Split the prompt into words. Drop common stopwords (a, the, is, to, in, for,
of, on, it, do, be, has, was, are, with, that, this, from, not, but, what,
why, how, can, should, would, does). Lowercase the rest. Keep up to 8 terms.

No synonym expansion. If a keyword hits, great. If not, project-only matching
still returns useful context.

### Token Budget

- **Budget**: 1,500 characters (~375 tokens). Enough for 3-5 compact results.
- **Estimation**: `${#text}`. Characters, not tokens. Simple and conservative.
- **Overflow**: Stop adding results when the budget fills. No truncation of
  individual records -- either the whole record fits or it's dropped.

### Output Format

```
--- lore context (auto-injected, 3 items) ---

[pattern] Safe bash arithmetic (confidence: 0.9)
  Problem: ((x++)) returns exit code 1 when x is 0
  Solution: Use x=$((x + 1)) instead

[decision] dec-a1b2c3d4 (2026-02-10)
  Use JSONL for storage -- append-only, grep-friendly

[handoff] session-20260214 (2026-02-14)
  Auth implementation 80% complete, need OAuth integration

--- end lore context ---
```

Markers distinguish injected context from user input.

## Implementation

### Single File

```
hooks/
  inject-context.sh    # Entry point, registered as UserPromptSubmit hook
```

No lib/ directory, no config files, no synonym mappings. One script under 150
lines. If the script grows past 200 lines, decompose then.

### Hook Registration

In `~/.claude/settings.json`:

```json
{
  "hooks": {
    "UserPromptSubmit": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash ~/dev/lore/hooks/inject-context.sh",
            "timeout": 5
          }
        ]
      }
    ]
  }
}
```

5-second timeout. The script should finish in under 200ms (a few greps on
small files). The timeout catches edge cases.

### Script Outline

```bash
#!/usr/bin/env bash
set -euo pipefail

# Read JSON from stdin
input=$(cat)
cwd=$(echo "$input" | jq -r '.cwd // ""')
prompt=$(echo "$input" | jq -r '.prompt // ""')

# Derive project
LORE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKSPACE_ROOT="$(dirname "$LORE_ROOT")"
project="${cwd#$WORKSPACE_ROOT/}"
project="${project%%/*}"

# Bail if outside workspace or project is empty
[[ -z "$project" || "$project" == "$cwd" ]] && exit 0

# Extract keywords from prompt (drop stopwords)
keywords=$(extract_keywords "$prompt")

# Query sources, accumulate results within budget
results=""
budget=1500

results+=$(query_patterns "$project" "$keywords")
results+=$(query_journal "$project")
results+=$(query_transfer "$project")

# If nothing matched, exit silently
[[ -z "$results" ]] && exit 0

# Emit JSON
count=$(echo "$results" | grep -c '^\[')
jq -n --arg ctx "--- lore context (auto-injected, $count items) ---

$results
--- end lore context ---" \
  '{ hookSpecificOutput: { additionalContext: $ctx } }'
```

### Error Handling

- `jq` parse failure: exit 0
- No matching results: exit 0 (no noise)
- Data file missing: skip that source
- Any unexpected error: `trap 'exit 0' ERR` at top -- fail-silent

### Query Functions

**Patterns**: Parse `patterns.yaml` with yq, grep for project name or
keywords in name/context/problem/solution fields. Format matching patterns as
one-line summaries.

**Journal**: `grep -i "$project" decisions.jsonl`, take the 3 most recent
(tail -3), extract decision text with jq.

**Transfer**: Find the latest session file in `transfer/data/sessions/`,
extract the handoff message if it mentions the project.

## Testing

```bash
# Simulate a prompt from the flow project
echo '{"cwd":"/Users/tslater/dev/flow","prompt":"fix the deploy script","session_id":"test"}' \
  | bash hooks/inject-context.sh

# Should output JSON with additionalContext, or nothing if no matches

# Simulate outside workspace (should exit silently)
echo '{"cwd":"/tmp","prompt":"hello","session_id":"test"}' \
  | bash hooks/inject-context.sh

# Dry run: check timing
time echo '{"cwd":"/Users/tslater/dev/lore","prompt":"bash patterns","session_id":"test"}' \
  | bash hooks/inject-context.sh
```

## What This Doesn't Do (Yet)

Deferred until the basic hook proves useful:

- **Relevance ranking**: No scoring formula. Results appear in source order
  (patterns, journal, transfer). Ranking adds complexity for marginal gain at
  current data volumes (~55 journal entries, ~13 patterns).
- **Synonym expansion**: No `keyword-synonyms.yaml`. Keywords match literally.
- **SessionStart hook**: Could inject project-level orientation on session
  start. Separate concern, separate hook.
- **Metrics**: No injection stats, no tracking of whether context gets used.
- **Cache**: Queries are fast greps on small files. Caching adds complexity
  for <100ms operations.
- **`lore resume` retirement**: Once the hook is reliable, the manual `lore
resume` instruction in CLAUDE.md becomes redundant. Remove it then.

## Risks

| Risk                    | Mitigation                                                  |
| ----------------------- | ----------------------------------------------------------- |
| Stale context misleads  | Show timestamps; agents can verify                          |
| Latency exceeds timeout | 5s timeout; greps on <100 line files finish in milliseconds |
| Irrelevant context      | No results = no injection; project scoping filters noise    |
| Budget too small        | 1,500 chars fits 3-5 results; increase if needed            |
| Budget too large        | Crowds working memory; start small, expand if starved       |

## Outcome

Implemented as planned. `hooks/inject-context.sh` exists and is registered as the `UserPromptSubmit` hook in `~/.claude/settings.json`. The script derives project from `cwd`, queries patterns, journal, and transfer, and injects up to 1,500 characters of context into the prompt window. The hook uses grep-based queries rather than the FTS5 search index (noted as a known gap in project memory: "Hook and search index disconnected").
