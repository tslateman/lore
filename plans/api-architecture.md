# Unified API Architecture: Lineage + Lore + Council

## Design Philosophy

**Shell scripts stay as the source of truth.** The API reads data files directly
(JSONL, JSON, YAML, markdown) and wraps CLI commands for writes. No database
migration, no data duplication. The existing bash tools keep working unchanged.

**Three prototypes, one API server.** The REST API powers all three GUIs. Each
prototype is a single HTML file with embedded JS — zero build step, open in any
browser.

## Technology Choices

| Layer       | Choice           | Rationale                                             |
| ----------- | ---------------- | ----------------------------------------------------- |
| API server  | Python + FastAPI | Async, auto-docs (OpenAPI), fast prototyping          |
| Data reads  | Direct file I/O  | No shell overhead for reads; jq/yq only when needed   |
| Data writes | Shell subprocess | Preserve existing validation and side effects         |
| Graph viz   | D3.js force      | Industry standard for interactive graph visualization |
| Dashboard   | Vanilla JS       | Zero deps, single HTML file, works offline            |
| Timeline    | CSS Grid         | No charting library needed for simple timeline        |

## Data Access Layer

### File Locations (configurable via env)

```
LINEAGE_DIR  = ~/dev/lineage
LORE_DIR     = ~/dev/lore
COUNCIL_DIR  = ~/dev/council
DEV_PATH     = ~/dev
MANI_FILE    = ~/dev/mani.yaml
```

### Read Paths (direct file I/O, no shell)

| Data              | File                                        | Format | Parser        |
| ----------------- | ------------------------------------------- | ------ | ------------- |
| Journal decisions | $LINEAGE_DIR/journal/data/decisions.jsonl   | JSONL  | readline+json |
| Graph             | $LINEAGE_DIR/graph/data/graph.json          | JSON   | json.load     |
| Patterns          | $LINEAGE_DIR/patterns/data/patterns.yaml    | YAML   | PyYAML        |
| Sessions          | $LINEAGE_DIR/transfer/data/sessions/\*.json | JSON   | json.load     |
| Projects (mani)   | $DEV_PATH/mani.yaml                         | YAML   | PyYAML        |
| Metadata          | $LORE_DIR/registry/metadata.yaml            | YAML   | PyYAML        |
| Clusters          | $LORE_DIR/registry/clusters.yaml            | YAML   | PyYAML        |
| Relationships     | $LORE_DIR/registry/relationships.yaml       | YAML   | PyYAML        |
| Contracts         | $LORE_DIR/registry/contracts.yaml           | YAML   | PyYAML        |
| Council charter   | $COUNCIL_DIR/charter.md                     | MD     | frontmatter   |
| Seat content      | $COUNCIL_DIR/<seat>/\*.md                   | MD     | markdown      |
| Initiatives       | $COUNCIL_DIR/initiatives/\*.md              | MD     | markdown      |
| ADRs              | $COUNCIL_DIR/<seat>/adr-\*.md               | MD     | markdown      |
| Tokens            | $COUNCIL_DIR/cred-broker/data/tokens.json   | JSON   | json.load     |
| Audit log         | $COUNCIL_DIR/cred-broker/data/audit.log     | JSONL  | readline+json |
| Marshal blocks    | $COUNCIL_DIR/.claude/marshal-blocks         | text   | readline      |

### Write Paths (via shell subprocess)

Writes delegate to existing CLIs to preserve validation logic and side effects:

```python
# Journal write
subprocess.run(["./lineage.sh", "remember", text, "--rationale", r, "--tags", t])

# Graph write
subprocess.run(["./graph/graph.sh", "add", node_type, name, "--data", json_str])

# Pattern write
subprocess.run(["./patterns/patterns.sh", "capture", name, "--context", ctx, ...])
```

## API Endpoints

### Lineage — Journal

