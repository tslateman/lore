Status: Done

# Plan: JSON I/O Mode for lore.sh

Structured input/output for `lore.sh` so Claude Code skills and agents
can write and read Lore without shell escaping or losing return values.

## Context

Lore's primary consumers shifted from humans and shell scripts to Claude
Code skills and agents. The `/narrate` comprehension checkpoint (created
2026-03-21) decomposes developer narrations into Lore decision, pattern,
and risk entries. This pipeline breaks on the current CLI interface:

- Rich prose (quotes, newlines, markdown) breaks shell argument parsing
- No return values -- callers cannot get entry IDs for linking
- Multi-step interactions (write decision, get ID, write risk, connect
  them) require fragile Bash chaining

A Council advisory (Critic, Marshal, Mainstay, Wayfinder -- 2026-03-21)
evaluated adding an MCP server. The Council converged: the real need is
structured I/O, not a new protocol. MCP becomes a trivial transport
adapter once the CLI speaks JSON.

## What to Do

### 1. Add `--json-in` flag to `lore.sh` dispatch

Accept a JSON object on stdin instead of positional arguments and flags.
The JSON schema mirrors the existing flag names:

```bash
echo '{"decision":"Use baseline detection","rationale":"Static thresholds fail on non-stationary noise","alternatives":["simple thresholding"],"type":"architecture","tags":["reck","anomaly"]}' \
  | lore remember --json-in
```

Parse with `jq`. Map JSON keys to the same internal variables the flag
parser sets. Both paths (flags and JSON) must converge to a single code
path before calling storage functions.

### 2. Add `--json-out` flag to all write commands

Emit a JSON object on stdout after a successful write:

```json
{
  "ok": true,
  "id": "dec-a1b2c3d4",
  "timestamp": "2026-03-21T14:30:00Z",
  "path": "journal/decisions.jsonl"
}
```

On failure:

```json
{ "ok": false, "error": "Duplicate detected", "existing_id": "dec-9f8e7d6c" }
```

When `--json-out` is absent, preserve current human-readable output.

### 3. Combined mode: `--json`

Shorthand for `--json-in --json-out`. This is the mode agents will use:

```bash
echo "$PAYLOAD" | lore remember --json
```

### 4. Apply to all write commands

| Command    | JSON input schema                                             |
| ---------- | ------------------------------------------------------------- |
| `remember` | `{decision, rationale?, alternatives?, type?, tags?, files?}` |
| `learn`    | `{pattern, context?, solution?, problem?, category?}`         |
| `fail`     | `{error_type, message, tool?, step?}`                         |
| `observe`  | `{text, source?, tags?}`                                      |

Required fields match the existing positional argument requirements.

### 5. Apply to read commands

`lore search`, `lore recall`, and `lore context` should also support
`--json-out` for structured responses. Lower priority than writes.

### 6. Update `/narrate` skill

Replace Bash flag construction with JSON piping:

```bash
echo '{"decision":"...","rationale":"...","alternatives":"...","type":"architecture","tags":"reck,narrate"}' \
  | lore remember --json
```

Parse the returned ID to link related entries.

## What NOT to Do

- Do not build an MCP server yet. JSON I/O mode is the prerequisite.
  If MCP proves necessary later, it wraps `lore.sh --json` as a thin
  transport adapter.
- Do not port storage logic to another language. Bash `lib/` functions
  remain authoritative. The MCP server (if built) calls the CLI.
- Do not change the storage format. JSONL and YAML files stay as-is.
- Do not break existing flag-based invocation. JSON mode is additive.

## Acceptance Criteria

- [ ] `echo '{"decision":"test"}' | lore remember --json` writes to
      `decisions.jsonl` and returns `{"ok":true,"id":"dec-..."}` on stdout
- [ ] `lore remember "test" --json-out` returns the same JSON structure
      via traditional flag invocation
- [ ] Rich content (quotes, newlines, backticks, markdown) survives
      round-trip through JSON mode without escaping errors
- [ ] Entry IDs returned by `--json-out` match the IDs in the JSONL file
- [ ] All four write commands (`remember`, `learn`, `fail`, `observe`)
      accept `--json-in` and emit `--json-out`
- [ ] Existing flag-based invocation is unchanged (no regressions)
- [ ] `/narrate` skill updated to use JSON piping for Lore writes

## Testing

```bash
# Write via JSON, verify output
echo '{"decision":"Test JSON mode","rationale":"Validating structured I/O"}' \
  | lore remember --json | jq .ok
# Expected: true

# Verify round-trip content safety
echo '{"decision":"Handle \"quotes\" and\nnewlines"}' \
  | lore remember --json | jq .id
# Expected: dec-<hash> (no escaping errors)

# Verify flag mode still works
lore remember "Test flag mode" --rationale "Regression check" --json-out | jq .ok
# Expected: true

# Verify dedup returns existing ID
echo '{"decision":"Test JSON mode","rationale":"Validating structured I/O"}' \
  | lore remember --json | jq .error
# Expected: "Duplicate detected"
```

## Files to Modify

- `lore.sh` -- add `--json-in`, `--json-out`, `--json` flag parsing to
  dispatch layer
- `journal/journal.sh` -- add JSON input parsing to `record` function
- `patterns/patterns.sh` -- add JSON input parsing to `capture` function
- `lib/conflict.sh` -- ensure dedup returns structured error in JSON mode
- `~/.claude/skills/narrate/SKILL.md` -- update Step 5 to use JSON piping
