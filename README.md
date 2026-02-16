# Lore

Explicit context management for multi-agent systems.

## Installation

### Requirements

- **bash** 4.0+
- **jq** - JSON processing
- **yq** - YAML processing
- **sqlite3** - Search index (included on macOS)

Optional for semantic search:

- **Ollama** with `nomic-embed-text` model
- **Python 3** for vector similarity

### Quick Install

```bash
# Clone the repository
git clone https://github.com/tslater/lore.git ~/dev/lore

# Add to PATH (add to ~/.bashrc or ~/.zshrc)
export PATH="$HOME/dev/lore:$PATH"

# Verify installation
lore --help
```

### Install Dependencies (macOS)

```bash
brew install jq yq

# Optional: semantic search
brew install ollama
ollama pull nomic-embed-text
```

### Install Dependencies (Linux)

```bash
# Debian/Ubuntu
sudo apt install jq sqlite3
pip install yq

# Or via snap
sudo snap install yq

# Optional: Ollama (see https://ollama.ai)
```

## Usage

```bash
# Record decisions, patterns, and failures with one command
lore capture "Use JSONL for storage" --rationale "Append-only, simple"
lore capture "Safe bash arithmetic" --solution 'Use x=$((x+1))' --context "set -e scripts"
lore capture "Permission denied" --error-type ToolError

# Or use shortcuts
lore remember "Use JSONL for storage" --rationale "Append-only, simple"
lore learn "Safe bash arithmetic" --solution 'Use x=$((x+1))'
lore fail ToolError "Permission denied"

# End a session with handoff notes
lore handoff "Auth implementation 80% complete, need OAuth integration"

# Resume previous session at start of new session
lore resume

# Search across all components
lore search "authentication"

# Semantic search (requires Ollama)
lore search "retry logic" --mode semantic

# Graph-enhanced search (follows relationships)
lore search "authentication" --graph-depth 2
```

Run `lore --help` for the full command list.

## Why Lore

MEMORY.md gives agents implicit context—loaded into the prompt, hoped to be relevant. Lore provides explicit context—structured writes, typed queries, cross-project assembly. This matters when:

- Multiple agents need the same context
- Context exceeds what fits in a system prompt
- You need to query across time ("What did we decide about auth?")

### Search

Three retrieval phases, used together:

1. **FTS5** - Keyword search with BM25 ranking
2. **Semantic** - Vector embeddings find conceptually related content ("retry logic" → "exponential backoff")
3. **Graph** - Traverse relationships to surface connected knowledge

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
| **intent/**   | Goals and missions    | "What are we trying to achieve?"       |
| **inbox/**    | Raw observations      | "What did we notice?"                  |

## Data Storage

```
~/.lore/
└── search.db          # FTS5 index, embeddings, graph cache

lore/
├── journal/data/      # decisions.jsonl
├── patterns/data/     # patterns.yaml
├── transfer/data/     # sessions/*.json
├── graph/data/        # graph.json
├── registry/data/     # metadata.yaml, clusters.yaml
├── intent/data/       # goals/, missions/
└── inbox/data/        # observations.jsonl
```

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
      "env": { "LORE_DIR": "/path/to/lore" }
    }
  }
}
```

Tools exposed: `lore_search`, `lore_context`, `lore_related`, `lore_remember`, `lore_learn`, `lore_resume`
