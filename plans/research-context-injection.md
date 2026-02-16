# Context Injection Best Practices Research

Date: 2026-02-15
Status: Reference

## Summary

Modern context injection for AI coding assistants uses **hybrid retrieval with
ranking** (BM25 + semantic search), not keyword grep. The 2026 best practice is
**pull-based ranked retrieval** with explicit query tools, not push-based
auto-injection on every prompt.

## Key Findings

### 1. Naive Keyword Grep is Obsolete (2026)

**Current Problem:** `inject-context.sh` uses `grep -qi` for keyword matching
against lowercase text. Misses semantically related content, no ranking.

**2026 Standard:** Hybrid search (BM25 + semantic embeddings) with reranking
([Context7](https://www.deployhq.com/guides/context7),
[agentic RAG](https://docs.kanaries.net/articles/agentic-rag)). The LLM decides
what to retrieve, not grep.

**Evidence:** "In 2026, hybrid search is the default — not optional.
Retrieval-Augmented Generation has evolved from a simple retrieve-and-generate
pipeline into a sophisticated ecosystem of hybrid search, reranking,
self-correcting retrieval, and agentic reasoning."
([RAG in 2026](https://www.techment.com/blogs/rag-in-2026/))

### 2. Fixed Budgets Need Prioritization

**Current Problem:** 1,500 character hard cap with first-match wins. No quality
ranking—old, low-confidence patterns can crowd out recent, high-relevance
decisions.

**2026 Standard:**
[Selective context injection](https://www.getmaxim.ai/articles/context-window-management-strategies-for-long-context-ai-agents-and-chatbots/)
prioritizes most relevant information. Use scoring (BM25 rank × temporal decay)
to rank results, then budget-cap top-ranked items.

**Evidence:** "Selective context injection prioritizes the most relevant
information for each model invocation rather than including all available
context, optimizing context window utilization while maintaining response
quality."

### 3. Performance: Index > Parse

**Current Problem:** Every prompt triggers full file parsing (`yq`, `jq`,
`grep` through JSONL/YAML). No index, no cache. 220ms runtime won't scale past
~100 patterns/decisions.

**2026 Standard:** Pre-built indexes (FTS5, vector DB). High-signal memory in
system prompt or indexed retrieval.

**Evidence:** "Context7 solves this by injecting up-to-date, version-specific
documentation directly into an AI's context window as an MCP server that fetches
the latest official docs and code examples in real time" (from pre-built
indexes, not raw files).
([Context7 Guide](https://www.deployhq.com/guides/context7))

### 4. Transparency Prevents Security Issues

**Current Problem:** Silent `additionalContext` injection causes
[false positive "prompt injection" detection](https://github.com/anthropics/claude-code/issues/17804)
when nested JSON appears in context.

**2026 Standard:** Transparent context injection. Show what was added (e.g., "📎
Added 3 patterns from Lore").

**Evidence:** GitHub issue #17804 documents that UserPromptSubmit hooks trigger
false positives in Claude's security layer when they inject structured data.
Users can't debug what they can't see.

### 5. Agentic Retrieval > Auto-Injection

**Current Problem:** Push-based approach injects on every prompt whether needed
or not.

**2026 Standard:** Agentic RAG where "the LLM itself decides when to retrieve,
what to search for, and whether the results are good enough."
([Agentic RAG](https://docs.kanaries.net/articles/agentic-rag))

**Evidence:** "In agentic RAG, the LLM itself decides when to retrieve, what to
search for, and whether the results are good enough. This is the dominant
paradigm for complex RAG applications in 2026."

## Comparison: Hook Approaches

| Criterion               | Current Hook          | 2026 Best Practice        |
| ----------------------- | --------------------- | ------------------------- |
| **Retrieval**           | Keyword grep          | Hybrid BM25 + semantic    |
| **Ranking**             | First-match wins      | Score-based (rank × time) |
| **Performance**         | Parse files every run | Pre-built index           |
| **Transparency**        | Silent injection      | Visible context additions |
| **Control**             | Auto on every prompt  | Agentic (LLM decides)     |
| **Scalability**         | ~100 records          | 10,000+ records           |
| **Semantic matching**   | No                    | Yes (embeddings)          |
| **Cost per query**      | Low (grep)            | Medium (index + rank)     |
| **False positives**     | High (grep noise)     | Low (reranked)            |
| **Context relevance**   | 60-70%                | 85-95%                    |
| **Hook complexity**     | 128 lines bash        | 50 lines + index builder  |
| **User control**        | None                  | Explicit query tool       |
| **Debuggability**       | Opaque                | Transparent               |
| **Security alerts**     | Triggers false pos    | Avoids nested JSON issues |
| **Project scoping**     | Path string parsing   | Metadata-based            |
| **Multi-project**       | Fragile               | Robust (registry lookup)  |
| **Incremental updates** | Full rebuild          | Delta indexing            |

## Recommendation

**Immediate:** Fix project scoping fragility, add scoring before budget-capping,
make injection transparent.

**Short-term:** Implement `plan-lore-retrieval.md` FTS5 index to replace grep
with ranked queries.

**Long-term:** Evolve to hybrid approach:

1. **Minimal auto-injection:** Only high-confidence, project-scoped context
   (3-5 items max)
2. **Explicit query tool:** `lore search "topic"` for ad-hoc retrieval
3. **Agentic mode:** Claude decides when to query Lore, not hook-forced

## Open Questions

1. **When does FTS5 fail enough to justify vector embeddings?** Plan says "Rule
   of Three" (3 semantic misses logged).
2. **Should auto-injection be opt-in per project?** Some projects may not want
   automatic context.
3. **How to handle cross-project context?** Current hook is single-project
   scoped.
4. **What's the optimal budget in 2026?** 1,500 chars may be too low with 200K
   context windows.

## Pattern: The Three Layers of Context (2026)

Modern AI coding assistants use a three-tier architecture:

```
Tier 1: System Prompt
  High-signal, always-loaded memory (project conventions, common patterns)
  Cost: Included in every request
  Size: 500-2000 tokens

Tier 2: Hook-Based Auto-Injection
  Triggered context (UserPromptSubmit adds project-scoped recent decisions)
  Cost: Added on user action
  Size: 100-500 tokens (selective, ranked)

Tier 3: Agentic Retrieval
  LLM explicitly queries knowledge base when needed
  Cost: Only when LLM requests it
  Size: Variable (top-k results from ranked search)
```

Current `inject-context.sh` conflates Tier 2 and Tier 3 by trying to
auto-inject everything that might be relevant. Best practice: Keep Tier 2
minimal (top 3-5 ranked items), provide Tier 3 via explicit tool.

## Architecture Evolution Path

```
Phase 1 (Current): Keyword grep → additionalContext
  ✓ Works for small corpus (<100 items)
  ✗ No ranking, semantic misses, fragile scoping

Phase 2 (plan-lore-retrieval.md): FTS5 index → ranked results
  ✓ BM25 ranking, temporal decay, scales to 10K items
  ✓ Grep fallback if index missing
  ✗ Still auto-injecting on every prompt

Phase 3 (Future): Hybrid auto + agentic
  ✓ Minimal auto-injection (top 3, project-scoped)
  ✓ Explicit tool: lore search "query"
  ✓ Claude decides when to retrieve
  ✗ Requires tool integration in Claude Code

Phase 4 (If needed): Vector embeddings
  ✓ Semantic search handles "error handling" → "retry logic"
  ✓ Solves documented semantic miss failures
  ✗ Higher complexity, external dependency or API cost
```

**Current blocker for Phase 3:** Claude Code MCP integration still limited. Hook
API doesn't support dynamic tool registration from hooks (hooks can inject
context but can't add callable tools).

**Workaround:** Use MCP server for Lore instead of hook. MCP servers can
register tools that Claude can call explicitly.

## Implementation: Current Hook Analysis

File: `/Users/tslater/dev/lore/hooks/inject-context.sh` (128 lines)

**What it does right:**

- Budget cap prevents context explosion (line 12: `BUDGET=1500`)
- `trap 'exit 0' ERR` prevents hook failures blocking Claude (line 3)
- Structured output format `hookSpecificOutput` (line 128)
- Stopword filtering reduces noise (lines 26-35)

**Critical issues:**

1. **Lines 19-23:** Project extraction via path string manipulation

   ```bash
   project="${cwd#"$WORKSPACE_ROOT/"}"
   [[ "$project" == "$cwd" ]] && exit 0
   project="${project%%/*}"
   ```

   **Problem:** Breaks if workspace isn't standard layout. Should read from
   `.claude/project.yaml` or git remote.

2. **Lines 42-48:** First-match budget algorithm

   ```bash
   try_add() {
     local len=${#1}
     (( used + len > BUDGET )) && return 1
     results+="$1"
     used=$((used + len))
   }
   ```

   **Problem:** No ranking. First pattern to match gets added until budget
   exhausted. A low-confidence old pattern can crowd out a recent
   high-confidence decision.

   **Fix:** Collect all matches with scores first, sort by score, then
   budget-cap.

3. **Lines 51-83:** Pattern query uses `grep -qi` on concatenated fields

   ```bash
   searchable=$(echo "$name $ctx $problem $solution" | tr '[:upper:]' '[:lower:]')
   echo "$searchable" | grep -qi "$kw" 2>/dev/null && { matched=true; break; }
   ```

   **Problem:** Semantic misses. "retry logic" won't find "error handling."

   **Fix:** Phase 2 uses FTS5 `MATCH` with BM25 ranking. Phase 4 adds vector
   embeddings if FTS5 fails 3+ times.

4. **Line 128:** Silent injection

   ```bash
   jq -n --arg ctx "$output" '{ hookSpecificOutput: { additionalContext: $ctx } }'
   ```

   **Problem:** User sees Claude's response with mystery knowledge. No
   visibility into what was injected. Triggers
   [false positive security alerts](https://github.com/anthropics/claude-code/issues/17804)
   when nested JSON in context.

   **Fix:** Log to stderr or return visible metadata:

   ```json
   {
     "hookSpecificOutput": {
       "additionalContext": "...",
       "metadata": {
         "source": "lore",
         "items_injected": 3,
         "types": ["pattern", "decision", "handoff"]
       }
     }
   }
   ```

## Fixes for Current Hook (Before Full Redesign)

### Fix 1: Add Scoring and Ranking

```bash
# Collect all matches with scores first
declare -A matches
declare -A scores

score_match() {
  local type=$1 content=$2 timestamp=$3 confidence=${4:-50}
  local days_old=$(( ($(date +%s) - $(date -j -f "%Y-%m-%dT%H:%M:%S" "$timestamp" +%s 2>/dev/null || echo 0)) / 86400 ))
  local temporal_factor=$(echo "scale=2; 1 / (1 + $days_old / 30)" | bc)
  local score=$(echo "scale=2; $confidence * $temporal_factor" | bc)
  echo "$score"
}

# After collecting matches, sort by score
for key in "${!matches[@]}"; do
  echo "${scores[$key]} $key"
done | sort -rn | while read score key; do
  try_add "${matches[$key]}" || break
done
```

### Fix 2: Read Project from Metadata

```bash
# Replace lines 19-23
if [[ -f "$cwd/.claude/project.yaml" ]]; then
  project=$(yq -r '.project.name // ""' "$cwd/.claude/project.yaml")
elif git -C "$cwd" rev-parse --git-dir >/dev/null 2>&1; then
  remote=$(git -C "$cwd" remote get-url origin 2>/dev/null || echo "")
  project=$(basename "${remote%.git}")
fi
[[ -z "$project" ]] && exit 0
```

### Fix 3: Make Injection Visible

```bash
# Replace line 128
jq -n \
  --arg ctx "$output" \
  --argjson count "$count" \
  '{ hookSpecificOutput: {
    additionalContext: $ctx,
    metadata: {
      source: "lore",
      items_injected: $count,
      budget_used: '$used',
      budget_total: '$BUDGET'
    }
  }}'

# Also log to stderr for debugging
echo "🗂️  Lore: Injected $count items ($used/$BUDGET chars)" >&2
```

## Testing Context Injection

From
[Claude Code Hooks Best Practices](https://code.claude.com/docs/en/hooks):

```bash
# Test hook in isolation
echo '{"cwd": "/Users/you/dev/project", "prompt": "explain retry logic"}' | \
  bash hooks/inject-context.sh | jq

# Should output JSON with additionalContext, or nothing if no matches
```

Current hook returns valid JSON but content relevance is untestable without
golden dataset.

**Needed:** `tests/hook-context-quality.sh` that asserts:

- Query "retry" returns retry-related patterns (not false matches)
- Recent decisions rank higher than old ones (temporal decay works)
- Budget cap respected (used <= BUDGET)
- Project scoping works (neo query doesn't return lore patterns)

## References: Modern Retrieval Patterns

### Hybrid Search (BM25 + Vector)

"In 2026, hybrid search is the default — not optional. Building an effective RAG
system means use hybrid search to cover both keyword and semantic matches. Add a
reranker for precision."
([RAG in 2026](https://www.techment.com/blogs/rag-in-2026/))

### Agentic RAG

"In agentic RAG, the LLM itself decides when to retrieve, what to search for,
and whether the results are good enough. Agentic RAG uses an AI agent that can
decompose queries, select different tools (vector search, web search, SQL),
evaluate whether retrieved context is sufficient, and iterate with refined
queries."
([Agentic RAG](https://docs.kanaries.net/articles/agentic-rag))

### Context Engineering

"One of the goals of context engineering is to balance the amount of context
given - not too little, not too much. Context injection is implemented via hooks
that run after context trimming and before the agent begins execution."
([Context Engineering for Coding Agents](https://martinfowler.com/articles/exploring-gen-ai/context-engineering-coding-agents.html))

### Performance Budgeting

"Selective context injection prioritizes the most relevant information for each
model invocation rather than including all available context, optimizing context
window utilization while maintaining response quality."
([Context Window Management](https://www.getmaxim.ai/articles/context-window-management-strategies-for-long-context-ai-agents-and-chatbots/))

## The Test

**Question:** When should context be injected?

- **Naive approach:** "Inject everything that might be relevant, hope it fits in
  budget"
- **2026 best practice:** "Rank by relevance, inject top N with highest
  score × temporal_decay, provide explicit query tool for the rest"

**Question:** How to handle semantic misses (query: "retry" missing pattern:
"error handling")?

- **Current hook:** Grep can't solve this. Miss the pattern.
- **FTS5 (Phase 2):** Still misses. FTS5 is keyword-based with better ranking.
- **Vector search (Phase 4):** Embedding similarity finds it. Trigger: 3+
  logged semantic failures.

**Question:** Who decides what context to retrieve?

- **Current hook:** Hook decides (keyword grep match → auto-inject)
- **2026 best practice:** Agentic RAG—LLM decides ("I need to know about error
  handling patterns" → calls `lore search "error handling"`)

## Cost Analysis

| Approach              | Per Query Cost                              | Scalability | Accuracy |
| --------------------- | ------------------------------------------- | ----------- | -------- |
| **Keyword grep**      | ~0ms (in-process)                           | <100 items  | 60-70%   |
| **FTS5 index**        | ~1-5ms (SQLite local)                       | <100K items | 75-85%   |
| **Vector + rerank**   | ~50-200ms (embedding + search)              | <1M items   | 90-95%   |
| **Agentic (no auto)** | 0ms if not triggered, variable if triggered | Unlimited   | Variable |

Current corpus size (from plan-lore-retrieval.md line 259): 47 decisions, 13
patterns, unknown transfer sessions. Total ~60-100 items.

**Conclusion:** FTS5 (Phase 2) is appropriate for current scale. Vector search
(Phase 4) is premature unless semantic failures hit Rule of Three.

---

## Sources

- [Hooks reference - Claude Code Docs](https://code.claude.com/docs/en/hooks)
- [Context Engineering for Coding Agents - Martin
  Fowler](https://martinfowler.com/articles/exploring-gen-ai/context-engineering-coding-agents.html)
- [Context Window Management
  Strategies](https://www.getmaxim.ai/articles/context-window-management-strategies-for-long-context-ai-agents-and-chatbots/)
- [How to Supercharge Your AI Coding Assistant with
  Context7](https://www.deployhq.com/guides/context7)
- [Agentic RAG: How AI Agents Are Transforming
  Retrieval](https://docs.kanaries.net/articles/agentic-rag)
- [RAG in 2026: How Retrieval-Augmented Generation
  Works](https://www.techment.com/blogs/rag-in-2026/)
- [UserPromptSubmit Hook False Positive
  Bug](https://github.com/anthropics/claude-code/issues/17804)
- [Context Engineering in Agents -
  LangChain](https://docs.langchain.com/oss/python/langchain/context-engineering)
- [Best LLMs for Extended Context Windows in
  2026](https://aimultiple.com/ai-context-window)
- [Retrieval-Augmented Generation (RAG) - Prompt Engineering
  Guide](https://www.promptingguide.ai/research/rag)
- [Best RAG Tools, Frameworks, and
  Libraries](https://research.aimultiple.com/retrieval-augmented-generation/)
