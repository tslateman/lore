# Memory Graph

A searchable knowledge base that connects concepts, files, decisions, and learnings for AI agents.

## Overview

Memory Graph provides a persistent, queryable graph database for storing and traversing knowledge. It helps answer questions like:

- "What do we know about authentication?"
- "What files are related to this concept?"
- "What lessons came from this session?"
- "How are these two ideas connected?"

## Installation

No installation required. Just make the script executable:

```bash
chmod +x graph.sh
```

Requires: `bash`, `jq`

## Quick Start

```bash
# Add some concepts
./graph.sh add concept "authentication" --data '{"tags": ["security", "core"]}'
./graph.sh add concept "JWT tokens" --data '{"tags": ["security", "auth"]}'
./graph.sh add file "auth.py" --data '{"path": "/src/auth.py"}'

# Create relationships
./graph.sh link concept-abc123 concept-def456 --relation "relates_to"
./graph.sh link file-xyz789 concept-abc123 --relation "implements"

# Search the graph
./graph.sh query "authentication"
./graph.sh query "security" --type concept --fuzzy

# Explore relationships
./graph.sh related concept-abc123 --hops 2
./graph.sh path concept-abc123 file-xyz789

# Visualize
./graph.sh visualize | dot -Tpng -o graph.png
```

## Commands

### Adding Nodes

```bash
./graph.sh add <type> <name> [--data '{}']
```

Node types:

- `concept` - Abstract ideas or topics
- `file` - Source files or documents
- `pattern` - Recurring patterns or practices
- `lesson` - Learned insights
- `decision` - Architectural or design decisions
- `session` - Work sessions or sprints
- `failure` - Recorded failure reports

Examples:

```bash
./graph.sh add concept "microservices" --data '{"tags": ["architecture"]}'
./graph.sh add lesson "cache invalidation is hard" --data '{"source": "session-123"}'
./graph.sh add decision "use PostgreSQL" --data '{"reason": "ACID compliance"}'
./graph.sh add file "database.py" --data '{"path": "/src/db/database.py", "language": "python"}'
```

### Creating Links

```bash
./graph.sh link <from-id> <to-id> --relation <type> [--weight 1.0] [--bidirectional]
```

Edge types:

| Edge Type       | Meaning                                  |
| --------------- | ---------------------------------------- |
| `relates_to`    | General semantic relationship            |
| `learned_from`  | Knowledge derived from experience        |
| `affects`       | Has impact on                            |
| `supersedes`    | Newer decision replaces older one        |
| `contradicts`   | Pattern/decision conflicts with another  |
| `contains`      | Parent/child relationship                |
| `references`    | Points to                                |
| `implements`    | Code realizes a concept                  |
| `depends_on`    | Requires                                 |
| `produces`      | Generates output consumed by another     |
| `consumes`      | Takes input produced by another          |
| `derived_from`  | Pattern learned from a specific decision |
| `part_of`       | Component of a larger concept/initiative |
| `summarized_by` | Consolidated into a higher-level summary |

Examples:

```bash
./graph.sh link concept-abc file-def --relation "implements"
./graph.sh link lesson-123 session-456 --relation "learned_from"
./graph.sh link decision-a decision-b --relation "supersedes"
./graph.sh link concept-x concept-y --relation "relates_to" --bidirectional
```

### Connecting by Name

The `connect` and `disconnect` commands accept node names instead of IDs:

```bash
# Connect two nodes by name
./graph.sh connect "authentication" "JWT tokens" relates_to

# Connect with a weight
./graph.sh connect "bash safety" "Safe bash arithmetic" part_of --weight 0.8

# Disconnect (removes the specific edge)
./graph.sh disconnect "authentication" "JWT tokens" relates_to

# Disconnect all edges between two nodes
./graph.sh disconnect "authentication" "JWT tokens"
```

### Searching

```bash
./graph.sh query <search> [--type type] [--fuzzy] [--limit n] [--after date] [--before date]
```

Examples:

```bash
./graph.sh query "authentication"
./graph.sh query "auth" --type concept --fuzzy
./graph.sh query "database" --limit 5
./graph.sh query "security" --after "2024-01-01"
```

### Exploring Relationships

```bash
# Find nodes related to a given node
./graph.sh related <node-id> [--hops n]

# Find the shortest path between two nodes
./graph.sh path <from-id> <to-id>
```

### Graph Analysis

```bash
# Find nodes with no connections
./graph.sh orphans

# Find most connected nodes
./graph.sh hubs [limit]

# Find clusters of related nodes
./graph.sh clusters

# Show statistics
./graph.sh stats
```

### Visualization

```bash
# Output DOT format
./graph.sh visualize

# Generate PNG (requires graphviz)
./graph.sh visualize | dot -Tpng -o graph.png

# Generate SVG
./graph.sh visualize | dot -Tsvg -o graph.svg
```

### Data Management

```bash
# List all nodes
./graph.sh list

# List nodes by type
./graph.sh list concept

# Get node details
./graph.sh get <node-id>

# Delete a node (and its edges)
./graph.sh delete <node-id>

# Export entire graph
./graph.sh export > backup.json

# Import from file
./graph.sh import other-graph.json
```

## Data Format

The graph is stored in `data/graph.json`:

