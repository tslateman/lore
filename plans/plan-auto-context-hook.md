# Plan: Auto-Context Injection via UserPromptSubmit Hook

Status: Proposed

## Problem

Agents start cold. Each session begins with CLAUDE.md and whatever the user
types -- no awareness of relevant decisions, patterns, or failures already
captured in lore. The `lore resume` instruction in CLAUDE.md helps, but only
if the agent runs it and only if the user remembers to ask. Context should
arrive automatically, scoped to the user's actual question.

## Prior Art

[claude-mem](https://github.com/thedotmack/claude-mem) solved this for
general-purpose memory: a `UserPromptSubmit` hook captures every prompt,
stores it in SQLite, then injects recent context via
`hookSpecificOutput.additionalContext` on subsequent sessions. Their approach
prioritizes recency over relevance and uses progressive disclosure (an index
of summaries, not full records).

Lore's advantage: structured, typed data. Decisions carry rationale. Patterns
carry solutions. Failures carry error types. We can rank by _kind_, not just
timestamp.

## Mechanism

### Hook Event

`UserPromptSubmit` -- fires after the user submits a prompt, before Claude
processes it. The hook script receives JSON on stdin:

```json
{
  "session_id": "abc123",
  "user_prompt": "Why does the deploy script fail on staging?",
  "cwd": "/Users/tslater/dev/flow",
  "hook_event_name": "UserPromptSubmit"
}
```

The script returns JSON on stdout. The key field is
`hookSpecificOutput.additionalContext`, a string injected silently into
Claude's context window without displaying to the user.

### Integration Point

A command hook in lore's settings or as a plugin hook:

```json
{
  "UserPromptSubmit": [
    {
      "matcher": "*",
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
```

The 5-second timeout keeps the hook fast. If lore is unavailable, the script
exits 0 with no output -- fail-silent, consistent with lore's integration
philosophy.

## What to Inject

### Sources (Priority Order)

| Priority | Source   | Data                                                | Why                                      |
| -------- | -------- | --------------------------------------------------- | ---------------------------------------- |
| 1        | patterns | Scored patterns matching keywords                   | Direct "do this / avoid that" guidance   |
| 2        | journal  | Recent decisions mentioning the project or keywords | Rationale prevents re-litigating choices |
| 3        | failures | Recent failures for the project/tool                | Prevents repeating known mistakes        |
| 4        | transfer | Latest handoff note for the project                 | Picks up where the last session left off |
| 5        | registry | Project metadata (role, contracts, deps)            | Orients the agent in the ecosystem       |
| 6        | inbox    | Raw observations tagged with the project            | Low-signal but sometimes useful          |

### Not Injected

- **Graph**: Too structural for prompt-level context. Better served by
  explicit `lore graph query` calls.
- **Intent (goals/missions)**: Injected only if the prompt mentions a
  goal-related keyword ("goal", "mission", "milestone"). Otherwise noise.

## Keyword Extraction

Simple and fast -- no NLP library, no external service:

1. **Project detection**: Derive project name from `$cwd`. Strip the
   workspace root (`~/dev/`) and take the first path segment. If `cwd` is
   `/Users/tslater/dev/flow/src`, project = `flow`.

2. **Keyword extraction**: Split the user's prompt into words. Remove
   stopwords (a, the, is, to, ...). Lowercase the remainder. Keep 5-10
   significant terms.

3. **Compound matching**: Some keywords map to lore tags:
   - `deploy` -> search tags `deploy`, `ci`, `pipeline`
   - `test` -> search tags `test`, `testing`, `ci`
   - `auth` -> search tags `auth`, `authentication`, `security`

   This mapping lives in a small config file
   (`hooks/keyword-synonyms.yaml`), editable without code changes.

### Why Not an LLM for Keyword Extraction?

A prompt-based hook could extract keywords with better semantic
understanding, but it adds 1-3 seconds of latency and costs a model call per
prompt. The keyword approach runs in <100ms, covers the common case, and
degrades gracefully to project-only matching when no keywords hit. If keyword
quality proves insufficient, a prompt-based hook can replace step 2 later.

## Relevance Ranking

Each candidate result gets a score:

```
score = source_weight * recency_factor * match_strength
```

- **source_weight**: patterns=1.0, journal=0.9, failures=0.8, transfer=0.7,
  registry=0.6, inbox=0.3
- **recency_factor**: `1.0 / (1 + days_since_created / 30)` -- recent items
  score higher, old items decay toward 0 but never vanish
- **match_strength**: `keyword_matches / total_keywords` -- what fraction of
  extracted keywords appear in the record's text/tags

Results below a threshold (e.g., score < 0.1) are dropped. The top N results
(governed by the token budget) are kept.

## Token Budgeting

The injected context must fit in a fixed budget to avoid crowding the
agent's working memory.

### Budget Allocation

- **Total budget**: 2,000 tokens (configurable via
  `LORE_CONTEXT_BUDGET` env var)
- **Header/framing**: ~100 tokens (section markers, attribution)
- **Content**: ~1,900 tokens for actual records

### Estimation

Use a simple heuristic: **1 token ~ 4 characters** (conservative for
English). Each candidate record is measured by `${#text} / 4`. Records are
added in score order until the budget fills. The last record that would
exceed the budget is truncated or dropped.

### Format

The injected string uses a compact, scannable format:

```
--- Lore Context (auto-injected, 3 items) ---

[pattern] Safe bash arithmetic (confidence: 0.9)
  Context: set -e scripts
  Solution: Use x=$((x+1)) not x=$(expr $x + 1)

[decision] dec-a1b2c3d4 (2026-02-10)
  Use JSONL for storage -- append-only, simple, grep-friendly

[failure] fail-e5f6 (2026-02-14, tool: Bash)
  NonZeroExit: deploy.sh fails when DEPLOY_ENV unset

--- end lore context ---
```

Markers (`--- Lore Context ---`) let the agent (and humans reading
transcripts) distinguish injected context from user input.

### Progressive Disclosure

If the budget allows only summaries, inject one-line summaries with IDs.
The agent can call `lore journal show <id>` or `lore patterns show <id>`
for full details. This mirrors claude-mem's index approach but with typed
records.

## Implementation Outline

### File Structure

```
hooks/
  inject-context.sh       # Main hook script (entry point)
  lib/
    extract-keywords.sh   # Keyword extraction from prompt
    query-sources.sh      # Query each lore component
    rank-results.sh       # Score and sort candidates
    format-output.sh      # Build the injection payload
  keyword-synonyms.yaml   # Editable synonym mapping
  config.yaml             # Budget, thresholds, source weights
```

### Script Flow

```
stdin (JSON) --> extract project + keywords
             --> query patterns, journal, failures, transfer, registry
             --> score and rank results
             --> trim to token budget
             --> format as hookSpecificOutput JSON
             --> stdout
```

### Output Format

```json
{
  "hookSpecificOutput": {
    "additionalContext": "--- Lore Context (auto-injected, 3 items) ---\n\n[pattern] Safe bash arithmetic..."
  }
}
```

### Error Handling

- `jq` parse failure on stdin: exit 0, inject nothing
- No matching results: exit 0, inject nothing (no noise)
- lore component missing or broken: skip that source, continue
- Timeout approaching: stop querying, return what we have

## Phased Delivery

### Phase 1: Project-Only Context

Inject the latest handoff note and top 3 patterns for the detected project.
No keyword extraction, no ranking. Validates the hook wiring and output
format.

### Phase 2: Keyword Matching

Add keyword extraction and search across journal + failures. Implement
scoring and token budgeting.

### Phase 3: Synonym Expansion + Tuning

Add `keyword-synonyms.yaml`. Tune weights and thresholds based on real
usage. Add `LORE_CONTEXT_BUDGET` and `LORE_CONTEXT_DEBUG` env vars.

### Phase 4: Metrics

Log injection stats (items injected, budget used, query time) to
`failures/data/` or a dedicated metrics file. Track whether injected context
actually gets referenced in the session (requires a PostToolUse or Stop hook
to check).

## Risks and Mitigations

| Risk                         | Impact                           | Mitigation                                                |
| ---------------------------- | -------------------------------- | --------------------------------------------------------- |
| Stale context misleads agent | Agent acts on outdated decision  | Recency decay in scoring; show timestamps                 |
| Latency exceeds timeout      | Context not injected             | 5s timeout; fast grep-based queries; fail-silent          |
| Token budget too small       | Useful context truncated         | Configurable budget; progressive disclosure               |
| Token budget too large       | Crowds agent's working memory    | Default 2,000 tokens; monitor session quality             |
| Keyword extraction too naive | Misses relevant context          | Phase 3 synonyms; upgrade path to prompt-based extraction |
| Irrelevant context injected  | Noise degrades agent performance | Score threshold; "no results = no injection"              |

## Open Questions

1. **Should the hook also fire on SessionStart?** A SessionStart hook could
   inject project-level orientation (registry metadata, active goals) while
   UserPromptSubmit handles per-prompt relevance. Two hooks, two purposes.

2. **Cache across prompts?** If the user sends 5 prompts about the same
   topic, should results be cached? The first query is cheap (<100ms), so
   caching adds complexity for minimal gain. Defer unless latency becomes
   an issue.

3. **Plugin vs settings hook?** A plugin packages the hook portably. A
   settings hook in `~/.claude/settings.json` is simpler but tied to one
   machine. Recommend: start with settings, migrate to plugin once stable.

4. **Interaction with `lore resume`?** The CLAUDE.md instruction to run
   `lore resume` at session start overlaps with auto-injection of transfer
   context. Once the hook is reliable, the manual instruction can be removed.
