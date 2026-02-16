# Unified Capture API: Implementation

## Changes to `lore.sh`

### 1. Add Type Inference Helper

```bash
# Infer capture type from flags
# Returns: "decision", "pattern", or "failure"
infer_capture_type() {
    local has_decision_flags=false
    local has_pattern_flags=false
    local has_failure_flags=false
    local explicit_type=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --decision) explicit_type="decision"; shift ;;
            --pattern) explicit_type="pattern"; shift ;;
            --failure) explicit_type="failure"; shift ;;

            --rationale|-r|--alternatives|-a|--outcome|--type|-f|--files)
                has_decision_flags=true
                [[ "$1" =~ ^- ]] && shift 2 || shift ;;

            --solution|--problem|--context|--category|--confidence|--origin)
                has_pattern_flags=true
                shift 2 ;;

            --error-type|--tool|--mission|--step)
                has_failure_flags=true
                [[ "$1" =~ ^- ]] && shift 2 || shift ;;

            *) shift ;;
        esac
    done

    [[ -n "$explicit_type" ]] && { echo "$explicit_type"; return; }

    if [[ "$has_failure_flags" == true ]]; then
        echo "failure"
    elif [[ "$has_pattern_flags" == true ]]; then
        echo "pattern"
    else
        echo "decision"  # Default
    fi
}
```

### 2. Add Unified Capture Command

```bash
cmd_capture() {
    local capture_type
    capture_type=$(infer_capture_type "$@")

    # Filter out explicit type flags before routing
    local args=()
    for arg in "$@"; do
        [[ "$arg" =~ ^--(decision|pattern|failure)$ ]] && continue
        args+=("$arg")
    done

    case "$capture_type" in
        decision) cmd_remember "${args[@]}" ;;
        pattern)  cmd_learn "${args[@]}" ;;
        failure)  cmd_fail "${args[@]}" ;;
        *)
            echo -e "${RED}Error: Unknown capture type: $capture_type${NC}" >&2
            return 1
            ;;
    esac
}
```

### 3. Update Help Text

```bash
show_help() {
    echo "Lore - Memory That Compounds"
    echo ""
    echo "Usage: lore <command> [options]"
    echo ""
    echo "Quick Commands:"
    echo "  lore capture <text>      Universal capture (infers type from flags)"
    echo "    --decision             Capture as decision (journal)"
    echo "    --pattern              Capture as pattern (lessons learned)"
    echo "    --failure              Capture as failure report"
    echo "  lore remember <text>     Shortcut for 'capture --decision'"
    echo "  lore learn <pattern>     Shortcut for 'capture --pattern'"
    echo "  lore fail <type> <msg>   Shortcut for 'capture --failure'"
    echo "  lore handoff <message>   Create handoff for next session"
    echo "  lore resume [session]    Resume from previous session"
    echo "  lore search <query>      Search across all components"
    # ... rest of help
}
```

### 4. Add Routing in Main Function

```bash
main() {
    [[ $# -eq 0 ]] && { show_help; exit 0; }

    case "$1" in
        # Unified capture API
        capture)    shift; cmd_capture "$@" ;;

        # Legacy shortcuts (backward compat)
        remember)   shift; cmd_remember "$@" ;;
        learn)      shift; cmd_learn "$@" ;;
        fail)       shift; cmd_fail "$@" ;;

        # ... rest of commands
    esac
}
```

## No Changes Required

These existing functions remain untouched:

- `cmd_remember()` - decision capture logic
- `cmd_learn()` - pattern capture logic
- `cmd_fail()` - failure capture logic
- Duplicate checking in `lib/conflict.sh`
- Component implementations (`journal/`, `patterns/`, `failures/`)

## Usage Examples

### Type Inference (Implicit)

```bash
# Decision (has --rationale)
lore capture "Use JSONL for storage" --rationale "Append-only"

# Pattern (has --solution)
lore capture "Safe arithmetic" --solution 'x=$((x+1))'

# Failure (has --error-type)
lore capture "Permission denied" --error-type ToolError
```

