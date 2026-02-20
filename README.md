# Lore

Explicit context management for multi-agent systems.

## Installation

### Requirements

- **bash** 4.0+
- **jq** - JSON processing
- **yq** - YAML processing
- **sqlite3** - Search index (included on macOS)

### Quick Install

```bash
# Clone the repository
git clone https://github.com/tslater/lore.git ~/dev/lore

# Add to PATH (add to ~/.bashrc or ~/.zshrc)
export PATH="$HOME/dev/lore:$PATH"

# Verify installation
lore --help
```

### Setup Data Directory

Lore stores user data (decisions, patterns, sessions) separately from tool
code. Run the install script to set this up:

```bash
./scripts/install.sh
```

This creates `~/.local/share/lore/` and migrates any existing data from the
repo. Add to your shell profile:

```bash
export LORE_DATA_DIR=~/.local/share/lore
```

### Install Dependencies (macOS)

```bash
brew install jq yq
```

### Install Dependencies (Linux)

```bash
# Debian/Ubuntu
sudo apt install jq sqlite3
pip install yq

# Or via snap
sudo snap install yq
```

## Usage

```bash
# One verb, four destinations — flags determine type
lore capture "Users retry after timeout"                                    # → observation (inbox)
lore capture "Use JSONL for storage" --rationale "Append-only, simple"      # → decision (journal)
lore capture "Safe bash arithmetic" --solution 'Use x=$((x+1))'            # → pattern (patterns)
lore capture "Permission denied" --error-type ToolError                     # → failure (failures)

# Shortcuts still work
lore remember "Use JSONL for storage" --rationale "Append-only, simple"
lore learn "Safe bash arithmetic" --solution 'Use x=$((x+1))'
lore fail ToolError "Permission denied"

# End a session with handoff notes
lore handoff "Auth implementation 80% complete, need OAuth integration"

# Resume previous session at start of new session
lore resume

# Search across all components
lore search "authentication"

# Graph-enhanced search (follows relationships)
lore search "authentication" --graph-depth 2
```

Run `lore help` for all commands, or `lore help <topic>` for details on capture, search, intent, registry, or components. See the [tutorial](docs/tutorial.md) for a hands-on walkthrough.

## Why Lore

MEMORY.md gives agents implicit context—loaded into the prompt, hoped to be relevant. Lore provides explicit context—structured writes, typed queries, cross-project assembly. This matters when:

- Multiple agents need the same context
- Context exceeds what fits in a system prompt
- You need to query across time ("What did we decide about auth?")

### Search

Two retrieval phases, used together:

1. **FTS5** — Keyword search with BM25 ranking, boosted by recency, frequency, importance, and project affinity
2. **Graph** — Traverse relationships to surface connected knowledge (`--graph-depth 1-3`)

### Session Continuity

`lore resume` at session start loads the previous session's state—what was done, what's next, what's blocked. `lore handoff` at session end captures context for the next agent.

### Structured Storage

Journal captures decisions with rationale. Patterns capture lessons learned. Graph connects concepts. These components earn their keep at scale—when flat files stop fitting in a prompt.

## Components

| Component     | Purpose               | Key Question                           |
| ------------- | --------------------- | -------------------------------------- |
| **journal/**  | Decision capture      | "Why did we choose this?"              |
| **patterns/** | Lessons learned       | "What did we learn?"                   |
| **transfer/** | Session succession    | "What's next?"                         |
| **graph/**    | Knowledge connections | "What relates to this?"                |
| **registry/** | Project metadata      | "What exists and how does it connect?" |
| **intent/**   | Goals and specs       | "What are we trying to achieve?"       |
| **inbox/**    | Raw observations      | "What did we notice?"                  |

## Data Storage

User data lives at `$LORE_DATA_DIR` (default: `~/.local/share/lore`):

```
~/.local/share/lore/
├── journal/data/      # decisions.jsonl
├── patterns/data/     # patterns.yaml
├── transfer/data/     # sessions/*.json
├── graph/data/        # graph.json
├── intent/data/       # goals/
├── inbox/data/        # observations.jsonl
├── failures/data/     # failures.jsonl
└── search.db          # FTS5 index, embeddings, graph cache
```

Run `lore init` to scaffold this structure, or `scripts/install.sh` to
migrate existing data.

## Integration

Projects integrate via `lib/lore-client-base.sh`—fail-silent wrappers that record decisions and patterns without blocking if Lore is unavailable. See `LORE_CONTRACT.md` for the full interface.

## MCP Server

Lore exposes an MCP server for AI agents:

```bash
cd mcp && npm install && npm run build
```

Add to your Claude Code configuration:

```json
{
  "mcpServers": {
    "lore": {
      "command": "node",
      "args": ["/path/to/lore/mcp/build/index.js"],
      "env": {
        "LORE_DIR": "/path/to/lore",
        "LORE_DATA_DIR": "~/.local/share/lore"
      }
    }
  }
}
```

Tools exposed: `lore_search`, `lore_context`, `lore_related`, `lore_remember`, `lore_learn`, `lore_resume`
