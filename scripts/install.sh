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

seed_file "${DATA_DIR}/registry/data/metadata.yaml" "$(cat <<'YAML'
version: "1.0"
metadata: {}
YAML
)"
seed_file "${DATA_DIR}/registry/data/clusters.yaml" "$(cat <<'YAML'
version: "1.0"
clusters: {}
YAML
)"
seed_file "${DATA_DIR}/registry/data/relationships.yaml" "$(cat <<'YAML'
version: "1.0"
dependencies: {}
shared: {}
integrations: {}
pattern_sharing: []
YAML
)"
seed_file "${DATA_DIR}/registry/data/contracts.yaml" "$(cat <<'YAML'
version: "1.0"
contracts: {}
YAML
)"

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

# Step 4: Symlink lore to PATH
BIN_DIR="${HOME}/.local/bin"
mkdir -p "$BIN_DIR"
SYMLINK="${BIN_DIR}/lore"

if [[ -L "$SYMLINK" || -f "$SYMLINK" ]]; then
    existing="$(readlink -f "$SYMLINK" 2>/dev/null || echo "$SYMLINK")"
    if [[ "$existing" == "${LORE_DIR}/lore.sh" ]]; then
        log "Symlink already exists: ${SYMLINK} → lore.sh"
    else
        warn "Existing ${SYMLINK} points to ${existing}. Skipping."
        warn "Remove it manually and re-run to create the symlink."
    fi
elif [[ "$DRY_RUN" == true ]]; then
    dry "ln -sf ${LORE_DIR}/lore.sh ${SYMLINK}"
else
    ln -sf "${LORE_DIR}/lore.sh" "$SYMLINK"
    log "Symlinked: ${SYMLINK} → lore.sh"
fi

# Check PATH
if ! echo "$PATH" | tr ':' '\n' | grep -qx "$BIN_DIR"; then
    warn "${BIN_DIR} is not in your PATH. Add it to ~/.zshrc:"
    echo "  export PATH=\"\${HOME}/.local/bin:\${PATH}\""
fi

# Step 5: Register lore as a local Claude Code plugin
CLAUDE_PLUGINS="${HOME}/.claude/plugins/marketplaces/local"
MARKETPLACE_JSON="${CLAUDE_PLUGINS}/.claude-plugin/marketplace.json"
PLUGIN_LINK="${CLAUDE_PLUGINS}/plugins/lore"

if [[ ! -d "$CLAUDE_PLUGINS" ]]; then
    warn "~/.claude/plugins/marketplaces/local not found — skipping plugin registration."
    warn "Create the local marketplace first, then re-run install."
else
    if [[ "$DRY_RUN" == true ]]; then
        dry "ln -sf ${LORE_DIR} ${PLUGIN_LINK}"
        dry "patch ${MARKETPLACE_JSON} with lore plugin entry"
        dry "patch installed_plugins.json with lore@local entry"
    else
        # Symlink lore repo into marketplace plugins directory
        if [[ -L "$PLUGIN_LINK" && "$(readlink -f "$PLUGIN_LINK" 2>/dev/null)" == "$LORE_DIR" ]]; then
            log "Plugin symlink already exists: ${PLUGIN_LINK}"
        elif [[ -e "$PLUGIN_LINK" ]]; then
            warn "Plugin path ${PLUGIN_LINK} already exists but points elsewhere. Skipping."
        else
            mkdir -p "${CLAUDE_PLUGINS}/plugins"
            ln -sf "$LORE_DIR" "$PLUGIN_LINK"
            log "Plugin symlink created: ${PLUGIN_LINK} → ${LORE_DIR}"
        fi

        # Register in marketplace.json
        if [[ ! -f "$MARKETPLACE_JSON" ]]; then
            warn "${MARKETPLACE_JSON} not found — skipping marketplace registration."
        elif jq -e '.plugins[] | select(.name == "lore")' "$MARKETPLACE_JSON" >/dev/null 2>&1; then
            log "Plugin already in ${MARKETPLACE_JSON}."
        else
            tmp="$(mktemp)"
            jq '.plugins += [{
                "name": "lore",
                "description": "Explicit context management for multi-agent systems — capture decisions, patterns, and failures across projects",
                "version": "0.1.0",
                "source": "./plugins/lore",
                "category": "development"
            }]' "$MARKETPLACE_JSON" > "$tmp" && mv "$tmp" "$MARKETPLACE_JSON"
            log "Plugin added to ${MARKETPLACE_JSON}."
        fi

        # Register in installed_plugins.json (required for commands to appear in Claude Code)
        INSTALLED_JSON="${HOME}/.claude/plugins/installed_plugins.json"
        if [[ ! -f "$INSTALLED_JSON" ]]; then
            warn "installed_plugins.json not found — skipping installation."
        elif jq -e '.plugins["lore@local"]' "$INSTALLED_JSON" >/dev/null 2>&1; then
            log "Plugin already in installed_plugins.json."
        else
            git_sha="$(git -C "${LORE_DIR}" rev-parse HEAD 2>/dev/null || echo "")"
            now="$(date -u +%Y-%m-%dT%H:%M:%S.000Z)"
            tmp="$(mktemp)"
            jq --arg sha "$git_sha" --arg now "$now" --arg path "$LORE_DIR" '
                .plugins["lore@local"] = [{
                    "scope": "user",
                    "installPath": $path,
                    "version": "0.1.0",
                    "installedAt": $now,
                    "lastUpdated": $now,
                    "gitCommitSha": $sha
                }]
            ' "$INSTALLED_JSON" > "$tmp" && mv "$tmp" "$INSTALLED_JSON"
            log "Plugin installed. Restart Claude Code for /lore:capture and /lore:handoff to appear."
        fi
    fi
fi

# Step 6: Rebuild search index
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

# Step 7: Print shell config instructions
echo ""
echo -e "${BOLD}Almost done!${NC} Add this to your shell profile (~/.bashrc or ~/.zshrc):"
echo ""
echo "  export LORE_DATA_DIR=${DATA_DIR}"
echo ""
echo "Then verify:"
echo ""
echo "  lore --help"
echo ""
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
