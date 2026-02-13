# Lineage Codebase Research

Comprehensive analysis of every CLI command, data schema, library function, query capability, and integration point. This document drives API design decisions.

## 1. Architecture Overview

Lineage is a bash-based persistent memory system with four components:

| Component | Purpose                     | Storage Format | Data File                       |
| --------- | --------------------------- | -------------- | ------------------------------- |
| Journal   | Decision capture + outcomes | JSONL          | `journal/data/decisions.jsonl`  |
| Graph     | Knowledge graph             | JSON           | `graph/data/graph.json`         |
| Patterns  | Lessons and anti-patterns   | YAML           | `patterns/data/patterns.yaml`   |
| Transfer  | Session snapshots + handoff | JSON per file  | `transfer/data/sessions/*.json` |

Entry point: `lineage.sh` dispatches to component scripts or handles cross-component "quick commands."

### File Tree

```
lineage.sh                          # Main dispatcher
lib/
  lineage-client-base.sh            # Shared client for external projects
  ingest.sh                         # Bulk import from Lore formats
journal/
  journal.sh                        # Journal CLI
  lib/capture.sh                    # Decision creation, entity extraction, type detection
  lib/store.sh                      # JSONL storage, indexing, search, stats
  lib/relate.sh                     # Decision linking, graph integration, legacy fallback
  data/decisions.jsonl               # Append-only decision log
  data/schema.json                   # JSON Schema for decisions
  data/decision_graph.json           # Legacy graph (fallback only)
  data/index/                        # File-based indexes (date, type, entity, tag)
graph/
  graph.sh                          # Graph CLI
  lib/nodes.sh                      # Node CRUD, deterministic IDs via md5sum
  lib/edges.sh                      # Edge CRUD, bidirectional support, neighbors
  lib/search.sh                     # Full-text + fuzzy (Levenshtein) search, tag search
  lib/traverse.sh                   # BFS, DFS, shortest path, clusters, orphans, hubs
  data/graph.json                   # Single JSON file: {nodes: {}, edges: []}
patterns/
  patterns.sh                       # Patterns CLI
  lib/capture.sh                    # Pattern + anti-pattern creation, YAML insertion, validation
  lib/match.sh                      # Keyword extraction, scoring, code pattern detection
  lib/suggest.sh                    # Context-based suggestion, category suggestion
  data/patterns.yaml                # YAML file with patterns: [] and anti_patterns: []
  templates/pattern.yaml            # Template for manual pattern creation
transfer/
  transfer.sh                       # Transfer CLI
  lib/snapshot.sh                   # Git state, active files, environment, related entries
  lib/resume.sh                     # Session loading, brief summary, latest session
  lib/handoff.sh                    # Handoff creation, next steps, blockers, questions
  lib/compress.sh                   # Session compression, critical extraction, merge, prune
  data/sessions/                    # One JSON file per session
  data/.current_session             # Tracks active session ID
```

## 2. CLI Command Surface

### 2.1 lineage.sh (Main Entry)

| Command                       | Delegates To               | Description                     |
| ----------------------------- | -------------------------- | ------------------------------- |
| `remember <text> [opts]`      | `journal.sh record`        | Quick decision capture          |
| `learn <pattern> [opts]`      | `patterns.sh capture`      | Quick pattern capture           |
| `handoff <message>`           | `transfer.sh handoff`      | Create handoff note             |
| `resume [session]`            | `transfer.sh resume`       | Resume previous session         |
| `search <query>`              | journal + graph + patterns | Cross-component search          |
| `suggest <context>`           | `patterns.sh suggest`      | Suggest relevant patterns       |
| `context <project>`           | journal + patterns + graph | Full project context            |
| `status`                      | `transfer.sh status`       | Current session state           |
| `ingest <proj> <type> <file>` | `lib/ingest.sh`            | Bulk import                     |
| `journal <cmd>`               | `journal/journal.sh`       | Journal subcommand passthrough  |
| `graph <cmd>`                 | `graph/graph.sh`           | Graph subcommand passthrough    |
| `patterns <cmd>`              | `patterns/patterns.sh`     | Patterns subcommand passthrough |
| `transfer <cmd>`              | `transfer/transfer.sh`     | Transfer subcommand passthrough |

### 2.2 journal.sh

