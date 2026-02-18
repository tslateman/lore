#!/usr/bin/env bash
# install.sh - Setup and migrate Lore data directory
#
# Separates user data (decisions, patterns, sessions) from tool code.
# Idempotent: safe to run multiple times.
#
# Usage: scripts/install.sh [--data-dir PATH] [--dry-run] [--skip-migrate]

set -euo pipefail

LORE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Defaults
DATA_DIR="${HOME}/.local/share/lore"
DRY_RUN=false
SKIP_MIGRATE=false

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

usage() {
    cat <<EOF
Usage: scripts/install.sh [OPTIONS]

Setup Lore data directory and migrate existing data from the repo.

Options:
  --data-dir PATH   Data directory (default: ~/.local/share/lore)
  --dry-run         Show what would happen without making changes
  --skip-migrate    Fresh install only, skip data migration
  -h, --help        Show this help
EOF
}

log() { echo -e "${GREEN}[install]${NC} $*"; }
warn() { echo -e "${YELLOW}[install]${NC} $*"; }
err() { echo -e "${RED}[install]${NC} $*" >&2; }
dry() { echo -e "${DIM}[dry-run]${NC} $*"; }

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --data-dir)   DATA_DIR="$2"; shift 2 ;;
        --dry-run)    DRY_RUN=true; shift ;;
        --skip-migrate) SKIP_MIGRATE=true; shift ;;
        -h|--help)    usage; exit 0 ;;
        *)            err "Unknown option: $1"; usage; exit 1 ;;
    esac
done

# Expand tilde
DATA_DIR="${DATA_DIR/#\~/$HOME}"

# Check: already migrated?
if [[ -n "${LORE_DATA_DIR:-}" && -d "${LORE_DATA_DIR}" ]]; then
    # Check if populated (has at least one non-empty data file)
    if find "${LORE_DATA_DIR}" -name "*.jsonl" -o -name "*.yaml" -o -name "*.json" 2>/dev/null | head -1 | grep -q .; then
        log "LORE_DATA_DIR already set to ${LORE_DATA_DIR} and contains data."
        log "Already migrated — nothing to do."
        exit 0
    fi
fi

echo -e "${BOLD}Lore Install${NC}"
echo "  Tool code:  ${LORE_DIR}"
echo "  Data dir:   ${DATA_DIR}"
echo ""

# Step 1: Scaffold the data directory
log "Creating data directory structure..."

DIRS=(
    "${DATA_DIR}/journal/data/entries"
    "${DATA_DIR}/journal/data/index"
    "${DATA_DIR}/patterns/data"
    "${DATA_DIR}/failures/data"
    "${DATA_DIR}/inbox/data"
    "${DATA_DIR}/transfer/data/sessions"
    "${DATA_DIR}/graph/data"
    "${DATA_DIR}/intent/data/goals"
    "${DATA_DIR}/registry/data"
)

for dir in "${DIRS[@]}"; do
    if [[ "$DRY_RUN" == true ]]; then
        dry "mkdir -p ${dir}"
    else
        mkdir -p "${dir}"
    fi
done

# Seed empty files (only if missing)
seed_file() {
    local file="$1"
    local content="${2:-}"
    if [[ -f "$file" ]]; then
        return
    fi
    if [[ "$DRY_RUN" == true ]]; then
        dry "create ${file}"
        return
    fi
    if [[ -n "$content" ]]; then
        echo "$content" > "$file"
    else
        touch "$file"
    fi
}

seed_file "${DATA_DIR}/journal/data/decisions.jsonl"
seed_file "${DATA_DIR}/failures/data/failures.jsonl"
seed_file "${DATA_DIR}/inbox/data/observations.jsonl"
seed_file "${DATA_DIR}/patterns/data/patterns.yaml" "$(cat <<'YAML'
# Pattern Learner Database
patterns: []
anti_patterns: []
YAML
)"
seed_file "${DATA_DIR}/graph/data/graph.json" '{"nodes":{},"edges":[]}'

log "Directory structure ready."

# Step 2: Migrate existing data from repo
if [[ "$SKIP_MIGRATE" == true ]]; then
    log "Skipping migration (--skip-migrate)."