### Explicit Type (Override Inference)

```bash
# Force decision even without decision-specific flags
lore capture "Switched to mani.yaml" --decision

# Force pattern even without pattern-specific flags
lore capture "Always use positive form" --pattern

# Force failure even without failure-specific flags
lore capture "Agent timeout" --failure
```

### Edge Cases

```bash
# No flags → defaults to decision
lore capture "Refactored registry code"

# Ambiguous flags → explicit type wins
lore capture "..." --solution "..." --decision  # → decision (explicit)

# Multiple types → first explicit wins
lore capture "..." --pattern --decision  # → pattern (first explicit)

# Old commands still work
lore remember "..."  # → decision
lore learn "..."     # → pattern
lore fail ToolError "..."  # → failure
```

## Testing Strategy

### Unit Tests

Test `infer_capture_type()` with:

- Each flag category independently
- Mixed flags
- Explicit overrides
- Edge cases (no flags, conflicting flags)

### Integration Tests

```bash
# Decision routing
lore capture "Test decision" --rationale "Test" | grep "journal"

# Pattern routing
lore capture "Test pattern" --solution "Test" | grep "pattern"

# Failure routing
lore capture "Test failure" --error-type ToolError | grep "fail-"

# Backward compat
lore remember "Test" --rationale "Test" | grep "journal"
lore learn "Test" --solution "Test" | grep "pattern"
lore fail ToolError "Test" | grep "fail-"
```

### Deduplication Tests

```bash
# Ensure duplicate checking works across all types
lore capture "Duplicate decision" --rationale "..."
lore capture "Duplicate decision" --rationale "..."  # Should warn

lore capture "Duplicate pattern" --solution "..."
lore capture "Duplicate pattern" --solution "..."  # Should warn

# --force should work
lore capture "Duplicate" --force  # Should succeed
```

## Rollout Plan

### Phase 1: Implementation (1-2 hours)

1. Add `infer_capture_type()` to `lore.sh`
2. Add `cmd_capture()` to `lore.sh`
3. Update `show_help()`
4. Add `capture)` case to `main()`
5. Test manually with all three types

### Phase 2: Validation (1 week)

1. Use `lore capture` in daily work
2. Monitor for:
   - Type inference mistakes (wrong routing)
   - Confusing error messages
   - Missing flags in inference logic
3. Adjust as needed

### Phase 3: Documentation (1 hour)

1. Update `README.md` to show `lore capture` as primary
2. Mark old commands as "shortcuts" in help text
3. Add examples to `docs/`

### Phase 4: Feedback Loop (1 month)

1. Decide if unified API improves UX
2. If yes: promote it, soft-deprecate old commands
3. If no: keep as alternative, document trade-offs
4. If neutral: keep both, let users choose

## Backward Compatibility

**Zero breaking changes:**

- All existing commands work identically
- No script changes required
- Gradual adoption possible
- Can revert anytime (just remove `cmd_capture()`)

## Risks

### 1. Type Inference Errors

**Risk:** Wrong type inferred, user confused.
**Mitigation:** Explicit `--decision/--pattern/--failure` always available.

### 2. Duplicate Flag Names

**Risk:** Future flag collision between types.
**Example:** What if decisions need a `--tool` flag too?
**Mitigation:** Namespace flags if needed (`--decision-tool`, `--failure-tool`).

### 3. Mental Model Mismatch

**Risk:** Users prefer explicit verbs over unified capture.
**Mitigation:** Keep old commands, let usage patterns decide.

## Success Metrics

After 1 month:

1. **Usage:** Count `lore capture` vs `lore remember/learn/fail` in shell history
2. **Errors:** Count "wrong type inferred" issues
3. **Sentiment:** Does it feel simpler or more confusing?

If success metrics positive → promote unified API.
If neutral or negative → keep both, document trade-offs.
