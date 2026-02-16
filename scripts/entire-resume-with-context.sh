#!/usr/bin/env bash
# Resume an Entire branch with Lore context injection
#
# Wraps `entire resume <branch>` to:
# 1. Run entire resume to restore checkpoint state
# 2. Query Lore for relevant patterns based on branch context
# 3. Display patterns before the agent session starts
#
# Usage: entire-resume-with-context.sh <branch> [entire-flags...]
#
# This closes the loop: checkpoints → Lore (via yeoman) → patterns → resume

set -euo pipefail

LORE_DIR="${LORE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

# Colors
CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'
BOLD='\033[1m'

# Disable colors if not a terminal
if [[ ! -t 1 ]]; then
    CYAN='' GREEN='' YELLOW='' NC='' BOLD=''
fi

usage() {
    echo "Usage: $(basename "$0") <branch> [entire-flags...]"
    echo ""
    echo "Resume an Entire branch with Lore context injection."
    echo ""
    echo "Examples:"
    echo "  $(basename "$0") feature/auth-refactor"
    echo "  $(basename "$0") fix/memory-leak --force"
    exit 1
}

# Check for branch argument or help flag
if [[ $# -lt 1 ]]; then
    usage
fi

case "$1" in
    -h|--help)
        usage
        ;;
esac

branch="$1"
shift

# Check dependencies
if ! command -v entire &>/dev/null; then
    echo "Error: entire CLI not found. Install with: brew install entire" >&2
    exit 1
fi

echo -e "${BOLD}=== Entire Resume with Lore Context ===${NC}"
echo ""

# Step 1: Gather context BEFORE entire resume (it may change the working dir state)
echo -e "${CYAN}Gathering context for branch: ${branch}${NC}"

# Extract context from branch name and any available checkpoint data
context_parts=()
context_parts+=("$branch")

# Try to get checkpoint context from Entire's explain command
# Skip if entire isn't set up in this repo (status check is fast)
if entire status 2>/dev/null | grep -q "enabled"; then
    checkpoint_info=$(entire explain --short 2>/dev/null | head -10 || true)
    if [[ -n "$checkpoint_info" ]]; then
        # Extract key terms from checkpoint info
        files_touched=$(echo "$checkpoint_info" | grep -oE '[a-zA-Z0-9_/-]+\.(ts|tsx|js|jsx|sh|py|go|rs|md)' | head -5 | tr '\n' ' ')
        [[ -n "$files_touched" ]] && context_parts+=("$files_touched")
    fi
fi

# Also check if we have git log context for the branch
if git show-ref --verify --quiet "refs/heads/${branch}" 2>/dev/null; then
    # Get recent commit messages on the branch
    recent_commits=$(git log "${branch}" --oneline -3 2>/dev/null | cut -d' ' -f2- || true)
    if [[ -n "$recent_commits" ]]; then
        context_parts+=("$recent_commits")
    fi
fi

# Step 2: Query Lore for relevant patterns
combined_context="${context_parts[*]}"
echo -e "${CYAN}Context: ${combined_context:0:80}...${NC}"
echo ""

if [[ -x "${LORE_DIR}/lore.sh" ]]; then
    echo -e "${GREEN}--- Relevant Lore Patterns ---${NC}"
    
    # Use patterns suggest command
    patterns_output=$("${LORE_DIR}/patterns/patterns.sh" suggest "${combined_context}" --limit 5 2>/dev/null || true)
    
    if [[ -n "$patterns_output" ]] && echo "$patterns_output" | grep -qE '^\s*[0-9]+\.'; then
        echo "$patterns_output"
    else
        echo "  (no matching patterns found)"
    fi
    echo ""
    
    # Also search journal for related decisions
    echo -e "${GREEN}--- Related Decisions ---${NC}"
    decisions=$("${LORE_DIR}/lore.sh" search "${branch}" --limit 3 2>/dev/null | grep -v "^Search" | head -10 || true)
    
    if [[ -n "$decisions" ]]; then
        echo "$decisions"
    else
        echo "  (no related decisions)"
    fi
    echo ""
else
    echo -e "${YELLOW}Warning: Lore not available at ${LORE_DIR}${NC}"
fi

# Step 3: Run entire resume
echo -e "${BOLD}--- Running: entire resume ${branch} $* ---${NC}"
echo ""

# Pass through to entire resume
entire resume "${branch}" "$@"

# Step 4: Post-resume: sync any new checkpoints and remind about Lore
echo ""
echo -e "${CYAN}Tip: Run 'make sync-entire' to sync new checkpoints to Lore${NC}"