| Command                | Aliases          | Arguments / Flags                                                            |
| ---------------------- | ---------------- | ---------------------------------------------------------------------------- |
| `record <decision>`    |                  | `--rationale/-r`, `--alternatives/-a`, `--tags/-t`, `--type`, `--files/-f`   |
| `query <search>`       | `search`, `find` | `--project/-p`, `--tag`                                                      |
| `context <file/topic>` | `ctx`            | Positional: file path or topic string                                        |
| `learn <id> <lesson>`  | `lesson`         | Decision ID + lesson text                                                    |
| `update <id>`          |                  | `--outcome/-o` (pending/successful/revised/abandoned), `--rationale/-r`      |
| `list`                 | `ls`             | `--recent/-n N`, `--type`, `--outcome`, `--tag`, `--project/-p`, `--session` |
| `link <id1> <id2>`     |                  | Optional 3rd arg: relationship type (default: "related")                     |
| `stats`                |                  | No args                                                                      |
| `compact`              |                  | No args. Deduplicates JSONL, rebuilds indexes                                |
| `export`               |                  | `--format/-f` (json/markdown/dot/mermaid), `--session/-s`                    |

**Inline syntax**: `journal.sh record "Use X [because: reason] [vs: alt1, alt2]"`

**Decision types** (auto-detected or explicit): `architecture`, `implementation`, `naming`, `tooling`, `process`, `bugfix`, `refactor`, `other`

**Outcome states**: `pending`, `successful`, `revised`, `abandoned`

### 2.3 graph.sh

| Command             | Aliases  | Arguments / Flags                                               |
| ------------------- | -------- | --------------------------------------------------------------- |
| `add <type> <name>` |          | `--data '{}'` (JSON metadata)                                   |
| `link <from> <to>`  |          | `--relation` (required), `--weight`, `--bidirectional`          |
| `query <search>`    | `search` | `--type`, `--after`, `--before`, `--fuzzy`, `--limit`, `--tags` |
| `related <node>`    |          | `--hops N` (default: 2)                                         |
| `path <from> <to>`  |          | No extra flags                                                  |
| `visualize`         | `viz`    | Outputs DOT format                                              |
| `list [type]`       | `ls`     | Optional type filter                                            |
| `get <node-id>`     |          | Returns full node JSON                                          |
| `delete <node-id>`  | `rm`     | Removes node + edges                                            |
| `orphans`           |          | Nodes with no connections                                       |
| `hubs [limit]`      |          | Most connected nodes (default limit: 10)                        |
| `clusters`          |          | Connected component detection                                   |
| `stats`             |          | Node/edge counts by type, orphan count                          |
| `import <file>`     |          | Merge JSON file into graph                                      |
| `export [format]`   |          | `json`, `dot`, `mermaid`                                        |

**Node types**: `concept`, `file`, `pattern`, `lesson`, `decision`, `session`, `project`

**Edge types**: `relates_to`, `learned_from`, `affects`, `supersedes`, `contradicts`, `contains`, `references`, `implements`, `depends_on`, `produces`, `consumes`

**Node ID strategy**: Deterministic via `md5sum(name)` prefixed by type (e.g., `project-a189c633`). Re-adding merges data via jq `*` operator.

### 2.4 patterns.sh

| Command               | Arguments / Flags                                                                                   |
| --------------------- | --------------------------------------------------------------------------------------------------- |
| `capture <pattern>`   | `--context`, `--solution`, `--problem`, `--category`, `--origin`, `--example-bad`, `--example-good` |
| `warn <anti-pattern>` | `--symptom`, `--fix`, `--risk`, `--severity`, `--category`                                          |
| `check <file/code>`   | `--verbose/-v`                                                                                      |
| `suggest <context>`   | `--limit N` (default: 5)                                                                            |
| `list`                | `--type` (patterns/anti-patterns/all), `--category`, `--format` (table/yaml/json)                   |
| `show <id>`           | Pattern or anti-pattern ID                                                                          |
| `validate <id>`       | Increases confidence score                                                                          |
| `init`                | Initialize empty patterns.yaml                                                                      |

**Pattern categories**: `bash`, `git`, `testing`, `architecture`, `naming`, `security`, `docker`, `api`, `performance`, `general`

**Anti-pattern severities**: `low`, `medium`, `high`, `critical`

**Pattern ID format**: `pat-<6-digit-timestamp-suffix>-<8-hex-random>` (e.g., `pat-000001-seed`)

