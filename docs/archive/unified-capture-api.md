# Unified Capture API Proposal

## Problem

Three similar write commands create cognitive overhead:

```bash
lore remember "Use JSONL" --rationale "Append-only"
lore learn "Safe arithmetic" --solution 'x=$((x+1))'
lore fail ToolError "Permission denied"
```

All three:

- Capture knowledge with context
- Have duplicate checking (--force to skip)
- Store timestamp + tags
- Route to different components

The choice between them is **categorization**, not **behavior**.

## Solution

**Unified capture with type inference:**

```bash
# Decision (inferred from --rationale)
lore capture "Use JSONL" --rationale "Append-only"

# Pattern (inferred from --solution)
lore capture "Safe arithmetic" --solution 'x=$((x+1))'

# Failure (inferred from --error-type)
lore capture "Permission denied" --error-type ToolError
```

**Or explicit type:**

```bash
lore capture "Use JSONL" --decision --rationale "Append-only"
lore capture "Safe arithmetic" --pattern --solution 'x=$((x+1))'
lore capture "Permission denied" --failure --error-type ToolError
```

## Type Inference Rules

1. **Failure-specific flags** → `failures/`
   - `--error-type`, `--tool`, `--step`

2. **Pattern-specific flags** → `patterns/`
   - `--solution`, `--problem`, `--context`, `--category`, `--confidence`

3. **Decision-specific flags** → `journal/`
   - `--rationale`, `--alternatives`, `--outcome`, `--type`

4. **Explicit override** → use specified type
   - `--decision`, `--pattern`, `--failure`

5. **No flags** → default to `decision` (most common)

## Benefits

### Reduced Mental Load

- One capture command to remember
- Type inference feels natural ("if I'm providing a solution, it's a pattern")
- Explicit flags available when inference is unclear

### Preserved Semantics

- Still routes to journal/, patterns/, failures/
- Data schemas unchanged
- Duplicate checking preserved
- Component boundaries intact

### Backward Compatibility

- Keep `remember`, `learn`, `fail` as aliases
- Existing scripts continue to work
- Gradual migration path

## What We Keep Separate

Components remain distinct because their **schemas diverge**:

- **journal/** - revision lifecycle (pending → successful/revised/abandoned)
- **patterns/** - confidence + validation tracking
- **failures/** - append-only JSONL, Rule of Three triggers

The unified API is **syntax**, not **semantics**.

## Implementation Path

1. Add `infer_capture_type()` helper
2. Add `cmd_capture()` that routes to existing functions
3. Keep `cmd_remember`, `cmd_learn`, `cmd_fail` as-is
4. Update help text to show `lore capture` as primary
5. Document old commands as "shortcuts" (backward compat)

## Example Session

```bash
# Quick decision (no flags needed)
lore capture "Switched to mani.yaml for registry"

# Pattern with context
lore capture "Grep pipeline gotcha" \
  --problem "grep exits 1 on no match, kills set -e" \
  --solution "Append || true to grep in pipelines"

# Failure report
lore capture "Agent timeout in transfer step" \
  --error-type Timeout \
  --step 3

# Search finds all three
lore search "pipeline"
  [decision] Switched to mani.yaml...
  [pattern] Grep pipeline gotcha: Append || true...
  [failure] fail-a1b2c3d4 [Timeout] Agent timeout...
```

## Open Questions

1. **Should we deprecate old commands eventually?**
   - Pro: Simpler mental model, one way to do it
   - Con: Breaks muscle memory, existing docs/scripts

2. **Should inference be smarter?**
   - Example: "failed to..." → infer failure type?
   - Risk: Magic behavior, hard to debug

3. **Do we need capture shortcuts?**
   - `lore decide` → `lore capture --decision`
   - `lore teach` → `lore capture --pattern`
   - `lore error` → `lore capture --failure`

## Decision

Need user input:

- Try the unified API?
- Keep old commands as primary?
- Hybrid (both documented equally)?
