Status: Active

# ADR Review: Three Council Pattern Documents

Reviewed 2026-02-13. All three ingested into Lineage today as architecture decisions with status `pending`.

## 1. Critique (dec-31a8b7ed)

**Source:** `council/critic/critique.md`
**Seat:** Critic
**Git commit:** `8784008` (bundled with Marshal hook and agent-optimization initiative)

### Proposal

Defines the Critic seat's operational philosophy — how to challenge ideas without destroying them. Codifies Rapoport's Rules (restate, agree, learn, then rebut), Sagan's Baloney Detection Kit adapted for engineering, Feynman's self-deception warning, cognitive bias countermeasures, and Socratic questioning techniques.

### Status

Accepted and merged. The document is comprehensive — 220 lines covering critique methodology, debiasing techniques, logical fallacies, and accountability frameworks. References `decisions.md` and `disagreement.md` as companions.

### Key Trade-offs

- **Depth vs. actionability:** The document is thorough (Kahneman, Munger, Sagan, Taleb) but risks becoming a reference shelf rather than an operational tool. The question checklists at the end help, but a working Critic agent would need a much shorter prompt distillation.
- **Process vs. judgment:** Heavy on structured techniques (pre-mortems, red teams, bias checklists) which is appropriate for the seat's role — but could slow fast two-way-door decisions if applied uniformly.

### Observations

- The "Common Traps" table is the most operationally useful section — catches cynicism-as-skepticism and critique theater.
- The commit (`8784008`) also added `.claude/marshal-blocks` and `initiatives/agent-optimization.md`, suggesting this was part of a broader council buildout session.

## 2. Worker (dec-91504739)

**Source:** `council/mainstay/worker.md`
**Seat:** Mainstay
**Git commit:** `e964468` (commit message says "Add Critic seat core operational document" — mislabeled)

### Proposal

Defines the Worker pattern: stateless specialists that receive task envelopes, execute within bounded scope, and return result envelopes. Covers manager/worker split, envelope schemas (task and result), incapability signaling, template injection, and layer visibility rules.

### Status

Accepted and merged. The pattern directly describes Bach's architecture and Flow's delegation model. This is a retroactive formalization of existing behavior, not a speculative proposal.

### Key Trade-offs

- **Strictness vs. flexibility:** Workers see only their envelope — never project state, other tasks, or the plan. This isolation prevents scope creep but means the manager must anticipate everything the worker needs. Incomplete envelopes produce `incapable` signals rather than creative workarounds.
- **Honest failure vs. throughput:** The `incapable` status is explicitly preferred over low-quality output. Good for correctness; potentially expensive if workers signal incapable frequently and the manager lacks fallback logic.
- **Four worker types** (researcher, coder, reviewer, tester) with separate templates. Clean separation, but adding a new specialty means a new template and manager routing logic.

### Observations

- The envelope schema is concrete and testable — good contract material.
- "Used In" section names Bach (framework) and Flow (delegator) explicitly. This is the glue pattern between them.
- Git commit message `e964468` is mislabeled as "Add Critic seat core operational document" — the actual diff adds `critic/critique.md` and updates `README.md`. The Worker ADR was committed separately but Lineage recorded this hash against it. **Data quality issue in ingestion.**

## 3. Pipeline (dec-01d3cc88)

**Source:** `council/mainstay/pipeline.md`
**Seat:** Mainstay
**Git commit:** `3e757d6` (commit message says "Add Worker pattern" — mislabeled)

### Proposal

Defines the Pipeline pattern: linear stages connected by narrow contracts with adjacent-only coupling. Each stage transforms data, communicates only with its immediate neighbors, and can be replaced independently. Applies to three concrete pipelines: Council (Harness → Flow → Bach), Orchestration (Oracle → Lore → Neo → Council), and Forge (spec-trace → GSD → coalesce).

### Status

Accepted and merged. Like Worker, this formalizes existing architecture rather than proposing something new. The two contracts (SIGNAL_CONTRACT.md and TASK_CONTRACT.md) already exist in the codebase.

### Key Trade-offs

- **Simplicity vs. expressiveness:** Linear topology prevents mesh coupling but forces intermediate stages to relay data. If Bach needs something from the harness, Flow must transform and forward it — no shortcuts allowed.
- **Formalized vs. conventional pipelines:** Council pipeline has explicit markdown contracts. Orchestration and Forge pipelines rely on convention. The document acknowledges this gap but doesn't prescribe a timeline for formalizing the others.
- **Nested composition:** The council pipeline nests inside the orchestration pipeline. Clean in theory, but means changes to the outer pipeline's contracts could cascade inward if the nesting boundary isn't maintained.

### Observations

- The "Adding a Stage" section provides a clean litmus test: if adding a stage requires modifying non-adjacent stages, the pipeline has hidden coupling.
- The actual git commit for this document is `ddf797d` ("Add Pipeline pattern — adjacent-only coupling with narrow contracts"). The Lineage record points to `3e757d6` which is the Worker commit. **Second data quality issue in ingestion.**

## Cross-Cutting Analysis

### Dependencies Between ADRs

```
Pipeline ──depends-on──> Worker (workers execute the terminal stage)
Pipeline ──depends-on──> State  (state holder manages transitions)
Pipeline ──depends-on──> Loop   (loop iterates the pipeline)
Worker   ──depends-on──> State  (manager reads state; workers don't)
```

All three pattern docs (Worker, Pipeline, plus the pre-existing Loop and State) form a coherent Mainstay pattern set describing the council execution stack. Critique stands alone as the Critic seat's operational document.

### Data Quality Issues

Two of three Lineage records have mismatched git commits:

| Decision      | Lineage commit | Actual commit | Actual message                 |
| ------------- | -------------- | ------------- | ------------------------------ |
| ADR: Critique | `8784008`      | `e964468`     | feat: Add Critic seat core doc |
| ADR: Worker   | `e964468`      | `3e757d6`     | docs: Add Worker pattern       |
| ADR: Pipeline | `3e757d6`      | `ddf797d`     | docs: Add Pipeline pattern     |

The commits are shifted by one position — each ADR points to the previous ADR's commit. This looks like an off-by-one error during batch ingestion.

### Recommendations

1. **Fix ingested commit hashes.** The off-by-one shift means `graph.sh query` and any commit-tracing tooling will point to wrong files. Update the three journal entries with correct hashes.

2. **Link the three decisions as related.** Worker and Pipeline are companion patterns under Mainstay; both reference Loop and State. Add `related_decisions` edges in the journal and graph nodes connecting them.

3. **Mark outcome as `accepted` rather than `pending`.** All three are merged and operational — the Lineage records still show `outcome: pending`.

4. **Consider distilling Critique for agent use.** The 220-line document is a reference for humans. A Critic agent prompt needs a 20-line operational subset. The checklist questions at the end are the starting point.

5. **Formalize the remaining conventional pipelines.** Pipeline doc acknowledges that Orchestration and Forge pipelines lack explicit contracts. This is a known gap worth tracking as an initiative.