**Anti-pattern ID format**: `anti-<6-digit-timestamp-suffix>-<8-hex-random>`

### 2.5 transfer.sh

| Command                      | Arguments / Flags                         |
| ---------------------------- | ----------------------------------------- |
| `init`                       | Creates new session JSON                  |
| `snapshot [summary]`         | Captures git state, active files, related |
| `resume <session-id>`        | Loads and displays session context        |
| `handoff <message>`          | Creates handoff note, sets ended_at       |
| `status`                     | Shows current session state               |
| `diff <session1> <session2>` | Compares goals, decisions, patterns, git  |
| `list`                       | Lists all sessions in table format        |
| `compress <session-id>`      | Smart compression preserving patterns     |

**Global flags**: `--json`, `--verbose/-v`

**Session ID format**: `session-YYYYMMDD-HHMMSS-<8-hex-random>`

### 2.6 lineage ingest

| Type            | Input                | Output                        |
| --------------- | -------------------- | ----------------------------- |
| `relationships` | `relationships.yaml` | Graph nodes (project) + edges |
| `handoffs`      | Markdown file        | Journal decisions (tagged)    |
| `patterns`      | `relationships.yaml` | Patterns (architecture)       |

## 3. Data Schemas

### 3.1 Decision Record (Journal)

```json
{
  "id": "dec-<8 hex>",
  "timestamp": "ISO8601",
  "session_id": "session-<id>|null",
  "decision": "string (required)",
  "rationale": "string|null",
  "alternatives": ["string"],
  "outcome": "pending|successful|revised|abandoned",
  "type": "architecture|implementation|naming|tooling|process|bugfix|refactor|other",
  "entities": ["string"],
  "tags": ["string"],
  "lesson_learned": "string|null",
  "related_decisions": ["dec-id"],
  "git_commit": "sha|null"
}
```

Storage: one JSON object per line in `decisions.jsonl`. Updates append a new version; dedup at read time via `group_by(.id) | map(.[-1])`.

Indexes: file-based in `data/index/` (date, type, entity, tag). Rebuilt on compact.

### 3.2 Graph Node

```json
{
  "<node-id>": {
    "type": "concept|file|pattern|lesson|decision|session|project",
    "name": "string",
    "data": {},
    "created_at": "ISO8601",
    "updated_at": "ISO8601"
  }
}
```

Node ID: `<type>-<md5sum(name)[0:8]>`. Deterministic for dedup.

### 3.3 Graph Edge

```json
{
  "from": "<node-id>",
  "to": "<node-id>",
  "relation": "<edge-type>",
  "weight": 1.0,
  "bidirectional": false,
  "created_at": "ISO8601"
}
```

Graph file structure: `{"nodes": {}, "edges": []}`

### 3.4 Pattern (YAML)

```yaml
- id: "pat-<6digits>-<hex>"
  name: "string"
  context: "when this applies"
  problem: "what goes wrong"
  solution: "what to do"
  category: "string"
  origin: "session-<date> or <project>"
  confidence: 0.0-1.0
  validations: integer
  created_at: "ISO8601"
  examples:
    - bad: "string"
    - good: "string"
```

### 3.5 Anti-Pattern (YAML)

```yaml
- id: "anti-<6digits>-<hex>"
  name: "string"
  symptom: "what you observe"
  risk: "why it's bad"
  fix: "how to fix it"
  category: "string"
  severity: "low|medium|high|critical"
  created_at: "ISO8601"
```

### 3.6 Session (Transfer)

```json
{
  "id": "session-<YYYYMMDD-HHMMSS-hex>",
  "started_at": "ISO8601",
  "ended_at": "ISO8601|null",
  "summary": "string",
  "goals_addressed": ["string"],
  "decisions_made": ["string"],
  "patterns_learned": ["string"],
  "open_threads": ["string"],
  "handoff": {
    "message": "string",
    "next_steps": ["string"],
    "blockers": ["string"],
    "questions": ["string"],
    "created_at": "ISO8601"
  },
  "git_state": {
    "branch": "string",
    "commits": ["string"],
    "uncommitted": ["string"],
    "stash_count": 0
  },
  "context": {
    "active_files": ["string"],
    "recent_commands": ["string"],
    "environment": {}
  },
  "related": {
    "journal_entries": ["dec-id"],
    "patterns": ["pat-id"],
    "goals": []
  }
}
```

