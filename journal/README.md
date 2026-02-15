# Decision Journal

A memory system component for capturing, querying, and learning from decisions made during AI agent sessions.

## Overview

The Decision Journal automatically captures decisions with their rationale, alternatives considered, and outcomes. Over time, it builds a searchable knowledge base that helps agents (and humans) understand why certain choices were made and what was learned from them.

## Installation

```bash
# Clone or copy to your project
cp -r journal/ ~/.lore/journal/

# Make executable
chmod +x ~/.lore/journal/journal.sh

# Add to PATH (optional)
export PATH="$PATH:$HOME/.lore/journal"
```

**Dependencies**: `bash`, `jq`

## Quick Start

```bash
# Record a decision
./journal.sh record "Use JSONL for storage" \
  --rationale "Simpler than SQLite, append-only is sufficient" \
  --alternatives "SQLite,JSON file,PostgreSQL"

# Search past decisions
./journal.sh query "storage"

# Get context for a file you're working on
./journal.sh context src/store.sh

# Mark a lesson learned
./journal.sh learn dec-abc123 "JSONL works great but needs periodic compaction at scale"
```

## Commands

### record

Record a new decision with optional metadata.

```bash
# Basic recording
journal.sh record "Choose monorepo structure"

# With rationale and alternatives
journal.sh record "Use Rust for CLI" \
  --rationale "Performance critical, good CLI ecosystem" \
  --alternatives "Go,Python,Node.js" \
  --tags "language,tooling"

# Inline format (alternative syntax)
journal.sh record "Use monorepo [because: easier dependency management] [vs: polyrepo, multi-repo]"

# Link to affected files
journal.sh record "Refactor auth module" --files "src/auth.rs,src/session.rs"
```

**Options:**

- `--rationale, -r` - Why this approach was chosen
- `--alternatives, -a` - Comma-separated list of other options considered
- `--tags, -t` - Comma-separated tags for categorization
- `--type` - Explicit decision type (architecture, implementation, naming, tooling, process, bugfix, refactor)
- `--files, -f` - Comma-separated list of affected files

### query

Search past decisions by text.

```bash
journal.sh query "storage format"
journal.sh query "authentication"
```

### context

Get decisions related to a file or topic.

```bash
# File context - shows decisions that affected this file
journal.sh context src/store.sh

# Topic context - shows decisions about a concept
journal.sh context "error handling"
```

### learn

Add a lesson learned to an existing decision.

```bash
journal.sh learn dec-abc123 "This approach worked well for small datasets but needs optimization for larger ones"
```

### update

Update a decision's outcome or details.

```bash
# Mark as successful
journal.sh update dec-abc123 --outcome successful

# Mark as revised (you changed your mind)
journal.sh update dec-abc123 --outcome revised

# Update rationale
journal.sh update dec-abc123 --rationale "Updated reasoning after more testing"
```

**Outcome values:** `pending`, `successful`, `revised`, `abandoned`

### list

List decisions with optional filters.

```bash
# Recent decisions
journal.sh list --recent 20

# Filter by type
journal.sh list --type architecture

# Filter by outcome
journal.sh list --outcome pending

# Filter by tag
journal.sh list --tag performance

# Current session only
journal.sh list --session
```

### link

Link two related decisions.

```bash
journal.sh link dec-abc123 dec-def456
journal.sh link dec-abc123 dec-def456 "supersedes"
```

### stats

Show decision journal statistics.

```bash
journal.sh stats
```

### export

Export decisions in various formats.

```bash
# JSON export
journal.sh export --format json

# Markdown export
journal.sh export --format markdown

# Graphviz DOT (for visualization)
journal.sh export --format dot > decisions.dot
dot -Tpng decisions.dot -o decisions.png

# Mermaid diagram
journal.sh export --format mermaid

# Export specific session
journal.sh export --session session-abc12345
```

## Integration with CLAUDE.md

Add a session retro section to your CLAUDE.md:

```markdown
## Session Retro: YYYY-MM-DD - Project Name

### Key Decisions

$(journal.sh export --session $LORE_SESSION_ID --format markdown)

### Lessons Learned

$(journal.sh list --session | grep -A1 "lesson_learned" | grep -v null)
```

Or create a git hook to prompt for decision recording:

```bash
#!/bin/bash
# .git/hooks/post-commit
echo "Any decisions to record for this commit?"
read -p "Decision (or Enter to skip): " decision
if [[ -n "$decision" ]]; then
  journal.sh record "$decision" --files "$(git diff-tree --no-commit-id --name-only -r HEAD | paste -sd,)"
fi
```

## Data Storage

Decisions are stored in:

- `data/decisions.jsonl` - Append-only decision log
- `data/index/` - Search indexes by date, type, entity, and tag
- Decision relationships stored in `graph/data/graph.json` via the graph library

## Decision Schema

```json
{
  "id": "dec-abc12345",
  "timestamp": "2024-01-15T10:30:00Z",
  "session_id": "session-xyz98765",
  "decision": "Use JSONL for decision storage",
  "rationale": "Simpler than SQLite, append-only pattern matches our use case",
  "alternatives": ["SQLite", "JSON file", "PostgreSQL"],
  "outcome": "successful",
  "type": "architecture",
  "entities": ["data/decisions.jsonl", "lib/store.sh"],
  "tags": ["storage", "simplicity"],
  "lesson_learned": "Works well up to ~10k decisions, may need compaction strategy",
  "related_decisions": ["dec-def67890"],
  "git_commit": "abc123def456..."
}
```

## Environment Variables

- `LORE_SESSION_ID` - Override automatic session ID generation
- `LORE_DATA_DIR` - Override default data directory

## Auto-Detection

The journal automatically:

1. **Detects decision type** based on keywords:
   - `architecture`, `structure`, `design` -> architecture
   - `tool`, `library`, `dependency` -> tooling
   - `name`, `rename`, `convention` -> naming
   - `fix`, `bug`, `error` -> bugfix
   - `refactor`, `cleanup`, `simplify` -> refactor

2. **Extracts entities** from decision text:
   - File paths (e.g., `src/main.rs`)
   - Function names (e.g., `parse_config()`)
   - Backtick-quoted terms (e.g., `` `SessionManager` ``)

3. **Links to git** if in a repository

4. **Auto-links related decisions** based on shared entities

## Tips

- Record decisions at the moment you make them, not after the fact
- Include the "why" in your rationale, not just the "what"
- Use tags consistently across your project
- Review pending decisions periodically and update outcomes
- Export and include in session retros for team visibility
