---
description: Run lore validate and fix any issues found
allowed-tools: [Bash, Read, Edit, Write, Grep, Glob]
---

Run Lore's validation suite and fix what it finds.

## Step 1: Run Validation

```bash
lore validate
```

## Step 2: Analyze Results

Parse the output. Each check reports PASS or FAIL with details.

The 11 validation checks:

1. metadata.yaml projects exist in mani.yaml
2. clusters.yaml components exist in mani.yaml
3. relationships.yaml references exist in mani.yaml
4. contracts.yaml paths exist on disk
5. Stale names (monarch, lineage, lens, neo, ralph) in active files
6. Cluster tags match clusters.yaml components
7. Archived projects have no cluster tags
8. All projects have type: and status: tags
9. Initiative staleness across CLAUDE.md files
10. Markdown path references resolve (dead links, moved plans)
11. `lore` commands in docs match the dispatch table

## Step 3: Fix Failures

For each FAIL:

- Read the relevant file to understand the issue
- Apply the minimal fix — do not refactor surrounding code
- Re-run the specific check if possible to confirm

Common fixes:

- **Stale references**: Replace retired project names in markdown files
- **Tag inconsistencies**: Fix prefix format in mani.yaml (`type:`, `lang:`, `status:`, `cluster:`)
- **Missing metadata fields**: Add required fields to registry/metadata.yaml
- **Broken relationships**: Remove references to nonexistent projects in relationships.yaml
- **Initiative staleness**: Update or archive stale initiatives in council/initiatives/
- **Dead path references**: Point the doc at the file's current location (the warning suggests plans/archive/ when the plan moved there)
- **Unknown lore commands**: Update the doc to the current command name (check the dispatch table in lore.sh)

## Step 4: Re-validate

Run `lore validate` again to confirm all fixes.

## Step 5 (optional): Deep Prose Review

```bash
lore validate --prose-deep
```

Emits a JSON manifest of architectural claims from SYSTEM.md and CLAUDE.md
(sentences with markers like "Not bridged", "never", "always", "only",
"does not"), each mapped to the component or lib file it likely concerns.
Judge each claim against the mapped files and fix contradictions. With
`LORE_VALIDATE_DEEP=1` and the `claude` CLI installed, the manifest is
judged automatically.

## Step 6: Report

Output a summary:

```
Validation: [N] checks passed, [M] fixed
  Fixed:
    - [what was fixed and where]
  Still failing:
    - [what couldn't be auto-fixed and why]
```

If everything passes on the first run, just say so.