Compressed sessions add: `"compressed": true`, `"compressed_at": "ISO8601"`.

## 4. Internal Library Functions

### 4.1 journal/lib/capture.sh

| Function                 | Signature                                 | Returns                                          |
| ------------------------ | ----------------------------------------- | ------------------------------------------------ |
| `generate_decision_id`   | `()`                                      | `dec-<8hex>` via `/dev/urandom`                  |
| `get_session_id`         | `()`                                      | Session ID (env, file, or new)                   |
| `extract_entities`       | `(text)`                                  | JSON array of entities                           |
| `detect_decision_type`   | `(text)`                                  | Type string                                      |
| `get_git_commit`         | `()`                                      | Current HEAD SHA or ""                           |
| `create_decision_record` | `(decision, rationale, alts, tags, type)` | Compact JSON record                              |
| `parse_inline_decision`  | `(text)`                                  | 3-line output: decision, rationale, alternatives |

Entity extraction parses: file paths (`*.ext`), function names (`name()`), backtick-quoted terms.

Type detection uses keyword matching against the decision text.

### 4.2 journal/lib/store.sh

| Function            | Signature            | Returns / Side Effect                                    |
| ------------------- | -------------------- | -------------------------------------------------------- |
| `reverse_lines`     | `(file)`             | Lines reversed (tac > tail -r > awk)                     |
| `init_store`        | `()`                 | Creates dirs + touches file                              |
| `store_decision`    | `(json)`             | Appends to JSONL, updates indexes, returns ID            |
| `get_decision`      | `(id)`               | Latest version of decision JSON                          |
| `update_decision`   | `(id, field, value)` | Appends updated version to JSONL                         |
| `list_recent`       | `(count)`            | JSON array of N recent decisions                         |
| `list_by_date`      | `(start, end)`       | JSON array filtered by date range                        |
| `search_decisions`  | `(query)`            | Full-text search across all fields                       |
| `get_by_entity`     | `(entity)`           | Decisions matching entity (indexed)                      |
| `get_by_type`       | `(type)`             | Decisions filtered by type                               |
| `get_by_tag`        | `(tag)`              | Decisions filtered by exact tag                          |
| `get_by_project`    | `(project)`          | Tag prefix matching                                      |
| `get_by_outcome`    | `(outcome)`          | Decisions filtered by outcome                            |
| `get_stats`         | `()`                 | JSON: total, by_type, by_outcome, with_lessons, by_month |
| `export_session`    | `(session_id)`       | Decisions from a specific session                        |
| `compact_decisions` | `()`                 | Dedup + rebuild indexes                                  |
| `rebuild_indexes`   | `()`                 | Rebuilds all index files from scratch                    |

### 4.3 journal/lib/relate.sh

| Function                 | Signature                  | Description                                       |
| ------------------------ | -------------------------- | ------------------------------------------------- |
| `_map_edge_type`         | `(rel)`                    | Maps journal names to graph edge types            |
| `_ensure_decision_node`  | `(decision_id)`            | Creates/merges decision node in graph, returns ID |
| `_ensure_file_node`      | `(filepath)`               | Creates/merges file node in graph, returns ID     |
| `link_to_files`          | `(id, files...)`           | Links decision to files via graph or legacy       |
| `link_decisions`         | `(id1, id2, relationship)` | Links two decisions in graph + journal records    |
| `get_decisions_for_file` | `(file)`                   | Finds decisions linked to a file                  |
| `get_related_decisions`  | `(id, depth)`              | Graph traversal to find related decisions         |
| `auto_link_by_entities`  | `(id)`                     | Auto-links decisions sharing entities             |
| `find_decision_chains`   | `(start_id, max_depth)`    | Traverses decision chains                         |
| `get_topic_context`      | `(topic, max_results)`     | Search + relation expansion                       |
| `get_graph_summary`      | `()`                       | Stats from graph or legacy                        |
| `export_graph`           | `(format)`                 | Export decision subgraph in json/dot/mermaid      |

Key design: `relate.sh` sources `graph/lib/edges.sh` when available (`_GRAPH_LIB_AVAILABLE`). Falls back to `decision_graph.json` legacy file when graph library is missing.

### 4.4 graph/lib/nodes.sh

