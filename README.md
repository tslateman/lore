# Lore

Explicit context management for multi-agent systems.

## Installation

### Requirements

- **bash** 4.0+
- **jq** - JSON processing
- **yq** - YAML processing. Install the Go implementation,
  [mikefarah/yq](https://github.com/mikefarah/yq). The Python package that
  `pip install yq` provides is an unrelated jq wrapper: it fails on the
  `yq -o=json` calls Lore makes with `jq: Unknown option -o`.
- **sqlite3** - Search index (included on macOS)
- **python3** - Graph traversal (`lib/search-index.sh`), rerank scoring
  (`lib/recall-router.sh`), and the session-handoff hooks under
  `scripts/hooks/`
- **perl** - `lore librarian` (`lib/librarian.sh`), and the timeout fallback
  for rerank on systems without `timeout(1)`. Ships with macOS and most Linux
  distributions.

### Quick Install

```bash
# Clone the repository
git clone https://github.com/tslateman/lore.git ~/dev/lore

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

Homebrew's `yq` is mikefarah's Go implementation, which is the one Lore needs.
macOS ships `python3` with the Xcode command line tools; `brew install python`
installs it otherwise.

### Install Dependencies (Linux)

Two tools answer to the name `yq`. Lore calls `yq -o=json`, which only
mikefarah's Go implementation accepts, so skip `pip install yq` -- that
installs the unrelated Python wrapper.

```bash
# Debian/Ubuntu
sudo apt install jq sqlite3 python3 perl

# Install the same yq binary CI uses
YQ_VERSION=$(curl -s https://api.github.com/repos/mikefarah/yq/releases/latest | jq -r '.tag_name')
sudo wget -qO /usr/local/bin/yq "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_amd64"
sudo chmod +x /usr/local/bin/yq

# Confirm you have the Go one. Both projects number themselves v4.x,
# so read the URL in the output, not the version.
yq --version   # yq (https://github.com/mikefarah/yq/) version v4.x.x
```

## Usage

```bash
# One verb, four destinations -- flags determine type
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

# Record a normative clause, then cite it by id
lore standards new "API versioning" --applies-to api --owner platform
lore standards add STD-0001 MUST "Every public endpoint carries a version prefix."

# Assemble the clauses a spec must be judged against
lore corpus plans/my-spec.md --prompt
```

Run `lore help` for all commands, or `lore help <topic>` for details on capture, search, intent, registry, or components. See the [tutorial](docs/tutorial.md) for a hands-on walkthrough and [docs/engram-integration.md](docs/engram-integration.md) for the Engram bridge.

## Why Lore

MEMORY.md gives agents implicit context -- loaded into the prompt, hoped to be relevant. Lore provides explicit context -- structured writes, typed queries, cross-project assembly. This matters when:

- Multiple agents need the same context
- Context exceeds what fits in a system prompt
- You need to query across time ("What did we decide about auth?")

### Search

Two retrieval phases, used together:

1. **FTS5** -- Keyword search with BM25 ranking, boosted by recency, frequency, importance, and project affinity
2. **Graph** -- Traverse relationships to surface connected knowledge (`--graph-depth 1-3`)

### Session Continuity

`lore resume` at session start loads the previous session's state -- what was done, what's next, what's blocked. `lore handoff` at session end captures context for the next agent.

### Structured Storage

Journal captures decisions with rationale. Patterns capture lessons learned. Graph connects concepts. These components earn their keep at scale -- when flat files stop fitting in a prompt.

### Specification Review

`standards/` holds normative clauses in RFC 2119 terms, each with its own id, so a reviewer cites `STD-0001.3` instead of "the API standard". `lore corpus <spec-file>` gathers the clauses that spec must answer to -- active standards clauses, doored decisions, and non-goals -- selected by the `applies_to` and `projects` tags in the spec's frontmatter. It emits JSON by default, a review prompt with `--prompt`, or a gate that exits 1 on open blocking findings with `--check`.

## Components

| Component      | Purpose               | Key Question                           |
| -------------- | --------------------- | -------------------------------------- |
| **journal/**   | Decision capture      | "Why did we choose this?"              |
| **patterns/**  | Lessons learned       | "What did we learn?"                   |
| **transfer/**  | Session succession    | "What's next?"                         |
| **graph/**     | Knowledge connections | "What relates to this?"                |
| **registry/**  | Project metadata      | "What exists and how does it connect?" |
| **intent/**    | Goals and specs       | "What are we trying to achieve?"       |
| **inbox/**     | Raw observations      | "What did we notice?"                  |
| **failures/**  | Failure reports       | "What went wrong?"                     |
| **evidence/**  | Factual evidence      | "What supports this?"                  |
| **standards/** | Normative clauses     | "What must a spec do?"                 |

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
├── evidence/data/     # evidence.jsonl
├── standards/data/    # standards.jsonl, clauses.jsonl
└── search.db          # FTS5 index, embeddings, graph cache
```

Run `lore init` to scaffold this structure, or `scripts/install.sh` to
migrate existing data. `lore init` skips `standards/data/`; the first
`lore standards` command creates it.

## Integration

Projects integrate via `lib/lore-client-base.sh` -- fail-silent wrappers that record decisions and patterns without blocking if Lore is unavailable. See `LORE_CONTRACT.md` for the full interface.

### Known Clients

- Praxis: CLI synthesis tool that uses Lore as its storage layer and handles query traversal.
- Shipyard: Fleet manager that does not require Lore, but agents can use the CLI to read and write context.

## Engram Sync

Lore can project its records into [Engram](https://github.com/jsflax/Engram) as shadow memories. Engram is a persistent semantic memory system (MCP server + SQLite) that Claude Code queries automatically before each turn via an advise hook. Without the bridge, Lore data stays invisible to that hook.

```bash
# Preview what would sync
lore sync --dry-run

# Sync recent records
lore sync --since 8h

# Sync only decisions
lore sync --type decisions

# Sync everything
lore sync
```

Shadow memories carry a `[lore:{id}]` prefix for deduplication -- running sync repeatedly is safe. Four sources are bridged: decisions, patterns, failure triggers, and session handoffs. See `plans/bridge-lore-to-claude-memory.md` for architecture details
