# Capture API: Before vs After

## Current API (Three Commands)

### Recording a Decision

```bash
# Must remember "lore remember" is for decisions
lore remember "Use JSONL for storage" \
  --rationale "Append-only, simple" \
  --tags "architecture,storage"
```

### Learning a Pattern

```bash
# Must remember "lore learn" is for patterns
lore learn "Safe bash arithmetic in set -e scripts" \
  --context "Scripts with set -e exit on command failures" \
  --solution 'Use x=$((x+1)) instead of x=$(expr $x + 1)'
```

### Logging a Failure

```bash
# Must remember "lore fail" takes error-type first
lore fail ToolError "Permission denied writing to /var/log" \
  --tool Bash \
  --mission "mis-abc123"
```

**Mental model:** Three verbs, must choose the right one upfront.

## Proposed API (Unified Capture)

### Recording a Decision

```bash
# Type inferred from --rationale
lore capture "Use JSONL for storage" \
  --rationale "Append-only, simple" \
  --tags "architecture,storage"
```

### Learning a Pattern

```bash
# Type inferred from --solution
lore capture "Safe bash arithmetic in set -e scripts" \
  --context "Scripts with set -e exit on command failures" \
  --solution 'Use x=$((x+1)) instead of x=$(expr $x + 1)'
```

### Logging a Failure

```bash
# Type inferred from --error-type
lore capture "Permission denied writing to /var/log" \
  --error-type ToolError \
  --tool Bash \
  --mission "mis-abc123"
```

**Mental model:** One verb, type follows naturally from the flags you provide.

## Side-by-Side Comparison

| Task                   | Current                                                                | Unified                                                                      |
| ---------------------- | ---------------------------------------------------------------------- | ---------------------------------------------------------------------------- |
| **Simple decision**    | `lore remember "Switched to SQLite"`                                   | `lore capture "Switched to SQLite"`                                          |
| **Decision + context** | `lore remember "Use FTS5" -r "Fast search"`                            | `lore capture "Use FTS5" -r "Fast search"`                                   |
| **Simple pattern**     | `lore learn "Avoid grep in pipelines" --solution "Use grep \|\| true"` | `lore capture "Avoid grep in pipelines" --solution "Use grep \|\| true"`     |
| **Pattern + metadata** | `lore learn "RRF for hybrid search" --solution "..." --confidence 0.8` | `lore capture "RRF for hybrid search" --solution "..." --confidence 0.8`     |
| **Simple failure**     | `lore fail Timeout "Agent did not respond"`                            | `lore capture "Agent did not respond" --error-type Timeout`                  |
| **Failure + context**  | `lore fail UserDeny "Blocked git push" --tool Bash --step 3`           | `lore capture "Blocked git push" --error-type UserDeny --tool Bash --step 3` |
| **Ambiguous case**     | Must choose: `lore remember` or `lore learn`?                          | `lore capture "..." --decision` (explicit)                                   |
| **Skip dup check**     | `lore remember "..." --force`                                          | `lore capture "..." --force`                                                 |
| **With project tags**  | `lore remember "..." --tags "lore,journal"`                            | `lore capture "..." --tags "lore,journal"`                                   |
| **From external tool** | `lore_record_decision "..."`<br>(calls `lore remember` internally)     | `lore_record_decision "..."`<br>(calls `lore capture --decision`)            |

## What Changes?

### User-Facing

- **Help text:** `lore capture` documented as primary
- **Muscle memory:** Optional transition (old commands stay as aliases)
- **Error messages:** "Unknown option for decision capture" instead of "Unknown option for lore remember"

### Internal

- **Routing:** `cmd_capture()` → `cmd_remember()` / `cmd_learn()` / `cmd_fail()`
- **Code reuse:** Existing functions untouched, just called differently
- **Backward compat:** Old commands remain, marked as "shortcuts"

## Migration Path

### Phase 1: Add Unified API (Non-Breaking)

- Implement `lore capture`
- Keep `remember`, `learn`, `fail` as-is
- Document both in help text

### Phase 2: Soft Deprecation (Optional)

- Help text shows `lore capture` first
- Old commands marked "(shortcut for lore capture --TYPE)"
- No warnings, no breaking changes

### Phase 3: Eventual Removal (Optional, Far Future)

- After 6+ months, consider deprecation warnings
- After 12+ months, remove old commands
- Only if unified API proves superior

## Recommendation

**Start with Phase 1:**

1. Implement `lore capture` alongside existing commands
2. Use it yourself for 2-4 weeks
3. Decide:
   - Keep both (if unified API doesn't feel better)
   - Promote unified (if it reduces friction)
   - Drop unified (if type inference causes confusion)

**Low-risk experiment** — old commands never break.