| Function             | Signature                 | Description                                |
| -------------------- | ------------------------- | ------------------------------------------ |
| `init_graph`         | `()`                      | Ensures graph.json exists                  |
| `generate_node_id`   | `(name, type)`            | Deterministic: `<type>-<md5sum(name)[:8]>` |
| `validate_node_type` | `(type)`                  | Checks against VALID_NODE_TYPES            |
| `add_node`           | `(type, name, data_json)` | Creates or merges node, returns ID         |
| `get_node`           | `(id)`                    | Returns node JSON                          |
| `find_node`          | `(name, type?)`           | Finds node by name                         |
| `delete_node`        | `(id)`                    | Removes node + all edges                   |
| `list_nodes`         | `(type?)`                 | Tab-separated: id, type, name              |
| `update_node`        | `(id, data_json)`         | Merges data via jq `*`                     |
| `node_count`         | `()`                      | Integer count                              |

### 4.5 graph/lib/edges.sh

| Function             | Signature                               | Description                           |
| -------------------- | --------------------------------------- | ------------------------------------- |
| `validate_edge_type` | `(type)`                                | Checks against VALID_EDGE_TYPES       |
| `add_edge`           | `(from, to, relation, weight?, bidir?)` | Creates or updates edge               |
| `delete_edge`        | `(from, to, relation?)`                 | Removes edge(s)                       |
| `get_outgoing_edges` | `(from)`                                | All edges from a node                 |
| `get_incoming_edges` | `(to)`                                  | All edges to a node                   |
| `get_all_edges`      | `(node)`                                | Both directions                       |
| `list_edges`         | `(relation?)`                           | All edges, optionally filtered        |
| `update_edge_weight` | `(from, to, relation, weight)`          | Updates weight of specific edge       |
| `edge_count`         | `()`                                    | Integer count                         |
| `get_neighbors`      | `(node)`                                | Unique neighbor IDs (both directions) |

### 4.6 graph/lib/search.sh

| Function          | Signature                                                      | Description                    |
| ----------------- | -------------------------------------------------------------- | ------------------------------ |
| `levenshtein`     | `(s1, s2)`                                                     | Edit distance via awk          |
| `fuzzy_match`     | `(query, text, max_distance)`                                  | Returns distance or -1         |
| `calculate_score` | `(query, name, data)`                                          | Integer relevance score        |
| `search`          | `(query, --type, --after, --before, --fuzzy, --limit, --tags)` | Full-text search with scoring  |
| `search_fuzzy`    | `(query, type?, limit?, max_distance?)`                        | Levenshtein-based fuzzy search |
| `search_by_tags`  | `(tags, type?)`                                                | Filter by tags in node data    |
| `quick_search`    | `(query)`                                                      | Returns matching node IDs only |
| `recent_nodes`    | `(limit?, type?)`                                              | Recently updated nodes         |

### 4.7 graph/lib/traverse.sh

| Function          | Signature            | Description                           |
| ----------------- | -------------------- | ------------------------------------- |
| `bfs`             | `(start, max_depth)` | Breadth-first search via jq           |
| `dfs`             | `(start, max_depth)` | Depth-first search via jq             |
| `shortest_path`   | `(from, to)`         | BFS shortest path, returns node array |
| `find_related`    | `(node, max_hops)`   | All nodes within N hops               |
| `find_clusters`   | `()`                 | Connected components via BFS          |
| `find_orphans`    | `()`                 | Nodes with no edges                   |
| `node_degree`     | `(node)`             | In/out/total degree                   |
| `find_hubs`       | `(limit)`            | Most connected nodes                  |
| `path_with_edges` | `(from, to)`         | Path with edge relation details       |

### 4.8 patterns/lib/capture.sh

| Function               | Signature                                                | Description                         |
| ---------------------- | -------------------------------------------------------- | ----------------------------------- |
| `generate_pattern_id`  | `(prefix)`                                               | `<prefix>-<timestamp6>-<hex8>`      |
| `validate_category`    | `(category)`                                             | Validates against known categories  |
| `validate_severity`    | `(severity)`                                             | Validates against known severities  |
| `yaml_escape`          | `(str)`                                                  | Escapes for YAML embedding          |
| `capture_pattern`      | `(name, ctx, solution, problem, cat, origin, bad, good)` | Inserts pattern into YAML           |
| `capture_anti_pattern` | `(name, symptom, fix, risk, severity, category)`         | Inserts anti-pattern into YAML      |
| `validate_pattern`     | `(id)`                                                   | Increments validations + confidence |
| `show_pattern`         | `(id)`                                                   | Extracts and displays pattern       |
| `list_patterns`        | `(type, category, format)`                               | Lists in table/yaml/json format     |
| `list_patterns_json`   | `(type, category)`                                       | Pure awk YAML-to-JSON conversion    |

