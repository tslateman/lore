# Plan: Entire CLI Yeoman Integration

Status: Implemented
Completed: 2026-02-16

## Context

Entire CLI captures agent checkpoints on git push. Checkpoints store session
metadata (files touched, token usage, prompts) on a separate branch
(`entire/checkpoints/v1`). This data should flow into Lore's journal as
decisions, following the same yeoman pattern used by Mirror.

**Source:** Council Entire Integration initiative, Phase 2.
See `~/dev/council/initiatives/entire-integration.md`.

**Goal:** `goal-1771258471-d0f6375a`

## Entire Schema (Verified)

Directory structure on `entire/checkpoints/v1` branch:

```
<hash_prefix>/<checkpoint_id>/
├── metadata.json           # Session-level metadata
└── 0/                      # First checkpoint in session
    ├── metadata.json       # Checkpoint-level metadata
    ├── context.md          # Session context with user prompts
    ├── full.jsonl          # Full transcript
    ├── prompt.txt          # Initial prompt
    └── content_hash.txt    # Content hash
```

**Session metadata** (`<hash>/<checkpoint_id>/metadata.json`):

- `checkpoint_id`: "7f699508ff13"
- `branch`: "main"
- `files_touched`: ["file1.md", "file2.sh"]
- `checkpoints_count`: 2
- `token_usage`: { input_tokens, output_tokens, ... }

**Checkpoint metadata** (`<hash>/<checkpoint_id>/0/metadata.json`):

- `checkpoint_id`: "7f699508ff13"
- `session_id`: "08a76340-7adb-4b8e-abc6-81eb6964ed03"
- `created_at`: "2026-02-15T03:10:35.321939Z"
- `branch`: "main"
- `files_touched`: [...]
- `agent`: "Claude Code"
- `token_usage`: {...}

## What to Do

### 1. Create `scripts/entire-yeoman.sh`

**File:** `scripts/entire-yeoman.sh`

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LORE_DIR="${LORE_DIR:-$(dirname "$SCRIPT_DIR")}"
MARKER_FILE="${LORE_DIR}/.entire-sync-marker"

# Check dependencies
command -v git &>/dev/null || { echo "git required"; exit 1; }
command -v jq &>/dev/null || { echo "jq required"; exit 1; }
[[ -x "${LORE_DIR}/lore.sh" ]] || { echo "Lore not found at ${LORE_DIR}"; exit 1; }

# Check if entire/checkpoints/v1 branch exists
if ! git show-ref --verify --quiet refs/heads/entire/checkpoints/v1 2>/dev/null; then
    echo "No Entire checkpoints branch found"
    exit 0
fi

# Read last synced checkpoint
last_synced=""
[[ -f "${MARKER_FILE}" ]] && last_synced=$(cat "${MARKER_FILE}")

synced=0

