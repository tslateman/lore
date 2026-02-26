# Plan: Remove Mission Layer from Lore

Status: Implemented (2026-02-16)

## Context

Lore's intent component has three layers: goals, missions, and tasks. Missions
decompose goals into one YAML file per success criterion. The missions directory
is empty -- `lore mission generate` has never been called despite three active
goals. In practice, Council initiatives bridge goals to work, and Claude Code's
built-in task lists handle execution.

Neo owns mission execution (`assign-mission`, `check-progress`, `abort-mission`).
Lore's mission layer duplicates Neo's vocabulary without adding information --
it mechanically renames success criteria into mission YAML files.

## What to Do

### 1. Remove mission functions from `intent/lib/intent.sh`

Delete these functions (reference: `intent/lib/intent.sh`):

- `get_mission_file()` (lines 97-100)
- `list_mission_files()` (lines 108-110)
- `create_mission()` (lines 367-479)
- `list_missions()` (lines 483-549)
- `intent_mission_main()` (lines 1064-1081)

Remove:

- `MISSIONS_DIR` variable (line 10)
- `mkdir -p "$MISSIONS_DIR"` from `init_intent()` if present
- Mission references in `get_goal()` display output (lines 1160-1179,
  1245-1298) -- the parts that query mission files and append missions info

### 2. Remove `mission_hints` from goal template

In `intent/lib/intent.sh` `create_goal()` (line 197), remove the
`mission_hints:` block from the goal YAML template:

```yaml
# Remove this block:
mission_hints:
  max_parallel: 3
  preferred_team_size: 2
  decomposition_strategy: sequential
```

Same block in `intent/lib/spec.sh` (line 507).

### 3. Remove `mission_hints` from existing goal files

Strip the `mission_hints:` section from all three files in
`intent/data/goals/`:

- `goal-1771254348-191098b1.yaml` (line 31)
- `goal-1771254688-cc3114e2.yaml` (line 30)
- `goal-1771258471-d0f6375a.yaml` (line 38)

### 4. Remove `--mission` flag from failures

In `lore.sh` `cmd_fail()` (line 903): remove the `--mission|-m` flag parsing
and stop passing `$mission` to `failures_append`.

In `failures/lib/failures.sh`:

- `failures_append()` (line 37): drop the `mission` parameter (4th arg).
  Remove the `--arg mission` from the `jq` call and the conditional mission
  field.
- `failures_list()` (line 85): remove `filter_mission` parameter and its
  filter logic.
- `failures_timeline()` (line 138): remove or repurpose. This function
  filters failures by mission ID. With no missions, delete it.

In `lore.sh` `cmd_failures()` (line 958): remove `--mission` flag parsing.

### 5. Remove mission from MCP server

In `mcp/src/index.ts` (line 782): remove the `mission` parameter from the
failures tool schema and its usage in the handler.

### 6. Update `lore.sh` routing and help

In `lore.sh`:

- Remove the `mission)` case from the main dispatch (line 1141)
- Remove mission lines from all help text (lines 1030-1031, and the
  `show_help_intent` function)
- Update `show_help_failures` to remove `--mission` flag documentation

### 7. Update documentation

**`intent/README.md`**: Remove all mission references. Rename the overview to
"Goals and tasks -- what we are trying to achieve." Remove the mission CLI
commands table, data format section, and `create_mission`/`list_missions` from
the key functions table.

**`CLAUDE.md`** (line 89): Remove `Missions: YAML (one file per mission in
intent/data/missions/)` from Data Formats. Update the intent component
description on line 77.

**`SYSTEM.md`** (line 66): Change "Goals, mission decomp" to "Goals, tasks".
Update line 88 to remove "missions" from YAML format list.

**`LORE_CONTRACT.md`**: Remove `missions/` from the intent row in the
component table (line 16). Remove the "Mission Generation" section (line 164).
Remove `lore mission list` from the read interface (line 214). Remove
`missions/` from the file paths section (line 303). Update "mission hints"
reference (line 140).

**`docs/tutorial.md`**: Remove any mission workflow examples.

**Other docs** in `docs/`: Remove mission mentions from
`capture-api-complete.md`, `capture-api-implementation.md`,
`capture-api-comparison.md`, `unified-capture-api.md`.

### 8. Update graph data

In `graph/data/graph.json` (line 70): change the intent node description from
"Goal management and mission decomposition" to "Goal management and task
delegation".

### 9. Delete the missions directory

```bash
rm -rf intent/data/missions/
```

The directory is empty, so this is safe.

### 10. Remove mission from test expectations

In `tests/test-capture-api.sh`: the two comments mentioning "mission" (lines
148, 238) are describing a known bug, not testing mission functionality.
Update the comments to remove the stale reference.

## What NOT to Do

- **Do not touch Neo's mission infrastructure.** Neo owns mission execution.
  This plan removes Lore's redundant mission definitions only.
- **Do not remove tasks from intent.** Tasks are standalone, claimable work
  items -- a different concept from missions. They stay.
- **Do not remove goals.** Goals define desired outcomes. They stay.
- **Do not add new functionality.** This is a pure removal.
- **Do not refactor the failures system** beyond removing the `--mission`
  parameter. The `--tool` and `--step` flags remain.

## Files to Modify

| File                          | Change                             |
| ----------------------------- | ---------------------------------- |
| `intent/lib/intent.sh`        | Remove mission functions + vars    |
| `intent/lib/spec.sh`          | Remove `mission_hints` template    |
| `intent/data/goals/*.yaml`    | Remove `mission_hints` blocks      |
| `lore.sh`                     | Remove mission routing, help, flag |
| `failures/lib/failures.sh`    | Remove mission parameter           |
| `mcp/src/index.ts`            | Remove mission from failures tool  |
| `intent/README.md`            | Rewrite without missions           |
| `CLAUDE.md`                   | Remove mission data format line    |
| `SYSTEM.md`                   | Update intent description          |
| `LORE_CONTRACT.md`            | Remove mission sections            |
| `docs/tutorial.md`            | Remove mission examples            |
| `docs/capture-api-*.md`       | Remove mission mentions            |
| `docs/unified-capture-api.md` | Remove mission mentions            |
| `graph/data/graph.json`       | Update intent node description     |
| `tests/test-capture-api.sh`   | Update comments                    |

## Acceptance Criteria

- `lore mission generate` and `lore mission list` no longer exist as commands
- `lore goal show <id>` displays goal details without a "Missions" section
- `lore fail ToolError "msg"` works without `--mission` flag
- `intent/data/missions/` directory does not exist
- `grep -r mission ~/dev/lore/{lore.sh,intent/,failures/,CLAUDE.md,SYSTEM.md}` returns zero matches (excluding `intent/data/goals/` notes
  field if any mention missions as prose)
- `LORE_CONTRACT.md` has no mission references
- All existing tests pass

## Testing

```bash
# Verify commands removed
lore mission generate foo 2>&1 | grep -q "Unknown"

# Verify failures still work without --mission
lore fail ToolError "test error" --tool Bash
lore failures --type ToolError

# Verify goal show works
lore goal show goal-1771254348-191098b1

# Grep for stragglers
grep -r "mission" lore.sh intent/ failures/ CLAUDE.md SYSTEM.md \
  LORE_CONTRACT.md mcp/src/index.ts

# Run existing tests
bash tests/test-capture-api.sh
```