### 4.9 patterns/lib/match.sh

| Function                    | Signature           | Description                          |
| --------------------------- | ------------------- | ------------------------------------ |
| `extract_keywords`          | `(text)`            | Stopword-filtered keyword extraction |
| `calculate_match_score`     | `(kw1, kw2)`        | Jaccard-like similarity (0-100)      |
| `check_code_patterns`       | `(content, type)`   | Regex checks for known anti-patterns |
| `check_patterns`            | `(target, verbose)` | Full anti-pattern + suggestion check |
| `match_patterns_to_context` | `(context, limit)`  | Scores all patterns against context  |

Built-in code checks: `bash_arithmetic`, `baked_credentials`, `set_e_without_trap`, `unsafe_rm`.

### 4.10 patterns/lib/suggest.sh

| Function                   | Signature           | Description                        |
| -------------------------- | ------------------- | ---------------------------------- |
| `suggest_patterns`         | `(context, limit)`  | Main suggestion engine             |
| `suggest_by_category`      | `(context, limit)`  | Category-based fallback            |
| `suggest_anti_patterns`    | `(context)`         | Warns about relevant anti-patterns |
| `get_category_suggestions` | `(category, limit)` | Top patterns for a category        |
| `interactive_suggest`      | `()`                | REPL for pattern suggestions       |

### 4.11 transfer/lib/snapshot.sh

| Function               | Signature      | Description                         |
| ---------------------- | -------------- | ----------------------------------- |
| `capture_git_state`    | `(dir?)`       | Branch, commits, uncommitted, stash |
| `capture_active_files` | `(dir?, max?)` | Recently modified files (24h)       |
| `capture_environment`  | `()`           | pwd, user, hostname, shell, term    |
| `find_related_entries` | `()`           | Recent journal + all patterns       |
| `snapshot_session`     | `(summary?)`   | Full snapshot into session file     |
| `add_goal`             | `(goal)`       | Appends to session goals            |
| `add_decision`         | `(decision)`   | Appends to session decisions        |
| `add_thread`           | `(thread)`     | Appends to session open threads     |
| `add_pattern`          | `(pattern)`    | Appends to session patterns learned |

### 4.12 transfer/lib/resume.sh

| Function              | Signature             | Description                    |
| --------------------- | --------------------- | ------------------------------ |
| `resume_session`      | `(session_id, json?)` | Full session display           |
| `get_session_brief`   | `(session_id)`        | One-paragraph summary          |
| `find_latest_session` | `()`                  | Most recently modified session |
| `resume_latest`       | `()`                  | Resume from latest             |

### 4.13 transfer/lib/handoff.sh

| Function              | Signature           | Description                   |
| --------------------- | ------------------- | ----------------------------- |
| `create_handoff`      | `(message)`         | Stores handoff message + time |
| `add_next_step`       | `(step, priority?)` | Append or insert next step    |
| `add_blocker`         | `(blocker)`         | Append blocker                |
| `add_question`        | `(question)`        | Append question               |
| `interactive_handoff` | `()`                | REPL wizard                   |
| `format_handoff`      | `(session_id)`      | Formatted handoff display     |

### 4.14 transfer/lib/compress.sh

| Function                  | Signature                | Description                        |
| ------------------------- | ------------------------ | ---------------------------------- |
| `compress_session`        | `(session_id)`           | Smart compression (keeps patterns) |
| `extract_critical`        | `(session_id)`           | Minimal essential extraction       |
| `one_line_summary`        | `(session_id)`           | Log-friendly one-liner             |
| `merge_sessions`          | `(output_id, ids...)`    | Merge multiple sessions            |
| `prune_old_sessions`      | `(days_old, keep_pats?)` | Archive old sessions               |
| `calculate_essence_ratio` | `(session_id)`           | Essential vs non-essential ratio   |

### 4.15 lib/lineage-client-base.sh