# List all checkpoint directories (format: <hash>/<checkpoint_id>)
# Find metadata.json files at the checkpoint level (not session level)
git ls-tree -r --name-only entire/checkpoints/v1 | grep '/0/metadata.json$' | while read -r metadata_path; do
    # Extract checkpoint directory (e.g., "7f/699508ff13/0")
    checkpoint_dir=$(dirname "$metadata_path")
    session_dir=$(dirname "$checkpoint_dir")

    # Read checkpoint metadata
    checkpoint_meta=$(git show "entire/checkpoints/v1:${metadata_path}" 2>/dev/null) || continue

    checkpoint_id=$(echo "$checkpoint_meta" | jq -r '.checkpoint_id // ""')
    session_id=$(echo "$checkpoint_meta" | jq -r '.session_id // ""')
    created_at=$(echo "$checkpoint_meta" | jq -r '.created_at // ""')
    branch=$(echo "$checkpoint_meta" | jq -r '.branch // "unknown"')
    agent=$(echo "$checkpoint_meta" | jq -r '.agent // "unknown"')
    files_touched=$(echo "$checkpoint_meta" | jq -r '.files_touched | join(", ")' 2>/dev/null || echo "")

    # Skip if already synced (compare checkpoint_id)
    if [[ -n "${last_synced}" ]]; then
        if grep -qxF "${checkpoint_id}" "${MARKER_FILE}" 2>/dev/null; then
            continue
        fi
    fi

    # Try to get context summary from context.md
    context_path="${checkpoint_dir}/context.md"
    summary=""
    if git show "entire/checkpoints/v1:${context_path}" &>/dev/null; then
        # Extract first user prompt as summary (first ### Prompt section)
        summary=$(git show "entire/checkpoints/v1:${context_path}" 2>/dev/null | \
            sed -n '/^### Prompt 1/,/^### Prompt 2/p' | head -5 | tail -4 | tr '\n' ' ' | cut -c1-100)
    fi
    [[ -z "$summary" ]] && summary="Checkpoint ${checkpoint_id} on ${branch}"

    # Build tags
    tags="entire,checkpoint:${checkpoint_id},branch:${branch},agent:${agent}"
    [[ -n "${session_id}" ]] && tags="${tags},session:${session_id}"

    # Build rationale from files touched
    rationale="Files: ${files_touched:-none}"
    [[ -n "${created_at}" ]] && rationale="${rationale}. Created: ${created_at}"

    # Sync to Lore journal
    "${LORE_DIR}/lore.sh" remember "${summary}" \
        --rationale "${rationale}" \
        --tags "${tags}" \
        --type "other" 2>/dev/null || {
        echo "Warning: Failed to sync checkpoint ${checkpoint_id}, continuing..."
        continue
    }

    echo "Synced: ${checkpoint_id} (session: ${session_id:-unknown})"
    synced=$((synced + 1))
    echo "${checkpoint_id}" >> "${MARKER_FILE}"
done

echo "Synced ${synced} checkpoint(s) to Lore."
```

### 2. Add Makefile target

**File:** `Makefile`

Add a sync target:

```makefile
sync-entire:
	@./scripts/entire-yeoman.sh
```

### 3. Update CLAUDE.md

**File:** `CLAUDE.md`

Add to integration section:

```markdown
## Entire Checkpoint Sync

Sync Entire checkpoints to journal: `make sync-entire`
Runs `scripts/entire-yeoman.sh` following the yeoman pattern.
```

## What NOT to Do

- Do not install Entire CLI in this plan -- already done
- Do not modify lore.sh itself -- yeoman scripts are standalone
- Do not auto-trigger on git hooks yet -- manual sync first
- Do not duplicate checkpoint data -- marker file tracks synced IDs
- Do not depend on Geordi -- yeoman writes to Lore, Geordi reads from Lore

## Files to Create/Modify

| File                       | Action | Change                   |
| -------------------------- | ------ | ------------------------ |
| `scripts/entire-yeoman.sh` | Create | Yeoman script            |
| `Makefile`                 | Modify | Add `sync-entire` target |
| `CLAUDE.md`                | Modify | Document integration     |

## Acceptance Criteria

- [ ] `scripts/entire-yeoman.sh` exists and is executable
- [ ] Script reads from `entire/checkpoints/v1` branch
- [ ] Checkpoints sync to Lore journal as decisions
- [ ] Marker file prevents duplicate syncs (stores synced checkpoint IDs)
- [ ] Re-running produces no duplicates
- [ ] `make sync-entire` runs the script
- [ ] Script handles missing branch gracefully (exit 0)

## Testing

```bash
# Run sync (Entire already enabled in lore repo)
./scripts/entire-yeoman.sh

# Verify in journal
./lore.sh search "entire"

# Re-run should produce no duplicates
./scripts/entire-yeoman.sh

# Check marker file
cat .entire-sync-marker
```

## Dependencies

| Dependency             | Status    | Notes             |
| ---------------------- | --------- | ----------------- |
| Entire CLI installed   | Complete  | Already installed |
| Entire enabled in repo | Complete  | Branch exists     |
| jq                     | Available | Standard tool     |
| Mirror yeoman as model | Complete  | Pattern proven    |

## Outcome

Implemented as planned. `scripts/entire-yeoman.sh` exists, reads from the `entire/checkpoints/v1` branch, writes checkpoint metadata to the journal, and uses `.entire-sync-marker` to prevent duplicate syncs. The `Makefile` adds both `sync-entire` and `sync-all` targets. The script landed in `scripts/` rather than in `hooks/` as some references suggested.
