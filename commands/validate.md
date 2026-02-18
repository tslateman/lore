---
description: Run lore validate and fix any issues found
allowed-tools: [Bash, Read, Edit, Write, Grep, Glob]
---

Run Lore's validation suite and fix what it finds.

## Step 1: Run Validation

```bash
${CLAUDE_PLUGIN_ROOT}/lore.sh validate
```

## Step 2: Analyze Results

Parse the output. Each check reports PASS or FAIL with details.

The 9 validation checks:

1. mani.yaml project consistency
2. metadata.yaml structure
3. relationships.yaml references
4. clusters.yaml references
5. Tag encoding format
6. Contract locations
7. Stale references (ralph, monarch, lens)
8. Initiative staleness
9. Component directory structure

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

## Step 4: Re-validate

Run `${CLAUDE_PLUGIN_ROOT}/lore.sh validate` again to confirm all fixes.

## Step 5: Report

Output a summary:

```
Validation: [N] checks passed, [M] fixed
  Fixed:
    - [what was fixed and where]
  Still failing:
    - [what couldn't be auto-fixed and why]
```

If everything passes on the first run, just say so.