| Function                   | Wraps                              | Behavior on Failure |
| -------------------------- | ---------------------------------- | ------------------- |
| `check_lineage`            | Tests `$LINEAGE_DIR/lineage.sh -x` | Returns 1           |
| `lineage_record_decision`  | `journal.sh record`                | Returns 0           |
| `lineage_add_node`         | `graph.sh add`                     | Returns 0           |
| `lineage_add_edge`         | `graph.sh link`                    | Returns 0           |
| `lineage_learn_pattern`    | `patterns.sh capture`              | Returns 0           |
| `lineage_handoff`          | `transfer.sh handoff`              | Returns 0           |
| `lineage_search`           | `lineage.sh search`                | Returns 0           |
| `lineage_context`          | `journal.sh context`               | Returns 0           |
| `lineage_suggest_patterns` | `patterns.sh suggest`              | Returns 0           |

All client functions fail silently (return 0) so host projects work without Lineage.

### 4.16 lib/ingest.sh

| Function               | Input Format              | Creates                          |
| ---------------------- | ------------------------- | -------------------------------- |
| `ingest_relationships` | `relationships.yaml`      | Project nodes + depends_on edges |
| `ingest_handoffs`      | Markdown with ## headings | Journal decisions (tagged)       |
| `ingest_patterns`      | `relationships.yaml`      | Patterns (architecture category) |

Uses `yq` when available, falls back to grep/sed parsing.

## 5. Query and Search Capabilities

### 5.1 Journal Search

| Query Method     | Filter By                                                 | Implementation                        |
| ---------------- | --------------------------------------------------------- | ------------------------------------- |
| Full-text search | decision, rationale, lesson, alternatives, entities, tags | `jq` case-insensitive contains        |
| By entity        | Entity string                                             | Index-first, fallback to jq           |
| By type          | Decision type                                             | jq filter                             |
| By tag           | Exact tag match                                           | jq filter                             |
| By project       | Tag prefix match                                          | jq: `== $p` or `startswith($p + ":")` |
| By outcome       | Outcome status                                            | jq filter                             |
| By date range    | Start/end dates                                           | jq timestamp comparison               |
| By session       | Session ID                                                | jq filter                             |

**Limitation**: No combined filters (cannot search text AND filter by type simultaneously through CLI).

### 5.2 Graph Search

| Query Method      | Mechanism                                   |
| ----------------- | ------------------------------------------- |
| Full-text         | jq: name + data contains (case-insensitive) |
| Fuzzy search      | Levenshtein distance via awk                |
| Type filter       | jq select on node type                      |
| Date range filter | jq select on created_at                     |
| Tag filter        | jq select on data.tags array                |
| Neighbor lookup   | Edge traversal (both directions)            |
| N-hop related     | BFS with configurable depth                 |
| Shortest path     | BFS path finding                            |
| Cluster detection | Connected components via BFS                |
| Hub detection     | Degree counting                             |
| Orphan detection  | Nodes with no edges                         |

**Scoring**: Exact name match (100), starts with (75), contains (50), data occurrences (10 each).

### 5.3 Pattern Search

| Query Method           | Mechanism                            |
| ---------------------- | ------------------------------------ |
| Keyword matching       | Stopword-filtered Jaccard similarity |
| Category suggestion    | Keyword-based category detection     |
| Code pattern detection | Regex checks (4 built-in patterns)   |
| Anti-pattern relevance | Keyword overlap with >15% threshold  |
| Confidence weighting   | Score multiplied by confidence       |

### 5.4 Cross-Component Search (`lineage search`)

Runs three independent searches:

1. `journal.sh query` - Full-text on decisions
2. `graph.sh query` - Full-text on graph nodes
3. `patterns.sh list | grep` - Simple text match on pattern listing

**Limitation**: Results are not unified or ranked. Three separate output blocks.

### 5.5 Context Gathering (`lineage context <project>`)

1. Journal: query by text + project tag filter
2. Patterns: suggest patterns for project name
3. Graph: find project node, get related nodes within 2 hops

## 6. Integration Contract Summary

The contract (`LINEAGE_CONTRACT.md`) defines:

**Write interface**: Four write paths (remember/record, learn/capture, graph add/link, handoff).

**Read interface**: Query decisions, query patterns, query graph, resume sessions.

**Conventions**:

