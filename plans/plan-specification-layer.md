Status: Partial (spec quality scoring implemented; lore review and lore brief not built)

# Plan: Specification Layer

Lore captures decisions after the fact. This plan makes it a specification
layer that improves intent _before_ execution and measures whether it worked.

## Context

Three documents frame the opportunity:

- **specification-bottleneck-pitch.md** — AI compresses execution;
  specification quality determines whether that produces value or waste.
- **five-levels-of-ai-coding.md** — Level 4+ requires specs precise enough
  that review becomes verification against intent. Most teams plateau at
  Level 2.
- **the-subtraction-test.md** — Autonomy without understanding is a liability
  with a delayed fuse. Volume without specification quality is activity
  mistaken for progress.

Lore already does specification archaeology — extracting implicit knowledge
into queryable form. The gap: it records specifications after execution, never
measures whether they worked, and doesn't help write better ones next time.

## What to Do

### 1. Close the outcome loop

Decisions have an `outcome` field (`pending|successful|revised|abandoned`) but
nothing updates it. Of 57 decisions, most are `pending` indefinitely.

**`lore review`** — surface unresolved decisions at resume time and prompt for
resolution.

Implementation:

- Add `cmd_review()` to `lore.sh` that queries `decisions.jsonl` for records
  where `outcome == "pending"` and age > 3 days.
- Display each with its rationale, ask for outcome
  (`successful|revised|abandoned`) and optional `lesson_learned`.
- Update the decision in-place (jq rewrite of the JSONL line by `id`).
- When outcome is `revised` or `abandoned`, prompt for a replacement decision
  or record a failure.
- Wire into `resume_session()` in `transfer/lib/resume.sh` (after line 710,
  alongside existing `suggest_promotions`): call `cmd_review --auto` which
  shows a summary of pending decisions older than 7 days. Non-interactive mode
  prints the list; interactive mode prompts.

Feedback loop:

- Decisions marked `successful` boost related pattern confidence by 0.1
  (capped at 1.0).
- Decisions marked `abandoned` trigger `lore fail` with type
  `AbandonedDecision`.
- `lesson_learned` text feeds into `suggest_promotions` clustering.

Files:

- `lore.sh` — add `cmd_review()`, wire `review)` case
- `journal/lib/store.sh` — add `journal_update_outcome()` for in-place update
- `transfer/lib/resume.sh` — call review summary after line 710

### 2. Specification quality scoring

A decision with rationale + alternatives + entities is a stronger specification
than a bare sentence. Score each record at write time.

**Scoring rubric** (0.0 to 1.0):

| Field          | Weight | Condition         |
| -------------- | ------ | ----------------- |
| `decision`     | 0.2    | always present    |
| `rationale`    | 0.3    | non-null, > 20 ch |
| `alternatives` | 0.2    | at least 1 listed |
| `entities`     | 0.15   | at least 1 listed |
| `tags`         | 0.15   | at least 1 listed |

Store as `spec_quality` field on the decision record. Compute at write time in
`journal/lib/capture.sh`.

**Surface the score:**

- `lore remember` prints the score after recording: "Spec quality: 0.65
  (missing alternatives, entities)".
- `lore resume` prints rolling average: "Last 10 decisions: 0.58 spec quality
  (up from 0.42 last week)".
- `lore review` shows spec quality alongside outcome for correlation analysis.

Patterns get a simpler score:

| Field      | Weight | Condition         |
| ---------- | ------ | ----------------- |
| `name`     | 0.2    | always present    |
| `context`  | 0.3    | non-null, > 10 ch |
| `solution` | 0.3    | non-null, > 10 ch |
| `problem`  | 0.2    | non-null, > 10 ch |

Store as `spec_quality` on pattern records. Compute in
`patterns/lib/capture.sh`.

Files:

- `journal/lib/capture.sh` — add `compute_spec_quality()`, store on record
- `patterns/lib/capture.sh` — add `compute_spec_quality()`, store on record
- `transfer/lib/resume.sh` — print rolling average at resume

### 3. Pre-execution briefing

`lore resume` loads the last session. `lore context <project>` assembles
project metadata. Neither answers: "What does Lore know about _this topic_
before I start working on it?"

**`lore brief <topic>`** — topic-specific context assembly for pre-execution.

Implementation:

- Search decisions, patterns, failures, and graph for `<topic>`.
- Group results by component, not by recency.
- For decisions: show outcome status and spec quality. Highlight contradictions
  (two decisions with overlapping entities and different conclusions).
- For patterns: show confidence and validation count. Flag stale patterns
  (confidence < 0.3 or no validations in 30 days).
- For failures: show recurrence count and whether promoted to anti-pattern.
- For graph: show 1-hop neighbors of any matching concept nodes.
- Output as structured markdown for agent consumption.

This differs from `lore search` (flat ranked list) and `lore context`
(project-scoped metadata). `lore brief` is topic-scoped, multi-component,
and opinionated — it surfaces problems (contradictions, stale patterns,
unresolved decisions) alongside knowledge.

Files:

- `lore.sh` — add `cmd_brief()`, wire `brief)` case
- `lib/brief.sh` — main implementation (sourced by lore.sh)

### 4. Active subtraction at resume

The subtraction test says: define what to subtract, not just what to add.
Currently `lore resume` only adds context. Wire contradiction detection and
confidence signals into resume as subtraction recommendations.

**Subtraction checks** (added to `resume_session()` after handoff notes):

1. **Contradicted decisions**: pairs where `lore_check_contradiction` (from
   `985acb9`) would fire. Print: "Contradiction: decision A says X, decision B
   says Y. Run `lore review` to resolve."
2. **Stale pending decisions**: outcome `pending` for > 14 days. Print:
   "N decisions pending for 2+ weeks. Run `lore review` to resolve or abandon."
3. **Low-confidence patterns**: confidence < 0.3 with 0 validations. Print:
   "N patterns have never been validated. Consider removing with
   `lore patterns deprecate`."
4. **Deprecated but unreplaced**: patterns marked `[DEPRECATED]` with no
   corresponding anti-pattern. Print: "N deprecated patterns lack
   anti-pattern replacements."

Keep the output brief — one summary line per category, not per record. The
details live in `lore review` and `lore brief`.

Files:

- `transfer/lib/resume.sh` — add `subtraction_check()` after line 710
- `lib/conflict.sh` — expose `find_contradictions()` for batch scanning (the
  current `lore_check_contradiction` checks one text at write time; this scans
  all active decisions pairwise)

## What NOT to Do

- **Don't auto-delete anything.** Subtraction is advisory. Humans decide what
  to remove. The append-only contract remains.
- **Don't block writes on low spec quality.** Print the score, don't reject
  the record. A quick decision with rationale only is better than no decision.
- **Don't make `lore review` mandatory at resume.** Print the summary, offer
  the command. Agents that skip it lose feedback but aren't blocked.
- **Don't add spec quality to the search ranking yet.** Correlation between
  spec quality and outcome needs data first. Ranking changes come after Phase
  1 proves the score is predictive.
- **Don't touch the graph for this plan.** Graph improvements (orphan wiring,
  edge semantics) are separate work. `lore brief` reads the graph; it doesn't
  write to it.

## Files to Create/Modify

| File                       | Action | Notes                                |
| -------------------------- | ------ | ------------------------------------ |
| `lore.sh`                  | Modify | Add `cmd_review`, `cmd_brief`, cases |
| `lib/brief.sh`             | Create | Topic briefing implementation        |
| `journal/lib/capture.sh`   | Modify | Add `compute_spec_quality()`         |
| `journal/lib/store.sh`     | Modify | Add `journal_update_outcome()`       |
| `patterns/lib/capture.sh`  | Modify | Add `compute_spec_quality()`         |
| `transfer/lib/resume.sh`   | Modify | Wire review summary + subtraction    |
| `lib/conflict.sh`          | Modify | Add `find_contradictions()` batch    |
| `tests/test-spec-layer.sh` | Create | Tests for all four features          |
| `LORE_CONTRACT.md`         | Modify | Document review, brief, spec quality |

## Acceptance Criteria

- [ ] `lore review` lists pending decisions older than N days
- [ ] `lore review` updates outcome and lesson_learned on a decision
- [ ] Successful outcomes boost related pattern confidence
- [ ] Abandoned outcomes create failure records
- [ ] `lore remember` prints spec quality score after recording
- [ ] `lore resume` prints rolling spec quality average
- [ ] `lore brief <topic>` returns grouped results across all components
- [ ] `lore brief` highlights contradictions and stale patterns
- [ ] `lore resume` prints subtraction recommendations (contradictions, stale
      decisions, low-confidence patterns)
- [ ] All new features have test coverage in `test-spec-layer.sh`
- [ ] `make test` passes with the new test file wired in

## Testing

```bash
# Spec quality scoring
lore remember "Test decision" --rationale "Because"
# Expect: prints spec quality ~0.5 (decision + rationale, missing alternatives/entities/tags)

lore remember "Full decision" --rationale "Full reason" \
  --alternatives "Option B" --entities "file.sh" --tags "test"
# Expect: prints spec quality 1.0

# Outcome review
lore review
# Expect: lists decisions with outcome=pending older than 3 days

lore review --resolve dec-XXXX --outcome successful --lesson "It worked because Y"
# Expect: updates the record, boosts related pattern confidence

# Pre-execution briefing
lore brief "authentication"
# Expect: grouped results from journal, patterns, failures, graph
# Expect: contradictions and stale entries flagged

# Subtraction at resume
lore resume
# Expect: after handoff notes, prints subtraction summary if issues exist
```

## Sequencing

Build in order: outcome loop (1) → spec quality (2) → subtraction (4) →
briefing (3).

The outcome loop produces the data that makes spec quality scoring meaningful.
Spec quality + outcomes make subtraction recommendations concrete. Briefing
ties it together for pre-execution consumption.

Each phase is independently useful. Ship 1 before starting 2.