```json
{
  "nodes": {
    "concept-a1b2c3d4": {
      "type": "concept",
      "name": "authentication",
      "data": {
        "tags": ["security", "core"],
        "description": "User identity verification"
      },
      "created_at": "2024-01-15T10:30:00Z",
      "updated_at": "2024-01-15T10:30:00Z"
    }
  },
  "edges": [
    {
      "from": "concept-a1b2c3d4",
      "to": "file-e5f6g7h8",
      "relation": "implements",
      "weight": 1.0,
      "bidirectional": false,
      "created_at": "2024-01-15T10:35:00Z"
    }
  ]
}
```

## Library Functions

The graph functionality is split into reusable libraries:

### lib/nodes.sh

- `add_node <type> <name> [data]` - Add or merge a node
- `get_node <id>` - Retrieve node by ID
- `find_node <name> [type]` - Find node by name
- `delete_node <id>` - Remove node and its edges
- `list_nodes [type]` - List all nodes
- `update_node <id> <data>` - Update node data

### lib/edges.sh

- `add_edge <from> <to> <relation> [weight] [bidirectional]` - Create edge
- `delete_edge <from> <to> [relation]` - Remove edge
- `get_outgoing_edges <node>` - Get edges from node
- `get_incoming_edges <node>` - Get edges to node
- `get_neighbors <node>` - Get all connected nodes

### lib/search.sh

- `search <query> [options]` - Full-text search with ranking
- `search_fuzzy <query> [type] [limit]` - Fuzzy matching
- `search_by_tags <tags> [type]` - Search by tags
- `quick_search <query>` - Fast ID-only search
- `recent_nodes [limit] [type]` - Recently updated nodes

### lib/traverse.sh

- `bfs <start> [max_depth]` - Breadth-first traversal
- `dfs <start> [max_depth]` - Depth-first traversal
- `shortest_path <from> <to>` - Find shortest path
- `find_related <node> [hops]` - Find related nodes
- `find_clusters` - Detect connected clusters
- `find_orphans` - Find isolated nodes
- `find_hubs [limit]` - Find most connected nodes

## Use Cases

### Tracking Knowledge Evolution

```bash
# Record a lesson learned
./graph.sh add lesson "Rate limiting prevents cascade failures" \
  --data '{"context": "production incident", "severity": "high"}'

# Link it to the session where it was learned
./graph.sh link lesson-abc session-def --relation "learned_from"

# Link to affected concepts
./graph.sh link lesson-abc concept-rate-limiting --relation "affects"
```

### Documenting Architecture Decisions

```bash
# Record a decision
./graph.sh add decision "Use event sourcing for audit trail" \
  --data '{"date": "2024-01-15", "stakeholders": ["team-lead"]}'

# Show what it supersedes
./graph.sh link decision-new decision-old --relation "supersedes"

# Connect to implementation
./graph.sh link decision-abc file-events-py --relation "implements"
```

### Building a Knowledge Map

```bash
# Add related concepts
./graph.sh add concept "microservices"
./graph.sh add concept "containers"
./graph.sh add concept "kubernetes"

# Create relationships
./graph.sh link concept-micro concept-containers --relation "depends_on"
./graph.sh link concept-containers concept-k8s --relation "relates_to"

# Visualize the knowledge map
./graph.sh visualize | dot -Tsvg -o architecture.svg
```

### Session Memory

```bash
# Start a session
./graph.sh add session "2024-01-15-auth-refactor" \
  --data '{"goal": "Refactor authentication module"}'

# Record files touched
./graph.sh link session-abc file-auth --relation "affects"
./graph.sh link session-abc file-users --relation "affects"

# Record lessons at end
./graph.sh add lesson "Split auth into strategies"
./graph.sh link lesson-xyz session-abc --relation "learned_from"
```

## Edge Type Guidelines

- **contradicts** — Use when a pattern says "don't X" and a decision says "we
  chose X." Flag for review.
- **supersedes** — Mark older decisions as superseded when new ones override
  them. Old decision stays in journal but ranks lower.
- **derived_from** — Link patterns back to the decision/session where they
  were learned.
- **part_of** — Group related patterns under a hub concept (e.g., "bash safety").
- **summarized_by** — When consolidating patterns, link originals to summary
  with this edge. Original patterns drop to importance=1.

## Rebuild

The graph is a derived projection — flat files (journal, patterns, failures,
sessions) are the source of truth. Rebuild from scratch:

```bash
./graph.sh rebuild
```

This resets the graph, runs all four sync scripts (decisions, patterns,
failures, sessions), normalizes edge spelling, and deduplicates edges.
Individual write commands (`remember`, `learn`, `fail`, `handoff`) sync
incrementally in the background.

## Integration with Lore

Memory Graph is part of the Lore memory system. It can be used alongside:

- **Session tracking** - Store per-session learnings
- **Context builders** - Provide relevant knowledge for prompts
- **Decision logs** - Track architectural decisions over time

## Tips

1. **Use consistent naming** - Node names are used for deduplication
2. **Add tags** - Use `data.tags` for better searchability
3. **Weight edges** - Higher weights indicate stronger relationships
4. **Prune orphans** - Periodically check for and clean up orphaned nodes
5. **Backup regularly** - Use `./graph.sh export` before major changes