- Tags always include source project name
- Decisions use the project's own terminology
- Patterns include origin for traceability
- Session handoffs belong to the creating project
- Graph nodes can reference cross-project entities

**Non-goals**: No replacement for project-specific state, no write enforcement, no real-time pub/sub.

## 7. Current Data Statistics

### Graph (as of latest reading)

- **22 nodes**: 2 concepts, 1 file, 1 lesson, 1 decision, 1 session, 12 projects, 4 council initiative concepts
- **16 edges**: 8 depends_on, 4 produces, 1 relates_to, 1 implements, 1 learned_from, 1 affects

### Journal

- **32 decision records** in JSONL (some with updates = more lines)
- Types: mostly architecture (ADRs), implementation, planning (Oracle missions)
- Sources: council ADRs, oracle goals/missions, lore architecture, manual

### Patterns

- **12 patterns**: 4 bash, 7 architecture, 1 general
- **6 anti-patterns**: 3 bash, 2 architecture, 1 security
- Confidence range: 0.5 to 0.95

### Sessions

- 3 session files: 1 real, 1 example, 1 compressed example

## 8. Gaps and Limitations

### Data Model Gaps

1. **No reverse-lookup from graph node ID to journal ID**. `graph.sh query` returns `decision-0240a9f4` but there is no command to resolve this back to `dec-xxxx`. The node's `data.journal_id` field exists but requires manual jq.

2. **Legacy decision_graph.json still active**. `relate.sh` falls back to writing to the legacy file. Should be removed once graph library is confirmed stable.

3. **No pattern ID in graph**. Patterns exist in YAML but are not represented as graph nodes. No way to link a pattern to a decision or concept in the graph.

4. **Session-journal disconnect**. Sessions store `decisions_made` as plain strings, not linked to journal decision IDs. Similarly, `patterns_learned` are strings, not pattern IDs.

5. **No schema validation at write time**. `schema.json` exists but is never used for validation. Decisions can be written with any shape.

### Query Limitations

6. **No compound filtering in journal**. Cannot combine text search with type/tag/project filters in a single query. The CLI handles one filter at a time.

7. **No pagination**. `list_recent` takes a count but there's no offset. For large datasets, must load all then slice.

8. **No sorting options**. Always sorted by timestamp descending. No option to sort by type, confidence, or relevance.

9. **Pattern search is keyword-only**. No semantic search, no embedding-based similarity. The Jaccard coefficient on stopword-filtered keywords is coarse.

10. **Cross-component search is naive**. `lineage search` runs three independent searches with no unified ranking or dedup.

### Structural Limitations

11. **YAML manipulation via awk**. Patterns are stored in YAML but manipulated by awk insertion. Multiline YAML values (`|` or `>` syntax) will break the parser.

12. **Graph stored as single JSON file**. Every node/edge operation rewrites the entire file. Will not scale past ~1000 nodes.

13. **No concurrency safety**. Simultaneous writes to JSONL or graph.json could corrupt data. No file locking.

14. **No streaming or incremental output**. All queries load the full dataset into memory via jq `-s` (slurp mode).

15. **md5sum portability**. `generate_node_id` uses `md5sum` which behaves differently on macOS (`md5 -r`). The code does not handle this.

### API-Relevant Gaps

16. **No structured JSON output mode for most commands**. Journal and patterns format for human display. Only transfer has `--json` flag. Graph's `export json` exports the whole graph, not query results.

17. **No bulk operations**. Cannot record multiple decisions or add multiple nodes in a single call. Each operation is a separate process invocation.

18. **No webhook/event system**. No way to subscribe to changes. Projects must poll or check at integration points.

19. **No authentication or access control**. Any process with filesystem access can read/write all data.

20. **No API versioning**. Contract is version 1.0 but the contract itself contains discrepancies (e.g., `add-node` vs `add`, `neighbors` vs `related`).

### Missing Features for API

21. **No decision deletion or archival**. Decisions are append-only with no soft-delete. `compact` deduplicates but doesn't remove.

22. **No pattern deletion**. Once captured, patterns cannot be removed or archived.

23. **No graph edge listing by node**. `get_all_edges` exists in library but is not exposed via CLI.

24. **No session update API**. Can add goals/decisions/threads via `snapshot.sh` library functions but these are not exposed as CLI commands.

25. **No health check**. No command to verify data integrity across components.