else
    echo ""
    log "Checking for data to migrate from repo..."

    # Files to migrate: source -> dest (relative to respective roots)
    MIGRATE_FILES=(
        "journal/data/decisions.jsonl"
        "patterns/data/patterns.yaml"
        "patterns/data/flags.jsonl"
        "failures/data/failures.jsonl"
        "inbox/data/observations.jsonl"
        "graph/data/graph.json"
    )

    migrated=0
    for rel in "${MIGRATE_FILES[@]}"; do
        src="${LORE_DIR}/${rel}"
        dst="${DATA_DIR}/${rel}"
        if [[ -f "$src" ]] && [[ -s "$src" ]]; then
            size=$(wc -c < "$src" | tr -d ' ')
            if [[ "$DRY_RUN" == true ]]; then
                dry "copy ${rel} (${size} bytes)"
            else
                cp "$src" "$dst"
                log "  ${rel} (${size} bytes)"
            fi
            migrated=$((migrated + 1))
        fi
    done

    # Migrate journal entries directory
    if [[ -d "${LORE_DIR}/journal/data/entries" ]]; then
        entry_count=$(find "${LORE_DIR}/journal/data/entries" -type f 2>/dev/null | wc -l | tr -d ' ')
        if [[ "$entry_count" -gt 0 ]]; then
            if [[ "$DRY_RUN" == true ]]; then
                dry "copy journal/data/entries/ (${entry_count} files)"
            else
                cp -r "${LORE_DIR}/journal/data/entries/"* "${DATA_DIR}/journal/data/entries/" 2>/dev/null || true
                log "  journal/data/entries/ (${entry_count} files)"
            fi
            migrated=$((migrated + 1))
        fi
    fi

    # Migrate journal index directory
    if [[ -d "${LORE_DIR}/journal/data/index" ]]; then
        idx_count=$(find "${LORE_DIR}/journal/data/index" -type f 2>/dev/null | wc -l | tr -d ' ')
        if [[ "$idx_count" -gt 0 ]]; then
            if [[ "$DRY_RUN" == true ]]; then
                dry "copy journal/data/index/ (${idx_count} files)"
            else
                cp -r "${LORE_DIR}/journal/data/index/"* "${DATA_DIR}/journal/data/index/" 2>/dev/null || true
                log "  journal/data/index/ (${idx_count} files)"
            fi
            migrated=$((migrated + 1))
        fi
    fi

    # Migrate goal files
    if [[ -d "${LORE_DIR}/intent/data/goals" ]]; then
        goal_count=$(find "${LORE_DIR}/intent/data/goals" -name "*.yaml" -type f 2>/dev/null | wc -l | tr -d ' ')
        if [[ "$goal_count" -gt 0 ]]; then
            if [[ "$DRY_RUN" == true ]]; then
                dry "copy intent/data/goals/ (${goal_count} files)"
            else
                cp "${LORE_DIR}/intent/data/goals/"*.yaml "${DATA_DIR}/intent/data/goals/" 2>/dev/null || true
                log "  intent/data/goals/ (${goal_count} files)"
            fi
            migrated=$((migrated + 1))
        fi
    fi

    if [[ "$migrated" -eq 0 ]]; then
        log "No data to migrate."
    else
        log "Migrated ${migrated} items."
    fi
fi

# Step 3: Update .gitignore
echo ""
GITIGNORE="${LORE_DIR}/.gitignore"
MARKER="# User data (lives at LORE_DATA_DIR after migration)"

if grep -qF "$MARKER" "$GITIGNORE" 2>/dev/null; then
    log ".gitignore already has data exclusions."
else
    if [[ "$DRY_RUN" == true ]]; then
        dry "append data exclusions to .gitignore"
    else
        cat >> "$GITIGNORE" <<'EOF'

# User data (lives at LORE_DATA_DIR after migration)
journal/data/decisions.jsonl
journal/data/entries/
patterns/data/patterns.yaml
patterns/data/flags.jsonl
failures/data/failures.jsonl
inbox/data/observations.jsonl
graph/data/graph.json
intent/data/goals/*.yaml
EOF
        log "Updated .gitignore with data exclusions."
    fi
fi

# Step 4: Rebuild search index
echo ""
if [[ "$DRY_RUN" == true ]]; then
    dry "LORE_DATA_DIR=${DATA_DIR} lore index build"
    dry "LORE_DATA_DIR=${DATA_DIR} lore search test"
    dry "LORE_DATA_DIR=${DATA_DIR} lore resume"
else
    log "Building search index..."
    if LORE_DATA_DIR="${DATA_DIR}" "${LORE_DIR}/lore.sh" index build 2>/dev/null; then
        log "Search index built."
    else
        warn "Search index build failed (non-critical). Run 'lore index build' manually."
    fi

    # Quick verify
    log "Verifying..."
    if LORE_DATA_DIR="${DATA_DIR}" "${LORE_DIR}/lore.sh" search "test" >/dev/null 2>&1; then
        log "Search: OK"
    else
        warn "Search verification returned no results (may be expected for fresh installs)."
    fi
fi

# Step 5: Shell profile configuration
echo ""

EXPORT_LINE="export LORE_DATA_DIR=${DATA_DIR}"

# Detect shell profile
detect_profile() {
    local shell_name
    shell_name="$(basename "${SHELL:-/bin/bash}")"
    case "$shell_name" in
        zsh)  echo "${HOME}/.zshrc" ;;
        bash)
            # Prefer .bashrc on Linux, .bash_profile on macOS
            if [[ -f "${HOME}/.bash_profile" ]]; then
                echo "${HOME}/.bash_profile"
            else
                echo "${HOME}/.bashrc"
            fi
            ;;
        *)    echo "${HOME}/.profile" ;;
    esac
}

PROFILE="$(detect_profile)"

# Check if already present
if grep -qF "LORE_DATA_DIR" "$PROFILE" 2>/dev/null; then
    log "LORE_DATA_DIR already set in ${PROFILE}."
elif [[ "$DRY_RUN" == true ]]; then
    dry "append to ${PROFILE}: ${EXPORT_LINE}"
else
    echo "" >> "$PROFILE"
    echo "# Lore data directory (added by scripts/install.sh)" >> "$PROFILE"
    echo "$EXPORT_LINE" >> "$PROFILE"
    log "Added LORE_DATA_DIR to ${PROFILE}."
    export LORE_DATA_DIR="${DATA_DIR}"
fi

if [[ "$DRY_RUN" != true && "$SKIP_MIGRATE" != true ]]; then
    echo -e "${DIM}Repo data files were copied (not moved). After confirming everything"
    echo -e "works, you can remove them from the repo with:${NC}"
    echo ""
    echo "  git rm journal/data/decisions.jsonl patterns/data/patterns.yaml \\"
    echo "         failures/data/failures.jsonl inbox/data/observations.jsonl \\"
    echo "         graph/data/graph.json intent/data/goals/*.yaml"
    echo ""
fi
log "Done."