| Method | Path                        | Description                 |
| ------ | --------------------------- | --------------------------- |
| GET    | /api/journal/decisions      | List decisions (filterable) |
| GET    | /api/journal/decisions/{id} | Get single decision         |
| POST   | /api/journal/decisions      | Record new decision         |
| PATCH  | /api/journal/decisions/{id} | Update outcome/lesson       |
| GET    | /api/journal/search?q=      | Full-text search            |
| GET    | /api/journal/stats          | Aggregate statistics        |

**Query params**: `type`, `tag`, `project`, `outcome`, `limit`, `offset`

### Lineage — Graph

| Method | Path                        | Description                |
| ------ | --------------------------- | -------------------------- |
| GET    | /api/graph                  | Full graph (nodes + edges) |
| GET    | /api/graph/nodes            | List nodes (filterable)    |
| GET    | /api/graph/nodes/{id}       | Get node with edges        |
| POST   | /api/graph/nodes            | Add node                   |
| GET    | /api/graph/edges            | List edges (filterable)    |
| POST   | /api/graph/edges            | Add edge                   |
| GET    | /api/graph/related/{id}     | N-hop traversal            |
| GET    | /api/graph/path/{from}/{to} | Shortest path              |
| GET    | /api/graph/clusters         | Connected components       |
| GET    | /api/graph/stats            | Node/edge counts           |
| GET    | /api/graph/search?q=        | Full-text + fuzzy search   |
| GET    | /api/graph/lookup/{node_id} | Reverse lookup to journal  |

**Query params**: `type`, `limit`, `hops`

### Lineage — Patterns

| Method | Path                        | Description          |
| ------ | --------------------------- | -------------------- |
| GET    | /api/patterns               | List patterns        |
| GET    | /api/patterns/{id}          | Get single pattern   |
| POST   | /api/patterns               | Capture pattern      |
| GET    | /api/patterns/anti          | List anti-patterns   |
| GET    | /api/patterns/suggest?ctx=  | Suggest for context  |
| PATCH  | /api/patterns/{id}/validate | Increment confidence |

**Query params**: `type` (patterns/anti_patterns/all), `category`

### Lineage — Transfer

| Method | Path                 | Description         |
| ------ | -------------------- | ------------------- |
| GET    | /api/sessions        | List sessions       |
| GET    | /api/sessions/{id}   | Get session detail  |
| GET    | /api/sessions/latest | Most recent session |

### Lore — Registry

| Method | Path                          | Description                |
| ------ | ----------------------------- | -------------------------- |
| GET    | /api/lore/projects            | All projects from mani     |
| GET    | /api/lore/projects/{name}     | Project detail + metadata  |
| GET    | /api/lore/projects/{name}/ctx | Full context bundle        |
| GET    | /api/lore/clusters            | Cluster definitions        |
| GET    | /api/lore/clusters/{name}     | Cluster detail + data flow |
| GET    | /api/lore/relationships       | All relationships          |
| GET    | /api/lore/contracts           | Contract registry          |
| GET    | /api/lore/patterns            | Shared patterns            |
| GET    | /api/lore/validate            | Run validation pipeline    |

**Query params** for projects: `tag`, `cluster`, `type`, `status`, `lang`

### Council — Governance

| Method | Path                          | Description                |
| ------ | ----------------------------- | -------------------------- |
| GET    | /api/council/seats            | All seats with metadata    |
| GET    | /api/council/seats/{name}     | Seat detail + content list |
| GET    | /api/council/seats/{name}/{f} | Read specific seat content |
| GET    | /api/council/adrs             | All ADRs across seats      |
| GET    | /api/council/adrs/{slug}      | Single ADR detail          |
| GET    | /api/council/initiatives      | All initiatives            |
| GET    | /api/council/initiatives/{n}  | Initiative detail          |
| GET    | /api/council/charter          | Charter document           |
| GET    | /api/council/marshal/blocks   | Active marshal block rules |

### Cross-System

| Method | Path           | Description                 |
| ------ | -------------- | --------------------------- |
| GET    | /api/search?q= | Unified cross-system search |
| GET    | /api/health    | System health check         |
| GET    | /api/stats     | Combined statistics         |
| GET    | /api/timeline  | Unified event timeline      |

## Data Models (Python)

### Journal Decision

```python
class Decision(BaseModel):
    id: str
    timestamp: datetime
    session_id: str | None
    decision: str
    rationale: str | None
    alternatives: list[str]
    outcome: Literal["pending", "successful", "revised", "abandoned"]
    type: str
    entities: list[str]
    tags: list[str]
    lesson_learned: str | None
    related_decisions: list[str]
    git_commit: str | None
```

### Graph Node

```python
class GraphNode(BaseModel):
    id: str
    type: Literal["concept", "file", "pattern", "lesson", "decision", "session", "project"]
    name: str
    data: dict
    created_at: datetime
    updated_at: datetime
    edges: list[GraphEdge] = []  # populated on detail fetch
```

### Lore Project

```python
class Project(BaseModel):
    name: str
    path: str
    description: str
    tags: list[str]
    type: str | None       # extracted from tags
    language: str | None   # extracted from tags
    status: str | None     # extracted from tags
    cluster: str | None    # extracted from tags
    metadata: ProjectMetadata | None
    dependencies: list[Dependency] = []
    depended_on_by: list[Dependency] = []
```

### Council Seat

```python
class Seat(BaseModel):
    name: str
    directive: str
    core_question: str
    content_files: list[str]
    adrs: list[ADRSummary]
```

## Prototype Specifications

### Prototype 1: REST API Server

**File**: `api/server.py`
**Run**: `python api/server.py` (port 8420)
**Deps**: fastapi, uvicorn, pyyaml

Implements all endpoints above. Auto-generates OpenAPI docs at `/docs`.
Reads data files on each request (no caching for prototype — data files are
small). CORS enabled for local GUI development.

### Prototype 2: Knowledge Graph Explorer

**File**: `api/explorer.html`
**Open**: Browser, served by API at `/explorer`

Features:

- Force-directed graph layout (D3.js)
- Color-coded node types (concept=blue, project=green, decision=amber, etc.)
- Click node -> side panel with detail (name, type, data, connections)
- Edge labels showing relationship type
- Filter by node type (checkboxes)
- Search box (highlights matching nodes)
- Zoom/pan controls
- Node size proportional to connection count (hubs are larger)
- Layout: full-screen graph, collapsible left sidebar for filters

Data source: `GET /api/graph` on page load, detail from `/api/graph/nodes/{id}`

### Prototype 3: Governance Dashboard

**File**: `api/dashboard.html`
**Open**: Browser, served by API at `/dashboard`

Layout (CSS Grid, 3-column):

**Top row** (full width): Unified search bar + system health badges

**Left column**: Council overview

- Six seat cards (name, directive, core question)
- Active initiatives list with status badges
- Pending ADRs (click to expand)

**Center column**: Decision timeline

- Vertical timeline of recent decisions from journal
- Color-coded by source (council=purple, oracle=gold, lore=teal, manual=gray)
- Click to expand: rationale, alternatives, outcome
- Filter by tag/type/source

**Right column**: System health

- Pattern scores (top patterns by confidence, anti-patterns by severity)
- Lore registry health (validation status, project counts by status)
- Graph statistics (nodes, edges, orphans, clusters)
- Dependency map (mini force graph of project relationships)

Data sources: `/api/stats`, `/api/timeline`, `/api/council/seats`,
`/api/council/initiatives`, `/api/council/adrs`, `/api/patterns`,
`/api/lore/projects`, `/api/graph/stats`

## Directory Structure

```
api/
  server.py          # FastAPI application
  explorer.html      # Prototype 2: graph explorer
  dashboard.html     # Prototype 3: governance dashboard
  requirements.txt   # Python dependencies
  README.md          # Setup and run instructions
```

## Implementation Sequence

1. Build `server.py` with all endpoints (data reading layer first, then CLI writes)
2. Build `explorer.html` against the graph endpoints
3. Build `dashboard.html` against the remaining endpoints
4. Wire cross-system search and timeline endpoints last
